// P7R6A: one strict, Foundation-only parser for the persisted Recovery
// lifecycle evidence. The persistence coordinator and the finalization
// validator must both consume this parser so "the coordinator accepts a
// file" and "finalization accepts the same file" can never disagree.
//
// The parser operates on one stable-read snapshot: it never reopens the
// file, never re-reads after a partial decision, and never accepts a
// truncated or non-canonical tail as durable evidence.

import Foundation
import CoreFoundation

/// P7R6B: one frozen size/record/depth contract for persisted Recovery
/// lifecycle evidence. The device parser, the finalization bundle
/// validator, the session stable-read snapshot and the PC reader
/// (`tools/PriorMap/offline_localization.py`) all reference the same
/// values, so one file never carries two different size policies. The
/// nesting bound also feeds the duplicate-key scanner.
enum RecoveryLifecycleEvidenceLimits {
    static let maximumFileBytes = 16 * 1024 * 1024
    static let maximumRecordBytes = 1_000_000
    static let maximumRecords = 100_000
    static let maximumTriggerRecordsPerEpisode = 8
    static let maximumJSONNestingDepth = 32
}

/// What the caller expects the persisted recovery evidence to contain.
///
/// `expectedRecordCount == nil` marks the coordinator pre-append check:
/// the file is parsed strictly but no exact count is enforced yet because
/// the transaction is about to append more records. A non-nil count marks
/// finalization, where the record count and the watermark tail fields must
/// match exactly.
struct RecoveryLifecycleEvidenceExpectation {
    let trackingSessionId: String
    let priorMapId: String
    let priorMapSha256: String
    let floorId: String
    let expectedRecordCount: Int?
    let expectedLastEpisodeId: Int?
    let expectedLastFinishedAtUptime: TimeInterval?

    init(
        trackingSessionId: String,
        priorMapId: String,
        priorMapSha256: String,
        floorId: String,
        expectedRecordCount: Int? = nil,
        expectedLastEpisodeId: Int? = nil,
        expectedLastFinishedAtUptime: TimeInterval? = nil
    ) {
        self.trackingSessionId = trackingSessionId
        self.priorMapId = priorMapId
        self.priorMapSha256 = priorMapSha256
        self.floorId = floorId
        self.expectedRecordCount = expectedRecordCount
        self.expectedLastEpisodeId = expectedLastEpisodeId
        self.expectedLastFinishedAtUptime = expectedLastFinishedAtUptime
    }
}

/// One version-aware persisted lifecycle record. Historical v1 records keep
/// their missing v2 facts as nil; the parser never fabricates a deadline,
/// attempts budget, or trigger sequence for them.
///
/// P7R6A v1 compatibility contract:
///
/// ```text
/// v1: deadlineUptime/maximumValidAttempts/triggerRecords are nil; a v1
///     record carrying any of those fields is rejected as an unknown field.
/// v2: all three facts must be present and valid.
/// A persisted v1 record is never rewritten or upgraded to v2, and a v1
/// record can never be merged idempotently with a pending v2 episode.
/// ```
struct PersistedRecoveryLifecycleRecord: Equatable {
    var isVersionOne: Bool {
        return version == 1
    }

    let format: String
    let version: Int

    let trackingSessionId: String
    let priorMapId: String
    let priorMapSha256: String
    let floorId: String

    let episodeId: Int
    let reason: String
    let outcome: PriorMapRecoveryOutcome
    let cancellationReason: PriorMapRecoveryCancellationReason?
    let episodeAutomatic: Bool

    let startedAtUptime: TimeInterval
    let finishedAtUptime: TimeInterval
    let elapsedMs: Double

    let validMatcherAttempts: Int
    let acceptedCorrections: Int
    let triggerCount: Int
    let automaticTriggerCount: Int
    let reliableLoopTriggerCount: Int
    let lastTriggerReason: String
    let lastTriggerAtUptime: TimeInterval

    let selectedHypothesisId: Int?
    let freshSupportFrames: Int
    let finalResidualTranslationM: Double?
    let finalResidualYawRad: Double?
    let completionFrameStepApplied: Bool

    /// v2 only; always nil for v1 records.
    let deadlineUptime: TimeInterval?
    let maximumValidAttempts: Int?
    let triggerRecords: [PriorMapRecoveryTriggerRecord]?

    /// Canonical JSON bytes of this record (sorted keys, no whitespace, no
    /// trailing newline) produced by re-encoding the strictly validated
    /// fields through the version-matching DTO.
    let canonicalRecordBytes: Data
}

/// Strict parse result over one stable snapshot.
struct ParsedRecoveryLifecycleEvidence {
    let records: [PersistedRecoveryLifecycleRecord]
    let recordsByEpisodeId: [Int: PersistedRecoveryLifecycleRecord]
    let exactSnapshotBytes: Data
    let recordCount: Int
    let lastEpisodeId: Int?
    let lastFinishedAtUptime: TimeInterval?
}

/// Stable error vocabulary. Audit strings must come from `stableCode`;
/// localized descriptions are forbidden in contracts and tests.
enum RecoveryLifecycleEvidenceParseError: Error, Equatable {
    case fileTooLarge
    case missingFinalNewline
    case blankRecord(line: Int)
    case recordTooLarge(line: Int)
    case invalidUTF8(line: Int)
    case invalidJSON(line: Int)
    case nonObject(line: Int)
    case unknownField(line: Int)
    case formatMismatch(line: Int)
    case versionMismatch(line: Int)
    case identityMismatch(line: Int)
    case outcomeInvalid(line: Int)
    case cancellationReasonInvalid(line: Int)
    case businessSchemaInvalid(line: Int)
    case triggerRecordsInvalid(line: Int)
    case duplicateEpisode(line: Int)
    case episodeOrderInvalid(line: Int)
    case finishOrderInvalid(line: Int)
    case expectedCountMismatch
    case lastEpisodeWatermarkMismatch
    case lastFinishedWatermarkMismatch
    case duplicateJSONKey(line: Int)

