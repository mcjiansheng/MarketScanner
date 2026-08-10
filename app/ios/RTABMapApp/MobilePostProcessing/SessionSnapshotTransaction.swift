import Darwin
import Foundation
import CryptoKit
import SQLite3

/// Captures a finalized session into a verified, immutable processing
/// snapshot (V1R3 Gate E §8). The source session is NEVER modified and
/// never loaded whole into memory:
///
/// - eligibility is checked once against the stable metadata (§8.1);
/// - every file is copied through a POSIX streaming copier (§8.3):
///   lstat/open O_RDONLY|O_NOFOLLOW, pre fstat, regular-file + nlink
///   policy, O_CREAT|O_EXCL destination, 1–8 MiB chunk copy with
///   incremental SHA-256, fsync, post-fstat source identity check,
///   destination reopen + second SHA, chmod read-only;
/// - the DB is validated read-only (quick_check exactly one "ok" and the
///   expected table inventory, §8.5);
/// - a dynamic disk budget is enforced before any copy (§8.6);
/// - the whole snapshot uses a durable intent-bound transaction: payloads
///   are frozen while the publication root remains 0755, the same-parent
///   rename publishes only a pathname, the exact renamed inode is then
///   frozen/fsynced as 0555, and the task-root authority is installed last
///   (§8.7). Rename alone is never the business commit point.
enum SessionSnapshotTransaction {
    enum FaultPoint {
        case afterSourceInventory
        case beforeManifestWrite
        case afterTransactionIntentCreationBeforeIdentityBind
        case afterTransactionIntentTemporaryFsyncBeforeRename
        case afterTransactionIntentRenameBeforeParentFsync
        case afterPreviousSnapshotThawBeforeBackupRename
        case afterPreviousSnapshotRenameBeforeFreeze
        case afterPreviousSnapshotFreezeBeforeParentFsync
        case afterSnapshotRenameBeforeFreeze
        case afterSnapshotFreezeBeforeParentFsync
        case afterSnapshotInstall
        case afterTaskReferenceAuthorityReadBeforeInstall
        case afterTaskReferenceCreationBeforeIdentityBind
        case afterTaskReferenceTemporaryFsyncBeforeRename
        case afterTaskReferenceAuthorityRecheckBeforeInstall
        case afterTaskReferenceRenameBeforePostcheck
        case afterTaskReferenceAuthorityRecheckBeforeClear
        case afterTaskReferenceClearRenameBeforePostcheck
        case beforeTaskReferenceFsync
        case afterTaskReferenceDurableBeforeCleanup
        case afterRecoveryCoreBeforeReturn
        case beforeBackupRestore
        case afterPriorAuthorityRestoreBeforeGenerationCleanup
        case afterCleanupRootPreparedBeforeRemoval
        case afterCleanupChildRemoval
        case afterTransactionIntentAuthorityRecheckBeforeRemoval
        case afterTransactionIntentRemovalRenameBeforePostcheck
        case afterGenerationRootOpenBeforeValidation
        case afterCommittedFileAuthorityReadBeforeOpen(String)
        case afterCommittedFileOpenBeforeRead(String)
        case afterArtifactAuthorityReadBeforeOpen(String)
        case afterArtifactHashBeforeGenerationEnd(String)
    }

    /// Deterministic filesystem fault injection used by the executable host
    /// suite. Production leaves this nil.
    static var faultInjector: ((FaultPoint) throws -> Void)?
    /// Host-only synchronization hooks for exact process-lock namespace
    /// replacement tests. Production leaves all three nil.
    static var processLockAttemptObserver: (() throws -> Void)?
    static var processLockAcquiredObserver: (() throws -> Void)?
    static var processLockValidationObserver: (() throws -> Void)?
    /// Executable host-test hook for the iOS compatibility path. Production
    /// leaves this false. When enabled, descriptor validation bypasses both
    /// the in-process semantic-validation cache and Darwin `/dev/fd` so the
    /// private descriptor-copy fallback is exercised deterministically.
    static var forcePrivateDatabaseValidationCopyForTests = false
    private static let transactionLock = NSLock()
    private static let databaseValidationCacheLock = NSLock()
    private static var databaseValidationCache = Set<DatabaseValidationIdentity>()
    private static var databaseValidationCacheOrder: [DatabaseValidationIdentity] = []
    private static let maximumDatabaseValidationCacheEntries = 64

    struct SessionSnapshot {
        var taskID: String
        var snapshotDirectory: URL
        var inputManifest: [String: Any]
        var bundleSHA256: String
    }

    private struct ValidatedSnapshotGeneration {
        let manifestData: Data
        let manifestSHA256: String
        let taskID: String
        let generation: String
        let bundleSHA256: String
        let directoryIdentity: ImmutableDirectoryPublication.Identity
        let directoryMode: mode_t
    }

    private struct SnapshotCommitIntent: Equatable {
        let taskID: String
        let newManifestSHA256: String
        let newIdentity: ImmutableDirectoryPublication.Identity
        let priorManifestSHA256: String?
        let priorIdentity: ImmutableDirectoryPublication.Identity?
    }

    private struct ReadSnapshotCommitIntent {
        let intent: SnapshotCommitIntent
        let fileIdentity: ImmutableDirectoryPublication.Identity
        let data: Data
    }

    private struct ProcessLockHandle {
        let rootURL: URL
        let rootDescriptor: Int32
        let rootMetadata: stat
        let lockDescriptor: Int32
        let lockMetadata: stat
    }

    /// A semantic SQLite validation is reusable only for the exact immutable
    /// file identity that was checked. Including size, mode, link count and
    /// nanosecond mtime/ctime means chmod, in-place writes and replacements
    /// cannot inherit a prior validation result.
    private struct DatabaseValidationIdentity: Hashable {
        let device: UInt64
        let inode: UInt64
        let mode: UInt32
        let linkCount: UInt64
        let size: Int64
        let modificationSeconds: Int64
        let modificationNanoseconds: Int64
        let changeSeconds: Int64
        let changeNanoseconds: Int64

        init(_ metadata: stat) {
            device = UInt64(metadata.st_dev)
            inode = UInt64(metadata.st_ino)
            mode = UInt32(metadata.st_mode)
            linkCount = UInt64(metadata.st_nlink)
            size = Int64(metadata.st_size)
            modificationSeconds = Int64(metadata.st_mtimespec.tv_sec)
            modificationNanoseconds = Int64(metadata.st_mtimespec.tv_nsec)
            changeSeconds = Int64(metadata.st_ctimespec.tv_sec)
            changeNanoseconds = Int64(metadata.st_ctimespec.tv_nsec)
        }
    }

    /// Signals an authority CAS conflict whose pre-transaction state could
    /// not be restored atomically. The caller must preserve the durable
    /// intent and every generation instead of attempting ordinary rollback.
    private enum SnapshotTransactionConflict: Error {
        case taskAuthorityDisplaced
    }

    private struct TaskManifestTemporaryName {
        let temporaryIdentity: ImmutableDirectoryPublication.Identity
        let expectedDisplacedIdentity: ImmutableDirectoryPublication.Identity?
        let targetSHA256: String
    }

    private struct IdentityBoundTemporaryName {
        let identity: ImmutableDirectoryPublication.Identity
    }

    /// Identity bindings the snapshot must match (§8.1). When nil (legacy
    /// callers), only the base finalization checks run.
    struct Eligibility {
        var priorMapID: String?
        var priorMapSHA256: String?
        var storeID: String?
        var floorID: String?
        var appGitSHA: String
    }

    /// Formal Mobile-Only finalized metadata. Legacy/minimal metadata may
    /// still be inspected by diagnostics elsewhere, but it can never enter
    /// the publishable snapshot path.
    private struct StrictFinalizedSessionMetadata {
        struct CaptureHealth {
            var requiredWriteFailureCount: Int64
            var localizationTraceRecordCount: Int64
            var localizationConstraintRecordCount: Int64
            var manualLocalizationEventCount: Int64
            var localizationStateEventCount: Int64
            var localizationEvidenceComplete: Bool
            var recoveryEventCount: Int64
            var lastRecoveryEpisodeID: Int64?
            var lastRecoveryFinishedAtUptime: Double?
            var recoveryEvidenceComplete: Bool
        }

        var raw: [String: Any]
        var format: String
        var version: Int64
        var formatVersion: Int64
        var finalized: Bool
        var finalizedAtUnix: Double
        var scanMode: String
        var workflowMode: String
        var trackingSessionID: String
        var storeID: String
        var floorID: String
        var priorMapID: String
        var priorMapSHA256: String
        var processingStatus: String
        var processingBlockers: [String]
        var captureHealth: CaptureHealth
        var clockCorrelationCount: Int64
        var clockNodeBindingCount: Int64
        var clockLastMonotonic: Double
        var clockLastUTC: Double
        var clockEvidenceComplete: Bool
        var tagObservationBurstCount: Int64
        var tagObservationBurstLastID: String?
        var tagObservationBurstComplete: Bool

        subscript(key: String) -> Any? { raw[key] }
    }

    private struct SourceInventoryEntry: Equatable {
        var relativeName: String
        var fileType: mode_t
        var device: UInt64
        var inode: UInt64
        var size: Int64
        var linkCount: UInt64
        var modificationSeconds: Int64
        var modificationNanoseconds: Int64
        var changeSeconds: Int64
        var changeNanoseconds: Int64
        var mode: mode_t
    }

    enum SessionError: Error, LocalizedError {
        case sessionMissing
        case notFinalized
        case notEligible(String)
        case missingRequired(String)
        case copyFailed(String)
        case emptyInput
        case insufficientDisk(String)
        case dbIntegrity(String)

        var errorDescription: String? {
            switch self {
            case .sessionMissing: return "会话输入缺失"
            case .notFinalized: return "会话未完成 finalization"
            case .notEligible(let detail): return "会话不满足处理资格：\(detail)"
            case .missingRequired(let detail): return "缺少必需证据文件：\(detail)"
            case .copyFailed(let detail): return "稳定复制失败：\(detail)"
            case .emptyInput: return "快照输入为空"
            case .insufficientDisk(let detail): return "磁盘预算不足：\(detail)"
            case .dbIntegrity(let detail): return "快照数据库校验失败：\(detail)"
            }
        }
    }

    /// Base session evidence files (§8.2). metadata.json and the DB are
    /// always required; the JSONL sidecars are required when present in
    /// the source (a session that recorded them cannot lose them).
    static let requiredFileNames = [
        "metadata.json",
        "localization_trace.jsonl",
        // RunSummary consumes scan-phase thermal evidence from this file.
        // A finalized Mobile-Only session always writes scan_started and
        // finalization events, so omitting the log would under-report a
        // critical thermal interruption and must fail closed.
        "scan_events.jsonl",
    ]
    static let watermarkFileNames = [
        "clock_correlations.jsonl",
        "tag_observation_bursts.jsonl",
    ]
    static let optionalFileNames = [
        "localization_constraints.jsonl",
        "localization_events.jsonl",
        "manual_localization_events.jsonl",
        "tag_observations.jsonl",
        "localization_recovery_events.jsonl",
        "localized_price_tags.json",
    ]
    static let databaseFileName = "rtabmap_segment_0001.db"
    /// V1R5 §9.4: a non-empty WAL/journal beside the main DB means the
    /// writer never checkpointed — copying only the main DB would silently
    /// drop committed data. Any of these files must be absent or EMPTY at
    /// snapshot time (fail closed).
    static let walJournalNames = [
        "-wal", "-journal", "-shm",
    ]

    /// Metadata sidecar declarations: metadata key -> artifact file name.
    /// A non-empty declaration makes the artifact REQUIRED (B-08).
    static let declaredSidecarPairs: [(key: String, name: String)] = [
        ("localizationTrace", "localization_trace.jsonl"),
        ("manualLocalizationEvents", "manual_localization_events.jsonl"),
        ("localizationConstraints", "localization_constraints.jsonl"),
        ("localizationEvents", "localization_events.jsonl"),
        ("localizationRecoveryEvents", "localization_recovery_events.jsonl"),
        ("tagObservations", "tag_observations.jsonl"),
        ("localizedPriceTags", "localized_price_tags.json"),
    ]

    static let copyChunkBytes = 4 * 1024 * 1024
    static let safetyReserveBytes: Int64 = 256 * 1024 * 1024
    static let maximumMetadataBytes: Int64 = 1024 * 1024
    static let committedFileMode: mode_t = 0o444
    static let committedDirectoryMode: mode_t = 0o555
    static let preparedDirectoryMode: mode_t = 0o755
    static let cleanupDirectoryMode: mode_t = 0o700
    static let transactionIntentFileName = "input_snapshot.transaction.json"
    static let transactionIntentTemporaryPrefix =
        "input_snapshot.transaction.tmp-"
    static let transactionIntentCreationPrefix =
        "input_snapshot.transaction.create-"
    static let transactionIntentRemovalPrefix =
        "input_snapshot.transaction.remove-"
    static let transactionIntentTemporaryRemovalPrefix =
        "input_snapshot.transaction.tmp-remove-"
    static let transactionIntentConflictPrefix =
        "input_snapshot.transaction.conflict-"
    static let taskManifestTemporaryPrefix = ".input_manifest."
    static let taskManifestTemporarySuffix = ".tmp"
    static let taskManifestCreationPrefix = ".input_manifest.create-"
    static let taskManifestRemovalPrefix = ".input_manifest.remove-"
    static let taskManifestTemporaryRemovalPrefix =
        ".input_manifest.tmp-remove-"
    static let taskManifestConflictPrefix = ".input_manifest.conflict-"
    static let processLockFileName = "input_snapshot.lock"
    static let maximumSnapshotTransactionIntentBytes = 64 * 1024
    static let maximumSnapshotCommitMarkerBytes = 64 * 1024
    static let maximumTaskManifestBytes = 4 * 1024 * 1024
    static let maximumSnapshotDirectoryEntries = 4_096
    static let maximumGraphNodes: Int64 = 200_000
    static let maximumGraphLinks: Int64 = 400_000

    /// Creates the snapshot for `taskID` under
    /// `Application Support/MarketScanner/Processing/<taskID>/input_snapshot/`
    /// and returns the verified snapshot.
    static func snapshot(
        finalizedSession: URL,
        sourceDatabase: URL,
        taskRoot: URL,
        eligibility: Eligibility? = nil
    ) throws -> SessionSnapshot {
        transactionLock.lock()
        defer { transactionLock.unlock() }
        let processLock = try acquireProcessLock(taskRoot: taskRoot)
        defer { releaseProcessLock(processLock) }
        let value = try snapshotLocked(
            finalizedSession: finalizedSession,
            sourceDatabase: sourceDatabase,
            taskRoot: taskRoot,
            eligibility: eligibility)
        try validateProcessLock(processLock)
        return value
    }

