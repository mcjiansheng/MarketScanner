import UIKit

/// The single entry point of the Mobile-Only product flow.
///
/// V1R2 (Gate 0 §4.1 / Gate A §5) rework:
/// - `beginMapImport(from:contract:storeID:mapName:)` is the ONLY import
///   entry point. The coordinator itself runs the full
///   pick → stage → import → compile → register chain; the UI only
///   observes unified progress/completion events. The UI must never wait
///   for `onImportFinished` before calling the function that produces it
///   (that pattern deadlocked the V1R1 wizard).
/// - Heavy work (import, compile, snapshot, optimize, export) runs on a
///   dedicated serial background queue (§5.1); the main thread only
///   receives observer notifications.
/// - Observers register with tokens (§5.3): no page can overwrite another
///   page's callback by assigning a global closure.
/// - Every transition goes through the explicit transition table of
///   `MobileOnlyWorkflowState` (§5.4); illegal transitions are typed
///   errors and are never silently applied.
/// - `workflow_state.json` persists the full durable context (§5.2):
///   state, task_id, staged_source, map identity, session identity,
///   result_id, progress/checkpoint, error_code, app_git_sha,
///   policy_sha and updated_at. On launch the references are verified
///   before an interrupted run can resume.
final class MobileOnlyWorkflowCoordinator {

    static let shared = MobileOnlyWorkflowCoordinator()

    // MARK: - Observer registry (§5.3, token based)

    /// Token returned by every observer registration; pages keep their
    /// tokens and remove them on exit so several pages can observe at
    /// once without overwriting each other.
    struct ObserverToken: Hashable {
        let id: UUID
    }

    private let observerLock = NSLock()
    private var stateObservers: [UUID: (MobileOnlyWorkflowState) -> Void] = [:]
    private var progressObservers: [UUID: (Double, String) -> Void] = [:]
    private var importObservers: [UUID: (Result<MapSourceImportReport, MobileOnlyWorkflowError>) -> Void] = [:]
    private var compileObservers: [UUID: (Result<MobileMapLibrary.MapEntry, MobileOnlyWorkflowError>) -> Void] = [:]
    private var processingObservers: [UUID: (Result<MobileResultLibrary.ResultEntry, MobileOnlyWorkflowError>) -> Void] = [:]

    @discardableResult
    func addStateObserver(_ handler: @escaping (MobileOnlyWorkflowState) -> Void) -> ObserverToken {
        let token = ObserverToken(id: UUID())
        observerLock.lock(); stateObservers[token.id] = handler; observerLock.unlock()
        return token
    }

    @discardableResult
    func addProgressObserver(_ handler: @escaping (Double, String) -> Void) -> ObserverToken {
        let token = ObserverToken(id: UUID())
        observerLock.lock(); progressObservers[token.id] = handler; observerLock.unlock()
        return token
    }

    @discardableResult
    func addImportObserver(_ handler: @escaping (Result<MapSourceImportReport, MobileOnlyWorkflowError>) -> Void) -> ObserverToken {
        let token = ObserverToken(id: UUID())
        observerLock.lock(); importObservers[token.id] = handler; observerLock.unlock()
        return token
    }

    @discardableResult
    func addCompileObserver(_ handler: @escaping (Result<MobileMapLibrary.MapEntry, MobileOnlyWorkflowError>) -> Void) -> ObserverToken {
        let token = ObserverToken(id: UUID())
        observerLock.lock(); compileObservers[token.id] = handler; observerLock.unlock()
        return token
    }

    @discardableResult
    func addProcessingObserver(_ handler: @escaping (Result<MobileResultLibrary.ResultEntry, MobileOnlyWorkflowError>) -> Void) -> ObserverToken {
        let token = ObserverToken(id: UUID())
        observerLock.lock(); processingObservers[token.id] = handler; observerLock.unlock()
        return token
    }

    func removeObserver(_ token: ObserverToken) {
        observerLock.lock()
        stateObservers.removeValue(forKey: token.id)
        progressObservers.removeValue(forKey: token.id)
        importObservers.removeValue(forKey: token.id)
        compileObservers.removeValue(forKey: token.id)
        processingObservers.removeValue(forKey: token.id)
        observerLock.unlock()
    }

    private func notifyState(_ state: MobileOnlyWorkflowState) {
        observerLock.lock(); let handlers = Array(stateObservers.values); observerLock.unlock()
        DispatchQueue.main.async {
            for handler in handlers { handler(state) }
        }
    }

    private func notifyProgress(_ fraction: Double, _ message: String) {
        observerLock.lock(); let handlers = Array(progressObservers.values); observerLock.unlock()
        DispatchQueue.main.async {
            for handler in handlers { handler(fraction, message) }
        }
    }

