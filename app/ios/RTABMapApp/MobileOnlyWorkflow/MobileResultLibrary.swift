import Darwin
import CryptoKit
import Foundation

/// One fail-closed publication rule shared by result construction and every
/// immutable-result reread. It lives with the result library so focused
/// reader/recovery hosts compile the same invariant without depending on the
/// full processing pipeline translation unit.
enum MobileResultPublicationInvariant {
    static let coordinateContractVersion = 2

    static func permits(
        coordinatesArePriorMapFrame: Bool,
        graphQualityPassed: Bool,
        degradationCount: Int,
        coordinateFrameAuditPassed: Bool,
        legacyCoordinateFrameCount: Int,
        lowConfidenceTagCount: Int,
        unpositionedTagCount: Int,
        unassociatedTagCount: Int,
        rescanTaskCount: Int
    ) -> Bool {
        coordinatesArePriorMapFrame
            && graphQualityPassed
            && degradationCount == 0
            && coordinateFrameAuditPassed
            && legacyCoordinateFrameCount == 0
            && lowConfidenceTagCount == 0
            && unpositionedTagCount == 0
            && unassociatedTagCount == 0
            && rescanTaskCount == 0
    }

    /// Reader/recovery-side invariant. It deliberately validates only
    /// manifest facts; graph quality is already represented by the declared
    /// status/degradation fields. A coordinate-contract-v1 result can still
    /// be retained as a review artifact, but can never claim COMPLETE.
    static func manifestIsConsistent(_ manifest: [String: Any]) -> Bool {
        guard let status = manifest["result_quality_status"] as? String,
              ["COMPLETE", "PARTIAL_REVIEW_REQUIRED", "LOCAL_FRAME_ONLY"]
                .contains(status),
              let publish = StrictJSONScalar.boolean(
                manifest["publish_permitted"]),
              publish == (status == "COMPLETE"),
              let coordinateVersion = StrictJSONScalar.integer(
                manifest["coordinate_contract_version"]),
              coordinateVersion == 1
                || coordinateVersion == coordinateContractVersion,
              let degradationCount = StrictJSONScalar.integer(
                manifest["degradation_count"]), degradationCount >= 0,
              let lowConfidenceCount = StrictJSONScalar.integer(
                manifest["low_confidence_tag_count"]),
              let unpositionedCount = StrictJSONScalar.integer(
                manifest["unpositioned_tag_count"]),
              let unassociatedCount = StrictJSONScalar.integer(
                manifest["unassociated_tag_count"]),
              let rescanCount = StrictJSONScalar.integer(
                manifest["rescan_count"]),
              [lowConfidenceCount, unpositionedCount, unassociatedCount,
               rescanCount].allSatisfy({ $0 >= 0 }) else {
            return false
        }
        if coordinateVersion == 1 {
            return !publish
        }
        guard let coordinateAuditPassed = StrictJSONScalar.boolean(
                manifest["coordinate_frame_audit_passed"]),
              let legacyCount = StrictJSONScalar.integer(
                manifest["legacy_tag_coordinate_frame_count"]),
              legacyCount >= 0 else {
            return false
        }
        if publish {
            return degradationCount == 0
                && coordinateAuditPassed
                && legacyCount == 0
                && lowConfidenceCount == 0
                && unpositionedCount == 0
                && unassociatedCount == 0
                && rescanCount == 0
        }
        return true
    }
}

/// Immutable on-device result library (V1R3 Gate Q §20).
///
/// Layout:
/// ```
/// Application Support/MarketScanner/Results/
///   .result-staging-<task-hash>.<result-hash>/ # hidden same-parent staging
///   <result-id>/                     # atomic rename target (immutable)
///     result_manifest.json           # per-file SHA + bindings
///     final_trajectory.jsonl
///     final_tags.json / graph_quality.json / quality_report.json
///     rescan_tasks.json / input_manifest.json
///     <workbook>.xlsx                # SHA recorded in the manifest only
/// ```
/// Commit protocol (§20.4): validate every staged artifact, fsync the
/// files and the staging directory, freeze every payload while leaving the
/// staging root owner-writable, persist a publish intent, same-parent atomic
/// rename into the library root, inode-bound root freeze, exact revalidation,
/// then fsync the parent and clear the intent.
/// The final pathname may exist briefly as an intent-bound 0755 directory,
/// but readers reject it until the exact inode is frozen, synced and fully
/// revalidated; an unbound writable final always fails closed.
/// Reads re-validate the manifest and every required hash (§20.5);
/// corrupted results are isolated with a diagnostic, never silently
/// listed.
enum MobileResultLibrary {

    struct ResultEntry {
        var resultID: String
        var taskID: String
        var createdAtUTC: Double
        var workbookURL: URL
        var workbookSHA256: String
        var directory: URL
        var manifest: [String: Any]
    }

    struct CommitReceipt: Equatable {
        var resultID: String
        /// Result-library-root-relative path. Absolute paths are never
        /// persisted in a receipt because a container may move between
        /// launches/restores.
        var finalPath: String
        var manifestSHA256: String
        var commitGeneration: Int
    }

    enum CommitStage: String {
        case beforeManifestWrite
        case afterManifestFsync
        case afterFreeze
        case afterPublishIntentTemporaryFsyncBeforeRename
        case afterPublishIntentRenameBeforeParentFsync
        case afterPublishIntentDurableBeforeDirectoryRename
        case afterDirectoryRenameBeforeFreeze
        case afterDestinationFchmodBeforeDirectoryFsync
        case afterDestinationFreezeBeforeParentFsync
        case afterRename
        case afterParentFsync
    }

    /// Deterministic host-test synchronization points for the immutable
    /// result reader. Production leaves the observer nil. These phases make
    /// post-read/post-hash namespace races reproducible without relying on
    /// artifact size, scheduler timing or arbitrary async delays.
    enum ResultReadVerificationPhase: Equatable {
        case initialManifestAndReceiptBound
        case artifactHashed(String)
        case beforeFinalSweep
    }

    enum ResultError: Error, LocalizedError {
        case cannotCreateRoot(String)
        case invalidManifest(String)
        case workbookMissing(String)
        case artifactMissing(String)
        case artifactCorrupt(String)
        case commitFailed(String)

        var errorDescription: String? {
            switch self {
            case .cannotCreateRoot(let d): return "无法创建结果目录：\(d)"
            case .invalidManifest(let d): return "结果清单无效：\(d)"
            case .workbookMissing(let d): return "结果工作簿缺失：\(d)"
            case .artifactMissing(let d): return "结果产物缺失：\(d)"
            case .artifactCorrupt(let d): return "结果产物损坏：\(d)"
            case .commitFailed(let d): return "结果提交失败：\(d)"
            }
        }
    }

    static let manifestFileName = "result_manifest.json"
    static let commitReceiptFileName = "result_commit_receipt.json"
    static let quarantineDiagnosticFileName = "quarantine_diagnostic.json"
    private static let hiddenStagingPrefix = ".result-staging-"
    private static let publishIntentSuffix = ".publish-intent.json"
    private static let publishIntentTemporaryPrefix =
        ".result-publish-intent-tmp-"
    private static let publishIntentCreationPrefix =
        ".result-publish-intent-create-"
    private static let publishIntentRemovalPrefix =
        ".result-publish-intent-remove-"
    private static let publishIntentTemporaryRemovalPrefix =
        ".result-publish-intent-tmp-remove-"
    private static let publishIntentConflictPrefix =
        ".result-publish-intent-conflict-"
    private static let resultQuarantineDiagnosticFormat =
        "MarketScannerResultQuarantineDiagnostic"
    private static let resultQuarantineDiagnosticVersion = 2
    private static let resultQuarantinePayloadName = "result_payload"
    private static let resultQuarantinePendingSuffix = ".pending"
    private static let resultQuarantineDiagnosticTemporarySuffix =
        ".diagnostic.tmp"
    private static let resultQuarantineIntentCreationPrefix =
        ".result-quarantine-intent-create-"
    private static let resultQuarantineIntentTemporaryPrefix =
        ".result-quarantine-intent-tmp-"
    private static let resultQuarantineIntentRemovalPrefix =
        ".result-quarantine-intent-tmp-remove-"
    private static let maximumResultQuarantineDiagnosticBytes = 64 * 1024
    private static let processLockFileName = ".result-library.lock"
    private static let maximumPublishIntentBytes = 64 * 1024
    private static let libraryLock = NSLock()

    private struct PublishIntent: Equatable {
        let taskID: String
        let resultID: String
        let stagingName: String
        let finalName: String
        let manifestSHA256: String
        let directoryIdentity: ImmutableDirectoryPublication.Identity
    }

    private struct StableRegularFile {
        let data: Data
        let metadata: stat
        let identity: ImmutableDirectoryPublication.Identity
    }

    private struct ReadPublishIntent {
        let intent: PublishIntent
        let data: Data
        let fileIdentity: ImmutableDirectoryPublication.Identity
        let metadata: stat
    }

    private struct IdentityBoundTemporaryName {
        let identity: ImmutableDirectoryPublication.Identity
    }

    private enum ResultQuarantinePayloadType: String {
        case directory
        case regular
        case symbolicLink = "symbolic_link"
    }

    private struct ResultQuarantineDiagnostic {
        let version: Int
        let quarantineID: String
        let sourceName: String
        let sourceMode: mode_t?
        let payloadType: ResultQuarantinePayloadType?
        let payloadIdentity: ImmutableDirectoryPublication.Identity?
        let wrapperIdentity: ImmutableDirectoryPublication.Identity?
        let reason: String
        let createdAtUTC: Double
        let canonicalData: Data
    }

    private struct ResultQuarantineRecoveryGroup {
        var pending: URL?
        var diagnosticTemporary: URL?
        var final: URL?
    }

    enum QuarantineStage {
        case afterIntentDurableBeforeSourceMove
        case afterSourceMoveBeforeFreeze
        case afterPreparedBeforePublish
        case afterPublishRenameBeforeFreeze
        case afterPublishFreezeBeforeParentSync
    }

    /// Deterministic fault-injection hook used by the executable crash
    /// matrix. Production leaves it nil. Throwing at any stage must never
    /// cause a mutable result to be listed as committed.
    static var commitFaultInjector: ((CommitStage) throws -> Void)?
    /// Host-only crash/fault injection for result quarantine transactions.
    /// Production leaves this nil.
    static var quarantineFaultInjector: ((QuarantineStage) throws -> Void)?

    /// Runtime diagnostics from the most recent listing pass. Successful
    /// quarantines also have a durable JSON diagnostic under Results/
    /// quarantine; this buffer makes an isolation failure non-silent.
    private static let listingDiagnosticsLock = NSLock()
    private static var listingDiagnostics: [String] = []

    static func lastListingDiagnostics() -> [String] {
        listingDiagnosticsLock.lock()
        defer { listingDiagnosticsLock.unlock() }
        return listingDiagnostics
    }

    /// V1R4 §16.3: the exact set of top-level manifest fields the reader
    /// accepts. Unknown fields (including unversioned extensions) are
    /// rejected on read AND on write — a new field must be added to this
    /// whitelist in the same change that writes it.
    static let allowedManifestKeys: Set<String> = [
        "format", "version", "result_id", "task_id", "created_at_utc",
        "workbook", "workbook_sha256", "workbook_bytes",
        "package_files", "artifacts",
        "store_id", "prior_map_id", "prior_map_sha256",
        "canonical_source_sha256", "coordinate_contract_version",
        "deliverable_contract_version",
        "tracking_session_id", "source_database", "input_bundle_sha256",
        "native_core_sha256", "processing_path",
        "policy_sha", "projection_policy_version",
        "trajectory_sha256", "graph_quality_sha256",
        "device_position_count", "available_position_count",
        "degraded_position_count", "coordinate_position_count",
        "tag_count", "rescan_count", "result_quality_status",
        "source_tag_count", "retained_tag_count", "positioned_tag_count",
        "unpositioned_tag_count", "shelf_associated_tag_count",
        "unassociated_tag_count", "low_confidence_tag_count",
        "publish_permitted", "degradation_count",
        "coordinate_frame_audit_passed",
        "legacy_tag_coordinate_frame_count",
    ]

    /// Test/embedding hook; see `MobileMapLibrary.rootOverride`.
    static var rootOverride: URL?
    /// Host-only synchronization hook fired immediately before the blocking
    /// cross-process `lockf(F_LOCK)`. Production leaves this nil.
    static var processLockAttemptObserver: (() throws -> Void)?
    /// Host-only synchronization hook fired only after `lockf(F_LOCK)` has
    /// acquired the cross-process lock. Production leaves this nil.
    static var processLockAcquiredObserver: (() throws -> Void)?
    /// Host-only fault hook fired immediately before a public operation's
    /// final root/lock authority validation. Production leaves this nil.
    static var processLockValidationObserver: (() throws -> Void)?
    /// Host-only observer for deterministic read-verification race tests.
    static var resultReadVerificationObserver:
        ((ResultReadVerificationPhase) throws -> Void)?

    private struct ProcessLockHandle {
        let rootURL: URL
        let rootDescriptor: Int32
        let rootMetadata: stat
        let lockDescriptor: Int32
        let lockMetadata: stat
    }

    /// `Application Support/MarketScanner/Results/` (or `rootOverride`).
    static func root() throws -> URL {
        if let rootOverride = rootOverride {
            try FileManager.default.createDirectory(
                at: rootOverride, withIntermediateDirectories: true)
            return rootOverride
        }
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true)
        let root = base
            .appendingPathComponent("MarketScanner", isDirectory: true)
            .appendingPathComponent("Results", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
        return root
    }

    /// Serializes publication/recovery across processes. NSLock protects
    /// threads in one process only; the durable intent protocol also needs a
    /// root-scoped advisory lock so another process cannot clear an intent
    /// while its publisher is between fsync and rename.
    private static func acquireProcessLock() throws -> ProcessLockHandle {
        let libraryRoot = try root()
        let openedRoot = try openBoundDirectory(
            libraryRoot, context: "result-library process-lock root")
        var keepRootDescriptor = false
        defer {
            if !keepRootDescriptor { _ = close(openedRoot.descriptor) }
        }
        let descriptor = openat(
            openedRoot.descriptor,
            processLockFileName,
            O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
            mode_t(0o600))
        guard descriptor >= 0 else {
            throw ResultError.cannotCreateRoot(
                "cannot open result-library process lock")
        }
        var metadata = stat()
        var lockPathMetadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_nlink == 1,
              metadata.st_size == 0,
              (metadata.st_mode & mode_t(0o777)) == 0o600,
              fstatat(
                openedRoot.descriptor,
                processLockFileName,
                &lockPathMetadata,
                AT_SYMLINK_NOFOLLOW) == 0,
              sameStableRegularFile(metadata, lockPathMetadata) else {
            _ = close(descriptor)
            throw ResultError.cannotCreateRoot(
                "result-library process lock identity/mode invalid")
        }
        do {
            try requireBoundDirectoryPath(
                descriptor: openedRoot.descriptor,
                url: libraryRoot,
                expectedMetadata: openedRoot.metadata,
                context: "result-library process-lock root before lock")
        } catch {
            _ = close(descriptor)
            throw error
        }
        do {
            try processLockAttemptObserver?()
        } catch {
            _ = close(descriptor)
            throw error
        }
        while Darwin.lockf(descriptor, F_LOCK, 0) != 0 {
            if errno == EINTR { continue }
            _ = close(descriptor)
            throw ResultError.cannotCreateRoot(
                "cannot acquire result-library process lock")
        }
        do {
            try processLockAcquiredObserver?()
        } catch {
            _ = Darwin.lockf(descriptor, F_ULOCK, 0)
            _ = close(descriptor)
            throw error
        }
        var lockedMetadata = stat()
        var lockedPathMetadata = stat()
        do {
            guard fstat(descriptor, &lockedMetadata) == 0,
                  fstatat(
                    openedRoot.descriptor,
                    processLockFileName,
                    &lockedPathMetadata,
                    AT_SYMLINK_NOFOLLOW) == 0,
                  sameStableRegularFile(metadata, lockedMetadata),
                  sameStableRegularFile(metadata, lockedPathMetadata),
                  lockedMetadata.st_nlink == 1,
                  lockedMetadata.st_size == 0,
                  (lockedMetadata.st_mode & mode_t(0o777)) == 0o600 else {
                throw ResultError.cannotCreateRoot(
                    "result-library process lock pathname changed while acquiring")
            }
            try requireBoundDirectoryPath(
                descriptor: openedRoot.descriptor,
                url: libraryRoot,
                expectedMetadata: openedRoot.metadata,
                context: "result-library process-lock root after lock")
        } catch {
            _ = Darwin.lockf(descriptor, F_ULOCK, 0)
            _ = close(descriptor)
            throw error
        }
        keepRootDescriptor = true
        return ProcessLockHandle(
            rootURL: libraryRoot,
            rootDescriptor: openedRoot.descriptor,
            rootMetadata: openedRoot.metadata,
            lockDescriptor: descriptor,
            lockMetadata: lockedMetadata)
    }

    /// Revalidates both pathname authorities while their descriptors and the
    /// advisory lock are still held. A cooperative peer cannot enter the
    /// critical section, and a non-cooperative same-UID namespace replacement
    /// turns every public success path into a fail-closed error/empty result.
    private static func validateProcessLock(
        _ handle: ProcessLockHandle
    ) throws {
        try processLockValidationObserver?()
        var openedLockMetadata = stat()
        var pathLockMetadata = stat()
        guard fstat(handle.lockDescriptor, &openedLockMetadata) == 0,
              fstatat(
                handle.rootDescriptor,
                processLockFileName,
                &pathLockMetadata,
                AT_SYMLINK_NOFOLLOW) == 0,
              sameStableRegularFile(
                handle.lockMetadata, openedLockMetadata),
              sameStableRegularFile(
                handle.lockMetadata, pathLockMetadata),
              openedLockMetadata.st_nlink == 1,
              openedLockMetadata.st_size == 0,
              (openedLockMetadata.st_mode & mode_t(0o777)) == 0o600 else {
            throw ResultError.cannotCreateRoot(
                "result-library process lock authority changed")
        }
        try requireBoundDirectoryPath(
            descriptor: handle.rootDescriptor,
            url: handle.rootURL,
            expectedMetadata: handle.rootMetadata,
            context: "result-library process-lock final validation")
    }

    private static func releaseProcessLock(_ handle: ProcessLockHandle) {
        _ = Darwin.lockf(handle.lockDescriptor, F_ULOCK, 0)
        _ = close(handle.lockDescriptor)
        _ = close(handle.rootDescriptor)
    }

    /// Final immutable location of a committed result.
    static func resultDirectory(resultID: String) throws -> URL {
        guard isSafeBasename(resultID) else {
            throw ResultError.invalidManifest("unsafe result_id: \(resultID)")
        }
        return try root().appendingPathComponent(resultID, isDirectory: true)
    }

