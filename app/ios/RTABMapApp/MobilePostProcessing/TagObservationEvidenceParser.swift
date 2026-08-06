import Foundation

// MARK: - Limits

/// File / record / count gates and the node-timebase binding policy for
/// `tag_observations.jsonl` (V1R4 §13.2, V1R5 §5.4/§6.1). Values are
/// aligned with the absolute-prior evidence limits and the PC reader.
///
/// V1R5 scale (review B-05): the V1R4 16 MiB / 100k gates did not match
/// the product ceiling of 200k observations. The contract is now derived
/// from real samples (≈600 bytes per complete observation record) times
/// the product maximum plus a safety factor, and the parser streams via
/// the shared strict JSONL reader so memory stays bounded to one line.
enum TagObservationEvidenceLimits {
    /// 200k observations × ≈600 bytes + safety factor (§4 contract).
    static let maximumFileBytes = 256 * 1024 * 1024
    static let maximumRecordBytes = 1024 * 1024
    static let maximumRecords = 200_000
    /// Node-timebase binding gate (identical to the PC reader
    /// `maximum_time_delta_seconds=1.0` and RTABMap.latestNodeBinding).
    static let maximumNodeTimeDeltaSeconds = 1.0
    static let stampEpsilon = 1.0e-6
    /// V1R5 §6.4: the second-best binding candidate must be farther than
    /// this from the observation (exact node binding, no tie/margin-free
    /// acceptance).
    static let minimumNodeMarginSeconds = 0.01
    /// Raw map-position sanity bound (±5 km, far beyond any store).
    static let maximumRawPositionM = 5000.0
    static let maximumConfidence = 1.0
    static let maximumDepthInlierRatio = 1.0
    static let maximumNormalizedBoundsDimension = 2.0
}

// MARK: - Audit

/// Stable failure code + per-record context for one rejected record.
/// Every rejection is counted and surfaced; a record is never silently
/// dropped (V1R4 §13.2: "不得 continue 后消失").
struct TagObservationRejectedDetail: Equatable {
    let recordIndex: Int
    let reason: String
}

/// Strict-parse audit counts so the device parser and the PC reader
/// classify identically.
struct TagObservationEvidenceAudit: Equatable {
    var recordTotal = 0
    var recordAccepted = 0
    /// Unlocalized observations (no raw_map_position) are valid evidence
    /// but never produce a price tag; counted for the quality report.
    var recordUnlocalizedSkipped = 0
    var recordFormatRejected = 0
    var recordVersionRejected = 0
    var recordIdentityRejected = 0
    var recordSchemaRejected = 0
    var recordFiniteRejected = 0
    var recordDuplicateRejected = 0
    var recordPoseRejected = 0
    var recordNodeBindingRejected = 0
    var rejectedDetails: [TagObservationRejectedDetail] = []

    var totalRejected: Int {
        return recordFormatRejected + recordVersionRejected
            + recordIdentityRejected + recordSchemaRejected
            + recordFiniteRejected + recordDuplicateRejected
            + recordPoseRejected + recordNodeBindingRejected
    }

    func reportPayload() -> [String: Any] {
        return [
            "total": recordTotal,
            "accepted": recordAccepted,
            "unlocalized_skipped": recordUnlocalizedSkipped,
            "rejected": [
                "format_invalid": recordFormatRejected,
                "version_unsupported": recordVersionRejected,
                "identity_missing_or_mismatch": recordIdentityRejected,
                "schema_invalid": recordSchemaRejected,
                "non_finite": recordFiniteRejected,
                "duplicate_observation": recordDuplicateRejected,
                "pose_invalid": recordPoseRejected,
                "node_binding_failed": recordNodeBindingRejected,
            ],
            "rejected_details": rejectedDetails.map {
                ["record_index": $0.recordIndex, "reason": $0.reason]
            },
        ]
    }
}

// MARK: - Records

