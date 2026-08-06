import Foundation

/// Durable processing-task store (V1R1 Gate A).
///
/// Each processing run owns a task directory under
/// `Application Support/MarketScanner/Processing/<taskID>/`:
/// ```
/// <taskID>/
///   task.json            # persistent state (see PersistentTaskCoordinator)
///   input_manifest.json  # SHA over the immutable input snapshot
///   input_snapshot/      # verified immutable snapshot (DB + sidecars)
///   work/                # verified work copy for processing
///   result/              # result package (see MobileResultLibrary)
/// ```
/// The store is a thin layer over `PersistentTaskCoordinator` and adds
/// discovery/listing plus a workflow-state binding so the app can resume
/// an interrupted run after relaunch.
enum MobileProcessingTaskStore {

    struct TaskSummary {
        var taskID: String
        var state: PersistentTaskCoordinator.TaskState
        var createdAtUTC: Double
        var updatedAtUTC: Double
        var progress: Double
        var error: String?
        var workflowState: MobileOnlyWorkflowState?
    }

    enum StoreError: Error, LocalizedError {
        case cannotCreateRoot(String)
        case invalidTask(String)

        var errorDescription: String? {
            switch self {
            case .cannotCreateRoot(let d): return "无法创建任务目录：\(d)"
            case .invalidTask(let d): return "任务记录无效：\(d)"
            }
        }
    }

    /// Test/embedding hook; see `MobileMapLibrary.rootOverride`.
    static var rootOverride: URL?

    /// `Application Support/MarketScanner/Processing/` (or `rootOverride`).
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
            .appendingPathComponent("Processing", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
        return root
    }

    static func taskRoot(taskID: String) throws -> URL {
        return try root().appendingPathComponent(taskID, isDirectory: true)
    }

    @discardableResult
    static func createTask(taskID: String) throws -> URL {
        let root = try taskRoot(taskID: taskID)
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: root.path) {
            // A retried task reuses its directory; the coordinator must
            // reset stale artifacts before reuse.
            return root
        }
        do {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            _ = try PersistentTaskCoordinator.createTask(taskID: taskID, taskRoot: root)
        } catch {
            throw StoreError.cannotCreateRoot("\(error)")
        }
        return root
    }

    static func listTasks() -> [TaskSummary] {
        let fileManager = FileManager.default
        guard let root = try? root(),
              let names = try? fileManager.contentsOfDirectory(atPath: root.path)
        else { return [] }
        var result: [TaskSummary] = []
        for name in names.sorted() {
            let taskRoot = root.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: taskRoot.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }
            guard let record = try? PersistentTaskCoordinator.read(taskRoot: taskRoot) else {
                continue
            }
            result.append(TaskSummary(
                taskID: record.taskID,
                state: record.state,
                createdAtUTC: record.createdAtUTC,
                updatedAtUTC: record.updatedAtUTC,
                progress: record.progress,
                error: record.error,
                workflowState: workflowStateBinding(for: record)))
        }
        return result.sorted { $0.createdAtUTC > $1.createdAtUTC }
    }

    /// Maps a persistent task state onto the workflow state so the UI can
    /// show one consistent state machine.
    static func workflowStateBinding(for record: PersistentTaskCoordinator.TaskRecord) -> MobileOnlyWorkflowState {
        switch record.state {
        case .created, .snapshotting:
            return .snapshotting
        case .fastOptimizing, .fastQualityCheck:
            return .fastProcessing
        case .deepReprocessing, .deepOptimizing:
            return .deepProcessing
        case .buildingTrajectory, .resamplingTrajectory:
            return .buildingTrajectory
        case .resolvingTags, .buildingRescanTasks:
            return .resolvingTags
        case .buildingWorkbook, .validatingResult, .committingResult:
            return .exporting
        case .completed:
            return .completed
        case .failed:
            return .failed
        case .cancelled:
            return .cancelled
        case .interrupted:
            return .interrupted
        }
    }
}

/// V1R4 §15 Gate L: per-stage durable checkpoints bound to the full run
/// identity.
///
/// Every pipeline stage transition writes `task.json` with the
/// checkpoint below (task ID, input bundle SHA, snapshot path,
/// map/app/native/policy identity, processing path, durable outputs,
/// retry count). On launch the app validates `task.json` and every
/// durable reference and resumes from the last verified snapshot
/// instead of re-reading the mutable source database.
enum PersistentTaskCheckpoint {

