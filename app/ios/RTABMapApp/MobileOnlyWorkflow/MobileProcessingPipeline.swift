import Darwin
import Foundation
import CryptoKit

/// End-to-end mobile processing pipeline (V1R1 Gate E/F/H/I/J).
///
/// Input: a finalized session directory (segment_0001) plus its source
/// database and a phone-compiled prior map from the on-device library.
/// Output: an immutable result package under the result library whose
/// workbook SHA256 is recorded only in the external result manifest.
///
/// Stages:
/// 1. P7R6D-grade immutable session snapshot (never touches the source DB).
/// 2. Read localization evidence (real sidecars) and the prior map.
/// 3. Fast Path: relative SE(2) factor-graph optimization over the
///    localized nodes.
/// 4. Final trajectory: one row per UTC second (1 Hz DevicePositions).
/// 5. Tag finalization: resolve -> cluster -> shelf association ->
///    automatic quality gate (ACCEPTED / LOW_CONFIDENCE /
///    RESCAN_REQUIRED).
/// 6. Result package files + streaming four-sheet XLSX + external
///    manifest commit.
enum MobileProcessingPipeline {

    /// Dedicated task-local terminal artifact. It is deliberately outside
    /// `MobileResultLibrary`: a RESCAN_SESSION outcome must remain visible
    /// and restart-safe without publishing PriceTags, DevicePositions, a
    /// workbook, or any ordinary Result entry.
    static let sessionRescanArtifactFileName = "rescan_session_outcome.json"
    static let maximumSessionRescanArtifactBytes = 256 * 1024

    enum SessionRescanArtifactWriteStage: String {
        case beforeTemporaryWrite = "before_temporary_write"
        case afterTemporaryFsync = "after_temporary_fsync"
        case afterRename = "after_rename"
        case afterParentFsync = "after_parent_fsync"
    }

    /// Host-test crash/failure injection at every durability boundary.
    static var sessionRescanArtifactWriteFaultInjector:
        ((SessionRescanArtifactWriteStage) throws -> Void)?

    enum SessionRescanArtifactError: Error, LocalizedError {
        case invalid(String)
        case conflictingOutcome(String)
        case cannotWrite(String)

        var errorDescription: String? {
            switch self {
            case .invalid(let detail):
                return "RESCAN_SESSION artifact invalid: \(detail)"
            case .conflictingOutcome(let detail):
                return "RESCAN_SESSION artifact outcome conflicts: \(detail)"
            case .cannotWrite(let detail):
                return "RESCAN_SESSION artifact write failed: \(detail)"
            }
        }
    }

    private struct SessionRescanArtifactRecord {
        var sha256: String
        var processingPath: String
        var graphDisposition: String
        var reasonCode: String
        var humanMessage: String
    }

    struct Request {
        var finalizedSession: URL
        var sourceDatabase: URL
        var taskRoot: URL
        var priorMap: MobileMapLibrary.MapEntry
        var storeID: String
        /// B-08: authoritative floor identity of the run. Never nil/default:
        /// the snapshot eligibility chain validates it fail-closed against
        /// the metadata, and the pipeline rejects an empty value.
        var floorID: String
        var trackingSessionID: String
        var appGitSHA: String
        var appVersion: String
        var deviceModel: String
        var osVersion: String
        /// Exact source SHA of the shared native factor-graph core used
        /// for this run (§14.4 binding). Empty on legacy callers.
        var nativeCoreSHA256: String = ""
        /// SHA of the processing policy in effect (§5.2 policy_sha).
        /// Empty on legacy callers.
        var policySHA: String = ""
    }

    struct Outcome {
        var resultEntry: MobileResultLibrary.ResultEntry
        var devicePositionCount: Int
        var availablePositionCount: Int
        var tagCount: Int
        var rescanCount: Int
    }

    enum PipelineError: Error, LocalizedError {
        case missingMetadata
        case emptyTrace
        case noOptimizedNodes
        case emptyGraph
        case qualityGateRejected(String)
        case cannotBuildWorkbook(String)
        case invalidPriorMap(String)
        case clockEvidenceIncomplete(String)
        case tagEvidenceInvalid(String)

        var errorDescription: String? {
            switch self {
            case .missingMetadata: return "会话元数据缺失"
            case .emptyTrace: return "本地化轨迹为空，无法处理"
            case .noOptimizedNodes: return "优化后没有可用节点"
            case .emptyGraph: return "会话数据库中没有可读取的 RTAB-Map 图"
            case .qualityGateRejected(let detail): return "质量门拒绝发布：\(detail)"
            case .cannotBuildWorkbook(let d): return "工作簿生成失败：\(d)"
            case .invalidPriorMap(let d): return "先验地图无效：\(d)"
            case .clockEvidenceIncomplete(let d): return "时钟证据不足，无法发布：\(d)"
            case .tagEvidenceInvalid(let d): return "价签观测证据存在坏记录，无法发布：\(d)"
            }
        }
    }

    // MARK: - Run

    static func run(
        request: Request,
        progress: (Double, String) -> Void,
        isCancelled: @escaping () -> Bool
    ) throws -> Outcome {
        do {
            return try runPipeline(
                request: request, progress: progress, isCancelled: isCancelled)
        } catch let error as PersistentTaskCheckpoint.CheckpointError {
            // Task-record/reference/identity failures never overwrite an
            // existing terminal state (fail closed).
            throw error
        } catch {
            // The result publication transaction crosses two durable
            // stores: an immutable Result becomes visible first, then
            // task.json advances from committing_result to completed. A
            // fault after the exclusive result rename (including the
            // completed-task writer's own crash boundaries) must never be
            // reclassified by generic terminal persistence as `failed`.
            // Reopen and fully validate the one receipt/result owned by
            // this task; if it exists, finish or verify the exact
            // completed checkpoint and return that committed outcome.
            do {
                if let recovered = try reconcileCommittedResultAfterFailure(
                        request: request) {
                    return recovered
                }
            } catch let recoveryError as PersistentTaskCheckpoint.CheckpointError {
                throw recoveryError
            } catch {
                throw PersistentTaskCheckpoint.CheckpointError.invalidRecord(
                    "committed-result failure reconciliation blocked: \(error)")
            }
            // RESCAN_SESSION has the same cross-file durability window:
            // its immutable task-local artifact is published before the
            // checkpoint binding and terminal task state. Once that final
            // artifact is visible, a later writer fault must never be
            // mapped to generic workflow_failed. Reopen it by exact task /
            // snapshot identity, repair the parent fsync, and ensure the
            // hash-bound checkpoint exists before terminal persistence.
            do {
                if let rescanError = try reconcileSessionRescanOutcomeAfterFailure(
                        request: request,
                        originalError: error) {
                    do {
                        try MobileTerminalStatePersistence.persistThenRethrow(
                            rescanError, taskRoot: request.taskRoot)
                    } catch let durabilityError
                            as MobileTerminalStatePersistence.DurabilityFailure {
                        // A task writer can throw after its rename or after
                        // parent fsync even though rescan_required is already
                        // durable. Accept only an exact artifact/checkpoint/
                        // state reread, and reconcile the matching intent.
                        if try reconcileExactSessionRescanTerminalIfPresent(
                                request: request) {
                            throw rescanError
                        }
                        throw durabilityError
                    } catch {
                        throw error
                    }
                }
            } catch let recoveryError as PersistentTaskCheckpoint.CheckpointError {
                throw recoveryError
            } catch let workflowError as MobileOnlyWorkflowError {
                throw workflowError
            } catch let durabilityError
                    as MobileTerminalStatePersistence.DurabilityFailure {
                throw durabilityError
            } catch {
                throw PersistentTaskCheckpoint.CheckpointError.invalidRecord(
                    "RESCAN_SESSION failure reconciliation blocked: \(error)")
            }
            // P1-11: the production-shared helper durably establishes a
            // terminal intent, persists the mapped terminal task state,
            // clears the intent, then rethrows the ORIGINAL business
            // error. Any persistence failure instead throws a typed
            // DurabilityFailure carrying both outcome and storage detail.
            try MobileTerminalStatePersistence.persistThenRethrow(
                error, taskRoot: request.taskRoot)
        }
    }

