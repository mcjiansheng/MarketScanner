//
//  SupermarketFinalizationCore.swift
//  RTABMapApp
//
//  Foundation-only finalization transaction primitives. Keeping this state
//  machine outside the view controller makes pre/post-commit failures
//  executable with injected writers instead of source-text assertions.
//

import Foundation
import CryptoKit
import Darwin
import CoreFoundation

struct CaptureFileDigest: Codable, Equatable {
    let relativePath: String
    let byteCount: UInt64
    let sha256: String
}

struct ExternalCopyVerificationReceipt: Codable {
    let format: String
    let version: Int
    let packageId: String
    let sessionId: String
    let verifiedAtUnix: TimeInterval
    let providerDisplayName: String
    let sourceRelativePath: String
    let destinationRelativePath: String
    let files: [CaptureFileDigest]
    let packageContentSha256: String
    let localCopyRetained: Bool
    let durabilityBoundary: String
}

struct ExternalCopyPackageManifest: Codable {
    let format: String
    let version: Int
    let packageId: String
    let sessionId: String
    let providerDisplayName: String
    let packageContentSha256: String
    let files: [CaptureFileDigest]
    let localCopyRetained: Bool
    let durabilityQualificationStatus: String
    let durabilityExperimentHook: String
}

struct ExternalCopyDurabilityQualificationEvidence: Codable {
    let format: String
    let version: Int
    let packageId: String
    let sessionId: String
    let providerDisplayName: String
    let experiment: String
    let verifiedAtUnix: TimeInterval
    let packageContentSha256: String
    let localCopyRetained: Bool
    let result: String
}

struct LocalizationEvidenceBundleExpectation {
    let trackingSessionId: String
    let priorMapId: String
    let priorMapSha256: String
    let floorId: String
    let traceRecordCount: Int
    let constraintRecordCount: Int
    let stateEventCount: Int
    let lastDurableState: String
    let localizedPriceTagCount: Int
    /// P7R6 recovery lifecycle watermark. The sidecar must contain exactly
    /// one record per durably appended terminal episode; an empty file is
    /// only legal when no episode was recorded.
    let recoveryEventCount: Int
    let lastRecoveryEpisodeId: Int?
    let lastRecoveryFinishedAtUptime: TimeInterval?

    init(
        trackingSessionId: String,
        priorMapId: String,
        priorMapSha256: String,
        floorId: String,
        traceRecordCount: Int,
        constraintRecordCount: Int,
        stateEventCount: Int,
        lastDurableState: String,
        localizedPriceTagCount: Int,
        recoveryEventCount: Int = 0,
        lastRecoveryEpisodeId: Int? = nil,
        lastRecoveryFinishedAtUptime: TimeInterval? = nil
    ) {
        self.trackingSessionId = trackingSessionId
        self.priorMapId = priorMapId
        self.priorMapSha256 = priorMapSha256
        self.floorId = floorId
        self.traceRecordCount = traceRecordCount
        self.constraintRecordCount = constraintRecordCount
        self.stateEventCount = stateEventCount
        self.lastDurableState = lastDurableState
        self.localizedPriceTagCount = localizedPriceTagCount
        self.recoveryEventCount = recoveryEventCount
        self.lastRecoveryEpisodeId = lastRecoveryEpisodeId
        self.lastRecoveryFinishedAtUptime = lastRecoveryFinishedAtUptime
    }
}

enum LocalizationEvidenceBundleValidator {
    private static let maximumRecordBytes = 1_000_000
    private static let maximumRecords = 500_000
    // V1 production scope is one store. Keep the only whole-array decode below
    // a measured mobile-memory budget; larger catalogs must be split by store.
    private static let maximumLocalizedTagRecords = 50_000
    private static let maximumOptionalJSONLBytes = 128 * 1024 * 1024
    private static let maximumRequiredJSONLBytes = 512 * 1024 * 1024
    private static let maximumLocalizedTagsBytes = 16 * 1024 * 1024

    private struct JSONLContract {
        let fileName: String
        let format: String
        let version: Int
        let expectedCount: Int?
        let requiredNonEmpty: Bool
        let strictlyIncreasingTimestamps: Bool
        let recordIdField: String?
    }

    private struct JSONLValidationSummary {
        var count = 0
        var lastState: String?
        var previousTimestamp: Double?
        var seenRecordIds = Set<String>()
        var lastRecoveryEpisodeId: Int?
    }

