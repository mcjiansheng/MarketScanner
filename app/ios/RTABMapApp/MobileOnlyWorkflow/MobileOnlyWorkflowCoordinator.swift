import UIKit

/// The single entry point of the Mobile-Only product flow (V1R1 Gate A).
///
/// Ownership contract:
/// - `documentPicker` is held strongly until its callback fires, so the
///   picker can never be deallocated mid-flow (V1R1 §5.1 / §18).
/// - `importTask` / `processingTask` are held strongly for the whole
///   import / processing run and released on completion.
///
/// Every state transition is written to `workflow_state.json` so an app
/// relaunch can resume the flow from `interrupted`.
final class MobileOnlyWorkflowCoordinator {

    static let shared = MobileOnlyWorkflowCoordinator()

    // MARK: - Strong ownership (must never be released early)

    private var documentPicker: MapSourceDocumentPicker?
    private var importTask: Task<Void, Never>?
    private var processingTask: Task<Void, Never>?

    // MARK: - State

    private(set) var state: MobileOnlyWorkflowState = .idle
    private(set) var lastError: MobileOnlyWorkflowError?

    /// Latest import report; kept until the map is compiled/registered.
    private(set) var lastImportReport: MapSourceImportReport?
    private var stagedImport: (url: URL, filename: String)?
    /// Latest compiled map entry; kept until a scan starts.
    private(set) var activeMap: MobileMapLibrary.MapEntry?

    // MARK: - Callbacks (UI wiring)

    var onStateChange: ((MobileOnlyWorkflowState) -> Void)?
    var onImportFinished: ((Result<MapSourceImportReport, Error>) -> Void)?
    var onCompileFinished: ((Result<MobileMapLibrary.MapEntry, Error>) -> Void)?
    var onProcessingProgress: ((Double, String) -> Void)?
    var onProcessingFinished: ((Result<MobileResultLibrary.ResultEntry, Error>) -> Void)?
    /// Fired when the scan-setup screen commits a configuration; the
    /// scanner (ViewController) registers this to start a real scan.
    var onStartScan: ((MobileScanConfiguration) -> Void)?

    // MARK: - App identity (populated by the host app)