    private static func runPipeline(
        request: Request,
        progress: (Double, String) -> Void,
        isCancelled: @escaping () -> Bool
    ) throws -> Outcome {
        // V1R4 §12.4: reset the run-scoped resource diagnostics so the
        // RunSummary reports this run's REAL peak RSS / thermal samples.
        ProcessingResourceGovernor.beginRun()
        defer { ProcessingResourceGovernor.endRun() }
        // Cancel latency (§12.4): measured from the first moment the
        // cancellation probe returns true until the run actually stops.
        var cancelRequestedAt: Double?
        func checkCancelled() throws {
            let now = isCancelled()
            if now && cancelRequestedAt == nil {
                cancelRequestedAt = Date().timeIntervalSince1970
            }
            if now { throw MobileOnlyWorkflowError.cancelled }
        }
        // V1R4 §15 Gate L: launch recovery. The persisted task.json is
        // validated together with every durable reference; a verified
        // snapshot is resumed without ever re-reading the mutable
        // source database, and a terminal task (completed/cancelled/
        // failed) is never restarted in-place. Bootstrap/recovery MUST
        // happen before any business eligibility check so every later
        // failure has an existing task.json to receive its terminal state.
        let taskFileURL = PersistentTaskCoordinator.taskFileURL(taskRoot: request.taskRoot)
        let recovery: PersistentTaskCheckpoint.Recovery
        var existingTaskRecord: PersistentTaskCoordinator.TaskRecord?
        var retryCount = 0
        if FileManager.default.fileExists(atPath: taskFileURL.path) {
            let existing = try PersistentTaskCoordinator.read(
                taskRoot: request.taskRoot)
            existingTaskRecord = existing
            if let checkpoint = existing.checkpoint {
                retryCount = ((checkpoint["retry_count"] as? NSNumber)?.intValue ?? 0) + 1
            }
            recovery = try PersistentTaskCheckpoint.recover(
                taskRoot: request.taskRoot, request: request)
        } else {
            do {
                guard try MobileTerminalStatePersistence.readIntentIfPresent(
                        taskRoot: request.taskRoot) == nil else {
                    throw PersistentTaskCheckpoint.CheckpointError.invalidRecord(
                        "terminal-state intent exists without task.json; "
                            + "refusing to create a replacement task record")
                }
            } catch let error as PersistentTaskCheckpoint.CheckpointError {
                throw error
            } catch {
                throw PersistentTaskCheckpoint.CheckpointError.invalidRecord(
                    "terminal-state intent cannot be safely read without "
                        + "task.json: \(error)")
            }
            if FileManager.default.fileExists(atPath: request.taskRoot.path) {
                let entries: [String]
                do {
                    entries = try FileManager.default.contentsOfDirectory(
                        atPath: request.taskRoot.path)
                } catch {
                    throw PersistentTaskCheckpoint.CheckpointError.invalidRecord(
                        "cannot inspect task directory without task.json: \(error)")
                }
                guard entries.isEmpty else {
                    throw PersistentTaskCheckpoint.CheckpointError.invalidRecord(
                        "task.json is missing from a non-empty task directory")
                }
            }
            _ = try PersistentTaskCoordinator.createTask(
                taskID: request.taskRoot.lastPathComponent,
                taskRoot: request.taskRoot)
            recovery = .fresh
        }
        // V1R3 §8.1 eligibility: an unknown build identity must never
        // reach a publishable session. Because task bootstrap is already
        // durable, this early rejection is recorded as a terminal failure
        // instead of leaving an orphan intent with no task.json.
        guard request.appGitSHA != "unknown", !request.appGitSHA.isEmpty else {
            throw MobileOnlyWorkflowError.invalidState(
                "app build identity is unknown; processing is blocked")
        }
        if case .committedResult(let entry) = recovery {
            guard let checkpoint = existingTaskRecord?.checkpoint else {
                throw PersistentTaskCheckpoint.CheckpointError.invalidRecord(
                    "committed result has no task checkpoint")
            }
            // The prior process may have stopped immediately after the
            // exclusive final rename and before the library-parent fsync.
            // Repair that boundary and reopen the immutable package before
            // the task is allowed to become completed.
            do {
                try MobileMapLibrary.syncDirectory(entry.directory)
                try MobileMapLibrary.syncDirectory(try MobileResultLibrary.root())
            } catch {
                throw PersistentTaskCheckpoint.CheckpointError.invalidRecord(
                    "committed result cannot be synchronized on restart: \(error)")
            }
            let reopened: MobileResultLibrary.ResultEntry
            do {
                reopened = try MobileResultLibrary.readResult(
                    resultID: entry.resultID)
            } catch {
                throw PersistentTaskCheckpoint.CheckpointError.invalidRecord(
                    "committed result cannot be reopened on restart: \(error)")
            }
            try PersistentTaskCheckpoint.validateCommittedResult(
                reopened,
                checkpoint: checkpoint,
                taskRoot: request.taskRoot,
                request: request)
            let completedCheckpoint = PersistentTaskCheckpoint
                .withCommittedResult(reopened, in: checkpoint)
            try PersistentTaskCoordinator.updateState(
                .completed, taskRoot: request.taskRoot, progress: 1.0,
                checkpoint: completedCheckpoint,
                clearError: true)
            return outcome(from: reopened)
        }
        // §16.4: remove crash-leftover uncommitted result staging of
        // this task (committed results are never touched).
        MobileResultLibrary.cleanupStaging(taskID: request.taskRoot.lastPathComponent)

        progress(0.05, "生成会话快照")
        try ProcessingResourceGovernor.checkBudget(
            stage: "snapshot",
            estimate: estimateTask(sourceDatabase: request.sourceDatabase))
        let snapshot: SessionSnapshotTransaction.SessionSnapshot
        switch recovery {
        case .fresh:
            try PersistentTaskCoordinator.updateState(
                .snapshotting, taskRoot: request.taskRoot, progress: 0.05,
                checkpoint: PersistentTaskCheckpoint.baseCheckpoint(
                    request: request, retryCount: retryCount),
                clearError: true)
            snapshot = try SessionSnapshotTransaction.snapshot(
                finalizedSession: request.finalizedSession,
                sourceDatabase: request.sourceDatabase,
                taskRoot: request.taskRoot,
                eligibility: SessionSnapshotTransaction.Eligibility(
                    priorMapID: request.priorMap.priorMapID,
                    priorMapSHA256: request.priorMap.packageSHA256,
                    storeID: request.storeID,
                    floorID: request.floorID,
                    appGitSHA: request.appGitSHA))
            // The snapshot is durable now: bind the input bundle SHA and
            // the snapshot path (§15 checkpoint).
            try PersistentTaskCoordinator.updateState(
                .snapshotting, taskRoot: request.taskRoot, progress: 0.12,
                checkpoint: PersistentTaskCheckpoint.snapshotCheckpoint(
                    request: request, snapshot: snapshot,
                    retryCount: retryCount))
        case .resumeSnapshot(let directory, let bundleSHA256):
            // Resume from the last durable checkpoint: re-use the
            // verified immutable snapshot, never re-read the source DB.
            let manifest = (try? PersistentTaskCheckpoint.readInputManifest(
                directory.appendingPathComponent("input_manifest.json"))) ?? [:]
            snapshot = SessionSnapshotTransaction.SessionSnapshot(
                taskID: request.taskRoot.lastPathComponent,
                snapshotDirectory: directory,
                inputManifest: manifest,
                bundleSHA256: bundleSHA256)
            try PersistentTaskCoordinator.updateState(
                .snapshotting, taskRoot: request.taskRoot, progress: 0.12,
                checkpoint: PersistentTaskCheckpoint.snapshotCheckpoint(
                    request: request, snapshot: snapshot,
                    retryCount: retryCount),
                clearError: true,
                allowRecoveryReentry: true)
        case .committedResult:
            preconditionFailure("committed result handled before snapshot switch")
        }

        // A crash may happen after the dedicated RESCAN_SESSION artifact
        // is durably renamed but before task.json reaches its terminal
        // state. Detect the identity-bound artifact before parsing evidence
        // or invoking either graph optimizer, restore its checkpoint
        // reference, and rethrow the typed product outcome. This makes
        // restart idempotent without publishing or re-running Route A.
        try resumeSessionRescanOutcomeIfPresent(
            request: request,
            snapshot: snapshot,
            retryCount: retryCount)
        try checkCancelled()
        let snapshotDatabase = snapshot.snapshotDirectory
            .appendingPathComponent(request.sourceDatabase.lastPathComponent)

        progress(0.15, "读取会话元数据")
        let metadata = try readMetadata(in: snapshot.snapshotDirectory)
        // B-08: the request carries the authoritative floor identity; the
        // metadata floor, when present, must agree — a mismatch is
        // evidence tampering and an empty request floor is fail-closed.
        guard !request.floorID.isEmpty else {
            throw MobileOnlyWorkflowError.invalidState(
                "floorID is empty; processing is blocked")
        }
        if let metadataFloorID = metadata["floorId"] as? String,
           !metadataFloorID.isEmpty, metadataFloorID != request.floorID {
            throw MobileOnlyWorkflowError.invalidState(
                "floorId mismatch: metadata='\(metadataFloorID)' request='\(request.floorID)'")
        }
        let floorID = request.floorID
        guard let finalizedAtUnix = StrictJSONScalar.number(
                metadata["finalizedAtUnix"]),
              finalizedAtUnix > 0 else {
            throw PipelineError.missingMetadata
        }

        // V1R4 §13.2: tag observations are strict-parsed BEFORE
        // optimization — every record is identity/format/pose checked and
        // bound to an exact snapshot-DB node via the node-timebase axis
        // (wired provider, §6.1). Bound node ids pin the adaptive skeleton
        // (§11.3) so tag-bound nodes survive reconstruction (§13). Any
        // rejected record blocks publish fail-closed; it is never silently
        // dropped (the audit is counted and surfaced in the error).
        let nodeInventory = Self.absolutePriorNodeInventoryProvider?(snapshotDatabase) ?? []

        // V1R5 §5.3/§5.4 (review B-02): the durable burst sidecar is
        // parsed with the strict burst parser BEFORE the observations;
        // every observation that may reach ACCEPTED must belong to a
        // verified complete burst. Missing watermarks fail closed.
        let burstEvidence = try TagObservationBurstEvidenceParser.parse(
            snapshotDirectory: snapshot.snapshotDirectory,
            nodes: nodeInventory,
            priorMapID: request.priorMap.priorMapID,
            priorMapSHA256: request.priorMap.packageSHA256,
            trackingSessionID: request.trackingSessionID,
            floorID: floorID,
            expectedBurstCount: (metadata["tagObservationBurstCount"] as? NSNumber)?.intValue,
            expectedLastBurstID: metadata["tagObservationBurstLastID"] as? String)
        guard burstEvidence.clean else {
            let audit = burstEvidence.audit
            throw PipelineError.tagEvidenceInvalid(
                "\(audit.totalRejected) bad burst records of \(audit.recordTotal)"
                + " (first: \(audit.rejectedDetails.prefix(3).map {"\($0.recordIndex):\($0.reason)" }.joined(separator: ", ")))")
        }
        if (metadata["tagObservationBurstCount"] as? NSNumber)?.intValue ?? 0 > 0
            && burstEvidence.bursts.isEmpty {
            throw PipelineError.tagEvidenceInvalid(
                "metadata declares bursts but the sidecar carries none")
        }

        // V1R4 §13.2: tag observations are strict-parsed BEFORE
        // optimization — every record is identity/format/pose checked and
        // bound to an exact snapshot-DB node via the node-timebase axis
        // (wired provider, §6.1). Bound node ids pin the adaptive skeleton
        // (§11.3) so tag-bound nodes survive reconstruction (§13). Any
        // rejected record blocks publish fail-closed; it is never silently
        // dropped (the audit is counted and surfaced in the error).
        let tagEvidence = try TagObservationEvidenceParser.parse(
            snapshotDirectory: snapshot.snapshotDirectory,
            nodes: nodeInventory,
            priorMapID: request.priorMap.priorMapID,
            priorMapSHA256: request.priorMap.packageSHA256,
            trackingSessionID: request.trackingSessionID,
            floorID: floorID,
            verifiedBursts: burstEvidence)
        guard burstEvidence.releaseConsumedFrames() else {
            throw PipelineError.tagEvidenceInvalid(
                "verified burst frames were not consumed exactly once")
        }
        guard tagEvidence.audit.clean else {
            let audit = tagEvidence.audit
            throw PipelineError.tagEvidenceInvalid(
                "\(audit.totalRejected) bad records of \(audit.recordTotal)"
                + " (first: \(audit.rejectedDetails.prefix(3).map {"\($0.recordIndex):\($0.reason)" }.joined(separator: ", ")))")
        }
        let tagObservations = tagEvidence.observations
        let tagNodeIDs = tagEvidence.boundNodeIDs

        // Accepted prior-map absolute constraints (§6.2): identity-bound,
        // finite, node-bound evidence only. The strict parser binds each
        // record to an exact RTAB-Map node via the snapshot-DB node
        // inventory (wired provider, §6.1) and audits every rejection.
        guard let captureHealth = metadata["captureHealth"] as? [String: Any],
              let expectedConstraintCount = StrictJSONScalar.integer(
                captureHealth["localizationConstraintRecordCount"]),
              expectedConstraintCount >= 0,
              let expectedManualCount = StrictJSONScalar.integer(
                captureHealth["manualLocalizationEventCount"]),
              expectedManualCount >= 0,
              let expectedRecoveryCount = StrictJSONScalar.integer(
                captureHealth["localizationRecoveryEventCount"]),
              expectedRecoveryCount >= 0 else {
            throw PipelineError.missingMetadata
        }
        let priorEvidence: AbsolutePriorEvidenceParseResult
        do {
            priorEvidence = try AbsolutePriorEvidenceParser.parse(
                snapshotDirectory: snapshot.snapshotDirectory,
                nodes: nodeInventory,
                priorMapID: request.priorMap.priorMapID,
                priorMapSHA256: request.priorMap.packageSHA256,
                trackingSessionID: request.trackingSessionID,
                floorID: floorID,
                expectedConstraintCount: expectedConstraintCount,
                expectedManualCount: expectedManualCount,
                expectedRecoveryCount: expectedRecoveryCount)
        } catch AbsolutePriorEvidenceParseError.qualificationLimitExceeded(
            let actual, let maximum) {
            throw MobileOnlyWorkflowError.resourceRequired(
                "localization_constraints qualification ceiling exceeded: "
                    + "\(actual) > \(maximum) records (48h @ 2 Hz)")
        }
        // V1R5 §8.3 (review B-06): parser/schema/identity failures are
        // fatal because absolute priors are authoritative map-frame anchors.
        // A well-formed, identity-bound `accepted=false` constraint is a
        // normal negative measurement: it is audited in nonAcceptedDetails,
        // contributes no prior, and does not make an otherwise clean run fail.
        guard priorEvidence.audit.clean else {
            let audit = priorEvidence.audit
            throw PipelineError.tagEvidenceInvalid(
                "\(audit.rejectedDetails.count) bad prior records"
                + " (first: \(audit.rejectedDetails.prefix(3).map {"\($0.source):\($0.recordIndex):\($0.reason)" }.joined(separator: ", ")))")
        }
        var absolutePriors = priorEvidence.priors
        if let initialPose = initialMapPosePrior(
            metadata: metadata, nodes: nodeInventory)
        {
            // One prior and nine scalars are negligible compared with the DB
            // graph. Native treats this as an explicit SE(2) gauge authority,
            // but it may authorize publication only when the same connected
            // component also contains a long-range RTAB-Map loop. Without
            // that independent relative-graph observability the outcome stays
            // LOCAL_FRAME_ONLY. The policy uncertainty represents map-tap and
            // heading-selection error; later structure/manual priors can still
            // refine the route.
            absolutePriors.insert(initialPose, at: 0)
        }

        // --- Fast Path: shared native factor-graph core (§2 / §11) -----
        // Real RTAB-Map nodes/links from the immutable snapshot DB drive
        // the run; the Swift solver is a host-test reference only.
        progress(0.30, "快速路径优化")
        try ProcessingResourceGovernor.checkBudget(
            stage: "fast",
            estimate: estimateTask(
                snapshot: snapshot,
                sourceDatabase: request.sourceDatabase,
                nodeCount: nodeInventory.count))
        let snapshotCheckpoint = PersistentTaskCheckpoint.snapshotCheckpoint(
            request: request, snapshot: snapshot, retryCount: retryCount)
        try PersistentTaskCoordinator.updateState(
            .fastOptimizing, taskRoot: request.taskRoot, progress: 0.30,
            checkpoint: snapshotCheckpoint)
        let startRun = Date()
        let nativeRequest = MobileNativeGraphRequest(
            databaseURL: snapshotDatabase,
            tagNodeIDs: tagNodeIDs,
            absolutePriors: absolutePriors,
            priorMapID: request.priorMap.priorMapID,
            priorMapSHA256: request.priorMap.packageSHA256,
            trackingSessionID: request.trackingSessionID,
            projectionPolicyVersion: 1,
            maxWallSeconds: 600)
        var nativeOutcome: MobileNativeGraphOutcome
        var processingPath = "fast"
        do {
            let fastOutcome = try MobileNativeFactorGraphGateway.runFast(
                request: nativeRequest,
                isCancelled: isCancelled)
            _ = try MobileNativeOutcomeContract.qualityReport(
                in: fastOutcome,
                request: nativeRequest,
                expectedPath: "fast")
            nativeOutcome = fastOutcome
        } catch let error as MobileNativeFactorGraphError {
            throw MobileOnlyWorkflowError.processingFailed("Fast Path 求解失败：\(error.localizedDescription)")
        }
        guard !nativeOutcome.trajectory.isEmpty else { throw PipelineError.emptyGraph }
        // §15: the Fast Path finished; its quality gate is the next
        // durable stage.
        try PersistentTaskCoordinator.updateState(
            .fastQualityCheck, taskRoot: request.taskRoot, progress: 0.38,
            checkpoint: PersistentTaskCheckpoint.withProcessingPath(
                "fast", in: snapshotCheckpoint))

        // One controlled full-graph optimization after a Fast
        // RECOVERABLE_FAIL (§13). This is NOT a sensor reprocess; when it
        // still cannot PASS the session needs a rescan, never a publish.
        if nativeOutcome.disposition == .recoverableFail {
            try checkCancelled()
            try ProcessingResourceGovernor.checkBudget(
                stage: "deep",
                estimate: estimateTask(
                    snapshot: snapshot,
                    sourceDatabase: request.sourceDatabase,
                    nodeCount: nodeInventory.count,
                    skeletonCount: nativeOutcome.skeletonIDs.count,
                    outcomeRowCount: nativeOutcome.trajectory.count))
            // §15: the controlled full-graph recovery is a durable stage
            // of its own (sensor_reprocessing/full_graph).
            try PersistentTaskCoordinator.updateState(
                .deepReprocessing, taskRoot: request.taskRoot, progress: 0.42,
                checkpoint: PersistentTaskCheckpoint.withProcessingPath(
                    "fast", in: snapshotCheckpoint))
            var fullGraphRequest = nativeRequest
            fullGraphRequest.maxWallSeconds = 1800
            do {
                let fullOutcome = try MobileNativeFactorGraphGateway.runFullGraph(
                    request: fullGraphRequest,
                    isCancelled: isCancelled)
                _ = try MobileNativeOutcomeContract.qualityReport(
                    in: fullOutcome,
                    request: fullGraphRequest,
                    expectedPath: "full_graph_optimization")
                nativeOutcome = fullOutcome
                processingPath = "full_graph_optimization"
                try PersistentTaskCoordinator.updateState(
                    .deepOptimizing, taskRoot: request.taskRoot, progress: 0.45,
                    checkpoint: PersistentTaskCheckpoint.withProcessingPath(
                        processingPath, in: snapshotCheckpoint))
            } catch let error as MobileNativeFactorGraphError {
                throw MobileOnlyWorkflowError.processingFailed("全图优化失败：\(error.localizedDescription)")
            }
        }

        // Strict quality gate: only PASS publishes (§2 / §11.5).
        // LOCAL_FRAME_ONLY means no accepted global anchor: diagnostics
        // only, never PriceTags/DevicePositions (§6.4).
        guard nativeOutcome.disposition == .pass else {
            // V1R4 §17 Gate N freeze: V1 has NO true sensor Deep on
            // device (the snapshot carries no raw RGB/depth frames and
            // the on-device core never runs a sensor reprocess). A
            // graph that still fails after the controlled full-graph
            // recovery turns into an EXPLICIT session-level RESCAN task
            // — never a silent drop — and publish stays blocked.
            let graphRescan = RescanTask(
                taskID: "rescan-\(request.trackingSessionID)-graph",
                taskType: .insufficientLoop,
                floorID: floorID,
                barcode: "",
                tagInstanceID: nil,
                shelfCode: "",
                shelfSegmentID: "",
                regionStartCm: nil,
                regionEndCm: nil,
                localStartTime: "",
                localEndTime: "",
                reasonCode: "graph_quality_failed",
                humanMessage: "图优化质量门未通过（\(processingPath)/"
                    + "\(nativeOutcome.disposition.reportValue)）；"
                    + "V1 无设备端 sensor Deep，需要重新扫描",
                suggestedAction: "RESCAN_SESSION",
                priority: 1)
            try persistSessionRescanOutcome(
                request: request,
                snapshot: snapshot,
                processingPath: processingPath,
                graphDisposition: nativeOutcome.disposition.reportValue,
                reasonCode: "graph_quality_failed",
                humanMessage: graphRescan.humanMessage,
                rescanTask: graphRescan,
                checkpoint: snapshotCheckpoint)
        }
        let graphQualityPassed = true
        try checkCancelled()

        // --- Clock mapping on the native UTC stamp axis (§7/§13) -------
        progress(0.40, "构建时钟映射")
        // V1R5 §9.6 (review B-09): the trace is strict-parsed — a bad
        // line throws instead of silently disappearing, so lost intervals
        // can never hide behind a lenient reader. The count is verified
        // against the metadata watermark.
        guard let expectedTraceCount = StrictJSONScalar.integer(
                captureHealth["localizationTraceRecordCount"]),
              expectedTraceCount >= 0 else {
            throw PipelineError.missingMetadata
        }
        let sessionStartStamp = nativeOutcome.trajectory.first?.stamp
            ?? finalizedAtUnix - 1
        let traces: [StrictLocalizationTraceParser.TraceRecord]
        do {
            traces = try StrictLocalizationTraceParser.parse(
                snapshotDirectory: snapshot.snapshotDirectory,
                trackingSessionID: request.trackingSessionID,
                priorMapID: request.priorMap.priorMapID,
                priorMapSHA256: request.priorMap.packageSHA256,
                floorID: floorID,
                expectedCount: expectedTraceCount,
                retentionOriginNodeTimestamp: sessionStartStamp)
        } catch StrictLocalizationTraceParser.ParseError
                    .qualificationLimitExceeded(let actual, let maximum) {
            throw MobileOnlyWorkflowError.resourceRequired(
                "localization_trace qualification ceiling exceeded: "
                    + "\(actual) > \(maximum) records "
                    + "(48h @ \(StrictLocalizationTraceParser.qualificationRecordRateHz) Hz)")
        }
        // Session end is the LAST COLLECTED stamp (§7.5) — never the
        // finalization wall-clock.
        let sessionEndStamp = max(
            nativeOutcome.trajectory.last?.stamp ?? sessionStartStamp,
            sessionStartStamp + 1)
        let sessionSpan = sessionEndStamp - sessionStartStamp
        guard sessionSpan >= 0, sessionSpan <= 48 * 3600 else {
            throw MobileOnlyWorkflowError.invalidState(
                "session time span inconsistent: \(sessionSpan) seconds")
        }
        // V1R4 §7.3: the authoritative node-stamp -> UTC mapper comes
        // ONLY from the recorded clock evidence (correlations + node
        // bindings), parsed strictly against the metadata watermark.
        // Missing/insufficient/inconsistent evidence fails the publish;
        // the identity stamp assumption and the processing-time
        // timezone are never used as fallbacks.
        let utcMapper = try buildClockMapper(
            snapshotDirectory: snapshot.snapshotDirectory,
            metadata: metadata,
            trackingSessionID: request.trackingSessionID,
            sessionStartStamp: sessionStartStamp,
            sessionEndStamp: sessionEndStamp,
            nodeInventory: nodeInventory)
        guard let sessionStartUTC = utcMapper.utcSeconds(forMonotonic: 0),
              let sessionEndUTC = utcMapper.utcSeconds(
                  forMonotonic: sessionEndStamp - sessionStartStamp) else {
            throw PipelineError.clockEvidenceIncomplete(
                "session span outside the node-binding evidence span")
        }

        // --- Final trajectory (1 Hz) from the native reconstruction -----
        progress(0.50, "构建最终轨迹")
        try ProcessingResourceGovernor.checkBudget(
            stage: "trajectory",
            estimate: estimateTask(
                snapshot: snapshot,
                sourceDatabase: request.sourceDatabase,
                nodeCount: nodeInventory.count,
                skeletonCount: nativeOutcome.skeletonIDs.count,
                outcomeRowCount: nativeOutcome.trajectory.count,
                sessionSpanSeconds: sessionSpan))
        try PersistentTaskCoordinator.updateState(
            .buildingTrajectory, taskRoot: request.taskRoot, progress: 0.50,
            checkpoint: PersistentTaskCheckpoint.withProcessingPath(
                processingPath, in: snapshotCheckpoint))
        // Rows that are not publish-eligible (fragment components, gaps,
        // other floors) become UNAVAILABLE intervals — never interpolated
        // across (§15.2).
        let eligibilityLost = lostIntervalsFromEligibility(
            rows: nativeOutcome.trajectory, sessionStartStamp: sessionStartStamp)
        let finalNodes = nativeOutcome.trajectory.filter { $0.publishEligible }.map {
            FinalTrajectory.Node(
                id: $0.id,
                monotonicSeconds: $0.stamp - sessionStartStamp,
                xM: $0.xM,
                yM: $0.yM,
                yawRad: $0.yawRad,
                // V1R5 §11.2 (review B-11): native uncertainty stays nil
                // when it cannot be estimated — it is NEVER fabricated as
                // 0.0. A nil-uncertainty node cannot anchor an AVAILABLE
                // row (the resampler emits UNAVAILABLE instead).
                uncertaintyM: $0.uncertaintyM,
                floorID: floorID)
        }
        guard !finalNodes.isEmpty else {
            let message = "图优化虽通过，但最终快照没有可发布的轨迹节点；"
                + "本次不会生成 PriceTags、DevicePositions 或普通结果，"
                + "需要重新扫描整个会话"
            let trajectoryRescan = RescanTask(
                taskID: "rescan-\(request.trackingSessionID)-trajectory",
                taskType: .weakLocalization,
                floorID: floorID,
                barcode: "",
                tagInstanceID: nil,
                shelfCode: "",
                shelfSegmentID: "",
                regionStartCm: nil,
                regionEndCm: nil,
                localStartTime: "",
                localEndTime: "",
                reasonCode: "no_publish_eligible_trajectory",
                humanMessage: message,
                suggestedAction: "RESCAN_SESSION",
                priority: 1)
            try persistSessionRescanOutcome(
                request: request,
                snapshot: snapshot,
                processingPath: processingPath,
                graphDisposition: nativeOutcome.disposition.reportValue,
                reasonCode: trajectoryRescan.reasonCode,
                humanMessage: message,
                rescanTask: trajectoryRescan,
                checkpoint: snapshotCheckpoint)
        }
        let lostIntervals = buildLostIntervals(
            from: traces, sessionStartStamp: sessionStartStamp) + eligibilityLost
        let trajectoryInput = FinalTrajectory.Input(
            nodes: finalNodes,
            lostIntervals: lostIntervals,
            sessionStartUTC: sessionStartUTC,
            sessionEndUTC: sessionEndUTC,
            // V1R5 §11.3 (H-20): real trace states drive the per-row
            // business status instead of hard-coded "tracking/connected".
            traceStates: traces.map {
                FinalTrajectory.TraceState(
                    timestamp: $0.nodeTimebaseTimestamp - sessionStartStamp,
                    trackingState: $0.trackingState,
                    localizationState: $0.localizationState,
                    confidence: $0.confidence,
                    floorID: $0.floorID)
            })
        let devicePositions = FinalTrajectory.resample(
            input: trajectoryInput,
            utcMapper: utcMapper,
            storeID: request.storeID,
            priorMapID: request.priorMap.priorMapID,
            priorMapSha256: request.priorMap.packageSHA256,
            trackingSessionID: request.trackingSessionID,
            appGitSHA: request.appGitSHA)
        try checkCancelled()

        // --- Tags -------------------------------------------------------
        progress(0.65, "解析价签")
        try ProcessingResourceGovernor.checkBudget(
            stage: "tags",
            estimate: estimateTask(
                snapshot: snapshot,
                sourceDatabase: request.sourceDatabase,
                nodeCount: nodeInventory.count,
                skeletonCount: nativeOutcome.skeletonIDs.count,
                outcomeRowCount: nativeOutcome.trajectory.count,
                sessionSpanSeconds: sessionSpan,
                tagObservationCount: tagObservations.count,
                burstSidecarURL: snapshot.snapshotDirectory
                    .appendingPathComponent("tag_observation_bursts.jsonl")))
        try PersistentTaskCoordinator.updateState(
            .resolvingTags, taskRoot: request.taskRoot, progress: 0.65,
            checkpoint: PersistentTaskCheckpoint.withProcessingPath(
                processingPath, in: snapshotCheckpoint))
        let shelves = try readShelves(from: request.priorMap)
        let structures = try readFixedStructures(from: request.priorMap)
        let shelfIndex = ShelfAssociationEngine.ShelfSpatialIndex(shelves: shelves)
        // Raw snapshot-DB node poses for the propagation chain
        // P_final = T_final_node * inverse(T_raw_node) * P_raw (§13.2).
        let rawNodePoses = Self.rawNodePoseProvider?(snapshotDatabase) ?? [:]
        // V1R5 §6.5 (review B-03): the resolver uses O(1) indexes — the
        // parser-bound node id is the only resolution path, and the raw
        // snapshot node stamps verify the exact node-timebase binding.
        let resolverIndex = TagObservationResolver.NodeIndex(
            finalNodes: finalNodes.map {
                TagObservationResolver.FinalNodePose(
                    id: $0.id,
                    monotonicSeconds: $0.monotonicSeconds,
                    pose: SE2Transform(xM: $0.xM, yM: $0.yM, yawRad: $0.yawRad),
                    floorID: $0.floorID,
                    uncertaintyM: $0.uncertaintyM)
            },
            rawNodeStamps: Dictionary(
                uniqueKeysWithValues: nodeInventory.map { ($0.nodeID, $0.stamp) }))
        let (priceTags, rescanTasks) = try finalizeTags(
            observations: tagObservations,
            resolverIndex: resolverIndex,
            shelves: shelves,
            shelfIndex: shelfIndex,
            structures: structures,
            sessionID: request.trackingSessionID,
            storeID: request.storeID,
            priorMap: request.priorMap,
            floorID: floorID,
            graphQualityPassed: graphQualityPassed,
            rawNodePoses: rawNodePoses,
            minimumAssociationMarginM: 0.5)
        try checkCancelled()

        // --- Result package (staged, then atomically committed, §20) ---
        progress(0.80, "生成结果包")
        // §15: every export below is reproducible; the checkpoint before
        // it binds only the snapshot-level durable outputs.
        try PersistentTaskCoordinator.updateState(
            .buildingWorkbook, taskRoot: request.taskRoot, progress: 0.80,
            checkpoint: PersistentTaskCheckpoint.withProcessingPath(
                processingPath, in: snapshotCheckpoint))
        let resultID = "result-\(UUID().uuidString.lowercased())"
        // All artifacts are written into the staging directory first;
        // the immutable library entry appears only after the atomic
        // commit (§20.1/§20.4).
        let resultDirectory = try MobileResultLibrary.stagingDirectory(
            taskID: request.taskRoot.lastPathComponent, resultID: resultID)
        try FileManager.default.createDirectory(
            at: resultDirectory, withIntermediateDirectories: true)
        // V1R4 §16.4 rollback: any failure below removes the staging
        // package; a committed result (already renamed out of staging)
        // is never touched.
        var committed = false
        defer {
            if !committed {
                try? FileManager.default.removeItem(at: resultDirectory)
            }
        }

        // final_trajectory.jsonl — streamed line by line with an
        // incremental SHA-256; the full file is never accumulated as one
        // String (V1R4 §16.1).
        let trajectoryURL = resultDirectory.appendingPathComponent("final_trajectory.jsonl")
        let trajectorySHA256: String
        do {
            if !FileManager.default.createFile(atPath: trajectoryURL.path, contents: nil) {
                throw PipelineError.cannotBuildWorkbook("final_trajectory.jsonl 无法创建")
            }
            let handle = try FileHandle(forWritingTo: trajectoryURL)
            defer { try? handle.close() }
            var hasher = SHA256()
            for row in devicePositions {
                // V1R5 §6.6 (review B-12): an encode failure BLOCKS the
                // whole result commit — a silently missing line would
                // corrupt the counts and the SHA identity. `try?` with
                // `continue` is forbidden on the authoritative writers.
                let data = try CanonicalJSONEncoder.encode(row.canonicalPayload)
                hasher.update(data: data)
                try handle.write(contentsOf: data)
                let newline = Data("\n".utf8)
                hasher.update(data: newline)
                try handle.write(contentsOf: newline)
            }
            trajectorySHA256 = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        } catch {
            throw PipelineError.cannotBuildWorkbook("final_trajectory.jsonl 写入失败：\(error)")
        }

        // final_tags.json / rescan_tasks.json — streamed array writer:
        // header + one element at a time + footer; the full JSON array is
        // never materialised (V1R4 §16.1). The byte layout matches the
        // whole-payload canonical encoder (keys sorted by Unicode scalar:
        // count/format/<arrayKey>/version).
        func writeStreamingArrayFile<C: Collection>(
            format: String,
            version: Int,
            count: Int,
            arrayKey: String,
            elements: C,
            payloadFor: (C.Element) -> [String: Any],
            to url: URL
        ) throws {
            if !FileManager.default.createFile(atPath: url.path, contents: nil) {
                throw PipelineError.cannotBuildWorkbook("无法创建 \(url.lastPathComponent)")
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.write(contentsOf: Data(
                "{\"count\":\(count),\"format\":\"\(format)\",\"\(arrayKey)\":[".utf8))
            var first = true
            for element in elements {
                if !first {
                    try handle.write(contentsOf: Data(",".utf8))
                }
                first = false
                try handle.write(contentsOf: CanonicalJSONEncoder.encode(payloadFor(element)))
            }
            try handle.write(contentsOf: Data("],\"version\":\(version)}".utf8))
        }
        try writeStreamingArrayFile(
            format: "MarketScannerFinalTags",
            version: 1,
            count: priceTags.count,
            arrayKey: "tags",
            elements: priceTags,
            payloadFor: { priceTagPayload($0) },
            to: resultDirectory.appendingPathComponent("final_tags.json"))
        try writeStreamingArrayFile(
            format: "MarketScannerRescanTasks",
            version: 1,
            count: rescanTasks.count,
            arrayKey: "tasks",
            elements: rescanTasks,
            payloadFor: { rescanTaskPayload($0) },
            to: resultDirectory.appendingPathComponent("rescan_tasks.json"))
        let qualityReport: [String: Any] = [
            "format": "MarketScannerQualityReport",
            "version": 2,
            "processing_path": processingPath,
            "graph_quality_disposition": nativeOutcome.disposition.reportValue,
            "graph": [
                "node_count": nativeOutcome.trajectory.count,
                "skeleton_node_count": nativeOutcome.skeletonIDs.count,
                // Verbatim §11.5 native metrics (components, residuals,
                // corrections, solver diagnostics).
                "native_quality": nativeOutcome.qualityJSON,
            ],
            "trajectory": [
                "device_position_count": devicePositions.count,
                "available_count": devicePositions.filter { $0.positionStatus == "AVAILABLE" }.count,
                "unavailable_count": devicePositions.filter { $0.positionStatus != "AVAILABLE" }.count,
            ],
            "tags": [
                "observation_count": tagObservations.count,
                "accepted_count": priceTags.filter { $0.qualityStatus == "ACCEPTED" }.count,
                "low_confidence_count": priceTags.filter {
                    $0.qualityStatus == "LOW_CONFIDENCE"
                }.count,
                "rescan_count": rescanTasks.count,
            ],
            "prior_evidence": priorEvidence.audit.reportPayload(
                priors: absolutePriors),
        ]
        try CanonicalJSONEncoder.encode(qualityReport).write(
            to: resultDirectory.appendingPathComponent("quality_report.json"))
        // Verbatim native quality JSON for audit/replay parity with the
        // PC diagnostic CLI.
        try nativeOutcome.qualityJSON.data(using: .utf8)!.write(
            to: resultDirectory.appendingPathComponent("graph_quality.json"))
        // input_manifest.json copy from the snapshot transaction.
        let inputManifestURL = request.taskRoot.appendingPathComponent("input_manifest.json")
        if FileManager.default.fileExists(atPath: inputManifestURL.path) {
            try FileManager.default.copyItem(
                at: inputManifestURL,
                to: resultDirectory.appendingPathComponent("input_manifest.json"))
        }

        // --- Streaming four-sheet XLSX ----------------------------------
        progress(0.90, "导出工作簿")
        try ProcessingResourceGovernor.checkBudget(
            stage: "xlsx",
            estimate: estimateTask(
                snapshot: snapshot,
                sourceDatabase: request.sourceDatabase,
                nodeCount: nodeInventory.count,
                skeletonCount: nativeOutcome.skeletonIDs.count,
                outcomeRowCount: nativeOutcome.trajectory.count,
                sessionSpanSeconds: sessionSpan,
                tagObservationCount: tagObservations.count,
                burstSidecarURL: snapshot.snapshotDirectory
                    .appendingPathComponent("tag_observation_bursts.jsonl"),
                devicePositionCount: devicePositions.count,
                tagCount: priceTags.count,
                rescanCount: rescanTasks.count))
        let runSummary = try buildRunSummary(
            request: request,
            snapshotDirectory: snapshot.snapshotDirectory,
            resultID: resultID,
            metadata: metadata,
            nativeOutcome: nativeOutcome,
            processingPath: processingPath,
            runDurationSeconds: Date().timeIntervalSince(startRun),
            cancelLatencySeconds: cancelRequestedAt.map {
                Date().timeIntervalSince1970 - $0
            } ?? 0,
            devicePositions: devicePositions,
            priceTags: priceTags,
            rescanTasks: rescanTasks)
        let workbookName = "\(resultID).xlsx"
        let workbookURL = resultDirectory.appendingPathComponent(workbookName)
        do {
            try MobileResultExporter.export(
                input: MobileResultExporter.Input(
                    devicePositions: devicePositions,
                    priceTags: priceTags,
                    rescanTasks: rescanTasks,
                    runSummary: runSummary,
                    appGitSHA: request.appGitSHA,
                    appVersion: request.appVersion,
                    deviceModel: request.deviceModel,
                    osVersion: request.osVersion),
                to: workbookURL)
        } catch {
            throw PipelineError.cannotBuildWorkbook("\(error)")
        }

        // --- Atomic commit (validate + per-file SHA + rename, §20.4) ---
        // §15: the result artifacts are durable now; the checkpoint
        // binds every one of them (validating_result / committing_result
        // crash points resume from the snapshot and re-export).
        let stagedArtifactNames = [
            "final_trajectory.jsonl", "final_tags.json",
            "quality_report.json", "graph_quality.json",
            "rescan_tasks.json", "input_manifest.json", workbookName,
        ]
        let resultDurableOutputs = [
            PersistentTaskCheckpoint.taskReference("input_snapshot"),
            PersistentTaskCheckpoint.taskReference("input_manifest.json"),
        ] + stagedArtifactNames.map {
            PersistentTaskCheckpoint.resultStagingReference(
                taskID: request.taskRoot.lastPathComponent,
                resultID: resultID,
                relativePath: $0)
        }
        progress(0.94, "校验结果包")
        try ProcessingResourceGovernor.checkBudget(
            stage: "result_commit",
            estimate: estimateTask(
                snapshot: snapshot,
                sourceDatabase: request.sourceDatabase,
                nodeCount: nodeInventory.count,
                skeletonCount: nativeOutcome.skeletonIDs.count,
                outcomeRowCount: nativeOutcome.trajectory.count,
                sessionSpanSeconds: sessionSpan,
                tagObservationCount: tagObservations.count,
                burstSidecarURL: snapshot.snapshotDirectory
                    .appendingPathComponent("tag_observation_bursts.jsonl"),
                devicePositionCount: devicePositions.count,
                tagCount: priceTags.count,
                rescanCount: rescanTasks.count,
                resultDirectory: resultDirectory))
        try PersistentTaskCoordinator.updateState(
            .validatingResult, taskRoot: request.taskRoot, progress: 0.94,
            checkpoint: PersistentTaskCheckpoint.withDurableOutputs(
                resultDurableOutputs,
                in: PersistentTaskCheckpoint.withProcessingPath(
                    processingPath, in: snapshotCheckpoint)))
        progress(0.98, "提交结果清单")
        try PersistentTaskCoordinator.updateState(
            .committingResult, taskRoot: request.taskRoot, progress: 0.98,
            checkpoint: PersistentTaskCheckpoint.withDurableOutputs(
                resultDurableOutputs,
                in: PersistentTaskCheckpoint.withProcessingPath(
                    processingPath, in: snapshotCheckpoint)))
        let entry = try MobileResultLibrary.commit(
            resultID: resultID,
            taskID: request.taskRoot.lastPathComponent,
            stagingDirectory: resultDirectory,
            packageFiles: [
                "final_trajectory.jsonl",
                "final_tags.json",
                "quality_report.json",
                "graph_quality.json",
                "rescan_tasks.json",
                "input_manifest.json",
            ],
            workbookFilename: workbookName,
            manifestExtras: [
                "store_id": request.storeID,
                "prior_map_id": request.priorMap.priorMapID,
                "prior_map_sha256": request.priorMap.packageSHA256,
                "tracking_session_id": request.trackingSessionID,
                "source_database": request.sourceDatabase.lastPathComponent,
                "input_bundle_sha256": snapshot.bundleSHA256,
                "native_core_sha256": request.nativeCoreSHA256,
                "processing_path": processingPath,
                // V1R4 §16.3 identity bindings: policy / projection /
                // graph / factor-graph outputs.
                "policy_sha": request.policySHA,
                "projection_policy_version": 1,
                "trajectory_sha256": trajectorySHA256,
                "graph_quality_sha256": CanonicalSourceHasher.sha256(
                    Data(nativeOutcome.qualityJSON.utf8)),
                "device_position_count": devicePositions.count,
                "available_position_count": devicePositions.filter {
                    $0.positionStatus == "AVAILABLE"
                }.count,
                "tag_count": priceTags.count,
                "rescan_count": rescanTasks.count,
            ])
        committed = true
        // §15: terminal durable state — the committed result is the
        // final checkpoint binding.
        try PersistentTaskCoordinator.updateState(
            .completed, taskRoot: request.taskRoot, progress: 1.0,
            checkpoint: PersistentTaskCheckpoint.withCommittedResult(
                entry,
                in: PersistentTaskCheckpoint.withProcessingPath(
                    processingPath, in: snapshotCheckpoint)),
            clearError: true)
        progress(1.0, "完成")
        return Outcome(
            resultEntry: entry,
            devicePositionCount: devicePositions.count,
            availablePositionCount: devicePositions.filter { $0.positionStatus == "AVAILABLE" }.count,
            tagCount: priceTags.count,
            rescanCount: rescanTasks.count)
    }

    /// Repairs the narrow crash window after an immutable Result has
    /// become visible but before task.json is durably `completed`.
    ///
    /// Returning nil means no committed Result exists and the caller may
    /// use ordinary terminal-error persistence. Any candidate conflict,
    /// duplicate, malformed receipt/package, identity mismatch, or task
    /// state mismatch throws a fail-closed checkpoint error and leaves the
    /// task/result evidence untouched.
    private static func reconcileCommittedResultAfterFailure(
        request: Request
    ) throws -> Outcome? {
        let taskFileURL = PersistentTaskCoordinator.taskFileURL(
            taskRoot: request.taskRoot)
        guard FileManager.default.fileExists(atPath: taskFileURL.path) else {
            return nil
        }
        let record: PersistentTaskCoordinator.TaskRecord
        do {
            record = try PersistentTaskCoordinator.read(taskRoot: request.taskRoot)
        } catch {
            throw PersistentTaskCheckpoint.CheckpointError.invalidRecord(
                "task.json unreadable during committed-result reconciliation: \(error)")
        }
        let expectedResultIDs = try PersistentTaskCheckpoint
            .expectedCommittedResultIDs(
                in: record.checkpoint, taskID: record.taskID)
        let entry: MobileResultLibrary.ResultEntry?
        do {
            entry = try MobileResultLibrary.committedResult(
                taskID: record.taskID,
                expectedResultIDs: expectedResultIDs)
        } catch {
            throw PersistentTaskCheckpoint.CheckpointError.invalidRecord(
                "committed result lookup failed: \(error)")
        }
        guard let entry else { return nil }
        guard record.state == .committingResult || record.state == .completed else {
            throw PersistentTaskCheckpoint.CheckpointError.invalidRecord(
                "committed result exists while task is \(record.state.rawValue)")
        }
        guard let checkpoint = record.checkpoint else {
            throw PersistentTaskCheckpoint.CheckpointError.invalidRecord(
                "committed result has no task checkpoint")
        }
        try PersistentTaskCheckpoint.validateCommittedResult(
            entry,
            checkpoint: checkpoint,
            taskRoot: request.taskRoot,
            request: request)

        // A fault injected immediately after final rename occurs before
        // the result-library parent fsync. Reconciliation explicitly
        // repairs that durability boundary, then reopens every immutable
        // byte/receipt before touching task.json.
        do {
            try MobileMapLibrary.syncDirectory(entry.directory)
            try MobileMapLibrary.syncDirectory(try MobileResultLibrary.root())
        } catch {
            throw PersistentTaskCheckpoint.CheckpointError.invalidRecord(
                "committed result cannot be durably synchronized: \(error)")
        }
        let reopened: MobileResultLibrary.ResultEntry
        do {
            reopened = try MobileResultLibrary.readResult(resultID: entry.resultID)
        } catch {
            throw PersistentTaskCheckpoint.CheckpointError.invalidRecord(
                "committed result cannot be reopened: \(error)")
        }
        try PersistentTaskCheckpoint.validateCommittedResult(
            reopened,
            checkpoint: checkpoint,
            taskRoot: request.taskRoot,
            request: request)
        let completedCheckpoint = PersistentTaskCheckpoint.withCommittedResult(
            reopened, in: checkpoint)

        if record.state == .committingResult {
            do {
                _ = try PersistentTaskCoordinator.updateState(
                    .completed,
                    taskRoot: request.taskRoot,
                    progress: 1.0,
                    checkpoint: completedCheckpoint,
                    clearError: true)
            } catch {
                // afterRename/afterParentFsync write faults report an error
                // even though the completed record may already be the
                // durable final bytes. Accept only an exact reread; a
                // pre-rename failure remains committing_result for launch
                // recovery and is NEVER rewritten to failed here.
                guard let reread = try? PersistentTaskCoordinator.read(
                        taskRoot: request.taskRoot),
                      exactCompletedRecord(
                        reread,
                        expectedCheckpoint: completedCheckpoint) else {
                    throw PersistentTaskCheckpoint.CheckpointError.invalidRecord(
                        "completed task transition failed after result commit: \(error)")
                }
            }
        }
        let finalRecord: PersistentTaskCoordinator.TaskRecord
        do {
            finalRecord = try PersistentTaskCoordinator.read(
                taskRoot: request.taskRoot)
        } catch {
            throw PersistentTaskCheckpoint.CheckpointError.invalidRecord(
                "completed task cannot be reopened: \(error)")
        }
        guard exactCompletedRecord(
                finalRecord, expectedCheckpoint: completedCheckpoint) else {
            throw PersistentTaskCheckpoint.CheckpointError.invalidRecord(
                "completed task/result checkpoint mismatch")
        }
        return outcome(from: reopened)
    }

    private static func exactCompletedRecord(
        _ record: PersistentTaskCoordinator.TaskRecord,
        expectedCheckpoint: [String: Any]
    ) -> Bool {
        guard record.state == .completed,
              record.progress == 1.0,
              record.error == nil,
              let actualCheckpoint = record.checkpoint,
              let actual = try? CanonicalJSONEncoder.encode(actualCheckpoint),
              let expected = try? CanonicalJSONEncoder.encode(expectedCheckpoint)
        else {
            return false
        }
        return actual == expected
    }

    private static func outcome(
        from entry: MobileResultLibrary.ResultEntry
    ) -> Outcome {
        return Outcome(
            resultEntry: entry,
            devicePositionCount: PersistentTaskCheckpoint.exactNonnegativeCount(
                "device_position_count", in: entry.manifest)!,
            availablePositionCount: PersistentTaskCheckpoint.exactNonnegativeCount(
                "available_position_count", in: entry.manifest)!,
            tagCount: PersistentTaskCheckpoint.exactNonnegativeCount(
                "tag_count", in: entry.manifest)!,
            rescanCount: PersistentTaskCheckpoint.exactNonnegativeCount(
                "rescan_count", in: entry.manifest)!)
    }

    // MARK: - Evidence readers

    static func readMetadata(in snapshotDirectory: URL) throws -> [String: Any] {
        let url = snapshotDirectory.appendingPathComponent("metadata.json")
        let data = try Data(contentsOf: url)
        guard let object = try? StrictJSONDocumentParser.object(
            from: data,
            limits: StrictJSONDocumentLimits(maximumBytes: data.count + 1)) as? [String: Any]
        else { throw PipelineError.missingMetadata }
        return object
    }

    /// Builds the mobile equivalent of the PC `initial_map_pose` factor.
    /// Hardware/VIO poses are not rewritten here; the native graph distributes
    /// the map-frame correction over relative odometry and loop constraints.
    static func initialMapPosePrior(
        metadata: [String: Any],
        nodes: [AbsolutePriorEvidenceNode]
    ) -> MobileAbsolutePrior? {
        guard let firstNode = nodes.min(by: {
            if $0.stamp == $1.stamp { return $0.nodeID < $1.nodeID }
            return $0.stamp < $1.stamp
        }),
              let raw = metadata["initialMapPose"] as? [String: Any],
              let xM = StrictJSONScalar.number(raw["x_m"]),
              let yM = StrictJSONScalar.number(raw["y_m"]),
              let yawRad = StrictJSONScalar.number(raw["yaw_rad"]),
              xM.isFinite, yM.isFinite, yawRad.isFinite else {
            return nil
        }
        let translationSigmaM = 1.0
        let yawSigmaRad = Double.pi / 12.0
        return MobileAbsolutePrior(
            nodeID: firstNode.nodeID,
            mapXM: xM,
            mapYM: yM,
            mapYawRad: yawRad,
            information3x3: [
                1.0 / (translationSigmaM * translationSigmaM), 0, 0,
                0, 1.0 / (translationSigmaM * translationSigmaM), 0,
                0, 0, 1.0 / (yawSigmaRad * yawSigmaRad),
            ],
            kind: 3,
            episodeID: 0)
    }

    // MARK: - Fast Path graph

    /// One sampled graph node together with its trace metadata needed by
    /// the trajectory stage.
    struct GraphSampledNode {
        var id: Int64
        var monotonicSeconds: Double
        var floorID: String
        var node: SE2FactorGraphCore.Node
    }

    /// Samples the trace into graph nodes (stride keeps the solve fast on
    /// device while preserving loop structure).
    static func buildGraphNodes(
        from traces: [StrictLocalizationTraceParser.TraceRecord],
        stride: Int = 4
    ) -> [GraphSampledNode] {
        var nodes: [GraphSampledNode] = []
        for (index, trace) in traces.enumerated() where index % stride == 0 {
            let id = Int64(index / stride) + 1
            let node = SE2FactorGraphCore.Node(
                id: id,
                initialPose: SE2Transform(xM: trace.xM, yM: trace.yM, yawRad: trace.yawRad),
                isAnchor: nodes.isEmpty,
                floorID: trace.floorID)
            nodes.append(GraphSampledNode(
                id: id,
                monotonicSeconds: trace.timestamp,
                floorID: trace.floorID,
                node: node))
        }
        return nodes
    }

    /// Odometry edges between consecutive sampled nodes (relative
    /// measurement = inv(T_i) * T_{i+1}, scalar weight).
    static func buildOdometryEdges(from nodes: [SE2FactorGraphCore.Node]) -> [SE2FactorGraphCore.Edge] {
        var edges: [SE2FactorGraphCore.Edge] = []
        for index in 0..<(nodes.count - 1) {
            let from = nodes[index]
            let to = nodes[index + 1]
            let measurement = from.initialPose.inverse.composed(with: to.initialPose)
            edges.append(SE2FactorGraphCore.Edge(
                from: from.id, to: to.id,
                measurement: measurement,
                weight: 1.0,
                kind: "odometry"))
        }
        return edges
    }

    // MARK: - Lost intervals

    /// Lost intervals from the real localization/tracking states, mapped
    /// onto the native UTC stamp axis (monotonic = utc - sessionStart).
    static func buildLostIntervals(
        from traces: [StrictLocalizationTraceParser.TraceRecord],
        sessionStartStamp: Double
    ) -> [FinalTrajectory.LostInterval] {
        /// Trace monotonic axis -> stamp axis conversion: prefer the
        /// recorded node-timebase UTC, fall back to the raw timestamp.
        func axisTime(_ trace: StrictLocalizationTraceParser.TraceRecord) -> Double {
            if trace.nodeTimebaseTimestamp > 0 {
                return trace.nodeTimebaseTimestamp - sessionStartStamp
            }
            return trace.timestamp
        }
        var intervals: [FinalTrajectory.LostInterval] = []
        var currentStart: Double?
        var currentReason = ""
        for trace in traces {
            let lost = trace.localizationState == "lost"
                || trace.localizationState == "initializing"
                || trace.trackingState == "notAvailable"
            if lost {
                if currentStart == nil {
                    currentStart = axisTime(trace)
                    currentReason = trace.localizationState == "initializing"
                        ? "localization_initializing" : "tracking_lost"
                }
            } else if let start = currentStart {
                intervals.append(FinalTrajectory.LostInterval(
                    fromMonotonic: start, toMonotonic: axisTime(trace),
                    reason: currentReason))
                currentStart = nil
            }
        }
        if let start = currentStart {
            intervals.append(FinalTrajectory.LostInterval(
                fromMonotonic: start,
                toMonotonic: traces.last.map { axisTime($0) } ?? start,
                reason: currentReason))
        }
        return intervals
    }

    // MARK: - Absolute prior evidence (§6.2)

    /// Node-inventory source used to bind absolute-prior evidence to DB
    /// nodes (§6.1). The app wires the native graph reader in
    /// `MobileNativeFactorGraph.wireIntoGateway()`; host tests inject a
    /// reference implementation so the strict parser stays host-testable
    /// without the Objective-C++ bridge.
    static var absolutePriorNodeInventoryProvider:
        ((URL) -> [AbsolutePriorEvidenceNode])? = nil

    // MARK: - Clock evidence (§7)

    /// Builds the authoritative monotonic(=stamp-sessionStart) -> UTC
    /// mapper from the recorded clock evidence (V1R4 §7.3). The sidecar
    /// is parsed strictly: exact schema/version/session identity/counts,
    /// strictly increasing axes and per-binding UTC cross-checks. Any
    /// failure throws `clockEvidenceIncomplete`; the identity stamp
    /// assumption and the processing-time timezone are never used as
    /// fallbacks.
    static func buildClockMapper(
        snapshotDirectory: URL,
        metadata: [String: Any],
        trackingSessionID: String,
        sessionStartStamp: Double,
        sessionEndStamp: Double,
        nodeInventory: [AbsolutePriorEvidenceNode]
    ) throws -> MonotonicUTCMapper {
        let clockURL = snapshotDirectory
            .appendingPathComponent("clock_correlations.jsonl")
        guard FileManager.default.fileExists(atPath: clockURL.path) else {
            throw PipelineError.clockEvidenceIncomplete(
                "clock_correlations.jsonl missing")
        }
        guard let expectedCorrelationCount = StrictJSONScalar.integer(
                metadata["clockCorrelationCount"]),
              expectedCorrelationCount >= 0,
              let expectedBindingCount = StrictJSONScalar.integer(
                metadata["clockNodeBindingCount"]),
              expectedBindingCount >= 0 else {
            throw PipelineError.clockEvidenceIncomplete(
                "clock evidence watermarks missing or invalid")
        }
        var expectedNodeStampsByID: [Int: Double] = [:]
        expectedNodeStampsByID.reserveCapacity(nodeInventory.count)
        for node in nodeInventory {
            guard let nodeID = Int(exactly: node.nodeID),
                  expectedNodeStampsByID[nodeID] == nil else {
                throw PipelineError.clockEvidenceIncomplete(
                    "database node inventory contains invalid or duplicate ids")
            }
            expectedNodeStampsByID[nodeID] = node.stamp
        }
        let evidence: StrictClockEvidenceParser.ParsedEvidence
        do {
            // V1R5 §7.1: streaming parse — the sidecar is never loaded
            // as one String (60k+ bindings stay bounded).
            evidence = try StrictClockEvidenceParser.parse(
                url: clockURL,
                expectedTrackingSessionID: trackingSessionID,
                expectedCorrelationCount: expectedCorrelationCount,
                expectedBindingCount: expectedBindingCount,
                expectedNodeStampsByID: expectedNodeStampsByID)
        } catch {
            throw PipelineError.clockEvidenceIncomplete(
                "invalid clock evidence: \(error.localizedDescription)")
        }
        guard StrictClockEvidenceParser.isEvidenceSufficient(evidence) else {
            throw PipelineError.clockEvidenceIncomplete(
                "insufficient clock evidence: correlations=\(evidence.correlations.count) bindings=\(evidence.bindings.count)")
        }
        let mapper = StrictClockEvidenceParser.buildMapper(
            evidence: evidence, sessionStartStamp: sessionStartStamp)
        guard let startUTC = mapper.utcSeconds(forMonotonic: 0),
              let endUTC = mapper.utcSeconds(
                  forMonotonic: sessionEndStamp - sessionStartStamp),
              endUTC >= startUTC else {
            throw PipelineError.clockEvidenceIncomplete(
                "session span outside the node-binding evidence span")
        }
        return mapper
    }

    /// Lost intervals covering trajectory rows that are not publish
    /// eligible (fragment components / gaps / other floors). Runs of
    /// ineligible rows become one interval on the stamp axis (§15.2).
    static func lostIntervalsFromEligibility(
        rows: [MobileNativeTrajectoryRow],
        sessionStartStamp: Double
    ) -> [FinalTrajectory.LostInterval] {
        var intervals: [FinalTrajectory.LostInterval] = []
        var start: Double?
        for row in rows {
            if !row.publishEligible {
                if start == nil { start = row.stamp - sessionStartStamp }
            } else if let s = start {
                intervals.append(FinalTrajectory.LostInterval(
                    fromMonotonic: s, toMonotonic: row.stamp - sessionStartStamp,
                    reason: "unanchored_component"))
                start = nil
            }
        }
        if let s = start, let last = rows.last {
            intervals.append(FinalTrajectory.LostInterval(
                fromMonotonic: s, toMonotonic: last.stamp - sessionStartStamp,
                reason: "unanchored_component"))
        }
        return intervals
    }

    // MARK: - Tags

    /// Raw snapshot-DB node poses (pre-optimization, node frame) used to
    /// propagate tag positions into the final optimized frame:
    /// P_final = T_final_node * inverse(T_raw_node) * P_raw (V1R4 §13.2
    /// raw-pose consistency). The app wires the native graph reader
    /// (`MobileNativeFactorGraph.wireIntoGateway`); host tests inject a
    /// reference implementation.
    static var rawNodePoseProvider: ((URL) -> [Int64: SE2Transform])? = nil

    /// Shelf segments from the compiled prior-map package (`shelves.json`).
    /// V2 consumes compiler-authored start/end/axis/front/back values
    /// directly and uses the legacy element polygon only as an index
    /// envelope. V1 remains readable through its geometry fallback.
    /// Unknown versions or any broken v2 relation fail the whole map.
    static func readShelves(from map: MobileMapLibrary.MapEntry) throws -> [ShelfAssociationEngine.ShelfSegment] {
        let url = map.packageDirectory.appendingPathComponent("shelves.json")
        let data = try Data(contentsOf: url)
        guard let object = try? StrictJSONDocumentParser.object(
            from: data,
            limits: StrictJSONDocumentLimits(maximumBytes: data.count + 1)) as? [String: Any]
        else { throw PipelineError.invalidPriorMap(map.packageDirectory.path) }
        let parsed: PriorMapShelvesSchema.ParsedDocument
        do {
            parsed = try PriorMapShelvesSchema.parse(object)
        } catch {
            throw PipelineError.invalidPriorMap("\(map.packageDirectory.path): \(error)")
        }

        func polygon(_ raw: [String: Any]) -> [(Double, Double)]? {
            var polygonM: [(Double, Double)]?
            if let geometry = raw["geometry"] as? [String: Any],
               let coordinates = geometry["coordinates"] as? [[Any]] {
                var vertices: [(Double, Double)] = []
                for coordinate in coordinates {
                    guard coordinate.count >= 2,
                          let x = StrictJSONScalar.number(coordinate[0]),
                          let y = StrictJSONScalar.number(coordinate[1]),
                          x.isFinite, y.isFinite else {
                        return nil
                    }
                    vertices.append((x, y))
                }
                if vertices.count >= 4 {
                    polygonM = vertices
                }
            }
            return polygonM
        }

        func bounds(
            _ raw: [String: Any]
        ) -> (minimum: (Double, Double), maximum: (Double, Double))? {
            if let value = raw["bounds"] as? [String: Any],
               let minX = StrictJSONScalar.number(value["min_x_m"]),
               let minY = StrictJSONScalar.number(value["min_y_m"]),
               let maxX = StrictJSONScalar.number(value["max_x_m"]),
               let maxY = StrictJSONScalar.number(value["max_y_m"]),
               minX.isFinite, minY.isFinite, maxX.isFinite, maxY.isFinite,
               maxX >= minX, maxY >= minY {
                return ((minX, minY), (maxX, maxY))
            }
            return nil
        }

        let rawByID = Dictionary(uniqueKeysWithValues: parsed.rawShelves.map {
            ($0["id"] as! String, $0)
        })
        if parsed.version == 2 {
            var shelves: [ShelfAssociationEngine.ShelfSegment] = []
            for compiled in parsed.segments {
                guard let raw = rawByID[compiled.shelfSegmentID] else {
                    throw PipelineError.invalidPriorMap(map.packageDirectory.path)
                }
                let envelope = bounds(raw)
                guard let segment = ShelfAssociationEngine.makeCompiledSegment(
                    compiled,
                    polygonM: polygon(raw),
                    boundsMinM: envelope?.minimum,
                    boundsMaxM: envelope?.maximum) else {
                    throw PipelineError.invalidPriorMap(
                        "\(map.packageDirectory.path): invalid compiled shelf \(compiled.shelfSegmentID)")
                }
                shelves.append(segment)
            }
            return shelves
        }

        var legacyShelves: [ShelfAssociationEngine.ShelfSegment] = []
        for raw in parsed.rawShelves {
            guard let shelfSegmentID = raw["id"] as? String,
                  let floorID = raw["floor_id"] as? String else {
                throw PipelineError.invalidPriorMap(map.packageDirectory.path)
            }
            let shelfCode = raw["code"] as? String ?? shelfSegmentID
            let envelope = bounds(raw)
            let yawRad = StrictJSONScalar.number(raw["yaw_rad"])
            guard let segment = ShelfAssociationEngine.makeSegment(
                shelfSegmentID: shelfSegmentID,
                shelfCode: shelfCode,
                floorID: floorID,
                polygonM: polygon(raw),
                boundsMinM: envelope?.minimum,
                boundsMaxM: envelope?.maximum,
                yawRad: yawRad,
                orientationProvenance: "legacy_geometry") else {
                throw PipelineError.invalidPriorMap(
                    "\(map.packageDirectory.path): invalid legacy shelf \(shelfSegmentID)")
            }
            legacyShelves.append(segment)
        }
        return legacyShelves
    }

    /// Fixed structures (`fixed_structures.json`) used by the occlusion
    /// check: a structure between the tag and its shelf blocks the
    /// sight line (§13.4/§13.6). Elements carry rotated polygons when
    /// available; the AABB remains the index envelope.
    static func readFixedStructures(from map: MobileMapLibrary.MapEntry) throws -> [ShelfAssociationEngine.FixedStructure] {
        let url = map.packageDirectory.appendingPathComponent("fixed_structures.json")
        let data = try Data(contentsOf: url)
        guard let object = try? StrictJSONDocumentParser.object(
            from: data,
            limits: StrictJSONDocumentLimits(maximumBytes: data.count + 1)) as? [String: Any],
            let rawStructures = object["structures"] as? [[String: Any]]
        else { throw PipelineError.invalidPriorMap(map.packageDirectory.path) }
        var structures: [ShelfAssociationEngine.FixedStructure] = []
        for raw in rawStructures {
            guard let structureCode = raw["code"] as? String,
                  let floorID = raw["floor_id"] as? String
            else { continue }
            var polygonM: [(Double, Double)]?
            if let geometry = raw["geometry"] as? [String: Any],
               let coordinates = geometry["coordinates"] as? [[Double]] {
                let vertices = coordinates.compactMap { coordinate -> (Double, Double)? in
                    guard coordinate.count >= 2 else { return nil }
                    let x = coordinate[0]
                    let y = coordinate[1]
                    guard x.isFinite, y.isFinite else { return nil }
                    return (x, y)
                }
                if vertices.count >= 3 {
                    polygonM = vertices
                }
            }
            guard let bounds = raw["bounds"] as? [String: Double],
                  let minX = bounds["min_x_m"], let minY = bounds["min_y_m"],
                  let maxX = bounds["max_x_m"], let maxY = bounds["max_y_m"],
                  minX.isFinite, minY.isFinite, maxX.isFinite, maxY.isFinite,
                  maxX >= minX, maxY >= minY else {
                continue
            }
            structures.append(ShelfAssociationEngine.FixedStructure(
                structureCode: structureCode,
                floorID: floorID,
                polygonM: polygonM,
                boundsMinM: (minX, minY),
                boundsMaxM: (maxX, maxY)))
        }
        return structures
    }

    /// V1R4 §13.2/§13.4 resolve + shelf-first + quality gate. The strict
    /// parser already bound every accepted observation to an exact
    /// snapshot-DB node; here each observation is propagated into the
    /// final optimized frame via
    /// P_final = T_final_node * inverse(T_raw_node) * P_raw, then
    /// associated to a shelf/side candidate (first/second margin +
    /// occlusion) BEFORE any clustering, bucketed by the exact
    /// barcode+symbology+floor+shelf-segment+side+session identity, and
    /// only then clustered with a bounded diameter. Unlocalized observations
    /// and observations that fail exact-node resolution become explicit
    /// RESCAN tasks. A resolved position that cannot yet be associated with a
    /// shelf is retained as LOW_CONFIDENCE instead of forcing another scan.
    static func finalizeTags(
        observations: [TagObservationEvidenceObservation],
        resolverIndex: TagObservationResolver.NodeIndex,
        shelves: [ShelfAssociationEngine.ShelfSegment],
        shelfIndex: ShelfAssociationEngine.ShelfSpatialIndex?,
        structures: [ShelfAssociationEngine.FixedStructure],
        sessionID: String,
        storeID: String,
        priorMap: MobileMapLibrary.MapEntry,
        floorID: String,
        graphQualityPassed: Bool,
        rawNodePoses: [Int64: SE2Transform],
        minimumAssociationMarginM: Double
    ) throws -> ([FinalPriceTag], [RescanTask]) {
        guard !observations.isEmpty else { return ([], []) }

        // Resolve each observation against the final optimized nodes.
        var resolved: [TagObservationResolver.ResolvedObservation] = []
        // Exact identity + reason for every frame that cannot contribute a
        // position. Hard authority failures always become RESCAN tasks; one
        // soft measurement miss may be absorbed by a three-frame valid
        // quorum from the same verified burst and marks that tag low confidence.
        typealias TagFailure = (
            barcode: String,
            symbology: String,
            floorID: String,
            trackingSessionID: String,
            burstID: String?,
            reason: String)
        var resolutionFailures: [TagFailure] = []
        var softFrameFailures: [TagFailure] = []
        for raw in observations {
            guard let position = raw.rawPositionM,
                  raw.measurementMethod != "unavailable" else {
                // A complete burst may contain one weak frame while three
                // other exact-bound frames still provide a recomputable
                // position quorum. Defer this frame-level decision until the
                // whole burst has been resolved.
                softFrameFailures.append((
                    barcode: raw.barcode, symbology: raw.symbology,
                    floorID: raw.floorID,
                    trackingSessionID: raw.trackingSessionID,
                    burstID: raw.burstID,
                    reason: raw.rawPositionM == nil
                        ? "unlocalized_observation"
                        : "measurement_method_unavailable"))
                continue
            }
            guard let boundNodeID = raw.boundNodeID else {
                // The propagation chain needs the parser-bound node id;
                // explicit RESCAN task below.
                resolutionFailures.append((
                    barcode: raw.barcode, symbology: raw.symbology,
                    floorID: raw.floorID,
                    trackingSessionID: raw.trackingSessionID,
                    burstID: raw.burstID,
                    reason: "node_binding_missing"))
                continue
            }
            guard let rawNodePose = rawNodePoses[boundNodeID] else {
                // The propagation chain cannot be built without the raw
                // snapshot node pose; explicit RESCAN task below.
                resolutionFailures.append((
                    barcode: raw.barcode, symbology: raw.symbology,
                    floorID: raw.floorID,
                    trackingSessionID: raw.trackingSessionID,
                    burstID: raw.burstID,
                    reason: "raw_node_pose_missing"))
                continue
            }
            let viewQuality: String
            if let normal = raw.surfaceNormalCamera, normal.count == 3 {
                if normal[2] < 0 { viewQuality = "front" }
                else if normal[2] > 0 { viewQuality = "back" }
                else { viewQuality = "unknown" }
            } else {
                viewQuality = "unknown"
            }
            let observation = TagObservationResolver.RawObservation(
                barcode: raw.barcode,
                symbology: raw.symbology,
                floorID: raw.floorID,
                nodeID: boundNodeID,
                nodeTimestamp: raw.nodeTimebaseTimestamp,
                frameMonotonicSeconds: raw.frameTimestamp,
                rawPositionM: position,
                rawNodePose: rawNodePose,
                trackingSessionID: raw.trackingSessionID,
                burstID: raw.burstID,
                frameID: raw.frameID,
                depthQuality: raw.depthInlierRatio,
                viewQuality: viewQuality,
                trackingQuality: raw.localizationState,
                measurementConfidence: raw.measurementConfidence,
                localizationConfidence: raw.localizationConfidence,
                needsReview: raw.needsReview,
                measurementMethod: raw.measurementMethod)
            do {
                resolved.append(try TagObservationResolver.resolve(
                    observation: observation,
                    index: resolverIndex,
                    sessionID: sessionID))
            } catch {
                resolutionFailures.append((
                    barcode: raw.barcode, symbology: raw.symbology,
                    floorID: raw.floorID,
                    trackingSessionID: raw.trackingSessionID,
                    burstID: raw.burstID,
                    reason: String(describing: error)))
            }
        }
        var resolvedFrameCountByBurst: [String: Int] = [:]
        for observation in resolved {
            if let burstID = observation.burstID {
                resolvedFrameCountByBurst[burstID, default: 0] += 1
            }
        }
        var partialPositionBurstIDs = Set<String>()
        var invalidBurstIDs = Set(resolutionFailures.compactMap { $0.burstID })
        for failure in softFrameFailures {
            if let burstID = failure.burstID,
               (resolvedFrameCountByBurst[burstID] ?? 0) >= 3 {
                partialPositionBurstIDs.insert(burstID)
            }
            else {
                resolutionFailures.append(failure)
                if let burstID = failure.burstID {
                    invalidBurstIDs.insert(burstID)
                }
            }
        }
        if !invalidBurstIDs.isEmpty {
            resolved.removeAll { observation in
                guard let burstID = observation.burstID else { return false }
                return invalidBurstIDs.contains(burstID)
            }
        }

        // Shelf/side candidates per observation BEFORE any clustering
        // (§13.4/H-07): use a typed identity so delimiter-bearing barcode
        // values cannot collide, and never cluster across symbologies,
        // floors, physical shelf segments, sides or sessions.
        struct TagBucketKey: Hashable {
            let barcode: String
            let symbology: String
            let floorID: String
            let shelfSegmentID: String
            let shelfSide: String
            let trackingSessionID: String
        }
        var buckets: [TagBucketKey: (
            shelfSegmentID: String,
            shelfSide: String,
            observations: [TagObservationResolver.ResolvedObservation]
        )] = [:]
        do {
            struct BurstBucketKey: Hashable {
                let barcode: String
                let symbology: String
                let floorID: String
                let trackingSessionID: String
                let burstID: String?
            }
            struct AssociationIdentity: Hashable {
                let shelfSegmentID: String
                let shelfSide: String
            }
            var burstCandidates: [BurstBucketKey: [(
                observationIndex: Int,
                association: AssociationIdentity?
            )]] = [:]
            for (observationIndex, observation) in resolved.enumerated() {
                let association = ShelfAssociationEngine.bestAssociation(
                    point: (observation.mapXM, observation.mapYM),
                    shelves: shelves,
                    index: shelfIndex,
                    floorID: observation.floorID,
                    occludedByStructure: { shelf in
                        ShelfAssociationEngine.isOccluded(
                            tagPoint: (observation.mapXM, observation.mapYM),
                            shelf: shelf,
                            structures: structures)
                    })
                let burstKey = BurstBucketKey(
                    barcode: observation.barcode,
                    symbology: observation.symbology,
                    floorID: observation.floorID,
                    trackingSessionID: observation.trackingSessionID,
                    burstID: observation.burstID)
                burstCandidates[burstKey, default: []].append((
                    observationIndex: observationIndex,
                    association: association.map {
                        AssociationIdentity(
                            shelfSegmentID: $0.shelfSegmentID,
                            shelfSide: $0.shelfSide)
                    }))
            }
            let orderedBurstKeys = burstCandidates.keys.sorted {
                ($0.barcode, $0.symbology, $0.floorID,
                 $0.trackingSessionID, $0.burstID ?? "")
                    < ($1.barcode, $1.symbology, $1.floorID,
                       $1.trackingSessionID, $1.burstID ?? "")
            }
            for burstKey in orderedBurstKeys {
                guard let candidates = burstCandidates[burstKey] else {
                    continue
                }
                // One burst is one operator capture of one physical tag. If
                // its frames yield exactly one shelf identity, let frames
                // with no candidate join that identity. If frames disagree
                // across shelf identities, retain the whole burst in one
                // unassociated bucket so it becomes one LOW_CONFIDENCE tag
                // instead of duplicate partial tags or an immediate rescan.
                let identities = Set(candidates.compactMap { $0.association })
                let consensus = identities.count == 1 ? identities.first : nil
                for candidate in candidates {
                    let observation = resolved[candidate.observationIndex]
                    let key = TagBucketKey(
                        barcode: observation.barcode,
                        symbology: observation.symbology,
                        floorID: observation.floorID,
                        shelfSegmentID: consensus?.shelfSegmentID ?? "",
                        shelfSide: consensus?.shelfSide ?? "",
                        trackingSessionID: observation.trackingSessionID)
                    if var bucket = buckets[key] {
                        bucket.observations.append(observation)
                        buckets[key] = bucket
                    } else {
                        buckets[key] = (
                            shelfSegmentID: consensus?.shelfSegmentID ?? "",
                            shelfSide: consensus?.shelfSide ?? "",
                            observations: [observation])
                    }
                }
            }
        }

        var priceTags: [FinalPriceTag] = []
        var rescanTasks: [RescanTask] = []
        // The strict parser verified identity per record; the gate still
        // derives the flag from the actual observations instead of a
        // hard-coded constant.
        let mapSessionIdentityConsistent = observations.allSatisfy {
            $0.trackingSessionID == sessionID
        }
        func authoritativeFailureReason(
            for instance: TagObservationResolver.TagInstance
        ) -> String? {
            guard mapSessionIdentityConsistent else {
                return "map_session_identity_mismatch"
            }
            guard graphQualityPassed else {
                return "graph_quality_failed"
            }
            guard instance.uniqueVerifiedFrameCount >= 3 else {
                return "insufficient_burst_samples"
            }
            guard instance.measurementMethodAccepted else {
                return "measurement_method_unavailable"
            }
            return nil
        }
        // Exact-node/position resolution failures become explicit RESCAN
        // tasks grouped in O(M) by observation identity + reason. Shelf
        // uncertainty is handled separately as LOW_CONFIDENCE.
        struct FailureGroupKey: Hashable {
            let barcode: String
            let symbology: String
            let floorID: String
            let trackingSessionID: String
            let reason: String
        }
        var failureGroups: [FailureGroupKey: Int] = [:]
        failureGroups.reserveCapacity(resolutionFailures.count)
        for failure in resolutionFailures {
            let key = FailureGroupKey(
                barcode: failure.barcode,
                symbology: failure.symbology,
                floorID: failure.floorID,
                trackingSessionID: failure.trackingSessionID,
                reason: failure.reason)
            failureGroups[key, default: 0] += 1
        }
        let orderedFailureKeys = failureGroups.keys.sorted {
            ($0.barcode, $0.symbology, $0.floorID,
             $0.trackingSessionID, $0.reason)
                < ($1.barcode, $1.symbology, $1.floorID,
                   $1.trackingSessionID, $1.reason)
        }
        for group in orderedFailureKeys {
            let failureCount = failureGroups[group] ?? 0
            rescanTasks.append(RescanTask(
                taskID: "rescan-\(rescanTasks.count + 1)-\(group.barcode)-\(group.reason)",
                taskType: .tagRescan,
                floorID: group.floorID,
                barcode: group.barcode,
                tagInstanceID: "\(group.barcode)-\(group.floorID)-unresolved",
                shelfCode: "",
                shelfSegmentID: "",
                regionStartCm: nil,
                regionEndCm: nil,
                localStartTime: "",
                localEndTime: "",
                reasonCode: group.reason,
                humanMessage: "价签观测无法解析（\(failureCount) 条）：\(group.reason)",
                suggestedAction: "重新扫描该价签",
                priority: 1))
        }
        // Per bucket: bounded-diameter robust cluster -> burst fusion ->
        // quality gate (the gate re-associates the fused centroid for
        // first/second margin + occlusion).
        let orderedBucketKeys = buckets.keys.sorted {
            ($0.barcode, $0.symbology, $0.floorID, $0.shelfSegmentID,
             $0.shelfSide, $0.trackingSessionID)
                < ($1.barcode, $1.symbology, $1.floorID, $1.shelfSegmentID,
                   $1.shelfSide, $1.trackingSessionID)
        }
        for bucketKey in orderedBucketKeys {
            guard let bucket = buckets[bucketKey] else { continue }
            let instances = TagObservationResolver.clusterInstances(
                observations: bucket.observations, clusterRadiusM: 1.5)
            for instance in instances {
                guard let association = ShelfAssociationEngine.bestAssociation(
                    point: (instance.mapXM, instance.mapYM),
                    shelves: shelves,
                    index: shelfIndex,
                    floorID: instance.floorID,
                    occludedByStructure: { shelf in
                        ShelfAssociationEngine.isOccluded(
                            tagPoint: (instance.mapXM, instance.mapYM),
                            shelf: shelf,
                            structures: structures)
                    }) else {
                    let reason = authoritativeFailureReason(for: instance)
                        ?? "no_shelf_association"
                    let status = reason == "no_shelf_association"
                        ? "LOW_CONFIDENCE" : "RESCAN_REQUIRED"
                    priceTags.append(FinalPriceTag(
                        tagInstanceID: "\(instance.barcode)-\(instance.floorID)-\(priceTags.count + 1)",
                        barcode: instance.barcode,
                        symbology: instance.symbology,
                        storeID: storeID,
                        floorID: instance.floorID,
                        mapVersion: 1,
                        priorMapSha256: priorMap.packageSHA256,
                        trackingSessionID: sessionID,
                        shelfCode: "",
                        shelfSegmentID: "",
                        shelfSide: "",
                        distanceFromShelfStartCm: nil,
                        positionRatio: nil,
                        mapXM: instance.mapXM,
                        mapYM: instance.mapYM,
                        observationCount: instance.observationCount,
                        positionSpreadCm: instance.positionSpreadM * 100.0,
                        localizationConfidence: instance.localizationConfidence,
                        associationConfidence: instance.associationConfidence,
                        qualityStatus: status,
                        reason: reason))
                    if status == "RESCAN_REQUIRED" {
                        rescanTasks.append(RescanTask(
                            taskID: "rescan-\(rescanTasks.count + 1)-\(instance.barcode)",
                            taskType: .tagRescan,
                            floorID: instance.floorID,
                            barcode: instance.barcode,
                            tagInstanceID: "\(instance.barcode)-\(instance.floorID)-\(priceTags.count)",
                            shelfCode: "",
                            shelfSegmentID: "",
                            regionStartCm: nil,
                            regionEndCm: nil,
                            localStartTime: "",
                            localEndTime: "",
                            reasonCode: reason,
                            humanMessage: reason,
                            suggestedAction: "重新扫描该价签",
                            priority: 1))
                    }
                    continue
                }
                let evaluation: (
                    AutomaticQualityGate.QualityStatus, String)
                if let reason = authoritativeFailureReason(for: instance) {
                    evaluation = (.rescanRequired, reason)
                } else if !partialPositionBurstIDs.isDisjoint(
                        with: instance.burstIDs) {
                    evaluation = (
                        .lowConfidence,
                        "partial_burst_position_unavailable")
                } else if association.shelfSegmentID != bucket.shelfSegmentID
                    || association.shelfSide != bucket.shelfSide {
                    // The fused centroid crossed a segment/side boundary;
                    // never publish it as an automatic acceptance.
                    evaluation = (
                        .lowConfidence,
                        "shelf_centroid_reassociation_changed")
                } else {
                    evaluation = AutomaticQualityGate.evaluate(
                        AutomaticQualityGate.TagQualityInput(
                            observationCount: instance.observationCount,
                            uniqueVerifiedFrameCount:
                                instance.uniqueVerifiedFrameCount,
                            effectiveSampleSize: instance.effectiveSampleSize,
                            positionSpreadM: instance.positionSpreadM,
                            minimumBurstSamples: 3,
                            maximumSpreadM: 0.10,
                            minimumDepthQuality: instance.minimumDepthQuality,
                            viewQualitySufficient: instance.allViewsKnown,
                            trackingQualitySufficient:
                                instance.trackingQualitySufficient,
                            localizationConfidence:
                                instance.localizationConfidence,
                            measurementConfidence:
                                instance.measurementConfidence,
                            needsReview: instance.needsReview,
                            measurementMethodAccepted:
                                instance.measurementMethodAccepted,
                            maximumNodeUncertaintyM:
                                instance.maximumNodeUncertaintyM,
                            bindingMethod: "resolved",
                            association: association,
                            maximumEndpointDistanceM: 0.15,
                            maximumAssociationDistanceM: 0.20,
                            minimumAssociationMarginM: minimumAssociationMarginM,
                            graphQualityPassed: graphQualityPassed,
                            mapSessionIdentityConsistent: mapSessionIdentityConsistent))
                }
                let status = evaluation.0.rawValue
                let reason = evaluation.1
                priceTags.append(FinalPriceTag(
                    tagInstanceID: "\(instance.barcode)-\(instance.floorID)-\(priceTags.count + 1)",
                    barcode: instance.barcode,
                    symbology: instance.symbology,
                    storeID: storeID,
                    floorID: instance.floorID,
                    mapVersion: 1,
                    priorMapSha256: priorMap.packageSHA256,
                    trackingSessionID: sessionID,
                    shelfCode: association.shelfCode,
                    shelfSegmentID: association.shelfSegmentID,
                    shelfSide: association.shelfSide,
                    distanceFromShelfStartCm: association.distanceFromShelfStartCm,
                    positionRatio: association.positionRatio,
                    mapXM: instance.mapXM,
                    mapYM: instance.mapYM,
                    observationCount: instance.observationCount,
                    positionSpreadCm: instance.positionSpreadM * 100.0,
                    localizationConfidence: instance.localizationConfidence,
                    associationConfidence: instance.associationConfidence,
                    qualityStatus: status,
                    reason: reason))
                if status == "RESCAN_REQUIRED" {
                    rescanTasks.append(RescanTask(
                        taskID: "rescan-\(rescanTasks.count + 1)-\(instance.barcode)",
                        taskType: .tagRescan,
                        floorID: instance.floorID,
                        barcode: instance.barcode,
                        tagInstanceID: "\(instance.barcode)-\(instance.floorID)-\(priceTags.count)",
                        shelfCode: association.shelfCode,
                        shelfSegmentID: association.shelfSegmentID,
                        regionStartCm: nil,
                        regionEndCm: nil,
                        localStartTime: "",
                        localEndTime: "",
                        reasonCode: reason,
                        humanMessage: reason,
                        suggestedAction: "重新扫描该价签",
                        priority: 1))
                }
            }
        }
        return (priceTags, rescanTasks)
    }

    // MARK: - Payload builders

    /// RunSummary projection of the strict typed native quality DTO. No
    /// security-relevant value is read through JSONSerialization/NSNumber
    /// coercion: the complete report has already passed duplicate/unknown/
    /// type/schema validation and request/C-outcome binding.
    struct NativeQualityMetrics {
        let factorCount: Int64
        let loopLinks: Int64
        let priorLinks: Int64
        let recoveryLinks: Int64
        let graphInputSHA256: String
        let factorSetSHA256: String
        let policyVersion: String

        static func parse(qualityJSON: String) throws -> NativeQualityMetrics {
            let report = try MobileNativeQualityReport.parse(
                qualityJSON: qualityJSON)
            return NativeQualityMetrics(
                factorCount: report.solver.factorCount,
                loopLinks: report.health.loopLinks,
                priorLinks: report.health.priorLinks,
                recoveryLinks: report.health.recoveryLinks,
                graphInputSHA256: report.graphInputSHA256,
                factorSetSHA256: report.factorSetSHA256,
                policyVersion: report.policyVersion)
        }
    }

    /// Real scan-phase thermal interruptions from the durable
    /// `scan_events.jsonl` (event == "thermal_critical"), plus the
    /// processing-phase serious/critical thermal samples. Both are real
    /// evidence; no placeholder is ever written.
    enum ScanEventEvidenceError: Error, LocalizedError, Equatable {
        case missingFile
        case framing(String)
        case record(Int, String)

        var errorDescription: String? {
            switch self {
            case .missingFile:
                return "扫描事件证据缺失：scan_events.jsonl"
            case .framing(let reason):
                return "扫描事件证据格式错误：\(reason)"
            case .record(let line, let reason):
                return "扫描事件第 \(line) 行无效：\(reason)"
            }
        }
    }

    static func countThermalInterruptions(
        in snapshotDirectory: URL,
        expectedTrackingSessionID: String,
        processingThermalSamples: Int
    ) throws -> Int {
        guard !expectedTrackingSessionID.isEmpty else {
            throw ScanEventEvidenceError.framing(
                "expected tracking session identity is empty")
        }
        var scanInterruptions = 0
        let eventsURL = snapshotDirectory.appendingPathComponent("scan_events.jsonl")
        guard FileManager.default.fileExists(atPath: eventsURL.path) else {
            throw ScanEventEvidenceError.missingFile
        }
        let contract = GeneratedMobileEvidenceContracts.File_scan_events_jsonl.self
        let knownFields: Set<String> = [
            "format", "version", "timestamp", "timestampUnix", "level",
            "event", "message", "trackingSessionId", "fields",
        ]
        let timestampParser = ISO8601DateFormatter()
        timestampParser.formatOptions = [
            .withInternetDateTime, .withFractionalSeconds,
        ]
        do {
            _ = try StrictJSONLStreamReader.forEachLine(
                from: eventsURL,
                limits: StrictJSONLStreamReader.Limits(
                    maximumFileBytes: contract.max_file_bytes,
                    maximumLineBytes: contract.max_record_bytes,
                    maximumLineCount: contract.max_records)) { line in
                let object: [String: Any]
                do {
                    guard let data = line.text.data(using: .utf8) else {
                        throw StrictJSONDocumentParseError.invalidUTF8
                    }
                    object = try StrictJSONDocumentParser.object(
                        from: data,
                        limits: StrictJSONDocumentLimits(
                            maximumBytes: contract.max_record_bytes,
                            maximumNestingDepth: contract.max_nesting_depth))
                } catch {
                    throw ScanEventEvidenceError.record(
                        line.number, "invalid_json")
                }
                let unknown = object.keys.filter { !knownFields.contains($0) }
                guard unknown.isEmpty else {
                    throw ScanEventEvidenceError.record(
                        line.number,
                        "unknown_field_\(unknown.sorted().joined(separator: ","))")
                }
                let missing = knownFields.filter { object[$0] == nil }
                guard missing.isEmpty else {
                    throw ScanEventEvidenceError.record(
                        line.number,
                        "required_field_missing_\(missing.sorted().joined(separator: ","))")
                }
                guard object["format"] as? String == "SupermarketScanEvent" else {
                    throw ScanEventEvidenceError.record(
                        line.number, "format_invalid")
                }
                guard StrictJSONScalar.integer(object["version"]) == 1 else {
                    throw ScanEventEvidenceError.record(
                        line.number, "version_unsupported")
                }
                guard let timestamp = object["timestamp"] as? String,
                      let timestampDate = timestampParser.date(from: timestamp),
                      let timestampUnix = StrictJSONScalar.number(
                          object["timestampUnix"]),
                      timestampUnix >= 0,
                      abs(timestampDate.timeIntervalSince1970 - timestampUnix)
                        <= 0.001,
                      let level = object["level"] as? String,
                      ["info", "warning", "error"].contains(level),
                      let event = object["event"] as? String,
                      !event.isEmpty,
                      let message = object["message"] as? String,
                      !message.isEmpty,
                      let trackingSessionID = object["trackingSessionId"] as? String,
                      !trackingSessionID.isEmpty,
                      let fields = object["fields"] as? [String: Any],
                      fields.allSatisfy({ !$0.key.isEmpty && $0.value is String })
                else {
                    throw ScanEventEvidenceError.record(
                        line.number, "schema_or_type_invalid")
                }
                guard trackingSessionID == expectedTrackingSessionID else {
                    throw ScanEventEvidenceError.record(
                        line.number, "tracking_session_identity_mismatch")
                }
                if event == "thermal_critical" {
                    scanInterruptions += 1
                }
            }
        } catch let error as ScanEventEvidenceError {
            throw error
        } catch let error as StrictJSONLStreamReader.StreamError {
            throw ScanEventEvidenceError.framing(
                error.localizedDescription)
        }
        return scanInterruptions + max(processingThermalSamples, 0)
    }

    private static func buildRunSummary(
        request: Request,
        snapshotDirectory: URL,
        resultID: String,
        metadata: [String: Any],
        nativeOutcome: MobileNativeGraphOutcome,
        processingPath: String,
        runDurationSeconds: Double,
        cancelLatencySeconds: Double,
        devicePositions: [FinalTrajectory.DevicePositionRow],
        priceTags: [FinalPriceTag],
        rescanTasks: [RescanTask]
    ) throws -> [String: String] {
        // Capture the completion boundary immediately before embedding
        // the run diagnostics into the workbook.
        ProcessingResourceGovernor.sampleRunDiagnostics()
        let available = devicePositions.filter { $0.positionStatus == "AVAILABLE" }.count
        // V1R4 §12.4 / RC strict binding: every metric is mandatory in the
        // typed native report. Missing/coerced fields fail the run instead of
        // silently becoming empty strings or fabricated integer values.
        let nativeMetrics = try NativeQualityMetrics.parse(
            qualityJSON: nativeOutcome.qualityJSON)
        return [
            "app_git_sha": request.appGitSHA,
            "app_version": request.appVersion,
            "device_model": request.deviceModel,
            "os_version": request.osVersion,
            "store_id": request.storeID,
            "map_name": request.priorMap.name,
            "prior_map_id": request.priorMap.priorMapID,
            "prior_map_sha256": request.priorMap.packageSHA256,
            "canonical_source_sha256": request.priorMap.canonicalSourceSHA256,
            "source_format": String(describing: metadata["formatVersion"] ?? "xlsx"),
            "tracking_session_id": request.trackingSessionID,
            "local_start": devicePositions.first?.localTimestamp ?? "",
            "local_end": devicePositions.last?.localTimestamp ?? "",
            "utc_start": devicePositions.first?.utcTimestamp ?? "",
            "utc_end": devicePositions.last?.utcTimestamp ?? "",
            "timezone_ids": devicePositions.first?.timezoneID ?? "",
            "duration_seconds": String(format: "%.1f",
                (devicePositions.last?.sessionElapsedS ?? 0) - (devicePositions.first?.sessionElapsedS ?? 0)),
            "rtabmap_node_count": String(nativeOutcome.trajectory.count),
            "skeleton_node_count": String(nativeOutcome.skeletonIDs.count),
            "factor_count": String(nativeMetrics.factorCount),
            "loop_closure_count": String(nativeMetrics.loopLinks),
            "recovery_count": String(nativeMetrics.recoveryLinks),
            "prior_count": String(nativeMetrics.priorLinks),
            "processing_path": processingPath,
            "processing_duration_seconds": String(format: "%.1f", runDurationSeconds),
            "peak_memory_mb": String(ProcessingResourceGovernor.runPeakMemoryFootprintMB()),
            "thermal_interruptions": String(try countThermalInterruptions(
                in: snapshotDirectory,
                expectedTrackingSessionID: request.trackingSessionID,
                processingThermalSamples:
                    ProcessingResourceGovernor.runSeriousOrCriticalThermalSampleCount())),
            "cancel_latency_seconds": String(format: "%.3f", cancelLatencySeconds),
            "graph_quality_status": nativeOutcome.disposition.reportValue,
            "accepted_tag_count": String(priceTags.filter { $0.qualityStatus == "ACCEPTED" }.count),
            "low_confidence_tag_count": String(priceTags.filter {
                $0.qualityStatus == "LOW_CONFIDENCE"
            }.count),
            "rescan_tag_count": String(rescanTasks.count),
            "device_position_row_count": String(devicePositions.count),
            "available_position_count": String(available),
            "unavailable_position_count": String(devicePositions.count - available),
            // V1R1 §14.2: the workbook carries the result id; the final
            // manifest/workbook SHA256 live only in the external
            // result_manifest.json and stay empty here.
            "result_id": resultID,
            "graph_input_sha256": nativeMetrics.graphInputSHA256,
            "factor_set_sha256": nativeMetrics.factorSetSHA256,
            "native_core_sha256": request.nativeCoreSHA256,
            "policy_sha": request.policySHA,
            "result_manifest_sha256": "",
            "workbook_sha256": "",
        ]
    }

    // MARK: - Resource estimate helpers (V1R4 §18)

    /// Builds the byte-level task estimate for the current stage. Each
    /// component is filled with what the run now knows; unknown
    /// components stay zero and the safety reserve is never zeroed.
    private static func estimateTask(
        snapshot: SessionSnapshotTransaction.SessionSnapshot? = nil,
        sourceDatabase: URL,
        nodeCount: Int = 0,
        skeletonCount: Int = 0,
        outcomeRowCount: Int = 0,
        sessionSpanSeconds: Double = 0,
        tagObservationCount: Int = 0,
        burstSidecarURL: URL? = nil,
        devicePositionCount: Int = 0,
        tagCount: Int = 0,
        rescanCount: Int = 0,
        resultDirectory: URL? = nil
    ) -> ProcessingResourceGovernor.TaskEstimate {
        var estimate = ProcessingResourceGovernor.TaskEstimate()
        if let snapshot {
            // Exact snapshot artifact bytes from the input manifest.
            if let artifacts = snapshot.inputManifest["artifacts"] as? [[String: Any]] {
                for artifact in artifacts {
                    estimate.snapshotBytes += (artifact["bytes"] as? NSNumber)?.int64Value ?? 0
                }
            }
        } else {
            // Pre-snapshot: source DB bytes plus a sidecar allowance.
            estimate.snapshotBytes = fileBytes(sourceDatabase) + 2 * 1024 * 1024
        }
        estimate.rawGraphBytes = Int64(nodeCount) * 384 * 3
        estimate.skeletonFactorBytes = Int64(skeletonCount) * 512
        estimate.nativeOutcomeBytes = Int64(outcomeRowCount) * 384 * 2
        estimate.tagEvidenceBytes = Int64(tagObservationCount) * 512
            + (burstSidecarURL.map(fileBytes) ?? 0)
        estimate.trajectoryBytes = Int64(sessionSpanSeconds) * 256
            + Int64(devicePositionCount) * 192
        estimate.xlsxTempBytes = Int64(devicePositionCount) * 192
            + Int64(tagCount) * 512 + Int64(rescanCount) * 384
            + 2 * 1024 * 1024
        estimate.resultStagingBytes = resultDirectory.map(directoryBytes) ?? 0
        return estimate
    }

    private static func fileBytes(_ url: URL) -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return 0
        }
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }

    private static func directoryBytes(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            total += fileBytes(fileURL)
        }
        return total
    }

    // MARK: - Dedicated RESCAN_SESSION terminal artifact

    /// Validates the artifact named by a terminal checkpoint. Recovery
    /// calls this before it treats any task-local reference as reusable.
    static func validateSessionRescanArtifact(
        taskRoot: URL,
        request: Request,
        inputBundleSHA256: String,
        expectedSHA256: String
    ) throws {
        guard try readSessionRescanArtifactIfPresent(
            taskRoot: taskRoot,
            request: request,
            inputBundleSHA256: inputBundleSHA256,
            expectedSHA256: expectedSHA256) != nil else {
            throw SessionRescanArtifactError.invalid(
                "checkpoint references a missing artifact")
        }
    }

    /// Catch-path reconciliation for the window after the immutable
    /// RESCAN_SESSION artifact rename but before its checkpoint and
    /// terminal task state are durable. A missing final artifact returns
    /// nil (pre-rename write failures may follow ordinary failure policy);
    /// every visible candidate is strict-validated and either recovered or
    /// rejected fail-closed.
    private static func reconcileSessionRescanOutcomeAfterFailure(
        request: Request,
        originalError: Error
    ) throws -> MobileOnlyWorkflowError? {
        if case SessionRescanArtifactError.conflictingOutcome(let detail)
                = originalError {
            throw PersistentTaskCheckpoint.CheckpointError.invalidRecord(
                "conflicting RESCAN_SESSION publication: \(detail)")
        }
        let artifactURL = request.taskRoot.appendingPathComponent(
            sessionRescanArtifactFileName)
        var artifactStat = stat()
        guard lstat(artifactURL.path, &artifactStat) == 0 else {
            if errno == ENOENT { return nil }
            throw PersistentTaskCheckpoint.CheckpointError.invalidRecord(
                "cannot inspect RESCAN_SESSION artifact after failure")
        }
        let record: PersistentTaskCoordinator.TaskRecord
        do {
            record = try PersistentTaskCoordinator.read(taskRoot: request.taskRoot)
        } catch {
            throw PersistentTaskCheckpoint.CheckpointError.invalidRecord(
                "task.json unreadable during RESCAN_SESSION reconciliation: \(error)")
        }
        guard let checkpoint = record.checkpoint,
              let inputBundleSHA256 = checkpoint["input_bundle_sha256"] as? String,
              !inputBundleSHA256.isEmpty else {
            throw PersistentTaskCheckpoint.CheckpointError.invalidRecord(
                "visible RESCAN_SESSION artifact has no snapshot binding")
        }
        let artifact: SessionRescanArtifactRecord
        do {
            guard let candidate = try readSessionRescanArtifactIfPresent(
                    taskRoot: request.taskRoot,
                    request: request,
                    inputBundleSHA256: inputBundleSHA256,
                    expectedSHA256: nil) else {
                throw SessionRescanArtifactError.invalid(
                    "visible artifact disappeared during reconciliation")
            }
            // afterRename injection happens before the task-root fsync.
            // Repair it, then require an exact hash-bound stable reread.
            try syncSessionRescanParent(request.taskRoot)
            guard let reopened = try readSessionRescanArtifactIfPresent(
                    taskRoot: request.taskRoot,
                    request: request,
                    inputBundleSHA256: inputBundleSHA256,
                    expectedSHA256: candidate.sha256) else {
                throw SessionRescanArtifactError.invalid(
                    "artifact disappeared after reconciliation fsync")
            }
            artifact = reopened
        } catch {
            throw PersistentTaskCheckpoint.CheckpointError.invalidRecord(
                "RESCAN_SESSION artifact validation failed: \(error)")
        }
        guard try MobileResultLibrary.committedResult(
                taskID: record.taskID) == nil else {
            throw PersistentTaskCheckpoint.CheckpointError.invalidRecord(
                "RESCAN_SESSION task also owns a committed Result")
        }
        guard record.state != .completed,
              record.state != .failed,
              record.state != .cancelled,
              record.state != .interrupted else {
            throw PersistentTaskCheckpoint.CheckpointError.invalidRecord(
                "visible RESCAN_SESSION artifact conflicts with task state "
                    + record.state.rawValue)
        }
        let boundCheckpoint = PersistentTaskCheckpoint.withSessionRescanOutcome(
            artifactSHA256: artifact.sha256,
            in: PersistentTaskCheckpoint.withProcessingPath(
                artifact.processingPath, in: checkpoint))
        if record.state == .rescanRequired {
            guard exactSessionRescanTaskRecord(
                    record, expectedCheckpoint: boundCheckpoint) else {
                throw PersistentTaskCheckpoint.CheckpointError.invalidRecord(
                    "rescan_required task does not exactly bind its artifact")
            }
            return sessionRescanWorkflowError(artifact)
        }
        guard PersistentTaskCoordinator.isResumable(record) else {
            throw PersistentTaskCheckpoint.CheckpointError.invalidRecord(
                "RESCAN_SESSION artifact belongs to a non-resumable task")
        }
        do {
            _ = try PersistentTaskCoordinator.updateState(
                record.state,
                taskRoot: request.taskRoot,
                progress: record.progress,
                checkpoint: boundCheckpoint)
        } catch {
            // A checkpoint writer can report afterRename/afterParentFsync
            // even though the exact reference+SHA generation is durable.
            // Pre-rename failures remain on the old checkpoint for restart.
            guard let reread = try? PersistentTaskCoordinator.read(
                    taskRoot: request.taskRoot),
                  reread.state == record.state,
                  exactCheckpoint(
                    reread.checkpoint, expected: boundCheckpoint) else {
                throw PersistentTaskCheckpoint.CheckpointError.invalidRecord(
                    "RESCAN_SESSION checkpoint transition failed: \(error)")
            }
        }
        return sessionRescanWorkflowError(artifact)
    }

    /// Accepts a terminal task-writer post-rename error only when the
    /// complete no-publish outcome can be reread exactly. Matching terminal
    /// intent cleanup is idempotent; any mismatch remains fail closed.
    private static func reconcileExactSessionRescanTerminalIfPresent(
        request: Request
    ) throws -> Bool {
        var record = try PersistentTaskCoordinator.read(taskRoot: request.taskRoot)
        guard record.state == .rescanRequired else { return false }
        guard record.error == "rescan_session_required",
              let checkpoint = record.checkpoint,
              let inputBundleSHA256 = checkpoint["input_bundle_sha256"] as? String,
              let terminal = checkpoint["terminal_outcome"] as? [String: Any],
              let expectedSHA256 = terminal["sha256"] as? String,
              let artifact = try readSessionRescanArtifactIfPresent(
                taskRoot: request.taskRoot,
                request: request,
                inputBundleSHA256: inputBundleSHA256,
                expectedSHA256: expectedSHA256) else {
            throw PersistentTaskCheckpoint.CheckpointError.invalidRecord(
                "rescan_required task cannot revalidate its artifact")
        }
        try syncSessionRescanParent(request.taskRoot)
        let expectedCheckpoint = PersistentTaskCheckpoint.withSessionRescanOutcome(
            artifactSHA256: artifact.sha256,
            in: PersistentTaskCheckpoint.withProcessingPath(
                artifact.processingPath, in: checkpoint))
        guard exactSessionRescanTaskRecord(
                record, expectedCheckpoint: expectedCheckpoint),
              try MobileResultLibrary.committedResult(
                taskID: record.taskID) == nil else {
            throw PersistentTaskCheckpoint.CheckpointError.invalidRecord(
                "rescan_required task/result/checkpoint conflict")
        }
        do {
            try MobileTerminalStatePersistence.reconcilePendingIntent(
                taskRoot: request.taskRoot)
        } catch {
            throw PersistentTaskCheckpoint.CheckpointError.invalidRecord(
                "rescan_required terminal intent cleanup failed: \(error)")
        }
        record = try PersistentTaskCoordinator.read(taskRoot: request.taskRoot)
        guard exactSessionRescanTaskRecord(
                record, expectedCheckpoint: expectedCheckpoint) else {
            throw PersistentTaskCheckpoint.CheckpointError.invalidRecord(
                "rescan_required task changed during exact reread")
        }
        return true
    }

    private static func exactSessionRescanTaskRecord(
        _ record: PersistentTaskCoordinator.TaskRecord,
        expectedCheckpoint: [String: Any]
    ) -> Bool {
        return record.state == .rescanRequired
            && record.error == "rescan_session_required"
            && exactCheckpoint(record.checkpoint, expected: expectedCheckpoint)
    }

    private static func exactCheckpoint(
        _ actual: [String: Any]?,
        expected: [String: Any]
    ) -> Bool {
        guard let actual,
              let actualData = try? CanonicalJSONEncoder.encode(actual),
              let expectedData = try? CanonicalJSONEncoder.encode(expected) else {
            return false
        }
        return actualData == expectedData
    }

    private static func sessionRescanWorkflowError(
        _ artifact: SessionRescanArtifactRecord
    ) -> MobileOnlyWorkflowError {
        return .rescanSessionRequired(
            "\(artifact.reasonCode)：\(artifact.humanMessage)")
    }

    /// Replays a crash-leftover artifact before evidence parsing/native
    /// graph work. The task state may still be any resumable intermediate
    /// state; updating that same state only adds the hash-bound durable
    /// reference, then the ordinary terminal-intent transaction commits
    /// `.rescanRequired` when the typed error reaches `run`.
    private static func resumeSessionRescanOutcomeIfPresent(
        request: Request,
        snapshot: SessionSnapshotTransaction.SessionSnapshot,
        retryCount: Int
    ) throws {
        guard let artifact = try readSessionRescanArtifactIfPresent(
            taskRoot: request.taskRoot,
            request: request,
            inputBundleSHA256: snapshot.bundleSHA256,
            expectedSHA256: nil) else {
            return
        }
        let checkpoint = PersistentTaskCheckpoint.withSessionRescanOutcome(
            artifactSHA256: artifact.sha256,
            in: PersistentTaskCheckpoint.snapshotCheckpoint(
                request: request,
                snapshot: snapshot,
                retryCount: retryCount,
                processingPath: artifact.processingPath))
        let record = try PersistentTaskCoordinator.read(taskRoot: request.taskRoot)
        _ = try PersistentTaskCoordinator.updateState(
            record.state,
            taskRoot: request.taskRoot,
            progress: record.progress,
            checkpoint: checkpoint)
        throw sessionRescanWorkflowError(artifact)
    }

    private static func persistSessionRescanOutcome(
        request: Request,
        snapshot: SessionSnapshotTransaction.SessionSnapshot,
        processingPath: String,
        graphDisposition: String,
        reasonCode: String,
        humanMessage: String,
        rescanTask: RescanTask,
        checkpoint: [String: Any]
    ) throws -> Never {
        let artifact = try writeSessionRescanArtifact(
            request: request,
            inputBundleSHA256: snapshot.bundleSHA256,
            processingPath: processingPath,
            graphDisposition: graphDisposition,
            reasonCode: reasonCode,
            humanMessage: humanMessage,
            rescanTask: rescanTask)
        let boundCheckpoint = PersistentTaskCheckpoint.withSessionRescanOutcome(
            artifactSHA256: artifact.sha256,
            in: PersistentTaskCheckpoint.withProcessingPath(
                processingPath, in: checkpoint))
        let record = try PersistentTaskCoordinator.read(taskRoot: request.taskRoot)
        _ = try PersistentTaskCoordinator.updateState(
            record.state,
            taskRoot: request.taskRoot,
            progress: record.progress,
            checkpoint: boundCheckpoint)
        throw sessionRescanWorkflowError(artifact)
    }

    private static func writeSessionRescanArtifact(
        request: Request,
        inputBundleSHA256: String,
        processingPath: String,
        graphDisposition: String,
        reasonCode: String,
        humanMessage: String,
        rescanTask: RescanTask
    ) throws -> SessionRescanArtifactRecord {
        if let existing = try readSessionRescanArtifactIfPresent(
            taskRoot: request.taskRoot,
            request: request,
            inputBundleSHA256: inputBundleSHA256,
            expectedSHA256: nil) {
            try validateSessionRescanOutcomeEquivalence(
                existing,
                processingPath: processingPath,
                graphDisposition: graphDisposition,
                reasonCode: reasonCode,
                humanMessage: humanMessage)
            return existing
        }

        let taskPayload = rescanTaskPayload(rescanTask)
        let payload: [String: Any] = [
            "format": "MarketScannerSessionRescanOutcome",
            "version": 1,
            "terminal_outcome": "RESCAN_SESSION",
            "task_id": request.taskRoot.lastPathComponent,
            "tracking_session_id": request.trackingSessionID,
            "store_id": request.storeID,
            "floor_id": request.floorID,
            "prior_map_id": request.priorMap.priorMapID,
            "prior_map_sha256": request.priorMap.packageSHA256,
            "input_bundle_sha256": inputBundleSHA256,
            "processing_path": processingPath,
            "graph_disposition": graphDisposition,
            "reason_code": reasonCode,
            "human_message": humanMessage,
            "suggested_action": "RESCAN_SESSION",
            "publish_permitted": false,
            "result_published": false,
            "created_at_utc": Date().timeIntervalSince1970,
            "rescan_tasks": [
                "count": 1,
                "format": "MarketScannerRescanTasks",
                "tasks": [taskPayload],
                "version": 1,
            ],
        ]
        let data = try CanonicalJSONEncoder.encode(payload)
        guard !data.isEmpty, data.count <= maximumSessionRescanArtifactBytes else {
            throw SessionRescanArtifactError.cannotWrite(
                "payload exceeds \(maximumSessionRescanArtifactBytes) bytes")
        }

        let finalURL = request.taskRoot.appendingPathComponent(
            sessionRescanArtifactFileName)
        let temporaryURL = request.taskRoot.appendingPathComponent(
            ".rescan-session-outcome.tmp-\(UUID().uuidString)")
        var removeTemporary = true
        defer {
            if removeTemporary {
                try? FileManager.default.removeItem(at: temporaryURL)
            }
        }
        do {
            try sessionRescanArtifactWriteFaultInjector?(.beforeTemporaryWrite)
            let fd = open(
                temporaryURL.path,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
                mode_t(0o600))
            guard fd >= 0 else {
                throw SessionRescanArtifactError.cannotWrite(
                    "cannot create exclusive temporary file")
            }
            do {
                try writeAllSessionRescanBytes(data, descriptor: fd)
                guard fchmod(fd, mode_t(0o400)) == 0, fsync(fd) == 0 else {
                    throw SessionRescanArtifactError.cannotWrite(
                        "temporary file chmod/fsync failed")
                }
            } catch {
                close(fd)
                throw error
            }
            close(fd)
            try sessionRescanArtifactWriteFaultInjector?(.afterTemporaryFsync)
            guard renameatx_np(
                AT_FDCWD, temporaryURL.path,
                AT_FDCWD, finalURL.path,
                UInt32(RENAME_EXCL)) == 0 else {
                if errno == EEXIST,
                   let existing = try readSessionRescanArtifactIfPresent(
                    taskRoot: request.taskRoot,
                    request: request,
                    inputBundleSHA256: inputBundleSHA256,
                    expectedSHA256: nil) {
                    // The race winner is acceptable only when it is the
                    // exact same business outcome. Identity/schema validity
                    // alone cannot turn a conflicting RESCAN reason into an
                    // idempotent write.
                    try validateSessionRescanOutcomeEquivalence(
                        existing,
                        processingPath: processingPath,
                        graphDisposition: graphDisposition,
                        reasonCode: reasonCode,
                        humanMessage: humanMessage)
                    return existing
                }
                throw SessionRescanArtifactError.cannotWrite(
                    "exclusive rename failed: \(String(cString: strerror(errno)))")
            }
            removeTemporary = false
            try sessionRescanArtifactWriteFaultInjector?(.afterRename)
            try syncSessionRescanParent(request.taskRoot)
            try sessionRescanArtifactWriteFaultInjector?(.afterParentFsync)
        } catch let error as SessionRescanArtifactError {
            throw error
        } catch {
            throw SessionRescanArtifactError.cannotWrite(String(describing: error))
        }

        guard let committed = try readSessionRescanArtifactIfPresent(
            taskRoot: request.taskRoot,
            request: request,
            inputBundleSHA256: inputBundleSHA256,
            expectedSHA256: sessionRescanSHA256(data)) else {
            throw SessionRescanArtifactError.invalid(
                "artifact disappeared after parent fsync")
        }
        return committed
    }

    private static func readSessionRescanArtifactIfPresent(
        taskRoot: URL,
        request: Request,
        inputBundleSHA256: String,
        expectedSHA256: String?
    ) throws -> SessionRescanArtifactRecord? {
        let url = taskRoot.appendingPathComponent(sessionRescanArtifactFileName)
        var pathBefore = stat()
        guard lstat(url.path, &pathBefore) == 0 else {
            if errno == ENOENT { return nil }
            throw SessionRescanArtifactError.invalid("cannot lstat artifact")
        }
        guard (pathBefore.st_mode & S_IFMT) == S_IFREG,
              pathBefore.st_nlink == 1,
              (pathBefore.st_mode & mode_t(0o222)) == 0,
              pathBefore.st_size > 0,
              pathBefore.st_size <= maximumSessionRescanArtifactBytes else {
            throw SessionRescanArtifactError.invalid(
                "artifact must be one bounded read-only regular file")
        }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else {
            throw SessionRescanArtifactError.invalid("cannot open artifact no-follow")
        }
        defer { close(fd) }
        var opened = stat()
        guard fstat(fd, &opened) == 0,
              sameSessionRescanIdentity(opened, pathBefore) else {
            throw SessionRescanArtifactError.invalid(
                "artifact identity changed before open")
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(fd, rawBuffer.baseAddress, rawBuffer.count)
            }
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else {
                throw SessionRescanArtifactError.invalid("artifact read failed")
            }
            if count == 0 { break }
            guard data.count + count <= maximumSessionRescanArtifactBytes else {
                throw SessionRescanArtifactError.invalid(
                    "artifact grew beyond its hard bound")
            }
            data.append(contentsOf: buffer.prefix(count))
        }
        var openedAfter = stat()
        var pathAfter = stat()
        guard fstat(fd, &openedAfter) == 0,
              lstat(url.path, &pathAfter) == 0,
              data.count == Int(opened.st_size),
              sameSessionRescanIdentity(openedAfter, opened),
              sameSessionRescanIdentity(pathAfter, opened) else {
            throw SessionRescanArtifactError.invalid(
                "artifact changed or was replaced while reading")
        }
        let digest = sessionRescanSHA256(data)
        if let expectedSHA256 = expectedSHA256,
           digest != expectedSHA256.lowercased() {
            throw SessionRescanArtifactError.invalid("checkpoint SHA-256 mismatch")
        }
        guard let object = try? StrictJSONDocumentParser.object(
            from: data,
            limits: StrictJSONDocumentLimits(
                maximumBytes: maximumSessionRescanArtifactBytes)) as? [String: Any],
              Set(object.keys) == Set([
                "format", "version", "terminal_outcome", "task_id",
                "tracking_session_id", "store_id", "floor_id",
                "prior_map_id", "prior_map_sha256", "input_bundle_sha256",
                "processing_path", "graph_disposition", "reason_code",
                "human_message", "suggested_action", "publish_permitted",
                "result_published", "created_at_utc", "rescan_tasks",
              ]),
              object["format"] as? String == "MarketScannerSessionRescanOutcome",
              StrictJSONScalar.integer(object["version"]) == 1,
              object["terminal_outcome"] as? String == "RESCAN_SESSION",
              object["task_id"] as? String == taskRoot.lastPathComponent,
              object["tracking_session_id"] as? String == request.trackingSessionID,
              object["store_id"] as? String == request.storeID,
              object["floor_id"] as? String == request.floorID,
              object["prior_map_id"] as? String == request.priorMap.priorMapID,
              object["prior_map_sha256"] as? String == request.priorMap.packageSHA256,
              object["input_bundle_sha256"] as? String == inputBundleSHA256,
              let processingPath = object["processing_path"] as? String,
              processingPath == "fast" || processingPath == "full_graph_optimization",
              let graphDisposition = object["graph_disposition"] as? String,
              let reasonCode = object["reason_code"] as? String,
              reasonCode == "graph_quality_failed"
                || reasonCode == "no_publish_eligible_trajectory",
              sessionRescanDispositionMatchesReason(
                graphDisposition: graphDisposition,
                reasonCode: reasonCode),
              let humanMessage = object["human_message"] as? String,
              !humanMessage.isEmpty,
              object["suggested_action"] as? String == "RESCAN_SESSION",
              StrictJSONScalar.boolean(object["publish_permitted"]) == false,
              StrictJSONScalar.boolean(object["result_published"]) == false,
              let createdAtUTC = StrictJSONScalar.number(object["created_at_utc"]),
              createdAtUTC.isFinite, createdAtUTC > 0,
              let tasksObject = object["rescan_tasks"] as? [String: Any],
              Set(tasksObject.keys) == Set(["count", "format", "tasks", "version"]),
              StrictJSONScalar.integer(tasksObject["count"]) == 1,
              tasksObject["format"] as? String == "MarketScannerRescanTasks",
              StrictJSONScalar.integer(tasksObject["version"]) == 1,
              let tasks = tasksObject["tasks"] as? [[String: Any]],
              tasks.count == 1,
              Set(tasks[0].keys) == Set([
                "task_id", "task_type", "floor_id", "barcode",
                "shelf_code", "shelf_segment_id", "reason_code",
                "human_message", "suggested_action", "priority",
              ]),
              let rescanTaskID = tasks[0]["task_id"] as? String,
              MobileResultLibrary.isSafeBasename(rescanTaskID),
              tasks[0]["task_type"] as? String == (reasonCode == "graph_quality_failed"
                ? MobileWorksheets.RescanTaskType.insufficientLoop.rawValue
                : MobileWorksheets.RescanTaskType.weakLocalization.rawValue),
              let taskReason = tasks[0]["reason_code"] as? String,
              taskReason == reasonCode,
              tasks[0]["floor_id"] as? String == request.floorID,
              tasks[0]["barcode"] as? String == "",
              tasks[0]["shelf_code"] as? String == "",
              tasks[0]["shelf_segment_id"] as? String == "",
              tasks[0]["human_message"] as? String == humanMessage,
              tasks[0]["suggested_action"] as? String == "RESCAN_SESSION",
              StrictJSONScalar.integer(tasks[0]["priority"]) == 1 else {
            throw SessionRescanArtifactError.invalid(
                "schema, identity, action, or publish invariant mismatch")
        }
        return SessionRescanArtifactRecord(
            sha256: digest,
            processingPath: processingPath,
            graphDisposition: graphDisposition,
            reasonCode: reasonCode,
            humanMessage: humanMessage)
    }

    private static func validateSessionRescanOutcomeEquivalence(
        _ existing: SessionRescanArtifactRecord,
        processingPath: String,
        graphDisposition: String,
        reasonCode: String,
        humanMessage: String
    ) throws {
        guard existing.processingPath == processingPath,
              existing.graphDisposition == graphDisposition,
              existing.reasonCode == reasonCode,
              existing.humanMessage == humanMessage else {
            throw SessionRescanArtifactError.conflictingOutcome(
                "an existing artifact conflicts with the new outcome")
        }
    }

    private static func sessionRescanDispositionMatchesReason(
        graphDisposition: String,
        reasonCode: String
    ) -> Bool {
        switch reasonCode {
        case "no_publish_eligible_trajectory":
            return graphDisposition == MobileGraphDisposition.pass.reportValue
        case "graph_quality_failed":
            return Set([
                MobileGraphDisposition.recoverableFail.reportValue,
                MobileGraphDisposition.nonRecoverableFail.reportValue,
                MobileGraphDisposition.localFrameOnly.reportValue,
            ]).contains(graphDisposition)
        default:
            return false
        }
    }

    private static func sameSessionRescanIdentity(
        _ lhs: stat,
        _ rhs: stat
    ) -> Bool {
        return lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
            && (lhs.st_mode & S_IFMT) == S_IFREG
            && lhs.st_nlink == 1
            && (lhs.st_mode & mode_t(0o222)) == 0
    }

    private static func writeAllSessionRescanBytes(
        _ data: Data,
        descriptor: Int32
    ) throws {
        var written = 0
        let success = data.withUnsafeBytes { rawBuffer -> Bool in
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
        guard success else {
            throw SessionRescanArtifactError.cannotWrite(
                "temporary file write failed")
        }
    }

    private static func syncSessionRescanParent(_ taskRoot: URL) throws {
        let fd = open(taskRoot.path, O_RDONLY | O_DIRECTORY)
        guard fd >= 0 else {
            throw SessionRescanArtifactError.cannotWrite(
                "cannot open task root for fsync")
        }
        defer { close(fd) }
        guard fsync(fd) == 0 else {
            throw SessionRescanArtifactError.cannotWrite(
                "task root fsync failed")
        }
    }

    private static func sessionRescanSHA256(_ data: Data) -> String {
        return SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
    }

    private static func priceTagPayload(_ tag: FinalPriceTag) -> [String: Any] {
        var payload: [String: Any] = [
            "tag_instance_id": tag.tagInstanceID,
            "barcode": tag.barcode,
            "symbology": tag.symbology,
            "store_id": tag.storeID,
            "floor_id": tag.floorID,
            "map_version": tag.mapVersion,
            "prior_map_sha256": tag.priorMapSha256,
            "tracking_session_id": tag.trackingSessionID,
            "shelf_code": tag.shelfCode,
            "shelf_segment_id": tag.shelfSegmentID,
            "shelf_side": tag.shelfSide,
            "map_x_m": tag.mapXM,
            "map_y_m": tag.mapYM,
            "observation_count": tag.observationCount,
            "position_spread_cm": tag.positionSpreadCm,
            "localization_confidence": tag.localizationConfidence,
            "association_confidence": tag.associationConfidence,
            "quality_status": tag.qualityStatus,
            "reason": tag.reason,
        ]
        if let distance = tag.distanceFromShelfStartCm { payload["distance_from_shelf_start_cm"] = distance }
        if let ratio = tag.positionRatio { payload["position_ratio"] = ratio }
        return payload
    }

    private static func rescanTaskPayload(_ task: RescanTask) -> [String: Any] {
        var payload: [String: Any] = [
            "task_id": task.taskID,
            "task_type": task.taskType.rawValue,
            "floor_id": task.floorID,
            "barcode": task.barcode,
            "shelf_code": task.shelfCode,
            "shelf_segment_id": task.shelfSegmentID,
            "reason_code": task.reasonCode,
            "human_message": task.humanMessage,
            "suggested_action": task.suggestedAction,
            "priority": task.priority,
        ]
        if let id = task.tagInstanceID { payload["tag_instance_id"] = id }
        if let start = task.regionStartCm { payload["region_start_cm"] = start }
        if let end = task.regionEndCm { payload["region_end_cm"] = end }
        if !task.localStartTime.isEmpty { payload["local_start_time"] = task.localStartTime }
        if !task.localEndTime.isEmpty { payload["local_end_time"] = task.localEndTime }
        return payload
    }
}