    static func blockers(
        in segmentDirectory: URL,
        expectation: LocalizationEvidenceBundleExpectation
    ) -> [String] {
        let required = [
            JSONLContract(
                fileName: "localization_trace.jsonl",
                format: "MarketScannerLocalizationTrace",
                version: 1,
                expectedCount: expectation.traceRecordCount,
                requiredNonEmpty: true,
                strictlyIncreasingTimestamps: true,
                recordIdField: nil),
            JSONLContract(
                fileName: "localization_constraints.jsonl",
                format: "MarketScannerLocalizationConstraint",
                version: 1,
                expectedCount: expectation.constraintRecordCount,
                requiredNonEmpty: false,
                strictlyIncreasingTimestamps: false,
                recordIdField: nil),
            JSONLContract(
                fileName: "localization_events.jsonl",
                format: "MarketScannerLocalizationStateEvent",
                version: 1,
                expectedCount: expectation.stateEventCount,
                requiredNonEmpty: true,
                strictlyIncreasingTimestamps: true,
                recordIdField: nil),
        ]
        let optional = [
            JSONLContract(
                fileName: "manual_localization_events.jsonl",
                format: "MarketScannerManualLocalizationEvent",
                version: 3,
                expectedCount: nil,
                requiredNonEmpty: false,
                strictlyIncreasingTimestamps: false,
                recordIdField: nil),
            JSONLContract(
                fileName: "tag_observations.jsonl",
                format: "MarketScannerPriceTagObservation",
                version: 1,
                expectedCount: nil,
                requiredNonEmpty: false,
                strictlyIncreasingTimestamps: false,
                recordIdField: "observation_id"),
            // Terminal Recovery lifecycle evidence (P7R5, P7R6 exact-count,
            // P7R6A shared parser). Timestamps are monotonic uptimes, not
            // node-timebase stamps, so this contract is validated through
            // RecoveryLifecyclePersistedEvidenceParser, the same strict
            // parser the persistence coordinator uses. The record count is
            // bound to the capture watermark and the file may only be empty
            // when zero episodes were recorded.
            JSONLContract(
                fileName: "localization_recovery_events.jsonl",
                format: "MarketScannerRecoveryLifecycleEvent",
                version: 2,
                expectedCount: expectation.recoveryEventCount,
                requiredNonEmpty: expectation.recoveryEventCount > 0,
                strictlyIncreasingTimestamps: false,
                recordIdField: nil),
        ]
        var blockers: [String] = []
        var summaries: [String: JSONLValidationSummary] = [:]
        for contract in required + optional {
            let url = segmentDirectory.appendingPathComponent(contract.fileName)
            do {
                if contract.fileName == "localization_recovery_events.jsonl" {
                    summaries[contract.fileName] =
                        try validateRecoveryLifecycleEvidence(
                            at: url,
                            within:
                                segmentDirectory.deletingLastPathComponent(),
                            expectation: expectation)
                }
                else {
                    summaries[contract.fileName] = try validateJSONL(
                        at: url,
                        within: segmentDirectory.deletingLastPathComponent(),
                        contract: contract,
                        expectation: expectation)
                }
            }
            catch {
                // The recovery watermark blocker keeps its historical name
                // without the file-name infix.
                if stableReason(error) == "recovery_watermark_mismatch" {
                    blockers.append("evidence_bundle_recovery_watermark_mismatch")
                }
                else {
                    blockers.append(
                        "evidence_bundle_\(contract.fileName)_\(stableReason(error))")
                }
            }
        }

        let tagsURL = segmentDirectory.appendingPathComponent(
            "localized_price_tags.json")
        do {
            let tags = try validateLocalizedTags(
                at: tagsURL,
                expectation: expectation)
            if tags.count != expectation.localizedPriceTagCount {
                blockers.append("evidence_bundle_localized_price_tags_count_mismatch")
            }
        }
        catch {
            blockers.append(
                "evidence_bundle_localized_price_tags_\(stableReason(error))")
        }

        if let states = summaries["localization_events.jsonl"],
           let lastState = states.lastState,
           lastState != expectation.lastDurableState {
            blockers.append("evidence_bundle_localization_events_watermark_mismatch")
        }
        return Array(Set(blockers)).sorted()
    }

