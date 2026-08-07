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
/// - the whole snapshot commits atomically: staging dir → fsync →
///   rename → fsync task root (§8.7).
enum SessionSnapshotTransaction {
    enum FaultPoint {
        case afterSourceInventory
        case beforeManifestWrite
        case afterSnapshotInstall
        case beforeTaskReferenceFsync
        case beforeBackupRestore
    }

    /// Deterministic filesystem fault injection used by the executable host
    /// suite. Production leaves this nil.
    static var faultInjector: ((FaultPoint) throws -> Void)?

    struct SessionSnapshot {
        var taskID: String
        var snapshotDirectory: URL
        var inputManifest: [String: Any]
        var bundleSHA256: String
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
        // Idempotence: rebuild the staging tree from the source on
        // retry. The committed snapshot is NOT deleted here — B-08 keeps
        // the previous valid snapshot until the new one is complete and
        // verified (see step 7).
        if fileManager.fileExists(atPath: stagingDirectory.path) {
            try removeImmutableTree(stagingDirectory)
        }
        let backupDirectory = taskRoot
            .appendingPathComponent("input_snapshot.backup")
        try recoverInterruptedCommitIfNeeded(
            taskRoot: taskRoot,
            snapshotDirectory: snapshotDirectory,
            backupDirectory: backupDirectory)
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
                [.posixPermissions: NSNumber(value: committedDirectoryMode)],
                ofItemAtPath: stagingDirectory.path)
            try fsyncDirectory(stagingDirectory)

            // RC-B09: one generation includes the immutable directory,
            // its manifest, its commit marker and the durable task-root
            // reference (the task-root input_manifest.json). The previous
            // generation remains in backup until every new marker/reference
            // is durable and has passed resume validation.
            let taskManifestURL = taskRoot.appendingPathComponent(
                "input_manifest.json")
            let priorTaskManifest = fileManager.fileExists(
                atPath: taskManifestURL.path)
                ? try Data(contentsOf: taskManifestURL) : nil
            var movedPreviousSnapshot = false
            var installedNewSnapshot = false
            do {
                if fileManager.fileExists(atPath: snapshotDirectory.path) {
                    try renameDirectoryExclusively(
                        snapshotDirectory,
                        to: backupDirectory,
                        context: "cannot stage previous snapshot backup")
                    movedPreviousSnapshot = true
                    try fsyncDirectory(taskRoot)
                }
                try renameDirectoryExclusively(
                    stagingDirectory,
                    to: snapshotDirectory,
                    context: "cannot install immutable snapshot")
                installedNewSnapshot = true
                try fsyncDirectory(taskRoot)
                try faultInjector?(.afterSnapshotInstall)
                try manifestData.write(
                    to: taskManifestURL, options: [.atomic])
                try fileManager.setAttributes(
                    [.posixPermissions: NSNumber(value: committedFileMode)],
                    ofItemAtPath: taskManifestURL.path)
                try faultInjector?(.beforeTaskReferenceFsync)
                try fsyncURL(taskManifestURL)
                try fsyncDirectory(taskRoot)
                try revalidateSnapshot(snapshotDirectory)
            } catch {
                let commitError = error
                do {
                    try faultInjector?(.beforeBackupRestore)
                    if installedNewSnapshot,
                       fileManager.fileExists(atPath: snapshotDirectory.path) {
                        try removeImmutableTree(snapshotDirectory)
                    }
                    if movedPreviousSnapshot,
                       fileManager.fileExists(atPath: backupDirectory.path) {
                        try renameDirectoryExclusively(
                            backupDirectory,
                            to: snapshotDirectory,
                            context: "cannot restore previous snapshot")
                    }
                    if let priorTaskManifest {
                        try priorTaskManifest.write(
                            to: taskManifestURL, options: [.atomic])
                        try fileManager.setAttributes(
                            [.posixPermissions: NSNumber(value: committedFileMode)],
                            ofItemAtPath: taskManifestURL.path)
                        try fsyncURL(taskManifestURL)
                    } else if fileManager.fileExists(
                        atPath: taskManifestURL.path) {
                        try fileManager.removeItem(at: taskManifestURL)
                    }
                    try fsyncDirectory(taskRoot)
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
                    try removeImmutableTree(backupDirectory)
                    try? fsyncDirectory(taskRoot)
                } catch { /* durable commit remains authoritative */ }
            }

