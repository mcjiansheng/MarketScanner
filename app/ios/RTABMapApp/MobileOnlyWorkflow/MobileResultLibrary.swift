import Foundation

/// Immutable on-device result library (V1R1 Gate A / Gate J).
///
/// Layout:
/// ```
/// Application Support/MarketScanner/Results/<result-id>/
///   result_manifest.json     # binds input task, maps and workbook SHA
///   final_trajectory.jsonl
///   final_tags.json
///   quality_report.json
///   rescan_tasks.json
///   input_manifest.json
///   <workbook>.xlsx          # external SHA recorded in the manifest only
/// ```
/// The workbook SHA256 is written *only* into the external
/// `result_manifest.json` — never into the workbook itself — so the
/// manifest never claims a SHA that is not the true final file SHA.
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

        var errorDescription: String? {
            switch self {
            case .cannotCreateRoot(let d): return "无法创建结果目录：\(d)"
            case .invalidManifest(let d): return "结果清单无效：\(d)"
            case .workbookMissing(let d): return "结果工作簿缺失：\(d)"
            }
        }
    }

    static let manifestFileName = "result_manifest.json"

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

    static func resultDirectory(resultID: String) throws -> URL {
        return try root().appendingPathComponent(resultID, isDirectory: true)
    }

    /// Creates the result directory and writes the external manifest.
    /// The caller must move the generated package files and workbook into
    /// the directory *before* calling this (the manifest records the
    /// workbook SHA over the final bytes).
    static func commit(
        resultID: String,
        taskID: String,
        packageFiles: [String],
        workbookFilename: String,
        manifestExtras: [String: Any] = [:]
    ) throws -> ResultEntry {
        let directory = try resultDirectory(resultID: resultID)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        // Hash the final workbook bytes in place (never self-referential).
        let workbookURL = directory.appendingPathComponent(workbookFilename)
        guard fileManager.fileExists(atPath: workbookURL.path) else {
            throw ResultError.workbookMissing(workbookURL.path)
        }
        let workbookData = try Data(contentsOf: workbookURL, options: .mappedIfSafe)
        let workbookSHA = CanonicalSourceHasher.sha256(workbookData)

        var manifest: [String: Any] = [
            "format": "MarketScannerResultManifest",
            "version": 1,
            "result_id": resultID,
            "task_id": taskID,
            "created_at_utc": Date().timeIntervalSince1970,
            "workbook": workbookFilename,
            "workbook_sha256": workbookSHA,
            "workbook_bytes": workbookData.count,
            "package_files": packageFiles.sorted(),
        ]
        for (key, value) in manifestExtras {
            manifest[key] = value
        }
        let data = try CanonicalJSONEncoder.encode(manifest)
        let manifestURL = directory.appendingPathComponent(manifestFileName)
        try data.write(to: manifestURL, options: [.atomic])
        try MobileMapLibrary.syncDirectory(directory)

        return ResultEntry(
            resultID: resultID,
            taskID: taskID,
            createdAtUTC: Date().timeIntervalSince1970,
            workbookURL: workbookURL,
            workbookSHA256: workbookSHA,
            directory: directory,
            manifest: manifest)
    }

    static func listResults() -> [ResultEntry] {
        let fileManager = FileManager.default
        guard let root = try? root(),
              let names = try? fileManager.contentsOfDirectory(atPath: root.path)
        else { return [] }
        var result: [ResultEntry] = []
        for name in names.sorted() {
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
              let resultID = manifest["result_id"] as? String,
              let taskID = manifest["task_id"] as? String,
              let createdAt = manifest["created_at_utc"] as? Double,
              let workbookName = manifest["workbook"] as? String,
              let workbookSHA = manifest["workbook_sha256"] as? String
        else {
            throw ResultError.invalidManifest(manifestURL.path)
        }
        let workbookURL = directory.appendingPathComponent(workbookName)
        guard FileManager.default.fileExists(atPath: workbookURL.path) else {
            throw ResultError.workbookMissing(workbookURL.path)
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
}
