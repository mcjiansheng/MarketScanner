import Foundation

// MARK: - Limits (aligned with the PC reader and
// RecoveryLifecycleEvidenceLimits; §6.3 sigma policy)

enum AbsolutePriorEvidenceLimits {
    /// Constraint sidecar file size / record size / record-count gates. A formal
    /// constraint is written at up to 2 Hz for the full qualified 48-hour
    /// session (345,600 records). The generated contract retains a 400,000
    /// hard parser cap, a 64 KiB hostile-row cap and a 768 MiB file cap; the
    /// shared strict JSONL reader streams the file without materializing it.
    static let maximumFileBytes =
        GeneratedMobileEvidenceContracts.File_localization_constraints_jsonl
            .max_file_bytes
    static let maximumRecordBytes =
        GeneratedMobileEvidenceContracts.File_localization_constraints_jsonl
            .max_record_bytes
    static let maximumRecords =
        GeneratedMobileEvidenceContracts.File_localization_constraints_jsonl
            .max_records
    static let qualificationMaximumConstraintRecords =
        GeneratedMobileEvidenceContracts.File_localization_constraints_jsonl
            .qualification_max_records
    /// Manual evidence has a different generated input contract from the
    /// high-rate constraint stream. Keep these limits separate so a manual
    /// file can never inherit the 768 MiB / 400,000-row constraint budget.
    static let manualMaximumFileBytes =
        GeneratedMobileEvidenceContracts.File_manual_localization_events_jsonl
            .max_file_bytes
    static let manualMaximumRecordBytes =
        GeneratedMobileEvidenceContracts.File_manual_localization_events_jsonl
            .max_record_bytes
    static let manualMaximumRecords =
        GeneratedMobileEvidenceContracts.File_manual_localization_events_jsonl
            .max_records
    /// Recovery evidence is owned by the shared lifecycle parser contract.
    /// This audit-only reader must enforce the exact same frozen limits.
    static let recoveryMaximumFileBytes =
        RecoveryLifecycleEvidenceLimits.maximumFileBytes
    static let recoveryMaximumRecordBytes =
        RecoveryLifecycleEvidenceLimits.maximumRecordBytes
    static let recoveryMaximumRecords =
        RecoveryLifecycleEvidenceLimits.maximumRecords
    /// Manual v3 node-binding gate (identical to the PC reader
    /// `maximum_time_delta_seconds=1.0`).
    static let maximumNodeTimeDeltaSeconds = 1.0
    /// Stamp / delta re-check tolerance (identical to the PC reader).
    static let stampEpsilon = 1.0e-6
    /// The ISO-8601 wall-clock string and its Unix scalar describe the same
    /// instant. A one-millisecond tolerance covers encoder rounding without
    /// permitting two independent clocks to be substituted.
    static let wallClockEpsilonSeconds = 0.001
    /// V1R5 §8.2: stamp-fallback binding must be unambiguous — the
    /// second-best candidate must be farther than this margin.
    static let minimumNodeMarginSeconds = 0.01
    // Localization-sigma policy (§6.3): information must derive from
    // recorded uncertainty, never an undocumented constant.
    static let minimumSigmaM = 0.02
    static let maximumSigmaM = 5.0
    static let minimumSigmaYawRad = 0.005
    static let maximumSigmaYawRad = 1.0
    static let manualSigmaM = 0.10
    static let manualSigmaYawRad = 0.05
    static let uniquenessLowerBound = 0.0
    static let uniquenessUpperBound = 1.0
    /// Weight derivation for online-structure constraints (identical to
    /// the PC reader `max(1.0, 6.0 * uniqueness)`).
    static func weightForUniqueness(_ uniqueness: Double) -> Double {
        return max(1.0, 6.0 * uniqueness)
    }
}

/// One immutable RTAB-Map graph node (id + UTC stamp on the node
/// timebase axis) used to bind absolute-prior evidence.
struct AbsolutePriorEvidenceNode: Equatable {
    let nodeID: Int64
    let stamp: Double
}

/// One immutable index shared by every absolute-prior record in a run.
/// Building this once avoids the old per-record sort/map/linear-ID scan and
/// gives every constraint/manual event identical nearest/second-nearest
/// semantics.
private struct NodeIndex {
    let sortedByStamp: [AbsolutePriorEvidenceNode]
    let stamps: [Double]
    let byID: [Int64: AbsolutePriorEvidenceNode]
    let duplicateIDs: Set<Int64>

    init(nodes: [AbsolutePriorEvidenceNode]) throws {
        guard nodes.allSatisfy({ $0.nodeID > 0 && $0.stamp.isFinite }) else {
            throw AbsolutePriorEvidenceParseError.invalidNodeInventory(
                "node ids must be positive and stamps finite")
        }
        var unique: [Int64: AbsolutePriorEvidenceNode] = [:]
        var duplicates = Set<Int64>()
        for node in nodes {
            if unique.updateValue(node, forKey: node.nodeID) != nil {
                duplicates.insert(node.nodeID)
            }
        }
        for duplicate in duplicates {
            unique.removeValue(forKey: duplicate)
        }
        sortedByStamp = nodes.sorted {
            if $0.stamp == $1.stamp { return $0.nodeID < $1.nodeID }
            return $0.stamp < $1.stamp
        }
        stamps = sortedByStamp.map(\.stamp)
        byID = unique
        duplicateIDs = duplicates
    }

    func uniqueNode(nodeID: Int64) -> AbsolutePriorEvidenceNode? {
        return byID[nodeID]
    }

    func nodeNotFoundReason(nodeID: Int64) -> String {
        return duplicateIDs.contains(nodeID)
            ? "manual_event_node_id_ambiguous"
            : "manual_event_node_id_not_found"
    }

    func nearest(
        stamp: Double
    ) -> (node: AbsolutePriorEvidenceNode, delta: Double, secondDelta: Double)? {
        guard stamp.isFinite, !stamps.isEmpty else { return nil }
        var lower = 0
        var upper = stamps.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if stamps[middle] < stamp {
                lower = middle + 1
            } else {
                upper = middle
            }
        }

