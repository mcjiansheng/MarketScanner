import Foundation

/// Immutable on-device result library (V1R3 Gate Q §20).
///
/// Layout:
/// ```
/// Application Support/MarketScanner/Results/
///   staging/<task-id>/<result-id>/   # all artifacts written here first
///   <result-id>/                     # atomic rename target (immutable)
///     result_manifest.json           # per-file SHA + bindings
///     final_trajectory.jsonl
///     final_tags.json / graph_quality.json / quality_report.json
///     rescan_tasks.json / input_manifest.json
///     <workbook>.xlsx                # SHA recorded in the manifest only
/// ```
/// Commit protocol (§20.4): validate every staged artifact, fsync the
/// files and the staging directory, atomic rename into the library root,
/// fsync the parent. A failed run never becomes visible in the library.
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
        return try root().appendingPathComponent(resultID, isDirectory: true)
    }

    /// Staging location where the pipeline writes every artifact before
    /// the atomic commit (§20.1).
    static func stagingDirectory(taskID: String, resultID: String) throws -> URL {
        let directory = try root()
            .appendingPathComponent("staging", isDirectory: true)
            .appendingPathComponent(taskID, isDirectory: true)
            .appendingPathComponent(resultID, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// V1R4 §16.4/§15: removes every UNCOMMITTED staging directory of a
    /// task (crash leftovers). Committed results live outside `staging/`
    /// and are never touched.
    static func cleanupStaging(taskID: String) {
        let fileManager = FileManager.default
        guard let root = try? root() else { return }
        let stagingRoot = root
            .appendingPathComponent("staging", isDirectory: true)
            .appendingPathComponent(taskID, isDirectory: true)
        guard let names = try? fileManager.contentsOfDirectory(atPath: stagingRoot.path) else {
            return
        }
        for name in names {
            try? fileManager.removeItem(
                at: stagingRoot.appendingPathComponent(name))
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
        let finalDirectory = try resultDirectory(resultID: resultID)

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
        var manifest: [String: Any] = [
            "format": "MarketScannerResultManifest",
            "version": 2,
            "result_id": resultID,
            "task_id": taskID,
            "created_at_utc": Date().timeIntervalSince1970,
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
        let stagedManifestURL = stagingDirectory.appendingPathComponent(manifestFileName)
        try manifestData.write(to: stagedManifestURL, options: [.atomic])

        // 3. fsync every staged file and the staging directory (V1R5
        //    §13.1 / review H-01: any open/fsync failure blocks the
        //    commit — durability is never best-effort).
        for name in packageFiles + [workbookFilename, manifestFileName] {
            try syncFile(stagingDirectory.appendingPathComponent(name))
        }
        try MobileMapLibrary.syncDirectory(stagingDirectory)

        // 4. Atomic rename into the library root + parent fsync.
        do {
            if fileManager.fileExists(atPath: finalDirectory.path) {
                throw ResultError.commitFailed("result already exists: \(resultID)")
            }
            try fileManager.moveItem(at: stagingDirectory, to: finalDirectory)
        } catch let error as ResultError {
            throw error
        } catch {
            throw ResultError.commitFailed("\(error)")
        }
        try MobileMapLibrary.syncDirectory(try root())

        // V1R5 §13.1 / review H-02: a committed result is IMMUTABLE —
        // recursive read-only (files 0444, directories 0555) before the
        // registry entry may report success. A chmod failure blocks the
        // commit (no success is reported for a mutable artifact).
        try freezeImmutably(finalDirectory)

        return ResultEntry(
            resultID: resultID,
            taskID: taskID,
            createdAtUTC: Date().timeIntervalSince1970,
            workbookURL: finalDirectory.appendingPathComponent(workbookFilename),
            workbookSHA256: workbookSHA,
            directory: finalDirectory,
            manifest: manifest)
    }

    /// Recursively makes a committed result read-only: files 0444,
    /// directories 0555, then the directory itself (V1R5 §13.1). Any
    /// failure throws — the result must not be reported as committed
    /// while mutable.
    private static func freezeImmutably(_ directory: URL) throws {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]) else {
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
            [.posixPermissions: 0o555],
            ofItemAtPath: directory.path)
    }

    /// Lists committed results, re-validating each manifest and the
    /// workbook hash (§20.5). Corrupted results are isolated (skipped),
    /// never silently listed.
    static func listResults() -> [ResultEntry] {
        let fileManager = FileManager.default
        guard let root = try? root(),
              let names = try? fileManager.contentsOfDirectory(atPath: root.path)
        else { return [] }
        var result: [ResultEntry] = []
        for name in names.sorted() where name != "staging" {
            let directory = root.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  let entry = try? readResult(in: directory)
            else { continue }
            result.append(entry)
        }
        return result.sorted { $0.createdAtUTC > $1.createdAtUTC }
    }

    static func readResult(resultID: String) throws -> ResultEntry {
        return try readResult(in: resultDirectory(resultID: resultID))
    }

    private static func readResult(in directory: URL) throws -> ResultEntry {
        let manifestURL = directory.appendingPathComponent(manifestFileName)
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
              let createdAt = manifest["created_at_utc"] as? Double,
              let workbookName = manifest["workbook"] as? String,
              let workbookSHA = manifest["workbook_sha256"] as? String,
              let workbookBytes = StrictJSONScalar.integer(manifest["workbook_bytes"]),
              let packageFiles = manifest["package_files"] as? [String],
              let artifacts = manifest["artifacts"] as? [[String: Any]]
        else {
            throw ResultError.invalidManifest(manifestURL.path)
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
    private static func isSafeBasename(_ name: String) -> Bool {
        guard !name.isEmpty, name != ".", name != ".." else { return false }
        return !name.contains("/") && !name.contains("\\")
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
