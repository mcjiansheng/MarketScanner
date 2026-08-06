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
        let metadata = try readMetadata(metadataURL)
        try checkEligibility(metadata, eligibility: eligibility)

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
                filesToCopy.append((name, source, true))
            }
        }
        // Watermark sidecars: required when the metadata watermark says
        // the scan recorded them; their absence is evidence tampering.
        let clockCount = (metadata["clockCorrelationCount"] as? NSNumber)?.int64Value ?? 0
        let burstCount = (metadata["tagObservationBurstCount"] as? NSNumber)?.int64Value ?? 0
        for name in watermarkFileNames {
            let source = finalizedSession.appendingPathComponent(name)
            let expected = name == "clock_correlations.jsonl" ? clockCount : burstCount
            let exists = fileManager.fileExists(atPath: source.path)
            if expected > 0 && !exists {
                throw SessionError.missingRequired(name)
            }
            if exists {
                filesToCopy.append((name, source, expected > 0))
            }
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
            totalSourceBytes += (attributes[.size] as? NSNumber)?.int64Value ?? 0
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
            try fileManager.removeItem(at: stagingDirectory)
        }
        try fileManager.createDirectory(
            at: stagingDirectory, withIntermediateDirectories: true)

        var artifacts: [[String: Any]] = []
        do {
            for entry in filesToCopy {
                let destination = stagingDirectory.appendingPathComponent(entry.name)
                let sha = try stableStreamingCopy(
                    source: entry.source, destination: destination)
                let attributes = try fileManager.attributesOfItem(atPath: destination.path)
                artifacts.append([
                    "file": entry.name,
                    "bytes": (attributes[.size] as? NSNumber)?.int64Value ?? 0,
                    "sha256": sha,
                    "required": entry.required,
                ])
            }
        } catch {
            try? fileManager.removeItem(at: stagingDirectory)
            throw error
        }
        guard !artifacts.isEmpty else {
            try? fileManager.removeItem(at: stagingDirectory)
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
            let stagedMetadata = try readMetadata(stagedMetadataURL)
            try checkEligibility(stagedMetadata, eligibility: eligibility)
            let sourceDigest = try CanonicalSourceHasher.sha256File(metadataURL)
            let stagedDigest = try CanonicalSourceHasher.sha256File(stagedMetadataURL)
            guard sourceDigest == stagedDigest else {
                throw SessionError.copyFailed(
                    "metadata changed during snapshot (TOCTOU)")
            }
            // Watermark re-check on the copied metadata: counts the
            // snapshot actually carries must be backed by the copied
            // artifacts.
            let stagedClock = (stagedMetadata["clockCorrelationCount"] as? NSNumber)?.int64Value ?? 0
            let stagedBurst = (stagedMetadata["tagObservationBurstCount"] as? NSNumber)?.int64Value ?? 0
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

            // 7. Input manifest + atomic commit (§8.7).
            let bundleSHA = MobilePackageManifestBuilder.packageDigest(artifacts)
            let manifest: [String: Any] = [
                "format": "MarketScannerSessionInputManifest",
                "version": 2,
                "task_id": taskID,
                "bundle_sha256": bundleSHA,
                "artifact_count": artifacts.count,
                "artifacts": artifacts,
            ]
            let manifestData = try CanonicalJSONEncoder.encode(manifest)
            let stagingManifest = stagingDirectory.appendingPathComponent("input_manifest.json")
            try manifestData.write(to: stagingManifest, options: [.atomic])
            try fsyncURL(stagingManifest)
            try fsyncDirectory(stagingDirectory)

            // B-08: only now is the previously committed snapshot
            // replaced — a failure above keeps the old valid snapshot.
            if fileManager.fileExists(atPath: snapshotDirectory.path) {
                try fileManager.removeItem(at: snapshotDirectory)
            }
            try fileManager.moveItem(at: stagingDirectory, to: snapshotDirectory)
            try fsyncDirectory(taskRoot)
            // The committed manifest lives in the task root as before.
            try manifestData.write(
                to: taskRoot.appendingPathComponent("input_manifest.json"),
                options: [.atomic])
            try fsyncURL(taskRoot.appendingPathComponent("input_manifest.json"))

            return SessionSnapshot(
                taskID: taskID,
                snapshotDirectory: snapshotDirectory,
                inputManifest: manifest,
                bundleSHA256: bundleSHA)
        } catch {
            try? fileManager.removeItem(at: stagingDirectory)
            throw error
        }
    }

    /// Maps a metadata sidecar-declaration key back to its artifact
    /// file name (used for the post-copy watermark re-check).
    private static func nameKey(for fileName: String) -> String {
        return Self.declaredSidecarPairs
            .first(where: { $0.name == fileName })?.key ?? ""
    }

    // MARK: - Eligibility (§8.1)

    private static func readMetadata(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        guard let object = try? StrictJSONDocumentParser.object(
            from: data,
            limits: StrictJSONDocumentLimits(maximumBytes: data.count + 1)) as? [String: Any]
        else {
            throw SessionError.sessionMissing
        }
        return object
    }

    private static func checkEligibility(
        _ metadata: [String: Any],
        eligibility: Eligibility?
    ) throws {
        guard let finalized = metadata["finalized"] as? Bool, finalized else {
            throw SessionError.notFinalized
        }
        let scanMode = metadata["scanMode"] as? String ?? ""
        guard scanMode == "continuous_streaming" else {
            throw SessionError.notEligible("scanMode != continuous_streaming")
        }
        let trackingSessionID = metadata["trackingSessionId"] as? String ?? ""
        guard !trackingSessionID.isEmpty else {
            throw SessionError.notEligible("trackingSessionId empty")
        }
        // Required write failures block processing (fail closed).
        let writeFailures = (metadata["requiredWriteFailureCount"] as? NSNumber)?.int64Value ?? 0
        if writeFailures > 0 {
            throw SessionError.notEligible("required write failures = \(writeFailures)")
        }
        // A live checkpoint means the scan never finalized cleanly.
        if let checkpoint = metadata["liveCheckpoint"] as? Bool, checkpoint {
            throw SessionError.notEligible("live checkpoint present")
        }
        guard let eligibility = eligibility else { return }
        guard eligibility.appGitSHA != "unknown", !eligibility.appGitSHA.isEmpty else {
            throw SessionError.notEligible("app build identity unknown")
        }
        if let priorMapID = eligibility.priorMapID {
            let sessionMapID = metadata["priorMapId"] as? String ?? ""
            guard sessionMapID == priorMapID else {
                throw SessionError.notEligible(
                    "priorMapId mismatch: \(sessionMapID) != \(priorMapID)")
            }
        }
        if let priorMapSHA = eligibility.priorMapSHA256 {
            let sessionSHA = metadata["priorMapSha256"] as? String ?? ""
            guard sessionSHA == priorMapSHA else {
                throw SessionError.notEligible(
                    "priorMapSha256 mismatch: \(sessionSHA.prefix(12)) != \(priorMapSHA.prefix(12))")
            }
        }
        if let storeID = eligibility.storeID, !storeID.isEmpty {
            let sessionStore = metadata["storeId"] as? String ?? ""
            // B-08: an empty session store is fail-closed — the
            // production session MUST record the store it belongs to.
            guard sessionStore == storeID else {
                throw SessionError.notEligible(
                    "storeId mismatch: '\(sessionStore)' != '\(storeID)'")
            }
        }
        if let floorID = eligibility.floorID, !floorID.isEmpty {
            let sessionFloor = metadata["floorId"] as? String ?? ""
            // B-08: same fail-closed policy for the floor.
            guard sessionFloor == floorID else {
                throw SessionError.notEligible(
                    "floorId mismatch: '\(sessionFloor)' != '\(floorID)'")
            }
        }
    }

    // MARK: - Disk budget (§8.6)

    private static func checkDiskBudget(neededBytes: Int64, at url: URL) throws {
        let values = try url.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let available = values.volumeAvailableCapacityForImportantUsage else {
            // Cannot determine capacity: fail closed (§8.6 never allows a
            // silent fail-open that could exhaust the device disk).
            throw SessionError.insufficientDisk("cannot determine available capacity")
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
    private static func stableStreamingCopy(source: URL, destination: URL) throws -> String {
        let sourceFD = open(source.path, O_RDONLY | O_NOFOLLOW)
        guard sourceFD >= 0 else {
            throw SessionError.copyFailed("cannot open source \(source.lastPathComponent)")
        }
        defer { close(sourceFD) }
        var preStat = stat()
        guard fstat(sourceFD, &preStat) == 0 else {
            throw SessionError.copyFailed("cannot fstat source \(source.lastPathComponent)")
        }
        // Regular file policy; hard links (nlink > 1) are allowed but the
        // post-copy identity check still guards against swaps.
        guard (preStat.st_mode & S_IFMT) == S_IFREG else {
            throw SessionError.copyFailed("source is not a regular file: \(source.lastPathComponent)")
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
            let bytesRead = read(sourceFD, &buffer, copyChunkBytes)
            if bytesRead < 0 {
                copyError = SessionError.copyFailed("read failed on \(source.lastPathComponent)")
                break
            }
            if bytesRead == 0 {
                break
            }
            hasher.update(data: Data(bytes: buffer, count: bytesRead))
            var written = 0
            while written < bytesRead {
                let result = write(
                    destFD, Array(buffer[written..<bytesRead]), bytesRead - written)
                if result <= 0 {
                    copyError = SessionError.copyFailed(
                        "write failed on \(destination.lastPathComponent)")
                    break
                }
                written += result
            }
            if copyError != nil { break }
            totalWritten += Int64(bytesRead)
        }
        if copyError == nil && fsync(destFD) != 0 {
            copyError = SessionError.copyFailed("fsync failed on \(destination.lastPathComponent)")
        }
        close(destFD)
        if let copyError = copyError {
            try? FileManager.default.removeItem(at: destination)
            throw copyError
        }

        // Post-copy: the source identity must be unchanged.
        var postStat = stat()
        guard fstat(sourceFD, &postStat) == 0 else {
            throw SessionError.copyFailed("cannot re-fstat source \(source.lastPathComponent)")
        }
        guard postStat.st_ino == preStat.st_ino,
              postStat.st_size == preStat.st_size,
              postStat.st_mtimespec.tv_sec == preStat.st_mtimespec.tv_sec
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
            [.posixPermissions: 0o444], ofItemAtPath: destination.path)
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
        while sqlite3_step(tableStatement) == SQLITE_ROW {
            if let text = sqlite3_column_text(tableStatement, 0) {
                tables.insert(String(cString: text))
            }
        }
        guard tables.contains("Node"), tables.contains("Link") else {
            throw SessionError.dbIntegrity("Node/Link tables missing")
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
        case failed
        case cancelled
        case interrupted
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
    }

    static func taskFileURL(taskRoot: URL) -> URL {
        return taskRoot.appendingPathComponent("task.json")
    }

    static func createTask(taskID: String, taskRoot: URL) throws -> TaskRecord {
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
        error: String? = nil
    ) throws -> TaskRecord {
        var record = try read(taskRoot: taskRoot)
        record.state = state
        record.updatedAtUTC = Date().timeIntervalSince1970
        if let progress = progress {
            record.progress = progress
        }
        if let checkpoint = checkpoint {
            record.checkpoint = checkpoint
        }
        if let error = error {
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
              let createdAt = object["created_at_utc"] as? Double,
              let updatedAt = object["updated_at_utc"] as? Double,
              let progress = object["progress"] as? Double
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
            try data.write(to: taskFileURL(taskRoot: taskRoot), options: [.atomic])
        } catch {
            throw TaskError.cannotWrite("\(error)")
        }
    }

    /// True when a record is in a resumable terminal-ish state after a
    /// crash (not completed, not failed by user action).
    static func isResumable(_ record: TaskRecord) -> Bool {
        switch record.state {
        case .completed, .cancelled, .failed:
            return false
        case .interrupted:
            return true
        default:
            return true
        }
    }
}
