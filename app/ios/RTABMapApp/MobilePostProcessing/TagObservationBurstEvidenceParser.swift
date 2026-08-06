import Foundation

// MARK: - Frame sample

/// One frame sample inside a durable tag burst (V1R5 §5.2). Frame
/// identity is captured on the phone; the node binding (bound_node_id)
/// is resolved by the PC-side strict burst parser through the node
/// timebase, so it is not part of the phone schema. The type lives here
/// (Foundation-only) so the strict burst parser and the Swift host suite
/// can compile it without the UIKit app target.
struct TagBurstFrameSample: Codable, Equatable {
    let frameId: String
    let frameTimestamp: TimeInterval
    let nodeTimebaseTimestamp: TimeInterval
    let observationId: String

    enum CodingKeys: String, CodingKey {
        case frameId = "frame_id"
        case frameTimestamp = "frame_timestamp"
        case nodeTimebaseTimestamp = "node_timebase_timestamp"
        case observationId = "observation_id"
    }
}

// MARK: - Limits

/// File / record gates for `tag_observation_bursts.jsonl` (V1R5 §5.3).
/// The record budget is sized for the product ceiling of 200k tag
/// observations; bursts are far fewer than observations, and the shared
/// StrictJSONLStreamReader keeps memory bounded to one line at a time.
enum TagObservationBurstEvidenceLimits {
    /// One burst line (including frame_samples) can be a few hundred KB
    /// for a long burst; the contract derives from real samples and a
    /// safety factor (§4).
    static let maximumFileBytes = 256 * 1024 * 1024
    static let maximumRecordBytes = 4 * 1024 * 1024
    static let maximumRecords = 200_000
    static let maximumFrameSamplesPerBurst = 10_000
    /// Node-timebase binding gate (identical to the observation parser).
    static let maximumNodeTimeDeltaSeconds = 1.0
    static let stampEpsilon = 1.0e-6
}

// MARK: - Audit

/// Per-record rejection with a stable code; every rejection is counted
/// and surfaced — never silently dropped (V1R5 §5.3).
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
        return recordFormatRejected + recordVersionRejected
            + recordIdentityRejected + recordSchemaRejected
            + recordDuplicateBurstRejected + recordDuplicateFrameRejected
            + recordIncompleteRejected + recordNodeBindingRejected
    }

    var clean: Bool { rejectedDetails.isEmpty }
}

// MARK: - Records

/// One verified burst (V1R5 §5.3): every observation that may reach
/// ACCEPTED must belong to exactly one of these.
struct VerifiedTagBurst: Equatable {
    var burstID: String
    var sequence: Int
    var barcode: String
    var symbology: String
    var floorID: String
    var trackingSessionID: String
    var frameIDs: [String]
    var uniqueFrameCount: Int
    var firstFrameTimestamp: Double
    var lastFrameTimestamp: Double
    var nodeTimebaseMin: Double
    var nodeTimebaseMax: Double
    var depthQuality: Double
    var viewAngle: String
    var trackingQuality: String
    var localizationConfidenceMean: Double
    var complete: Bool
    var frameSamples: [TagBurstFrameSample]
    var rawSamples: [PriorMapTagPoint3D]
    /// Distinct snapshot-DB nodes the burst spans (resolved through the
    /// node-timebase binding; V1R5 §5.4 "bound node 位于 burst node
    /// range").
    var boundNodeIDs: [Int64]
}

struct TagObservationBurstEvidenceParseResult {
    let bursts: [VerifiedTagBurst]
    /// burst_id -> verified burst for O(1) observation linkage.
    let byBurstID: [String: VerifiedTagBurst]
    let audit: TagObservationBurstEvidenceAudit
    /// True when every record passed and every burst is complete.
    var clean: Bool {
        return audit.clean && bursts.allSatisfy { $0.complete }
    }
}

// MARK: - Errors

enum TagObservationBurstEvidenceParseError: Error, LocalizedError {
    case fileTooLarge(Int)
    case fileUnreadable(String)
    case framing(String)
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
        case .expectedCountMismatch(let actual, let expected):
            return "价签 burst 计数不匹配：\(actual) != metadata \(expected)"
        case .expectedLastIDMismatch(let actual, let expected):
            return "价签 burst 最后 ID 不匹配：'\(actual ?? "nil")' != '\(expected ?? "nil")'"
        }
    }
}