    enum Recovery {
        /// No durable snapshot yet: the run starts from scratch (the
        /// snapshot never completed, so there is nothing to re-use).
        case fresh
        /// The verified immutable snapshot exists and matches the
        /// checkpoint: resume without touching the source session.
        case resumeSnapshot(directory: URL, bundleSHA256: String)
    }

    enum CheckpointError: Error, LocalizedError {
        case invalidRecord(String)
        case identityMismatch(String)
        case referenceMissing(String)
        case notResumable(String)

        var errorDescription: String? {
            switch self {
            case .invalidRecord(let d): return "任务检查点无效：\(d)"
            case .identityMismatch(let d): return "任务身份与当前请求不匹配：\(d)"
            case .referenceMissing(let d): return "任务引用缺失：\(d)"
            case .notResumable(let d): return "任务不可恢复：\(d)"
            }
        }
    }

    /// Checkpoint binding keys (write and read sides share this set so
    /// they cannot drift; unknown fields fail the validation).
    static let boundKeys: Set<String> = [
        "task_id",
        "input_bundle_sha256",
        "snapshot_path",
        "map_identity",
        "app_identity",
        "native_identity",
        "policy_identity",
        "processing_path",
        "durable_outputs",
        "retry_count",
    ]

    static func mapIdentity(request: MobileProcessingPipeline.Request) -> [String: Any] {
        return [
            "prior_map_id": request.priorMap.priorMapID,
            "prior_map_sha256": request.priorMap.packageSHA256,
            "canonical_source_sha256": request.priorMap.canonicalSourceSHA256,
        ]
    }

    static func appIdentity(request: MobileProcessingPipeline.Request) -> [String: Any] {
        return ["app_git_sha": request.appGitSHA]
    }

    static func nativeIdentity(request: MobileProcessingPipeline.Request) -> [String: Any] {
        return ["native_core_sha256": request.nativeCoreSHA256]
    }

    static func policyIdentity(request: MobileProcessingPipeline.Request) -> [String: Any] {
        return [
            "policy_sha": request.policySHA,
            "projection_policy_version": 1,
        ]
    }

    /// Checkpoint written BEFORE the snapshot completes: binds the task
    /// ID and the full run identity; no snapshot reference yet.
    static func baseCheckpoint(
        request: MobileProcessingPipeline.Request,
        retryCount: Int
    ) -> [String: Any] {
        return [
            "task_id": request.taskRoot.lastPathComponent,
            "map_identity": mapIdentity(request: request),
            "app_identity": appIdentity(request: request),
            "native_identity": nativeIdentity(request: request),
            "policy_identity": policyIdentity(request: request),
            "processing_path": "",
            "durable_outputs": [],
            "retry_count": retryCount,
        ]
    }

    /// Full checkpoint after the immutable snapshot exists: binds the
    /// input bundle SHA, the snapshot path and the durable outputs
    /// (absolute paths — the result artifacts live outside the task
    /// root, under the result library staging).
    static func snapshotCheckpoint(
        request: MobileProcessingPipeline.Request,
        snapshot: SessionSnapshotTransaction.SessionSnapshot,
        retryCount: Int,
        processingPath: String = "",
        durableOutputs: [String]? = nil
    ) -> [String: Any] {
        var checkpoint = baseCheckpoint(request: request, retryCount: retryCount)
        checkpoint["input_bundle_sha256"] = snapshot.bundleSHA256
        checkpoint["snapshot_path"] = snapshot.snapshotDirectory.path
        checkpoint["processing_path"] = processingPath
        checkpoint["durable_outputs"] = durableOutputs ?? [
            request.taskRoot.appendingPathComponent("input_snapshot").path,
            request.taskRoot.appendingPathComponent("input_manifest.json").path,
        ]
        return checkpoint
    }

    /// Returns `checkpoint` with an updated processing path.
    static func withProcessingPath(_ path: String, in checkpoint: [String: Any]) -> [String: Any] {
        var updated = checkpoint
        updated["processing_path"] = path
        return updated
    }

    /// Returns `checkpoint` with updated durable outputs.
    static func withDurableOutputs(_ outputs: [String], in checkpoint: [String: Any]) -> [String: Any] {
        var updated = checkpoint
        updated["durable_outputs"] = outputs
        return updated
    }

