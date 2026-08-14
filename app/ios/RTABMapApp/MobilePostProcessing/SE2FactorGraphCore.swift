import Foundation

/// In-process relative SE(2) factor graph optimizer (Fast Path).
///
/// Nodes carry an initial pose; edges carry relative measurements
/// (odometry, loop closures, prior-map constraints, road priors,
/// accepted localization constraints) with a scalar weight. The
/// optimizer runs bounded Gauss-Newton iterations with a deterministic
/// sparse solve (conjugate gradients with Levenberg-Marquardt damping),
/// finite checks on every step and a fixed iteration budget — no
/// randomization, no unbounded memory (storage is O(edges)).
enum SE2FactorGraphCore {
    struct Node {
        var id: Int64
        var initialPose: SE2Transform
        var isAnchor: Bool
        var floorID: String
    }

    struct Edge {
        var from: Int64
        var to: Int64
        var measurement: SE2Transform
        var weight: Double
        var kind: String
    }

    struct OptimizedGraph {
        var poses: [Int64: SE2Transform]
        var finalResidual: Double
        var iterationsUsed: Int
        var converged: Bool
    }

    enum FactorGraphError: Error {
        case noFreeNodes
        case duplicateNode(Int64)
        case noAnchor
        case unknownNode(Int64)
        case nonFiniteState
        case solverDiverged
    }

    static let maximumIterations = 100
    static let convergenceTolerance = 1.0e-7
    static let maximumCGSolverIterations = 120

    static func optimize(nodes: [Node], edges: [Edge]) throws -> OptimizedGraph {
        // Duplicate node IDs are a typed error (V1R1 §10.2) — never a
        // Dictionary trap.
        var seenIDs: Set<Int64> = []
        for node in nodes {
            guard seenIDs.insert(node.id).inserted else {
                throw FactorGraphError.duplicateNode(node.id)
            }
        }
        // At least one anchor is required (V1R1 §10.2): without a fixed
        // reference the whole graph is gauge-free and the solve is
        // meaningless.
        guard nodes.contains(where: { $0.isAnchor }) else {
            throw FactorGraphError.noAnchor
        }
        let byID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        let freeIDs = nodes.filter { !$0.isAnchor }.map { $0.id }.sorted()
        guard !freeIDs.isEmpty else {
            throw FactorGraphError.noFreeNodes
        }
        var indexOf: [Int64: Int] = [:]
        for (index, id) in freeIDs.enumerated() {
            indexOf[id] = index
        }
        var state: [Double] = []
        for id in freeIDs {
            guard let pose = byID[id]?.initialPose else {
                throw FactorGraphError.unknownNode(id)
            }
            state.append(pose.xM)
            state.append(pose.yM)
            state.append(pose.yawRad)
        }
        for edge in edges {
            guard byID[edge.from] != nil, byID[edge.to] != nil else {
                throw FactorGraphError.unknownNode(byID[edge.from] == nil ? edge.from : edge.to)
            }
            guard edge.weight > 0, edge.weight.isFinite,
                  edge.measurement.xM.isFinite, edge.measurement.yM.isFinite,
                  edge.measurement.yawRad.isFinite
            else {
                throw FactorGraphError.nonFiniteState
            }
        }

        var previousResidual = Double.infinity
        var converged = false
        var iterationsUsed = 0
        for iteration in 0..<maximumIterations {
            iterationsUsed = iteration + 1
            let squared = try squaredResidual(
                state: state, nodes: byID, freeIDs: freeIDs, edges: edges)
            guard squared.isFinite else {
                throw FactorGraphError.nonFiniteState
            }
            if squared <= convergenceTolerance * convergenceTolerance
                || abs(previousResidual - squared) < convergenceTolerance * max(1.0, previousResidual) {
                converged = true
                break
            }
            previousResidual = squared
            let step = try solveNormalEquations(
                state: state, nodes: byID, freeIDs: freeIDs,
                indexOf: indexOf, edges: edges)
            var applied = 0.0
            for (parameterIndex, delta) in step.enumerated() {
                state[parameterIndex] += delta
                applied += delta * delta
            }
            guard state.allSatisfy({ $0.isFinite }) else {
                throw FactorGraphError.nonFiniteState
            }
            if applied < convergenceTolerance {
                converged = true
                break
            }
        }

        var poses: [Int64: SE2Transform] = [:]
        for (index, id) in freeIDs.enumerated() {
            poses[id] = SE2Transform(
                xM: state[index * 3],
                yM: state[index * 3 + 1],
                yawRad: SourceGeometry.normalizeAngle(state[index * 3 + 2]))
        }
        for node in nodes where node.isAnchor {
            poses[node.id] = node.initialPose
        }
        let finalResidual = try squaredResidual(
            state: state, nodes: byID, freeIDs: freeIDs, edges: edges)
        return OptimizedGraph(
            poses: poses,
            finalResidual: finalResidual,
            iterationsUsed: iterationsUsed,
            converged: converged)
    }

