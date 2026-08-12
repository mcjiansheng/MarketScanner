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

    /// Outcome validation policy (§9.2 / V1R5 §10.1 review H-16): the
    /// bounds are PRODUCT-DERIVED — the largest qualified store is
    /// ≈60k raw nodes, and the trajectory reconstruction emits at most
    /// one row per raw node. The V1R4 generic 5,000,000 ceiling would
    /// let an anomalous native outcome allocate tens of GiB before the
    /// resource governor could react.
    static let maximumTrajectoryRows = MobileNativeOutcomeContract
        .maximumTrajectoryRows
    static let maximumSkeletonNodes = MobileNativeOutcomeContract
        .maximumSkeletonNodes
    static let maximumRawNodes = MobileNativeOutcomeContract.maximumRawNodes
    static let maximumFactors = MobileNativeOutcomeContract.maximumFactors
    static let maximumPriors = MobileNativeOutcomeContract.maximumPriors

    static func wireIntoGateway() {
        MobileNativeFactorGraphGateway.runFastImplementation = { request, isCancelled in
            return try run(request: request, fullGraph: false, isCancelled: isCancelled)
        }
        MobileNativeFactorGraphGateway.runFullGraphImplementation = { request, isCancelled in
            return try run(request: request, fullGraph: true, isCancelled: isCancelled)
        }
        // Wire the snapshot-DB node inventory into the strict absolute
        // prior parser (§6.1): evidence binds to real RTAB-Map node ids
        // via the node-stamp (UTC) axis; without this wiring every
        // constraint/manual record is rejected by the audit (fail
        // closed, never applied with a default).
        MobileProcessingPipeline.absolutePriorNodeInventoryProvider = { databaseURL in
            guard let readout = try? MobileGraphReader.readGraph(databaseURL: databaseURL) else {
                return []
            }
            return readout.nodes.map {
                AbsolutePriorEvidenceNode(nodeID: $0.id, stamp: $0.stamp)
            }
        }
        // Wire the raw snapshot-DB node poses into the tag propagation
        // chain (§13.2): P_final = T_final_node * inverse(T_raw_node) *
        // P_raw needs T_raw_node per bound node id; without this wiring
        // every observation fails resolution with an explicit RESCAN
        // task (fail closed, never a default pose).
        MobileProcessingPipeline.rawNodePoseProvider = { databaseURL in
            guard let readout = try? MobileGraphReader.readGraph(databaseURL: databaseURL) else {
                return [:]
            }
            var poses: [Int64: SE2Transform] = [:]
            for node in readout.nodes {
                guard let pose = try? MobileGraphReader.projectToSE2(
                    poseRowMajor3x4: node.poseRowMajor3x4) else {
                    return [:]
                }
                poses[node.id] = pose
            }
            return poses
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
        // V1R5 §10.1 (review H-16): product-derived bounds — an
        // oversized input must fail before any native allocation.
        try MobileNativeOutcomeContract.validateInputCounts(
            priorCount: request.absolutePriors.count,
            tagNodeCount: request.tagNodeIDs.count)
        guard request.projectionPolicyVersion == 1,
              request.maxWallSeconds.isFinite,
              request.maxWallSeconds > 0,
              !request.priorMapID.isEmpty,
              !request.trackingSessionID.isEmpty,
              Self.isLowercaseSHA256(request.priorMapSHA256) else {
            throw MobileNativeFactorGraphError.invalidOutcome(
                "input projection/time/identity contract invalid")
        }
        var seenTagNodeIDs = Set<Int64>()
        guard request.tagNodeIDs.allSatisfy({
            $0 > 0 && seenTagNodeIDs.insert($0).inserted
        }) else {
            throw MobileNativeFactorGraphError.invalidOutcome(
                "tag node IDs must be positive and unique")
        }
        guard request.absolutePriors.allSatisfy({ prior in
            prior.nodeID > 0 && prior.mapXM.isFinite && prior.mapYM.isFinite &&
                prior.mapYawRad.isFinite && prior.information3x3.count == 9 &&
                prior.information3x3.allSatisfy({ $0.isFinite }) &&
                (prior.kind == 0 || prior.kind == 1 || prior.kind == 2 ||
                    prior.kind == 3) &&
                prior.episodeID >= 0
        }) else {
            throw MobileNativeFactorGraphError.invalidOutcome(
                "absolute prior shape/finite/identity contract invalid")
        }
        var cPriors: [MSAbsolutePriorC] = request.absolutePriors.map { prior in
            var c = MSAbsolutePriorC(
                node_id: prior.nodeID,
                map_x: prior.mapXM,
                map_y: prior.mapYM,
                map_yaw: prior.mapYawRad,
                information_3x3: (0, 0, 0, 0, 0, 0, 0, 0, 0),
                kind: prior.kind,
                episode_id: prior.episodeID)
            for (index, value) in prior.information3x3.enumerated() {
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
                        return try Self.convert(
                            cOutcome,
                            context: context,
                            request: request,
                            expectedPath: fullGraph
                                ? "full_graph_optimization" : "fast")
                    }}
                    }
                }
            }
        }
        return outcome
    }

    /// Validates and converts the C outcome (§9.2 / §10.4). Any violation
    /// raises `invalidOutcome` — unvalidated native memory is never
    /// trusted; unknown ABI values are errors, never silent downgrades.
    private static func convert(
        _ cOutcome: MSFactorGraphOutcomeC,
        context: RunContext,
        request: MobileNativeGraphRequest,
        expectedPath: String
    ) throws -> MobileNativeGraphOutcome {
        if context.cancelledFlag {
            throw MobileOnlyWorkflowError.cancelled
        }
        guard Int64(cOutcome.abi_version)
                == MobileNativeQualityReport.expectedABIVersion else {
            throw MobileNativeFactorGraphError.invalidOutcome(
                "runtime ABI version mismatch: \(cOutcome.abi_version)")
        }
        // Disposition is authoritative and is parsed BEFORE the optional
        // error string. RESOURCE_REQUIRED often carries a diagnostic error
        // and must remain a resumable resource pause, while an unknown ABI
        // disposition is invalid even if an error string is present.
        let disposition = try MobileNativeOutcomeContract.disposition(
            rawValue: cOutcome.disposition,
            errorMessage: cOutcome.error.map { String(cString: $0) })

        let count = cOutcome.count
        guard count >= 0, count <= maximumTrajectoryRows else {
            throw MobileNativeFactorGraphError.invalidOutcome(
                "trajectory row count out of bounds: \(count)")
        }
        if (count == 0) != (cOutcome.rows == nil) {
            throw MobileNativeFactorGraphError.invalidOutcome(
                "trajectory rows pointer/count mismatch")
        }
        let skeletonCount = cOutcome.skeleton_count
        guard skeletonCount >= 0, skeletonCount <= maximumSkeletonNodes else {
            throw MobileNativeFactorGraphError.invalidOutcome(
                "skeleton count out of bounds: \(skeletonCount)")
        }
        let allSkeletonPointersNil = cOutcome.skeleton_ids == nil &&
            cOutcome.skeleton_x == nil && cOutcome.skeleton_y == nil &&
            cOutcome.skeleton_yaw == nil
        let allSkeletonPointersPresent = cOutcome.skeleton_ids != nil &&
            cOutcome.skeleton_x != nil && cOutcome.skeleton_y != nil &&
            cOutcome.skeleton_yaw != nil
        if (skeletonCount == 0 && !allSkeletonPointersNil) ||
            (skeletonCount > 0 && !allSkeletonPointersPresent) {
            throw MobileNativeFactorGraphError.invalidOutcome(
                "skeleton pointers/count mismatch")
        }

        var trajectory: [MobileNativeTrajectoryRow] = []
        trajectory.reserveCapacity(Int(count))
        var seenIDs = Set<Int64>()
        // §10.4: stamps must be monotonic within each component. Different
        // disconnected components are emitted in deterministic topology
        // order, not necessarily in one global timestamp order; imposing a
        // cross-component monotonic gate would reject a valid native result.
        // The processing pipeline sorts the validated rows by stamp before
        // building the one-hertz business trajectory.
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
                guard row.map_id >= -1, row.map_id <= Int64(Int32.max) else {
                    throw MobileNativeFactorGraphError.invalidOutcome(
                        "trajectory node id \(row.id) map_id out of range: \(row.map_id)")
                }
                guard row.component_id >= -1, row.component_id <= Int64(Int32.max) else {
                    throw MobileNativeFactorGraphError.invalidOutcome(
                        "trajectory node id \(row.id) component_id out of range: \(row.component_id)")
                }
                guard row.stamp.isFinite, row.x.isFinite,
                      row.y.isFinite, row.yaw.isFinite else {
                    throw MobileNativeFactorGraphError.invalidOutcome(
                        "non-finite trajectory row at id \(row.id)")
                }
                // §10.4: the publish bool is strictly 0/1.
                guard row.publish_eligible == 0 || row.publish_eligible == 1 else {
                    throw MobileNativeFactorGraphError.invalidOutcome(
                        "publish_eligible is not 0/1 at id \(row.id): \(row.publish_eligible)")
                }
                // §10.4: uncertainty is nil (NaN) or finite non-negative.
                guard row.uncertainty_m.isNaN ||
                      (row.uncertainty_m.isFinite && row.uncertainty_m >= 0.0) else {
                    throw MobileNativeFactorGraphError.invalidOutcome(
                        "uncertainty invalid at id \(row.id): \(row.uncertainty_m)")
                }
                trajectory.append(MobileNativeTrajectoryRow(
                    id: row.id,
                    stamp: row.stamp,
                    xM: row.x,
                    yM: row.y,
                    yawRad: row.yaw,
                    mapID: row.map_id,
                    componentID: row.component_id,
                    publishEligible: row.publish_eligible == 1,
                    uncertaintyM: row.uncertainty_m.isNaN ? nil : row.uncertainty_m))
            }
        }
        try MobileNativeOutcomeContract.validateComponentTimestampOrder(
            trajectory)

        // §10.4: skeleton IDs are unique, a subset of the trajectory,
        // and carry finite poses.
        var skeletonIDs: [Int64] = []
        if skeletonCount > 0, let ids = cOutcome.skeleton_ids,
           let xPtr = cOutcome.skeleton_x,
           let yPtr = cOutcome.skeleton_y,
           let yawPtr = cOutcome.skeleton_yaw {
            skeletonIDs.reserveCapacity(Int(skeletonCount))
            var seenSkeleton = Set<Int64>()
            for index in 0..<Int(skeletonCount) {
                let id = ids[index]
                guard seenSkeleton.insert(id).inserted else {
                    throw MobileNativeFactorGraphError.invalidOutcome(
                        "duplicate skeleton node id \(id)")
                }
                guard seenIDs.contains(id) else {
                    throw MobileNativeFactorGraphError.invalidOutcome(
                        "skeleton node id \(id) is not a trajectory row")
                }
                guard xPtr[index].isFinite, yPtr[index].isFinite,
                      yawPtr[index].isFinite else {
                    throw MobileNativeFactorGraphError.invalidOutcome(
                        "non-finite skeleton pose at id \(id)")
                }
                skeletonIDs.append(id)
            }
        }

        guard cOutcome.factor_count >= 0,
              cOutcome.factor_count <= maximumFactors,
              cOutcome.publish_count >= 0,
              cOutcome.publish_count <= count else {
            throw MobileNativeFactorGraphError.invalidOutcome(
                "native factor/publish counts are out of bounds")
        }
        let actualPublishCount = trajectory.filter { $0.publishEligible }.count
        guard cOutcome.publish_count == Int64(actualPublishCount) else {
            throw MobileNativeFactorGraphError.invalidOutcome(
                "native publish_count does not match C trajectory rows")
        }

        let qualityJSON = try boundedNativeUTF8(
            cOutcome.quality_json,
            byteCount: cOutcome.quality_json_size,
            maximumBytes: MobileNativeOutcomeContract.maximumQualityJSONBytes,
            name: "quality JSON")
        let graphInputSHA256 = try boundedNativeUTF8(
            cOutcome.graph_input_sha256,
            byteCount: cOutcome.graph_input_sha256_size,
            maximumBytes: 64,
            name: "graph_input_sha256")
        let factorSetSHA256 = try boundedNativeUTF8(
            cOutcome.factor_set_sha256,
            byteCount: cOutcome.factor_set_sha256_size,
            maximumBytes: 64,
            name: "factor_set_sha256")
        guard isLowercaseSHA256(graphInputSHA256),
              isLowercaseSHA256(factorSetSHA256) else {
            throw MobileNativeFactorGraphError.invalidOutcome(
                "native graph/factor SHA is malformed")
        }
        let report = try MobileNativeQualityReport.parse(
            qualityJSON: qualityJSON)
        try report.validate(
            request: request,
            expectedPath: expectedPath,
            disposition: disposition,
            trajectoryCount: trajectory.count,
            skeletonCount: skeletonIDs.count,
            publishCount: actualPublishCount,
            cABIVersion: Int64(cOutcome.abi_version),
            cFactorCount: cOutcome.factor_count,
            cGraphInputSHA256: graphInputSHA256,
            cFactorSetSHA256: factorSetSHA256)

        return MobileNativeGraphOutcome(
            disposition: disposition,
            qualityJSON: qualityJSON,
            trajectory: trajectory,
            skeletonIDs: skeletonIDs)
    }

    private static func boundedNativeUTF8(
        _ pointer: UnsafePointer<CChar>?,
        byteCount: Int64,
        maximumBytes: Int,
        name: String
    ) throws -> String {
        guard byteCount > 0,
              byteCount <= Int64(maximumBytes),
              let pointer else {
            throw MobileNativeFactorGraphError.invalidOutcome(
                "\(name) pointer/size mismatch")
        }
        let count = Int(byteCount)
        guard pointer[count] == 0 else {
            throw MobileNativeFactorGraphError.invalidOutcome(
                "\(name) is not NUL terminated at its declared size")
        }
        let data = Data(bytes: pointer, count: count)
        guard let value = String(data: data, encoding: .utf8),
              !value.isEmpty else {
            throw MobileNativeFactorGraphError.invalidOutcome(
                "\(name) is not non-empty UTF-8")
        }
        return value
    }

    private static func isLowercaseSHA256(_ value: String) -> Bool {
        guard value.utf8.count == 64 else { return false }
        return value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
        }
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