        var candidates: [Int] = []
        if lower < stamps.count { candidates.append(lower) }
        if lower > 0 { candidates.append(lower - 1) }
        // Equal-stamp runs may extend beyond the two insertion neighbors.
        // Include their immediate outer neighbors so the second-best margin
        // is exact even when duplicate timestamps are present.
        if lower + 1 < stamps.count { candidates.append(lower + 1) }
        if lower > 1 { candidates.append(lower - 2) }
        let ranked = Set(candidates).map { index in
            (index: index, delta: abs(stamps[index] - stamp))
        }.sorted {
            if $0.delta == $1.delta {
                return sortedByStamp[$0.index].nodeID
                    < sortedByStamp[$1.index].nodeID
            }
            return $0.delta < $1.delta
        }
        guard let best = ranked.first else { return nil }
        let bestNode = sortedByStamp[best.index]
        guard !duplicateIDs.contains(bestNode.nodeID) else { return nil }
        let secondDelta = ranked.dropFirst().first?.delta ?? .infinity
        return (bestNode, best.delta, secondDelta)
    }
}

/// Stable failure code + per-record context for one rejected record.
struct AbsolutePriorRejectedDetail: Equatable {
    let source: String
    let recordIndex: Int
    let reason: String
}

/// Strict-parse audit counts; every rejected record has a stable code
/// so the device parser and the PC reader classify identically.
struct AbsolutePriorEvidenceAudit: Equatable {
    var constraintTotal = 0
    var constraintAccepted = 0
    var constraintInvalidRecordRejected = 0
    var constraintFormatRejected = 0
    var constraintNotAcceptedRejected = 0
    var constraintDispositionRejected = 0
    var constraintIdentityRejected = 0
    var constraintPoseRejected = 0
    var constraintUniquenessRejected = 0
    var constraintTimestampRejected = 0
    var constraintNodeBindingRejected = 0

    var manualTotal = 0
    var manualAccepted = 0
    var manualInvalidRecordRejected = 0
    var manualFormatRejected = 0
    var manualVersionRejected = 0
    var manualIdentityRejected = 0
    var manualWallClockRejected = 0
    var manualNodeTimebaseRejected = 0
    var manualAlignmentRejected = 0
    var manualPoseRejected = 0
    var manualBindingRejected = 0

    /// Recovery episodes are audited only: they carry no node binding /
    /// map pose and must never produce an absolute prior (the PC reader
    /// behaves identically). Full recovery evidence validation lives in
    /// RecoveryLifecycleEvidenceParser.
    var recoveryRecordCount = 0

    /// Parser/schema/identity/accepted-record validation failures. These are
    /// authoritative bad evidence and block the processing pipeline.
    var rejectedDetails: [AbsolutePriorRejectedDetail] = []
    /// Well-formed, identity-bound constraints whose formal decision is
    /// `accepted=false`. They are normal negative measurements: audited and
    /// excluded from priors, but never treated as corrupt evidence.
    var nonAcceptedDetails: [AbsolutePriorRejectedDetail] = []

    var acceptedPriorCount: Int { constraintAccepted + manualAccepted }
    var clean: Bool { rejectedDetails.isEmpty }

    func reportPayload(priors: [MobileAbsolutePrior]) -> [String: Any] {
        var kindCounts: [Int32: Int] = [:]
        for prior in priors {
            kindCounts[prior.kind, default: 0] += 1
        }
        return [
            "constraints": [
                "total": constraintTotal,
                "accepted": constraintAccepted,
                "rejected": constraintTotal - constraintAccepted,
                "invalid_record": constraintInvalidRecordRejected,
                "format_invalid": constraintFormatRejected,
                "not_accepted": constraintNotAcceptedRejected,
                "disposition_invalid": constraintDispositionRejected,
                "identity_missing_or_mismatch": constraintIdentityRejected,
                "pose_invalid": constraintPoseRejected,
                "uniqueness_invalid": constraintUniquenessRejected,
                "timestamp_invalid": constraintTimestampRejected,
                "node_binding_failed": constraintNodeBindingRejected,
            ],
            "manual": [
                "total": manualTotal,
                "accepted": manualAccepted,
                "rejected": manualTotal - manualAccepted,
                "invalid_record": manualInvalidRecordRejected,
                "format_invalid": manualFormatRejected,
                "version_unsupported": manualVersionRejected,
                "identity_missing_or_mismatch": manualIdentityRejected,
                "wall_clock_invalid": manualWallClockRejected,
                "node_timebase_invalid": manualNodeTimebaseRejected,
                "alignment_stale_or_invalid": manualAlignmentRejected,
                "pose_invalid": manualPoseRejected,
                "node_binding_failed": manualBindingRejected,
            ],
            "recovery_record_count": recoveryRecordCount,
            "accepted_priors": [
                "count": priors.count,
                "kinds": [
                    "localization": kindCounts[0] ?? 0,
                    "recovery": kindCounts[1] ?? 0,
                    "manual": kindCounts[2] ?? 0,
                ],
                "details": priors.map {
                    [
                        "node_id": $0.nodeID,
                        "kind": Int($0.kind),
                        "episode_id": $0.episodeID,
                        "map_x_m": $0.mapXM,
                        "map_y_m": $0.mapYM,
                        "map_yaw_rad": $0.mapYawRad,
                    ]
                },
            ],
            "rejected_details": rejectedDetails.map {
                ["source": $0.source, "record_index": $0.recordIndex, "reason": $0.reason]
            },
            "non_accepted_details": nonAcceptedDetails.map {
                ["source": $0.source, "record_index": $0.recordIndex, "reason": $0.reason]
            },
        ]
    }
}

/// File-level failures (write anomaly) fail the parse closed; record
/// level rejections are audited per record and never throw.
enum AbsolutePriorEvidenceParseError: Error, LocalizedError {
    case fileTooLarge(String, Int)
    case recordTooLarge(String, Int)
    case tooManyRecords(String, Int)
    case fileUnreadable(String)
    case constraintCountMismatch(Int, Int)
    case manualCountMismatch(Int, Int)
    case recoveryCountMismatch(Int, Int)
    case qualificationLimitExceeded(Int, Int)
    case invalidNodeInventory(String)