    var stableCode: String {
        switch self {
        case .fileTooLarge: return "file_too_large"
        case .missingFinalNewline: return "missing_final_newline"
        case .blankRecord: return "blank_record"
        case .recordTooLarge: return "record_too_large"
        case .invalidUTF8: return "invalid_utf8"
        case .invalidJSON: return "invalid_json"
        case .nonObject: return "non_object"
        case .unknownField: return "unknown_field"
        case .formatMismatch: return "format_mismatch"
        case .versionMismatch: return "version_mismatch"
        case .identityMismatch: return "identity_mismatch"
        case .outcomeInvalid: return "outcome_invalid"
        case .cancellationReasonInvalid: return "cancellation_reason_invalid"
        case .businessSchemaInvalid: return "business_schema_invalid"
        case .triggerRecordsInvalid: return "trigger_records_invalid"
        case .duplicateEpisode: return "duplicate_episode"
        case .episodeOrderInvalid: return "episode_order_invalid"
        case .finishOrderInvalid: return "finish_order_invalid"
        case .expectedCountMismatch: return "expected_count_mismatch"
        case .lastEpisodeWatermarkMismatch:
            return "last_episode_watermark_mismatch"
        case .lastFinishedWatermarkMismatch:
            return "last_finished_watermark_mismatch"
        case .duplicateJSONKey: return "duplicate_json_key"
        }
    }
}

enum RecoveryLifecyclePersistedEvidenceParser {
    static let formatName = "MarketScannerRecoveryLifecycleEvent"
    /// P7R6B: the parser, the finalization validator and the session
    /// stable-read snapshot share one frozen contract
    /// (`RecoveryLifecycleEvidenceLimits`); these aliases keep existing
    /// call sites compiling while binding them to the shared constants.
    static let maximumFileBytes =
        RecoveryLifecycleEvidenceLimits.maximumFileBytes
    static let maximumRecordBytes =
        RecoveryLifecycleEvidenceLimits.maximumRecordBytes
    static let maximumRecords =
        RecoveryLifecycleEvidenceLimits.maximumRecords

    private static let baseFields: Set<String> = [
        "format", "version", "tracking_session_id", "prior_map_id",
        "prior_map_sha256", "floor_id", "episode_id", "reason",
        "outcome", "cancellation_reason", "episode_automatic",
        "started_at_uptime", "finished_at_uptime", "elapsed_ms",
        "valid_matcher_attempts", "accepted_corrections",
        "trigger_count", "automatic_trigger_count",
        "reliable_loop_trigger_count", "last_trigger_reason",
        "last_trigger_at_uptime", "selected_hypothesis_id",
        "fresh_support_frames", "final_residual_translation_m",
        "final_residual_yaw_rad", "completion_frame_step_applied",
    ]
    private static let v2AdditionalFields: Set<String> = [
        "deadline_uptime", "maximum_valid_attempts", "trigger_records",
    ]
    private static let allowedOutcomes: Set<String> = [
        "converged", "timed_out", "cancelled", "manual_reset",
    ]
    private static let allowedCancellationReasons: Set<String> = [
        "scan_stopped", "map_unloaded", "app_interrupted",
        "session_generation_changed", "operator_cancelled",
    ]
    private static let lowercaseHexDigits = CharacterSet(charactersIn: "0123456789abcdef")