    private static func acquireProcessLock(
        taskRoot: URL
    ) throws -> ProcessLockHandle {
        let openedRoot = try openStableDirectoryNoFollow(
            taskRoot, context: "snapshot process-lock task root")
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
            throw SessionError.copyFailed(
                "cannot open snapshot process lock")
        }
        var metadata = stat()
        var pathMetadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_nlink == 1,
              metadata.st_size == 0,
              (metadata.st_mode & mode_t(0o777)) == 0o600,
              fstatat(
                openedRoot.descriptor,
                processLockFileName,
                &pathMetadata,
                AT_SYMLINK_NOFOLLOW) == 0,
              sameFileIdentity(metadata, pathMetadata) else {
            _ = close(descriptor)
            throw SessionError.copyFailed(
                "snapshot process lock identity/mode invalid")
        }
        do {
            try requireOpenDirectoryPath(
                descriptor: openedRoot.descriptor,
                url: taskRoot,
                expectedMetadata: openedRoot.metadata,
                context: "snapshot process-lock task root before lock")
            try processLockAttemptObserver?()
        } catch {
            _ = close(descriptor)
            throw error
        }
        while Darwin.lockf(descriptor, F_LOCK, 0) != 0 {
            if errno == EINTR { continue }
            _ = close(descriptor)
            throw SessionError.copyFailed(
                "cannot acquire snapshot process lock")
        }
        do {
            try processLockAcquiredObserver?()
            var lockedMetadata = stat()
            var lockedPathMetadata = stat()
            guard fstat(descriptor, &lockedMetadata) == 0,
                  fstatat(
                    openedRoot.descriptor,
                    processLockFileName,
                    &lockedPathMetadata,
                    AT_SYMLINK_NOFOLLOW) == 0,
                  sameFileIdentity(metadata, lockedMetadata),
                  sameFileIdentity(metadata, lockedPathMetadata),
                  lockedMetadata.st_nlink == 1,
                  lockedMetadata.st_size == 0,
                  (lockedMetadata.st_mode & mode_t(0o777)) == 0o600 else {
                throw SessionError.copyFailed(
                    "snapshot process lock pathname changed while acquiring")
            }
            try requireOpenDirectoryPath(
                descriptor: openedRoot.descriptor,
                url: taskRoot,
                expectedMetadata: openedRoot.metadata,
                context: "snapshot process-lock task root after lock")
            keepRootDescriptor = true
            return ProcessLockHandle(
                rootURL: taskRoot,
                rootDescriptor: openedRoot.descriptor,
                rootMetadata: openedRoot.metadata,
                lockDescriptor: descriptor,
                lockMetadata: lockedMetadata)
        } catch {
            _ = Darwin.lockf(descriptor, F_ULOCK, 0)
            _ = close(descriptor)
            throw error
        }
    }

    private static func validateProcessLock(
        _ handle: ProcessLockHandle
    ) throws {
        try processLockValidationObserver?()
        var lockDescriptorMetadata = stat()
        var lockPathMetadata = stat()
        guard fstat(handle.lockDescriptor, &lockDescriptorMetadata) == 0,
              fstatat(
                handle.rootDescriptor,
                processLockFileName,
                &lockPathMetadata,
                AT_SYMLINK_NOFOLLOW) == 0,
              sameFileIdentity(
                handle.lockMetadata, lockDescriptorMetadata),
              sameFileIdentity(handle.lockMetadata, lockPathMetadata),
              lockDescriptorMetadata.st_nlink == 1,
              lockDescriptorMetadata.st_size == 0,
              (lockDescriptorMetadata.st_mode & mode_t(0o777)) == 0o600 else {
            throw SessionError.copyFailed(
                "snapshot process lock authority changed")
        }
        try requireOpenDirectoryPath(
            descriptor: handle.rootDescriptor,
            url: handle.rootURL,
            expectedMetadata: handle.rootMetadata,
            context: "snapshot process-lock final validation")
    }

    private static func releaseProcessLock(_ handle: ProcessLockHandle) {
        _ = Darwin.lockf(handle.lockDescriptor, F_ULOCK, 0)
        _ = close(handle.lockDescriptor)
        _ = close(handle.rootDescriptor)
    }

    private static func snapshotLocked(
        finalizedSession: URL,
        sourceDatabase: URL,
        taskRoot: URL,
        eligibility: Eligibility? = nil
    ) throws -> SessionSnapshot {
        let fileManager = FileManager.default
        let taskID = taskRoot.lastPathComponent

        // B-08: the source database must be PROVEN to live inside the
        // finalized session (receipt/segment) directory; a database
        // referenced from anywhere else is not session evidence.
        let sessionPath = finalizedSession.standardizedFileURL.path
        let dbPath = sourceDatabase.standardizedFileURL.path
        guard dbPath.hasPrefix(sessionPath + "/") else {
            throw SessionError.sessionMissing
        }

        // 1. Eligibility on the STABLE source metadata (§8.1).
        let metadataURL = finalizedSession.appendingPathComponent("metadata.json")
        guard fileManager.fileExists(atPath: metadataURL.path) else {
            throw SessionError.sessionMissing
        }
        let metadataSnapshot = try readMetadata(metadataURL)
        let metadata = metadataSnapshot.value
        try checkEligibility(metadata, eligibility: eligibility)
        let liveCheckpoint = finalizedSession.appendingPathComponent(
            "live_checkpoint.json")
        guard !fileManager.fileExists(atPath: liveCheckpoint.path) else {
            throw SessionError.notEligible("live_checkpoint.json present")
        }
        try validateWALJournalState(
            sessionDirectory: finalizedSession,
            databaseName: sourceDatabase.lastPathComponent,
            phase: "pre-inventory")
        let sourceInventoryBefore = try sourceInventory(
            of: finalizedSession)
        try faultInjector?(.afterSourceInventory)

        // 2. Build the file set: required + metadata-DECLARED + present
        //    optional/watermark. Declarations drive requiredness instead
        //    of directory presence (B-08).
        var filesToCopy: [(name: String, source: URL, required: Bool)] = []
        for name in requiredFileNames {
            let source = finalizedSession.appendingPathComponent(name)
            guard fileManager.fileExists(atPath: source.path) else {
                throw SessionError.missingRequired(name)
            }
            filesToCopy.append((name, source, true))
        }
        // V1R5 §9.4: the SQLite contract is single-file finalized. A
        // non-empty WAL/journal beside the main DB is a blocker — the
        // writer never checkpointed, so a main-DB-only copy would be
        // silently incomplete.
        let databaseName = sourceDatabase.lastPathComponent
        // Sidecars the metadata explicitly declares by file name: when
        // declared they are REQUIRED — losing them is evidence tampering.
        for (key, name) in Self.declaredSidecarPairs {
            let declared = metadata[key] as? String ?? ""
            guard declared.isEmpty || declared == name else {
                throw SessionError.notEligible(
                    "metadata declares unexpected \(key): \(declared)")
            }
            if !declared.isEmpty {
                let source = finalizedSession.appendingPathComponent(name)
                guard fileManager.fileExists(atPath: source.path) else {
                    throw SessionError.missingRequired(name)
                }
                // A formally required base file (currently metadata and
                // localization trace) may also be named by its metadata
                // declaration. Keep one destination entry: a duplicate
                // would make the second O_EXCL copy fail after the first
                // valid copy had already been created.
                if !filesToCopy.contains(where: { $0.name == name }) {
                    filesToCopy.append((name, source, true))
                }
            }
        }
        // Watermark sidecars: required when the metadata watermark says
        // the scan recorded them; their absence is evidence tampering.
        for name in watermarkFileNames {
            let source = finalizedSession.appendingPathComponent(name)
            let exists = fileManager.fileExists(atPath: source.path)
            if !exists {
                throw SessionError.missingRequired(name)
            }
            filesToCopy.append((name, source, true))
        }
        for name in optionalFileNames {
            // B-08: never duplicate an artifact already covered by a
            // metadata declaration.
            if filesToCopy.contains(where: { $0.name == name }) { continue }
            let source = finalizedSession.appendingPathComponent(name)
            if fileManager.fileExists(atPath: source.path) {
                filesToCopy.append((name, source, false))
            }
        }
        guard fileManager.fileExists(atPath: sourceDatabase.path) else {
            throw SessionError.sessionMissing
        }
        // The DB is copied under its own name so downstream readers can
        // address it by the source file name.
        filesToCopy.append((sourceDatabase.lastPathComponent, sourceDatabase, true))

        // 3. Dynamic disk budget (§8.6): source bytes + reserve must fit.
        var totalSourceBytes: Int64 = 0
        for entry in filesToCopy {
            let attributes = try fileManager.attributesOfItem(atPath: entry.source.path)
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? -1
            guard size >= 0, totalSourceBytes <= Int64.max - size else {
                throw SessionError.insufficientDisk(
                    "source byte count overflow")
            }
            totalSourceBytes += size
        }
        try checkDiskBudget(neededBytes: totalSourceBytes, at: taskRoot)

        // 4. Streaming stable copies into staging (§8.3/§8.7).
        let snapshotDirectory = taskRoot.appendingPathComponent("input_snapshot")
        let stagingDirectory = taskRoot.appendingPathComponent("input_snapshot.staging")
        let backupDirectory = taskRoot
            .appendingPathComponent("input_snapshot.backup")
        try recoverInterruptedCommitIfNeeded(
            taskRoot: taskRoot,
            snapshotDirectory: snapshotDirectory,
            backupDirectory: backupDirectory,
            stagingDirectory: stagingDirectory)
        // Idempotence: after durable transaction recovery, rebuild any
        // remaining uncommitted staging tree from the source. The committed
        // snapshot is never deleted here.
        if fileManager.fileExists(atPath: stagingDirectory.path) {
            try removeImmutableTree(stagingDirectory)
        }
        try fileManager.createDirectory(
            at: stagingDirectory, withIntermediateDirectories: true)

        var artifacts: [[String: Any]] = []
        do {
            for entry in filesToCopy {
                let destination = stagingDirectory.appendingPathComponent(entry.name)
                let isDatabase = entry.source.standardizedFileURL.path ==
                    sourceDatabase.standardizedFileURL.path
                if isDatabase {
                    try validateWALJournalState(
                        sessionDirectory: finalizedSession,
                        databaseName: databaseName,
                        phase: "before database copy")
                }
                let sha = try stableStreamingCopy(
                    source: entry.source,
                    destination: destination,
                    duringCopy: isDatabase ? {
                        try validateWALJournalState(
                            sessionDirectory: finalizedSession,
                            databaseName: databaseName,
                            phase: "during database copy")
                    } : nil)
                if isDatabase {
                    try validateWALJournalState(
                        sessionDirectory: finalizedSession,
                        databaseName: databaseName,
                        phase: "after database copy")
                }
                let attributes = try fileManager.attributesOfItem(atPath: destination.path)
                artifacts.append([
                    "file": entry.name,
                    "bytes": (attributes[.size] as? NSNumber)?.int64Value ?? 0,
                    "sha256": sha,
                    "required": entry.required,
                ])
            }
        } catch {
            if fileManager.fileExists(atPath: stagingDirectory.path) {
                try? removeImmutableTree(stagingDirectory)
            }
            throw error
        }
        guard !artifacts.isEmpty else {
            if fileManager.fileExists(atPath: stagingDirectory.path) {
                try? removeImmutableTree(stagingDirectory)
            }
            throw SessionError.emptyInput
        }

        // Steps 5-7 run in a cleanup scope: any failure removes the
        // staging tree; the previously committed snapshot (if any) is
        // only replaced AFTER the new one is complete and verified
        // (B-08 retry safety).
        do {
            // 5. DB validation on the stable copy (§8.5).
            try validateSnapshotDatabase(
                stagingDirectory.appendingPathComponent(sourceDatabase.lastPathComponent))

            // 6. B-08: re-validate the COPIED metadata. Eligibility must
            //    hold on the exact bytes the snapshot contains, and the
            //    copy must be byte-identical to the source metadata that
            //    was checked in step 1 (TOCTOU detection — the source
            //    cannot swap between eligibility and copy).
            let stagedMetadataURL = stagingDirectory.appendingPathComponent("metadata.json")
            let stagedMetadataSnapshot = try readMetadata(stagedMetadataURL)
            let stagedMetadata = stagedMetadataSnapshot.value
            try checkEligibility(stagedMetadata, eligibility: eligibility)
            guard metadataSnapshot.sha256 == stagedMetadataSnapshot.sha256 else {
                throw SessionError.copyFailed(
                    "metadata changed during snapshot (TOCTOU)")
            }
            // Watermark re-check on the copied metadata: counts the
            // snapshot actually carries must be backed by the copied
            // artifacts.
            let stagedClock = stagedMetadata.clockCorrelationCount
            let stagedBurst = stagedMetadata.tagObservationBurstCount
            if stagedClock > 0 && !fileManager.fileExists(
                atPath: stagingDirectory.appendingPathComponent("clock_correlations.jsonl").path) {
                throw SessionError.missingRequired("clock_correlations.jsonl")
            }
            if stagedBurst > 0 && !fileManager.fileExists(
                atPath: stagingDirectory.appendingPathComponent("tag_observation_bursts.jsonl").path) {
                throw SessionError.missingRequired("tag_observation_bursts.jsonl")
            }
            for (_, name) in Self.declaredSidecarPairs {
                let declared = stagedMetadata[Self.nameKey(for: name)] as? String ?? ""
                if !declared.isEmpty && !fileManager.fileExists(
                    atPath: stagingDirectory.appendingPathComponent(name).path) {
                    throw SessionError.missingRequired(name)
                }
            }

            // RC-B08/B09: the entire top-level source inventory must be
            // exactly stable across the generation, not only each selected
            // file. This catches additions/removals and metadata/mode/link
            // changes that happen between eligibility and commit.
            try validateWALJournalState(
                sessionDirectory: finalizedSession,
                databaseName: databaseName,
                phase: "post-copy")
            let sourceInventoryAfter = try sourceInventory(
                of: finalizedSession)
            guard sourceInventoryAfter == sourceInventoryBefore else {
                throw SessionError.copyFailed(
                    "source directory inventory changed during snapshot")
            }

            // 7. Input manifest + atomic commit (§8.7).
            let bundleSHA = MobilePackageManifestBuilder.packageDigest(artifacts)
            let generation = UUID().uuidString.lowercased()
            let manifest: [String: Any] = [
                "format": "MarketScannerSessionInputManifest",
                "version": 3,
                "generation": generation,
                "task_id": taskID,
                "snapshot_directory": "input_snapshot",
                "bundle_sha256": bundleSHA,
                "artifact_count": artifacts.count,
                "artifacts": artifacts,
                "source_inventory": sourceInventoryBefore.map {
                    sourceInventoryManifestRecord($0)
                },
            ]
            let manifestData = try CanonicalJSONEncoder.encode(manifest)
            let manifestSHA = sha256(manifestData)
            try faultInjector?(.beforeManifestWrite)
            let stagingManifest = stagingDirectory.appendingPathComponent("input_manifest.json")
            try manifestData.write(to: stagingManifest, options: [.atomic])
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: committedFileMode)],
                ofItemAtPath: stagingManifest.path)
            try fsyncURL(stagingManifest)
            let commitMarker: [String: Any] = [
                "format": "MarketScannerSessionSnapshotCommit",
                "version": 1,
                "generation": generation,
                "task_id": taskID,
                "manifest_sha256": manifestSHA,
                "bundle_sha256": bundleSHA,
            ]
            let commitMarkerData = try CanonicalJSONEncoder.encode(commitMarker)
            let stagingCommitMarker = stagingDirectory.appendingPathComponent(
                "snapshot_commit.json")
            try commitMarkerData.write(
                to: stagingCommitMarker, options: [.atomic])
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: committedFileMode)],
                ofItemAtPath: stagingCommitMarker.path)
            try fsyncURL(stagingCommitMarker)
            try fsyncDirectory(stagingDirectory)
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: preparedDirectoryMode)],
                ofItemAtPath: stagingDirectory.path)
            try fsyncDirectory(stagingDirectory)
            _ = try validateSnapshotGeneration(
                stagingDirectory,
                allowedDirectoryModes: [preparedDirectoryMode])

            // RC-B09: one generation includes the immutable directory,
            // its manifest, its commit marker and the durable task-root
            // reference (the task-root input_manifest.json). The previous
            // generation remains in backup until every new marker/reference
            // is durable and has passed resume validation.
            let taskManifestURL = taskRoot.appendingPathComponent(
                "input_manifest.json")
            let priorTaskManifest = try readStableCommittedFileIfPresent(
                taskManifestURL,
                maximumBytes: maximumTaskManifestBytes)?.data
            let stagingIdentity = try ImmutableDirectoryPublication.identity(
                of: stagingDirectory,
                allowedModes: [preparedDirectoryMode])
            var priorIdentity: ImmutableDirectoryPublication.Identity?
            var priorManifestSHA256: String?
            if fileManager.fileExists(atPath: snapshotDirectory.path) {
                try revalidateSnapshot(snapshotDirectory)
                let priorGeneration = try validateSnapshotGeneration(
                    snapshotDirectory,
                    allowedDirectoryModes: [committedDirectoryMode])
                priorIdentity = try ImmutableDirectoryPublication.identity(
                    of: snapshotDirectory,
                    allowedModes: [committedDirectoryMode])
                priorManifestSHA256 = priorGeneration.manifestSHA256
                guard priorTaskManifest == priorGeneration.manifestData else {
                    throw SessionError.copyFailed(
                        "prior snapshot/task reference mismatch before commit")
                }
            } else if priorTaskManifest != nil {
                throw SessionError.copyFailed(
                    "task reference exists without a prior snapshot")
            }
            let commitIntent = SnapshotCommitIntent(
                taskID: taskID,
                newManifestSHA256: manifestSHA,
                newIdentity: stagingIdentity,
                priorManifestSHA256: priorManifestSHA256,
                priorIdentity: priorIdentity)
            let transactionIntentURL = taskRoot.appendingPathComponent(
                transactionIntentFileName)
            let transactionIntentIdentity = try writeSnapshotCommitIntent(
                commitIntent, to: transactionIntentURL)
            do {
                if fileManager.fileExists(atPath: snapshotDirectory.path) {
                    try ImmutableDirectoryPublication.publish(
                        source: snapshotDirectory,
                        destination: backupDirectory,
                        expectedIdentity: priorIdentity,
                        afterRootThawBeforeRename: {
                            try faultInjector?(
                                .afterPreviousSnapshotThawBeforeBackupRename)
                        },
                        afterRenameBeforeFreeze: {
                            try faultInjector?(
                                .afterPreviousSnapshotRenameBeforeFreeze)
                        },
                        afterFreezeBeforeParentSync: {
                            try faultInjector?(
                                .afterPreviousSnapshotFreezeBeforeParentFsync)
                        })
                }
                try ImmutableDirectoryPublication.publish(
                    source: stagingDirectory,
                    destination: snapshotDirectory,
                    expectedIdentity: stagingIdentity,
                    afterRenameBeforeFreeze: {
                        try faultInjector?(.afterSnapshotRenameBeforeFreeze)
                    },
                    afterFreezeBeforeParentSync: {
                        try faultInjector?(
                            .afterSnapshotFreezeBeforeParentFsync)
                    })
                try ImmutableDirectoryPublication.freezeInterruptedDestination(
                    snapshotDirectory, expectedIdentity: stagingIdentity)
                _ = try validateIntentBoundGeneration(
                    snapshotDirectory,
                    expectedManifestSHA256: manifestSHA,
                    expectedIdentity: stagingIdentity)
                try faultInjector?(.afterSnapshotInstall)
                try writeTaskManifest(
                    manifestData,
                    to: taskManifestURL,
                    taskRoot: taskRoot,
                    afterRenameBeforeParentSync: {
                        try faultInjector?(.beforeTaskReferenceFsync)
                    })
                try revalidateSnapshot(
                    snapshotDirectory,
                    expectedDirectoryIdentity: stagingIdentity,
                    expectedManifestSHA256: manifestSHA)
                try faultInjector?(.afterTaskReferenceDurableBeforeCleanup)
            } catch let conflict as SnapshotTransactionConflict {
                throw SessionError.copyFailed(
                    "snapshot commit found an unrecoverable authority conflict; "
                    + "transaction intent and generations were preserved: "
                    + String(describing: conflict))
            } catch {
                let commitError = error
                do {
                    try faultInjector?(.beforeBackupRestore)
                    try rollbackSnapshotCommit(
                        intent: commitIntent,
                        priorTaskManifest: priorTaskManifest,
                        taskRoot: taskRoot,
                        snapshotDirectory: snapshotDirectory,
                        backupDirectory: backupDirectory,
                        stagingDirectory: stagingDirectory,
                        transactionIntentURL: transactionIntentURL,
                        transactionIntentIdentity: transactionIntentIdentity)
                } catch {
                    throw SessionError.copyFailed(
                        "snapshot commit rollback failed after "
                        + "\(commitError.localizedDescription): "
                        + error.localizedDescription)
                }
                throw commitError
            }

            // Backup deletion is cleanup after the commit point. A failed
            // cleanup leaves a recoverable backup for the next invocation;
            // it never rolls back or obscures the already durable generation.
            if fileManager.fileExists(atPath: backupDirectory.path) {
                do {
                    guard let priorIdentity else {
                        throw SessionError.copyFailed(
                            "snapshot backup exists without prior identity")
                    }
                    try removeImmutableTree(
                        backupDirectory, expectedIdentity: priorIdentity)
                    try fsyncDirectory(taskRoot)
                } catch { /* durable commit remains authoritative */ }
            }
            try revalidateSnapshot(
                snapshotDirectory,
                expectedDirectoryIdentity: stagingIdentity,
                expectedManifestSHA256: manifestSHA)
            do {
                try removeSnapshotCommitIntent(
                    transactionIntentURL,
                    expectedIntent: commitIntent,
                    expectedIdentity: transactionIntentIdentity)
            } catch { /* durable committed generation remains authoritative */ }

            return SessionSnapshot(
                taskID: taskID,
                snapshotDirectory: snapshotDirectory,
                inputManifest: manifest,
                bundleSHA256: bundleSHA)
        } catch {
            let transactionIntentURL = taskRoot.appendingPathComponent(
                transactionIntentFileName)
            if !fileManager.fileExists(atPath: transactionIntentURL.path),
               fileManager.fileExists(atPath: stagingDirectory.path) {
                try? removeImmutableTree(stagingDirectory)
            }
            throw error
        }
    }

    /// Maps a metadata sidecar-declaration key back to its artifact
    /// file name (used for the post-copy watermark re-check).
    private static func nameKey(for fileName: String) -> String {
        return Self.declaredSidecarPairs
            .first(where: { $0.name == fileName })?.key ?? ""
    }

    /// V1R5 §13.6 (review H-14): full re-validation of a committed
    /// snapshot before a task resume — the manifest, every artifact's
    /// exact bytes + SHA-256, the DB quick-check and the WAL/journal
    /// contract are re-verified. Resume never trusts "the file exists".
    static func revalidateSnapshot(
        _ directory: URL,
        expectedDirectoryIdentity: ImmutableDirectoryPublication.Identity? = nil,
        expectedManifestSHA256: String? = nil
    ) throws {
        let validated = try validateSnapshotGeneration(
            directory,
            allowedDirectoryModes: [committedDirectoryMode],
            expectedDirectoryIdentity: expectedDirectoryIdentity)
        if let expectedManifestSHA256,
           validated.manifestSHA256 != expectedManifestSHA256 {
            throw SessionError.notEligible(
                "snapshot manifest differs from expected transaction generation")
        }

        // The task-root copy is the durable reference to this exact
        // generation. A snapshot directory without the matching reference
        // is an interrupted commit and cannot be resumed.
        let taskRoot = directory.deletingLastPathComponent()
        guard taskRoot.lastPathComponent == validated.taskID else {
            throw SessionError.notEligible(
                "snapshot task identity mismatch")
        }
        let taskManifestURL = taskRoot.appendingPathComponent(
            "input_manifest.json")
        guard let taskManifestData = try readStableCommittedFileIfPresent(
                taskManifestURL,
                maximumBytes: maximumTaskManifestBytes)?.data else {
            throw SessionError.notEligible(
                "snapshot task reference is missing")
        }
        guard taskManifestData == validated.manifestData else {
            throw SessionError.notEligible(
                "task reference generation does not match snapshot manifest")
        }
        let finalIdentity = try ImmutableDirectoryPublication.identity(
            of: directory, allowedModes: [validated.directoryMode])
        guard finalIdentity == validated.directoryIdentity else {
            throw SessionError.notEligible(
                "snapshot generation changed while validating task authority")
        }
    }

    private static func validateSnapshotGeneration(
        _ directory: URL,
        allowedDirectoryModes: Set<mode_t>,
        expectedDirectoryIdentity: ImmutableDirectoryPublication.Identity? = nil
    ) throws -> ValidatedSnapshotGeneration {
        let parent = directory.deletingLastPathComponent()
        let openedParent = try openStableDirectoryNoFollow(
            parent, context: "snapshot generation parent")
        defer { _ = close(openedParent.descriptor) }
        let directoryDescriptor = openat(
            openedParent.descriptor,
            directory.lastPathComponent,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard directoryDescriptor >= 0 else {
            throw SessionError.notEligible(
                "cannot open snapshot generation without following links")
        }
        defer { _ = close(directoryDescriptor) }
        var openedDirectory = stat()
        var pathDirectory = stat()
        guard fstat(directoryDescriptor, &openedDirectory) == 0,
              fstatat(
                openedParent.descriptor,
                directory.lastPathComponent,
                &pathDirectory,
                AT_SYMLINK_NOFOLLOW) == 0,
              sameDirectoryIdentity(openedDirectory, pathDirectory) else {
            throw SessionError.notEligible(
                "snapshot generation changed while opening")
        }
        let directoryMode = openedDirectory.st_mode & mode_t(0o777)
        guard allowedDirectoryModes.contains(directoryMode),
              pathDirectory.st_mode & mode_t(0o777) == directoryMode else {
            throw SessionError.notEligible(
                "snapshot directory mode is not allowed: "
                    + String(directoryMode, radix: 8))
        }
        let openedIdentity = ImmutableDirectoryPublication.Identity(
            device: UInt64(openedDirectory.st_dev),
            inode: UInt64(openedDirectory.st_ino))
        if let expectedDirectoryIdentity,
           openedIdentity != expectedDirectoryIdentity {
            throw SessionError.copyFailed(
                "snapshot generation dev/inode differs from transaction intent")
        }
        try faultInjector?(.afterGenerationRootOpenBeforeValidation)
        try requireBoundDirectoryPath(
            descriptor: directoryDescriptor,
            expectedIdentity: expectedDirectoryIdentity,
            expectedMode: directoryMode,
            parentDescriptor: openedParent.descriptor,
            parentURL: parent,
            parentMetadata: openedParent.metadata,
            basename: directory.lastPathComponent,
            context: "snapshot generation before validation")

        guard let stableManifest = try readStableCommittedFileIfPresent(
                parentDescriptor: directoryDescriptor,
                basename: "input_manifest.json",
                maximumBytes: maximumTaskManifestBytes) else {
            throw SessionError.notEligible(
                "input_manifest.json is missing for resume")
        }
        let manifestData = stableManifest.data
        guard let manifest = try? StrictJSONDocumentParser.object(
            from: manifestData,
            limits: StrictJSONDocumentLimits(maximumBytes: manifestData.count + 1))
                as? [String: Any],
              manifest["format"] as? String ==
                "MarketScannerSessionInputManifest",
              strictInteger(manifest["version"]) == 3,
              let generation = nonEmptyString(manifest["generation"]),
              let taskID = nonEmptyString(manifest["task_id"]),
              manifest["snapshot_directory"] as? String == "input_snapshot",
              let bundleSHA = nonEmptyString(manifest["bundle_sha256"]),
              let artifacts = manifest["artifacts"] as? [[String: Any]],
              !artifacts.isEmpty,
              let sourceInventoryRecords = manifest["source_inventory"]
                as? [[String: Any]],
              !sourceInventoryRecords.isEmpty,
              strictInteger(manifest["artifact_count"]) ==
                Int64(artifacts.count) else {
            throw SessionError.notEligible(
                "input_manifest.json invalid for resume")
        }
        var recordedSourceNames = Set<String>()
        for record in sourceInventoryRecords {
            guard let name = nonEmptyString(record["relative_name"]),
                  isSafeTopLevelName(name),
                  record["type"] as? String == "regular",
                  nonEmptyString(record["dev"]) != nil,
                  nonEmptyString(record["ino"]) != nil,
                  strictInteger(record["size"]) != nil,
                  nonEmptyString(record["nlink"]) != nil,
                  strictInteger(record["mtime_sec"]) != nil,
                  strictInteger(record["mtime_nsec"]) != nil,
                  strictInteger(record["ctime_sec"]) != nil,
                  strictInteger(record["ctime_nsec"]) != nil,
                  nonEmptyString(record["mode_octal"]) != nil,
                  recordedSourceNames.insert(name).inserted else {
                throw SessionError.notEligible(
                    "source inventory record invalid for resume")
            }
        }

        var expectedNames = Set(["input_manifest.json", "snapshot_commit.json"])
        var artifactNames = Set<String>()
        var artifactMetadata: [String: stat] = [:]
        for artifact in artifacts {
            guard let name = artifact["file"] as? String,
                  isSafeTopLevelName(name),
                  let expectedSHA = artifact["sha256"] as? String,
                  let expectedBytes = strictInteger(artifact["bytes"]),
                  StrictJSONScalar.boolean(artifact["required"]) != nil
            else {
                throw SessionError.notEligible(
                    "input_manifest.json artifact record invalid")
            }
            guard expectedBytes >= 0,
                  isSHA256(expectedSHA),
                  artifactNames.insert(name).inserted,
                  expectedNames.insert(name).inserted else {
                throw SessionError.notEligible(
                    "input_manifest.json artifact name/count invalid")
            }
            let stableArtifact = try sha256StableCommittedFile(
                parentDescriptor: directoryDescriptor,
                basename: name,
                expectedBytes: expectedBytes)
            guard stableArtifact.sha256 == expectedSHA else {
                throw SessionError.copyFailed(
                    "resume sha mismatch: \(name)")
            }
            artifactMetadata[name] = stableArtifact.metadata
            try faultInjector?(.afterArtifactHashBeforeGenerationEnd(name))
        }

        // Explicit WAL/journal gate runs before the exact directory-name
        // comparison so resume records the database-generation violation,
        // rather than only reporting a generic unexpected-file mismatch.
        let databaseNames = artifacts.compactMap {
            ($0["file"] as? String)?.hasSuffix(".db") == true
                ? $0["file"] as? String : nil
        }
        guard databaseNames.count == 1,
              let databaseName = databaseNames.first else {
            throw SessionError.emptyInput
        }
        try validateWALJournalState(
            parentDescriptor: directoryDescriptor,
            databaseName: databaseName,
            phase: "resume")

        let actualNames = Set(try directoryEntryNames(
            atBoundDirectoryDescriptor: directoryDescriptor,
            context: "snapshot generation",
            maximumEntries: maximumSnapshotDirectoryEntries))
        guard actualNames == expectedNames else {
            throw SessionError.notEligible(
                "snapshot file inventory differs from committed manifest")
        }
        guard MobilePackageManifestBuilder.packageDigest(artifacts) == bundleSHA else {
            throw SessionError.notEligible(
                "snapshot bundle digest does not match artifacts")
        }

        guard let stableCommit = try readStableCommittedFileIfPresent(
                parentDescriptor: directoryDescriptor,
                basename: "snapshot_commit.json",
                maximumBytes: maximumSnapshotCommitMarkerBytes) else {
            throw SessionError.notEligible(
                "snapshot commit marker is missing")
        }
        let commitData = stableCommit.data
        guard let commit = try? StrictJSONDocumentParser.object(
            from: commitData,
            limits: StrictJSONDocumentLimits(maximumBytes: commitData.count + 1))
                as? [String: Any],
              commit["format"] as? String ==
                "MarketScannerSessionSnapshotCommit",
              strictInteger(commit["version"]) == 1,
              commit["generation"] as? String == generation,
              commit["task_id"] as? String == taskID,
              commit["manifest_sha256"] as? String == sha256(manifestData),
              commit["bundle_sha256"] as? String == bundleSHA else {
            throw SessionError.notEligible(
                "snapshot commit marker is missing or inconsistent")
        }

        // Formal metadata is re-parsed on every resume. Legacy metadata,
        // incomplete evidence and a changed eligibility status remain
        // diagnostic-only even if artifact hashes happen to match.
        guard let metadataBefore = artifactMetadata["metadata.json"] else {
            throw SessionError.notEligible(
                "metadata.json is missing from the committed artifact set")
        }
        try requireBoundDirectoryPath(
            descriptor: directoryDescriptor,
            expectedIdentity: expectedDirectoryIdentity,
            expectedMode: directoryMode,
            parentDescriptor: openedParent.descriptor,
            parentURL: parent,
            parentMetadata: openedParent.metadata,
            basename: directory.lastPathComponent,
            context: "snapshot generation before metadata validation")
        guard let committedMetadata = try readStableCommittedFileIfPresent(
            parentDescriptor: directoryDescriptor,
            basename: "metadata.json",
            maximumBytes: Int(maximumMetadataBytes)),
              sameFileIdentity(
                metadataBefore, committedMetadata.metadata) else {
            throw SessionError.copyFailed(
                "metadata.json changed during snapshot eligibility validation")
        }
        let metadata = try parseMetadataData(committedMetadata.data)
        try checkEligibility(metadata.value, eligibility: nil)

        // DB quick-check + WAL contract on the snapshot copy.
        guard let databaseBefore = artifactMetadata[databaseName] else {
            throw SessionError.emptyInput
        }
        try requireBoundDirectoryPath(
            descriptor: directoryDescriptor,
            expectedIdentity: expectedDirectoryIdentity,
            expectedMode: directoryMode,
            parentDescriptor: openedParent.descriptor,
            parentURL: parent,
            parentMetadata: openedParent.metadata,
            basename: directory.lastPathComponent,
            context: "snapshot generation before database validation")
        try validateSnapshotDatabase(
            parentDescriptor: directoryDescriptor,
            databaseName: databaseName,
            expectedMetadata: databaseBefore)
        var databaseAfter = stat()
        guard fstatat(
            directoryDescriptor,
            databaseName,
            &databaseAfter,
            AT_SYMLINK_NOFOLLOW) == 0,
              sameFileIdentity(databaseBefore, databaseAfter) else {
            throw SessionError.dbIntegrity(
                "snapshot database changed during read-only validation")
        }

        // Extend every per-file stable-read/hash guarantee through the end
        // of the complete generation validation. Without this final sweep,
        // an early sidecar could be modified in place after its hash window
        // and restored to 0444 before the later metadata/SQLite checks end.
        var finalExpectedMetadata = artifactMetadata
        finalExpectedMetadata["input_manifest.json"] = stableManifest.metadata
        finalExpectedMetadata["snapshot_commit.json"] = stableCommit.metadata
        for name in finalExpectedMetadata.keys.sorted() {
            guard let expected = finalExpectedMetadata[name] else { continue }
            var current = stat()
            guard fstatat(
                directoryDescriptor,
                name,
                &current,
                AT_SYMLINK_NOFOLLOW) == 0,
                  sameFileIdentity(expected, current) else {
                throw SessionError.copyFailed(
                    "snapshot generation file changed during validation: \(name)")
            }
        }
        try requireBoundDirectoryPath(
            descriptor: directoryDescriptor,
            expectedIdentity: expectedDirectoryIdentity,
            expectedMode: directoryMode,
            parentDescriptor: openedParent.descriptor,
            parentURL: parent,
            parentMetadata: openedParent.metadata,
            basename: directory.lastPathComponent,
            context: "snapshot generation after validation")
        return ValidatedSnapshotGeneration(
            manifestData: manifestData,
            manifestSHA256: sha256(manifestData),
            taskID: taskID,
            generation: generation,
            bundleSHA256: bundleSHA,
            directoryIdentity: openedIdentity,
            directoryMode: directoryMode)
    }

    // MARK: - Eligibility (§8.1)

    private static func readMetadata(
        _ url: URL
    ) throws -> (value: StrictFinalizedSessionMetadata, sha256: String) {
        let fileDescriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fileDescriptor >= 0 else {
            throw SessionError.notEligible(
                "metadata.json must be one non-hardlinked regular file")
        }
        defer { close(fileDescriptor) }
        var before = stat()
        guard fstat(fileDescriptor, &before) == 0,
              (before.st_mode & S_IFMT) == S_IFREG,
              before.st_nlink == 1 else {
            throw SessionError.notEligible(
                "metadata.json must be one non-hardlinked regular file")
        }
        guard before.st_size > 0,
              Int64(before.st_size) <= maximumMetadataBytes else {
            throw SessionError.notEligible(
                "metadata.json size exceeds the formal input limit")
        }
        var data = Data()
        data.reserveCapacity(Int(before.st_size))
        var buffer = [UInt8](repeating: 0, count: min(copyChunkBytes, 64 * 1024))
        while true {
            let count = buffer.withUnsafeMutableBytes { rawBuffer -> Int in
                guard let address = rawBuffer.baseAddress else { return -1 }
                return read(fileDescriptor, address, rawBuffer.count)
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw SessionError.notEligible("metadata.json stable read failed")
            }
            if count == 0 { break }
            guard data.count <= Int(maximumMetadataBytes) - count else {
                throw SessionError.notEligible(
                    "metadata.json size exceeds the formal input limit")
            }
            data.append(contentsOf: buffer.prefix(count))
        }
        var after = stat()
        var pathAfter = stat()
        guard fstat(fileDescriptor, &after) == 0,
              lstat(url.path, &pathAfter) == 0,
              sameFileIdentity(before, after),
              sameFileIdentity(before, pathAfter),
              data.count == Int(before.st_size) else {
            throw SessionError.notEligible(
                "metadata.json changed during stable read")
        }
        return try parseMetadataData(data)
    }

    private static func parseMetadataData(
        _ data: Data
    ) throws -> (value: StrictFinalizedSessionMetadata, sha256: String) {
        guard let object = try? StrictJSONDocumentParser.object(
            from: data,
            limits: StrictJSONDocumentLimits(
                maximumBytes: Int(maximumMetadataBytes))) as? [String: Any]
        else {
            throw SessionError.sessionMissing
        }

        guard object["format"] as? String ==
                "MarketScannerFinalizedSessionMetadata",
              let version = strictInteger(object["version"]),
              version == 1,
              let formatVersion = strictInteger(object["formatVersion"]),
              formatVersion == 2 else {
            throw SessionError.notEligible(
                "formal metadata format/version is missing or unsupported")
        }
        guard StrictJSONScalar.boolean(object["finalized"]) == true else {
            throw SessionError.notFinalized
        }
        guard let finalizedAtUnix = StrictJSONScalar.number(
                object["finalizedAtUnix"]),
              finalizedAtUnix > 0 else {
            throw SessionError.notEligible(
                "formal finalizedAtUnix is missing or invalid")
        }
        guard let scanMode = nonEmptyString(object["scanMode"]),
              scanMode == "continuous_streaming" else {
            throw SessionError.notEligible(
                "scanMode != continuous_streaming")
        }
        guard let workflowMode = nonEmptyString(object["workflowMode"]),
              workflowMode == "prior_map_localized" else {
            throw SessionError.notEligible(
                "workflowMode != prior_map_localized")
        }
        guard let trackingSessionID = nonEmptyString(
                object["trackingSessionId"]),
              let storeID = nonEmptyString(object["storeId"]),
              let floorID = nonEmptyString(object["floorId"]),
              let priorMapID = nonEmptyString(object["priorMapId"]),
              let priorMapSHA = nonEmptyString(object["priorMapSha256"]),
              isSHA256(priorMapSHA) else {
            throw SessionError.notEligible(
                "formal tracking/store/floor/prior-map identity missing")
        }
        guard let processing = object["processingEligibility"]
                as? [String: Any],
              let processingStatus = nonEmptyString(processing["status"]),
              let processingBlockers = processing["blockers"] as? [String]
        else {
            throw SessionError.notEligible(
                "processingEligibility formal fields missing")
        }
        guard let capture = object["captureHealth"] as? [String: Any],
              let writeFailures = strictInteger(
                capture["localizationRequiredWriteFailureCount"]),
              writeFailures >= 0,
              let traceCount = strictInteger(
                capture["localizationTraceRecordCount"]),
              traceCount >= 0,
              let constraintCount = strictInteger(
                capture["localizationConstraintRecordCount"]),
              constraintCount >= 0,
              let manualEventCount = strictInteger(
                capture["manualLocalizationEventCount"]),
              manualEventCount >= 0,
              let stateEventCount = strictInteger(
                capture["localizationStateEventCount"]),
              stateEventCount >= 0,
              let localizationComplete = StrictJSONScalar.boolean(
                capture["localizationEvidenceComplete"]),
              let recoveryCount = strictInteger(
                capture["localizationRecoveryEventCount"]),
              recoveryCount >= 0,
              let recoveryComplete = StrictJSONScalar.boolean(
                capture["localizationRecoveryEvidenceComplete"])
        else {
            throw SessionError.notEligible(
                "captureHealth formal evidence fields missing")
        }
        let rawLastRecoveryID = capture[
            "localizationLastRecoveryEpisodeId"]
        let rawLastRecoveryUptime = capture[
            "localizationLastRecoveryFinishedAtUptime"]
        guard rawLastRecoveryID == nil || rawLastRecoveryID is NSNull ||
                strictInteger(rawLastRecoveryID) != nil,
              rawLastRecoveryUptime == nil || rawLastRecoveryUptime is NSNull ||
                StrictJSONScalar.number(rawLastRecoveryUptime) != nil else {
            throw SessionError.notEligible(
                "recovery watermark has an invalid scalar type")
        }
        let lastRecoveryID = optionalStrictInteger(rawLastRecoveryID)
        let lastRecoveryUptime = optionalStrictNumber(rawLastRecoveryUptime)
        if recoveryCount == 0 {
            guard lastRecoveryID == nil, lastRecoveryUptime == nil else {
                throw SessionError.notEligible(
                    "zero recovery count has non-empty recovery watermark")
            }
        } else {
            guard let lastRecoveryID, lastRecoveryID > 0,
                  let lastRecoveryUptime, lastRecoveryUptime >= 0 else {
                throw SessionError.notEligible(
                    "recovery count lacks exact last-ID/time watermark")
            }
        }
        guard let clockCorrelationCount = strictInteger(
                object["clockCorrelationCount"]),
              clockCorrelationCount >= 0,
              let clockNodeBindingCount = strictInteger(
                object["clockNodeBindingCount"]),
              clockNodeBindingCount >= 0,
              let clockLastMonotonic = StrictJSONScalar.number(
                object["clockLastMonotonic"]),
              let clockLastUTC = StrictJSONScalar.number(
                object["clockLastUTC"]),
              let clockComplete = StrictJSONScalar.boolean(
                object["clockEvidenceComplete"]),
              let burstCount = strictInteger(
                object["tagObservationBurstCount"]),
              burstCount >= 0,
              let burstComplete = StrictJSONScalar.boolean(
                object["tagObservationBurstComplete"])
        else {
            throw SessionError.notEligible(
                "clock/tag formal count and watermark fields missing")
        }
        let rawBurstLastID = object["tagObservationBurstLastID"]
        guard rawBurstLastID == nil || rawBurstLastID is NSNull ||
                nonEmptyString(rawBurstLastID) != nil else {
            throw SessionError.notEligible(
                "tag burst last-ID has an invalid scalar type")
        }
        let burstLastID = optionalNonEmptyString(rawBurstLastID)
        if burstCount == 0 {
            guard burstLastID == nil else {
                throw SessionError.notEligible(
                    "zero tag burst count has a last-ID watermark")
            }
        } else if burstLastID == nil {
            throw SessionError.notEligible(
                "tag burst count lacks an exact last-ID watermark")
        }

        let value = StrictFinalizedSessionMetadata(
            raw: object,
            format: "MarketScannerFinalizedSessionMetadata",
            version: version,
            formatVersion: formatVersion,
            finalized: true,
            finalizedAtUnix: finalizedAtUnix,
            scanMode: scanMode,
            workflowMode: workflowMode,
            trackingSessionID: trackingSessionID,
            storeID: storeID,
            floorID: floorID,
            priorMapID: priorMapID,
            priorMapSHA256: priorMapSHA.lowercased(),
            processingStatus: processingStatus,
            processingBlockers: processingBlockers,
            captureHealth: StrictFinalizedSessionMetadata.CaptureHealth(
                requiredWriteFailureCount: writeFailures,
                localizationTraceRecordCount: traceCount,
                localizationConstraintRecordCount: constraintCount,
                manualLocalizationEventCount: manualEventCount,
                localizationStateEventCount: stateEventCount,
                localizationEvidenceComplete: localizationComplete,
                recoveryEventCount: recoveryCount,
                lastRecoveryEpisodeID: lastRecoveryID,
                lastRecoveryFinishedAtUptime: lastRecoveryUptime,
                recoveryEvidenceComplete: recoveryComplete),
            clockCorrelationCount: clockCorrelationCount,
            clockNodeBindingCount: clockNodeBindingCount,
            clockLastMonotonic: clockLastMonotonic,
            clockLastUTC: clockLastUTC,
            clockEvidenceComplete: clockComplete,
            tagObservationBurstCount: burstCount,
            tagObservationBurstLastID: burstLastID,
            tagObservationBurstComplete: burstComplete)
        return (value, sha256(data))
    }

    private static func sameFileIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
        return lhs.st_dev == rhs.st_dev &&
            lhs.st_ino == rhs.st_ino &&
            lhs.st_mode == rhs.st_mode &&
            lhs.st_nlink == rhs.st_nlink &&
            lhs.st_size == rhs.st_size &&
            lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec &&
            lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec &&
            lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec &&
            lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

    /// APFS may expose a newly renamed immutable file through the directory
    /// entry before the descriptor view has observed the rename's final ctime.
    /// A read-only open can therefore see the same 0444 single-link inode,
    /// size and mtime with a later ctime. This is not a content mutation.
    ///
    /// The exception is deliberately narrower than `sameCommittedFileObject`:
    /// mtime remains exact, while every supported transaction writer publishes
    /// a new inode and never mutates a committed file in place. The caller must
    /// immediately re-stat the pathname and bind it exactly to the opened
    /// descriptor, then retain the full strict checks through EOF.
    private static func sameFileIdentityIgnoringChangeTime(
        _ lhs: stat,
        _ rhs: stat
    ) -> Bool {
        return lhs.st_dev == rhs.st_dev &&
            lhs.st_ino == rhs.st_ino &&
            lhs.st_mode == rhs.st_mode &&
            lhs.st_nlink == rhs.st_nlink &&
            lhs.st_size == rhs.st_size &&
            lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec &&
            lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
    }

    private static func changeTimeDidNotMoveBackward(
        _ before: stat,
        _ after: stat
    ) -> Bool {
        if before.st_ctimespec.tv_sec != after.st_ctimespec.tv_sec {
            return before.st_ctimespec.tv_sec < after.st_ctimespec.tv_sec
        }
        return before.st_ctimespec.tv_nsec <= after.st_ctimespec.tv_nsec
    }

    private static func fileIdentityDifferenceSummary(
        _ lhs: stat,
        _ rhs: stat
    ) -> String {
        var fields: [String] = []
        if lhs.st_dev != rhs.st_dev { fields.append("device") }
        if lhs.st_ino != rhs.st_ino { fields.append("inode") }
        if lhs.st_mode != rhs.st_mode { fields.append("mode") }
        if lhs.st_nlink != rhs.st_nlink { fields.append("link_count") }
        if lhs.st_size != rhs.st_size { fields.append("size") }
        if lhs.st_mtimespec.tv_sec != rhs.st_mtimespec.tv_sec ||
            lhs.st_mtimespec.tv_nsec != rhs.st_mtimespec.tv_nsec {
            fields.append("mtime")
        }
        if lhs.st_ctimespec.tv_sec != rhs.st_ctimespec.tv_sec ||
            lhs.st_ctimespec.tv_nsec != rhs.st_ctimespec.tv_nsec {
            fields.append("ctime")
        }
        return fields.isEmpty ? "none" : fields.joined(separator: ",")
    }

    private static func sameDirectoryIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
        return (lhs.st_mode & S_IFMT) == S_IFDIR
            && (rhs.st_mode & S_IFMT) == S_IFDIR
            && lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
    }

    /// Rename and RENAME_SWAP may legitimately advance ctime on the same
    /// inode. Across an atomic namespace mutation, bind the immutable file by
    /// dev/inode/type/mode/link/size; stable reads still use the stricter
    /// `sameFileIdentity` including mtime/ctime.
    private static func sameCommittedFileObject(_ lhs: stat, _ rhs: stat) -> Bool {
        return lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && (lhs.st_mode & S_IFMT) == S_IFREG
            && (rhs.st_mode & S_IFMT) == S_IFREG
            && (lhs.st_mode & mode_t(0o777)) == committedFileMode
            && (rhs.st_mode & mode_t(0o777)) == committedFileMode
            && lhs.st_nlink == 1
            && rhs.st_nlink == 1
            && lhs.st_size == rhs.st_size
    }

    private static func checkEligibility(
        _ metadata: StrictFinalizedSessionMetadata,
        eligibility: Eligibility?
    ) throws {
        guard metadata.format == "MarketScannerFinalizedSessionMetadata",
              metadata.version == 1,
              metadata.finalized,
              metadata.formatVersion == 2,
              metadata.scanMode == "continuous_streaming",
              metadata.workflowMode == "prior_map_localized" else {
            throw SessionError.notEligible(
                "metadata is not a formal finalized Mobile-Only session")
        }
        guard metadata.processingStatus == "eligible",
              metadata.processingBlockers.isEmpty else {
            throw SessionError.notEligible(
                "processingEligibility is not eligible with zero blockers")
        }
        let capture = metadata.captureHealth
        guard capture.requiredWriteFailureCount == 0 else {
            throw SessionError.notEligible(
                "localization required write failures = "
                + "\(capture.requiredWriteFailureCount)")
        }
        guard capture.localizationEvidenceComplete,
              capture.localizationTraceRecordCount > 0,
              capture.localizationConstraintRecordCount > 0,
              capture.localizationStateEventCount > 0 else {
            throw SessionError.notEligible(
                "localization evidence is incomplete")
        }
        guard capture.recoveryEvidenceComplete else {
            throw SessionError.notEligible(
                "localization recovery evidence is incomplete")
        }
        guard metadata.clockEvidenceComplete,
              metadata.clockCorrelationCount >= 2,
              metadata.clockNodeBindingCount >= 2,
              metadata.clockLastMonotonic >= 0,
              metadata.clockLastUTC > 0 else {
            throw SessionError.notEligible(
                "clock evidence is incomplete")
        }
        guard metadata.tagObservationBurstComplete else {
            throw SessionError.notEligible(
                "tag observation burst evidence is incomplete")
        }
        for (key, name) in declaredSidecarPairs {
            guard metadata[key] as? String == name else {
                throw SessionError.notEligible(
                    "formal metadata must declare \(key)=\(name)")
            }
        }
        guard let eligibility = eligibility else { return }
        guard eligibility.appGitSHA != "unknown", !eligibility.appGitSHA.isEmpty else {
            throw SessionError.notEligible("app build identity unknown")
        }
        if let priorMapID = eligibility.priorMapID {
            let sessionMapID = metadata.priorMapID
            guard sessionMapID == priorMapID else {
                throw SessionError.notEligible(
                    "priorMapId mismatch: \(sessionMapID) != \(priorMapID)")
            }
        }
        if let priorMapSHA = eligibility.priorMapSHA256 {
            let sessionSHA = metadata.priorMapSHA256
            guard sessionSHA == priorMapSHA.lowercased() else {
                throw SessionError.notEligible(
                    "priorMapSha256 mismatch: \(sessionSHA.prefix(12)) != \(priorMapSHA.prefix(12))")
            }
        }
        if let storeID = eligibility.storeID, !storeID.isEmpty {
            let sessionStore = metadata.storeID
            // B-08: an empty session store is fail-closed — the
            // production session MUST record the store it belongs to.
            guard sessionStore == storeID else {
                throw SessionError.notEligible(
                    "storeId mismatch: '\(sessionStore)' != '\(storeID)'")
            }
        }
        if let floorID = eligibility.floorID, !floorID.isEmpty {
            let sessionFloor = metadata.floorID
            // B-08: same fail-closed policy for the floor.
            guard sessionFloor == floorID else {
                throw SessionError.notEligible(
                    "floorId mismatch: '\(sessionFloor)' != '\(floorID)'")
            }
        }
    }

    // MARK: - Strict scalar / identity helpers

    private static func strictInteger(_ value: Any?) -> Int64? {
        guard let value = StrictJSONScalar.integer(value) else { return nil }
        return Int64(value)
    }

    private static func optionalStrictInteger(_ value: Any?) -> Int64? {
        guard value != nil, !(value is NSNull) else { return nil }
        return strictInteger(value)
    }

    private static func optionalStrictNumber(_ value: Any?) -> Double? {
        guard value != nil, !(value is NSNull) else { return nil }
        return StrictJSONScalar.number(value)
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let value = value as? String,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return value
    }

    private static func optionalNonEmptyString(_ value: Any?) -> String? {
        guard value != nil, !(value is NSNull) else { return nil }
        return nonEmptyString(value)
    }

    private static func isSHA256(_ value: String) -> Bool {
        guard value.utf8.count == 64 else { return false }
        return value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 70) ||
                ($0 >= 97 && $0 <= 102)
        }
    }

    private static func isSafeTopLevelName(_ value: String) -> Bool {
        return !value.isEmpty && value != "." && value != ".." &&
            !value.contains("/") && !value.contains("\\") &&
            !value.utf8.contains(0)
    }

    private static func sha256(_ data: Data) -> String {
        return SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
    }

    // MARK: - Source inventory / WAL generation guards

    private static func sourceInventory(
        of directory: URL
    ) throws -> [SourceInventoryEntry] {
        let names = try FileManager.default.contentsOfDirectory(
            atPath: directory.path).sorted()
        var inventory: [SourceInventoryEntry] = []
        inventory.reserveCapacity(names.count)
        for name in names {
            guard isSafeTopLevelName(name) else {
                throw SessionError.copyFailed(
                    "unsafe source inventory name: \(name)")
            }
            let url = directory.appendingPathComponent(name)
            var fileStat = stat()
            guard lstat(url.path, &fileStat) == 0 else {
                throw SessionError.copyFailed(
                    "cannot lstat source inventory entry: \(name)")
            }
            let fileType = fileStat.st_mode & S_IFMT
            guard fileType == S_IFREG else {
                throw SessionError.copyFailed(
                    "source inventory entry is not a regular file: \(name)")
            }
            guard fileStat.st_nlink == 1 else {
                throw SessionError.copyFailed(
                    "source inventory entry has hard links: \(name)")
            }
            inventory.append(SourceInventoryEntry(
                relativeName: name,
                fileType: fileType,
                device: UInt64(fileStat.st_dev),
                inode: UInt64(fileStat.st_ino),
                size: Int64(fileStat.st_size),
                linkCount: UInt64(fileStat.st_nlink),
                modificationSeconds: Int64(fileStat.st_mtimespec.tv_sec),
                modificationNanoseconds: Int64(fileStat.st_mtimespec.tv_nsec),
                changeSeconds: Int64(fileStat.st_ctimespec.tv_sec),
                changeNanoseconds: Int64(fileStat.st_ctimespec.tv_nsec),
                mode: fileStat.st_mode))
        }
        return inventory
    }

    private static func sourceInventoryManifestRecord(
        _ entry: SourceInventoryEntry
    ) -> [String: Any] {
        return [
            "relative_name": entry.relativeName,
            "type": entry.fileType == S_IFREG ? "regular" : "unknown",
            // Decimal strings preserve the full platform identity without
            // JSON/NSNumber precision loss above 2^53.
            "dev": String(entry.device),
            "ino": String(entry.inode),
            "size": entry.size,
            "nlink": String(entry.linkCount),
            "mtime_sec": entry.modificationSeconds,
            "mtime_nsec": entry.modificationNanoseconds,
            "ctime_sec": entry.changeSeconds,
            "ctime_nsec": entry.changeNanoseconds,
            "mode_octal": String(entry.mode, radix: 8),
        ]
    }

    private static func validateWALJournalState(
        sessionDirectory: URL,
        databaseName: String,
        phase: String
    ) throws {
        for suffix in walJournalNames {
            let name = databaseName + suffix
            let url = sessionDirectory.appendingPathComponent(name)
            var fileStat = stat()
            if lstat(url.path, &fileStat) != 0 {
                if errno == ENOENT { continue }
                throw SessionError.notEligible(
                    "\(phase): cannot inspect \(name)")
            }
            guard (fileStat.st_mode & S_IFMT) == S_IFREG,
                  fileStat.st_nlink == 1 else {
                throw SessionError.notEligible(
                    "\(phase): \(name) is not a single regular file")
            }
            guard fileStat.st_size == 0 else {
                throw SessionError.notEligible(
                    "\(phase): non-empty \(name) present; "
                    + "the session DB is not a single-file checkpoint")
            }
        }
    }

    /// FD-relative form used for committed generation validation. Every
    /// lookup stays under the already-bound snapshot root, so replacing the
    /// generation pathname cannot redirect WAL/journal inspection.
    private static func validateWALJournalState(
        parentDescriptor: Int32,
        databaseName: String,
        phase: String
    ) throws {
        for suffix in walJournalNames {
            let name = databaseName + suffix
            var fileStat = stat()
            if fstatat(
                parentDescriptor,
                name,
                &fileStat,
                AT_SYMLINK_NOFOLLOW) != 0 {
                if errno == ENOENT { continue }
                throw SessionError.notEligible(
                    "\(phase): cannot inspect \(name)")
            }
            guard (fileStat.st_mode & S_IFMT) == S_IFREG,
                  fileStat.st_nlink == 1 else {
                throw SessionError.notEligible(
                    "\(phase): \(name) is not a single regular file")
            }
            guard fileStat.st_size == 0 else {
                throw SessionError.notEligible(
                    "\(phase): non-empty \(name) present; "
                    + "the session DB is not a single-file checkpoint")
            }
        }
    }

    // MARK: - Immutable commit / recovery helpers

    /// Removes a snapshot transaction tree after first binding the pathname
    /// to the durable intent's dev/inode. The 0700 cleanup mode is accepted
    /// on retry so a real process death during recursive deletion remains
    /// recoverable even after manifest/payload files have already vanished.
    private static func removeImmutableTree(
        _ directory: URL,
        expectedIdentity: ImmutableDirectoryPublication.Identity? = nil
    ) throws {
        let parent = directory.deletingLastPathComponent()
        let openedParent = try openStableDirectoryNoFollow(
            parent, context: "snapshot cleanup parent")
        defer { _ = close(openedParent.descriptor) }
        let descriptor = openat(
            openedParent.descriptor,
            directory.lastPathComponent,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw SessionError.copyFailed(
                "cannot open snapshot tree for identity-bound removal")
        }
        defer { _ = close(descriptor) }
        var opened = stat()
        var pathBefore = stat()
        guard fstat(descriptor, &opened) == 0,
              (opened.st_mode & S_IFMT) == S_IFDIR,
              fstatat(
                openedParent.descriptor,
                directory.lastPathComponent,
                &pathBefore,
                AT_SYMLINK_NOFOLLOW) == 0,
              sameDirectoryIdentity(opened, pathBefore) else {
            throw SessionError.copyFailed(
                "snapshot tree changed before removal")
        }
        if let expectedIdentity {
            guard UInt64(opened.st_dev) == expectedIdentity.device,
                  UInt64(opened.st_ino) == expectedIdentity.inode else {
                throw SessionError.copyFailed(
                    "snapshot cleanup dev/inode differs from transaction intent")
            }
        }
        guard fchmod(descriptor, cleanupDirectoryMode) == 0,
              fsync(descriptor) == 0 else {
            throw SessionError.copyFailed(
                "cannot make immutable snapshot removable")
        }
        try faultInjector?(.afterCleanupRootPreparedBeforeRemoval)
        try requireBoundDirectoryPath(
            descriptor: descriptor,
            expectedIdentity: expectedIdentity,
            expectedMode: cleanupDirectoryMode,
            parentDescriptor: openedParent.descriptor,
            parentURL: parent,
            parentMetadata: openedParent.metadata,
            basename: directory.lastPathComponent,
            context: "snapshot tree before recursive removal")
        try removeFlatSnapshotContents(
            directoryDescriptor: descriptor,
            context: directory.lastPathComponent)
        guard fsync(descriptor) == 0 else {
            throw SessionError.copyFailed(
                "cannot sync snapshot tree after content removal")
        }
        try requireBoundDirectoryPath(
            descriptor: descriptor,
            expectedIdentity: expectedIdentity,
            expectedMode: cleanupDirectoryMode,
            parentDescriptor: openedParent.descriptor,
            parentURL: parent,
            parentMetadata: openedParent.metadata,
            basename: directory.lastPathComponent,
            context: "snapshot tree before root removal")
        guard unlinkat(
            openedParent.descriptor,
            directory.lastPathComponent,
            AT_REMOVEDIR) == 0 else {
            throw SessionError.copyFailed(
                "cannot remove identity-bound snapshot root")
        }
        guard fsync(openedParent.descriptor) == 0 else {
            throw SessionError.copyFailed(
                "cannot sync snapshot cleanup parent")
        }
    }

    private static func removeFlatSnapshotContents(
        directoryDescriptor: Int32,
        context: String
    ) throws {
        let names = try directoryEntryNames(
            atBoundDirectoryDescriptor: directoryDescriptor,
            context: context,
            maximumEntries: maximumSnapshotDirectoryEntries)
        for name in names {
            var metadata = stat()
            guard fstatat(
                directoryDescriptor,
                name,
                &metadata,
                AT_SYMLINK_NOFOLLOW) == 0,
                  (metadata.st_mode & S_IFMT) == S_IFREG,
                  metadata.st_nlink == 1 else {
                throw SessionError.copyFailed(
                    "snapshot cleanup found a non-regular or linked child")
            }
            guard unlinkat(directoryDescriptor, name, 0) == 0 else {
                throw SessionError.copyFailed(
                    "cannot remove snapshot cleanup child")
            }
            try faultInjector?(.afterCleanupChildRemoval)
        }
    }

    private static func recoverInterruptedCommitIfNeeded(
        taskRoot: URL,
        snapshotDirectory: URL,
        backupDirectory: URL,
        stagingDirectory: URL
    ) throws {
        try rejectUnboundSnapshotCreationTemporaries(taskRoot: taskRoot)
        try cleanupSnapshotIntentTemporaryRemovalTombstones(
            taskRoot: taskRoot)
        try cleanupSnapshotIntentRemovalTombstones(taskRoot: taskRoot)
        try cleanupSnapshotIntentTemporaries(taskRoot: taskRoot)
        try cleanupTaskManifestTemporaryRemovalTombstones(taskRoot: taskRoot)
        try cleanupTaskManifestRemovalTombstones(taskRoot: taskRoot)
        let authorizedTaskTemporaries = try authorizeTaskManifestTemporaries(
            taskRoot: taskRoot)
        // These entries have already been jointly classified against the
        // canonical task authority and durable intent. They are cleanup-only
        // state in both pre-swap and normal post-swap cases, so detach them
        // before recovery can remove the intent. A second crash can then
        // never strand an authorized temp without its classification record.
        try cleanupTaskManifestTemporaries(
            taskRoot: taskRoot,
            authorized: authorizedTaskTemporaries)
        try recoverInterruptedCommitCore(
            taskRoot: taskRoot,
            snapshotDirectory: snapshotDirectory,
            backupDirectory: backupDirectory,
            stagingDirectory: stagingDirectory)
        try faultInjector?(.afterRecoveryCoreBeforeReturn)
    }

    private static func recoverInterruptedCommitCore(
        taskRoot: URL,
        snapshotDirectory: URL,
        backupDirectory: URL,
        stagingDirectory: URL
    ) throws {
        let fileManager = FileManager.default
        let transactionIntentURL = taskRoot.appendingPathComponent(
            transactionIntentFileName)
        if fileManager.fileExists(atPath: transactionIntentURL.path) {
            let intentRecord = try readSnapshotCommitIntent(transactionIntentURL)
            let intent = intentRecord.intent
            guard intent.taskID == taskRoot.lastPathComponent else {
                throw SessionError.copyFailed(
                    "snapshot transaction intent task mismatch")
            }
            let taskManifest = try taskManifestDataIfPresent(taskRoot)
            let taskManifestSHA = taskManifest.map(sha256)
            if taskManifestSHA == intent.newManifestSHA256 {
                try finishNewSnapshotGeneration(
                    intent: intent,
                    taskRoot: taskRoot,
                    snapshotDirectory: snapshotDirectory,
                    backupDirectory: backupDirectory,
                    stagingDirectory: stagingDirectory,
                    transactionIntentURL: transactionIntentURL,
                    transactionIntentIdentity: intentRecord.fileIdentity)
                return
            }
            guard taskManifestSHA == intent.priorManifestSHA256 else {
                throw SessionError.copyFailed(
                    "snapshot task reference matches neither transaction generation")
            }
            try restorePriorSnapshotGeneration(
                intent: intent,
                priorTaskManifest: taskManifest,
                taskRoot: taskRoot,
                snapshotDirectory: snapshotDirectory,
                backupDirectory: backupDirectory,
                stagingDirectory: stagingDirectory,
                transactionIntentURL: transactionIntentURL,
                transactionIntentIdentity: intentRecord.fileIdentity)
            return
        }

        // Legacy cleanup for a transaction created before the durable intent
        // existed. Only a fully frozen generation matching the authoritative
        // task reference may be selected. A writable root without an intent
        // is never repaired because it may be a post-commit mode tamper.
        guard fileManager.fileExists(atPath: backupDirectory.path) else {
            return
        }
        if fileManager.fileExists(atPath: snapshotDirectory.path) {
            do {
                try revalidateSnapshot(snapshotDirectory)
                try removeImmutableTree(backupDirectory)
                try fsyncDirectory(taskRoot)
                return
            } catch let currentError {
                do {
                    try revalidateSnapshot(backupDirectory)
                    try removeImmutableTree(snapshotDirectory)
                    let backupIdentity = try ImmutableDirectoryPublication
                        .identity(
                            of: backupDirectory,
                            allowedModes: [committedDirectoryMode])
                    try ImmutableDirectoryPublication.publish(
                        source: backupDirectory,
                        destination: snapshotDirectory,
                        expectedIdentity: backupIdentity)
                    try revalidateSnapshot(snapshotDirectory)
                    return
                } catch {
                    if snapshotMatchesTaskReferenceLoosely(
                        backupDirectory, taskRoot: taskRoot) {
                        try removeImmutableTree(snapshotDirectory)
                        let backupIdentity = try ImmutableDirectoryPublication
                            .identity(
                                of: backupDirectory,
                                allowedModes: [committedDirectoryMode])
                        try ImmutableDirectoryPublication.publish(
                            source: backupDirectory,
                            destination: snapshotDirectory,
                            expectedIdentity: backupIdentity)
                        try revalidateSnapshot(snapshotDirectory)
                        return
                    }
                    throw SessionError.copyFailed(
                        "neither current nor backup snapshot is a durable "
                        + "generation: current=\(currentError.localizedDescription); "
                        + "backup=\(error.localizedDescription)")
                }
            }
        }
        guard snapshotMatchesTaskReferenceLoosely(
            backupDirectory, taskRoot: taskRoot) else {
            throw SessionError.copyFailed(
                "orphaned snapshot backup does not match the task reference")
        }
        let backupIdentity = try ImmutableDirectoryPublication.identity(
            of: backupDirectory,
            allowedModes: [committedDirectoryMode])
        try ImmutableDirectoryPublication.publish(
            source: backupDirectory,
            destination: snapshotDirectory,
            expectedIdentity: backupIdentity)
        try revalidateSnapshot(snapshotDirectory)
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

    private static func parseTaskManifestTemporaryName(
        _ name: String
    ) -> TaskManifestTemporaryName? {
        guard name.hasPrefix(taskManifestTemporaryPrefix),
              name.hasSuffix(taskManifestTemporarySuffix) else {
            return nil
        }
        let start = name.index(
            name.startIndex,
            offsetBy: taskManifestTemporaryPrefix.count)
        let end = name.index(
            name.endIndex,
            offsetBy: -taskManifestTemporarySuffix.count)
        let body = String(name[start..<end])
        let parts = body.split(
            separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4,
              let temporaryIdentity = parseIdentityToken(String(parts[0])),
              isSHA256(String(parts[2])),
              String(parts[2]) == String(parts[2]).lowercased(),
              isCanonicalLowercaseUUID(String(parts[3])) else {
            return nil
        }
        let displacedToken = String(parts[1])
        let displacedIdentity: ImmutableDirectoryPublication.Identity?
        if displacedToken == "none" {
            displacedIdentity = nil
        } else {
            guard let parsed = parseIdentityToken(displacedToken) else {
                return nil
            }
            displacedIdentity = parsed
        }
        return TaskManifestTemporaryName(
            temporaryIdentity: temporaryIdentity,
            expectedDisplacedIdentity: displacedIdentity,
            targetSHA256: String(parts[2]))
    }

    private static func metadataIdentity(
        _ metadata: stat
    ) -> ImmutableDirectoryPublication.Identity {
        return ImmutableDirectoryPublication.Identity(
            device: UInt64(metadata.st_dev), inode: UInt64(metadata.st_ino))
    }

    private static func quarantineUnexpectedFile(
        parentDescriptor: Int32,
        basename: String,
        conflictPrefix: String,
        context: String
    ) throws {
        let conflictName = conflictPrefix + UUID().uuidString.lowercased()
        if renameatx_np(
            parentDescriptor, basename,
            parentDescriptor, conflictName,
            UInt32(RENAME_EXCL)) == 0 {
            guard fsync(parentDescriptor) == 0 else {
                throw SessionError.copyFailed(
                    "cannot sync preserved \(context)")
            }
        }
        throw SessionError.copyFailed(
            "\(context) identity mismatch; evidence preserved")
    }

    private static func restoreOrQuarantineUnexpectedRemoval(
        parentDescriptor: Int32,
        tombstoneName: String,
        canonicalName: String,
        conflictPrefix: String,
        context: String
    ) throws {
        var canonicalMetadata = stat()
        let lookup = fstatat(
            parentDescriptor,
            canonicalName,
            &canonicalMetadata,
            AT_SYMLINK_NOFOLLOW)
        if lookup != 0, errno == ENOENT,
           renameatx_np(
                parentDescriptor, tombstoneName,
                parentDescriptor, canonicalName,
                UInt32(RENAME_EXCL)) == 0 {
            guard fsync(parentDescriptor) == 0 else {
                throw SessionError.copyFailed(
                    "cannot sync restored \(context)")
            }
            throw SessionError.copyFailed(
                "\(context) identity mismatch; unexpected authority restored")
        }
        try quarantineUnexpectedFile(
            parentDescriptor: parentDescriptor,
            basename: tombstoneName,
            conflictPrefix: conflictPrefix,
            context: context)
    }

    private static func removeIdentityBoundTemporary(
        parentDescriptor: Int32,
        basename: String,
        expectedMetadata: stat,
        removalPrefix: String,
        conflictPrefix: String,
        context: String
    ) throws {
        let expectedIdentity = metadataIdentity(expectedMetadata)
        let tombstoneName = removalPrefix + identityToken(expectedIdentity)
            + "." + UUID().uuidString.lowercased()
        guard renameatx_np(
            parentDescriptor, basename,
            parentDescriptor, tombstoneName,
            UInt32(RENAME_EXCL)) == 0 else {
            throw SessionError.copyFailed(
                "cannot detach \(context)")
        }
        var moved = stat()
        guard fstatat(
            parentDescriptor,
            tombstoneName,
            &moved,
            AT_SYMLINK_NOFOLLOW) == 0,
              metadataIdentity(moved) == expectedIdentity,
              (moved.st_mode & S_IFMT) == S_IFREG,
              moved.st_nlink == 1 else {
            try quarantineUnexpectedFile(
                parentDescriptor: parentDescriptor,
                basename: tombstoneName,
                conflictPrefix: conflictPrefix,
                context: context)
            return
        }
        guard fsync(parentDescriptor) == 0,
              unlinkat(parentDescriptor, tombstoneName, 0) == 0,
              fsync(parentDescriptor) == 0 else {
            throw SessionError.copyFailed(
                "cannot durably remove \(context)")
        }
    }

    private static func rejectUnboundSnapshotCreationTemporaries(
        taskRoot: URL
    ) throws {
        let openedParent = try openStableDirectoryNoFollow(
            taskRoot, context: "snapshot unbound temporary parent")
        defer { _ = close(openedParent.descriptor) }
        let names = try directoryEntryNames(
            atBoundDirectoryDescriptor: openedParent.descriptor,
            context: "snapshot unbound temporary parent",
            maximumEntries: maximumSnapshotDirectoryEntries)
        for name in names {
            let mapping: (prefix: String, conflict: String)?
            if name.hasPrefix(transactionIntentCreationPrefix) {
                mapping = (
                    transactionIntentCreationPrefix,
                    transactionIntentConflictPrefix)
            } else if name.hasPrefix(taskManifestCreationPrefix) {
                mapping = (
                    taskManifestCreationPrefix,
                    taskManifestConflictPrefix)
            } else {
                mapping = nil
            }
            guard let mapping else { continue }
            let suffix = String(name.dropFirst(mapping.prefix.count))
            guard isCanonicalLowercaseUUID(suffix) else {
                throw SessionError.copyFailed(
                    "malformed unbound snapshot creation temporary preserved")
            }
            try quarantineUnexpectedFile(
                parentDescriptor: openedParent.descriptor,
                basename: name,
                conflictPrefix: mapping.conflict,
                context: "unbound snapshot creation temporary")
        }
    }

    private static func cleanupIdentityBoundTemporaryRemovalTombstones(
        taskRoot: URL,
        prefix: String,
        conflictPrefix: String,
        maximumBytes: Int,
        context: String
    ) throws {
        let openedParent = try openStableDirectoryNoFollow(
            taskRoot, context: context + " parent")
        defer { _ = close(openedParent.descriptor) }
        let names = try directoryEntryNames(
            atBoundDirectoryDescriptor: openedParent.descriptor,
            context: context + " parent",
            maximumEntries: maximumSnapshotDirectoryEntries)
        var removed = false
        for name in names where name.hasPrefix(prefix) {
            guard let parsed = parseIdentityBoundName(name, prefix: prefix) else {
                throw SessionError.copyFailed(
                    "malformed \(context) preserved")
            }
            var metadata = stat()
            guard fstatat(
                openedParent.descriptor,
                name,
                &metadata,
                AT_SYMLINK_NOFOLLOW) == 0 else {
                throw SessionError.copyFailed(
                    "cannot inspect \(context)")
            }
            guard metadataIdentity(metadata) == parsed.identity else {
                try quarantineUnexpectedFile(
                    parentDescriptor: openedParent.descriptor,
                    basename: name,
                    conflictPrefix: conflictPrefix,
                    context: context)
                return
            }
            guard (metadata.st_mode & S_IFMT) == S_IFREG,
                  metadata.st_nlink == 1,
                  metadata.st_size >= 0,
                  metadata.st_size <= maximumBytes,
                  [mode_t(0o600), committedFileMode].contains(
                    metadata.st_mode & mode_t(0o777)),
                  unlinkat(openedParent.descriptor, name, 0) == 0 else {
                throw SessionError.copyFailed(
                    "invalid \(context)")
            }
            removed = true
        }
        if removed, fsync(openedParent.descriptor) != 0 {
            throw SessionError.copyFailed(
                "cannot sync \(context) cleanup")
        }
    }

    private static func cleanupSnapshotIntentTemporaryRemovalTombstones(
        taskRoot: URL
    ) throws {
        try cleanupIdentityBoundTemporaryRemovalTombstones(
            taskRoot: taskRoot,
            prefix: transactionIntentTemporaryRemovalPrefix,
            conflictPrefix: transactionIntentConflictPrefix,
            maximumBytes: maximumSnapshotTransactionIntentBytes,
            context: "snapshot intent-temporary removal tombstone")
    }

    private static func cleanupTaskManifestTemporaryRemovalTombstones(
        taskRoot: URL
    ) throws {
        try cleanupIdentityBoundTemporaryRemovalTombstones(
            taskRoot: taskRoot,
            prefix: taskManifestTemporaryRemovalPrefix,
            conflictPrefix: taskManifestConflictPrefix,
            maximumBytes: maximumTaskManifestBytes,
            context: "task-reference temporary removal tombstone")
    }

    private static func cleanupSnapshotIntentTemporaries(
        taskRoot: URL
    ) throws {
        let openedParent = try openStableDirectoryNoFollow(
            taskRoot, context: "snapshot intent temporary parent")
        defer { _ = close(openedParent.descriptor) }
        let names = try directoryEntryNames(
            atBoundDirectoryDescriptor: openedParent.descriptor,
            context: "snapshot intent temporary parent",
            maximumEntries: maximumSnapshotDirectoryEntries)
        for name in names where
            name.hasPrefix(transactionIntentTemporaryPrefix)
                && !name.hasPrefix(transactionIntentTemporaryRemovalPrefix) {
            guard let parsed = parseIdentityBoundName(
                name, prefix: transactionIntentTemporaryPrefix) else {
                throw SessionError.copyFailed(
                    "malformed orphan snapshot transaction temporary preserved")
            }
            var canonical = stat()
            guard fstatat(
                openedParent.descriptor,
                transactionIntentFileName,
                &canonical,
                AT_SYMLINK_NOFOLLOW) != 0,
                  errno == ENOENT else {
                throw SessionError.copyFailed(
                    "snapshot transaction temporary coexists with canonical intent")
            }
            var metadata = stat()
            guard fstatat(
                openedParent.descriptor,
                name,
                &metadata,
                AT_SYMLINK_NOFOLLOW) == 0,
                  metadataIdentity(metadata) == parsed.identity,
                  (metadata.st_mode & S_IFMT) == S_IFREG,
                  metadata.st_nlink == 1,
                  metadata.st_size >= 0,
                  metadata.st_size <= maximumSnapshotTransactionIntentBytes,
                  [mode_t(0o600), committedFileMode].contains(
                    metadata.st_mode & mode_t(0o777)) else {
                throw SessionError.copyFailed(
                    "orphan snapshot transaction temporary identity mismatch")
            }
            if metadata.st_mode & mode_t(0o777) == committedFileMode {
                let record = try readSnapshotCommitIntent(
                    taskRoot.appendingPathComponent(name))
                guard record.fileIdentity == parsed.identity,
                      record.intent.taskID == taskRoot.lastPathComponent else {
                    throw SessionError.copyFailed(
                        "orphan snapshot transaction temporary payload mismatch")
                }
            }
            try removeIdentityBoundTemporary(
                parentDescriptor: openedParent.descriptor,
                basename: name,
                expectedMetadata: metadata,
                removalPrefix: transactionIntentTemporaryRemovalPrefix,
                conflictPrefix: transactionIntentConflictPrefix,
                context: "snapshot transaction temporary")
        }
        try requireOpenDirectoryPath(
            descriptor: openedParent.descriptor,
            url: taskRoot,
            expectedMetadata: openedParent.metadata,
            context: "snapshot intent temporary parent after cleanup")
    }

    private static func cleanupSnapshotIntentRemovalTombstones(
        taskRoot: URL
    ) throws {
        let openedParent = try openStableDirectoryNoFollow(
            taskRoot, context: "snapshot intent-removal parent")
        defer { _ = close(openedParent.descriptor) }
        let names = try directoryEntryNames(
            atBoundDirectoryDescriptor: openedParent.descriptor,
            context: "snapshot intent-removal parent",
            maximumEntries: maximumSnapshotDirectoryEntries)
        var removed = false
        for name in names where name.hasPrefix(transactionIntentRemovalPrefix) {
            guard let parsed = parseIdentityBoundName(
                name, prefix: transactionIntentRemovalPrefix) else {
                throw SessionError.copyFailed(
                    "malformed snapshot intent-removal tombstone preserved")
            }
            var metadata = stat()
            guard fstatat(
                openedParent.descriptor,
                name,
                &metadata,
                AT_SYMLINK_NOFOLLOW) == 0 else {
                throw SessionError.copyFailed(
                    "cannot inspect snapshot intent-removal tombstone")
            }
            guard metadataIdentity(metadata) == parsed.identity else {
                try restoreOrQuarantineUnexpectedRemoval(
                    parentDescriptor: openedParent.descriptor,
                    tombstoneName: name,
                    canonicalName: transactionIntentFileName,
                    conflictPrefix: transactionIntentConflictPrefix,
                    context: "snapshot intent-removal tombstone")
                return
            }
            let record = try readSnapshotCommitIntent(
                taskRoot.appendingPathComponent(name))
            guard record.fileIdentity == parsed.identity,
                  record.intent.taskID == taskRoot.lastPathComponent,
                  unlinkat(openedParent.descriptor, name, 0) == 0 else {
                throw SessionError.copyFailed(
                    "invalid snapshot intent-removal tombstone")
            }
            removed = true
        }
        if removed, fsync(openedParent.descriptor) != 0 {
            throw SessionError.copyFailed(
                "cannot sync snapshot intent-removal cleanup")
        }
    }

    private static func cleanupTaskManifestRemovalTombstones(
        taskRoot: URL
    ) throws {
        let openedParent = try openStableDirectoryNoFollow(
            taskRoot, context: "task-reference removal parent")
        defer { _ = close(openedParent.descriptor) }
        let names = try directoryEntryNames(
            atBoundDirectoryDescriptor: openedParent.descriptor,
            context: "task-reference removal parent",
            maximumEntries: maximumSnapshotDirectoryEntries)
        let removalNames = names.filter {
            $0.hasPrefix(taskManifestRemovalPrefix)
        }
        guard !removalNames.isEmpty else { return }
        let intentRecord: ReadSnapshotCommitIntent
        do {
            intentRecord = try readSnapshotCommitIntent(
                taskRoot.appendingPathComponent(transactionIntentFileName))
        } catch {
            throw SessionError.copyFailed(
                "task-reference removal tombstone exists without durable intent")
        }
        let intent = intentRecord.intent
        guard intent.priorManifestSHA256 == nil,
              intent.priorIdentity == nil else {
            throw SessionError.copyFailed(
                "task-reference removal tombstone intent is inconsistent")
        }
        var removed = false
        for name in removalNames {
            guard let parsed = parseIdentityBoundName(
                name, prefix: taskManifestRemovalPrefix) else {
                throw SessionError.copyFailed(
                    "malformed task-reference removal tombstone preserved")
            }
            var metadata = stat()
            guard fstatat(
                openedParent.descriptor,
                name,
                &metadata,
                AT_SYMLINK_NOFOLLOW) == 0 else {
                throw SessionError.copyFailed(
                    "cannot inspect task-reference removal tombstone")
            }
            guard metadataIdentity(metadata) == parsed.identity else {
                try restoreOrQuarantineUnexpectedRemoval(
                    parentDescriptor: openedParent.descriptor,
                    tombstoneName: name,
                    canonicalName: "input_manifest.json",
                    conflictPrefix: taskManifestConflictPrefix,
                    context: "task-reference removal tombstone")
                return
            }
            guard let stable = try readStableCommittedFileIfPresent(
                parentDescriptor: openedParent.descriptor,
                basename: name,
                maximumBytes: maximumTaskManifestBytes),
                  stable.identity == parsed.identity,
                  sha256(stable.data) == intent.newManifestSHA256,
                  unlinkat(openedParent.descriptor, name, 0) == 0 else {
                throw SessionError.copyFailed(
                    "invalid task-reference removal tombstone")
            }
            removed = true
        }
        if removed, fsync(openedParent.descriptor) != 0 {
            throw SessionError.copyFailed(
                "cannot sync task-reference removal cleanup")
        }
    }

    /// Preflights identity-bearing task-reference temporaries before recovery
    /// mutates a generation. The encoded temporary/old-authority identities
    /// distinguish pre-swap, normal post-swap and unrelated displaced files.
    private static func authorizeTaskManifestTemporaries(
        taskRoot: URL
    ) throws -> [String: stat] {
        let openedParent = try openStableDirectoryNoFollow(
            taskRoot, context: "task manifest temporary parent")
        defer { _ = close(openedParent.descriptor) }
        let names = try directoryEntryNames(
            atBoundDirectoryDescriptor: openedParent.descriptor,
            context: "task manifest temporary parent",
            maximumEntries: maximumSnapshotDirectoryEntries)
        let temporaryNames = names.filter {
            $0.hasPrefix(taskManifestTemporaryPrefix)
                && $0.hasSuffix(taskManifestTemporarySuffix)
        }
        guard !temporaryNames.isEmpty else { return [:] }

        let intentURL = taskRoot.appendingPathComponent(
            transactionIntentFileName)
        let intent: SnapshotCommitIntent?
        var intentMetadata = stat()
        if fstatat(
            openedParent.descriptor,
            transactionIntentFileName,
            &intentMetadata,
            AT_SYMLINK_NOFOLLOW) == 0 {
            intent = try readSnapshotCommitIntent(intentURL).intent
        } else if errno == ENOENT {
            intent = nil
        } else {
            throw SessionError.copyFailed(
                "cannot inspect snapshot transaction intent during temporary recovery")
        }
        let allowedSHA256 = Set([
            intent?.newManifestSHA256,
            intent?.priorManifestSHA256,
        ].compactMap { $0 })
        var authorized: [String: stat] = [:]
        for name in temporaryNames {
            guard let parsed = parseTaskManifestTemporaryName(name) else {
                throw SessionError.copyFailed(
                    "malformed snapshot task-reference temporary preserved")
            }
            if let intent,
               !allowedSHA256.contains(parsed.targetSHA256) {
                throw SessionError.copyFailed(
                    "snapshot task-reference temporary target is not intent-bound")
            }
            var metadata = stat()
            guard fstatat(
                openedParent.descriptor,
                name,
                &metadata,
                AT_SYMLINK_NOFOLLOW) == 0,
                  (metadata.st_mode & S_IFMT) == S_IFREG,
                  metadata.st_nlink == 1,
                  metadata.st_size >= 0,
                  metadata.st_size <= maximumTaskManifestBytes else {
                throw SessionError.copyFailed(
                    "invalid orphan snapshot task-reference temporary")
            }
            let actualIdentity = metadataIdentity(metadata)
            let canonical = try readStableCommittedFileIfPresent(
                parentDescriptor: openedParent.descriptor,
                basename: "input_manifest.json",
                maximumBytes: maximumTaskManifestBytes)

            if actualIdentity == parsed.temporaryIdentity {
                guard intent != nil,
                      [mode_t(0o600), committedFileMode].contains(
                        metadata.st_mode & mode_t(0o777)) else {
                    throw SessionError.copyFailed(
                        "pre-swap task-reference temporary lacks durable intent")
                }
                if let expectedDisplaced = parsed.expectedDisplacedIdentity {
                    guard canonical?.identity == expectedDisplaced else {
                        throw SessionError.copyFailed(
                            "pre-swap task-reference authority identity changed")
                    }
                } else {
                    guard canonical == nil else {
                        throw SessionError.copyFailed(
                            "first-generation task-reference authority appeared")
                    }
                }
                if metadata.st_mode & mode_t(0o777) == committedFileMode {
                    guard let stable = try readStableCommittedFileIfPresent(
                        parentDescriptor: openedParent.descriptor,
                        basename: name,
                        maximumBytes: maximumTaskManifestBytes),
                          stable.identity == parsed.temporaryIdentity,
                          sha256(stable.data) == parsed.targetSHA256 else {
                        throw SessionError.copyFailed(
                            "pre-swap task-reference temporary payload changed")
                    }
                    metadata = stable.metadata
                }
                authorized[name] = metadata
                continue
            }

            guard let expectedDisplaced = parsed.expectedDisplacedIdentity,
                  actualIdentity == expectedDisplaced,
                  metadata.st_mode & mode_t(0o777) == committedFileMode,
                  let installed = canonical,
                  installed.identity == parsed.temporaryIdentity,
                  sha256(installed.data) == parsed.targetSHA256 else {
                throw SessionError.copyFailed(
                    "task-reference swap displaced unrelated authority; evidence preserved")
            }
            guard let stableDisplaced = try readStableCommittedFileIfPresent(
                    parentDescriptor: openedParent.descriptor,
                    basename: name,
                    maximumBytes: maximumTaskManifestBytes),
                  stableDisplaced.identity == expectedDisplaced else {
                throw SessionError.copyFailed(
                    "displaced task-reference identity changed during authorization")
            }
            if intent != nil {
                guard allowedSHA256.contains(sha256(stableDisplaced.data)) else {
                    throw SessionError.copyFailed(
                        "displaced task-reference bytes are not intent-bound")
                }
            }
            authorized[name] = stableDisplaced.metadata
        }
        try requireOpenDirectoryPath(
            descriptor: openedParent.descriptor,
            url: taskRoot,
            expectedMetadata: openedParent.metadata,
            context: "task manifest temporary parent after authorization")
        return authorized
    }

    private static func cleanupTaskManifestTemporaries(
        taskRoot: URL,
        authorized: [String: stat]
    ) throws {
        guard !authorized.isEmpty else { return }
        let openedParent = try openStableDirectoryNoFollow(
            taskRoot, context: "task manifest temporary cleanup parent")
        defer { _ = close(openedParent.descriptor) }
        for (name, expectedMetadata) in authorized {
            var current = stat()
            if fstatat(
                openedParent.descriptor,
                name,
                &current,
                AT_SYMLINK_NOFOLLOW) != 0 {
                if errno == ENOENT { continue }
                throw SessionError.copyFailed(
                    "cannot inspect authorized task-reference temporary")
            }
            guard sameFileIdentity(expectedMetadata, current) else {
                throw SessionError.copyFailed(
                    "authorized task-reference temporary changed before cleanup")
            }
            try removeIdentityBoundTemporary(
                parentDescriptor: openedParent.descriptor,
                basename: name,
                expectedMetadata: current,
                removalPrefix: taskManifestTemporaryRemovalPrefix,
                conflictPrefix: taskManifestConflictPrefix,
                context: "authorized task-reference temporary")
        }
        if fsync(openedParent.descriptor) != 0 {
            throw SessionError.copyFailed(
                "cannot sync task root after task-reference temporary cleanup")
        }
    }

    private static func rollbackSnapshotCommit(
        intent: SnapshotCommitIntent,
        priorTaskManifest: Data?,
        taskRoot: URL,
        snapshotDirectory: URL,
        backupDirectory: URL,
        stagingDirectory: URL,
        transactionIntentURL: URL,
        transactionIntentIdentity: ImmutableDirectoryPublication.Identity
    ) throws {
        try restorePriorSnapshotGeneration(
            intent: intent,
            priorTaskManifest: priorTaskManifest,
            taskRoot: taskRoot,
            snapshotDirectory: snapshotDirectory,
            backupDirectory: backupDirectory,
            stagingDirectory: stagingDirectory,
            transactionIntentURL: transactionIntentURL,
            transactionIntentIdentity: transactionIntentIdentity)
    }

    private static func finishNewSnapshotGeneration(
        intent: SnapshotCommitIntent,
        taskRoot: URL,
        snapshotDirectory: URL,
        backupDirectory: URL,
        stagingDirectory: URL,
        transactionIntentURL: URL,
        transactionIntentIdentity: ImmutableDirectoryPublication.Identity
    ) throws {
        let generation = try validateIntentBoundGeneration(
            snapshotDirectory,
            expectedManifestSHA256: intent.newManifestSHA256,
            expectedIdentity: intent.newIdentity)
        try ImmutableDirectoryPublication.freezeInterruptedDestination(
            snapshotDirectory, expectedIdentity: intent.newIdentity)
        guard generation.taskID == intent.taskID else {
            throw SessionError.copyFailed(
                "new snapshot generation task mismatch")
        }
        try revalidateSnapshot(
            snapshotDirectory,
            expectedDirectoryIdentity: intent.newIdentity,
            expectedManifestSHA256: intent.newManifestSHA256)
        if FileManager.default.fileExists(atPath: backupDirectory.path) {
            guard let priorIdentity = intent.priorIdentity else {
                throw SessionError.copyFailed(
                    "committed snapshot has an unexpected backup generation")
            }
            try removeImmutableTree(
                backupDirectory, expectedIdentity: priorIdentity)
        }
        if FileManager.default.fileExists(atPath: stagingDirectory.path) {
            try removeImmutableTree(
                stagingDirectory, expectedIdentity: intent.newIdentity)
        }
        try fsyncDirectory(taskRoot)
        try revalidateSnapshot(
            snapshotDirectory,
            expectedDirectoryIdentity: intent.newIdentity,
            expectedManifestSHA256: intent.newManifestSHA256)
        try removeSnapshotCommitIntent(
            transactionIntentURL,
            expectedIntent: intent,
            expectedIdentity: transactionIntentIdentity)
    }

    private static func restorePriorSnapshotGeneration(
        intent: SnapshotCommitIntent,
        priorTaskManifest: Data?,
        taskRoot: URL,
        snapshotDirectory: URL,
        backupDirectory: URL,
        stagingDirectory: URL,
        transactionIntentURL: URL,
        transactionIntentIdentity: ImmutableDirectoryPublication.Identity
    ) throws {
        let fileManager = FileManager.default
        let taskManifestURL = taskRoot.appendingPathComponent(
            "input_manifest.json")
        let currentTaskManifestSHA = try taskManifestDataIfPresent(taskRoot)
            .map(sha256)
        let allowedAuthoritySHAs = Set([
            intent.newManifestSHA256,
            intent.priorManifestSHA256,
        ].compactMap { $0 })
        if let currentTaskManifestSHA {
            guard allowedAuthoritySHAs.contains(currentTaskManifestSHA) else {
                throw SessionError.copyFailed(
                    "snapshot rollback found an unrelated task authority")
            }
        } else if intent.priorManifestSHA256 != nil {
            throw SessionError.copyFailed(
                "snapshot rollback lost the prior task authority")
        }

        if let priorSHA = intent.priorManifestSHA256,
           let priorIdentity = intent.priorIdentity {
            var priorLocation: URL?
            if fileManager.fileExists(atPath: backupDirectory.path),
               (try? validateIntentBoundGeneration(
                    backupDirectory,
                    expectedManifestSHA256: priorSHA,
                    expectedIdentity: priorIdentity)) != nil {
                priorLocation = backupDirectory
            } else if fileManager.fileExists(atPath: snapshotDirectory.path),
                      (try? validateIntentBoundGeneration(
                        snapshotDirectory,
                        expectedManifestSHA256: priorSHA,
                        expectedIdentity: priorIdentity)) != nil {
                priorLocation = snapshotDirectory
            }
            guard let priorLocation else {
                throw SessionError.copyFailed(
                    "transaction cannot locate the prior snapshot generation")
            }

            guard let priorTaskManifest,
                  sha256(priorTaskManifest) == priorSHA else {
                throw SessionError.copyFailed(
                    "prior task reference bytes unavailable for rollback")
            }
            // Restore the authority first. If a second process death lands
            // during cleanup or backup publication, restart will select the
            // prior generation again instead of trying to finish a new
            // generation that has already been removed.
            if currentTaskManifestSHA != priorSHA {
                try writeTaskManifest(
                    priorTaskManifest, to: taskManifestURL, taskRoot: taskRoot)
            } else {
                try fsyncDirectory(taskRoot)
            }
            try faultInjector?(
                .afterPriorAuthorityRestoreBeforeGenerationCleanup)

            if priorLocation == backupDirectory {
                if fileManager.fileExists(atPath: snapshotDirectory.path) {
                    try removeImmutableTree(
                        snapshotDirectory,
                        expectedIdentity: intent.newIdentity)
                }
                try ImmutableDirectoryPublication.publish(
                    source: backupDirectory,
                    destination: snapshotDirectory,
                    expectedIdentity: priorIdentity)
            } else {
                try ImmutableDirectoryPublication.freezeInterruptedDestination(
                    snapshotDirectory, expectedIdentity: priorIdentity)
            }
            try revalidateSnapshot(
                snapshotDirectory,
                expectedDirectoryIdentity: priorIdentity,
                expectedManifestSHA256: priorSHA)
        } else {
            guard intent.priorManifestSHA256 == nil,
                  intent.priorIdentity == nil,
                  priorTaskManifest == nil else {
                throw SessionError.copyFailed(
                    "first-generation snapshot intent is internally inconsistent")
            }
            // Absence is the prior authority for the first generation. Make
            // that state durable before destroying any new snapshot bytes.
            try clearTaskManifestForRollback(
                taskRoot: taskRoot,
                expectedNewManifestSHA256: intent.newManifestSHA256)
            try faultInjector?(
                .afterPriorAuthorityRestoreBeforeGenerationCleanup)
            if fileManager.fileExists(atPath: snapshotDirectory.path) {
                try removeImmutableTree(
                    snapshotDirectory,
                    expectedIdentity: intent.newIdentity)
            }
        }

        if fileManager.fileExists(atPath: stagingDirectory.path) {
            try removeImmutableTree(
                stagingDirectory, expectedIdentity: intent.newIdentity)
        }
        if fileManager.fileExists(atPath: backupDirectory.path) {
            throw SessionError.copyFailed(
                "snapshot rollback left an unexpected backup generation")
        }
        try fsyncDirectory(taskRoot)
        if let priorSHA = intent.priorManifestSHA256,
           let priorIdentity = intent.priorIdentity {
            try revalidateSnapshot(
                snapshotDirectory,
                expectedDirectoryIdentity: priorIdentity,
                expectedManifestSHA256: priorSHA)
        } else {
            guard !fileManager.fileExists(atPath: snapshotDirectory.path),
                  try taskManifestDataIfPresent(taskRoot) == nil else {
                throw SessionError.copyFailed(
                    "first-generation rollback authority changed before intent cleanup")
            }
        }
        try removeSnapshotCommitIntent(
            transactionIntentURL,
            expectedIntent: intent,
            expectedIdentity: transactionIntentIdentity)
    }

    private static func validateIntentBoundGeneration(
        _ directory: URL,
        expectedManifestSHA256: String,
        expectedIdentity: ImmutableDirectoryPublication.Identity
    ) throws -> ValidatedSnapshotGeneration {
        let generation = try validateSnapshotGeneration(
            directory,
            allowedDirectoryModes: [
                preparedDirectoryMode, committedDirectoryMode,
            ],
            expectedDirectoryIdentity: expectedIdentity)
        guard generation.manifestSHA256 == expectedManifestSHA256 else {
            throw SessionError.copyFailed(
                "snapshot generation manifest differs from transaction intent")
        }
        return generation
    }

    private static func taskManifestDataIfPresent(
        _ taskRoot: URL
    ) throws -> Data? {
        let url = taskRoot.appendingPathComponent("input_manifest.json")
        return try readStableCommittedFileIfPresent(
            url, maximumBytes: maximumTaskManifestBytes)?.data
    }

    private static func writeTaskManifest(
        _ data: Data,
        to url: URL,
        taskRoot: URL,
        afterRenameBeforeParentSync: (() throws -> Void)? = nil
    ) throws {
        guard !data.isEmpty, data.count <= maximumTaskManifestBytes,
              url.deletingLastPathComponent().standardizedFileURL
                == taskRoot.standardizedFileURL,
              url.lastPathComponent == "input_manifest.json" else {
            throw SessionError.copyFailed(
                "task snapshot reference payload/path is invalid")
        }
        let openedParent = try openStableDirectoryNoFollow(
            taskRoot, context: "task root for snapshot reference update")
        let parentDescriptor = openedParent.descriptor
        defer { _ = close(parentDescriptor) }
        // Existing authority must already be one stable committed file. A
        // symlink, hardlink or mode-drifted reference is not replaceable.
        let existing = try readStableCommittedFileIfPresent(
            parentDescriptor: parentDescriptor,
            basename: url.lastPathComponent,
            maximumBytes: maximumTaskManifestBytes)
        try faultInjector?(.afterTaskReferenceAuthorityReadBeforeInstall)

        let targetSHA256 = sha256(data)
        let displacedToken = existing.map {
            String($0.identity.device) + "-" + String($0.identity.inode)
        } ?? "none"
        let temporaryUUID = UUID().uuidString.lowercased()
        var temporaryName = taskManifestCreationPrefix + temporaryUUID
        let temporaryDescriptor = openat(
            parentDescriptor,
            temporaryName,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            mode_t(0o600))
        guard temporaryDescriptor >= 0 else {
            throw SessionError.copyFailed(
                "cannot create snapshot reference temporary")
        }
        var temporaryOpen = true
        var renamed = false
        var cleanupExpectedMetadata: stat?
        defer {
            if temporaryOpen { _ = close(temporaryDescriptor) }
            if !renamed, let cleanupExpectedMetadata {
                try? removeIdentityBoundTemporary(
                    parentDescriptor: parentDescriptor,
                    basename: temporaryName,
                    expectedMetadata: cleanupExpectedMetadata,
                    removalPrefix: taskManifestTemporaryRemovalPrefix,
                    conflictPrefix: taskManifestConflictPrefix,
                    context: "failed task-reference temporary")
            }
        }

        var createdMetadata = stat()
        guard fstat(temporaryDescriptor, &createdMetadata) == 0,
              (createdMetadata.st_mode & S_IFMT) == S_IFREG,
              (createdMetadata.st_mode & mode_t(0o777)) == 0o600,
              createdMetadata.st_nlink == 1,
              createdMetadata.st_size == 0 else {
            throw SessionError.copyFailed(
                "snapshot reference creation temporary identity is invalid")
        }
        cleanupExpectedMetadata = createdMetadata
        try faultInjector?(.afterTaskReferenceCreationBeforeIdentityBind)
        let boundTemporaryName = taskManifestTemporaryPrefix
            + identityToken(metadataIdentity(createdMetadata)) + "."
            + displacedToken + "." + targetSHA256 + "."
            + temporaryUUID + taskManifestTemporarySuffix
        guard renameatx_np(
            parentDescriptor, temporaryName,
            parentDescriptor, boundTemporaryName,
            UInt32(RENAME_EXCL)) == 0 else {
            throw SessionError.copyFailed(
                "cannot bind snapshot reference temporary identity")
        }
        temporaryName = boundTemporaryName
        guard fsync(parentDescriptor) == 0 else {
            throw SessionError.copyFailed(
                "cannot sync snapshot reference temporary identity")
        }

        guard writeAll(data, to: temporaryDescriptor),
              fchmod(temporaryDescriptor, committedFileMode) == 0,
              fsync(temporaryDescriptor) == 0 else {
            throw SessionError.copyFailed(
                "cannot persist frozen snapshot reference temporary")
        }
        var temporaryMetadata = stat()
        guard fstat(temporaryDescriptor, &temporaryMetadata) == 0,
              (temporaryMetadata.st_mode & S_IFMT) == S_IFREG,
              (temporaryMetadata.st_mode & mode_t(0o777)) == committedFileMode,
              temporaryMetadata.st_nlink == 1,
              temporaryMetadata.st_size == data.count,
              close(temporaryDescriptor) == 0 else {
            throw SessionError.copyFailed(
                "snapshot reference temporary identity is invalid")
        }
        temporaryOpen = false
        try faultInjector?(.afterTaskReferenceTemporaryFsyncBeforeRename)

        var currentAuthority = stat()
        let authorityLookup = fstatat(
            parentDescriptor,
            url.lastPathComponent,
            &currentAuthority,
            AT_SYMLINK_NOFOLLOW)
        if let existing {
            guard authorityLookup == 0,
                  sameFileIdentity(existing.metadata, currentAuthority) else {
                throw SessionError.copyFailed(
                    "snapshot task reference changed before atomic swap")
            }
        } else {
            guard authorityLookup != 0, errno == ENOENT else {
                throw SessionError.copyFailed(
                    "snapshot task reference appeared before exclusive install")
            }
        }
        try faultInjector?(.afterTaskReferenceAuthorityRecheckBeforeInstall)
        let renameFlags = existing == nil
            ? UInt32(RENAME_EXCL)
            : UInt32(RENAME_SWAP)
        guard renameatx_np(
            parentDescriptor, temporaryName,
            parentDescriptor, url.lastPathComponent,
            renameFlags) == 0 else {
            throw SessionError.copyFailed(
                "cannot atomically install snapshot task reference: "
                    + String(cString: strerror(errno)))
        }
        renamed = true
        try faultInjector?(.afterTaskReferenceRenameBeforePostcheck)
        var installedPathMetadata = stat()
        guard fstatat(
            parentDescriptor,
            url.lastPathComponent,
            &installedPathMetadata,
            AT_SYMLINK_NOFOLLOW) == 0,
              sameCommittedFileObject(
                temporaryMetadata, installedPathMetadata) else {
            throw SessionError.copyFailed(
                "new snapshot task reference identity changed during install")
        }
        if let existing {
            var displacedMetadata = stat()
            let displacedMatches = fstatat(
                parentDescriptor,
                temporaryName,
                &displacedMetadata,
                AT_SYMLINK_NOFOLLOW) == 0
                && sameCommittedFileObject(
                    existing.metadata, displacedMetadata)
            if !displacedMatches {
                if renameatx_np(
                    parentDescriptor, temporaryName,
                    parentDescriptor, url.lastPathComponent,
                    UInt32(RENAME_SWAP)) == 0 {
                    var restoredAuthority = stat()
                    guard fstatat(
                        parentDescriptor,
                        url.lastPathComponent,
                        &restoredAuthority,
                        AT_SYMLINK_NOFOLLOW) == 0,
                          sameCommittedFileObject(
                            displacedMetadata, restoredAuthority),
                          fsync(parentDescriptor) == 0 else {
                        throw SessionError.copyFailed(
                            "cannot verify restored conflicting task authority")
                    }
                    // The temporary once again contains only our new manifest.
                    // Delete it durably; never leave the unrelated authority in
                    // the generic orphan-temp namespace.
                    guard unlinkat(parentDescriptor, temporaryName, 0) == 0,
                          fsync(parentDescriptor) == 0 else {
                        throw SessionError.copyFailed(
                            "cannot remove rejected task-reference temporary")
                    }
                } else {
                    let conflictName = taskManifestConflictPrefix
                        + UUID().uuidString.lowercased()
                    _ = renameatx_np(
                        parentDescriptor, temporaryName,
                        parentDescriptor, conflictName,
                        UInt32(RENAME_EXCL))
                    _ = fsync(parentDescriptor)
                    throw SnapshotTransactionConflict.taskAuthorityDisplaced
                }
                throw SessionError.copyFailed(
                    "atomic snapshot task-reference swap displaced an unrelated file")
            }
        }
        try afterRenameBeforeParentSync?()
        guard fsync(parentDescriptor) == 0 else {
            throw SessionError.copyFailed(
                "cannot sync task root after snapshot reference replacement")
        }
        guard let installed = try readStableCommittedFileIfPresent(
                parentDescriptor: parentDescriptor,
                basename: url.lastPathComponent,
                maximumBytes: maximumTaskManifestBytes),
              installed.data == data,
              installed.identity.device == UInt64(temporaryMetadata.st_dev),
              installed.identity.inode == UInt64(temporaryMetadata.st_ino) else {
            throw SessionError.copyFailed(
                "installed snapshot task reference changed after replacement")
        }
        if let existing {
            var displacedMetadata = stat()
            guard fstatat(
                parentDescriptor,
                temporaryName,
                &displacedMetadata,
                AT_SYMLINK_NOFOLLOW) == 0,
                  sameCommittedFileObject(
                    existing.metadata, displacedMetadata),
                  unlinkat(parentDescriptor, temporaryName, 0) == 0,
                  fsync(parentDescriptor) == 0 else {
                throw SessionError.copyFailed(
                    "cannot durably remove displaced snapshot task reference")
            }
        }
        try requireOpenDirectoryPath(
            descriptor: parentDescriptor,
            url: taskRoot,
            expectedMetadata: openedParent.metadata,
            context: "task root after snapshot reference update")
    }

    private static func clearTaskManifestForRollback(
        taskRoot: URL,
        expectedNewManifestSHA256: String
    ) throws {
        let url = taskRoot.appendingPathComponent("input_manifest.json")
        let openedParent = try openStableDirectoryNoFollow(
            taskRoot, context: "task root for snapshot reference rollback")
        defer { _ = close(openedParent.descriptor) }
        guard let current = try readStableCommittedFileIfPresent(
                parentDescriptor: openedParent.descriptor,
                basename: url.lastPathComponent,
                maximumBytes: maximumTaskManifestBytes) else {
            guard fsync(openedParent.descriptor) == 0 else {
                throw SessionError.copyFailed(
                    "cannot sync absent first-generation snapshot reference")
            }
            return
        }
        guard sha256(current.data) == expectedNewManifestSHA256 else {
            throw SessionError.copyFailed(
                "first-generation rollback found an unrelated task reference")
        }
        var beforeRename = stat()
        guard fstatat(
            openedParent.descriptor,
            url.lastPathComponent,
            &beforeRename,
            AT_SYMLINK_NOFOLLOW) == 0,
              sameFileIdentity(current.metadata, beforeRename) else {
            throw SessionError.copyFailed(
                "first-generation snapshot reference changed before rollback")
        }
        try faultInjector?(.afterTaskReferenceAuthorityRecheckBeforeClear)
        let tombstoneName = taskManifestRemovalPrefix
            + identityToken(current.identity) + "."
            + UUID().uuidString.lowercased()
        guard renameatx_np(
            openedParent.descriptor,
            url.lastPathComponent,
            openedParent.descriptor,
            tombstoneName,
            UInt32(RENAME_EXCL)) == 0 else {
            throw SessionError.copyFailed(
                "cannot atomically clear first-generation snapshot reference")
        }
        try faultInjector?(.afterTaskReferenceClearRenameBeforePostcheck)
        var tombstoneMetadata = stat()
        let tombstoneMatches = fstatat(
            openedParent.descriptor,
            tombstoneName,
            &tombstoneMetadata,
            AT_SYMLINK_NOFOLLOW) == 0
            && sameCommittedFileObject(current.metadata, tombstoneMetadata)
        guard tombstoneMatches else {
            if renameatx_np(
                openedParent.descriptor, tombstoneName,
                openedParent.descriptor, url.lastPathComponent,
                UInt32(RENAME_EXCL)) == 0 {
                var restoredMetadata = stat()
                guard fstatat(
                    openedParent.descriptor,
                    url.lastPathComponent,
                    &restoredMetadata,
                    AT_SYMLINK_NOFOLLOW) == 0,
                      sameCommittedFileObject(
                        tombstoneMetadata, restoredMetadata),
                      fsync(openedParent.descriptor) == 0 else {
                    throw SessionError.copyFailed(
                        "cannot verify restored conflicting task authority")
                }
            } else {
                let conflictName = taskManifestConflictPrefix
                    + UUID().uuidString.lowercased()
                _ = renameatx_np(
                    openedParent.descriptor, tombstoneName,
                    openedParent.descriptor, conflictName,
                    UInt32(RENAME_EXCL))
                _ = fsync(openedParent.descriptor)
            }
            throw SessionError.copyFailed(
                "cleared snapshot reference does not match expected authority")
        }
        guard fsync(openedParent.descriptor) == 0 else {
            throw SessionError.copyFailed(
                "cannot sync cleared snapshot reference")
        }
        guard unlinkat(openedParent.descriptor, tombstoneName, 0) == 0,
              fsync(openedParent.descriptor) == 0 else {
            throw SessionError.copyFailed(
                "cannot durably remove cleared snapshot reference tombstone")
        }
    }

    private static func readStableCommittedFileIfPresent(
        _ url: URL,
        maximumBytes: Int
    ) throws -> (
        data: Data,
        identity: ImmutableDirectoryPublication.Identity,
        metadata: stat
    )? {
        let parent = url.deletingLastPathComponent()
        let openedParent = try openStableDirectoryNoFollow(
            parent, context: "committed transaction file parent")
        defer { _ = close(openedParent.descriptor) }
        let result = try readStableCommittedFileIfPresent(
            parentDescriptor: openedParent.descriptor,
            basename: url.lastPathComponent,
            maximumBytes: maximumBytes)
        try requireOpenDirectoryPath(
            descriptor: openedParent.descriptor,
            url: parent,
            expectedMetadata: openedParent.metadata,
            context: "committed transaction file parent after read")
        return result
    }

    /// Host-test entry for the exact primitive used by task manifests,
    /// snapshot commit markers and transaction intents. Production callers
    /// continue through the private typed wrappers below.
    static func readStableCommittedFileForTests(
        _ url: URL,
        maximumBytes: Int
    ) throws -> Data? {
        return try readStableCommittedFileIfPresent(
            url, maximumBytes: maximumBytes)?.data
    }

    private static func readStableCommittedFileIfPresent(
        parentDescriptor: Int32,
        basename: String,
        maximumBytes: Int
    ) throws -> (
        data: Data,
        identity: ImmutableDirectoryPublication.Identity,
        metadata: stat
    )? {
        var pathBefore = stat()
        guard fstatat(
            parentDescriptor,
            basename,
            &pathBefore,
            AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return nil }
            throw SessionError.copyFailed(
                "cannot inspect committed transaction file")
        }
        guard (pathBefore.st_mode & S_IFMT) == S_IFREG,
              (pathBefore.st_mode & mode_t(0o777)) == committedFileMode,
              pathBefore.st_nlink == 1,
              pathBefore.st_size > 0,
              pathBefore.st_size <= maximumBytes else {
            throw SessionError.copyFailed(
                "committed transaction file type/mode/size is invalid: "
                    + basename)
        }
        try faultInjector?(
            .afterCommittedFileAuthorityReadBeforeOpen(basename))
        let descriptor = openat(
            parentDescriptor,
            basename,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw SessionError.copyFailed(
                "cannot open committed transaction file no-follow")
        }
        defer { _ = close(descriptor) }
        var openedBefore = stat()
        guard fstat(descriptor, &openedBefore) == 0 else {
            throw SessionError.copyFailed(
                "cannot inspect opened committed transaction file: "
                    + basename)
        }
        if !sameFileIdentity(pathBefore, openedBefore) {
            let preOpenDifference = fileIdentityDifferenceSummary(
                pathBefore, openedBefore)
            guard sameFileIdentityIgnoringChangeTime(
                    pathBefore, openedBefore),
                  changeTimeDidNotMoveBackward(pathBefore, openedBefore) else {
                throw SessionError.copyFailed(
                    "committed transaction file changed before open: "
                        + basename + " [" + preOpenDifference + "]")
            }

            // Accept only the known iOS/APFS ctime stabilization. The
            // namespace must now point exactly at the descriptor metadata;
            // inode replacement, chmod, hardlink, size or mtime changes still
            // fail closed before a byte is consumed.
            var reboundPath = stat()
            guard fstatat(
                    parentDescriptor,
                    basename,
                    &reboundPath,
                    AT_SYMLINK_NOFOLLOW) == 0,
                  sameFileIdentity(openedBefore, reboundPath) else {
                let reboundDifference = fileIdentityDifferenceSummary(
                    openedBefore, reboundPath)
                throw SessionError.copyFailed(
                    "committed transaction file namespace changed while "
                        + "stabilizing ctime: " + basename + " ["
                        + reboundDifference + "]")
            }
        }
        try faultInjector?(.afterCommittedFileOpenBeforeRead(basename))
        var data = Data()
        data.reserveCapacity(Int(openedBefore.st_size))
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { rawBuffer -> Int in
                guard let base = rawBuffer.baseAddress else { return -1 }
                return Darwin.read(descriptor, base, rawBuffer.count)
            }
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else {
                throw SessionError.copyFailed(
                    "committed transaction file read failed")
            }
            if count == 0 { break }
            guard data.count <= maximumBytes - count else {
                throw SessionError.copyFailed(
                    "committed transaction file grew beyond limit")
            }
            data.append(contentsOf: buffer.prefix(count))
        }
        var openedAfter = stat()
        var pathAfter = stat()
        guard fstat(descriptor, &openedAfter) == 0 else {
            throw SessionError.copyFailed(
                "cannot inspect committed transaction file after read: "
                    + basename)
        }
        guard fstatat(
                parentDescriptor,
                basename,
                &pathAfter,
                AT_SYMLINK_NOFOLLOW) == 0 else {
            throw SessionError.copyFailed(
                "committed transaction file disappeared during read: "
                    + basename)
        }
        guard sameFileIdentity(openedBefore, openedAfter),
              sameFileIdentity(openedBefore, pathAfter),
              data.count == Int(openedBefore.st_size) else {
            let descriptorDifference = fileIdentityDifferenceSummary(
                openedBefore, openedAfter)
            let pathDifference = fileIdentityDifferenceSummary(
                openedBefore, pathAfter)
            let byteDifference = data.count == Int(openedBefore.st_size)
                ? "none" : "size"
            throw SessionError.copyFailed(
                "committed transaction file changed during read: "
                    + basename + " [descriptor=" + descriptorDifference
                    + ";path=" + pathDifference + ";bytes="
                    + byteDifference + "]")
        }
        return (
            data,
            ImmutableDirectoryPublication.Identity(
                device: UInt64(openedBefore.st_dev),
                inode: UInt64(openedBefore.st_ino)),
            openedBefore)
    }

    /// Streams and hashes one immutable artifact through a descriptor opened
    /// relative to the already-bound snapshot root. The pre-open pathname,
    /// opened inode, post-read inode and final pathname must all remain the
    /// same 0444, single-link regular file.
    private static func sha256StableCommittedFile(
        parentDescriptor: Int32,
        basename: String,
        expectedBytes: Int64
    ) throws -> (sha256: String, metadata: stat) {
        guard expectedBytes >= 0 else {
            throw SessionError.copyFailed(
                "committed artifact has a negative expected size")
        }
        var pathBefore = stat()
        guard fstatat(
            parentDescriptor,
            basename,
            &pathBefore,
            AT_SYMLINK_NOFOLLOW) == 0,
              (pathBefore.st_mode & S_IFMT) == S_IFREG,
              (pathBefore.st_mode & mode_t(0o777)) == committedFileMode,
              pathBefore.st_nlink == 1,
              Int64(pathBefore.st_size) == expectedBytes else {
            throw SessionError.copyFailed(
                "committed artifact type/mode/link/size is invalid: \(basename)")
        }
        try faultInjector?(.afterArtifactAuthorityReadBeforeOpen(basename))
        let descriptor = openat(
            parentDescriptor,
            basename,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw SessionError.copyFailed(
                "cannot open committed artifact no-follow: \(basename)")
        }
        defer { _ = close(descriptor) }
        var openedBefore = stat()
        guard fstat(descriptor, &openedBefore) == 0,
              sameFileIdentity(pathBefore, openedBefore) else {
            throw SessionError.copyFailed(
                "committed artifact changed before open: \(basename)")
        }

        var hasher = SHA256()
        var totalBytes: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: copyChunkBytes)
        while true {
            let count = buffer.withUnsafeMutableBytes { rawBuffer -> Int in
                guard let base = rawBuffer.baseAddress else { return -1 }
                return Darwin.read(descriptor, base, rawBuffer.count)
            }
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else {
                throw SessionError.copyFailed(
                    "committed artifact read failed: \(basename)")
            }
            if count == 0 { break }
            guard totalBytes <= expectedBytes - Int64(count) else {
                throw SessionError.copyFailed(
                    "committed artifact grew during hash: \(basename)")
            }
            let chunk = buffer.withUnsafeBytes { rawBuffer -> Data in
                Data(bytes: rawBuffer.baseAddress!, count: count)
            }
            hasher.update(data: chunk)
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
              sameFileIdentity(openedBefore, openedAfter),
              sameFileIdentity(openedBefore, pathAfter) else {
            throw SessionError.copyFailed(
                "committed artifact changed during hash: \(basename)")
        }
        let digest = hasher.finalize().map {
            String(format: "%02x", $0)
        }.joined()
        return (digest, openedBefore)
    }

    private static func openStableDirectoryNoFollow(
        _ url: URL,
        context: String
    ) throws -> (descriptor: Int32, metadata: stat) {
        var pathMetadata = stat()
        guard lstat(url.path, &pathMetadata) == 0,
              (pathMetadata.st_mode & S_IFMT) == S_IFDIR else {
            throw SessionError.copyFailed(
                "\(context) is not a real directory")
        }
        let descriptor = open(
            url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw SessionError.copyFailed(
                "cannot open \(context) without following links")
        }
        var openedMetadata = stat()
        guard fstat(descriptor, &openedMetadata) == 0,
              sameFileIdentity(pathMetadata, openedMetadata) else {
            _ = close(descriptor)
            throw SessionError.copyFailed(
                "\(context) changed while opening")
        }
        return (descriptor, openedMetadata)
    }

    private static func requireOpenDirectoryPath(
        descriptor: Int32,
        url: URL,
        expectedMetadata: stat,
        context: String
    ) throws {
        var descriptorMetadata = stat()
        var pathMetadata = stat()
        guard fstat(descriptor, &descriptorMetadata) == 0,
              lstat(url.path, &pathMetadata) == 0,
              sameDirectoryIdentity(expectedMetadata, descriptorMetadata),
              sameDirectoryIdentity(expectedMetadata, pathMetadata) else {
            throw SessionError.copyFailed(
                "\(context) dev/inode/path binding changed")
        }
    }

    private static func requireBoundDirectoryPath(
        descriptor: Int32,
        expectedIdentity: ImmutableDirectoryPublication.Identity?,
        expectedMode: mode_t,
        parentDescriptor: Int32,
        parentURL: URL,
        parentMetadata: stat,
        basename: String,
        context: String
    ) throws {
        try requireOpenDirectoryPath(
            descriptor: parentDescriptor,
            url: parentURL,
            expectedMetadata: parentMetadata,
            context: "\(context) parent")
        var openedMetadata = stat()
        var pathMetadata = stat()
        guard fstat(descriptor, &openedMetadata) == 0,
              fstatat(
                parentDescriptor,
                basename,
                &pathMetadata,
                AT_SYMLINK_NOFOLLOW) == 0,
              sameDirectoryIdentity(openedMetadata, pathMetadata),
              openedMetadata.st_mode & mode_t(0o777) == expectedMode,
              pathMetadata.st_mode & mode_t(0o777) == expectedMode else {
            throw SessionError.copyFailed(
                "\(context) dev/inode/path/mode binding changed")
        }
        if let expectedIdentity {
            guard UInt64(openedMetadata.st_dev) == expectedIdentity.device,
                  UInt64(openedMetadata.st_ino) == expectedIdentity.inode else {
                throw SessionError.copyFailed(
                    "\(context) differs from the transaction identity")
            }
        }
    }

    private static func directoryEntryNames(
        atBoundDirectoryDescriptor descriptor: Int32,
        context: String,
        maximumEntries: Int
    ) throws -> [String] {
        let enumerationDescriptor = openat(
            descriptor, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard enumerationDescriptor >= 0 else {
            throw SessionError.copyFailed(
                "cannot duplicate \(context) for enumeration")
        }
        guard let stream = fdopendir(enumerationDescriptor) else {
            _ = close(enumerationDescriptor)
            throw SessionError.copyFailed(
                "cannot enumerate \(context)")
        }
        defer { _ = closedir(stream) }
        var names: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else {
                    throw SessionError.copyFailed(
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
                throw SessionError.copyFailed(
                    "\(context) contains a non-UTF-8 name")
            }
            if name == "." || name == ".." { continue }
            guard !name.isEmpty, !name.contains("/") else {
                throw SessionError.copyFailed(
                    "\(context) contains an unsafe name")
            }
            guard names.count < maximumEntries else {
                throw SessionError.copyFailed(
                    "\(context) entry limit exceeded")
            }
            names.append(name)
        }
        return names.sorted()
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) -> Bool {
        var offset = 0
        return data.withUnsafeBytes { rawBuffer -> Bool in
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
    }

    private static func writeSnapshotCommitIntent(
        _ intent: SnapshotCommitIntent,
        to url: URL
    ) throws -> ImmutableDirectoryPublication.Identity {
        let null = NSNull()
        let payload: [String: Any] = [
            "format": "MarketScannerSessionSnapshotTransaction",
            "version": 1,
            "task_id": intent.taskID,
            "new_manifest_sha256": intent.newManifestSHA256,
            "new_device": String(intent.newIdentity.device),
            "new_inode": String(intent.newIdentity.inode),
            "prior_manifest_sha256": intent.priorManifestSHA256 ?? null,
            "prior_device": intent.priorIdentity.map {
                String($0.device)
            } ?? null,
            "prior_inode": intent.priorIdentity.map {
                String($0.inode)
            } ?? null,
        ]
        let data = try CanonicalJSONEncoder.encode(payload)
        guard !data.isEmpty,
              data.count <= maximumSnapshotTransactionIntentBytes else {
            throw SessionError.copyFailed(
                "snapshot transaction intent exceeds size limit")
        }
        let parent = url.deletingLastPathComponent()
        let openedParent = try openStableDirectoryNoFollow(
            parent, context: "task root for snapshot transaction intent")
        let parentDescriptor = openedParent.descriptor
        defer { _ = close(parentDescriptor) }
        let temporaryUUID = UUID().uuidString.lowercased()
        var temporaryName = transactionIntentCreationPrefix + temporaryUUID
        let descriptor = openat(
            parentDescriptor,
            temporaryName,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            mode_t(0o600))
        guard descriptor >= 0 else {
            throw SessionError.copyFailed(
                "cannot create snapshot transaction intent temporary")
        }
        var descriptorOpen = true
        var renamed = false
        var cleanupExpectedMetadata: stat?
        defer {
            if descriptorOpen { _ = close(descriptor) }
            if !renamed, let cleanupExpectedMetadata {
                try? removeIdentityBoundTemporary(
                    parentDescriptor: parentDescriptor,
                    basename: temporaryName,
                    expectedMetadata: cleanupExpectedMetadata,
                    removalPrefix: transactionIntentTemporaryRemovalPrefix,
                    conflictPrefix: transactionIntentConflictPrefix,
                    context: "failed snapshot transaction intent temporary")
            }
        }
        var createdMetadata = stat()
        guard fstat(descriptor, &createdMetadata) == 0,
              (createdMetadata.st_mode & S_IFMT) == S_IFREG,
              (createdMetadata.st_mode & mode_t(0o777)) == 0o600,
              createdMetadata.st_nlink == 1,
              createdMetadata.st_size == 0 else {
            throw SessionError.copyFailed(
                "snapshot transaction intent creation identity is invalid")
        }
        cleanupExpectedMetadata = createdMetadata
        try faultInjector?(.afterTransactionIntentCreationBeforeIdentityBind)
        let boundTemporaryName = transactionIntentTemporaryPrefix
            + identityToken(metadataIdentity(createdMetadata)) + "."
            + temporaryUUID
        guard renameatx_np(
            parentDescriptor, temporaryName,
            parentDescriptor, boundTemporaryName,
            UInt32(RENAME_EXCL)) == 0 else {
            throw SessionError.copyFailed(
                "cannot bind snapshot transaction intent temporary identity")
        }
        temporaryName = boundTemporaryName
        guard fsync(parentDescriptor) == 0 else {
            throw SessionError.copyFailed(
                "cannot sync snapshot transaction intent temporary identity")
        }
        guard writeAll(data, to: descriptor),
              fchmod(descriptor, committedFileMode) == 0,
              fsync(descriptor) == 0,
              close(descriptor) == 0 else {
            throw SessionError.copyFailed(
                "cannot persist frozen snapshot transaction intent temporary")
        }
        descriptorOpen = false
        try faultInjector?(.afterTransactionIntentTemporaryFsyncBeforeRename)
        guard renameatx_np(
            parentDescriptor, temporaryName,
            parentDescriptor, url.lastPathComponent,
            UInt32(RENAME_EXCL)) == 0 else {
            throw SessionError.copyFailed(
                "cannot publish snapshot transaction intent exclusively: "
                    + String(cString: strerror(errno)))
        }
        renamed = true
        try faultInjector?(.afterTransactionIntentRenameBeforeParentFsync)
        guard fsync(parentDescriptor) == 0 else {
            throw SessionError.copyFailed(
                "cannot sync task root after snapshot intent rename")
        }
        let installed = try readSnapshotCommitIntent(url)
        guard installed.intent == intent,
              installed.fileIdentity == metadataIdentity(createdMetadata) else {
            throw SessionError.copyFailed(
                "installed snapshot transaction intent identity mismatch")
        }
        try requireOpenDirectoryPath(
            descriptor: parentDescriptor,
            url: parent,
            expectedMetadata: openedParent.metadata,
            context: "task root after snapshot transaction intent install")
        return installed.fileIdentity
    }

    private static func readSnapshotCommitIntent(
        _ url: URL
    ) throws -> ReadSnapshotCommitIntent {
        guard let stable = try readStableCommittedFileIfPresent(
                url,
                maximumBytes: maximumSnapshotTransactionIntentBytes) else {
            throw SessionError.copyFailed(
                "snapshot transaction intent disappeared during recovery")
        }
        let data = stable.data
        guard let object = try? StrictJSONDocumentParser.object(
                from: data,
                limits: StrictJSONDocumentLimits(
                    maximumBytes: maximumSnapshotTransactionIntentBytes))
                as? [String: Any],
              Set(object.keys) == Set([
                "format", "version", "task_id",
                "new_manifest_sha256", "new_device", "new_inode",
                "prior_manifest_sha256", "prior_device", "prior_inode",
              ]),
              object["format"] as? String ==
                "MarketScannerSessionSnapshotTransaction",
              strictInteger(object["version"]) == 1,
              let taskID = nonEmptyString(object["task_id"]),
              let newManifestSHA = object["new_manifest_sha256"] as? String,
              isSHA256(newManifestSHA),
              let newDeviceText = object["new_device"] as? String,
              let newInodeText = object["new_inode"] as? String,
              isCanonicalUnsignedDecimal(newDeviceText),
              isCanonicalUnsignedDecimal(newInodeText),
              let newDevice = UInt64(newDeviceText),
              let newInode = UInt64(newInodeText) else {
            throw SessionError.copyFailed(
                "snapshot transaction intent schema invalid")
        }

        let priorManifestValue = object["prior_manifest_sha256"]
        let priorDeviceValue = object["prior_device"]
        let priorInodeValue = object["prior_inode"]
        let priorManifest: String?
        let priorIdentity: ImmutableDirectoryPublication.Identity?
        if priorManifestValue is NSNull,
           priorDeviceValue is NSNull,
           priorInodeValue is NSNull {
            priorManifest = nil
            priorIdentity = nil
        } else {
            guard let manifest = priorManifestValue as? String,
                  isSHA256(manifest),
                  let deviceText = priorDeviceValue as? String,
                  let inodeText = priorInodeValue as? String,
                  isCanonicalUnsignedDecimal(deviceText),
                  isCanonicalUnsignedDecimal(inodeText),
                  let device = UInt64(deviceText),
                  let inode = UInt64(inodeText) else {
                throw SessionError.copyFailed(
                    "snapshot transaction prior identity invalid")
            }
            priorManifest = manifest
            priorIdentity = ImmutableDirectoryPublication.Identity(
                device: device, inode: inode)
        }

        let normalized: [String: Any] = [
            "format": "MarketScannerSessionSnapshotTransaction",
            "version": 1,
            "task_id": taskID,
            "new_manifest_sha256": newManifestSHA,
            "new_device": newDeviceText,
            "new_inode": newInodeText,
            "prior_manifest_sha256": priorManifest ?? NSNull(),
            "prior_device": priorIdentity.map {
                String($0.device)
            } ?? NSNull(),
            "prior_inode": priorIdentity.map {
                String($0.inode)
            } ?? NSNull(),
        ]
        guard (try? CanonicalJSONEncoder.encode(normalized)) == data else {
            throw SessionError.copyFailed(
                "snapshot transaction intent is not canonical")
        }
        return ReadSnapshotCommitIntent(
            intent: SnapshotCommitIntent(
                taskID: taskID,
                newManifestSHA256: newManifestSHA,
                newIdentity: ImmutableDirectoryPublication.Identity(
                    device: newDevice, inode: newInode),
                priorManifestSHA256: priorManifest,
                priorIdentity: priorIdentity),
            fileIdentity: stable.identity,
            data: data)
    }

    private static func removeSnapshotCommitIntent(
        _ url: URL,
        expectedIntent: SnapshotCommitIntent,
        expectedIdentity: ImmutableDirectoryPublication.Identity
    ) throws {
        let record = try readSnapshotCommitIntent(url)
        guard record.intent == expectedIntent,
              record.fileIdentity == expectedIdentity else {
            throw SessionError.copyFailed(
                "snapshot transaction intent authority changed before removal")
        }
        let parent = url.deletingLastPathComponent()
        let openedParent = try openStableDirectoryNoFollow(
            parent, context: "snapshot transaction intent parent")
        defer { _ = close(openedParent.descriptor) }
        guard let stable = try readStableCommittedFileIfPresent(
                parentDescriptor: openedParent.descriptor,
                basename: url.lastPathComponent,
                maximumBytes: maximumSnapshotTransactionIntentBytes),
              stable.identity == expectedIdentity,
              stable.data == record.data else {
            throw SessionError.copyFailed(
                "snapshot transaction intent changed before unlink")
        }
        var beforeRemoval = stat()
        guard fstatat(
            openedParent.descriptor,
            url.lastPathComponent,
            &beforeRemoval,
            AT_SYMLINK_NOFOLLOW) == 0,
              sameFileIdentity(stable.metadata, beforeRemoval) else {
            throw SessionError.copyFailed(
                "snapshot transaction intent changed before removal")
        }
        try faultInjector?(.afterTransactionIntentAuthorityRecheckBeforeRemoval)
        let tombstoneName = transactionIntentRemovalPrefix
            + identityToken(expectedIdentity) + "."
            + UUID().uuidString.lowercased()
        guard renameatx_np(
            openedParent.descriptor,
            url.lastPathComponent,
            openedParent.descriptor,
            tombstoneName,
            UInt32(RENAME_EXCL)) == 0 else {
            throw SessionError.copyFailed(
                "cannot atomically detach snapshot transaction intent")
        }
        try faultInjector?(.afterTransactionIntentRemovalRenameBeforePostcheck)
        var tombstoneMetadata = stat()
        let tombstoneMatches = fstatat(
            openedParent.descriptor,
            tombstoneName,
            &tombstoneMetadata,
            AT_SYMLINK_NOFOLLOW) == 0
            && sameCommittedFileObject(stable.metadata, tombstoneMetadata)
        guard tombstoneMatches else {
            if renameatx_np(
                openedParent.descriptor, tombstoneName,
                openedParent.descriptor, url.lastPathComponent,
                UInt32(RENAME_EXCL)) == 0 {
                var restoredMetadata = stat()
                guard fstatat(
                    openedParent.descriptor,
                    url.lastPathComponent,
                    &restoredMetadata,
                    AT_SYMLINK_NOFOLLOW) == 0,
                      sameCommittedFileObject(
                        tombstoneMetadata, restoredMetadata),
                      fsync(openedParent.descriptor) == 0 else {
                    throw SessionError.copyFailed(
                        "cannot verify restored conflicting transaction intent")
                }
            } else {
                let conflictName = transactionIntentConflictPrefix
                    + UUID().uuidString.lowercased()
                _ = renameatx_np(
                    openedParent.descriptor, tombstoneName,
                    openedParent.descriptor, conflictName,
                    UInt32(RENAME_EXCL))
                _ = fsync(openedParent.descriptor)
            }
            throw SessionError.copyFailed(
                "detached snapshot transaction intent is not the expected inode")
        }
        guard fsync(openedParent.descriptor) == 0 else {
            throw SessionError.copyFailed(
                "cannot sync detached snapshot transaction intent")
        }
        guard unlinkat(openedParent.descriptor, tombstoneName, 0) == 0,
              fsync(openedParent.descriptor) == 0 else {
            throw SessionError.copyFailed(
                "cannot durably remove snapshot transaction intent tombstone")
        }
        try requireOpenDirectoryPath(
            descriptor: openedParent.descriptor,
            url: parent,
            expectedMetadata: openedParent.metadata,
            context: "snapshot transaction intent parent after removal")
    }

    private static func isCanonicalUnsignedDecimal(_ value: String) -> Bool {
        guard !value.isEmpty,
              value.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else {
            return false
        }
        return value == "0" || !value.hasPrefix("0")
    }

    /// Upgrade-safe rollback check for a pre-v3 committed generation. It is
    /// never sufficient for resume; it only proves that the backup's
    /// manifest bytes are the task's still-authoritative pre-commit
    /// reference, allowing the atomic rename to be undone after a crash.
    private static func snapshotMatchesTaskReferenceLoosely(
        _ directory: URL,
        taskRoot: URL
    ) -> Bool {
        var directoryStat = stat()
        guard lstat(directory.path, &directoryStat) == 0,
              (directoryStat.st_mode & S_IFMT) == S_IFDIR else {
            return false
        }
        let snapshotManifest = directory.appendingPathComponent(
            "input_manifest.json")
        let taskManifest = taskRoot.appendingPathComponent(
            "input_manifest.json")
        guard let snapshotData = try? readStableCommittedFileIfPresent(
                snapshotManifest,
                maximumBytes: maximumTaskManifestBytes)?.data,
              let taskData = try? readStableCommittedFileIfPresent(
                taskManifest,
                maximumBytes: maximumTaskManifestBytes)?.data else {
            return false
        }
        return snapshotData == taskData
    }

    // MARK: - Disk budget (§8.6)

    private static func checkDiskBudget(neededBytes: Int64, at url: URL) throws {
        // `volumeAvailableCapacityForImportantUsage` is the preferred iOS
        // value, but Foundation may report zero for otherwise healthy local
        // volumes (notably host-test and restricted execution environments).
        // Cross-check it with the filesystem free-byte counter and use the
        // lowest positive value. A genuine zero/unknown result from both
        // sources still fails closed.
        var positiveCapacityCandidates: [Int64] = []
        if let values = try? url.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let importantCapacity = values.volumeAvailableCapacityForImportantUsage,
           importantCapacity > 0 {
            positiveCapacityCandidates.append(importantCapacity)
        }
        if let attributes = try? FileManager.default.attributesOfFileSystem(
            forPath: url.path),
           let freeSize = (attributes[.systemFreeSize] as? NSNumber)?.int64Value,
           freeSize > 0 {
            positiveCapacityCandidates.append(freeSize)
        }
        guard let available = positiveCapacityCandidates.min() else {
            throw SessionError.insufficientDisk(
                "cannot determine positive available capacity")
        }
        guard neededBytes >= 0,
              neededBytes <= Int64.max - safetyReserveBytes else {
            throw SessionError.insufficientDisk(
                "required byte count overflow")
        }
        let required = neededBytes + safetyReserveBytes
        if available < required {
            throw SessionError.insufficientDisk(
                "available \(available) bytes < required \(required) bytes")
        }
    }

    // MARK: - POSIX streaming copy (§8.3)

    /// Copies one file with O_NOFOLLOW source protection, incremental
    /// SHA-256, fsync and pre/post identity verification. Returns the
    /// SHA-256 of the copied bytes (verified twice).
    private static func stableStreamingCopy(
        source: URL,
        destination: URL,
        duringCopy: (() throws -> Void)? = nil
    ) throws -> String {
        let sourceFD = open(source.path, O_RDONLY | O_NOFOLLOW)
        guard sourceFD >= 0 else {
            throw SessionError.copyFailed("cannot open source \(source.lastPathComponent)")
        }
        defer { close(sourceFD) }
        var preStat = stat()
        guard fstat(sourceFD, &preStat) == 0 else {
            throw SessionError.copyFailed("cannot fstat source \(source.lastPathComponent)")
        }
        // Regular file policy (V1R5 §9.2): symlinks are already blocked
        // by O_NOFOLLOW; hard links (nlink > 1) are now REJECTED too —
        // an external writer can mutate the shared inode and change the
        // snapshot's file identity after the copy.
        guard (preStat.st_mode & S_IFMT) == S_IFREG else {
            throw SessionError.copyFailed("source is not a regular file: \(source.lastPathComponent)")
        }
        guard preStat.st_nlink == 1 else {
            throw SessionError.copyFailed(
                "source has \(preStat.st_nlink) hard links: \(source.lastPathComponent)")
        }

        let destFD = open(
            destination.path,
            O_CREAT | O_EXCL | O_WRONLY,
            S_IRUSR | S_IWUSR)
        guard destFD >= 0 else {
            throw SessionError.copyFailed("cannot create destination \(destination.lastPathComponent)")
        }

        var hasher = SHA256()
        var totalWritten: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: copyChunkBytes)
        var copyError: SessionError?
        while true {
            do {
                try duringCopy?()
            } catch {
                copyError = SessionError.copyFailed(
                    "generation guard failed while copying "
                    + source.lastPathComponent + ": "
                    + error.localizedDescription)
                break
            }
            let bytesRead = buffer.withUnsafeMutableBytes { rawBuffer -> Int in
                guard let baseAddress = rawBuffer.baseAddress else { return -1 }
                return read(sourceFD, baseAddress, copyChunkBytes)
            }
            if bytesRead < 0 {
                if errno == EINTR { continue }
                copyError = SessionError.copyFailed("read failed on \(source.lastPathComponent)")
                break
            }
            if bytesRead == 0 {
                break
            }
            let chunk = buffer.withUnsafeBytes { rawBuffer -> Data in
                return Data(bytes: rawBuffer.baseAddress!, count: bytesRead)
            }
            hasher.update(data: chunk)
            var written = 0
            while written < bytesRead {
                let result = buffer.withUnsafeBytes { rawBuffer -> Int in
                    guard let baseAddress = rawBuffer.baseAddress else {
                        return -1
                    }
                    return write(
                        destFD,
                        baseAddress.advanced(by: written),
                        bytesRead - written)
                }
                if result < 0 && errno == EINTR { continue }
                if result <= 0 {
                    copyError = SessionError.copyFailed(
                        "write failed on \(destination.lastPathComponent)")
                    break
                }
                written += result
            }
            if copyError != nil { break }
            totalWritten += Int64(bytesRead)
            do {
                try duringCopy?()
            } catch {
                copyError = SessionError.copyFailed(
                    "generation guard failed while copying "
                    + source.lastPathComponent + ": "
                    + error.localizedDescription)
                break
            }
        }
        if copyError == nil && fsync(destFD) != 0 {
            copyError = SessionError.copyFailed("fsync failed on \(destination.lastPathComponent)")
        }
        close(destFD)
        if let copyError = copyError {
            try? FileManager.default.removeItem(at: destination)
            throw copyError
        }

        // Post-copy: the source identity must be unchanged (V1R5 §9.2
        // full identity: dev/ino/size/nlink/mtime_ns/ctime_ns).
        var postStat = stat()
        guard fstat(sourceFD, &postStat) == 0 else {
            throw SessionError.copyFailed("cannot re-fstat source \(source.lastPathComponent)")
        }
        guard postStat.st_dev == preStat.st_dev,
              postStat.st_ino == preStat.st_ino,
              postStat.st_mode == preStat.st_mode,
              postStat.st_nlink == preStat.st_nlink,
              postStat.st_size == preStat.st_size,
              postStat.st_mtimespec.tv_sec == preStat.st_mtimespec.tv_sec,
              postStat.st_mtimespec.tv_nsec == preStat.st_mtimespec.tv_nsec,
              postStat.st_ctimespec.tv_sec == preStat.st_ctimespec.tv_sec,
              postStat.st_ctimespec.tv_nsec == preStat.st_ctimespec.tv_nsec
        else {
            try? FileManager.default.removeItem(at: destination)
            throw SessionError.copyFailed("source mutated during copy: \(source.lastPathComponent)")
        }
        guard totalWritten == Int64(preStat.st_size) else {
            try? FileManager.default.removeItem(at: destination)
            throw SessionError.copyFailed("copied size mismatch on \(source.lastPathComponent)")
        }

        // Destination reopen + second SHA (§8.3).
        let secondSHA = try CanonicalSourceHasher.sha256File(destination)
        let firstSHA = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard firstSHA == secondSHA else {
            try? FileManager.default.removeItem(at: destination)
            throw SessionError.copyFailed("sha mismatch after reopen: \(destination.lastPathComponent)")
        }
        // Make the snapshot artifact read-only.
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: committedFileMode)],
            ofItemAtPath: destination.path)
        try fsyncURL(destination)
        return firstSHA
    }

    // MARK: - DB validation (§8.5)

    private static func validateSnapshotDatabase(_ url: URL) throws {
        let descriptor = open(
            url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw SessionError.dbIntegrity(
                "cannot open snapshot DB no-follow")
        }
        defer { _ = close(descriptor) }
        var openedBefore = stat()
        var pathBefore = stat()
        guard fstat(descriptor, &openedBefore) == 0,
              lstat(url.path, &pathBefore) == 0,
              (openedBefore.st_mode & S_IFMT) == S_IFREG,
              openedBefore.st_nlink == 1,
              sameFileIdentity(openedBefore, pathBefore) else {
            throw SessionError.dbIntegrity(
                "snapshot DB changed while opening for validation")
        }
        // Percent-encode the path so '%', '#', '?' in file names cannot
        // inject URI parameters/fragments (mirrors the C++ core's
        // uriEncodePath hardening).
        try validateSnapshotDatabase(uri: readOnlySQLiteURI(for: url))
        var openedAfter = stat()
        var pathAfter = stat()
        guard fstat(descriptor, &openedAfter) == 0,
              lstat(url.path, &pathAfter) == 0,
              sameFileIdentity(openedBefore, openedAfter),
              sameFileIdentity(openedBefore, pathAfter) else {
            throw SessionError.dbIntegrity(
                "snapshot DB changed during path validation")
        }
        rememberDatabaseValidation(openedBefore)
    }

    /// Opens the committed database relative to the bound snapshot root and
    /// validates the exact no-follow descriptor. macOS can duplicate that
    /// descriptor through `/dev/fd`; iOS app sandboxes do not guarantee that
    /// namespace is openable by SQLite. On iOS, the bytes are therefore copied
    /// from the already-bound descriptor into a private 0700/0400 temporary
    /// validation directory, checked through a normal immutable SQLite URI,
    /// then destroyed. The source descriptor and its parent pathname are
    /// revalidated before and after either route.
    private static func validateSnapshotDatabase(
        parentDescriptor: Int32,
        databaseName: String,
        expectedMetadata: stat
    ) throws {
        let descriptor = openat(
            parentDescriptor,
            databaseName,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw SessionError.dbIntegrity(
                "cannot open committed snapshot DB no-follow")
        }
        defer { _ = close(descriptor) }
        var openedBefore = stat()
        guard fstat(descriptor, &openedBefore) == 0,
              (openedBefore.st_mode & S_IFMT) == S_IFREG,
              openedBefore.st_nlink == 1,
              sameFileIdentity(expectedMetadata, openedBefore) else {
            throw SessionError.dbIntegrity(
                "committed snapshot DB changed before validation")
        }

        let mayUseCachedValidation =
            !forcePrivateDatabaseValidationCopyForTests
            && hasRememberedDatabaseValidation(openedBefore)
        if !mayUseCachedValidation {
            var descriptorRouteSucceeded = false
            if !forcePrivateDatabaseValidationCopyForTests {
                do {
                    try validateSnapshotDatabase(
                        uri: "file:/dev/fd/\(descriptor)?mode=ro&immutable=1")
                    descriptorRouteSucceeded = true
                } catch let error as SessionError {
                    // Expected on iOS: its sandboxed SQLite VFS may reject
                    // `/dev/fd/<n>`. The descriptor-bound private-copy path
                    // below retains the same fail-closed file-identity gates.
                    guard case .dbIntegrity(let detail) = error,
                          detail == "cannot open snapshot DB read-only" else {
                        throw error
                    }
                } catch {
                    throw error
                }
            }
            if !descriptorRouteSucceeded {
                try validateSnapshotDatabaseThroughPrivateCopy(
                    sourceDescriptor: descriptor,
                    sourceMetadata: openedBefore)
            }
        }
        var openedAfter = stat()
        var pathAfter = stat()
        guard fstat(descriptor, &openedAfter) == 0,
              fstatat(
                parentDescriptor,
                databaseName,
                &pathAfter,
                AT_SYMLINK_NOFOLLOW) == 0,
              sameFileIdentity(openedBefore, openedAfter),
              sameFileIdentity(openedBefore, pathAfter) else {
            throw SessionError.dbIntegrity(
                "committed snapshot DB changed during validation")
        }
        rememberDatabaseValidation(openedAfter)
    }

    private static func validateSnapshotDatabaseThroughPrivateCopy(
        sourceDescriptor: Int32,
        sourceMetadata: stat
    ) throws {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory
        try checkDiskBudget(
            neededBytes: Int64(sourceMetadata.st_size),
            at: temporaryRoot)
        let directoryURL = temporaryRoot.appendingPathComponent(
            ".marketscanner-db-validation-"
                + UUID().uuidString.lowercased(),
            isDirectory: true)
        guard mkdir(directoryURL.path, mode_t(0o700)) == 0 else {
            throw SessionError.dbIntegrity(
                "cannot create private snapshot DB validation directory")
        }

        var directoryDescriptor: Int32 = -1
        var directoryMetadata = stat()
        guard lstat(directoryURL.path, &directoryMetadata) == 0,
              (directoryMetadata.st_mode & S_IFMT) == S_IFDIR,
              directoryMetadata.st_mode & mode_t(0o777) == 0o700 else {
            _ = rmdir(directoryURL.path)
            throw SessionError.dbIntegrity(
                "private snapshot DB validation directory identity invalid")
        }
        let validationName = "snapshot-validation.db"
        var validationFileCreated = false
        defer {
            if directoryDescriptor >= 0 {
                _ = fchmod(directoryDescriptor, mode_t(0o700))
                if validationFileCreated {
                    _ = unlinkat(directoryDescriptor, validationName, 0)
                }
                _ = close(directoryDescriptor)
            }
            var currentDirectory = stat()
            if lstat(directoryURL.path, &currentDirectory) == 0,
               sameDirectoryIdentity(directoryMetadata, currentDirectory) {
                _ = rmdir(directoryURL.path)
            }
        }

        let openedDirectory = try openStableDirectoryNoFollow(
            directoryURL,
            context: "private snapshot DB validation directory")
        directoryDescriptor = openedDirectory.descriptor
        guard sameDirectoryIdentity(
                directoryMetadata, openedDirectory.metadata),
              openedDirectory.metadata.st_mode & mode_t(0o777) == 0o700 else {
            throw SessionError.dbIntegrity(
                "private snapshot DB validation directory mode invalid")
        }

        let destinationDescriptor = openat(
            directoryDescriptor,
            validationName,
            O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW,
            mode_t(0o600))
        guard destinationDescriptor >= 0 else {
            throw SessionError.dbIntegrity(
                "cannot create private snapshot DB validation copy")
        }
        validationFileCreated = true
        var destinationOpen = true
        defer {
            if destinationOpen { _ = close(destinationDescriptor) }
        }

        guard lseek(sourceDescriptor, 0, SEEK_SET) == 0 else {
            throw SessionError.dbIntegrity(
                "cannot rewind committed snapshot DB for validation")
        }
        var totalBytes: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: copyChunkBytes)
        while true {
            let bytesRead = buffer.withUnsafeMutableBytes { rawBuffer -> Int in
                guard let baseAddress = rawBuffer.baseAddress else { return -1 }
                return read(sourceDescriptor, baseAddress, rawBuffer.count)
            }
            if bytesRead < 0 {
                if errno == EINTR { continue }
                throw SessionError.dbIntegrity(
                    "cannot read committed snapshot DB validation bytes")
            }
            if bytesRead == 0 { break }
            guard totalBytes <= Int64.max - Int64(bytesRead) else {
                throw SessionError.dbIntegrity(
                    "snapshot DB validation copy size overflow")
            }
            totalBytes += Int64(bytesRead)
            guard totalBytes <= Int64(sourceMetadata.st_size) else {
                throw SessionError.dbIntegrity(
                    "snapshot DB grew during validation copy")
            }
            var written = 0
            while written < bytesRead {
                let count = buffer.withUnsafeBytes { rawBuffer -> Int in
                    guard let baseAddress = rawBuffer.baseAddress else {
                        return -1
                    }
                    return write(
                        destinationDescriptor,
                        baseAddress.advanced(by: written),
                        bytesRead - written)
                }
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else {
                    throw SessionError.dbIntegrity(
                        "cannot write private snapshot DB validation copy")
                }
                written += count
            }
        }
        guard totalBytes == Int64(sourceMetadata.st_size),
              fsync(destinationDescriptor) == 0,
              fchmod(destinationDescriptor, mode_t(0o400)) == 0,
              fsync(destinationDescriptor) == 0 else {
            throw SessionError.dbIntegrity(
                "private snapshot DB validation copy is incomplete")
        }
        var destinationMetadata = stat()
        guard fstat(destinationDescriptor, &destinationMetadata) == 0,
              (destinationMetadata.st_mode & S_IFMT) == S_IFREG,
              destinationMetadata.st_nlink == 1,
              destinationMetadata.st_size == sourceMetadata.st_size,
              destinationMetadata.st_mode & mode_t(0o777) == 0o400,
              close(destinationDescriptor) == 0 else {
            throw SessionError.dbIntegrity(
                "private snapshot DB validation copy identity invalid")
        }
        destinationOpen = false

        var sourceAfterCopy = stat()
        guard fstat(sourceDescriptor, &sourceAfterCopy) == 0,
              sameFileIdentity(sourceMetadata, sourceAfterCopy),
              fchmod(directoryDescriptor, mode_t(0o500)) == 0,
              fsync(directoryDescriptor) == 0 else {
            throw SessionError.dbIntegrity(
                "committed snapshot DB changed during validation copy")
        }
        try requireOpenDirectoryPath(
            descriptor: directoryDescriptor,
            url: directoryURL,
            expectedMetadata: directoryMetadata,
            context: "private snapshot DB validation directory before SQLite")
        var validationPathMetadata = stat()
        guard fstatat(
                directoryDescriptor,
                validationName,
                &validationPathMetadata,
                AT_SYMLINK_NOFOLLOW) == 0,
              sameFileIdentity(destinationMetadata, validationPathMetadata) else {
            throw SessionError.dbIntegrity(
                "private snapshot DB validation path changed")
        }

        let validationURL = directoryURL.appendingPathComponent(validationName)
        try validateSnapshotDatabase(uri: readOnlySQLiteURI(for: validationURL))

        var validationAfter = stat()
        var sourceAfterValidation = stat()
        guard fstatat(
                directoryDescriptor,
                validationName,
                &validationAfter,
                AT_SYMLINK_NOFOLLOW) == 0,
              sameFileIdentity(destinationMetadata, validationAfter),
              fstat(sourceDescriptor, &sourceAfterValidation) == 0,
              sameFileIdentity(sourceMetadata, sourceAfterValidation) else {
            throw SessionError.dbIntegrity(
                "snapshot DB identity changed during private validation")
        }
        try requireOpenDirectoryPath(
            descriptor: directoryDescriptor,
            url: directoryURL,
            expectedMetadata: directoryMetadata,
            context: "private snapshot DB validation directory after SQLite")
    }

    private static func readOnlySQLiteURI(for url: URL) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~/")
        let encodedPath = url.path.addingPercentEncoding(
            withAllowedCharacters: allowed) ?? url.path
        return "file:\(encodedPath)?mode=ro&immutable=1"
    }

    private static func hasRememberedDatabaseValidation(
        _ metadata: stat
    ) -> Bool {
        let identity = DatabaseValidationIdentity(metadata)
        databaseValidationCacheLock.lock()
        defer { databaseValidationCacheLock.unlock() }
        return databaseValidationCache.contains(identity)
    }

    private static func rememberDatabaseValidation(_ metadata: stat) {
        let identity = DatabaseValidationIdentity(metadata)
        databaseValidationCacheLock.lock()
        defer { databaseValidationCacheLock.unlock() }
        guard databaseValidationCache.insert(identity).inserted else { return }
        databaseValidationCacheOrder.append(identity)
        while databaseValidationCacheOrder.count
                > maximumDatabaseValidationCacheEntries {
            let evicted = databaseValidationCacheOrder.removeFirst()
            databaseValidationCache.remove(evicted)
        }
    }

    private static func validateSnapshotDatabase(uri: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK,
              let database = db
        else {
            if let db = db { sqlite3_close(db) }
            throw SessionError.dbIntegrity("cannot open snapshot DB read-only")
        }
        defer { sqlite3_close(database) }

        // quick_check must yield exactly one "ok" row.
        var check: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA quick_check;", -1, &check, nil) == SQLITE_OK,
              let checkStatement = check
        else {
            throw SessionError.dbIntegrity("cannot prepare quick_check")
        }
        defer { sqlite3_finalize(checkStatement) }
        var rows = 0
        while true {
            let rc = sqlite3_step(checkStatement)
            if rc == SQLITE_ROW {
                rows += 1
                let text = sqlite3_column_text(checkStatement, 0)
                let value = text.map { String(cString: $0) } ?? ""
                guard rows == 1, value == "ok" else {
                    throw SessionError.dbIntegrity("quick_check returned '\(value)'")
                }
            } else if rc == SQLITE_DONE {
                break
            } else {
                throw SessionError.dbIntegrity("quick_check step failed")
            }
        }
        guard rows == 1 else {
            throw SessionError.dbIntegrity("quick_check returned no rows")
        }

        // Expected table inventory.
        var tableCheck: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT name FROM sqlite_master WHERE type='table' AND name IN ('Node','Link');",
            -1, &tableCheck, nil) == SQLITE_OK,
            let tableStatement = tableCheck
        else {
            throw SessionError.dbIntegrity("cannot query table inventory")
        }
        defer { sqlite3_finalize(tableStatement) }
        var tables = Set<String>()
        while true {
            let rc = sqlite3_step(tableStatement)
            if rc == SQLITE_ROW {
                if let text = sqlite3_column_text(tableStatement, 0) {
                    tables.insert(String(cString: text))
                }
            } else if rc == SQLITE_DONE {
                break
            } else {
                throw SessionError.dbIntegrity(
                    "table inventory step failed")
            }
        }
        guard tables.contains("Node"), tables.contains("Link") else {
            throw SessionError.dbIntegrity("Node/Link tables missing")
        }
        try validateGraphBlobContracts(database)
    }

    /// Cross-reader parity (RC-B10/E-06): snapshot acceptance applies the
    /// same exact BLOB, finite, identity and endpoint contract as the
    /// Objective-C++ reader and native core. A quick_check-clean DB with a
    /// malformed graph row is still rejected.
    private static func validateGraphBlobContracts(
        _ database: OpaquePointer
    ) throws {
        var nodeStatement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT id, stamp, pose FROM Node ORDER BY id;",
            -1, &nodeStatement, nil) == SQLITE_OK,
              let nodes = nodeStatement else {
            throw SessionError.dbIntegrity(
                "cannot prepare strict Node validation")
        }
        defer { sqlite3_finalize(nodes) }
        var nodeIDs = Set<Int64>()
        var nodeCount: Int64 = 0
        while true {
            let rc = sqlite3_step(nodes)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else {
                throw SessionError.dbIntegrity(
                    "strict Node validation step failed")
            }
            guard nodeCount < maximumGraphNodes else {
                throw SessionError.dbIntegrity(
                    "Node count exceeds product hard maximum")
            }
            let nodeID = sqlite3_column_int64(nodes, 0)
            let stampType = sqlite3_column_type(nodes, 1)
            let stamp = sqlite3_column_double(nodes, 1)
            guard nodeID > 0, nodeIDs.insert(nodeID).inserted,
                  (stampType == SQLITE_FLOAT || stampType == SQLITE_INTEGER),
                  stamp.isFinite else {
                throw SessionError.dbIntegrity(
                    "Node id/stamp contract invalid")
            }
            try validateFiniteFloatBlob(
                statement: nodes, column: 2, count: 12,
                label: "Node.pose")
            nodeCount += 1
        }

        var linkStatement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT from_id, to_id, transform, information_matrix "
                + "FROM Link ORDER BY from_id, to_id;",
            -1, &linkStatement, nil) == SQLITE_OK,
              let links = linkStatement else {
            throw SessionError.dbIntegrity(
                "cannot prepare strict Link validation")
        }
        defer { sqlite3_finalize(links) }
        var linkCount: Int64 = 0
        while true {
            let rc = sqlite3_step(links)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else {
                throw SessionError.dbIntegrity(
                    "strict Link validation step failed")
            }
            guard linkCount < maximumGraphLinks else {
                throw SessionError.dbIntegrity(
                    "Link count exceeds product hard maximum")
            }
            let from = sqlite3_column_int64(links, 0)
            let to = sqlite3_column_int64(links, 1)
            guard nodeIDs.contains(from), nodeIDs.contains(to) else {
                throw SessionError.dbIntegrity(
                    "Link endpoint missing from Node inventory")
            }
            try validateFiniteFloatBlob(
                statement: links, column: 2, count: 12,
                label: "Link.transform")
            try validateFiniteDoubleBlob(
                statement: links, column: 3, count: 36,
                label: "Link.information_matrix")
            linkCount += 1
        }
    }

    private static func validateFiniteFloatBlob(
        statement: OpaquePointer,
        column: Int32,
        count: Int,
        label: String
    ) throws {
        let expectedBytes = count * MemoryLayout<Float>.size
        guard sqlite3_column_type(statement, column) == SQLITE_BLOB,
              sqlite3_column_bytes(statement, column) == Int32(expectedBytes),
              let blob = sqlite3_column_blob(statement, column) else {
            throw SessionError.dbIntegrity(
                "\(label) must be an exact \(expectedBytes)-byte BLOB")
        }
        var values = [Float](repeating: 0, count: count)
        values.withUnsafeMutableBytes { destination in
            memcpy(destination.baseAddress!, blob, expectedBytes)
        }
        guard values.allSatisfy({ $0.isFinite }) else {
            throw SessionError.dbIntegrity(
                "\(label) contains NaN/Inf")
        }
    }

    private static func validateFiniteDoubleBlob(
        statement: OpaquePointer,
        column: Int32,
        count: Int,
        label: String
    ) throws {
        let expectedBytes = count * MemoryLayout<Double>.size
        guard sqlite3_column_type(statement, column) == SQLITE_BLOB,
              sqlite3_column_bytes(statement, column) == Int32(expectedBytes),
              let blob = sqlite3_column_blob(statement, column) else {
            throw SessionError.dbIntegrity(
                "\(label) must be an exact \(expectedBytes)-byte BLOB")
        }
        var values = [Double](repeating: 0, count: count)
        values.withUnsafeMutableBytes { destination in
            memcpy(destination.baseAddress!, blob, expectedBytes)
        }
        guard values.allSatisfy({ $0.isFinite }) else {
            throw SessionError.dbIntegrity(
                "\(label) contains NaN/Inf")
        }
    }

    // MARK: - Durability helpers

    private static func fsyncURL(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else {
            throw SessionError.copyFailed(
                "cannot open for fsync: \(url.lastPathComponent)")
        }
        defer { close(fd) }
        guard fsync(fd) == 0 else {
            throw SessionError.copyFailed(
                "fsync failed: \(url.lastPathComponent)")
        }
    }

    private static func fsyncDirectory(_ directory: URL) throws {
        let fd = open(directory.path, O_RDONLY)
        guard fd >= 0 else {
            throw SessionError.copyFailed(
                "cannot open directory for fsync: \(directory.lastPathComponent)")
        }
        defer { close(fd) }
        guard fsync(fd) == 0 else {
            throw SessionError.copyFailed(
                "directory fsync failed: \(directory.lastPathComponent)")
        }
    }
}