    private func notifyImport(_ result: Result<MapSourceImportReport, MobileOnlyWorkflowError>) {
        observerLock.lock(); let handlers = Array(importObservers.values); observerLock.unlock()
        DispatchQueue.main.async {
            for handler in handlers { handler(result) }
        }
    }

    private func notifyCompile(_ result: Result<MobileMapLibrary.MapEntry, MobileOnlyWorkflowError>) {
        observerLock.lock(); let handlers = Array(compileObservers.values); observerLock.unlock()
        DispatchQueue.main.async {
            for handler in handlers { handler(result) }
        }
    }

    private func notifyProcessing(_ result: Result<MobileResultLibrary.ResultEntry, MobileOnlyWorkflowError>) {
        observerLock.lock(); let handlers = Array(processingObservers.values); observerLock.unlock()
        DispatchQueue.main.async {
            for handler in handlers { handler(result) }
        }
    }

    // MARK: - State

    private(set) var state: MobileOnlyWorkflowState = .idle
    private(set) var lastError: MobileOnlyWorkflowError?

    /// Latest compiled map entry; kept until a scan starts.
    private(set) var activeMap: MobileMapLibrary.MapEntry?

    /// Single scanner delegate slot (registered once by ViewController).
    /// The host must start the real scan and return a receipt; throwing
    /// or an incomplete receipt keeps the workflow out of `.scanning`.
    var onStartScan: ((MobileScanConfiguration) throws -> MobileScanStartReceipt)?

    /// B-09: called when a validated host start cannot be committed
    /// (receipt invalid or persistence failed). The host must stop the
    /// already-running scan so it cannot outlive a failed workflow.
    var onRollbackScan: ((MobileScanStartReceipt) -> Void)?

    /// Last validated scan start receipt (§4.1), durably persisted.
    private(set) var lastScanReceipt: MobileScanStartReceipt?

    // MARK: - App identity (populated by the host app)

    var appGitSHA: String = "unknown"
    var appVersion: String = "1.0"
    var deviceModel: String = "iPhone"
    var osVersion: String = "unknown"
    /// SHA of the processing policy in effect (§5.2 policy_sha).
    var policySHA: String = "mobile-processing-policy-v1"
    /// Exact source SHA of the shared native factor-graph core compiled
    /// into this app (V1R3 §4.4 / §14.4 binding).
    var nativeCoreSHA256: String = "unknown"

    // MARK: - Durable context (§5.2)

    struct PersistedContext {
        var state: MobileOnlyWorkflowState
        var taskID: String = ""
        var stagedSource: String = ""
        var originalFilename: String = ""
        var contractRaw: String = ""
        var storeID: String = ""
        var mapID: String = ""
        var mapSHA: String = ""
        var sessionID: String = ""
        var segmentDirectory: String = ""
        var sourceDatabase: String = ""
        var resultID: String = ""
        var progress: Double = 0
        var checkpoint: String = ""
        var errorCode: String = ""
        var appGitSHA: String = ""
        var policySHA: String = ""
        var updatedAt: Double = 0
    }

    private(set) var context = PersistedContext(state: .idle)

    // MARK: - Ownership and work queue

    private var documentPicker: MapSourceDocumentPicker?
    private var importOperation: BlockOperation?
    private var processingOperation: BlockOperation?
    private var importBusy = false
    private var processingBusy = false
    private let coordinatorLock = NSLock()
    /// Guards `state` reads/writes; transitions may be requested from
    /// the main thread (UI) and the serial work queue.
    private let stateLock = NSLock()
    /// Guards every read/write of the durable `context` (mutated from the
    /// background work queue and read from the main thread).
    private let contextLock = NSLock()