// MARK: - Strict parser

/// Strict streaming parser for `tag_observation_bursts.jsonl`
/// (V1R5 §5.3).
///
/// Contract:
/// - streaming JSONL via the shared strict reader (64 KiB chunks, final
///   newline, no blank lines, bounded line);
/// - strict schema: unknown fields reject, strict Bool/Int/finite;
/// - identity exact: format/version/tracking_session_id/floor_id;
/// - burst id unique and sequence strictly increasing;
/// - frame ids unique inside one burst and frame_count == unique frames;
/// - every burst `complete == true` (a durable-complete gate);
/// - metadata watermark cross-check: count and last burst id must match
///   exactly (missing metadata watermarks fail closed, never default 0);
/// - node binding: every frame sample binds to an exact snapshot node
///   through the node timebase with the frozen 1.0 s delta gate.
enum TagObservationBurstEvidenceParser {

    /// Exact snake_case field set of the frozen v1 write schema.
    private static let knownFields: Set<String> = [
        "format", "version", "burst_id", "sequence", "barcode",
        "symbology", "floor_id", "frame_count", "first_frame_timestamp",
        "last_frame_timestamp", "node_timebase_min", "node_timebase_max",
        "depth_quality", "view_angle", "tracking_quality",
        "localization_confidence_mean", "raw_3d_samples",
        "tracking_session_id", "complete", "frame_ids", "frame_samples",
    ]
    private static let frameSampleKeys: Set<String> = [
        "frame_id", "frame_timestamp", "node_timebase_timestamp",
        "observation_id",
    ]
    private static let rawSampleKeys: Set<String> = [
        "x_m", "y_m", "height_m",
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
        let url = snapshotDirectory
            .appendingPathComponent("tag_observation_bursts.jsonl")
        guard FileManager.default.fileExists(atPath: url.path) else {
            // No burst sidecar: no verified bursts exist. When metadata
            // watermarks demand bursts, the caller must fail (checked in
            // the snapshot eligibility / pipeline, not here).
            return TagObservationBurstEvidenceParseResult(
                bursts: [], byBurstID: [:],
                audit: TagObservationBurstEvidenceAudit())
        }
        let attributes = try FileManager.default
            .attributesOfItem(atPath: url.path)
        let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard fileSize <= Int64(TagObservationBurstEvidenceLimits.maximumFileBytes) else {
            throw TagObservationBurstEvidenceParseError.fileTooLarge(
                Int(fileSize))
        }
        let framing: StrictJSONLStreamReader.ParsedLines
        do {
            framing = try StrictJSONLStreamReader.readLines(
                from: url,
                maximumLineBytes: TagObservationBurstEvidenceLimits.maximumRecordBytes,
                maximumLineCount: TagObservationBurstEvidenceLimits.maximumRecords)
        } catch let error as StrictJSONLStreamReader.StreamError {
            throw TagObservationBurstEvidenceParseError.framing(
                error.localizedDescription)
        }

        // Node stamps sorted once; every frame binds via binary search.
        let sortedStamps = nodes.map { $0.stamp }.sorted()
        let sortedNodes = nodes.sorted { $0.stamp < $1.stamp }

        var audit = TagObservationBurstEvidenceAudit()
        var bursts: [VerifiedTagBurst] = []
        var byBurstID: [String: VerifiedTagBurst] = [:]
        var seenBurstIDs = Set<String>()
        var previousSequence: Int?

        for (offset, line) in framing.lines.enumerated() {
            let recordIndex = offset + 1
            audit.recordTotal += 1
            guard line.utf8.count <= TagObservationBurstEvidenceLimits.maximumRecordBytes else {
                reject(&audit, recordIndex: recordIndex,
                       reason: "record_too_large", counter: \.recordSchemaRejected)
                continue
            }
            let object: [String: Any]
            do {
                object = try StrictJSONLStreamReader.strictObject(
                    from: line, lineNumber: recordIndex)
            } catch {
                reject(&audit, recordIndex: recordIndex,
                       reason: "invalid_json", counter: \.recordSchemaRejected)
                continue
            }
            guard object["format"] as? String == "MarketScannerPriceTagBurst" else {
                reject(&audit, recordIndex: recordIndex,
                       reason: "format_invalid", counter: \.recordFormatRejected)
                continue
            }
            guard StrictJSONScalar.integer(object["version"]) == 1 else {
                reject(&audit, recordIndex: recordIndex,
                       reason: "version_unsupported", counter: \.recordVersionRejected)
                continue
            }
            // Unknown policy: schema drift rejects the record.
            let unknown = object.keys.filter { !knownFields.contains($0) }
            guard unknown.isEmpty else {
                reject(&audit, recordIndex: recordIndex,
                       reason: "unknown_field_\(unknown.sorted().joined(separator: ","))",
                       counter: \.recordSchemaRejected)
                continue
            }
            // Identity: required and exact.
            guard (object["tracking_session_id"] as? String) == trackingSessionID,
                  let recordFloorID = object["floor_id"] as? String,
                  recordFloorID == floorID,
                  let burstID = object["burst_id"] as? String,
                  !burstID.isEmpty else {
                reject(&audit, recordIndex: recordIndex,
                       reason: "identity_missing_or_mismatch",
                       counter: \.recordIdentityRejected)
                continue
            }
            // Burst id unique; sequence strictly increasing.
            guard seenBurstIDs.insert(burstID).inserted else {
                reject(&audit, recordIndex: recordIndex,
                       reason: "duplicate_burst_id",
                       counter: \.recordDuplicateBurstRejected)
                continue
            }
            guard let sequence = StrictJSONScalar.integer(object["sequence"]),
                  sequence > 0 else {
                reject(&audit, recordIndex: recordIndex,
                       reason: "sequence_invalid", counter: \.recordSchemaRejected)
                continue
            }
            if let previous = previousSequence {
                guard sequence > previous else {
                    reject(&audit, recordIndex: recordIndex,
                           reason: "sequence_not_increasing",
                           counter: \.recordDuplicateBurstRejected)
                    continue
                }
            }
            previousSequence = sequence
            // Strict scalars.
            guard let barcode = nonEmptyString(object["barcode"]),
                  let symbology = nonEmptyString(object["symbology"]),
                  let frameCount = StrictJSONScalar.integer(object["frame_count"]),
                  frameCount >= 0,
                  let firstFrame = StrictJSONScalar.number(object["first_frame_timestamp"]),
                  let lastFrame = StrictJSONScalar.number(object["last_frame_timestamp"]),
                  let nodeMin = StrictJSONScalar.number(object["node_timebase_min"]),
                  let nodeMax = StrictJSONScalar.number(object["node_timebase_max"]),
                  let depthQuality = StrictJSONScalar.number(object["depth_quality"]),
                  depthQuality >= 0, depthQuality <= 1,
                  let viewAngle = nonEmptyString(object["view_angle"]),
                  let trackingQuality = nonEmptyString(object["tracking_quality"]),
                  let confidenceMean = StrictJSONScalar.number(object["localization_confidence_mean"]),
                  confidenceMean >= 0, confidenceMean <= 1 else {
                reject(&audit, recordIndex: recordIndex,
                       reason: "schema_invalid", counter: \.recordSchemaRejected)
                continue
            }
            // Strict Bool: never a numeric 0/1 (V1R5 §6.1).
            guard let complete = StrictJSONScalar.boolean(object["complete"]) else {
                reject(&audit, recordIndex: recordIndex,
                       reason: "complete_missing_or_not_boolean",
                       counter: \.recordSchemaRejected)
                continue
            }
            guard complete else {
                // A burst that was never durably completed cannot verify
                // any observation (V1R5 §5.5 durable complete gate).
                reject(&audit, recordIndex: recordIndex,
                       reason: "burst_incomplete",
                       counter: \.recordIncompleteRejected)
                continue
            }
            // Frame identity: array of unique ids; frame samples exact.
            guard let rawFrameIDs = object["frame_ids"] as? [Any],
                  rawFrameIDs.count == frameCount,
                  let frameSamples = object["frame_samples"] as? [Any] else {
                reject(&audit, recordIndex: recordIndex,
                       reason: "frame_identity_missing",
                       counter: \.recordSchemaRejected)
                continue
            }
            var frameIDs: [String] = []
            var frameIDSet = Set<String>()
            for raw in rawFrameIDs {
                guard let frameID = raw as? String, !frameID.isEmpty,
                      frameIDSet.insert(frameID).inserted else {
                    reject(&audit, recordIndex: recordIndex,
                           reason: "duplicate_or_invalid_frame_id",
                           counter: \.recordDuplicateFrameRejected)
                    break
                }
                frameIDs.append(frameID)
            }
            guard frameIDs.count == frameCount else { continue }
            guard frameSamples.count == frameCount,
                  frameSamples.count <= TagObservationBurstEvidenceLimits
                    .maximumFrameSamplesPerBurst else {
                reject(&audit, recordIndex: recordIndex,
                       reason: "frame_samples_count_mismatch",
                       counter: \.recordSchemaRejected)
                continue
            }
            var parsedSamples: [TagBurstFrameSample] = []
            var sampleFrameIDs = Set<String>()
            var parseFailed = false
            for rawSample in frameSamples {
                guard let sample = rawSample as? [String: Any],
                      let sampleFrameID = sample["frame_id"] as? String,
                      sampleFrameIDSetOK(sampleFrameID, set: &sampleFrameIDs),
                      let frameTimestamp = StrictJSONScalar.number(sample["frame_timestamp"]),
                      let nodeTimestamp = StrictJSONScalar.number(sample["node_timebase_timestamp"]),
                      let observationID = nonEmptyString(sample["observation_id"]) else {
                    reject(&audit, recordIndex: recordIndex,
                           reason: "frame_sample_invalid",
                           counter: \.recordSchemaRejected)
                    parseFailed = true
                    break
                }
                let unknownSample = sample.keys.filter {
                    !frameSampleKeys.contains($0)
                }
                guard unknownSample.isEmpty else {
                    reject(&audit, recordIndex: recordIndex,
                           reason: "frame_sample_unknown_field",
                           counter: \.recordSchemaRejected)
                    parseFailed = true
                    break
                }
                parsedSamples.append(TagBurstFrameSample(
                    frameId: sampleFrameID,
                    frameTimestamp: frameTimestamp,
                    nodeTimebaseTimestamp: nodeTimestamp,
                    observationId: observationID))
            }
            if parseFailed { continue }
            // Sample frame ids must equal the declared frame_ids set.
            guard sampleFrameIDs == frameIDSet else {
                reject(&audit, recordIndex: recordIndex,
                       reason: "frame_sample_identity_mismatch",
                       counter: \.recordSchemaRejected)
                continue
            }
            // Raw 3D samples (optional; a present field with the WRONG
            // type is rejected — never silently skipped).
            var rawSamples: [PriorMapTagPoint3D] = []
            if object["raw_3d_samples"] != nil {
                guard let rawArray = object["raw_3d_samples"] as? [Any] else {
                    reject(&audit, recordIndex: recordIndex,
                           reason: "raw_samples_type_invalid",
                           counter: \.recordSchemaRejected)
                    continue
                }
                for raw in rawArray {
                    guard let rawObject = raw as? [String: Any],
                          rawObject.keys.allSatisfy({ rawSampleKeys.contains($0) }),
                          let xM = StrictJSONScalar.number(rawObject["x_m"]),
                          let yM = StrictJSONScalar.number(rawObject["y_m"]) else {
                        reject(&audit, recordIndex: recordIndex,
                               reason: "raw_sample_invalid",
                               counter: \.recordSchemaRejected)
                        parseFailed = true
                        break
                    }
                    let heightM = rawObject["height_m"].flatMap {
                        StrictJSONScalar.number($0)
                    }
                    rawSamples.append(PriorMapTagPoint3D(
                        xM: xM, yM: yM, heightM: heightM))
                }
                if parseFailed { continue }
            }
            // Bound node ids via the node-timebase binding of every frame
            // sample (binary search; delta <= frozen threshold). A frame
            // that cannot bind rejects the whole burst (V1R5 §5.4).
            var boundNodeIDs = Set<Int64>()
            var bindingFailed = false
            for sample in parsedSamples {
                guard let binding = nearestNodeBinding(
                    nodes: sortedNodes,
                    stamps: sortedStamps,
                    stamp: sample.nodeTimebaseTimestamp) else {
                    bindingFailed = true
                    break
                }
                guard binding.delta <= TagObservationBurstEvidenceLimits
                    .maximumNodeTimeDeltaSeconds else {
                    bindingFailed = true
                    break
                }
                boundNodeIDs.insert(binding.node.nodeID)
            }
            if bindingFailed {
                reject(&audit, recordIndex: recordIndex,
                       reason: "node_binding_failed",
                       counter: \.recordNodeBindingRejected)
                continue
            }
            let burst = VerifiedTagBurst(
                burstID: burstID,
                sequence: sequence,
                barcode: barcode,
                symbology: symbology,
                floorID: recordFloorID,
                trackingSessionID: trackingSessionID,
                frameIDs: frameIDs,
                uniqueFrameCount: frameCount,
                firstFrameTimestamp: firstFrame,
                lastFrameTimestamp: lastFrame,
                nodeTimebaseMin: nodeMin,
                nodeTimebaseMax: nodeMax,
                depthQuality: depthQuality,
                viewAngle: viewAngle,
                trackingQuality: trackingQuality,
                localizationConfidenceMean: confidenceMean,
                complete: true,
                frameSamples: parsedSamples,
                rawSamples: rawSamples,
                boundNodeIDs: boundNodeIDs.sorted())
            bursts.append(burst)
            byBurstID[burstID] = burst
            audit.recordAccepted += 1
        }

        // Metadata watermark cross-check (V1R5 §5.3): exact count and
        // exact last burst id. Missing watermarks fail closed.
        if let expected = expectedBurstCount {
            guard bursts.count == expected else {
                throw TagObservationBurstEvidenceParseError
                    .expectedCountMismatch(bursts.count, expected)
            }
        }
        if let expected = expectedLastBurstID {
            let actual = bursts.last?.burstID
            guard actual == expected else {
                throw TagObservationBurstEvidenceParseError
                    .expectedLastIDMismatch(actual, expected)
            }
        }
        return TagObservationBurstEvidenceParseResult(
            bursts: bursts, byBurstID: byBurstID, audit: audit)
    }

