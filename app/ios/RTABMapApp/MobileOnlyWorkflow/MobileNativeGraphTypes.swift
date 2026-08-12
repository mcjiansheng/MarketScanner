import Foundation

/// Native factor-graph product types and the gateway seam (V1R2 Gate G,
/// V1R3 evidence-integrity closeout).
///
/// `MobileNativeFactorGraphGateway` is the ONLY entry point the
/// processing pipeline uses. The real app wires the shared native
/// factor-graph core (compiled from `core/MarketScannerFactorGraph`) at
/// startup; the Swift host suite wires a deterministic reference
/// implementation so pipeline orchestration stays testable without the
/// C bridge. Production runs always use the native core — the Swift
/// `SE2FactorGraphCore` solver is a host-test reference only (§11.5).
enum MobileGraphDisposition: Int32 {
    case pass = 0
    case recoverableFail = 1
    case nonRecoverableFail = 2
    case resourceRequired = 3
    /// Solved in the local frame only: no accepted prior-map absolute
    /// constraint anchors the graph to the map (V1R3 §6.4). Diagnostics
    /// only — never publishable.
    case localFrameOnly = 4

    var reportValue: String {
        switch self {
        case .pass: return "PASS"
        case .recoverableFail: return "RECOVERABLE_FAIL"
        case .nonRecoverableFail: return "NON_RECOVERABLE_FAIL"
        case .resourceRequired: return "RESOURCE_REQUIRED"
        case .localFrameOnly: return "LOCAL_FRAME_ONLY"
        }
    }
}

/// Absolute prior-map constraint (V1R3 §6.3): the node pose expressed in
/// the PRIOR-MAP frame (T_map_node) with policy-sourced information.
struct MobileAbsolutePrior {
    var nodeID: Int64
    var mapXM: Double
    var mapYM: Double
    var mapYawRad: Double
    /// Row-major 3x3 planar information.
    var information3x3: [Double]
    /// 0 localization, 1 recovery, 2 manual, 3 operator-selected initial pose.
    var kind: Int32
    var episodeID: Int64
}

/// One reconstructed trajectory row (V1R3 §15): component and floor
/// identity travel with every node; uncertainty is nil when it cannot be
/// estimated (never fabricated as 0).
struct MobileNativeTrajectoryRow {
    var id: Int64
    var stamp: Double
    var xM: Double
    var yM: Double
    var yawRad: Double
    var mapID: Int32
    var componentID: Int64
    var publishEligible: Bool
    var uncertaintyM: Double?
}

struct MobileNativeGraphOutcome {
    var disposition: MobileGraphDisposition
    var qualityJSON: String
    var trajectory: [MobileNativeTrajectoryRow]
    var skeletonIDs: [Int64]
}

enum MobileNativeFactorGraphError: Error, LocalizedError {
    case nativeFailed(String)
    case notWired
    /// The C outcome failed validation (§9.2) — never trust unvalidated
    /// native memory.
    case invalidOutcome(String)

    var errorDescription: String? {
        switch self {
        case .nativeFailed(let detail): return "原生因子图求解失败：\(detail)"
        case .notWired: return "原生因子图核心尚未接线"
        case .invalidOutcome(let detail): return "原生结果校验失败：\(detail)"
        }
    }
}

/// Strict, fully typed representation of the native quality format.
///
/// The report is a security boundary, not an extensible telemetry bag:
/// duplicate keys, unknown/missing fields, JSON Bool values in numeric
/// positions, fractional counts and non-finite numbers all fail closed.
/// Schema/runtime constants are intentionally frozen beside the parser so a
/// native ABI or quality-format change cannot silently reach RunSummary.
struct MobileNativeQualityReport {
    static let expectedFormat = "MarketScannerGraphQuality"
    static let expectedVersion: Int64 = 3
    static let expectedABIVersion: Int64 = 5
    static let expectedPolicyVersion = "candidate-1"

    struct ResidualTriple {
        let count: Int64
        let p50: Double
        let p95: Double
        let maximum: Double
    }

    struct ResidualsByKind {
        let odometry: ResidualTriple
        let loop: ResidualTriple
        let prior: ResidualTriple
        let recovery: ResidualTriple
    }

