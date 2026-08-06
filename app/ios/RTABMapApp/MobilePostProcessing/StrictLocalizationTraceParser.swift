import Foundation

/// Strict streaming parser for `localization_trace.jsonl` (V1R5 §9.6).
///
/// The V1R4 pipeline read the trace with a lenient reader that silently
/// dropped bad lines and defaulted missing fields (review B-09). The
/// trace feeds lost-interval / tracking-state decisions, so a bad line
/// could hide an actually-lost interval and produce a wrong AVAILABLE
/// row. This parser fails closed:
/// - streaming via the shared strict JSONL reader (64 KiB chunks, final
///   newline, no blank lines, bounded line);
/// - strict schema: unknown fields reject, strict Bool/Int/finite;
/// - identity: tracking_session_id / prior_map_id / prior_map_sha256 /
///   floor_id must match the expected run identity;
/// - strict states: localization_state / tracking_state are whitelisted
///   (a default is never substituted);
/// - strictly increasing frame timestamps (monotonic axis);
/// - finite poses only (x_m / y_m / yaw_rad / confidence);
/// - exact count against the metadata watermark
///   (`captureHealth.localizationTraceRecordCount`);
/// - ANY invalid record throws (no "skip and continue").
enum StrictLocalizationTraceParser {

    static let maximumFileBytes = 512 * 1024 * 1024
    static let maximumRecordBytes = 1024 * 1024
    static let maximumRecords = 2_000_000

    enum ParseError: Error, LocalizedError {
        case fileTooLarge(Int)
        case missingFile(String)
        case framing(String)
        case record(Int, String)
        case countMismatch(Int, Int)

        var errorDescription: String? {
            switch self {
            case .fileTooLarge(let bytes):
                return "本地化轨迹证据文件超限：\(bytes) bytes"
            case .missingFile(let detail):
                return "本地化轨迹证据缺失：\(detail)"
            case .framing(let detail):
                return "本地化轨迹证据格式错误：\(detail)"
            case .record(let line, let detail):
                return "本地化轨迹第 \(line) 行无效：\(detail)"
            case .countMismatch(let actual, let expected):
                return "本地化轨迹计数不匹配：\(actual) != metadata \(expected)"
            }
        }
    }

    struct TraceRecord: Equatable {
        var timestamp: Double
        var xM: Double
        var yM: Double
        var yawRad: Double
        var localizationState: String
        var trackingState: String
        var floorID: String
        var nodeTimebaseOffsetSeconds: Double
        var nodeTimebaseTimestamp: Double
        var confidence: Double
    }

    /// Values written by `PriorMapLocalizationPhase` (PriorMapScanMatcher)
    /// and the ARKit tracking state.
    static let localizationStates: Set<String> = [
        "uninitialized", "initializing", "stable", "usable",
        "recovering", "weak", "lost", "manualCorrection",
    ]
    static let trackingStates: Set<String> = [
        "normal", "limited", "unavailable", "unknown",
    ]

    /// Exact field set of the frozen trace schema — the JSONEncoder
    /// default (camelCase) keys of `PriorMapLocalizationUpdate`, which is
    /// the real writer of `localization_trace.jsonl`. Optional fields are
    /// absent when nil.
    private static let knownFields: Set<String> = [
        "format", "version", "timestamp", "trackingState",
        "localizationState", "confidence", "rawPose", "estimatedPose",
        "roadCandidates", "structureSource", "structurePointCount",
        "structureCoverageAngleRad", "matchCandidates",
        "matchUniqueness", "matchResidualCost", "matcherElapsedMs",
        "constraintAccepted", "constraintReason",
        "measurementAccepted", "hypothesisTrusted",
        "correctionStepApplied", "recoveryConvergedThisUpdate",
        "confidenceAccepted", "constraintDisposition",
        "postRecoveryTrustedLocalFrames", "scanSearchPerformed",
        "hypothesisSupportFrames", "hypothesisScoreMargin",
        "recoverySearch", "correctionTranslationM",
        "correctionYawDeg", "mapFromArkitX", "mapFromArkitY",
        "mapFromArkitYawDeg", "selectedHypothesisId",
        "activeHypothesisTrackCount", "hypothesisBestCost",
        "hypothesisSecondCost", "hypothesisReason",
        "hypothesisTrackerElapsedMs", "recoveryEpisodeId",
        "recoveryReason", "recoveryOutcome",
        "recoveryValidAttemptCount", "recoveryRemainingValidAttempts",
        "recoveryElapsedMs", "recoveryFreshSupportFrames",
        "recoveryTriggerCount", "recoveryFinishedAtUptime",
        "recoverySelectedHypothesisId",
        "recoveryFinalResidualTranslationM",
        "recoveryFinalResidualYawDeg",
        "recoveryCorrectionStepAppliedOnCompletionFrame",
        "recoveryCooldownRemainingMs",
        "recoveryAutomaticTriggerSuppressed",
        "recoveryAutomaticTriggerReason", "trackingSessionId",
        "priorMapId", "priorMapSha256", "floorId",
        "nodeTimebaseTimestamp", "nodeTimebaseOffsetSeconds",
    ]

    private static let poseKeys: Set<String> = [
        "x_m", "y_m", "yaw_rad",
    ]