    // MARK: - Residuals

    private static func posesForState(
        _ state: [Double],
        nodes: [Int64: Node],
        freeIDs: [Int64]
    ) throws -> [Int64: SE2Transform] {
        guard state.count == freeIDs.count * 3 else {
            throw FactorGraphError.nonFiniteState
        }
        var poses: [Int64: SE2Transform] = [:]
        for (id, node) in nodes {
            poses[id] = node.initialPose
        }
        for (index, id) in freeIDs.enumerated() {
            poses[id] = SE2Transform(
                xM: state[index * 3], yM: state[index * 3 + 1],
                yawRad: state[index * 3 + 2])
        }
        return poses
    }

    private static func relativeError(
        from: SE2Transform,
        to: SE2Transform,
        measurement: SE2Transform
    ) -> (dx: Double, dy: Double, dyaw: Double) {
        let relative = from.inverse.composed(with: to)
        let dx = measurement.xM - relative.xM
        let dy = measurement.yM - relative.yM
        let dyaw = SourceGeometry.shortestAngleDifference(relative.yawRad, measurement.yawRad)
        return (dx, dy, dyaw)
    }

    /// Builds the stacked residual vector for the current state.
    private static func residualVector(
        state: [Double],
        nodes: [Int64: Node],
        freeIDs: [Int64],
        edges: [Edge]
    ) throws -> [Double] {
        let poses = try posesForState(
            state, nodes: nodes, freeIDs: freeIDs)
        var rows: [Double] = []
        for edge in edges {
            guard let fromPose = poses[edge.from],
                  let toPose = poses[edge.to] else {
                throw FactorGraphError.unknownNode(
                    poses[edge.from] == nil ? edge.from : edge.to)
            }
            let error = relativeError(
                from: fromPose, to: toPose,
                measurement: edge.measurement)
            rows.append(error.dx)
            rows.append(error.dy)
            rows.append(error.dyaw)
        }
        return rows
    }

    private static func squaredResidual(
        state: [Double],
        nodes: [Int64: Node],
        freeIDs: [Int64],
        edges: [Edge]
    ) throws -> Double {
        let rows = try residualVector(
            state: state, nodes: nodes, freeIDs: freeIDs, edges: edges)
        guard rows.allSatisfy({ $0.isFinite }) else {
            throw FactorGraphError.nonFiniteState
        }
        return rows.reduce(0) { $0 + $1 * $1 }
    }

    // MARK: - Sparse normal equations (analytic Jacobian + damped CG)

