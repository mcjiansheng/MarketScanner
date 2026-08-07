import Darwin
import Foundation

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
/// files and the staging directory, freeze the complete hidden package,
/// same-parent atomic rename into the library root, then fsync the parent.
/// A failed run never becomes visible at its final path in the library.
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
        case afterRename
        case afterParentFsync
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

    /// Deterministic fault-injection hook used by the executable crash
    /// matrix. Production leaves it nil. Throwing at any stage must never
    /// cause a mutable result to be listed as committed.
    static var commitFaultInjector: ((CommitStage) throws -> Void)?

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
        "tracking_session_id", "source_database", "input_bundle_sha256",
        "native_core_sha256", "processing_path",
        "policy_sha", "projection_policy_version",
        "trajectory_sha256", "graph_quality_sha256",
        "device_position_count", "available_position_count",
        "tag_count", "rescan_count",
    ]

    /// Test/embedding hook; see `MobileMapLibrary.rootOverride`.
    static var rootOverride: URL?

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
    /// directory across parents. Keeping staging and final as siblings
    /// lets commit freeze the staging root to 0555 before an exclusive
    /// same-parent rename, so the final path is immutable from its first
    /// visible instant.
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
        let fileManager = FileManager.default
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
        var stagingWasRenamed = false
        do {
            // Freeze the ENTIRE staging package while it is still hidden:
            // files 0444 and the staging root itself 0555. Same-volume
            // rename permission is governed by the writable parent, not by
            // the renamed directory's own mode, so the exclusive rename
            // preserves this immutable mode without a visibility window.
            freezeAttempted = true
            try freezeImmutably(stagingDirectory)
            try validateExactDirectorySet(
                stagingDirectory,
                expectedNames: committedNames,
                expectedDirectoryMode: 0o555,
                expectedFileMode: 0o444)
            try commitFaultInjector?(.afterFreeze)

            // 4. Atomic rename into the library root. The commit receipt
            // travels inside the same rename generation, so a crash after
            // rename can be reconciled idempotently by task_id.
            if fileManager.fileExists(atPath: finalDirectory.path) {
                throw ResultError.commitFailed(
                    "result already exists: \(resultID)")
            }
            guard renameatx_np(
                AT_FDCWD, stagingDirectory.path,
                AT_FDCWD, finalDirectory.path,
                UInt32(RENAME_EXCL)) == 0 else {
                let renameError = errno
                if renameError == EEXIST || renameError == ENOTEMPTY {
                    throw ResultError.commitFailed(
                        "result already exists: \(resultID)")
                }
                throw ResultError.commitFailed(
                    "atomic result rename failed: "
                        + String(cString: strerror(renameError)))
            }
            stagingWasRenamed = true
        } catch {
            if freezeAttempted && !stagingWasRenamed {
                do {
                    try makeStagingRecoverable(stagingDirectory)
                } catch let recoveryError {
                    throw ResultError.commitFailed(
                        "pre-rename commit failed: \(error); "
                            + "staging recovery failed: \(recoveryError)")
                }
            }
            throw error
        }

        // The final path was already immutable before it became visible.
        // Re-verify the exact set/modes, receipt and EVERY artifact hash
        // after rename before reporting success.
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

    /// Lists committed results, re-validating each manifest and every
    /// artifact hash (§20.5). Corrupted/unknown root entries are moved
    /// into a durable quarantine package with an audit diagnostic.
    static func listResults() -> [ResultEntry] {
        replaceListingDiagnostics([])
        let fileManager = FileManager.default
        guard let root = try? root(),
              let names = try? fileManager.contentsOfDirectory(atPath: root.path)
        else { return [] }
        var result: [ResultEntry] = []
        for name in names.sorted()
            where name != "staging" && name != "quarantine"
                && !isHiddenStagingName(name) {
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
                        directory, sourceName: name, reason: error)
                    appendListingDiagnostic(
                        "quarantined \(name) as \(quarantineID): \(error)")
                } catch let quarantineError {
                    let message = "failed to quarantine \(name): \(error); "
                        + "quarantine error: \(quarantineError)"
                    appendListingDiagnostic(message)
                    NSLog("MarketScanner result-library audit: %@", message)
                }
            }
        }
        return result.sorted { $0.createdAtUTC > $1.createdAtUTC }
    }

    /// Quarantines one invalid root entry in a wrapper whose diagnostic
    /// is durable before this method reports success. The original entry
    /// is moved, not deleted, so support tooling can inspect/recover it.
    @discardableResult
    private static func quarantine(
        _ source: URL,
        sourceName: String,
        reason: Error
    ) throws -> String {
        let fileManager = FileManager.default
        let libraryRoot = try root()
        let quarantineRoot = libraryRoot.appendingPathComponent(
            "quarantine", isDirectory: true)
        try fileManager.createDirectory(
            at: quarantineRoot, withIntermediateDirectories: true)
        let quarantineID = "quarantine-\(UUID().uuidString.lowercased())"
        let wrapper = quarantineRoot.appendingPathComponent(
            quarantineID, isDirectory: true)
        try fileManager.createDirectory(
            at: wrapper, withIntermediateDirectories: false)
        var keepWrapper = false
        defer {
            if !keepWrapper { try? fileManager.removeItem(at: wrapper) }
        }
        let payload = wrapper.appendingPathComponent("result_payload")
        var sourceStat = stat()
        guard lstat(source.path, &sourceStat) == 0 else {
            throw ResultError.commitFailed(
                "cannot stat invalid result-library entry")
        }
        let sourceIsDirectory = (sourceStat.st_mode & S_IFMT) == S_IFDIR
        let originalSourceMode = mode_t(sourceStat.st_mode & 0o777)
        var sourceModeChanged = false
        var sourceMoved = false
        if sourceIsDirectory && (originalSourceMode & mode_t(S_IWUSR)) == 0 {
            guard chmod(source.path, originalSourceMode | mode_t(S_IWUSR)) == 0 else {
                throw ResultError.commitFailed(
                    "cannot unlock invalid result directory for isolation")
            }
            sourceModeChanged = true
        }
        defer {
            if sourceModeChanged && !sourceMoved {
                _ = chmod(source.path, originalSourceMode)
            }
        }
        guard renameatx_np(
            AT_FDCWD, source.path,
            AT_FDCWD, payload.path,
            UInt32(RENAME_EXCL)) == 0 else {
            let renameError = errno
            throw ResultError.commitFailed(
                "cannot isolate invalid result-library entry: "
                    + String(cString: strerror(renameError)))
        }
        sourceMoved = true
        keepWrapper = true

        let diagnostic: [String: Any] = [
            "format": "MarketScannerResultQuarantineDiagnostic",
            "version": 1,
            "quarantine_id": quarantineID,
            "source_name": sourceName,
            "reason": String(describing: reason),
            "created_at_utc": Date().timeIntervalSince1970,
            "payload": "result_payload",
        ]
        let diagnosticURL = wrapper.appendingPathComponent(
            quarantineDiagnosticFileName)
        try writeNewRegularFile(
            CanonicalJSONEncoder.encode(diagnostic), to: diagnosticURL)
        try syncFile(diagnosticURL)
        // Quarantine is evidence, not a mutable trash folder: freeze the
        // moved payload and diagnostic recursively before publishing the
        // wrapper as a successful isolation.
        try freezeImmutably(wrapper)
        try MobileMapLibrary.syncDirectory(wrapper)
        try MobileMapLibrary.syncDirectory(quarantineRoot)
        try MobileMapLibrary.syncDirectory(libraryRoot)
        return quarantineID
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
        return try readResult(in: resultDirectory(resultID: resultID))
    }

    /// Finds the one committed result owned by a task. This is the
    /// crash-recovery bridge for the window after result rename/parent
    /// fsync and before task.json reaches `completed`.
    static func committedResult(
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
                && !isHiddenStagingName(name) {
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
        guard let attributes = try? FileManager.default.attributesOfItem(
                atPath: manifestURL.path),
              let size = attributes[.size] as? NSNumber,
              size.int64Value > 0,
              size.int64Value <= 4 * 1024 * 1024,
              let data = try? Data(contentsOf: manifestURL),
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

    private static func readResult(in directory: URL) throws -> ResultEntry {
        let manifestURL = directory.appendingPathComponent(manifestFileName)
        guard isSafeBasename(directory.lastPathComponent) else {
            throw ResultError.invalidManifest("unsafe result directory")
        }
        let data = try Data(contentsOf: manifestURL)
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
        for artifact in artifacts {
            guard let name = artifact["file"] as? String,
                  let sha = artifact["sha256"] as? String,
                  let bytes = StrictJSONScalar.integer(artifact["bytes"]),
                  StrictJSONScalar.boolean(artifact["required"]) == true,
                  artifactFiles.insert(name).inserted
            else {
                throw ResultError.invalidManifest("invalid artifact record")
            }
            _ = (sha, bytes)
        }
        guard artifactFiles == Set(packageFiles).union([workbookName]) else {
            throw ResultError.invalidManifest("artifact file set != package_files + workbook")
        }
        do {
            try validateExactDirectorySet(
                directory,
                expectedNames: artifactFiles.union([
                    manifestFileName, commitReceiptFileName,
                ]),
                expectedDirectoryMode: 0o555,
                expectedFileMode: 0o444)
        } catch {
            throw ResultError.artifactCorrupt(
                "result file-set/mode validation failed: \(error)")
        }

        let receipt = try readCommitReceipt(
            directory.appendingPathComponent(commitReceiptFileName))
        let manifestSHA256 = CanonicalSourceHasher.sha256(data)
        guard receipt.resultID == resultID,
              receipt.finalPath == resultID,
              receipt.manifestSHA256 == manifestSHA256,
              receipt.commitGeneration == 1 else {
            throw ResultError.invalidManifest("commit receipt mismatch")
        }
        let workbookURL = directory.appendingPathComponent(workbookName)
        guard FileManager.default.fileExists(atPath: workbookURL.path) else {
            throw ResultError.workbookMissing(workbookURL.path)
        }
        // Exact workbook bytes + hash; a corrupted result is isolated.
        let actualWorkbookBytes = fileBytes(workbookURL)
        guard actualWorkbookBytes == Int64(workbookBytes) else {
            throw ResultError.artifactCorrupt(
                "workbook bytes mismatch: \(actualWorkbookBytes) != \(workbookBytes)")
        }
        let actualSHA = try CanonicalSourceHasher.sha256File(workbookURL)
        guard actualSHA == workbookSHA else {
            throw ResultError.artifactCorrupt(
                "workbook sha mismatch: \(actualSHA.prefix(12)) != \(workbookSHA.prefix(12))")
        }
        // Re-verify every per-file artifact: exact bytes + exact SHA
        // (V1R4 §16.3 — reads re-validate everything).
        for artifact in artifacts {
            guard let name = artifact["file"] as? String,
                  let sha = artifact["sha256"] as? String,
                  let bytes = StrictJSONScalar.integer(artifact["bytes"])
            else {
                throw ResultError.invalidManifest("invalid artifact record")
            }
            let url = directory.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw ResultError.artifactMissing(name)
            }
            let actualBytes = fileBytes(url)
            guard actualBytes == Int64(bytes) else {
                throw ResultError.artifactCorrupt(
                    "\(name) bytes mismatch: \(actualBytes) != \(bytes)")
            }
            let actual = try CanonicalSourceHasher.sha256File(url)
            guard actual == sha else {
                throw ResultError.artifactCorrupt(name)
            }
        }
        return ResultEntry(
            resultID: resultID,
            taskID: taskID,
            createdAtUTC: createdAt,
            workbookURL: workbookURL,
            workbookSHA256: workbookSHA,
            directory: directory,
            manifest: manifest)
    }

    /// File size in bytes, or -1 when the file cannot be read.
    private static func fileBytes(_ url: URL) -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else { return -1 }
        return size.int64Value
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

    private static func recoverAndRemoveStaging(_ directory: URL) {
        // A process kill after the pre-rename freeze can leave an
        // uncommitted package at 0555/0444. Thaw only an internal staging
        // path before removing it; committed final paths never reach here.
        try? makeStagingRecoverable(directory)
        try? FileManager.default.removeItem(at: directory)
    }

    private static func readCommitReceipt(_ url: URL) throws -> CommitReceipt {
        let data = try Data(contentsOf: url)
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
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else {
            throw ResultError.commitFailed(
                "cannot open for fsync: \(url.lastPathComponent)")
        }
        defer { close(fd) }
        guard fsync(fd) == 0 else {
            throw ResultError.commitFailed(
                "fsync failed: \(url.lastPathComponent)")
        }
    }
}
