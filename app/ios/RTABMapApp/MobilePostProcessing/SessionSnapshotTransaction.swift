import Foundation

/// Captures a finalized session into a verified private processing
/// snapshot: the input directory is copied once, an input manifest is
/// computed over the stable copy, the source database gets its own
/// immutable copy, and every later processing step reads only the
/// snapshot — never the original session path.
enum SessionSnapshotTransaction {
    struct SessionSnapshot {
        var taskID: String
        var snapshotDirectory: URL
        var inputManifest: [String: Any]
        var bundleSHA256: String
    }

    enum SessionError: Error {
        case sessionMissing
        case notFinalized
        case copyFailed(String)
        case emptyInput
    }

    /// Files that make up a finalized session input bundle.
    static let sessionFileNames = [
        "metadata.json",
        "localization_trace.jsonl",
        "localization_constraints.jsonl",
        "manual_localization_events.jsonl",
        "tag_observations.jsonl",
        "localization_events.jsonl",
        "localization_recovery_events.jsonl",
        "localized_price_tags.json",
    ]

    /// Creates the snapshot for `taskID` under
    /// `Application Support/MarketScanner/Processing/<taskID>/input_snapshot/`
    /// and returns the verified snapshot.
    static func snapshot(
        finalizedSession: URL,
        sourceDatabase: URL,
        taskRoot: URL
    ) throws -> SessionSnapshot {
        let fileManager = FileManager.default
        let taskID = taskRoot.lastPathComponent
        let snapshotDirectory = taskRoot.appendingPathComponent("input_snapshot")
        // The snapshot is idempotent: rebuild from the finalized session
        // so a retried task never mixes old and new input bytes.
        if fileManager.fileExists(atPath: snapshotDirectory.path) {
            try fileManager.removeItem(at: snapshotDirectory)
        }
        try fileManager.createDirectory(
            at: snapshotDirectory, withIntermediateDirectories: true)

        // Copy the finalized session into the private snapshot.
        for name in sessionFileNames {
            let source = finalizedSession.appendingPathComponent(name)
            guard fileManager.fileExists(atPath: source.path) else {
                throw SessionError.sessionMissing
            }
            try fileManager.copyItem(
                at: source, to: snapshotDirectory.appendingPathComponent(name))
        }
        // Immutable source database copy.
        guard fileManager.fileExists(atPath: sourceDatabase.path) else {
            throw SessionError.sessionMissing
        }
        let dbName = sourceDatabase.lastPathComponent
        try fileManager.copyItem(
            at: sourceDatabase,
            to: snapshotDirectory.appendingPathComponent(dbName))

        // Compute the input manifest over the stable snapshot bytes.
        var artifacts: [[String: Any]] = []
        let names = try fileManager.contentsOfDirectory(
            atPath: snapshotDirectory.path).sorted()
        for name in names {
            let data = try Data(contentsOf: snapshotDirectory.appendingPathComponent(name))
            artifacts.append([
                "file": name,
                "bytes": data.count,
                "sha256": CanonicalSourceHasher.sha256(data),
            ])
        }
        guard !artifacts.isEmpty else {
            throw SessionError.emptyInput
        }
        let bundleSHA = MobilePackageManifestBuilder.packageDigest(artifacts)
        let manifest: [String: Any] = [
            "format": "MarketScannerSessionInputManifest",
            "version": 1,
            "task_id": taskID,
            "bundle_sha256": bundleSHA,
            "artifact_count": artifacts.count,
            "artifacts": artifacts,
        ]
        let manifestData = try CanonicalJSONEncoder.encode(manifest)
        try manifestData.write(to: taskRoot.appendingPathComponent("input_manifest.json"))
        return SessionSnapshot(
            taskID: taskID,
            snapshotDirectory: snapshotDirectory,
            inputManifest: manifest,
            bundleSHA256: bundleSHA)
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