    var errorDescription: String? {
        switch self {
        case .fileTooLarge(let file, let bytes):
            return "绝对先验证据文件超限：\(file) \(bytes) bytes"
        case .recordTooLarge(let file, let bytes):
            return "绝对先验证据单条记录超限：\(file) \(bytes) bytes"
        case .tooManyRecords(let file, let count):
            return "绝对先验证据记录数超限：\(file) \(count)"
        case .fileUnreadable(let file):
            return "绝对先验证据文件不可读：\(file)"
        case .constraintCountMismatch(let actual, let expected):
            return "定位约束计数不匹配：\(actual) != metadata \(expected)"
        case .manualCountMismatch(let actual, let expected):
            return "人工定位事件计数不匹配：\(actual) != metadata \(expected)"
        case .recoveryCountMismatch(let actual, let expected):
            return "恢复事件计数不匹配：\(actual) != metadata \(expected)"
        case .qualificationLimitExceeded(let actual, let maximum):
            return "定位约束超过产品资格上限：\(actual) > \(maximum)"
        case .invalidNodeInventory(let detail):
            return "RTAB-Map 节点索引无效：\(detail)"
        }
    }
}

struct AbsolutePriorEvidenceParseResult {
    let priors: [MobileAbsolutePrior]
    let audit: AbsolutePriorEvidenceAudit
}

/// Strict parser for the absolute prior-map evidence sidecars (§6.1).
///
/// Real write-side schemas (SupermarketScanSession):
/// - `localization_constraints.jsonl`: `PriorMapConstraintRecord`
///   (JSONEncoder default camelCase keys; NO nodeId/mapPose/sigma).
///   Accepted records bind by `nodeTimebaseTimestamp` to the nearest
///   DB node stamp and derive sigma from `uniqueness`
///   (weight = max(1.0, 6.0*uniqueness)) exactly like the PC reader.
/// - `manual_localization_events.jsonl`: `ManualLocalizationEvent` v3
///   (snake_case keys); binding by `nearest_node_id` with the same
///   stamp/delta re-checks and 1.0 s gate as the PC reader.
/// - `localization_recovery_events.jsonl`: audited only; recovery
///   episodes never produce an absolute prior.
///
/// Fail-closed rules: a record missing/ mismatching identity
/// (prior_map_id, prior_map_sha256, tracking_session_id), missing
/// accepted, invalid pose, invalid uniqueness, or unbindable node is
/// REJECTED with a stable code — never applied with a default.
enum AbsolutePriorEvidenceParser {