    struct InformationPolicy {
        let regularized: Int64
        let rejected: Int64
    }

    struct Correction {
        let median: Double
        let p95: Double
        let maximum: Double
        let maximumJump: Double
        let yawMedian: Double
        let yawP95: Double
        let yawMaximum: Double
        let yawMaximumJump: Double
    }

    struct Solver {
        let strategy: String
        let iterations: Int64
        let finalError: Double
        let converged: Bool
        let stoppedReason: String
        let initialError: Double?
        let relativeImprovement: Double?
        let wallSeconds: Double
        let chunks: Int64
        let skeletonNodes: Int64
        let factorCount: Int64
        let available: Bool
    }

    struct GaugeComponent {
        let componentID: Int64
        let candidateCount: Int64
        let inlierCount: Int64
        let outlierCount: Int64
        let consensusRatio: Double
        let secondClusterRatio: Double
        let translationSpreadM: Double
        let yawSpreadRad: Double
        let authority: String
        let initialAuthorityCandidateCount: Int64
        let longRangeLoopFactorCount: Int64
        let anchored: Bool
        let rejectReason: String
    }

    struct Health {
        let nodeCount: Int64
        let linkCount: Int64
        let malformedLinks: Int64
        let voidLinks: Int64
        let ignoredOptionalLinks: Int64
        let loopLinks: Int64
        let priorLinks: Int64
        let recoveryLinks: Int64
    }

    let format: String
    let version: Int64
    let policyVersion: String
    let abiVersion: Int64
    let path: String
    let disposition: String
    let graphInputSHA256: String
    let factorSetSHA256: String
    let projectionPolicyVersion: Int64
    let priorMapID: String
    let priorMapSHA256: String
    let trackingSessionID: String
    let absolutePriorCount: Int64
    let parsedValidPriorCount: Int64
    let appliedPriorFactorCount: Int64
    let uniquePriorNodeCount: Int64
    let appliedPriorCount: Int64
    let initialMapPosePriorCount: Int64
    let robustConsensusPriorCount: Int64
    let robustConsensusUniquePriorNodeCount: Int64
    let longRangeLoopFactorCount: Int64
    let rejectedPriors: Int64
    let fusedPriorDuplicates: Int64
    let priorConflicts: Int64
    let componentCount: Int64
    let totalComponents: Int64
    let anchoredComponents: Int64
    let publishNodes: Int64
    let publishRatio: Double
    let anchoredRatio: Double
    let isolatedCount: Int64
    let crossFloorLinkCount: Int64
    let gapSegments: Int64
    let aggregatedChains: Int64
    let reciprocalInconsistent: Int64
    let weightedChi2: Double
    let degreesOfFreedom: Int64
    let chi2PerDegreeOfFreedom: Double
    let residualsByKind: ResidualsByKind
    let yawResidualsByKind: ResidualsByKind
    let residualThresholdRatio: Double
    let yawThresholdRatio: Double
    let informationPolicy: InformationPolicy
    let correction: Correction
    let coverage: Double
    let optimizerError: String
    let solver: Solver
    let gaugesByComponent: [GaugeComponent]
    let health: Health

    private static let rootKeys: Set<String> = [
        "format", "version", "policy_version", "abi_version", "path",
        "disposition", "graph_input_sha256", "factor_set_sha256",
        "projection_policy_version", "prior_map_id", "prior_map_sha256",
        "tracking_session_id", "absolute_prior_count",
        "parsed_valid_prior_count", "applied_prior_factor_count",
        "unique_prior_node_count", "applied_prior_count", "rejected_priors",
        "initial_map_pose_prior_count", "long_range_loop_factor_count",
        "robust_consensus_prior_count",
        "robust_consensus_unique_prior_node_count",
        "fused_prior_duplicates", "prior_conflicts", "component_count",
        "total_components", "anchored_components", "publish_nodes",
        "publish_ratio", "anchored_ratio", "isolated_count",
        "cross_floor_link_count", "gap_segments", "aggregated_chains",
        "reciprocal_inconsistent", "weighted_chi2", "dof", "chi2_per_dof",
        "residual_by_kind", "yaw_residual_by_kind",
        "residual_threshold_ratio", "yaw_threshold_ratio", "info_policy",
        "correction", "coverage", "optimizer_error", "solver",
        "gauge_by_component", "health",
    ]