    private static func validateJSONL(
        at url: URL,
        within root: URL,
        contract: JSONLContract,
        expectation: LocalizationEvidenceBundleExpectation
    ) throws -> JSONLValidationSummary {
        if let expectedCount = contract.expectedCount,
           !(0...maximumRecords).contains(expectedCount) {
            throw validationError("expected_count_out_of_range")
        }
        let fileLimit: Int64
        if let expectedCount = contract.expectedCount {
            fileLimit = Int64(min(
                maximumRequiredJSONLBytes,
                max(1024 * 1024, expectedCount * 64 * 1024 + 1024 * 1024)))
        }
        else {
            fileLimit = Int64(maximumOptionalJSONLBytes)
        }
        var summary = JSONLValidationSummary()
        var pending = Data()
        try SafeSessionPath.streamRegularFile(
            url,
            within: root,
            maximumBytes: fileLimit,
            chunkBytes: 64 * 1024
        ) { chunk in
            pending.append(chunk)
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = pending.subdata(in: pending.startIndex..<newline)
                pending.removeSubrange(pending.startIndex...newline)
                try autoreleasepool {
                    try validateJSONLRecord(
                        line,
                        contract: contract,
                        expectation: expectation,
                        summary: &summary)
                }
            }
            if pending.count > maximumRecordBytes {
                throw validationError("record_too_large")
            }
        }
        guard pending.isEmpty else {
            throw validationError("invalid_utf8_or_partial_line")
        }
        if contract.requiredNonEmpty && summary.count == 0 {
            throw validationError("empty")
        }
        if let expectedCount = contract.expectedCount,
           summary.count != expectedCount {
            throw validationError("count_mismatch")
        }
        return summary
    }

    /// P7R6A: recovery lifecycle finalization delegates every JSONL
    /// decision (syntax, schema, ordering, identity, watermark) to the
    /// same strict parser the persistence coordinator uses, so one file is
    /// accepted by both or rejected by both. Legacy blocker reasons are
    /// preserved through `legacyRecoveryReason`.
    private static func validateRecoveryLifecycleEvidence(
        at url: URL,
        within root: URL,
        expectation: LocalizationEvidenceBundleExpectation
    ) throws -> JSONLValidationSummary {
        guard (0...maximumRecords).contains(expectation.recoveryEventCount)
        else {
            throw validationError("expected_count_out_of_range")
        }
        let fileLimit = Int64(min(
            maximumRequiredJSONLBytes,
            max(
                1024 * 1024,
                expectation.recoveryEventCount * 64 * 1024 + 1024 * 1024)))
        // One stable read; the parser only ever consumes this snapshot.
        let snapshot = try SafeSessionPath.readRegularFile(
            url,
            within: root,
            maximumBytes: fileLimit).data
        if snapshot.isEmpty, expectation.recoveryEventCount > 0 {
            // An emptied sidecar must not mask a positive watermark; keep
            // the legacy "empty" blocker instead of the count reason.
            throw validationError("empty")
        }
        var summary = JSONLValidationSummary()
        do {
            let parsed = try RecoveryLifecyclePersistedEvidenceParser.parse(
                snapshot: snapshot,
                expectation: RecoveryLifecycleEvidenceExpectation(
                    trackingSessionId: expectation.trackingSessionId,
                    priorMapId: expectation.priorMapId,
                    priorMapSha256: expectation.priorMapSha256,
                    floorId: expectation.floorId,
                    expectedRecordCount: expectation.recoveryEventCount,
                    expectedLastEpisodeId: expectation.lastRecoveryEpisodeId,
                    expectedLastFinishedAtUptime:
                        expectation.lastRecoveryFinishedAtUptime))
            summary.count = parsed.recordCount
            summary.lastRecoveryEpisodeId = parsed.lastEpisodeId
            summary.previousTimestamp = parsed.lastFinishedAtUptime
        }
        catch let error as RecoveryLifecycleEvidenceParseError {
            throw validationError(legacyRecoveryReason(for: error))
        }
        return summary
    }

    private static func legacyRecoveryReason(
        for error: RecoveryLifecycleEvidenceParseError
    ) -> String {
        switch error {
        case .fileTooLarge, .recordTooLarge:
            return "record_too_large"
        case .missingFinalNewline, .invalidUTF8:
            return "invalid_utf8_or_partial_line"
        case .blankRecord:
            return "blank_record"
        case .invalidJSON, .nonObject:
            return "invalid_json_object"
        case .unknownField:
            return "recovery_unknown_field"
        case .formatMismatch, .versionMismatch:
            return "format_or_version_mismatch"
        case .identityMismatch:
            return "identity_mismatch"
        case .outcomeInvalid:
            return "recovery_outcome_invalid"
        case .cancellationReasonInvalid:
            return "recovery_cancellation_reason_invalid"
        case .businessSchemaInvalid:
            return "recovery_business_schema_invalid"
        case .triggerRecordsInvalid:
            return "recovery_trigger_records_invalid"
        case .duplicateEpisode:
            return "recovery_duplicate_episode"
        case .episodeOrderInvalid:
            return "recovery_episode_order_invalid"
        case .finishOrderInvalid:
            return "recovery_finish_order_invalid"
        case .expectedCountMismatch:
            return "count_mismatch"
        case .lastEpisodeWatermarkMismatch, .lastFinishedWatermarkMismatch:
            return "recovery_watermark_mismatch"
        case .duplicateJSONKey:
            return "duplicate_json_key"
        }
    }

    private static func validateJSONLRecord(
        _ line: Data,
        contract: JSONLContract,
        expectation: LocalizationEvidenceBundleExpectation,
        summary: inout JSONLValidationSummary
    ) throws {
        guard !line.isEmpty else {
            throw validationError("blank_record")
        }
        guard line.count <= maximumRecordBytes else {
            throw validationError("record_too_large")
        }
        guard String(data: line, encoding: .utf8) != nil else {
            throw validationError("invalid_utf8_or_partial_line")
        }
        // P7R6B: reject duplicate object keys on the raw bytes before
        // JSONSerialization can silently apply last-key-wins.
        do {
            try StrictJSONKeyUniquenessValidator.validate(line)
        }
        catch StrictJSONKeyError.duplicateKey {
            throw validationError("duplicate_json_key")
        }
        catch StrictJSONKeyError.nestingTooDeep,
              StrictJSONKeyError.tokenLimitExceeded {
            throw validationError("invalid_json_object")
        }
        let decoded: Any
        do {
            decoded = try JSONSerialization.jsonObject(with: line)
        }
        catch {
            throw validationError("invalid_json_object")
        }
        guard let object = decoded as? [String: Any] else {
            throw validationError("invalid_json_object")
        }
        guard object["format"] as? String == contract.format else {
            throw validationError("format_or_version_mismatch")
        }
        let version = strictInteger(object["version"])
        if version != contract.version {
            throw validationError("format_or_version_mismatch")
        }
        try validateIdentity(object, expectation: expectation)
        let timestamp = try validateBusinessRecord(
            object,
            fileName: contract.fileName,
            summary: &summary)
        if contract.strictlyIncreasingTimestamps,
           let previous = summary.previousTimestamp,
           timestamp <= previous {
            throw validationError("non_monotonic_timestamp")
        }
        summary.previousTimestamp = timestamp
        if let field = contract.recordIdField {
            guard let identifier = object[field] as? String,
                  !identifier.isEmpty,
                  summary.seenRecordIds.insert(identifier).inserted else {
                throw validationError("missing_or_duplicate_record_id")
            }
        }
        summary.lastState = object["state"] as? String ?? summary.lastState
        summary.count += 1
        if summary.count > maximumRecords {
            throw validationError("record_count_limit")
        }
    }

    private static func validateLocalizedTags(
        at url: URL,
        expectation: LocalizationEvidenceBundleExpectation
    ) throws -> [[String: Any]] {
        let data = try SafeSessionPath.readRegularFile(
            url,
            within: url.deletingLastPathComponent().deletingLastPathComponent(),
            maximumBytes: Int64(maximumLocalizedTagsBytes)).data
        // P7R6B: duplicate keys anywhere in the whole-array document are
        // rejected before JSONSerialization can lose the ambiguity.
        do {
            try StrictJSONKeyUniquenessValidator.validate(data)
        }
        catch StrictJSONKeyError.duplicateKey {
            throw validationError("duplicate_json_key")
        }
        catch StrictJSONKeyError.nestingTooDeep,
              StrictJSONKeyError.tokenLimitExceeded {
            throw validationError("invalid_json_array")
        }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let values = object as? [[String: Any]],
              values.count <= maximumLocalizedTagRecords else {
            throw validationError("invalid_json_array")
        }
        let allowedFields = Set([
            "format", "version", "tag_id", "observation_id", "payload",
            "symbology", "floor_id", "timestamp", "tracking_session_id",
            "prior_map_id", "prior_map_sha256", "shelf_code", "row_flag",
            "cross_code", "shelf_side", "distance_from_shelf_start_cm",
            "height_cm", "raw_map_position", "snapped_map_position",
            "localization_confidence", "measurement_confidence",
            "association_confidence", "measurement_method", "needs_review",
            "user_confirmed",
        ])
        var tagIds = Set<String>()
        var observationIds = Set<String>()
        for value in values {
            guard Set(value.keys).isSubset(of: allowedFields),
                  value["format"] as? String == "MarketScannerLocalizedPriceTag",
                  strictInteger(value["version"]) == 1 else {
                throw validationError("tag_contract_mismatch")
            }
            try validateIdentity(value, expectation: expectation)
            guard value["prior_map_id"] as? String == expectation.priorMapId,
                  let tagId = value["tag_id"] as? String,
                  !tagId.isEmpty,
                  tagIds.insert(tagId).inserted,
                  let observationId = value["observation_id"] as? String,
                  !observationId.isEmpty,
                  observationIds.insert(observationId).inserted,
                  nonEmptyString(value["payload"]),
                  nonEmptyString(value["symbology"]),
                  nonEmptyString(value["measurement_method"]),
                  strictNumber(value["timestamp"]) != nil,
                  validUnitInterval(value["localization_confidence"]),
                  validUnitInterval(value["measurement_confidence"]),
                  validUnitInterval(value["association_confidence"]),
                  StrictJSONScalar.boolean(value["needs_review"]) != nil,
                  StrictJSONScalar.boolean(value["user_confirmed"]) != nil else {
                throw validationError("tag_business_schema_invalid")
            }
            for fieldName in ["shelf_code", "row_flag", "cross_code", "shelf_side"] {
                if let string = value[fieldName] as? String {
                    guard string.count <= 128 else {
                        throw validationError("tag_business_schema_invalid")
                    }
                }
                else if value[fieldName] != nil && !(value[fieldName] is NSNull) {
                    throw validationError("tag_business_schema_invalid")
                }
            }
            if let distance = value["distance_from_shelf_start_cm"],
               !(distance is NSNull) {
                guard let number = strictNumber(distance),
                      (0.0...100_000.0).contains(number) else {
                    throw validationError("tag_business_schema_invalid")
                }
            }
            if let height = value["height_cm"], !(height is NSNull) {
                guard let number = strictNumber(height),
                      (0.0...500.0).contains(number) else {
                    throw validationError("tag_business_schema_invalid")
                }
            }
        }
        return values
    }

    private static func validateIdentity(
        _ object: [String: Any],
        expectation: LocalizationEvidenceBundleExpectation
    ) throws {
        func string(_ camel: String, _ snake: String) -> String? {
            return (object[camel] ?? object[snake]) as? String
        }
        guard string("trackingSessionId", "tracking_session_id")
                == expectation.trackingSessionId,
              string("priorMapId", "prior_map_id") == expectation.priorMapId,
              string("priorMapSha256", "prior_map_sha256")
                == expectation.priorMapSha256,
              string("floorId", "floor_id") == expectation.floorId else {
            throw validationError("identity_mismatch")
        }
    }

    private static func validateBusinessRecord(
        _ object: [String: Any],
        fileName: String,
        summary: inout JSONLValidationSummary
    ) throws -> Double {
        let frameTimestamp = fileName == "tag_observations.jsonl"
            || fileName == "manual_localization_events.jsonl"
        let rawKey = frameTimestamp ? "frameTimestamp" : "timestamp"
        let rawSnake = frameTimestamp ? "frame_timestamp" : "timestamp"
        let convertedKey = frameTimestamp
            ? "nodeTimebaseFrameTimestamp" : "nodeTimebaseTimestamp"
        let convertedSnake = frameTimestamp
            ? "node_timebase_frame_timestamp" : "node_timebase_timestamp"
        guard let raw = strictNumber(field(object, rawSnake, rawKey)),
              let converted = strictNumber(field(object, convertedSnake, convertedKey)),
              let offset = strictNumber(field(
                object,
                "node_timebase_offset_seconds",
                "nodeTimebaseOffsetSeconds")),
              abs(raw + offset - converted) <= 1.0e-6 else {
            throw validationError("node_timebase_contract_invalid")
        }
        switch fileName {
        case "localization_trace.jsonl":
            guard validPose(field(object, "raw_pose", "rawPose")),
                  validPose(field(object, "estimated_pose", "estimatedPose")),
                  nonEmptyString(field(object, "tracking_state", "trackingState")),
                  nonEmptyString(field(object, "localization_state", "localizationState")),
                  validUnitInterval(object["confidence"]) else {
                throw validationError("trace_business_schema_invalid")
            }
        case "localization_constraints.jsonl":
            guard let accepted =
                    StrictJSONScalar.boolean(object["accepted"]),
                  validPose(field(object, "predicted_pose", "predictedPose")),
                  (!accepted || validPose(field(object, "estimated_pose", "estimatedPose"))),
                  validUnitInterval(object["uniqueness"]) else {
                throw validationError("constraint_business_schema_invalid")
            }
        case "localization_events.jsonl":
            guard nonEmptyString(object["state"]),
                  validUnitInterval(object["confidence"]) else {
                throw validationError("state_business_schema_invalid")
            }
        case "tag_observations.jsonl":
            guard nonEmptyString(object["observation_id"]),
                  nonEmptyString(object["payload"]),
                  nonEmptyString(object["symbology"]),
                  validPosition(object["raw_map_position"]) else {
                throw validationError("tag_business_schema_invalid")
            }
        default:
            break
        }
        return converted
    }

    private static func field(
        _ object: [String: Any],
        _ snake: String,
        _ camel: String
    ) -> Any? {
        return object[snake] ?? object[camel]
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

    private static func nonEmptyString(_ value: Any?) -> Bool {
        return (value as? String)?.isEmpty == false
    }

    private static func validUnitInterval(_ value: Any?) -> Bool {
        guard let number = strictNumber(value) else { return false }
        return (0.0...1.0).contains(number)
    }

    private static func validPose(_ value: Any?) -> Bool {
        guard let pose = value as? [String: Any] else { return false }
        return strictNumber(pose["x_m"]) != nil
            && strictNumber(pose["y_m"]) != nil
            && strictNumber(pose["yaw_rad"]) != nil
    }

    private static func validPosition(_ value: Any?) -> Bool {
        guard let position = value as? [String: Any] else { return false }
        return strictNumber(position["x_m"]) != nil
            && strictNumber(position["y_m"]) != nil
            && (position["height_m"] == nil
                || strictNumber(position["height_m"]) != nil)
    }

    private static func validationError(_ reason: String) -> NSError {
        return NSError(
            domain: "LocalizationEvidenceBundleValidator",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: reason])
    }

    private static func stableReason(_ error: Error) -> String {
        let value = (error as NSError).localizedDescription
            .lowercased()
            .replacingOccurrences(
                of: "[^a-z0-9]+",
                with: "_",
                options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return value.isEmpty ? "invalid" : value
    }
}