    /// Serial background queue for every heavy step (§5.1). MainActor is
    /// never used for import/compile/snapshot/optimize/export work.
    private let workQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "MarketScannerWorkflow.work"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        return queue
    }()

    // MARK: - Persistence

    private var stateFileURL: URL {
        let base = try! FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true)
        return base
            .appendingPathComponent("MarketScanner", isDirectory: true)
            .appendingPathComponent("workflow_state.json")
    }

    private init() {
        context.state = .idle
        loadAndVerifyPersistedContext()
    }

    // MARK: - Import flow (Gate 0 §4.1 unified chain)

    /// Presents the Files picker and — once a file is staged — runs the
    /// full strict import + compile + register chain automatically.
    /// Double-click / concurrent imports are rejected with a typed error.
    func beginMapImport(
        from presenter: UIViewController,
        contract: CoordinateContract,
        storeID: String? = nil,
        mapName: String? = nil
    ) {
        coordinatorLock.lock()
        guard !importBusy else {
            coordinatorLock.unlock()
            let error = MobileOnlyWorkflowError.duplicateImport("import already running")
            lastError = error
            notifyImport(.failure(error))
            return
        }
        importBusy = true
        coordinatorLock.unlock()

        guard transition(to: .pickingMap) else {
            releaseImport()
            return
        }
        contextLock.lock()
        context.contractRaw = contract == .topLeft ? "top_left" : "bottom_left"
        context.storeID = storeID ?? ""
        contextLock.unlock()
        persistContext()

        let picker = MapSourceDocumentPicker { [weak self] outcome in
            guard let self = self else { return }
            switch outcome {
            case .staged(let url, let originalFilename):
                self.contextLock.lock()
                self.context.stagedSource = url.path
                self.context.originalFilename = originalFilename
                self.contextLock.unlock()
                self.persistContext()
                self.transition(to: .stagingMapSource)
                self.runImportChain(
                    stagedURL: url,
                    filename: originalFilename,
                    contract: contract,
                    storeID: storeID,
                    mapName: mapName)
            case .failed(let reason):
                let error = MobileOnlyWorkflowError.pickerCopyFailed(reason.message)
                self.fail(with: error)
                self.notifyImport(.failure(error))
                // H-11: the failed path must release the import gate too,
                // otherwise `importBusy` and the strong picker reference
                // stay forever and every later import is rejected as a
                // duplicate.
                self.releaseImport()
            case .cancelled:
                self.releaseImport()
                self.transition(to: .idle)
            }
        }
        self.documentPicker = picker // strong reference until callback
        picker.present(from: presenter)
    }

    func cancelImport() {
        // H-11: cancel only marks the running/queued operation. The busy
        // gate is released by the operation's completion block once the
        // background chain has REALLY stopped — releasing it here would
        // let a new import start while the old operation still compiles
        // and registers (the pre-H-11 race).
        importOperation?.cancel()
        transition(to: .cancelled)
        transition(to: .idle)
    }

    private func releaseImport() {
        documentPicker = nil
        contextLock.lock()
        context.stagedSource = ""
        context.originalFilename = ""
        contextLock.unlock()
        coordinatorLock.lock(); importBusy = false; coordinatorLock.unlock()
        persistContext()
    }

    /// Background chain: strict import → compile → immutable package →
    /// registry register (§4.1). Every step reports through the unified
    /// observer registry; failures are typed and leave the library
    /// untouched.
    private func runImportChain(
        stagedURL: URL,
        filename: String,
        contract: CoordinateContract,
        storeID: String?,
        mapName: String?
    ) {
        let operation = BlockOperation { [weak self] in
            self?.executeImportChain(
                stagedURL: stagedURL,
                filename: filename,
                contract: contract,
                storeID: storeID,
                mapName: mapName)
        }
        // H-11: the gate releases when THIS operation has truly finished
        // (cancelled-while-queued operations also run their completion
        // block). The identity check keeps a stale operation's completion
        // from clearing the gate of a newer import.
        operation.completionBlock = { [weak self, weak operation] in
            guard let self = self, let operation = operation else { return }
            self.coordinatorLock.lock()
            let stillCurrent = self.importOperation === operation
            self.coordinatorLock.unlock()
            if stillCurrent {
                self.releaseImport()
            }
        }
        importOperation = operation
        workQueue.addOperation(operation)
    }

    private func executeImportChain(
        stagedURL: URL,
        filename: String,
        contract: CoordinateContract,
        storeID: String?,
        mapName: String?
    ) {
        // 1. Strict import (XLSX/CSV/JSON → canonical source v2).
        guard transition(to: .importingMap) else {
            releaseImport()
            return
        }
        notifyProgress(0.15, "严格解析地图文件")
        let report: MapSourceImportReport
        do {
            report = try MapSourceImportCoordinator.importMap(
                stagedURL: stagedURL,
                originalFilename: filename,
                contract: contract,
                storeId: storeID,
                mapName: mapName,
                strict: true)
        } catch let error as MobileOnlyWorkflowError {
            self.fail(with: error)
            self.notifyImport(.failure(error))
            self.releaseImport()
            return
        } catch {
            if (importOperation?.isCancelled ?? false) {
                let cancelled = MobileOnlyWorkflowError.cancelled
                self.fail(with: cancelled)
                self.notifyImport(.failure(cancelled))
            } else {
                let wrapped = MobileOnlyWorkflowError.importFailed(error.localizedDescription)
                self.fail(with: wrapped)
                self.notifyImport(.failure(wrapped))
            }
            self.releaseImport()
            return
        }
        if importOperation?.isCancelled ?? false {
            let cancelled = MobileOnlyWorkflowError.cancelled
            self.fail(with: cancelled)
            self.notifyImport(.failure(cancelled))
            self.releaseImport()
            return
        }
        self.notifyImport(.success(report))

        // 2. Compile into a staging directory.
        guard transition(to: .compilingMap) else {
            releaseImport()
            return
        }
        notifyProgress(0.60, "手机端编译地图")
        do {
            let taskID = "compile-\(UUID().uuidString)"
            contextLock.lock()
            context.taskID = taskID
            context.mapID = ""
            contextLock.unlock()
            persistContext()
            let staging = try MobileMapLibrary.stagingDirectory(for: taskID)
            let compileResult = try MobilePriorMapCompiler.compile(
                canonicalSource: report.canonicalSource,
                outputDirectory: staging)

            // 3. Content-addressed immutable home (§7.3): when the same
            //    (map-id, sha) package already exists, re-verify and reuse
            //    it instead of deleting/overwriting.
            let target = try MobileMapLibrary.packageDirectory(
                priorMapID: compileResult.priorMapID,
                packageSHA: compileResult.packageSHA256)
            let fileManager = FileManager.default
            if fileManager.fileExists(atPath: target.path) {
                // V1R4 §14.2: an existing content-addressed target is
                // reused only after re-verification (full manifest +
                // digest + identity); a corrupt package fails closed
                // instead of being silently overwritten.
                _ = try MobileMapLibrary.verifyPackage(
                    at: target,
                    priorMapID: compileResult.priorMapID,
                    packageSHA256: compileResult.packageSHA256,
                    expectedFloorCount: compileResult.floorCount,
                    expectedElementCount: compileResult.elementCount)
                try? fileManager.removeItem(at: staging)
            } else {
                try fileManager.createDirectory(
                    at: target.deletingLastPathComponent(),
                    withIntermediateDirectories: true)
                try fileManager.moveItem(at: staging, to: target)
            }

            // 4. Durable registry update.
            let entry = try MobileMapLibrary.register(
                priorMapID: compileResult.priorMapID,
                name: report.mapName,
                packageSHA256: compileResult.packageSHA256,
                packageURL: target,
                floorCount: compileResult.floorCount,
                elementCount: compileResult.elementCount,
                compilerVersion: "swift-v1",
                canonicalSourceSHA256: report.canonicalSourceSha256)
            self.activeMap = entry
            self.contextLock.lock()
            self.context.mapID = entry.priorMapID
            self.context.mapSHA = entry.packageSHA256
            self.context.taskID = ""
            self.contextLock.unlock()
            self.persistContext()
            self.transition(to: .mapReady)
            self.notifyProgress(1.0, "地图已注册")
            self.notifyCompile(.success(entry))
        } catch let error as MobileOnlyWorkflowError {
            self.fail(with: error)
            self.notifyCompile(.failure(error))
        } catch {
            let wrapped = MobileOnlyWorkflowError.compileFailed(error.localizedDescription)
            self.fail(with: wrapped)
            self.notifyCompile(.failure(wrapped))
        }
        self.releaseImport()
    }

    // MARK: - Scan flow

    func beginScanSetup(map: MobileMapLibrary.MapEntry) {
        activeMap = map
        contextLock.lock()
        context.mapID = map.priorMapID
        context.mapSHA = map.packageSHA256
        contextLock.unlock()
        transition(to: .configuringScan)
        persistContext()
    }

    func commitScanConfiguration(_ configuration: MobileScanConfiguration) {
        // Transactional start (§4.3): validate -> require host ->
        // host.start -> validate receipt -> persist receipt -> scanning.
        // Any failure goes configuringScan -> failed; the workflow never
        // enters `.scanning` before the receipt is validated.
        guard state == .configuringScan else {
            fail(with: .invalidState(
                "scan commit requires configuringScan, got \(state.rawValue)"))
            return
        }
        guard configuration.priorMap.packageSHA256 == activeMap?.packageSHA256 else {
            fail(with: .invalidState("map identity mismatch"))
            return
        }
        guard !configuration.storeID.isEmpty,
              !configuration.floorID.isEmpty else {
            fail(with: .invalidState("store/floor identity missing"))
            return
        }
        guard appGitSHA != "unknown", !appGitSHA.isEmpty else {
            fail(with: .invalidState("app build identity unknown"))
            return
        }
        guard let host = onStartScan else {
            fail(with: .invalidState("scan host not registered"))
            return
        }
        let receipt: MobileScanStartReceipt
        do {
            receipt = try host(configuration)
        } catch {
            fail(with: .invalidState("scan start failed: \(error.localizedDescription)"))
            return
        }
        guard receipt.isComplete,
              receipt.priorMapSHA256 == configuration.priorMap.packageSHA256,
              receipt.floorID == configuration.floorID,
              receipt.storeID == configuration.storeID else {
            // B-09: the host reported a started scan; stop it before the
            // workflow fails, otherwise the live capture outlives the
            // failed workflow.
            onRollbackScan?(receipt)
            fail(with: .invalidState("scan start receipt incomplete or inconsistent"))
            return
        }
        do {
            try persistScanReceipt(receipt)
        } catch {
            // B-09: same rollback requirement on persistence failure.
            onRollbackScan?(receipt)
            fail(with: .invalidState("scan receipt persistence failed: \(error.localizedDescription)"))
            return
        }
        lastScanReceipt = receipt
        transition(to: .scanning)
    }

    /// Durably stores the validated receipt (§4.1) so a crash after host
    /// start but before workflow commit is recoverable/auditable.
    private func persistScanReceipt(_ receipt: MobileScanStartReceipt) throws {
        let directory = stateFileURL.deletingLastPathComponent()
            .appendingPathComponent("scan_receipts", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let data = try CanonicalJSONEncoder.encode([
            "format": "MarketScannerScanStartReceipt",
            "version": 1,
            "tracking_session_id": receipt.trackingSessionID,
            "segment_directory": receipt.segmentDirectory.path,
            "database_url": receipt.databaseURL.path,
            "prior_map_id": receipt.priorMapID,
            "prior_map_sha256": receipt.priorMapSHA256,
            "floor_id": receipt.floorID,
            "store_id": receipt.storeID,
            "ar_session_started": receipt.arSessionStarted,
            "rtabmap_recording_started": receipt.rtabMapRecordingStarted,
            "required_sidecar_writers_ready": receipt.requiredSidecarWritersReady,
            "started_at_monotonic": receipt.startedAtMonotonic,
            "started_at_utc": receipt.startedAtUTC,
            "app_git_sha": receipt.appGitSHA,
        ])
        let file = directory.appendingPathComponent(
            "\(receipt.trackingSessionID).json")
        try data.write(to: file, options: [.atomic])
        // B-09: durability is proven by fsync, not assumed — the receipt
        // must survive a crash right after the workflow commits.
        try Self.fsyncURL(file)
        try Self.fsyncDirectory(directory)
    }

    /// B-09: fsync a file (fail-closed; the receipt is not durable until
    /// both the file and its parent directory are flushed).
    private static func fsyncURL(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else {
            throw MobileOnlyWorkflowError.invalidState(
                "receipt fsync open failed: \(url.lastPathComponent)")
        }
        defer { close(fd) }
        guard fsync(fd) == 0 else {
            throw MobileOnlyWorkflowError.invalidState(
                "receipt fsync failed: \(url.lastPathComponent)")
        }
    }

    /// B-09: fsync a directory so the rename that created the receipt
    /// file is durable.
    private static func fsyncDirectory(_ directory: URL) throws {
        let fd = open(directory.path, O_RDONLY)
        guard fd >= 0 else {
            throw MobileOnlyWorkflowError.invalidState(
                "receipt directory fsync open failed: \(directory.lastPathComponent)")
        }
        defer { close(fd) }
        guard fsync(fd) == 0 else {
            throw MobileOnlyWorkflowError.invalidState(
                "receipt directory fsync failed: \(directory.lastPathComponent)")
        }
    }

    func scanFinalized() {
        transition(to: .finalizingScan)
    }

    /// Reported by the scanner host when the real scan start failed
    /// (package missing, SHA mismatch, ARKit/RTAB-Map refused). The
    /// workflow must not stay stuck in `.scanning` (V1R2 review fix).
    func scanStartFailed(with error: Error) {
        if let workflowError = error as? MobileOnlyWorkflowError {
            fail(with: workflowError)
        } else {
            fail(with: .invalidState(error.localizedDescription))
        }
    }

    // MARK: - Processing flow (Gate A / Fast+Deep / results)

    /// Processes a finalized session end-to-end on the background work
    /// queue (§5.1): snapshot → graph → optimization → trajectory →
    /// tags → result package → streaming XLSX.
    func beginProcessing(
        finalizedSession: URL,
        sourceDatabase: URL,
        priorMap: MobileMapLibrary.MapEntry,
        storeID: String,
        floorID: String,
        trackingSessionID: String,
        taskID: String? = nil
    ) {
        coordinatorLock.lock()
        guard !processingBusy else {
            coordinatorLock.unlock()
            let error = MobileOnlyWorkflowError.invalidState("processing already running")
            lastError = error
            notifyProcessing(.failure(error))
            return
        }
        processingBusy = true
        coordinatorLock.unlock()

        guard transition(to: .snapshotting) else {
            coordinatorLock.lock(); processingBusy = false; coordinatorLock.unlock()
            return
        }
        // V1R4 §15: a resumed run re-uses the persisted task ID — a new
        // task is never created to impersonate a resume. The pipeline
        // validates task.json and resumes from the last durable
        // checkpoint inside the same task directory.
        let taskID = taskID ?? "task-\(UUID().uuidString)"
        guard let taskRoot = try? MobileProcessingTaskStore.createTask(taskID: taskID) else {
            coordinatorLock.lock(); processingBusy = false; coordinatorLock.unlock()
            fail(with: .snapshotFailed("cannot create task directory"))
            notifyProcessing(.failure(lastError ?? .snapshotFailed("unknown")))
            return
        }
        contextLock.lock()
        context.taskID = taskID
        context.sessionID = trackingSessionID
        context.segmentDirectory = finalizedSession.path
        context.sourceDatabase = sourceDatabase.path
        context.mapID = priorMap.priorMapID
        context.mapSHA = priorMap.packageSHA256
        context.progress = 0
        context.checkpoint = "snapshotting"
        contextLock.unlock()
        persistContext()

        let request = MobileProcessingPipeline.Request(
            finalizedSession: finalizedSession,
            sourceDatabase: sourceDatabase,
            taskRoot: taskRoot,
            priorMap: priorMap,
            storeID: storeID,
            floorID: floorID,
            trackingSessionID: trackingSessionID,
            appGitSHA: appGitSHA,
            appVersion: appVersion,
            deviceModel: deviceModel,
            osVersion: osVersion,
            nativeCoreSHA256: nativeCoreSHA256,
            policySHA: policySHA)

        let operation = BlockOperation { [weak self] in
            self?.executeProcessing(request: request)
        }
        processingOperation = operation
        workQueue.addOperation(operation)
    }

    private func executeProcessing(request: MobileProcessingPipeline.Request) {
        do {
            let outcome = try MobileProcessingPipeline.run(
                request: request,
                progress: { [weak self] fraction, message in
                    guard let self = self else { return }
                    self.contextLock.lock()
                    self.context.progress = fraction
                    self.context.checkpoint = message
                    self.contextLock.unlock()
                    self.persistContext()
                    self.transitionToPipelineFraction(fraction)
                    self.notifyProgress(fraction, message)
                },
                isCancelled: { [weak self] in
                    self?.processingOperation?.isCancelled ?? false
                })
            self.contextLock.lock()
            self.context.resultID = outcome.resultEntry.resultID
            self.context.progress = 1.0
            self.context.checkpoint = "completed"
            self.contextLock.unlock()
            self.persistContext()
            self.transition(to: .completed)
            self.notifyProcessing(.success(outcome.resultEntry))
        } catch {
            if (error as? MobileOnlyWorkflowError) == .cancelled {
                self.transition(to: .cancelled)
            } else if let workflowError = error as? MobileOnlyWorkflowError {
                if case .rescanSessionRequired = workflowError {
                    self.markRescanRequired(with: workflowError)
                } else {
                    self.fail(with: workflowError)
                }
                self.notifyProcessing(.failure(workflowError))
            } else {
                let wrapped = MobileOnlyWorkflowError.processingFailed(error.localizedDescription)
                self.fail(with: wrapped)
                self.notifyProcessing(.failure(wrapped))
            }
        }
        self.processingOperation = nil
        self.coordinatorLock.lock(); self.processingBusy = false; self.coordinatorLock.unlock()
    }

    /// Maps the pipeline progress fraction onto the legal processing
    /// sub-states so observers see the true stage.
    private func transitionToPipelineFraction(_ fraction: Double) {
        let target: MobileOnlyWorkflowState
        switch fraction {
        case ..<0.20: target = .snapshotting
        case ..<0.45: target = .fastProcessing
        case ..<0.55: target = .buildingTrajectory
        case ..<0.70: target = .resolvingTags
        default: target = .exporting
        }
        // The pipeline reports monotonically; only move forward.
        stateLock.lock()
        let current = state
        stateLock.unlock()
        if current == .snapshotting || (current.isProcessingStage && target.isProcessingStage) {
            if current != target {
                transition(to: target)
            }
        }
    }

    func cancelProcessing() {
        processingOperation?.cancel()
    }

    // MARK: - State machine (§5.4)

    private func transition(to newState: MobileOnlyWorkflowState) -> Bool {
        stateLock.lock()
        let current = state
        guard current.allowsTransition(to: newState) else {
            stateLock.unlock()
            let error = MobileOnlyWorkflowError.illegalTransition(
                "\(current.rawValue) -> \(newState.rawValue)")
            lastError = error
            contextLock.lock()
            context.errorCode = error.code
            contextLock.unlock()
            persistContext()
            return false
        }
        state = newState
        stateLock.unlock()
        if newState != .failed && newState != .rescanRequired {
            contextLock.lock()
            context.errorCode = ""
            contextLock.unlock()
        }
        persistContext()
        notifyState(newState)
        return true
    }

    private func fail(with error: MobileOnlyWorkflowError) {
        lastError = error
        contextLock.lock()
        context.errorCode = error.code
        contextLock.unlock()
        transition(to: .failed)
    }

    private func markRescanRequired(with error: MobileOnlyWorkflowError) {
        lastError = error
        contextLock.lock()
        context.errorCode = error.code
        context.checkpoint = "RESCAN_SESSION"
        contextLock.unlock()
        transition(to: .rescanRequired)
    }

    // MARK: - Persistence (§5.2)

    private func persistContext() {
        stateLock.lock()
        let currentState = state
        stateLock.unlock()
        contextLock.lock()
        context.state = currentState
        context.appGitSHA = appGitSHA
        context.policySHA = policySHA
        context.updatedAt = Date().timeIntervalSince1970
        let payload: [String: Any] = [
            "format": "MarketScannerWorkflowState",
            "version": 2,
            "state": currentState.rawValue,
            "task_id": context.taskID,
            "staged_source": context.stagedSource,
            "original_filename": context.originalFilename,
            "coordinate_contract": context.contractRaw,
            "store_id": context.storeID,
            "map_id": context.mapID,
            "map_sha": context.mapSHA,
            "session_id": context.sessionID,
            "segment_directory": context.segmentDirectory,
            "source_database": context.sourceDatabase,
            "result_id": context.resultID,
            "progress": context.progress,
            "checkpoint": context.checkpoint,
            "error_code": context.errorCode,
            "app_git_sha": context.appGitSHA,
            "policy_sha": context.policySHA,
            "updated_at": context.updatedAt,
        ]
        contextLock.unlock()
        guard let data = try? CanonicalJSONEncoder.encode(payload) else { return }
        do {
            let directory = stateFileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            try data.write(to: stateFileURL, options: [.atomic])
        } catch {
            // Non-fatal: in-memory state still drives the UI.
        }
    }

    /// Loads `workflow_state.json`, verifies every durable reference and
    /// exposes a resumable `interrupted` state only when the referenced
    /// files/registrations still exist (§5.2).
    private func loadAndVerifyPersistedContext() {
        guard let data = try? Data(contentsOf: stateFileURL),
              let object = try? StrictJSONDocumentParser.object(
                  from: data,
                  limits: StrictJSONDocumentLimits(maximumBytes: data.count + 1)) as? [String: Any],
              let raw = object["state"] as? String,
              let persistedState = MobileOnlyWorkflowState(rawValue: raw)
        else {
            state = .idle
            return
        }
        context.taskID = object["task_id"] as? String ?? ""
        context.stagedSource = object["staged_source"] as? String ?? ""
        context.originalFilename = object["original_filename"] as? String ?? ""
        context.contractRaw = object["coordinate_contract"] as? String ?? ""
        context.storeID = object["store_id"] as? String ?? ""
        context.mapID = object["map_id"] as? String ?? ""
        context.mapSHA = object["map_sha"] as? String ?? ""
        context.sessionID = object["session_id"] as? String ?? ""
        context.segmentDirectory = object["segment_directory"] as? String ?? ""
        context.sourceDatabase = object["source_database"] as? String ?? ""
        context.resultID = object["result_id"] as? String ?? ""
        context.progress = object["progress"] as? Double ?? 0
        context.checkpoint = object["checkpoint"] as? String ?? ""
        context.errorCode = object["error_code"] as? String ?? ""

        guard persistedState.isResumable else {
            // RESCAN_SESSION is a product terminal outcome, not a stale
            // failure. Keep it visible across relaunch until the operator
            // deliberately starts another workflow.
            state = persistedState == .rescanRequired
                ? .rescanRequired
                : (persistedState == .interrupted ? .interrupted : .idle)
            return
        }

        // Verify the durable references of the interrupted run.
        var valid = true
        var reason = ""
        let fileManager = FileManager.default
        switch persistedState {
        case .stagingMapSource, .importingMap, .compilingMap:
            if context.stagedSource.isEmpty
                || !fileManager.fileExists(atPath: context.stagedSource) {
                valid = false
                reason = "staged source missing"
            }
        case .configuringScan, .scanning, .finalizingScan:
            if !isRegisteredMap(context.mapID, sha: context.mapSHA) {
                valid = false
                reason = "map registration missing"
            }
        case .snapshotting, .fastProcessing, .deepProcessing,
             .buildingTrajectory, .resolvingTags, .exporting:
            if context.segmentDirectory.isEmpty
                || !fileManager.fileExists(atPath: context.segmentDirectory) {
                valid = false
                reason = "session segment missing"
            } else if context.sourceDatabase.isEmpty
                || !fileManager.fileExists(atPath: context.sourceDatabase) {
                valid = false
                reason = "source database missing"
            } else if !isRegisteredMap(context.mapID, sha: context.mapSHA) {
                valid = false
                reason = "map registration missing"
            }
        default:
            break
        }

        if valid {
            state = .interrupted
        } else {
            // An interrupted run whose references disappeared cannot
            // resume; record why and return to idle (fail closed).
            state = .idle
            context.errorCode = MobileOnlyWorkflowError.referenceMissing(reason).code
        }
        context.state = state
        persistContext()
    }

    private func isRegisteredMap(_ priorMapID: String, sha: String) -> Bool {
        guard !priorMapID.isEmpty, !sha.isEmpty else { return false }
        guard let entry = try? MobileMapLibrary.map(priorMapID: priorMapID, packageSHA256: sha)
        else { return false }
        if activeMap == nil {
            activeMap = entry
        }
        return true
    }

    /// Attempts to resume the interrupted run (called by the home screen
    /// after the user acknowledges the banner). Processing runs are
    /// re-enqueued with the verified references; import runs fall back
    /// to idle because the picker interaction cannot be replayed.
    func attemptResume() -> Bool {
        guard state == .interrupted else { return false }
        contextLock.lock()
        let checkpoint = context.checkpoint
        let segmentDirectory = context.segmentDirectory
        let sourceDatabase = context.sourceDatabase
        let mapID = context.mapID
        let mapSHA = context.mapSHA
        let storeID = context.storeID
        let sessionID = context.sessionID
        let taskID = context.taskID
        contextLock.unlock()
        // B-08: the resumed run re-derives the floor identity from the
        // session metadata. An unreadable/missing floor flows as empty
        // and fails the snapshot eligibility check fail-closed instead
        // of silently defaulting.
        let floorID = Self.floorIDFromMetadata(segmentDirectory: segmentDirectory)
        switch checkpoint {
        case _ where !segmentDirectory.isEmpty && !sourceDatabase.isEmpty:
            guard let map = activeMap ?? (try? MobileMapLibrary.map(
                priorMapID: mapID, packageSHA256: mapSHA)) else {
                transition(to: .idle)
                return false
            }
            transition(to: .idle)
            beginProcessing(
                finalizedSession: URL(fileURLWithPath: segmentDirectory),
                sourceDatabase: URL(fileURLWithPath: sourceDatabase),
                priorMap: map,
                storeID: storeID,
                floorID: floorID,
                trackingSessionID: sessionID,
                taskID: taskID.isEmpty ? nil : taskID)
            return true
        default:
            transition(to: .idle)
            return false
        }
    }

    /// B-08: reads the floor identity recorded in the session metadata
    /// (resume path). Returns "" when unreadable so the snapshot
    /// eligibility chain fails closed.
    private static func floorIDFromMetadata(segmentDirectory: String) -> String {
        let url = URL(fileURLWithPath: segmentDirectory)
            .appendingPathComponent("metadata.json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(
                  with: data, options: []) as? [String: Any],
              let floorID = object["floorId"] as? String else {
            return ""
        }
        return floorID
    }
}

