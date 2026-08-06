import Foundation

/// App-side wiring of the shared native MarketScanner factor-graph core
/// (V1R2 Gate G, V1R3 Gate F closeout). The core itself lives in
/// `core/MarketScannerFactorGraph` and is compiled directly into this
/// app target and into the PC diagnostic CLI — one implementation, two
/// surfaces.
///
/// C ABI safety (§9):
/// - every C call is nested inside `withCString` /
///   `withUnsafeBufferPointer` so no temporary bridge pointer outlives
///   the statement that uses it;
/// - the outcome is fully validated (counts, pointer nullness, id
///   uniqueness, finiteness, JSON well-formedness) before any value is
///   trusted;
/// - cancellation is checked before the error string so a cancelled run
///   surfaces `.cancelled`, not a generic failure.
enum MobileNativeFactorGraph {

    /// Outcome validation policy (§9.2).
    static let maximumTrajectoryRows: Int64 = 5_000_000
    static let maximumSkeletonNodes: Int64 = 5_000_000

    static func wireIntoGateway() {
        MobileNativeFactorGraphGateway.runFastImplementation = { request, isCancelled in
            return try run(request: request, fullGraph: false, isCancelled: isCancelled)
        }
        MobileNativeFactorGraphGateway.runFullGraphImplementation = { request, isCancelled in
            return try run(request: request, fullGraph: true, isCancelled: isCancelled)
        }
    }

    // MARK: - C ABI bridge

    /// Bridges cancellation state across the C ABI. File-scope visibility
    /// so the free-function C probe below can reference it.
    fileprivate final class RunContext {
        var isCancelled: () -> Bool
        var cancelledFlag = false

        init(isCancelled: @escaping () -> Bool) {
            self.isCancelled = isCancelled
        }
    }

    private static func run(
        request: MobileNativeGraphRequest,
        fullGraph: Bool,
        isCancelled: @escaping () -> Bool
    ) throws -> MobileNativeGraphOutcome {
        let context = RunContext(isCancelled: isCancelled)
        let contextPointer = Unmanaged.passRetained(context).toOpaque()
        defer { Unmanaged<RunContext>.fromOpaque(contextPointer).release() }

        // Map the Swift priors into the C struct layout. The array
        // buffer pointer is only used inside the nested C call below.
        var cPriors: [MSAbsolutePriorC] = request.absolutePriors.map { prior in
            var c = MSAbsolutePriorC(
                node_id: prior.nodeID,
                map_x: prior.mapXM,
                map_y: prior.mapYM,
                map_yaw: prior.mapYawRad,
                information_3x3: (0, 0, 0, 0, 0, 0, 0, 0, 0),
                kind: prior.kind,
                episode_id: prior.episodeID)
            for (index, value) in prior.information3x3.prefix(9).enumerated() {
                withUnsafeMutablePointer(to: &c.information_3x3) { tuplePtr in
                    tuplePtr.withMemoryRebound(to: Double.self, capacity: 9) { raw in
                        raw[index] = value
                    }
                }
            }
            return c
        }
        let tagNodeIDs = request.tagNodeIDs

        // §9.1: all bridge pointers live strictly inside this nested
        // call; nothing escapes the statement scope.
        let outcome: MobileNativeGraphOutcome = try request.databaseURL.path.withCString { dbPath in
            try tagNodeIDs.withUnsafeBufferPointer { tagBuffer in
                try cPriors.withUnsafeMutableBufferPointer { priorBuffer in
                    try request.priorMapID.withCString { mapIDPtr in
                    try request.priorMapSHA256.withCString { mapSHAPtr in
                    try request.trackingSessionID.withCString { sessionPtr in
                        var cRequest = MSFactorGraphRequestC(
                            db_path: dbPath,
                            tag_node_ids: tagBuffer.baseAddress,
                            tag_node_count: Int64(tagBuffer.count),
                            absolute_priors: priorBuffer.baseAddress,
                            absolute_prior_count: Int64(priorBuffer.count),
                            prior_map_id: mapIDPtr,
                            prior_map_sha256: mapSHAPtr,
                            tracking_session_id: sessionPtr,
                            projection_policy_version: request.projectionPolicyVersion,
                            max_nodes: 0,
                            max_wall_seconds: request.maxWallSeconds,
                            fast_iterations: 0,
                            deep_iterations: 0,
                            cancel: msNativeFactorGraphCancelProbe,
                            cancel_user: contextPointer,
                            progress: nil,
                            progress_user: nil)
                        var cOutcome = fullGraph
                            ? MSFactorGraphRunFullGraph(&cRequest)
                            : MSFactorGraphRunFast(&cRequest)
                        defer { MSFactorGraphFree(&cOutcome) }
                        return try Self.convert(cOutcome, context: context)
                    }}
                    }
                }
            }
        }
        return outcome
    }