    // MARK: - Helpers

    private static func sampleFrameIDSetOK(
        _ frameID: String,
        set: inout Set<String>
    ) -> Bool {
        return !frameID.isEmpty && set.insert(frameID).inserted
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String, !string.isEmpty else {
            return nil
        }
        return string
    }

    private static func reject(
        _ audit: inout TagObservationBurstEvidenceAudit,
        recordIndex: Int,
        reason: String,
        counter: WritableKeyPath<TagObservationBurstEvidenceAudit, Int>
    ) {
        audit[keyPath: counter] += 1
        audit.rejectedDetails.append(TagBurstRejectedDetail(
            recordIndex: recordIndex, reason: reason))
    }

    /// Nearest node by stamp via binary search over the pre-sorted
    /// stamps; a tie within the stamp epsilon is ambiguous and rejected.
    private static func nearestNodeBinding(
        nodes: [AbsolutePriorEvidenceNode],
        stamps: [Double],
        stamp: Double
    ) -> (node: AbsolutePriorEvidenceNode, delta: Double)? {
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
        var bestIndex = lower
        var bestDelta = abs(stamps[lower] - stamp)
        if lower > 0 {
            let previous = abs(stamps[lower - 1] - stamp)
            if previous < bestDelta {
                bestIndex = lower - 1
                bestDelta = previous
            }
        }
        if lower + 1 < stamps.count {
            let next = abs(stamps[lower + 1] - stamp)
            if next < bestDelta {
                bestIndex = lower + 1
                bestDelta = next
            }
        }
        if bestIndex > 0,
           abs(stamps[bestIndex - 1] - stamp) - bestDelta
                <= TagObservationBurstEvidenceLimits.stampEpsilon {
            return nil
        }
        if bestIndex + 1 < stamps.count,
           abs(stamps[bestIndex + 1] - stamp) - bestDelta
                <= TagObservationBurstEvidenceLimits.stampEpsilon {
            return nil
        }
        return (nodes[bestIndex], bestDelta)
    }
}