    private static func solveNormalEquations(
        state: [Double],
        nodes: [Int64: Node],
        freeIDs: [Int64],
        indexOf: [Int64: Int],
        edges: [Edge]
    ) throws -> [Double] {
        let stateCount = freeIDs.count * 3
        let poses = try posesForState(
            state, nodes: nodes, freeIDs: freeIDs)
        let rows = try residualVector(
            state: state, nodes: nodes, freeIDs: freeIDs, edges: edges)

        // A = J^T W J (sparse rows), b = -J^T W r.
        var aRows: [[(col: Int, value: Double)]] = Array(repeating: [], count: stateCount)
        var b = Array(repeating: 0.0, count: stateCount)
        var rowIndex = 0
        for edge in edges {
            let weight = edge.weight
            let r0 = rows[rowIndex]
            let r1 = rows[rowIndex + 1]
            let r2 = rows[rowIndex + 2]
            guard let fromPose = poses[edge.from], let toPose = poses[edge.to] else {
                throw FactorGraphError.unknownNode(edge.from)
            }
            let cosF = cos(fromPose.yawRad)
            let sinF = sin(fromPose.yawRad)
            let tx = toPose.xM - fromPose.xM
            let ty = toPose.yM - fromPose.yM
            // Analytic Jacobian columns of e = z - R(-yaw_f)*(t_to-t_from):
            // de/dx_f = R(-theta)*(1,0) = (c,-s); de/dy_f = (s,c);
            // de/dyaw_f = -(dR(-theta)/dtheta)*(tx,ty) = (s*tx-c*ty, c*tx+s*ty);
            // de/dx_t = (-c,s); de/dy_t = (-s,-c); e_yaw rows as noted.
            let fromIndexBase = indexOf[edge.from].map { $0 * 3 } ?? -1
            let toIndexBase = indexOf[edge.to].map { $0 * 3 } ?? -1
            var columns: [(parameter: Int, dx: Double, dy: Double, dyaw: Double)] = []
            if fromIndexBase >= 0 {
                columns.append((fromIndexBase + 0, cosF, -sinF, 0.0))
                columns.append((fromIndexBase + 1, sinF, cosF, 0.0))
                columns.append((fromIndexBase + 2, sinF * tx - cosF * ty, cosF * tx + sinF * ty, 1.0))
            }
            if toIndexBase >= 0 {
                columns.append((toIndexBase + 0, -cosF, sinF, 0.0))
                columns.append((toIndexBase + 1, -sinF, -cosF, 0.0))
                columns.append((toIndexBase + 2, 0.0, 0.0, -1.0))
            }
            for column in columns {
                b[column.parameter] -= weight
                    * (column.dx * r0 + column.dy * r1 + column.dyaw * r2)
                for other in columns {
                    let value = weight
                        * (column.dx * other.dx + column.dy * other.dy + column.dyaw * other.dyaw)
                    aRows[column.parameter].append((other.parameter, value))
                }
            }
            rowIndex += 3
        }

        // Damped (Levenberg-Marquardt) conjugate-gradient solve.
        var damping = 1.0e-3
        var lastDelta: [Double] = []
        var lastNorm = Double.infinity
        for _ in 0..<8 {
            var diagonal: [Double] = []
            for column in 0..<stateCount {
                var diag = damping
                for entry in aRows[column] where entry.col == column {
                    diag += entry.value
                }
                diagonal.append(diag)
            }
            let delta = try conjugateGradient(
                aRows: aRows, diagonal: diagonal, b: b,
                maximumIterations: maximumCGSolverIterations)
            var residualNorm = 0.0
            for column in 0..<stateCount {
                var ax = 0.0
                for entry in aRows[column] {
                    ax += entry.value * delta[entry.col]
                }
                ax += diagonal[column] * delta[column]
                residualNorm += (ax - b[column]) * (ax - b[column])
            }
            if residualNorm < 1.0e-12 {
                return delta
            }
            if residualNorm < lastNorm {
                lastNorm = residualNorm
                lastDelta = delta
            }
            damping *= 0.5
        }
        if !lastDelta.isEmpty {
            return lastDelta
        }
        throw FactorGraphError.solverDiverged
    }

    /// Sparse conjugate-gradient solver for (A + D) x = b.
    private static func conjugateGradient(
        aRows: [[(col: Int, value: Double)]],
        diagonal: [Double],
        b: [Double],
        maximumIterations: Int
    ) throws -> [Double] {
        let count = b.count
        var x = Array(repeating: 0.0, count: count)
        var r = b
        var p = r
        var rsOld = r.reduce(0) { $0 + $1 * $1 }
        guard rsOld > 0 else { return x }
        for _ in 0..<maximumIterations {
            var ap = Array(repeating: 0.0, count: count)
            for column in 0..<count {
                var value = diagonal[column] * p[column]
                for entry in aRows[column] {
                    value += entry.value * p[entry.col]
                }
                ap[column] = value
            }
            let pAp = zip(p, ap).reduce(0) { $0 + $1.0 * $1.1 }
            guard pAp > 0, pAp.isFinite else { break }
            let alpha = rsOld / pAp
            for index in 0..<count {
                x[index] += alpha * p[index]
                r[index] -= alpha * ap[index]
            }
            let rsNew = r.reduce(0) { $0 + $1 * $1 }
            if rsNew < 1.0e-14 { break }
            let beta = rsNew / rsOld
            for index in 0..<count {
                p[index] = r[index] + beta * p[index]
            }
            rsOld = rsNew
        }
        guard x.allSatisfy({ $0.isFinite }) else {
            throw FactorGraphError.nonFiniteState
        }
        return x
    }
}