/// Persistent processing-task state machine. Every state change is
/// written atomically to `task.json`; after a crash the app can resume
/// or safely restart the task. An interrupted task is never reported as
/// completed.
enum PersistentTaskCoordinator {
    enum TaskState: String {
        case created
        case snapshotting
        case fastOptimizing = "fast_optimizing"
        case fastQualityCheck = "fast_quality_check"
        case deepReprocessing = "deep_reprocessing"
        case deepOptimizing = "deep_optimizing"
        case buildingTrajectory = "building_trajectory"
        case resamplingTrajectory = "resampling_trajectory"
        case resolvingTags = "resolving_tags"
        case buildingRescanTasks = "building_rescan_tasks"
        case buildingWorkbook = "building_workbook"
        case validatingResult = "validating_result"
        case committingResult = "committing_result"
        case completed
        case rescanRequired = "rescan_required"
        case failed
        case cancelled
        case interrupted

        func allowsTransition(to next: TaskState) -> Bool {
            if self == next { return true }
            if next == .rescanRequired || next == .failed
                || next == .cancelled || next == .interrupted {
                switch self {
                case .completed, .rescanRequired, .failed, .cancelled:
                    return false
                default:
                    return true
                }
            }
            switch self {
            case .created:
                return next == .snapshotting
            case .snapshotting:
                return next == .fastOptimizing
            case .fastOptimizing:
                return next == .fastQualityCheck
            case .fastQualityCheck:
                return next == .deepReprocessing
                    || next == .buildingTrajectory
            case .deepReprocessing:
                return next == .deepOptimizing
            case .deepOptimizing:
                return next == .buildingTrajectory
            case .buildingTrajectory:
                return next == .resamplingTrajectory
                    || next == .resolvingTags
            case .resamplingTrajectory:
                return next == .resolvingTags
            case .resolvingTags:
                return next == .buildingRescanTasks
                    || next == .buildingWorkbook
            case .buildingRescanTasks:
                return next == .buildingWorkbook
            case .buildingWorkbook:
                return next == .validatingResult
            case .validatingResult:
                return next == .committingResult
            case .committingResult:
                return next == .completed
            case .interrupted:
                return next == .snapshotting
            case .completed, .rescanRequired, .failed, .cancelled:
                return false
            }
        }
    }