/// A normalized, strict-parsed tag observation. `rawPositionM` is nil for
/// unlocalized observations; `boundNodeID`/`boundNodeDelta` come from the
/// node-timebase binding (V1R4 §13.2/§13.3). V1R5 §5.4 adds the durable
/// burst linkage: `burstID`/`frameID` are the identity of the verified
/// complete burst this observation belongs to (nil on legacy records,
/// which can never reach ACCEPTED).
struct TagObservationEvidenceObservation: Equatable {
    var observationID: String
    var barcode: String
    var symbology: String
    var floorID: String
    var frameTimestamp: Double
    var nodeTimebaseTimestamp: Double
    var rawPositionM: (Double, Double, Double)?
    var measurementConfidence: Double
    var localizationState: String
    var localizationConfidence: Double
    var needsReview: Bool
    var trackingSessionID: String
    var boundNodeID: Int64?
    var boundNodeDelta: Double?
    /// V1R5 §6.4: distance to the second-best binding candidate. The
    /// binding is only accepted when `boundNodeDelta <= frozen threshold`
    /// AND `secondBest - bound > ambiguity margin` (exact node binding).
    var secondCandidateDelta: Double?
    /// V1R5 §5.4: verified-burst linkage (nil on legacy records).
    var burstID: String?
    var frameID: String?

    static func == (lhs: Self, rhs: Self) -> Bool {
        return lhs.observationID == rhs.observationID
            && lhs.barcode == rhs.barcode
            && lhs.symbology == rhs.symbology
            && lhs.floorID == rhs.floorID
            && lhs.frameTimestamp == rhs.frameTimestamp
            && lhs.nodeTimebaseTimestamp == rhs.nodeTimebaseTimestamp
            && lhs.rawPositionM?.0 == rhs.rawPositionM?.0
            && lhs.rawPositionM?.1 == rhs.rawPositionM?.1
            && lhs.rawPositionM?.2 == rhs.rawPositionM?.2
            && lhs.measurementConfidence == rhs.measurementConfidence
            && lhs.localizationState == rhs.localizationState
            && lhs.localizationConfidence == rhs.localizationConfidence
            && lhs.needsReview == rhs.needsReview
            && lhs.trackingSessionID == rhs.trackingSessionID
            && lhs.boundNodeID == rhs.boundNodeID
            && lhs.boundNodeDelta == rhs.boundNodeDelta
            && lhs.secondCandidateDelta == rhs.secondCandidateDelta
            && lhs.burstID == rhs.burstID
            && lhs.frameID == rhs.frameID
    }
}

// MARK: - Errors / result

/// File-level failures (write anomaly) fail the parse closed; record-level
/// rejections are audited per record.
enum TagObservationEvidenceParseError: Error, LocalizedError {
    case fileTooLarge(Int)
    case recordTooLarge(Int)
    case tooManyRecords(Int)
    case fileUnreadable(String)

    var errorDescription: String? {
        switch self {
        case .fileTooLarge(let bytes):
            return "价签观测证据文件超限：\(bytes) bytes"
        case .recordTooLarge(let bytes):
            return "价签观测单条记录超限：\(bytes) bytes"
        case .tooManyRecords(let count):
            return "价签观测记录数超限：\(count)"
        case .fileUnreadable(let detail):
            return "价签观测证据文件不可读：\(detail)"
        }
    }
}

struct TagObservationEvidenceParseResult {
    let observations: [TagObservationEvidenceObservation]
    /// Distinct node IDs bound by the strict parser; used to pin the
    /// adaptive skeleton so tag-bound nodes survive reconstruction (§13).
    let boundNodeIDs: [Int64]
    let audit: TagObservationEvidenceAudit
    /// True when every record passed (no rejections of any kind).
    var clean: Bool { audit.rejectedDetails.isEmpty }
}

// MARK: - Strict parser

/// Strict streaming parser for `tag_observations.jsonl` (V1R4 §13.2).
///
/// Real write-side schema (PriorMapLocalizationCore.PriorMapTagObservation
/// Record, JSONEncoder snake_case keys):
/// - required: format/version/observation_id/timestamp/payload/symbology/
///   normalized_bounds/frame_timestamp/node_timebase_frame_timestamp/
///   node_timebase_offset_seconds/pose_timestamp_delta_ms/alignment_*/
///   measurement_method/measurement_confidence/depth_sample_count/
///   depth_inlier_count/depth_inlier_ratio/localization_state/
///   localization_confidence/prior_map_id/prior_map_sha256/floor_id/
///   tracking_session_id/needs_review
/// - optional (absent when nil): raw_map_position, depth_median_m,
///   depth_mad_m, plane_residual_m, surface_normal_camera
///
/// Rules: chunked line parse with size/line/count limits, final newline,
/// strict format/version, exact identity (prior_map_id/prior_map_sha256/
/// tracking_session_id/floor_id), finite-only scalars, known-field
/// whitelist (unknown policy = reject), duplicate observation_id
/// rejection, raw-pose sanity, and node-timebase binding to the snapshot
/// node inventory with a 1.0 s gate. Every rejected record is audited
/// with a stable code — never silently dropped.
enum TagObservationEvidenceParser {