struct SafeRegularFileSnapshot: Equatable {
    let data: Data
    let device: UInt64
    let inode: UInt64
    let byteCount: Int64
    let sha256: String
}

enum SafeSessionPath {
    static func isStrictlyContained(_ candidate: URL, in root: URL) -> Bool {
        let rootComponents = root.standardizedFileURL
            .resolvingSymlinksInPath().pathComponents
        let candidateComponents = candidate.standardizedFileURL
            .resolvingSymlinksInPath().pathComponents
        guard candidateComponents.count > rootComponents.count else {
            return false
        }
        return Array(candidateComponents.prefix(rootComponents.count))
            == rootComponents
    }

    static func validateDirectory(_ directory: URL, within root: URL) throws {
        let descriptor = try openValidatedDirectory(directory, within: root)
        Darwin.close(descriptor)
    }

    private static func openValidatedDirectory(
        _ directory: URL,
        within root: URL
    ) throws -> Int32 {
        guard isStrictlyContained(directory, in: root) else {
            throw error("directory_outside_session")
        }
        var linkInfo = stat()
        guard lstat(directory.path, &linkInfo) == 0,
              (linkInfo.st_mode & S_IFMT) == S_IFDIR else {
            throw error("directory_missing_linked_or_replaced")
        }
        let descriptor = Darwin.open(
            directory.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw error("directory_open_no_follow_failed")
        }
        var openedInfo = stat()
        guard fstat(descriptor, &openedInfo) == 0,
              (openedInfo.st_mode & S_IFMT) == S_IFDIR,
              openedInfo.st_dev == linkInfo.st_dev,
              openedInfo.st_ino == linkInfo.st_ino else {
            Darwin.close(descriptor)
            throw error("directory_identity_changed_during_open")
        }
        return descriptor
    }