    struct TaskRecord {
        var taskID: String
        var state: TaskState
        var createdAtUTC: Double
        var updatedAtUTC: Double
        var progress: Double
        var checkpoint: [String: Any]?
        var error: String?
    }

    enum TaskError: Error {
        case cannotWrite(String)
        case invalidRecord
        case invalidTransition(String)
    }

    enum WriteStage: String {
        case beforeTemporaryWrite
        case afterTemporaryFsync
        case afterRename
        case afterParentFsync
    }

    static var writeFaultInjector: ((WriteStage) throws -> Void)?

    static func taskFileURL(taskRoot: URL) -> URL {
        return taskRoot.appendingPathComponent("task.json")
    }

    static func createTask(taskID: String, taskRoot: URL) throws -> TaskRecord {
        guard MobileResultLibrary.isSafeBasename(taskID),
              taskRoot.lastPathComponent == taskID else {
            throw TaskError.invalidRecord
        }
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: taskRoot, withIntermediateDirectories: true)
        let now = Date().timeIntervalSince1970
        let record = TaskRecord(
            taskID: taskID, state: .created,
            createdAtUTC: now, updatedAtUTC: now,
            progress: 0, checkpoint: nil, error: nil)
        try write(record, taskRoot: taskRoot)
        return record
    }

    @discardableResult
    static func updateState(
        _ state: TaskState,
        taskRoot: URL,
        progress: Double? = nil,
        checkpoint: [String: Any]? = nil,
        error: String? = nil,
        clearError: Bool = false,
        allowRecoveryReentry: Bool = false
    ) throws -> TaskRecord {
        var record = try read(taskRoot: taskRoot)
        let recoveryReentry = allowRecoveryReentry
            && state == .snapshotting
            && isResumable(record)
        guard recoveryReentry || record.state.allowsTransition(to: state) else {
            throw TaskError.invalidTransition(
                "\(record.state.rawValue) -> \(state.rawValue)")
        }
        record.state = state
        record.updatedAtUTC = Date().timeIntervalSince1970
        if let progress = progress {
            record.progress = progress
        }
        if let checkpoint = checkpoint {
            record.checkpoint = checkpoint
        }
        if clearError {
            record.error = nil
        } else if let error = error {
            record.error = error
        }
        try write(record, taskRoot: taskRoot)
        return record
    }

    static func read(taskRoot: URL) throws -> TaskRecord {
        let url = taskFileURL(taskRoot: taskRoot)
        let data = try Data(contentsOf: url)
        guard let object = try? StrictJSONDocumentParser.object(
            from: data,
            limits: StrictJSONDocumentLimits(maximumBytes: data.count + 1)) as? [String: Any]
        else {
            throw TaskError.invalidRecord
        }
        guard let taskID = object["task_id"] as? String,
              let rawState = object["state"] as? String,
              let state = TaskState(rawValue: rawState),
              let createdAt = StrictJSONScalar.number(
                object["created_at_utc"]), createdAt.isFinite,
              let updatedAt = StrictJSONScalar.number(
                object["updated_at_utc"]), updatedAt.isFinite,
              let progress = StrictJSONScalar.number(object["progress"]),
              progress.isFinite, progress >= 0, progress <= 1,
              createdAt > 0, updatedAt >= createdAt,
              MobileResultLibrary.isSafeBasename(taskID),
              taskID == taskRoot.lastPathComponent,
              Set(object.keys).isSubset(of: Set([
                "task_id", "state", "created_at_utc", "updated_at_utc",
                "progress", "checkpoint", "error",
              ]))
        else {
            throw TaskError.invalidRecord
        }
        return TaskRecord(
            taskID: taskID, state: state,
            createdAtUTC: createdAt, updatedAtUTC: updatedAt,
            progress: progress,
            checkpoint: object["checkpoint"] as? [String: Any],
            error: object["error"] as? String)
    }

    static func write(_ record: TaskRecord, taskRoot: URL) throws {
        guard MobileResultLibrary.isSafeBasename(record.taskID),
              record.taskID == taskRoot.lastPathComponent,
              record.createdAtUTC.isFinite, record.updatedAtUTC.isFinite,
              record.updatedAtUTC >= record.createdAtUTC,
              record.progress.isFinite,
              record.progress >= 0, record.progress <= 1 else {
            throw TaskError.invalidRecord
        }
        var payload: [String: Any] = [
            "task_id": record.taskID,
            "state": record.state.rawValue,
            "created_at_utc": record.createdAtUTC,
            "updated_at_utc": record.updatedAtUTC,
            "progress": record.progress,
        ]
        if let checkpoint = record.checkpoint {
            payload["checkpoint"] = checkpoint
        }
        if let error = record.error {
            payload["error"] = error
        }
        do {
            let data = try CanonicalJSONEncoder.encode(payload)
            try writeFaultInjector?(.beforeTemporaryWrite)
            let temporaryURL = taskRoot.appendingPathComponent(
                ".task.json.tmp-\(UUID().uuidString)")
            let finalURL = taskFileURL(taskRoot: taskRoot)
            var shouldRemoveTemporary = true
            defer {
                if shouldRemoveTemporary {
                    try? FileManager.default.removeItem(at: temporaryURL)
                }
            }
            let fd = open(
                temporaryURL.path,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
                mode_t(0o600))
            guard fd >= 0 else {
                throw TaskError.cannotWrite("cannot create task temp")
            }
            var writeSucceeded = false
            do {
                var written = 0
                writeSucceeded = data.withUnsafeBytes { rawBuffer -> Bool in
                    guard let base = rawBuffer.baseAddress else {
                        return data.isEmpty
                    }
                    while written < rawBuffer.count {
                        let count = Darwin.write(
                            fd,
                            base.advanced(by: written),
                            rawBuffer.count - written)
                        if count <= 0 { return false }
                        written += count
                    }
                    return true
                }
                guard writeSucceeded, fsync(fd) == 0 else {
                    throw TaskError.cannotWrite("task temp write/fsync failed")
                }
            } catch {
                close(fd)
                throw error
            }
            close(fd)
            try writeFaultInjector?(.afterTemporaryFsync)
            guard rename(temporaryURL.path, finalURL.path) == 0 else {
                throw TaskError.cannotWrite("task rename failed")
            }
            shouldRemoveTemporary = false
            try writeFaultInjector?(.afterRename)
            let directoryFD = open(taskRoot.path, O_RDONLY | O_DIRECTORY)
            guard directoryFD >= 0 else {
                throw TaskError.cannotWrite("cannot open task root for fsync")
            }
            defer { close(directoryFD) }
            guard fsync(directoryFD) == 0 else {
                throw TaskError.cannotWrite("task root fsync failed")
            }
            try writeFaultInjector?(.afterParentFsync)
        } catch {
            if let taskError = error as? TaskError {
                throw taskError
            }
            throw TaskError.cannotWrite("\(error)")
        }
    }

    /// True when a record is in a resumable terminal-ish state after a
    /// crash (not completed, not failed by user action).
    static func isResumable(_ record: TaskRecord) -> Bool {
        switch record.state {
        case .completed, .rescanRequired, .cancelled, .failed:
            return false
        case .interrupted:
            return true
        default:
            return true
        }
    }
}