    /// Parses one complete stable-read snapshot under the strict JSONL
    /// contract. Every decision is made on `snapshot`; reopening or
    /// re-reading the file is forbidden.
    static func parse(
        snapshot: Data,
        expectation: RecoveryLifecycleEvidenceExpectation
    ) throws -> ParsedRecoveryLifecycleEvidence {
        guard snapshot.count <= maximumFileBytes else {
            throw RecoveryLifecycleEvidenceParseError.fileTooLarge
        }
        if snapshot.isEmpty {
            // An empty file is legal only when no episode is expected.
            if let expectedCount = expectation.expectedRecordCount,
               expectedCount != 0 {
                throw RecoveryLifecycleEvidenceParseError.expectedCountMismatch
            }
            if expectation.expectedRecordCount == 0 {
                if expectation.expectedLastEpisodeId != nil {
                    throw RecoveryLifecycleEvidenceParseError
                        .lastEpisodeWatermarkMismatch
                }
                if expectation.expectedLastFinishedAtUptime != nil {
                    throw RecoveryLifecycleEvidenceParseError
                        .lastFinishedWatermarkMismatch
                }
            }
            return ParsedRecoveryLifecycleEvidence(
                records: [],
                recordsByEpisodeId: [:],
                exactSnapshotBytes: snapshot,
                recordCount: 0,
                lastEpisodeId: nil,
                lastFinishedAtUptime: nil)
        }
        guard snapshot.last == 0x0A else {
            throw RecoveryLifecycleEvidenceParseError.missingFinalNewline
        }
        var records: [PersistedRecoveryLifecycleRecord] = []
        var byEpisode: [Int: PersistedRecoveryLifecycleRecord] = [:]
        var previousEpisodeId: Int?
        var previousFinishedAtUptime: TimeInterval?
        var lineNumber = 0
        var lineStart = snapshot.startIndex
        while lineStart < snapshot.endIndex {
            lineNumber += 1
            guard let newline = snapshot[lineStart...].firstIndex(of: 0x0A)
            else {
                // Unreachable while the final-newline guard holds, but the
                // tail must never be silently accepted.
                throw RecoveryLifecycleEvidenceParseError.missingFinalNewline
            }
            let line = snapshot.subdata(in: lineStart..<newline)
            lineStart = snapshot.index(after: newline)
            guard !line.isEmpty else {
                throw RecoveryLifecycleEvidenceParseError.blankRecord(
                    line: lineNumber)
            }
            guard line.count <= maximumRecordBytes else {
                throw RecoveryLifecycleEvidenceParseError.recordTooLarge(
                    line: lineNumber)
            }
            guard String(data: line, encoding: .utf8) != nil else {
                throw RecoveryLifecycleEvidenceParseError.invalidUTF8(
                    line: lineNumber)
            }
            // P7R6B: reject duplicate object keys on the raw bytes before
            // JSONSerialization can silently apply last-key-wins.
            do {
                try StrictJSONKeyUniquenessValidator.validate(
                    line, line: lineNumber)
            }
            catch StrictJSONValidationError.duplicateKey(_, _) {
                throw RecoveryLifecycleEvidenceParseError.duplicateJSONKey(
                    line: lineNumber)
            }
            catch is StrictJSONValidationError {
                throw RecoveryLifecycleEvidenceParseError.invalidJSON(
                    line: lineNumber)
            }
            let decoded: Any
            do {
                decoded = try JSONSerialization.jsonObject(with: line)
            }
            catch {
                throw RecoveryLifecycleEvidenceParseError.invalidJSON(
                    line: lineNumber)
            }
            guard let object = decoded as? [String: Any] else {
                throw RecoveryLifecycleEvidenceParseError.nonObject(
                    line: lineNumber)
            }
            let record = try parseRecord(
                object,
                line: line,
                lineNumber: lineNumber,
                expectation: expectation)
            if byEpisode[record.episodeId] != nil {
                throw RecoveryLifecycleEvidenceParseError.duplicateEpisode(
                    line: lineNumber)
            }
            if let previous = previousEpisodeId,
               record.episodeId <= previous {
                throw RecoveryLifecycleEvidenceParseError.episodeOrderInvalid(
                    line: lineNumber)
            }
            if let previousFinished = previousFinishedAtUptime,
               record.finishedAtUptime < previousFinished {
                throw RecoveryLifecycleEvidenceParseError.finishOrderInvalid(
                    line: lineNumber)
            }
            previousEpisodeId = record.episodeId
            previousFinishedAtUptime = record.finishedAtUptime
            byEpisode[record.episodeId] = record
            records.append(record)
            guard records.count <= maximumRecords else {
                throw RecoveryLifecycleEvidenceParseError.fileTooLarge
            }
        }
        if let expectedCount = expectation.expectedRecordCount,
           records.count != expectedCount {
            throw RecoveryLifecycleEvidenceParseError.expectedCountMismatch
        }
        if let expectedCount = expectation.expectedRecordCount,
           expectedCount > 0 {
            let last = records[records.count - 1]
            if expectation.expectedLastEpisodeId != last.episodeId {
                throw RecoveryLifecycleEvidenceParseError
                    .lastEpisodeWatermarkMismatch
            }
            guard let expectedFinished =
                expectation.expectedLastFinishedAtUptime,
                abs(last.finishedAtUptime - expectedFinished) <= 1.0e-9 else {
                throw RecoveryLifecycleEvidenceParseError
                    .lastFinishedWatermarkMismatch
            }
        }
        return ParsedRecoveryLifecycleEvidence(
            records: records,
            recordsByEpisodeId: byEpisode,
            exactSnapshotBytes: snapshot,
            recordCount: records.count,
            lastEpisodeId: records.last?.episodeId,
            lastFinishedAtUptime: records.last?.finishedAtUptime)
    }

    /// Canonical bytes for a freshly built pending v2 record. The production
    /// writer encodes the same struct with sorted keys, so these bytes are
    /// the idempotence reference for the coordinator.
    static func canonicalPendingRecordBytes(
        _ record: PriorMapRecoveryLifecycleRecord
    ) throws -> Data {
        return try canonicalEncoder().encode(record)
    }