    static func readRegularFile(
        _ url: URL,
        within root: URL,
        maximumBytes: Int64? = nil
    ) throws -> SafeRegularFileSnapshot {
        if let maximumBytes, maximumBytes < 0 {
            throw error("file_size_limit_invalid")
        }
        guard isStrictlyContained(url, in: root) else {
            throw error("file_outside_session")
        }
        let parentDescriptor = try openValidatedDirectory(
            url.deletingLastPathComponent(),
            within: root)
        defer { Darwin.close(parentDescriptor) }
        var linkInfo = stat()
        guard fstatat(
            parentDescriptor,
            url.lastPathComponent,
            &linkInfo,
            AT_SYMLINK_NOFOLLOW) == 0,
              (linkInfo.st_mode & S_IFMT) == S_IFREG else {
            throw error("file_missing_linked_or_not_regular")
        }
        let descriptor = Darwin.openat(
            parentDescriptor,
            url.lastPathComponent,
            O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw error("file_open_no_follow_failed")
        }
        let handle = FileHandle(
            fileDescriptor: descriptor,
            closeOnDealloc: true)
        var openedInfo = stat()
        guard fstat(descriptor, &openedInfo) == 0,
              (openedInfo.st_mode & S_IFMT) == S_IFREG,
              openedInfo.st_dev == linkInfo.st_dev,
              openedInfo.st_ino == linkInfo.st_ino,
              openedInfo.st_nlink == 1,
              maximumBytes.map({ openedInfo.st_size <= $0 }) ?? true else {
            try? handle.close()
            throw error("file_identity_changed_or_size_limit")
        }
        let data: Data
        do {
            data = try handle.readToEnd() ?? Data()
        }
        catch {
            try? handle.close()
            throw Self.error("file_read_failed")
        }
        var finalOpenedInfo = stat()
        var finalPathInfo = stat()
        guard fstat(descriptor, &finalOpenedInfo) == 0,
              fstatat(
                parentDescriptor,
                url.lastPathComponent,
                &finalPathInfo,
                AT_SYMLINK_NOFOLLOW) == 0,
              finalOpenedInfo.st_dev == openedInfo.st_dev,
              finalOpenedInfo.st_ino == openedInfo.st_ino,
              finalOpenedInfo.st_size == openedInfo.st_size,
              finalPathInfo.st_dev == openedInfo.st_dev,
              finalPathInfo.st_ino == openedInfo.st_ino,
              finalPathInfo.st_size == openedInfo.st_size,
              Int64(data.count) == Int64(openedInfo.st_size) else {
            try? handle.close()
            throw error("file_identity_changed_during_read")
        }
        try handle.close()
        return SafeRegularFileSnapshot(
            data: data,
            device: UInt64(openedInfo.st_dev),
            inode: UInt64(openedInfo.st_ino),
            byteCount: Int64(openedInfo.st_size),
            sha256: sha256(data))
    }