/// P1-11 terminal-state transaction shared by every processing-pipeline
/// failure exit. A durable intent is installed before `task.json` changes,
/// preventing a pre-rename task-write failure from silently leaving an old
/// intermediate state that restart would misinterpret as ordinary resume.
///
/// The transaction is:
/// intent temp/write/fsync -> intent rename/parent fsync -> task.json update
/// -> intent unlink/parent fsync. If any step fails, callers receive a typed
/// `DurabilityFailure`; the original business outcome is never reported as
/// though its terminal state were safely committed.
enum MobileTerminalStatePersistence {
    static let intentFileName = "terminal_state_intent.json"
    static let maximumIntentBytes = 64 * 1024

    enum BusinessOutcome: String, CaseIterable {
        case cancelled
        case interrupted
        case resourceRequired = "resource_required"
        case rescanSession = "rescan_session"
        case workflowFailed = "workflow_failed"
    }

    enum FailurePhase: String {
        case establishIntent = "establish_intent"
        case persistTaskState = "persist_task_state"
        case clearIntent = "clear_intent"
    }

    struct Intent {
        var taskID: String
        var outcome: BusinessOutcome
        var targetState: PersistentTaskCoordinator.TaskState
        var persistedReason: String
        var businessCode: String
        var businessDetail: String
        var createdAtUTC: Double
    }