    /// Exact snake_case field set of the frozen v1 write schema. Unknown
    /// fields are rejected (unknown policy) so a schema drift can never
    /// silently pass.
    private static let knownFields: Set<String> = [
        "format", "version", "observation_id", "timestamp", "payload",
        "symbology", "normalized_bounds", "frame_timestamp",
        "node_timebase_frame_timestamp", "node_timebase_offset_seconds",
        "pose_timestamp_delta_ms", "alignment_version",
        "alignment_snapshot_timestamp", "alignment_age_ms",
        "alignment_version_lag", "alignment_freshness",
        "raw_map_position", "measurement_method", "measurement_confidence",
        "depth_sample_count", "depth_inlier_count", "depth_inlier_ratio",
        "depth_median_m", "depth_mad_m", "plane_residual_m",
        "surface_normal_camera", "localization_state",
        "localization_confidence", "prior_map_id", "prior_map_sha256",
        "floor_id", "tracking_session_id", "needs_review",
        "burst_id", "frame_id",
    ]

    static func parse(
        snapshotDirectory: URL,
        nodes: [AbsolutePriorEvidenceNode],
        priorMapID: String,
        priorMapSHA256: String,
        trackingSessionID: String,
        floorID: String,
        verifiedBursts: TagObservationBurstEvidenceParseResult? = nil
    ) throws -> TagObservationEvidenceParseResult {
        var audit = TagObservationEvidenceAudit()
        let url = snapshotDirectory
            .appendingPathComponent("tag_observations.jsonl")
        guard FileManager.default.fileExists(atPath: url.path) else {
            return TagObservationEvidenceParseResult(
                observations: [], boundNodeIDs: [], audit: audit)
        }
        let attributes = try FileManager.default
            .attributesOfItem(atPath: url.path)
        let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard fileSize <= Int64(TagObservationEvidenceLimits.maximumFileBytes) else {
            throw TagObservationEvidenceParseError.fileTooLarge(Int(fileSize))
        }
        // V1R5 §6.3: shared streaming JSONL reader (64 KiB chunks, strict
        // final newline, no blank lines, bounded line) — the file is
        // never loaded as one String.
        let framing: StrictJSONLStreamReader.ParsedLines
        do {
            framing = try StrictJSONLStreamReader.readLines(
                from: url,
                maximumLineBytes: TagObservationEvidenceLimits.maximumRecordBytes,
                maximumLineCount: TagObservationEvidenceLimits.maximumRecords)
        } catch let error as StrictJSONLStreamReader.StreamError {
            throw TagObservationEvidenceParseError.fileUnreadable(
                error.localizedDescription)
        }
        // Node stamps sorted once; every record binds via binary search
        // (V1R4 §13.3: O(N log N) overall).
        let sortedStamps = nodes.map { $0.stamp }.sorted()
        let sortedNodes = nodes.sorted { $0.stamp < $1.stamp }

        var observations: [TagObservationEvidenceObservation] = []
        var boundIDs = Set<Int64>()
        var seenObservationIDs = Set<String>()
        for (offset, line) in framing.lines.enumerated() {
            let recordIndex = offset + 1
            audit.recordTotal += 1
            guard line.utf8.count <= TagObservationEvidenceLimits
                .maximumRecordBytes else {
                throw TagObservationEvidenceParseError.recordTooLarge(
                    line.utf8.count)
            }
            let object: [String: Any]
            do {
                object = try StrictJSONLStreamReader.strictObject(
                    from: line, lineNumber: recordIndex)
            } catch {
                reject(&audit, recordIndex: recordIndex,
                       reason: "invalid_json",
                       counter: \.recordSchemaRejected)
                continue
            }

            guard object["format"] as? String
                == "MarketScannerPriceTagObservation" else {
                reject(&audit, recordIndex: recordIndex,
                       reason: "format_invalid",
                       counter: \.recordFormatRejected)
                continue
            }
            // V1R5 §6.1: strict integer — a fractional number or a
            // numeric Bool can never pass as version 1.
            guard StrictJSONScalar.integer(object["version"]) == 1 else {
                reject(&audit, recordIndex: recordIndex,
                       reason: "version_unsupported",
                       counter: \.recordVersionRejected)
                continue
            }
            // Unknown policy: any field outside the frozen schema is a
            // schema drift and rejects the record.
            let unknown = object.keys.filter { !knownFields.contains($0) }
            guard unknown.isEmpty else {
                reject(&audit, recordIndex: recordIndex,
                       reason: "unknown_field_\(unknown.sorted().joined(separator: ","))",
                       counter: \.recordSchemaRejected)
                continue
            }
            // Identity: required and exact (fail-closed).
            guard (object["prior_map_id"] as? String) == priorMapID,
                  (object["prior_map_sha256"] as? String) == priorMapSHA256,
                  (object["tracking_session_id"] as? String)
                    == trackingSessionID,
                  let recordFloorID = object["floor_id"] as? String,
                  recordFloorID == floorID else {
                reject(&audit, recordIndex: recordIndex,
                       reason: "identity_missing_or_mismatch",
                       counter: \.recordIdentityRejected)
                continue
            }
            // Required scalar schema (V1R5 §6.1 strict typed reads).
            guard let observationID = nonEmptyString(
                    object["observation_id"]),
                  let barcode = nonEmptyString(object["payload"]),
                  let symbology = nonEmptyString(object["symbology"]),
                  let state = nonEmptyString(object["localization_state"]),
                  let frameTimestamp = StrictJSONScalar.number(
                      object["frame_timestamp"]),
                  let nodeTimebaseTimestamp = StrictJSONScalar.number(
                      object["node_timebase_frame_timestamp"]),
                  let timestamp = StrictJSONScalar.number(object["timestamp"]),
                  StrictJSONScalar.number(
                      object["node_timebase_offset_seconds"]) != nil,
                  StrictJSONScalar.number(
                      object["pose_timestamp_delta_ms"]) != nil,
                  let measurementConfidence = boundedDouble(
                      object["measurement_confidence"],
                      upperBound: TagObservationEvidenceLimits.maximumConfidence),
                  let localizationConfidence = boundedDouble(
                      object["localization_confidence"],
                      upperBound: TagObservationEvidenceLimits.maximumConfidence),
                  boundedDouble(
                      object["depth_inlier_ratio"],
                      upperBound: TagObservationEvidenceLimits.maximumDepthInlierRatio) != nil else {
                reject(&audit, recordIndex: recordIndex,
                       reason: "schema_or_finite_invalid",
                       counter: \.recordSchemaRejected)
                continue
            }
            _ = timestamp
            // V1R5 §6.1: strict JSON Bool — a numeric 0/1 must never
            // bridge into `needs_review` (review B-04).
            guard let needsReview = StrictJSONScalar.boolean(
                object["needs_review"]) else {
                reject(&audit, recordIndex: recordIndex,
                       reason: "needs_review_missing",
                       counter: \.recordSchemaRejected)
                continue
            }
            // normalized_bounds: exactly 4 finite elements in [0, 2].
            guard let bounds = object["normalized_bounds"] as? [Any],
                  bounds.count == 4,
                  bounds.allSatisfy({
                      boundedDouble(
                          $0,
                          upperBound: TagObservationEvidenceLimits
                            .maximumNormalizedBoundsDimension) != nil
                  }) else {
                reject(&audit, recordIndex: recordIndex,
                       reason: "normalized_bounds_invalid",
                       counter: \.recordSchemaRejected)
                continue
            }
            // Optional depth/normal fields: type-check when present.
            if let depthMedian = object["depth_median_m"],
               StrictJSONScalar.number(depthMedian) == nil {
                reject(&audit, recordIndex: recordIndex,
                       reason: "depth_median_invalid",
                       counter: \.recordSchemaRejected)
                continue
            }
            if let depthMad = object["depth_mad_m"],
               StrictJSONScalar.number(depthMad) == nil {
                reject(&audit, recordIndex: recordIndex,
                       reason: "depth_mad_invalid",
                       counter: \.recordSchemaRejected)
                continue
            }
            if let planeResidual = object["plane_residual_m"],
               StrictJSONScalar.number(planeResidual) == nil {
                reject(&audit, recordIndex: recordIndex,
                       reason: "plane_residual_invalid",
                       counter: \.recordSchemaRejected)
                continue
            }
            // V1R5 §6.2 (review B-04): a valid surface normal is EXACTLY
            // three finite elements. Two finite values or a trio with one
            // non-finite member are invalid — the V1R4 condition
            // (`count < 3, !allSatisfy`) wrongly passed both. A field
            // present with the WRONG type is also rejected (never
            // silently skipped).
            if object["surface_normal_camera"] != nil {
                guard let normal = object["surface_normal_camera"] as? [Any],
                      normal.count == 3,
                      normal.allSatisfy({ StrictJSONScalar.number($0) != nil }) else {
                    reject(&audit, recordIndex: recordIndex,
                           reason: "surface_normal_invalid",
                           counter: \.recordSchemaRejected)
                    continue
                }
            }
            // Duplicate observation_id.
            guard seenObservationIDs.insert(observationID).inserted else {
                reject(&audit, recordIndex: recordIndex,
                       reason: "duplicate_observation_id",
                       counter: \.recordDuplicateRejected)
                continue
            }
            // Raw pose consistency (V1R4 §13.2): present -> finite and
            // sane; absent -> valid unlocalized evidence.
            let rawPositionM: (Double, Double, Double)?
            if let raw = object["raw_map_position"] as? [String: Any] {
                guard let xM = StrictJSONScalar.number(raw["x_m"]),
                      let yM = StrictJSONScalar.number(raw["y_m"]),
                      abs(xM) <= TagObservationEvidenceLimits
                        .maximumRawPositionM,
                      abs(yM) <= TagObservationEvidenceLimits
                        .maximumRawPositionM,
                      let heightM = finiteDoubleOrNil(raw["height_m"]) else {
                    reject(&audit, recordIndex: recordIndex,
                           reason: "raw_pose_invalid",
                           counter: \.recordPoseRejected)
                    continue
                }
                rawPositionM = (xM, yM, heightM)
            } else {
                rawPositionM = nil
                audit.recordUnlocalizedSkipped += 1
            }
            // Node-timebase binding with the 1.0 s gate (binary search)
            // and the second-candidate margin (V1R5 §6.4).
            guard let binding = nearestNodeBinding(
                nodes: sortedNodes,
                stamps: sortedStamps,
                stamp: nodeTimebaseTimestamp) else {
                reject(&audit, recordIndex: recordIndex,
                       reason: "node_binding_failed",
                       counter: \.recordNodeBindingRejected)
                continue
            }
            guard binding.delta <= TagObservationEvidenceLimits
                .maximumNodeTimeDeltaSeconds else {
                reject(&audit, recordIndex: recordIndex,
                       reason: "node_time_delta_exceeded",
                       counter: \.recordNodeBindingRejected)
                continue
            }
            guard binding.secondDelta - binding.delta
                > TagObservationEvidenceLimits.minimumNodeMarginSeconds else {
                reject(&audit, recordIndex: recordIndex,
                       reason: "node_binding_ambiguous",
                       counter: \.recordNodeBindingRejected)
                continue
            }
            // V1R5 §5.4: every observation usable for ACCEPTED must
            // belong to a verified complete burst with consistent
            // barcode/floor/session and a timestamp inside the burst
            // range. A missing burst (legacy records) or a mismatch
            // rejects the observation fail-closed.
            let burstID = object["burst_id"] as? String
            let frameID = object["frame_id"] as? String
            var burstVerified = false
            if let burstID, !burstID.isEmpty,
               let bursts = verifiedBursts,
               let burst = bursts.byBurstID[burstID] {
                burstVerified = burst.trackingSessionID == trackingSessionID
                    && burst.floorID == recordFloorID
                    && burst.barcode == barcode
                    && frameTimestamp >= burst.firstFrameTimestamp
                    && frameTimestamp <= burst.lastFrameTimestamp
                    // V1R5 §5.4: the claimed frame must be a VERIFIED
                    // burst frame — a frame id outside the burst (e.g. a
                    // duplicate-frame observation rejected by the phone
                    // aggregator) can never pass the gate.
                    && (frameID.map { burst.frameIDs.contains($0) } ?? false)
                    && binding.node.nodeID >= (burst.boundNodeIDs.first ?? Int64.min)
                    && binding.node.nodeID <= (burst.boundNodeIDs.last ?? Int64.max)
            }
            guard burstVerified else {
                reject(&audit, recordIndex: recordIndex,
                       reason: "observation_not_in_verified_burst",
                       counter: \.recordNodeBindingRejected)
                continue
            }
            boundIDs.insert(binding.node.nodeID)
            observations.append(TagObservationEvidenceObservation(
                observationID: observationID,
                barcode: barcode,
                symbology: symbology,
                floorID: recordFloorID,
                frameTimestamp: frameTimestamp,
                nodeTimebaseTimestamp: nodeTimebaseTimestamp,
                rawPositionM: rawPositionM,
                measurementConfidence: measurementConfidence,
                localizationState: state,
                localizationConfidence: localizationConfidence,
                needsReview: needsReview,
                trackingSessionID: trackingSessionID,
                boundNodeID: binding.node.nodeID,
                boundNodeDelta: binding.delta,
                secondCandidateDelta: binding.secondDelta,
                burstID: burstID,
                frameID: frameID))
            audit.recordAccepted += 1
            if observations.count > TagObservationEvidenceLimits.maximumRecords {
                throw TagObservationEvidenceParseError.tooManyRecords(
                    observations.count)
            }
        }
        return TagObservationEvidenceParseResult(
            observations: observations,
            boundNodeIDs: boundIDs.sorted(),
            audit: audit)
    }