    private static func invalid(_ detail: String) -> MobileNativeFactorGraphError {
        return .invalidOutcome("quality JSON \(detail)")
    }

    private static func requireExactKeys(
        _ object: [String: Any], _ expected: Set<String>, _ name: String
    ) throws {
        guard Set(object.keys) == expected else {
            throw invalid("\(name) has unknown or missing fields")
        }
    }

    private static func string(
        _ object: [String: Any], _ key: String,
        maximumLength: Int = 512, allowEmpty: Bool = false
    ) throws -> String {
        guard let value = object[key] as? String,
              value.count <= maximumLength,
              (allowEmpty || !value.isEmpty),
              value.unicodeScalars.allSatisfy({
                  $0.value >= 0x20 && $0.value != 0x7f
              }) else {
            throw invalid("\(key) is not a bounded printable string")
        }
        return value
    }

    private static func integer(
        _ object: [String: Any], _ key: String,
        minimum: Int64 = 0, maximum: Int64 = Int64.max
    ) throws -> Int64 {
        guard let parsed = StrictJSONScalar.integer(object[key]) else {
            throw invalid("\(key) is not a strict integer")
        }
        let value = Int64(parsed)
        guard value >= minimum, value <= maximum else {
            throw invalid("\(key) is out of bounds")
        }
        return value
    }

    private static func number(
        _ object: [String: Any], _ key: String,
        minimum: Double = 0.0, maximum: Double = Double.greatestFiniteMagnitude
    ) throws -> Double {
        guard let value = StrictJSONScalar.number(object[key]),
              value >= minimum, value <= maximum else {
            throw invalid("\(key) is not a finite in-range number")
        }
        return value
    }

    private static func nullableNumber(
        _ object: [String: Any], _ key: String
    ) throws -> Double? {
        if object[key] is NSNull { return nil }
        guard let value = StrictJSONScalar.number(object[key]) else {
            throw invalid("\(key) is neither null nor a finite number")
        }
        return value
    }

    private static func boolean(
        _ object: [String: Any], _ key: String
    ) throws -> Bool {
        guard let value = StrictJSONScalar.boolean(object[key]) else {
            throw invalid("\(key) is not a JSON boolean")
        }
        return value
    }

    private static func object(
        _ parent: [String: Any], _ key: String
    ) throws -> [String: Any] {
        guard let value = parent[key] as? [String: Any] else {
            throw invalid("\(key) is not an object")
        }
        return value
    }

    private static func sha256(
        _ object: [String: Any], _ key: String
    ) throws -> String {
        let value = try string(object, key, maximumLength: 64)
        guard value.count == 64,
              value.unicodeScalars.allSatisfy({ scalar in
                  (scalar.value >= 48 && scalar.value <= 57)
                      || (scalar.value >= 97 && scalar.value <= 102)
              }) else {
            throw invalid("\(key) is not a lowercase SHA-256")
        }
        return value
    }

    private static func residualTriple(
        _ object: [String: Any], _ name: String
    ) throws -> ResidualTriple {
        try requireExactKeys(object, ["count", "p50", "p95", "max"], name)
        let result = ResidualTriple(
            count: try integer(object, "count"),
            p50: try number(object, "p50"),
            p95: try number(object, "p95"),
            maximum: try number(object, "max"))
        guard result.p50 <= result.p95, result.p95 <= result.maximum else {
            throw invalid("\(name) percentiles are not ordered")
        }
        return result
    }

    private static func residualsByKind(
        _ object: [String: Any], _ name: String
    ) throws -> ResidualsByKind {
        let keys: Set<String> = ["odometry", "loop", "prior", "recovery"]
        try requireExactKeys(object, keys, name)
        return ResidualsByKind(
            odometry: try residualTriple(try self.object(object, "odometry"), "\(name).odometry"),
            loop: try residualTriple(try self.object(object, "loop"), "\(name).loop"),
            prior: try residualTriple(try self.object(object, "prior"), "\(name).prior"),
            recovery: try residualTriple(try self.object(object, "recovery"), "\(name).recovery"))
    }

