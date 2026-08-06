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
///    automatic quality gate (ACCEPTED / RESCAN_REQUIRED).
/// 6. Result package files + streaming four-sheet XLSX + external
///    manifest commit.
enum MobileProcessingPipeline {

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
        } catch let error as MobileOnlyWorkflowError where error == .cancelled {
            // §15: a user-cancelled run is recorded as cancelled and can
            // still be resumed later.
            try? PersistentTaskCoordinator.updateState(
                .cancelled, taskRoot: request.taskRoot, error: "cancelled")
            throw error
        } catch let error as PersistentTaskCheckpoint.CheckpointError {
            // Task-record/reference/identity failures never overwrite an
            // existing terminal state (fail closed).
            throw error
        } catch {
            // §15: any other failure is recorded; the durable task is
            // never left claiming an intermediate stage it did not
            // finish.
            try? PersistentTaskCoordinator.updateState(
                .failed, taskRoot: request.taskRoot,
                error: String(describing: error))
            throw error
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
        // V1R3 §8.1 eligibility: an unknown build identity must never
        // reach a publishable session.
        guard request.appGitSHA != "unknown", !request.appGitSHA.isEmpty else {
            throw MobileOnlyWorkflowError.invalidState(
                "app build identity is unknown; processing is blocked")
        }
        // V1R4 §15 Gate L: launch recovery. The persisted task.json is
        // validated together with every durable reference; a verified
        // snapshot is resumed without ever re-reading the mutable
        // source database, and a terminal task (completed/cancelled/
        // failed) is never restarted in-place.
        let taskFileURL = PersistentTaskCoordinator.taskFileURL(taskRoot: request.taskRoot)
        let recovery: PersistentTaskCheckpoint.Recovery
        var retryCount = 0
        if FileManager.default.fileExists(atPath: taskFileURL.path) {
            if let existing = try? PersistentTaskCoordinator.read(taskRoot: request.taskRoot),
               let checkpoint = existing.checkpoint {
                retryCount = ((checkpoint["retry_count"] as? NSNumber)?.intValue ?? 0) + 1
            }
            recovery = try PersistentTaskCheckpoint.recover(
                taskRoot: request.taskRoot, request: request)
        } else {
            _ = try PersistentTaskCoordinator.createTask(
                taskID: request.taskRoot.lastPathComponent,
                taskRoot: request.taskRoot)
            recovery = .fresh
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
                    request: request, retryCount: retryCount))
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
                    retryCount: retryCount))
        }
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
        let finalizedAtUnix = metadata["finalizedAtUnix"] as? Double
            ?? metadata["finalized_at_unix"] as? Double
            ?? Date().timeIntervalSince1970

        // V1R4 §13.2: tag observations are strict-parsed BEFORE
        // optimization — every record is identity/format/pose checked and
        // bound to an exact snapshot-DB node via the node-timebase axis
        // (wired provider, §6.1). Bound node ids pin the adaptive skeleton
        // (§11.3) so tag-bound nodes survive reconstruction (§13). Any
        // rejected record blocks publish fail-closed; it is never silently
        // dropped (the audit is counted and surfaced in the error).
        let nodeInventory = Self.absolutePriorNodeInventoryProvider?(snapshotDatabase) ?? []
        let tagEvidence = try TagObservationEvidenceParser.parse(
            snapshotDirectory: snapshot.snapshotDirectory,
            nodes: nodeInventory,
            priorMapID: request.priorMap.priorMapID,
            priorMapSHA256: request.priorMap.packageSHA256,
            trackingSessionID: request.trackingSessionID,
            floorID: floorID)
        guard tagEvidence.audit.rejectedDetails.isEmpty else {
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
        let priorEvidence = try AbsolutePriorEvidenceParser.parse(
            snapshotDirectory: snapshot.snapshotDirectory,
            nodes: nodeInventory,
            priorMapID: request.priorMap.priorMapID,
            priorMapSHA256: request.priorMap.packageSHA256,
            trackingSessionID: request.trackingSessionID,
            floorID: floorID)
        let absolutePriors = priorEvidence.priors

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
            nativeOutcome = try MobileNativeFactorGraphGateway.runFast(
                request: nativeRequest,
                isCancelled: isCancelled)
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
            let rescanURL = request.taskRoot
                .appendingPathComponent("rescan_tasks.json")
            let rescanRecord: [String: Any] = [
                "count": 1,
                "format": "MarketScannerRescanTasks",
                "tasks": [rescanTaskPayload(graphRescan)],
                "version": 1,
            ]
            try CanonicalJSONEncoder.encode(rescanRecord).write(
                to: rescanURL, options: [.atomic])
            throw PipelineError.qualityGateRejected(
                "\(processingPath) disposition="
                + "\(nativeOutcome.disposition.reportValue)；"
                + "已生成图级 RESCAN：\(rescanURL.path)")
        }
        let graphQualityPassed = true
        try checkCancelled()

        // --- Clock mapping on the native UTC stamp axis (§7/§13) -------
        progress(0.40, "构建时钟映射")
        let traces = try readTrace(in: snapshot.snapshotDirectory)
        let sessionStartStamp = nativeOutcome.trajectory.first?.stamp ?? finalizedAtUnix - 1
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
            sessionEndStamp: sessionEndStamp)
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
                uncertaintyM: $0.uncertaintyM ?? 0.0,
                floorID: floorID)
        }
        guard !finalNodes.isEmpty else {
            throw PipelineError.qualityGateRejected("no publish-eligible trajectory nodes")
        }
        let lostIntervals = buildLostIntervals(
            from: traces, sessionStartStamp: sessionStartStamp) + eligibilityLost
        let trajectoryInput = FinalTrajectory.Input(
            nodes: finalNodes,
            lostIntervals: lostIntervals,
            sessionStartUTC: sessionStartUTC,
            sessionEndUTC: sessionEndUTC)
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
        let (priceTags, rescanTasks) = try finalizeTags(
            observations: tagObservations,
            finalNodes: finalNodes.map {
                TagObservationResolver.FinalNodePose(
                    id: $0.id,
                    monotonicSeconds: $0.monotonicSeconds,
                    pose: SE2Transform(xM: $0.xM, yM: $0.yM, yawRad: $0.yawRad),
                    floorID: $0.floorID)
            },
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
                guard let data = try? CanonicalJSONEncoder.encode(row.canonicalPayload) else { continue }
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
        let runSummary = buildRunSummary(
            request: request,
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
        let resultDurableOutputs = [
            request.taskRoot.appendingPathComponent("input_snapshot").path,
            request.taskRoot.appendingPathComponent("input_manifest.json").path,
            resultDirectory.appendingPathComponent("final_trajectory.jsonl").path,
            resultDirectory.appendingPathComponent("final_tags.json").path,
            resultDirectory.appendingPathComponent("quality_report.json").path,
            resultDirectory.appendingPathComponent("graph_quality.json").path,
            resultDirectory.appendingPathComponent("rescan_tasks.json").path,
            resultDirectory.appendingPathComponent("input_manifest.json").path,
            workbookURL.path,
        ]
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
            ])
        committed = true
        // §15: terminal durable state — the committed result is the
        // final checkpoint binding.
        try PersistentTaskCoordinator.updateState(
            .completed, taskRoot: request.taskRoot, progress: 1.0,
            checkpoint: PersistentTaskCheckpoint.withDurableOutputs(
                resultDurableOutputs,
                in: PersistentTaskCheckpoint.withProcessingPath(
                    processingPath, in: snapshotCheckpoint)))
        progress(1.0, "完成")
        return Outcome(
            resultEntry: entry,
            devicePositionCount: devicePositions.count,
            availablePositionCount: devicePositions.filter { $0.positionStatus == "AVAILABLE" }.count,
            tagCount: priceTags.count,
            rescanCount: rescanTasks.count)
    }

    // MARK: - Evidence readers

    /// One localized node record from `localization_trace.jsonl`.
    struct TraceRecord {
        var timestamp: Double
        var xM: Double
        var yM: Double
        var yawRad: Double
        var localizationState: String
        var trackingState: String
        var floorID: String
        var nodeTimebaseOffsetSeconds: Double
        var nodeTimebaseTimestamp: Double
        var confidence: Double
    }

    static func readMetadata(in snapshotDirectory: URL) throws -> [String: Any] {
        let url = snapshotDirectory.appendingPathComponent("metadata.json")
        let data = try Data(contentsOf: url)
        guard let object = try? StrictJSONDocumentParser.object(
            from: data,
            limits: StrictJSONDocumentLimits(maximumBytes: data.count + 1)) as? [String: Any]
        else { throw PipelineError.missingMetadata }
        return object
    }

    static func readTrace(in snapshotDirectory: URL) throws -> [TraceRecord] {
        let url = snapshotDirectory.appendingPathComponent("localization_trace.jsonl")
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            return []
        }
        var records: [TraceRecord] = []
        for line in content.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let object = try? StrictJSONDocumentParser.object(
                      from: data,
                      limits: StrictJSONDocumentLimits(maximumBytes: data.count + 1)) as? [String: Any]
            else { continue }
            guard let timestamp = object["timestamp"] as? Double,
                  let pose = object["estimatedPose"] as? [String: Any],
                  let xM = pose["x_m"] as? Double,
                  let yM = pose["y_m"] as? Double,
                  let yawRad = pose["yaw_rad"] as? Double
            else { continue }
            records.append(TraceRecord(
                timestamp: timestamp,
                xM: xM, yM: yM, yawRad: yawRad,
                localizationState: object["localizationState"] as? String ?? "unknown",
                trackingState: object["trackingState"] as? String ?? "unknown",
                floorID: object["floorId"] as? String ?? "1",
                nodeTimebaseOffsetSeconds: object["nodeTimebaseOffsetSeconds"] as? Double ?? 0,
                nodeTimebaseTimestamp: object["nodeTimebaseTimestamp"] as? Double ?? timestamp,
                confidence: object["confidence"] as? Double ?? 0))
        }
        return records
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
    static func buildGraphNodes(from traces: [TraceRecord], stride: Int = 4) -> [GraphSampledNode] {
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
        from traces: [TraceRecord], sessionStartStamp: Double
    ) -> [FinalTrajectory.LostInterval] {
        /// Trace monotonic axis -> stamp axis conversion: prefer the
        /// recorded node-timebase UTC, fall back to the raw timestamp.
        func axisTime(_ trace: TraceRecord) -> Double {
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
                || trace.trackingState == "unavailable"
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
        sessionEndStamp: Double
    ) throws -> MonotonicUTCMapper {
        let clockURL = snapshotDirectory
            .appendingPathComponent("clock_correlations.jsonl")
        let content: String
        do {
            content = try String(contentsOf: clockURL, encoding: .utf8)
        } catch {
            throw PipelineError.clockEvidenceIncomplete(
                "clock_correlations.jsonl missing: \(error.localizedDescription)")
        }
        let expectedCorrelationCount =
            (metadata["clockCorrelationCount"] as? NSNumber)?.intValue
        let expectedBindingCount =
            (metadata["clockNodeBindingCount"] as? NSNumber)?.intValue
        let evidence: StrictClockEvidenceParser.ParsedEvidence
        do {
            evidence = try StrictClockEvidenceParser.parse(
                content: content,
                expectedTrackingSessionID: trackingSessionID,
                expectedCorrelationCount: expectedCorrelationCount,
                expectedBindingCount: expectedBindingCount)
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

    /// Shelf segments from the compiled prior-map package (`shelves.json`),
    /// computed per V1R4 §13.5: the rotated polygon (when present) defines
    /// the longitudinal axis, start/end and front/back normals; the AABB is
    /// only an index envelope. A malformed shelf element is skipped with
    /// the segment-level identity intact (code/floor are validated first).
    static func readShelves(from map: MobileMapLibrary.MapEntry) throws -> [ShelfAssociationEngine.ShelfSegment] {
        let url = map.packageDirectory.appendingPathComponent("shelves.json")
        let data = try Data(contentsOf: url)
        guard let object = try? StrictJSONDocumentParser.object(
            from: data,
            limits: StrictJSONDocumentLimits(maximumBytes: data.count + 1)) as? [String: Any],
            let rawShelves = object["shelves"] as? [[String: Any]]
        else { throw PipelineError.invalidPriorMap(map.packageDirectory.path) }
        var shelves: [ShelfAssociationEngine.ShelfSegment] = []
        for raw in rawShelves {
            guard let shelfCode = raw["code"] as? String,
                  let floorID = raw["floor_id"] as? String
            else { continue }
            // Rotated polygon geometry (metres).
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
                if vertices.count >= 4 {
                    polygonM = vertices
                }
            }
            // AABB: index envelope only (§13.5).
            var boundsMinM: (Double, Double)?
            var boundsMaxM: (Double, Double)?
            if let bounds = raw["bounds"] as? [String: Double],
               let minX = bounds["min_x_m"], let minY = bounds["min_y_m"],
               let maxX = bounds["max_x_m"], let maxY = bounds["max_y_m"],
               minX.isFinite, minY.isFinite, maxX.isFinite, maxY.isFinite,
               maxX >= minX, maxY >= minY {
                boundsMinM = (minX, minY)
                boundsMaxM = (maxX, maxY)
            }
            let yawRad = raw["yaw_rad"] as? Double
            if let segment = ShelfAssociationEngine.makeSegment(
                shelfCode: shelfCode,
                floorID: floorID,
                polygonM: polygonM,
                boundsMinM: boundsMinM,
                boundsMaxM: boundsMaxM,
                yawRad: yawRad) {
                shelves.append(segment)
            }
        }
        return shelves
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
    /// occlusion) BEFORE any clustering, bucketed by
    /// barcode+floor+shelf+side, and only then clustered with a bounded
    /// diameter. Unlocalized observations are counted and never
    /// published; observations that fail resolution or association
    /// become explicit RESCAN tasks — nothing is silently dropped.
    static func finalizeTags(
        observations: [TagObservationEvidenceObservation],
        finalNodes: [TagObservationResolver.FinalNodePose],
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
        // (barcode, floorID, reason) for every observation that cannot
        // produce a price tag; surfaced as RESCAN tasks (never dropped).
        var resolutionFailures: [(barcode: String, floorID: String, reason: String)] = []
        for raw in observations {
            guard let position = raw.rawPositionM else {
                // Valid unlocalized evidence: never a price tag, never
                // silently dropped — counted in the quality report.
                resolutionFailures.append((
                    barcode: raw.barcode, floorID: raw.floorID,
                    reason: "unlocalized_observation"))
                continue
            }
            guard let boundNodeID = raw.boundNodeID else {
                // The propagation chain needs the parser-bound node id;
                // explicit RESCAN task below.
                resolutionFailures.append((
                    barcode: raw.barcode, floorID: raw.floorID,
                    reason: "node_binding_missing"))
                continue
            }
            guard let rawNodePose = rawNodePoses[boundNodeID] else {
                // The propagation chain cannot be built without the raw
                // snapshot node pose; explicit RESCAN task below.
                resolutionFailures.append((
                    barcode: raw.barcode, floorID: raw.floorID,
                    reason: "raw_node_pose_missing"))
                continue
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
                trackingSessionID: raw.trackingSessionID)
            do {
                resolved.append(try TagObservationResolver.resolve(
                    observation: observation,
                    finalNodes: finalNodes,
                    sessionID: sessionID))
            } catch {
                resolutionFailures.append((
                    barcode: raw.barcode, floorID: raw.floorID,
                    reason: String(describing: error)))
            }
        }

        // Shelf/side candidates per observation BEFORE any clustering
        // (§13.4: barcode+floor+shelf+side bucket — never cluster across
        // shelves first).
        var buckets: [String: [TagObservationResolver.ResolvedObservation]] = [:]
        var associationFailures: [(barcode: String, floorID: String, reason: String)] = []
        for observation in resolved {
            guard let association = ShelfAssociationEngine.bestAssociation(
                point: (observation.mapXM, observation.mapYM),
                shelves: shelves,
                index: shelfIndex,
                floorID: observation.floorID,
                occludedByStructure: { shelf in
                    ShelfAssociationEngine.isOccluded(
                        tagPoint: (observation.mapXM, observation.mapYM),
                        shelf: shelf,
                        structures: structures)
                }) else {
                associationFailures.append((
                    barcode: observation.barcode,
                    floorID: observation.floorID,
                    reason: "no_shelf_association"))
                continue
            }
            let key = "\(observation.barcode)|\(observation.floorID)|\(association.shelfCode)|\(association.shelfSide)"
            buckets[key, default: []].append(observation)
        }

        var priceTags: [FinalPriceTag] = []
        var rescanTasks: [RescanTask] = []
        // The strict parser verified identity per record; the gate still
        // derives the flag from the actual observations instead of a
        // hard-coded constant.
        let mapSessionIdentityConsistent = observations.allSatisfy {
            $0.trackingSessionID == sessionID
        }
        // Resolution/association failures become explicit RESCAN tasks
        // grouped by (barcode, floorID, reason).
        var failureGroups: [(key: String, barcode: String, floorID: String, reason: String, count: Int)] = []
        for failure in resolutionFailures + associationFailures {
            let key = "\(failure.barcode)|\(failure.floorID)|\(failure.reason)"
            if let index = failureGroups.firstIndex(where: { $0.key == key }) {
                failureGroups[index].count += 1
            } else {
                failureGroups.append((key: key, barcode: failure.barcode,
                                      floorID: failure.floorID,
                                      reason: failure.reason, count: 1))
            }
        }
        for group in failureGroups {
            rescanTasks.append(RescanTask(
                taskID: "rescan-\(rescanTasks.count + 1)-\(group.barcode)-\(group.reason)",
                taskType: .tagRescan,
                floorID: group.floorID,
                barcode: group.barcode,
                tagInstanceID: "\(group.barcode)-\(group.floorID)-unresolved",
                shelfCode: "",
                regionStartCm: nil,
                regionEndCm: nil,
                localStartTime: "",
                localEndTime: "",
                reasonCode: group.reason,
                humanMessage: "价签观测无法解析（\(group.count) 条）：\(group.reason)",
                suggestedAction: "重新扫描该价签",
                priority: 1))
        }
        // Per bucket: bounded-diameter robust cluster -> burst fusion ->
        // quality gate (the gate re-associates the fused centroid for
        // first/second margin + occlusion).
        for bucket in buckets.values {
            let instances = TagObservationResolver.clusterInstances(
                observations: bucket, clusterRadiusM: 1.5)
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
                        shelfSide: "",
                        distanceFromShelfStartCm: nil,
                        positionRatio: nil,
                        mapXM: instance.mapXM,
                        mapYM: instance.mapYM,
                        observationCount: instance.observationCount,
                        positionSpreadCm: instance.positionSpreadM * 100.0,
                        localizationConfidence: instance.localizationConfidence,
                        associationConfidence: instance.associationConfidence,
                        qualityStatus: "RESCAN_REQUIRED",
                        reason: "no_shelf_association"))
                    rescanTasks.append(RescanTask(
                        taskID: "rescan-\(rescanTasks.count + 1)-\(instance.barcode)",
                        taskType: .tagRescan,
                        floorID: instance.floorID,
                        barcode: instance.barcode,
                        tagInstanceID: "\(instance.barcode)-\(instance.floorID)-\(priceTags.count)",
                        shelfCode: "",
                        regionStartCm: nil,
                        regionEndCm: nil,
                        localStartTime: "",
                        localEndTime: "",
                        reasonCode: "no_shelf_association",
                        humanMessage: "无法关联货架",
                        suggestedAction: "重新扫描该价签",
                        priority: 1))
                    continue
                }
                let evaluation = AutomaticQualityGate.evaluate(
                    AutomaticQualityGate.TagQualityInput(
                        observationCount: instance.observationCount,
                        positionSpreadM: instance.positionSpreadM,
                        minimumBurstSamples: 3,
                        maximumSpreadM: 0.15,
                        bindingMethod: "resolved",
                        association: association,
                        maximumEndpointDistanceM: 0.15,
                        maximumAssociationDistanceM: 0.75,
                        minimumAssociationMarginM: minimumAssociationMarginM,
                        graphQualityPassed: graphQualityPassed,
                        mapSessionIdentityConsistent: mapSessionIdentityConsistent))
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

    /// Real factor-graph metrics parsed from the verbatim native quality
    /// JSON (V1R4 §12.4: RunSummary must report actual counts and SHAs,
    /// never placeholders). The native core serializes
    /// `solver.factor_count`, `health.loop_links/prior_links/
    /// recovery_links`, `graph_input_sha256`, `factor_set_sha256` and
    /// `policy_version`; values absent from the payload (e.g. the host
    /// reference implementation) stay nil/empty — never fabricated.
    struct NativeQualityMetrics {
        var factorCount: Int?
        var loopLinks: Int?
        var priorLinks: Int?
        var recoveryLinks: Int?
        var graphInputSHA256: String = ""
        var factorSetSHA256: String = ""
        var policyVersion: String = ""

        static func parse(qualityJSON: String) -> NativeQualityMetrics {
            var metrics = NativeQualityMetrics()
            guard let data = qualityJSON.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data)
                      as? [String: Any]
            else { return metrics }
            if let solver = object["solver"] as? [String: Any] {
                metrics.factorCount = (solver["factor_count"] as? NSNumber)?.intValue
            }
            if let health = object["health"] as? [String: Any] {
                metrics.loopLinks = (health["loop_links"] as? NSNumber)?.intValue
                metrics.priorLinks = (health["prior_links"] as? NSNumber)?.intValue
                metrics.recoveryLinks = (health["recovery_links"] as? NSNumber)?.intValue
            }
            metrics.graphInputSHA256 = object["graph_input_sha256"] as? String ?? ""
            metrics.factorSetSHA256 = object["factor_set_sha256"] as? String ?? ""
            metrics.policyVersion = object["policy_version"] as? String ?? ""
            return metrics
        }
    }

    /// Real scan-phase thermal interruptions from the durable
    /// `scan_events.jsonl` (event == "thermal_critical"), plus the
    /// processing-phase serious/critical thermal samples. Both are real
    /// evidence; no placeholder is ever written.
    static func countThermalInterruptions(
        in snapshotDirectory: URL,
        processingThermalSamples: Int
    ) -> Int {
        var scanInterruptions = 0
        let eventsURL = snapshotDirectory.appendingPathComponent("scan_events.jsonl")
        if let content = try? String(contentsOf: eventsURL, encoding: .utf8) {
            for line in content.split(separator: "\n") {
                guard let data = line.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data)
                          as? [String: Any]
                else { continue }
                if (object["event"] as? String) == "thermal_critical" {
                    scanInterruptions += 1
                }
            }
        }
        return scanInterruptions + max(processingThermalSamples, 0)
    }

    private static func buildRunSummary(
        request: Request,
        resultID: String,
        metadata: [String: Any],
        nativeOutcome: MobileNativeGraphOutcome,
        processingPath: String,
        runDurationSeconds: Double,
        cancelLatencySeconds: Double,
        devicePositions: [FinalTrajectory.DevicePositionRow],
        priceTags: [FinalPriceTag],
        rescanTasks: [RescanTask]
    ) -> [String: String] {
        let available = devicePositions.filter { $0.positionStatus == "AVAILABLE" }.count
        // V1R4 §12.4: real native metrics only. Fields the quality JSON
        // does not carry are written empty (never a fabricated 0).
        let nativeMetrics = NativeQualityMetrics.parse(
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
            "factor_count": nativeMetrics.factorCount.map(String.init) ?? "",
            "loop_closure_count": nativeMetrics.loopLinks.map(String.init) ?? "",
            "recovery_count": nativeMetrics.recoveryLinks.map(String.init) ?? "",
            "prior_count": nativeMetrics.priorLinks.map(String.init) ?? "",
            "processing_path": processingPath,
            "processing_duration_seconds": String(format: "%.1f", runDurationSeconds),
            "peak_memory_mb": String(ProcessingResourceGovernor.runPeakMemoryFootprintMB()),
            "thermal_interruptions": String(countThermalInterruptions(
                in: request.finalizedSession,
                processingThermalSamples:
                    ProcessingResourceGovernor.runSeriousOrCriticalThermalSampleCount())),
            "cancel_latency_seconds": String(format: "%.3f", cancelLatencySeconds),
            "graph_quality_status": nativeOutcome.disposition.reportValue,
            "accepted_tag_count": String(priceTags.filter { $0.qualityStatus == "ACCEPTED" }.count),
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