    static func parse(
        snapshotDirectory: URL,
        nodes: [AbsolutePriorEvidenceNode],
        priorMapID: String,
        priorMapSHA256: String,
        trackingSessionID: String,
        floorID: String,
        expectedConstraintCount: Int? = nil,
        expectedManualCount: Int? = nil,
        expectedRecoveryCount: Int? = nil
    ) throws -> AbsolutePriorEvidenceParseResult {
        guard expectedConstraintCount.map({ $0 >= 0 }) ?? true,
              expectedManualCount.map({ $0 >= 0 }) ?? true,
              expectedRecoveryCount.map({ $0 >= 0 }) ?? true else {
            throw AbsolutePriorEvidenceParseError.fileUnreadable(
                "negative absolute-prior metadata watermark")
        }
        if let expectedConstraintCount,
           expectedConstraintCount > AbsolutePriorEvidenceLimits
            .qualificationMaximumConstraintRecords {
            throw AbsolutePriorEvidenceParseError.qualificationLimitExceeded(
                expectedConstraintCount,
                AbsolutePriorEvidenceLimits.qualificationMaximumConstraintRecords)
        }
        if let expectedManualCount,
           expectedManualCount > AbsolutePriorEvidenceLimits.manualMaximumRecords {
            throw AbsolutePriorEvidenceParseError.tooManyRecords(
                "manual metadata watermark", expectedManualCount)
        }
        if let expectedRecoveryCount,
           expectedRecoveryCount > AbsolutePriorEvidenceLimits.recoveryMaximumRecords {
            throw AbsolutePriorEvidenceParseError.tooManyRecords(
                "recovery metadata watermark", expectedRecoveryCount)
        }
        var audit = AbsolutePriorEvidenceAudit()
        var priors: [MobileAbsolutePrior] = []
        let nodeIndex = try NodeIndex(nodes: nodes)

        // 1) Localization constraints.
        let constraintsURL = snapshotDirectory
            .appendingPathComponent("localization_constraints.jsonl")
        let constraintLineCount = try readSidecar(
            url: constraintsURL,
            source: "constraints",
            maximumFileBytes: AbsolutePriorEvidenceLimits.maximumFileBytes,
            maximumRecordBytes: AbsolutePriorEvidenceLimits.maximumRecordBytes,
            maximumRecords: AbsolutePriorEvidenceLimits.maximumRecords,
            invalidRecord: { recordIndex in
                audit.constraintInvalidRecordRejected += 1
                audit.rejectedDetails.append(AbsolutePriorRejectedDetail(
                    source: "constraints", recordIndex: recordIndex,
                    reason: "invalid_record"))
            }
        ) { recordIndex, object in
          repeat {
            audit.constraintTotal += 1
            guard (object["format"] as? String) == "MarketScannerLocalizationConstraint" else {
                audit.constraintFormatRejected += 1
                audit.rejectedDetails.append(AbsolutePriorRejectedDetail(
                    source: "constraints", recordIndex: recordIndex,
                    reason: "constraint_format_invalid"))
                continue
            }
            guard StrictJSONScalar.integer(object["version"]) == 1 else {
                audit.constraintFormatRejected += 1
                audit.rejectedDetails.append(AbsolutePriorRejectedDetail(
                    source: "constraints", recordIndex: recordIndex,
                    reason: "constraint_version_unsupported"))
                continue
            }
            guard Set(object.keys).isSubset(of: constraintKnownFields) else {
                audit.constraintInvalidRecordRejected += 1
                audit.rejectedDetails.append(AbsolutePriorRejectedDetail(
                    source: "constraints", recordIndex: recordIndex,
                    reason: "constraint_unknown_field"))
                continue
            }
            guard let accepted = StrictJSONScalar.boolean(object["accepted"]) else {
                audit.constraintInvalidRecordRejected += 1
                audit.rejectedDetails.append(AbsolutePriorRejectedDetail(
                    source: "constraints", recordIndex: recordIndex,
                    reason: "constraint_accepted_invalid"))
                continue
            }
            guard let measurementAccepted = StrictJSONScalar.boolean(
                    object["measurementAccepted"]),
                  let correctionStepApplied = StrictJSONScalar.boolean(
                    object["correctionStepApplied"]),
                  let confidenceAccepted = StrictJSONScalar.boolean(
                    object["confidenceAccepted"]) else {
                audit.constraintInvalidRecordRejected += 1
                audit.rejectedDetails.append(AbsolutePriorRejectedDetail(
                    source: "constraints", recordIndex: recordIndex,
                    reason: "constraint_decision_flags_invalid"))
                continue
            }
            guard let disposition = object["disposition"] as? String,
                  accepted
                    ? (disposition == "accepted_local"
                        || disposition == "accepted_recovery_convergence")
                    : (disposition == "rejected"
                        || disposition == "provisional_recovery_step") else {
                audit.constraintDispositionRejected += 1
                audit.rejectedDetails.append(AbsolutePriorRejectedDetail(
                    source: "constraints", recordIndex: recordIndex,
                    reason: "constraint_disposition_invalid"))
                continue
            }
            let measurementDisposition = accepted
                || disposition == "provisional_recovery_step"
            guard measurementAccepted == measurementDisposition,
                  correctionStepApplied == measurementDisposition,
                  confidenceAccepted == accepted else {
                audit.constraintDispositionRejected += 1
                audit.rejectedDetails.append(AbsolutePriorRejectedDetail(
                    source: "constraints", recordIndex: recordIndex,
                    reason: "constraint_disposition_inconsistent"))
                continue
            }
            guard identityMatches(
                object, priorMapID: priorMapID,
                priorMapSHA256: priorMapSHA256,
                trackingSessionID: trackingSessionID,
                floorID: floorID) else {
                audit.constraintIdentityRejected += 1
                audit.rejectedDetails.append(AbsolutePriorRejectedDetail(
                    source: "constraints", recordIndex: recordIndex,
                    reason: "constraint_identity_missing_or_mismatch"))
                continue
            }
            guard let timestamp = finiteDouble(object["timestamp"]),
                  let nodeTimestamp = finiteDouble(
                    object["nodeTimebaseTimestamp"]),
                  let nodeOffset = finiteDouble(
                    object["nodeTimebaseOffsetSeconds"]),
                  abs(nodeTimestamp - (timestamp + nodeOffset))
                    <= AbsolutePriorEvidenceLimits.stampEpsilon else {
                audit.constraintTimestampRejected += 1
                audit.rejectedDetails.append(AbsolutePriorRejectedDetail(
                    source: "constraints", recordIndex: recordIndex,
                    reason: "constraint_timestamp_invalid"))
                continue
            }
            guard strictPose2D(object["predictedPose"]) != nil,
                  let pose = strictPose2D(object["estimatedPose"]),
                  validateCandidates(object["candidates"]) else {
                audit.constraintPoseRejected += 1
                audit.rejectedDetails.append(AbsolutePriorRejectedDetail(
                    source: "constraints", recordIndex: recordIndex,
                    reason: "constraint_pose_invalid"))
                continue
            }
            guard let uniqueness = finiteDouble(object["uniqueness"]),
                  uniqueness >= AbsolutePriorEvidenceLimits.uniquenessLowerBound,
                  uniqueness <= AbsolutePriorEvidenceLimits.uniquenessUpperBound else {
                audit.constraintUniquenessRejected += 1
                audit.rejectedDetails.append(AbsolutePriorRejectedDetail(
                    source: "constraints", recordIndex: recordIndex,
                    reason: "constraint_uniqueness_invalid"))
                continue
            }
            guard let reason = object["reason"] as? String,
                  !reason.isEmpty,
                  optionalFiniteDouble(object, key: "residualCost"),
                  let effectivePointCount = StrictJSONScalar.integer(
                    object["effectivePointCount"]),
                  effectivePointCount >= 0,
                  let coverageAngle = finiteDouble(object["coverageAngleRad"]),
                  coverageAngle >= 0,
                  let matcherElapsed = finiteDouble(object["matcherElapsedMs"]),
                  matcherElapsed >= 0 else {
                audit.constraintInvalidRecordRejected += 1
                audit.rejectedDetails.append(AbsolutePriorRejectedDetail(
                    source: "constraints", recordIndex: recordIndex,
                    reason: "constraint_schema_invalid"))
                continue
            }
            guard accepted else {
                audit.constraintNotAcceptedRejected += 1
                audit.nonAcceptedDetails.append(AbsolutePriorRejectedDetail(
                    source: "constraints", recordIndex: recordIndex,
                    reason: "constraint_not_accepted"))
                continue
            }
            guard let bound = nearestNodeBinding(
                index: nodeIndex, stamp: nodeTimestamp) else {
                audit.constraintNodeBindingRejected += 1
                audit.rejectedDetails.append(AbsolutePriorRejectedDetail(
                    source: "constraints", recordIndex: recordIndex,
                    reason: "constraint_node_binding_failed"))
                continue
            }
            // V1R5 §8.2 (review B-06): the stamp fallback must be exact —
            // frozen delta AND second-candidate ambiguity margin.
            guard bound.delta <= AbsolutePriorEvidenceLimits
                .maximumNodeTimeDeltaSeconds else {
                audit.constraintNodeBindingRejected += 1
                audit.rejectedDetails.append(AbsolutePriorRejectedDetail(
                    source: "constraints", recordIndex: recordIndex,
                    reason: "constraint_node_time_delta_exceeded"))
                continue
            }
            guard bound.secondDelta - bound.delta
                > AbsolutePriorEvidenceLimits.minimumNodeMarginSeconds else {
                audit.constraintNodeBindingRejected += 1
                audit.rejectedDetails.append(AbsolutePriorRejectedDetail(
                    source: "constraints", recordIndex: recordIndex,
                    reason: "constraint_node_binding_ambiguous"))
                continue
            }
            // Derive sigma from the recorded uniqueness, exactly like
            // the PC reader (weight = max(1.0, 6.0*uniqueness)).
            let weight = AbsolutePriorEvidenceLimits.weightForUniqueness(uniqueness)
            let sigmaXY = 1.0 / sqrt(weight)
            let sigmaYaw = 1.0 / sqrt(weight)
            guard let information = informationFromSigmas(
                sigmaXM: sigmaXY, sigmaYM: sigmaXY, sigmaYawRad: sigmaYaw) else {
                audit.constraintUniquenessRejected += 1
                audit.rejectedDetails.append(AbsolutePriorRejectedDetail(
                    source: "constraints", recordIndex: recordIndex,
                    reason: "constraint_information_invalid"))
                continue
            }
            priors.append(MobileAbsolutePrior(
                nodeID: bound.node.nodeID,
                mapXM: pose.xM, mapYM: pose.yM, mapYawRad: pose.yawRad,
                information3x3: information, kind: 0, episodeID: 0))
            audit.constraintAccepted += 1
          } while false
        }
        guard constraintLineCount
                <= AbsolutePriorEvidenceLimits.qualificationMaximumConstraintRecords
        else {
            throw AbsolutePriorEvidenceParseError.qualificationLimitExceeded(
                constraintLineCount,
                AbsolutePriorEvidenceLimits.qualificationMaximumConstraintRecords)
        }
        if let expectedConstraintCount,
           constraintLineCount != expectedConstraintCount {
            throw AbsolutePriorEvidenceParseError.constraintCountMismatch(
                constraintLineCount, expectedConstraintCount)
        }

        // 2) Manual resets (v2 frame-timestamp binding / v3 nearest-node
        //    binding; fixed policy sigma §6.3).
        let manualURL = snapshotDirectory
            .appendingPathComponent("manual_localization_events.jsonl")
        var lastAlignmentVersion = 0
        let manualLineCount = try readSidecar(
            url: manualURL,
            source: "manual",
            maximumFileBytes: AbsolutePriorEvidenceLimits.manualMaximumFileBytes,
            maximumRecordBytes: AbsolutePriorEvidenceLimits.manualMaximumRecordBytes,
            maximumRecords: AbsolutePriorEvidenceLimits.manualMaximumRecords,
            invalidRecord: { recordIndex in
                audit.manualInvalidRecordRejected += 1
                audit.rejectedDetails.append(AbsolutePriorRejectedDetail(
                    source: "manual", recordIndex: recordIndex,
                    reason: "invalid_record"))
            }
        ) { recordIndex, object in
          repeat {
            audit.manualTotal += 1
            guard (object["format"] as? String) == "MarketScannerManualLocalizationEvent" else {
                audit.manualFormatRejected += 1
                audit.rejectedDetails.append(AbsolutePriorRejectedDetail(
                    source: "manual", recordIndex: recordIndex,
                    reason: "manual_event_format_invalid"))
                continue
            }
            guard Set(object.keys).isSubset(of: manualKnownFields) else {
                audit.manualInvalidRecordRejected += 1
                audit.rejectedDetails.append(AbsolutePriorRejectedDetail(
                    source: "manual", recordIndex: recordIndex,
                    reason: "manual_event_unknown_field"))
                continue
            }
            let version = StrictJSONScalar.integer(object["version"])
            guard version == 2 || version == 3 else {
                audit.manualVersionRejected += 1
                audit.rejectedDetails.append(AbsolutePriorRejectedDetail(
                    source: "manual", recordIndex: recordIndex,
                    reason: "manual_event_legacy_or_unknown_version"))
                continue
            }
            guard manualIdentityMatches(
                object, priorMapID: priorMapID,
                priorMapSHA256: priorMapSHA256,
                trackingSessionID: trackingSessionID,
                floorID: floorID) else {
                audit.manualIdentityRejected += 1
                audit.rejectedDetails.append(AbsolutePriorRejectedDetail(
                    source: "manual", recordIndex: recordIndex,
                    reason: "manual_event_identity_missing_or_mismatch"))
                continue
            }
            guard let wallUnix = finiteDouble(object["wall_clock_timestamp_unix"]),
                  let wallISO = object["wall_clock_timestamp"] as? String,
                  let parsedWallUnix = iso8601UnixSeconds(wallISO),
                  abs(parsedWallUnix - wallUnix)
                    <= AbsolutePriorEvidenceLimits.wallClockEpsilonSeconds else {
                audit.manualWallClockRejected += 1
                audit.rejectedDetails.append(AbsolutePriorRejectedDetail(
                    source: "manual", recordIndex: recordIndex,
                    reason: "manual_event_wall_clock_missing_or_invalid"))
                continue
            }
            guard let rawFrameTimestamp = finiteDouble(object["frame_timestamp"]),
                  let frameTimestamp = finiteDouble(
                    object["node_timebase_frame_timestamp"]),
                  let frameOffset = finiteDouble(
                    object["node_timebase_offset_seconds"]),
                  abs(frameTimestamp - (rawFrameTimestamp + frameOffset))
                    <= AbsolutePriorEvidenceLimits.stampEpsilon else {
                audit.manualNodeTimebaseRejected += 1
                audit.rejectedDetails.append(AbsolutePriorRejectedDetail(
                    source: "manual", recordIndex: recordIndex,
                    reason: "manual_event_node_timebase_invalid"))
                continue
            }
            guard let alignmentVersion = intField(object, "alignment_version"),
                  alignmentVersion > 0,
                  alignmentVersion > lastAlignmentVersion,
                  let snapshotGeneration = intField(
                    object, "node_time_snapshot_generation"),
                  snapshotGeneration >= 0,
                  let manualReason = object["reason"] as? String,
                  !manualReason.isEmpty,
                  let bindingReason = object["node_binding_reason"] as? String,
                  !bindingReason.isEmpty else {
                audit.manualAlignmentRejected += 1
                audit.rejectedDetails.append(AbsolutePriorRejectedDetail(
                    source: "manual", recordIndex: recordIndex,
                    reason: "manual_event_time_or_alignment_invalid"))
                continue
            }
            // Advance the observed watermark before node binding: a
            // newer confirmation that later fails evidence checks still
            // proves every following lower version is stale (PC parity).
            lastAlignmentVersion = alignmentVersion
            guard strictPose2D(object["confirmed_map_pose"]) != nil,
                  strictPose2D(object["arkit_pose"]) != nil else {
                audit.manualPoseRejected += 1
                audit.rejectedDetails.append(AbsolutePriorRejectedDetail(
                    source: "manual", recordIndex: recordIndex,
                    reason: "manual_event_pose_invalid"))
                continue
            }
            let bound: AbsolutePriorEvidenceNode?
            if version == 3 {
                guard snapshotGeneration > 0 else {
                    audit.manualBindingRejected += 1
                    audit.rejectedDetails.append(AbsolutePriorRejectedDetail(
                        source: "manual", recordIndex: recordIndex,
                        reason: "manual_event_node_time_snapshot_generation_invalid"))
                    continue
                }
                guard (object["node_binding_status"] as? String) == "matched" else {
                    audit.manualBindingRejected += 1
                    audit.rejectedDetails.append(AbsolutePriorRejectedDetail(
                        source: "manual", recordIndex: recordIndex,
                        reason: "manual_event_node_binding_status_invalid"))
                    continue
                }
                guard let nearestID = intField(object, "nearest_node_id"),
                      nearestID > 0 else {
                    audit.manualBindingRejected += 1
                    audit.rejectedDetails.append(AbsolutePriorRejectedDetail(
                        source: "manual", recordIndex: recordIndex,
                        reason: "manual_event_node_evidence_missing"))
                    continue
                }
                guard let node = nodeIndex.uniqueNode(nodeID: Int64(nearestID)) else {
                    audit.manualBindingRejected += 1
                    audit.rejectedDetails.append(AbsolutePriorRejectedDetail(
                        source: "manual", recordIndex: recordIndex,
                    reason: nodeIndex.nodeNotFoundReason(nodeID: Int64(nearestID))))
                    continue
                }
                guard let nearestStamp = finiteDouble(object["nearest_node_stamp"]),
                      let eventDelta = finiteDouble(object["node_time_delta_seconds"]) else {
                    audit.manualBindingRejected += 1
                    audit.rejectedDetails.append(AbsolutePriorRejectedDetail(
                        source: "manual", recordIndex: recordIndex,
                        reason: "manual_event_node_evidence_missing"))
                    continue
                }
                let stampDelta = abs(nearestStamp - node.stamp)
                let recomputedDelta = abs(frameTimestamp - node.stamp)
                guard stampDelta <= AbsolutePriorEvidenceLimits.stampEpsilon else {
                    audit.manualBindingRejected += 1
                    audit.rejectedDetails.append(AbsolutePriorRejectedDetail(
                        source: "manual", recordIndex: recordIndex,
                        reason: "manual_event_node_stamp_mismatch"))
                    continue
                }
                guard abs(eventDelta - recomputedDelta)
                    <= AbsolutePriorEvidenceLimits.stampEpsilon else {
                    audit.manualBindingRejected += 1
                    audit.rejectedDetails.append(AbsolutePriorRejectedDetail(
                        source: "manual", recordIndex: recordIndex,
                        reason: "manual_event_node_delta_mismatch"))
                    continue
                }
                guard recomputedDelta
                    <= AbsolutePriorEvidenceLimits.maximumNodeTimeDeltaSeconds else {
                    audit.manualBindingRejected += 1
                    audit.rejectedDetails.append(AbsolutePriorRejectedDetail(
                        source: "manual", recordIndex: recordIndex,
                        reason: "manual_event_node_time_delta_exceeded"))
                    continue
                }
                guard let nearest = nodeIndex.nearest(stamp: frameTimestamp),
                      nearest.node.nodeID == node.nodeID else {
                    audit.manualBindingRejected += 1
                    audit.rejectedDetails.append(AbsolutePriorRejectedDetail(
                        source: "manual", recordIndex: recordIndex,
                        reason: "manual_event_claimed_node_not_nearest"))
                    continue
                }
                guard nearest.secondDelta - nearest.delta
                    > AbsolutePriorEvidenceLimits.minimumNodeMarginSeconds else {
                    audit.manualBindingRejected += 1
                    audit.rejectedDetails.append(AbsolutePriorRejectedDetail(
                        source: "manual", recordIndex: recordIndex,
                        reason: "manual_event_node_binding_ambiguous"))
                    continue
                }
                bound = node
            } else {
                // v2 legacy: frame-timestamp-only binding.
                guard (object["node_binding_status"] as? String) == "frame_timestamp_only" else {
                    audit.manualBindingRejected += 1
                    audit.rejectedDetails.append(AbsolutePriorRejectedDetail(
                        source: "manual", recordIndex: recordIndex,
                        reason: "manual_event_node_binding_status_invalid"))
                    continue
                }
                if !isJSONNull(object["nearest_node_id"])
                    || !isJSONNull(object["nearest_node_stamp"])
                    || !isJSONNull(object["node_time_delta_seconds"]) {
                    audit.manualBindingRejected += 1
                    audit.rejectedDetails.append(AbsolutePriorRejectedDetail(
                        source: "manual", recordIndex: recordIndex,
                        reason: "manual_event_node_evidence_contradictory"))
                    continue
                }
                guard let nearest = nearestNodeBinding(
                    index: nodeIndex, stamp: frameTimestamp) else {
                    audit.manualBindingRejected += 1
                    audit.rejectedDetails.append(AbsolutePriorRejectedDetail(
                        source: "manual", recordIndex: recordIndex,
                        reason: nodes.isEmpty
                            ? "manual_event_no_node_timestamps"
                            : "manual_event_timestamp_binding_ambiguous"))
                    continue
                }
                guard nearest.delta
                    <= AbsolutePriorEvidenceLimits.maximumNodeTimeDeltaSeconds else {
                    audit.manualBindingRejected += 1
                    audit.rejectedDetails.append(AbsolutePriorRejectedDetail(
                        source: "manual", recordIndex: recordIndex,
                        reason: "manual_event_node_time_delta_exceeded"))
                    continue
                }
                guard nearest.secondDelta - nearest.delta
                    > AbsolutePriorEvidenceLimits.minimumNodeMarginSeconds else {
                    audit.manualBindingRejected += 1
                    audit.rejectedDetails.append(AbsolutePriorRejectedDetail(
                        source: "manual", recordIndex: recordIndex,
                        reason: "manual_event_node_binding_ambiguous"))
                    continue
                }
                bound = nearest.node
            }
            guard let bound = bound else { continue }
            guard let pose = strictPose2D(object["confirmed_map_pose"]),
                  let information = informationFromSigmas(
                      sigmaXM: AbsolutePriorEvidenceLimits.manualSigmaM,
                      sigmaYM: AbsolutePriorEvidenceLimits.manualSigmaM,
                      sigmaYawRad: AbsolutePriorEvidenceLimits.manualSigmaYawRad) else {
                audit.manualPoseRejected += 1
                audit.rejectedDetails.append(AbsolutePriorRejectedDetail(
                    source: "manual", recordIndex: recordIndex,
                    reason: "manual_event_pose_invalid"))
                continue
            }
            priors.append(MobileAbsolutePrior(
                nodeID: bound.nodeID,
                mapXM: pose.xM, mapYM: pose.yM, mapYawRad: pose.yawRad,
                information3x3: information, kind: 2, episodeID: 0))
            audit.manualAccepted += 1
          } while false
        }
        if let expectedManualCount,
           manualLineCount != expectedManualCount {
            throw AbsolutePriorEvidenceParseError.manualCountMismatch(
                manualLineCount, expectedManualCount)
        }

        // 3) Recovery episodes: audit only (no priors). Full evidence
        //    validation is the RecoveryLifecycleEvidenceParser's job.
        let recoveryURL = snapshotDirectory
            .appendingPathComponent("localization_recovery_events.jsonl")
        audit.recoveryRecordCount = try countNonEmptyLines(
            url: recoveryURL,
            source: "recovery",
            maximumFileBytes: AbsolutePriorEvidenceLimits.recoveryMaximumFileBytes,
            maximumRecordBytes: AbsolutePriorEvidenceLimits.recoveryMaximumRecordBytes,
            maximumRecords: AbsolutePriorEvidenceLimits.recoveryMaximumRecords)
        if let expectedRecoveryCount,
           audit.recoveryRecordCount != expectedRecoveryCount {
            throw AbsolutePriorEvidenceParseError.recoveryCountMismatch(
                audit.recoveryRecordCount, expectedRecoveryCount)
        }

        return AbsolutePriorEvidenceParseResult(priors: priors, audit: audit)
    }