    static func parse(qualityJSON: String) throws -> MobileNativeQualityReport {
        guard let data = qualityJSON.data(using: .utf8),
              !data.isEmpty,
              data.count <= MobileNativeOutcomeContract.maximumQualityJSONBytes else {
            throw invalid("is missing, non-UTF-8 or too large")
        }
        let root: [String: Any]
        do {
            root = try StrictJSONDocumentParser.object(
                from: data,
                limits: StrictJSONDocumentLimits(
                    maximumBytes: MobileNativeOutcomeContract.maximumQualityJSONBytes))
        } catch {
            throw invalid("is not a strict JSON object")
        }
        try requireExactKeys(root, rootKeys, "root")

        let format = try string(root, "format", maximumLength: 64)
        let version = try integer(root, "version")
        let policyVersion = try string(root, "policy_version", maximumLength: 64)
        let abiVersion = try integer(root, "abi_version")
        guard format == expectedFormat,
              version == expectedVersion,
              policyVersion == expectedPolicyVersion,
              abiVersion == expectedABIVersion else {
            throw invalid("format/version/policy/ABI identity mismatch")
        }
        let path = try string(root, "path", maximumLength: 64)
        guard path == "fast" || path == "full_graph_optimization" else {
            throw invalid("path is not a production optimizer path")
        }
        let disposition = try string(root, "disposition", maximumLength: 32)
        guard ["PASS", "RECOVERABLE_FAIL", "NON_RECOVERABLE_FAIL",
               "RESOURCE_REQUIRED", "LOCAL_FRAME_ONLY"].contains(disposition) else {
            throw invalid("disposition is unknown")
        }

        let residuals = try residualsByKind(
            try object(root, "residual_by_kind"), "residual_by_kind")
        let yawResiduals = try residualsByKind(
            try object(root, "yaw_residual_by_kind"), "yaw_residual_by_kind")

        let info = try object(root, "info_policy")
        try requireExactKeys(info, ["regularized", "rejected"], "info_policy")
        let informationPolicy = InformationPolicy(
            regularized: try integer(info, "regularized"),
            rejected: try integer(info, "rejected"))

        let correctionObject = try object(root, "correction")
        try requireExactKeys(correctionObject, [
            "median", "p95", "max", "max_jump", "yaw_median", "yaw_p95",
            "yaw_max", "yaw_max_jump",
        ], "correction")
        let correction = Correction(
            median: try number(correctionObject, "median"),
            p95: try number(correctionObject, "p95"),
            maximum: try number(correctionObject, "max"),
            maximumJump: try number(correctionObject, "max_jump"),
            yawMedian: try number(correctionObject, "yaw_median"),
            yawP95: try number(correctionObject, "yaw_p95"),
            yawMaximum: try number(correctionObject, "yaw_max"),
            yawMaximumJump: try number(correctionObject, "yaw_max_jump"))
        guard correction.median <= correction.p95,
              correction.p95 <= correction.maximum,
              correction.yawMedian <= correction.yawP95,
              correction.yawP95 <= correction.yawMaximum else {
            throw invalid("correction percentiles are not ordered")
        }

        let solverObject = try object(root, "solver")
        try requireExactKeys(solverObject, [
            "strategy", "iterations", "final_error", "converged",
            "stopped_reason", "initial_error", "relative_improvement",
            "wall_seconds", "chunks", "skeleton_nodes", "factor_count",
            "available",
        ], "solver")
        let solver = Solver(
            strategy: try string(solverObject, "strategy", maximumLength: 32),
            iterations: try integer(solverObject, "iterations"),
            finalError: try number(solverObject, "final_error"),
            converged: try boolean(solverObject, "converged"),
            stoppedReason: try string(solverObject, "stopped_reason", maximumLength: 64),
            initialError: try nullableNumber(solverObject, "initial_error"),
            relativeImprovement: try nullableNumber(solverObject, "relative_improvement"),
            wallSeconds: try number(solverObject, "wall_seconds"),
            chunks: try integer(solverObject, "chunks"),
            skeletonNodes: try integer(
                solverObject, "skeleton_nodes",
                maximum: MobileNativeOutcomeContract.maximumSkeletonNodes),
            factorCount: try integer(
                solverObject, "factor_count",
                maximum: MobileNativeOutcomeContract.maximumFactors),
            available: try boolean(solverObject, "available"))
        guard solver.strategy == "g2o_robust" else {
            throw invalid("solver.strategy mismatch")
        }

        guard let gaugeValues = root["gauge_by_component"] as? [Any] else {
            throw invalid("gauge_by_component is not an array")
        }
        var gauges: [GaugeComponent] = []
        gauges.reserveCapacity(gaugeValues.count)
        var gaugeIDs = Set<Int64>()
        let gaugeKeys: Set<String> = [
            "component_id", "gauge_candidate_count", "gauge_inlier_count",
            "gauge_outlier_count", "gauge_consensus_ratio",
            "gauge_second_cluster_ratio", "gauge_translation_spread_m",
            "gauge_yaw_spread_rad", "gauge_authority",
            "initial_authority_candidate_count", "long_range_loop_factor_count",
            "gauge_anchored", "gauge_reject_reason",
        ]
        for value in gaugeValues {
            guard let gaugeObject = value as? [String: Any] else {
                throw invalid("gauge_by_component contains a non-object")
            }
            try requireExactKeys(gaugeObject, gaugeKeys, "gauge_by_component entry")
            let gauge = GaugeComponent(
                componentID: try integer(gaugeObject, "component_id"),
                candidateCount: try integer(gaugeObject, "gauge_candidate_count"),
                inlierCount: try integer(gaugeObject, "gauge_inlier_count"),
                outlierCount: try integer(gaugeObject, "gauge_outlier_count"),
                consensusRatio: try number(
                    gaugeObject, "gauge_consensus_ratio", maximum: 1.0),
                secondClusterRatio: try number(
                    gaugeObject, "gauge_second_cluster_ratio", maximum: 1.0),
                translationSpreadM: try number(
                    gaugeObject, "gauge_translation_spread_m"),
                yawSpreadRad: try number(gaugeObject, "gauge_yaw_spread_rad"),
                authority: try string(
                    gaugeObject, "gauge_authority", maximumLength: 64),
                initialAuthorityCandidateCount: try integer(
                    gaugeObject, "initial_authority_candidate_count"),
                longRangeLoopFactorCount: try integer(
                    gaugeObject, "long_range_loop_factor_count"),
                anchored: try boolean(gaugeObject, "gauge_anchored"),
                rejectReason: try string(
                    gaugeObject, "gauge_reject_reason",
                    maximumLength: 128, allowEmpty: true))
            guard gaugeIDs.insert(gauge.componentID).inserted,
                  gauge.inlierCount <= gauge.candidateCount,
                  gauge.outlierCount <= gauge.candidateCount,
                  gauge.inlierCount + gauge.outlierCount <= gauge.candidateCount,
                  ["none", "robust_prior_consensus", "initial_map_pose"]
                    .contains(gauge.authority),
                  gauge.anchored == gauge.rejectReason.isEmpty,
                  gauge.anchored == (gauge.authority != "none"),
                  gauge.authority != "initial_map_pose"
                    || (gauge.initialAuthorityCandidateCount == 1
                        && gauge.longRangeLoopFactorCount > 0) else {
                throw invalid("gauge_by_component entry is inconsistent")
            }
            gauges.append(gauge)
        }

        let healthObject = try object(root, "health")
        try requireExactKeys(healthObject, [
            "node_count", "link_count", "malformed_links", "void_links",
            "ignored_optional_links", "loop_links", "prior_links",
            "recovery_links",
        ], "health")
        let health = Health(
            nodeCount: try integer(
                healthObject, "node_count",
                maximum: MobileNativeOutcomeContract.maximumTrajectoryRows),
            linkCount: try integer(healthObject, "link_count"),
            malformedLinks: try integer(healthObject, "malformed_links"),
            voidLinks: try integer(healthObject, "void_links"),
            ignoredOptionalLinks: try integer(healthObject, "ignored_optional_links"),
            loopLinks: try integer(healthObject, "loop_links"),
            priorLinks: try integer(healthObject, "prior_links"),
            recoveryLinks: try integer(healthObject, "recovery_links"))

        let report = MobileNativeQualityReport(
            format: format,
            version: version,
            policyVersion: policyVersion,
            abiVersion: abiVersion,
            path: path,
            disposition: disposition,
            graphInputSHA256: try sha256(root, "graph_input_sha256"),
            factorSetSHA256: try sha256(root, "factor_set_sha256"),
            projectionPolicyVersion: try integer(root, "projection_policy_version"),
            priorMapID: try string(root, "prior_map_id", maximumLength: 256),
            priorMapSHA256: try sha256(root, "prior_map_sha256"),
            trackingSessionID: try string(root, "tracking_session_id", maximumLength: 256),
            absolutePriorCount: try integer(
                root, "absolute_prior_count",
                maximum: MobileNativeOutcomeContract.maximumPriors),
            parsedValidPriorCount: try integer(
                root, "parsed_valid_prior_count",
                maximum: MobileNativeOutcomeContract.maximumPriors),
            appliedPriorFactorCount: try integer(
                root, "applied_prior_factor_count",
                maximum: MobileNativeOutcomeContract.maximumFactors),
            uniquePriorNodeCount: try integer(
                root, "unique_prior_node_count",
                maximum: MobileNativeOutcomeContract.maximumPriors),
            appliedPriorCount: try integer(
                root, "applied_prior_count",
                maximum: MobileNativeOutcomeContract.maximumFactors),
            initialMapPosePriorCount: try integer(
                root, "initial_map_pose_prior_count",
                maximum: MobileNativeOutcomeContract.maximumPriors),
            robustConsensusPriorCount: try integer(
                root, "robust_consensus_prior_count",
                maximum: MobileNativeOutcomeContract.maximumPriors),
            robustConsensusUniquePriorNodeCount: try integer(
                root, "robust_consensus_unique_prior_node_count",
                maximum: MobileNativeOutcomeContract.maximumPriors),
            longRangeLoopFactorCount: try integer(
                root, "long_range_loop_factor_count",
                maximum: MobileNativeOutcomeContract.maximumFactors),
            rejectedPriors: try integer(
                root, "rejected_priors",
                maximum: MobileNativeOutcomeContract.maximumPriors),
            fusedPriorDuplicates: try integer(
                root, "fused_prior_duplicates",
                maximum: MobileNativeOutcomeContract.maximumPriors),
            priorConflicts: try integer(
                root, "prior_conflicts",
                maximum: MobileNativeOutcomeContract.maximumPriors),
            componentCount: try integer(root, "component_count"),
            totalComponents: try integer(root, "total_components"),
            anchoredComponents: try integer(root, "anchored_components"),
            publishNodes: try integer(
                root, "publish_nodes",
                maximum: MobileNativeOutcomeContract.maximumTrajectoryRows),
            publishRatio: try number(root, "publish_ratio", maximum: 1.0),
            anchoredRatio: try number(root, "anchored_ratio", maximum: 1.0),
            isolatedCount: try integer(root, "isolated_count"),
            crossFloorLinkCount: try integer(root, "cross_floor_link_count"),
            gapSegments: try integer(root, "gap_segments"),
            aggregatedChains: try integer(root, "aggregated_chains"),
            reciprocalInconsistent: try integer(root, "reciprocal_inconsistent"),
            weightedChi2: try number(root, "weighted_chi2"),
            degreesOfFreedom: try integer(root, "dof"),
            chi2PerDegreeOfFreedom: try number(root, "chi2_per_dof"),
            residualsByKind: residuals,
            yawResidualsByKind: yawResiduals,
            residualThresholdRatio: try number(
                root, "residual_threshold_ratio", maximum: 1.0),
            yawThresholdRatio: try number(
                root, "yaw_threshold_ratio", maximum: 1.0),
            informationPolicy: informationPolicy,
            correction: correction,
            coverage: try number(root, "coverage", maximum: 1.0),
            optimizerError: try string(
                root, "optimizer_error", maximumLength: 4096, allowEmpty: true),
            solver: solver,
            gaugesByComponent: gauges,
            health: health)

        guard report.parsedValidPriorCount == report.absolutePriorCount,
              report.appliedPriorFactorCount == report.appliedPriorCount,
              report.uniquePriorNodeCount <= report.appliedPriorCount,
              report.initialMapPosePriorCount
                + report.robustConsensusPriorCount == report.appliedPriorCount,
              report.robustConsensusUniquePriorNodeCount
                <= report.robustConsensusPriorCount,
              report.anchoredComponents <= report.totalComponents,
              report.publishNodes <= report.health.nodeCount else {
            throw invalid("cross-field counts are inconsistent")
        }
        return report
    }