    private static func canonicalEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func parseRecord(
        _ object: [String: Any],
        line: Data,
        lineNumber: Int,
        expectation: RecoveryLifecycleEvidenceExpectation
    ) throws -> PersistedRecoveryLifecycleRecord {
        guard object["format"] as? String == formatName else {
            throw RecoveryLifecycleEvidenceParseError.formatMismatch(
                line: lineNumber)
        }
        guard let version = strictInteger(object["version"]),
              version == 1 || version == 2 else {
            throw RecoveryLifecycleEvidenceParseError.versionMismatch(
                line: lineNumber)
        }
        var allowedFields = baseFields
        if version == 2 {
            allowedFields.formUnion(v2AdditionalFields)
        }
        guard Set(object.keys).isSubset(of: allowedFields) else {
            throw RecoveryLifecycleEvidenceParseError.unknownField(
                line: lineNumber)
        }
        // Identity must match exactly; the map digest is additionally bound
        // to the canonical lowercase-hex SHA-256 shape.
        guard let trackingSessionId = object["tracking_session_id"] as? String,
              trackingSessionId == expectation.trackingSessionId,
              let priorMapId = object["prior_map_id"] as? String,
              priorMapId == expectation.priorMapId,
              let priorMapSha256 = object["prior_map_sha256"] as? String,
              priorMapSha256 == expectation.priorMapSha256,
              isValidLowercaseSha256(priorMapSha256),
              let floorId = object["floor_id"] as? String,
              floorId == expectation.floorId else {
            throw RecoveryLifecycleEvidenceParseError.identityMismatch(
                line: lineNumber)
        }
        guard let outcomeRaw = object["outcome"] as? String,
              allowedOutcomes.contains(outcomeRaw),
              let outcome = PriorMapRecoveryOutcome(rawValue: outcomeRaw)
        else {
            throw RecoveryLifecycleEvidenceParseError.outcomeInvalid(
                line: lineNumber)
        }
        let cancellationValue = object["cancellation_reason"]
        let cancellationPresent = cancellationValue != nil
            && !(cancellationValue is NSNull)
        var cancellationReason: PriorMapRecoveryCancellationReason?
        if outcome == .cancelled {
            guard let reasonRaw = cancellationValue as? String,
                  allowedCancellationReasons.contains(reasonRaw),
                  let reason = PriorMapRecoveryCancellationReason(
                    rawValue: reasonRaw) else {
                throw RecoveryLifecycleEvidenceParseError
                    .cancellationReasonInvalid(line: lineNumber)
            }
            cancellationReason = reason
        }
        else if cancellationPresent {
            throw RecoveryLifecycleEvidenceParseError
                .cancellationReasonInvalid(line: lineNumber)
        }
        guard let episodeId = strictInteger(object["episode_id"]),
              episodeId > 0,
              let reason = nonEmptyString(object["reason"]),
              let episodeAutomatic =
                  StrictJSONScalar.boolean(object["episode_automatic"]),
              let startedAtUptime = strictNumber(object["started_at_uptime"]),
              startedAtUptime >= 0,
              let finishedAtUptime = strictNumber(object["finished_at_uptime"]),
              finishedAtUptime >= startedAtUptime,
              let elapsedMs = strictNumber(object["elapsed_ms"]),
              elapsedMs >= 0,
              abs(elapsedMs - (finishedAtUptime - startedAtUptime) * 1000)
                  <= 1.0,
              let validMatcherAttempts =
                  strictInteger(object["valid_matcher_attempts"]),
              validMatcherAttempts >= 0,
              let acceptedCorrections =
                  strictInteger(object["accepted_corrections"]),
              (0...validMatcherAttempts).contains(acceptedCorrections),
              let triggerCount = strictInteger(object["trigger_count"]),
              triggerCount >= 1,
              let automaticTriggerCount =
                  strictInteger(object["automatic_trigger_count"]),
              automaticTriggerCount >= 0,
              let reliableLoopTriggerCount =
                  strictInteger(object["reliable_loop_trigger_count"]),
              reliableLoopTriggerCount >= 0,
              automaticTriggerCount + reliableLoopTriggerCount
                  == triggerCount,
              let lastTriggerReason =
                  nonEmptyString(object["last_trigger_reason"]),
              let lastTriggerAtUptime =
                  strictNumber(object["last_trigger_at_uptime"]),
              lastTriggerAtUptime >= startedAtUptime,
              lastTriggerAtUptime <= finishedAtUptime,
              let freshSupportFrames =
                  strictInteger(object["fresh_support_frames"]),
              freshSupportFrames >= 0,
              let completionFrameStepApplied =
                  StrictJSONScalar.boolean(
                      object["completion_frame_step_applied"]) else {
            throw RecoveryLifecycleEvidenceParseError.businessSchemaInvalid(
                line: lineNumber)
        }
        var selectedHypothesisId: Int?
        let hypothesisValue = object["selected_hypothesis_id"]
        if hypothesisValue != nil && !(hypothesisValue is NSNull) {
            guard let hypothesis = strictInteger(hypothesisValue),
                  hypothesis > 0 else {
                throw RecoveryLifecycleEvidenceParseError
                    .businessSchemaInvalid(line: lineNumber)
            }
            selectedHypothesisId = hypothesis
        }
        let finalResidualTranslationM = try optionalNonNegativeNumber(
            object["final_residual_translation_m"], line: lineNumber)
        let finalResidualYawRad = try optionalNonNegativeNumber(
            object["final_residual_yaw_rad"], line: lineNumber)
        var deadlineUptime: TimeInterval?
        var maximumValidAttempts: Int?
        var triggerRecords: [PriorMapRecoveryTriggerRecord]?
        if version == 2 {
            guard let deadline = strictNumber(object["deadline_uptime"]),
                  deadline >= startedAtUptime,
                  let budget =
                      strictInteger(object["maximum_valid_attempts"]),
                  budget >= 1,
                  validMatcherAttempts <= budget else {
                throw RecoveryLifecycleEvidenceParseError
                    .businessSchemaInvalid(line: lineNumber)
            }
            deadlineUptime = deadline
            maximumValidAttempts = budget
            triggerRecords = try parseTriggerRecords(
                object,
                lineNumber: lineNumber,
                startedAtUptime: startedAtUptime,
                finishedAtUptime: finishedAtUptime,
                lastTriggerReason: lastTriggerReason,
                lastTriggerAtUptime: lastTriggerAtUptime)
        }
        let canonical = try canonicalBytes(
            version: version,
            trackingSessionId: trackingSessionId,
            priorMapId: priorMapId,
            priorMapSha256: priorMapSha256,
            floorId: floorId,
            episodeId: episodeId,
            reason: reason,
            outcomeRaw: outcomeRaw,
            cancellationReasonRaw: cancellationReason?.rawValue,
            episodeAutomatic: episodeAutomatic,
            startedAtUptime: startedAtUptime,
            finishedAtUptime: finishedAtUptime,
            elapsedMs: elapsedMs,
            validMatcherAttempts: validMatcherAttempts,
            acceptedCorrections: acceptedCorrections,
            triggerCount: triggerCount,
            automaticTriggerCount: automaticTriggerCount,
            reliableLoopTriggerCount: reliableLoopTriggerCount,
            lastTriggerReason: lastTriggerReason,
            lastTriggerAtUptime: lastTriggerAtUptime,
            selectedHypothesisId: selectedHypothesisId,
            freshSupportFrames: freshSupportFrames,
            finalResidualTranslationM: finalResidualTranslationM,
            finalResidualYawRad: finalResidualYawRad,
            completionFrameStepApplied: completionFrameStepApplied,
            deadlineUptime: deadlineUptime,
            maximumValidAttempts: maximumValidAttempts,
            triggerRecords: triggerRecords)
        return PersistedRecoveryLifecycleRecord(
            format: formatName,
            version: version,
            trackingSessionId: trackingSessionId,
            priorMapId: priorMapId,
            priorMapSha256: priorMapSha256,
            floorId: floorId,
            episodeId: episodeId,
            reason: reason,
            outcome: outcome,
            cancellationReason: cancellationReason,
            episodeAutomatic: episodeAutomatic,
            startedAtUptime: startedAtUptime,
            finishedAtUptime: finishedAtUptime,
            elapsedMs: elapsedMs,
            validMatcherAttempts: validMatcherAttempts,
            acceptedCorrections: acceptedCorrections,
            triggerCount: triggerCount,
            automaticTriggerCount: automaticTriggerCount,
            reliableLoopTriggerCount: reliableLoopTriggerCount,
            lastTriggerReason: lastTriggerReason,
            lastTriggerAtUptime: lastTriggerAtUptime,
            selectedHypothesisId: selectedHypothesisId,
            freshSupportFrames: freshSupportFrames,
            finalResidualTranslationM: finalResidualTranslationM,
            finalResidualYawRad: finalResidualYawRad,
            completionFrameStepApplied: completionFrameStepApplied,
            deadlineUptime: deadlineUptime,
            maximumValidAttempts: maximumValidAttempts,
            triggerRecords: triggerRecords,
            canonicalRecordBytes: canonical)
    }