    // MARK: - Record helpers

    /// Reads a sidecar exactly once with the file-level limits and the
    /// V1R5 §8.1 frozen JSONL framing (streaming 64 KiB chunks, final
    /// newline, no blank lines). A missing file is a legal empty input; a
    /// file-level anomaly throws; a single unparseable line is audited as
    /// `invalid_record` (the PC reader also skips damaged lines instead
    /// of failing the run). Valid objects are delivered immediately and
    /// never accumulated as `[[String: Any]]`.
    private static func readSidecar(
        url: URL,
        source: String,
        maximumFileBytes: Int,
        maximumRecordBytes: Int,
        maximumRecords: Int,
        invalidRecord: (Int) -> Void,
        body: (Int, [String: Any]) throws -> Void
    ) throws -> Int {
        guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard fileSize <= maximumFileBytes else {
            throw AbsolutePriorEvidenceParseError.fileTooLarge(source, fileSize)
        }
        do {
            let summary = try StrictJSONLStreamReader.forEachLine(
                from: url,
                limits: .init(
                    maximumFileBytes: maximumFileBytes,
                    maximumLineBytes: maximumRecordBytes,
                    maximumLineCount: maximumRecords)
            ) { line in
                let object: [String: Any]
                do {
                    object = try StrictJSONLStreamReader.strictObject(
                        from: line.text, lineNumber: line.number)
                } catch {
                    invalidRecord(line.number)
                    return
                }
                try body(line.number, object)
            }
            return summary.lineCount
        } catch let error as AbsolutePriorEvidenceParseError {
            throw error
        } catch let error as StrictJSONLStreamReader.StreamError {
            throw AbsolutePriorEvidenceParseError.fileUnreadable(
                "\(source): \(error.localizedDescription)")
        }
    }