    /// Exact request/outcome binding. C-backed callers also pass the runtime
    /// duplicate fields, so a stale or forged JSON payload cannot override C
    /// disposition/count/SHA truth. Host implementations use the same method
    /// without the C-only values and therefore cannot bypass schema/identity
    /// or trajectory/skeleton/publish count checks.
    func validate(
        request: MobileNativeGraphRequest,
        expectedPath: String,
        disposition expectedDisposition: MobileGraphDisposition,
        trajectoryCount: Int,
        skeletonCount: Int,
        publishCount: Int,
        cABIVersion: Int64? = nil,
        cFactorCount: Int64? = nil,
        cGraphInputSHA256: String? = nil,
        cFactorSetSHA256: String? = nil
    ) throws {
        guard path == expectedPath,
              disposition == expectedDisposition.reportValue,
              projectionPolicyVersion == Int64(request.projectionPolicyVersion),
              priorMapID == request.priorMapID,
              priorMapSHA256 == request.priorMapSHA256,
              trackingSessionID == request.trackingSessionID,
              absolutePriorCount == Int64(request.absolutePriors.count),
              health.nodeCount == Int64(trajectoryCount),
              solver.skeletonNodes == Int64(skeletonCount),
              publishNodes == Int64(publishCount) else {
            throw Self.invalid("request/path/disposition/count binding mismatch")
        }
        if let cABIVersion, abiVersion != cABIVersion {
            throw Self.invalid("runtime ABI binding mismatch")
        }
        if let cFactorCount, solver.factorCount != cFactorCount {
            throw Self.invalid("C factor_count binding mismatch")
        }
        if let cGraphInputSHA256, graphInputSHA256 != cGraphInputSHA256 {
            throw Self.invalid("C graph_input_sha256 binding mismatch")
        }
        if let cFactorSetSHA256, factorSetSHA256 != cFactorSetSHA256 {
            throw Self.invalid("C factor_set_sha256 binding mismatch")
        }
    }
}

