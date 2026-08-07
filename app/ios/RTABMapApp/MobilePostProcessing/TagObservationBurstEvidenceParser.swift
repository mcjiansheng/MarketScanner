import Foundation

// MARK: - Burst v2 records

/// One authoritative frame inside a durable burst. The writer captures the
/// exact graph-node binding at observation time; readers never infer a node
/// from a summary range or fall back to a timestamp-only resolver.
struct TagBurstFrameSample: Codable, Equatable {
    let frameId: String
    let observationId: String
    let boundNodeId: Int64
    let frameTimestamp: TimeInterval
    let nodeTimestamp: TimeInterval
    let depth: Double
    let view: String
    let tracking: String
    let confidence: Double

    enum CodingKeys: String, CodingKey {
        case frameId = "frame_id"
        case observationId = "observation_id"
        case boundNodeId = "bound_node_id"
        case frameTimestamp = "frame_timestamp"
        case nodeTimestamp = "node_timestamp"
        case depth
        case view
        case tracking
        case confidence
    }
}

enum TagObservationBurstEvidenceLimits {
    static let maximumFileBytes =
        GeneratedMobileEvidenceContracts.File_tag_observation_bursts_jsonl
            .max_file_bytes
    static let maximumRecordBytes =
        GeneratedMobileEvidenceContracts.File_tag_observation_bursts_jsonl
            .max_record_bytes
    static let maximumRecords =
        GeneratedMobileEvidenceContracts.File_tag_observation_bursts_jsonl
            .max_records
    static let maximumFrameSamplesPerBurst =
        GeneratedMobileEvidenceContracts.ProductScale.maxTagObservations
    static let maximumNodeTimeDeltaSeconds = 1.0
    static let numericTolerance = 1.0e-6
    /// Audit counters remain exact; only detailed strings are capped so a
    /// hostile 200k-record file cannot allocate 200k diagnostic objects.
    static let maximumRejectedDetails = 1_024
}

struct TagBurstRejectedDetail: Equatable {
    let recordIndex: Int
    let reason: String
}

struct TagObservationBurstEvidenceAudit: Equatable {
    var recordTotal = 0
    var recordAccepted = 0
    var recordFormatRejected = 0
    var recordVersionRejected = 0
    var recordIdentityRejected = 0
    var recordSchemaRejected = 0
    var recordDuplicateBurstRejected = 0
    var recordDuplicateFrameRejected = 0
    var recordIncompleteRejected = 0
    var recordNodeBindingRejected = 0
    var rejectedDetails: [TagBurstRejectedDetail] = []

    var totalRejected: Int {
        recordFormatRejected + recordVersionRejected
            + recordIdentityRejected + recordSchemaRejected
            + recordDuplicateBurstRejected + recordDuplicateFrameRejected
            + recordIncompleteRejected + recordNodeBindingRejected
    }

    var clean: Bool { totalRejected == 0 }
}

struct VerifiedTagBurst: Equatable {
    var burstID: String
    var sequence: Int
    var barcode: String
    var symbology: String
    var priorMapID: String
    var priorMapSHA256: String
    var floorID: String
    var trackingSessionID: String
    var uniqueFrameCount: Int
    var firstFrameTimestamp: Double
    var lastFrameTimestamp: Double
    var boundNodeIDMin: Int64
    var boundNodeIDMax: Int64
    var depthQuality: Double
    var viewAngle: String
    var trackingQuality: String
    var localizationConfidenceMean: Double
    var complete: Bool
}

struct VerifiedTagBurstFrame: Equatable {
    /// Index into `TagObservationBurstEvidenceParseResult.bursts`. Shared
    /// burst/map/session identity is stored once per burst, not repeated in
    /// every one of up to 200k frame dictionary values.
    let burstIndex: Int
    let sample: TagBurstFrameSample
}

final class TagObservationBurstEvidenceParseResult {
    struct StoredFrame {
        let frame: VerifiedTagBurstFrame
        var consumed: Bool
    }

    enum FrameLookup {
        case available(VerifiedTagBurstFrame)
        case alreadyConsumed
        case missing
    }

    let bursts: [VerifiedTagBurst]
    let audit: TagObservationBurstEvidenceAudit
    let frameCount: Int
    /// The only full-frame index retained after burst parsing. Consumption
    /// is one bit in the dictionary value, so exact duplicate/unconsumed
    /// checks do not allocate separate 200k-entry sets.
    private var frameByObservationID: [String: StoredFrame]
    private(set) var remainingFrameCount: Int