    /// Counts lines of a sidecar (recovery audit) through the shared strict
    /// framing. Missing file -> 0; blank lines and partial tails are rejected.
    private static func countNonEmptyLines(
        url: URL,
        source: String,
        maximumFileBytes: Int,
        maximumRecordBytes: Int,
        maximumRecords: Int
    ) throws -> Int {
        guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard fileSize <= maximumFileBytes else {
            throw AbsolutePriorEvidenceParseError.fileTooLarge(source, fileSize)
        }
        let summary: StrictJSONLStreamReader.Summary
        do {
            summary = try StrictJSONLStreamReader.forEachLine(
                from: url,
                limits: .init(
                    maximumFileBytes: maximumFileBytes,
                    maximumLineBytes: maximumRecordBytes,
                    maximumLineCount: maximumRecords)
            ) { _ in }
        } catch let error as StrictJSONLStreamReader.StreamError {
            throw AbsolutePriorEvidenceParseError.fileUnreadable(
                "\(source): \(error.localizedDescription)")
        }
        return summary.lineCount
    }

    /// Identity is required and must match exactly: a record missing an
    /// identity field is rejected (fail-closed), never applied.
    private static func identityMatches(
        _ object: [String: Any],
        priorMapID: String,
        priorMapSHA256: String,
        trackingSessionID: String,
        floorID: String
    ) -> Bool {
        guard let recordMapID = object["priorMapId"] as? String,
              recordMapID == priorMapID else { return false }
        guard let recordSHA = object["priorMapSha256"] as? String,
              recordSHA == priorMapSHA256 else { return false }
        guard let recordSession = object["trackingSessionId"] as? String,
              recordSession == trackingSessionID else { return false }
        guard let recordFloor = object["floorId"] as? String,
              recordFloor == floorID else { return false }
        return true
    }