    struct DurabilityFailure: Error, LocalizedError {
        var outcome: BusinessOutcome
        var businessCode: String
        var businessDetail: String
        var phase: FailurePhase
        var persistenceDetail: String
        var observedTaskState: PersistentTaskCoordinator.TaskState?

        var errorDescription: String? {
            let observed = observedTaskState?.rawValue ?? "unreadable"
            return "terminal outcome \(outcome.rawValue) "
                + "(\(businessCode): \(businessDetail)) was not durably "
                + "committed at \(phase.rawValue): \(persistenceDetail); "
                + "observed_task_state=\(observed)"
        }
    }

    enum IntentError: Error, LocalizedError {
        case invalidIntent(String)
        case conflictingIntent(String)
        case cannotWrite(String)
        case cannotClear(String)

        var errorDescription: String? {
            switch self {
            case .invalidIntent(let detail):
                return "terminal intent invalid: \(detail)"
            case .conflictingIntent(let detail):
                return "terminal intent conflicts: \(detail)"
            case .cannotWrite(let detail):
                return "terminal intent cannot be written: \(detail)"
            case .cannotClear(let detail):
                return "terminal intent cannot be cleared: \(detail)"
            }
        }
    }

    /// Commits the mapped terminal task state and then throws the original
    /// business error. The only alternative thrown type is
    /// `DurabilityFailure`, which preserves the business outcome together
    /// with the exact persistence phase/detail.
    static func persistThenRethrow(
        _ businessError: Error,
        taskRoot: URL
    ) throws -> Never {
        let intent = makeIntent(for: businessError, taskRoot: taskRoot)
        do {
            try ensureIntent(intent, taskRoot: taskRoot)
        } catch {
            throw durabilityFailure(
                intent: intent, phase: .establishIntent,
                persistenceError: error, taskRoot: taskRoot)
        }
        do {
            _ = try PersistentTaskCoordinator.updateState(
                intent.targetState,
                taskRoot: taskRoot,
                error: intent.persistedReason)
        } catch {
            throw durabilityFailure(
                intent: intent, phase: .persistTaskState,
                persistenceError: error, taskRoot: taskRoot)
        }
        do {
            try clearIntent(taskRoot: taskRoot)
        } catch {
            throw durabilityFailure(
                intent: intent, phase: .clearIntent,
                persistenceError: error, taskRoot: taskRoot)
        }
        throw businessError
    }