    @discardableResult
    static func streamRegularFile(
        _ url: URL,
        within root: URL,
        maximumBytes: Int64,
        chunkBytes: Int,
        consume: (Data) throws -> Void
    ) throws -> Int64 {
        guard maximumBytes >= 0, chunkBytes > 0,
              isStrictlyContained(url, in: root) else {
            throw error("stream_arguments_or_containment_invalid")
        }
        let parentDescriptor = try openValidatedDirectory(
            url.deletingLastPathComponent(),
            within: root)
        defer { Darwin.close(parentDescriptor) }
        var linkInfo = stat()
        guard fstatat(
            parentDescriptor,
            url.lastPathComponent,
            &linkInfo,
            AT_SYMLINK_NOFOLLOW) == 0,
              (linkInfo.st_mode & S_IFMT) == S_IFREG,
              linkInfo.st_nlink == 1,
              linkInfo.st_size >= 0,
              linkInfo.st_size <= maximumBytes else {
            throw error("stream_file_missing_linked_or_size_limit")
        }
        let descriptor = Darwin.openat(
            parentDescriptor,
            url.lastPathComponent,
            O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw error("stream_file_open_no_follow_failed")
        }
        defer { Darwin.close(descriptor) }
        var openedInfo = stat()
        guard fstat(descriptor, &openedInfo) == 0,
              (openedInfo.st_mode & S_IFMT) == S_IFREG,
              openedInfo.st_dev == linkInfo.st_dev,
              openedInfo.st_ino == linkInfo.st_ino,
              openedInfo.st_nlink == 1,
              openedInfo.st_size == linkInfo.st_size else {
            throw error("stream_file_identity_changed_during_open")
        }
        var totalBytes: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: chunkBytes)
        while true {
            let count = buffer.withUnsafeMutableBytes { rawBuffer -> Int in
                return Darwin.read(
                    descriptor,
                    rawBuffer.baseAddress,
                    rawBuffer.count)
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw error("stream_file_read_failed")
            }
            if count == 0 { break }
            totalBytes += Int64(count)
            guard totalBytes <= maximumBytes,
                  totalBytes <= openedInfo.st_size else {
                throw error("stream_file_size_changed_or_limit")
            }
            try consume(Data(buffer[0..<count]))
        }
        var finalOpenedInfo = stat()
        var finalPathInfo = stat()
        guard fstat(descriptor, &finalOpenedInfo) == 0,
              fstatat(
                parentDescriptor,
                url.lastPathComponent,
                &finalPathInfo,
                AT_SYMLINK_NOFOLLOW) == 0,
              finalOpenedInfo.st_dev == openedInfo.st_dev,
              finalOpenedInfo.st_ino == openedInfo.st_ino,
              finalOpenedInfo.st_size == openedInfo.st_size,
              finalPathInfo.st_dev == openedInfo.st_dev,
              finalPathInfo.st_ino == openedInfo.st_ino,
              finalPathInfo.st_size == openedInfo.st_size,
              totalBytes == openedInfo.st_size else {
            throw error("stream_file_identity_changed_during_read")
        }
        return totalBytes
    }

    static func append(
        _ data: Data,
        to url: URL,
        within root: URL
    ) throws {
        let parentDescriptor = try openValidatedDirectory(
            url.deletingLastPathComponent(),
            within: root)
        defer { Darwin.close(parentDescriptor) }
        let descriptor = Darwin.openat(
            parentDescriptor,
            url.lastPathComponent,
            O_APPEND | O_CREAT | O_WRONLY | O_NOFOLLOW,
            S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw error("audit_open_no_follow_failed")
        }
        let handle = FileHandle(
            fileDescriptor: descriptor,
            closeOnDealloc: true)
        var openedInfo = stat()
        guard fstat(descriptor, &openedInfo) == 0,
              (openedInfo.st_mode & S_IFMT) == S_IFREG,
              openedInfo.st_nlink == 1 else {
            try? handle.close()
            throw error("audit_target_not_regular")
        }
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        }
        catch {
            try? handle.close()
            throw Self.error("audit_write_failed")
        }
    }

    static func removeRegularFile(
        _ url: URL,
        within root: URL,
        expected: SafeRegularFileSnapshot
    ) throws {
        let parent = url.deletingLastPathComponent()
        let parentDescriptor = try openValidatedDirectory(parent, within: root)
        defer { Darwin.close(parentDescriptor) }
        let descriptor = Darwin.openat(
            parentDescriptor,
            url.lastPathComponent,
            O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw error("file_open_no_follow_failed")
        }
        let handle = FileHandle(
            fileDescriptor: descriptor,
            closeOnDealloc: true)
        var openedInfo = stat()
        guard fstat(descriptor, &openedInfo) == 0,
              (openedInfo.st_mode & S_IFMT) == S_IFREG else {
            try? handle.close()
            throw error("delete_target_not_regular")
        }
        let data: Data
        do {
            data = try handle.readToEnd() ?? Data()
            try handle.close()
        }
        catch {
            try? handle.close()
            throw Self.error("delete_target_read_failed")
        }
        let current = SafeRegularFileSnapshot(
            data: data,
            device: UInt64(openedInfo.st_dev),
            inode: UInt64(openedInfo.st_ino),
            byteCount: Int64(openedInfo.st_size),
            sha256: sha256(data))
        guard current == expected else {
            throw error("file_changed_before_delete")
        }
        guard Darwin.unlinkat(parentDescriptor, url.lastPathComponent, 0) == 0 else {
            throw error("file_delete_failed")
        }
    }

    private static func sha256(_ data: Data) -> String {
        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func error(_ reason: String) -> NSError {
        return NSError(
            domain: "SafeSessionPath",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: reason])
    }
}