extension MobileOnlyWorkflowState {
    /// Sub-states of the processing run (snapshotting → exporting).
    var isProcessingStage: Bool {
        switch self {
        case .fastProcessing, .deepProcessing, .buildingTrajectory,
             .resolvingTags, .exporting:
            return true
        default:
            return false
        }
    }
}

/// Configuration committed by the scan-setup screen. The scanner reads
/// only phone-compiled maps from the on-device library (V1R1 §8.1).
struct MobileScanConfiguration {
    var priorMap: MobileMapLibrary.MapEntry
    var floorID: String
    var startXM: Double
    var startYM: Double
    var startYawRad: Double
    var storeID: String
}

/// Receipt proving the real scan actually started (V1R3 §4.1). Produced
/// by the host; validated and durably persisted by the coordinator
/// BEFORE the workflow may enter `.scanning`.
struct MobileScanStartReceipt: Codable, Equatable {
    let trackingSessionID: String
    let segmentDirectory: URL
    let databaseURL: URL
    let priorMapID: String
    let priorMapSHA256: String
    let floorID: String
    let storeID: String
    let arSessionStarted: Bool
    let rtabMapRecordingStarted: Bool
    let requiredSidecarWritersReady: Bool
    let startedAtMonotonic: Double
    let startedAtUTC: Double
    let appGitSHA: String

    /// Every subsystem must actually be up; a partial start is a failure.
    var isComplete: Bool {
        return !trackingSessionID.isEmpty
            && !segmentDirectory.path.isEmpty
            && !databaseURL.path.isEmpty
            && !priorMapID.isEmpty
            && !priorMapSHA256.isEmpty
            && !floorID.isEmpty
            && !storeID.isEmpty
            && arSessionStarted
            && rtabMapRecordingStarted
            && requiredSidecarWritersReady
            && !appGitSHA.isEmpty
            && appGitSHA != "unknown"
    }
}

/// Host scan-starting service (V1R3 §4). The scanner host
/// (`ViewController`) implements this and performs the REAL production
/// steps: load the compiled package, verify its SHA, build the PriorMap
/// scan configuration with the committed initial map pose, then start
/// the ARSession + RTAB-Map recording + session metadata, returning a
/// receipt. Any failed substep must throw; persisting the configuration
/// alone is not a valid implementation.
protocol MobileOnlyScanStarting: AnyObject {
    func startMobileOnlyScan(
        _ configuration: MobileScanConfiguration
    ) throws -> MobileScanStartReceipt
}
