import Darwin
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
        guard MobileResultLibrary.isSafeBasename(taskID) else {
            throw StoreError.invalidTask("unsafe task ID")
        }
        let root = try taskRoot(taskID: taskID)
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: root.path) {
            // Reuse is legal only for a real task record. In particular,
            // never create a replacement task.json over a durable terminal
            // intent left by a failed terminal-state transaction: doing so
            // would discard the earlier business outcome on restart.
            var rootStat = stat()
            guard lstat(root.path, &rootStat) == 0,
                  (rootStat.st_mode & S_IFMT) == S_IFDIR else {
                throw StoreError.invalidTask(
                    "existing task path is not a physical directory")
            }
            let taskFile = PersistentTaskCoordinator.taskFileURL(taskRoot: root)
            if fileManager.fileExists(atPath: taskFile.path) {
                do {
                    let record = try PersistentTaskCoordinator.read(taskRoot: root)
                    guard record.taskID == taskID else {
                        throw StoreError.invalidTask("task identity mismatch")
                    }
                } catch let error as StoreError {
                    throw error
                } catch {
                    throw StoreError.invalidTask(
                        "existing task.json is unreadable: \(error)")
                }
                return root
            }
            do {
                if try MobileTerminalStatePersistence.readIntentIfPresent(
                        taskRoot: root) != nil {
                    throw StoreError.invalidTask(
                        "terminal-state intent exists without task.json; "
                            + "refusing replacement")
                }
            } catch let error as StoreError {
                throw error
            } catch {
                throw StoreError.invalidTask(
                    "terminal-state intent cannot be safely read without "
                        + "task.json: \(error)")
            }
            let entries: [String]
            do {
                entries = try fileManager.contentsOfDirectory(atPath: root.path)
            } catch {
                throw StoreError.invalidTask(
                    "cannot inspect existing task directory: \(error)")
            }
            guard entries.isEmpty else {
                throw StoreError.invalidTask(
                    "task.json is missing from a non-empty task directory")
            }
            do {
                _ = try PersistentTaskCoordinator.createTask(
                    taskID: taskID, taskRoot: root)
            } catch {
                throw StoreError.cannotCreateRoot("\(error)")
            }
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
        case .rescanRequired:
            return .rescanRequired
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
        /// A result commit receipt is already visible and immutable, but
        /// task.json crashed before the `completed` transition. The
        /// pipeline must reconcile this entry instead of re-exporting or
        /// orphaning it.
        case committedResult(MobileResultLibrary.ResultEntry)
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
        "terminal_outcome",
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

    /// Full checkpoint after the immutable snapshot exists. Every path is
    /// root-relative and namespace-qualified; absolute container paths
    /// are forbidden because they are neither portable nor safely
    /// containable after restore.
    static func snapshotCheckpoint(
        request: MobileProcessingPipeline.Request,
        snapshot: SessionSnapshotTransaction.SessionSnapshot,
        retryCount: Int,
        processingPath: String = "",
        durableOutputs: [String]? = nil
    ) -> [String: Any] {
        var checkpoint = baseCheckpoint(request: request, retryCount: retryCount)
        checkpoint["input_bundle_sha256"] = snapshot.bundleSHA256
        checkpoint["snapshot_path"] = "input_snapshot"
        checkpoint["processing_path"] = processingPath
        checkpoint["durable_outputs"] = durableOutputs ?? [
            taskReference("input_snapshot"),
            taskReference("input_manifest.json"),
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

    /// Binds the dedicated session-level rescan artifact into the same
    /// identity-checked checkpoint used by restart recovery. The artifact
    /// lives under the task namespace and is never a normal Result output.
    static func withSessionRescanOutcome(
        artifactSHA256: String,
        in checkpoint: [String: Any]
    ) -> [String: Any] {
        var updated = checkpoint
        let reference = taskReference(
            MobileProcessingPipeline.sessionRescanArtifactFileName)
        updated["terminal_outcome"] = [
            "code": "RESCAN_SESSION",
            "artifact": reference,
            "sha256": artifactSHA256,
        ]
        var outputs = updated["durable_outputs"] as? [String] ?? []
        if !outputs.contains(reference) {
            outputs.append(reference)
        }
        updated["durable_outputs"] = outputs
        return updated
    }

    static func taskReference(_ relativePath: String) -> String {
        return "task:\(relativePath)"
    }

    static func resultStagingReference(
        taskID: String,
        resultID: String,
        relativePath: String
    ) -> String {
        return "result_staging:\(taskID)/\(resultID)/\(relativePath)"
    }

    static func resultReference(
        resultID: String,
        relativePath: String
    ) -> String {
        return "result:\(resultID)/\(relativePath)"
    }

    static func withCommittedResult(
        _ entry: MobileResultLibrary.ResultEntry,
        in checkpoint: [String: Any]
    ) -> [String: Any] {
        let artifactNames = ((entry.manifest["artifacts"] as? [[String: Any]]) ?? [])
            .compactMap { $0["file"] as? String }
        let outputs = [
            taskReference("input_snapshot"),
            taskReference("input_manifest.json"),
        ] + (artifactNames + [
            MobileResultLibrary.manifestFileName,
            MobileResultLibrary.commitReceiptFileName,
        ]).map {
            resultReference(resultID: entry.resultID, relativePath: $0)
        }
        return withDurableOutputs(outputs, in: checkpoint)
    }

    /// Extracts the single result identity named by a committing or
    /// completed checkpoint. This identity is used to make an invalid
    /// receipt/manifest at the expected final path a hard recovery error
    /// instead of treating it as "no result" and terminalizing the task
    /// as a generic failure.
    static func expectedCommittedResultIDs(
        in checkpoint: [String: Any]?,
        taskID: String
    ) throws -> Set<String> {
        guard let checkpoint else { return [] }
        guard let outputs = checkpoint["durable_outputs"] as? [String] else {
            return []
        }
        var resultIDs = Set<String>()
        for reference in outputs {
            if reference.hasPrefix("result_staging:") {
                let relative = String(reference.dropFirst("result_staging:".count))
                let components = relative.split(
                    separator: "/", omittingEmptySubsequences: false)
                guard components.count == 3,
                      String(components[0]) == taskID,
                      MobileResultLibrary.isSafeBasename(String(components[1])),
                      MobileResultLibrary.isSafeBasename(String(components[2])) else {
                    throw CheckpointError.invalidRecord(
                        "invalid result_staging reference during commit recovery")
                }
                resultIDs.insert(String(components[1]))
            } else if reference.hasPrefix("result:") {
                let relative = String(reference.dropFirst("result:".count))
                let components = relative.split(
                    separator: "/", omittingEmptySubsequences: false)
                guard components.count == 2,
                      MobileResultLibrary.isSafeBasename(String(components[0])),
                      MobileResultLibrary.isSafeBasename(String(components[1])) else {
                    throw CheckpointError.invalidRecord(
                        "invalid result reference during commit recovery")
                }
                resultIDs.insert(String(components[0]))
            }
        }
        guard resultIDs.count <= 1 else {
            throw CheckpointError.invalidRecord(
                "checkpoint names multiple result identities")
        }
        return resultIDs
    }

    /// Exact transaction binding used both by the immediate catch path
    /// and by launch recovery. The immutable package alone is not enough:
    /// its manifest must belong to the same task, snapshot, map, policy,
    /// native core and processing route as the persisted checkpoint.
    static func validateCommittedResult(
        _ entry: MobileResultLibrary.ResultEntry,
        checkpoint: [String: Any],
        taskRoot: URL,
        request: MobileProcessingPipeline.Request
    ) throws {
        try validate(checkpoint, taskRoot: taskRoot, request: request)
        let manifest = entry.manifest
        guard entry.taskID == taskRoot.lastPathComponent,
              manifest["task_id"] as? String == entry.taskID,
              manifest["result_id"] as? String == entry.resultID,
              manifest["store_id"] as? String == request.storeID,
              manifest["prior_map_id"] as? String == request.priorMap.priorMapID,
              manifest["prior_map_sha256"] as? String
                == request.priorMap.packageSHA256,
              manifest["tracking_session_id"] as? String
                == request.trackingSessionID,
              manifest["source_database"] as? String
                == request.sourceDatabase.lastPathComponent,
              manifest["native_core_sha256"] as? String
                == request.nativeCoreSHA256,
              manifest["policy_sha"] as? String == request.policySHA,
              StrictJSONScalar.integer(
                manifest["projection_policy_version"]) == 1,
              let inputBundleSHA256 = checkpoint["input_bundle_sha256"] as? String,
              manifest["input_bundle_sha256"] as? String
                == inputBundleSHA256,
              let processingPath = checkpoint["processing_path"] as? String,
              !processingPath.isEmpty,
              manifest["processing_path"] as? String == processingPath,
              validSHA256(manifest["trajectory_sha256"]),
              validSHA256(manifest["graph_quality_sha256"]),
              exactNonnegativeCount("device_position_count", in: manifest) != nil,
              exactNonnegativeCount("available_position_count", in: manifest) != nil,
              exactNonnegativeCount("tag_count", in: manifest) != nil,
              exactNonnegativeCount("rescan_count", in: manifest) != nil else {
            throw CheckpointError.identityMismatch(
                "committed result manifest/checkpoint binding")
        }
        let expectedIDs = try expectedCommittedResultIDs(
            in: checkpoint, taskID: entry.taskID)
        guard expectedIDs == Set([entry.resultID]) else {
            throw CheckpointError.identityMismatch(
                "committed result identity/checkpoint binding")
        }
    }

    static func exactNonnegativeCount(
        _ key: String,
        in manifest: [String: Any]
    ) -> Int? {
        guard let value = StrictJSONScalar.integer(manifest[key]), value >= 0 else {
            return nil
        }
        return value
    }

    private static func validSHA256(_ value: Any?) -> Bool {
        guard let value = value as? String, value.count == 64 else {
            return false
        }
        return value.allSatisfy {
            ("0"..."9").contains($0) || ("a"..."f").contains($0)
        }
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
        if let terminalOutcome = checkpoint["terminal_outcome"] {
            guard let outcome = terminalOutcome as? [String: Any],
                  Set(outcome.keys) == Set(["code", "artifact", "sha256"]),
                  outcome["code"] as? String == "RESCAN_SESSION",
                  outcome["artifact"] as? String == taskReference(
                    MobileProcessingPipeline.sessionRescanArtifactFileName),
                  let artifactSHA256 = outcome["sha256"] as? String,
                  let inputBundleSHA256 = checkpoint["input_bundle_sha256"] as? String else {
                throw CheckpointError.invalidRecord(
                    "invalid RESCAN_SESSION terminal_outcome binding")
            }
            try MobileProcessingPipeline.validateSessionRescanArtifact(
                taskRoot: taskRoot,
                request: request,
                inputBundleSHA256: inputBundleSHA256,
                expectedSHA256: artifactSHA256)
        }
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
        do {
            // P1-11: a durable terminal intent always takes precedence
            // over ordinary intermediate-stage resume. Reconciliation is
            // idempotent; failure remains a typed, fail-closed checkpoint
            // error rather than silently reviving a cancelled/failed run.
            try MobileTerminalStatePersistence.reconcilePendingIntent(
                taskRoot: taskRoot)
        } catch {
            throw CheckpointError.invalidRecord(
                "terminal-state intent reconciliation failed: \(error)")
        }
        let record: PersistentTaskCoordinator.TaskRecord
        do {
            record = try PersistentTaskCoordinator.read(taskRoot: taskRoot)
        } catch {
            throw CheckpointError.invalidRecord("task.json unreadable: \(error)")
        }
        if record.state == .rescanRequired {
            guard record.error == "rescan_session_required",
                  let checkpoint = record.checkpoint else {
                throw CheckpointError.invalidRecord(
                    "rescan_required task lacks its exact reason/checkpoint")
            }
            // A restart may have just replayed a pending terminal intent.
            // Validate the hash-bound no-publish artifact before treating
            // the task as a legitimate terminal RESCAN_SESSION outcome.
            try validate(checkpoint, taskRoot: taskRoot, request: request)
            guard try MobileResultLibrary.committedResult(
                    taskID: record.taskID) == nil else {
                throw CheckpointError.invalidRecord(
                    "rescan_required task also owns a committed Result")
            }
            throw CheckpointError.notResumable(
                "task is rescan_required; refusing to start over in-place")
        }
        if record.state == .committingResult {
            guard let checkpoint = record.checkpoint else {
                throw CheckpointError.invalidRecord(
                    "committing_result has no checkpoint")
            }
            let expectedResultIDs = try expectedCommittedResultIDs(
                in: checkpoint, taskID: record.taskID)
            guard expectedResultIDs.count == 1 else {
                throw CheckpointError.invalidRecord(
                    "committing_result checkpoint has no unique result identity")
            }
            if let committed = try MobileResultLibrary.committedResult(
                    taskID: record.taskID,
                    expectedResultIDs: expectedResultIDs) {
                try validateCommittedResult(
                    committed,
                    checkpoint: checkpoint,
                    taskRoot: taskRoot,
                    request: request)
                return .committedResult(committed)
            }
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
            for reference in outputs {
                let url = try resolveReference(
                    reference, taskRoot: taskRoot, taskID: record.taskID)
                guard fileManager.fileExists(atPath: url.path) else {
                    throw CheckpointError.referenceMissing(reference)
                }
            }
        }
        guard let bundleSHA = checkpoint["input_bundle_sha256"] as? String,
              let snapshotPath = checkpoint["snapshot_path"] as? String else {
            // The snapshot never completed durably: restart from scratch.
            return .fresh
        }
        guard isSafeRelativePath(snapshotPath) else {
            throw CheckpointError.invalidRecord("unsafe snapshot_path")
        }
        let snapshotDirectory = taskRoot.appendingPathComponent(snapshotPath)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: snapshotDirectory.path, isDirectory: &isDirectory),
            isDirectory.boolValue else {
            throw CheckpointError.referenceMissing("input_snapshot")
        }
        // V1R5 §13.6 (review H-14): resume re-validates the FULL
        // snapshot — manifest, every artifact's exact bytes + SHA-256,
        // the DB quick-check and the WAL/journal contract. "The file
        // exists" is never enough to resume from a checkpoint.
        do {
            try SessionSnapshotTransaction.revalidateSnapshot(snapshotDirectory)
        } catch let error as SessionSnapshotTransaction.SessionError {
            throw CheckpointError.referenceMissing(
                "input_snapshot re-validation failed: \(error.localizedDescription)")
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

    private static func resolveReference(
        _ reference: String,
        taskRoot: URL,
        taskID: String
    ) throws -> URL {
        guard let separator = reference.firstIndex(of: ":") else {
            throw CheckpointError.invalidRecord(
                "durable reference lacks namespace")
        }
        let namespace = String(reference[..<separator])
        let relative = String(reference[reference.index(after: separator)...])
        guard isSafeRelativePath(relative) else {
            throw CheckpointError.invalidRecord(
                "unsafe durable reference: \(reference)")
        }
        if namespace == "result_staging" {
            let components = relative.split(
                separator: "/", omittingEmptySubsequences: false)
            guard components.count == 3,
                  String(components[0]) == taskID else {
                throw CheckpointError.identityMismatch(
                    "result staging task/reference identity")
            }
            let resultID = String(components[1])
            let artifactName = String(components[2])
            let stagingRoot = try MobileResultLibrary.stagingDirectoryURL(
                taskID: taskID, resultID: resultID)
            let resolved = stagingRoot.appendingPathComponent(artifactName)
            try rejectSymlinkComponents(resolved, beneath: stagingRoot)
            return resolved
        }
        let base: URL
        switch namespace {
        case "task":
            base = taskRoot
        case "result":
            base = try MobileResultLibrary.root()
        default:
            throw CheckpointError.invalidRecord(
                "unknown durable reference namespace: \(namespace)")
        }
        let resolved = base.appendingPathComponent(relative)
        try rejectSymlinkComponents(resolved, beneath: base)
        return resolved
    }

    private static func isSafeRelativePath(_ value: String) -> Bool {
        guard !value.isEmpty, !value.hasPrefix("/"),
              !value.contains("\\"), value.utf8.count <= 1024 else {
            return false
        }
        let components = value.split(
            separator: "/", omittingEmptySubsequences: false)
        return !components.isEmpty && components.allSatisfy {
            MobileResultLibrary.isSafeBasename(String($0))
        }
    }

    private static func rejectSymlinkComponents(
        _ url: URL,
        beneath base: URL
    ) throws {
        let baseComponents = base.standardizedFileURL.pathComponents
        let targetComponents = url.standardizedFileURL.pathComponents
        guard targetComponents.starts(with: baseComponents) else {
            throw CheckpointError.invalidRecord("reference escapes root")
        }
        var baseStat = stat()
        guard lstat(base.path, &baseStat) == 0,
              (baseStat.st_mode & S_IFMT) == S_IFDIR else {
            throw CheckpointError.invalidRecord("durable reference root invalid")
        }
        // The container path itself may legitimately traverse an OS-owned
        // alias such as /var -> /private/var on Apple platforms. The trust
        // boundary is the verified task/result root; reject symlinks only
        // in caller-controlled components beneath that root.
        var cursor = base
        for component in targetComponents.dropFirst(baseComponents.count) {
            cursor.appendPathComponent(component)
            var value = stat()
            if lstat(cursor.path, &value) == 0,
               (value.st_mode & S_IFMT) == S_IFLNK {
                throw CheckpointError.invalidRecord(
                    "symlink in durable reference")
            }
        }
    }
}