    private static func parseTriggerRecords(
        _ object: [String: Any],
        lineNumber: Int,
        startedAtUptime: TimeInterval,
        finishedAtUptime: TimeInterval,
        lastTriggerReason: String?,
        lastTriggerAtUptime: TimeInterval
    ) throws -> [PriorMapRecoveryTriggerRecord] {
        guard let rawRecords = object["trigger_records"] as? [[String: Any]],
              !rawRecords.isEmpty,
              rawRecords.count
                  <= RecoveryLifecycleEvidenceLimits
                      .maximumTriggerRecordsPerEpisode else {
            throw RecoveryLifecycleEvidenceParseError.triggerRecordsInvalid(
                line: lineNumber)
        }
        var records: [PriorMapRecoveryTriggerRecord] = []
        var previousUptime: TimeInterval?
        for record in rawRecords {
            guard Set(record.keys).isSubset(
                    of: ["reason", "automatic", "at_uptime"]),
                  let reason = nonEmptyString(record["reason"]),
                  let automatic =
                      StrictJSONScalar.boolean(record["automatic"]),
                  let uptime = strictNumber(record["at_uptime"]),
                  uptime >= startedAtUptime,
                  uptime <= finishedAtUptime else {
                throw RecoveryLifecycleEvidenceParseError
                    .triggerRecordsInvalid(line: lineNumber)
            }
            if let previous = previousUptime, uptime < previous {
                throw RecoveryLifecycleEvidenceParseError
                    .triggerRecordsInvalid(line: lineNumber)
            }
            previousUptime = uptime
            records.append(PriorMapRecoveryTriggerRecord(
                reason: reason,
                automatic: automatic,
                atUptime: uptime))
        }
        // Bounded eviction may drop early records, but the newest retained
        // record must always agree with the persisted trigger summary.
        guard let newest = records.last,
              newest.reason == lastTriggerReason,
              abs(newest.atUptime - lastTriggerAtUptime) <= 1.0e-9 else {
            throw RecoveryLifecycleEvidenceParseError.triggerRecordsInvalid(
                line: lineNumber)
        }
        return records
    }