    /// Strictly parses the trace. `expectedCount` comes from the metadata
    /// watermark (`captureHealth.localizationTraceRecordCount`) and must
    /// match exactly when provided (missing file with a declared count is
    /// a hard failure).
    static func parse(
        snapshotDirectory: URL,
        trackingSessionID: String,
        priorMapID: String,
        priorMapSHA256: String,
        floorID: String,
        expectedCount: Int?
    ) throws -> [TraceRecord] {
        let url = snapshotDirectory
            .appendingPathComponent("localization_trace.jsonl")
        guard FileManager.default.fileExists(atPath: url.path) else {
            if let expectedCount, expectedCount > 0 {
                throw ParseError.missingFile(
                    "metadata declares \(expectedCount) records but the file is absent")
            }
            return []
        }
        let attributes = try FileManager.default
            .attributesOfItem(atPath: url.path)
        let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard fileSize <= Int64(maximumFileBytes) else {
            throw ParseError.fileTooLarge(Int(fileSize))
        }
        let framing: StrictJSONLStreamReader.ParsedLines
        do {
            framing = try StrictJSONLStreamReader.readLines(
                from: url,
                maximumLineBytes: maximumRecordBytes,
                maximumLineCount: maximumRecords)
        } catch let error as StrictJSONLStreamReader.StreamError {
            throw ParseError.framing(error.localizedDescription)
        }
        var records: [TraceRecord] = []
        var previousTimestamp: Double?
        for (offset, line) in framing.lines.enumerated() {
            let lineNumber = offset + 1
            let object: [String: Any]
            do {
                object = try StrictJSONLStreamReader.strictObject(
                    from: line, lineNumber: lineNumber)
            } catch {
                throw ParseError.record(lineNumber, "invalid_json")
            }
            // Unknown policy.
            let unknown = object.keys.filter { !knownFields.contains($0) }
            guard unknown.isEmpty else {
                throw ParseError.record(
                    lineNumber,
                    "unknown_field_\(unknown.sorted().joined(separator: ","))")
            }
            // Format/version.
            guard object["format"] as? String == "MarketScannerLocalizationTrace" else {
                throw ParseError.record(lineNumber, "format_invalid")
            }
            guard StrictJSONScalar.integer(object["version"]) == 1 else {
                throw ParseError.record(lineNumber, "version_unsupported")
            }
            // Identity: required and exact (no defaults).
            guard (object["trackingSessionId"] as? String) == trackingSessionID,
                  (object["priorMapId"] as? String) == priorMapID,
                  (object["priorMapSha256"] as? String) == priorMapSHA256,
                  (object["floorId"] as? String) == floorID else {
                throw ParseError.record(lineNumber, "identity_missing_or_mismatch")
            }
            // Strict scalars.
            guard let timestamp = StrictJSONScalar.number(object["timestamp"]),
                  let confidence = StrictJSONScalar.number(object["confidence"]),
                  confidence >= 0, confidence <= 1,
                  let state = object["localizationState"] as? String,
                  localizationStates.contains(state),
                  let trackingState = object["trackingState"] as? String,
                  trackingStates.contains(trackingState),
                  let nodeTimebaseOffset = StrictJSONScalar.number(
                      object["nodeTimebaseOffsetSeconds"]),
                  let nodeTimebaseTimestamp = StrictJSONScalar.number(
                      object["nodeTimebaseTimestamp"]) else {
                throw ParseError.record(lineNumber, "schema_or_state_invalid")
            }
            // Strictly increasing frame timestamps (monotonic axis).
            if let previous = previousTimestamp {
                guard timestamp > previous else {
                    throw ParseError.record(
                        lineNumber, "timestamp_not_strictly_increasing")
                }
            }
            previousTimestamp = timestamp
            // Finite pose only (the real writer always emits both).
            guard let estimated = object["estimatedPose"] as? [String: Any],
                  let raw = object["rawPose"] as? [String: Any] else {
                throw ParseError.record(lineNumber, "pose_missing")
            }
            for pose in [estimated, raw] {
                guard pose.keys.allSatisfy({ poseKeys.contains($0) }),
                      let xM = StrictJSONScalar.number(pose["x_m"]),
                      let yM = StrictJSONScalar.number(pose["y_m"]),
                      let yawRad = StrictJSONScalar.number(pose["yaw_rad"]),
                      xM.isFinite, yM.isFinite, yawRad.isFinite else {
                    throw ParseError.record(lineNumber, "pose_invalid")
                }
            }
            let xM = StrictJSONScalar.number(estimated["x_m"])!
            let yM = StrictJSONScalar.number(estimated["y_m"])!
            let yawRad = StrictJSONScalar.number(estimated["yaw_rad"])!
            records.append(TraceRecord(
                timestamp: timestamp,
                xM: xM, yM: yM, yawRad: yawRad,
                localizationState: state,
                trackingState: trackingState,
                floorID: floorID,
                nodeTimebaseOffsetSeconds: nodeTimebaseOffset,
                nodeTimebaseTimestamp: nodeTimebaseTimestamp,
                confidence: confidence))
        }
        if let expectedCount {
            guard records.count == expectedCount else {
                throw ParseError.countMismatch(records.count, expectedCount)
            }
        }
        return records
    }
}