    /// Restart reconciliation. A durable intent whose task record still
    /// has the old intermediate state is replayed idempotently. A matching
    /// terminal record only needs marker cleanup. Any conflict or storage
    /// failure remains fail-closed and must not drive ordinary resume.
    @discardableResult
    static func reconcilePendingIntent(taskRoot: URL) throws -> Bool {
        guard let intent = try readIntentIfPresent(taskRoot: taskRoot) else {
            return false
        }
        let record = try PersistentTaskCoordinator.read(taskRoot: taskRoot)
        guard record.taskID == intent.taskID,
              record.taskID == taskRoot.lastPathComponent else {
            throw IntentError.conflictingIntent(
                "task identity does not match terminal intent")
        }
        if record.state == intent.targetState {
            // Idempotent cleanup is legal only when BOTH the target state
            // and its exact persisted reason already match. Treating a
            // same-state/different-reason record as equivalent would let a
            // stale resource-pause intent disguise a system interruption
            // (or vice versa).
            guard record.error == intent.persistedReason else {
                throw IntentError.conflictingIntent(
                    "target state exists with a different terminal reason")
            }
        } else {
            // Only an old non-terminal pipeline stage may be advanced.
            // Never overwrite completed or any different terminal state
            // (failed/cancelled/interrupted) from a leftover or injected
            // intent.
            guard isAdvanceableIntermediateState(record.state) else {
                throw IntentError.conflictingIntent(
                    "existing terminal state \(record.state.rawValue) "
                        + "conflicts with intent target "
                        + intent.targetState.rawValue)
            }
            let updated = try PersistentTaskCoordinator.updateState(
                intent.targetState,
                taskRoot: taskRoot,
                error: intent.persistedReason)
            guard updated.taskID == intent.taskID,
                  updated.state == intent.targetState,
                  updated.error == intent.persistedReason else {
                throw IntentError.conflictingIntent(
                    "terminal intent update did not produce exact state/reason")
            }
        }
        try clearIntent(taskRoot: taskRoot)
        return true
    }