    private static func canonicalBytes(
        version: Int,
        trackingSessionId: String,
        priorMapId: String,
        priorMapSha256: String,
        floorId: String,
        episodeId: Int,
        reason: String,
        outcomeRaw: String,
        cancellationReasonRaw: String?,
        episodeAutomatic: Bool,
        startedAtUptime: TimeInterval,
        finishedAtUptime: TimeInterval,
        elapsedMs: Double,
        validMatcherAttempts: Int,
        acceptedCorrections: Int,
        triggerCount: Int,
        automaticTriggerCount: Int,
        reliableLoopTriggerCount: Int,
        lastTriggerReason: String,
        lastTriggerAtUptime: TimeInterval,
        selectedHypothesisId: Int?,
        freshSupportFrames: Int,
        finalResidualTranslationM: Double?,
        finalResidualYawRad: Double?,
        completionFrameStepApplied: Bool,
        deadlineUptime: TimeInterval?,
        maximumValidAttempts: Int?,
        triggerRecords: [PriorMapRecoveryTriggerRecord]?
    ) throws -> Data {
        if version == 1 {
            return try canonicalEncoder().encode(
                PersistedRecoveryLifecycleRecordV1DTO(
                    trackingSessionId: trackingSessionId,
                    priorMapId: priorMapId,
                    priorMapSha256: priorMapSha256,
                    floorId: floorId,
                    episodeId: episodeId,
                    reason: reason,
                    outcomeRaw: outcomeRaw,
                    cancellationReasonRaw: cancellationReasonRaw,
                    episodeAutomatic: episodeAutomatic,
                    startedAtUptime: startedAtUptime,
                    finishedAtUptime: finishedAtUptime,
                    elapsedMs: elapsedMs,
                    validMatcherAttempts: validMatcherAttempts,
                    acceptedCorrections: acceptedCorrections,
                    triggerCount: triggerCount,
                    automaticTriggerCount: automaticTriggerCount,
                    reliableLoopTriggerCount: reliableLoopTriggerCount,
                    lastTriggerReason: lastTriggerReason,
                    lastTriggerAtUptime: lastTriggerAtUptime,
                    selectedHypothesisId: selectedHypothesisId,
                    freshSupportFrames: freshSupportFrames,
                    finalResidualTranslationM: finalResidualTranslationM,
                    finalResidualYawRad: finalResidualYawRad,
                    completionFrameStepApplied: completionFrameStepApplied))
        }
        return try canonicalEncoder().encode(
            PersistedRecoveryLifecycleRecordV2DTO(
                trackingSessionId: trackingSessionId,
                priorMapId: priorMapId,
                priorMapSha256: priorMapSha256,
                floorId: floorId,
                episodeId: episodeId,
                reason: reason,
                outcomeRaw: outcomeRaw,
                cancellationReasonRaw: cancellationReasonRaw,
                episodeAutomatic: episodeAutomatic,
                startedAtUptime: startedAtUptime,
                deadlineUptime: deadlineUptime ?? 0,
                finishedAtUptime: finishedAtUptime,
                elapsedMs: elapsedMs,
                maximumValidAttempts: maximumValidAttempts ?? 0,
                validMatcherAttempts: validMatcherAttempts,
                acceptedCorrections: acceptedCorrections,
                triggerCount: triggerCount,
                automaticTriggerCount: automaticTriggerCount,
                reliableLoopTriggerCount: reliableLoopTriggerCount,
                lastTriggerReason: lastTriggerReason,
                lastTriggerAtUptime: lastTriggerAtUptime,
                triggerRecords: triggerRecords ?? [],
                selectedHypothesisId: selectedHypothesisId,
                freshSupportFrames: freshSupportFrames,
                finalResidualTranslationM: finalResidualTranslationM,
                finalResidualYawRad: finalResidualYawRad,
                completionFrameStepApplied: completionFrameStepApplied))
    }

    private static func optionalNonNegativeNumber(
        _ value: Any?,
        line: Int
    ) throws -> Double? {
        guard value != nil && !(value is NSNull) else { return nil }
        guard let number = strictNumber(value), number >= 0 else {
            throw RecoveryLifecycleEvidenceParseError.businessSchemaInvalid(
                line: line)
        }
        return number
    }

    private static func isValidLowercaseSha256(_ value: String) -> Bool {
        return value.count == 64
            && value.unicodeScalars.allSatisfy {
                lowercaseHexDigits.contains($0)
            }
    }

    private static func strictInteger(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return nil
        }
        let double = number.doubleValue
        guard double.isFinite, double.rounded() == double else { return nil }
        return Int(exactly: double)
    }

    private static func strictNumber(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return nil
        }
        let result = number.doubleValue
        return result.isFinite ? result : nil
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty else {
            return nil
        }
        return value
    }
}

/// Canonical v1 DTO. Field names and types mirror the historical writer
/// exactly; re-encoding a strictly parsed v1 record through this DTO yields
/// the idempotence reference bytes without inventing any v2 facts.
private struct PersistedRecoveryLifecycleRecordV1DTO: Encodable {
    let trackingSessionId: String
    let priorMapId: String
    let priorMapSha256: String
    let floorId: String
    let episodeId: Int
    let reason: String
    let outcomeRaw: String
    let cancellationReasonRaw: String?
    let episodeAutomatic: Bool
    let startedAtUptime: TimeInterval
    let finishedAtUptime: TimeInterval
    let elapsedMs: Double
    let validMatcherAttempts: Int
    let acceptedCorrections: Int
    let triggerCount: Int
    let automaticTriggerCount: Int
    let reliableLoopTriggerCount: Int
    let lastTriggerReason: String
    let lastTriggerAtUptime: TimeInterval
    let selectedHypothesisId: Int?
    let freshSupportFrames: Int
    let finalResidualTranslationM: Double?
    let finalResidualYawRad: Double?
    let completionFrameStepApplied: Bool

    private enum CodingKeys: String, CodingKey {
        case format
        case version
        case trackingSessionId = "tracking_session_id"
        case priorMapId = "prior_map_id"
        case priorMapSha256 = "prior_map_sha256"
        case floorId = "floor_id"
        case episodeId = "episode_id"
        case reason
        case outcome
        case cancellationReason = "cancellation_reason"
        case episodeAutomatic = "episode_automatic"
        case startedAtUptime = "started_at_uptime"
        case finishedAtUptime = "finished_at_uptime"
        case elapsedMs = "elapsed_ms"
        case validMatcherAttempts = "valid_matcher_attempts"
        case acceptedCorrections = "accepted_corrections"
        case triggerCount = "trigger_count"
        case automaticTriggerCount = "automatic_trigger_count"
        case reliableLoopTriggerCount = "reliable_loop_trigger_count"
        case lastTriggerReason = "last_trigger_reason"
        case lastTriggerAtUptime = "last_trigger_at_uptime"
        case selectedHypothesisId = "selected_hypothesis_id"
        case freshSupportFrames = "fresh_support_frames"
        case finalResidualTranslationM = "final_residual_translation_m"
        case finalResidualYawRad = "final_residual_yaw_rad"
        case completionFrameStepApplied = "completion_frame_step_applied"
    }