            return SessionSnapshot(
                taskID: taskID,
                snapshotDirectory: snapshotDirectory,
                inputManifest: manifest,
                bundleSHA256: bundleSHA)
        } catch {
            if fileManager.fileExists(atPath: stagingDirectory.path) {
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
    static func revalidateSnapshot(_ directory: URL) throws {
        let fileManager = FileManager.default
        try validateCommittedDirectory(directory)
        let manifestURL = directory.appendingPathComponent("input_manifest.json")
        try validateCommittedRegularFile(manifestURL)
        let manifestData = try Data(contentsOf: manifestURL)
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

        // The task-root copy is the durable reference to this exact
        // generation. A snapshot directory without the matching reference
        // is an interrupted commit and cannot be resumed.
        let taskRoot = directory.deletingLastPathComponent()
        guard taskRoot.lastPathComponent == taskID else {
            throw SessionError.notEligible(
                "snapshot task identity mismatch")
        }
        let taskManifestURL = taskRoot.appendingPathComponent(
            "input_manifest.json")
        try validateCommittedRegularFile(taskManifestURL)
        let taskManifestData = try Data(contentsOf: taskManifestURL)
        guard taskManifestData == manifestData else {
            throw SessionError.notEligible(
                "task reference generation does not match snapshot manifest")
        }

        var expectedNames = Set(["input_manifest.json", "snapshot_commit.json"])
        var artifactNames = Set<String>()
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
                  !expectedSHA.isEmpty,
                  artifactNames.insert(name).inserted,
                  expectedNames.insert(name).inserted else {
                throw SessionError.notEligible(
                    "input_manifest.json artifact name/count invalid")
            }
            let url = directory.appendingPathComponent(name)
            let fileStat = try validateCommittedRegularFile(url)
            let actualBytes = Int64(fileStat.st_size)
            guard actualBytes == expectedBytes else {
                throw SessionError.copyFailed(
                    "resume bytes mismatch: \(name) \(actualBytes) != \(expectedBytes)")
            }
            let actualSHA = try CanonicalSourceHasher.sha256File(url)
            guard actualSHA == expectedSHA else {
                throw SessionError.copyFailed(
                    "resume sha mismatch: \(name)")
            }
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
            sessionDirectory: directory,
            databaseName: databaseName,
            phase: "resume")

        let actualNames = Set(try fileManager.contentsOfDirectory(
            atPath: directory.path))
        guard actualNames == expectedNames else {
            throw SessionError.notEligible(
                "snapshot file inventory differs from committed manifest")
        }
        guard MobilePackageManifestBuilder.packageDigest(artifacts) == bundleSHA else {
            throw SessionError.notEligible(
                "snapshot bundle digest does not match artifacts")
        }

        let commitMarkerURL = directory.appendingPathComponent(
            "snapshot_commit.json")
        try validateCommittedRegularFile(commitMarkerURL)
        let commitData = try Data(contentsOf: commitMarkerURL)
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
        let metadata = try readMetadata(
            directory.appendingPathComponent("metadata.json"))
        try checkEligibility(metadata.value, eligibility: nil)

        // DB quick-check + WAL contract on the snapshot copy.
        try validateSnapshotDatabase(
            directory.appendingPathComponent(databaseName))
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

    // MARK: - Immutable commit / recovery helpers

    @discardableResult
    private static func validateCommittedRegularFile(
        _ url: URL
    ) throws -> stat {
        var fileStat = stat()
        guard lstat(url.path, &fileStat) == 0,
              (fileStat.st_mode & S_IFMT) == S_IFREG,
              fileStat.st_nlink == 1 else {
            throw SessionError.notEligible(
                "committed artifact is not one regular file: "
                + url.lastPathComponent)
        }
        guard (fileStat.st_mode & 0o777) == committedFileMode else {
            throw SessionError.notEligible(
                "committed artifact mode is not 0444: "
                + url.lastPathComponent)
        }
        return fileStat
    }

    private static func validateCommittedDirectory(_ url: URL) throws {
        var directoryStat = stat()
        guard lstat(url.path, &directoryStat) == 0,
              (directoryStat.st_mode & S_IFMT) == S_IFDIR else {
            throw SessionError.notEligible(
                "snapshot is not a real directory")
        }
        guard (directoryStat.st_mode & 0o777) == committedDirectoryMode else {
            throw SessionError.notEligible(
                "snapshot directory mode is not 0555")
        }
    }

    private static func removeImmutableTree(_ directory: URL) throws {
        var directoryStat = stat()
        guard lstat(directory.path, &directoryStat) == 0,
              (directoryStat.st_mode & S_IFMT) == S_IFDIR else {
            throw SessionError.copyFailed(
                "refusing to remove non-directory snapshot path")
        }
        guard chmod(directory.path, S_IRWXU) == 0 else {
            throw SessionError.copyFailed(
                "cannot make immutable snapshot removable")
        }
        try FileManager.default.removeItem(at: directory)
    }

    /// Foundation's `moveItem` may reject a 0555 source directory before
    /// issuing the same-volume rename on some macOS releases. Snapshot
    /// generations are deliberately frozen before publication, so use the
    /// Darwin primitive directly and keep the destination no-replace.
    private static func renameDirectoryExclusively(
        _ source: URL,
        to destination: URL,
        context: String
    ) throws {
        guard renameatx_np(
            AT_FDCWD, source.path,
            AT_FDCWD, destination.path,
            UInt32(RENAME_EXCL)) == 0 else {
            let renameError = errno
            throw SessionError.copyFailed(
                context + ": " + String(cString: strerror(renameError)))
        }
    }

    private static func recoverInterruptedCommitIfNeeded(
        taskRoot: URL,
        snapshotDirectory: URL,
        backupDirectory: URL
    ) throws {
        let fileManager = FileManager.default
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
                    try renameDirectoryExclusively(
                        backupDirectory,
                        to: snapshotDirectory,
                        context: "cannot restore verified snapshot backup")
                    try fsyncDirectory(taskRoot)
                    return
                } catch {
                    if snapshotMatchesTaskReferenceLoosely(
                        backupDirectory, taskRoot: taskRoot) {
                        try removeImmutableTree(snapshotDirectory)
                        try renameDirectoryExclusively(
                            backupDirectory,
                            to: snapshotDirectory,
                            context: "cannot restore referenced snapshot backup")
                        try fsyncDirectory(taskRoot)
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
        try renameDirectoryExclusively(
            backupDirectory,
            to: snapshotDirectory,
            context: "cannot recover orphaned snapshot backup")
        try fsyncDirectory(taskRoot)
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
        var snapshotStat = stat()
        var taskStat = stat()
        guard lstat(snapshotManifest.path, &snapshotStat) == 0,
              lstat(taskManifest.path, &taskStat) == 0,
              (snapshotStat.st_mode & S_IFMT) == S_IFREG,
              (taskStat.st_mode & S_IFMT) == S_IFREG,
              snapshotStat.st_nlink == 1,
              taskStat.st_nlink == 1,
              snapshotStat.st_size == taskStat.st_size,
              let snapshotData = try? Data(contentsOf: snapshotManifest),
              let taskData = try? Data(contentsOf: taskManifest) else {
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
        var db: OpaquePointer?
        // Percent-encode the path so '%', '#', '?' in file names cannot
        // inject URI parameters/fragments (mirrors the C++ core's
        // uriEncodePath hardening).
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~/")
        let encodedPath = url.path.addingPercentEncoding(withAllowedCharacters: allowed)
            ?? url.path
        let uri = "file:\(encodedPath)?mode=ro&immutable=1"
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