/// Frozen Swift-side validation contract for the native C outcome.
///
/// Kept in the Foundation-only graph-types file so the executable host suite
/// validates the exact same disposition/error ordering and generated bounds
/// used by `MobileNativeFactorGraph` without substituting a mock C ABI.
enum MobileNativeOutcomeContract {
    static let maximumTrajectoryRows = Int64(
        GeneratedMobileEvidenceContracts.File_native_graph.max_trajectory_rows)
    static let maximumSkeletonNodes = Int64(
        GeneratedMobileEvidenceContracts.File_native_graph.max_skeleton_nodes)
    static let maximumRawNodes = Int64(
        GeneratedMobileEvidenceContracts.File_native_graph.max_raw_nodes)
    static let maximumFactors = Int64(
        GeneratedMobileEvidenceContracts.File_native_graph.max_factors)
    static let maximumPriors = Int64(
        GeneratedMobileEvidenceContracts.File_native_graph.max_priors)
    static let maximumQualityJSONBytes = 1024 * 1024

    /// Native topology order may move between disconnected components whose
    /// timestamp ranges overlap or run backwards globally. Only ordering
    /// inside one component is authoritative. This Foundation-only contract
    /// is shared by the C bridge and the host suite.
    static func validateComponentTimestampOrder(
        _ rows: [MobileNativeTrajectoryRow]
    ) throws {
        var lastStampByComponent: [Int64: Double] = [:]
        for row in rows {
            if let previous = lastStampByComponent[row.componentID],
               row.stamp < previous {
                throw MobileNativeFactorGraphError.invalidOutcome(
                    "non-monotonic stamp at id \(row.id) in component \(row.componentID)")
            }
            lastStampByComponent[row.componentID] = row.stamp
        }
    }