    init(
        bursts: [VerifiedTagBurst],
        byObservationID: [String: StoredFrame],
        audit: TagObservationBurstEvidenceAudit
    ) {
        self.bursts = bursts
        self.audit = audit
        self.frameCount = byObservationID.count
        self.frameByObservationID = byObservationID
        self.remainingFrameCount = byObservationID.count
    }

    func burst(at index: Int) -> VerifiedTagBurst? {
        guard index >= 0, index < bursts.count else { return nil }
        return bursts[index]
    }

    func frame(for observationID: String) -> FrameLookup {
        guard let stored = frameByObservationID[observationID] else {
            return .missing
        }
        return stored.consumed
            ? .alreadyConsumed : .available(stored.frame)
    }

    @discardableResult
    func consumeFrame(observationID: String) -> Bool {
        guard var stored = frameByObservationID[observationID],
              !stored.consumed else {
            return false
        }
        stored.consumed = true
        frameByObservationID[observationID] = stored
        remainingFrameCount -= 1
        return true
    }

    /// Drops the full exact-match index once every frame has been consumed.
    /// The pipeline calls this before optimization/tag fusion so the 200k
    /// burst index and the 200k parsed observations are not retained for the
    /// rest of the run at the same time.
    @discardableResult
    func releaseConsumedFrames() -> Bool {
        guard remainingFrameCount == 0 else { return false }
        frameByObservationID.removeAll(keepingCapacity: false)
        return true
    }

    var clean: Bool {
        audit.clean && bursts.allSatisfy {
            $0.complete && $0.uniqueFrameCount > 0
        }
    }
}

enum TagObservationBurstEvidenceParseError: Error, LocalizedError {
    case fileTooLarge(Int)
    case fileUnreadable(String)
    case framing(String)
    case expectedCountMissing
    case expectedCountMismatch(Int, Int)
    case expectedLastIDMismatch(String?, String?)

    var errorDescription: String? {
        switch self {
        case .fileTooLarge(let bytes):
            return "价签 burst 证据文件超限：\(bytes) bytes"
        case .fileUnreadable(let detail):
            return "价签 burst 证据文件不可读：\(detail)"
        case .framing(let detail):
            return "价签 burst 证据文件格式错误：\(detail)"
        case .expectedCountMissing:
            return "价签 burst metadata 缺少正式 count watermark"
        case .expectedCountMismatch(let actual, let expected):
            return "价签 burst 计数不匹配：\(actual) != metadata \(expected)"
        case .expectedLastIDMismatch(let actual, let expected):
            return "价签 burst 最后 ID 不匹配：'\(actual ?? "nil")' != '\(expected ?? "nil")'"
        }
    }
}

enum TagObservationBurstEvidenceParser {
    private static let knownFields: Set<String> = [
        "format", "version", "prior_map_id", "prior_map_sha256",
        "tracking_session_id", "floor_id", "burst_id", "sequence",
        "barcode", "symbology", "complete", "frame_count", "frames",
        "first_frame_timestamp", "last_frame_timestamp",
        "bound_node_id_min", "bound_node_id_max", "depth_quality",
        "view_angle", "tracking_quality", "localization_confidence_mean",
    ]
    private static let frameKeys: Set<String> = [
        "frame_id", "observation_id", "bound_node_id", "frame_timestamp",
        "node_timestamp", "depth", "view", "tracking", "confidence",
    ]
    private static let allowedViews: Set<String> = ["front", "back", "unknown"]
    private static let allowedTracking: Set<String> = [
        "uninitialized", "initializing", "stable", "usable", "recovering",
        "weak", "lost", "manualCorrection", "unknown",
    ]