    /// Validates every binding of a persisted checkpoint against the
    /// current request. Any mismatch is fail-closed: a run never
    /// continues under a different identity.
    static func validate(
        _ checkpoint: [String: Any],
        taskRoot: URL,
        request: MobileProcessingPipeline.Request
    ) throws {
        for key in checkpoint.keys where !boundKeys.contains(key) {
            throw CheckpointError.invalidRecord("unknown checkpoint field: \(key)")
        }
        guard let taskID = checkpoint["task_id"] as? String,
              taskID == taskRoot.lastPathComponent else {
            throw CheckpointError.invalidRecord("task_id mismatch")
        }
        try validateSubIdentity(
            "map", expected: mapIdentity(request: request),
            actual: checkpoint["map_identity"] as? [String: Any])
        try validateSubIdentity(
            "app", expected: appIdentity(request: request),
            actual: checkpoint["app_identity"] as? [String: Any])
        try validateSubIdentity(
            "native", expected: nativeIdentity(request: request),
            actual: checkpoint["native_identity"] as? [String: Any])
        try validateSubIdentity(
            "policy", expected: policyIdentity(request: request),
            actual: checkpoint["policy_identity"] as? [String: Any])
    }

    /// V1R4 §15 launch recovery:
    /// - validates `task.json` and every durable reference;
    /// - resumes from the last durable snapshot checkpoint (never
    ///   re-reads the mutable source database);
    /// - refuses to start over in-place for terminal states
    ///   (completed/cancelled/failed) — a new task is never created to
    ///   impersonate a resume.
    static func recover(
        taskRoot: URL,
        request: MobileProcessingPipeline.Request
    ) throws -> Recovery {
        let fileManager = FileManager.default
        let record: PersistentTaskCoordinator.TaskRecord
        do {
            record = try PersistentTaskCoordinator.read(taskRoot: taskRoot)
        } catch {
            throw CheckpointError.invalidRecord("task.json unreadable: \(error)")
        }
        guard PersistentTaskCoordinator.isResumable(record) else {
            throw CheckpointError.notResumable(
                "task is \(record.state.rawValue); refusing to start over in-place")
        }
        guard let checkpoint = record.checkpoint else {
            // No durable checkpoint: the snapshot never completed.
            return .fresh
        }
        try validate(checkpoint, taskRoot: taskRoot, request: request)
        // Verify every declared durable reference still exists.
        if let outputs = checkpoint["durable_outputs"] as? [String] {
            for path in outputs {
                guard fileManager.fileExists(atPath: path) else {
                    throw CheckpointError.referenceMissing(path)
                }
            }
        }
        guard let bundleSHA = checkpoint["input_bundle_sha256"] as? String,
              let snapshotPath = checkpoint["snapshot_path"] as? String else {
            // The snapshot never completed durably: restart from scratch.
            return .fresh
        }
        let snapshotDirectory = URL(fileURLWithPath: snapshotPath)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: snapshotDirectory.path, isDirectory: &isDirectory),
            isDirectory.boolValue else {
            throw CheckpointError.referenceMissing("input_snapshot")
        }
        let manifestURL = snapshotDirectory.appendingPathComponent("input_manifest.json")
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            throw CheckpointError.referenceMissing(
                "input_snapshot/input_manifest.json")
        }
        // The manifest's bundle SHA must match the checkpoint binding.
        let manifest: [String: Any]
        do {
            manifest = try readInputManifest(manifestURL)
        } catch {
            throw CheckpointError.referenceMissing(
                "input_snapshot/input_manifest.json unreadable")
        }
        guard let recorded = manifest["bundle_sha256"] as? String,
              recorded == bundleSHA else {
            throw CheckpointError.referenceMissing(
                "input_manifest bundle_sha256 mismatch with checkpoint")
        }
        return .resumeSnapshot(directory: snapshotDirectory, bundleSHA256: bundleSHA)
    }

    /// Reads the task-level `input_manifest.json` (the same bytes are
    /// committed inside the snapshot directory).
    static func readInputManifest(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        guard let object = try? StrictJSONDocumentParser.object(
            from: data,
            limits: StrictJSONDocumentLimits(maximumBytes: data.count + 1)) as? [String: Any]
        else {
            throw CheckpointError.invalidRecord("input_manifest.json unreadable")
        }
        return object
    }

    private static func validateSubIdentity(
        _ name: String,
        expected: [String: Any],
        actual: [String: Any]?
    ) throws {
        guard let actual = actual,
              actual.count == expected.count,
              expected.allSatisfy({ key, value in
                  (actual[key] as? String) == (value as? String)
              }) else {
            throw CheckpointError.identityMismatch("\(name) identity")
        }
    }
}
