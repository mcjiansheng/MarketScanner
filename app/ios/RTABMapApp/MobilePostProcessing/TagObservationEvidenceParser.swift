import Foundation

enum TagObservationEvidenceLimits {
    static let maximumFileBytes =
        GeneratedMobileEvidenceContracts.File_tag_observations_jsonl.max_file_bytes
    static let maximumRecordBytes =
        GeneratedMobileEvidenceContracts.File_tag_observations_jsonl.max_record_bytes
    static let maximumRecords =
        GeneratedMobileEvidenceContracts.File_tag_observations_jsonl.max_records
    static let maximumNodeTimeDeltaSeconds = 1.0
    static let minimumNodeMarginSeconds = 0.01
    static let stampEpsilon = 1.0e-6
    static let maximumRawPositionM = 5_000.0
    static let maximumRawHeightM = 100.0
    static let maximumPoseDeltaMs = 60_000.0
    static let numericTolerance = 1.0e-6
    /// Exact rejection counters are unbounded integers; verbose per-line
    /// diagnostics are capped to keep hostile-input memory deterministic.
    static let maximumRejectedDetails = 1_024
}

struct TagObservationRejectedDetail: Equatable {
    let recordIndex: Int
    let reason: String
}

struct TagObservationEvidenceAudit: Equatable {
    var recordTotal = 0
    var recordAccepted = 0
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
        recordFormatRejected + recordVersionRejected
            + recordIdentityRejected + recordSchemaRejected
            + recordFiniteRejected + recordDuplicateRejected
            + recordPoseRejected + recordNodeBindingRejected
    }

    var clean: Bool { totalRejected == 0 }

    func reportPayload() -> [String: Any] {
        [
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
            "rejected_details_truncated": totalRejected
                > rejectedDetails.count,
        ]
    }
}

/// Strict typed evidence retained through the final quality pipeline. Older
/// call sites may omit the new quality fields because every one has a safe
/// default; the production parser always supplies the validated values.
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
    var secondCandidateDelta: Double?
    var burstID: String?
    var frameID: String?
    var timestamp: Double = 0
    var nodeTimebaseOffsetSeconds: Double = 0
    var poseTimestampDeltaMs: Double = 0
    var alignmentVersion: Int = 0
    var alignmentSnapshotTimestamp: Double = 0
    var alignmentAgeMs: Double = 0
    var alignmentVersionLag: Int = 0
    var alignmentFreshness: String = "timestamp_stale"
    var measurementMethod: String = "unavailable"
    var depthSampleCount: Int = 0
    var depthInlierCount: Int = 0
    var depthInlierRatio: Double = 0
    var depthMedianM: Double? = nil
    var depthMadM: Double? = nil
    var planeResidualM: Double? = nil
    var surfaceNormalCamera: [Double]? = nil

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.observationID == rhs.observationID
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
            && lhs.timestamp == rhs.timestamp
            && lhs.nodeTimebaseOffsetSeconds == rhs.nodeTimebaseOffsetSeconds
            && lhs.poseTimestampDeltaMs == rhs.poseTimestampDeltaMs
            && lhs.alignmentVersion == rhs.alignmentVersion
            && lhs.alignmentSnapshotTimestamp == rhs.alignmentSnapshotTimestamp
            && lhs.alignmentAgeMs == rhs.alignmentAgeMs
            && lhs.alignmentVersionLag == rhs.alignmentVersionLag
            && lhs.alignmentFreshness == rhs.alignmentFreshness
            && lhs.measurementMethod == rhs.measurementMethod
            && lhs.depthSampleCount == rhs.depthSampleCount
            && lhs.depthInlierCount == rhs.depthInlierCount
            && lhs.depthInlierRatio == rhs.depthInlierRatio
            && lhs.depthMedianM == rhs.depthMedianM
            && lhs.depthMadM == rhs.depthMadM
            && lhs.planeResidualM == rhs.planeResidualM
            && lhs.surfaceNormalCamera == rhs.surfaceNormalCamera
    }
}

enum TagObservationEvidenceParseError: Error, LocalizedError {
    case fileTooLarge(Int)
    case recordTooLarge(Int)
    case tooManyRecords(Int)
    case fileUnreadable(String)
    case unconsumedBurstFrames(Int)

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
        case .unconsumedBurstFrames(let count):
            return "价签 burst 存在 \(count) 个未被 observation 精确消费的 frame"
        }
    }
}