    /// Disposition is the authoritative branch signal and must be decoded
    /// before interpreting the optional native error string. In particular,
    /// native resource failures commonly carry both RESOURCE_REQUIRED and an
    /// explanatory error; they remain resumable resource pauses rather than
    /// being collapsed into a generic solver failure.
    static func disposition(
        rawValue: Int32,
        errorMessage: String?
    ) throws -> MobileGraphDisposition {
        guard let disposition = MobileGraphDisposition(rawValue: rawValue) else {
            throw MobileNativeFactorGraphError.invalidOutcome(
                "unknown ABI disposition \(rawValue)")
        }
        if disposition == .resourceRequired {
            let detail = errorMessage.flatMap { $0.isEmpty ? nil : $0 }
                ?? "native factor graph requested additional resources"
            throw MobileOnlyWorkflowError.resourceRequired(
                detail)
        }
        if let errorMessage, !errorMessage.isEmpty {
            throw MobileNativeFactorGraphError.nativeFailed(errorMessage)
        }
        return disposition
    }

    static func validateInputCounts(
        priorCount: Int,
        tagNodeCount: Int
    ) throws {
        guard priorCount >= 0,
              Int64(priorCount) <= maximumPriors,
              tagNodeCount >= 0,
              Int64(tagNodeCount) <= maximumRawNodes else {
            throw MobileNativeFactorGraphError.invalidOutcome(
                "input limits exceeded: priors=\(priorCount) "
                    + "tagNodes=\(tagNodeCount)")
        }
    }

