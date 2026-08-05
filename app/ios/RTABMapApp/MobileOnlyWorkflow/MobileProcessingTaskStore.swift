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