struct TagObservationEvidenceParseResult {
    let observations: [TagObservationEvidenceObservation]
    let boundNodeIDs: [Int64]
    let audit: TagObservationEvidenceAudit
    var clean: Bool { audit.clean }
}

private struct StrictTagObservationDTO {
    let observationID: String
    let timestamp: Double
    let barcode: String
    let symbology: String
    let frameTimestamp: Double
    let nodeTimestamp: Double
    let nodeOffset: Double
    let poseDeltaMs: Double
    let alignmentVersion: Int
    let alignmentSnapshotTimestamp: Double
    let alignmentAgeMs: Double
    let alignmentVersionLag: Int
    let alignmentFreshness: String
    let rawPosition: (Double, Double, Double)?
    let hasPlanarPosition: Bool
    let method: String
    let measurementConfidence: Double
    let depthSampleCount: Int
    let depthInlierCount: Int
    let depthInlierRatio: Double
    let depthMedianM: Double?
    let depthMadM: Double?
    let planeResidualM: Double?
    let surfaceNormal: [Double]?
    let localizationState: String
    let localizationConfidence: Double
    let needsReview: Bool
    let burstID: String
    let frameID: String
}

private struct TagSchemaFailure: Error {
    let reason: String
    let category: TagSchemaFailureCategory
}

private enum TagSchemaFailureCategory: Equatable {
    case schema
    case pose
}