    init(
        trackingSessionId: String,
        priorMapId: String,
        priorMapSha256: String,
        floorId: String,
        episodeId: Int,
        reason: String,
        outcomeRaw: String,
        cancellationReasonRaw: String?,
        episodeAutomatic: Bool,
        startedAtUptime: TimeInterval,
        finishedAtUptime: TimeInterval,
        elapsedMs: Double,
        validMatcherAttempts: Int,
        acceptedCorrections: Int,
        triggerCount: Int,
        automaticTriggerCount: Int,
        reliableLoopTriggerCount: Int,
        lastTriggerReason: String,
        lastTriggerAtUptime: TimeInterval,
        selectedHypothesisId: Int?,
        freshSupportFrames: Int,
        finalResidualTranslationM: Double?,
        finalResidualYawRad: Double?,
        completionFrameStepApplied: Bool
    ) {
        self.trackingSessionId = trackingSessionId
        self.priorMapId = priorMapId
        self.priorMapSha256 = priorMapSha256
        self.floorId = floorId
        self.episodeId = episodeId
        self.reason = reason
        self.outcomeRaw = outcomeRaw
        self.cancellationReasonRaw = cancellationReasonRaw
        self.episodeAutomatic = episodeAutomatic
        self.startedAtUptime = startedAtUptime
        self.finishedAtUptime = finishedAtUptime
        self.elapsedMs = elapsedMs
        self.validMatcherAttempts = validMatcherAttempts
        self.acceptedCorrections = acceptedCorrections
        self.triggerCount = triggerCount
        self.automaticTriggerCount = automaticTriggerCount
        self.reliableLoopTriggerCount = reliableLoopTriggerCount
        self.lastTriggerReason = lastTriggerReason
        self.lastTriggerAtUptime = lastTriggerAtUptime
        self.selectedHypothesisId = selectedHypothesisId
        self.freshSupportFrames = freshSupportFrames
        self.finalResidualTranslationM = finalResidualTranslationM
        self.finalResidualYawRad = finalResidualYawRad
        self.completionFrameStepApplied = completionFrameStepApplied
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(
            RecoveryLifecyclePersistedEvidenceParser.formatName,
            forKey: .format)
        try container.encode(1, forKey: .version)
        try container.encode(trackingSessionId, forKey: .trackingSessionId)
        try container.encode(priorMapId, forKey: .priorMapId)
        try container.encode(priorMapSha256, forKey: .priorMapSha256)
        try container.encode(floorId, forKey: .floorId)
        try container.encode(episodeId, forKey: .episodeId)
        try container.encode(reason, forKey: .reason)
        try container.encode(outcomeRaw, forKey: .outcome)
        try container.encodeIfPresent(
            cancellationReasonRaw, forKey: .cancellationReason)
        try container.encode(episodeAutomatic, forKey: .episodeAutomatic)
        try container.encode(startedAtUptime, forKey: .startedAtUptime)
        try container.encode(finishedAtUptime, forKey: .finishedAtUptime)
        try container.encode(elapsedMs, forKey: .elapsedMs)
        try container.encode(
            validMatcherAttempts, forKey: .validMatcherAttempts)
        try container.encode(acceptedCorrections, forKey: .acceptedCorrections)
        try container.encode(triggerCount, forKey: .triggerCount)
        try container.encode(
            automaticTriggerCount, forKey: .automaticTriggerCount)
        try container.encode(
            reliableLoopTriggerCount, forKey: .reliableLoopTriggerCount)
        try container.encode(lastTriggerReason, forKey: .lastTriggerReason)
        try container.encode(
            lastTriggerAtUptime, forKey: .lastTriggerAtUptime)
        try container.encodeIfPresent(
            selectedHypothesisId, forKey: .selectedHypothesisId)
        try container.encode(freshSupportFrames, forKey: .freshSupportFrames)
        try container.encodeIfPresent(
            finalResidualTranslationM,
            forKey: .finalResidualTranslationM)
        try container.encodeIfPresent(
            finalResidualYawRad, forKey: .finalResidualYawRad)
        try container.encode(
            completionFrameStepApplied, forKey: .completionFrameStepApplied)
    }
}

/// Canonical v2 DTO. Field names and types mirror the production
/// `PriorMapRecoveryLifecycleRecord` exactly so re-encoded bytes match the
/// bytes the production writer persisted.
private struct PersistedRecoveryLifecycleRecordV2DTO: Encodable {
    let trackingSessionId: String
    let priorMapId: String
    let priorMapSha256: String
    let floorId: String
    let episodeId: Int
    let reason: String
    let outcomeRaw: String
    let cancellationReasonRaw: String?
    let episodeAutomatic: Bool
    let startedAtUptime: TimeInterval
    let deadlineUptime: TimeInterval
    let finishedAtUptime: TimeInterval
    let elapsedMs: Double
    let maximumValidAttempts: Int
    let validMatcherAttempts: Int
    let acceptedCorrections: Int
    let triggerCount: Int
    let automaticTriggerCount: Int
    let reliableLoopTriggerCount: Int
    let lastTriggerReason: String
    let lastTriggerAtUptime: TimeInterval
    let triggerRecords: [PriorMapRecoveryTriggerRecord]
    let selectedHypothesisId: Int?
    let freshSupportFrames: Int
    let finalResidualTranslationM: Double?
    let finalResidualYawRad: Double?
    let completionFrameStepApplied: Bool