    private static func manualIdentityMatches(
        _ object: [String: Any],
        priorMapID: String,
        priorMapSHA256: String,
        trackingSessionID: String,
        floorID: String
    ) -> Bool {
        guard let recordMapID = object["prior_map_id"] as? String,
              recordMapID == priorMapID else { return false }
        guard let recordSHA = object["prior_map_sha256"] as? String,
              recordSHA == priorMapSHA256 else { return false }
        guard let recordSession = object["tracking_session_id"] as? String,
              recordSession == trackingSessionID else { return false }
        guard let recordFloor = object["floor_id"] as? String,
              recordFloor == floorID else { return false }
        return true
    }

    private static let constraintKnownFields: Set<String> = [
        "format", "version", "timestamp", "nodeTimebaseTimestamp",
        "nodeTimebaseOffsetSeconds", "trackingSessionId", "priorMapId",
        "priorMapSha256", "floorId", "accepted", "measurementAccepted",
        "correctionStepApplied", "confidenceAccepted", "disposition", "reason",
        "predictedPose", "estimatedPose", "candidates", "uniqueness",
        "residualCost", "effectivePointCount", "coverageAngleRad",
        "matcherElapsedMs",
    ]

    private static let manualKnownFields: Set<String> = [
        "format", "version", "wall_clock_timestamp",
        "wall_clock_timestamp_unix", "frame_timestamp",
        "node_timebase_frame_timestamp", "node_timebase_offset_seconds",
        "nearest_node_id", "nearest_node_stamp", "node_time_delta_seconds",
        "node_time_snapshot_generation", "node_binding_status",
        "node_binding_reason", "alignment_version", "tracking_session_id",
        "prior_map_id", "prior_map_sha256", "floor_id", "reason",
        "arkit_pose", "confirmed_map_pose",
    ]