    /// Validates and converts the C outcome (§9.2). Any violation raises
    /// `invalidOutcome` — unvalidated native memory is never trusted.
    private static func convert(
        _ cOutcome: MSFactorGraphOutcomeC,
        context: RunContext
    ) throws -> MobileNativeGraphOutcome {
        if context.cancelledFlag {
            throw MobileOnlyWorkflowError.cancelled
        }
        if let error = cOutcome.error {
            throw MobileNativeFactorGraphError.nativeFailed(String(cString: error))
        }

        let count = cOutcome.count
        guard count >= 0, count <= maximumTrajectoryRows else {
            throw MobileNativeFactorGraphError.invalidOutcome(
                "trajectory row count out of bounds: \(count)")
        }
        if count > 0 && cOutcome.rows == nil {
            throw MobileNativeFactorGraphError.invalidOutcome(
                "trajectory rows pointer is NULL with count > 0")
        }
        let skeletonCount = cOutcome.skeleton_count
        guard skeletonCount >= 0, skeletonCount <= maximumSkeletonNodes else {
            throw MobileNativeFactorGraphError.invalidOutcome(
                "skeleton count out of bounds: \(skeletonCount)")
        }
        if skeletonCount > 0 &&
            (cOutcome.skeleton_ids == nil || cOutcome.skeleton_x == nil ||
             cOutcome.skeleton_y == nil || cOutcome.skeleton_yaw == nil) {
            throw MobileNativeFactorGraphError.invalidOutcome(
                "skeleton pointers NULL with count > 0")
        }

        let qualityJSON: String
        if let json = cOutcome.quality_json {
            let candidate = String(cString: json)
            // The quality report must be valid UTF-8 JSON (§9.2).
            guard let data = candidate.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: data),
                  parsed is [String: Any] else {
                throw MobileNativeFactorGraphError.invalidOutcome(
                    "quality JSON is not a well-formed object")
            }
            qualityJSON = candidate
        } else {
            qualityJSON = ""
        }

        var trajectory: [MobileNativeTrajectoryRow] = []
        trajectory.reserveCapacity(Int(count))
        var seenIDs = Set<Int64>()
        if count > 0, let rows = cOutcome.rows {
            for index in 0..<Int(count) {
                let row = rows[index]
                guard seenIDs.insert(row.id).inserted else {
                    throw MobileNativeFactorGraphError.invalidOutcome(
                        "duplicate trajectory node id \(row.id)")
                }
                guard row.id > 0, row.id <= Int64(Int32.max) else {
                    throw MobileNativeFactorGraphError.invalidOutcome(
                        "trajectory node id out of int range: \(row.id)")
                }
                guard row.stamp.isFinite, row.xM.isFinite,
                      row.yM.isFinite, row.yawRad.isFinite else {
                    throw MobileNativeFactorGraphError.invalidOutcome(
                        "non-finite trajectory row at id \(row.id)")
                }
                trajectory.append(MobileNativeTrajectoryRow(
                    id: row.id,
                    stamp: row.stamp,
                    xM: row.xM,
                    yM: row.yM,
                    yawRad: row.yawRad,
                    mapID: row.map_id,
                    componentID: row.component_id,
                    publishEligible: row.publish_eligible != 0,
                    uncertaintyM: row.uncertainty_m.isFinite ? row.uncertainty_m : nil))
            }
        }

        var skeletonIDs: [Int64] = []
        if skeletonCount > 0, let ids = cOutcome.skeleton_ids {
            skeletonIDs.reserveCapacity(Int(skeletonCount))
            for index in 0..<Int(skeletonCount) {
                skeletonIDs.append(ids[index])
            }
        }

        return MobileNativeGraphOutcome(
            disposition: MobileGraphDisposition(rawValue: cOutcome.disposition)
                ?? .nonRecoverableFail,
            qualityJSON: qualityJSON,
            trajectory: trajectory,
            skeletonIDs: skeletonIDs)
    }
}

/// Free-function C cancellation probe (a C function pointer can only be
/// formed from a free `func` reference, not a static method).
private func msNativeFactorGraphCancelProbe(_ user: UnsafeMutableRawPointer?) -> Int32 {
    guard let user = user else { return 0 }
    let context = Unmanaged<MobileNativeFactorGraph.RunContext>.fromOpaque(user).takeUnretainedValue()
    if context.isCancelled() {
        context.cancelledFlag = true
        return 1
    }
    return 0
}