    /// Hidden staging location where the pipeline writes every artifact
    /// before the atomic commit (§20.1). It is a direct child of the
    /// result-library root because Darwin rejects moving a non-writable
    /// directory on macOS 14. Keeping staging and final as siblings permits
    /// an exclusive rename while the root remains 0755; the durable intent
    /// gates the short rename-to-freeze window from every reader.
    static func stagingDirectory(taskID: String, resultID: String) throws -> URL {
        let directory = try stagingDirectoryURL(
            taskID: taskID, resultID: resultID)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false)
        return directory
    }

    /// Resolves (without creating) the deterministic hidden staging path.
    /// Persistent checkpoint references use this same function so their
    /// namespace cannot drift from the publication transaction layout.
    static func stagingDirectoryURL(
        taskID: String,
        resultID: String
    ) throws -> URL {
        guard isSafeBasename(taskID), isSafeBasename(resultID) else {
            throw ResultError.invalidManifest("unsafe task/result identity")
        }
        return try root().appendingPathComponent(
            hiddenStagingName(taskID: taskID, resultID: resultID),
            isDirectory: true)
    }

    /// V1R4 §16.4/§15: removes every UNCOMMITTED staging directory of a
    /// task (crash leftovers). This covers both current hidden same-parent
    /// staging and the legacy `staging/<task>/...` layout. Committed result
    /// names can never match the internal hidden prefix and are untouched.
    static func cleanupStaging(taskID: String) {
        libraryLock.lock()
        defer { libraryLock.unlock() }
        guard let processLock = try? acquireProcessLock() else { return }
        defer { releaseProcessLock(processLock) }
        do {
            try recoverInterruptedPublicationsLocked()
            cleanupStagingLocked(taskID: taskID)
            try validateProcessLock(processLock)
        } catch {
            let message = "result staging cleanup failed closed: \(error)"
            appendListingDiagnostic(message)
            NSLog("MarketScanner result-library audit: %@", message)
        }
    }

    private static func cleanupStagingLocked(taskID: String) {
        let fileManager = FileManager.default
        guard isSafeBasename(taskID) else { return }
        guard let root = try? root() else { return }
        let legacyStagingRoot = root
            .appendingPathComponent("staging", isDirectory: true)
            .appendingPathComponent(taskID, isDirectory: true)
        if let names = try? fileManager.contentsOfDirectory(
            atPath: legacyStagingRoot.path) {
            for name in names {
                recoverAndRemoveStaging(
                    legacyStagingRoot.appendingPathComponent(name))
            }
        }

        let taskPrefix = hiddenStagingTaskPrefix(taskID: taskID)
        if let names = try? fileManager.contentsOfDirectory(atPath: root.path) {
            for name in names where name.hasPrefix(taskPrefix)
                    && isHiddenStagingName(name) {
                recoverAndRemoveStaging(root.appendingPathComponent(name))
            }
        }
    }

    /// Atomically commits a fully staged result package (§20.4):
    /// every staged file is hashed (streaming), the manifest binds the
    /// per-file SHAs plus caller bindings, files + staging directory are
    /// fsynced, then the directory is atomically renamed into the library
    /// root and the parent is fsynced.
    static func commit(
        resultID: String,
        taskID: String,
        stagingDirectory: URL,
        packageFiles: [String],
        workbookFilename: String,
        manifestExtras: [String: Any] = [:]
    ) throws -> ResultEntry {
        libraryLock.lock()
        defer { libraryLock.unlock() }
        let processLock = try acquireProcessLock()
        defer { releaseProcessLock(processLock) }
        let entry = try commitLocked(
            resultID: resultID,
            taskID: taskID,
            stagingDirectory: stagingDirectory,
            packageFiles: packageFiles,
            workbookFilename: workbookFilename,
            manifestExtras: manifestExtras)
        try validateProcessLock(processLock)
        return entry
    }

    private static func commitLocked(
        resultID: String,
        taskID: String,
        stagingDirectory: URL,
        packageFiles: [String],
        workbookFilename: String,
        manifestExtras: [String: Any] = [:]
    ) throws -> ResultEntry {
        let fileManager = FileManager.default
        try recoverInterruptedPublicationsLocked()
        guard isSafeBasename(resultID), isSafeBasename(taskID),
              isSafeBasename(workbookFilename),
              Set(packageFiles).count == packageFiles.count,
              packageFiles.allSatisfy(isSafeBasename),
              !packageFiles.contains(workbookFilename),
              !packageFiles.contains(manifestFileName),
              !packageFiles.contains(commitReceiptFileName) else {
            throw ResultError.invalidManifest(
                "unsafe or duplicate result staging identity/file set")
        }
        let libraryRoot = try root()
        let finalDirectory = libraryRoot.appendingPathComponent(
            resultID, isDirectory: true)
        let expectedStagingDirectory = libraryRoot.appendingPathComponent(
            hiddenStagingName(taskID: taskID, resultID: resultID),
            isDirectory: true)
        guard stagingDirectory.standardizedFileURL
                == expectedStagingDirectory.standardizedFileURL else {
            throw ResultError.invalidManifest(
                "staging directory is outside the task result namespace")
        }

        let expectedPayloadNames = Set(packageFiles + [workbookFilename])
        try validateExactDirectorySet(
            stagingDirectory,
            expectedNames: expectedPayloadNames,
            expectedDirectoryMode: nil,
            expectedFileMode: nil)

        // 1. Validate every staged artifact and hash it (§20.3).
        var artifacts: [[String: Any]] = []
        for name in (packageFiles + [workbookFilename]).sorted() {
            let url = stagingDirectory.appendingPathComponent(name)
            guard fileManager.fileExists(atPath: url.path) else {
                throw ResultError.artifactMissing(name)
            }
            let sha = try CanonicalSourceHasher.sha256File(url)
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            artifacts.append([
                "file": name,
                "bytes": (attributes[.size] as? NSNumber)?.int64Value ?? 0,
                "sha256": sha,
                "required": true,
            ])
        }
        guard let workbookArtifact = artifacts.first(where: { $0["file"] as? String == workbookFilename }),
              let workbookSHA = workbookArtifact["sha256"] as? String,
              let workbookBytes = workbookArtifact["bytes"] as? Int64
        else {
            throw ResultError.workbookMissing(workbookFilename)
        }

        // 2. Manifest over the staged bytes.
        let createdAtUTC = Date().timeIntervalSince1970
        var manifest: [String: Any] = [
            "format": "MarketScannerResultManifest",
            "version": 2,
            "result_id": resultID,
            "task_id": taskID,
            "created_at_utc": createdAtUTC,
            "workbook": workbookFilename,
            "workbook_sha256": workbookSHA,
            "workbook_bytes": workbookBytes,
            "package_files": packageFiles.sorted(),
            "artifacts": artifacts,
        ]
        for (key, value) in manifestExtras {
            // V1R4 §16.3: unknown fields are rejected on write too, so
            // the whitelist can never drift from what is emitted.
            guard allowedManifestKeys.contains(key) else {
                throw ResultError.invalidManifest("unknown manifest extra: \(key)")
            }
            manifest[key] = value
        }
        let manifestData = try CanonicalJSONEncoder.encode(manifest)
        let manifestSHA256 = CanonicalSourceHasher.sha256(manifestData)
        let stagedManifestURL = stagingDirectory.appendingPathComponent(manifestFileName)
        let stagedReceiptURL = stagingDirectory.appendingPathComponent(
            commitReceiptFileName)
        try commitFaultInjector?(.beforeManifestWrite)
        try writeNewRegularFile(manifestData, to: stagedManifestURL)
        let receiptPayload: [String: Any] = [
            "format": "MarketScannerResultCommitReceipt",
            "version": 1,
            "result_id": resultID,
            "final_path": resultID,
            "manifest_sha256": manifestSHA256,
            "commit_generation": 1,
        ]
        try writeNewRegularFile(
            CanonicalJSONEncoder.encode(receiptPayload),
            to: stagedReceiptURL)

        // 3. fsync every staged file and the staging directory (V1R5
        //    §13.1 / review H-01: any open/fsync failure blocks the
        //    commit — durability is never best-effort).
        for name in packageFiles + [
            workbookFilename, manifestFileName, commitReceiptFileName,
        ] {
            try syncFile(stagingDirectory.appendingPathComponent(name))
        }
        try MobileMapLibrary.syncDirectory(stagingDirectory)
        try commitFaultInjector?(.afterManifestFsync)

        let committedNames = expectedPayloadNames.union([
            manifestFileName, commitReceiptFileName,
        ])
        var freezeAttempted = false
        var stagingIdentity: ImmutableDirectoryPublication.Identity?
        var publishIntentRecord: ReadPublishIntent?
        let publishIntentURL = libraryRoot.appendingPathComponent(
            publishIntentName(taskID: taskID, resultID: resultID))
        do {
            // Freeze every payload while the staging package is hidden.  On
            // macOS 14 a 0555 directory root cannot be renamed, so only the
            // root remains 0755 until the inode-bound publication helper
            // freezes the renamed destination.
            freezeAttempted = true
            try freezeImmutably(
                stagingDirectory, freezeRootDirectory: false)
            try validateExactDirectorySet(
                stagingDirectory,
                expectedNames: committedNames,
                expectedDirectoryMode: 0o755,
                expectedFileMode: 0o444)
            // chmod metadata is part of the immutable payload contract. The
            // earlier content fsync happened before freeze, so sync every
            // exact file inode again after 0444 and then the staging root.
            for name in committedNames.sorted() {
                try syncFile(stagingDirectory.appendingPathComponent(name))
            }
            try MobileMapLibrary.syncDirectory(stagingDirectory)
            let preparedIdentity = try ImmutableDirectoryPublication.identity(
                of: stagingDirectory,
                allowedModes: [ImmutableDirectoryPublication.renameableMode])
            stagingIdentity = preparedIdentity
            try commitFaultInjector?(.afterFreeze)

            // The durable external intent is what distinguishes a genuine
            // rename→freeze crash window from a later chmod/tamper of an
            // already committed result. Readers reconcile only an exact
            // intent-bound dev/inode; an unbound writable final fails closed.
            if fileManager.fileExists(atPath: finalDirectory.path) {
                throw ResultError.commitFailed(
                    "result already exists: \(resultID)")
            }
            let expectedIntent = PublishIntent(
                    taskID: taskID,
                    resultID: resultID,
                    stagingName: stagingDirectory.lastPathComponent,
                    finalName: finalDirectory.lastPathComponent,
                    manifestSHA256: manifestSHA256,
                    directoryIdentity: preparedIdentity)
            publishIntentRecord = try writePublishIntent(
                expectedIntent, to: publishIntentURL)
            try commitFaultInjector?(
                .afterPublishIntentDurableBeforeDirectoryRename)

            try ImmutableDirectoryPublication.publish(
                source: stagingDirectory,
                destination: finalDirectory,
                expectedIdentity: preparedIdentity,
                afterRenameBeforeFreeze: {
                    try commitFaultInjector?(
                        .afterDirectoryRenameBeforeFreeze)
                },
                afterFreezeBeforeDirectorySync: {
                    try commitFaultInjector?(
                        .afterDestinationFchmodBeforeDirectoryFsync)
                },
                afterFreezeBeforeParentSync: {
                    try commitFaultInjector?(
                        .afterDestinationFreezeBeforeParentFsync)
                })
        } catch {
            var finalStat = stat()
            let finalExists = lstat(finalDirectory.path, &finalStat) == 0
            if freezeAttempted && !finalExists {
                do {
                    guard let stagingIdentity else {
                        throw ResultError.commitFailed(
                            "pre-rename failure occurred before staging identity binding")
                    }
                    let currentStagingIdentity = try ImmutableDirectoryPublication
                        .identity(
                            of: stagingDirectory,
                            allowedModes: [
                                ImmutableDirectoryPublication.renameableMode,
                                ImmutableDirectoryPublication.immutableMode,
                            ])
                    guard currentStagingIdentity == stagingIdentity else {
                        throw ResultError.commitFailed(
                            "pre-rename staging pathname is not the bound inode")
                    }
                    if let publishIntentRecord {
                        try removePublishIntent(
                            publishIntentURL,
                            expectedRecord: publishIntentRecord)
                    } else if fileManager.fileExists(
                                atPath: publishIntentURL.path) {
                        throw ResultError.commitFailed(
                            "pre-rename publish intent authority is uncertain; preserved")
                    }
                    try makeStagingRecoverable(
                        stagingDirectory,
                        expectedIdentity: stagingIdentity,
                        expectedNames: committedNames)
                } catch let recoveryError {
                    throw ResultError.commitFailed(
                        "pre-rename commit failed: \(error); "
                            + "staging recovery failed: \(recoveryError)")
                }
            }
            throw error
        }

        // The final pathname may have existed briefly as intent-bound 0755.
        // It is not a commit point: re-verify the exact modes, receipt and
        // EVERY artifact hash after the FD-bound freeze, fsync the library
        // root, then clear the durable publish intent.
        try validateExactDirectorySet(
            finalDirectory,
            expectedNames: committedNames,
            expectedDirectoryMode: 0o555,
            expectedFileMode: 0o444)
        try MobileMapLibrary.syncDirectory(finalDirectory)
        let verifiedEntry = try readResult(in: finalDirectory)
        try commitFaultInjector?(.afterRename)
        try MobileMapLibrary.syncDirectory(libraryRoot)
        try commitFaultInjector?(.afterParentFsync)
        guard let publishIntentRecord else {
            throw ResultError.commitFailed(
                "result publication lost its bound intent record")
        }
        let finalIdentity = try ImmutableDirectoryPublication.identity(
            of: finalDirectory,
            allowedModes: [ImmutableDirectoryPublication.immutableMode])
        guard finalIdentity == publishIntentRecord.intent.directoryIdentity else {
            throw ResultError.commitFailed(
                "result final identity changed before intent removal")
        }
        try removePublishIntent(
            publishIntentURL, expectedRecord: publishIntentRecord)

        return verifiedEntry
    }

    /// Recursively makes a committed result read-only: files 0444,
    /// directories 0555, then the directory itself (V1R5 §13.1). Any
    /// failure throws — the result must not be reported as committed
    /// while mutable.
    private static func freezeImmutably(
        _ directory: URL,
        freezeRootDirectory: Bool = true
    ) throws {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: []) else {
            throw ResultError.commitFailed(
                "cannot enumerate result for immutability")
        }
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(
                forKeys: [.isDirectoryKey, .isRegularFileKey])
            if values.isRegularFile == true {
                try fileManager.setAttributes(
                    [.posixPermissions: 0o444],
                    ofItemAtPath: fileURL.path)
            } else if values.isDirectory == true {
                try fileManager.setAttributes(
                    [.posixPermissions: 0o555],
                    ofItemAtPath: fileURL.path)
            }
        }
        try fileManager.setAttributes(
            [.posixPermissions: freezeRootDirectory ? 0o555 : 0o755],
            ofItemAtPath: directory.path)
    }

    /// Restores only an UNCOMMITTED task-scoped staging package to modes
    /// that can be removed or rebuilt after a failed/crashed pre-rename
    /// commit. This helper is never called for a final result path.
    private static func makeStagingRecoverable(_ directory: URL) throws {
        var directoryStat = stat()
        guard lstat(directory.path, &directoryStat) == 0,
              (directoryStat.st_mode & S_IFMT) == S_IFDIR else {
            throw ResultError.commitFailed(
                "cannot recover non-directory staging package")
        }
        let fileManager = FileManager.default
        try fileManager.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: directory.path)
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: []) else {
            throw ResultError.commitFailed(
                "cannot enumerate staging package for recovery")
        }
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(
                forKeys: [.isDirectoryKey, .isRegularFileKey])
            if values.isDirectory == true {
                try fileManager.setAttributes(
                    [.posixPermissions: 0o755], ofItemAtPath: fileURL.path)
            } else if values.isRegularFile == true {
                try fileManager.setAttributes(
                    [.posixPermissions: 0o644], ofItemAtPath: fileURL.path)
            }
        }
    }

    /// Restores only the exact intent-bound staging inode. All child access
    /// is relative to the already-open directory descriptor, so a replacement
    /// at the public pathname is preserved rather than chmod'ed as if it were
    /// the failed transaction's staging package.
    private static func makeStagingRecoverable(
        _ directory: URL,
        expectedIdentity: ImmutableDirectoryPublication.Identity,
        expectedNames: Set<String>
    ) throws {
        let parent = directory.deletingLastPathComponent()
        let openedParent = try openBoundDirectory(
            parent, context: "result staging recovery parent")
        defer { _ = close(openedParent.descriptor) }
        let directoryDescriptor = openat(
            openedParent.descriptor,
            directory.lastPathComponent,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard directoryDescriptor >= 0 else {
            throw ResultError.commitFailed(
                "cannot open intent-bound result staging for recovery")
        }
        defer { _ = close(directoryDescriptor) }
        var opened = stat()
        var pathMetadata = stat()
        guard fstat(directoryDescriptor, &opened) == 0,
              fstatat(
                openedParent.descriptor,
                directory.lastPathComponent,
                &pathMetadata,
                AT_SYMLINK_NOFOLLOW) == 0,
              sameDirectoryObject(opened, pathMetadata),
              metadataIdentity(opened) == expectedIdentity else {
            throw ResultError.commitFailed(
                "result staging recovery identity mismatch")
        }
        let names = try FileManager.default.contentsOfDirectory(
            atPath: directory.path)
        guard Set(names) == expectedNames,
              names.count == expectedNames.count else {
            throw ResultError.commitFailed(
                "result staging recovery file set changed")
        }
        guard fchmod(directoryDescriptor, mode_t(0o755)) == 0 else {
            throw ResultError.commitFailed(
                "cannot thaw intent-bound result staging root")
        }
        for name in expectedNames.sorted() {
            guard isSafeBasename(name) else {
                throw ResultError.commitFailed(
                    "unsafe result staging recovery child")
            }
            let childDescriptor = openat(
                directoryDescriptor,
                name,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            guard childDescriptor >= 0 else {
                throw ResultError.commitFailed(
                    "cannot open result staging recovery child: \(name)")
            }
            var child = stat()
            let childValid = fstat(childDescriptor, &child) == 0
                && (child.st_mode & S_IFMT) == S_IFREG
                && child.st_nlink == 1
                && fchmod(childDescriptor, mode_t(0o644)) == 0
            _ = close(childDescriptor)
            guard childValid else {
                throw ResultError.commitFailed(
                    "invalid result staging recovery child: \(name)")
            }
        }
        guard fsync(directoryDescriptor) == 0,
              fsync(openedParent.descriptor) == 0 else {
            throw ResultError.commitFailed(
                "cannot sync intent-bound result staging recovery")
        }
        var finalOpened = stat()
        var finalPath = stat()
        guard fstat(directoryDescriptor, &finalOpened) == 0,
              fstatat(
                openedParent.descriptor,
                directory.lastPathComponent,
                &finalPath,
                AT_SYMLINK_NOFOLLOW) == 0,
              sameDirectoryObject(opened, finalOpened),
              sameDirectoryObject(opened, finalPath),
              (finalOpened.st_mode & mode_t(0o777)) == 0o755 else {
            throw ResultError.commitFailed(
                "result staging recovery pathname changed")
        }
    }

    /// Lists committed results, re-validating each manifest and every
    /// artifact hash (§20.5). Corrupted/unknown root entries are moved
    /// into a durable quarantine package with an audit diagnostic.
    static func listResults() -> [ResultEntry] {
        libraryLock.lock()
        defer { libraryLock.unlock() }
        let processLock: ProcessLockHandle
        do {
            processLock = try acquireProcessLock()
        } catch {
            replaceListingDiagnostics([
                "result-library process lock failed closed: \(error)",
            ])
            return []
        }
        defer { releaseProcessLock(processLock) }
        let entries = listResultsLocked(processLock: processLock)
        do {
            try validateProcessLock(processLock)
            return entries
        } catch {
            let message =
                "result-library final process-lock validation failed closed: \(error)"
            appendListingDiagnostic(message)
            NSLog("MarketScanner result-library audit: %@", message)
            return []
        }
    }

    private static func listResultsLocked(
        processLock: ProcessLockHandle
    ) -> [ResultEntry] {
        replaceListingDiagnostics([])
        let fileManager = FileManager.default
        do {
            try recoverInterruptedPublicationsLocked()
        } catch {
            appendListingDiagnostic(
                "result publication recovery failed closed: \(error)")
            return []
        }
        guard let root = try? root(),
              let names = try? fileManager.contentsOfDirectory(atPath: root.path)
        else { return [] }
        var result: [ResultEntry] = []
        var quarantineFailed = false
        for name in names.sorted()
            where name != "staging" && name != "quarantine"
                && name != processLockFileName
                && !isPublishIntentTemporaryName(name)
                && !isHiddenStagingName(name)
                && !isPublishIntentName(name) {
            let directory = root.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            do {
                guard fileManager.fileExists(
                    atPath: directory.path, isDirectory: &isDirectory),
                    isDirectory.boolValue else {
                    throw ResultError.invalidManifest(
                        "result-library entry is not a directory")
                }
                result.append(try readResult(in: directory))
            } catch {
                do {
                    let quarantineID = try quarantine(
                        directory,
                        sourceName: name,
                        reason: error,
                        processLock: processLock)
                    appendListingDiagnostic(
                        "quarantined \(name) as \(quarantineID): \(error)")
                } catch let quarantineError {
                    quarantineFailed = true
                    let message = "failed to quarantine \(name): \(error); "
                        + "quarantine error: \(quarantineError)"
                    appendListingDiagnostic(message)
                    NSLog("MarketScanner result-library audit: %@", message)
                }
            }
        }
        if quarantineFailed { return [] }
        return result.sorted { $0.createdAtUTC > $1.createdAtUTC }
    }

    /// Quarantines one invalid root entry through a crash-recoverable hidden
    /// wrapper transaction.  The canonical v2 diagnostic is durable and binds
    /// source + wrapper dev/inode before the source pathname can be moved.
    /// Only a fully frozen, verified wrapper is atomically published.
    @discardableResult
    private static func quarantine(
        _ source: URL,
        sourceName: String,
        reason: Error,
        processLock: ProcessLockHandle
    ) throws -> String {
        try validateProcessLock(processLock)
        let libraryRoot = try root()
        guard source.deletingLastPathComponent().path == libraryRoot.path,
              source.lastPathComponent == sourceName,
              isSafeInternalBasename(sourceName),
              sourceName != "quarantine",
              sourceName != processLockFileName else {
            throw ResultError.commitFailed(
                "invalid result quarantine source binding")
        }
        let quarantineRoot = libraryRoot.appendingPathComponent(
            "quarantine", isDirectory: true)
        try ensureResultQuarantineRoot(
            quarantineRoot, libraryRoot: libraryRoot)
        let openedLibraryRoot = try openBoundDirectory(
            libraryRoot, context: "result quarantine library root")
        defer { _ = close(openedLibraryRoot.descriptor) }
        let openedQuarantineRoot = try openBoundDirectory(
            quarantineRoot, context: "result quarantine root")
        defer { _ = close(openedQuarantineRoot.descriptor) }

        var sourcePathMetadata = stat()
        guard fstatat(
            openedLibraryRoot.descriptor,
            sourceName,
            &sourcePathMetadata,
            AT_SYMLINK_NOFOLLOW) == 0 else {
            throw ResultError.commitFailed(
                "cannot stat invalid result-library entry")
        }
        let payloadType: ResultQuarantinePayloadType
        let sourceOpenFlags: Int32
        switch sourcePathMetadata.st_mode & S_IFMT {
        case S_IFDIR:
            payloadType = .directory
            sourceOpenFlags = O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        case S_IFREG:
            guard sourcePathMetadata.st_nlink == 1 else {
                throw ResultError.commitFailed(
                    "invalid result quarantine source is hardlinked")
            }
            payloadType = .regular
            sourceOpenFlags = O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        case S_IFLNK:
            payloadType = .symbolicLink
            sourceOpenFlags = O_RDONLY | O_CLOEXEC | O_SYMLINK
        default:
            throw ResultError.commitFailed(
                "invalid result quarantine source is a special file")
        }
        let sourceDescriptor = openat(
            openedLibraryRoot.descriptor, sourceName, sourceOpenFlags)
        guard sourceDescriptor >= 0 else {
            throw ResultError.commitFailed(
                "cannot open invalid result quarantine source without following links")
        }
        defer { _ = close(sourceDescriptor) }
        var sourceOpenedMetadata = stat()
        guard fstat(sourceDescriptor, &sourceOpenedMetadata) == 0,
              sameResultQuarantinePayloadObject(
                sourcePathMetadata,
                sourceOpenedMetadata,
                type: payloadType) else {
            throw ResultError.commitFailed(
                "invalid result quarantine source changed while opening")
        }

        let quarantineID = "quarantine-\(UUID().uuidString.lowercased())"
        let pendingName = ".\(quarantineID)\(resultQuarantinePendingSuffix)"
        let diagnosticTemporaryName =
            ".\(quarantineID)\(resultQuarantineDiagnosticTemporarySuffix)"
        let pendingWrapper = quarantineRoot.appendingPathComponent(
            pendingName, isDirectory: true)
        let finalWrapper = quarantineRoot.appendingPathComponent(
            quarantineID, isDirectory: true)
        guard mkdirat(
            openedQuarantineRoot.descriptor,
            pendingName,
            mode_t(0o755)) == 0 else {
            throw ResultError.commitFailed(
                "cannot create result quarantine pending wrapper: "
                    + String(cString: strerror(errno)))
        }
        guard fsync(openedQuarantineRoot.descriptor) == 0 else {
            throw ResultError.commitFailed(
                "cannot sync result quarantine pending creation")
        }
        let pendingDescriptor = openat(
            openedQuarantineRoot.descriptor,
            pendingName,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard pendingDescriptor >= 0 else {
            throw ResultError.commitFailed(
                "cannot open result quarantine pending wrapper")
        }
        defer { _ = close(pendingDescriptor) }
        var wrapperMetadata = stat()
        guard fstat(pendingDescriptor, &wrapperMetadata) == 0,
              (wrapperMetadata.st_mode & S_IFMT) == S_IFDIR,
              (wrapperMetadata.st_mode & mode_t(0o777)) == 0o755 else {
            throw ResultError.commitFailed(
                "result quarantine pending wrapper identity/mode invalid")
        }

        let rawReason = String(describing: reason)
        let boundedReason = String(rawReason.unicodeScalars.prefix(1024))
        let originalSourceMode = mode_t(sourceOpenedMetadata.st_mode & 0o777)
        let diagnosticPayload: [String: Any] = [
            "format": resultQuarantineDiagnosticFormat,
            "version": resultQuarantineDiagnosticVersion,
            "quarantine_id": quarantineID,
            "source_name": sourceName,
            "source_mode": Int(originalSourceMode),
            "payload": resultQuarantinePayloadName,
            "payload_type": payloadType.rawValue,
            "payload_device": String(UInt64(sourceOpenedMetadata.st_dev)),
            "payload_inode": String(UInt64(sourceOpenedMetadata.st_ino)),
            "wrapper_device": String(UInt64(wrapperMetadata.st_dev)),
            "wrapper_inode": String(UInt64(wrapperMetadata.st_ino)),
            "reason": boundedReason.isEmpty ? "unknown result validation failure" : boundedReason,
            "created_at_utc": Date().timeIntervalSince1970,
        ]
        let diagnosticData = try CanonicalJSONEncoder.encode(diagnosticPayload)
        try writeFrozenResultQuarantineIntent(
            diagnosticData,
            canonicalBasename: diagnosticTemporaryName,
            parentDescriptor: openedQuarantineRoot.descriptor)
        try quarantineFaultInjector?(.afterIntentDurableBeforeSourceMove)

        guard renameatx_np(
            openedQuarantineRoot.descriptor,
            diagnosticTemporaryName,
            pendingDescriptor,
            quarantineDiagnosticFileName,
            UInt32(RENAME_EXCL)) == 0,
              fsync(pendingDescriptor) == 0,
              fsync(openedQuarantineRoot.descriptor) == 0 else {
            throw ResultError.commitFailed(
                "cannot place durable result quarantine diagnostic")
        }

        var sourceModeChanged = false
        var sourceMoved = false
        if payloadType == .directory,
           (originalSourceMode & mode_t(S_IWUSR)) == 0 {
            guard fchmod(
                sourceDescriptor,
                originalSourceMode | mode_t(S_IWUSR)) == 0,
                  fsync(sourceDescriptor) == 0 else {
                throw ResultError.commitFailed(
                    "cannot unlock invalid result directory for isolation")
            }
            sourceModeChanged = true
        }
        defer {
            if sourceModeChanged && !sourceMoved {
                _ = fchmod(sourceDescriptor, originalSourceMode)
                _ = fsync(sourceDescriptor)
            }
        }
        var sourceBeforeMove = stat()
        var payloadBeforeMove = stat()
        guard fstatat(
            openedLibraryRoot.descriptor,
            sourceName,
            &sourceBeforeMove,
            AT_SYMLINK_NOFOLLOW) == 0,
              sameResultQuarantinePayloadObject(
                sourceOpenedMetadata,
                sourceBeforeMove,
                type: payloadType),
              metadataIdentity(sourceBeforeMove)
                == metadataIdentity(sourceOpenedMetadata),
              fstatat(
                pendingDescriptor,
                resultQuarantinePayloadName,
                &payloadBeforeMove,
                AT_SYMLINK_NOFOLLOW) != 0,
              errno == ENOENT else {
            throw ResultError.commitFailed(
                "result quarantine source/payload authority changed before move")
        }
        try validateProcessLock(processLock)
        guard renameatx_np(
            openedLibraryRoot.descriptor,
            sourceName,
            pendingDescriptor,
            resultQuarantinePayloadName,
            UInt32(RENAME_EXCL)) == 0 else {
            let renameError = errno
            throw ResultError.commitFailed(
                "cannot isolate invalid result-library entry: "
                    + String(cString: strerror(renameError)))
        }
        sourceMoved = true
        guard fsync(openedLibraryRoot.descriptor) == 0,
              fsync(pendingDescriptor) == 0 else {
            throw ResultError.commitFailed(
                "cannot sync moved result quarantine payload")
        }
        try quarantineFaultInjector?(.afterSourceMoveBeforeFreeze)

        let diagnostic = try readResultQuarantineDiagnostic(
            parentDescriptor: pendingDescriptor,
            basename: quarantineDiagnosticFileName,
            expectedQuarantineID: quarantineID)
        try freezeResultQuarantineWrapper(
            descriptor: pendingDescriptor,
            diagnostic: diagnostic)
        try verifyResultQuarantineWrapper(
            descriptor: pendingDescriptor,
            diagnostic: diagnostic,
            expectedRootMode: ImmutableDirectoryPublication.renameableMode)
        try quarantineFaultInjector?(.afterPreparedBeforePublish)
        try validateProcessLock(processLock)
        try ImmutableDirectoryPublication.publish(
            source: pendingWrapper,
            destination: finalWrapper,
            expectedIdentity: metadataIdentity(wrapperMetadata),
            afterRenameBeforeFreeze: {
                try quarantineFaultInjector?(.afterPublishRenameBeforeFreeze)
            },
            afterFreezeBeforeParentSync: {
                try quarantineFaultInjector?(
                    .afterPublishFreezeBeforeParentSync)
            })
        try verifyResultQuarantineWrapper(
            finalWrapper,
            diagnostic: diagnostic,
            expectedRootMode: ImmutableDirectoryPublication.immutableMode)
        try MobileMapLibrary.syncDirectory(finalWrapper)
        guard fsync(openedQuarantineRoot.descriptor) == 0,
              fsync(openedLibraryRoot.descriptor) == 0 else {
            throw ResultError.commitFailed(
                "cannot sync published result quarantine wrapper")
        }
        try validateProcessLock(processLock)
        return quarantineID
    }

    private static func ensureResultQuarantineRoot(
        _ quarantineRoot: URL,
        libraryRoot: URL
    ) throws {
        guard quarantineRoot.deletingLastPathComponent().standardizedFileURL
                == libraryRoot.standardizedFileURL,
              quarantineRoot.lastPathComponent == "quarantine" else {
            throw ResultError.commitFailed(
                "invalid result quarantine root binding")
        }
        let openedLibraryRoot = try openBoundDirectory(
            libraryRoot, context: "result quarantine root parent")
        defer { _ = close(openedLibraryRoot.descriptor) }
        var metadata = stat()
        if fstatat(
            openedLibraryRoot.descriptor,
            quarantineRoot.lastPathComponent,
            &metadata,
            AT_SYMLINK_NOFOLLOW) != 0 {
            guard errno == ENOENT,
                  mkdirat(
                    openedLibraryRoot.descriptor,
                    quarantineRoot.lastPathComponent,
                    mode_t(0o755)) == 0,
                  fsync(openedLibraryRoot.descriptor) == 0 else {
                throw ResultError.commitFailed(
                    "cannot create durable result quarantine root")
            }
        }
        let descriptor = openat(
            openedLibraryRoot.descriptor,
            quarantineRoot.lastPathComponent,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw ResultError.commitFailed(
                "cannot open result quarantine root without following links")
        }
        defer { _ = close(descriptor) }
        var opened = stat()
        var path = stat()
        guard fstat(descriptor, &opened) == 0,
              fstatat(
                openedLibraryRoot.descriptor,
                quarantineRoot.lastPathComponent,
                &path,
                AT_SYMLINK_NOFOLLOW) == 0,
              sameDirectoryObject(opened, path),
              (opened.st_mode & mode_t(0o777)) == 0o755 else {
            throw ResultError.commitFailed(
                "result quarantine root identity/mode invalid")
        }
        try requireBoundDirectoryPath(
            descriptor: openedLibraryRoot.descriptor,
            url: libraryRoot,
            expectedMetadata: openedLibraryRoot.metadata,
            context: "result quarantine root parent after creation")
    }

    private static func sameResultQuarantinePayloadObject(
        _ lhs: stat,
        _ rhs: stat,
        type: ResultQuarantinePayloadType
    ) -> Bool {
        let expectedType: mode_t
        switch type {
        case .directory: expectedType = S_IFDIR
        case .regular: expectedType = S_IFREG
        case .symbolicLink: expectedType = S_IFLNK
        }
        guard (lhs.st_mode & S_IFMT) == expectedType,
              (rhs.st_mode & S_IFMT) == expectedType,
              lhs.st_dev == rhs.st_dev,
              lhs.st_ino == rhs.st_ino else {
            return false
        }
        if type == .regular {
            return lhs.st_nlink == 1 && rhs.st_nlink == 1
        }
        return true
    }

    private static func writeFrozenResultQuarantineIntent(
        _ data: Data,
        canonicalBasename: String,
        parentDescriptor: Int32
    ) throws {
        guard !data.isEmpty,
              data.count <= maximumResultQuarantineDiagnosticBytes,
              isSafeInternalBasename(canonicalBasename),
              canonicalBasename.hasPrefix(".quarantine-"),
              canonicalBasename.hasSuffix(
                resultQuarantineDiagnosticTemporarySuffix) else {
            throw ResultError.commitFailed(
                "invalid result quarantine diagnostic intent request")
        }
        let temporaryUUID = UUID().uuidString.lowercased()
        var temporaryName = resultQuarantineIntentCreationPrefix
            + temporaryUUID
        let descriptor = openat(
            parentDescriptor,
            temporaryName,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            mode_t(0o600))
        guard descriptor >= 0 else {
            throw ResultError.commitFailed(
                "cannot create result quarantine diagnostic temporary")
        }
        var descriptorOpen = true
        var installedCanonical = false
        var cleanupMetadata: stat?
        defer {
            if descriptorOpen { _ = close(descriptor) }
            if !installedCanonical, let cleanupMetadata {
                try? removeIdentityBoundResultQuarantineTemporary(
                    parentDescriptor: parentDescriptor,
                    basename: temporaryName,
                    expectedMetadata: cleanupMetadata,
                    context: "failed result quarantine diagnostic temporary")
            }
        }
        var created = stat()
        guard fstat(descriptor, &created) == 0,
              (created.st_mode & S_IFMT) == S_IFREG,
              (created.st_mode & mode_t(0o777)) == 0o600,
              created.st_nlink == 1,
              created.st_size == 0 else {
            throw ResultError.commitFailed(
                "result quarantine diagnostic creation identity invalid")
        }
        cleanupMetadata = created
        let boundName = resultQuarantineIntentTemporaryPrefix
            + identityToken(metadataIdentity(created)) + "."
            + temporaryUUID
        guard renameatx_np(
            parentDescriptor, temporaryName,
            parentDescriptor, boundName,
            UInt32(RENAME_EXCL)) == 0,
              fsync(parentDescriptor) == 0 else {
            throw ResultError.commitFailed(
                "cannot durably bind result quarantine diagnostic temporary")
        }
        temporaryName = boundName
        var offset = 0
        let wroteAll = data.withUnsafeBytes { rawBuffer -> Bool in
            guard let base = rawBuffer.baseAddress else { return data.isEmpty }
            while offset < rawBuffer.count {
                let count = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    rawBuffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                if count <= 0 { return false }
                offset += count
            }
            return true
        }
        var persisted = stat()
        guard wroteAll,
              fchmod(descriptor, mode_t(0o444)) == 0,
              fsync(descriptor) == 0,
              fstat(descriptor, &persisted) == 0,
              (persisted.st_mode & S_IFMT) == S_IFREG,
              (persisted.st_mode & mode_t(0o777)) == 0o444,
              persisted.st_nlink == 1,
              persisted.st_size == data.count,
              metadataIdentity(persisted) == metadataIdentity(created),
              close(descriptor) == 0 else {
            throw ResultError.commitFailed(
                "cannot persist frozen result quarantine diagnostic temporary")
        }
        descriptorOpen = false
        cleanupMetadata = persisted
        var temporaryAuthority = stat()
        guard fstatat(
            parentDescriptor,
            temporaryName,
            &temporaryAuthority,
            AT_SYMLINK_NOFOLLOW) == 0,
              sameStableRegularFile(persisted, temporaryAuthority),
              renameatx_np(
                parentDescriptor, temporaryName,
                parentDescriptor, canonicalBasename,
                UInt32(RENAME_EXCL)) == 0 else {
            throw ResultError.commitFailed(
                "cannot install result quarantine diagnostic intent exclusively")
        }
        installedCanonical = true
        guard fsync(parentDescriptor) == 0 else {
            throw ResultError.commitFailed(
                "cannot sync result quarantine diagnostic intent")
        }
        let installed = try readStableSmallRegularFileRecord(
            parentDescriptor: parentDescriptor,
            basename: canonicalBasename,
            maximumBytes: maximumResultQuarantineDiagnosticBytes,
            requiredMode: 0o444)
        guard installed.data == data,
              installed.identity == metadataIdentity(created) else {
            throw ResultError.commitFailed(
                "installed result quarantine diagnostic authority mismatch")
        }
    }

    private static func readResultQuarantineDiagnostic(
        parentDescriptor: Int32,
        basename: String,
        expectedQuarantineID: String,
        allowedVersions: Set<Int> = [1, 2]
    ) throws -> ResultQuarantineDiagnostic {
        guard isCanonicalResultQuarantineID(expectedQuarantineID) else {
            throw ResultError.commitFailed(
                "invalid expected result quarantine identity")
        }
        let stable = try readStableSmallRegularFileRecord(
            parentDescriptor: parentDescriptor,
            basename: basename,
            maximumBytes: maximumResultQuarantineDiagnosticBytes,
            requiredMode: 0o444)
        let data = stable.data
        guard let object = try? StrictJSONDocumentParser.object(
            from: data,
            limits: StrictJSONDocumentLimits(
                maximumBytes: maximumResultQuarantineDiagnosticBytes))
                as? [String: Any],
              object["format"] as? String
                == resultQuarantineDiagnosticFormat,
              let version = StrictJSONScalar.integer(object["version"]),
              allowedVersions.contains(version),
              let quarantineID = object["quarantine_id"] as? String,
              quarantineID == expectedQuarantineID,
              isCanonicalResultQuarantineID(quarantineID),
              let sourceName = object["source_name"] as? String,
              isSafeInternalBasename(sourceName),
              sourceName != "quarantine",
              sourceName != processLockFileName,
              let reason = object["reason"] as? String,
              !reason.isEmpty,
              reason.utf8.count <= maximumResultQuarantineDiagnosticBytes,
              let createdAtUTC = StrictJSONScalar.number(
                object["created_at_utc"]),
              createdAtUTC > 0,
              object["payload"] as? String
                == resultQuarantinePayloadName else {
            throw ResultError.commitFailed(
                "invalid result quarantine diagnostic: \(basename)")
        }
        if version == 1 {
            guard Set(object.keys) == Set([
                "format", "version", "quarantine_id", "source_name",
                "reason", "created_at_utc", "payload",
            ]) else {
                throw ResultError.commitFailed(
                    "invalid historical result quarantine diagnostic schema")
            }
            let canonical: [String: Any] = [
                "format": resultQuarantineDiagnosticFormat,
                "version": 1,
                "quarantine_id": quarantineID,
                "source_name": sourceName,
                "reason": reason,
                "created_at_utc": createdAtUTC,
                "payload": resultQuarantinePayloadName,
            ]
            guard (try? CanonicalJSONEncoder.encode(canonical)) == data else {
                throw ResultError.commitFailed(
                    "non-canonical historical result quarantine diagnostic")
            }
            return ResultQuarantineDiagnostic(
                version: version,
                quarantineID: quarantineID,
                sourceName: sourceName,
                sourceMode: nil,
                payloadType: nil,
                payloadIdentity: nil,
                wrapperIdentity: nil,
                reason: reason,
                createdAtUTC: createdAtUTC,
                canonicalData: data)
        }
        guard version == resultQuarantineDiagnosticVersion,
              Set(object.keys) == Set([
                "format", "version", "quarantine_id", "source_name",
                "source_mode", "payload", "payload_type",
                "payload_device", "payload_inode", "wrapper_device",
                "wrapper_inode", "reason", "created_at_utc",
              ]),
              let sourceModeValue = StrictJSONScalar.integer(
                object["source_mode"]),
              (0...0o777).contains(sourceModeValue),
              let payloadTypeText = object["payload_type"] as? String,
              let payloadType = ResultQuarantinePayloadType(
                rawValue: payloadTypeText),
              let payloadDeviceText = object["payload_device"] as? String,
              let payloadInodeText = object["payload_inode"] as? String,
              let wrapperDeviceText = object["wrapper_device"] as? String,
              let wrapperInodeText = object["wrapper_inode"] as? String,
              isCanonicalUnsignedDecimal(payloadDeviceText),
              isCanonicalUnsignedDecimal(payloadInodeText),
              isCanonicalUnsignedDecimal(wrapperDeviceText),
              isCanonicalUnsignedDecimal(wrapperInodeText),
              let payloadDevice = UInt64(payloadDeviceText),
              let payloadInode = UInt64(payloadInodeText),
              let wrapperDevice = UInt64(wrapperDeviceText),
              let wrapperInode = UInt64(wrapperInodeText) else {
            throw ResultError.commitFailed(
                "invalid v2 result quarantine diagnostic schema")
        }
        let canonical: [String: Any] = [
            "format": resultQuarantineDiagnosticFormat,
            "version": resultQuarantineDiagnosticVersion,
            "quarantine_id": quarantineID,
            "source_name": sourceName,
            "source_mode": sourceModeValue,
            "payload": resultQuarantinePayloadName,
            "payload_type": payloadTypeText,
            "payload_device": payloadDeviceText,
            "payload_inode": payloadInodeText,
            "wrapper_device": wrapperDeviceText,
            "wrapper_inode": wrapperInodeText,
            "reason": reason,
            "created_at_utc": createdAtUTC,
        ]
        guard (try? CanonicalJSONEncoder.encode(canonical)) == data else {
            throw ResultError.commitFailed(
                "non-canonical v2 result quarantine diagnostic")
        }
        return ResultQuarantineDiagnostic(
            version: version,
            quarantineID: quarantineID,
            sourceName: sourceName,
            sourceMode: mode_t(sourceModeValue),
            payloadType: payloadType,
            payloadIdentity: ImmutableDirectoryPublication.Identity(
                device: payloadDevice, inode: payloadInode),
            wrapperIdentity: ImmutableDirectoryPublication.Identity(
                device: wrapperDevice, inode: wrapperInode),
            reason: reason,
            createdAtUTC: createdAtUTC,
            canonicalData: data)
    }

    private static func freezeResultQuarantineWrapper(
        descriptor: Int32,
        diagnostic: ResultQuarantineDiagnostic
    ) throws {
        guard diagnostic.version == resultQuarantineDiagnosticVersion,
              let wrapperIdentity = diagnostic.wrapperIdentity,
              let payloadIdentity = diagnostic.payloadIdentity,
              let payloadType = diagnostic.payloadType else {
            throw ResultError.commitFailed(
                "historical diagnostic cannot authorize quarantine preparation")
        }
        var wrapper = stat()
        guard fstat(descriptor, &wrapper) == 0,
              (wrapper.st_mode & S_IFMT) == S_IFDIR,
              (wrapper.st_mode & mode_t(0o777))
                == ImmutableDirectoryPublication.renameableMode,
              metadataIdentity(wrapper) == wrapperIdentity else {
            throw ResultError.commitFailed(
                "result quarantine wrapper authority changed before freeze")
        }
        let names = try directoryEntryNames(
            atBoundDirectoryDescriptor: descriptor,
            context: "result quarantine wrapper before freeze")
        guard Set(names) == Set([
            quarantineDiagnosticFileName,
            resultQuarantinePayloadName,
        ]) else {
            throw ResultError.commitFailed(
                "result quarantine wrapper has unexpected entries")
        }
        let embedded = try readResultQuarantineDiagnostic(
            parentDescriptor: descriptor,
            basename: quarantineDiagnosticFileName,
            expectedQuarantineID: diagnostic.quarantineID,
            allowedVersions: [resultQuarantineDiagnosticVersion])
        guard embedded.canonicalData == diagnostic.canonicalData else {
            throw ResultError.commitFailed(
                "result quarantine diagnostic changed before freeze")
        }
        try freezeResultQuarantineEntry(
            parentDescriptor: descriptor,
            basename: resultQuarantinePayloadName,
            expectedType: payloadType,
            expectedIdentity: payloadIdentity)
        guard fsync(descriptor) == 0 else {
            throw ResultError.commitFailed(
                "cannot sync prepared result quarantine wrapper")
        }
    }

    private static func freezeResultQuarantineEntry(
        parentDescriptor: Int32,
        basename: String,
        expectedType: ResultQuarantinePayloadType? = nil,
        expectedIdentity: ImmutableDirectoryPublication.Identity? = nil
    ) throws {
        var pathBefore = stat()
        guard fstatat(
            parentDescriptor,
            basename,
            &pathBefore,
            AT_SYMLINK_NOFOLLOW) == 0 else {
            throw ResultError.commitFailed(
                "cannot inspect result quarantine payload entry")
        }
        let type: ResultQuarantinePayloadType
        switch pathBefore.st_mode & S_IFMT {
        case S_IFDIR: type = .directory
        case S_IFREG:
            guard pathBefore.st_nlink == 1 else {
                throw ResultError.commitFailed(
                    "result quarantine payload contains a hardlink")
            }
            type = .regular
        case S_IFLNK: type = .symbolicLink
        default:
            throw ResultError.commitFailed(
                "result quarantine payload contains a special file")
        }
        if let expectedType, expectedType != type {
            throw ResultError.commitFailed(
                "result quarantine payload type changed")
        }
        if let expectedIdentity,
           metadataIdentity(pathBefore) != expectedIdentity {
            throw ResultError.commitFailed(
                "result quarantine payload identity changed")
        }
        if type == .symbolicLink {
            guard expectedType == .symbolicLink else {
                throw ResultError.commitFailed(
                    "result quarantine directory contains a symbolic link")
            }
            let descriptor = openat(
                parentDescriptor,
                basename,
                O_RDONLY | O_CLOEXEC | O_SYMLINK)
            guard descriptor >= 0 else {
                throw ResultError.commitFailed(
                    "cannot bind result quarantine symbolic-link payload")
            }
            defer { _ = close(descriptor) }
            var opened = stat()
            var pathAfter = stat()
            guard fstat(descriptor, &opened) == 0,
                  fstatat(
                    parentDescriptor,
                    basename,
                    &pathAfter,
                    AT_SYMLINK_NOFOLLOW) == 0,
                  sameResultQuarantinePayloadObject(
                    pathBefore, opened, type: .symbolicLink),
                  sameResultQuarantinePayloadObject(
                    pathBefore, pathAfter, type: .symbolicLink) else {
                throw ResultError.commitFailed(
                    "result quarantine symbolic-link payload changed")
            }
            return
        }
        if type == .regular {
            let descriptor = openat(
                parentDescriptor,
                basename,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            guard descriptor >= 0 else {
                throw ResultError.commitFailed(
                    "cannot open result quarantine regular payload")
            }
            defer { _ = close(descriptor) }
            var opened = stat()
            guard fstat(descriptor, &opened) == 0,
                  sameResultQuarantinePayloadObject(
                    pathBefore, opened, type: .regular),
                  fchmod(descriptor, mode_t(0o444)) == 0,
                  fsync(descriptor) == 0 else {
                throw ResultError.commitFailed(
                    "cannot freeze result quarantine regular payload")
            }
            var openedAfter = stat()
            var pathAfter = stat()
            guard fstat(descriptor, &openedAfter) == 0,
                  fstatat(
                    parentDescriptor,
                    basename,
                    &pathAfter,
                    AT_SYMLINK_NOFOLLOW) == 0,
                  sameResultQuarantinePayloadObject(
                    opened, openedAfter, type: .regular),
                  sameResultQuarantinePayloadObject(
                    opened, pathAfter, type: .regular),
                  (openedAfter.st_mode & mode_t(0o777)) == 0o444,
                  (pathAfter.st_mode & mode_t(0o777)) == 0o444 else {
                throw ResultError.commitFailed(
                    "result quarantine regular payload changed during freeze")
            }
            return
        }
        let descriptor = openat(
            parentDescriptor,
            basename,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw ResultError.commitFailed(
                "cannot open result quarantine directory payload")
        }
        defer { _ = close(descriptor) }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0,
              sameResultQuarantinePayloadObject(
                pathBefore, opened, type: .directory) else {
            throw ResultError.commitFailed(
                "result quarantine directory payload changed while opening")
        }
        let childNames = try directoryEntryNames(
            atBoundDirectoryDescriptor: descriptor,
            context: "result quarantine payload directory")
        for childName in childNames {
            try freezeResultQuarantineEntry(
                parentDescriptor: descriptor,
                basename: childName)
        }
        guard fchmod(descriptor, mode_t(0o555)) == 0,
              fsync(descriptor) == 0 else {
            throw ResultError.commitFailed(
                "cannot freeze result quarantine directory payload")
        }
        var openedAfter = stat()
        var pathAfter = stat()
        guard fstat(descriptor, &openedAfter) == 0,
              fstatat(
                parentDescriptor,
                basename,
                &pathAfter,
                AT_SYMLINK_NOFOLLOW) == 0,
              sameResultQuarantinePayloadObject(
                opened, openedAfter, type: .directory),
              sameResultQuarantinePayloadObject(
                opened, pathAfter, type: .directory),
              (openedAfter.st_mode & mode_t(0o777)) == 0o555,
              (pathAfter.st_mode & mode_t(0o777)) == 0o555,
              try directoryEntryNames(
                atBoundDirectoryDescriptor: descriptor,
                context: "result quarantine payload directory after freeze")
                == childNames else {
            throw ResultError.commitFailed(
                "result quarantine directory payload changed during freeze")
        }
    }

    private static func verifyResultQuarantineWrapper(
        _ url: URL,
        diagnostic: ResultQuarantineDiagnostic,
        expectedRootMode: mode_t
    ) throws {
        let opened = try openBoundDirectory(
            url, context: "result quarantine wrapper verification")
        defer { _ = close(opened.descriptor) }
        try verifyResultQuarantineWrapper(
            descriptor: opened.descriptor,
            diagnostic: diagnostic,
            expectedRootMode: expectedRootMode)
        try requireBoundDirectoryPath(
            descriptor: opened.descriptor,
            url: url,
            expectedMetadata: opened.metadata,
            context: "result quarantine wrapper after verification")
    }

    private static func verifyResultQuarantineWrapper(
        descriptor: Int32,
        diagnostic: ResultQuarantineDiagnostic,
        expectedRootMode: mode_t
    ) throws {
        var rootMetadata = stat()
        guard fstat(descriptor, &rootMetadata) == 0,
              (rootMetadata.st_mode & S_IFMT) == S_IFDIR,
              (rootMetadata.st_mode & mode_t(0o777)) == expectedRootMode else {
            throw ResultError.commitFailed(
                "result quarantine wrapper root mode/type invalid")
        }
        if let wrapperIdentity = diagnostic.wrapperIdentity,
           metadataIdentity(rootMetadata) != wrapperIdentity {
            throw ResultError.commitFailed(
                "result quarantine wrapper identity mismatch")
        }
        let names = try directoryEntryNames(
            atBoundDirectoryDescriptor: descriptor,
            context: "result quarantine wrapper verification")
        guard Set(names) == Set([
            quarantineDiagnosticFileName,
            resultQuarantinePayloadName,
        ]) else {
            throw ResultError.commitFailed(
                "result quarantine wrapper exact file set invalid")
        }
        let embedded = try readResultQuarantineDiagnostic(
            parentDescriptor: descriptor,
            basename: quarantineDiagnosticFileName,
            expectedQuarantineID: diagnostic.quarantineID,
            allowedVersions: [diagnostic.version])
        guard embedded.canonicalData == diagnostic.canonicalData else {
            throw ResultError.commitFailed(
                "result quarantine embedded diagnostic changed")
        }
        // Historical v1 diagnostics predate `payload_type`. The old writer
        // could quarantine a root-level symbolic link by renaming the link
        // object itself. Infer only that top-level legacy case from lstat;
        // nested links remain forbidden by the recursive verifier.
        var expectedPayloadType = diagnostic.payloadType
        if diagnostic.version == 1 {
            var legacyPayloadMetadata = stat()
            guard fstatat(
                descriptor,
                resultQuarantinePayloadName,
                &legacyPayloadMetadata,
                AT_SYMLINK_NOFOLLOW) == 0 else {
                throw ResultError.commitFailed(
                    "cannot inspect historical result quarantine payload")
            }
            if legacyPayloadMetadata.st_mode & S_IFMT == S_IFLNK {
                expectedPayloadType = .symbolicLink
            }
        }
        try verifyImmutableResultQuarantineEntry(
            parentDescriptor: descriptor,
            basename: resultQuarantinePayloadName,
            expectedType: expectedPayloadType,
            expectedIdentity: diagnostic.payloadIdentity)
        var rootAfter = stat()
        guard fstat(descriptor, &rootAfter) == 0,
              sameDirectoryObject(rootMetadata, rootAfter),
              (rootAfter.st_mode & mode_t(0o777)) == expectedRootMode else {
            throw ResultError.commitFailed(
                "result quarantine wrapper changed during verification")
        }
    }

    private static func verifyImmutableResultQuarantineEntry(
        parentDescriptor: Int32,
        basename: String,
        expectedType: ResultQuarantinePayloadType? = nil,
        expectedIdentity: ImmutableDirectoryPublication.Identity? = nil
    ) throws {
        var pathBefore = stat()
        guard fstatat(
            parentDescriptor,
            basename,
            &pathBefore,
            AT_SYMLINK_NOFOLLOW) == 0 else {
            throw ResultError.commitFailed(
                "cannot inspect immutable result quarantine payload")
        }
        let type: ResultQuarantinePayloadType
        switch pathBefore.st_mode & S_IFMT {
        case S_IFDIR: type = .directory
        case S_IFREG: type = .regular
        case S_IFLNK: type = .symbolicLink
        default:
            throw ResultError.commitFailed(
                "immutable result quarantine contains a special file")
        }
        if let expectedType, expectedType != type {
            throw ResultError.commitFailed(
                "immutable result quarantine payload type mismatch")
        }
        if let expectedIdentity,
           metadataIdentity(pathBefore) != expectedIdentity {
            throw ResultError.commitFailed(
                "immutable result quarantine payload identity mismatch")
        }
        if type == .symbolicLink {
            guard expectedType == .symbolicLink else {
                throw ResultError.commitFailed(
                    "immutable result quarantine directory contains a symbolic link")
            }
            let descriptor = openat(
                parentDescriptor,
                basename,
                O_RDONLY | O_CLOEXEC | O_SYMLINK)
            guard descriptor >= 0 else {
                throw ResultError.commitFailed(
                    "cannot bind immutable result quarantine symbolic link")
            }
            defer { _ = close(descriptor) }
            var opened = stat()
            var pathAfter = stat()
            guard fstat(descriptor, &opened) == 0,
                  fstatat(
                    parentDescriptor,
                    basename,
                    &pathAfter,
                    AT_SYMLINK_NOFOLLOW) == 0,
                  sameResultQuarantinePayloadObject(
                    pathBefore, opened, type: .symbolicLink),
                  sameResultQuarantinePayloadObject(
                    pathBefore, pathAfter, type: .symbolicLink) else {
                throw ResultError.commitFailed(
                    "immutable result quarantine symbolic link changed")
            }
            return
        }
        if type == .regular {
            guard pathBefore.st_nlink == 1,
                  (pathBefore.st_mode & mode_t(0o777)) == 0o444 else {
                throw ResultError.commitFailed(
                    "immutable result quarantine regular mode/link invalid")
            }
            let descriptor = openat(
                parentDescriptor,
                basename,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            guard descriptor >= 0 else {
                throw ResultError.commitFailed(
                    "cannot open immutable result quarantine regular file")
            }
            defer { _ = close(descriptor) }
            var opened = stat()
            var pathAfter = stat()
            guard fstat(descriptor, &opened) == 0,
                  fstatat(
                    parentDescriptor,
                    basename,
                    &pathAfter,
                    AT_SYMLINK_NOFOLLOW) == 0,
                  sameStableRegularFile(pathBefore, opened),
                  sameStableRegularFile(pathBefore, pathAfter) else {
                throw ResultError.commitFailed(
                    "immutable result quarantine regular file changed")
            }
            return
        }
        guard (pathBefore.st_mode & mode_t(0o777)) == 0o555 else {
            throw ResultError.commitFailed(
                "immutable result quarantine directory mode invalid")
        }
        let descriptor = openat(
            parentDescriptor,
            basename,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw ResultError.commitFailed(
                "cannot open immutable result quarantine directory")
        }
        defer { _ = close(descriptor) }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0,
              sameResultQuarantinePayloadObject(
                pathBefore, opened, type: .directory),
              (opened.st_mode & mode_t(0o777)) == 0o555 else {
            throw ResultError.commitFailed(
                "immutable result quarantine directory changed while opening")
        }
        let childNames = try directoryEntryNames(
            atBoundDirectoryDescriptor: descriptor,
            context: "immutable result quarantine directory")
        for childName in childNames {
            try verifyImmutableResultQuarantineEntry(
                parentDescriptor: descriptor,
                basename: childName)
        }
        var openedAfter = stat()
        var pathAfter = stat()
        guard fstat(descriptor, &openedAfter) == 0,
              fstatat(
                parentDescriptor,
                basename,
                &pathAfter,
                AT_SYMLINK_NOFOLLOW) == 0,
              sameResultQuarantinePayloadObject(
                opened, openedAfter, type: .directory),
              sameResultQuarantinePayloadObject(
                opened, pathAfter, type: .directory),
              (openedAfter.st_mode & mode_t(0o777)) == 0o555,
              (pathAfter.st_mode & mode_t(0o777)) == 0o555,
              try directoryEntryNames(
                atBoundDirectoryDescriptor: descriptor,
                context: "immutable result quarantine directory after verify")
                == childNames else {
            throw ResultError.commitFailed(
                "immutable result quarantine directory changed during verification")
        }
    }

    private static func recoverResultQuarantinesLocked(
        at libraryRoot: URL
    ) throws {
        let quarantineRoot = libraryRoot.appendingPathComponent(
            "quarantine", isDirectory: true)
        try ensureResultQuarantineRoot(
            quarantineRoot, libraryRoot: libraryRoot)
        let openedLibraryRoot = try openBoundDirectory(
            libraryRoot, context: "result quarantine recovery library root")
        defer { _ = close(openedLibraryRoot.descriptor) }
        let openedQuarantineRoot = try openBoundDirectory(
            quarantineRoot, context: "result quarantine recovery root")
        defer { _ = close(openedQuarantineRoot.descriptor) }
        try cleanupResultQuarantineIntentTemporaries(
            parentDescriptor: openedQuarantineRoot.descriptor)
        let names = try directoryEntryNames(
            atBoundDirectoryDescriptor: openedQuarantineRoot.descriptor,
            context: "result quarantine recovery root")
        var groups: [String: ResultQuarantineRecoveryGroup] = [:]
        for name in names {
            if let parsed = parseResultQuarantineArtifactName(name) {
                var group = groups[parsed.quarantineID]
                    ?? ResultQuarantineRecoveryGroup()
                let url = quarantineRoot.appendingPathComponent(
                    name, isDirectory: parsed.kind != .diagnosticTemporary)
                switch parsed.kind {
                case .pending:
                    guard group.pending == nil else {
                        throw ResultError.commitFailed(
                            "duplicate result quarantine pending authority")
                    }
                    group.pending = url
                case .diagnosticTemporary:
                    guard group.diagnosticTemporary == nil else {
                        throw ResultError.commitFailed(
                            "duplicate result quarantine diagnostic authority")
                    }
                    group.diagnosticTemporary = url
                case .final:
                    guard group.final == nil else {
                        throw ResultError.commitFailed(
                            "duplicate result quarantine final authority")
                    }
                    group.final = url
                }
                groups[parsed.quarantineID] = group
                continue
            }
            throw ResultError.commitFailed(
                "unknown result quarantine artifact preserved: \(name)")
        }
        for quarantineID in groups.keys.sorted() {
            guard let group = groups[quarantineID] else { continue }
            if let final = group.final {
                guard group.pending == nil,
                      group.diagnosticTemporary == nil else {
                    throw ResultError.commitFailed(
                        "result quarantine final conflicts with pending authority")
                }
                try recoverFinalResultQuarantine(
                    final,
                    quarantineID: quarantineID,
                    libraryDescriptor: openedLibraryRoot.descriptor)
                continue
            }
            guard let pending = group.pending else {
                throw ResultError.commitFailed(
                    "orphan result quarantine diagnostic preserved")
            }
            try recoverPendingResultQuarantine(
                pending,
                diagnosticTemporary: group.diagnosticTemporary,
                quarantineID: quarantineID,
                libraryRoot: libraryRoot,
                quarantineRoot: quarantineRoot,
                libraryDescriptor: openedLibraryRoot.descriptor,
                quarantineDescriptor: openedQuarantineRoot.descriptor)
        }
        guard fsync(openedQuarantineRoot.descriptor) == 0,
              fsync(openedLibraryRoot.descriptor) == 0 else {
            throw ResultError.commitFailed(
                "cannot sync result quarantine recovery roots")
        }
        try requireBoundDirectoryPath(
            descriptor: openedQuarantineRoot.descriptor,
            url: quarantineRoot,
            expectedMetadata: openedQuarantineRoot.metadata,
            context: "result quarantine recovery root after reconciliation")
        try requireBoundDirectoryPath(
            descriptor: openedLibraryRoot.descriptor,
            url: libraryRoot,
            expectedMetadata: openedLibraryRoot.metadata,
            context: "result quarantine library root after reconciliation")
    }

    private enum ResultQuarantineArtifactKind {
        case pending
        case diagnosticTemporary
        case final
    }

    private static func parseResultQuarantineArtifactName(
        _ name: String
    ) -> (quarantineID: String, kind: ResultQuarantineArtifactKind)? {
        if name.hasPrefix(".quarantine-"),
           name.hasSuffix(resultQuarantinePendingSuffix) {
            let id = String(
                name.dropFirst().dropLast(
                    resultQuarantinePendingSuffix.count))
            guard isCanonicalResultQuarantineID(id) else { return nil }
            return (id, .pending)
        }
        if name.hasPrefix(".quarantine-"),
           name.hasSuffix(resultQuarantineDiagnosticTemporarySuffix) {
            let id = String(
                name.dropFirst().dropLast(
                    resultQuarantineDiagnosticTemporarySuffix.count))
            guard isCanonicalResultQuarantineID(id) else { return nil }
            return (id, .diagnosticTemporary)
        }
        guard isCanonicalResultQuarantineID(name) else { return nil }
        return (name, .final)
    }

    private static func isCanonicalResultQuarantineID(
        _ value: String
    ) -> Bool {
        let prefix = "quarantine-"
        guard value.hasPrefix(prefix) else { return false }
        return isCanonicalLowercaseUUID(
            String(value.dropFirst(prefix.count)))
    }

    private static func recoverPendingResultQuarantine(
        _ pending: URL,
        diagnosticTemporary: URL?,
        quarantineID: String,
        libraryRoot: URL,
        quarantineRoot: URL,
        libraryDescriptor: Int32,
        quarantineDescriptor: Int32
    ) throws {
        let openedPending = try openBoundDirectory(
            pending, context: "pending result quarantine wrapper")
        defer { _ = close(openedPending.descriptor) }
        guard (openedPending.metadata.st_mode & mode_t(0o777))
                == ImmutableDirectoryPublication.renameableMode else {
            throw ResultError.commitFailed(
                "pending result quarantine wrapper is not renameable")
        }
        var names = try directoryEntryNames(
            atBoundDirectoryDescriptor: openedPending.descriptor,
            context: "pending result quarantine wrapper")
        if let diagnosticTemporary {
            guard !names.contains(quarantineDiagnosticFileName),
                  names.isEmpty else {
                throw ResultError.commitFailed(
                    "pending result quarantine has conflicting diagnostic state")
            }
            let temporaryDiagnostic = try readResultQuarantineDiagnostic(
                parentDescriptor: quarantineDescriptor,
                basename: diagnosticTemporary.lastPathComponent,
                expectedQuarantineID: quarantineID,
                allowedVersions: [resultQuarantineDiagnosticVersion])
            guard temporaryDiagnostic.wrapperIdentity
                    == metadataIdentity(openedPending.metadata),
                  renameatx_np(
                    quarantineDescriptor,
                    diagnosticTemporary.lastPathComponent,
                    openedPending.descriptor,
                    quarantineDiagnosticFileName,
                    UInt32(RENAME_EXCL)) == 0,
                  fsync(openedPending.descriptor) == 0,
                  fsync(quarantineDescriptor) == 0 else {
                throw ResultError.commitFailed(
                    "cannot recover result quarantine diagnostic placement")
            }
            names = try directoryEntryNames(
                atBoundDirectoryDescriptor: openedPending.descriptor,
                context: "pending result quarantine after diagnostic recovery")
        }
        if names.isEmpty {
            try removeEmptyPendingResultQuarantine(
                pending,
                openedPending: openedPending,
                quarantineDescriptor: quarantineDescriptor)
            return
        }
        guard names.contains(quarantineDiagnosticFileName),
              Set(names).isSubset(of: Set([
                quarantineDiagnosticFileName,
                resultQuarantinePayloadName,
              ])) else {
            throw ResultError.commitFailed(
                "pending result quarantine lacks canonical diagnostic authority")
        }
        let diagnostic = try readResultQuarantineDiagnostic(
            parentDescriptor: openedPending.descriptor,
            basename: quarantineDiagnosticFileName,
            expectedQuarantineID: quarantineID,
            allowedVersions: [resultQuarantineDiagnosticVersion])
        guard diagnostic.wrapperIdentity
                == metadataIdentity(openedPending.metadata),
              let payloadType = diagnostic.payloadType,
              let payloadIdentity = diagnostic.payloadIdentity,
              let sourceMode = diagnostic.sourceMode else {
            throw ResultError.commitFailed(
                "pending result quarantine diagnostic is not wrapper-bound")
        }
        var sourceMetadata = stat()
        var payloadMetadata = stat()
        let sourceLookup = fstatat(
            libraryDescriptor,
            diagnostic.sourceName,
            &sourceMetadata,
            AT_SYMLINK_NOFOLLOW)
        let sourceExists = sourceLookup == 0
        if !sourceExists, errno != ENOENT {
            throw ResultError.commitFailed(
                "cannot inspect pending result quarantine source")
        }
        let payloadLookup = fstatat(
            openedPending.descriptor,
            resultQuarantinePayloadName,
            &payloadMetadata,
            AT_SYMLINK_NOFOLLOW)
        let payloadExists = payloadLookup == 0
        if !payloadExists, errno != ENOENT {
            throw ResultError.commitFailed(
                "cannot inspect pending result quarantine payload")
        }
        guard sourceExists != payloadExists else {
            throw ResultError.commitFailed(
                "pending result quarantine has ambiguous source/payload authority")
        }
        if sourceExists {
            try moveBoundResultQuarantineSource(
                diagnostic: diagnostic,
                sourceMetadata: sourceMetadata,
                sourceMode: sourceMode,
                payloadType: payloadType,
                payloadIdentity: payloadIdentity,
                libraryDescriptor: libraryDescriptor,
                pendingDescriptor: openedPending.descriptor)
        } else {
            guard resultQuarantinePayloadMatchesDiagnostic(
                payloadMetadata,
                diagnostic: diagnostic,
                allowsPreparedMode: true) else {
                throw ResultError.commitFailed(
                    "pending result quarantine payload authority mismatch")
            }
        }
        try freezeResultQuarantineWrapper(
            descriptor: openedPending.descriptor,
            diagnostic: diagnostic)
        try verifyResultQuarantineWrapper(
            descriptor: openedPending.descriptor,
            diagnostic: diagnostic,
            expectedRootMode: ImmutableDirectoryPublication.renameableMode)
        let final = quarantineRoot.appendingPathComponent(
            quarantineID, isDirectory: true)
        try ImmutableDirectoryPublication.publish(
            source: pending,
            destination: final,
            expectedIdentity: metadataIdentity(openedPending.metadata))
        try verifyResultQuarantineWrapper(
            final,
            diagnostic: diagnostic,
            expectedRootMode: ImmutableDirectoryPublication.immutableMode)
        try MobileMapLibrary.syncDirectory(final)
        guard fsync(quarantineDescriptor) == 0,
              fsync(libraryDescriptor) == 0 else {
            throw ResultError.commitFailed(
                "cannot sync recovered result quarantine publication")
        }
        _ = libraryRoot
    }

    private static func moveBoundResultQuarantineSource(
        diagnostic: ResultQuarantineDiagnostic,
        sourceMetadata: stat,
        sourceMode: mode_t,
        payloadType: ResultQuarantinePayloadType,
        payloadIdentity: ImmutableDirectoryPublication.Identity,
        libraryDescriptor: Int32,
        pendingDescriptor: Int32
    ) throws {
        guard metadataIdentity(sourceMetadata) == payloadIdentity,
              resultQuarantineSourceModeIsRecoverable(
                sourceMetadata,
                originalMode: sourceMode,
                type: payloadType,
                allowsPreparedMode: false) else {
            throw ResultError.commitFailed(
                "result quarantine source no longer matches durable diagnostic")
        }
        let flags: Int32
        switch payloadType {
        case .directory:
            flags = O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        case .regular:
            flags = O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        case .symbolicLink:
            flags = O_RDONLY | O_CLOEXEC | O_SYMLINK
        }
        let descriptor = openat(
            libraryDescriptor, diagnostic.sourceName, flags)
        guard descriptor >= 0 else {
            throw ResultError.commitFailed(
                "cannot bind interrupted result quarantine source")
        }
        defer { _ = close(descriptor) }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0,
              sameResultQuarantinePayloadObject(
                sourceMetadata, opened, type: payloadType) else {
            throw ResultError.commitFailed(
                "interrupted result quarantine source changed while opening")
        }
        if payloadType == .directory,
           (opened.st_mode & mode_t(S_IWUSR)) == 0 {
            guard fchmod(
                descriptor,
                sourceMode | mode_t(S_IWUSR)) == 0,
                  fsync(descriptor) == 0 else {
                throw ResultError.commitFailed(
                    "cannot thaw interrupted result quarantine source")
            }
        }
        var sourceBeforeMove = stat()
        var payloadBeforeMove = stat()
        guard fstatat(
            libraryDescriptor,
            diagnostic.sourceName,
            &sourceBeforeMove,
            AT_SYMLINK_NOFOLLOW) == 0,
              sameResultQuarantinePayloadObject(
                opened, sourceBeforeMove, type: payloadType),
              metadataIdentity(sourceBeforeMove) == payloadIdentity,
              fstatat(
                pendingDescriptor,
                resultQuarantinePayloadName,
                &payloadBeforeMove,
                AT_SYMLINK_NOFOLLOW) != 0,
              errno == ENOENT,
              renameatx_np(
                libraryDescriptor,
                diagnostic.sourceName,
                pendingDescriptor,
                resultQuarantinePayloadName,
                UInt32(RENAME_EXCL)) == 0,
              fsync(libraryDescriptor) == 0,
              fsync(pendingDescriptor) == 0 else {
            throw ResultError.commitFailed(
                "cannot recover interrupted result quarantine source move")
        }
    }

    private static func recoverFinalResultQuarantine(
        _ final: URL,
        quarantineID: String,
        libraryDescriptor: Int32
    ) throws {
        let opened = try openBoundDirectory(
            final, context: "published result quarantine wrapper")
        defer { _ = close(opened.descriptor) }
        let mode = opened.metadata.st_mode & mode_t(0o777)
        guard mode == ImmutableDirectoryPublication.renameableMode
                || mode == ImmutableDirectoryPublication.immutableMode else {
            throw ResultError.commitFailed(
                "published result quarantine wrapper mode invalid")
        }
        let diagnostic = try readResultQuarantineDiagnostic(
            parentDescriptor: opened.descriptor,
            basename: quarantineDiagnosticFileName,
            expectedQuarantineID: quarantineID)
        var sourceMetadata = stat()
        guard fstatat(
            libraryDescriptor,
            diagnostic.sourceName,
            &sourceMetadata,
            AT_SYMLINK_NOFOLLOW) != 0,
              errno == ENOENT else {
            throw ResultError.commitFailed(
                "published result quarantine conflicts with source pathname")
        }
        if diagnostic.version == 1 {
            guard mode == ImmutableDirectoryPublication.immutableMode else {
                throw ResultError.commitFailed(
                    "historical result quarantine is not fully frozen")
            }
            try verifyResultQuarantineWrapper(
                descriptor: opened.descriptor,
                diagnostic: diagnostic,
                expectedRootMode: ImmutableDirectoryPublication.immutableMode)
            return
        }
        guard diagnostic.wrapperIdentity
                == metadataIdentity(opened.metadata) else {
            throw ResultError.commitFailed(
                "published result quarantine wrapper identity mismatch")
        }
        try verifyResultQuarantineWrapper(
            descriptor: opened.descriptor,
            diagnostic: diagnostic,
            expectedRootMode: mode)
        if mode == ImmutableDirectoryPublication.renameableMode {
            try ImmutableDirectoryPublication.freezeInterruptedDestination(
                final,
                expectedIdentity: metadataIdentity(opened.metadata))
            try verifyResultQuarantineWrapper(
                final,
                diagnostic: diagnostic,
                expectedRootMode: ImmutableDirectoryPublication.immutableMode)
        }
        try MobileMapLibrary.syncDirectory(final)
    }

    private static func resultQuarantinePayloadMatchesDiagnostic(
        _ metadata: stat,
        diagnostic: ResultQuarantineDiagnostic,
        allowsPreparedMode: Bool
    ) -> Bool {
        guard let payloadType = diagnostic.payloadType,
              let payloadIdentity = diagnostic.payloadIdentity,
              let sourceMode = diagnostic.sourceMode,
              metadataIdentity(metadata) == payloadIdentity else {
            return false
        }
        return resultQuarantineSourceModeIsRecoverable(
            metadata,
            originalMode: sourceMode,
            type: payloadType,
            allowsPreparedMode: allowsPreparedMode)
    }

    private static func resultQuarantineSourceModeIsRecoverable(
        _ metadata: stat,
        originalMode: mode_t,
        type: ResultQuarantinePayloadType,
        allowsPreparedMode: Bool
    ) -> Bool {
        guard sameResultQuarantinePayloadObject(
            metadata, metadata, type: type) else {
            return false
        }
        let mode = metadata.st_mode & mode_t(0o777)
        switch type {
        case .directory:
            var allowed: Set<mode_t> = [
                originalMode,
                originalMode | mode_t(S_IWUSR),
            ]
            if allowsPreparedMode { allowed.insert(0o555) }
            return allowed.contains(mode)
        case .regular:
            return mode == originalMode
                || (allowsPreparedMode && mode == 0o444)
        case .symbolicLink:
            return true
        }
    }

    private static func removeEmptyPendingResultQuarantine(
        _ pending: URL,
        openedPending: (descriptor: Int32, metadata: stat),
        quarantineDescriptor: Int32
    ) throws {
        guard try directoryEntryNames(
            atBoundDirectoryDescriptor: openedPending.descriptor,
            context: "empty result quarantine pending wrapper").isEmpty else {
            throw ResultError.commitFailed(
                "result quarantine pending wrapper became non-empty")
        }
        var pathMetadata = stat()
        guard fstatat(
            quarantineDescriptor,
            pending.lastPathComponent,
            &pathMetadata,
            AT_SYMLINK_NOFOLLOW) == 0,
              sameDirectoryObject(openedPending.metadata, pathMetadata),
              (pathMetadata.st_mode & mode_t(0o777))
                == ImmutableDirectoryPublication.renameableMode,
              unlinkat(
                quarantineDescriptor,
                pending.lastPathComponent,
                AT_REMOVEDIR) == 0,
              fsync(quarantineDescriptor) == 0 else {
            throw ResultError.commitFailed(
                "cannot remove proven-empty result quarantine pending wrapper")
        }
    }

    private static func cleanupResultQuarantineIntentTemporaries(
        parentDescriptor: Int32
    ) throws {
        var names = try directoryEntryNames(
            atBoundDirectoryDescriptor: parentDescriptor,
            context: "result quarantine intent cleanup root")
        var changed = false
        for name in names where
            name.hasPrefix(resultQuarantineIntentRemovalPrefix) {
            guard let parsed = parseIdentityBoundName(
                name, prefix: resultQuarantineIntentRemovalPrefix) else {
                throw ResultError.commitFailed(
                    "malformed result quarantine intent tombstone preserved")
            }
            var metadata = stat()
            let mode: mode_t
            guard fstatat(
                parentDescriptor,
                name,
                &metadata,
                AT_SYMLINK_NOFOLLOW) == 0,
                  metadataIdentity(metadata) == parsed.identity,
                  (metadata.st_mode & S_IFMT) == S_IFREG,
                  metadata.st_nlink == 1,
                  metadata.st_size >= 0,
                  metadata.st_size
                    <= maximumResultQuarantineDiagnosticBytes else {
                throw ResultError.commitFailed(
                    "result quarantine intent tombstone identity invalid")
            }
            mode = metadata.st_mode & mode_t(0o777)
            guard [mode_t(0o600), mode_t(0o444)].contains(mode),
                  unlinkat(parentDescriptor, name, 0) == 0 else {
                throw ResultError.commitFailed(
                    "cannot remove result quarantine intent tombstone")
            }
            changed = true
        }
        if changed, fsync(parentDescriptor) != 0 {
            throw ResultError.commitFailed(
                "cannot sync result quarantine intent tombstone cleanup")
        }
        names = try directoryEntryNames(
            atBoundDirectoryDescriptor: parentDescriptor,
            context: "result quarantine creation-temporary cleanup root")
        for name in names where
            name.hasPrefix(resultQuarantineIntentCreationPrefix) {
            let suffix = String(
                name.dropFirst(resultQuarantineIntentCreationPrefix.count))
            guard isCanonicalLowercaseUUID(suffix) else {
                throw ResultError.commitFailed(
                    "malformed result quarantine creation temporary preserved")
            }
            var metadata = stat()
            guard fstatat(
                parentDescriptor,
                name,
                &metadata,
                AT_SYMLINK_NOFOLLOW) == 0,
                  (metadata.st_mode & S_IFMT) == S_IFREG,
                  (metadata.st_mode & mode_t(0o777)) == 0o600,
                  metadata.st_nlink == 1,
                  metadata.st_size == 0 else {
                throw ResultError.commitFailed(
                    "unbound result quarantine creation evidence preserved")
            }
            let descriptor = openat(
                parentDescriptor,
                name,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            guard descriptor >= 0 else {
                throw ResultError.commitFailed(
                    "cannot bind result quarantine creation temporary")
            }
            var opened = stat()
            let matches = fstat(descriptor, &opened) == 0
                && sameCommittedOrCreationFileObject(metadata, opened)
            _ = close(descriptor)
            guard matches else {
                throw ResultError.commitFailed(
                    "result quarantine creation temporary changed")
            }
            try removeIdentityBoundResultQuarantineTemporary(
                parentDescriptor: parentDescriptor,
                basename: name,
                expectedMetadata: metadata,
                context: "unbound result quarantine creation temporary")
        }
        names = try directoryEntryNames(
            atBoundDirectoryDescriptor: parentDescriptor,
            context: "result quarantine bound-temporary cleanup root")
        for name in names where
            name.hasPrefix(resultQuarantineIntentTemporaryPrefix) {
            guard let parsed = parseIdentityBoundName(
                name, prefix: resultQuarantineIntentTemporaryPrefix) else {
                throw ResultError.commitFailed(
                    "malformed result quarantine bound temporary preserved")
            }
            var metadata = stat()
            guard fstatat(
                parentDescriptor,
                name,
                &metadata,
                AT_SYMLINK_NOFOLLOW) == 0,
                  metadataIdentity(metadata) == parsed.identity,
                  (metadata.st_mode & S_IFMT) == S_IFREG,
                  metadata.st_nlink == 1,
                  metadata.st_size >= 0,
                  metadata.st_size
                    <= maximumResultQuarantineDiagnosticBytes,
                  [mode_t(0o600), mode_t(0o444)].contains(
                    metadata.st_mode & mode_t(0o777)) else {
                throw ResultError.commitFailed(
                    "result quarantine bound temporary identity invalid")
            }
            try removeIdentityBoundResultQuarantineTemporary(
                parentDescriptor: parentDescriptor,
                basename: name,
                expectedMetadata: metadata,
                context: "orphan result quarantine bound temporary")
        }
    }

    private static func removeIdentityBoundResultQuarantineTemporary(
        parentDescriptor: Int32,
        basename: String,
        expectedMetadata: stat,
        context: String
    ) throws {
        let expectedIdentity = metadataIdentity(expectedMetadata)
        let tombstoneName = resultQuarantineIntentRemovalPrefix
            + identityToken(expectedIdentity) + "."
            + UUID().uuidString.lowercased()
        guard renameatx_np(
            parentDescriptor, basename,
            parentDescriptor, tombstoneName,
            UInt32(RENAME_EXCL)) == 0 else {
            throw ResultError.commitFailed("cannot detach \(context)")
        }
        var moved = stat()
        guard fstatat(
            parentDescriptor,
            tombstoneName,
            &moved,
            AT_SYMLINK_NOFOLLOW) == 0,
              metadataIdentity(moved) == expectedIdentity,
              sameCommittedOrCreationFileObject(expectedMetadata, moved) else {
            var canonical = stat()
            if fstatat(
                parentDescriptor,
                basename,
                &canonical,
                AT_SYMLINK_NOFOLLOW) != 0,
               errno == ENOENT {
                _ = renameatx_np(
                    parentDescriptor, tombstoneName,
                    parentDescriptor, basename,
                    UInt32(RENAME_EXCL))
                _ = fsync(parentDescriptor)
            }
            throw ResultError.commitFailed(
                "\(context) identity mismatch; evidence preserved")
        }
        guard fsync(parentDescriptor) == 0,
              unlinkat(parentDescriptor, tombstoneName, 0) == 0,
              fsync(parentDescriptor) == 0 else {
            throw ResultError.commitFailed(
                "cannot durably remove \(context)")
        }
    }

    private static func replaceListingDiagnostics(_ values: [String]) {
        listingDiagnosticsLock.lock()
        listingDiagnostics = values
        listingDiagnosticsLock.unlock()
    }

    private static func appendListingDiagnostic(_ value: String) {
        listingDiagnosticsLock.lock()
        listingDiagnostics.append(value)
        listingDiagnosticsLock.unlock()
    }

    static func readResult(resultID: String) throws -> ResultEntry {
        libraryLock.lock()
        defer { libraryLock.unlock() }
        let processLock = try acquireProcessLock()
        defer { releaseProcessLock(processLock) }
        try recoverInterruptedPublicationsLocked()
        let entry = try readResult(in: resultDirectory(resultID: resultID))
        try validateProcessLock(processLock)
        return entry
    }

    /// Finds the one committed result owned by a task. This is the
    /// crash-recovery bridge for the window after result rename/parent
    /// fsync and before task.json reaches `completed`.
    static func committedResult(
        taskID: String,
        expectedResultIDs: Set<String> = []
    ) throws -> ResultEntry? {
        libraryLock.lock()
        defer { libraryLock.unlock() }
        let processLock = try acquireProcessLock()
        defer { releaseProcessLock(processLock) }
        try recoverInterruptedPublicationsLocked()
        let entry = try committedResultLocked(
            taskID: taskID, expectedResultIDs: expectedResultIDs)
        try validateProcessLock(processLock)
        return entry
    }

    private static func committedResultLocked(
        taskID: String,
        expectedResultIDs: Set<String> = []
    ) throws -> ResultEntry? {
        guard isSafeBasename(taskID) else {
            throw ResultError.invalidManifest("unsafe task_id: \(taskID)")
        }
        guard expectedResultIDs.allSatisfy(isSafeBasename) else {
            throw ResultError.invalidManifest(
                "unsafe expected result identity for task_id \(taskID)")
        }
        guard expectedResultIDs.count <= 1 else {
            throw ResultError.invalidManifest(
                "checkpoint names multiple result identities for task_id \(taskID)")
        }
        let fileManager = FileManager.default
        let libraryRoot = try root()
        let names = try fileManager.contentsOfDirectory(atPath: libraryRoot.path)
        var matches: [ResultEntry] = []
        for name in names.sorted()
            where name != "staging" && name != "quarantine"
                && name != processLockFileName
                && !isPublishIntentTemporaryName(name)
                && !isHiddenStagingName(name)
                && !isPublishIntentName(name) {
            let directory = libraryRoot.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            let isExpectedIdentity = expectedResultIDs.contains(name)
            let claimedTaskID = claimedTaskIDIfReadable(in: directory)
            // Recovery is deliberately narrower than normal result
            // listing. Invalid unrelated entries are left for the library
            // audit/quarantine path; an entry named by this task's
            // committing checkpoint, or whose strict manifest claims this
            // task, is part of the transaction and MUST fail closed.
            guard isExpectedIdentity || claimedTaskID == taskID else {
                continue
            }
            let entry: ResultEntry
            do {
                guard isSafeBasename(name),
                      fileManager.fileExists(
                        atPath: directory.path, isDirectory: &isDirectory),
                      isDirectory.boolValue else {
                    throw ResultError.invalidManifest(
                        "unsafe or non-directory result-library entry")
                }
                entry = try readResult(in: directory)
            } catch {
                throw ResultError.invalidManifest(
                    "committed-result candidate \(name) for task_id "
                        + "\(taskID) is invalid: \(error)")
            }
            if isExpectedIdentity && entry.taskID != taskID {
                throw ResultError.invalidManifest(
                    "checkpoint result \(name) belongs to task_id "
                        + "\(entry.taskID), expected \(taskID)")
            }
            if entry.taskID == taskID {
                matches.append(entry)
            }
        }
        guard matches.count <= 1 else {
            throw ResultError.invalidManifest(
                "multiple committed results for task_id \(taskID)")
        }
        if let match = matches.first,
           !expectedResultIDs.isEmpty,
           !expectedResultIDs.contains(match.resultID) {
            throw ResultError.invalidManifest(
                "committed result \(match.resultID) conflicts with task checkpoint")
        }
        return matches.first
    }

    /// Reads only the strict manifest envelope needed to decide whether
    /// an invalid library entry belongs to the task under recovery. Full
    /// trust is established exclusively by `readResult(in:)` above.
    private static func claimedTaskIDIfReadable(in directory: URL) -> String? {
        let manifestURL = directory.appendingPathComponent(manifestFileName)
        guard let data = try? readStableSmallRegularFile(
                manifestURL,
                maximumBytes: 4 * 1024 * 1024,
                requiredMode: 0o444),
              let object = try? StrictJSONDocumentParser.object(
                from: data,
                limits: StrictJSONDocumentLimits(
                    maximumBytes: data.count + 1)) as? [String: Any],
              object["format"] as? String == "MarketScannerResultManifest",
              StrictJSONScalar.integer(object["version"]) == 2,
              let taskID = object["task_id"] as? String,
              isSafeBasename(taskID) else {
            return nil
        }
        return taskID
    }

    private static func readResult(
        in directory: URL,
        expectedDirectoryMode: Int? = 0o555
    ) throws -> ResultEntry {
        let manifestURL = directory.appendingPathComponent(manifestFileName)
        guard isSafeBasename(directory.lastPathComponent) else {
            throw ResultError.invalidManifest("unsafe result directory")
        }
        let openedDirectory = try openBoundDirectory(
            directory, context: "result package root")
        defer { _ = close(openedDirectory.descriptor) }
        if let expectedDirectoryMode {
            let mode = openedDirectory.metadata.st_mode & mode_t(0o777)
            guard mode == mode_t(expectedDirectoryMode) else {
                throw ResultError.artifactCorrupt(
                    "result root mode mismatch: \(String(mode, radix: 8))")
            }
        }
        let manifestRecord: StableRegularFile
        do {
            manifestRecord = try readStableSmallRegularFileRecord(
                parentDescriptor: openedDirectory.descriptor,
                basename: manifestFileName,
                maximumBytes: 4 * 1024 * 1024,
                requiredMode: 0o444)
        } catch {
            throw ResultError.invalidManifest(manifestURL.path)
        }
        let data = manifestRecord.data
        guard let manifest = try? StrictJSONDocumentParser.object(
            from: data,
            limits: StrictJSONDocumentLimits(maximumBytes: data.count + 1)) as? [String: Any],
              let format = manifest["format"] as? String,
              format == "MarketScannerResultManifest",
              let version = StrictJSONScalar.integer(manifest["version"]),
              version == 2,
              let resultID = manifest["result_id"] as? String,
              let taskID = manifest["task_id"] as? String,
              let createdAt = StrictJSONScalar.number(
                manifest["created_at_utc"]), createdAt.isFinite,
              let workbookName = manifest["workbook"] as? String,
              let workbookSHA = manifest["workbook_sha256"] as? String,
              let workbookBytes = StrictJSONScalar.integer(manifest["workbook_bytes"]),
              workbookBytes >= 0,
              isSHA256(workbookSHA),
              let packageFiles = manifest["package_files"] as? [String],
              let artifacts = manifest["artifacts"] as? [[String: Any]]
        else {
            throw ResultError.invalidManifest(manifestURL.path)
        }
        guard isSafeBasename(resultID), resultID == directory.lastPathComponent,
              isSafeBasename(taskID), isSafeBasename(workbookName) else {
            throw ResultError.invalidManifest("unsafe/mismatched result identity")
        }
        // V1R4 §16.3: unknown top-level fields are rejected — versioned
        // extensions must be whitelisted in the same change that writes
        // them.
        for key in manifest.keys where !allowedManifestKeys.contains(key) {
            throw ResultError.invalidManifest("unknown manifest field: \(key)")
        }
        if let rawStatus = manifest["result_quality_status"] {
            guard let status = rawStatus as? String,
                  ["COMPLETE", "PARTIAL_REVIEW_REQUIRED", "LOCAL_FRAME_ONLY"]
                    .contains(status),
                  MobileResultPublicationInvariant.manifestIsConsistent(
                    manifest),
                  let degradationCount = StrictJSONScalar.integer(
                    manifest["degradation_count"]), degradationCount >= 0,
                  let degradedPositionCount = StrictJSONScalar.integer(
                    manifest["degraded_position_count"]),
                  degradedPositionCount >= 0,
                  let coordinatePositionCount = StrictJSONScalar.integer(
                    manifest["coordinate_position_count"]),
                  coordinatePositionCount >= 0,
                  let devicePositionCount = StrictJSONScalar.integer(
                    manifest["device_position_count"]),
                  coordinatePositionCount <= devicePositionCount else {
                throw ResultError.invalidManifest(
                    "result quality/degradation fields invalid")
            }
            if manifest["deliverable_contract_version"] != nil {
                guard StrictJSONScalar.integer(
                        manifest["deliverable_contract_version"]) == 1,
                      let coordinateContractVersion = StrictJSONScalar.integer(
                        manifest["coordinate_contract_version"]),
                      coordinateContractVersion == 1
                        || coordinateContractVersion
                            == MobileResultPublicationInvariant
                                .coordinateContractVersion,
                      let canonicalSHA = manifest[
                        "canonical_source_sha256"] as? String,
                      isSHA256(canonicalSHA),
                      let tagCount = StrictJSONScalar.integer(
                        manifest["tag_count"]), tagCount >= 0,
                      let sourceTagCount = StrictJSONScalar.integer(
                        manifest["source_tag_count"]),
                      let retainedTagCount = StrictJSONScalar.integer(
                        manifest["retained_tag_count"]),
                      let positionedTagCount = StrictJSONScalar.integer(
                        manifest["positioned_tag_count"]),
                      let unpositionedTagCount = StrictJSONScalar.integer(
                        manifest["unpositioned_tag_count"]),
                      let associatedTagCount = StrictJSONScalar.integer(
                        manifest["shelf_associated_tag_count"]),
                      let unassociatedTagCount = StrictJSONScalar.integer(
                        manifest["unassociated_tag_count"]),
                      let lowConfidenceTagCount = StrictJSONScalar.integer(
                        manifest["low_confidence_tag_count"]),
                      sourceTagCount == retainedTagCount,
                      retainedTagCount == tagCount,
                      positionedTagCount >= 0,
                      unpositionedTagCount >= 0,
                      positionedTagCount + unpositionedTagCount == tagCount,
                      associatedTagCount >= 0,
                      unassociatedTagCount >= 0,
                      associatedTagCount + unassociatedTagCount == tagCount,
                      lowConfidenceTagCount >= 0,
                      lowConfidenceTagCount <= tagCount else {
                    throw ResultError.invalidManifest(
                        "calibrated deliverable counts/identity invalid")
                }
            }
        }
        // Exact artifact contract: unique safe basenames, exact count and
        // an artifact file set that equals package_files exactly.
        guard !packageFiles.isEmpty else {
            throw ResultError.invalidManifest("package_files is empty")
        }
        guard Set(packageFiles).count == packageFiles.count else {
            throw ResultError.invalidManifest("package_files contains duplicates")
        }
        for name in packageFiles where !isSafeBasename(name) {
            throw ResultError.invalidManifest("unsafe package file name: \(name)")
        }
        guard artifacts.count == packageFiles.count + 1 else {
            throw ResultError.invalidManifest(
                "artifact count \(artifacts.count) != package_files \(packageFiles.count) + workbook")
        }
        var artifactFiles = Set<String>()
        var artifactContracts: [String: (sha256: String, bytes: Int64)] = [:]
        for artifact in artifacts {
            guard Set(artifact.keys) == Set([
                    "file", "sha256", "bytes", "required",
                  ]),
                  let name = artifact["file"] as? String,
                  isSafeBasename(name),
                  let sha = artifact["sha256"] as? String,
                  isSHA256(sha),
                  let bytes = StrictJSONScalar.integer(artifact["bytes"]),
                  bytes >= 0,
                  StrictJSONScalar.boolean(artifact["required"]) == true,
                  artifactFiles.insert(name).inserted
            else {
                throw ResultError.invalidManifest("invalid artifact record")
            }
            artifactContracts[name] = (sha, Int64(bytes))
        }
        guard artifactFiles == Set(packageFiles).union([workbookName]) else {
            throw ResultError.invalidManifest("artifact file set != package_files + workbook")
        }
        guard let workbookContract = artifactContracts[workbookName],
              workbookContract.sha256 == workbookSHA,
              workbookContract.bytes == Int64(workbookBytes) else {
            throw ResultError.invalidManifest(
                "workbook top-level fields differ from artifact record")
        }
        do {
            try validateExactDirectorySet(
                directory,
                expectedNames: artifactFiles.union([
                    manifestFileName, commitReceiptFileName,
                ]),
                expectedDirectoryMode: expectedDirectoryMode,
                expectedFileMode: 0o444)
        } catch {
            throw ResultError.artifactCorrupt(
                "result file-set/mode validation failed: \(error)")
        }

        let receiptRecord = try readStableSmallRegularFileRecord(
            parentDescriptor: openedDirectory.descriptor,
            basename: commitReceiptFileName,
            maximumBytes: 64 * 1024,
            requiredMode: 0o444)
        let receipt = try readCommitReceipt(receiptRecord.data)
        let manifestSHA256 = CanonicalSourceHasher.sha256(data)
        guard receipt.resultID == resultID,
              receipt.finalPath == resultID,
              receipt.manifestSHA256 == manifestSHA256,
              receipt.commitGeneration == 1 else {
            throw ResultError.invalidManifest("commit receipt mismatch")
        }
        try resultReadVerificationObserver?(
            .initialManifestAndReceiptBound)
        let workbookURL = directory.appendingPathComponent(workbookName)
        // Hash every artifact through one descriptor opened relative to the
        // already-bound result root. Size, hash and final pathname therefore
        // describe the same 0444, single-link inode.
        var verifiedArtifactMetadata: [String: stat] = [:]
        for name in artifactFiles.sorted() {
            guard let contract = artifactContracts[name] else {
                throw ResultError.invalidManifest(
                    "missing artifact contract: \(name)")
            }
            let actual = try sha256StableCommittedFile(
                parentDescriptor: openedDirectory.descriptor,
                basename: name,
                expectedBytes: contract.bytes)
            guard actual.sha256 == contract.sha256 else {
                throw ResultError.artifactCorrupt(name)
            }
            verifiedArtifactMetadata[name] = actual.metadata
            try resultReadVerificationObserver?(.artifactHashed(name))
        }

        // A generation-wide final sweep catches replacement or same-inode
        // mutation after an earlier artifact was hashed. The exact inventory,
        // manifest, receipt, every artifact and the root pathname must all
        // remain bound until this method returns success.
        try resultReadVerificationObserver?(.beforeFinalSweep)
        let expectedNames = artifactFiles.union([
            manifestFileName, commitReceiptFileName,
        ])
        let finalNames = try directoryEntryNames(
            atBoundDirectoryDescriptor: openedDirectory.descriptor,
            context: "result package final inventory")
        guard Set(finalNames) == expectedNames,
              finalNames.count == expectedNames.count else {
            throw ResultError.artifactCorrupt(
                "result package inventory changed during validation")
        }
        let finalManifestRecord = try readStableSmallRegularFileRecord(
            parentDescriptor: openedDirectory.descriptor,
            basename: manifestFileName,
            maximumBytes: 4 * 1024 * 1024,
            requiredMode: 0o444)
        let finalReceiptRecord = try readStableSmallRegularFileRecord(
            parentDescriptor: openedDirectory.descriptor,
            basename: commitReceiptFileName,
            maximumBytes: 64 * 1024,
            requiredMode: 0o444)
        guard finalManifestRecord.data == manifestRecord.data,
              sameStableRegularFile(
                finalManifestRecord.metadata, manifestRecord.metadata),
              finalReceiptRecord.data == receiptRecord.data,
              sameStableRegularFile(
                finalReceiptRecord.metadata, receiptRecord.metadata) else {
            throw ResultError.artifactCorrupt(
                "result manifest/receipt changed during validation")
        }
        for (name, expectedMetadata) in verifiedArtifactMetadata {
            var current = stat()
            guard fstatat(
                openedDirectory.descriptor,
                name,
                &current,
                AT_SYMLINK_NOFOLLOW) == 0,
                  sameStableRegularFile(expectedMetadata, current) else {
                throw ResultError.artifactCorrupt(
                    "artifact changed after hash: \(name)")
            }
        }
        var finalRootMetadata = stat()
        guard fstat(openedDirectory.descriptor, &finalRootMetadata) == 0,
              sameDirectoryObject(
                openedDirectory.metadata, finalRootMetadata) else {
            throw ResultError.artifactCorrupt(
                "result root changed during validation")
        }
        if let expectedDirectoryMode {
            guard finalRootMetadata.st_mode & mode_t(0o777)
                    == mode_t(expectedDirectoryMode) else {
                throw ResultError.artifactCorrupt(
                    "result root mode changed during validation")
            }
        }
        try requireBoundDirectoryPath(
            descriptor: openedDirectory.descriptor,
            url: directory,
            expectedMetadata: openedDirectory.metadata,
            context: "result package root after validation")
        return ResultEntry(
            resultID: resultID,
            taskID: taskID,
            createdAtUTC: createdAt,
            workbookURL: workbookURL,
            workbookSHA256: workbookSHA,
            directory: directory,
            manifest: manifest)
    }

    /// A package file name must be a safe basename: non-empty, never a
    /// path separator, never an absolute or parent traversal.
    static func isSafeBasename(_ name: String) -> Bool {
        guard !name.isEmpty, name != ".", name != ".." else { return false }
        guard !name.hasPrefix("."), name.utf8.count <= 255,
              !name.contains("/"), !name.contains("\\"),
              !name.unicodeScalars.contains(where: {
                  $0.value < 0x20 || $0.value == 0x7F
              }) else { return false }
        return URL(fileURLWithPath: name).lastPathComponent == name
    }

    /// Internal transaction files intentionally use a leading dot. They
    /// still must be one bounded UTF-8 basename with no traversal, separator
    /// or control characters.
    private static func isSafeInternalBasename(_ name: String) -> Bool {
        guard !name.isEmpty, name != ".", name != "..",
              name.utf8.count <= 255,
              !name.contains("/"), !name.contains("\\"),
              !name.unicodeScalars.contains(where: {
                $0.value < 0x20 || $0.value == 0x7F
              }) else {
            return false
        }
        return URL(fileURLWithPath: name).lastPathComponent == name
    }

    private static func hiddenStagingTaskPrefix(taskID: String) -> String {
        let taskHash = CanonicalSourceHasher.sha256(Data(taskID.utf8))
        return hiddenStagingPrefix + taskHash + "."
    }

    private static func hiddenStagingName(
        taskID: String,
        resultID: String
    ) -> String {
        let resultHash = CanonicalSourceHasher.sha256(Data(resultID.utf8))
        return hiddenStagingTaskPrefix(taskID: taskID) + resultHash
    }

    private static func publishIntentName(
        taskID: String,
        resultID: String
    ) -> String {
        return hiddenStagingName(taskID: taskID, resultID: resultID)
            + publishIntentSuffix
    }

    private static func isHiddenStagingName(_ name: String) -> Bool {
        guard name.hasPrefix(hiddenStagingPrefix) else { return false }
        let suffix = name.dropFirst(hiddenStagingPrefix.count)
        let components = suffix.split(
            separator: ".", omittingEmptySubsequences: false)
        guard components.count == 2 else { return false }
        return components.allSatisfy { component in
            component.count == 64 && component.allSatisfy { character in
                ("0"..."9").contains(character)
                    || ("a"..."f").contains(character)
            }
        }
    }

    private static func isPublishIntentName(_ name: String) -> Bool {
        guard name.hasSuffix(publishIntentSuffix) else { return false }
        return isHiddenStagingName(
            String(name.dropLast(publishIntentSuffix.count)))
    }

    private static func isPublishIntentTemporaryName(_ name: String) -> Bool {
        return parseIdentityBoundName(
            name, prefix: publishIntentTemporaryPrefix) != nil
    }

    private static func writePublishIntent(
        _ intent: PublishIntent,
        to url: URL
    ) throws -> ReadPublishIntent {
        let payload: [String: Any] = [
            "format": "MarketScannerResultPublishIntent",
            "version": 1,
            "task_id": intent.taskID,
            "result_id": intent.resultID,
            "staging_name": intent.stagingName,
            "final_name": intent.finalName,
            "manifest_sha256": intent.manifestSHA256,
            "directory_device": String(intent.directoryIdentity.device),
            "directory_inode": String(intent.directoryIdentity.inode),
        ]
        let data = try CanonicalJSONEncoder.encode(payload)
        guard !data.isEmpty, data.count <= maximumPublishIntentBytes else {
            throw ResultError.commitFailed(
                "result publish intent exceeds size limit")
        }
        let parent = url.deletingLastPathComponent()
        let openedParent = try openBoundDirectory(
            parent, context: "result publish-intent parent")
        let parentDescriptor = openedParent.descriptor
        defer { _ = close(parentDescriptor) }
        let temporaryUUID = UUID().uuidString.lowercased()
        var temporaryName = publishIntentCreationPrefix + temporaryUUID
        let descriptor = openat(
            parentDescriptor,
            temporaryName,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            mode_t(0o600))
        guard descriptor >= 0 else {
            throw ResultError.commitFailed(
                "cannot create result publish intent temporary")
        }
        var descriptorOpen = true
        var installedCanonical = false
        var cleanupExpectedMetadata: stat?
        defer {
            if descriptorOpen { _ = close(descriptor) }
            if !installedCanonical, let cleanupExpectedMetadata {
                try? removeIdentityBoundPublishIntentTemporary(
                    parentDescriptor: parentDescriptor,
                    basename: temporaryName,
                    expectedMetadata: cleanupExpectedMetadata,
                    context: "failed result publish-intent temporary")
            }
        }
        var createdMetadata = stat()
        guard fstat(descriptor, &createdMetadata) == 0,
              (createdMetadata.st_mode & S_IFMT) == S_IFREG,
              (createdMetadata.st_mode & mode_t(0o777)) == 0o600,
              createdMetadata.st_nlink == 1,
              createdMetadata.st_size == 0 else {
            throw ResultError.commitFailed(
                "result publish-intent creation identity is invalid")
        }
        cleanupExpectedMetadata = createdMetadata
        let boundTemporaryName = publishIntentTemporaryPrefix
            + identityToken(metadataIdentity(createdMetadata)) + "."
            + temporaryUUID
        guard renameatx_np(
            parentDescriptor, temporaryName,
            parentDescriptor, boundTemporaryName,
            UInt32(RENAME_EXCL)) == 0 else {
            throw ResultError.commitFailed(
                "cannot bind result publish-intent temporary identity")
        }
        temporaryName = boundTemporaryName
        guard fsync(parentDescriptor) == 0 else {
            throw ResultError.commitFailed(
                "cannot sync result publish-intent temporary identity")
        }
        var offset = 0
        let wroteAll = data.withUnsafeBytes { rawBuffer -> Bool in
            guard let base = rawBuffer.baseAddress else { return data.isEmpty }
            while offset < rawBuffer.count {
                let count = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    rawBuffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                if count <= 0 { return false }
                offset += count
        }
        return true
    }

        var persistedMetadata = stat()
        guard wroteAll,
              fchmod(descriptor, mode_t(0o444)) == 0,
              fsync(descriptor) == 0,
              fstat(descriptor, &persistedMetadata) == 0,
              (persistedMetadata.st_mode & S_IFMT) == S_IFREG,
              (persistedMetadata.st_mode & mode_t(0o777)) == 0o444,
              persistedMetadata.st_nlink == 1,
              persistedMetadata.st_size == data.count,
              metadataIdentity(persistedMetadata)
                == metadataIdentity(createdMetadata),
              close(descriptor) == 0 else {
            throw ResultError.commitFailed(
                "cannot persist frozen result publish intent temporary")
        }
        descriptorOpen = false
        cleanupExpectedMetadata = persistedMetadata
        try commitFaultInjector?(.afterPublishIntentTemporaryFsyncBeforeRename)
        var temporaryAuthority = stat()
        guard fstatat(
            parentDescriptor,
            temporaryName,
            &temporaryAuthority,
            AT_SYMLINK_NOFOLLOW) == 0,
              sameStableRegularFile(persistedMetadata, temporaryAuthority) else {
            throw ResultError.commitFailed(
                "result publish-intent temporary authority changed before install")
        }
        guard renameatx_np(
            parentDescriptor, temporaryName,
            parentDescriptor, url.lastPathComponent,
            UInt32(RENAME_EXCL)) == 0 else {
            throw ResultError.commitFailed(
                "cannot publish result intent exclusively: "
                    + String(cString: strerror(errno)))
        }
        installedCanonical = true
        try commitFaultInjector?(.afterPublishIntentRenameBeforeParentFsync)
        guard fsync(parentDescriptor) == 0 else {
            throw ResultError.commitFailed(
                "cannot sync result root after publish intent rename")
        }
        let installed = try readPublishIntent(url)
        guard installed.intent == intent,
              installed.data == data,
              installed.fileIdentity == metadataIdentity(createdMetadata) else {
            throw ResultError.commitFailed(
                "installed result publish intent identity mismatch")
        }
        try requireBoundDirectoryPath(
            descriptor: parentDescriptor,
            url: parent,
            expectedMetadata: openedParent.metadata,
            context: "result publish-intent parent after install")
        return installed
    }

    private static func readPublishIntent(
        _ url: URL,
        requireCanonicalName: Bool = true
    ) throws -> ReadPublishIntent {
        let parent = url.deletingLastPathComponent()
        let openedParent = try openBoundDirectory(
            parent, context: "result publish-intent read parent")
        defer { _ = close(openedParent.descriptor) }
        let result = try readPublishIntent(
            parentDescriptor: openedParent.descriptor,
            basename: url.lastPathComponent,
            requireCanonicalName: requireCanonicalName)
        try requireBoundDirectoryPath(
            descriptor: openedParent.descriptor,
            url: parent,
            expectedMetadata: openedParent.metadata,
            context: "result publish-intent read parent after read")
        return result
    }

    private static func readPublishIntent(
        parentDescriptor: Int32,
        basename: String,
        requireCanonicalName: Bool
    ) throws -> ReadPublishIntent {
        let stable = try readStableSmallRegularFileRecord(
            parentDescriptor: parentDescriptor,
            basename: basename,
            maximumBytes: maximumPublishIntentBytes,
            requiredMode: 0o444)
        let data = stable.data
        guard let object = try? StrictJSONDocumentParser.object(
            from: data,
            limits: StrictJSONDocumentLimits(
                maximumBytes: maximumPublishIntentBytes))
                as? [String: Any],
              Set(object.keys) == Set([
                "format", "version", "task_id", "result_id",
                "staging_name", "final_name", "manifest_sha256",
                "directory_device", "directory_inode",
              ]),
              object["format"] as? String ==
                "MarketScannerResultPublishIntent",
              StrictJSONScalar.integer(object["version"]) == 1,
              let taskID = object["task_id"] as? String,
              let resultID = object["result_id"] as? String,
              isSafeBasename(taskID), isSafeBasename(resultID),
              let stagingName = object["staging_name"] as? String,
              stagingName == hiddenStagingName(
                taskID: taskID, resultID: resultID),
              let finalName = object["final_name"] as? String,
              finalName == resultID,
              let manifestSHA = object["manifest_sha256"] as? String,
              isSHA256(manifestSHA),
              let deviceText = object["directory_device"] as? String,
              let inodeText = object["directory_inode"] as? String,
              isCanonicalUnsignedDecimal(deviceText),
              isCanonicalUnsignedDecimal(inodeText),
              let device = UInt64(deviceText),
              let inode = UInt64(inodeText) else {
            throw ResultError.commitFailed(
                "invalid result publish intent: \(basename)")
        }
        if requireCanonicalName,
           basename != publishIntentName(
                taskID: taskID, resultID: resultID) {
            throw ResultError.commitFailed(
                "result publish intent is outside its canonical basename")
        }
        let canonical: [String: Any] = [
            "format": "MarketScannerResultPublishIntent",
            "version": 1,
            "task_id": taskID,
            "result_id": resultID,
            "staging_name": stagingName,
            "final_name": finalName,
            "manifest_sha256": manifestSHA,
            "directory_device": deviceText,
            "directory_inode": inodeText,
        ]
        guard (try? CanonicalJSONEncoder.encode(canonical)) == data else {
            throw ResultError.commitFailed(
                "non-canonical result publish intent")
        }
        return ReadPublishIntent(
            intent: PublishIntent(
                taskID: taskID,
                resultID: resultID,
                stagingName: stagingName,
                finalName: finalName,
                manifestSHA256: manifestSHA,
                directoryIdentity: ImmutableDirectoryPublication.Identity(
                    device: device, inode: inode)),
            data: data,
            fileIdentity: stable.identity,
            metadata: stable.metadata)
    }

    private static func recoverInterruptedPublicationsLocked() throws {
        let libraryRoot = try root()
        try recoverResultQuarantinesLocked(at: libraryRoot)
        try rejectUnboundPublishIntentCreationTemporaries(at: libraryRoot)
        try cleanupPublishIntentTemporaryRemovalTombstones(at: libraryRoot)
        try cleanupPublishIntentRemovalTombstones(at: libraryRoot)
        try cleanupPublishIntentTemporaries(at: libraryRoot)
        try rejectPublishIntentConflictEvidence(at: libraryRoot)
        let openedRoot = try openBoundDirectory(
            libraryRoot, context: "result publication recovery root")
        defer { _ = close(openedRoot.descriptor) }
        let names = try directoryEntryNames(
            atBoundDirectoryDescriptor: openedRoot.descriptor,
            context: "result publication recovery root")
        for name in names where isPublishIntentName(name) {
            let intentURL = libraryRoot.appendingPathComponent(name)
            let intentRecord = try readPublishIntent(intentURL)
            let intent = intentRecord.intent
            let staging = libraryRoot.appendingPathComponent(
                intent.stagingName, isDirectory: true)
            let final = libraryRoot.appendingPathComponent(
                intent.finalName, isDirectory: true)
            var stagingStat = stat()
            var finalStat = stat()
            let stagingExists = lstat(staging.path, &stagingStat) == 0
            let finalExists = lstat(final.path, &finalStat) == 0
            guard !(stagingExists && finalExists) else {
                throw ResultError.commitFailed(
                    "result publish intent has both staging and final")
            }
            if finalExists {
                guard (finalStat.st_mode & S_IFMT) == S_IFDIR,
                      ImmutableDirectoryPublication.Identity(
                        device: UInt64(finalStat.st_dev),
                        inode: UInt64(finalStat.st_ino))
                        == intent.directoryIdentity else {
                    throw ResultError.commitFailed(
                        "result publish final identity mismatch")
                }
                let mode = Int(finalStat.st_mode & 0o777)
                guard mode == 0o755 || mode == 0o555 else {
                    throw ResultError.commitFailed(
                        "result publish final mode is neither 0755 nor 0555")
                }
                let provisional = try readResult(
                    in: final, expectedDirectoryMode: mode)
                let manifestData = try readStableSmallRegularFile(
                    final.appendingPathComponent(manifestFileName),
                    maximumBytes: 4 * 1024 * 1024,
                    requiredMode: 0o444)
                guard provisional.taskID == intent.taskID,
                      provisional.resultID == intent.resultID,
                      CanonicalSourceHasher.sha256(manifestData)
                        == intent.manifestSHA256 else {
                    throw ResultError.commitFailed(
                        "result publish intent/manifest identity mismatch")
                }
                try ImmutableDirectoryPublication
                    .freezeInterruptedDestination(
                        final,
                        expectedIdentity: intent.directoryIdentity)
                _ = try readResult(in: final)
                try MobileMapLibrary.syncDirectory(libraryRoot)
                let finalIdentity = try ImmutableDirectoryPublication.identity(
                    of: final,
                    allowedModes: [ImmutableDirectoryPublication.immutableMode])
                guard finalIdentity == intent.directoryIdentity else {
                    throw ResultError.commitFailed(
                        "result publish final identity changed before recovery completion")
                }
                try removePublishIntent(
                    intentURL, expectedRecord: intentRecord)
                continue
            }
            if stagingExists {
                guard (stagingStat.st_mode & S_IFMT) == S_IFDIR,
                      ImmutableDirectoryPublication.Identity(
                        device: UInt64(stagingStat.st_dev),
                        inode: UInt64(stagingStat.st_ino))
                        == intent.directoryIdentity else {
                    throw ResultError.commitFailed(
                        "result publish staging identity mismatch")
                }
                // Rename never happened. The package is still hidden and is
                // not a committed business fact; clear only the intent and
                // leave normal task-scoped staging cleanup to remove/rebuild it.
                let stagingIdentity = try ImmutableDirectoryPublication.identity(
                    of: staging,
                    allowedModes: [
                        ImmutableDirectoryPublication.renameableMode,
                        ImmutableDirectoryPublication.immutableMode,
                    ])
                guard stagingIdentity == intent.directoryIdentity else {
                    throw ResultError.commitFailed(
                        "result publish staging changed before intent removal")
                }
                try removePublishIntent(
                    intentURL, expectedRecord: intentRecord)
                continue
            }
            throw ResultError.commitFailed(
                "result publish intent has neither staging nor final")
        }
        try requireBoundDirectoryPath(
            descriptor: openedRoot.descriptor,
            url: libraryRoot,
            expectedMetadata: openedRoot.metadata,
            context: "result publication recovery root after reconciliation")
    }

    private static func removePublishIntent(
        _ url: URL,
        expectedRecord: ReadPublishIntent
    ) throws {
        let record = try readPublishIntent(url)
        guard record.intent == expectedRecord.intent,
              record.data == expectedRecord.data,
              record.fileIdentity == expectedRecord.fileIdentity else {
            throw ResultError.commitFailed(
                "result publish-intent authority changed before removal")
        }
        let parent = url.deletingLastPathComponent()
        let openedParent = try openBoundDirectory(
            parent, context: "result publish-intent removal parent")
        defer { _ = close(openedParent.descriptor) }
        let stable = try readStableSmallRegularFileRecord(
            parentDescriptor: openedParent.descriptor,
            basename: url.lastPathComponent,
            maximumBytes: maximumPublishIntentBytes,
            requiredMode: 0o444)
        guard stable.data == record.data,
              stable.identity == record.fileIdentity else {
            throw ResultError.commitFailed(
                "result publish-intent changed before detach")
        }
        var beforeRemoval = stat()
        guard fstatat(
            openedParent.descriptor,
            url.lastPathComponent,
            &beforeRemoval,
            AT_SYMLINK_NOFOLLOW) == 0,
              sameStableRegularFile(stable.metadata, beforeRemoval) else {
            throw ResultError.commitFailed(
                "result publish-intent changed before removal rename")
        }
        let tombstoneName = publishIntentRemovalPrefix
            + identityToken(record.fileIdentity) + "."
            + UUID().uuidString.lowercased()
        guard renameatx_np(
            openedParent.descriptor, url.lastPathComponent,
            openedParent.descriptor, tombstoneName,
            UInt32(RENAME_EXCL)) == 0 else {
            throw ResultError.commitFailed(
                "cannot atomically detach result publish-intent")
        }
        var tombstoneMetadata = stat()
        let tombstoneMatches = fstatat(
            openedParent.descriptor,
            tombstoneName,
            &tombstoneMetadata,
            AT_SYMLINK_NOFOLLOW) == 0
            && sameCommittedRegularFileObject(
                stable.metadata, tombstoneMetadata)
        guard tombstoneMatches else {
            try quarantineUnexpectedPublishIntentRemoval(
                parentDescriptor: openedParent.descriptor,
                tombstoneName: tombstoneName,
                context: "detached result publish-intent")
        }
        guard fsync(openedParent.descriptor) == 0,
              unlinkat(openedParent.descriptor, tombstoneName, 0) == 0,
              fsync(openedParent.descriptor) == 0 else {
            throw ResultError.commitFailed(
                "cannot durably remove result publish-intent tombstone")
        }
        try requireBoundDirectoryPath(
            descriptor: openedParent.descriptor,
            url: parent,
            expectedMetadata: openedParent.metadata,
            context: "result publish-intent parent after removal")
    }

    private static func identityToken(
        _ identity: ImmutableDirectoryPublication.Identity
    ) -> String {
        return String(identity.device) + "-" + String(identity.inode)
    }

    private static func parseIdentityToken(
        _ token: String
    ) -> ImmutableDirectoryPublication.Identity? {
        let parts = token.split(
            separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let deviceText = String(parts[0])
        let inodeText = String(parts[1])
        guard isCanonicalUnsignedDecimal(deviceText),
              isCanonicalUnsignedDecimal(inodeText),
              let device = UInt64(deviceText),
              let inode = UInt64(inodeText) else {
            return nil
        }
        return ImmutableDirectoryPublication.Identity(
            device: device, inode: inode)
    }

    private static func isCanonicalLowercaseUUID(_ value: String) -> Bool {
        guard let uuid = UUID(uuidString: value) else { return false }
        return uuid.uuidString.lowercased() == value
    }

    private static func parseIdentityBoundName(
        _ name: String,
        prefix: String
    ) -> IdentityBoundTemporaryName? {
        guard name.hasPrefix(prefix) else { return nil }
        let body = String(name.dropFirst(prefix.count))
        let parts = body.split(
            separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let identity = parseIdentityToken(String(parts[0])),
              isCanonicalLowercaseUUID(String(parts[1])) else {
            return nil
        }
        return IdentityBoundTemporaryName(identity: identity)
    }

    private static func metadataIdentity(
        _ metadata: stat
    ) -> ImmutableDirectoryPublication.Identity {
        return ImmutableDirectoryPublication.Identity(
            device: UInt64(metadata.st_dev), inode: UInt64(metadata.st_ino))
    }

    private static func sameDirectoryObject(_ lhs: stat, _ rhs: stat) -> Bool {
        return (lhs.st_mode & S_IFMT) == S_IFDIR
            && (rhs.st_mode & S_IFMT) == S_IFDIR
            && lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
    }

    private static func sameStableRegularFile(_ lhs: stat, _ rhs: stat) -> Bool {
        return (lhs.st_mode & S_IFMT) == S_IFREG
            && (rhs.st_mode & S_IFMT) == S_IFREG
            && lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && lhs.st_mode == rhs.st_mode
            && lhs.st_nlink == rhs.st_nlink
            && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

    private static func sameCommittedRegularFileObject(
        _ lhs: stat,
        _ rhs: stat
    ) -> Bool {
        return (lhs.st_mode & S_IFMT) == S_IFREG
            && (rhs.st_mode & S_IFMT) == S_IFREG
            && lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && (lhs.st_mode & mode_t(0o777)) == 0o444
            && (rhs.st_mode & mode_t(0o777)) == 0o444
            && lhs.st_nlink == 1
            && rhs.st_nlink == 1
            && lhs.st_size == rhs.st_size
    }

    private static func openBoundDirectory(
        _ url: URL,
        context: String
    ) throws -> (descriptor: Int32, metadata: stat) {
        var pathMetadata = stat()
        guard lstat(url.path, &pathMetadata) == 0,
              (pathMetadata.st_mode & S_IFMT) == S_IFDIR else {
            throw ResultError.commitFailed("\(context) is not a real directory")
        }
        let descriptor = open(
            url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw ResultError.commitFailed(
                "cannot open \(context) without following links")
        }
        var openedMetadata = stat()
        guard fstat(descriptor, &openedMetadata) == 0,
              sameDirectoryObject(pathMetadata, openedMetadata) else {
            _ = close(descriptor)
            throw ResultError.commitFailed("\(context) changed while opening")
        }
        return (descriptor, openedMetadata)
    }

    private static func requireBoundDirectoryPath(
        descriptor: Int32,
        url: URL,
        expectedMetadata: stat,
        context: String
    ) throws {
        var openedMetadata = stat()
        var pathMetadata = stat()
        guard fstat(descriptor, &openedMetadata) == 0,
              lstat(url.path, &pathMetadata) == 0,
              sameDirectoryObject(expectedMetadata, openedMetadata),
              sameDirectoryObject(expectedMetadata, pathMetadata) else {
            throw ResultError.commitFailed(
                "\(context) dev/inode/path binding changed")
        }
    }

    private static func directoryEntryNames(
        atBoundDirectoryDescriptor descriptor: Int32,
        context: String,
        maximumEntries: Int = 100_000
    ) throws -> [String] {
        let enumerationDescriptor = openat(
            descriptor, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard enumerationDescriptor >= 0 else {
            throw ResultError.commitFailed(
                "cannot duplicate \(context) for enumeration")
        }
        guard let stream = fdopendir(enumerationDescriptor) else {
            _ = close(enumerationDescriptor)
            throw ResultError.commitFailed("cannot enumerate \(context)")
        }
        defer { _ = closedir(stream) }
        var names: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else {
                    throw ResultError.commitFailed(
                        "cannot finish enumerating \(context)")
                }
                break
            }
            guard let name = withUnsafePointer(to: entry.pointee.d_name, {
                pointer -> String? in
                pointer.withMemoryRebound(
                    to: CChar.self,
                    capacity: Int(MAXNAMLEN) + 1
                ) { String(validatingUTF8: $0) }
            }) else {
                throw ResultError.commitFailed(
                    "\(context) contains a non-UTF-8 name")
            }
            if name == "." || name == ".." { continue }
            guard !name.isEmpty, !name.contains("/") else {
                throw ResultError.commitFailed(
                    "\(context) contains an unsafe name")
            }
            guard names.count < maximumEntries else {
                throw ResultError.commitFailed(
                    "\(context) entry limit exceeded")
            }
            names.append(name)
        }
        return names.sorted()
    }

    private static func quarantineUnexpectedPublishIntentFile(
        parentDescriptor: Int32,
        basename: String,
        context: String
    ) throws -> Never {
        let conflictName = publishIntentConflictPrefix
            + UUID().uuidString.lowercased()
        if renameatx_np(
            parentDescriptor, basename,
            parentDescriptor, conflictName,
            UInt32(RENAME_EXCL)) == 0 {
            guard fsync(parentDescriptor) == 0 else {
                throw ResultError.commitFailed(
                    "cannot sync preserved \(context)")
            }
        }
        throw ResultError.commitFailed(
            "\(context) identity mismatch; evidence preserved")
    }

    private static func quarantineUnexpectedPublishIntentRemoval(
        parentDescriptor: Int32,
        tombstoneName: String,
        context: String
    ) throws -> Never {
        // A tombstone whose inode no longer matches its identity-bound name
        // can never regain the canonical intent basename. Restoring it would
        // let a later recovery pass treat the replacement inode as fresh
        // authority. Preserve it under the durable conflict namespace so all
        // subsequent recovery attempts remain fail-closed.
        try quarantineUnexpectedPublishIntentFile(
            parentDescriptor: parentDescriptor,
            basename: tombstoneName,
            context: context)
    }

    private static func removeIdentityBoundPublishIntentTemporary(
        parentDescriptor: Int32,
        basename: String,
        expectedMetadata: stat,
        context: String
    ) throws {
        let expectedIdentity = metadataIdentity(expectedMetadata)
        let tombstoneName = publishIntentTemporaryRemovalPrefix
            + identityToken(expectedIdentity) + "."
            + UUID().uuidString.lowercased()
        guard renameatx_np(
            parentDescriptor, basename,
            parentDescriptor, tombstoneName,
            UInt32(RENAME_EXCL)) == 0 else {
            throw ResultError.commitFailed("cannot detach \(context)")
        }
        var moved = stat()
        guard fstatat(
            parentDescriptor,
            tombstoneName,
            &moved,
            AT_SYMLINK_NOFOLLOW) == 0,
              sameCommittedOrCreationFileObject(expectedMetadata, moved) else {
            try quarantineUnexpectedPublishIntentRemoval(
                parentDescriptor: parentDescriptor,
                tombstoneName: tombstoneName,
                context: context)
        }
        guard fsync(parentDescriptor) == 0,
              unlinkat(parentDescriptor, tombstoneName, 0) == 0,
              fsync(parentDescriptor) == 0 else {
            throw ResultError.commitFailed(
                "cannot durably remove \(context)")
        }
    }

    private static func sameCommittedOrCreationFileObject(
        _ lhs: stat,
        _ rhs: stat
    ) -> Bool {
        let lhsMode = lhs.st_mode & mode_t(0o777)
        let rhsMode = rhs.st_mode & mode_t(0o777)
        return (lhs.st_mode & S_IFMT) == S_IFREG
            && (rhs.st_mode & S_IFMT) == S_IFREG
            && lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && lhsMode == rhsMode
            && [mode_t(0o600), mode_t(0o444)].contains(lhsMode)
            && lhs.st_nlink == 1
            && rhs.st_nlink == 1
            && lhs.st_size == rhs.st_size
    }

    private static func rejectUnboundPublishIntentCreationTemporaries(
        at libraryRoot: URL
    ) throws {
        let openedRoot = try openBoundDirectory(
            libraryRoot, context: "result publish-intent creation root")
        defer { _ = close(openedRoot.descriptor) }
        let names = try directoryEntryNames(
            atBoundDirectoryDescriptor: openedRoot.descriptor,
            context: "result publish-intent creation root")
        for name in names where name.hasPrefix(publishIntentCreationPrefix) {
            let suffix = String(name.dropFirst(publishIntentCreationPrefix.count))
            guard isCanonicalLowercaseUUID(suffix) else {
                throw ResultError.commitFailed(
                    "malformed unbound result publish-intent temporary preserved")
            }
            try quarantineUnexpectedPublishIntentFile(
                parentDescriptor: openedRoot.descriptor,
                basename: name,
                context: "unbound result publish-intent temporary")
        }
    }

    private static func cleanupPublishIntentTemporaryRemovalTombstones(
        at libraryRoot: URL
    ) throws {
        let openedRoot = try openBoundDirectory(
            libraryRoot, context: "result intent-temporary tombstone root")
        defer { _ = close(openedRoot.descriptor) }
        let names = try directoryEntryNames(
            atBoundDirectoryDescriptor: openedRoot.descriptor,
            context: "result intent-temporary tombstone root")
        var removed = false
        for name in names where
            name.hasPrefix(publishIntentTemporaryRemovalPrefix) {
            guard let parsed = parseIdentityBoundName(
                name, prefix: publishIntentTemporaryRemovalPrefix) else {
                throw ResultError.commitFailed(
                    "malformed result intent-temporary tombstone preserved")
            }
            var metadata = stat()
            guard fstatat(
                openedRoot.descriptor,
                name,
                &metadata,
                AT_SYMLINK_NOFOLLOW) == 0 else {
                throw ResultError.commitFailed(
                    "cannot inspect result intent-temporary tombstone")
            }
            guard metadataIdentity(metadata) == parsed.identity else {
                try quarantineUnexpectedPublishIntentFile(
                    parentDescriptor: openedRoot.descriptor,
                    basename: name,
                    context: "result intent-temporary tombstone")
            }
            let mode = metadata.st_mode & mode_t(0o777)
            guard (metadata.st_mode & S_IFMT) == S_IFREG,
                  metadata.st_nlink == 1,
                  metadata.st_size >= 0,
                  metadata.st_size <= maximumPublishIntentBytes,
                  [mode_t(0o600), mode_t(0o444)].contains(mode),
                  unlinkat(openedRoot.descriptor, name, 0) == 0 else {
                throw ResultError.commitFailed(
                    "invalid result intent-temporary tombstone")
            }
            removed = true
        }
        if removed, fsync(openedRoot.descriptor) != 0 {
            throw ResultError.commitFailed(
                "cannot sync result intent-temporary tombstone cleanup")
        }
    }

    private static func cleanupPublishIntentRemovalTombstones(
        at libraryRoot: URL
    ) throws {
        let openedRoot = try openBoundDirectory(
            libraryRoot, context: "result publish-intent tombstone root")
        defer { _ = close(openedRoot.descriptor) }
        let names = try directoryEntryNames(
            atBoundDirectoryDescriptor: openedRoot.descriptor,
            context: "result publish-intent tombstone root")
        var removed = false
        for name in names where name.hasPrefix(publishIntentRemovalPrefix) {
            guard let parsed = parseIdentityBoundName(
                name, prefix: publishIntentRemovalPrefix) else {
                throw ResultError.commitFailed(
                    "malformed result publish-intent tombstone preserved")
            }
            let record: ReadPublishIntent
            do {
                record = try readPublishIntent(
                    parentDescriptor: openedRoot.descriptor,
                    basename: name,
                    requireCanonicalName: false)
            } catch {
                try quarantineUnexpectedPublishIntentFile(
                    parentDescriptor: openedRoot.descriptor,
                    basename: name,
                    context: "invalid result publish-intent tombstone")
            }
            let canonicalName = publishIntentName(
                taskID: record.intent.taskID,
                resultID: record.intent.resultID)
            guard record.fileIdentity == parsed.identity else {
                try quarantineUnexpectedPublishIntentRemoval(
                    parentDescriptor: openedRoot.descriptor,
                    tombstoneName: name,
                    context: "result publish-intent tombstone")
            }
            var canonicalMetadata = stat()
            guard fstatat(
                openedRoot.descriptor,
                canonicalName,
                &canonicalMetadata,
                AT_SYMLINK_NOFOLLOW) != 0,
                  errno == ENOENT,
                  unlinkat(openedRoot.descriptor, name, 0) == 0 else {
                throw ResultError.commitFailed(
                    "result publish-intent tombstone conflicts with canonical authority")
            }
            removed = true
        }
        if removed, fsync(openedRoot.descriptor) != 0 {
            throw ResultError.commitFailed(
                "cannot sync result publish-intent tombstone cleanup")
        }
    }

    private static func cleanupPublishIntentTemporaries(
        at libraryRoot: URL
    ) throws {
        let openedRoot = try openBoundDirectory(
            libraryRoot, context: "result publish-intent temporary root")
        defer { _ = close(openedRoot.descriptor) }
        let names = try directoryEntryNames(
            atBoundDirectoryDescriptor: openedRoot.descriptor,
            context: "result publish-intent temporary root")
        let temporaryNames = names.filter {
            $0.hasPrefix(publishIntentTemporaryPrefix)
                && !$0.hasPrefix(publishIntentTemporaryRemovalPrefix)
        }
        guard temporaryNames.isEmpty
                || !names.contains(where: isPublishIntentName) else {
            throw ResultError.commitFailed(
                "result publish-intent temporary coexists with canonical intent")
        }
        for name in temporaryNames where
            name.hasPrefix(publishIntentTemporaryPrefix)
                && !name.hasPrefix(publishIntentTemporaryRemovalPrefix) {
            guard let parsed = parseIdentityBoundName(
                name, prefix: publishIntentTemporaryPrefix) else {
                throw ResultError.commitFailed(
                    "malformed result publish-intent temporary preserved")
            }
            var metadata = stat()
            guard fstatat(
                openedRoot.descriptor,
                name,
                &metadata,
                AT_SYMLINK_NOFOLLOW) == 0,
                  metadataIdentity(metadata) == parsed.identity,
                  (metadata.st_mode & S_IFMT) == S_IFREG,
                  metadata.st_nlink == 1,
                  metadata.st_size >= 0,
                  metadata.st_size <= maximumPublishIntentBytes,
                  [mode_t(0o600), mode_t(0o444)].contains(
                    metadata.st_mode & mode_t(0o777)) else {
                throw ResultError.commitFailed(
                    "orphan result publish-intent temporary identity mismatch")
            }
            if metadata.st_mode & mode_t(0o777) == 0o444 {
                let record = try readPublishIntent(
                    parentDescriptor: openedRoot.descriptor,
                    basename: name,
                    requireCanonicalName: false)
                guard record.fileIdentity == parsed.identity else {
                    throw ResultError.commitFailed(
                        "orphan result publish-intent temporary payload mismatch")
                }
            }
            try removeIdentityBoundPublishIntentTemporary(
                parentDescriptor: openedRoot.descriptor,
                basename: name,
                expectedMetadata: metadata,
                context: "orphan result publish-intent temporary")
        }
    }

    private static func rejectPublishIntentConflictEvidence(
        at libraryRoot: URL
    ) throws {
        let openedRoot = try openBoundDirectory(
            libraryRoot, context: "result publish-intent conflict root")
        defer { _ = close(openedRoot.descriptor) }
        let names = try directoryEntryNames(
            atBoundDirectoryDescriptor: openedRoot.descriptor,
            context: "result publish-intent conflict root")
        if names.contains(where: { $0.hasPrefix(publishIntentConflictPrefix) }) {
            throw ResultError.commitFailed(
                "result publish-intent conflict evidence is preserved")
        }
    }

    private static func isCanonicalUnsignedDecimal(_ value: String) -> Bool {
        guard !value.isEmpty,
              value.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else {
            return false
        }
        return value == "0" || !value.hasPrefix("0")
    }

    private static func isSHA256(_ value: String) -> Bool {
        return value.utf8.count == 64 && value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
        }
    }

    private static func readStableSmallRegularFile(
        _ url: URL,
        maximumBytes: Int,
        requiredMode: mode_t
    ) throws -> Data {
        return try readStableSmallRegularFileRecord(
            url,
            maximumBytes: maximumBytes,
            requiredMode: requiredMode).data
    }

    private static func sha256StableCommittedFile(
        parentDescriptor: Int32,
        basename: String,
        expectedBytes: Int64
    ) throws -> (sha256: String, metadata: stat) {
        guard isSafeBasename(basename), expectedBytes >= 0 else {
            throw ResultError.artifactCorrupt(
                "invalid committed artifact contract: \(basename)")
        }
        var pathBefore = stat()
        guard fstatat(
            parentDescriptor,
            basename,
            &pathBefore,
            AT_SYMLINK_NOFOLLOW) == 0,
              (pathBefore.st_mode & S_IFMT) == S_IFREG,
              (pathBefore.st_mode & mode_t(0o777)) == 0o444,
              pathBefore.st_nlink == 1,
              Int64(pathBefore.st_size) == expectedBytes else {
            throw ResultError.artifactCorrupt(
                "artifact type/mode/link/size is invalid: \(basename)")
        }
        let descriptor = openat(
            parentDescriptor,
            basename,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw ResultError.artifactCorrupt(
                "cannot open artifact without following links: \(basename)")
        }
        defer { _ = close(descriptor) }
        var openedBefore = stat()
        guard fstat(descriptor, &openedBefore) == 0,
              sameStableRegularFile(pathBefore, openedBefore) else {
            throw ResultError.artifactCorrupt(
                "artifact changed before open: \(basename)")
        }
        var hasher = SHA256()
        var totalBytes: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { rawBuffer -> Int in
                guard let base = rawBuffer.baseAddress else { return -1 }
                return Darwin.read(descriptor, base, rawBuffer.count)
            }
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else {
                throw ResultError.artifactCorrupt(
                    "artifact read failed: \(basename)")
            }
            if count == 0 { break }
            guard totalBytes <= expectedBytes - Int64(count) else {
                throw ResultError.artifactCorrupt(
                    "artifact grew during hash: \(basename)")
            }
            hasher.update(data: Data(buffer.prefix(count)))
            totalBytes += Int64(count)
        }
        var openedAfter = stat()
        var pathAfter = stat()
        guard totalBytes == expectedBytes,
              fstat(descriptor, &openedAfter) == 0,
              fstatat(
                parentDescriptor,
                basename,
                &pathAfter,
                AT_SYMLINK_NOFOLLOW) == 0,
              sameStableRegularFile(openedBefore, openedAfter),
              sameStableRegularFile(openedBefore, pathAfter) else {
            throw ResultError.artifactCorrupt(
                "artifact changed during hash: \(basename)")
        }
        let digest = hasher.finalize().map {
            String(format: "%02x", $0)
        }.joined()
        return (digest, openedBefore)
    }

    private static func readStableSmallRegularFileRecord(
        _ url: URL,
        maximumBytes: Int,
        requiredMode: mode_t
    ) throws -> StableRegularFile {
        let parent = url.deletingLastPathComponent()
        let openedParent = try openBoundDirectory(
            parent, context: "bounded regular-file parent")
        defer { _ = close(openedParent.descriptor) }
        let result = try readStableSmallRegularFileRecord(
            parentDescriptor: openedParent.descriptor,
            basename: url.lastPathComponent,
            maximumBytes: maximumBytes,
            requiredMode: requiredMode)
        try requireBoundDirectoryPath(
            descriptor: openedParent.descriptor,
            url: parent,
            expectedMetadata: openedParent.metadata,
            context: "bounded regular-file parent after read")
        return result
    }

    private static func readStableSmallRegularFileRecord(
        parentDescriptor: Int32,
        basename: String,
        maximumBytes: Int,
        requiredMode: mode_t
    ) throws -> StableRegularFile {
        guard isSafeInternalBasename(basename), maximumBytes >= 0 else {
            throw ResultError.commitFailed(
                "invalid bounded regular-file read request")
        }
        var pathBefore = stat()
        guard fstatat(
            parentDescriptor,
            basename,
            &pathBefore,
            AT_SYMLINK_NOFOLLOW) == 0,
              (pathBefore.st_mode & S_IFMT) == S_IFREG,
              pathBefore.st_nlink == 1,
              (pathBefore.st_mode & mode_t(0o777)) == requiredMode,
              pathBefore.st_size >= 0,
              pathBefore.st_size <= maximumBytes else {
            throw ResultError.commitFailed(
                "invalid bounded regular file: \(basename)")
        }
        let descriptor = openat(
            parentDescriptor,
            basename,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw ResultError.commitFailed(
                "cannot open \(basename) without following links")
        }
        defer { _ = close(descriptor) }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0,
              sameStableRegularFile(pathBefore, opened) else {
            throw ResultError.commitFailed(
                "bounded regular file changed before open: \(basename)")
        }
        var data = Data()
        data.reserveCapacity(Int(opened.st_size))
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { rawBuffer -> Int in
                guard let base = rawBuffer.baseAddress else { return -1 }
                return Darwin.read(descriptor, base, rawBuffer.count)
            }
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else {
                throw ResultError.commitFailed(
                    "cannot read \(basename)")
            }
            if count == 0 { break }
            guard data.count <= maximumBytes - count else {
                throw ResultError.commitFailed(
                    "bounded file grew while reading: \(basename)")
            }
            data.append(contentsOf: buffer.prefix(count))
        }
        var after = stat()
        var pathAfter = stat()
        guard fstat(descriptor, &after) == 0,
              fstatat(
                parentDescriptor,
                basename,
                &pathAfter,
                AT_SYMLINK_NOFOLLOW) == 0,
              sameStableRegularFile(opened, after),
              sameStableRegularFile(opened, pathAfter),
              data.count == Int(opened.st_size) else {
            throw ResultError.commitFailed(
                "bounded file changed while reading: \(basename)")
        }
        return StableRegularFile(
            data: data,
            metadata: opened,
            identity: metadataIdentity(opened))
    }

    private static func recoverAndRemoveStaging(_ directory: URL) {
        // A process kill after the pre-rename freeze can leave an
        // uncommitted package at 0555/0444. Thaw only an internal staging
        // path before removing it; committed final paths never reach here.
        try? makeStagingRecoverable(directory)
        try? FileManager.default.removeItem(at: directory)
    }

    private static func readCommitReceipt(_ data: Data) throws -> CommitReceipt {
        guard !data.isEmpty, data.count <= 64 * 1024 else {
            throw ResultError.invalidManifest("invalid commit receipt")
        }
        guard let object = try? StrictJSONDocumentParser.object(
            from: data,
            limits: StrictJSONDocumentLimits(maximumBytes: data.count + 1))
                as? [String: Any],
              Set(object.keys) == Set([
                "format", "version", "result_id", "final_path",
                "manifest_sha256", "commit_generation",
              ]),
              object["format"] as? String ==
                "MarketScannerResultCommitReceipt",
              StrictJSONScalar.integer(object["version"]) == 1,
              let resultID = object["result_id"] as? String,
              let finalPath = object["final_path"] as? String,
              let manifestSHA256 = object["manifest_sha256"] as? String,
              manifestSHA256.count == 64,
              manifestSHA256.allSatisfy({ $0.isHexDigit }),
              let generation = StrictJSONScalar.integer(
                object["commit_generation"]), generation == 1 else {
            throw ResultError.invalidManifest("invalid commit receipt")
        }
        return CommitReceipt(
            resultID: resultID,
            finalPath: finalPath,
            manifestSHA256: manifestSHA256,
            commitGeneration: generation)
    }

    private static func writeNewRegularFile(_ data: Data, to url: URL) throws {
        let fd = open(
            url.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
            mode_t(0o600))
        guard fd >= 0 else {
            throw ResultError.commitFailed(
                "cannot create \(url.lastPathComponent)")
        }
        defer { close(fd) }
        var written = 0
        let result = data.withUnsafeBytes { rawBuffer -> Bool in
            guard let base = rawBuffer.baseAddress else { return data.isEmpty }
            while written < rawBuffer.count {
                let count = Darwin.write(
                    fd, base.advanced(by: written), rawBuffer.count - written)
                if count <= 0 { return false }
                written += count
            }
            return true
        }
        guard result else {
            throw ResultError.commitFailed(
                "cannot write \(url.lastPathComponent)")
        }
    }

    private static func validateExactDirectorySet(
        _ directory: URL,
        expectedNames: Set<String>,
        expectedDirectoryMode: Int?,
        expectedFileMode: Int?
    ) throws {
        var directoryStat = stat()
        guard lstat(directory.path, &directoryStat) == 0,
              (directoryStat.st_mode & S_IFMT) == S_IFDIR,
              directoryStat.st_nlink >= 1 else {
            throw ResultError.commitFailed("result staging is not a directory")
        }
        if let expectedDirectoryMode,
           Int(directoryStat.st_mode & 0o777) != expectedDirectoryMode {
            throw ResultError.commitFailed("result directory mode mismatch")
        }
        let names = try FileManager.default.contentsOfDirectory(
            atPath: directory.path)
        guard Set(names) == expectedNames, names.count == expectedNames.count else {
            throw ResultError.commitFailed(
                "result file set mismatch: expected=\(expectedNames.sorted()) actual=\(names.sorted())")
        }
        for name in names {
            guard isSafeBasename(name) else {
                throw ResultError.commitFailed("unsafe staged file: \(name)")
            }
            let url = directory.appendingPathComponent(name)
            var value = stat()
            guard lstat(url.path, &value) == 0,
                  (value.st_mode & S_IFMT) == S_IFREG,
                  value.st_nlink == 1 else {
                throw ResultError.commitFailed(
                    "staged artifact must be one regular non-hardlinked file: \(name)")
            }
            if let expectedFileMode,
               Int(value.st_mode & 0o777) != expectedFileMode {
                throw ResultError.commitFailed("file mode mismatch: \(name)")
            }
        }
    }

    /// V1R5 §13.1 (review H-01): durability is never best-effort — any
    /// open/fsync failure THROWS and blocks the commit.
    private static func syncFile(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else {
            throw ResultError.commitFailed(
                "cannot open for fsync: \(url.lastPathComponent)")
        }
        defer { _ = close(fd) }
        var metadata = stat()
        guard fstat(fd, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_nlink == 1,
              fsync(fd) == 0 else {
            throw ResultError.commitFailed(
                "fsync failed: \(url.lastPathComponent)")
        }
    }
}