    private static let poseKnownFields: Set<String> = [
        "x_m", "y_m", "yaw_rad",
    ]

    private static let candidateKnownFields: Set<String> = [
        "pose", "cost", "score",
    ]

    private static func strictPose2D(_ value: Any?) -> PriorMapPose2D? {
        guard let object = value as? [String: Any],
              Set(object.keys) == poseKnownFields,
              let xM = finiteDouble(object["x_m"]),
              let yM = finiteDouble(object["y_m"]),
              let yawRad = finiteDouble(object["yaw_rad"]) else { return nil }
        return PriorMapPose2D(xM: xM, yM: yM, yawRad: yawRad)
    }

    private static func validateCandidates(_ value: Any?) -> Bool {
        guard let candidates = value as? [Any] else { return false }
        return candidates.allSatisfy { candidate in
            guard let object = candidate as? [String: Any],
                  Set(object.keys) == candidateKnownFields,
                  strictPose2D(object["pose"]) != nil,
                  finiteDouble(object["cost"]) != nil,
                  finiteDouble(object["score"]) != nil else { return false }
            return true
        }
    }

    private static func optionalFiniteDouble(
        _ object: [String: Any], key: String
    ) -> Bool {
        guard let value = object[key] else { return true }
        return value is NSNull || finiteDouble(value) != nil
    }

    private static func isJSONNull(_ value: Any?) -> Bool {
        return value is NSNull
    }

    private static func iso8601UnixSeconds(_ value: String) -> Double? {
        guard !value.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return date.timeIntervalSince1970
        }
        let wholeSeconds = ISO8601DateFormatter()
        wholeSeconds.formatOptions = [.withInternetDateTime]
        return wholeSeconds.date(from: value)?.timeIntervalSince1970
    }

    /// V1R5 §6.1: strict finite JSON number via the shared scalar helper
    /// (never a Bool, never non-finite).
    private static func finiteDouble(_ value: Any?) -> Double? {
        return StrictJSONScalar.number(value)
    }

    /// V1R5 §6.1 (review B-06): strict integer — a fractional number or a
    /// numeric Bool can never pass (the V1R4 `NSNumber.intValue`
    /// truncated 1.9 into 1).
    private static func intField(_ object: [String: Any], _ key: String) -> Int? {
        return StrictJSONScalar.integer(object[key])
    }

    /// V1R5 §8.2: nearest node by stamp with the frozen delta and
    /// second-candidate data (binary search over the one run-scoped index —
    /// never a P×N linear scan). Callers apply their frozen delta/margin
    /// gates so they can emit the correct stable rejection category.
    private static func nearestNodeBinding(
        index: NodeIndex, stamp: Double
    ) -> (node: AbsolutePriorEvidenceNode, delta: Double, secondDelta: Double)? {
        return index.nearest(stamp: stamp)
    }

    /// Localization-sigma policy (§6.3): information must derive from
    /// recorded uncertainty, never an undocumented constant.
    private static func informationFromSigmas(
        sigmaXM: Double, sigmaYM: Double, sigmaYawRad: Double
    ) -> [Double]? {
        guard sigmaXM.isFinite, sigmaYM.isFinite, sigmaYawRad.isFinite,
              sigmaXM > 0, sigmaYM > 0, sigmaYawRad > 0 else { return nil }
        let limits = AbsolutePriorEvidenceLimits.self
        let cx = min(max(sigmaXM, limits.minimumSigmaM), limits.maximumSigmaM)
        let cy = min(max(sigmaYM, limits.minimumSigmaM), limits.maximumSigmaM)
        let cyaw = min(
            max(sigmaYawRad, limits.minimumSigmaYawRad),
            limits.maximumSigmaYawRad)
        return [1.0 / (cx * cx), 0, 0,
                0, 1.0 / (cy * cy), 0,
                0, 0, 1.0 / (cyaw * cyaw)]
    }
}