enum TagObservationEvidenceParser {
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
        "floor_id", "tracking_session_id", "needs_review", "burst_id",
        "frame_id",
    ]
    private static let rawPositionKeys: Set<String> = ["x_m", "y_m", "height_m"]
    private static let allowedMethods: Set<String> = [
        "smoothed_scene_depth", "scene_depth", "shelf_plane_ray", "unavailable",
    ]
    private static let allowedStates: Set<String> = [
        "uninitialized", "initializing", "stable", "usable", "recovering",
        "weak", "lost", "manualCorrection",
    ]
    private static let allowedFreshness: Set<String> = [
        "fresh", "aging", "version_stale", "timestamp_stale",
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
        let url = snapshotDirectory.appendingPathComponent("tag_observations.jsonl")
        guard FileManager.default.fileExists(atPath: url.path) else {
            let unconsumed = verifiedBursts?.remainingFrameCount ?? 0
            guard unconsumed == 0 else {
                throw TagObservationEvidenceParseError.unconsumedBurstFrames(unconsumed)
            }
            return TagObservationEvidenceParseResult(
                observations: [], boundNodeIDs: [], audit: audit)
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard fileSize <= TagObservationEvidenceLimits.maximumFileBytes else {
            throw TagObservationEvidenceParseError.fileTooLarge(fileSize)
        }

        let sortedNodes = nodes.sorted { $0.stamp < $1.stamp }
        let sortedStamps = sortedNodes.map(\.stamp)
        var observations: [TagObservationEvidenceObservation] = []
        var boundIDs = Set<Int64>()
        var seenObservationIDs: Set<String>? = verifiedBursts == nil
            ? Set<String>() : nil

        do {
            _ = try StrictJSONLStreamReader.forEachLine(
                from: url,
                limits: .init(
                    maximumFileBytes: TagObservationEvidenceLimits.maximumFileBytes,
                    maximumLineBytes: TagObservationEvidenceLimits.maximumRecordBytes,
                    maximumLineCount: TagObservationEvidenceLimits.maximumRecords)
            ) { line in
                audit.recordTotal += 1
                let object: [String: Any]
                do {
                    object = try StrictJSONLStreamReader.strictObject(
                        from: line.text, lineNumber: line.number)
                } catch {
                    reject(&audit, line.number, "invalid_json", \.recordSchemaRejected)
                    return
                }
                guard object["format"] as? String
                    == "MarketScannerPriceTagObservation" else {
                    reject(&audit, line.number, "format_invalid", \.recordFormatRejected)
                    return
                }
                guard StrictJSONScalar.integer(object["version"]) == 1 else {
                    reject(&audit, line.number, "version_unsupported", \.recordVersionRejected)
                    return
                }
                guard object.keys.allSatisfy(knownFields.contains) else {
                    let unknown = object.keys.filter { !knownFields.contains($0) }.sorted()
                    reject(
                        &audit, line.number,
                        "unknown_field_\(unknown.joined(separator: ","))",
                        \.recordSchemaRejected)
                    return
                }
                guard object["prior_map_id"] as? String == priorMapID,
                      object["prior_map_sha256"] as? String == priorMapSHA256,
                      object["tracking_session_id"] as? String == trackingSessionID,
                      object["floor_id"] as? String == floorID else {
                    reject(&audit, line.number, "identity_missing_or_mismatch", \.recordIdentityRejected)
                    return
                }

                let dto: StrictTagObservationDTO
                do {
                    dto = try decode(object)
                } catch let failure as TagSchemaFailure {
                    let counter: WritableKeyPath<TagObservationEvidenceAudit, Int> =
                        failure.category == .pose
                            ? \.recordPoseRejected : \.recordSchemaRejected
                    reject(&audit, line.number, failure.reason, counter)
                    return
                }
                if seenObservationIDs != nil,
                   !seenObservationIDs!.insert(dto.observationID).inserted {
                    reject(
                        &audit, line.number, "duplicate_observation_id",
                        \.recordDuplicateRejected)
                    return
                }
                guard let binding = nearestNodeBinding(
                    nodes: sortedNodes, stamps: sortedStamps, stamp: dto.nodeTimestamp) else {
                    reject(&audit, line.number, "node_binding_failed", \.recordNodeBindingRejected)
                    return
                }
                guard binding.delta <= TagObservationEvidenceLimits.maximumNodeTimeDeltaSeconds else {
                    reject(&audit, line.number, "node_time_delta_exceeded", \.recordNodeBindingRejected)
                    return
                }
                guard binding.secondDelta - binding.delta
                    > TagObservationEvidenceLimits.minimumNodeMarginSeconds else {
                    reject(&audit, line.number, "node_binding_ambiguous", \.recordNodeBindingRejected)
                    return
                }

                guard let bursts = verifiedBursts else {
                    reject(
                        &audit, line.number, "observation_has_no_verified_burst",
                        \.recordNodeBindingRejected)
                    return
                }
                let expected: VerifiedTagBurstFrame
                switch bursts.frame(for: dto.observationID) {
                case .available(let frame):
                    expected = frame
                case .alreadyConsumed:
                    reject(
                        &audit, line.number, "duplicate_observation_id",
                        \.recordDuplicateRejected)
                    return
                case .missing:
                    reject(
                        &audit, line.number, "observation_frame_exact_mismatch",
                        \.recordNodeBindingRejected)
                    return
                }
                guard let expectedBurst = bursts.burst(
                        at: expected.burstIndex),
                      expectedBurst.burstID == dto.burstID,
                      expected.frameID == dto.frameID,
                      expected.boundNodeID == binding.node.nodeID,
                      expected.frameTimestamp == dto.frameTimestamp,
                      expected.nodeTimestamp == dto.nodeTimestamp,
                      expectedBurst.barcode == dto.barcode,
                      expectedBurst.symbology == dto.symbology,
                      expectedBurst.priorMapID == priorMapID,
                      expectedBurst.priorMapSHA256 == priorMapSHA256,
                      expectedBurst.floorID == floorID,
                      expectedBurst.trackingSessionID == trackingSessionID,
                      expected.depth == dto.depthInlierRatio,
                      expected.matches(
                        view: view(from: dto.surfaceNormal),
                        tracking: dto.localizationState),
                      expected.confidence == dto.localizationConfidence else {
                    reject(
                        &audit, line.number, "observation_frame_exact_mismatch",
                        \.recordNodeBindingRejected)
                    return
                }
                guard bursts.consumeFrame(
                    observationID: dto.observationID) else {
                    reject(&audit, line.number, "frame_consumed_twice", \.recordDuplicateRejected)
                    return
                }

                if dto.rawPosition == nil { audit.recordUnlocalizedSkipped += 1 }
                boundIDs.insert(binding.node.nodeID)
                observations.append(TagObservationEvidenceObservation(
                    observationID: dto.observationID,
                    barcode: dto.barcode,
                    symbology: dto.symbology,
                    floorID: floorID,
                    frameTimestamp: dto.frameTimestamp,
                    nodeTimebaseTimestamp: dto.nodeTimestamp,
                    rawPositionM: dto.rawPosition,
                    measurementConfidence: dto.measurementConfidence,
                    localizationState: dto.localizationState,
                    localizationConfidence: dto.localizationConfidence,
                    needsReview: dto.needsReview,
                    trackingSessionID: trackingSessionID,
                    boundNodeID: binding.node.nodeID,
                    boundNodeDelta: binding.delta,
                    secondCandidateDelta: binding.secondDelta,
                    burstID: dto.burstID,
                    frameID: dto.frameID,
                    timestamp: dto.timestamp,
                    nodeTimebaseOffsetSeconds: dto.nodeOffset,
                    poseTimestampDeltaMs: dto.poseDeltaMs,
                    alignmentVersion: dto.alignmentVersion,
                    alignmentSnapshotTimestamp: dto.alignmentSnapshotTimestamp,
                    alignmentAgeMs: dto.alignmentAgeMs,
                    alignmentVersionLag: dto.alignmentVersionLag,
                    alignmentFreshness: dto.alignmentFreshness,
                    measurementMethod: dto.method,
                    depthSampleCount: dto.depthSampleCount,
                    depthInlierCount: dto.depthInlierCount,
                    depthInlierRatio: dto.depthInlierRatio,
                    depthMedianM: dto.depthMedianM,
                    depthMadM: dto.depthMadM,
                    planeResidualM: dto.planeResidualM,
                    surfaceNormalCamera: dto.surfaceNormal))
                audit.recordAccepted += 1
            }
        } catch let error as TagObservationEvidenceParseError {
            throw error
        } catch let error as StrictJSONLStreamReader.StreamError {
            throw TagObservationEvidenceParseError.fileUnreadable(
                error.localizedDescription)
        }

        let remainingFrameCount = verifiedBursts?.remainingFrameCount ?? 0
        guard remainingFrameCount == 0 else {
            throw TagObservationEvidenceParseError.unconsumedBurstFrames(
                remainingFrameCount)
        }
        return TagObservationEvidenceParseResult(
            observations: observations,
            boundNodeIDs: boundIDs.sorted(),
            audit: audit)
    }

    private static func decode(_ object: [String: Any]) throws
        -> StrictTagObservationDTO {
        func fail(_ reason: String, _ category: TagSchemaFailureCategory = .schema)
            throws -> Never {
            throw TagSchemaFailure(reason: reason, category: category)
        }
        guard let observationID = nonEmptyString(object["observation_id"]),
              let timestamp = StrictJSONScalar.number(object["timestamp"]),
              let barcode = nonEmptyString(object["payload"]),
              let symbology = nonEmptyString(object["symbology"]),
              let frameTimestamp = StrictJSONScalar.number(object["frame_timestamp"]),
              let nodeTimestamp = StrictJSONScalar.number(
                object["node_timebase_frame_timestamp"]),
              let nodeOffset = StrictJSONScalar.number(
                object["node_timebase_offset_seconds"]),
              let poseDelta = bounded(
                object["pose_timestamp_delta_ms"], 0,
                TagObservationEvidenceLimits.maximumPoseDeltaMs),
              let alignmentVersion = StrictJSONScalar.integer(object["alignment_version"]),
              alignmentVersion > 0,
              let alignmentSnapshot = StrictJSONScalar.number(
                object["alignment_snapshot_timestamp"]),
              let alignmentAge = bounded(
                object["alignment_age_ms"], 0,
                TagObservationEvidenceLimits.maximumPoseDeltaMs),
              let versionLag = StrictJSONScalar.integer(object["alignment_version_lag"]),
              versionLag >= 0, versionLag < alignmentVersion,
              let freshness = nonEmptyString(object["alignment_freshness"]),
              allowedFreshness.contains(freshness),
              let method = nonEmptyString(object["measurement_method"]),
              allowedMethods.contains(method),
              let measurementConfidence = bounded(object["measurement_confidence"], 0, 1),
              let sampleCount = StrictJSONScalar.integer(object["depth_sample_count"]),
              sampleCount >= 0,
              let inlierCount = StrictJSONScalar.integer(object["depth_inlier_count"]),
              inlierCount >= 0, inlierCount <= sampleCount,
              let inlierRatio = bounded(object["depth_inlier_ratio"], 0, 1),
              let state = nonEmptyString(object["localization_state"]),
              allowedStates.contains(state),
              let localizationConfidence = bounded(object["localization_confidence"], 0, 1),
              let needsReview = StrictJSONScalar.boolean(object["needs_review"]),
              let burstID = nonEmptyString(object["burst_id"]),
              let frameID = nonEmptyString(object["frame_id"]) else {
            try fail("schema_or_finite_invalid")
        }
        guard abs(frameTimestamp + nodeOffset - nodeTimestamp)
            <= TagObservationEvidenceLimits.numericTolerance else {
            try fail("node_timebase_invariant_invalid")
        }
        let recomputedAge = abs(frameTimestamp - alignmentSnapshot) * 1_000
        guard approximatelyEqual(recomputedAge, alignmentAge),
              approximatelyEqual(poseDelta, alignmentAge) else {
            try fail("alignment_age_or_pose_delta_invalid")
        }
        let expectedFreshness: String
        if alignmentAge <= 250, versionLag == 0 { expectedFreshness = "fresh" }
        else if alignmentAge <= 600, versionLag == 0 { expectedFreshness = "aging" }
        else if versionLag > 0 { expectedFreshness = "version_stale" }
        else { expectedFreshness = "timestamp_stale" }
        guard freshness == expectedFreshness,
              (freshness != "aging" || state == "weak"),
              (!freshness.hasSuffix("stale") || state == "lost") else {
            try fail("alignment_freshness_inconsistent")
        }
        guard let bounds = object["normalized_bounds"] as? [Any],
              bounds.count == 4,
              let x = bounded(bounds[0], 0, 1),
              let y = bounded(bounds[1], 0, 1),
              let width = bounded(bounds[2], 0, 1),
              let height = bounded(bounds[3], 0, 1),
              width > 0, height > 0,
              x + width <= 1 + TagObservationEvidenceLimits.numericTolerance,
              y + height <= 1 + TagObservationEvidenceLimits.numericTolerance else {
            try fail("normalized_bounds_invalid")
        }

        let expectedRatio = sampleCount == 0
            ? 0 : Double(inlierCount) / Double(sampleCount)
        guard approximatelyEqual(inlierRatio, expectedRatio) else {
            try fail("depth_count_ratio_inconsistent")
        }
        let depthMedian = try optionalNumber(
            object, key: "depth_median_m", minimum: 0.2, maximum: 8.0)
        let depthMad = try optionalNumber(
            object, key: "depth_mad_m", minimum: 0, maximum: 8.0)
        let planeResidual = try optionalNumber(
            object, key: "plane_residual_m", minimum: 0, maximum: 8.0)
        if sampleCount == 0,
           depthMedian != nil || depthMad != nil || planeResidual != nil {
            try fail("depth_optional_without_samples")
        }

        let surfaceNormal: [Double]?
        if object.keys.contains("surface_normal_camera") {
            guard let rawNormal = object["surface_normal_camera"] as? [Any],
                  rawNormal.count == 3 else {
                try fail("surface_normal_invalid")
            }
            let normal = rawNormal.compactMap(StrictJSONScalar.number)
            guard normal.count == 3,
                  abs(sqrt(normal.reduce(0) { $0 + $1 * $1 }) - 1)
                    <= 1.0e-3 else {
                try fail("surface_normal_not_unit")
            }
            surfaceNormal = normal
        } else {
            surfaceNormal = nil
        }

        var rawPosition: (Double, Double, Double)?
        var hasPlanarPosition = false
        if object.keys.contains("raw_map_position") {
            guard let raw = object["raw_map_position"] as? [String: Any],
                  raw.keys.allSatisfy(rawPositionKeys.contains),
                  let xM = bounded(
                    raw["x_m"], -TagObservationEvidenceLimits.maximumRawPositionM,
                    TagObservationEvidenceLimits.maximumRawPositionM),
                  let yM = bounded(
                    raw["y_m"], -TagObservationEvidenceLimits.maximumRawPositionM,
                    TagObservationEvidenceLimits.maximumRawPositionM) else {
                try fail("raw_pose_invalid", .pose)
            }
            hasPlanarPosition = true
            if raw.keys.contains("height_m") {
                guard let heightM = bounded(
                    raw["height_m"], -TagObservationEvidenceLimits.maximumRawHeightM,
                    TagObservationEvidenceLimits.maximumRawHeightM) else {
                    try fail("raw_height_invalid", .pose)
                }
                rawPosition = (xM, yM, heightM)
            } else {
                // Height is genuinely optional. Planar evidence remains valid,
                // but it cannot be resolved into an automatic 3D tag.
                rawPosition = nil
            }
        }
        guard (method == "unavailable") == !hasPlanarPosition else {
            try fail("measurement_method_position_inconsistent", .pose)
        }
        if method == "unavailable" {
            guard measurementConfidence == 0 else {
                try fail("unavailable_measurement_confidence_invalid")
            }
        }
        if !needsReview {
            guard state == "stable", freshness == "fresh",
                  rawPosition != nil, method != "unavailable",
                  measurementConfidence >= 0.65 else {
                try fail("automatic_accept_invariant_invalid")
            }
        }

        return StrictTagObservationDTO(
            observationID: observationID,
            timestamp: timestamp,
            barcode: barcode,
            symbology: symbology,
            frameTimestamp: frameTimestamp,
            nodeTimestamp: nodeTimestamp,
            nodeOffset: nodeOffset,
            poseDeltaMs: poseDelta,
            alignmentVersion: alignmentVersion,
            alignmentSnapshotTimestamp: alignmentSnapshot,
            alignmentAgeMs: alignmentAge,
            alignmentVersionLag: versionLag,
            alignmentFreshness: freshness,
            rawPosition: rawPosition,
            hasPlanarPosition: hasPlanarPosition,
            method: method,
            measurementConfidence: measurementConfidence,
            depthSampleCount: sampleCount,
            depthInlierCount: inlierCount,
            depthInlierRatio: inlierRatio,
            depthMedianM: depthMedian,
            depthMadM: depthMad,
            planeResidualM: planeResidual,
            surfaceNormal: surfaceNormal,
            localizationState: state,
            localizationConfidence: localizationConfidence,
            needsReview: needsReview,
            burstID: burstID,
            frameID: frameID)
    }

    private static func optionalNumber(
        _ object: [String: Any],
        key: String,
        minimum: Double,
        maximum: Double
    ) throws -> Double? {
        guard object.keys.contains(key) else { return nil }
        guard let value = bounded(object[key], minimum, maximum) else {
            throw TagSchemaFailure(
                reason: "\(key)_invalid", category: .schema)
        }
        return value
    }

    private static func bounded(
        _ value: Any?, _ minimum: Double, _ maximum: Double
    ) -> Double? {
        guard let number = StrictJSONScalar.number(value),
              number >= minimum, number <= maximum else { return nil }
        return number
    }

    private static func approximatelyEqual(_ lhs: Double, _ rhs: Double) -> Bool {
        abs(lhs - rhs) <= TagObservationEvidenceLimits.numericTolerance
    }

    private static func view(from normal: [Double]?) -> String {
        guard let normal, normal.count == 3 else { return "unknown" }
        if normal[2] < 0 { return "front" }
        if normal[2] > 0 { return "back" }
        return "unknown"
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        return string
    }

    private static func reject(
        _ audit: inout TagObservationEvidenceAudit,
        _ recordIndex: Int,
        _ reason: String,
        _ counter: WritableKeyPath<TagObservationEvidenceAudit, Int>
    ) {
        audit[keyPath: counter] += 1
        if audit.rejectedDetails.count
            < TagObservationEvidenceLimits.maximumRejectedDetails {
            audit.rejectedDetails.append(TagObservationRejectedDetail(
                recordIndex: recordIndex, reason: reason))
        }
    }

    /// Complete nearest/second-nearest selection around the binary-search
    /// insertion point. A one-node inventory has no imaginary second tie.
    private static func nearestNodeBinding(
        nodes: [AbsolutePriorEvidenceNode],
        stamps: [Double],
        stamp: Double
    ) -> (node: AbsolutePriorEvidenceNode, delta: Double, secondDelta: Double)? {
        guard !nodes.isEmpty else { return nil }
        var lower = 0
        var upper = stamps.count
        while lower < upper {
            let mid = (lower + upper) / 2
            if stamps[mid] < stamp { lower = mid + 1 }
            else { upper = mid }
        }
        var candidates = Set<Int>()
        for index in [lower - 2, lower - 1, lower, lower + 1]
            where index >= 0 && index < stamps.count {
            candidates.insert(index)
        }
        var ranked: [(index: Int, delta: Double)] = []
        ranked.reserveCapacity(candidates.count)
        for index in candidates {
            ranked.append((index: index, delta: abs(stamps[index] - stamp)))
        }
        ranked.sort { lhs, rhs in
            if lhs.delta == rhs.delta { return lhs.index < rhs.index }
            return lhs.delta < rhs.delta
        }
        guard let best = ranked.first else { return nil }
        let second = ranked.dropFirst().first?.delta ?? Double.infinity
        guard second - best.delta > TagObservationEvidenceLimits.stampEpsilon else {
            return nil
        }
        return (nodes[best.index], best.delta, second)
    }
}