    var appGitSHA: String = "unknown"
    var appVersion: String = "1.0"
    var deviceModel: String = "iPhone"
    var osVersion: String = "unknown"

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
        state = Self.loadPersistedState(url: stateFileURL) ?? .idle
        if state.isResumable {
            state = .interrupted
        }
    }

    // MARK: - Import flow (Gate A / Gate B)

    /// Presents the Files picker and stages a security-scoped copy.
    /// The provider URL is never read after the copy (V1R1 §6.1).
    func beginMapImport(from presenter: UIViewController) {
        transition(to: .pickingMap)
        let picker = MapSourceDocumentPicker { [weak self] outcome in
            guard let self = self else { return }
            switch outcome {
            case .staged(let url, let originalFilename):
                self.stagedImport = (url, originalFilename)
                self.transition(to: .stagingMapSource)
            case .failed(let reason):
                self.lastError = .pickerCopyFailed(reason.message)
                self.transition(to: .failed)
                self.onImportFinished?(.failure(self.lastError!))
            case .cancelled:
                self.transition(to: .idle)
            }
        }
        self.documentPicker = picker // strong reference until callback
        picker.present(from: presenter)
    }

    func cancelImport() {
        importTask?.cancel()
        importTask = nil
        documentPicker = nil
        stagedImport = nil
        transition(to: .idle)
    }

    /// Runs the strict import (XLSX/CSV/JSON -> canonical source v2) and
    /// then compiles the prior map into the on-device library.
    func importAndCompile(
        contract: CoordinateContract,
        storeID: String? = nil,
        mapName: String? = nil
    ) {
        guard let staged = stagedImport else {
            lastError = .invalidState("no staged map source")
            transition(to: .failed)
            return
        }
        transition(to: .importingMap)
        importTask = Task { @MainActor [weak self] in
            guard let self = self else { return }
            do {
                let report = try MapSourceImportCoordinator.importMap(
                    stagedURL: staged.url,
                    originalFilename: staged.filename,
                    contract: contract,
                    storeId: storeID,
                    mapName: mapName,
                    strict: true)
                self.lastImportReport = report
                self.onImportFinished?(.success(report))
                try self.compileMap(report: report)
            } catch {
                self.lastError = .importFailed(error.localizedDescription)
                self.transition(to: .failed)
                self.onImportFinished?(.failure(error))
            }
        }
    }

    private func compileMap(report: MapSourceImportReport) throws {
        transition(to: .compilingMap)
        let taskID = "compile-\(UUID().uuidString)"
        let staging = try MobileMapLibrary.stagingDirectory(for: taskID)
        let compileResult = try MobilePriorMapCompiler.compile(
            canonicalSource: report.canonicalSource,
            outputDirectory: staging)
        // Move the verified package into its immutable home, then register.
        let target = try MobileMapLibrary.packageDirectory(
            priorMapID: compileResult.priorMapID,
            packageSHA: compileResult.packageSHA256)
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: target.path) {
            try fileManager.removeItem(at: target)
        }
        try fileManager.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.moveItem(at: staging, to: target)
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
        self.stagedImport = nil
        self.lastImportReport = nil
        transition(to: .mapReady)
        onCompileFinished?(.success(entry))
    }

    // MARK: - Scan flow

    func beginScanSetup(map: MobileMapLibrary.MapEntry) {
        activeMap = map
        transition(to: .configuringScan)
    }

    func commitScanConfiguration(_ configuration: MobileScanConfiguration) {
        guard configuration.priorMap.packageSHA256 == activeMap?.packageSHA256 else {
            lastError = .invalidState("map identity mismatch")
            transition(to: .failed)
            return
        }
        transition(to: .scanning)
        onStartScan?(configuration)
    }

    func scanFinalized() {
        transition(to: .finalizingScan)
    }

    // MARK: - Processing flow (Gate A / Fast+Deep / results)

    /// Processes a finalized session end-to-end: snapshot -> graph ->
    /// fast optimization -> trajectory -> tags -> result package ->
    /// streaming XLSX (V1R1 §14).
    func beginProcessing(
        finalizedSession: URL,
        sourceDatabase: URL,
        priorMap: MobileMapLibrary.MapEntry,
        storeID: String,
        trackingSessionID: String
    ) {
        transition(to: .snapshotting)
        let taskID = "task-\(UUID().uuidString)"
        guard let taskRoot = try? MobileProcessingTaskStore.createTask(taskID: taskID) else {
            lastError = .snapshotFailed("cannot create task directory")
            transition(to: .failed)
            return
        }
        let request = MobileProcessingPipeline.Request(
            finalizedSession: finalizedSession,
            sourceDatabase: sourceDatabase,
            taskRoot: taskRoot,
            priorMap: priorMap,
            storeID: storeID,
            trackingSessionID: trackingSessionID,
            appGitSHA: appGitSHA,
            appVersion: appVersion,
            deviceModel: deviceModel,
            osVersion: osVersion)
        processingTask = Task { @MainActor [weak self] in
            guard let self = self else { return }
            do {
                let outcome = try MobileProcessingPipeline.run(
                    request: request,
                    progress: { fraction, message in
                        self.onProcessingProgress?(fraction, message)
                    },
                    isCancelled: { [weak self] in
                        self?.processingTask?.isCancelled ?? false
                    })
                self.transition(to: .completed)
                self.onProcessingFinished?(.success(outcome.resultEntry))
            } catch {
                if (error as? MobileOnlyWorkflowError) == .cancelled {
                    self.transition(to: .cancelled)
                    return
                }
                self.lastError = .processingFailed(error.localizedDescription)
                self.transition(to: .failed)
                self.onProcessingFinished?(.failure(error))
            }
        }
    }

    func cancelProcessing() {
        processingTask?.cancel()
    }

    // MARK: - State machine

    private func transition(to newState: MobileOnlyWorkflowState) {
        state = newState
        persistState()
        onStateChange?(newState)
    }

    private func persistState() {
        let payload: [String: Any] = [
            "format": "MarketScannerWorkflowState",
            "version": 1,
            "state": state.rawValue,
        ]
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

    private static func loadPersistedState(url: URL) -> MobileOnlyWorkflowState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let object = try? StrictJSONDocumentParser.object(
            from: data,
            limits: StrictJSONDocumentLimits(maximumBytes: data.count + 1)) as? [String: Any],
            let raw = object["state"] as? String
        else { return nil }
        return MobileOnlyWorkflowState(rawValue: raw)
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