    // MARK: - Helpers

    private static func reject(
        _ audit: inout TagObservationEvidenceAudit,
        recordIndex: Int,
        reason: String,
        counter: WritableKeyPath<TagObservationEvidenceAudit, Int>
    ) {
        audit[keyPath: counter] += 1
        audit.rejectedDetails.append(TagObservationRejectedDetail(
            recordIndex: recordIndex, reason: reason))
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String, !string.isEmpty else {
            return nil
        }
        return string
    }

    /// V1R5 §6.1: strict finite JSON number via the shared scalar helper
    /// (never a Bool, never non-finite).
    private static func finiteDouble(_ value: Any?) -> Double? {
        return StrictJSONScalar.number(value)
    }

    private static func finiteDoubleOrNil(_ value: Any?) -> Double? {
        guard let value else { return nil }
        return finiteDouble(value)
    }

    private static func boundedDouble(
        _ value: Any?,
        upperBound: Double,
        lowerBound: Double = 0
    ) -> Double? {
        guard let double = finiteDouble(value),
              double >= lowerBound, double <= upperBound else {
            return nil
        }
        return double
    }

    /// Nearest node by stamp via binary search over the pre-sorted stamps
    /// (V1R4 §13.3). The binding reports the distance to the second-best
    /// candidate so the caller can enforce the V1R5 §6.4 ambiguity margin.
    private static func nearestNodeBinding(
        nodes: [AbsolutePriorEvidenceNode],
        stamps: [Double],
        stamp: Double
    ) -> (node: AbsolutePriorEvidenceNode, delta: Double, secondDelta: Double)? {
        guard !stamps.isEmpty else { return nil }
        var lower = 0
        var upper = stamps.count - 1
        while lower < upper {
            let mid = (lower + upper) / 2
            if stamps[mid] < stamp {
                lower = mid + 1
            } else {
                upper = mid
            }
        }
        // Candidates: lower-1, lower (lower+1 when within epsilon tie).
        var bestIndex = lower
        var bestDelta = abs(stamps[lower] - stamp)
        var secondDelta = Double.infinity
        if lower > 0 {
            let previous = abs(stamps[lower - 1] - stamp)
            if previous < bestDelta {
                secondDelta = bestDelta
                bestIndex = lower - 1
                bestDelta = previous
            } else {
                secondDelta = min(secondDelta, previous)
            }
        }
        if lower + 1 < stamps.count {
            let next = abs(stamps[lower + 1] - stamp)
            if next < bestDelta {
                secondDelta = bestDelta
                bestIndex = lower + 1
                bestDelta = next
            } else {
                secondDelta = min(secondDelta, next)
            }
        }
        // Ambiguity: another node within the stamp epsilon.
        if bestIndex > 0,
           abs(stamps[bestIndex - 1] - stamp) - bestDelta
                <= TagObservationEvidenceLimits.stampEpsilon {
            return nil
        }
        if bestIndex + 1 < stamps.count,
           abs(stamps[bestIndex + 1] - stamp) - bestDelta
                <= TagObservationEvidenceLimits.stampEpsilon {
            return nil
        }
        if !secondDelta.isFinite {
            secondDelta = bestDelta
        }
        return (nodes[bestIndex], bestDelta, secondDelta)
    }
}