    static func qualityReport(
        in outcome: MobileNativeGraphOutcome,
        request: MobileNativeGraphRequest,
        expectedPath: String
    ) throws -> MobileNativeQualityReport {
        let report = try MobileNativeQualityReport.parse(
            qualityJSON: outcome.qualityJSON)
        try report.validate(
            request: request,
            expectedPath: expectedPath,
            disposition: outcome.disposition,
            trajectoryCount: outcome.trajectory.count,
            skeletonCount: outcome.skeletonIDs.count,
            publishCount: outcome.trajectory.filter(\.publishEligible).count)
        return report
    }
}

/// Run request for the gateway (§6.1): identity bindings and accepted
/// absolute priors are mandatory inputs, never just DB + tag IDs.
struct MobileNativeGraphRequest {
    var databaseURL: URL
    var tagNodeIDs: [Int64]
    var absolutePriors: [MobileAbsolutePrior]
    var priorMapID: String
    var priorMapSHA256: String
    var trackingSessionID: String
    var projectionPolicyVersion: Int32
    var maxWallSeconds: Double
}

enum MobileNativeFactorGraphGateway {

    /// Signature shared by Fast/full-graph implementations.
    typealias RunImplementation = (
        _ request: MobileNativeGraphRequest,
        _ isCancelled: @escaping () -> Bool
    ) throws -> MobileNativeGraphOutcome

    /// Wired implementations. The app assigns the native-core closures
    /// at startup (`MobileNativeFactorGraph.wireIntoGateway()`); host
    /// tests assign a reference implementation before running.
    static var runFastImplementation: RunImplementation?
    /// Full-graph optimization (§13.1) — NOT a sensor reprocess.
    static var runFullGraphImplementation: RunImplementation?

    /// Fast Path (§2).
    static func runFast(
        request: MobileNativeGraphRequest,
        isCancelled: @escaping () -> Bool
    ) throws -> MobileNativeGraphOutcome {
        guard let implementation = runFastImplementation else {
            throw MobileNativeFactorGraphError.notWired
        }
        return try implementation(request, isCancelled)
    }

    /// Full-graph optimization. The pipeline calls this AT MOST once and
    /// only after a Fast RECOVERABLE_FAIL whose recovery policy allows
    /// it (§13.3).
    static func runFullGraph(
        request: MobileNativeGraphRequest,
        isCancelled: @escaping () -> Bool
    ) throws -> MobileNativeGraphOutcome {
        guard let implementation = runFullGraphImplementation else {
            throw MobileNativeFactorGraphError.notWired
        }
        return try implementation(request, isCancelled)
    }
}