    static func intentFileURL(taskRoot: URL) -> URL {
        return taskRoot.appendingPathComponent(intentFileName)
    }

    static func readIntentIfPresent(taskRoot: URL) throws -> Intent? {
        let url = intentFileURL(taskRoot: taskRoot)
        guard let data = try readStableIntentData(url) else {
            return nil
        }
        guard let object = try? StrictJSONDocumentParser.object(
            from: data,
            limits: StrictJSONDocumentLimits(maximumBytes: data.count + 1))
                as? [String: Any],
              Set(object.keys) == Set([
                "format", "version", "task_id", "outcome",
                "target_state", "persisted_reason", "business_code",
                "business_detail", "created_at_utc",
              ]),
              object["format"] as? String
                == "MarketScannerTerminalStateIntent",
              StrictJSONScalar.integer(object["version"]) == 1,
              let taskID = object["task_id"] as? String,
              taskID == taskRoot.lastPathComponent,
              MobileResultLibrary.isSafeBasename(taskID),
              let rawOutcome = object["outcome"] as? String,
              let outcome = BusinessOutcome(rawValue: rawOutcome),
              let rawState = object["target_state"] as? String,
              let targetState = PersistentTaskCoordinator.TaskState(
                rawValue: rawState),
              let persistedReason = object["persisted_reason"] as? String,
              !persistedReason.isEmpty,
              let businessCode = object["business_code"] as? String,
              !businessCode.isEmpty,
              let businessDetail = object["business_detail"] as? String,
              !businessDetail.isEmpty,
              let createdAtUTC = StrictJSONScalar.number(
                object["created_at_utc"]),
              createdAtUTC.isFinite, createdAtUTC > 0 else {
            throw IntentError.invalidIntent(url.path)
        }
        let intent = Intent(
            taskID: taskID,
            outcome: outcome,
            targetState: targetState,
            persistedReason: persistedReason,
            businessCode: businessCode,
            businessDetail: businessDetail,
            createdAtUTC: createdAtUTC)
        guard targetStateAndReason(for: outcome, businessDetail: businessDetail)
                == (targetState, persistedReason) else {
            throw IntentError.invalidIntent(
                "outcome/target-state/reason mismatch")
        }
        return intent
    }

    private static func makeIntent(
        for error: Error,
        taskRoot: URL
    ) -> Intent {
        let outcome: BusinessOutcome
        let businessCode: String
        let businessDetail: String
        if let workflowError = error as? MobileOnlyWorkflowError {
            businessCode = workflowError.code
            businessDetail = workflowError.localizedDescription
            switch workflowError {
            case .cancelled:
                outcome = .cancelled
            case .interrupted:
                outcome = .interrupted
            case .resourceRequired:
                outcome = .resourceRequired
            case .rescanSessionRequired:
                outcome = .rescanSession
            default:
                outcome = .workflowFailed
            }
        } else {
            outcome = .workflowFailed
            businessCode = String(reflecting: type(of: error))
            businessDetail = String(describing: error)
        }
        let mapping = targetStateAndReason(
            for: outcome, businessDetail: businessDetail)
        return Intent(
            taskID: taskRoot.lastPathComponent,
            outcome: outcome,
            targetState: mapping.0,
            persistedReason: mapping.1,
            businessCode: businessCode,
            businessDetail: businessDetail,
            createdAtUTC: Date().timeIntervalSince1970)
    }

    private static func targetStateAndReason(
        for outcome: BusinessOutcome,
        businessDetail: String
    ) -> (PersistentTaskCoordinator.TaskState, String) {
        switch outcome {
        case .cancelled:
            return (.cancelled, "user_cancelled")
        case .interrupted:
            return (.interrupted, "system_interrupted")
        case .resourceRequired:
            return (.interrupted, "resource_pause")
        case .rescanSession:
            return (.rescanRequired, "rescan_session_required")
        case .workflowFailed:
            return (.failed, businessDetail)
        }
    }

    private static func ensureIntent(
        _ intent: Intent,
        taskRoot: URL
    ) throws {
        if let existing = try readIntentIfPresent(taskRoot: taskRoot) {
            guard existing.taskID == intent.taskID,
                  existing.outcome == intent.outcome,
                  existing.targetState == intent.targetState,
                  existing.persistedReason == intent.persistedReason,
                  existing.businessCode == intent.businessCode,
                  existing.businessDetail == intent.businessDetail else {
                throw IntentError.conflictingIntent(intent.taskID)
            }
            return
        }
        let payload: [String: Any] = [
            "format": "MarketScannerTerminalStateIntent",
            "version": 1,
            "task_id": intent.taskID,
            "outcome": intent.outcome.rawValue,
            "target_state": intent.targetState.rawValue,
            "persisted_reason": intent.persistedReason,
            "business_code": intent.businessCode,
            "business_detail": intent.businessDetail,
            "created_at_utc": intent.createdAtUTC,
        ]
        let data = try CanonicalJSONEncoder.encode(payload)
        guard !data.isEmpty, data.count <= maximumIntentBytes else {
            throw IntentError.cannotWrite(
                "intent payload exceeds \(maximumIntentBytes) bytes")
        }
        let temporary = taskRoot.appendingPathComponent(
            ".terminal-state-intent.tmp-\(UUID().uuidString)")
        let final = intentFileURL(taskRoot: taskRoot)
        var removeTemporary = true
        defer {
            if removeTemporary {
                try? FileManager.default.removeItem(at: temporary)
            }
        }
        let fd = open(
            temporary.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
            mode_t(0o600))
        guard fd >= 0 else {
            throw IntentError.cannotWrite("cannot create intent temp")
        }
        do {
            try writeAll(data, descriptor: fd)
            guard fsync(fd) == 0 else {
                throw IntentError.cannotWrite("intent temp fsync failed")
            }
        } catch {
            close(fd)
            throw error
        }
        close(fd)
        guard renameatx_np(
            AT_FDCWD, temporary.path,
            AT_FDCWD, final.path,
            UInt32(RENAME_EXCL)) == 0 else {
            throw IntentError.cannotWrite(
                "intent rename failed: \(String(cString: strerror(errno)))")
        }
        removeTemporary = false
        try syncTaskRoot(taskRoot)
    }

    private static func clearIntent(taskRoot: URL) throws {
        let url = intentFileURL(taskRoot: taskRoot)
        if unlink(url.path) != 0 {
            guard errno == ENOENT else {
                throw IntentError.cannotClear(
                    "intent unlink failed: \(String(cString: strerror(errno)))")
            }
            return
        }
        try syncTaskRoot(taskRoot)
    }

    /// Stable, no-follow read of the restart marker. A symlink, hardlink,
    /// oversized file, concurrent mutation, or path replacement is an
    /// invalid intent, never equivalent to marker absence.
    private static func readStableIntentData(_ url: URL) throws -> Data? {
        var pathBefore = stat()
        guard lstat(url.path, &pathBefore) == 0 else {
            if errno == ENOENT { return nil }
            throw IntentError.invalidIntent("cannot lstat intent")
        }
        guard (pathBefore.st_mode & S_IFMT) == S_IFREG,
              pathBefore.st_nlink == 1,
              pathBefore.st_size > 0,
              pathBefore.st_size <= maximumIntentBytes else {
            throw IntentError.invalidIntent(
                "intent must be one bounded regular non-hardlinked file")
        }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else {
            throw IntentError.invalidIntent("cannot open intent no-follow")
        }
        defer { close(fd) }
        var opened = stat()
        guard fstat(fd, &opened) == 0,
              (opened.st_mode & S_IFMT) == S_IFREG,
              opened.st_nlink == 1,
              opened.st_dev == pathBefore.st_dev,
              opened.st_ino == pathBefore.st_ino,
              opened.st_size == pathBefore.st_size,
              opened.st_mtimespec.tv_sec
                == pathBefore.st_mtimespec.tv_sec,
              opened.st_mtimespec.tv_nsec
                == pathBefore.st_mtimespec.tv_nsec,
              opened.st_ctimespec.tv_sec
                == pathBefore.st_ctimespec.tv_sec,
              opened.st_ctimespec.tv_nsec
                == pathBefore.st_ctimespec.tv_nsec else {
            throw IntentError.invalidIntent(
                "intent identity changed before open")
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(fd, rawBuffer.baseAddress, rawBuffer.count)
            }
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else {
                throw IntentError.invalidIntent("intent read failed")
            }
            if count == 0 { break }
            guard data.count + count <= maximumIntentBytes else {
                throw IntentError.invalidIntent("intent grew beyond limit")
            }
            data.append(contentsOf: buffer.prefix(count))
        }
        var openedAfter = stat()
        var pathAfter = stat()
        guard fstat(fd, &openedAfter) == 0,
              lstat(url.path, &pathAfter) == 0,
              data.count == Int(opened.st_size),
              openedAfter.st_dev == opened.st_dev,
              openedAfter.st_ino == opened.st_ino,
              openedAfter.st_size == opened.st_size,
              openedAfter.st_mtimespec.tv_sec
                == opened.st_mtimespec.tv_sec,
              openedAfter.st_mtimespec.tv_nsec
                == opened.st_mtimespec.tv_nsec,
              openedAfter.st_ctimespec.tv_sec
                == opened.st_ctimespec.tv_sec,
              openedAfter.st_ctimespec.tv_nsec
                == opened.st_ctimespec.tv_nsec,
              pathAfter.st_dev == opened.st_dev,
              pathAfter.st_ino == opened.st_ino,
              (pathAfter.st_mode & S_IFMT) == S_IFREG,
              pathAfter.st_nlink == 1,
              pathAfter.st_size == opened.st_size,
              pathAfter.st_mtimespec.tv_sec
                == opened.st_mtimespec.tv_sec,
              pathAfter.st_mtimespec.tv_nsec
                == opened.st_mtimespec.tv_nsec,
              pathAfter.st_ctimespec.tv_sec
                == opened.st_ctimespec.tv_sec,
              pathAfter.st_ctimespec.tv_nsec
                == opened.st_ctimespec.tv_nsec else {
            throw IntentError.invalidIntent(
                "intent changed or was replaced during read")
        }
        return data
    }

    private static func isAdvanceableIntermediateState(
        _ state: PersistentTaskCoordinator.TaskState
    ) -> Bool {
        switch state {
        case .completed, .rescanRequired, .failed, .cancelled, .interrupted:
            return false
        default:
            return true
        }
    }

    private static func syncTaskRoot(_ taskRoot: URL) throws {
        let fd = open(taskRoot.path, O_RDONLY | O_DIRECTORY)
        guard fd >= 0 else {
            throw IntentError.cannotWrite("cannot open task root")
        }
        defer { close(fd) }
        guard fsync(fd) == 0 else {
            throw IntentError.cannotWrite("task root fsync failed")
        }
    }

    private static func writeAll(_ data: Data, descriptor: Int32) throws {
        var written = 0
        let succeeded = data.withUnsafeBytes { rawBuffer -> Bool in
            guard let base = rawBuffer.baseAddress else { return data.isEmpty }
            while written < rawBuffer.count {
                let count = Darwin.write(
                    descriptor,
                    base.advanced(by: written),
                    rawBuffer.count - written)
                if count < 0 && errno == EINTR { continue }
                if count <= 0 { return false }
                written += count
            }
            return true
        }
        guard succeeded else {
            throw IntentError.cannotWrite("intent temp write failed")
        }
    }

    private static func durabilityFailure(
        intent: Intent,
        phase: FailurePhase,
        persistenceError: Error,
        taskRoot: URL
    ) -> DurabilityFailure {
        let observed = try? PersistentTaskCoordinator.read(taskRoot: taskRoot)
        return DurabilityFailure(
            outcome: intent.outcome,
            businessCode: intent.businessCode,
            businessDetail: intent.businessDetail,
            phase: phase,
            persistenceDetail: String(describing: persistenceError),
            observedTaskState: observed?.state)
    }
}