enum CaptureDirectoryIntegrity {
    static func manifestSHA256(_ files: [CaptureFileDigest]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(files))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func manifest(
        for directory: URL,
        fileManager: FileManager = .default
    ) throws -> [CaptureFileDigest] {
        let directoryValues = try directory.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard directoryValues.isDirectory == true,
              directoryValues.isSymbolicLink != true else {
            throw NSError(
                domain: "CaptureDirectoryIntegrity",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "Capture directory is missing or is a symbolic link."])
        }
        let root = directory.standardizedFileURL
        let rootComponents = root.pathComponents
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
            ],
            options: []) else {
            throw NSError(
                domain: "CaptureDirectoryIntegrity",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey:
                    "Unable to enumerate capture directory."])
        }
        var result: [CaptureFileDigest] = []
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
            ])
            if values.isSymbolicLink == true {
                throw NSError(
                    domain: "CaptureDirectoryIntegrity",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey:
                        "Capture directory contains a symbolic link."])
            }
            guard values.isRegularFile == true else {
                continue
            }
            let standardized = fileURL.standardizedFileURL
            guard SafeSessionPath.isStrictlyContained(
                    standardized,
                    in: root) else {
                throw NSError(
                    domain: "CaptureDirectoryIntegrity",
                    code: 4,
                    userInfo: [NSLocalizedDescriptionKey:
                        "Capture file escaped the expected directory."])
            }
            let relativePath = standardized.pathComponents
                .dropFirst(rootComponents.count)
                .joined(separator: "/")
            result.append(CaptureFileDigest(
                relativePath: relativePath,
                byteCount: UInt64(values.fileSize ?? 0),
                sha256: try sha256(standardized)))
        }
        return result.sorted { $0.relativePath < $1.relativePath }
    }

    private static func sha256(_ fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var digest = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024),
              !chunk.isEmpty {
            digest.update(data: chunk)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

enum SidecarFinalizationPhase: String, Codable {
    case preparing
    case artifactsWritten
    case metadataCommitted
    case checkpointCleaned
    case finalizedNeedsCleanup
}

struct SidecarCommitResult {
    let phase: SidecarFinalizationPhase
    let metadataCommitted: Bool
    let finalizedMetadataCommitted: Bool
    let checkpointCleanupSucceeded: Bool
    let cleanupError: String?
    let evidenceValidationBlockers: [String]

    init(
        phase: SidecarFinalizationPhase,
        metadataCommitted: Bool,
        finalizedMetadataCommitted: Bool,
        checkpointCleanupSucceeded: Bool,
        cleanupError: String?,
        evidenceValidationBlockers: [String] = []
    ) {
        self.phase = phase
        self.metadataCommitted = metadataCommitted
        self.finalizedMetadataCommitted = finalizedMetadataCommitted
        self.checkpointCleanupSucceeded = checkpointCleanupSucceeded
        self.cleanupError = cleanupError
        self.evidenceValidationBlockers = evidenceValidationBlockers
    }

    var requiresTerminalCleanup: Bool {
        return finalizedMetadataCommitted && !checkpointCleanupSucceeded
    }
}

struct LocalizationWriteResult {
    let traceWritten: Bool
    let constraintWritten: Bool
    let stateWriteRequired: Bool
    let stateWritten: Bool
    let failureReasons: [String: String]

    var succeeded: Bool {
        return traceWritten
            && constraintWritten
            && (!stateWriteRequired || stateWritten)
    }

    var failedRequiredFiles: [String] {
        return failureReasons.keys.sorted()
    }
}

struct EncodedLocalizationSidecarRecord {
    let fileName: String
    let data: Data
    let url: URL
}

enum LocalizationEvidenceWriteCoordinator {
    static func write(
        trace: EncodedLocalizationSidecarRecord,
        constraint: EncodedLocalizationSidecarRecord,
        state: EncodedLocalizationSidecarRecord?,
        writer: ScanSidecarFileWriting
    ) -> LocalizationWriteResult {
        let traceError = append(trace, writer: writer)
        let constraintError = append(constraint, writer: writer)
        let stateError = state.flatMap { append($0, writer: writer) }
        var failures: [String: String] = [:]
        if let traceError {
            failures[trace.fileName] = traceError
        }
        if let constraintError {
            failures[constraint.fileName] = constraintError
        }
        if let state, let stateError {
            failures[state.fileName] = stateError
        }
        return LocalizationWriteResult(
            traceWritten: traceError == nil,
            constraintWritten: constraintError == nil,
            stateWriteRequired: state != nil,
            stateWritten: stateError == nil,
            failureReasons: failures)
    }

    private static func append(
        _ record: EncodedLocalizationSidecarRecord,
        writer: ScanSidecarFileWriting
    ) -> String? {
        do {
            try writer.append(record.data, to: record.url)
            return nil
        }
        catch {
            return error.localizedDescription
        }
    }
}

enum ScanFinalizationDisposition: Equatable {
    case resumeRecording
    case terminalFinalized
    case terminalFinalizedNeedsCleanup
    case terminalIneligibleEvidence
}

struct ScanFinalizationEffects: Equatable {
    let resumesCameraAndMapping: Bool
    let closesSession: Bool
    let allowsExternalCopy: Bool
    let preservesCheckpoint: Bool
    let processingEligible: Bool
}

enum ScanFinalizationEffectPlanner {
    static func effects(
        for disposition: ScanFinalizationDisposition
    ) -> ScanFinalizationEffects {
        switch disposition {
        case .resumeRecording:
            return ScanFinalizationEffects(
                resumesCameraAndMapping: true,
                closesSession: false,
                allowsExternalCopy: false,
                preservesCheckpoint: true,
                processingEligible: false)
        case .terminalFinalized:
            return ScanFinalizationEffects(
                resumesCameraAndMapping: false,
                closesSession: true,
                allowsExternalCopy: true,
                preservesCheckpoint: false,
                processingEligible: true)
        case .terminalFinalizedNeedsCleanup:
            return ScanFinalizationEffects(
                resumesCameraAndMapping: false,
                closesSession: true,
                allowsExternalCopy: false,
                preservesCheckpoint: true,
                processingEligible: false)
        case .terminalIneligibleEvidence:
            return ScanFinalizationEffects(
                resumesCameraAndMapping: false,
                closesSession: true,
                allowsExternalCopy: true,
                preservesCheckpoint: true,
                processingEligible: false)
        }
    }
}

protocol ScanSidecarFileWriting {
    func fileExists(at url: URL) -> Bool
    func append(_ data: Data, to url: URL) throws
    func writeAtomic(_ data: Data, to url: URL) throws
    func removeItem(at url: URL) throws
}

struct FoundationScanSidecarWriter: ScanSidecarFileWriting {
    private let fileManager: FileManager
    private let atomicWriteFault: ((AtomicWriteStage, URL) throws -> Void)?

    init(
        fileManager: FileManager = .default,
        atomicWriteFault: ((AtomicWriteStage, URL) throws -> Void)? = nil
    ) {
        self.fileManager = fileManager
        self.atomicWriteFault = atomicWriteFault
    }

    func fileExists(at url: URL) -> Bool {
        return fileManager.fileExists(atPath: url.path)
    }

    func append(_ data: Data, to url: URL) throws {
        if !fileExists(at: url) {
            try writeAtomic(data, to: url)
            return
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.synchronize()
    }

    func writeAtomic(_ data: Data, to url: URL) throws {
        let temporaryURL = url.deletingLastPathComponent()
            .appendingPathComponent(
                ".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let descriptor = Darwin.open(
            temporaryURL.path,
            O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW,
            S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw atomicError("temporary_open_failed")
        }
        let handle = FileHandle(
            fileDescriptor: descriptor,
            closeOnDealloc: true)
        var renamed = false
        defer {
            try? handle.close()
            if !renamed {
                try? fileManager.removeItem(at: temporaryURL)
            }
        }
        do {
            try atomicWriteFault?(.write, url)
            try handle.write(contentsOf: data)
            try atomicWriteFault?(.flush, url)
            try handle.synchronize()
            try handle.close()
            try atomicWriteFault?(.rename, url)
            guard Darwin.rename(temporaryURL.path, url.path) == 0 else {
                throw atomicError("atomic_rename_failed")
            }
            renamed = true
        }
        catch {
            throw error
        }
    }

    func removeItem(at url: URL) throws {
        try fileManager.removeItem(at: url)
    }

    private func atomicError(_ reason: String) -> NSError {
        return NSError(
            domain: "FoundationScanSidecarWriter",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: reason])
    }
}

enum AtomicWriteStage: String {
    case write
    case flush
    case rename
}

enum SidecarFinalizationCoordinator {
    static func commitMetadata(
        _ metadataData: Data,
        metadataURL: URL,
        finalized: Bool,
        checkpointURL: URL,
        writer: ScanSidecarFileWriting,
        evidenceValidationBlockers: [String] = []
    ) throws -> SidecarCommitResult {
        // Any error here is pre-commit: callers may resume recording because
        // finalized metadata never became visible.
        try writer.writeAtomic(metadataData, to: metadataURL)

        guard finalized else {
            return SidecarCommitResult(
                phase: .metadataCommitted,
                metadataCommitted: true,
                finalizedMetadataCommitted: false,
                checkpointCleanupSucceeded: false,
                cleanupError: nil,
                evidenceValidationBlockers: evidenceValidationBlockers)
        }
        guard writer.fileExists(at: checkpointURL) else {
            return SidecarCommitResult(
                phase: .checkpointCleaned,
                metadataCommitted: true,
                finalizedMetadataCommitted: true,
                checkpointCleanupSucceeded: true,
                cleanupError: nil,
                evidenceValidationBlockers: evidenceValidationBlockers)
        }
        do {
            try writer.removeItem(at: checkpointURL)
            return SidecarCommitResult(
                phase: .checkpointCleaned,
                metadataCommitted: true,
                finalizedMetadataCommitted: true,
                checkpointCleanupSucceeded: true,
                cleanupError: nil,
                evidenceValidationBlockers: evidenceValidationBlockers)
        }
        catch {
            // Metadata is already the atomically visible commit marker.
            // Cleanup failure is terminal and must never resume recording.
            return SidecarCommitResult(
                phase: .finalizedNeedsCleanup,
                metadataCommitted: true,
                finalizedMetadataCommitted: true,
                checkpointCleanupSucceeded: false,
                cleanupError: error.localizedDescription,
                evidenceValidationBlockers: evidenceValidationBlockers)
        }
    }

    static func disposition(
        saveSucceeded: Bool,
        expectedFinalizedMetadata: Bool,
        commitResult: SidecarCommitResult?,
        preCommitError: String?,
        eligibilityError: String?
    ) -> ScanFinalizationDisposition {
        if expectedFinalizedMetadata,
           let commitResult,
           commitResult.finalizedMetadataCommitted {
            return commitResult.requiresTerminalCleanup
                ? .terminalFinalizedNeedsCleanup
                : .terminalFinalized
        }
        if saveSucceeded,
           expectedFinalizedMetadata == false,
           let commitResult,
           commitResult.metadataCommitted,
           eligibilityError != nil,
           preCommitError == nil {
            // Required evidence is permanently ineligible, but the database
            // and finalized=false metadata were saved successfully. Stop the
            // session and preserve/export its recovery package; do not resume
            // a workflow that can never become eligible.
            return .terminalIneligibleEvidence
        }
        if !saveSucceeded || preCommitError != nil || eligibilityError != nil {
            return .resumeRecording
        }
        return .resumeRecording
    }
}

struct FinalizedCheckpointCleanupMetadata: Decodable {
    let finalized: Bool?
    let trackingSessionId: String?
    let finalizedAtUnix: TimeInterval?
}

struct FinalizedCheckpointCleanupRecord: Decodable {
    let trackingSessionId: String
    let updatedAtUnix: TimeInterval?
}

enum FinalizedCheckpointCleanupValidationError: Error, LocalizedError {
    case metadataNotFinalized
    case missingIdentityOrTime
    case identityMismatch
    case checkpointNewerThanCommit

    var errorDescription: String? {
        switch self {
        case .metadataNotFinalized:
            return "Metadata is not a committed finalized scan."
        case .missingIdentityOrTime:
            return "Finalization cleanup evidence is incomplete."
        case .identityMismatch:
            return "Checkpoint tracking identity does not match metadata."
        case .checkpointNewerThanCommit:
            return "Checkpoint is newer than the finalized metadata commit."
        }
    }
}

enum FinalizedCheckpointCleanupValidator {
    static func validate(metadataData: Data, checkpointData: Data) throws {
        let decoder = JSONDecoder()
        let metadata = try decoder.decode(
            FinalizedCheckpointCleanupMetadata.self,
            from: metadataData)
        let checkpoint = try decoder.decode(
            FinalizedCheckpointCleanupRecord.self,
            from: checkpointData)
        guard metadata.finalized == true else {
            throw FinalizedCheckpointCleanupValidationError.metadataNotFinalized
        }
        guard let metadataSession = metadata.trackingSessionId,
              !metadataSession.isEmpty,
              let finalizedAtUnix = metadata.finalizedAtUnix,
              finalizedAtUnix.isFinite,
              let checkpointUpdatedAtUnix = checkpoint.updatedAtUnix,
              checkpointUpdatedAtUnix.isFinite else {
            throw FinalizedCheckpointCleanupValidationError.missingIdentityOrTime
        }
        guard metadataSession == checkpoint.trackingSessionId else {
            throw FinalizedCheckpointCleanupValidationError.identityMismatch
        }
        guard checkpointUpdatedAtUnix <= finalizedAtUnix else {
            throw FinalizedCheckpointCleanupValidationError.checkpointNewerThanCommit
        }
    }
}
