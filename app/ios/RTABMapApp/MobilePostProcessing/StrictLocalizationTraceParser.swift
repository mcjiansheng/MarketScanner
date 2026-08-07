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

    static let maximumFileBytes = GeneratedMobileEvidenceContracts
        .File_localization_trace_jsonl.max_file_bytes
    static let maximumRecordBytes = GeneratedMobileEvidenceContracts
        .File_localization_trace_jsonl.max_record_bytes
    static let maximumRecords = GeneratedMobileEvidenceContracts
        .File_localization_trace_jsonl.max_records
    static let maximumNestingDepth = GeneratedMobileEvidenceContracts
        .File_localization_trace_jsonl.max_nesting_depth
    /// 48 qualified scan hours × 10 formal trace records/second. The
    /// 2,000,000-record limit above is only a hostile-input safety cap.
    static let qualificationMaximumRecords = GeneratedMobileEvidenceContracts
        .File_localization_trace_jsonl.qualification_max_records
    static let qualificationRecordRateHz = GeneratedMobileEvidenceContracts
        .File_localization_trace_jsonl.qualification_record_rate_hz

    enum ParseError: Error, LocalizedError {
        case fileTooLarge(Int)
        case missingFile(String)
        case framing(String)
        case record(Int, String)
        case countMismatch(Int, Int)
        case qualificationLimitExceeded(Int, Int)

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
            case .qualificationLimitExceeded(let actual, let maximum):
                return "本地化轨迹超过产品资格上限：\(actual) > \(maximum) records"
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

    /// Streaming production compactor. The formal trace is validated at
    /// its full 10 Hz rate, but downstream output is only one row/second.
    /// Retaining every state transition is not bounded: a hostile or noisy
    /// session can toggle state on every frame and keep all 1,728,000
    /// qualified records alive. This compactor keeps one conservative
    /// representative per node-axis second plus the exact final sample.
    ///
    /// If any sample in a second is lost/initializing/notAvailable, that
    /// sample wins the bucket even when the state recovers later in the
    /// same second. This can only turn a row UNAVAILABLE; it cannot hide a
    /// lost interval and manufacture an AVAILABLE row. Among equal-risk
    /// samples, lower confidence wins, followed by the later sample.
    struct RetainedTraceCompactor {
        let originNodeTimestamp: Double
        private(set) var records: [TraceRecord] = []
        private var pendingSecond: Int64?
        private var pendingRecord: TraceRecord?
        private var lastRecord: TraceRecord?

        init(originNodeTimestamp: Double) {
            self.originNodeTimestamp = originNodeTimestamp
        }

        /// Returns `false` when the record cannot be assigned to an Int64
        /// second without trapping. JSON numbers may be finite while their
        /// difference is infinite or outside Int64 (for example
        /// `1e308 - -1e308`). Callers must fail the trace closed in that
        /// case; silently dropping the record could hide lost evidence.
        @discardableResult
        mutating func consume(_ record: TraceRecord) -> Bool {
            lastRecord = record
            let delta = record.nodeTimebaseTimestamp - originNodeTimestamp
            guard delta.isFinite else {
                return false
            }
            let flooredDelta = floor(delta)
            // Double(Int64.max) rounds to 2^63, which is already one past
            // the largest Int64. Keep the upper comparison strict while
            // allowing the exactly representable Int64.min boundary.
            guard flooredDelta >= Double(Int64.min),
                  flooredDelta < Double(Int64.max) else {
                return false
            }
            let second = Int64(flooredDelta)
            if pendingSecond != second {
                flushPending()
                pendingSecond = second
                pendingRecord = record
                return true
            }
            guard let current = pendingRecord else {
                pendingRecord = record
                return true
            }
            if Self.prefer(record, over: current) {
                pendingRecord = record
            }
            return true
        }

        mutating func finish() -> [TraceRecord] {
            flushPending()
            if let lastRecord,
               records.last?.nodeTimebaseTimestamp
                    != lastRecord.nodeTimebaseTimestamp {
                records.append(lastRecord)
            }
            return records
        }

        private mutating func flushPending() {
            if let pendingRecord {
                records.append(pendingRecord)
            }
            pendingRecord = nil
        }

        private static func risk(_ record: TraceRecord) -> Int {
            if record.localizationState == "lost"
                || record.localizationState == "initializing"
                || record.trackingState == "notAvailable" {
                return 3
            }
            if record.localizationState == "recovering"
                || record.localizationState == "weak"
                || record.trackingState != "normal" {
                return 2
            }
            return 1
        }

        private static func prefer(
            _ candidate: TraceRecord,
            over current: TraceRecord
        ) -> Bool {
            let candidateRisk = risk(candidate)
            let currentRisk = risk(current)
            if candidateRisk != currentRisk {
                return candidateRisk > currentRisk
            }
            if candidate.confidence != current.confidence {
                return candidate.confidence < current.confidence
            }
            return candidate.nodeTimebaseTimestamp
                > current.nodeTimebaseTimestamp
        }
    }

    /// Values written by `PriorMapLocalizationPhase` (PriorMapScanMatcher)
    /// and the ARKit tracking state.
    static let localizationStates: Set<String> = [
        "uninitialized", "initializing", "stable", "usable",
        "recovering", "weak", "lost", "manualCorrection",
    ]
    static let trackingStates: Set<String> = [
        "normal", "notAvailable", "limited.excessiveMotion",
        "limited.insufficientFeatures", "limited.initializing",
        "limited.relocalizing", "unknown",
    ]

    private static let requiredBooleanFields: Set<String> = [
        "constraintAccepted", "measurementAccepted", "hypothesisTrusted",
        "correctionStepApplied", "recoveryConvergedThisUpdate",
        "confidenceAccepted", "scanSearchPerformed", "recoverySearch",
        "recoveryAutomaticTriggerSuppressed",
    ]

    private static let requiredNonnegativeIntegerFields: Set<String> = [
        "structurePointCount", "postRecoveryTrustedLocalFrames",
        "hypothesisSupportFrames", "activeHypothesisTrackCount",
    ]

    private static let requiredFiniteNumberFields: Set<String> = [
        "structureCoverageAngleRad", "matchUniqueness", "matcherElapsedMs",
        "hypothesisScoreMargin", "correctionTranslationM",
        "correctionYawDeg", "hypothesisTrackerElapsedMs",
        "recoveryCooldownRemainingMs",
    ]

    private static let optionalFiniteNumberFields: Set<String> = [
        "matchResidualCost", "mapFromArkitX", "mapFromArkitY",
        "mapFromArkitYawDeg", "hypothesisBestCost", "hypothesisSecondCost",
        "recoveryElapsedMs", "recoveryFinishedAtUptime",
        "recoveryFinalResidualTranslationM", "recoveryFinalResidualYawDeg",
    ]

    private static let optionalNonnegativeIntegerFields: Set<String> = [
        "selectedHypothesisId", "recoveryEpisodeId",
        "recoveryValidAttemptCount", "recoveryRemainingValidAttempts",
        "recoveryFreshSupportFrames", "recoveryTriggerCount",
        "recoverySelectedHypothesisId",
    ]

    private static let constraintDispositions: Set<String> = [
        "rejected", "provisional_recovery_step", "accepted_local",
        "accepted_recovery_convergence",
    ]

    private static let recoveryOutcomes: Set<String> = [
        "active", "converged", "timed_out", "cancelled", "manual_reset",
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

    private static func strictObject(
        from line: StrictJSONLStreamReader.Line
    ) throws -> [String: Any] {
        guard let data = line.text.data(using: .utf8) else {
            throw ParseError.record(line.number, "invalid_json")
        }
        do {
            return try StrictJSONDocumentParser.object(
                from: data,
                limits: StrictJSONDocumentLimits(
                    maximumBytes: maximumRecordBytes,
                    maximumNestingDepth: maximumNestingDepth))
        } catch {
            throw ParseError.record(line.number, "invalid_json")
        }
    }

    /// Validates the formal localization/recovery decision state written by
    /// `PriorMapLocalizationUpdate`. These fields are not optional telemetry:
    /// downstream availability decisions depend on their exact relationship.
    private static func validateFormalState(
        _ object: [String: Any],
        line: Int,
        localizationState: String,
        trackingState: String,
        confidence: Double
    ) throws {
        for field in requiredBooleanFields {
            guard StrictJSONScalar.boolean(object[field]) != nil else {
                throw ParseError.record(line, "state_field_type_invalid_\(field)")
            }
        }
        for field in requiredNonnegativeIntegerFields {
            guard let value = StrictJSONScalar.integer(object[field]), value >= 0 else {
                throw ParseError.record(line, "state_field_type_invalid_\(field)")
            }
        }
        for field in requiredFiniteNumberFields {
            guard let value = StrictJSONScalar.number(object[field]) else {
                throw ParseError.record(line, "state_field_type_invalid_\(field)")
            }
            if ["matcherElapsedMs", "correctionTranslationM",
                "hypothesisTrackerElapsedMs", "recoveryCooldownRemainingMs"]
                .contains(field), value < 0 {
                throw ParseError.record(line, "state_field_range_invalid_\(field)")
            }
        }
        guard let matchUniqueness = StrictJSONScalar.number(
                  object["matchUniqueness"]),
              matchUniqueness >= 0, matchUniqueness <= 1 else {
            throw ParseError.record(line, "state_field_range_invalid_matchUniqueness")
        }
        for field in optionalFiniteNumberFields where object[field] != nil {
            guard let value = StrictJSONScalar.number(object[field]) else {
                throw ParseError.record(line, "state_field_type_invalid_\(field)")
            }
            if ["recoveryElapsedMs", "recoveryFinishedAtUptime",
                "recoveryFinalResidualTranslationM"]
                .contains(field), value < 0 {
                throw ParseError.record(line, "state_field_range_invalid_\(field)")
            }
        }
        for field in optionalNonnegativeIntegerFields where object[field] != nil {
            guard let value = StrictJSONScalar.integer(object[field]), value >= 0 else {
                throw ParseError.record(line, "state_field_type_invalid_\(field)")
            }
        }
        if object["recoveryCorrectionStepAppliedOnCompletionFrame"] != nil,
           StrictJSONScalar.boolean(
               object["recoveryCorrectionStepAppliedOnCompletionFrame"]) == nil {
            throw ParseError.record(
                line,
                "state_field_type_invalid_recoveryCorrectionStepAppliedOnCompletionFrame")
        }
        if object["recoveryAutomaticTriggerReason"] != nil {
            guard let reason = object["recoveryAutomaticTriggerReason"] as? String,
                  !reason.isEmpty else {
                throw ParseError.record(
                    line, "state_field_type_invalid_recoveryAutomaticTriggerReason")
            }
        }
        guard let structureSource = object["structureSource"] as? String,
              !structureSource.isEmpty,
              let constraintReason = object["constraintReason"] as? String,
              !constraintReason.isEmpty,
              let hypothesisReason = object["hypothesisReason"] as? String,
              !hypothesisReason.isEmpty,
              object["roadCandidates"] is [Any],
              object["matchCandidates"] is [Any],
              let disposition = object["constraintDisposition"] as? String,
              constraintDispositions.contains(disposition) else {
            throw ParseError.record(line, "formal_state_schema_invalid")
        }

        let constraintAccepted = StrictJSONScalar.boolean(
            object["constraintAccepted"])!
        let measurementAccepted = StrictJSONScalar.boolean(
            object["measurementAccepted"])!
        let hypothesisTrusted = StrictJSONScalar.boolean(
            object["hypothesisTrusted"])!
        let correctionStepApplied = StrictJSONScalar.boolean(
            object["correctionStepApplied"])!
        let recoveryConverged = StrictJSONScalar.boolean(
            object["recoveryConvergedThisUpdate"])!
        let confidenceAccepted = StrictJSONScalar.boolean(
            object["confidenceAccepted"])!
        let scanSearchPerformed = StrictJSONScalar.boolean(
            object["scanSearchPerformed"])!
        let recoverySearch = StrictJSONScalar.boolean(object["recoverySearch"])!
        let automaticTriggerSuppressed = StrictJSONScalar.boolean(
            object["recoveryAutomaticTriggerSuppressed"])!

        let acceptedDisposition = disposition == "accepted_local"
            || disposition == "accepted_recovery_convergence"
        let measurementDisposition = acceptedDisposition
            || disposition == "provisional_recovery_step"
        guard constraintAccepted == acceptedDisposition,
              measurementAccepted == measurementDisposition,
              correctionStepApplied == measurementDisposition,
              confidenceAccepted == acceptedDisposition,
              recoveryConverged
                == (disposition == "accepted_recovery_convergence") else {
            throw ParseError.record(line, "constraint_disposition_inconsistent")
        }
        if measurementAccepted && (!hypothesisTrusted || !scanSearchPerformed) {
            throw ParseError.record(line, "measurement_state_inconsistent")
        }
        if disposition == "accepted_local" && recoverySearch {
            throw ParseError.record(line, "local_acceptance_during_recovery")
        }
        if disposition == "provisional_recovery_step" && !recoverySearch {
            throw ParseError.record(line, "provisional_step_without_recovery")
        }
        if trackingState != "normal"
            && (constraintAccepted || measurementAccepted
                || correctionStepApplied || confidenceAccepted) {
            throw ParseError.record(line, "tracking_state_inconsistent")
        }
        if trackingState == "notAvailable"
            && (localizationState != "lost" || confidence != 0) {
            throw ParseError.record(line, "tracking_state_inconsistent")
        }

        let recoveryCoreFields = [
            "recoveryEpisodeId", "recoveryReason", "recoveryOutcome",
            "recoveryValidAttemptCount", "recoveryRemainingValidAttempts",
            "recoveryElapsedMs", "recoveryTriggerCount",
        ]
        let recoveryPresentCount = recoveryCoreFields.reduce(0) {
            $0 + (object[$1] == nil ? 0 : 1)
        }
        guard recoveryPresentCount == 0
                || recoveryPresentCount == recoveryCoreFields.count else {
            throw ParseError.record(line, "recovery_bundle_incomplete")
        }
        let recoveryOutcome = object["recoveryOutcome"] as? String
        if recoveryPresentCount > 0 {
            guard let reason = object["recoveryReason"] as? String,
                  !reason.isEmpty,
                  let recoveryOutcome,
                  recoveryOutcomes.contains(recoveryOutcome),
                  let episodeID = StrictJSONScalar.integer(
                      object["recoveryEpisodeId"]), episodeID > 0 else {
                throw ParseError.record(line, "recovery_bundle_invalid")
            }
            if recoveryOutcome == "active" {
                guard recoverySearch,
                      object["recoveryFinishedAtUptime"] == nil,
                      object["recoveryCorrectionStepAppliedOnCompletionFrame"] == nil
                else {
                    throw ParseError.record(line, "recovery_active_state_inconsistent")
                }
            } else {
                guard object["recoveryFinishedAtUptime"] != nil,
                      object["recoveryFreshSupportFrames"] != nil,
                      object["recoveryCorrectionStepAppliedOnCompletionFrame"] != nil
                else {
                    throw ParseError.record(line, "recovery_completion_incomplete")
                }
            }
        } else {
            let strayRecoveryFields = [
                "recoveryFreshSupportFrames", "recoveryFinishedAtUptime",
                "recoverySelectedHypothesisId",
                "recoveryFinalResidualTranslationM",
                "recoveryFinalResidualYawDeg",
                "recoveryCorrectionStepAppliedOnCompletionFrame",
            ]
            guard strayRecoveryFields.allSatisfy({ object[$0] == nil }) else {
                throw ParseError.record(line, "recovery_bundle_incomplete")
            }
        }
        if localizationState == "recovering" {
            guard recoverySearch, recoveryOutcome == "active", !recoveryConverged else {
                throw ParseError.record(line, "localization_recovery_state_inconsistent")
            }
        }
        if recoveryOutcome == "active" && localizationState != "recovering" {
            // `PriorMapConfidenceManager` gives tracking unavailability
            // precedence over an active recovery episode and emits `lost`.
            guard trackingState == "notAvailable", localizationState == "lost" else {
                throw ParseError.record(
                    line, "localization_recovery_state_inconsistent")
            }
        }
        if recoveryConverged && recoveryOutcome != "converged" {
            throw ParseError.record(line, "recovery_convergence_inconsistent")
        }
        if automaticTriggerSuppressed
            != (object["recoveryAutomaticTriggerReason"] != nil) {
            throw ParseError.record(line, "automatic_trigger_state_inconsistent")
        }
    }

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
        expectedCount: Int?,
        /// Optional production compaction origin. Every line is still
        /// validated and counted, while retained output is bounded to one
        /// conservative sample per node-axis second plus the exact final
        /// sample. State transitions never bypass this bound.
        retentionOriginNodeTimestamp: Double? = nil
    ) throws -> [TraceRecord] {
        if let expectedCount, expectedCount > qualificationMaximumRecords {
            throw ParseError.qualificationLimitExceeded(
                expectedCount, qualificationMaximumRecords)
        }
        let url = snapshotDirectory
            .appendingPathComponent("localization_trace.jsonl")
        guard FileManager.default.fileExists(atPath: url.path) else {
            if let expectedCount, expectedCount > 0 {
                throw ParseError.missingFile(
                    "metadata declares \(expectedCount) records but the file is absent")
            }
            return []
        }
        var records: [TraceRecord] = []
        var previousTimestamp: Double?
        var previousNodeTimebaseTimestamp: Double?
        var retainedCompactor = retentionOriginNodeTimestamp.map {
            RetainedTraceCompactor(originNodeTimestamp: $0)
        }
        let summary: StrictJSONLStreamReader.Summary
        do {
            summary = try StrictJSONLStreamReader.forEachLine(
                from: url,
                limits: StrictJSONLStreamReader.Limits(
                    maximumFileBytes: maximumFileBytes,
                    maximumLineBytes: maximumRecordBytes,
                    maximumLineCount: maximumRecords)) { line in
            let lineNumber = line.number
            guard lineNumber <= qualificationMaximumRecords else {
                throw ParseError.qualificationLimitExceeded(
                    lineNumber, qualificationMaximumRecords)
            }
            let object = try strictObject(from: line)
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
            try validateFormalState(
                object,
                line: lineNumber,
                localizationState: state,
                trackingState: trackingState,
                confidence: confidence)
            // Strictly increasing frame timestamps (monotonic axis).
            if let previous = previousTimestamp {
                guard timestamp > previous else {
                    throw ParseError.record(
                        lineNumber, "timestamp_not_strictly_increasing")
                }
            }
            previousTimestamp = timestamp
            guard abs(
                nodeTimebaseTimestamp
                    - (timestamp + nodeTimebaseOffset)) <= 0.001 else {
                throw ParseError.record(
                    lineNumber, "node_timebase_offset_identity_mismatch")
            }
            if let previous = previousNodeTimebaseTimestamp {
                guard nodeTimebaseTimestamp > previous else {
                    throw ParseError.record(
                        lineNumber,
                        "node_timebase_timestamp_not_strictly_increasing")
                }
            }
            previousNodeTimebaseTimestamp = nodeTimebaseTimestamp
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
            let record = TraceRecord(
                timestamp: timestamp,
                xM: xM, yM: yM, yawRad: yawRad,
                localizationState: state,
                trackingState: trackingState,
                floorID: floorID,
                nodeTimebaseOffsetSeconds: nodeTimebaseOffset,
                nodeTimebaseTimestamp: nodeTimebaseTimestamp,
                confidence: confidence)
            if retainedCompactor != nil {
                guard retainedCompactor!.consume(record) else {
                    throw ParseError.record(
                        lineNumber, "compaction_axis_out_of_range")
                }
            } else {
                records.append(record)
            }
            }
        } catch let error as ParseError {
            throw error
        } catch let error as StrictJSONLStreamReader.StreamError {
            throw ParseError.framing(error.localizedDescription)
        }
        if let expectedCount {
            guard summary.lineCount == expectedCount else {
                throw ParseError.countMismatch(summary.lineCount, expectedCount)
            }
        }
        if var compactor = retainedCompactor {
            records = compactor.finish()
        }
        return records
    }
}
