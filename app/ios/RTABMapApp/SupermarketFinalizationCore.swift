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

struct CaptureFileDigest: Codable, Equatable {
    let relativePath: String
    let byteCount: UInt64
    let sha256: String
}

struct ExternalCopyVerificationReceipt: Codable {
    let format: String
    let version: Int
    let verifiedAtUnix: TimeInterval
    let sourceDirectory: String
    let destinationDirectory: String
    let files: [CaptureFileDigest]
    let localCopyRetained: Bool
    let durabilityBoundary: String
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
}

enum LocalizationEvidenceBundleValidator {
    private struct JSONLContract {
        let fileName: String
        let format: String
        let version: Int
        let expectedCount: Int?
        let requiredNonEmpty: Bool
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
                requiredNonEmpty: true),
            JSONLContract(
                fileName: "localization_constraints.jsonl",
                format: "MarketScannerLocalizationConstraint",
                version: 1,
                expectedCount: expectation.constraintRecordCount,
                requiredNonEmpty: true),
            JSONLContract(
                fileName: "localization_events.jsonl",
                format: "MarketScannerLocalizationStateEvent",
                version: 1,
                expectedCount: expectation.stateEventCount,
                requiredNonEmpty: true),
        ]
        let optional = [
            JSONLContract(
                fileName: "manual_localization_events.jsonl",
                format: "MarketScannerManualLocalizationEvent",
                version: 3,
                expectedCount: nil,
                requiredNonEmpty: false),
            JSONLContract(
                fileName: "tag_observations.jsonl",
                format: "MarketScannerPriceTagObservation",
                version: 1,
                expectedCount: nil,
                requiredNonEmpty: false),
        ]
        var blockers: [String] = []
        var decodedRecords: [String: [[String: Any]]] = [:]
        for contract in required + optional {
            let url = segmentDirectory.appendingPathComponent(contract.fileName)
            do {
                decodedRecords[contract.fileName] = try validateJSONL(
                    at: url,
                    contract: contract,
                    expectation: expectation)
            }
            catch {
                blockers.append(
                    "evidence_bundle_\(contract.fileName)_\(stableReason(error))")
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

        if let states = decodedRecords["localization_events.jsonl"],
           let lastState = states.last?["state"] as? String,
           lastState != expectation.lastDurableState {
            blockers.append("evidence_bundle_localization_events_watermark_mismatch")
        }
        return Array(Set(blockers)).sorted()
    }

    private static func validateJSONL(
        at url: URL,
        contract: JSONLContract,
        expectation: LocalizationEvidenceBundleExpectation
    ) throws -> [[String: Any]] {
        let data = try readRegularFile(url)
        if data.isEmpty {
            if contract.requiredNonEmpty {
                throw validationError("empty")
            }
            return []
        }
        guard data.last == 0x0A,
              let text = String(data: data, encoding: .utf8) else {
            throw validationError("invalid_utf8_or_partial_line")
        }
        var records: [[String: Any]] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).dropLast() {
            guard !line.isEmpty,
                  let lineData = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(
                    with: lineData),
                  let object = object as? [String: Any] else {
                throw validationError("invalid_json_object")
            }
            guard object["format"] as? String == contract.format,
                  object["version"] as? Int == contract.version else {
                throw validationError("format_or_version_mismatch")
            }
            try validateIdentity(object, expectation: expectation)
            records.append(object)
        }
        if contract.requiredNonEmpty && records.isEmpty {
            throw validationError("empty")
        }
        if let expectedCount = contract.expectedCount,
           records.count != expectedCount {
            throw validationError("count_mismatch")
        }
        return records
    }

    private static func validateLocalizedTags(
        at url: URL,
        expectation: LocalizationEvidenceBundleExpectation
    ) throws -> [[String: Any]] {
        let data = try readRegularFile(url)
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let values = object as? [[String: Any]] else {
            throw validationError("invalid_json_array")
        }
        for value in values {
            guard value["format"] as? String == "MarketScannerLocalizedPriceTag",
                  value["version"] as? Int == 1 else {
                throw validationError("format_or_version_mismatch")
            }
            try validateIdentity(value, expectation: expectation)
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

    private static func readRegularFile(_ url: URL) throws -> Data {
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ])
        }
        catch {
            throw validationError("missing_or_unreadable")
        }
        guard values.isRegularFile == true,
              values.isSymbolicLink != true else {
            throw validationError("missing_or_linked")
        }
        do {
            return try Data(contentsOf: url, options: [.mappedIfSafe])
        }
        catch {
            throw validationError("unreadable")
        }
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
        guard isStrictlyContained(directory, in: root) else {
            throw error("directory_outside_session")
        }
        var linkInfo = stat()
        var targetInfo = stat()
        guard lstat(directory.path, &linkInfo) == 0,
              (linkInfo.st_mode & S_IFMT) == S_IFDIR,
              stat(directory.path, &targetInfo) == 0,
              linkInfo.st_dev == targetInfo.st_dev,
              linkInfo.st_ino == targetInfo.st_ino else {
            throw error("directory_missing_linked_or_replaced")
        }
    }

    static func readRegularFile(
        _ url: URL,
        within root: URL
    ) throws -> SafeRegularFileSnapshot {
        guard isStrictlyContained(url, in: root) else {
            throw error("file_outside_session")
        }
        var linkInfo = stat()
        guard lstat(url.path, &linkInfo) == 0,
              (linkInfo.st_mode & S_IFMT) == S_IFREG else {
            throw error("file_missing_linked_or_not_regular")
        }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
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
              openedInfo.st_ino == linkInfo.st_ino else {
            try? handle.close()
            throw error("file_identity_changed_during_open")
        }
        let data: Data
        do {
            data = try handle.readToEnd() ?? Data()
            try handle.close()
        }
        catch {
            try? handle.close()
            throw Self.error("file_read_failed")
        }
        return SafeRegularFileSnapshot(
            data: data,
            device: UInt64(openedInfo.st_dev),
            inode: UInt64(openedInfo.st_ino),
            byteCount: Int64(openedInfo.st_size),
            sha256: sha256(data))
    }

    static func append(
        _ data: Data,
        to url: URL,
        within root: URL
    ) throws {
        try validateDirectory(url.deletingLastPathComponent(), within: root)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try readRegularFile(url, within: root)
        }
        let descriptor = Darwin.open(
            url.path,
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
              (openedInfo.st_mode & S_IFMT) == S_IFREG else {
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
        let current = try readRegularFile(url, within: root)
        guard current == expected else {
            throw error("file_changed_before_delete")
        }
        guard Darwin.unlink(url.path) == 0 else {
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