    private enum CodingKeys: String, CodingKey {
        case format
        case version
        case trackingSessionId = "tracking_session_id"
        case priorMapId = "prior_map_id"
        case priorMapSha256 = "prior_map_sha256"
        case floorId = "floor_id"
        case episodeId = "episode_id"
        case reason
        case outcome
        case cancellationReason = "cancellation_reason"
        case episodeAutomatic = "episode_automatic"
        case startedAtUptime = "started_at_uptime"
        case deadlineUptime = "deadline_uptime"
        case finishedAtUptime = "finished_at_uptime"
        case elapsedMs = "elapsed_ms"
        case maximumValidAttempts = "maximum_valid_attempts"
        case validMatcherAttempts = "valid_matcher_attempts"
        case acceptedCorrections = "accepted_corrections"
        case triggerCount = "trigger_count"
        case automaticTriggerCount = "automatic_trigger_count"
        case reliableLoopTriggerCount = "reliable_loop_trigger_count"
        case lastTriggerReason = "last_trigger_reason"
        case lastTriggerAtUptime = "last_trigger_at_uptime"
        case triggerRecords = "trigger_records"
        case selectedHypothesisId = "selected_hypothesis_id"
        case freshSupportFrames = "fresh_support_frames"
        case finalResidualTranslationM = "final_residual_translation_m"
        case finalResidualYawRad = "final_residual_yaw_rad"
        case completionFrameStepApplied = "completion_frame_step_applied"
    }

    init(
        trackingSessionId: String,
        priorMapId: String,
        priorMapSha256: String,
        floorId: String,
        episodeId: Int,
        reason: String,
        outcomeRaw: String,
        cancellationReasonRaw: String?,
        episodeAutomatic: Bool,
        startedAtUptime: TimeInterval,
        deadlineUptime: TimeInterval,
        finishedAtUptime: TimeInterval,
        elapsedMs: Double,
        maximumValidAttempts: Int,
        validMatcherAttempts: Int,
        acceptedCorrections: Int,
        triggerCount: Int,
        automaticTriggerCount: Int,
        reliableLoopTriggerCount: Int,
        lastTriggerReason: String,
        lastTriggerAtUptime: TimeInterval,
        triggerRecords: [PriorMapRecoveryTriggerRecord],
        selectedHypothesisId: Int?,
        freshSupportFrames: Int,
        finalResidualTranslationM: Double?,
        finalResidualYawRad: Double?,
        completionFrameStepApplied: Bool
    ) {
        self.trackingSessionId = trackingSessionId
        self.priorMapId = priorMapId
        self.priorMapSha256 = priorMapSha256
        self.floorId = floorId
        self.episodeId = episodeId
        self.reason = reason
        self.outcomeRaw = outcomeRaw
        self.cancellationReasonRaw = cancellationReasonRaw
        self.episodeAutomatic = episodeAutomatic
        self.startedAtUptime = startedAtUptime
        self.deadlineUptime = deadlineUptime
        self.finishedAtUptime = finishedAtUptime
        self.elapsedMs = elapsedMs
        self.maximumValidAttempts = maximumValidAttempts
        self.validMatcherAttempts = validMatcherAttempts
        self.acceptedCorrections = acceptedCorrections
        self.triggerCount = triggerCount
        self.automaticTriggerCount = automaticTriggerCount
        self.reliableLoopTriggerCount = reliableLoopTriggerCount
        self.lastTriggerReason = lastTriggerReason
        self.lastTriggerAtUptime = lastTriggerAtUptime
        self.triggerRecords = triggerRecords
        self.selectedHypothesisId = selectedHypothesisId
        self.freshSupportFrames = freshSupportFrames
        self.finalResidualTranslationM = finalResidualTranslationM
        self.finalResidualYawRad = finalResidualYawRad
        self.completionFrameStepApplied = completionFrameStepApplied
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(
            RecoveryLifecyclePersistedEvidenceParser.formatName,
            forKey: .format)
        try container.encode(2, forKey: .version)
        try container.encode(trackingSessionId, forKey: .trackingSessionId)
        try container.encode(priorMapId, forKey: .priorMapId)
        try container.encode(priorMapSha256, forKey: .priorMapSha256)
        try container.encode(floorId, forKey: .floorId)
        try container.encode(episodeId, forKey: .episodeId)
        try container.encode(reason, forKey: .reason)
        try container.encode(outcomeRaw, forKey: .outcome)
        try container.encodeIfPresent(
            cancellationReasonRaw, forKey: .cancellationReason)
        try container.encode(episodeAutomatic, forKey: .episodeAutomatic)
        try container.encode(startedAtUptime, forKey: .startedAtUptime)
        try container.encode(deadlineUptime, forKey: .deadlineUptime)
        try container.encode(finishedAtUptime, forKey: .finishedAtUptime)
        try container.encode(elapsedMs, forKey: .elapsedMs)
        try container.encode(
            maximumValidAttempts, forKey: .maximumValidAttempts)
        try container.encode(
            validMatcherAttempts, forKey: .validMatcherAttempts)
        try container.encode(acceptedCorrections, forKey: .acceptedCorrections)
        try container.encode(triggerCount, forKey: .triggerCount)
        try container.encode(
            automaticTriggerCount, forKey: .automaticTriggerCount)
        try container.encode(
            reliableLoopTriggerCount, forKey: .reliableLoopTriggerCount)
        try container.encode(lastTriggerReason, forKey: .lastTriggerReason)
        try container.encode(
            lastTriggerAtUptime, forKey: .lastTriggerAtUptime)
        try container.encode(triggerRecords, forKey: .triggerRecords)
        try container.encodeIfPresent(
            selectedHypothesisId, forKey: .selectedHypothesisId)
        try container.encode(freshSupportFrames, forKey: .freshSupportFrames)
        try container.encodeIfPresent(
            finalResidualTranslationM,
            forKey: .finalResidualTranslationM)
        try container.encodeIfPresent(
            finalResidualYawRad, forKey: .finalResidualYawRad)
        try container.encode(
            completionFrameStepApplied, forKey: .completionFrameStepApplied)
    }
}
