import Foundation

// MARK: - Limits (aligned with the PC reader and
// RecoveryLifecycleEvidenceLimits; §6.3 sigma policy)

enum AbsolutePriorEvidenceLimits {
    /// Sidecar file size / record size / record-count gates.
    static let maximumFileBytes = 16 * 1024 * 1024
    static let maximumRecordBytes = 1024 * 1024
    static let maximumRecords = 100_000
    /// Manual v3 node-binding gate (identical to the PC reader
    /// `maximum_time_delta_seconds=1.0`).
    static let maximumNodeTimeDeltaSeconds = 1.0
    /// Stamp / delta re-check tolerance (identical to the PC reader).
    static let stampEpsilon = 1.0e-6
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

    var rejectedDetails: [AbsolutePriorRejectedDetail] = []

    var acceptedPriorCount: Int { constraintAccepted + manualAccepted }

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
        floorID: String
    ) throws -> AbsolutePriorEvidenceParseResult {
        var audit = AbsolutePriorEvidenceAudit()
        var priors: [MobileAbsolutePrior] = []

        // 1) Localization constraints.
        let constraintsURL = snapshotDirectory
            .appendingPathComponent("localization_constraints.jsonl")
        let constraintRecords = try readSidecar(
            url: constraintsURL, source: "constraints", audit: &audit)
        for (index, object) in constraintRecords.enumerated() {
            let recordIndex = index + 1
            audit.constraintTotal += 1
            guard (object["format"] as? String) == "MarketScannerLocalizationConstraint" else {
                audit.constraintFormatRejected += 1
                audit.rejectedDetails.append(AbsolutePriorRejectedDetail(
                    source: "constraints", recordIndex: recordIndex,
                    reason: "constraint_format_invalid"))
                continue
            }
            guard object["accepted"] as? Bool == true else {
                audit.constraintNotAcceptedRejected += 1
                audit.rejectedDetails.append(AbsolutePriorRejectedDetail(
                    source: "constraints", recordIndex: recordIndex,
                    reason: "constraint_not_accepted"))
                continue
            }
            let disposition = object["disposition"] as? String
            guard disposition == "accepted_local"
                || disposition == "accepted_recovery_convergence" else {
                audit.constraintDispositionRejected += 1
                audit.rejectedDetails.append(AbsolutePriorRejectedDetail(
                    source: "constraints", recordIndex: recordIndex,
                    reason: "constraint_disposition_invalid"))
                continue
            }
            guard identityMatches(
                object, priorMapID: priorMapID,
                priorMapSHA256: priorMapSHA256,
                trackingSessionID: trackingSessionID) else {
                audit.constraintIdentityRejected += 1
                audit.rejectedDetails.append(AbsolutePriorRejectedDetail(
                    source: "constraints", recordIndex: recordIndex,
                    reason: "constraint_identity_missing_or_mismatch"))
                continue
            }
            guard let pose = pose2D(object["estimatedPose"] as? [String: Any]) else {
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
            guard let nodeTimestamp = finiteDouble(object["nodeTimebaseTimestamp"]) else {
                audit.constraintTimestampRejected += 1
                audit.rejectedDetails.append(AbsolutePriorRejectedDetail(
                    source: "constraints", recordIndex: recordIndex,
                    reason: "constraint_timestamp_invalid"))
                continue
            }
            guard let bound = nearestNode(nodes: nodes, stamp: nodeTimestamp) else {
                audit.constraintNodeBindingRejected += 1
                audit.rejectedDetails.append(AbsolutePriorRejectedDetail(
                    source: "constraints", recordIndex: recordIndex,
                    reason: "constraint_node_binding_failed"))
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
                nodeID: bound.nodeID,
                mapXM: pose.xM, mapYM: pose.yM, mapYawRad: pose.yawRad,
                information3x3: information, kind: 0, episodeID: 0))
            audit.constraintAccepted += 1
        }

        // 2) Manual resets (v2 frame-timestamp binding / v3 nearest-node
        //    binding; fixed policy sigma §6.3).
        let manualURL = snapshotDirectory
            .appendingPathComponent("manual_localization_events.jsonl")
        let manualRecords = try readSidecar(
            url: manualURL, source: "manual", audit: &audit)
        var lastAlignmentVersion = 0
        for (index, object) in manualRecords.enumerated() {
            let recordIndex = index + 1
            audit.manualTotal += 1
            guard (object["format"] as? String) == "MarketScannerManualLocalizationEvent" else {
                audit.manualFormatRejected += 1
                audit.rejectedDetails.append(AbsolutePriorRejectedDetail(
                    source: "manual", recordIndex: recordIndex,
                    reason: "manual_event_format_invalid"))
                continue
            }
            let version = object["version"] as? Int
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
                  !wallISO.isEmpty else {
                audit.manualWallClockRejected += 1
                audit.rejectedDetails.append(AbsolutePriorRejectedDetail(
                    source: "manual", recordIndex: recordIndex,
                    reason: "manual_event_wall_clock_missing_or_invalid"))
                continue
            }
            _ = wallUnix
            guard let frameTimestamp = finiteDouble(object["node_timebase_frame_timestamp"]) else {
                audit.manualNodeTimebaseRejected += 1
                audit.rejectedDetails.append(AbsolutePriorRejectedDetail(
                    source: "manual", recordIndex: recordIndex,
                    reason: "manual_event_node_timebase_invalid"))
                continue
            }
            guard let alignmentVersion = intField(object, "alignment_version"),
                  alignmentVersion > 0,
                  alignmentVersion > lastAlignmentVersion else {
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
            guard pose2D(object["confirmed_map_pose"] as? [String: Any]) != nil,
                  pose2D(object["arkit_pose"] as? [String: Any]) != nil else {
                audit.manualPoseRejected += 1
                audit.rejectedDetails.append(AbsolutePriorRejectedDetail(
                    source: "manual", recordIndex: recordIndex,
                    reason: "manual_event_pose_invalid"))
                continue
            }
            let bound: AbsolutePriorEvidenceNode?
            if version == 3 {
                guard let generation = intField(object, "node_time_snapshot_generation"),
                      generation > 0 else {
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
                guard let node = uniqueNode(nodes: nodes, nodeID: Int64(nearestID)) else {
                    audit.manualBindingRejected += 1
                    audit.rejectedDetails.append(AbsolutePriorRejectedDetail(
                        source: "manual", recordIndex: recordIndex,
                        reason: nodeNotFoundReason(nodes: nodes, nodeID: Int64(nearestID))))
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
                if object["nearest_node_stamp"] != nil
                    || object["node_time_delta_seconds"] != nil {
                    audit.manualBindingRejected += 1
                    audit.rejectedDetails.append(AbsolutePriorRejectedDetail(
                        source: "manual", recordIndex: recordIndex,
                        reason: "manual_event_node_evidence_contradictory"))
                    continue
                }
                guard let nearest = nearestNodeBinding(
                    nodes: nodes, stamp: frameTimestamp) else {
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
                bound = nearest.node
            }
            guard let bound = bound else { continue }
            guard let pose = pose2D(object["confirmed_map_pose"] as? [String: Any]),
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
        }

        // 3) Recovery episodes: audit only (no priors). Full evidence
        //    validation is the RecoveryLifecycleEvidenceParser's job.
        let recoveryURL = snapshotDirectory
            .appendingPathComponent("localization_recovery_events.jsonl")
        audit.recoveryRecordCount = try countNonEmptyLines(
            url: recoveryURL, source: "recovery")

        return AbsolutePriorEvidenceParseResult(priors: priors, audit: audit)
    }

    // MARK: - Record helpers

    /// Reads a sidecar exactly once with the file-level limits. A
    /// missing file is a legal empty input; a file-level anomaly throws;
    /// a single unparseable line is audited as `invalid_record` (the PC
    /// reader also skips damaged lines instead of failing the run).
    private static func readSidecar(
        url: URL,
        source: String,
        audit: inout AbsolutePriorEvidenceAudit
    ) throws -> [[String: Any]] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard fileSize <= AbsolutePriorEvidenceLimits.maximumFileBytes else {
            throw AbsolutePriorEvidenceParseError.fileTooLarge(source, fileSize)
        }
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            throw AbsolutePriorEvidenceParseError.fileUnreadable(source)
        }
        var records: [[String: Any]] = []
        var lineNumber = 0
        for rawLine in content.split(
            separator: "\n", omittingEmptySubsequences: false) {
            lineNumber += 1
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            guard let data = line.data(using: .utf8) else {
                if source == "constraints" {
                    audit.constraintInvalidRecordRejected += 1
                } else {
                    audit.manualInvalidRecordRejected += 1
                }
                audit.rejectedDetails.append(AbsolutePriorRejectedDetail(
                    source: source, recordIndex: lineNumber,
                    reason: "invalid_record"))
                continue
            }
            guard data.count <= AbsolutePriorEvidenceLimits.maximumRecordBytes else {
                throw AbsolutePriorEvidenceParseError.recordTooLarge(
                    source, data.count)
            }
            guard let object = try? StrictJSONDocumentParser.object(
                from: data,
                limits: StrictJSONDocumentLimits(maximumBytes: data.count + 1))
                as? [String: Any] else {
                if source == "constraints" {
                    audit.constraintInvalidRecordRejected += 1
                } else {
                    audit.manualInvalidRecordRejected += 1
                }
                audit.rejectedDetails.append(AbsolutePriorRejectedDetail(
                    source: source, recordIndex: lineNumber,
                    reason: "invalid_record"))
                continue
            }
            records.append(object)
        }
        guard records.count <= AbsolutePriorEvidenceLimits.maximumRecords else {
            throw AbsolutePriorEvidenceParseError.tooManyRecords(
                source, records.count)
        }
        return records
    }

    /// Counts non-empty lines of a sidecar (recovery audit). Missing
    /// file -> 0; file-level limits identical to the evidence parser.
    private static func countNonEmptyLines(url: URL, source: String) throws -> Int {
        guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard fileSize <= AbsolutePriorEvidenceLimits.maximumFileBytes else {
            throw AbsolutePriorEvidenceParseError.fileTooLarge(source, fileSize)
        }
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            throw AbsolutePriorEvidenceParseError.fileUnreadable(source)
        }
        var count = 0
        for rawLine in content.split(
            separator: "\n", omittingEmptySubsequences: false) {
            if !rawLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                count += 1
            }
        }
        guard count <= AbsolutePriorEvidenceLimits.maximumRecords else {
            throw AbsolutePriorEvidenceParseError.tooManyRecords(source, count)
        }
        return count
    }

    /// Identity is required and must match exactly: a record missing an
    /// identity field is rejected (fail-closed), never applied.
    private static func identityMatches(
        _ object: [String: Any],
        priorMapID: String,
        priorMapSHA256: String,
        trackingSessionID: String
    ) -> Bool {
        guard let recordMapID = object["priorMapId"] as? String,
              recordMapID == priorMapID else { return false }
        guard let recordSHA = object["priorMapSha256"] as? String,
              recordSHA == priorMapSHA256 else { return false }
        guard let recordSession = object["trackingSessionId"] as? String,
              recordSession == trackingSessionID else { return false }
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

    private static func pose2D(_ object: [String: Any]?) -> PriorMapPose2D? {
        guard let object = object,
              let xM = finiteDouble(object["x_m"]),
              let yM = finiteDouble(object["y_m"]),
              let yawRad = finiteDouble(object["yaw_rad"]) else { return nil }
        return PriorMapPose2D(xM: xM, yM: yM, yawRad: yawRad)
    }

    /// JSON booleans decode as CFBoolean and would otherwise pass the
    /// NSNumber casts; JSON integers decode as NSNumber whose `as?
    /// Double`/`as? Int` bridging is unreliable (integer-valued doubles
    /// can fail or be treated as Bool). Cast through NSNumber and
    /// exclude CFBoolean by type id.
    private static func finiteDouble(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite else { return nil }
        return double
    }

    private static func intField(_ object: [String: Any], _ key: String) -> Int? {
        guard let number = object[key] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.intValue
    }

    /// Nearest node by stamp (no delta gate) — online-structure binding
    /// parity with the PC reader.
    private static func nearestNode(
        nodes: [AbsolutePriorEvidenceNode], stamp: Double
    ) -> AbsolutePriorEvidenceNode? {
        var best: AbsolutePriorEvidenceNode?
        var bestDelta = Double.greatestFiniteMagnitude
        for node in nodes {
            let delta = abs(node.stamp - stamp)
            if delta < bestDelta {
                bestDelta = delta
                best = node
            }
        }
        return best
    }

    /// Exact node-id lookup; a duplicate id is ambiguous (never occurs
    /// in a valid DB, but fail closed anyway).
    private static func uniqueNode(
        nodes: [AbsolutePriorEvidenceNode], nodeID: Int64
    ) -> AbsolutePriorEvidenceNode? {
        var found: AbsolutePriorEvidenceNode?
        for node in nodes where node.nodeID == nodeID {
            if found != nil { return nil }
            found = node
        }
        return found
    }

    /// v2 frame-timestamp binding: nearest node by stamp; a tie within
    /// the stamp epsilon is ambiguous and rejected (PC parity).
    private static func nearestNodeBinding(
        nodes: [AbsolutePriorEvidenceNode], stamp: Double
    ) -> (node: AbsolutePriorEvidenceNode, delta: Double)? {
        var best: AbsolutePriorEvidenceNode?
        var bestDelta = Double.greatestFiniteMagnitude
        var ambiguous = false
        for node in nodes {
            let delta = abs(node.stamp - stamp)
            if delta < bestDelta {
                bestDelta = delta
                best = node
                ambiguous = false
            } else if abs(delta - bestDelta)
                <= AbsolutePriorEvidenceLimits.stampEpsilon {
                ambiguous = true
            }
        }
        guard let node = best, !ambiguous else { return nil }
        return (node, bestDelta)
    }

    private static func nodeNotFoundReason(
        nodes: [AbsolutePriorEvidenceNode], nodeID: Int64
    ) -> String {
        let present = nodes.contains { $0.nodeID == nodeID }
        return present
            ? "manual_event_node_id_ambiguous"
            : "manual_event_node_id_not_found"
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