    static func parse(
        snapshotDirectory: URL,
        nodes: [AbsolutePriorEvidenceNode],
        priorMapID: String,
        priorMapSHA256: String,
        trackingSessionID: String,
        floorID: String,
        expectedBurstCount: Int?,
        expectedLastBurstID: String?
    ) throws -> TagObservationBurstEvidenceParseResult {
        guard let expectedBurstCount, expectedBurstCount >= 0 else {
            throw TagObservationBurstEvidenceParseError.expectedCountMissing
        }
        let url = snapshotDirectory
            .appendingPathComponent("tag_observation_bursts.jsonl")
        guard FileManager.default.fileExists(atPath: url.path) else {
            guard expectedBurstCount == 0 else {
                throw TagObservationBurstEvidenceParseError
                    .expectedCountMismatch(0, expectedBurstCount)
            }
            guard expectedLastBurstID == nil else {
                throw TagObservationBurstEvidenceParseError
                    .expectedLastIDMismatch(nil, expectedLastBurstID)
            }
            return TagObservationBurstEvidenceParseResult(
                bursts: [], byObservationID: [:],
                audit: TagObservationBurstEvidenceAudit())
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard fileSize <= TagObservationBurstEvidenceLimits.maximumFileBytes else {
            throw TagObservationBurstEvidenceParseError.fileTooLarge(fileSize)
        }

        var nodeByID: [Int64: AbsolutePriorEvidenceNode] = [:]
        var duplicateNodeIDs = Set<Int64>()
        for node in nodes {
            if nodeByID.updateValue(node, forKey: node.nodeID) != nil {
                duplicateNodeIDs.insert(node.nodeID)
            }
        }

        var audit = TagObservationBurstEvidenceAudit()
        var bursts: [VerifiedTagBurst] = []
        var byObservationID: [
            String: TagObservationBurstEvidenceParseResult.StoredFrame
        ] = [:]
        var seenBurstIDs = Set<String>()
        var seenFrameIDs = Set<String>()
        var previousSequence: Int?

        do {
            _ = try StrictJSONLStreamReader.forEachLine(
                from: url,
                limits: .init(
                    maximumFileBytes: TagObservationBurstEvidenceLimits.maximumFileBytes,
                    maximumLineBytes: TagObservationBurstEvidenceLimits.maximumRecordBytes,
                    maximumLineCount: TagObservationBurstEvidenceLimits.maximumRecords)
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
                guard object.keys.allSatisfy(knownFields.contains) else {
                    reject(&audit, line.number, "unknown_field", \.recordSchemaRejected)
                    return
                }
                guard object["format"] as? String == "MarketScannerPriceTagBurst" else {
                    reject(&audit, line.number, "format_invalid", \.recordFormatRejected)
                    return
                }
                guard StrictJSONScalar.integer(object["version"]) == 2 else {
                    reject(&audit, line.number, "version_unsupported", \.recordVersionRejected)
                    return
                }
                guard object["prior_map_id"] as? String == priorMapID,
                      object["prior_map_sha256"] as? String == priorMapSHA256,
                      object["tracking_session_id"] as? String == trackingSessionID,
                      object["floor_id"] as? String == floorID,
                      let burstID = nonEmptyString(object["burst_id"]) else {
                    reject(&audit, line.number, "identity_missing_or_mismatch", \.recordIdentityRejected)
                    return
                }
                guard seenBurstIDs.insert(burstID).inserted else {
                    reject(&audit, line.number, "duplicate_burst_id", \.recordDuplicateBurstRejected)
                    return
                }
                guard let sequence = StrictJSONScalar.integer(object["sequence"]),
                      sequence > 0,
                      previousSequence.map({ sequence > $0 }) ?? true else {
                    reject(&audit, line.number, "sequence_invalid", \.recordDuplicateBurstRejected)
                    return
                }
                previousSequence = sequence
                guard StrictJSONScalar.boolean(object["complete"]) == true else {
                    reject(&audit, line.number, "burst_incomplete", \.recordIncompleteRejected)
                    return
                }
                guard let barcode = nonEmptyString(object["barcode"]),
                      let symbology = nonEmptyString(object["symbology"]),
                      let declaredCount = StrictJSONScalar.integer(object["frame_count"]),
                      declaredCount >= 1,
                      declaredCount <= TagObservationBurstEvidenceLimits.maximumFrameSamplesPerBurst,
                      let rawFrames = object["frames"] as? [Any],
                      rawFrames.count == declaredCount else {
                    reject(&audit, line.number, "frame_count_or_frames_invalid", \.recordSchemaRejected)
                    return
                }

                var parsedFrames: [TagBurstFrameSample] = []
                parsedFrames.reserveCapacity(rawFrames.count)
                var localFrameIDs = Set<String>()
                var localObservationIDs = Set<String>()
                var frameFailure: String?
                for rawFrame in rawFrames {
                    guard let frame = rawFrame as? [String: Any],
                          frame.keys.allSatisfy(frameKeys.contains),
                          let frameID = nonEmptyString(frame["frame_id"]),
                          let observationID = nonEmptyString(frame["observation_id"]),
                          let boundNodeValue = StrictJSONScalar.integer(frame["bound_node_id"]),
                          boundNodeValue > 0,
                          let frameTimestamp = StrictJSONScalar.number(frame["frame_timestamp"]),
                          let nodeTimestamp = StrictJSONScalar.number(frame["node_timestamp"]),
                          let depth = boundedUnit(frame["depth"]),
                          let view = nonEmptyString(frame["view"]), allowedViews.contains(view),
                          let tracking = nonEmptyString(frame["tracking"]), allowedTracking.contains(tracking),
                          let confidence = boundedUnit(frame["confidence"]) else {
                        frameFailure = "frame_schema_invalid"
                        break
                    }
                    guard localFrameIDs.insert(frameID).inserted,
                          !seenFrameIDs.contains(frameID) else {
                        frameFailure = "duplicate_frame_id"
                        break
                    }
                    guard localObservationIDs.insert(observationID).inserted,
                          byObservationID[observationID] == nil else {
                        frameFailure = "duplicate_observation_id"
                        break
                    }
                    let boundNodeID = Int64(boundNodeValue)
                    guard !duplicateNodeIDs.contains(boundNodeID),
                          let node = nodeByID[boundNodeID],
                          abs(node.stamp - nodeTimestamp)
                            <= TagObservationBurstEvidenceLimits.maximumNodeTimeDeltaSeconds else {
                        frameFailure = "bound_node_invalid"
                        break
                    }
                    parsedFrames.append(TagBurstFrameSample(
                        frameId: frameID,
                        observationId: observationID,
                        boundNodeId: boundNodeID,
                        frameTimestamp: frameTimestamp,
                        nodeTimestamp: nodeTimestamp,
                        depth: depth,
                        view: view,
                        tracking: tracking,
                        confidence: confidence))
                }
                if let frameFailure {
                    let counter: WritableKeyPath<TagObservationBurstEvidenceAudit, Int> =
                        frameFailure == "duplicate_frame_id"
                            || frameFailure == "duplicate_observation_id"
                            ? \.recordDuplicateFrameRejected
                            : frameFailure == "bound_node_invalid"
                                ? \.recordNodeBindingRejected
                                : \.recordSchemaRejected
                    reject(&audit, line.number, frameFailure, counter)
                    return
                }

                guard let declaredFirst = StrictJSONScalar.number(object["first_frame_timestamp"]),
                      let declaredLast = StrictJSONScalar.number(object["last_frame_timestamp"]),
                      let declaredNodeMinValue = StrictJSONScalar.integer(object["bound_node_id_min"]),
                      let declaredNodeMaxValue = StrictJSONScalar.integer(object["bound_node_id_max"]),
                      let declaredDepth = boundedUnit(object["depth_quality"]),
                      let declaredView = nonEmptyString(object["view_angle"]),
                      allowedViews.contains(declaredView),
                      let declaredTracking = nonEmptyString(object["tracking_quality"]),
                      allowedTracking.contains(declaredTracking),
                      let declaredConfidence = boundedUnit(object["localization_confidence_mean"]) else {
                    reject(&audit, line.number, "summary_schema_invalid", \.recordSchemaRejected)
                    return
                }
                let declaredNodeMin = Int64(declaredNodeMinValue)
                let declaredNodeMax = Int64(declaredNodeMaxValue)
                let recomputed = recomputeSummary(parsedFrames)
                guard declaredCount == recomputed.count,
                      approximatelyEqual(declaredFirst, recomputed.firstFrameTimestamp),
                      approximatelyEqual(declaredLast, recomputed.lastFrameTimestamp),
                      declaredNodeMin == recomputed.boundNodeIDMin,
                      declaredNodeMax == recomputed.boundNodeIDMax,
                      approximatelyEqual(declaredDepth, recomputed.depthQuality),
                      declaredView == recomputed.view,
                      declaredTracking == recomputed.tracking,
                      approximatelyEqual(declaredConfidence, recomputed.confidenceMean) else {
                    reject(&audit, line.number, "summary_mismatch", \.recordSchemaRejected)
                    return
                }

                let burstIndex = bursts.count
                let burst = VerifiedTagBurst(
                    burstID: burstID,
                    sequence: sequence,
                    barcode: barcode,
                    symbology: symbology,
                    priorMapID: priorMapID,
                    priorMapSHA256: priorMapSHA256,
                    floorID: floorID,
                    trackingSessionID: trackingSessionID,
                    uniqueFrameCount: recomputed.count,
                    firstFrameTimestamp: recomputed.firstFrameTimestamp,
                    lastFrameTimestamp: recomputed.lastFrameTimestamp,
                    boundNodeIDMin: recomputed.boundNodeIDMin,
                    boundNodeIDMax: recomputed.boundNodeIDMax,
                    depthQuality: recomputed.depthQuality,
                    viewAngle: recomputed.view,
                    trackingQuality: recomputed.tracking,
                    localizationConfidenceMean: recomputed.confidenceMean,
                    complete: true)
                bursts.append(burst)
                for sample in parsedFrames {
                    seenFrameIDs.insert(sample.frameId)
                    byObservationID[sample.observationId] =
                        TagObservationBurstEvidenceParseResult.StoredFrame(
                            frame: VerifiedTagBurstFrame(
                                burstIndex: burstIndex,
                                sample: sample),
                            consumed: false)
                }
                audit.recordAccepted += 1
            }
        } catch let error as StrictJSONLStreamReader.StreamError {
            throw TagObservationBurstEvidenceParseError.framing(
                error.localizedDescription)
        }

        guard bursts.count == expectedBurstCount else {
            throw TagObservationBurstEvidenceParseError
                .expectedCountMismatch(bursts.count, expectedBurstCount)
        }
        let actualLastID = bursts.last?.burstID
        guard actualLastID == expectedLastBurstID else {
            throw TagObservationBurstEvidenceParseError
                .expectedLastIDMismatch(actualLastID, expectedLastBurstID)
        }
        return TagObservationBurstEvidenceParseResult(
            bursts: bursts,
            byObservationID: byObservationID,
            audit: audit)
    }

    static func recomputeSummary(_ frames: [TagBurstFrameSample]) -> (
        count: Int,
        firstFrameTimestamp: Double,
        lastFrameTimestamp: Double,
        boundNodeIDMin: Int64,
        boundNodeIDMax: Int64,
        depthQuality: Double,
        view: String,
        tracking: String,
        confidenceMean: Double
    ) {
        precondition(!frames.isEmpty)
        return (
            count: frames.count,
            firstFrameTimestamp: frames.map(\.frameTimestamp).min()!,
            lastFrameTimestamp: frames.map(\.frameTimestamp).max()!,
            boundNodeIDMin: frames.map(\.boundNodeId).min()!,
            boundNodeIDMax: frames.map(\.boundNodeId).max()!,
            depthQuality: frames.reduce(0) { $0 + $1.depth } / Double(frames.count),
            view: dominantVote(frames.map(\.view)),
            tracking: dominantVote(frames.map(\.tracking)),
            confidenceMean: frames.reduce(0) { $0 + $1.confidence }
                / Double(frames.count))
    }

    /// A tie is deliberately ambiguous. In particular, front never wins a
    /// front/back/unknown tie through ordering or `>=` bias.
    static func dominantVote(_ values: [String]) -> String {
        var counts: [String: Int] = [:]
        values.forEach { counts[$0, default: 0] += 1 }
        guard let maximum = counts.values.max(), maximum > 0 else {
            return "unknown"
        }
        let winners = counts.filter { $0.value == maximum }.map(\.key)
        return winners.count == 1 ? winners[0] : "unknown"
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        return string
    }

    private static func boundedUnit(_ value: Any?) -> Double? {
        guard let number = StrictJSONScalar.number(value),
              number >= 0, number <= 1 else { return nil }
        return number
    }

    private static func approximatelyEqual(_ lhs: Double, _ rhs: Double) -> Bool {
        abs(lhs - rhs) <= TagObservationBurstEvidenceLimits.numericTolerance
    }

    private static func reject(
        _ audit: inout TagObservationBurstEvidenceAudit,
        _ recordIndex: Int,
        _ reason: String,
        _ counter: WritableKeyPath<TagObservationBurstEvidenceAudit, Int>
    ) {
        audit[keyPath: counter] += 1
        if audit.rejectedDetails.count
            < TagObservationBurstEvidenceLimits.maximumRejectedDetails {
            audit.rejectedDetails.append(TagBurstRejectedDetail(
                recordIndex: recordIndex, reason: reason))
        }
    }
}
