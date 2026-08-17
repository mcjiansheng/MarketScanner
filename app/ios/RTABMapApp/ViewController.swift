//
//  ViewController.swift
//  GLKittutorial
//
//  Created by Mathieu Labbe on 2020-12-28.
//

import GLKit
import ARKit
import Zip
import StoreKit
import UniformTypeIdentifiers
import simd
import Darwin

extension Array {
    func size() -> Int {
        return MemoryLayout<Element>.stride * self.count
    }
}

// P7R6: the scan session is the durable writer consumed by
// RecoveryLifecyclePersistenceCoordinator.
extension SupermarketScanSession: RecoveryLifecycleWriting {
}

private struct PriceTagCaptureNodeBinding {
    let nodeID: Int64
    let nodeStamp: TimeInterval
    let nodeMapID: Int32
    let nodeTimebaseOffsetSeconds: TimeInterval
    let openGLWorldFromNode: simd_float4x4
}

private struct PendingManualPriorMapPoseRequest {
    let id: UUID
    let mapPose: PriorMapPose2D
    let reason: String
    let requestedAtWallClock: Date
    let requestedAtFrameTimestamp: TimeInterval?
    let baselineNodeID: Int?
    let baselineNodeStamp: TimeInterval?
    let priorMapGeneration: UUID
    let trackingSessionID: String
    let completion: (PriorMapManualPoseSubmissionOutcome) -> Void
}

private struct PendingPoseEpochTransition {
    let fromEpoch: Int
    let toEpoch: Int
    let beforeFrameTimestamp: TimeInterval
    let afterFrameTimestamp: TimeInterval
    let beforeNodeID: Int64
    let transform: ShelfEvidenceTransform
    let reason: String
}

private struct PendingShelfObservationWindow {
    let shelfSegmentID: String
    let side: String
    let faceNormal: ShelfFaceNormal
    let epoch: Int
    let component: Int64
    let startNodeID: Int64
    let startTimestamp: TimeInterval
    var endNodeID: Int64
    var endTimestamp: TimeInterval
    var sampleCount: Int
    var maximumCoverageAngleRad: Double
    var dynamicRejectionCount: Int
    var geometryResidualsM: [Double]
    var geometryInlierCount: Int
    var phonePoseXSum: Double
    var phonePoseYSum: Double
    var phonePoseSinYawSum: Double
    var phonePoseCosYawSum: Double
    var phonePoseSampleCount: Int
}

class ViewController: GLKViewController, ARSessionDelegate, RTABMapObserver, UIPickerViewDataSource, UIPickerViewDelegate, CLLocationManagerDelegate, UIDocumentPickerDelegate {
    
    private let session = ARSession()
    private var locationManager: CLLocationManager?
    private var mLastKnownLocation: CLLocation?
    private var mLastLightEstimate: CGFloat?
    
    private var context: EAGLContext?
    private var rtabmap: RTABMap?
    private var supermarketSession: SupermarketScanSession?
    // V1R3 §7.1: clock correlation evidence recorded during the scan and
    // flushed to clock_correlations.jsonl on finalization.
    private var clockRecorder: ClockCorrelationRecorder?
    private var clockTimer: Timer?
    // V1R4 §7.2/§7.4: system clock / timezone change observers; the
    // recorder appends an explicit segment-start correlation on each.
    private var clockChangeObservers: [NSObjectProtocol] = []
    // V1R4 §7.2: a failed durable sidecar write blocks processing
    // eligibility (fail closed; the write is never `try?`-swallowed).
    private var clockSidecarWriteFailure: String?
    private var clockSidecarWriteResult: ClockSidecarWriteResult?
    // V1R4 §7.1: last node id bound into the clock sidecar, so a new
    // binding is recorded only when RTAB-Map creates a new node.
    private var lastClockBoundNodeID = 0
    private var activeScanConfiguration = PriorMapScanConfiguration.freeMapping
    private var priorMapLocalizer: PriorMapStageOneLocalizer?
    private var activePriorMapPackage: PriorMapPackage?
    private var priorMapOverlay: PriorMapLiveMapView?
    private var priorMapLatestUpdate: PriorMapLocalizationUpdate?
    private var priorMapEvidenceWriteWarningShown = false
    private var priorMapNodeTimebaseUnavailableNoticeAt: TimeInterval?
    private var priorMapLastNodeBinding: (
        nodeId: Int,
        nodeStamp: TimeInterval,
        nodeMapId: Int32,
        nodeTimebaseOffsetSeconds: TimeInterval,
        generation: UInt64,
        openGLWorldFromNode: simd_float4x4,
        sampledFrameTimestamp: TimeInterval
    )?
    private var finalizedCleanupPromptShown = false
    private let priorMapUpdateGate = PriorMapUpdateGate(minimumInterval: 0.5)
    private var priorMapGeneration = UUID()
    private let priorMapQueue = DispatchQueue(
        label: "com.introlab.rtabmap.prior-map-localization",
        qos: .userInitiated)
    private let priceTagVisionScanner = PriceTagVisionScanner()
    private let priceTagCaptureCoordinator = PriceTagCaptureCoordinator()
    private let priceTagCaptureResultsLock = NSLock()
    private let priceTagCaptureAuditLock = NSLock()
    private var priceTagCaptureLastAuditAt: [String: TimeInterval] = [:]
    private var priceTagCaptureAuditTrackingSessionIDs: [UUID: String] = [:]
    private var priceTagCaptureAuditGenerationOrder: [UUID] = []
    private var priceTagCaptureFrameResults:
        [UUID: [PriceTagShelfAssociationResult]] = [:]
    private var priceTagCaptureOverlay: PriceTagCaptureOverlayView?
    private weak var priceTagCaptureStartFailureAlert: UIAlertController?
    private weak var priceTagShelfConfirmationController:
        PriceTagShelfConfirmationViewController?
    private var priceTagCapturePresentationGeneration: UUID?
    private var priceTagCapturePriorMapOverlayWasHidden: Bool?
    private var priceTagCaptureContinuityStart:
        PriceTagCaptureContinuitySample?
    private var priceTagCapturePausedReason: String?
    private let priorMapAlignmentSnapshots = PriorMapAlignmentSnapshotStore()
    private var priceTagNFCReader: PriceTagNFCReader?
    // NFC is intentionally paused. Presenting Core NFC interrupts the active
    // camera capture on iOS, and the entitlement cannot be debugged with an
    // unprovisioned Apple developer account. Keep the implementation for a
    // future certified workflow, but expose no production/debug entry point.
    private let supermarketNFCEnabled = false
    private var startupCompleted = false
    
    private var databases = [URL]()
    private var currentDatabaseIndex: Int = 0
    private var openedDatabasePath: URL?
    
    private var progressDialog: UIAlertController?
    var progressView : UIProgressView?
    
    var maxPolygonsPickerView: UIPickerView!
    var maxPolygonsPickerData: [Int]!
    
    private var mTotalLoopClosures: Int = 0
    private var mMapNodes: Int = 0
    private var mOdometrySubmissionCount: UInt64 = 0
    private var mTimeThr: Int = 0
    private var mMaxFeatures: Int = 0
    private var mLoopThr = 0.11
    private var mDataRecording = false
    
    private var mReviewRequested = false
    
    private var mMaximumMemory: Int = 0
    private var mLatestDatabaseMemoryMB: Int = 0
    private var mLatestScanStorageBytes: UInt64 = 0
    private var mLatestPerformanceUpdateTimeMS: Double?
    private var mLatestPerformanceFPS: Double?
    private var mLatestPerformanceWordCount: Int?
    private var mLatestPerformanceFeatureCount: Int?
    private var mLatestPerformancePointCount: Int?
    private var mLatestPerformancePolygonCount: Int?
    private var mLastPerformanceSampleUptime: TimeInterval = 0
    private var mLastPerformanceCPUTimeSeconds: Double?
    private var mPerformanceWriteFailureReported = false
    private var mLatestPose = (x: Float(0), y: Float(0), z: Float(0), roll: Float(0), pitch: Float(0), yaw: Float(0))
    private let supermarketStreamingMemoryNodesKey = "SupermarketStreamingMemoryNodes"
    private let supermarketSaveLocationBookmarkKey = "SupermarketSaveLocationBookmark"
    private let supermarketSaveLocationNameKey = "SupermarketSaveLocationName"
    private let supermarketDefaultsVersionKey = "SupermarketDefaultsVersion"
    private let supermarketDefaultStreamingMemoryNodes = 300
    private let supermarketDefaultsVersion = 4
    
    // UI states
    private enum State {
        case STATE_WELCOME,    // Camera/Motion off - showing only buttons open and start new scan
        STATE_CAMERA,          // Camera/Motion on - not mapping
        STATE_MAPPING,         // Camera/Motion on - mapping
        STATE_IDLE,            // Camera/Motion off
        STATE_PROCESSING,      // Camera/Motion off - post processing
        STATE_VISUALIZING,     // Camera/Motion off - Showing optimized mesh
        STATE_VISUALIZING_CAMERA,     // Camera/Motion on  - Showing optimized mesh and localizing
        STATE_VISUALIZING_WHILE_LOADING, // Camera/Motion off - Loading data while showing optimized mesh
        STATE_VISUALIZING_AND_MEASURING    // Camera/Motion on  - Showing optimized mesh without localizing and measuring tools enabled
    }
    private var mState: State = State.STATE_WELCOME;
    private var mCaptureStateBeforeSystemInterruption: State?
    private var mSystemInterruptionInProgress = false
    private var mSystemInterruptionRequiresTrackingReset = false
    private var mSystemInterruptionBeganAt: Date?
    private var mSystemInterruptionReason = ""
    private func localized(_ key: String) -> String {
        return NSLocalizedString(key, comment: "")
    }
    private func getStateString(state: State) -> String {
        switch state {
        case .STATE_WELCOME:
            return localized("Welcome")
        case .STATE_CAMERA:
            return localized("Camera Preview")
        case .STATE_MAPPING:
            return mDataRecording ? localized("Data Recording") : localized("Mapping")
        case .STATE_PROCESSING:
            return localized("Processing")
        case .STATE_VISUALIZING:
            return localized("Visualizing")
        case .STATE_VISUALIZING_CAMERA:
            return localized("Visualizing with Camera")
        case .STATE_VISUALIZING_WHILE_LOADING:
            return localized("Visualizing while Loading")
        case .STATE_VISUALIZING_AND_MEASURING:
            return localized("Measuring")
        default: // IDLE
            return localized("Idle")
        }
    }
    
    private var depthSupported: Bool = false
    
    private var viewMode: Int = 2 // 0=Cloud, 1=Mesh, 2=Textured Mesh
    private var cameraMode: Int = 1
    
    private var statusShown: Bool = true
    private var debugShown: Bool = false
    private var mapShown: Bool = true
    private var odomShown: Bool = true
    private var graphShown: Bool = true
    private var gridShown: Bool = true
    private var optimizedGraphShown: Bool = true
    private var wireframeShown: Bool = false
    private var backfaceShown: Bool = false
    private var lightingShown: Bool = false
    private var textureColorSeamsShown: Bool = false
    private var mHudVisible: Bool = true
    private var mLastTimeHudShown: DispatchTime = .now()
    private var mMenuOpened: Bool = false
    private var mLastStreamingCheckpointAt: TimeInterval = 0
    private var mStreamingCheckpointInFlight = false
    private var mStreamingDiskWarningShown = false
    private var mStreamingCriticalStopRequested = false
    private var mStreamingThermalWarningShown = false
    private var mStreamingThermalPolicyLevel = 0
    private var mStreamingMemoryPressureLevel = 0
    private var mLastLoggedTrackingState = ""
    private var mARPoseCorrection = matrix_identity_float4x4
    /// Monotonic software-pose authority epoch. It advances whenever a raw
    /// ARKit coordinate discontinuity is rebased so audit logs can distinguish
    /// a continuous accepted trajectory from a new raw sensor coordinate era.
    private var mCapturePoseEpoch: UInt64 = 1
    private var pendingPoseEpochTransition: PendingPoseEpochTransition?
    private var poseEpochTransitionSequence = 0
    private var shelfTrackingStateMachine = ShelfTrackingStateMachine()
    private var corridorHypothesisSequence = 0
    private var lastCorridorHypothesisNodeID: Int64?
    private var recentShelfTrackingDegradationCount = 0
    private var selectedShelfSegmentID = ""
    private var selectedShelfSide = "unknown"
    private var pendingShelfObservationWindow: PendingShelfObservationWindow?
    private var shelfObservationWindowSequence = 0
    private var recentShelfObservationWindows:
        [String: [ShelfObservationWindowRecord]] = [:]
    private var recentShelfWindowRelativePoses:
        [String: ShelfPhoneRelativePose] = [:]
    private var shelfLoopEventSequence = 0
    private var lastShelfEvidenceResourcePolicyLevel = -1
    private let mMapCorrectionLock = NSLock()
    private var mMapToOdomCorrection = matrix_identity_float4x4
    private var mLastAcceptedARPose: simd_float4x4?
    private var mLastAcceptedARTimestamp: TimeInterval?
    private var mTrackingWasDegraded = true
    private var mConsecutiveNormalTrackingFrames = 0
    private var mLastTrackingGuidanceAt: TimeInterval = 0
    private let mRequiredNormalFramesAfterTrackingRecovery = 6
    private let mManualPriorMapPoseRequestLock = NSLock()
    private var mPendingManualPriorMapPoseRequest:
        PendingManualPriorMapPoseRequest?
    private let mManualPriorMapPoseTimeoutSeconds: TimeInterval = 6.0
    private let mStreamingOptimizeMaxError = 2.0
    private let mStreamingMinimumVisualInliers = 40
    private var mLastStreamingSettingsAuditTrackingSessionID: String?
    private let mStructureCoverageAdvisor = SupermarketStructureCoverageAdvisor()
    private var mLastStructureCoverageGuidanceAt: TimeInterval = 0
    private var mLastStructureCoverageSummaryAt: TimeInterval = 0
    private var mLastAdaptiveDetectionRateUpdateAt: TimeInterval = 0
    private var mAdaptiveDetectionRateHz = 1.0
    private var mPendingAdaptiveDetectionRateHz: Double?
    private var mPendingAdaptiveDetectionRateSince: TimeInterval = 0
    private var mConsecutiveRejectedLoopClosures = 0
    private let mReliableLoopMinimumNodeSpan = 50
    private var mReliableLoopClosures = 0
    private var mLastReliableLoopClosureDistance: Float = 0
    private var mCurrentDistanceTravelled: Float = 0
    private var mLastLoopHealthGuidanceAt: TimeInterval = 0
    private var mLastNotifiedLoopClosureSignature = ""
    private var mLastMapCorrectionTranslationM = 0.0
    private var mLastMapCorrectionRotationDeg = 0.0
    private var mLastMapCorrectionDeltaTranslationM = 0.0
    private var mLastMapCorrectionDeltaRotationDeg = 0.0
    private var mToastDismissWorkItem: DispatchWorkItem?
    static var previewImages: [String: UIImage] = [:]
    private var measuringMode: Int = 0
    private var visualizationType: Int = 0 // 0=Cloud, 1=Mesh, 2=Texture Mesh
    
    @IBOutlet weak var stopButton: UIButton!
    @IBOutlet weak var recordButton: UIButton!
    @IBOutlet weak var menuButton: UIButton!
    @IBOutlet weak var viewButton: UIButton!
    @IBOutlet weak var newScanButtonLarge: UIButton!
    @IBOutlet weak var libraryButton: UIButton!
    @IBOutlet weak var statusLabel: UILabel!
    @IBOutlet weak var closeVisualizationButton: UIButton!
    @IBOutlet weak var stopCameraButton: UIButton!
    @IBOutlet weak var stopMeasuringButton: UIButton!
    @IBOutlet weak var teleportButton: UIButton!
    @IBOutlet weak var addMeasureButton: UIButton!
    @IBOutlet weak var removeMeasureButton: UIButton!
    @IBOutlet weak var measuringModeButton: UIButton!
    @IBOutlet weak var exportOBJPLYButton: UIButton!
    @IBOutlet weak var orthoDistanceSlider: UISlider!{
        didSet{
            orthoDistanceSlider.transform = CGAffineTransform(rotationAngle: CGFloat(-Double.pi/2))
        }
    }
    @IBOutlet weak var orthoGridSlider: UISlider!
    @IBOutlet weak var toastLabel: UILabel!
    
    let RTABMAP_TMP_DB = "rtabmap.tmp.db"
    let RTABMAP_RECOVERY_DB = "rtabmap.tmp.recovery.db"
    let RTABMAP_EXPORT_DIR = "Export"

    func getDocumentDirectory() -> URL {
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    
    func getTmpDirectory() -> URL {
       return URL(fileURLWithPath: NSTemporaryDirectory())
    }
    
    @objc func defaultsChanged(){
        print("defaultsChanged()")
        if rtabmap != nil {
            updateDisplayFromDefaults()
        }
    }
    
    func showToast(message: String, seconds: Double, replacingCurrent: Bool = false) {
        if !self.toastLabel.isHidden && !replacingCurrent
        {
            return
        }

        mToastDismissWorkItem?.cancel()
        self.toastLabel.text = message
        self.toastLabel.isHidden = false

        let dismissWorkItem = DispatchWorkItem { [weak self] in
            self?.toastLabel.isHidden = true
        }
        mToastDismissWorkItem = dismissWorkItem
        DispatchQueue.main.asyncAfter(
            deadline: DispatchTime.now() + seconds,
            execute: dismissWorkItem)
    }

    /// Explicit overload for callers that do not need a custom duration
    /// (V1R2 Gate 0 §4.3). The default 2 s matches the feedback toasts.
    func showToast(_ message: String, seconds: Double = 2.0) {
        showToast(message: message, seconds: seconds)
    }

    private func showLoopClosureFeedback(
        reliable: Bool,
        loopClosureType: Int,
        currentNodeId: Int,
        targetNodeId: Int
    ) {
        let signature = "\(loopClosureType):\(currentNodeId):\(targetNodeId)"
        guard signature != mLastNotifiedLoopClosureSignature else {
            return
        }
        mLastNotifiedLoopClosureSignature = signature

        let message: String
        if reliable {
            let feedback = UINotificationFeedbackGenerator()
            feedback.prepare()
            feedback.notificationOccurred(.success)
            message = String(
                format: localized("Loop completed. Map corrected (%d reliable loops)."),
                mReliableLoopClosures)
        }
        else {
            let feedback = UIImpactFeedbackGenerator(style: .light)
            feedback.prepare()
            feedback.impactOccurred()
            message = localized("Nearby loop match accepted. Continue to a previously scanned cross-aisle to complete a reliable loop.")
        }

        showToast(
            message: message,
            seconds: reliable ? 2.5 : 1.8,
            replacingCurrent: reliable)
        UIAccessibility.post(notification: .announcement, argument: message)
    }
    
    func resetNoTouchTimer(_ showHud: Bool = false) {
        if(showHud)
        {
            mMenuOpened = false
            mHudVisible = true
            setNeedsStatusBarAppearanceUpdate()
            updateState(state: self.mState)
            
            mLastTimeHudShown = DispatchTime.now()
            DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + 5) {
                if(DispatchTime.now() <= self.mLastTimeHudShown + 4.9) {
                    return
                }
                if(self.mState != .STATE_WELCOME && self.mState != .STATE_CAMERA && self.presentedViewController as? UIAlertController == nil && !self.mMenuOpened)
                {
                    print("Hide HUD")
                    self.mHudVisible = false
                    self.setNeedsStatusBarAppearanceUpdate()
                    self.updateState(state: self.mState)
                }
            }
        }
        else if(mState != .STATE_WELCOME && mState != .STATE_CAMERA && presentedViewController as? UIAlertController == nil && !mMenuOpened)
        {
            self.mHudVisible = false
            self.setNeedsStatusBarAppearanceUpdate()
            self.updateState(state: self.mState)
        }
    }
    
    func addShadow(_ view: UIView, _ offset: Int = 4)
    {
        view.layer.shadowColor = UIColor.black.cgColor
        view.layer.shadowRadius = 3.0
        view.layer.shadowOpacity = 1.0
        view.layer.shadowOffset = CGSize(width: offset, height: offset)
        view.layer.masksToBounds = false
    }
    
    override func viewDidLoad() {
        
        mMaximumMemory = getAvailableMemory()
        
        super.viewDidLoad()
        // Do any additional setup after loading the view.
        
        self.toastLabel.isHidden = true
        session.delegate = self
        
        addShadow(stopButton)
        addShadow(recordButton)
        addShadow(menuButton)
        addShadow(viewButton)
        addShadow(newScanButtonLarge)
        addShadow(libraryButton)
        addShadow(closeVisualizationButton)
        addShadow(stopCameraButton)
        addShadow(stopMeasuringButton)
        addShadow(teleportButton)
        addShadow(addMeasureButton)
        addShadow(removeMeasureButton)
        addShadow(measuringModeButton)
        addShadow(exportOBJPLYButton)
        
        addShadow(statusLabel, 0)
        addShadow(toastLabel, 0)
        
        addShadow(orthoDistanceSlider, 0)
        addShadow(orthoGridSlider, 0)
        
        depthSupported = ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
        
        supermarketSession = SupermarketScanSession(documentsDirectory: getDocumentDirectory())
        applySupermarketSettings()
        setupMobileOnlyWorkflow()
        
        context = EAGLContext(api: .openGLES2)
        EAGLContext.setCurrent(context)
        
        if let view = self.view as? GLKView, let context = context {
            view.context = context
            delegate = self
        }
        
        menuButton.showsMenuAsPrimaryAction = true
        viewButton.showsMenuAsPrimaryAction = true
        statusLabel.numberOfLines = 0
        statusLabel.text = ""
        
        updateDatabases()
        
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        view.addGestureRecognizer(doubleTap)
        let singleTap = UITapGestureRecognizer(target: self, action: #selector(singleTapped(_:)))
        singleTap.numberOfTapsRequired = 1
        view.addGestureRecognizer(singleTap)
        
        let notificationCenter = NotificationCenter.default
        notificationCenter.addObserver(self, selector: #selector(appMovedToBackground), name: UIApplication.willResignActiveNotification, object: nil)
        // didBecomeActive also covers short interruptions (Control Center,
        // notification shade or Siri) which never enter the background.
        notificationCenter.addObserver(self, selector: #selector(appMovedToForeground), name: UIApplication.didBecomeActiveNotification, object: nil)
        notificationCenter.addObserver(self, selector: #selector(defaultsChanged), name: UserDefaults.didChangeNotification, object: nil)
        
        registerSettingsBundle()
        
        maxPolygonsPickerView = UIPickerView(frame: CGRect(x: 10, y: 50, width: 250, height: 150))
        maxPolygonsPickerView.delegate = self
        maxPolygonsPickerView.dataSource = self

        // This is where you can set your min/max values
        let minNum = 0
        let maxNum = 9
        maxPolygonsPickerData = Array(stride(from: minNum, to: maxNum + 1, by: 1))
        
        orthoDistanceSlider.setValue(80, animated: false)
        orthoGridSlider.setValue(90, animated: false)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.updateState(state: self.mState)
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard let overlay = priceTagCaptureOverlay,
              overlay.bounds.width > 0,
              overlay.bounds.height > 0 else {
            return
        }
        priceTagCaptureCoordinator.updateGeometry(overlay.captureGeometry)
    }

    // MARK: - Mobile-Only workflow entry (V1R1 Gate A)

    private func presentMobileFlow(_ root: UIViewController) {
        let navigation = UINavigationController(rootViewController: root)
        navigation.modalPresentationStyle = .fullScreen
        present(navigation, animated: true)
    }

    private func setupMobileOnlyWorkflow() {
        let coordinator = MobileOnlyWorkflowCoordinator.shared
        // Wire the shared native factor-graph core into the processing
        // gateway (V1R2 Gate G): production Fast/Deep runs never use the
        // Swift reference solver.
        MobileNativeFactorGraph.wireIntoGateway()
        // Exact build identity embedded by the Xcode script phase (V1R3
        // §4.4); an unusable identity blocks processing eligibility.
        let identity = MobileBuildIdentity.loadFromBundle()
        coordinator.buildIdentity = identity
        coordinator.appGitSHA = identity.appGitSHA
        coordinator.policySHA = identity.wave
        coordinator.nativeCoreSHA256 = identity.nativeCoreSHA256
        coordinator.appVersion =
            Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.22.0"
        coordinator.deviceModel = UIDevice.current.model
        coordinator.osVersion = UIDevice.current.systemVersion
        // Scan start (V1R2 Gate D §8.3): the host performs the REAL
        // production steps — package load, SHA verification, PriorMap
        // configuration with the committed initial map pose, then the
        // ARSession + RTAB-Map recording + session metadata via newScan.
        coordinator.onStartScan = { [weak self] configuration in
            guard let self = self else {
                throw MobileOnlyWorkflowError.invalidState("scan host released")
            }
            return try self.startMobileOnlyScan(configuration)
        }
        // B-09: when the workflow cannot commit a validated host start
        // (receipt invalid or persistence failed), the host must stop the
        // already-running scan so it cannot outlive a failed workflow.
        coordinator.onRollbackScan = { [weak self] receipt in
            self?.rollbackMobileOnlyScanStart(
                receipt: receipt,
                reason: "workflow_start_commit_failed")
        }
    }

    /// Transaction rollback for a mobile-only start that reached the host
    /// but could not commit a durable receipt/workflow context. This is
    /// intentionally stronger than `stopMapping(ignoreSaving:)`: it stops
    /// every producer, detaches the native database, releases the failed
    /// session identity and clears prior-map state so a retry cannot append
    /// to the uncommitted session.
    private func rollbackMobileOnlyScanStart(
        receipt: MobileScanStartReceipt?,
        reason: String
    ) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.rollbackMobileOnlyScanStart(
                    receipt: receipt,
                    reason: reason)
            }
            return
        }
        cancelAutomaticCaptureResume()
        stopMapping(ignoreSaving: true)
        _ = stopClockCorrelationRecording(flush: false)

        let failedSession = supermarketSession
        failedSession?.appendScanEvent(
            level: "error",
            event: "mobile_only_scan_start_rolled_back",
            message: "The live scan start did not reach its durable workflow commit",
            fields: [
                "reason": reason,
                "trackingSessionId": receipt?.trackingSessionID
                    ?? failedSession?.trackingSessionId
                    ?? "",
                "priorMapId": receipt?.priorMapID
                    ?? activeScanConfiguration.priorMapId
                    ?? "",
            ])

        // Persist/cancel any in-flight prior-map recovery evidence while the
        // failed session identity is still available, then unbind it.
        clearPriorMapLocalization()

        // Opening a private scratch database closes the failed streaming DB
        // inside the native core. Never reuse/delete the legacy
        // Documents/rtabmap.tmp.db recovery file for this purpose.
        if let rtabmap = rtabmap {
            do {
                let base = try FileManager.default.url(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask,
                    appropriateFor: nil,
                    create: true)
                let directory = base
                    .appendingPathComponent("MarketScanner", isDirectory: true)
                    .appendingPathComponent("FailedScanStart", isDirectory: true)
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: true)
                let detachedDatabase = directory
                    .appendingPathComponent("native_detached.db")
                _ = rtabmap.openDatabase(
                    databasePath: detachedDatabase.path,
                    databaseInMemory: false,
                    optimize: false,
                    clearDatabase: true)
            } catch {
                print("Could not detach failed mobile-only database: \(error)")
            }
        }

        if let failedSession {
            MarketScannerCrashDiagnostics.shared.markScanCompleted(
                trackingSessionID: failedSession.trackingSessionId)
            failedSession.completeCurrentSession()
        }
        activeScanConfiguration = .freeMapping
        mDataRecording = false
        openedDatabasePath = nil
        mMapNodes = 0
        mLatestDatabaseMemoryMB = 0
        mLatestScanStorageBytes = 0
        updateState(state: .STATE_IDLE)
    }

    private func persistScanConfiguration(_ configuration: MobileScanConfiguration) {
        let payload: [String: Any] = [
            "prior_map_id": configuration.priorMap.priorMapID,
            "prior_map_sha256": configuration.priorMap.packageSHA256,
            "map_name": configuration.priorMap.name,
            "floor_id": configuration.floorID,
            "start_x_m": configuration.startXM,
            "start_y_m": configuration.startYM,
            "start_yaw_rad": configuration.startYawRad,
            "store_id": configuration.storeID,
            "committed_at_utc": Date().timeIntervalSince1970,
        ]
        UserDefaults.standard.set(payload, forKey: "MarketScannerScanConfiguration")
        let message = String(
            format: "扫描配置已提交：%@（%@）", configuration.priorMap.name,
            configuration.priorMap.priorMapID)
        showToast(message)
    }

    // MARK: - Clock correlation evidence (V1R3 §7.1)

    /// Begins recording monotonic↔UTC correlations for the active scan.
    /// The sidecar is written into the segment directory and flushed on
    /// finalization; a periodic timer samples every 30 s while scanning
    /// and system clock / timezone changes append explicit segment
    /// starts (V1R4 §7.4).
    private func startClockCorrelationRecording(
        segmentDirectory: URL,
        trackingSessionID: String
    ) throws {
        stopClockCorrelationRecording(flush: false)
        let url = segmentDirectory.appendingPathComponent("clock_correlations.jsonl")
        let recorder = try ClockCorrelationRecorder(
            trackingSessionID: trackingSessionID,
            url: url)
        try recorder.record(
            reason: .sessionStart,
            monotonicSeconds: ProcessInfo.processInfo.systemUptime,
            utcUnixSeconds: Date().timeIntervalSince1970,
            timezoneID: TimeZone.current.identifier,
            utcOffsetSeconds: TimeZone.current.secondsFromGMT())
        clockRecorder = recorder
        clockSidecarWriteFailure = nil
        clockSidecarWriteResult = nil
        lastClockBoundNodeID = 0
        // V1R4 §7.4: an explicit correlation at every system clock change
        // and timezone change; each becomes a discontinuity segment edge
        // so post-processing never interpolates across it.
        let center = NotificationCenter.default
        clockChangeObservers = [
            center.addObserver(
                forName: NSNotification.Name.NSSystemClockDidChange,
                object: nil, queue: .main) { [weak self] _ in
                self?.recordClockCorrelation(reason: .systemClockChange)
            },
            center.addObserver(
                forName: NSNotification.Name.NSSystemTimeZoneDidChange,
                object: nil, queue: .main) { [weak self] _ in
                self?.recordClockCorrelation(reason: .timezoneChange)
            },
        ]
        clockTimer = Timer.scheduledTimer(
            withTimeInterval: ClockCorrelationRecorder.periodicIntervalSeconds,
            repeats: true) { [weak self] _ in
            guard let self = self, let recorder = self.clockRecorder else { return }
            do {
                try recorder.maybeRecordPeriodic(
                    monotonicSeconds: ProcessInfo.processInfo.systemUptime,
                    utcUnixSeconds: Date().timeIntervalSince1970,
                    timezoneID: TimeZone.current.identifier,
                    utcOffsetSeconds: TimeZone.current.secondsFromGMT())
            } catch {
                self.recordClockSidecarFailure(error)
            }
        }
    }

    /// Appends a correlation record for the given reason (clock change /
    /// timezone change / app lifecycle events, V1R4 §7.4).
    private func recordClockCorrelation(reason: ClockCorrelationRecorder.Reason) {
        guard let recorder = clockRecorder else { return }
        do {
            try recorder.record(
                reason: reason,
                monotonicSeconds: ProcessInfo.processInfo.systemUptime,
                utcUnixSeconds: Date().timeIntervalSince1970,
                timezoneID: TimeZone.current.identifier,
                utcOffsetSeconds: TimeZone.current.secondsFromGMT())
        } catch {
            recordClockSidecarFailure(error)
        }
    }

    private func recordClockSidecarFailure(_ error: Error) {
        if clockSidecarWriteFailure == nil {
            clockSidecarWriteFailure =
                "clock_sidecar_write_failed: \(error.localizedDescription)"
        }
        clockSidecarWriteResult = nil
        clockRecorder?.cancel()
    }

    /// Stops the periodic timer and observers and, when flushing, appends
    /// the session_end record and writes the sidecar durably (V1R4 §7.2).
    /// A failed write is never swallowed: it is captured in
    /// `clockSidecarWriteFailure` and blocks processing eligibility.
    /// Returns the write watermark when the flush succeeded.
    @discardableResult
    private func stopClockCorrelationRecording(
        flush: Bool
    ) -> ClockSidecarWriteResult? {
        clockTimer?.invalidate()
        clockTimer = nil
        for observer in clockChangeObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        clockChangeObservers = []
        guard let recorder = clockRecorder else {
            clockRecorder = nil
            return nil
        }
        var result: ClockSidecarWriteResult?
        if flush, clockSidecarWriteFailure == nil {
            do {
                try recorder.record(
                    reason: .sessionEnd,
                    monotonicSeconds: ProcessInfo.processInfo.systemUptime,
                    utcUnixSeconds: Date().timeIntervalSince1970,
                    timezoneID: TimeZone.current.identifier,
                    utcOffsetSeconds: TimeZone.current.secondsFromGMT())
                let writeResult = try recorder.finish()
                clockSidecarWriteResult = writeResult
                result = writeResult
            } catch {
                recordClockSidecarFailure(error)
            }
        } else {
            recorder.cancel()
        }
        clockRecorder = nil
        return result
    }

    private func finishStartup() {
        guard !startupCompleted else {
            return
        }
        startupCompleted = true

        rtabmap = RTABMap()
        rtabmap?.setupCallbacksWithCPP()
        rtabmap?.addObserver(self)

        if let context = context {
            EAGLContext.setCurrent(context)
            rtabmap?.initGlContent()
        }

        updateDisplayFromDefaults()
        presentFinalizedCheckpointCleanupIfNeeded()
    }

    private func presentFinalizedCheckpointCleanupIfNeeded() {
        guard !finalizedCleanupPromptShown,
              let scanSession = supermarketSession else {
            return
        }
        let segments = scanSession.finalizedSegmentsNeedingCheckpointCleanup()
        guard !segments.isEmpty else {
            return
        }
        finalizedCleanupPromptShown = true
        let alert = UIAlertController(
            title: localized("Scan saved; cleanup required"),
            message: String(
                format: localized("%d finalized scan(s) still contain an older live checkpoint. Their databases are closed. Clean only checkpoints whose tracking identity and time are verified?"),
                segments.count),
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(
            title: localized("Keep for diagnosis"),
            style: .cancel))
        alert.addAction(UIAlertAction(
            title: localized("Verify and clean"),
            style: .default,
            handler: { _ in
                var failures: [String] = []
                for segment in segments {
                    do {
                        try scanSession.cleanupFinalizedCheckpoint(in: segment)
                    }
                    catch {
                        failures.append(
                            "\(segment.deletingLastPathComponent().lastPathComponent): \(error.localizedDescription)")
                    }
                }
                self.showToast(
                    message: failures.isEmpty
                        ? self.localized("Finalized checkpoint cleanup completed. The saved scans are now eligible for PC inspection.")
                        : String(
                            format: self.localized("Some finalized checkpoints were not cleaned: %@"),
                            failures.joined(separator: "; ")),
                    seconds: failures.isEmpty ? 4 : 8,
                    replacingCurrent: true)
            }))
        present(alert, animated: true)
    }

    func progressStatusUpdate() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            if self.mState == .STATE_PROCESSING && self.statusShown
            {
                let availableMem = self.getAvailableMemory()
                let usedMem = self.mMaximumMemory - availableMem;
                self.statusLabel.text =
                    "Status: \(self.getStateString(state: self.mState))\n" +
                    "RAM Usage (MB): \(usedMem) / \(self.mMaximumMemory)"
                self.progressStatusUpdate()
            }
        }
    }
    
    func progressUpdated(_ rtabmap: RTABMap, count: Int, max: Int) {
        DispatchQueue.main.async {
            self.progressView?.setProgress(Float(count)/Float(max), animated: true)
        }
    }
    func initEventReceived(_ rtabmap: RTABMap, status: Int, msg: String) {
        DispatchQueue.main.async {
            var optimizedMeshDetected = 0

            if(msg == "Loading optimized cloud...done!")
            {
                optimizedMeshDetected = 1;
            }
            else if(msg == "Loading optimized mesh...done!")
            {
                optimizedMeshDetected = 2;
            }
            else if(msg == "Loading optimized texture mesh...done!")
            {
                optimizedMeshDetected = 3;
            }
            if(optimizedMeshDetected > 0)
            {
                if(optimizedMeshDetected==1)
                {
                    self.visualizationType = 0;
                    self.setMeshRendering(viewMode: 0)
                }
                else if(optimizedMeshDetected==2)
                {
                    self.visualizationType = 1;
                    self.setMeshRendering(viewMode: 1)
                }
                else // isOBJ
                {
                    self.visualizationType = 2;
                    self.setMeshRendering(viewMode: 2)
                }

                self.updateState(state: .STATE_VISUALIZING_WHILE_LOADING);
                self.setGLCamera(type: 2);
                
                self.dismiss(animated: true)
                self.showToast(message: "Optimized mesh detected in the database, it is shown while the database is loading...", seconds: 3)
            }

            let availableMem = self.getAvailableMemory()
            let usedMem = self.mMaximumMemory - availableMem;
            self.statusLabel.text =
                "Status: " + (status == 1 && msg.isEmpty ? self.mState == State.STATE_CAMERA ? "Camera Preview" : "Idle" : msg) + "\n" +
            	"RAM Usage (MB): \(usedMem) / \(self.mMaximumMemory)"
        }
    }
        
    func statsUpdated(_ rtabmap: RTABMap,
                           nodes: Int,
                           words: Int,
                           points: Int,
                           polygons: Int,
                           updateTime: Float,
                           loopClosureId: Int,
                           highestHypId: Int,
                           databaseMemoryUsed: Int,
                           inliers: Int,
                           matches: Int,
                           featuresExtracted: Int,
                           hypothesis: Float,
                           nodesDrawn: Int,
                           fps: Float,
                           rejected: Int,
                           rehearsalValue: Float,
                           optimizationMaxError: Float,
                           optimizationMaxErrorRatio: Float,
                           distanceTravelled: Float,
                           fastMovement: Int,
                           landmarkDetected: Int,
                           loopClosureType: Int,
                           loopClosureCurrentId: Int,
                           loopClosureTargetId: Int,
                           mapCorrectionX: Float,
                           mapCorrectionY: Float,
                           mapCorrectionZ: Float,
                           mapCorrectionQx: Float,
                           mapCorrectionQy: Float,
                           mapCorrectionQz: Float,
                           mapCorrectionQw: Float,
                           x: Float,
                           y: Float,
                           z: Float,
                           roll: Float,
                           pitch: Float,
                           yaw: Float)
    {
        let availableMem = self.getAvailableMemory()
        let usedMem = max(0, self.mMaximumMemory - availableMem)
        let scanStorageBytes = currentContinuousScanStorageBytes()
        let structureCoverage = supermarketSession?.structureCoverageSummary()
        let mapCorrection = makeRigidTransform(
            x: mapCorrectionX,
            y: mapCorrectionY,
            z: mapCorrectionZ,
            qx: mapCorrectionQx,
            qy: mapCorrectionQy,
            qz: mapCorrectionQz,
            qw: mapCorrectionQw)
        let previousMapCorrection = updateMapToOdomCorrection(mapCorrection)
        let mapCorrectionDelta = simd_mul(
            mapCorrection,
            simd_inverse(previousMapCorrection))
        let mapCorrectionTranslation = SIMD3<Float>(
            mapCorrection.columns.3.x,
            mapCorrection.columns.3.y,
            mapCorrection.columns.3.z)
        let mapCorrectionDeltaTranslation = SIMD3<Float>(
            mapCorrectionDelta.columns.3.x,
            mapCorrectionDelta.columns.3.y,
            mapCorrectionDelta.columns.3.z)
        let mapCorrectionTranslationM = Double(simd_length(mapCorrectionTranslation))
        let mapCorrectionRotationDeg = rotationAngleDegrees(mapCorrection)
        let mapCorrectionDeltaTranslationM = Double(simd_length(mapCorrectionDeltaTranslation))
        let mapCorrectionDeltaRotationDeg = rotationAngleDegrees(mapCorrectionDelta)
        mLastMapCorrectionTranslationM = mapCorrectionTranslationM
        mLastMapCorrectionRotationDeg = mapCorrectionRotationDeg
        mLastMapCorrectionDeltaTranslationM = mapCorrectionDeltaTranslationM
        mLastMapCorrectionDeltaRotationDeg = mapCorrectionDeltaRotationDeg

        let loopNodeSpan =
            loopClosureCurrentId > 0 && loopClosureTargetId > 0 ?
            abs(loopClosureCurrentId - loopClosureTargetId) : 0
        let loopInlierRatio =
            matches > 0 ? Double(inliers) / Double(matches) : 0.0
        let loopClosureTypeLabel: String
        switch loopClosureType {
        case 1:
            loopClosureTypeLabel = "global_visual"
        case 2:
            loopClosureTypeLabel = "local_space"
        default:
            loopClosureTypeLabel = "none"
        }
        // Accepted neighboring/local-time constraints help local consistency,
        // but they do not make accumulated drift observable. Only an accepted
        // global or local-space constraint spanning enough graph nodes resets
        // the "distance without a reliable anchor" health metric.
        let reliableLoopClosure =
            loopClosureId > 0 &&
            loopClosureTargetId > 0 &&
            (loopClosureType == 1 || loopClosureType == 2) &&
            loopNodeSpan >= mReliableLoopMinimumNodeSpan
        mCurrentDistanceTravelled = distanceTravelled
        
        var loopHealthGuidance: String?
        if(loopClosureId > 0)
        {
            mTotalLoopClosures += 1;
        }
        if reliableLoopClosure
        {
            mReliableLoopClosures += 1
            mConsecutiveRejectedLoopClosures = 0
            mLastReliableLoopClosureDistance = distanceTravelled
        }
        else if rejected > 0 && self.mState == .STATE_MAPPING {
            mConsecutiveRejectedLoopClosures += 1
        }
        if self.mState == .STATE_MAPPING {
            let distanceWithoutClosure = max(0, distanceTravelled - mLastReliableLoopClosureDistance)
            let now = Date().timeIntervalSince1970
            if (distanceWithoutClosure >= 25 && mConsecutiveRejectedLoopClosures >= 6) ||
               distanceWithoutClosure >= 45 {
                if now - mLastLoopHealthGuidanceAt >= 20 {
                    mLastLoopHealthGuidanceAt = now
                    loopHealthGuidance = localized("Reliable loop closure has been missing for a long distance. Return through the nearest previously scanned cross-aisle before continuing.")
                    supermarketSession?.appendScanEvent(
                        level: "warning",
                        event: "loop_closure_health_degraded",
                        message: "Long travel distance without a reliable long-range loop closure",
                        fields: [
                            "distanceWithoutClosureM": String(format: "%.2f", distanceWithoutClosure),
                            "consecutiveRejectedCandidates": "\(mConsecutiveRejectedLoopClosures)",
                            "reliableLoopClosures": "\(mReliableLoopClosures)",
                            "mapCorrectionTranslationM": String(format: "%.3f", mLastMapCorrectionTranslationM),
                            "mapCorrectionRotationDeg": String(format: "%.2f", mLastMapCorrectionRotationDeg),
                            "nodeCount": "\(nodes)"
                        ])
                }
            }
        }
        let previousNodes = mMapNodes
        mMapNodes = nodes;
        mLatestDatabaseMemoryMB = databaseMemoryUsed
        mLatestScanStorageBytes = scanStorageBytes
        mLatestPerformanceUpdateTimeMS = max(0, Double(updateTime))
        mLatestPerformanceFPS = max(0, Double(fps))
        mLatestPerformanceWordCount = max(0, words)
        mLatestPerformanceFeatureCount = max(0, featuresExtracted)
        mLatestPerformancePointCount = max(0, points)
        mLatestPerformancePolygonCount = max(0, polygons)
        mLatestPose = (x, y, z, roll, pitch, yaw)
        let estimatedArea = (self.mState == .STATE_MAPPING) ? (supermarketSession?.updateArea(timestamp: Date().timeIntervalSince1970, nodeCount: nodes, x: x, y: y, z: z, roll: roll, pitch: pitch, yaw: yaw) ?? 0.0) : (supermarketSession?.currentAreaM2 ?? 0.0)
        
        let formattedDate = Date().getFormattedDate(format: "HH:mm:ss.SSS")

        if self.mState == .STATE_MAPPING {
            self.recordStreamingPerformanceSample(
                nodeCount: nodes,
                databaseMemoryMB: databaseMemoryUsed,
                scanStorageBytes: scanStorageBytes,
                updateTimeMS: Double(updateTime),
                renderingFPS: Double(fps),
                wordCount: words,
                featureCount: featuresExtracted,
                pointCount: points,
                polygonCount: polygons)
        }
        
        DispatchQueue.main.async {
            if self.mState == .STATE_MAPPING {
                self.updateStreamingCaptureHealth(
                    nodeCount: nodes,
                    databaseMemoryMB: databaseMemoryUsed,
                    usedMemoryMB: usedMem)
            }
            
            if(self.mMapNodes>0 && previousNodes==0 && self.mState != .STATE_MAPPING)
            {
                self.updateState(state: self.mState) // refesh menus and actions
            }
            
            self.statusLabel.text = ""
            if self.statusShown {
                self.statusLabel.text =
                    String(format: self.localized("Status: %@\n"), self.getStateString(state: self.mState)) +
                    String(format: self.localized("RAM Usage (MB): %d / %d"), usedMem, self.mMaximumMemory) +
                    String(format: self.localized("\nScan Storage: %@"), self.formattedStorageSize(scanStorageBytes)) +
                    String(format: self.localized("\nScanned Area: %.1f m2"), estimatedArea)
                if let structureCoverage = structureCoverage {
                    self.statusLabel.text = (self.statusLabel.text ?? "") +
                        String(
                            format: self.localized("\nStructure coverage: %d stable / %d multi-view (%d%%)"),
                            structureCoverage.stableStructureCellCount,
                            structureCoverage.multiViewStructureCellCount,
                            Int(round(structureCoverage.coverageScore * 100)))
                }
            }
            if self.debugShown {
                self.statusLabel.text = (self.statusLabel.text ?? "") + "\n"
                var gpsString = "\n"
                if(UserDefaults.standard.bool(forKey: "SaveGPS"))
                {
                    if let lastKnownLocation = self.mLastKnownLocation
                    {
                        let secondsOld = Date().timeIntervalSince1970
                            - lastKnownLocation.timestamp.timeIntervalSince1970
                        var bearing = 0.0
                        if lastKnownLocation.course > 0.0 {
                            bearing = lastKnownLocation.course
                            
                        }
                        gpsString = String(format: "GPS: %.2f %.2f %.2fm %ddeg %.0fm [%d sec old]\n",
                                           lastKnownLocation.coordinate.longitude,
                                           lastKnownLocation.coordinate.latitude,
                                           lastKnownLocation.altitude,
                                           Int(bearing),
                                           lastKnownLocation.horizontalAccuracy,
                                           Int(secondsOld));
                    }
                    else
                    {
                        gpsString = "GPS: [not yet available]\n";
                    }
                }
                var lightString = "\n"
                if let lastLightEstimate = self.mLastLightEstimate
                {
                    lightString = String("Light (lm): \(Int(lastLightEstimate))\n")
                }
                
                self.statusLabel.text =
                    (self.statusLabel.text ?? "") +
                    gpsString + //gps
                    lightString + //env sensors
                    "Time: \(formattedDate)\n" +
                    "Nodes (WM): \(nodes) (\(nodesDrawn) shown)\n" +
                    "Words: \(words)\n" +
                    "Database (MB): \(databaseMemoryUsed)\n" +
                    "Number of points: \(points)\n" +
                    "Polygons: \(polygons)\n" +
                    "Update time (ms): \(Int(updateTime)) / \(self.mTimeThr==0 ? "No Limit" : String(self.mTimeThr))\n" +
                    "Features: \(featuresExtracted) / \(self.mMaxFeatures==0 ? "No Limit" : (self.mMaxFeatures == -1 ? "Disabled" : String(self.mMaxFeatures)))\n" +
                    "Rehearsal (%): \(Int(rehearsalValue*100))\n" +
                    "Loop closures: \(self.mTotalLoopClosures)\n" +
                    "Reliable loop anchors: \(self.mReliableLoopClosures)\n" +
                    String(format: "Map correction: %.2f m / %.1f deg (delta %.2f m / %.1f deg)\n", self.mLastMapCorrectionTranslationM, self.mLastMapCorrectionRotationDeg, self.mLastMapCorrectionDeltaTranslationM, self.mLastMapCorrectionDeltaRotationDeg) +
                    "Inliers: \(inliers)\n" +
                    "Hypothesis (%): \(Int(hypothesis*100)) / \(Int(self.mLoopThr*100)) (\(loopClosureId>0 ? loopClosureId : highestHypId))\n" +
                    String(format: "FPS (rendering): %.1f Hz\n", fps) +
                    String(format: "Travelled distance: %.2f m\n", distanceTravelled) +
                    String(format: "Pose (x,y,z): %.2f %.2f %.2f", x, y, z)
            }
            if(self.mState == .STATE_MAPPING || self.mState == .STATE_VISUALIZING_CAMERA)
            {
                if(loopClosureId > 0) {
                    if self.mState == .STATE_MAPPING {
                        self.supermarketSession?.appendScanEvent(
                            event: "loop_closure",
                            message: "Loop closure detected",
                            fields: [
                                "loopClosureId": "\(loopClosureId)",
                                "loopClosureType": loopClosureTypeLabel,
                                "currentNodeId": "\(loopClosureCurrentId)",
                                "targetNodeId": "\(loopClosureTargetId)",
                                "nodeSpan": "\(loopNodeSpan)",
                                "reliableForDriftCorrection": reliableLoopClosure ? "true" : "false",
                                "nodeCount": "\(nodes)",
                                "inliers": "\(inliers)",
                                "matches": "\(matches)",
                                "inlierRatio": String(format: "%.3f", loopInlierRatio),
                                "mapCorrectionTranslationM": String(format: "%.4f", mapCorrectionTranslationM),
                                "mapCorrectionRotationDeg": String(format: "%.3f", mapCorrectionRotationDeg),
                                "mapCorrectionDeltaTranslationM": String(format: "%.4f", mapCorrectionDeltaTranslationM),
                                "mapCorrectionDeltaRotationDeg": String(format: "%.3f", mapCorrectionDeltaRotationDeg)
                            ])
                    }
                    if(self.mState == .STATE_VISUALIZING_CAMERA) {
                        self.showToast(message: self.localized("Localized!"), seconds: 1);
                    }
                    else {
                        self.showLoopClosureFeedback(
                            reliable: reliableLoopClosure,
                            loopClosureType: loopClosureType,
                            currentNodeId: loopClosureCurrentId,
                            targetNodeId: loopClosureTargetId)
                    }
                    if reliableLoopClosure,
                       self.activeScanConfiguration.workflowMode == .priorMapLocalized,
                       let localizer = self.priorMapLocalizer {
                        let generation = self.priorMapGeneration
                        self.priorMapQueue.async {
                            guard generation == self.priorMapGeneration else { return }
                            localizer.requestRecovery(reason: "reliable_rtabmap_loop")
                            let shelfCandidates = localizer
                                .nearbyShelfIdentityCandidates()
                            guard generation == self.priorMapGeneration else {
                                return
                            }
                            let identityStatus: String
                            if shelfCandidates.isEmpty {
                                identityStatus = "unavailable"
                            }
                            else if shelfCandidates.count == 1 {
                                identityStatus = "single_nearby_candidate"
                            }
                            else {
                                identityStatus = "ambiguous_top_k_retained"
                            }
                            if let scanSession = self.supermarketSession {
                                _ = self.persistShelfLoopEvent(
                                    shelfCandidates: shelfCandidates,
                                    scanSession: scanSession,
                                    loopFromNode: loopClosureCurrentId,
                                    loopToNode: loopClosureTargetId,
                                    rtabLoopID: loopClosureId,
                                    rtabGraphOptimizationMaxError: Double(max(
                                        0, optimizationMaxError)),
                                    visualLoopInlierRatio: loopInlierRatio)
                            }
                            self.supermarketSession?.appendScanEvent(
                                level: shelfCandidates.count == 1
                                    ? "info" : "warning",
                                event: "loop_opened_shelf_identity_candidates",
                                message: "Reliable RTAB-Map loop opened bounded recovery; the latest filtered depth-geometry shelf top-K was retained",
                                fields: [
                                    "authority": "manifest_v5_shelf_loop_candidate",
                                    "candidate_source": "filtered_depth_point_to_shelf_segment_residuals",
                                    "identity_status": identityStatus,
                                    "candidate_count": "\(shelfCandidates.count)",
                                    "shelf_segment_ids": shelfCandidates
                                        .map(\.shelfSegmentId)
                                        .joined(separator: ","),
                                    "shelf_codes": shelfCandidates
                                        .map(\.shelfCode)
                                        .joined(separator: ","),
                                    "distances_m": shelfCandidates
                                        .map { String(format: "%.3f", $0.distanceM) }
                                        .joined(separator: ","),
                                    "geometry_scores": shelfCandidates
                                        .map { String(format: "%.4f", $0.geometryScore) }
                                        .joined(separator: ","),
                                    "longitudinal_fractions": shelfCandidates
                                        .map {
                                            String(
                                                format: "%.4f",
                                                $0.longitudinalFraction)
                                        }
                                        .joined(separator: ","),
                                ])
                        }
                    }
                }
                else if(rejected > 0)
                {
                    if self.mState == .STATE_MAPPING {
                        self.supermarketSession?.appendScanEvent(
                            level: "warning",
                            event: "loop_closure_rejected",
                            message: "Loop closure candidate was rejected",
                            fields: [
                                "nodeCount": "\(nodes)",
                                "candidateNodeId": "\(highestHypId)",
                                "inliers": "\(inliers)",
                                "matches": "\(matches)",
                                "inlierRatio": String(format: "%.3f", loopInlierRatio),
                                "optimizationMaxError": "\(optimizationMaxError)"
                            ])
                    }
                    if let guidance = loopHealthGuidance {
                        self.showToast(message: guidance, seconds: 4)
                    }
                    else if self.debugShown && inliers >= (self.mDataRecording
                        ? UserDefaults.standard.integer(forKey: "MinInliers")
                        : self.mStreamingMinimumVisualInliers)
                    {
                        if(optimizationMaxError > 0.0)
                        {
                            let appliedFactor = self.mDataRecording
                                ? UserDefaults.standard.double(
                                    forKey: "MaxOptimizationError")
                                : self.mStreamingOptimizeMaxError
                            self.showToast(message: String(format: self.localized("Loop closure rejected, too high graph optimization error (%.3fm: ratio=%.3f < factor=%.1fx)."), optimizationMaxError, optimizationMaxErrorRatio, appliedFactor), seconds: 1);
                        }
                        else
                        {
                            self.showToast(message: self.localized("Loop closure rejected, graph optimization failed! You may try a different Graph Optimizer in Mapping settings."), seconds: 1);
                        }
                    }
                    else if self.debugShown
                    {
                        self.showToast(message: String(format: self.localized("Loop closure rejected, not enough inliers (%d/%d < %d)."), inliers, matches, UserDefaults.standard.integer(forKey: "MinInliers")), seconds: 1);
                    }
                }
                else if(landmarkDetected > 0) {
                    if self.mState == .STATE_MAPPING {
                        self.supermarketSession?.appendScanEvent(
                            event: "landmark_detected",
                            message: "Landmark detected",
                            fields: ["landmarkId": "\(landmarkDetected)", "nodeCount": "\(nodes)"])
                    }
                    self.showToast(message: String(format: self.localized("Landmark %d detected!"), landmarkDetected), seconds: 1);
                }
            }
        }
    }
    
    func cameraInfoEventReceived(_ rtabmap: RTABMap, type: Int, key: String, value: String) {
        if(self.debugShown && key == "UpstreamRelocationFiltered")
        {
            DispatchQueue.main.async {
                self.dismiss(animated: true)
                self.showToast(message: "ARKit re-localization filtered because an acceleration of \(value) has been detected, which is over current threshold set in the settings.", seconds: 3)
            }
        }
    }
    
    func getAvailableMemory() -> Int {
        return os_proc_available_memory()/(1024*1024)
    }
    
    @objc func appMovedToBackground() {
        print("appMovedToBackground()")
        cancelPriceTagCapture(
            reason: "application_resigned_active",
            userMessage: localized("ESL capture was cancelled because the app is no longer active."))
        // V1R4 §7.4: capture the clock correlation at the interruption
        // boundary so processing sees the background gap explicitly.
        recordClockCorrelation(reason: .willResignActive)
        if mState == .STATE_MAPPING || mState == .STATE_CAMERA {
            suspendCaptureForSystemInterruption(reason: "application resigned active")
        }
        else if mState == .STATE_VISUALIZING_CAMERA || mState == .STATE_VISUALIZING_AND_MEASURING {
            stopMapping(ignoreSaving: true)
        }
    }

    private func suspendCaptureForSystemInterruption(reason: String)
    {
        cancelPriceTagCapture(
            reason: "system_interruption",
            userMessage: localized("ESL capture was cancelled by a system interruption."))
        guard !mSystemInterruptionInProgress,
              mState == .STATE_MAPPING || mState == .STATE_CAMERA else {
            return
        }

        mSystemInterruptionInProgress = true
        mCaptureStateBeforeSystemInterruption = mState
        mSystemInterruptionBeganAt = Date()
        mSystemInterruptionReason = reason
        mTrackingWasDegraded = true
        mConsecutiveNormalTrackingFrames = 0
        supermarketSession?.appendScanEvent(
            level: "warning",
            event: "system_interruption_started",
            message: "Capture suspended without ending the scan",
            fields: ["reason": reason, "state": getStateString(state: mState)])

        // Keep the database open and preserve the CameraMobile origin. Only
        // the producers are paused, so no save/finalize or map boundary is
        // introduced by a temporary iOS interruption.
        session.pause()
        locationManager?.stopUpdatingLocation()
        rtabmap?.setPausedMapping(paused: true)
        rtabmap?.setPreserveCameraOrigin(enabled: true)
        rtabmap?.stopCamera()
        print("Capture suspended without ending scan: \(reason)")
    }

    @discardableResult
    private func resumeCaptureAfterSystemInterruption(resetTracking: Bool = false) -> Bool
    {
        guard UIApplication.shared.applicationState == .active,
              mSystemInterruptionInProgress,
              let previousState = mCaptureStateBeforeSystemInterruption else {
            return false
        }

        let shouldResetTracking = resetTracking || mSystemInterruptionRequiresTrackingReset
        let interruptionSeconds = Date().timeIntervalSince(mSystemInterruptionBeganAt ?? Date())
        let interruptionReason = mSystemInterruptionReason

        // Recreate CameraMobile with its saved origin before restarting the
        // RTAB-Map worker. triggerNewMap=false is essential: the next frame is
        // appended to the same trajectory instead of creating a fake segment.
        guard startCamera(resetTracking: shouldResetTracking) else {
            showToast(
                message: localized("The camera could not resume. The active scan remains open; return to the app to retry or use Stop to save it."),
                seconds: 5)
            return false
        }
        if previousState == .STATE_MAPPING {
            rtabmap?.setPausedMapping(paused: false, triggerNewMap: false)
            updateState(state: .STATE_MAPPING)
        }
        else {
            updateState(state: .STATE_CAMERA)
        }
        rtabmap?.setPreserveCameraOrigin(enabled: false)

        mSystemInterruptionInProgress = false
        mCaptureStateBeforeSystemInterruption = nil
        mSystemInterruptionRequiresTrackingReset = false
        mSystemInterruptionBeganAt = nil
        mSystemInterruptionReason = ""

        supermarketSession?.appendScanEvent(
            event: "system_interruption_ended",
            message: "Capture resumed on the same continuous trajectory",
            fields: [
                "reason": interruptionReason,
                "durationSeconds": String(format: "%.3f", interruptionSeconds),
                "resetTracking": shouldResetTracking ? "true" : "false"
            ])

        print(String(format: "Capture resumed after %.2fs (%@), resetTracking=%@",
                     interruptionSeconds, interruptionReason, shouldResetTracking ? "true" : "false"))
        showToast(
            message: shouldResetTracking ?
                localized("System interruption ended. Scanning resumed; move slowly until tracking stabilizes.") :
                localized("Scanning resumed automatically after a temporary interruption."),
            seconds: 4)
        return true
    }

    private func cancelAutomaticCaptureResume()
    {
        mSystemInterruptionInProgress = false
        mCaptureStateBeforeSystemInterruption = nil
        mSystemInterruptionRequiresTrackingReset = false
        mSystemInterruptionBeganAt = nil
        mSystemInterruptionReason = ""
    }
    
    @objc func appMovedToForeground() {
        print("appMovedToForeground()")
        // V1R4 §7.4: capture the clock correlation when the app returns
        // so the interruption gap is a bounded, explicit segment.
        recordClockCorrelation(reason: .didBecomeActive)
        updateDisplayFromDefaults()
        if !resumeCaptureAfterSystemInterruption() {
            updateState(state: mState)
        }
    }
    
    func setMeshRendering(viewMode: Int)
    {
        switch viewMode {
        case 0:
            self.rtabmap?.setMeshRendering(enabled: false, withTexture: false)
        case 1:
            self.rtabmap?.setMeshRendering(enabled: true, withTexture: false)
        default:
            self.rtabmap?.setMeshRendering(enabled: true, withTexture: true)
        }
        self.viewMode = viewMode
        updateState(state: mState)
    }
    
    func setGLCamera(type: Int)
    {
        cameraMode = type
        rtabmap?.setCamera(type: type);
    }
    
    @discardableResult
    func startCamera(resetTracking: Bool = true, runARSession: Bool = true) -> Bool
    {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: // The user has previously granted access to the camera.
                print("Start Camera")
                guard rtabmap?.startCamera() == true else {
                    print("Could not start native CameraMobile")
                    return false
                }
                let configuration = ARWorldTrackingConfiguration()
                // ESL capture reuses this ARSession. Keep continuous
                // autofocus explicit so close-range barcode work cannot
                // inherit a disabled camera configuration from another mode.
                configuration.isAutoFocusEnabled = true
                var message = ""
            	if(mState != .STATE_VISUALIZING_AND_MEASURING)
            	{
                	if(!UserDefaults.standard.bool(forKey: "LidarMode"))
                	{
       		        	message = "LiDAR is disabled (Settings->Mapping->LiDAR Mode = OFF), only tracked features will be mapped."
       		        	self.setMeshRendering(viewMode: 0)
        	    	}
                	else if !depthSupported
                	{
                    	message = "The device does not have a LiDAR, only tracked features will be mapped. A LiDAR is required for accurate 3D reconstruction."
                    	self.setMeshRendering(viewMode: 0)
                	}
                	else
                	{
                    	configuration.frameSemantics = .sceneDepth
                	}
            	}
                
                if runARSession {
                    let runOptions: ARSession.RunOptions = resetTracking ? [.resetSceneReconstruction, .resetTracking, .removeExistingAnchors] : []
                    session.run(configuration, options: runOptions)
                }
                
                switch mState {
                case .STATE_VISUALIZING_AND_MEASURING,
                    .STATE_VISUALIZING_CAMERA:
                    break // State should be already set
                default:
                    locationManager?.startUpdatingLocation()
                    updateState(state: .STATE_CAMERA)
                }
                
                if(!message.isEmpty)
                {
                    let alertController = UIAlertController(title: "Start Camera", message: message, preferredStyle: .alert)
                    let okAction = UIAlertAction(title: "OK", style: .default) { (action) in
                    }
                    alertController.addAction(okAction)
                    present(alertController, animated: true)
                }
                return true
            
            case .notDetermined: // The user has not yet been asked for camera access.
                AVCaptureDevice.requestAccess(for: .video) { granted in
                    if granted {
                        DispatchQueue.main.async {
                            self.startCamera()
                        }
                    }
                }
                return false
            
        default:
            let alertController = UIAlertController(title: "Camera Disabled", message: "Camera permission is required to start the camera. You can enable it in Settings.", preferredStyle: .alert)

            let settingsAction = UIAlertAction(title: "Settings", style: .default) { (action) in
                guard let settingsUrl = URL(string: UIApplication.openSettingsURLString) else {
                    return
                }
                if UIApplication.shared.canOpenURL(settingsUrl) {
                    UIApplication.shared.open(settingsUrl, completionHandler: { (success) in
                        print("Settings opened: \(success)") // Prints true
                    })
                }
            }
            alertController.addAction(settingsAction)
            
            let okAction = UIAlertAction(title: "Ignore", style: .default) { (action) in
            }
            alertController.addAction(okAction)
            
            present(alertController, animated: true)
            return false
        }
    }
    
    private func updateState(state: State)
    {
        print("State: \(state)")
        
        if(mState != state)
        {
            mState = state;
            resetNoTouchTimer(true)
            return
        }
        
        mState = state;

        var actionNewScanEnabled: Bool
        var actionNewDataRecording: Bool
        var actionSaveEnabled: Bool
        var actionResumeEnabled: Bool
        var actionExportEnabled: Bool
        var actionOptimizeEnabled: Bool
        var actionSettingsEnabled: Bool
        var actionMeasuringEnabled: Bool
        
        switch mState {
        case .STATE_CAMERA:
            libraryButton.isEnabled = false
            libraryButton.isHidden = false
            menuButton.isHidden = false
            viewButton.isHidden = false
            newScanButtonLarge.isHidden = true // WELCOME button
            recordButton.isHidden = false
            stopButton.isHidden = true
            closeVisualizationButton.isHidden = true
            stopCameraButton.isHidden = false
            stopMeasuringButton.isHidden = true
            exportOBJPLYButton.isHidden = true
            orthoDistanceSlider.isHidden = cameraMode != 3
            orthoGridSlider.isHidden = cameraMode != 3
            teleportButton.isHidden = true
            addMeasureButton.isHidden = true
            removeMeasureButton.isHidden = true
            measuringModeButton.isHidden = true
            // While capture is active, only the dedicated Stop button may end
            // or replace the current scan.
            actionNewScanEnabled = false
            actionNewDataRecording = false
            actionSaveEnabled = false
            actionResumeEnabled = false
            actionExportEnabled = false
            actionOptimizeEnabled = false
            actionSettingsEnabled = false
            actionMeasuringEnabled = false
        case .STATE_MAPPING:
            libraryButton.isEnabled = false
            libraryButton.isHidden = !mHudVisible
            menuButton.isHidden = !mHudVisible
            viewButton.isHidden = !mHudVisible
            newScanButtonLarge.isHidden = true // WELCOME button
            recordButton.isHidden = true
            stopButton.isHidden = false
            closeVisualizationButton.isHidden = true
            stopCameraButton.isHidden = true
            stopMeasuringButton.isHidden = true
            exportOBJPLYButton.isHidden = true
            orthoDistanceSlider.isHidden = cameraMode != 3 || !mHudVisible
            orthoGridSlider.isHidden = cameraMode != 3 || !mHudVisible
            teleportButton.isHidden = true
            addMeasureButton.isHidden = true
            removeMeasureButton.isHidden = true
            measuringModeButton.isHidden = true
            actionNewScanEnabled = !mDataRecording
            actionNewDataRecording = mDataRecording
            actionSaveEnabled = false
            actionResumeEnabled = false
            actionExportEnabled = false
            actionOptimizeEnabled = false
            actionSettingsEnabled = false
            actionMeasuringEnabled = false
        case .STATE_PROCESSING,
             .STATE_VISUALIZING_WHILE_LOADING,
             .STATE_VISUALIZING_CAMERA,
             .STATE_VISUALIZING_AND_MEASURING:
            libraryButton.isEnabled = false
            libraryButton.isHidden = !mHudVisible
            menuButton.isHidden = !mHudVisible
            viewButton.isHidden = !mHudVisible
            newScanButtonLarge.isHidden = true // WELCOME button
            recordButton.isHidden = true
            stopButton.isHidden = true
            closeVisualizationButton.isHidden = true
            stopCameraButton.isHidden = mState != .STATE_VISUALIZING_CAMERA
            stopMeasuringButton.isHidden = mState != .STATE_VISUALIZING_AND_MEASURING
            exportOBJPLYButton.isHidden = true
            orthoDistanceSlider.isHidden = cameraMode != 3 || mState == .STATE_PROCESSING
            orthoGridSlider.isHidden = cameraMode != 3 || mState == .STATE_PROCESSING
            teleportButton.isHidden = mState != .STATE_VISUALIZING_AND_MEASURING || cameraMode != 0
            addMeasureButton.isHidden = mState != .STATE_VISUALIZING_AND_MEASURING || cameraMode == 3
            removeMeasureButton.isHidden = mState != .STATE_VISUALIZING_AND_MEASURING || cameraMode == 3
            measuringModeButton.isHidden = true
            actionNewScanEnabled = false
            actionNewDataRecording = false
            actionSaveEnabled = false
            actionResumeEnabled = false
            actionExportEnabled = false
            actionOptimizeEnabled = false
            actionSettingsEnabled = false
            actionMeasuringEnabled = mState == .STATE_VISUALIZING_AND_MEASURING
        case .STATE_VISUALIZING:
            libraryButton.isEnabled = !databases.isEmpty
            libraryButton.isHidden = !mHudVisible
            menuButton.isHidden = !mHudVisible
            viewButton.isHidden = !mHudVisible
            newScanButtonLarge.isHidden = true // WELCOME button
            recordButton.isHidden = true
            stopButton.isHidden = true
            closeVisualizationButton.isHidden = !mHudVisible
            stopCameraButton.isHidden = true
            stopMeasuringButton.isHidden = true
            exportOBJPLYButton.isHidden = !mHudVisible
            orthoDistanceSlider.isHidden = cameraMode != 3 || !mHudVisible
            orthoGridSlider.isHidden = cameraMode != 3 || !mHudVisible
            teleportButton.isHidden = true
            addMeasureButton.isHidden = true
            removeMeasureButton.isHidden = true
            measuringModeButton.isHidden = !mHudVisible || self.visualizationType==0
            actionNewScanEnabled = true
            actionNewDataRecording = true
            actionSaveEnabled = mMapNodes>0
            actionResumeEnabled = mMapNodes>0
            actionExportEnabled = mMapNodes>0
            actionOptimizeEnabled = mMapNodes>0
            actionSettingsEnabled = true
            actionMeasuringEnabled = true
        default: // IDLE // WELCOME
            libraryButton.isEnabled = !databases.isEmpty
            libraryButton.isHidden = mState != .STATE_WELCOME && !mHudVisible
            menuButton.isHidden = mState != .STATE_WELCOME && !mHudVisible
            viewButton.isHidden = mState != .STATE_WELCOME && !mHudVisible
            newScanButtonLarge.isHidden = mState != .STATE_WELCOME
            recordButton.isHidden = true
            stopButton.isHidden = true
            closeVisualizationButton.isHidden = true
            stopCameraButton.isHidden = true
            stopMeasuringButton.isHidden = true
            exportOBJPLYButton.isHidden = true
            orthoDistanceSlider.isHidden = cameraMode != 3 || !mHudVisible
            orthoGridSlider.isHidden = cameraMode != 3 || !mHudVisible
            teleportButton.isHidden = true
            addMeasureButton.isHidden = true
            removeMeasureButton.isHidden = true
            measuringModeButton.isHidden = true
            actionNewScanEnabled = true
            actionNewDataRecording = true
            actionSaveEnabled = mState != .STATE_WELCOME && mMapNodes>0
            actionResumeEnabled = mState != .STATE_WELCOME && mMapNodes>0
            actionExportEnabled = mState != .STATE_WELCOME && mMapNodes>0
            actionOptimizeEnabled = mState != .STATE_WELCOME && mMapNodes>0
            actionSettingsEnabled = true
            actionMeasuringEnabled = false
        }

        let view = self.view as? GLKView
        if(mState != .STATE_MAPPING && mState != .STATE_CAMERA && mState != .STATE_VISUALIZING_CAMERA && mState != .STATE_VISUALIZING_AND_MEASURING)
        {
            self.isPaused = true
            view?.enableSetNeedsDisplay = true
            self.view.setNeedsDisplay()
        }
        else
        {
            view?.enableSetNeedsDisplay = false
            self.isPaused = false
        }
        
        if !self.isPaused {
            self.view.setNeedsDisplay()
        }
        
        // Update menus based on current state
        
        if(!exportOBJPLYButton.isHidden) {
            let format = UserDefaults.standard.string(
                forKey: "ExportPointCloudFormat") ?? "ply"
            var title = "Export "
            if (self.visualizationType == 2) {
                title += "OBJ";
            }
            else if (self.visualizationType == 1)
            {
                title += "PLY";
            }
            else
            {
                title += format == "las" ? "LAS" : format == "laz" ? "LAZ" : "PLY";
            }
            self.exportOBJPLYButton.setTitle(title, for: .normal)
        }
        
        // PointCloud menu
        let pointCloudMenu = UIMenu(title: localized("Point cloud..."), children: [
            UIAction(title: localized("Current Density"), handler: { _ in
                self.export(isOBJ: false, meshing: false, regenerateCloud: false, optimized: false, optimizedMaxPolygons: 0, previousState: self.mState)
            }),
            UIAction(title: localized("Max Density"), handler: { _ in
                self.export(isOBJ: false, meshing: false, regenerateCloud: true, optimized: false, optimizedMaxPolygons: 0, previousState: self.mState)
            })
        ])
        // Optimized Mesh menu
        let optimizedMeshMenu = UIMenu(title: localized("Optimized mesh..."), children: [
            UIAction(title: localized("Colored Mesh"), handler: { _ in
                self.exportMesh(isOBJ: false)
            }),
            UIAction(title: localized("Textured Mesh"), handler: { _ in
                self.exportMesh(isOBJ: true)
            })
        ])
        
        // Export menu
        let exportMenu = UIMenu(title: localized("Assemble..."), children: [pointCloudMenu, optimizedMeshMenu])
        
        // Optimized Mesh menu
        let optimizeAdvancedMenu = UIMenu(title: localized("Advanced..."), children: [
            UIAction(title: localized("Global Graph Optimization"), handler: { _ in
                self.optimization(approach: 0)
            }),
            UIAction(title: localized("Detect More Loop Closures"), handler: { _ in
                self.optimization(approach: 2)
            }),
            UIAction(title: localized("Adjust Colors (Fast)"), handler: { _ in
                self.optimization(approach: 5)
            }),
            UIAction(title: localized("Adjust Colors (Full)"), handler: { _ in
                self.optimization(approach: 6)
            }),
            UIAction(title: localized("Mesh Smoothing"), handler: { _ in
                self.optimization(approach: 7)
            }),
            UIAction(title: localized("Bundle Adjustment"), handler: { _ in
                self.optimization(approach: 1)
            }),
            UIAction(title: localized("Noise Filtering"), handler: { _ in
                self.optimization(approach: 4)
            })
        ])
        
        // Optimize menu
        let optimizeMenu = UIMenu(title: localized("Optimize..."), children: [
            UIAction(title: localized("Standard Optimization"), handler: { _ in
                self.optimization(approach: -1)
            }),
            optimizeAdvancedMenu])

        // Advanced menu
        let advancedMenu = UIMenu(title: localized("Advanced..."), children: [
            UIAction(
                title: localized("自由扫描建图（实验）"),
                image: UIImage(systemName: "viewfinder"),
                attributes: actionNewScanEnabled ? [] : .disabled,
                handler: { _ in
                    self.newScan(configuration: .freeMapping)
                }),
            UIAction(title: localized("New Data Recording"), image: UIImage(systemName: "plus.app"), attributes: actionNewDataRecording ? [] : .disabled, state: .off, handler: { _ in
                self.newScan(dataRecordingMode: true)
            })
        ])
        
        // Measuring menu
        let measuringMenu = UIMenu(title: localized("Measuring..."), image: UIImage(systemName: "ruler"), children: [
            UIAction(title: localized("Plane to Plane Mode"), image: measuringMode == 0 ? UIImage(systemName: "checkmark.circle") : UIImage(systemName: "circle"), handler: { _ in
                self.measuringMode = 0
                self.rtabmap?.setMeasuringMode(self.measuringMode)
                self.resetNoTouchTimer(true)
            }),
            UIAction(title: localized("Point to Point Mode"), image: measuringMode == 2 ? UIImage(systemName: "checkmark.circle") : UIImage(systemName: "circle"), handler: { _ in
                self.measuringMode = 2
                self.rtabmap?.setMeasuringMode(self.measuringMode)
                self.resetNoTouchTimer(true)
            }),
            UIAction(title: localized("Clear All Measures"), image: UIImage(systemName: "trash"), state: .off, handler: { _ in
                self.clearMeasures();
                self.resetNoTouchTimer(true)
            })
        ])
                
        var fileMenuChildren: [UIMenuElement] = []
        if supermarketNFCEnabled {
            fileMenuChildren.append(UIAction(title: localized("Read Price Tag NFC"), image: UIImage(systemName: "tag"), attributes: self.mState == .STATE_MAPPING ? [] : .disabled, state: .off, handler: { _ in
                self.readPriceTagNFC()
            }))
        }
        if(actionOptimizeEnabled) {
            fileMenuChildren.append(optimizeMenu)
        }
        else {
            fileMenuChildren.append(UIAction(title: localized("Optimize..."), attributes: .disabled, state: .off, handler: { _ in
            }))
        }
        if(actionExportEnabled) {
            fileMenuChildren.append(exportMenu)
        }
        else {
            fileMenuChildren.append(UIAction(title: localized("Assemble..."), attributes: .disabled, state: .off, handler: { _ in
            }))
        }
        fileMenuChildren.append(UIAction(title: localized("Save"), image: UIImage(systemName: "square.and.arrow.down"), attributes: actionSaveEnabled ? [] : .disabled, state: .off, handler: { _ in
            self.save()
        }))
        fileMenuChildren.append(UIAction(title: localized("Append Scan"), image: UIImage(systemName: "play.fill"), attributes: actionResumeEnabled ? [] : .disabled, state: .off, handler: { _ in
            self.resumeScan()
        }))
        if(actionMeasuringEnabled) {
            fileMenuChildren.append(measuringMenu)
        }
        else {
            fileMenuChildren.append(UIAction(title: localized("Measuring..."), image: UIImage(systemName: "ruler"), attributes: .disabled, state: .off, handler: { _ in
            }))
        }
        fileMenuChildren.append(advancedMenu)
        
        // Current production product entries are top-level and ordered by
        // operator priority. The legacy/free mapping tools remain under the
        // experimental File menu instead of competing with the full-phone
        // store workflow.
        let mobileOnlyPrimary = UIMenu(
            title: "",
            options: .displayInline,
            children: [
            UIAction(title: localized("开始门店扫描"), image: UIImage(systemName: "camera.viewfinder"), attributes: actionNewScanEnabled ? [] : .disabled, handler: { _ in
                self.presentMobileFlow(MobileMapLibraryViewController(
                    purpose: .selectForScan))
            }),
            UIAction(title: localized("门店地图"), image: UIImage(systemName: "map"), handler: { _ in
                self.presentMobileFlow(MobileMapLibraryViewController())
            }),
            UIAction(title: localized("处理历史扫描"), image: UIImage(systemName: "wand.and.stars"), handler: { _ in
                self.presentMobileFlow(MobileProcessingViewController())
            }),
            UIAction(title: localized("历史结果"), image: UIImage(systemName: "doc.text"), handler: { _ in
                self.presentMobileFlow(MobileResultViewController())
            })
        ])
        
        // File menu
        let fileMenu = UIMenu(
            title: localized("实验与兼容工具"),
            image: UIImage(systemName: "wrench.and.screwdriver"),
            children: fileMenuChildren)
        
        // Visibility menu
        let visibilityMenu = UIMenu(title: localized("Visibility..."), children: [
            UIAction(title: localized("Status"), image: statusShown ? UIImage(systemName: "checkmark.circle") : UIImage(systemName: "circle"), attributes: (self.mState != .STATE_WELCOME) ? [] : .disabled, handler: { _ in
                self.statusShown = !self.statusShown
                self.resetNoTouchTimer(true)
            }),
            UIAction(title: localized("Debug"), image: debugShown ? UIImage(systemName: "checkmark.circle") : UIImage(systemName: "circle"), attributes: (self.mState != .STATE_WELCOME) ? [] : .disabled, handler: { _ in
                self.debugShown = !self.debugShown
                self.resetNoTouchTimer(true)
            }),
            UIAction(title: localized("Odom Visible"), image: odomShown ? UIImage(systemName: "checkmark.circle") : UIImage(systemName: "circle"), attributes: (self.mState == .STATE_MAPPING || self.mState == .STATE_CAMERA || self.mState == .STATE_VISUALIZING_CAMERA || self.mState == .STATE_VISUALIZING_AND_MEASURING) ? [] : .disabled, handler: { _ in
                self.odomShown = !self.odomShown
                self.rtabmap?.setOdomCloudShown(shown: self.odomShown)
                self.resetNoTouchTimer(true)
            }),
            UIAction(title: localized("Graph Visible"), image: graphShown ? UIImage(systemName: "checkmark.circle") : UIImage(systemName: "circle"), attributes: (self.mState == .STATE_MAPPING || self.mState == .STATE_CAMERA || self.mState == .STATE_IDLE) ? [] : .disabled, handler: { _ in
                self.graphShown = !self.graphShown
                self.rtabmap?.setGraphVisible(visible: self.graphShown)
                self.resetNoTouchTimer(true)
            }),
            UIAction(title: localized("Grid Visible"), image: gridShown ? UIImage(systemName: "checkmark.circle") : UIImage(systemName: "circle"), handler: { _ in
                self.gridShown = !self.gridShown
                self.rtabmap?.setGridVisible(visible: self.gridShown)
                self.resetNoTouchTimer(true)
            }),
            UIAction(title: localized("Optimized Graph"), image: optimizedGraphShown ? UIImage(systemName: "checkmark.circle") : UIImage(systemName: "circle"), attributes: (self.mState == .STATE_IDLE) ? [] : .disabled, handler: { _ in
                self.optimizedGraphShown = !self.optimizedGraphShown
                self.rtabmap?.setGraphOptimization(enabled: self.optimizedGraphShown)
                self.resetNoTouchTimer(true)
            })
        ])
        
        let settingsMenu = UIMenu(title: localized("Settings"), options: .displayInline, children: [visibilityMenu,
            UIAction(title: localized("Supermarket Scan Settings"), image: UIImage(systemName: "slider.horizontal.3"), attributes: actionSettingsEnabled ? [] : .disabled, state: .off, handler: { _ in
                self.showSupermarketScanSettings()
            }),
            UIAction(title: localized("System Settings"), image: UIImage(systemName: "gearshape.2"), attributes: actionSettingsEnabled ? [] : .disabled, state: .off, handler: { _ in
                guard let settingsUrl = URL(string: UIApplication.openSettingsURLString) else {
                    return
                }

                if UIApplication.shared.canOpenURL(settingsUrl) {
                    UIApplication.shared.open(settingsUrl, completionHandler: { (success) in
                        print("Settings opened: \(success)") // Prints true
                    })
                }
            }),
            UIAction(title: localized("Restore All Default Settings"), attributes: actionSettingsEnabled ? [] : .disabled, state: .off, handler: { _ in
                
                let ac = UIAlertController(title: self.localized("Reset All Default Settings"), message: self.localized("Do you want to reset all settings to default?"), preferredStyle: .alert)
                ac.addAction(UIAlertAction(title: self.localized("Yes"), style: .default, handler: { _ in
                    let notificationCenter = NotificationCenter.default
                    notificationCenter.removeObserver(self, name: UserDefaults.didChangeNotification, object: nil)
                    UserDefaults.standard.reset()
                    self.registerSettingsBundle()
                    self.updateDisplayFromDefaults();
                    notificationCenter.addObserver(self, selector: #selector(self.defaultsChanged), name: UserDefaults.didChangeNotification, object: nil)
                }))
                ac.addAction(UIAlertAction(title: self.localized("No"), style: .cancel, handler: nil))
                self.present(ac, animated: true)
             })
        ])

        menuButton.menu = UIMenu(
            title: "", children: [mobileOnlyPrimary, fileMenu, settingsMenu])
        menuButton.addTarget(self, action: #selector(ViewController.menuOpened(_:)), for: .menuActionTriggered)
        
        // Camera menu
        let renderingMenu = UIMenu(title: "Rendering", options: .displayInline, children: [
            UIAction(title: "Texture/Color Blend", image: self.textureColorSeamsShown ? UIImage(systemName: "checkmark.circle") : UIImage(systemName: "circle"), attributes: self.mState == .STATE_VISUALIZING || self.mState == .STATE_VISUALIZING_CAMERA || self.mState == .STATE_VISUALIZING_AND_MEASURING || self.mState == .STATE_VISUALIZING_WHILE_LOADING ? [] : .disabled, handler: { _ in
                self.textureColorSeamsShown = !self.textureColorSeamsShown
                self.rtabmap?.setTextureColorSeamsHidden(hidden: !self.textureColorSeamsShown)
                self.resetNoTouchTimer(true)
            }),
            UIAction(title: "Wireframe", image: self.wireframeShown ? UIImage(systemName: "checkmark.circle") : UIImage(systemName: "circle"), handler: { _ in
                self.wireframeShown = !self.wireframeShown
                self.rtabmap?.setWireframe(enabled: self.wireframeShown)
                self.resetNoTouchTimer(true)
            }),
            UIAction(title: "Lighting", image: self.lightingShown ? UIImage(systemName: "checkmark.circle") : UIImage(systemName: "circle"), attributes: self.mState == .STATE_VISUALIZING || self.mState == .STATE_VISUALIZING_CAMERA || self.mState == .STATE_VISUALIZING_AND_MEASURING || self.mState == .STATE_VISUALIZING_WHILE_LOADING ? [] : .disabled, handler: { _ in
                self.lightingShown = !self.lightingShown
                self.rtabmap?.setLighting(enabled: self.lightingShown)
                self.resetNoTouchTimer(true)
            }),
            UIAction(title: "Backface", image: self.backfaceShown ? UIImage(systemName: "checkmark.circle") : UIImage(systemName: "circle"), handler: { _ in
                self.backfaceShown = !self.backfaceShown
                self.rtabmap?.setBackfaceCulling(enabled: !self.backfaceShown)
                self.resetNoTouchTimer(true)
            })
        ])
        
        let cameraMenu = UIMenu(title: "View", options: .displayInline, children: [
            UIAction(title: "First-P. View", image: cameraMode == 0 ? UIImage(systemName: "checkmark.circle") : UIImage(systemName: "circle"), attributes: (self.mState == .STATE_CAMERA || self.mState == .STATE_VISUALIZING || self.mState == .STATE_MAPPING || self.mState == .STATE_VISUALIZING_CAMERA || self.mState == .STATE_VISUALIZING_AND_MEASURING) ? [] : .disabled, handler: { _ in
                self.setGLCamera(type: 0)
                if(self.mState == .STATE_VISUALIZING)
                {
                    self.rtabmap?.setLocalizationMode(enabled: true)
                    self.rtabmap?.setPausedMapping(paused: false);
                    self.updateState(state: .STATE_VISUALIZING_CAMERA)
                    self.startCamera()
                }
                else
                {
                    self.resetNoTouchTimer(true)
                }
            }),
            UIAction(title: "Third-P. View", image: cameraMode == 1 ? UIImage(systemName: "checkmark.circle") : UIImage(systemName: "circle"), attributes: (self.mState != .STATE_VISUALIZING_AND_MEASURING) ? [] : .disabled, handler: { _ in
                self.setGLCamera(type: 1)
                self.resetNoTouchTimer(true)
            }),
            UIAction(title: "Top View", image: cameraMode == 2 ? UIImage(systemName: "checkmark.circle") : UIImage(systemName: "circle"), handler: { _ in
                self.setGLCamera(type: 2)
                self.resetNoTouchTimer(true)
            }),
            UIAction(title: "Ortho View", image: cameraMode == 3 ? UIImage(systemName: "checkmark.circle") : UIImage(systemName: "circle"), handler: { _ in
                self.setGLCamera(type: 3)
                self.resetNoTouchTimer(true)
            })
        ])
        
        let showCloudMeshActions = mState != .STATE_VISUALIZING && mState != .STATE_VISUALIZING_CAMERA && mState != .STATE_VISUALIZING_AND_MEASURING && mState != .STATE_PROCESSING && mState != .STATE_VISUALIZING_WHILE_LOADING
        let cloudMeshMenu = UIMenu(title: "CloudMesh", options: .displayInline, children: [
            UIAction(title: "Point Cloud", image: viewMode == 0 ? UIImage(systemName: "checkmark.circle") : UIImage(systemName: "circle"), attributes: showCloudMeshActions ? [] : .disabled, handler: { _ in
                self.setMeshRendering(viewMode: 0)
                self.resetNoTouchTimer(true)
            }),
            UIAction(title: "Mesh", image: viewMode == 1 ? UIImage(systemName: "checkmark.circle") : UIImage(systemName: "circle"), attributes: showCloudMeshActions ? [] : .disabled, handler: { _ in
                self.setMeshRendering(viewMode: 1)
                self.resetNoTouchTimer(true)
            }),
            UIAction(title: "Texture Mesh", image: viewMode == 2 ? UIImage(systemName: "checkmark.circle") : UIImage(systemName: "circle"), attributes: showCloudMeshActions ? [] : .disabled, handler: { _ in
                self.setMeshRendering(viewMode: 2)
                self.resetNoTouchTimer(true)
            })
        ])

        var viewMenuChildren: [UIMenuElement] = []
        viewMenuChildren.append(cameraMenu)
        viewMenuChildren.append(renderingMenu)
        viewMenuChildren.append(cloudMeshMenu)
        viewButton.menu = UIMenu(title: "", children: viewMenuChildren)
        viewButton.addTarget(self, action: #selector(ViewController.menuOpened(_:)), for: .menuActionTriggered)
    }
    
    @IBAction func menuOpened(_ sender:UIButton)
    {
        mMenuOpened = true;
    }
    
    func exportMesh(isOBJ: Bool)
    {
        let ac = UIAlertController(title: "Maximum Polygons", message: "\n\n\n\n\n\n\n\n\n\n", preferredStyle: .alert)
        ac.view.addSubview(maxPolygonsPickerView)
        maxPolygonsPickerView.selectRow(2, inComponent: 0, animated: false)
        ac.addAction(UIAlertAction(title: "OK", style: .default, handler: { _ in
            let pickerValue = self.maxPolygonsPickerData[self.maxPolygonsPickerView.selectedRow(inComponent: 0)]
            self.export(isOBJ: isOBJ, meshing: true, regenerateCloud: false, optimized: true, optimizedMaxPolygons: pickerValue*100000, previousState: self.mState);
        }))
        ac.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: nil))
        present(ac, animated: true)
    }
    
    func numberOfComponents(in pickerView: UIPickerView) -> Int {
        return 1
    }

    func pickerView(_ pickerView: UIPickerView, numberOfRowsInComponent component: Int) -> Int {
        return maxPolygonsPickerData.count
    }

    func pickerView(_ pickerView: UIPickerView, titleForRow row: Int, forComponent component: Int) -> String? {
        if(row == 0)
        {
            return "No Limit"
        }
        return "\(maxPolygonsPickerData[row])00 000"
    }
    
    // Auto-hide the home indicator to maximize immersion in AR experiences.
    override var prefersHomeIndicatorAutoHidden: Bool {
        return true
    }
    
    // Hide the status bar to maximize immersion in AR experiences.
    override var prefersStatusBarHidden: Bool {
        return !mHudVisible
    }

    private func resetSoftwarePoseStabilizer()
    {
        mARPoseCorrection = matrix_identity_float4x4
        mCapturePoseEpoch = 1
        pendingPoseEpochTransition = nil
        poseEpochTransitionSequence = 0
        shelfTrackingStateMachine = ShelfTrackingStateMachine()
        corridorHypothesisSequence = 0
        lastCorridorHypothesisNodeID = nil
        recentShelfTrackingDegradationCount = 0
        selectedShelfSegmentID = ""
        selectedShelfSide = "unknown"
        pendingShelfObservationWindow = nil
        shelfObservationWindowSequence = 0
        recentShelfObservationWindows.removeAll()
        recentShelfWindowRelativePoses.removeAll()
        shelfLoopEventSequence = 0
        lastShelfEvidenceResourcePolicyLevel = -1
        mLastAcceptedARPose = nil
        mLastAcceptedARTimestamp = nil
        mTrackingWasDegraded = true
        mConsecutiveNormalTrackingFrames = 0
        mLastTrackingGuidanceAt = 0
    }

    private func preparePoseEpochTransition(
        fromEpoch: UInt64,
        beforeFrameTimestamp: TimeInterval,
        afterFrameTimestamp: TimeInterval,
        transform: simd_float4x4,
        reason: String
    ) {
        guard activeScanConfiguration.workflowMode == .priorMapLocalized,
              let beforeNodeID = priorMapLastNodeBinding?.nodeId,
              beforeNodeID > 0,
              fromEpoch < UInt64(Int.max),
              mCapturePoseEpoch < UInt64(Int.max) else {
            supermarketSession?.appendScanEvent(
                level: "error",
                event: "pose_epoch_transition_identity_unavailable",
                message: "Pose epoch changed before an exact prior node could be bound",
                fields: ["reason": reason])
            return
        }
        let horizontal = PriorMapStageOneMath.arkitHorizontalPose(
            positionX: Double(transform.columns.3.x),
            positionZ: Double(transform.columns.3.z),
            forwardX: Double(-transform.columns.2.x),
            forwardZ: Double(-transform.columns.2.z))
        pendingPoseEpochTransition = PendingPoseEpochTransition(
            fromEpoch: Int(fromEpoch),
            toEpoch: Int(mCapturePoseEpoch),
            beforeFrameTimestamp: beforeFrameTimestamp,
            afterFrameTimestamp: afterFrameTimestamp,
            beforeNodeID: Int64(beforeNodeID),
            transform: ShelfEvidenceTransform(
                dxM: horizontal.xM,
                dyM: horizontal.yM,
                dyawRad: horizontal.yawRad),
            reason: reason)
    }

    private func persistPendingPoseEpochTransition(
        afterNodeID: Int64,
        scanSession: SupermarketScanSession,
        trackingSessionID: String
    ) {
        guard let pending = pendingPoseEpochTransition,
              afterNodeID > 0,
              afterNodeID != pending.beforeNodeID else { return }
        let sequence = poseEpochTransitionSequence + 1
        let record = PoseEpochTransitionRecord(
            format: PoseEpochTransitionRecord.formatName,
            version: ShelfLocalizationPolicy.contractVersion,
            trackingSessionID: trackingSessionID,
            sequence: sequence,
            fromEpoch: pending.fromEpoch,
            toEpoch: pending.toEpoch,
            beforeFrameTimestamp: pending.beforeFrameTimestamp,
            afterFrameTimestamp: pending.afterFrameTimestamp,
            beforeNodeID: pending.beforeNodeID,
            afterNodeID: afterNodeID,
            transform: pending.transform,
            bridgeEvidence: [],
            reason: pending.reason,
            writeWatermark: sequence)
        if scanSession.appendPoseEpochTransition(
            record,
            expectedTrackingSessionId: trackingSessionID) {
            poseEpochTransitionSequence = sequence
        }
        pendingPoseEpochTransition = nil
    }

    private func resetSupermarketScanQualityAdvisors()
    {
        mStructureCoverageAdvisor.reset()
        mLastStructureCoverageGuidanceAt = 0
        mLastStructureCoverageSummaryAt = 0
        mLastAdaptiveDetectionRateUpdateAt = 0
        mAdaptiveDetectionRateHz = 1.0
        mPendingAdaptiveDetectionRateHz = nil
        mPendingAdaptiveDetectionRateSince = 0
        mStructureCoverageAdvisor.setCurrentDetectionRateHz(mAdaptiveDetectionRateHz)
        mConsecutiveRejectedLoopClosures = 0
        mTotalLoopClosures = 0
        mReliableLoopClosures = 0
        mLastReliableLoopClosureDistance = 0
        mLastLoopHealthGuidanceAt = 0
        mLastNotifiedLoopClosureSignature = ""
        mLastMapCorrectionTranslationM = 0
        mLastMapCorrectionRotationDeg = 0
        mLastMapCorrectionDeltaTranslationM = 0
        mLastMapCorrectionDeltaRotationDeg = 0
        mMapCorrectionLock.lock()
        mMapToOdomCorrection = matrix_identity_float4x4
        mMapCorrectionLock.unlock()
    }

    private func updateAdaptiveStructureCapture(
        feedback: ScanStructureCoverageFeedback,
        frameTimestamp: TimeInterval
    )
    {
        guard feedback.processed else {
            return
        }
        if mLastStructureCoverageSummaryAt == 0 ||
           frameTimestamp - mLastStructureCoverageSummaryAt >= 10.0 {
            mLastStructureCoverageSummaryAt = frameTimestamp
            supermarketSession?.updateStructureCoverageSummary(
                mStructureCoverageAdvisor.summary())
        }
        let proposedRate = feedback.recommendedDetectionRateHz
        if abs(proposedRate - mAdaptiveDetectionRateHz) < 0.20 {
            mPendingAdaptiveDetectionRateHz = nil
            mPendingAdaptiveDetectionRateSince = 0
        }
        else if mPendingAdaptiveDetectionRateHz == nil
            || abs((mPendingAdaptiveDetectionRateHz ?? proposedRate) - proposedRate) >= 0.20 {
            mPendingAdaptiveDetectionRateHz = proposedRate
            mPendingAdaptiveDetectionRateSince = frameTimestamp
        }
        let dwellSeconds = proposedRate > mAdaptiveDetectionRateHz ? 8.0 : 12.0
        let pendingRateMatches = mPendingAdaptiveDetectionRateHz.map {
            abs($0 - proposedRate) < 0.20
        } ?? false
        if abs(proposedRate - mAdaptiveDetectionRateHz) >= 0.20,
           pendingRateMatches,
           frameTimestamp - mPendingAdaptiveDetectionRateSince >= dwellSeconds,
           (mLastAdaptiveDetectionRateUpdateAt == 0
            || frameTimestamp - mLastAdaptiveDetectionRateUpdateAt >= dwellSeconds) {
            mAdaptiveDetectionRateHz = proposedRate
            mLastAdaptiveDetectionRateUpdateAt = frameTimestamp
            mPendingAdaptiveDetectionRateHz = nil
            mPendingAdaptiveDetectionRateSince = 0
            mStructureCoverageAdvisor.setCurrentDetectionRateHz(proposedRate)
            rtabmap?.setMappingParameter(
                key: "Rtabmap/DetectionRate",
                value: String(format: "%.2f", proposedRate))
            supermarketSession?.appendScanEvent(
                event: "adaptive_capture_rate_changed",
                message: "RGB-D node rate adjusted from structural evidence novelty",
                fields: [
                    "detectionRateHz": String(format: "%.2f", proposedRate),
                    "newElevatedCells": "\(feedback.newElevatedCellCount)",
                    "newStableCells": "\(feedback.newlyStableCellCount)",
                    "newMultiViewCells": "\(feedback.newlyMultiViewCellCount)",
                    "floorCells": "\(feedback.currentFrameFloorCellCount)",
                    "elevatedCells": "\(feedback.currentFrameElevatedCellCount)"
                ])
        }

        if let guidance = feedback.guidance,
           frameTimestamp - mLastStructureCoverageGuidanceAt >= 6.0 {
            mLastStructureCoverageGuidanceAt = frameTimestamp
            supermarketSession?.appendScanEvent(
                event: "structure_coverage_guidance",
                message: guidance,
                fields: [
                    "validDepthSamples": "\(feedback.validDepthSampleCount)",
                    "newElevatedCells": "\(feedback.newElevatedCellCount)",
                    "newStableCells": "\(feedback.newlyStableCellCount)",
                    "newMultiViewCells": "\(feedback.newlyMultiViewCellCount)"
                ])
            DispatchQueue.main.async {
                self.showToast(message: guidance, seconds: 3)
            }
        }
    }

    private func rotationAngleDegrees(_ transform: simd_float4x4) -> Double
    {
        let trace = transform.columns.0.x + transform.columns.1.y + transform.columns.2.z
        let cosine = min(Float(1), max(Float(-1), (trace - 1) / 2))
        return Double(acos(cosine) * 180 / .pi)
    }

    private func makeRigidTransform(
        x: Float,
        y: Float,
        z: Float,
        qx: Float,
        qy: Float,
        qz: Float,
        qw: Float
    ) -> simd_float4x4
    {
        guard x.isFinite, y.isFinite, z.isFinite,
              qx.isFinite, qy.isFinite, qz.isFinite, qw.isFinite else {
            return matrix_identity_float4x4
        }
        let quaternionNorm = sqrt(qx*qx + qy*qy + qz*qz + qw*qw)
        guard quaternionNorm > 0.000001 else {
            return matrix_identity_float4x4
        }
        let quaternion = simd_quatf(
            ix: qx / quaternionNorm,
            iy: qy / quaternionNorm,
            iz: qz / quaternionNorm,
            r: qw / quaternionNorm)
        var transform = simd_float4x4(quaternion)
        transform.columns.3 = SIMD4<Float>(x, y, z, 1)
        return transform
    }

    @discardableResult
    private func updateMapToOdomCorrection(
        _ correction: simd_float4x4
    ) -> simd_float4x4
    {
        mMapCorrectionLock.lock()
        let previous = mMapToOdomCorrection
        mMapToOdomCorrection = correction
        mMapCorrectionLock.unlock()
        return previous
    }

    private func mapCorrectedPose(
        from odometryPose: simd_float4x4
    ) -> simd_float4x4
    {
        mMapCorrectionLock.lock()
        let correction = mMapToOdomCorrection
        mMapCorrectionLock.unlock()
        return simd_mul(correction, odometryPose)
    }

    private func currentMapToOdomCorrection() -> simd_float4x4
    {
        mMapCorrectionLock.lock()
        let correction = mMapToOdomCorrection
        mMapCorrectionLock.unlock()
        return correction
    }

    /// Return a pose that is safe to feed into the continuous RTAB-Map graph.
    /// ARKit still runs and every sensor pose is audited while frames rejected
    /// here simply do not create an unreliable map constraint.
    private func stabilizedMappingPose(
        for frame: ARFrame,
        trackingState: String
    ) -> simd_float4x4?
    {
        let rawFeatureCount = frame.rawFeaturePoints?.points.count ?? 0
        guard trackingState == "normal" else {
            mTrackingWasDegraded = true
            mConsecutiveNormalTrackingFrames = 0
            supermarketSession?.recordMappingFrameQuality(
                accepted: false,
                rejectionReason: "degraded_tracking",
                rawFeatureCount: rawFeatureCount)
            return nil
        }
        guard rawFeatureCount > 0 else {
            supermarketSession?.recordMappingFrameQuality(
                accepted: false,
                rejectionReason: "no_visual_features",
                rawFeatureCount: 0)
            return nil
        }

        var recoveredTrackingThisFrame = false
        if mTrackingWasDegraded {
            mConsecutiveNormalTrackingFrames += 1
            if mConsecutiveNormalTrackingFrames < mRequiredNormalFramesAfterTrackingRecovery {
                supermarketSession?.recordMappingFrameQuality(
                    accepted: false,
                    rejectionReason: "tracking_recovery",
                    rawFeatureCount: rawFeatureCount)
                return nil
            }
            mTrackingWasDegraded = false
            recoveredTrackingThisFrame = true
            supermarketSession?.appendScanEvent(
                event: "tracking_recovery_stabilized",
                message: "ARKit tracking remained normal long enough to resume mapping frames",
                fields: [
                    "normalFrames": "\(mConsecutiveNormalTrackingFrames)",
                    "poseEpoch": "\(mCapturePoseEpoch)",
                ])
        }

        let rawPose = frame.camera.transform
        let correctedPose = simd_mul(mARPoseCorrection, rawPose)
        var linearSpeed: Double?
        var angularSpeed: Double?
        if let previousPose = mLastAcceptedARPose,
           let previousTimestamp = mLastAcceptedARTimestamp {
            let elapsed = frame.timestamp - previousTimestamp
            if elapsed > 0 {
                let delta = simd_mul(simd_inverse(previousPose), correctedPose)
                let translation = SIMD3<Float>(
                    delta.columns.3.x,
                    delta.columns.3.y,
                    delta.columns.3.z)
                let distance = Double(simd_length(translation))
                let rotation = rotationAngleDegrees(delta)
                linearSpeed = distance / elapsed
                angularSpeed = rotation / elapsed

                // A recovered ARKit session may report `.normal` while its
                // world origin has moved. Do not bridge that raw epoch with a
                // large graph edge. Rebase the new raw epoch onto the last
                // accepted pose, reject this boundary frame, then resume from
                // subsequent relative motion.
                if recoveredTrackingThisFrame,
                   distance > 0.35 || rotation > 20.0 {
                    let previousEpoch = mCapturePoseEpoch
                    mARPoseCorrection = simd_mul(
                        previousPose,
                        simd_inverse(rawPose))
                    mCapturePoseEpoch &+= 1
                    preparePoseEpochTransition(
                        fromEpoch: previousEpoch,
                        beforeFrameTimestamp: previousTimestamp,
                        afterFrameTimestamp: frame.timestamp,
                        transform: mARPoseCorrection,
                        reason: "tracking_recovery_epoch_rebase")
                    supermarketSession?.recordMappingFrameQuality(
                        accepted: false,
                        rejectionReason: "tracking_recovery_epoch_rebase",
                        rawFeatureCount: rawFeatureCount,
                        linearSpeedMps: linearSpeed,
                        angularSpeedDegPerSecond: angularSpeed)
                    supermarketSession?.appendScanEvent(
                        level: "warning",
                        event: "tracking_recovery_epoch_rebased",
                        message: "A recovered ARKit coordinate epoch was rebased without creating a discontinuous graph edge",
                        fields: [
                            "distanceM": String(format: "%.4f", distance),
                            "rotationDeg": String(format: "%.3f", rotation),
                            "elapsedSeconds": String(format: "%.4f", elapsed),
                            "poseEpoch": "\(mCapturePoseEpoch)",
                        ])
                    return nil
                }

                // A walking scanner cannot move this far between submitted
                // frames. Treat it as an ARKit coordinate jump, keep the last
                // continuous pose and rebase subsequent raw poses into that
                // coordinate system. PC loop closures can then correct drift
                // without inheriting a false neighbor edge.
                // Callback gaps must not widen this gate to the former
                // 6 m / 360° allowance. A capped continuity interval keeps a
                // delayed callback from turning a raw coordinate reset into a
                // plausible long-distance human motion.
                let continuityInterval = min(elapsed, 0.25)
                let translationLimit = max(0.10, continuityInterval * 3.0)
                let rotationLimit = max(12.0, continuityInterval * 180.0)
                let impossibleLinearSpeed = (linearSpeed ?? 0) > 3.0 && distance > 0.08
                let impossibleAngularSpeed = (angularSpeed ?? 0) > 180.0 && rotation > 12.0
                if distance > translationLimit
                    || rotation > rotationLimit
                    || impossibleLinearSpeed
                    || impossibleAngularSpeed {
                    let previousEpoch = mCapturePoseEpoch
                    mARPoseCorrection = simd_mul(previousPose, simd_inverse(rawPose))
                    mCapturePoseEpoch &+= 1
                    preparePoseEpochTransition(
                        fromEpoch: previousEpoch,
                        beforeFrameTimestamp: previousTimestamp,
                        afterFrameTimestamp: frame.timestamp,
                        transform: mARPoseCorrection,
                        reason: "arkit_world_rebuild")
                    supermarketSession?.recordMappingFrameQuality(
                        accepted: false,
                        rejectionReason: "pose_discontinuity",
                        rawFeatureCount: rawFeatureCount,
                        linearSpeedMps: linearSpeed,
                        angularSpeedDegPerSecond: angularSpeed)
                    supermarketSession?.appendScanEvent(
                        level: "warning",
                        event: "pose_discontinuity_compensated",
                        message: "An implausible ARKit pose jump was removed from the map trajectory",
                        fields: [
                            "distanceM": String(format: "%.4f", distance),
                            "rotationDeg": String(format: "%.3f", rotation),
                            "elapsedSeconds": String(format: "%.4f", elapsed),
                            "linearSpeedMps": String(format: "%.3f", linearSpeed ?? 0),
                            "angularSpeedDegPerSecond": String(format: "%.2f", angularSpeed ?? 0),
                            "translationLimitM": String(format: "%.3f", translationLimit),
                            "rotationLimitDeg": String(format: "%.2f", rotationLimit),
                            "poseEpoch": "\(mCapturePoseEpoch)",
                        ])
                    return nil
                }
            }
        }

        mLastAcceptedARPose = correctedPose
        mLastAcceptedARTimestamp = frame.timestamp
        supermarketSession?.recordMappingFrameQuality(
            accepted: true,
            rawFeatureCount: rawFeatureCount,
            linearSpeedMps: linearSpeed,
            angularSpeedDegPerSecond: angularSpeed)
        return correctedPose
    }

    //This is called when a new frame has been updated.
    func session(_ session: ARSession, didUpdate frame: ARFrame)
    {
        // ARSession can still deliver a queued frame after pause(). Do not let
        // that stale frame race with CameraMobile shutdown/recreation.
        guard !mSystemInterruptionInProgress else {
            return
        }

        var status = ""
        var accept = false
        var trackingStateLabel = "unknown"
        
        switch frame.camera.trackingState {
        case .normal:
            accept = true
            trackingStateLabel = "normal"
        case .notAvailable:
            status = "Tracking not available"
            trackingStateLabel = "notAvailable"
        case .limited(.excessiveMotion):
            accept = true
            status = "Please Slow Your Movement"
            trackingStateLabel = "limited.excessiveMotion"
        case .limited(.insufficientFeatures):
            accept = true
            status = "Avoid Featureless Surfaces"
            trackingStateLabel = "limited.insufficientFeatures"
        case .limited(.initializing):
            status = "Initializing"
            trackingStateLabel = "limited.initializing"
        case .limited(.relocalizing):
            status = "Relocalizing"
            trackingStateLabel = "limited.relocalizing"
        default:
            status = "Unknown tracking state"
        }
        
        mLastLightEstimate = frame.lightEstimate?.ambientIntensity
        
        if !status.isEmpty,
           let lastLightEstimate = mLastLightEstimate,
           lastLightEstimate < 100,
           accept {
            status = "Camera Is Occluded Or Lighting Is Too Dark"
        }

        var acceptedMappingPose: simd_float4x4?
        if let rotation = UIApplication.shared.windows.first?.windowScene?.interfaceOrientation
        {
            if mState == .STATE_MAPPING && trackingStateLabel != mLastLoggedTrackingState {
                let level = trackingStateLabel == "normal" ? "info" : "warning"
                supermarketSession?.appendScanEvent(
                    level: level,
                    event: "tracking_state_changed",
                    message: "ARKit tracking state changed",
                    fields: ["from": mLastLoggedTrackingState.isEmpty ? "unknown" : mLastLoggedTrackingState, "to": trackingStateLabel])
                mLastLoggedTrackingState = trackingStateLabel
            }
            if mState == .STATE_MAPPING && !mDataRecording {
                if let correctedPose = stabilizedMappingPose(
                    for: frame,
                    trackingState: trackingStateLabel) {
                    acceptedMappingPose = correctedPose
                    supermarketSession?.updateSensorPose(
                        timestamp: frame.timestamp,
                        matrixColumnMajor: [
                            correctedPose[0,0], correctedPose[0,1], correctedPose[0,2], correctedPose[0,3],
                            correctedPose[1,0], correctedPose[1,1], correctedPose[1,2], correctedPose[1,3],
                            correctedPose[2,0], correctedPose[2,1], correctedPose[2,2], correctedPose[2,3],
                            correctedPose[3,0], correctedPose[3,1], correctedPose[3,2], correctedPose[3,3]
                        ],
                        trackingState: trackingStateLabel,
                        acceptedForLocation: true)
                    // Coverage is a map-frame world grid. Reproject depth with
                    // RTAB-Map's latest map→odom correction so cells observed
                    // before and after a loop closure remain aligned. The
                    // continuous odometry pose below intentionally stays
                    // uncorrected to avoid applying the graph correction twice.
                    let coverageMapPose = mapCorrectedPose(from: correctedPose)
                    let coverageFeedback = mStructureCoverageAdvisor.evaluate(
                        frame: frame,
                        correctedPose: coverageMapPose,
                        thermalState: currentThermalStateText())
                    updateAdaptiveStructureCapture(
                        feedback: coverageFeedback,
                        frameTimestamp: frame.timestamp)
                    if rtabmap?.postOdometryEvent(
                        frame: frame,
                        orientation: rotation,
                        viewport: self.view.frame.size,
                        poseOverride: correctedPose) == true {
                        mOdometrySubmissionCount &+= 1
                    }
                    // Prior-map localization, ESL depth/rays and the native
                    // graph consume the exact same accepted transform. They
                    // must never re-read a raw ARKit epoch jump from `frame`.
                    updatePriorMapLocalization(
                        frame: frame,
                        trackingState: trackingStateLabel,
                        poseOverride: correctedPose)
                    updatePriceTagCapture(
                        frame: frame,
                        trackingState: trackingStateLabel,
                        cameraTransform: correctedPose)
                }
                else {
                    let rawPose = frame.camera.transform
                    supermarketSession?.updateSensorPose(
                        timestamp: frame.timestamp,
                        matrixColumnMajor: [
                            rawPose[0,0], rawPose[0,1], rawPose[0,2], rawPose[0,3],
                            rawPose[1,0], rawPose[1,1], rawPose[1,2], rawPose[1,3],
                            rawPose[2,0], rawPose[2,1], rawPose[2,2], rawPose[2,3],
                            rawPose[3,0], rawPose[3,1], rawPose[3,2], rawPose[3,3]
                        ],
                        trackingState: trackingStateLabel,
                        acceptedForLocation: false)
                }
            }
            else if accept {
                let pose = frame.camera.transform
                supermarketSession?.updateSensorPose(
                    timestamp: frame.timestamp,
                    matrixColumnMajor: [
                        pose[0,0], pose[0,1], pose[0,2], pose[0,3],
                        pose[1,0], pose[1,1], pose[1,2], pose[1,3],
                        pose[2,0], pose[2,1], pose[2,2], pose[2,3],
                        pose[3,0], pose[3,1], pose[3,2], pose[3,3]
                    ],
                    trackingState: trackingStateLabel)
                if rtabmap?.postOdometryEvent(
                    frame: frame,
                    orientation: rotation,
                    viewport: self.view.frame.size) == true {
                    mOdometrySubmissionCount &+= 1
                }
            }
        }

        // V1R4 §7.1: bind every newly created RTAB-Map node to the ARKit
        // frame timestamp, device uptime and UTC so post-processing can
        // map DB node stamps to UTC without assuming they are UTC.
        let latestNodeBinding = mState == .STATE_MAPPING
            ? rtabmap?.latestNodeBinding(frameTimestamp: frame.timestamp)
            : nil
        if let recorder = clockRecorder,
           let binding = latestNodeBinding,
           binding.nodeId != lastClockBoundNodeID {
            do {
                try recorder.recordNodeBinding(
                    nodeID: binding.nodeId,
                    nodeStamp: binding.nodeStamp,
                    sampledFrameTimestamp: binding.nodeTimebaseFrameTimestamp,
                    systemUptime: ProcessInfo.processInfo.systemUptime,
                    utcUnixSeconds: Date().timeIntervalSince1970,
                    timezoneID: TimeZone.current.identifier,
                    utcOffsetSeconds: TimeZone.current.secondsFromGMT())
                // Advance only after the append succeeded. A failed write
                // must not make a missing node look durably recorded.
                lastClockBoundNodeID = binding.nodeId
            } catch {
                recordClockSidecarFailure(error)
            }
        }
        if let acceptedMappingPose,
           let binding = latestNodeBinding {
            resolvePendingManualPriorMapPoseIfReady(
                frameTimestamp: frame.timestamp,
                acceptedTransform: acceptedMappingPose,
                nodeBinding: binding)
        }
        
        if !status.isEmpty {
            let now = Date().timeIntervalSince1970
            if now - mLastTrackingGuidanceAt >= 2.0 {
                mLastTrackingGuidanceAt = now
                DispatchQueue.main.async {
                    self.showToast(message: status, seconds: 2)
                }
            }
        }
    }

    func sessionWasInterrupted(_ session: ARSession)
    {
        DispatchQueue.main.async {
            self.suspendCaptureForSystemInterruption(reason: "ARSession interrupted")
        }
    }

    func sessionInterruptionEnded(_ session: ARSession)
    {
        DispatchQueue.main.async {
            _ = self.resumeCaptureAfterSystemInterruption()
        }
    }
    
    // This is called when a session fails.
    func session(_ session: ARSession, didFailWithError error: Error) {
        // Present an error message to the user.
        guard error is ARError else { return }
        let errorWithInfo = error as NSError
        let messages = [
            errorWithInfo.localizedDescription,
            errorWithInfo.localizedFailureReason,
            errorWithInfo.localizedRecoverySuggestion
        ]
        let errorMessage = messages.compactMap({ $0 }).joined(separator: "\n")
        DispatchQueue.main.async {
            if self.mState == .STATE_MAPPING ||
               self.mState == .STATE_CAMERA ||
               self.mSystemInterruptionInProgress {
                // A failed ARSession is an Apple-level interruption, not a
                // user request to end capture. Preserve the database/camera
                // origin and retry automatically with a tracking reset.
                self.mSystemInterruptionRequiresTrackingReset = true
                self.suspendCaptureForSystemInterruption(reason: "ARSession failed: \(errorMessage)")
                if UIApplication.shared.applicationState == .active {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        _ = self.resumeCaptureAfterSystemInterruption(resetTracking: true)
                    }
                }
                return
            }

            // Present an alert informing about the error that has occurred.
            let alertController = UIAlertController(title: "The AR session failed.", message: errorMessage, preferredStyle: .alert)
            let restartAction = UIAlertAction(title: "Restart Session", style: .default) { _ in
                alertController.dismiss(animated: true, completion: nil)
                if let configuration = self.session.configuration {
                    self.session.run(configuration, options: [.resetSceneReconstruction, .resetTracking, .removeExistingAnchors])
                }
            }
            alertController.addAction(restartAction)
            self.present(alertController, animated: true, completion: nil)
        }
    }
    
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation])
    {
        guard let location = locations.last else {
            print("Ignoring empty Core Location update")
            if let scanSession = supermarketSession {
                _ = scanSession.appendScanEventIfSessionActive(
                    expectedTrackingSessionId: scanSession.trackingSessionId,
                    level: "warning",
                    event: "gps_empty_update_ignored",
                    message: "Core Location delivered an empty location batch; capture continued")
            }
            return
        }
        mLastKnownLocation = location
        rtabmap?.setGPS(location: location)
    }
    
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error)
    {
        print(error)
    }
    
    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus)
    {
        print(status.rawValue)
        if(status == .notDetermined)
        {
            locationManager?.requestWhenInUseAuthorization()
        }
        if(status == .denied)
        {
            let alertController = UIAlertController(title: "GPS Disabled", message: "GPS option is enabled (Settings->Mapping...) but localization is denied for this App. To enable location for this App, go in Settings->Privacy->Location.", preferredStyle: .alert)

            let settingsAction = UIAlertAction(title: "Settings", style: .default) { (action) in
                self.locationManager = nil
                self.mLastKnownLocation = nil
                guard let settingsUrl = URL(string: UIApplication.openSettingsURLString) else {
                    return
                }

                if UIApplication.shared.canOpenURL(settingsUrl) {
                    UIApplication.shared.open(settingsUrl, completionHandler: { (success) in
                        print("Settings opened: \(success)") // Prints true
                    })
                }
            }
            alertController.addAction(settingsAction)
            
            let okAction = UIAlertAction(title: "Turn Off GPS", style: .default) { (action) in
                UserDefaults.standard.setValue(false, forKey: "SaveGPS")
                self.updateDisplayFromDefaults()
            }
            alertController.addAction(okAction)
            
            present(alertController, animated: true)
        }
        else if(status == .authorizedWhenInUse)
        {
            if let locationManager {
                if(locationManager.accuracyAuthorization == .reducedAccuracy) {
                    let alertController = UIAlertController(title: "GPS Reduced Accuracy", message: "Your location settings for this App is set to reduced accuracy. We recommend to use high accuracy.", preferredStyle: .alert)

                    let settingsAction = UIAlertAction(title: "Settings", style: .default) { (action) in
                        guard let settingsUrl = URL(string: UIApplication.openSettingsURLString) else {
                            return
                        }

                        if UIApplication.shared.canOpenURL(settingsUrl) {
                            UIApplication.shared.open(settingsUrl, completionHandler: { (success) in
                                print("Settings opened: \(success)") // Prints true
                            })
                        }
                    }
                    alertController.addAction(settingsAction)
                    
                    let okAction = UIAlertAction(title: "Ignore", style: .default) { (action) in
                    }
                    alertController.addAction(okAction)
                    
                    present(alertController, animated: true)
                }
            }
        }
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
        // The screen shouldn't dim during AR experiences.
        UIApplication.shared.isIdleTimerDisabled = true
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        finishStartup()
    }
    
    var statusBarOrientation: UIInterfaceOrientation? {
        get {
            if let orientation = viewIfLoaded?.window?.windowScene?.interfaceOrientation {
                return orientation
            }
            return UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first(where: { $0.activationState == .foregroundActive })?
                .interfaceOrientation
        }
    }
        
    deinit {
        priceTagVisionScanner.cancel()
        _ = priceTagCaptureCoordinator.cancel(reason: "view_controller_deinit")
        EAGLContext.setCurrent(context)
        rtabmap = nil
        context = nil
        EAGLContext.setCurrent(nil)
    }
    
    var firstTouch: UITouch?
    var secondTouch: UITouch?
    
    override func touchesBegan(_ touches: Set<UITouch>,
                 with event: UIEvent?)
    {
        super.touchesBegan(touches, with: event)
        for touch in touches {
            if (firstTouch == nil) {
                firstTouch = touch
                let pose = touch.location(in: self.view)
                let normalizedX = pose.x / self.view.bounds.size.width;
                let normalizedY = pose.y / self.view.bounds.size.height;
                rtabmap?.onTouchEvent(touch_count: 1, event: 0, x0: Float(normalizedX), y0: Float(normalizedY), x1: 0.0, y1: 0.0);
            }
            else if (firstTouch != nil && secondTouch == nil)
            {
                secondTouch = touch
                if let pose0 = firstTouch?.location(in: self.view)
                {
                    if let pose1 = secondTouch?.location(in: self.view)
                    {
                        let normalizedX0 = pose0.x / self.view.bounds.size.width;
                        let normalizedY0 = pose0.y / self.view.bounds.size.height;
                        let normalizedX1 = pose1.x / self.view.bounds.size.width;
                        let normalizedY1 = pose1.y / self.view.bounds.size.height;
                        rtabmap?.onTouchEvent(touch_count: 2, event: 5, x0: Float(normalizedX0), y0: Float(normalizedY0), x1: Float(normalizedX1), y1: Float(normalizedY1));
                    }
                }
            }
        }
        if self.isPaused {
            self.view.setNeedsDisplay()
        }
    }
    
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesMoved(touches, with: event)
        var firstTouchUsed = false
        var secondTouchUsed = false
        for touch in touches {
            if(touch == firstTouch)
            {
                firstTouchUsed = true
            }
            else if(touch == secondTouch)
            {
                secondTouchUsed = true
            }
        }
        if(secondTouch != nil)
        {
            if(firstTouchUsed || secondTouchUsed)
            {
                if let pose0 = firstTouch?.location(in: self.view)
                {
                    if let pose1 = secondTouch?.location(in: self.view)
                    {
                        let normalizedX0 = pose0.x / self.view.bounds.size.width;
                        let normalizedY0 = pose0.y / self.view.bounds.size.height;
                        let normalizedX1 = pose1.x / self.view.bounds.size.width;
                        let normalizedY1 = pose1.y / self.view.bounds.size.height;
                        rtabmap?.onTouchEvent(touch_count: 2, event: 2, x0: Float(normalizedX0), y0: Float(normalizedY0), x1: Float(normalizedX1), y1: Float(normalizedY1));
                    }
                }
            }
        }
        else if(firstTouchUsed)
        {
            if let pose = firstTouch?.location(in: self.view)
            {
                let normalizedX = pose.x / self.view.bounds.size.width;
                let normalizedY = pose.y / self.view.bounds.size.height;
                rtabmap?.onTouchEvent(touch_count: 1, event: 2, x0: Float(normalizedX), y0: Float(normalizedY), x1: 0.0, y1: 0.0);
            }
        }
        if self.isPaused {
            self.view.setNeedsDisplay()
        }
    }

    
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        for touch in touches {
            if(touch == firstTouch)
            {
                firstTouch = nil
            }
            else if(touch == secondTouch)
            {
                secondTouch = nil
            }
        }
        if (firstTouch == nil && secondTouch != nil)
        {
            firstTouch = secondTouch
            secondTouch = nil
        }
        if let firstTouch, secondTouch == nil
        {
            let pose = firstTouch.location(in: self.view)
            let normalizedX = pose.x / self.view.bounds.size.width;
            let normalizedY = pose.y / self.view.bounds.size.height;
            rtabmap?.onTouchEvent(touch_count: 1, event: 0, x0: Float(normalizedX), y0: Float(normalizedY), x1: 0.0, y1: 0.0);
        }
        if self.isPaused {
            self.view.setNeedsDisplay()
        }
    }
    
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        for touch in touches {
            if(touch == firstTouch)
            {
                firstTouch = nil;
            }
            else if(touch == secondTouch)
            {
                secondTouch = nil;
            }
        }
        if self.isPaused {
            self.view.setNeedsDisplay()
        }
    }
    
    @IBAction func doubleTapped(_ gestureRecognizer: UITapGestureRecognizer) {
        if gestureRecognizer.state == UIGestureRecognizer.State.recognized
        {
            let pose = gestureRecognizer.location(in: gestureRecognizer.view)
            let normalizedX = pose.x / self.view.bounds.size.width;
            let normalizedY = pose.y / self.view.bounds.size.height;
            rtabmap?.onTouchEvent(touch_count: 3, event: 0, x0: Float(normalizedX), y0: Float(normalizedY), x1: 0.0, y1: 0.0);
        
            
            if self.isPaused {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    self.view.setNeedsDisplay()
                }
            }
        }
    }
    
    @IBAction func singleTapped(_ gestureRecognizer: UITapGestureRecognizer) {
        if gestureRecognizer.state == .recognized
        {
            resetNoTouchTimer(!mHudVisible)
            
            if self.isPaused {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    self.view.setNeedsDisplay()
                }
            }
        }
    }
    
    func registerSettingsBundle(){
        let appDefaults: [String:Any] = [
            supermarketStreamingMemoryNodesKey: supermarketDefaultStreamingMemoryNodes
        ]
        UserDefaults.standard.register(defaults: appDefaults)
    }
    
    func updateDisplayFromDefaults()
    {
        //Get the defaults
        let defaults = UserDefaults.standard
        applySupermarketSettings()
        guard let nativeHost = rtabmap else {
            return
        }

        // Settings.bundle normally registers every value before this method
        // runs. Keep conservative fallbacks here so an incomplete upgrade,
        // damaged preference domain or missing bundle entry cannot crash the
        // app during cold start. The supermarket production overrides are
        // applied below after these compatibility values.
        func stringSetting(_ key: String, fallback: String) -> String {
            if let value = defaults.string(forKey: key), !value.isEmpty {
                return value
            }
            NSLog(
                "MarketScanner setting %@ missing or invalid; using fallback %@",
                key,
                fallback)
            return fallback
        }
 
        //let appendMode = defaults.bool(forKey: "AppendMode")
        
        // update preference
        nativeHost.setOnlineBlending(enabled: defaults.bool(forKey: "Blending"));
        nativeHost.setNodesFiltering(enabled: defaults.bool(forKey: "NodesFiltering"));
        nativeHost.setFullResolution(enabled: defaults.bool(forKey: "HDMode"));
        nativeHost.setSmoothing(enabled: defaults.bool(forKey: "Smoothing"));
        nativeHost.setDepthBleedingError(value: defaults.float(forKey: "DepthBleedingError"));
        nativeHost.setAppendMode(enabled: defaults.bool(forKey: "AppendMode"));
        nativeHost.setUpstreamRelocalizationAccThr(value: defaults.float(forKey: "UpstreamRelocalizationFilteringAccThr"));
        nativeHost.setExportPointCloudFormat(
            format: stringSetting("ExportPointCloudFormat", fallback: "ply"));
        
        mTimeThr = (stringSetting("TimeLimit", fallback: "0") as NSString).integerValue
        mMaxFeatures = (stringSetting(
            "MaxFeaturesExtractedLoopClosure",
            fallback: "400") as NSString).integerValue
        
        // Mapping parameters
        nativeHost.setMappingParameter(key: "Rtabmap/DetectionRate", value: stringSetting("UpdateRate", fallback: "1"));
        nativeHost.setMappingParameter(key: "Rtabmap/TimeThr", value: stringSetting("TimeLimit", fallback: "0"));
        nativeHost.setMappingParameter(key: "Rtabmap/MemoryThr", value: stringSetting("MemoryLimit", fallback: "0"));
        let maximumMotionSpeed = stringSetting("MaximumMotionSpeed", fallback: "0")
        nativeHost.setMappingParameter(key: "RGBD/LinearSpeedUpdate", value: maximumMotionSpeed);
        let motionSpeed = (maximumMotionSpeed as NSString).floatValue/2.0;
        nativeHost.setMappingParameter(key: "RGBD/AngularSpeedUpdate", value: NSString(format: "%.2f", motionSpeed) as String);
        nativeHost.setMappingParameter(key: "Rtabmap/LoopThr", value: stringSetting("LoopClosureThreshold", fallback: "0.11"));
        nativeHost.setMappingParameter(key: "Mem/RehearsalSimilarity", value: stringSetting("SimilarityThreshold", fallback: "0.3"));
        nativeHost.setMappingParameter(key: "Kp/MaxFeatures", value: stringSetting("MaxFeaturesExtractedVocabulary", fallback: "400"));
        nativeHost.setMappingParameter(key: "Vis/MaxFeatures", value: stringSetting("MaxFeaturesExtractedLoopClosure", fallback: "400"));
        nativeHost.setMappingParameter(key: "Vis/MinInliers", value: stringSetting("MinInliers", fallback: "25"));
        nativeHost.setMappingParameter(key: "RGBD/OptimizeMaxError", value: stringSetting("MaxOptimizationError", fallback: "2"));
        let featureType = stringSetting("FeatureType", fallback: "6")
        nativeHost.setMappingParameter(key: "Kp/DetectorStrategy", value: featureType);
        nativeHost.setMappingParameter(key: "Vis/FeatureType", value: featureType);
        nativeHost.setMappingParameter(key: "Mem/NotLinkedNodesKept", value: defaults.bool(forKey: "SaveAllFramesInDatabase") ? "true" : "false");
        nativeHost.setMappingParameter(key: "RGBD/OptimizeFromGraphEnd", value: defaults.bool(forKey: "OptimizationfromGraphEnd") ? "true" : "false");
        nativeHost.setMappingParameter(key: "RGBD/MaxOdomCacheSize", value: stringSetting("MaximumOdometryCacheSize", fallback: "10"));
        nativeHost.setMappingParameter(key: "Optimizer/Strategy", value: stringSetting("GraphOptimizer", fallback: "2"));
        nativeHost.setMappingParameter(key: "RGBD/ProximityBySpace", value: stringSetting("ProximityDetection", fallback: "true"));
        applyStreamingMappingSettings()

        let markerDetection = defaults.integer(forKey: "ArUcoMarkerDetection")
        // Continuous supermarket scanning currently uses the software-only
        // profile. Do not let an old Settings value silently add AprilTag,
        // ArUco or landmark constraints to this graph.
        if(markerDetection == -1 || !mDataRecording)
        {
            nativeHost.setMappingParameter(key: "RGBD/MarkerDetection", value: "false");
        }
        else
        {
            nativeHost.setMappingParameter(key: "RGBD/MarkerDetection", value: "true");
            nativeHost.setMappingParameter(key: "Marker/Dictionary", value: stringSetting("ArUcoMarkerDetection", fallback: "0"));
            nativeHost.setMappingParameter(key: "Marker/CornerRefinementMethod", value: (markerDetection > 16 ? "3":"0"));
            nativeHost.setMappingParameter(key: "Marker/MaxDepthError", value: stringSetting("MarkerDepthErrorEstimation", fallback: "0"));
            nativeHost.setMappingParameter(key: "Marker/MaxRange", value: stringSetting("MarkerMaxRange", fallback: "0"));
            if let val = NumberFormatter().number(
                from: stringSetting("MarkerSize", fallback: "0"))?.doubleValue
            {
                nativeHost.setMappingParameter(key: "Marker/Length", value: String(format: "%f", val/100.0))
            }
            else{
                nativeHost.setMappingParameter(key: "Marker/Length", value: "0")
            }
        }

        // Rendering
        nativeHost.setCloudDensityLevel(value: defaults.integer(forKey: "PointCloudDensity"));
        nativeHost.setMaxCloudDepth(value: defaults.float(forKey: "MaxDepth"));
        nativeHost.setMinCloudDepth(value: defaults.float(forKey: "MinDepth"));
        nativeHost.setDepthConfidence(value: defaults.integer(forKey: "DepthConfidence"));
        nativeHost.setPointSize(value: defaults.float(forKey: "PointSize"));
        nativeHost.setMeshAngleTolerance(value: defaults.float(forKey: "MeshAngleTolerance"));
        nativeHost.setMeshTriangleSize(value: defaults.integer(forKey: "MeshTriangleSize"));
        nativeHost.setMeshDecimationFactor(value: defaults.float(forKey: "MeshDecimationFactor"));
        let bgColor = defaults.float(forKey: "BackgroundColor");
        nativeHost.setBackgroundColor(gray: bgColor);
        
        DispatchQueue.main.async {
            self.statusLabel.textColor = bgColor>=0.6 ? UIColor(white: 0.0, alpha: 1) : UIColor(white: 1.0, alpha: 1)
        }
    
        nativeHost.setClusterRatio(value: defaults.float(forKey: "NoiseFilteringRatio"));
        nativeHost.setMaxGainRadius(value: defaults.float(forKey: "ColorCorrectionRadius"));
        nativeHost.setRenderingTextureDecimation(value: defaults.integer(forKey: "TextureResolution"));
        
        nativeHost.setMetricSystem(defaults.integer(forKey: "MeasuringUnits") == 0);
        nativeHost.setMeasuringTextSize(defaults.float(forKey: "MeasuringTextSize"));
        
        if(locationManager != nil && !defaults.bool(forKey: "SaveGPS"))
        {
            locationManager?.stopUpdatingLocation()
            locationManager = nil
            mLastKnownLocation = nil
        }
        else if(locationManager == nil && defaults.bool(forKey: "SaveGPS"))
        {
            locationManager = CLLocationManager()
            locationManager?.desiredAccuracy = kCLLocationAccuracyBestForNavigation
            locationManager?.delegate = self
        }
    }
    
    func resumeScan()
    {
        if(mState == State.STATE_VISUALIZING)
        {
            closeVisualization()
            rtabmap?.postExportation(visualize: false)
        }
        
        if(!mDataRecording) {
            let alertController = UIAlertController(title: "Append Mode", message: "The camera preview will not be aligned to map on start, move to a previously scanned area, then push Record. When a loop closure is detected, new scans will be appended to map.", preferredStyle: .alert)
            
            let okAction = UIAlertAction(title: "OK", style: .default) { (action) in
            }
            alertController.addAction(okAction)
            
            present(alertController, animated: true)
        }
        
        setGLCamera(type: 0);
        startCamera();
    }

    private func presentNewScanModePicker()
    {
        guard mState != .STATE_MAPPING else {
            showToast(
                message: localized("A scan is in progress. Use the Stop button before starting another scan."),
                seconds: 4)
            return
        }
        // Select from the lightweight registry before loading a package.
        // This avoids validating an arbitrary first map and then forcing the
        // operator to wait again before choosing the intended store.
        presentMobileFlow(MobileMapLibraryViewController(
            purpose: .selectForScan))
    }

    private func preparePriorMapLocalization(
        configuration: PriorMapScanConfiguration,
        preparedPackage: PriorMapPackage? = nil,
        preparedLocalizer: PriorMapStageOneLocalizer? = nil
    ) -> Bool {
        clearPriorMapLocalization()
        activeScanConfiguration = configuration
        supermarketSession?.configureScan(configuration)
        guard configuration.workflowMode == .priorMapLocalized else {
            return true
        }
        guard configuration.isReadyToStart else {
            showToast(
                message: localized("The prior-map setup is incomplete. No scan was started and existing data is safe."),
                seconds: 5)
            activeScanConfiguration = .freeMapping
            supermarketSession?.configureScan(.freeMapping)
            return false
        }
        guard let directory = configuration.packageDirectory,
              let floorId = configuration.floorId,
              let initialPose = configuration.initialMapPose else {
            showToast(
                message: localized("The prior map, floor or starting position is missing. No scan was started."),
                seconds: 5)
            activeScanConfiguration = .freeMapping
            supermarketSession?.configureScan(.freeMapping)
            return false
        }
        do {
            // The canonical mobile setup performs the expensive immutable
            // snapshot read and full package validation on a background
            // queue. Reuse that exact typed package here; legacy/internal
            // callers without a prepared package retain the fail-closed
            // loader fallback.
            let package = try preparedPackage
                ?? PriorMapPackage.load(directory: directory)
            guard package.manifest.priorMapId == configuration.priorMapId,
                  package.packageSha256 == configuration.priorMapSha256,
                  package.manifest.storeID == configuration.storeID,
                  package.directory.standardizedFileURL
                    == directory.standardizedFileURL,
                  package.manifest.floors.contains(where: { $0.id == floorId }) else {
                throw NSError(
                    domain: "PriorMap",
                    code: 4,
                    userInfo: [NSLocalizedDescriptionKey: localized("The selected prior-map identity or floor no longer matches the setup.")])
            }
            // The canonical mobile-only path constructs the matcher/localizer
            // on the workflow background queue and installs it here. Legacy
            // callers retain the synchronous fallback.
            priorMapLocalizer = try preparedLocalizer
                ?? PriorMapStageOneLocalizer(
                    package: package,
                    floorId: floorId,
                    initialMapPose: initialPose)
            activePriorMapPackage = package
            guard let overlay = PriorMapLiveMapView(
                    package: package,
                    floorId: floorId) else {
                throw NSError(
                    domain: "PriorMap",
                    code: 5,
                    userInfo: [NSLocalizedDescriptionKey: localized(
                        "The selected floor is unavailable for the live map overlay.")])
            }
            overlay.translatesAutoresizingMaskIntoConstraints = false
            overlay.confirmButton.addTarget(
                self,
                action: #selector(confirmPriorMapPosition),
                for: .touchUpInside)
            overlay.reselectButton.addTarget(
                self,
                action: #selector(reselectPriorMapPosition),
                for: .touchUpInside)
            overlay.scanPriceTagButton.addTarget(
                self,
                action: #selector(scanPriorMapPriceTag),
                for: .touchUpInside)
            view.addSubview(overlay)
            NSLayoutConstraint.activate([
                overlay.trailingAnchor.constraint(
                    equalTo: view.safeAreaLayoutGuide.trailingAnchor,
                    constant: -12),
                overlay.topAnchor.constraint(
                    equalTo: view.safeAreaLayoutGuide.topAnchor,
                    constant: 12),
                overlay.widthAnchor.constraint(equalToConstant: 290),
            ])
            priorMapOverlay = overlay
            priorMapEvidenceWriteWarningShown = false
            priorMapNodeTimebaseUnavailableNoticeAt = nil
            priorMapGeneration = UUID()
            priorMapUpdateGate.reset()
            return true
        }
        catch {
            showToast(
                message: String(
                    format: localized("The prior map could not be opened: %@. No scan was started and existing data is safe."),
                    error.localizedDescription),
                seconds: 6)
            activeScanConfiguration = .freeMapping
            supermarketSession?.configureScan(.freeMapping)
            clearPriorMapLocalization()
            return false
        }
    }

    private func clearPriorMapLocalization()
    {
        cancelPendingManualPriorMapPoseRequest(reason: "prior_map_unloaded")
        cancelPriceTagCapture(
            reason: "prior_map_unloaded",
            userMessage: nil)
        // F-02: persist the terminal Recovery completion before unbinding.
        // Teardown must never be a fire-and-forget cancel: the lifecycle
        // record is written first, confirmed, and only then is the localizer
        // released.
        if let session = supermarketSession {
            persistTerminalRecoveryEvidence(
                reason: .mapUnloaded,
                scanSession: session)
        }
        let localizerToCancel = priorMapLocalizer
        priorMapGeneration = UUID()
        priorMapLocalizer = nil
        activePriorMapPackage = nil
        priorMapLatestUpdate = nil
        priorMapEvidenceWriteWarningShown = false
        priorMapNodeTimebaseUnavailableNoticeAt = nil
        priorMapLastNodeBinding = nil
        priorMapUpdateGate.reset()
        if let localizerToCancel {
            priorMapQueue.async {
                // Defensive: the episode was already cancelled and drained by
                // persistTerminalRecoveryEvidence, so this returns nil unless
                // a never-persisted episode somehow outlived the teardown.
                _ = localizerToCancel.cancelRecovery(
                    reason: .mapUnloaded,
                    now: ProcessInfo.processInfo.systemUptime)
            }
        }
        priceTagVisionScanner.cancel()
        priorMapAlignmentSnapshots.reset()
        let overlay = priorMapOverlay
        priorMapOverlay = nil
        if Thread.isMainThread {
            overlay?.removeFromSuperview()
        }
        else {
            DispatchQueue.main.async {
                overlay?.removeFromSuperview()
            }
        }
    }

    /// F-02: persists every terminal Recovery completion as lifecycle
    /// evidence before the localizer is unbound. Ordering inside the serial
    /// queue is strict: finish Recovery, build the record, write required
    /// evidence, confirm, and only then may callers clean up the localizer.
    /// Returns false when any required write failed (fail closed).
    @discardableResult
    private func persistTerminalRecoveryEvidence(
        reason: PriorMapRecoveryCancellationReason?,
        scanSession: SupermarketScanSession
    ) -> Bool {
        guard scanSession.scanConfiguration.workflowMode
                == .priorMapLocalized else {
            return true
        }
        // P7R6: the transaction runs inside priorMapQueue.sync below; a
        // re-entrant call from the queue itself would deadlock, so
        // wrong-queue teardown calls fail closed instead of hanging.
        dispatchPrecondition(condition: .notOnQueue(priorMapQueue))
        let trackingSessionId = scanSession.trackingSessionId
        var result = RecoveryLifecyclePersistenceResult(
            attemptedEpisodeIds: [],
            persistedEpisodeIds: [],
            failedEpisodeId: nil,
            failureReason: nil,
            allPersisted: true)
        priorMapQueue.sync {
            guard let localizer = self.priorMapLocalizer else { return }
            result = self.runRecoveryLifecyclePersistence(
                localizer: localizer,
                scanSession: scanSession,
                trackingSessionId: trackingSessionId,
                cancellationReason: reason,
                now: ProcessInfo.processInfo.systemUptime,
                allowDuringFinalization: true)
        }
        reportCoordinatorLevelRecoveryFailure(result, scanSession: scanSession)
        return result.allPersisted
    }

    /// P7R6: runs one teardown-to-disk Recovery evidence transaction through
    /// the Foundation-only peek/ack coordinator. Must already be executing on
    /// `priorMapQueue`; the coordinator itself holds no locks.
    private func runRecoveryLifecyclePersistence(
        localizer: PriorMapStageOneLocalizer,
        scanSession: SupermarketScanSession,
        trackingSessionId: String,
        cancellationReason: PriorMapRecoveryCancellationReason?,
        now: TimeInterval,
        allowDuringFinalization: Bool = false
    ) -> RecoveryLifecyclePersistenceResult {
        dispatchPrecondition(condition: .onQueue(priorMapQueue))
        let coordinator = RecoveryLifecyclePersistenceCoordinator(
            source: localizer,
            writer: scanSession,
            trackingSessionId: trackingSessionId,
            priorMapId: scanSession.scanConfiguration.priorMapId,
            priorMapSha256: scanSession.scanConfiguration.priorMapSha256,
            floorId: scanSession.scanConfiguration.floorId,
            allowDuringFinalization: allowDuringFinalization,
            persistedEvidenceSnapshot: {
                try scanSession.persistedRecoveryLifecycleSnapshot(
                    expectedTrackingSessionId: trackingSessionId)
            })
        return coordinator.persistTerminalEvidence(
            cancellationReason: cancellationReason,
            now: now)
    }

    /// Coordinator-level failures (evidence snapshot unreadable, duplicated
    /// persisted episodes, byte conflicts, missing identity) are not seen by
    /// the session writer, so they must still mark the session ineligible.
    /// `durable_append_failed` is excluded because the writer already
    /// recorded that failure with its own reason.
    private func reportCoordinatorLevelRecoveryFailure(
        _ result: RecoveryLifecyclePersistenceResult,
        scanSession: SupermarketScanSession
    ) {
        guard !result.allPersisted,
              let failureReason = result.failureReason,
              failureReason != "durable_append_failed" else {
            return
        }
        scanSession.recordRecoveryPersistenceFailure(failureReason)
    }

    private func presentLocalizationEvidenceWriteFailure(_ failedFiles: [String]) {
        let fileList = failedFiles.isEmpty
            ? localized("required localization sidecars")
            : failedFiles.joined(separator: ", ")
        priorMapOverlay?.showEvidenceWriteFailure(
            localized("辅助定位证据写入失败；本次扫描不能标记为可处理完成。")
                + " \(fileList)")
        if !priorMapEvidenceWriteWarningShown {
            priorMapEvidenceWriteWarningShown = true
            showToast(
                message: localized("Localization evidence could not be saved. Raw RTAB-Map recording continues, but this scan cannot be finalized for prior-map processing."),
                seconds: 7,
                replacingCurrent: true)
        }
    }

    /// Frozen degradation order: retain the full 24-candidate evidence first,
    /// then reduce to 12, and only under the next resource-pressure level
    /// reduce observation frequency. Raw RTAB-Map capture is never throttled
    /// by this diagnostic/constraint sidecar policy.
    private func shelfEvidenceResourcePolicy()
        -> (level: Int, candidateLimit: Int, nodeStride: Int) {
        let level = max(
            mStreamingThermalPolicyLevel,
            mStreamingMemoryPressureLevel)
        if level <= 0 { return (0, 24, 1) }
        if level == 1 { return (1, 12, 1) }
        if level == 2 { return (2, 12, 2) }
        return (3, 12, 4)
    }

    private func auditShelfEvidenceResourcePolicyIfNeeded(
        scanSession: SupermarketScanSession
    ) {
        let policy = shelfEvidenceResourcePolicy()
        guard policy.level != lastShelfEvidenceResourcePolicyLevel else {
            return
        }
        lastShelfEvidenceResourcePolicyLevel = policy.level
        scanSession.appendScanEvent(
            level: policy.level == 0 ? "info" : "warning",
            event: "shelf_evidence_resource_policy",
            message: "Shelf evidence resource policy changed without changing raw capture",
            fields: [
                "policy_level": String(policy.level),
                "candidate_limit": String(policy.candidateLimit),
                "accepted_node_stride": String(policy.nodeStride),
                "order": "24_to_12_then_frequency",
            ])
    }

    private func clearSelectedShelfEvidence() {
        selectedShelfSegmentID = ""
        selectedShelfSide = "unknown"
    }

    @discardableResult
    private func persistCorridorHypotheses(
        update: PriorMapLocalizationUpdate,
        binding: RTABMapNodeBindingSnapshot,
        scanSession: SupermarketScanSession,
        trackingSessionID: String,
        epoch: Int,
        component: Int64
    ) -> Bool {
        let nodeID = Int64(binding.nodeId)
        if lastCorridorHypothesisNodeID == nodeID { return true }
        let policy = shelfEvidenceResourcePolicy()
        let limitedCandidates = Array(update.roadCandidates.prefix(
            min(
                ShelfLocalizationPolicy.maximumCorridorHypotheses,
                policy.candidateLimit)))
        var hypotheses: [CorridorHypothesisEvidence] = limitedCandidates.map {
            candidate in
            return CorridorHypothesisEvidence(
                corridorID: candidate.edgeId,
                distanceScore: candidate.distanceScore,
                structureBasinScore: candidate.structureBasinScore,
                topologyReachable: candidate.topologyReachable,
                score: candidate.combinedScore)
        }
        hypotheses.sort { lhs, rhs in
            if lhs.score == rhs.score {
                return lhs.corridorID < rhs.corridorID
            }
            return lhs.score > rhs.score
        }
        let relativeMargin: Double
        if hypotheses.count >= 2 {
            relativeMargin = max(
                0,
                (hypotheses[0].score - hypotheses[1].score)
                    / max(abs(hypotheses[0].score), 1.0e-9))
        } else {
            relativeMargin = hypotheses.isEmpty ? 0 : 1
        }
        if update.trackingState == "normal" {
            recentShelfTrackingDegradationCount = max(
                0, recentShelfTrackingDegradationCount - 1)
        } else {
            recentShelfTrackingDegradationCount = min(
                100, recentShelfTrackingDegradationCount + 1)
        }
        let distanceSinceLoop = Double(max(
            0, mCurrentDistanceTravelled - mLastReliableLoopClosureDistance))
        let decision = shelfTrackingStateMachine.update(
            hypotheses: hypotheses,
            distanceSinceReliableLoopM: distanceSinceLoop,
            recentTrackingDegradationCount:
                recentShelfTrackingDegradationCount)
        let sequence = corridorHypothesisSequence + 1
        let crossSigma = max(
            0.10, update.roadCandidates.first?.distanceM ?? 3.0)
        let record = CorridorHypothesesRecord(
            format: CorridorHypothesesRecord.formatName,
            version: ShelfLocalizationPolicy.contractVersion,
            trackingSessionID: trackingSessionID,
            sequence: sequence,
            nodeID: nodeID,
            nodeTimestamp: binding.nodeStamp,
            nodeMapID: Int(binding.nodeMapId),
            epoch: epoch,
            component: component,
            hypotheses: hypotheses,
            top1Top2Margin: relativeMargin,
            trackingState: decision.state,
            selectedCorridorID: decision.selectedCorridorID ?? "",
            selectedShelfSegmentID: selectedShelfSegmentID,
            selectedShelfSide: selectedShelfSide,
            lowConfidenceReasons: decision.lowConfidenceReasons,
            penetrationAudit: ShelfPenetrationAudit(
                nodeInsideShelfCount: update.shelfNodePenetrationCount,
                segmentCrossingCount: update.shelfSegmentCrossingCount),
            covariance: ShelfLocalizationCovariance(
                alongM: max(0.35, distanceSinceLoop * 0.08),
                crossM: crossSigma,
                yawRad: max(0.03, abs(update.correctionYawDeg) * .pi / 180.0)),
            writeWatermark: sequence)
        let succeeded = scanSession.appendCorridorHypotheses(
            record,
            expectedTrackingSessionId: trackingSessionID)
        if succeeded {
            corridorHypothesisSequence = sequence
            lastCorridorHypothesisNodeID = nodeID
            DispatchQueue.main.async { [weak self] in
                self?.priorMapOverlay?.updateShelfTrackingDecision(decision)
            }
        }
        return succeeded
    }

    @discardableResult
    private func consumeShelfObservationWindow(
        update: PriorMapLocalizationUpdate,
        binding: RTABMapNodeBindingSnapshot,
        localizer: PriorMapStageOneLocalizer,
        scanSession: SupermarketScanSession,
        trackingSessionID: String,
        epoch: Int,
        component: Int64
    ) -> Bool {
        let policy = shelfEvidenceResourcePolicy()
        guard Int64(binding.nodeId) % Int64(policy.nodeStride) == 0 else {
            // A skipped evidence tick has no current shelf geometry authority.
            // Keep the bounded pending window, but never publish its previous
            // shelf/side as if it described this accepted node.
            clearSelectedShelfEvidence()
            return true
        }
        guard let package = activePriorMapPackage,
              !package.distanceFieldSha256.isEmpty else {
            clearSelectedShelfEvidence()
            return false
        }
        let candidates = localizer.nearbyShelfIdentityCandidates(
            limit: min(
                ShelfLocalizationPolicy.maximumShelfCandidates,
                policy.candidateLimit),
            radiusM: 6.0)
        guard let top = candidates.first,
              let segment = package.shelfSegments.first(where: {
                $0.shelfSegmentID == top.shelfSegmentId
                    && $0.floorID == activeScanConfiguration.floorId
              }),
              segment.frontNormal.count == 2,
              segment.backNormal.count == 2 else {
            pendingShelfObservationWindow = nil
            clearSelectedShelfEvidence()
            return true
        }
        let toPhoneX = update.estimatedPose.xM - top.nearestXM
        let toPhoneY = update.estimatedPose.yM - top.nearestYM
        let onFront = toPhoneX * segment.frontNormal[0]
            + toPhoneY * segment.frontNormal[1] >= 0
        let side = onFront ? "right" : "left"
        let rawNormal = onFront ? segment.frontNormal : segment.backNormal
        let normalLength = hypot(rawNormal[0], rawNormal[1])
        guard normalLength > 0 else {
            clearSelectedShelfEvidence()
            return false
        }
        let normal = ShelfFaceNormal(
            x: rawNormal[0] / normalLength,
            y: rawNormal[1] / normalLength)
        let nodeID = Int64(binding.nodeId)
        guard update.estimatedPose.xM.isFinite,
              update.estimatedPose.yM.isFinite,
              update.estimatedPose.yawRad.isFinite else {
            pendingShelfObservationWindow = nil
            clearSelectedShelfEvidence()
            return true
        }
        selectedShelfSegmentID = top.shelfSegmentId
        selectedShelfSide = side
        // The prior-map queue can observe the same native binding on more than
        // one 1-2 Hz localization tick. That is one accepted node, not a new
        // sample and not a reason to discard the window accumulated so far.
        if let pending = pendingShelfObservationWindow,
           pending.epoch == epoch,
           pending.component == component,
           nodeID == pending.endNodeID {
            return true
        }
        let phonePose = update.estimatedPose
        if var pending = pendingShelfObservationWindow,
           pending.shelfSegmentID == top.shelfSegmentId,
           pending.side == side,
           pending.epoch == epoch,
           pending.component == component,
           nodeID > pending.endNodeID,
           nodeID - pending.endNodeID <= 8 {
            pending.endNodeID = nodeID
            pending.endTimestamp = binding.nodeStamp
            pending.sampleCount += 1
            pending.maximumCoverageAngleRad = max(
                pending.maximumCoverageAngleRad,
                update.structureCoverageAngleRad)
            // Window contract counts affected accepted-node samples, not raw
            // depth points, so the dominant-dynamic ratio has one stable
            // denominator across devices and depth resolutions.
            pending.dynamicRejectionCount +=
                update.dynamicStructureRejectionCount > 0 ? 1 : 0
            pending.geometryResidualsM.append(
                contentsOf: top.geometryResidualsM)
            pending.geometryInlierCount += top.geometryInlierCount
            pending.phonePoseXSum += phonePose.xM
            pending.phonePoseYSum += phonePose.yM
            pending.phonePoseSinYawSum += sin(phonePose.yawRad)
            pending.phonePoseCosYawSum += cos(phonePose.yawRad)
            pending.phonePoseSampleCount += 1
            pendingShelfObservationWindow = pending
        } else {
            pendingShelfObservationWindow = PendingShelfObservationWindow(
                shelfSegmentID: top.shelfSegmentId,
                side: side,
                faceNormal: normal,
                epoch: epoch,
                component: component,
                startNodeID: nodeID,
                startTimestamp: binding.nodeStamp,
                endNodeID: nodeID,
                endTimestamp: binding.nodeStamp,
                sampleCount: 1,
                maximumCoverageAngleRad: update.structureCoverageAngleRad,
                dynamicRejectionCount:
                    update.dynamicStructureRejectionCount > 0 ? 1 : 0,
                geometryResidualsM: top.geometryResidualsM,
                geometryInlierCount: top.geometryInlierCount,
                phonePoseXSum: phonePose.xM,
                phonePoseYSum: phonePose.yM,
                phonePoseSinYawSum: sin(phonePose.yawRad),
                phonePoseCosYawSum: cos(phonePose.yawRad),
                phonePoseSampleCount: 1)
        }
        guard let completed = pendingShelfObservationWindow,
              completed.sampleCount >= 5,
              completed.endTimestamp - completed.startTimestamp >= 1.0 else {
            return true
        }
        let sequence = shelfObservationWindowSequence + 1
        let evidenceCandidates = candidates.map {
            ShelfCandidateEvidence(
                shelfSegmentID: $0.shelfSegmentId,
                score: $0.geometryScore)
        }
        let orderedGeometryResiduals = completed.geometryResidualsM.sorted()
        guard orderedGeometryResiduals.count >= 12 else {
            pendingShelfObservationWindow = nil
            return true
        }
        let geometryMedian = orderedGeometryResiduals[
            orderedGeometryResiduals.count / 2]
        let geometryMaximum = orderedGeometryResiduals.last ?? geometryMedian
        let geometryInlierRatio = Double(completed.geometryInlierCount)
            / Double(orderedGeometryResiduals.count)
        let record = ShelfObservationWindowRecord(
            format: ShelfObservationWindowRecord.formatName,
            version: ShelfLocalizationPolicy.contractVersion,
            trackingSessionID: trackingSessionID,
            sequence: sequence,
            windowID: String(format: "sow-%06d", sequence),
            nodeRange: [completed.startNodeID, completed.endNodeID],
            timeRange: [completed.startTimestamp, completed.endTimestamp],
            epoch: completed.epoch,
            component: completed.component,
            side: completed.side,
            faceNormalMap: completed.faceNormal,
            shelfCandidates: evidenceCandidates,
            observationNodeCount: completed.sampleCount,
            geometry: ShelfWindowGeometryEvidence(
                sampleCount: orderedGeometryResiduals.count,
                inlierCount: completed.geometryInlierCount,
                inlierRatio: geometryInlierRatio,
                residualMedianM: geometryMedian,
                residualMaximumM: geometryMaximum),
            coverageAngleRad: completed.maximumCoverageAngleRad,
            endcapVisible: top.longitudinalFraction <= 0.1
                || top.longitudinalFraction >= 0.9,
            dynamicRejectionCount: completed.dynamicRejectionCount,
            priorMapSHA256: package.packageSha256,
            distanceFieldSHA256: package.distanceFieldSha256,
            writeWatermark: sequence)
        let succeeded = scanSession.appendShelfObservationWindow(
            record,
            expectedTrackingSessionId: trackingSessionID)
        pendingShelfObservationWindow = nil
        if succeeded {
            shelfObservationWindowSequence = sequence
            let phonePoseCount = Double(max(1, completed.phonePoseSampleCount))
            let meanPhoneX = completed.phonePoseXSum / phonePoseCount
            let meanPhoneY = completed.phonePoseYSum / phonePoseCount
            let meanPhoneYaw = atan2(
                completed.phonePoseSinYawSum,
                completed.phonePoseCosYawSum)
            let shelfYaw = atan2(
                segment.longitudinalAxis[1], segment.longitudinalAxis[0])
            let shelfCenterX = (segment.longitudinalStartM[0]
                + segment.longitudinalEndM[0]) / 2.0
            let shelfCenterY = (segment.longitudinalStartM[1]
                + segment.longitudinalEndM[1]) / 2.0
            let deltaX = meanPhoneX - shelfCenterX
            let deltaY = meanPhoneY - shelfCenterY
            let outwardNormal = completed.side == "right"
                ? segment.frontNormal : segment.backNormal
            let canonicalReferenceYaw = shelfYaw
                + (completed.side == "right" ? 0 : .pi)
            recentShelfWindowRelativePoses[record.windowID] =
                ShelfPhoneRelativePose(
                    dxM: deltaX * segment.longitudinalAxis[0]
                        + deltaY * segment.longitudinalAxis[1],
                    dyM: deltaX * outwardNormal[0]
                        + deltaY * outwardNormal[1],
                    dyawRad: PriorMapStageOneMath.normalizeAngle(
                        meanPhoneYaw - canonicalReferenceYaw))
            var retained = recentShelfObservationWindows[
                completed.shelfSegmentID, default: []]
            retained.append(record)
            if retained.count > 16 {
                let removed = retained.prefix(retained.count - 16)
                for item in removed {
                    recentShelfWindowRelativePoses.removeValue(
                        forKey: item.windowID)
                }
                retained.removeFirst(retained.count - 16)
            }
            recentShelfObservationWindows[completed.shelfSegmentID] = retained
            if recentShelfObservationWindows.count > 64,
               let oldest = recentShelfObservationWindows.keys.sorted().first {
                for item in recentShelfObservationWindows[oldest] ?? [] {
                    recentShelfWindowRelativePoses.removeValue(
                        forKey: item.windowID)
                }
                recentShelfObservationWindows.removeValue(forKey: oldest)
            }
        }
        return succeeded
    }

    @discardableResult
    private func persistShelfLoopEvent(
        shelfCandidates: [PriorMapShelfIdentityCandidate],
        scanSession: SupermarketScanSession,
        loopFromNode: Int,
        loopToNode: Int,
        rtabLoopID: Int,
        rtabGraphOptimizationMaxError: Double,
        visualLoopInlierRatio: Double
    ) -> Bool {
        guard let top = shelfCandidates.first,
              let windows = recentShelfObservationWindows[top.shelfSegmentId],
              let latest = windows.reversed().first(where: {
                $0.nodeRange[0] <= Int64(loopFromNode)
                    && Int64(loopFromNode) <= $0.nodeRange[1]
              }),
              let opposite = windows.reversed().first(where: {
                $0.windowID != latest.windowID
                    && $0.side != latest.side
                    && $0.nodeRange[0] <= Int64(loopToNode)
                    && Int64(loopToNode) <= $0.nodeRange[1]
              }),
              let oppositeRelative = recentShelfWindowRelativePoses[
                opposite.windowID],
              let latestRelative = recentShelfWindowRelativePoses[
                latest.windowID],
              loopFromNode > 0, loopToNode > 0 else {
            return true
        }
        let relativeDeltaM = hypot(
            latestRelative.dxM - oppositeRelative.dxM,
            latestRelative.dyM - oppositeRelative.dyM)
        let relativeDeltaYawRad = abs(
            PriorMapStageOneMath.normalizeAngle(
                latestRelative.dyawRad - oppositeRelative.dyawRad))
        let geometryInlierRatio = min(
            opposite.geometry.inlierRatio,
            latest.geometry.inlierRatio)
        let geometryResidualMedianM = max(
            opposite.geometry.residualMedianM,
            latest.geometry.residualMedianM)
        let geometryResidualMaximumM = max(
            opposite.geometry.residualMaximumM,
            latest.geometry.residualMaximumM)
        let accepted = ShelfLoopVerifier.accepts(
            first: opposite,
            second: latest,
            relativePoseDeltaM: relativeDeltaM,
            relativePoseDeltaYawRad: relativeDeltaYawRad,
            inlierRatio: geometryInlierRatio,
            hasEpochBridge: opposite.epoch == latest.epoch,
            dominantDynamicEvidence:
                opposite.dynamicRejectionCount * 2
                    > opposite.observationNodeCount
                || latest.dynamicRejectionCount * 2
                    > latest.observationNodeCount)
        let reason: String
        if accepted {
            reason = "two_sided_consistency_confirmed"
        } else if opposite.epoch != latest.epoch {
            reason = "epoch_mismatch"
        } else if ShelfLoopVerifier.candidateRelativeMargin(opposite)
                    < ShelfLocalizationPolicy.calibrationPendingLowConfidenceMargin
                    || ShelfLoopVerifier.candidateRelativeMargin(latest)
                    < ShelfLocalizationPolicy.calibrationPendingLowConfidenceMargin {
            reason = "margin_insufficient"
        } else if opposite.dynamicRejectionCount * 2
                    > opposite.observationNodeCount
                    || latest.dynamicRejectionCount * 2
                    > latest.observationNodeCount {
            reason = "dynamic_evidence_dominant"
        } else if relativeDeltaM
                    > ShelfLocalizationPolicy.calibrationPendingLoopTranslationM
                    || relativeDeltaYawRad
                    > ShelfLocalizationPolicy.calibrationPendingLoopYawRad {
            reason = "phone_shelf_se2_inconsistent"
        } else if geometryInlierRatio
                    < ShelfLocalizationPolicy.calibrationPendingLoopInlierRatio {
            reason = "shelf_geometry_inlier_ratio_insufficient"
        } else {
            reason = "opposing_normal_insufficient"
        }
        let sequence = shelfLoopEventSequence + 1
        let record = ShelfLoopEventRecord(
            format: ShelfLoopEventRecord.formatName,
            version: ShelfLocalizationPolicy.contractVersion,
            trackingSessionID: scanSession.trackingSessionId,
            sequence: sequence,
            shelfSegmentID: top.shelfSegmentId,
            windowIDs: [latest.windowID, opposite.windowID],
            sides: [latest.side, opposite.side],
            epoch: latest.epoch,
            component: latest.component,
            loopFromNode: Int64(loopFromNode),
            loopToNode: Int64(loopToNode),
            rtabLoopID: max(0, rtabLoopID),
            legacyRtabLoopResidualM: ShelfLegacyLoopResidualNull(),
            rtabGraphOptimizationMaxError: max(
                0, rtabGraphOptimizationMaxError),
            phoneShelfSE2: ShelfPhoneRelativePose(
                dxM: latestRelative.dxM,
                dyM: latestRelative.dyM,
                dyawRad: latestRelative.dyawRad),
            consistency: ShelfLoopConsistency(
                relativePoseDeltaM: relativeDeltaM,
                relativePoseDeltaYawRad: relativeDeltaYawRad,
                inlierRatio: max(0, min(1, geometryInlierRatio)),
                residualMedianM: geometryResidualMedianM,
                residualMaximumM: geometryResidualMaximumM),
            accepted: accepted,
            reason: reason,
            calibrationStatus: ShelfLocalizationPolicy.calibrationStatus,
            writeWatermark: sequence)
        let succeeded = scanSession.appendShelfLoopEvent(
            record,
            expectedTrackingSessionId: scanSession.trackingSessionId)
        if succeeded { shelfLoopEventSequence = sequence }
        scanSession.appendScanEvent(
            level: accepted ? "info" : "warning",
            event: "shelf_loop_geometry_verification",
            message: "Shelf loop acceptance used independent depth-geometry window evidence; visual loop metrics remained diagnostic-only",
            fields: [
                "geometry_inlier_ratio": String(format: "%.4f", geometryInlierRatio),
                "geometry_residual_median_m": String(format: "%.4f", geometryResidualMedianM),
                "geometry_residual_maximum_m": String(format: "%.4f", geometryResidualMaximumM),
                "visual_loop_inlier_ratio_diagnostic": String(format: "%.4f", visualLoopInlierRatio),
            ])
        return succeeded
    }

    private func updatePriorMapLocalization(
        frame: ARFrame,
        trackingState: String,
        poseOverride: simd_float4x4
    ) {
        guard activeScanConfiguration.workflowMode == .priorMapLocalized,
              let localizer = priorMapLocalizer,
              let scanSession = supermarketSession,
              !scanSession.isFinalizingScan,
              !scanSession.hasLocalizationRequiredWriteFailure() else {
            return
        }
        let generation = priorMapGeneration
        let trackingSessionId = scanSession.trackingSessionId
        let nodeTimebase = rtabmap?.nodeTimebase(frameTimestamp: frame.timestamp)
        guard PriorMapNodeTimebaseAdmission.accepts(
                offsetSeconds: nodeTimebase?.offsetSeconds),
              let nodeTimebase else {
            let previousNotice = priorMapNodeTimebaseUnavailableNoticeAt
            let shouldReport: Bool
            if let previousNotice {
                shouldReport = frame.timestamp - previousNotice >= 2.0
            }
            else {
                shouldReport = true
            }
            if shouldReport {
                priorMapNodeTimebaseUnavailableNoticeAt = frame.timestamp
                scanSession.appendScanEvent(
                    level: "warning",
                    event: "prior_map_update_waiting_for_node_timebase",
                    message: "Prior-map localization is waiting for the first native node-time snapshot",
                    fields: [
                        "frame_timestamp": String(
                            format: "%.9f", frame.timestamp),
                    ])
            }
            return
        }
        priorMapNodeTimebaseUnavailableNoticeAt = nil
        let priceTagNodeBinding = rtabmap?.latestNodeBinding(
            frameTimestamp: frame.timestamp)
        if let binding = priceTagNodeBinding {
            priorMapLastNodeBinding = (
                binding.nodeId,
                binding.nodeStamp,
                binding.nodeMapId,
                binding.nodeTimebaseOffsetSeconds,
                binding.generation,
                binding.openGLWorldFromNode,
                frame.timestamp)
            persistPendingPoseEpochTransition(
                afterNodeID: Int64(binding.nodeId),
                scanSession: scanSession,
                trackingSessionID: trackingSessionId)
        }
        let localizationEpoch = mCapturePoseEpoch
        let localizationComponent = Int64(priceTagNodeBinding?.nodeMapId ?? 0)
        let ticket: Int
        switch priorMapUpdateGate.begin(timestamp: frame.timestamp) {
        case .throttled:
            return
        case .busy(let droppedCount):
            if droppedCount == 1 || droppedCount % 20 == 0 {
                supermarketSession?.appendScanEvent(
                    level: "warning",
                    event: "prior_map_update_dropped",
                    message: "Skipped a stale prior-map update while the previous one was still running",
                    fields: ["dropped_count": String(droppedCount)])
            }
            return
        case .accepted(let acceptedTicket):
            ticket = acceptedTicket
        }
        let shelfEvidencePolicy = shelfEvidenceResourcePolicy()
        let computeShelfGeometryEvidence = priceTagNodeBinding.map {
            Int64($0.nodeId) % Int64(shelfEvidencePolicy.nodeStride) == 0
        } ?? false
        priorMapQueue.async {
            // A frame can race beginFinalization() after the main-thread
            // admission check and be enqueued behind the drain sentinel. Check
            // the invalidated generation before touching the localizer so no
            // post-sentinel frame mutates Recovery/localization state.
            guard generation == self.priorMapGeneration,
                  !scanSession.isFinalizingScan else {
                self.priorMapUpdateGate.finish(ticket: ticket)
                return
            }
            var update = autoreleasepool {
                localizer.update(
                    frame: frame,
                    trackingState: trackingState,
                    poseOverride: poseOverride,
                    shelfEvidenceCandidateLimit:
                        shelfEvidencePolicy.candidateLimit,
                    computeShelfGeometryEvidence:
                        computeShelfGeometryEvidence)
            }
            update.epoch = Int(localizationEpoch)
            update.component = localizationComponent
            if let binding = priceTagNodeBinding {
                self.auditShelfEvidenceResourcePolicyIfNeeded(
                    scanSession: scanSession)
                _ = self.consumeShelfObservationWindow(
                    update: update,
                    binding: binding,
                    localizer: localizer,
                    scanSession: scanSession,
                    trackingSessionID: trackingSessionId,
                    epoch: Int(localizationEpoch),
                    component: localizationComponent)
                _ = self.persistCorridorHypotheses(
                    update: update,
                    binding: binding,
                    scanSession: scanSession,
                    trackingSessionID: trackingSessionId,
                    epoch: Int(localizationEpoch),
                    component: localizationComponent)
            }
            self.priorMapUpdateGate.finish(ticket: ticket)
            guard generation == self.priorMapGeneration else {
                return
            }
            let alignmentSnapshot = localizer.alignmentSnapshot(
                frameTimestamp: frame.timestamp)
            let writeResult = scanSession.appendLocalizationTrace(
                update,
                expectedTrackingSessionId: trackingSessionId,
                nodeTimebaseOffsetSeconds: nodeTimebase.offsetSeconds)
            // F-02/P7R6: every terminal episode completion must leave the
            // device as persisted lifecycle evidence through the peek/ack
            // coordinator, including converged, timed out, and manual-reset
            // outcomes consumed on this frame.
            var recoveryEvidenceSucceeded = true
            let recoveryResult = self.runRecoveryLifecyclePersistence(
                localizer: localizer,
                scanSession: scanSession,
                trackingSessionId: trackingSessionId,
                cancellationReason: nil,
                now: ProcessInfo.processInfo.systemUptime,
                allowDuringFinalization: false)
            recoveryEvidenceSucceeded = recoveryResult.allPersisted
            self.reportCoordinatorLevelRecoveryFailure(
                recoveryResult,
                scanSession: scanSession)
            let preclaimedCancellation: PriceTagCaptureCancellation?
            if !writeResult.succeeded {
                preclaimedCancellation = self.priceTagCaptureCoordinator.cancel(
                    reason: "localization_evidence_write_failed")
            }
            else if !recoveryEvidenceSucceeded {
                preclaimedCancellation = self.priceTagCaptureCoordinator.cancel(
                    reason: "recovery_evidence_write_failed")
            }
            else if alignmentSnapshot?.localizationState == "lost" {
                // Invalidate the generation on the prior-map queue before it
                // can admit another queued ESL evidence job. Main-thread UI
                // cleanup receives the already-claimed cancellation below.
                preclaimedCancellation = self.priceTagCaptureCoordinator.cancel(
                    reason: "prior_map_localization_lost")
            }
            else {
                preclaimedCancellation = nil
            }
            DispatchQueue.main.async {
                guard generation == self.priorMapGeneration else {
                    return
                }
                if !writeResult.succeeded {
                    self.cancelPriceTagCapture(
                        reason: "localization_evidence_write_failed",
                        userMessage: nil,
                        preclaimedCancellation: preclaimedCancellation)
                    self.priorMapAlignmentSnapshots.reset()
                    self.presentLocalizationEvidenceWriteFailure(
                        writeResult.failedRequiredFiles)
                    return
                }
                if !recoveryEvidenceSucceeded {
                    self.cancelPriceTagCapture(
                        reason: "recovery_evidence_write_failed",
                        userMessage: nil,
                        preclaimedCancellation: preclaimedCancellation)
                    self.priorMapAlignmentSnapshots.reset()
                    self.presentLocalizationEvidenceWriteFailure(
                        [PriorMapRecoveryLifecycleRecord.fileName])
                    return
                }
                if let alignmentSnapshot,
                   alignmentSnapshot.localizationState == "lost" {
                    self.cancelPriceTagCapture(
                        reason: "prior_map_localization_lost",
                        userMessage: self.localized("Prior-map localization was lost. ESL capture stopped; raw scanning continues."),
                        preclaimedCancellation: preclaimedCancellation)
                }
                if let alignmentSnapshot {
                    self.priorMapAlignmentSnapshots.publish(alignmentSnapshot)
                }
                self.priorMapLatestUpdate = update
                self.priorMapOverlay?.update(update)
            }
        }
    }

    @objc private func scanPriorMapPriceTag() {
        startPriceTagCapture()
    }

    private func recordPriceTagCaptureAudit(
        _ code: PriceTagCaptureAuditCode,
        generation: UUID? = nil,
        captureID: UUID? = nil,
        phase: String,
        payload: String? = nil,
        symbology: String? = nil,
        sourceReason: String? = nil,
        terminal: Bool,
        minimumInterval: TimeInterval = 0,
        allowDuringFinalization: Bool = false
    ) {
        let now = ProcessInfo.processInfo.systemUptime
        let auditKey = [
            code.rawValue,
            generation?.uuidString.lowercased() ?? "",
            captureID?.uuidString.lowercased() ?? "",
        ].joined(separator: ":")
        priceTagCaptureAuditLock.lock()
        if minimumInterval > 0,
           let previous = priceTagCaptureLastAuditAt[auditKey],
           now - previous < minimumInterval {
            priceTagCaptureAuditLock.unlock()
            return
        }
        priceTagCaptureLastAuditAt[auditKey] = now
        if priceTagCaptureLastAuditAt.count > 128 {
            priceTagCaptureLastAuditAt = priceTagCaptureLastAuditAt.filter {
                now - $0.value <= 30
            }
        }
        let frozenTrackingSessionID = generation.flatMap {
            priceTagCaptureAuditTrackingSessionIDs[$0]
        }
        priceTagCaptureAuditLock.unlock()

        let authority = priceTagCaptureCoordinator.currentPriorMapAuthority()
        guard let scanSession = supermarketSession else {
            return
        }
        let configuration = scanSession.scanConfiguration
        let expectedTrackingSessionID: String
        if let frozenTrackingSessionID {
            expectedTrackingSessionID = frozenTrackingSessionID
        }
        else if generation == nil {
            expectedTrackingSessionID = authority?.trackingSessionID
                ?? scanSession.trackingSessionId
        }
        else {
            // A delayed callback for an evicted/unknown generation must never
            // fall back to the identity of a newer scan.
            return
        }
        func bounded(_ value: String?, limit: Int = 128) -> String {
            guard let value else { return "" }
            return String(value.prefix(limit))
        }
        scanSession.appendScanEventIfSessionActive(
            expectedTrackingSessionId: expectedTrackingSessionID,
            allowDuringFinalization: allowDuringFinalization,
            level: terminal ? "error" : "warning",
            event: code.rawValue,
            message: "Stable ESL capture audit event",
            fields: [
                "code": code.rawValue,
                "phase": bounded(phase, limit: 64),
                "terminal": terminal ? "true" : "false",
                "capture_generation": generation?.uuidString
                    .lowercased() ?? "",
                "capture_id": captureID?.uuidString.lowercased() ?? "",
                "tracking_session_id": expectedTrackingSessionID,
                "prior_map_generation": authority?.priorMapGeneration
                    .uuidString.lowercased() ?? "",
                "prior_map_id": authority?.priorMapID
                    ?? configuration.priorMapId ?? "",
                "prior_map_sha256": authority?.priorMapSHA256
                    ?? configuration.priorMapSha256 ?? "",
                "floor_id": authority?.floorID
                    ?? configuration.floorId ?? "",
                "payload": bounded(payload),
                "symbology": bounded(symbology, limit: 64),
                "source_reason": bounded(sourceReason, limit: 256),
            ])
    }

    private func persistPriceTagCaptureDiagnostics(
        generation: UUID?,
        captureID: UUID?,
        phase: String
    ) {
        for diagnostic in priceTagCaptureCoordinator.drainDiagnostics() {
            recordPriceTagCaptureAudit(
                .illegalTransition,
                generation: generation,
                captureID: captureID,
                phase: phase,
                sourceReason: diagnostic,
                terminal: true)
        }
    }

    private func presentPriceTagCaptureStartFailure(_ reason: String?) {
        guard priceTagCaptureStartFailureAlert == nil else { return }
        let message: String
        switch reason {
        case "required_localization_evidence_failed":
            message = localized("Required localization evidence has failed for this scan. Barcode capture is disabled to protect the result. End the scan, keep the recovery package, then start a new scan.")
        case "alignment_snapshot_unavailable":
            message = localized("Prior-map alignment is not ready yet. Hold the device steady and try again after localization recovers.")
        case "arkit_frame_unavailable":
            message = localized("The camera frame is not ready. Keep the app in the foreground and try again in a moment.")
        case "mapping_state_unavailable":
            message = localized("Barcode capture is available only while a store scan is actively recording.")
        case "prior_map_localizer_unavailable",
             "workflow_not_prior_map_localized",
             "prior_map_scan_identity_unavailable",
             "capture_authority_unavailable":
            message = localized("This scan does not have a usable prior-map identity. End it and start again through Start Store Scan after selecting a map.")
        default:
            message = localized("Tracking or prior-map localization is temporarily unstable. Hold the device steady and try again after localization recovers.")
        }
        let alert = UIAlertController(
            title: localized("Unable to scan ESL barcode"),
            message: message,
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(
            title: "OK",
            style: .default,
            handler: { [weak self] _ in
                self?.priceTagCaptureStartFailureAlert = nil
            }))
        priceTagCaptureStartFailureAlert = alert
        present(alert, animated: true)
    }

    private func startPriceTagCapture() {
        let currentFrame = session.currentFrame
        let currentAlignment = priorMapAlignmentSnapshots.snapshot()
        let startFailure: String?
        if activeScanConfiguration.workflowMode != .priorMapLocalized {
            startFailure = "workflow_not_prior_map_localized"
        }
        else if priorMapLocalizer == nil {
            startFailure = "prior_map_localizer_unavailable"
        }
        else if currentFrame == nil {
            startFailure = "arkit_frame_unavailable"
        }
        else if currentAlignment == nil {
            startFailure = "alignment_snapshot_unavailable"
        }
        else if mState != .STATE_MAPPING || mDataRecording {
            startFailure = "mapping_state_unavailable"
        }
        else if supermarketSession?.hasLocalizationRequiredWriteFailure()
            == true {
            startFailure = "required_localization_evidence_failed"
        }
        else if let frame = currentFrame,
                let alignment = currentAlignment {
            switch PriceTagCaptureTrackingGate.evaluate(
                trackingState: priceTagTrackingStateLabel(
                    frame.camera.trackingState),
                localizationState: alignment.localizationState) {
            case .allow:
                startFailure = nil
            case .pause(let reason), .cancel(let reason):
                startFailure = reason
            }
        }
        else {
            startFailure = "capture_authority_unavailable"
        }
        guard startFailure == nil, let frame = currentFrame else {
            recordPriceTagCaptureAudit(
                .startUnavailable,
                phase: "start",
                sourceReason: startFailure,
                terminal: true)
            presentPriceTagCaptureStartFailure(startFailure)
            return
        }
        guard !priceTagCaptureCoordinator.isActive() else {
            recordPriceTagCaptureAudit(
                .startUnavailable,
                generation: priceTagCaptureCoordinator.currentState().generation,
                phase: "start",
                sourceReason: "capture_already_active",
                terminal: false)
            showToast(
                message: localized("An ESL capture or shelf confirmation is already active."),
                seconds: 2)
            return
        }

        guard let scanSession = supermarketSession,
              scanSession.scanConfiguration.workflowMode == .priorMapLocalized,
              scanSession.scanConfiguration.isReadyToStart,
              let priorMapID = scanSession.scanConfiguration.priorMapId,
              let priorMapSHA256 = scanSession.scanConfiguration.priorMapSha256,
              let floorID = scanSession.scanConfiguration.floorId,
              !scanSession.trackingSessionId.isEmpty else {
            recordPriceTagCaptureAudit(
                .startUnavailable,
                phase: "start_identity",
                sourceReason: "prior_map_scan_identity_unavailable",
                terminal: true)
            presentPriceTagCaptureStartFailure(
                "prior_map_scan_identity_unavailable")
            return
        }
        let capturePriorMapGeneration = priorMapGeneration
        let priorMapAuthority = PriceTagCapturePriorMapAuthority(
            priorMapGeneration: capturePriorMapGeneration,
            trackingSessionID: scanSession.trackingSessionId,
            priorMapID: priorMapID,
            priorMapSHA256: priorMapSHA256,
            floorID: floorID)
        let generation = priceTagCaptureCoordinator.begin(
            now: frame.timestamp,
            priorMapAuthority: priorMapAuthority)
        priceTagCaptureAuditLock.lock()
        priceTagCaptureAuditTrackingSessionIDs[generation] =
            scanSession.trackingSessionId
        priceTagCaptureAuditGenerationOrder.append(generation)
        while priceTagCaptureAuditGenerationOrder.count > 32 {
            let expired = priceTagCaptureAuditGenerationOrder.removeFirst()
            priceTagCaptureAuditTrackingSessionIDs.removeValue(forKey: expired)
        }
        priceTagCaptureAuditLock.unlock()
        clearPriceTagCaptureResults()
        priceTagCapturePausedReason = nil

        let overlay = PriceTagCaptureOverlayView()
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.onCancel = { [weak self] in
            self?.cancelPriceTagCapture(
                reason: "user_cancelled",
                userMessage: self?.localized("ESL capture cancelled. Raw scanning continued."))
        }
        priceTagCapturePriorMapOverlayWasHidden = priorMapOverlay?.isHidden
        priorMapOverlay?.isHidden = true
        view.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: view.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        view.layoutIfNeeded()
        overlay.accessibilityViewIsModal = true
        view.bringSubviewToFront(overlay)
        priceTagCaptureOverlay = overlay
        priceTagCapturePresentationGeneration = generation
        priceTagCaptureCoordinator.updateGeometry(overlay.captureGeometry)
        guard priceTagCaptureCoordinator.markAiming(generation: generation) else {
            persistPriceTagCaptureDiagnostics(
                generation: generation,
                captureID: nil,
                phase: "entering_to_aiming")
            cancelPriceTagCapture(
                reason: "entering_transition_failed",
                userMessage: localized("ESL capture could not start."))
            return
        }
        priceTagVisionScanner.activate(generation: generation)
        priceTagCaptureContinuityStart = makePriceTagCaptureContinuitySnapshot(
            generation: generation,
            frameTimestamp: frame.timestamp)
        supermarketSession?.appendScanEvent(
            event: "price_tag_capture_started",
            message: "Barcode Capture Mode started without pausing the scan",
            fields: [
                "capture_generation": generation.uuidString.lowercased(),
                "vision_rate_hz": "8",
                "target_evidence_frames": "4",
            ])
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        overlay.update(.aiming)
        UIAccessibility.post(notification: .screenChanged, argument: overlay)
    }

    private func priceTagImageOrientation() -> CGImagePropertyOrientation {
        let interfaceOrientation = view.window?.windowScene?.interfaceOrientation
            ?? .portrait
        switch interfaceOrientation {
        case .portraitUpsideDown:
            return .left
        case .landscapeLeft:
            return .up
        case .landscapeRight:
            return .down
        default:
            return .right
        }
    }

    private func priceTagTrackingStateLabel(
        _ state: ARCamera.TrackingState
    ) -> String {
        switch state {
        case .normal:
            return "normal"
        case .notAvailable:
            return "notAvailable"
        case .limited(.excessiveMotion):
            return "limited.excessiveMotion"
        case .limited(.insufficientFeatures):
            return "limited.insufficientFeatures"
        case .limited(.initializing):
            return "limited.initializing"
        case .limited(.relocalizing):
            return "limited.relocalizing"
        default:
            return "unknown"
        }
    }

    private func updatePriceTagCapture(
        frame: ARFrame,
        trackingState: String,
        cameraTransform: simd_float4x4
    ) {
        guard priceTagCaptureCoordinator.isActive(),
              let capturePriorMapGeneration = priceTagCaptureCoordinator
                .currentPriorMapGeneration() else {
            return
        }
        guard let alignmentSnapshot = priorMapAlignmentSnapshots.snapshot(),
              let localizer = priorMapLocalizer else {
            cancelPriceTagCapture(
                reason: "prior_map_capture_authority_unavailable",
                userMessage: localized("Prior-map localization is unavailable. ESL capture stopped; raw scanning continues."))
            return
        }
        switch PriceTagCaptureTrackingGate.evaluate(
            trackingState: trackingState,
            localizationState: alignmentSnapshot.localizationState) {
        case .cancel(let reason):
            recordPriceTagCaptureAudit(
                .trackingUnavailable,
                generation: priceTagCaptureCoordinator.currentState().generation,
                phase: "tracking_gate",
                sourceReason: reason,
                terminal: true)
            cancelPriceTagCapture(
                reason: reason,
                userMessage: localized("Tracking or prior-map localization was lost. ESL capture stopped; raw scanning continues."))
            return
        case .pause(let reason):
            let deadlineAction = priceTagCaptureCoordinator.tickDeadline(
                frameTimestamp: frame.timestamp)
            if handlePriceTagDeadlineAction(
                deadlineAction,
                generation: priceTagCaptureCoordinator.currentState().generation) {
                return
            }
            if priceTagCapturePausedReason != reason {
                priceTagCapturePausedReason = reason
                recordPriceTagCaptureAudit(
                    .trackingUnavailable,
                    generation: priceTagCaptureCoordinator.currentState().generation,
                    phase: "tracking_gate",
                    sourceReason: reason,
                    terminal: false,
                    minimumInterval: 0.5)
                DispatchQueue.main.async {
                    guard self.priceTagCaptureCoordinator.isActive() else {
                        return
                    }
                    self.priceTagCaptureOverlay?.update(.error(
                        message: self.localized("Hold steady and keep the ESL in view. Barcode evidence is paused until tracking recovers.")))
                }
            }
            return
        case .allow:
            priceTagCapturePausedReason = nil
        }
        let deadlineAction = priceTagCaptureCoordinator.tickDeadline(
            frameTimestamp: frame.timestamp)
        if handlePriceTagDeadlineAction(
            deadlineAction,
            generation: priceTagCaptureCoordinator.currentState().generation) {
            return
        }
        let orientation = priceTagImageOrientation()
        if let generation = priceTagCaptureCoordinator.shouldSubmitPreview(
            frameTimestamp: frame.timestamp) {
            priceTagCaptureOverlay?.previewView.enqueue(
                pixelBuffer: frame.capturedImage,
                orientation: orientation,
                generation: generation)
        }
        guard let submission = priceTagCaptureCoordinator.requestVisionSubmission(
                frameTimestamp: frame.timestamp) else {
            return
        }
        let regionOfInterest: CGRect
        do {
            regionOfInterest = try PriceTagScanROIMapper.visionRegionOfInterest(
                scanRectInView: submission.geometry.scanRect,
                previewBounds: submission.geometry.previewBounds,
                imageResolution: frame.camera.imageResolution,
                orientation: orientation)
        }
        catch {
            priceTagCaptureCoordinator.failVision(
                generation: submission.generation,
                frameTimestamp: frame.timestamp)
            recordPriceTagCaptureAudit(
                .roiUnavailable,
                generation: submission.generation,
                phase: "roi_mapping",
                sourceReason: String(describing: error),
                terminal: false,
                minimumInterval: 1)
            DispatchQueue.main.async {
                guard self.priceTagCaptureCoordinator.isCurrent(
                    submission.generation) else { return }
                self.priceTagCaptureOverlay?.update(.error(
                    message: self.localized("The ESL scan region is unavailable. Rotate the device or try again.")))
            }
            return
        }
        let binding = priceTagNodeBinding(frameTimestamp: frame.timestamp)
        let trackingSessionID = supermarketSession?.trackingSessionId ?? ""
        let submitted = priceTagVisionScanner.detect(
            frame: frame,
            orientation: orientation,
            regionOfInterest: regionOfInterest,
            generation: submission.generation,
            cameraTransform: cameraTransform,
            alignmentSnapshot: alignmentSnapshot) { result in
                guard self.priceTagCaptureCoordinator.matchesPriorMapAuthority(
                        generation: submission.generation,
                        priorMapGeneration: capturePriorMapGeneration) else {
                    return
                }
                switch result {
                case .failure(let error):
                    self.priceTagCaptureCoordinator.failVision(
                        generation: submission.generation,
                        frameTimestamp: frame.timestamp)
                    if let scannerError = error as? PriceTagVisionScannerError,
                       case .workerCapacityExhausted = scannerError {
                        self.recordPriceTagCaptureAudit(
                            .visionFailed,
                            generation: submission.generation,
                            phase: "vision_worker_capacity",
                            sourceReason:
                                "price_tag_vision_worker_capacity_exhausted",
                            terminal: true)
                        DispatchQueue.main.async {
                            guard self.priceTagCaptureCoordinator.isCurrent(
                                submission.generation) else { return }
                            self.cancelPriceTagCapture(
                                reason:
                                    "price_tag_vision_worker_capacity_exhausted",
                                userMessage: self.localized("Barcode detection stopped after repeated Vision timeouts. Raw scanning continues; try ESL capture again after restarting the app."))
                        }
                        return
                    }
                    self.recordPriceTagCaptureAudit(
                        .visionFailed,
                        generation: submission.generation,
                        phase: "vision",
                        sourceReason: (error as? LocalizedError)?
                            .errorDescription ?? "vision_request_failed",
                        terminal: false,
                        minimumInterval: 1)
                    DispatchQueue.main.async {
                        guard self.priceTagCaptureCoordinator.isCurrent(
                            submission.generation) else { return }
                        self.priceTagCaptureOverlay?.update(.error(
                            message: self.localized("Barcode detection failed. Hold steady and try again.")))
                    }
                case .success(let scanResult):
                    self.handlePriceTagVisionResult(
                        scanResult,
                        regionOfInterest: regionOfInterest,
                        binding: binding,
                        localizer: localizer,
                        trackingSessionID: trackingSessionID,
                        capturePriorMapGeneration:
                            capturePriorMapGeneration)
                }
            }
        if !submitted {
            priceTagCaptureCoordinator.failVision(
                generation: submission.generation,
                frameTimestamp: frame.timestamp)
            recordPriceTagCaptureAudit(
                .visionFailed,
                generation: submission.generation,
                phase: "vision_submission",
                sourceReason: "scanner_rejected_submission",
                terminal: false,
                minimumInterval: 1)
        }
    }

    /// Prefer the atomic live node snapshot. During a short native node
    /// publication gap, reuse only the already-frozen snapshot that still
    /// satisfies the same strict one-second node-timebase contract. This is
    /// exact-ID authority reuse, never the removed nearest-node fallback.
    private func priceTagNodeBinding(
        frameTimestamp: TimeInterval
    ) -> PriceTagCaptureNodeBinding? {
        if let live = rtabmap?.latestNodeBinding(
                frameTimestamp: frameTimestamp) {
            return PriceTagCaptureNodeBinding(
                nodeID: Int64(live.nodeId),
                nodeStamp: live.nodeStamp,
                nodeMapID: live.nodeMapId,
                nodeTimebaseOffsetSeconds:
                    live.nodeTimebaseOffsetSeconds,
                openGLWorldFromNode: live.openGLWorldFromNode)
        }
        guard let cached = priorMapLastNodeBinding else { return nil }
        let nodeTimebaseFrameTimestamp = frameTimestamp
            + cached.nodeTimebaseOffsetSeconds
        let delta = abs(nodeTimebaseFrameTimestamp - cached.nodeStamp)
        guard abs(frameTimestamp - cached.sampledFrameTimestamp) <= 1.0,
              delta <= 1.0 else {
            return nil
        }
        return PriceTagCaptureNodeBinding(
            nodeID: Int64(cached.nodeId),
            nodeStamp: cached.nodeStamp,
            nodeMapID: cached.nodeMapId,
            nodeTimebaseOffsetSeconds:
                cached.nodeTimebaseOffsetSeconds,
            openGLWorldFromNode: cached.openGLWorldFromNode)
    }

    @discardableResult
    private func handlePriceTagDeadlineAction(
        _ action: PriceTagCaptureVisionAction,
        generation: UUID?
    ) -> Bool {
        guard let generation else { return false }
        switch action {
        case .requestTimedOut:
            _ = priceTagVisionScanner.restart(generation: generation)
            recordPriceTagCaptureAudit(
                .visionFailed,
                generation: generation,
                phase: "vision_request_deadline",
                sourceReason: "price_tag_vision_request_timeout",
                terminal: false,
                minimumInterval: 0.5)
            DispatchQueue.main.async {
                guard self.priceTagCaptureCoordinator.isCurrent(
                    generation) else { return }
                self.priceTagCaptureOverlay?.update(.error(
                    message: self.localized("Barcode detection timed out. Hold steady while the scanner retries.")))
            }
            return true
        case .resolve(let captureID, let observationIDs):
            handlePriceTagEvidenceAction(
                .resolve(
                    captureID: captureID,
                    observationIDs: observationIDs),
                generation: generation,
                captureID: captureID,
                payload: "")
            return true
        case .timedOut(let captureID, let revokeVisionRequest):
            if revokeVisionRequest {
                // This branch runs synchronously on the ARSession delegate
                // callback that crossed the burst deadline. No fresh frame can
                // be admitted between the coordinator transition and this
                // exact cleanup. Callback/evidence timeout paths carry false
                // and must never cancel a newer same-generation request.
                _ = priceTagVisionScanner.restart(generation: generation)
            }
            handlePriceTagEvidenceAction(
                .timedOut(captureID: captureID),
                generation: generation,
                captureID: captureID,
                payload: "")
            return true
        default:
            return false
        }
    }

    private func handlePriceTagVisionResult(
        _ result: PriceTagVisionScanResult,
        regionOfInterest: CGRect,
        binding: PriceTagCaptureNodeBinding?,
        localizer: PriorMapStageOneLocalizer,
        trackingSessionID: String,
        capturePriorMapGeneration: UUID
    ) {
        let action = priceTagCaptureCoordinator.finishVision(
            generation: result.generation,
            frameTimestamp: result.frame.timestamp,
            candidates: result.candidates,
            regionOfInterest: regionOfInterest)
        switch action {
        case .ignored:
            return
        case .requestTimedOut:
            return
        case .keepAiming(let code):
            recordPriceTagCaptureAudit(
                code == "price_tag_duplicate_detection_frame"
                    || code == "price_tag_duplicate_capture_frame"
                    ? .duplicateFrame
                    : .roiMiss,
                generation: result.generation,
                phase: "aiming",
                sourceReason: code,
                terminal: false,
                minimumInterval: 1)
            DispatchQueue.main.async {
                guard self.priceTagCaptureCoordinator.isCurrent(
                    result.generation) else { return }
                if case .aiming = self.priceTagCaptureCoordinator.currentState() {
                    self.priceTagCaptureOverlay?.update(.aiming)
                }
            }
        case .candidateSeen(let payload, let lockFrames, let requiredFrames):
            DispatchQueue.main.async {
                guard self.priceTagCaptureCoordinator.isCurrent(
                    result.generation) else { return }
                self.priceTagCaptureOverlay?.update(.candidate(
                    payload: payload,
                    lockFrames: lockFrames,
                    requiredFrames: requiredFrames))
            }
        case .candidateLocked(let captureID, let barcode),
             .collect(let captureID, let barcode):
            DispatchQueue.main.async {
                guard self.priceTagCaptureCoordinator.isCurrent(
                    result.generation) else { return }
                let state = self.priceTagCaptureCoordinator.currentState()
                let accepted: Int
                let required: Int
                if case .collecting(_, _, _, _, let count, let target) = state {
                    accepted = count
                    required = target
                }
                else {
                    accepted = 0
                    required = 4
                }
                self.priceTagCaptureOverlay?.update(.collecting(
                    payload: barcode.candidate.payload,
                    acceptedFrames: accepted,
                    requiredFrames: required))
            }
            collectPriceTagEvidence(
                result: result,
                selected: barcode,
                captureID: captureID,
                binding: binding,
                localizer: localizer,
                trackingSessionID: trackingSessionID,
                capturePriorMapGeneration: capturePriorMapGeneration)
        case .duplicateCompleted:
            recordPriceTagCaptureAudit(
                .duplicateCompleted,
                generation: result.generation,
                phase: "candidate_selection",
                terminal: false,
                minimumInterval: 1)
            DispatchQueue.main.async {
                guard self.priceTagCaptureCoordinator.isCurrent(
                    result.generation) else { return }
                self.priceTagCaptureOverlay?.update(.duplicate)
            }
        case .multipleBarcodes:
            recordPriceTagCaptureAudit(
                .multipleBarcodes,
                generation: result.generation,
                phase: "candidate_selection",
                sourceReason: "ambiguous_candidates_inside_roi",
                terminal: false,
                minimumInterval: 0.5)
            DispatchQueue.main.async {
                guard self.priceTagCaptureCoordinator.isCurrent(
                    result.generation) else { return }
                self.priceTagCaptureOverlay?.update(.multiple)
            }
        case .targetChanged(let previousCaptureID, let payload):
            _ = supermarketSession?.finalizeTagObservationCapture(
                captureID: previousCaptureID,
                minimumFrameCount: 3)
            removePriceTagCaptureResults(captureID: previousCaptureID)
            DispatchQueue.main.async {
                guard self.priceTagCaptureCoordinator.isCurrent(
                    result.generation) else { return }
                self.priceTagCaptureOverlay?.update(.candidate(
                    payload: payload,
                    lockFrames: 1,
                    requiredFrames: 2))
            }
        case .resolve(let captureID, let observationIDs):
            handlePriceTagEvidenceAction(
                .resolve(
                    captureID: captureID,
                    observationIDs: observationIDs),
                generation: result.generation,
                captureID: captureID,
                payload: "")
        case .timedOut(let captureID, _):
            recordPriceTagCaptureAudit(
                .captureTimeout,
                generation: result.generation,
                captureID: captureID,
                phase: "burst_collection",
                sourceReason: "minimum_independent_frames_not_reached",
                terminal: false)
            _ = supermarketSession?.finalizeTagObservationCapture(
                captureID: captureID,
                minimumFrameCount: 3)
            removePriceTagCaptureResults(captureID: captureID)
            DispatchQueue.main.async {
                guard self.priceTagCaptureCoordinator.isCurrent(
                    result.generation) else { return }
                self.priceTagCaptureOverlay?.update(.error(
                    message: self.localized("Not enough independent frames. Hold the ESL steady and try again.")))
            }
        }
    }

    private func collectPriceTagEvidence(
        result: PriceTagVisionScanResult,
        selected: PriceTagSelectedBarcode,
        captureID: UUID,
        binding: PriceTagCaptureNodeBinding?,
        localizer: PriorMapStageOneLocalizer,
        trackingSessionID: String,
        capturePriorMapGeneration: UUID
    ) {
        let detection = result.detection(for: selected)
        let capturePoseEpoch = Int(mCapturePoseEpoch)
        guard let binding else {
            recordPriceTagCaptureAudit(
                .trackingUnavailable,
                generation: result.generation,
                captureID: captureID,
                phase: "node_binding",
                payload: detection.payload,
                symbology: detection.symbology,
                sourceReason: "native_node_binding_unavailable",
                terminal: false,
                minimumInterval: 0.5)
            let action = priceTagCaptureCoordinator
                .deferEvidenceUntilNodeBinding(
                    generation: result.generation,
                    captureID: captureID,
                    frameTimestamp: result.frame.timestamp)
            handlePriceTagEvidenceAction(
                action,
                generation: result.generation,
                captureID: captureID,
                payload: detection.payload)
            return
        }
        priorMapQueue.async {
            guard self.priceTagCaptureCoordinator.matchesPriorMapAuthority(
                    generation: result.generation,
                    priorMapGeneration: capturePriorMapGeneration) else {
                return
            }
            guard self.supermarketSession?.hasLocalizationRequiredWriteFailure()
                    != true else {
                self.recordPriceTagCaptureAudit(
                    .evidenceWriteFailed,
                    generation: result.generation,
                    captureID: captureID,
                    phase: "evidence_admission",
                    payload: detection.payload,
                    symbology: detection.symbology,
                    sourceReason: "required_write_health_already_failed",
                    terminal: true)
                let action = self.priceTagCaptureCoordinator.finishEvidence(
                    generation: result.generation,
                    captureID: captureID,
                    frameTimestamp: result.frame.timestamp,
                    observationID: detection.observationId,
                    succeeded: false)
                self.handlePriceTagEvidenceAction(
                    action,
                    generation: result.generation,
                    captureID: captureID,
                    payload: detection.payload)
                return
            }
            let localized = autoreleasepool {
                localizer.localizePriceTag(
                    detection,
                    trackingSessionId: trackingSessionID,
                    nodeTimebaseOffsetSeconds:
                        binding.nodeTimebaseOffsetSeconds,
                    boundNodeID: binding.nodeID,
                    boundNodeStamp: binding.nodeStamp,
                    boundNodeMapID: binding.nodeMapID,
                    capturePoseEpoch: capturePoseEpoch,
                    openGLWorldFromNode: binding.openGLWorldFromNode)
            }
            if localized.observation.pointInBoundNodeFrame == nil
                || localized.observation.measurementMethod == "unavailable" {
                self.recordPriceTagCaptureAudit(
                    .measurementUnavailable,
                    generation: result.generation,
                    captureID: captureID,
                    phase: "measurement",
                    payload: detection.payload,
                    symbology: detection.symbology,
                    sourceReason: localized.observation.measurementMethod,
                    terminal: false,
                    minimumInterval: 0.5)
            }
            if !localized.association.algorithmCandidateReliable {
                self.recordPriceTagCaptureAudit(
                    localized.association.candidates.isEmpty
                        ? .shelfUnavailable
                        : .shelfAmbiguous,
                    generation: result.generation,
                    captureID: captureID,
                    phase: "shelf_association",
                    payload: detection.payload,
                    symbology: detection.symbology,
                    sourceReason: localized.association.candidates.isEmpty
                        ? "no_candidate"
                        : "candidate_not_reliable",
                    terminal: false,
                    minimumInterval: 0.5)
            }
            var appendResult: TagObservationAppendResult?
            let commitAccepted = self.priceTagCaptureCoordinator
                .performEvidenceCommitIfCurrent(
                    generation: result.generation,
                    captureID: captureID,
                    frameTimestamp: result.frame.timestamp,
                    priorMapGeneration: capturePriorMapGeneration) {
                        appendResult = self.supermarketSession?
                            .appendTagObservationForCapture(
                                localized.observation,
                                boundNodeID: binding.nodeID,
                                captureID: captureID)
                    }
            guard commitAccepted else {
                return
            }
            if appendResult != nil {
                self.appendPriceTagCaptureResult(
                    localized.association,
                    captureID: captureID)
            }
            else {
                self.recordPriceTagCaptureAudit(
                    .evidenceWriteFailed,
                    generation: result.generation,
                    captureID: captureID,
                    phase: "observation_persistence",
                    payload: detection.payload,
                    symbology: detection.symbology,
                    sourceReason: "append_tag_observation_rejected",
                    terminal: true)
            }
            let action = self.priceTagCaptureCoordinator.finishEvidence(
                generation: result.generation,
                captureID: captureID,
                frameTimestamp: result.frame.timestamp,
                observationID: localized.observation.observationId,
                succeeded: appendResult != nil)
            self.handlePriceTagEvidenceAction(
                action,
                generation: result.generation,
                captureID: captureID,
                payload: detection.payload)
        }
    }

    private func handlePriceTagEvidenceAction(
        _ action: PriceTagCaptureEvidenceAction,
        generation: UUID,
        captureID: UUID,
        payload: String
    ) {
        switch action {
        case .ignored:
            return
        case .continueCollecting(let acceptedFrames, let requiredFrames):
            DispatchQueue.main.async {
                guard self.priceTagCaptureCoordinator.isCurrent(generation) else {
                    return
                }
                self.priceTagCaptureOverlay?.update(.collecting(
                    payload: payload,
                    acceptedFrames: acceptedFrames,
                    requiredFrames: requiredFrames))
            }
        case .waitingForNodeBinding(let acceptedFrames, let requiredFrames):
            DispatchQueue.main.async {
                guard self.priceTagCaptureCoordinator.isCurrent(generation) else {
                    return
                }
                self.priceTagCaptureOverlay?.update(.error(
                    message: String(
                        format: self.localized("Barcode recognized. Waiting for an exact scan-node pose before saving low-confidence evidence (%d/%d)."),
                        acceptedFrames,
                        requiredFrames)))
            }
        case .resolve(_, let observationIDs):
            priceTagVisionScanner.cancel(generation: generation)
            let captureResults = priceTagCaptureResults(
                captureID: captureID)
            guard let completion = supermarketSession?
                    .finalizeTagObservationCapture(
                        captureID: captureID,
                        minimumFrameCount: 3),
                  completion.persisted,
                  completion.sufficient,
                  Set(completion.observationIDs) == Set(observationIDs),
                  let resolved = PriceTagCaptureResolver.resolve(
                    captureResults,
                    minimumEvidenceFrames: 3) else {
                recordPriceTagCaptureAudit(
                    .shelfAmbiguous,
                    generation: generation,
                    captureID: captureID,
                    phase: "capture_resolution",
                    payload: payload,
                    sourceReason: "durable_burst_or_reliable_quorum_missing",
                    terminal: true)
                DispatchQueue.main.async {
                    self.cancelPriceTagCapture(
                        reason: "capture_resolution_failed",
                        userMessage: self.localized("ESL evidence was saved, but the shelf result was not stable. Please rescan."),
                        captureIDToFinalize: captureID)
                }
                return
            }
            let boundTag = resolved.tag.bindingCapture(
                captureID: captureID,
                observationIDs: completion.observationIDs)
            let resolution = PriceTagCaptureResolution(
                tag: boundTag,
                candidates: resolved.candidates,
                algorithmCandidateReliable:
                    resolved.algorithmCandidateReliable)
            guard priceTagCaptureCoordinator.markConfirming(
                generation: generation,
                captureID: captureID) else {
                persistPriceTagCaptureDiagnostics(
                    generation: generation,
                    captureID: captureID,
                    phase: "resolving_to_confirming")
                return
            }
            if resolution.tag.needsReview
                || !resolution.algorithmCandidateReliable {
                let recomputableFrameCount = captureResults.filter {
                    $0.tag.rawMapPosition != nil
                        && $0.tag.measurementMethod != "unavailable"
                }.count
                guard recomputableFrameCount >= 3 else {
                    recordPriceTagCaptureAudit(
                        .measurementUnavailable,
                        generation: generation,
                        captureID: captureID,
                        phase: "capture_resolution",
                        payload: resolution.tag.payload,
                        symbology: resolution.tag.symbology,
                        sourceReason: "recomputable_position_quorum_missing",
                        terminal: true)
                    DispatchQueue.main.async {
                        self.cancelPriceTagCapture(
                            reason: "capture_position_unresolvable",
                            userMessage: self.localized("The barcode evidence was saved, but fewer than three frames had a recomputable ESL position. Move slightly back and rescan once."),
                            captureIDToFinalize: captureID)
                    }
                    return
                }
                // The exact complete burst is already durable. Retain it as
                // low confidence and let post-processing reproject every
                // observation through its exact boundNodeID and the final
                // optimized phone pose. The operator should not have to scan
                // the same physical tag repeatedly just to improve confidence.
                DispatchQueue.main.async {
                    guard self.priceTagCaptureCoordinator.isCurrent(generation) else {
                        return
                    }
                    self.priceTagCaptureOverlay?.update(.success)
                    UINotificationFeedbackGenerator()
                        .notificationOccurred(.warning)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        guard self.priceTagCaptureCoordinator.isCurrent(
                            generation) else { return }
                        _ = self.finishPriceTagCapture(
                            generation: generation,
                            payload: resolution.tag.payload,
                            committed: false,
                            retainedForReview: true,
                            outcome: "low_confidence_retained")
                        self.showToast(
                            message: self.localized("The ESL was saved as low confidence. Its position will be recomputed from the exact scan node during processing; no immediate rescan is required."),
                            seconds: 5,
                            replacingCurrent: true)
                    }
                }
                return
            }
            DispatchQueue.main.async {
                guard self.priceTagCaptureCoordinator.isCurrent(generation) else {
                    return
                }
                self.presentPriceTagShelfConfirmation(
                    resolution,
                    generation: generation,
                    captureID: captureID)
            }
        case .timedOut:
            recordPriceTagCaptureAudit(
                .captureTimeout,
                generation: generation,
                captureID: captureID,
                phase: "evidence_deadline",
                payload: payload,
                sourceReason: "minimum_independent_frames_not_reached",
                terminal: false)
            _ = supermarketSession?.finalizeTagObservationCapture(
                captureID: captureID,
                minimumFrameCount: 3)
            removePriceTagCaptureResults(captureID: captureID)
            DispatchQueue.main.async {
                guard self.priceTagCaptureCoordinator.isCurrent(generation) else {
                    return
                }
                self.priceTagCaptureOverlay?.update(.error(
                    message: self.localized("Not enough independent frames. Hold the ESL steady and try again.")))
            }
        case .requiredEvidenceFailed:
            recordPriceTagCaptureAudit(
                .evidenceWriteFailed,
                generation: generation,
                captureID: captureID,
                phase: "required_evidence",
                payload: payload,
                sourceReason: "required_capture_evidence_failed",
                terminal: true)
            DispatchQueue.main.async {
                self.cancelPriceTagCapture(
                    reason: "required_capture_evidence_failed",
                    userMessage: self.localized("The ESL observations could not be saved. The tag was not created; raw RTAB-Map recording continues."),
                    captureIDToFinalize: captureID)
            }
        }
    }

    private func presentPriceTagShelfConfirmation(
        _ resolution: PriceTagCaptureResolution,
        generation: UUID,
        captureID: UUID
    ) {
        priceTagCaptureOverlay?.update(.success)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        let pendingPoint = resolution.tag.snappedMapPosition
            ?? resolution.tag.rawMapPosition
        priorMapOverlay?.updateTagLayers(
            confirmed: confirmedPriceTagDisplayPoints(),
            pending: pendingPoint.map { [$0] } ?? [])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            guard self.priceTagCaptureCoordinator.isCurrent(generation),
                  self.priceTagCaptureCoordinator.currentState()
                    == .confirming(
                        generation: generation,
                        captureID: captureID) else {
                return
            }
            self.removePriceTagCaptureOverlay(generation: generation)
            guard self.presentedViewController == nil else {
                self.cancelPriceTagCapture(
                    reason: "confirmation_presentation_blocked",
                    userMessage: self.localized("Shelf confirmation could not be shown. The observations were kept for review."),
                    captureIDToFinalize: captureID)
                return
            }
            let controller = PriceTagShelfConfirmationViewController(
                model: PriceTagShelfConfirmationModel(
                    tag: resolution.tag,
                    candidates: resolution.candidates,
                    algorithmCandidateReliable:
                        resolution.algorithmCandidateReliable))
            controller.onDecision = { [weak self, weak controller] decision in
                guard let self,
                      self.priceTagCaptureCoordinator.isCurrent(generation) else {
                    return
                }
                guard self.supermarketSession?
                        .hasLocalizationRequiredWriteFailure() != true else {
                    controller?.dismiss(animated: true) {
                        _ = self.finishPriceTagCapture(
                            generation: generation,
                            payload: resolution.tag.payload,
                            committed: false,
                            outcome: "required_evidence_already_failed")
                        self.showToast(
                            message: self.localized("Required localization evidence has failed. The ESL cannot be finalized; raw RTAB-Map recording continues."),
                            seconds: 6)
                    }
                    return
                }
                switch decision {
                case .rescan:
                    self.recordPriceTagCaptureAudit(
                        .userRescan,
                        generation: generation,
                        captureID: captureID,
                        phase: "confirmation",
                        payload: resolution.tag.payload,
                        symbology: resolution.tag.symbology,
                        sourceReason: "operator_requested_rescan",
                        terminal: false)
                    controller?.dismiss(animated: true) {
                        guard self.finishPriceTagCapture(
                            generation: generation,
                            payload: resolution.tag.payload,
                            committed: false,
                            outcome: "rescan") else { return }
                        self.startPriceTagCapture()
                    }
                case .observationOnly:
                    controller?.dismiss(animated: true) {
                        _ = self.finishPriceTagCapture(
                            generation: generation,
                            payload: resolution.tag.payload,
                            committed: false,
                            outcome: "observation_only")
                    }
                case .confirmedAlgorithmCandidate, .selectedAlternative:
                    guard resolution.algorithmCandidateReliable,
                          !resolution.tag.needsReview else {
                        self.recordPriceTagCaptureAudit(
                            .shelfAmbiguous,
                            generation: generation,
                            captureID: captureID,
                            phase: "confirmation",
                            payload: resolution.tag.payload,
                            symbology: resolution.tag.symbology,
                            sourceReason: "unreliable_confirmation_rejected",
                            terminal: true)
                        controller?.dismiss(animated: true) {
                            _ = self.finishPriceTagCapture(
                                generation: generation,
                                payload: resolution.tag.payload,
                                committed: false,
                                outcome: "unreliable_confirmation_rejected")
                            self.showToast(
                                message: self.localized("No reliable shelf candidate is available. The observations were kept for review."),
                                seconds: 5)
                        }
                        return
                    }
                    let confirmedAtUTC = Date().timeIntervalSince1970
                    let confirmedAtMonotonic =
                        ProcessInfo.processInfo.systemUptime
                    self.priorMapQueue.async {
                        guard self.priceTagCaptureCoordinator.isCurrent(
                            generation),
                              let confirmed = resolution.tag.applyingConfirmation(
                            decision: decision,
                            candidates: resolution.candidates,
                            confirmedAtUTC: confirmedAtUTC,
                            confirmedAtMonotonic: confirmedAtMonotonic) else {
                            self.recordPriceTagCaptureAudit(
                                .confirmationAdmissionRejected,
                                generation: generation,
                                captureID: captureID,
                                phase: "confirmation_selection",
                                payload: resolution.tag.payload,
                                symbology: resolution.tag.symbology,
                                sourceReason: "candidate_identity_rejected",
                                terminal: true)
                            DispatchQueue.main.async {
                                guard self.priceTagCaptureCoordinator.isCurrent(
                                    generation) else { return }
                                controller?.dismiss(animated: true) {
                                    _ = self.finishPriceTagCapture(
                                        generation: generation,
                                        payload: resolution.tag.payload,
                                        committed: false,
                                        outcome: "confirmation_identity_rejected")
                                    self.showToast(
                                        message: self.localized("The selected shelf is no longer a valid candidate. The observations were kept for review."),
                                        seconds: 6)
                                }
                            }
                            return
                        }
                        guard let authority = self.priceTagCaptureCoordinator
                                .pendingConfirmationCommitAuthority(
                                    generation: generation,
                                    captureID: captureID),
                              let scanSession = self.supermarketSession else {
                            self.persistPriceTagCaptureDiagnostics(
                                generation: generation,
                                captureID: captureID,
                                phase: "confirmation_authority")
                            self.recordPriceTagCaptureAudit(
                                .confirmationAdmissionRejected,
                                generation: generation,
                                captureID: captureID,
                                phase: "confirmation_authority",
                                payload: confirmed.payload,
                                symbology: confirmed.symbology,
                                sourceReason: "authority_or_session_unavailable",
                                terminal: true)
                            DispatchQueue.main.async {
                                guard self.priceTagCaptureCoordinator.isCurrent(
                                    generation) else { return }
                                controller?.dismiss(animated: true) {
                                    _ = self.finishPriceTagCapture(
                                        generation: generation,
                                        payload: confirmed.payload,
                                        committed: false,
                                        outcome: "confirmation_authority_unavailable")
                                }
                            }
                            return
                        }
                        let reservation = scanSession
                            .reserveLocalizedPriceTagConfirmation(
                                confirmed,
                                authority: authority)
                        guard reservation.reserved else {
                            self.recordPriceTagCaptureAudit(
                                .confirmationAdmissionRejected,
                                generation: generation,
                                captureID: captureID,
                                phase: "session_reservation",
                                payload: confirmed.payload,
                                symbology: confirmed.symbology,
                                sourceReason: reservation.failure?.rawValue,
                                terminal: true)
                            DispatchQueue.main.async {
                                guard self.priceTagCaptureCoordinator.isCurrent(
                                    generation) else { return }
                                controller?.dismiss(animated: true) {
                                    _ = self.finishPriceTagCapture(
                                        generation: generation,
                                        payload: confirmed.payload,
                                        committed: false,
                                        outcome: "confirmation_reservation_rejected")
                                }
                            }
                            return
                        }
                        guard self.priceTagCaptureCoordinator
                                .claimConfirmationCommit(
                                    generation: generation,
                                    captureID: captureID) == authority else {
                            scanSession
                                .cancelLocalizedPriceTagConfirmationReservation(
                                    authority: authority)
                            self.persistPriceTagCaptureDiagnostics(
                                generation: generation,
                                captureID: captureID,
                                phase: "confirmation_claim")
                            self.recordPriceTagCaptureAudit(
                                .confirmationAdmissionRejected,
                                generation: generation,
                                captureID: captureID,
                                phase: "confirmation_claim",
                                payload: confirmed.payload,
                                symbology: confirmed.symbology,
                                sourceReason: "coordinator_claim_lost",
                                terminal: true)
                            return
                        }
                        let commit = scanSession.recordLocalizedPriceTag(
                            confirmed,
                            authority: authority)
                        let persisted = commit.persisted
                        if persisted {
                            scanSession.appendScanEvent(
                                event: "localized_price_tag_confirmed",
                                message: "Operator confirmed an ESL shelf association without changing SLAM",
                                fields: [
                                    "tag_id": confirmed.tagId,
                                    "capture_id": confirmed.captureId ?? "",
                                    "confirmation_status":
                                        confirmed.confirmationStatus ?? "",
                                    "algorithm_shelf_segment_id":
                                        confirmed.algorithmShelfSegmentId ?? "",
                                    "user_shelf_segment_id":
                                        confirmed.userConfirmedShelfSegmentId ?? "",
                                ])
                        }
                        else {
                            self.recordPriceTagCaptureAudit(
                                .confirmationPersistenceFailed,
                                generation: generation,
                                captureID: captureID,
                                phase: "confirmation_commit",
                                payload: confirmed.payload,
                                symbology: confirmed.symbology,
                                sourceReason: commit.failure?.rawValue,
                                terminal: true)
                        }
                        DispatchQueue.main.async {
                            guard self.priceTagCaptureCoordinator
                                    .isConfirmationCommitInFlight(authority) else {
                                return
                            }
                            let completeCommit = {
                                _ = self.finishPriceTagCapture(
                                    generation: generation,
                                    payload: confirmed.payload,
                                    committed: persisted,
                                    outcome: persisted
                                        ? confirmed.confirmationStatus
                                            ?? "confirmed"
                                        : "confirmation_persistence_failed")
                                self.showToast(
                                    message: persisted
                                        ? self.localized("The localized ESL was saved.")
                                        : self.localized("The localized ESL could not be saved. The observations remain available for review."),
                                    seconds: persisted ? 3 : 6)
                            }
                            if let controller,
                               controller.presentingViewController != nil {
                                controller.dismiss(
                                    animated: true,
                                    completion: completeCommit)
                            }
                            else {
                                completeCommit()
                            }
                        }
                    }
                }
            }
            self.priceTagShelfConfirmationController = controller
            self.present(controller, animated: true)
        }
    }

    @discardableResult
    private func finishPriceTagCapture(
        generation: UUID,
        payload: String,
        committed: Bool,
        retainedForReview: Bool = false,
        outcome: String
    ) -> Bool {
        let completedAt = session.currentFrame?.timestamp
            ?? ProcessInfo.processInfo.systemUptime
        guard priceTagCaptureCoordinator.finishConfirmation(
            generation: generation,
            payload: payload,
            completedAt: completedAt,
            committed: committed,
            retainedForReview: retainedForReview) else {
            persistPriceTagCaptureDiagnostics(
                generation: generation,
                captureID: nil,
                phase: "confirmation_finish")
            return false
        }
        priceTagVisionScanner.cancel(generation: generation)
        removePriceTagCaptureOverlay(generation: generation)
        priceTagShelfConfirmationController = nil
        priceTagCapturePausedReason = nil
        clearPriceTagCaptureResults()
        recordPriceTagCaptureContinuityEnd(
            generation: generation,
            outcome: outcome)
        priorMapOverlay?.updateTagLayers(
            confirmed: confirmedPriceTagDisplayPoints(),
            pending: [])
        supermarketSession?.appendScanEvent(
            event: "price_tag_capture_finished",
            message: "Barcode Capture Mode finished; mapping state was not changed",
            fields: [
                "capture_generation": generation.uuidString.lowercased(),
                "outcome": outcome,
                "committed": committed ? "true" : "false",
                "retained_for_review": retainedForReview ? "true" : "false",
            ])
        return true
    }

    private func cancelPriceTagCapture(
        reason: String,
        userMessage: String?,
        captureIDToFinalize: UUID? = nil,
        preclaimedCancellation: PriceTagCaptureCancellation? = nil
    ) {
        if !Thread.isMainThread {
            DispatchQueue.main.async {
                self.cancelPriceTagCapture(
                    reason: reason,
                    userMessage: userMessage,
                    captureIDToFinalize: captureIDToFinalize,
                    preclaimedCancellation: preclaimedCancellation)
            }
            return
        }
        let presentationGeneration = priceTagCapturePresentationGeneration
        let cancellation = preclaimedCancellation
            ?? priceTagCaptureCoordinator.cancel(reason: reason)
        guard let generation = cancellation?.generation
                ?? priceTagCaptureContinuityStart?.generation
                ?? presentationGeneration else {
            return
        }
        priceTagVisionScanner.cancel(generation: generation)
        if cancellation?.confirmationCommitInFlight == true {
            // The explicit decision already crossed the atomic claim. Hide
            // the UX, but do not turn the ordered durable write into a stale
            // callback; its completion owns final cleanup.
            if let controller = priceTagShelfConfirmationController,
               controller.presentingViewController != nil {
                controller.dismiss(animated: false)
            }
            removePriceTagCaptureOverlay(generation: generation)
            if let scanSession = supermarketSession,
               let expectedTrackingSessionID = priceTagCaptureCoordinator
                    .currentPriorMapAuthority()?.trackingSessionID {
                scanSession.appendScanEventIfSessionActive(
                    expectedTrackingSessionId: expectedTrackingSessionID,
                    allowDuringFinalization:
                        reason == "scan_finalization_started",
                    level: "warning",
                    event: "price_tag_confirmation_cancel_after_commit_claim",
                    message: "Capture cancellation arrived after the confirmation commit was claimed",
                    fields: [
                        "capture_generation": generation.uuidString.lowercased(),
                        "capture_id": cancellation?.captureID?.uuidString
                            .lowercased() ?? "",
                        "reason": reason,
                    ])
            }
            return
        }
        recordPriceTagCaptureAudit(
            .captureCancelled,
            generation: generation,
            captureID: captureIDToFinalize ?? cancellation?.captureID,
            phase: "cancellation",
            sourceReason: reason,
            terminal: true,
            allowDuringFinalization: reason == "scan_finalization_started")
        if let captureID = captureIDToFinalize ?? cancellation?.captureID {
            _ = supermarketSession?.finalizeTagObservationCapture(
                captureID: captureID,
                minimumFrameCount: 3)
            removePriceTagCaptureResults(captureID: captureID)
        }
        if let controller = priceTagShelfConfirmationController,
           controller.presentingViewController != nil {
            controller.dismiss(animated: false)
        }
        priceTagShelfConfirmationController = nil
        priceTagCapturePausedReason = nil
        removePriceTagCaptureOverlay(generation: generation)
        clearPriceTagCaptureResults()
        recordPriceTagCaptureContinuityEnd(
            generation: generation,
            outcome: "cancelled_\(reason)",
            allowDuringFinalization: reason == "scan_finalization_started")
        priorMapOverlay?.updateTagLayers(
            confirmed: confirmedPriceTagDisplayPoints(),
            pending: [])
        if let userMessage {
            showToast(message: userMessage, seconds: 4)
        }
    }

    private func removePriceTagCaptureOverlay(generation: UUID) {
        guard priceTagCapturePresentationGeneration == generation else {
            return
        }
        priceTagCaptureOverlay?.previewView.clear(generation: generation)
        priceTagCaptureOverlay?.removeFromSuperview()
        priceTagCaptureOverlay = nil
        priceTagCapturePresentationGeneration = nil
        if let hidden = priceTagCapturePriorMapOverlayWasHidden {
            priorMapOverlay?.isHidden = hidden
        }
        priceTagCapturePriorMapOverlayWasHidden = nil
    }

    private func appendPriceTagCaptureResult(
        _ result: PriceTagShelfAssociationResult,
        captureID: UUID
    ) {
        priceTagCaptureResultsLock.lock()
        priceTagCaptureFrameResults[captureID, default: []].append(result)
        priceTagCaptureResultsLock.unlock()
    }

    private func priceTagCaptureResults(
        captureID: UUID
    ) -> [PriceTagShelfAssociationResult] {
        priceTagCaptureResultsLock.lock()
        defer { priceTagCaptureResultsLock.unlock() }
        return priceTagCaptureFrameResults[captureID] ?? []
    }

    private func removePriceTagCaptureResults(captureID: UUID) {
        priceTagCaptureResultsLock.lock()
        priceTagCaptureFrameResults.removeValue(forKey: captureID)
        priceTagCaptureResultsLock.unlock()
    }

    private func clearPriceTagCaptureResults() {
        priceTagCaptureResultsLock.lock()
        priceTagCaptureFrameResults.removeAll(keepingCapacity: true)
        priceTagCaptureResultsLock.unlock()
    }

    private func confirmedPriceTagDisplayPoints() -> [PriorMapTagPoint3D] {
        return supermarketSession?.localizedPriceTagSnapshot().compactMap {
            $0.rawMapPosition ?? $0.snappedMapPosition
        } ?? []
    }

    private func activeStreamingDatabaseBytes() -> UInt64 {
        guard let scanSession = supermarketSession,
              let root = scanSession.rootDirectory,
              scanSession.segmentIndex == 1 else {
            return mLatestScanStorageBytes
        }
        let databaseURL = root
            .appendingPathComponent("segment_0001", isDirectory: true)
            .appendingPathComponent("rtabmap_segment_0001.db")
        return ["", "-wal", "-shm", "-journal"].reduce(0) {
            partial, suffix in
            let url = URL(fileURLWithPath: databaseURL.path + suffix)
            let size = (try? FileManager.default.attributesOfItem(
                atPath: url.path)[.size] as? NSNumber)?.uint64Value ?? 0
            return partial + size
        }
    }

    private func activeStreamingDatabaseIdentity() -> String? {
        guard let scanSession = supermarketSession,
              let root = scanSession.rootDirectory,
              scanSession.segmentIndex == 1,
              mState == .STATE_MAPPING,
              !mDataRecording,
              rtabmap != nil else {
            return nil
        }
        let databaseURL = root
            .appendingPathComponent("segment_0001", isDirectory: true)
            .appendingPathComponent("rtabmap_segment_0001.db")
            .standardizedFileURL
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            return nil
        }
        return databaseURL.path
    }

    private func makePriceTagCaptureContinuitySnapshot(
        generation: UUID,
        frameTimestamp: TimeInterval
    ) -> PriceTagCaptureContinuitySample? {
        guard let scanSession = supermarketSession else { return nil }
        let health = scanSession.boundarySnapshot().captureHealth
        let databaseIdentity = activeStreamingDatabaseIdentity()
        return PriceTagCaptureContinuitySample(
            generation: generation,
            capturedAtMonotonic: ProcessInfo.processInfo.systemUptime,
            frameTimestamp: frameTimestamp,
            trackingSessionID: scanSession.trackingSessionId,
            mappingActive: mState == .STATE_MAPPING,
            dataRecording: mDataRecording,
            nativePipelineAvailable: rtabmap != nil,
            databaseWriterReady: databaseIdentity != nil,
            databaseIdentity: databaseIdentity,
            clockWriterReady: clockRecorder != nil
                && clockSidecarWriteFailure == nil,
            sessionFinalizing: scanSession.isFinalizingScan,
            localizationRequiredWriteFailed:
                scanSession.hasLocalizationRequiredWriteFailure(),
            sensorPoseCount: health.sensorPoseCount,
            odometrySubmissionCount: mOdometrySubmissionCount,
            mapNodeCount: mMapNodes,
            databaseBytes: activeStreamingDatabaseBytes(),
            clockBoundNodeID: lastClockBoundNodeID,
            localizationTraceCount: health.localizationTraceRecordCount,
            localizationConstraintCount:
                health.localizationConstraintRecordCount)
    }

    private func recordPriceTagCaptureContinuityEnd(
        generation: UUID,
        outcome: String,
        allowDuringFinalization: Bool = false
    ) {
        guard let start = priceTagCaptureContinuityStart,
              start.generation == generation,
              let end = makePriceTagCaptureContinuitySnapshot(
                generation: generation,
                frameTimestamp: session.currentFrame?.timestamp
                    ?? start.frameTimestamp) else {
            priceTagCaptureContinuityStart = nil
            return
        }
        priceTagCaptureContinuityStart = nil
        let duration = end.capturedAtMonotonic - start.capturedAtMonotonic
        let assessment = PriceTagCaptureContinuityEvaluator.evaluate(
            start: start,
            end: end)
        let level: String
        let event: String
        let message: String
        let reasons: [String]
        switch assessment {
        case .passed:
            level = "info"
            event = "price_tag_capture_continuity_passed"
            message = "AR pose, native odometry submission, prior-map trace and the active database/clock writer identity remained continuous during ESL capture"
            reasons = []
        case .notEvaluable(let values):
            level = "warning"
            event = "price_tag_capture_continuity_not_evaluable"
            message = "The ESL workflow ended before every asynchronous continuity channel could be evaluated"
            reasons = values
        case .failed(let values):
            level = "error"
            event = "price_tag_capture_continuity_failed"
            message = "An ESL capture continuity invariant failed"
            reasons = values
        }
        let databaseByteDelta = end.databaseBytes >= start.databaseBytes
            ? "+\(end.databaseBytes - start.databaseBytes)"
            : "-\(start.databaseBytes - end.databaseBytes)"
        let odometryDelta = end.odometrySubmissionCount
            >= start.odometrySubmissionCount
            ? end.odometrySubmissionCount - start.odometrySubmissionCount
            : 0
        supermarketSession?.appendScanEventIfSessionActive(
            expectedTrackingSessionId: start.trackingSessionID,
            allowDuringFinalization: allowDuringFinalization,
            level: level,
            event: event,
            message: message,
            fields: [
                "capture_generation": generation.uuidString.lowercased(),
                "outcome": outcome,
                "duration_seconds": String(format: "%.3f", duration),
                "assessment_reasons": reasons.joined(separator: ","),
                "tracking_session_unchanged":
                    start.trackingSessionID == end.trackingSessionID
                        ? "true" : "false",
                "mapping_active_at_boundaries":
                    start.mappingActive && end.mappingActive
                        ? "true" : "false",
                "database_writer_ready_at_boundaries":
                    start.databaseWriterReady && end.databaseWriterReady
                        ? "true" : "false",
                "database_identity_unchanged":
                    start.databaseIdentity != nil
                        && start.databaseIdentity == end.databaseIdentity
                        ? "true" : "false",
                "clock_writer_ready_at_boundaries":
                    start.clockWriterReady && end.clockWriterReady
                        ? "true" : "false",
                "sensor_pose_delta":
                    "\(end.sensorPoseCount - start.sensorPoseCount)",
                "odometry_submission_delta": "\(odometryDelta)",
                "map_node_delta":
                    "\(end.mapNodeCount - start.mapNodeCount)",
                "database_byte_delta": databaseByteDelta,
                "database_bytes_are_audit_only": "true",
                "clock_binding_delta":
                    "\(end.clockBoundNodeID - start.clockBoundNodeID)",
                "localization_trace_delta":
                    "\(end.localizationTraceCount - start.localizationTraceCount)",
                "localization_constraint_delta":
                    "\(end.localizationConstraintCount - start.localizationConstraintCount)",
            ])
    }

    @objc private func confirmPriorMapPosition()
    {
        guard let update = priorMapLatestUpdate else {
            showToast(
                message: localized("Wait for the first location update, then confirm again."),
                seconds: 3)
            return
        }
        applyManualPriorMapPose(
            update.estimatedPose,
            reason: "user_confirmed_current_estimate") { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .applied:
                self.showToast(
                    message: self.localized("Position confirmed. The adjustment was added to the audit log."),
                    seconds: 3)
            case .rejected(let message):
                self.showToast(
                    message: message,
                    seconds: 6,
                    replacingCurrent: true)
            }
        }
    }

    @objc private func reselectPriorMapPosition()
    {
        let initial = priorMapLatestUpdate?.estimatedPose
            ?? activeScanConfiguration.initialMapPose
            ?? PriorMapPose2D(xM: 0, yM: 0, yawRad: 0)
        guard let package = activePriorMapPackage,
              let floorId = activeScanConfiguration.floorId else {
            showToast(message: localized("The prior map is no longer available."), seconds: 3)
            return
        }
        guard let picker = PriorMapPoseSelectionViewController(
            package: package,
            floorId: floorId,
            pose: initial,
            completion: { [weak self] pose, finished in
            guard let self else {
                finished(.rejected(message: "扫描界面已关闭，位置未更改。"))
                return
            }
            self.applyManualPriorMapPose(
                pose,
                reason: "user_reselected_map_pose_on_map") { outcome in
                finished(outcome)
                if case .applied = outcome {
                    self.showToast(
                        message: self.localized("Position confirmed. The adjustment was added to the audit log."),
                        seconds: 3)
                }
            }
        })
        else {
            showToast(
                message: localized(
                    "The selected floor is no longer present in the verified map package. The scan was not changed."),
                seconds: 6,
                replacingCurrent: true)
            return
        }
        present(picker, animated: true)
    }

    private func applyManualPriorMapPose(
        _ mapPose: PriorMapPose2D,
        reason: String,
        completion: @escaping (PriorMapManualPoseSubmissionOutcome) -> Void
    ) {
        guard mapPose.xM.isFinite,
              mapPose.yM.isFinite,
              mapPose.yawRad.isFinite else {
            completion(.rejected(message: localized(
                "The selected coordinates are invalid. The position was not changed.")))
            return
        }
        guard let scanSession = supermarketSession,
              scanSession.hasLocalizationRequiredWriteFailure() != true else {
            completion(.rejected(message: localized(
                "Required localization evidence has failed. New prior-map corrections are disabled; raw RTAB-Map recording continues.")))
            return
        }
        guard mState == .STATE_MAPPING,
              !mDataRecording,
              priorMapLocalizer != nil else {
            completion(.rejected(message: localized(
                "Scanning or prior-map localization is not active. The position was not changed.")))
            return
        }

        let currentFrame = session.currentFrame
        let baselineBinding = currentFrame.flatMap {
            rtabmap?.latestNodeBinding(frameTimestamp: $0.timestamp)
        }
        let request = PendingManualPriorMapPoseRequest(
            id: UUID(),
            mapPose: mapPose,
            reason: reason,
            requestedAtWallClock: Date(),
            requestedAtFrameTimestamp: currentFrame?.timestamp,
            baselineNodeID: baselineBinding?.nodeId,
            baselineNodeStamp: baselineBinding?.nodeStamp,
            priorMapGeneration: priorMapGeneration,
            trackingSessionID: scanSession.trackingSessionId,
            completion: completion)

        mManualPriorMapPoseRequestLock.lock()
        guard mPendingManualPriorMapPoseRequest == nil else {
            mManualPriorMapPoseRequestLock.unlock()
            completion(.rejected(message: localized(
                "Another position correction is already waiting for a stable node.")))
            return
        }
        mPendingManualPriorMapPoseRequest = request
        mManualPriorMapPoseRequestLock.unlock()

        scanSession.appendScanEvent(
            event: "manual_localization_requested",
            message: "User requested a durable manual prior-map correction",
            fields: [
                "reason": reason,
                "xM": "\(mapPose.xM)",
                "yM": "\(mapPose.yM)",
                "yawRad": "\(mapPose.yawRad)",
                "baselineNodeId": baselineBinding.map { "\($0.nodeId)" }
                    ?? "unavailable",
                "poseEpoch": "\(mCapturePoseEpoch)",
            ])

        DispatchQueue.main.asyncAfter(
            deadline: .now() + mManualPriorMapPoseTimeoutSeconds) {
            self.expirePendingManualPriorMapPoseRequest(requestID: request.id)
        }
    }

    private func expirePendingManualPriorMapPoseRequest(requestID: UUID) {
        mManualPriorMapPoseRequestLock.lock()
        guard let request = mPendingManualPriorMapPoseRequest,
              request.id == requestID else {
            mManualPriorMapPoseRequestLock.unlock()
            return
        }
        mPendingManualPriorMapPoseRequest = nil
        mManualPriorMapPoseRequestLock.unlock()

        supermarketSession?.appendScanEvent(
            level: "warning",
            event: "manual_localization_event_rejected",
            message: "Manual localization timed out while waiting for a fresh accepted RTAB-Map node",
            fields: ["reason": "fresh_node_timeout"])
        request.completion(.rejected(message: localized(
            "No new stable RTAB-Map node was created in time. Keep the phone steady with the scene visible, then confirm again; your selected coordinates are still shown.")))
    }

    private func cancelPendingManualPriorMapPoseRequest(reason: String) {
        mManualPriorMapPoseRequestLock.lock()
        let request = mPendingManualPriorMapPoseRequest
        mPendingManualPriorMapPoseRequest = nil
        mManualPriorMapPoseRequestLock.unlock()
        guard let request else { return }
        DispatchQueue.main.async {
            request.completion(.rejected(message: self.localized(
                "The scan state changed before the position could be committed. The position was not changed.")))
        }
        supermarketSession?.appendScanEvent(
            level: "warning",
            event: "manual_localization_event_rejected",
            message: "Pending manual localization was cancelled before commit",
            fields: ["reason": reason])
    }

    private func resolvePendingManualPriorMapPoseIfReady(
        frameTimestamp: TimeInterval,
        acceptedTransform: simd_float4x4,
        nodeBinding: RTABMapNodeBindingSnapshot
    ) {
        mManualPriorMapPoseRequestLock.lock()
        guard let request = mPendingManualPriorMapPoseRequest else {
            mManualPriorMapPoseRequestLock.unlock()
            return
        }
        let frameIsNew = request.requestedAtFrameTimestamp.map {
            frameTimestamp > $0
        } ?? true
        let bindingIsFresh: Bool
        if let baselineNodeID = request.baselineNodeID,
           let baselineNodeStamp = request.baselineNodeStamp {
            let publishedAfterRequest = nodeBinding.nodeId != baselineNodeID
                || nodeBinding.nodeStamp > baselineNodeStamp + 0.000_001
            // A node published immediately before the tap is still an exact
            // authority when the accepted frame is within 250 ms of its stamp.
            // This avoids forcing a stationary operator to move merely to
            // manufacture another node, while never reusing the old 1 s cache.
            let sameNodeStillFresh = nodeBinding.nodeId == baselineNodeID
                && nodeBinding.deltaSeconds <= 0.25
            bindingIsFresh = publishedAfterRequest || sameNodeStillFresh
        }
        else {
            bindingIsFresh = nodeBinding.deltaSeconds <= 0.25
        }
        guard frameIsNew, bindingIsFresh else {
            mManualPriorMapPoseRequestLock.unlock()
            return
        }
        mPendingManualPriorMapPoseRequest = nil
        mManualPriorMapPoseRequestLock.unlock()

        let localizer = priorMapLocalizer
        let confirmationWallClock = Date()
        let requestLatency = confirmationWallClock.timeIntervalSince(
            request.requestedAtWallClock)
        let poseEpoch = mCapturePoseEpoch
        let generation = priorMapGeneration
        priorMapQueue.async {
            guard generation == request.priorMapGeneration,
                  generation == self.priorMapGeneration,
                  let localizer,
                  let scanSession = self.supermarketSession,
                  scanSession.trackingSessionId == request.trackingSessionID,
                  !scanSession.isFinalizingScan,
                  !scanSession.hasLocalizationRequiredWriteFailure() else {
                DispatchQueue.main.async {
                    request.completion(.rejected(message: self.localized(
                        "The scan state changed before the position could be committed. The position was not changed.")))
                }
                return
            }
            let candidate = localizer.prepareManualPosition(
                transform: acceptedTransform,
                mapPose: request.mapPose)
            // Durable-first transaction: an append failure leaves the live
            // alignment untouched. The old implementation mutated alignment
            // before this call and could not roll it back safely.
            let eventPersisted = scanSession.appendManualLocalizationEvent(
                reason: request.reason,
                arkitPose: candidate.arkitPose,
                confirmedMapPose: candidate.confirmedMapPose,
                wallClock: confirmationWallClock,
                frameTimestamp: frameTimestamp,
                nodeTimebaseFrameTimestamp:
                    nodeBinding.nodeTimebaseFrameTimestamp,
                nodeTimebaseOffsetSeconds:
                    nodeBinding.nodeTimebaseOffsetSeconds,
                nearestNodeId: nodeBinding.nodeId,
                nearestNodeStamp: nodeBinding.nodeStamp,
                nodeTimeDeltaSeconds: nodeBinding.deltaSeconds,
                nodeTimeSnapshotGeneration: nodeBinding.generation,
                alignmentVersion: candidate.committedAlignmentVersion,
                expectedTrackingSessionId: request.trackingSessionID)
            guard eventPersisted else {
                scanSession.appendScanEvent(
                    level: "error",
                    event: "manual_localization_event_write_failed",
                    message: "Manual localization audit persistence failed before the live alignment was changed",
                    fields: ["reason": request.reason])
                DispatchQueue.main.async {
                    self.presentLocalizationEvidenceWriteFailure(
                        ["manual_localization_events.jsonl"])
                    request.completion(.rejected(message: self.localized(
                        "The audit record could not be saved, so the position was not changed. Raw scanning remains safe; stop and recover this scan before another correction.")))
                }
                return
            }

            guard localizer.commitManualPosition(candidate) else {
                // This cannot occur while every mutation stays serialized on
                // priorMapQueue. Keep it non-crashing and preserve evidence so
                // the field report contains the exact integrity failure.
                scanSession.recordManualLocalizationCommitConflict()
                scanSession.appendScanEvent(
                    level: "error",
                    event: "manual_localization_commit_conflict",
                    message: "A durable manual event could not be committed because the alignment version changed",
                    fields: [
                        "expectedAlignmentVersion":
                            "\(candidate.expectedAlignmentVersion)",
                        "committedAlignmentVersion":
                            "\(candidate.committedAlignmentVersion)",
                    ])
                DispatchQueue.main.async {
                    request.completion(.rejected(message: self.localized(
                        "The correction encountered an internal alignment conflict. The audit evidence was preserved; continue raw scanning and export diagnostics.")))
                }
                return
            }

            if let snapshot = localizer.alignmentSnapshot(
                    frameTimestamp: frameTimestamp) {
                self.priorMapAlignmentSnapshots.publish(snapshot)
            }
            self.shelfTrackingStateMachine = ShelfTrackingStateMachine()
            self.recentShelfTrackingDegradationCount = 0
            scanSession.appendScanEvent(
                event: "manual_localization_confirmed",
                message: "User confirmed a prior-map position after durable evidence commit",
                fields: [
                    "reason": request.reason,
                    "xM": "\(request.mapPose.xM)",
                    "yM": "\(request.mapPose.yM)",
                    "yawRad": "\(request.mapPose.yawRad)",
                    "nodeId": "\(nodeBinding.nodeId)",
                    "requestLatencySeconds": String(
                        format: "%.3f", requestLatency),
                    "poseEpoch": "\(poseEpoch)",
                ])
            DispatchQueue.main.async {
                self.priorMapOverlay?.updateShelfTrackingDecision(
                    ShelfTrackingDecision(
                        state: .tracking,
                        selectedCorridorID: nil,
                        lowConfidenceReasons: []))
                request.completion(.applied)
            }
        }
    }
    
    /// Returns true only when the scan actually started (V1R3 §4.2):
    /// every failure path returns false instead of a silent return so
    /// callers can never mistake a refused start for a success.
    @discardableResult
    func newScan(
        dataRecordingMode: Bool = false,
        configuration: PriorMapScanConfiguration = .freeMapping,
        preparedPriorMapPackage: PriorMapPackage? = nil
    ) -> Bool
    {
        guard mState != .STATE_MAPPING else {
            showToast(
                message: localized("A scan is in progress. Use the Stop button before starting another scan."),
                seconds: 4)
            return false
        }
        if dataRecordingMode {
            _ = preparePriorMapLocalization(configuration: .freeMapping)
        }
        else {
            guard preparePriorMapLocalization(
                    configuration: configuration,
                    preparedPackage: preparedPriorMapPackage) else {
                return false
            }
        }

        print("databases.size() = \(databases.size())")
        if(databases.count >= 10 && !mReviewRequested && self.depthSupported)
        {
            SKStoreReviewController.requestReviewInCurrentScene()
            mReviewRequested = true
        }
        
        if(mState == State.STATE_VISUALIZING)
        {
            closeVisualization()
        }
        
        mMapNodes = 0;
        self.openedDatabasePath = nil
        let tmpDatabase = self.getDocumentDirectory().appendingPathComponent(self.RTABMAP_TMP_DB)
        // The canonical mobile-only path writes to its session-scoped
        // streaming database, never to the legacy Documents/rtabmap.tmp.db.
        // Do not present the legacy asynchronous recovery continuation here:
        // it would return `false` to the coordinator and could later start a
        // scan outside the receipt transaction after the user taps Ignore.
        if(preparedPriorMapPackage == nil &&
           !(self.mState == State.STATE_CAMERA || self.mState == State.STATE_MAPPING) &&
           FileManager.default.fileExists(atPath: tmpDatabase.path) &&
           tmpDatabase.fileSize > 1024*1024) // > 1MB
        {
            dismiss(animated: true, completion: {
                let msg = "The previous session (\(tmpDatabase.fileSizeString)) was not correctly saved, do you want to recover it?"
                let alert = UIAlertController(title: "Recovery", message: msg, preferredStyle: .alert)
                let alertActionNo = UIAlertAction(title: "Ignore", style: .destructive) {
                    (UIAlertAction) -> Void in
                    do {
                        try FileManager.default.removeItem(at: tmpDatabase)
                    }
                    catch {
                        print("Could not clear tmp database: \(error)")
                    }
                    self.newScan(
                        dataRecordingMode: dataRecordingMode,
                        configuration: configuration,
                        preparedPriorMapPackage: preparedPriorMapPackage)
                }
                alert.addAction(alertActionNo)
                let alertActionCancel = UIAlertAction(title: "Cancel", style: .cancel) {
                    (UIAlertAction) -> Void in
                    // do nothing
                }
                alert.addAction(alertActionCancel)
                let alertActionYes = UIAlertAction(title: "Yes", style: .default) {
                    (UIAlertAction2) -> Void in

                    let fileName = Date().getFormattedDate(format: "yyMMdd-HHmmss") + ".db"
                    let outputDbPath = self.getDocumentDirectory().appendingPathComponent(fileName).path
                    
                    var indicator: UIActivityIndicatorView?
                    
                    let alertView = UIAlertController(title: "Recovering", message: "Please wait while recovering data...", preferredStyle: .alert)
                    let alertViewActionCancel = UIAlertAction(title: "Cancel", style: .cancel) {
                        (UIAlertAction) -> Void in
                        self.dismiss(animated: true, completion: {
                            self.progressView = nil
                            
                            indicator = UIActivityIndicatorView(style: .large)
                            indicator?.frame = CGRect(x: 0.0, y: 0.0, width: 60.0, height: 60.0)
                            indicator?.center = self.view.center
                            if let indicator {
                                self.view.addSubview(indicator)
                                indicator.bringSubviewToFront(self.view)
                                indicator.startAnimating()
                            }
                            self.rtabmap?.cancelProcessing();
                        })
                    }
                    alertView.addAction(alertViewActionCancel)
                    
                    let previousState = self.mState
                    self.updateState(state: .STATE_PROCESSING);
                    
                    self.present(alertView, animated: true, completion: {
                        //  Add your progressbar after alert is shown (and measured)
                        let margin:CGFloat = 8.0
                        let rect = CGRect(x: margin, y: 84.0, width: alertView.view.frame.width - margin * 2.0 , height: 2.0)
                        let progressView = UIProgressView(frame: rect)
                        progressView.progress = 0
                        progressView.tintColor = self.view.tintColor
                        self.progressView = progressView
                        alertView.view.addSubview(progressView)
                        
                        var success : Bool = false
                        DispatchQueue.background(background: {
                            
                            success = self.rtabmap?.recover(
                                from: tmpDatabase.path,
                                to: outputDbPath) ?? false
                            
                        }, completion:{
                            indicator?.stopAnimating()
                            indicator?.removeFromSuperview()
                            if self.progressView != nil
                            {
                                self.dismiss(animated: self.openedDatabasePath == nil, completion: {
                                    if(success)
                                    {
                                        let alertSaved = UIAlertController(title: "Database saved!", message: String(format: "Database \"%@\" successfully recovered!", fileName), preferredStyle: .alert)
                                        let yes = UIAlertAction(title: "OK", style: .default) {
                                            (UIAlertAction) -> Void in
                                            self.openDatabase(fileUrl: URL(fileURLWithPath: outputDbPath))
                                        }
                                        alertSaved.addAction(yes)
                                        self.present(alertSaved, animated: true, completion: nil)
                                    }
                                    else
                                    {
                                        self.updateState(state: previousState);
                                        self.showToast(message: "Recovery failed!", seconds: 4)
                                    }
                                })
                            }
                            else
                            {
                                self.showToast(message: "Recovery canceled", seconds: 2)
                                self.updateState(state: previousState);
                            }
                        })
                    })
                }
                alert.addAction(alertActionYes)
                self.present(alert, animated: true, completion: nil)
            })
        }
        else
        {
            applySupermarketSettings()
            let didStartSecurityScope = supermarketSession?.startAccessingBaseDirectorySecurityScope() ?? false
            do {
                try supermarketSession?.startNewSessionIfNeeded()
                supermarketSession?.resetCurrentSegment()
                supermarketSession?.configureScan(configuration)
                if let scanSession = supermarketSession {
                    MarketScannerCrashDiagnostics.shared.markScanActive(
                        trackingSessionID: scanSession.trackingSessionId,
                        rootDirectory: scanSession.rootDirectory)
                }
            }
            catch {
                showToast(message: String(format: localized("Could not create supermarket session: %@"), error.localizedDescription), seconds: 4)
                if didStartSecurityScope {
                    supermarketSession?.stopAccessingBaseDirectorySecurityScope()
                }
                return false
            }
            if didStartSecurityScope {
                supermarketSession?.stopAccessingBaseDirectorySecurityScope()
            }
            var activeDatabase = tmpDatabase
            if !dataRecordingMode {
                do {
                    guard let streamURL = try supermarketSession?.streamingDatabaseURL() else {
                        throw NSError(
                            domain: "SupermarketScan",
                            code: 1,
                            userInfo: [NSLocalizedDescriptionKey: localized("Streaming database path is unavailable")])
                    }
                    activeDatabase = streamURL
                }
                catch {
                    showToast(message: String(format: localized("Could not create streaming database: %@"), error.localizedDescription), seconds: 4)
                    return false
                }
            }
            let inMemory = dataRecordingMode ? UserDefaults.standard.bool(forKey: "DatabaseInMemory") : false
            guard let nativeHost = rtabmap else {
                showToast(
                    message: localized(
                        "The native scanning engine is unavailable. Restart the app before starting a scan."),
                    seconds: 5)
                supermarketSession?.appendScanEvent(
                    level: "error",
                    event: "native_host_unavailable_before_database_open",
                    message: "Scan start stopped before opening the database")
                return false
            }
            mDataRecording = dataRecordingMode
            nativeHost.setDataRecorderMode(enabled: dataRecordingMode)
            applyStreamingMappingSettings()
            nativeHost.setPreserveCameraOrigin(enabled: false)
            self.optimizedGraphShown = true // Always reset to true when opening a database
            nativeHost.openDatabase(
                databasePath: activeDatabase.path,
                databaseInMemory: inMemory,
                optimize: false,
                clearDatabase: true)
            self.mLatestDatabaseMemoryMB = 0
            self.mLatestScanStorageBytes = 0
            self.resetStreamingPerformanceTelemetry()
            self.mLastStreamingCheckpointAt = 0
            self.mStreamingCheckpointInFlight = false
            self.mStreamingDiskWarningShown = false
            self.mStreamingCriticalStopRequested = false
            self.mStreamingThermalWarningShown = false
            self.mStreamingThermalPolicyLevel = 0
            self.mStreamingMemoryPressureLevel = 0
            self.mLastLoggedTrackingState = ""
            self.resetSoftwarePoseStabilizer()
            self.resetSupermarketScanQualityAdvisors()
            if !dataRecordingMode {
                self.supermarketSession?.appendScanEvent(
                    event: "scan_started",
                    message: "Continuous streaming scan started",
                    fields: [
                        "database": activeDatabase.lastPathComponent,
                        "workingMemoryNodes": "\(self.supermarketIntDefault(self.supermarketStreamingMemoryNodesKey, fallback: self.supermarketDefaultStreamingMemoryNodes))",
                        "errorOptimizationProfile": "software_only_no_fiducials",
                        "fiducialsEnabled": "false",
                        "onlinePoseCorrection": "rtabmap_map_to_odom_v1",
                        "reliableLoopMinimumNodeSpan": "\(self.mReliableLoopMinimumNodeSpan)",
                        "structureCoverageAdvisor": "map_frame_world_grid_v2",
                        "adaptiveDetectionRateHz": "1.0-2.0",
                        "optimizeMaxErrorApplied": String(
                            format: "%.1f", self.mStreamingOptimizeMaxError),
                        "minimumVisualInliersApplied":
                            "\(self.mStreamingMinimumVisualInliers)",
                        "workflowMode": configuration.workflowMode.rawValue,
                        "priorMapId": configuration.priorMapId ?? "",
                        "floorId": configuration.floorId ?? ""
                    ])
            }
            
            if(!(self.mState == State.STATE_CAMERA || self.mState == State.STATE_MAPPING))
            {
                if(mDataRecording) {
                    let alertController = UIAlertController(title: "Data Recording Mode", message: "This mode should be only used if you want to record raw ARKit data as long as possible without any feedback: loop closure detection and map rendering are disabled. The database size in Debug display shows how much data has been recorded so far.", preferredStyle: .alert)
                    
                    let okAction = UIAlertAction(title: "OK", style: .default) { (action) in
                    }
                    alertController.addAction(okAction)
                    
                    present(alertController, animated: true)
                    self.debugShown = true
                }
                
                self.setGLCamera(type: 0);
                return self.startCamera();
            }
            return true
        }
        // The unsaved-session recovery alert path starts asynchronously
        // after user confirmation; it cannot produce a synchronous
        // start receipt, so report it as not started (V1R3 §4.2).
        return false
    }

    private func supermarketIntDefault(_ key: String, fallback: Int) -> Int
    {
        let value = UserDefaults.standard.object(forKey: key)
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let text = value as? String, let parsed = Int(text) {
            return parsed
        }
        return fallback
    }

    private func applySupermarketSettings()
    {
        let defaults = UserDefaults.standard
        migrateSupermarketDefaultsIfNeeded(defaults)

        if let bookmarkData = defaults.data(forKey: supermarketSaveLocationBookmarkKey) {
            do {
                var isStale = false
                let url = try URL(
                    resolvingBookmarkData: bookmarkData,
                    options: [],
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale)
                supermarketSession?.setCustomBaseDirectory(url)
                if isStale {
                    saveSupermarketLocationBookmark(url)
                }
            }
            catch {
                supermarketSession?.clearCustomBaseDirectory()
                defaults.removeObject(forKey: supermarketSaveLocationBookmarkKey)
                defaults.removeObject(forKey: supermarketSaveLocationNameKey)
            }
        }
        else {
            supermarketSession?.clearCustomBaseDirectory()
        }
    }

    private func migrateSupermarketDefaultsIfNeeded(_ defaults: UserDefaults)
    {
        guard defaults.integer(forKey: supermarketDefaultsVersionKey) < supermarketDefaultsVersion else {
            return
        }

        // Remove obsolete runtime switches so an older installation cannot
        // silently reactivate database rollover or memory-triggered segments.
        [
            "SupermarketAreaThresholdM2",
            "SupermarketDatabaseThresholdMB",
            "SupermarketUsedMemoryThresholdMB",
            "SupermarketMinimumNodesBeforeRollover",
            "SupermarketAutoSegmentExportEnabled",
            "SupermarketStreamingScanEnabled"
        ].forEach { defaults.removeObject(forKey: $0) }
        if defaults.object(forKey: supermarketStreamingMemoryNodesKey) == nil {
            defaults.set(supermarketDefaultStreamingMemoryNodes, forKey: supermarketStreamingMemoryNodesKey)
        }
        defaults.set(supermarketDefaultsVersion, forKey: supermarketDefaultsVersionKey)
    }

    private func applyStreamingMappingSettings()
    {
        guard let rtabmap = rtabmap else {
            return
        }
        let defaults = UserDefaults.standard
        let memoryNodes = max(
            50,
            supermarketIntDefault(
                supermarketStreamingMemoryNodesKey,
                fallback: supermarketDefaultStreamingMemoryNodes))
        let streamingActive = !mDataRecording
        rtabmap.setStreamingMapMode(
            enabled: streamingActive,
            maxRenderedNodes: memoryNodes + 50)
        if streamingActive {
            // RTAB-Map continuously saves transferred nodes through
            // DBDriver::asyncSave(). Important/high-weight and recent nodes stay
            // in WM, while older low-weight nodes become on-disk LTM entries.
            rtabmap.setMappingParameter(key: "Mem/IncrementalMemory", value: "true")
            rtabmap.setMappingParameter(key: "Mem/STMSize", value: "20")
            rtabmap.setMappingParameter(key: "Mem/ImageKept", value: "false")
            rtabmap.setMappingParameter(key: "Mem/InitWMWithAllNodes", value: "false")
            rtabmap.setMappingParameter(key: "Mem/RecentWmRatio", value: "0.2")
            rtabmap.setMappingParameter(key: "Mem/TransferSortingByWeightId", value: "false")
            rtabmap.setMappingParameter(key: "Rtabmap/MemoryThr", value: "\(memoryNodes)")
            // Start conservatively, then let scan-time structure novelty raise
            // the rate to 1.5-2 Hz only around new, fragmented shelf evidence.
            rtabmap.setMappingParameter(key: "Rtabmap/DetectionRate", value: "1.0")
            // Keep enough phone-side visual feedback to catch bad coverage and
            // obvious loop closures, while PC reprocessing remains authoritative.
            rtabmap.setMappingParameter(key: "Kp/MaxFeatures", value: "500")
            rtabmap.setMappingParameter(key: "Rtabmap/MaxRetrieved", value: "3")
            rtabmap.setMappingParameter(key: "Rtabmap/LoopThr", value: "0.15")
            rtabmap.setMappingParameter(key: "RGBD/MaxLocalRetrieved", value: "3")
            rtabmap.setMappingParameter(key: "RGBD/ProximityByTime", value: "true")
            rtabmap.setMappingParameter(key: "RGBD/ProximityBySpace", value: "true")
            rtabmap.setMappingParameter(key: "RGBD/ProximityOdomGuess", value: "true")
            let appliedOptimizeMaxError = String(
                format: "%.1f", mStreamingOptimizeMaxError)
            rtabmap.setMappingParameter(
                key: "RGBD/OptimizeMaxError",
                value: appliedOptimizeMaxError)
            rtabmap.setMappingParameter(key: "RGBD/OptimizeMaxErrorRepairRadius", value: "1.0")
            rtabmap.setMappingParameter(
                key: "Vis/MinInliers",
                value: "\(mStreamingMinimumVisualInliers)")
            rtabmap.setMappingParameter(key: "Mem/UseOdomGravity", value: "true")
            rtabmap.setMappingParameter(key: "Optimizer/Iterations", value: "30")
            rtabmap.setMappingParameter(key: "Optimizer/GravitySigma", value: "0.2")
            rtabmap.setMappingParameter(key: "Optimizer/Robust", value: "true")
            rtabmap.setMappingParameter(key: "Optimizer/PriorsIgnored", value: "true")
            rtabmap.setMappingParameter(key: "Optimizer/LandmarksIgnored", value: "true")
            rtabmap.setMappingParameter(key: "RGBD/MarkerDetection", value: "false")
            if let trackingSessionID = supermarketSession?.trackingSessionId,
               trackingSessionID != mLastStreamingSettingsAuditTrackingSessionID {
                mLastStreamingSettingsAuditTrackingSessionID = trackingSessionID
                supermarketSession?.appendScanEvent(
                    event: "streaming_mapping_profile_applied",
                    message: "The authoritative continuous-scan mapping profile was applied",
                    fields: [
                        "optimizeMaxErrorApplied": appliedOptimizeMaxError,
                        "optimizeMaxErrorUserSetting": defaults.string(
                            forKey: "MaxOptimizationError") ?? "unset",
                        "minimumVisualInliersApplied":
                            "\(mStreamingMinimumVisualInliers)",
                        "loopThresholdApplied": "0.15",
                        "authority": "continuous_streaming_profile_v1",
                    ])
            }
        }
        else {
            rtabmap.setMappingParameter(
                key: "Rtabmap/MemoryThr",
                value: defaults.string(forKey: "MemoryLimit") ?? "0")
        }
    }

    private func saveSupermarketLocationBookmark(_ url: URL)
    {
        do {
            let bookmarkData = try url.bookmarkData(options: [.minimalBookmark], includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(bookmarkData, forKey: supermarketSaveLocationBookmarkKey)
            UserDefaults.standard.set(url.lastPathComponent, forKey: supermarketSaveLocationNameKey)
        }
        catch {
            showToast(message: String(format: localized("Could not save scan folder permission: %@"), error.localizedDescription), seconds: 3)
        }
    }

    private func selectedSupermarketLocationName() -> String
    {
        return UserDefaults.standard.string(forKey: supermarketSaveLocationNameKey) ?? localized("Default Location")
    }

    private func currentThermalStateText() -> String
    {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal:
            return "nominal"
        case .fair:
            return "fair"
        case .serious:
            return "serious"
        case .critical:
            return "critical"
        @unknown default:
            return "unknown"
        }
    }

    private func availableDiskBytes(at directory: URL) -> Int64?
    {
        return try? directory.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
    }

    private func databaseBytes(at url: URL) -> UInt64
    {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]) else {
            return 0
        }
        return UInt64(max(0, values.fileSize ?? 0))
    }

    private func databaseStorageBytes(at url: URL) -> UInt64
    {
        // SQLite may hold recently streamed frames in WAL/journal sidecars.
        // Include them so the HUD reports actual storage, not RTAB-Map's WM.
        let candidates = [
            url,
            URL(fileURLWithPath: url.path + "-wal"),
            URL(fileURLWithPath: url.path + "-shm"),
            URL(fileURLWithPath: url.path + "-journal")
        ]
        return candidates.reduce(UInt64(0)) { $0 + databaseBytes(at: $1) }
    }

    private func captureDirectoryStorageBytes(at directory: URL) -> UInt64
    {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]) else {
            return 0
        }
        return files.reduce(UInt64(0)) { total, file in
            guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else {
                return total
            }
            return total + UInt64(max(0, values.fileSize ?? 0))
        }
    }

    private func currentContinuousScanStorageBytes() -> UInt64
    {
        guard !mDataRecording,
              mState == .STATE_MAPPING,
              let scanSession = supermarketSession,
              scanSession.rootDirectory != nil,
              let captureDirectory = try? scanSession.currentSegmentDirectory() else {
            return mLatestScanStorageBytes
        }
        return captureDirectoryStorageBytes(at: captureDirectory)
    }

    private func formattedStorageSize(_ bytes: UInt64) -> String
    {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: Int64(min(bytes, UInt64(Int64.max))))
    }

    private func processCPUTimeSeconds() -> Double?
    {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else {
            return nil
        }
        let user = Double(usage.ru_utime.tv_sec)
            + Double(usage.ru_utime.tv_usec) / 1_000_000.0
        let system = Double(usage.ru_stime.tv_sec)
            + Double(usage.ru_stime.tv_usec) / 1_000_000.0
        let total = user + system
        return total.isFinite && total >= 0 ? total : nil
    }

    private func resetStreamingPerformanceTelemetry()
    {
        mLatestPerformanceUpdateTimeMS = nil
        mLatestPerformanceFPS = nil
        mLatestPerformanceWordCount = nil
        mLatestPerformanceFeatureCount = nil
        mLatestPerformancePointCount = nil
        mLatestPerformancePolygonCount = nil
        mLastPerformanceSampleUptime = 0
        mLastPerformanceCPUTimeSeconds = nil
        mPerformanceWriteFailureReported = false
    }

    private func recordStreamingPerformanceSample(
        nodeCount: Int? = nil,
        databaseMemoryMB: Int? = nil,
        scanStorageBytes: UInt64? = nil,
        updateTimeMS: Double? = nil,
        renderingFPS: Double? = nil,
        wordCount: Int? = nil,
        featureCount: Int? = nil,
        pointCount: Int? = nil,
        polygonCount: Int? = nil,
        force: Bool = false,
        scanState: String = "mapping"
    ) {
        guard !mDataRecording,
              let scanSession = supermarketSession,
              scanSession.rootDirectory != nil else {
            return
        }
        let uptime = ProcessInfo.processInfo.systemUptime
        guard force || mLastPerformanceSampleUptime == 0
                || uptime - mLastPerformanceSampleUptime >= 5.0 else {
            return
        }
        let cpuTime = processCPUTimeSeconds()
        let cpuPercent: Double?
        if let cpuTime,
           let previousCPU = mLastPerformanceCPUTimeSeconds,
           mLastPerformanceSampleUptime > 0,
           uptime > mLastPerformanceSampleUptime,
           cpuTime >= previousCPU {
            cpuPercent = (cpuTime - previousCPU)
                / (uptime - mLastPerformanceSampleUptime) * 100.0
        } else {
            cpuPercent = nil
        }
        mLastPerformanceSampleUptime = uptime
        mLastPerformanceCPUTimeSeconds = cpuTime

        let segmentDirectory: URL
        let databaseURL: URL
        do {
            segmentDirectory = try scanSession.currentSegmentDirectory()
            databaseURL = try scanSession.streamingDatabaseURL()
        } catch {
            if !mPerformanceWriteFailureReported {
                mPerformanceWriteFailureReported = true
                scanSession.appendScanEvent(
                    level: "warning",
                    event: "performance_sample_failed",
                    message: "Performance evidence path was unavailable",
                    fields: ["error": error.localizedDescription])
            }
            return
        }
        let availableMemoryBytes = ProcessingResourceGovernor.availableMemoryBytes()
        let memoryFootprintMB = ProcessingResourceGovernor.currentMemoryFootprintMB()
        let battery = ProcessingResourceGovernor.batteryPercent()
        let persisted = scanSession.appendPerformanceSample(
            ScanPerformanceSampleInput(
                timestampUnix: Date().timeIntervalSince1970,
                processUptimeSeconds: uptime,
                scanState: scanState,
                trackingState: mLastLoggedTrackingState.isEmpty
                    ? "unknown" : mLastLoggedTrackingState,
                nodeCount: max(0, nodeCount ?? mMapNodes),
                databaseMemoryMB: max(
                    0, databaseMemoryMB ?? mLatestDatabaseMemoryMB),
                databaseBytes: databaseStorageBytes(at: databaseURL),
                scanStorageBytes: scanStorageBytes
                    ?? captureDirectoryStorageBytes(at: segmentDirectory),
                processMemoryFootprintMB: memoryFootprintMB > 0
                    ? memoryFootprintMB : nil,
                availableMemoryMB: availableMemoryBytes >= 0
                    ? availableMemoryBytes / (1024 * 1024) : nil,
                processCPUTimeSeconds: cpuTime,
                processCPUPercent: cpuPercent,
                thermalState: currentThermalStateText(),
                batteryPercent: battery >= 0 ? Double(battery) : nil,
                batteryCharging: battery >= 0
                    ? ProcessingResourceGovernor.isBatteryCharging() : nil,
                availableDiskBytes: availableDiskBytes(at: segmentDirectory),
                renderingFPS: max(0, renderingFPS
                    ?? mLatestPerformanceFPS ?? 0),
                rtabmapUpdateTimeMS: max(0, updateTimeMS
                    ?? mLatestPerformanceUpdateTimeMS ?? 0),
                wordCount: max(0, wordCount
                    ?? mLatestPerformanceWordCount ?? 0),
                featureCount: max(0, featureCount
                    ?? mLatestPerformanceFeatureCount ?? 0),
                pointCount: max(0, pointCount
                    ?? mLatestPerformancePointCount ?? 0),
                polygonCount: max(0, polygonCount
                    ?? mLatestPerformancePolygonCount ?? 0),
                onlineLoopClosureCount: max(0, mTotalLoopClosures),
                reliableLoopClosureCount: max(0, mReliableLoopClosures)),
            sealAfterAppend: force && scanState == "finalizing")
        if !persisted && !mPerformanceWriteFailureReported {
            mPerformanceWriteFailureReported = true
            scanSession.appendScanEvent(
                level: "warning",
                event: "performance_sample_failed",
                message: "Performance evidence could not be persisted",
                fields: [
                    "policy": "map_data_remains_valid_performance_qualification_closed"
                ])
        }
    }

    private func applyStreamingMemoryPressurePolicy(availableMemoryMB: Int)
    {
        guard !mDataRecording else {
            return
        }
        let level: Int
        let memoryNodes: Int
        let renderedNodes: Int
        if availableMemoryMB < 350 {
            level = 3
            memoryNodes = 60
            renderedNodes = 80
        }
        else if availableMemoryMB < 700 {
            level = 2
            memoryNodes = 100
            renderedNodes = 130
        }
        else if availableMemoryMB < 1200 {
            level = 1
            memoryNodes = 180
            renderedNodes = 220
        }
        else {
            return
        }
        guard level > mStreamingMemoryPressureLevel else {
            return
        }
        mStreamingMemoryPressureLevel = level
        // This transfers older WM nodes to the same on-disk database and
        // trims only disposable live rendering. Capture, ARKit and timestamps
        // continue without a modal dialog or trajectory boundary.
        rtabmap?.setStreamingMapMode(enabled: true, maxRenderedNodes: renderedNodes)
        rtabmap?.setMappingParameter(key: "Rtabmap/MemoryThr", value: "\(memoryNodes)")
        supermarketSession?.appendScanEvent(
            level: "warning",
            event: "memory_policy_adjusted",
            message: "Live memory window reduced; streaming capture continued",
            fields: [
                "availableMemoryMB": "\(availableMemoryMB)",
                "workingMemoryNodes": "\(memoryNodes)",
                "renderedNodes": "\(renderedNodes)"
            ])
        showToast(
            message: localized("Memory pressure detected. Older frames remain on disk; live preview was reduced without stopping the scan."),
            seconds: 4)
    }

    private func updateStreamingCaptureHealth(nodeCount: Int, databaseMemoryMB: Int, usedMemoryMB: Int)
    {
        guard !mDataRecording,
              !mStreamingCriticalStopRequested,
              let scanSession = supermarketSession else {
            return
        }
        let now = Date().timeIntervalSince1970
        guard now - mLastStreamingCheckpointAt >= 15.0 else {
            return
        }
        mLastStreamingCheckpointAt = now

        let segmentDirectory: URL
        let databaseURL: URL
        do {
            segmentDirectory = try scanSession.currentSegmentDirectory()
            databaseURL = try scanSession.streamingDatabaseURL()
        }
        catch {
            print("Could not create streaming health checkpoint: \(error)")
            return
        }

        let freeDiskBytes = availableDiskBytes(at: segmentDirectory)
        let actualDatabaseBytes = databaseStorageBytes(at: databaseURL)
        let scanStorageBytes = captureDirectoryStorageBytes(at: segmentDirectory)
        mLatestScanStorageBytes = scanStorageBytes
        let thermalState = currentThermalStateText()
        scanSession.updateStructureCoverageSummary(mStructureCoverageAdvisor.summary())
        let checkpoint = scanSession.makeLiveCheckpoint(
            nodeCount: nodeCount,
            databaseBytes: actualDatabaseBytes,
            availableDiskBytes: freeDiskBytes,
            usedMemoryMB: usedMemoryMB,
            thermalState: thermalState)

        applyStreamingMemoryPressurePolicy(availableMemoryMB: getAvailableMemory())
        scanSession.appendScanEvent(
            event: "health_checkpoint",
            message: "Continuous capture health checkpoint",
            fields: [
                "nodeCount": "\(nodeCount)",
                "databaseMemoryMB": "\(databaseMemoryMB)",
                "scanStorageBytes": "\(scanStorageBytes)",
                "usedMemoryMB": "\(usedMemoryMB)",
                "availableDiskBytes": freeDiskBytes.map(String.init) ?? "unknown",
                "thermalState": thermalState
            ])

        if !mStreamingCheckpointInFlight {
            mStreamingCheckpointInFlight = true
            DispatchQueue.background(background: {
                do {
                    try scanSession.writeLiveCheckpoint(
                        to: segmentDirectory,
                        checkpoint: checkpoint)
                }
                catch {
                    print("Could not write live scan checkpoint: \(error)")
                }
            }, completion: {
                self.mStreamingCheckpointInFlight = false
            })
        }

        if let freeDiskBytes = freeDiskBytes {
            let freeGB = Double(freeDiskBytes) / 1024.0 / 1024.0 / 1024.0
            if freeDiskBytes < 1024 * 1024 * 1024 {
                mStreamingCriticalStopRequested = true
                scanSession.appendScanEvent(
                    level: "error",
                    event: "storage_exhausted",
                    message: "Scan finalized because device storage was critically low",
                    fields: ["availableDiskBytes": "\(freeDiskBytes)"])
                showToast(
                    message: String(format: localized("Only %.1f GB of storage remains. Finalizing the scan to protect the database."), freeGB),
                    seconds: 5)
                stopMapping(ignoreSaving: false, offerPostProcessing: false)
                return
            }
            if freeDiskBytes < 8 * 1024 * 1024 * 1024 && !mStreamingDiskWarningShown {
                mStreamingDiskWarningShown = true
                scanSession.appendScanEvent(
                    level: "warning",
                    event: "storage_low",
                    message: "Device storage is getting low",
                    fields: ["availableDiskBytes": "\(freeDiskBytes)"])
                showToast(
                    message: String(format: localized("Storage is getting low (%.1f GB free). Finish the route or free space soon."), freeGB),
                    seconds: 5)
            }
        }

        if thermalState == "critical" {
            mStreamingCriticalStopRequested = true
            scanSession.appendScanEvent(
                level: "error",
                event: "thermal_critical",
                message: "Scan finalized because the device reached critical thermal state")
            showToast(
                message: localized("The iPhone is critically hot. Finalizing the scan to protect data integrity."),
                seconds: 5)
            stopMapping(ignoreSaving: false, offerPostProcessing: false)
        }
        else if thermalState == "serious" && !mStreamingThermalWarningShown {
            mStreamingThermalWarningShown = true
            mStreamingThermalPolicyLevel = 2
            // Reduce only the disposable online window. Disk recording and the
            // continuous ARKit pose chain remain untouched.
            rtabmap?.setStreamingMapMode(enabled: true, maxRenderedNodes: 200)
            rtabmap?.setMappingParameter(key: "Rtabmap/MemoryThr", value: "150")
            scanSession.appendScanEvent(
                level: "warning",
                event: "thermal_policy_adjusted",
                message: "Live preview reduced because the device is hot",
                fields: ["workingMemoryNodes": "150", "renderedNodes": "200"])
            showToast(
                message: localized("The iPhone is hot. Live preview memory was reduced; continuous data recording is unchanged."),
                seconds: 5)
        }
        else if thermalState == "fair" && mStreamingThermalPolicyLevel < 1 {
            mStreamingThermalPolicyLevel = 1
            // Reduce rendering before the device reaches `serious`. Keep the
            // 300-node working graph intact so loop-closure opportunities are
            // not sacrificed merely to draw a denser phone preview.
            rtabmap?.setStreamingMapMode(enabled: true, maxRenderedNodes: 220)
            scanSession.appendScanEvent(
                level: "warning",
                event: "thermal_preview_preemptively_reduced",
                message: "Live rendering was reduced before serious thermal throttling",
                fields: [
                    "renderedNodes": "220",
                    "detectionRateCapHz": "1.5"
                ])
            showToast(
                message: localized("The iPhone is warming up. Live rendering was reduced while structural capture remains active."),
                seconds: 4)
        }
    }

    private func showSupermarketScanSettings()
    {
        applySupermarketSettings()
        let defaults = UserDefaults.standard
        let modeText = localized("Continuous streaming is always enabled: old working-memory nodes are written to one on-disk database without stopping ARKit. Map optimization and generation run on the PC.") + "\n\n" + localized("Software error optimization is enabled. Unstable tracking frames and implausible pose jumps are excluded; AprilTag and landmark priors are not used.")
        let message = String(format: localized("Current save location: %@\n\n%@"), selectedSupermarketLocationName(), modeText)
        let alert = UIAlertController(title: localized("Supermarket Scan Settings"), message: message, preferredStyle: .alert)

        alert.addTextField { textField in
            textField.placeholder = self.localized("Streaming working-memory nodes")
            textField.keyboardType = .numberPad
            textField.text = "\(self.supermarketIntDefault(self.supermarketStreamingMemoryNodesKey, fallback: self.supermarketDefaultStreamingMemoryNodes))"
        }
        alert.addAction(UIAlertAction(title: localized("Choose Save Location"), style: .default, handler: { _ in
            self.presentSupermarketSaveLocationPicker()
        }))
        alert.addAction(UIAlertAction(title: localized("Use Default Location"), style: .default, handler: { _ in
            defaults.removeObject(forKey: self.supermarketSaveLocationBookmarkKey)
            defaults.removeObject(forKey: self.supermarketSaveLocationNameKey)
            self.applySupermarketSettings()
            self.supermarketSession?.refreshUnsavedSessionLocation()
            self.showToast(message: self.localized("Using default save location"), seconds: 2)
        }))
        alert.addAction(UIAlertAction(title: localized("Save"), style: .default, handler: { _ in
            if let streamingNodesText = alert.textFields?[0].text,
               let streamingNodes = Int(streamingNodesText), streamingNodes >= 50 {
                defaults.set(streamingNodes, forKey: self.supermarketStreamingMemoryNodesKey)
            }
            self.applySupermarketSettings()
            self.applyStreamingMappingSettings()
            self.showToast(message: self.localized("Supermarket scan settings saved"), seconds: 2)
        }))
        alert.addAction(UIAlertAction(title: localized("Cancel"), style: .cancel, handler: nil))
        present(alert, animated: true)
    }

    private func presentSupermarketSaveLocationPicker()
    {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true
        present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL])
    {
        guard let url = urls.first else {
            return
        }
        saveSupermarketLocationBookmark(url)
        applySupermarketSettings()
        supermarketSession?.refreshUnsavedSessionLocation()
        showToast(message: String(format: localized("Scan save location set to: %@"), url.lastPathComponent), seconds: 3)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController)
    {
        showToast(message: localized("Save location selection canceled"), seconds: 2)
    }

    func readPriceTagNFC()
    {
        guard supermarketNFCEnabled else {
            return
        }
        guard mState == .STATE_MAPPING else {
            showToast(message: localized("Start mapping before reading a price tag."), seconds: 2)
            return
        }
        priceTagNFCReader = PriceTagNFCReader { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let tag):
                    let pose = self.mLatestPose
                    let record = self.supermarketSession?.addPriceTag(
                        tagIdentifier: tag.identifier,
                        payload: tag.payload,
                        timestamp: Date().timeIntervalSince1970,
                        nodeCount: self.mMapNodes,
                        x: pose.x,
                        y: pose.y,
                        z: pose.z,
                        roll: pose.roll,
                        pitch: pose.pitch,
                        yaw: pose.yaw)
                    self.supermarketSession?.appendScanEvent(
                        event: "price_tag_recorded",
                        message: "NFC price tag recorded",
                        fields: ["tagIdentifier": record?.tagIdentifier ?? tag.identifier, "nodeCount": "\(self.mMapNodes)"])
                    self.showToast(message: String(format: self.localized("Price tag recorded: %@"), record?.tagIdentifier ?? tag.identifier), seconds: 2)
                case .failure(let error):
                    self.showToast(message: String(format: self.localized("NFC read failed: %@"), error.localizedDescription), seconds: 3)
                }
                self.priceTagNFCReader = nil
            }
        }
        priceTagNFCReader?.begin()
    }

    private func finalizeStreamingScan(
        completion: ((ScanFinalizationDisposition) -> Void)? = nil
    )
    {
        guard let scanSession = supermarketSession,
              !scanSession.isFinalizingScan,
              mMapNodes > 0 else {
            completion?(.resumeRecording)
            return
        }
        guard scanSession.beginFinalization() else {
            completion?(.resumeRecording)
            return
        }
        let mobileWorkflowFinalizationActive =
            scanSession.scanConfiguration.workflowMode == .priorMapLocalized
                && MobileOnlyWorkflowCoordinator.shared.scanFinalizationBegan()
        let resumeMobileWorkflowIfNeeded = {
            if mobileWorkflowFinalizationActive {
                MobileOnlyWorkflowCoordinator.shared.scanFinalizationResumed()
            }
        }
        cancelPriceTagCapture(
            reason: "scan_finalization_started",
            userMessage: nil)
        cancelPendingManualPriorMapPoseRequest(
            reason: "scan_finalization_started")
        // Close ordinary localization/tag admission immediately, then drain
        // both already-admitted session transactions and the serial prior-map
        // queue off the main thread. A two-second deadline changes the final
        // eligibility result, but no metadata snapshot is allowed until both
        // drains actually finish, preventing a writer from crossing the
        // finalization snapshot boundary after timeout.
        priorMapGeneration = UUID()
        priorMapUpdateGate.reset()
        priceTagVisionScanner.cancel()
        priorMapAlignmentSnapshots.reset()
        let finalizationDrainDeadline = DispatchTime.now() + 2.0

        // Stop ARKit and native mapping at the same linearization boundary as
        // write admission. Otherwise new RTAB-Map nodes could be produced
        // while localization sidecars are already closed and the drain is
        // waiting, creating an avoidable terminal evidence gap. The database
        // stays open until save completes below.
        session.pause()
        locationManager?.stopUpdatingLocation()
        rtabmap?.setPausedMapping(paused: true)
        rtabmap?.stopCamera()
        updateState(state: .STATE_PROCESSING)
        showToast(
            message: localized("Finalizing continuous streaming database..."),
            seconds: 2)

        let segmentDirectory: URL
        let databaseURL: URL
        do {
            segmentDirectory = try scanSession.currentSegmentDirectory()
            databaseURL = try scanSession.streamingDatabaseURL()
        }
        catch {
            scanSession.endFinalization()
            resumeMobileWorkflowIfNeeded()
            setGLCamera(type: 0)
            _ = startCamera(resetTracking: false)
            rtabmap?.setPausedMapping(paused: false, triggerNewMap: false)
            updateState(state: .STATE_MAPPING)
            showToast(message: String(format: localized("Could not finalize streaming scan: %@"), error.localizedDescription), seconds: 4)
            completion?(.resumeRecording)
            return
        }

        let priorMapDrain = DispatchSemaphore(value: 0)
        priorMapQueue.async {
            priorMapDrain.signal()
        }
        let localizationTransactionDrain = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            scanSession.waitForFinalizationTransactionDrain()
            localizationTransactionDrain.signal()
        }
        // V1R3 §7.1 / V1R4 §7.2: flush the clock correlation sidecar
        // before the scan is finalized so the evidence is bound into the
        // session. A failed write is captured (never `try?`-swallowed)
        // and blocks processing eligibility below.
        let clockSidecarResult = stopClockCorrelationRecording(flush: true)

        let continueFinalization: (Bool, Bool) -> Void = {
            [weak self] priorMapDrainedWithinDeadline,
            localizationTransactionsDrainedWithinDeadline in
        guard let self else {
            scanSession.endFinalization()
            resumeMobileWorkflowIfNeeded()
            completion?(.resumeRecording)
            return
        }
        scanSession.appendScanEvent(
            event: "scan_finalization_started",
            message: "Finalizing the continuous streaming database",
            fields: [
                "nodeCount": "\(mMapNodes)",
                "scanStorageBytes": "\(mLatestScanStorageBytes)",
                "priorMapQueueDrainedWithinDeadline":
                    priorMapDrainedWithinDeadline ? "true" : "false",
                "localizationTransactionsDrainedWithinDeadline":
                    localizationTransactionsDrainedWithinDeadline
                        ? "true" : "false",
            ])
        // F-02: commit the terminal Recovery lifecycle evidence before any
        // sidecar snapshot. A failed write increments the required evidence
        // failure counter read by the eligibility check below (fail closed).
        if scanSession.scanConfiguration.workflowMode == .priorMapLocalized {
            _ = persistTerminalRecoveryEvidence(
                reason: .scanStopped,
                scanSession: scanSession)
        }
        let exportBaseDirectory = scanSession.customBaseDirectorySnapshot()
        let didStartSecurityScope = exportBaseDirectory?.startAccessingSecurityScopedResource() ?? false
        let originValues = rtabmap?.cameraOriginOffset()
        let originOffset: ScanTransform?
        if let values = originValues, values.count == 7 {
            originOffset = ScanTransform(
                x: values[0], y: values[1], z: values[2],
                qx: values[3], qy: values[4], qz: values[5], qw: values[6])
        }
        else {
            originOffset = nil
        }
        let usedMemory = max(0, mMaximumMemory - getAvailableMemory())
        scanSession.updateStructureCoverageSnapshot(mStructureCoverageAdvisor.snapshot())
        let boundary = scanSession.boundarySnapshot()
        let correctionQuaternion = simd_quatf(mARPoseCorrection)
        let softwarePoseCorrection = ScanTransform(
            x: mARPoseCorrection.columns.3.x,
            y: mARPoseCorrection.columns.3.y,
            z: mARPoseCorrection.columns.3.z,
            qx: correctionQuaternion.imag.x,
            qy: correctionQuaternion.imag.y,
            qz: correctionQuaternion.imag.z,
            qw: correctionQuaternion.real)
        let finalMapToOdomCorrection = currentMapToOdomCorrection()
        let finalMapToOdomQuaternion = simd_quatf(finalMapToOdomCorrection)
        let rtabmapMapToOdomCorrection = ScanTransform(
            x: finalMapToOdomCorrection.columns.3.x,
            y: finalMapToOdomCorrection.columns.3.y,
            z: finalMapToOdomCorrection.columns.3.z,
            qx: finalMapToOdomQuaternion.imag.x,
            qy: finalMapToOdomQuaternion.imag.y,
            qz: finalMapToOdomQuaternion.imag.z,
            qw: finalMapToOdomQuaternion.real)
        let finalMapCorrectionTranslationM = Double(simd_length(SIMD3<Float>(
            finalMapToOdomCorrection.columns.3.x,
            finalMapToOdomCorrection.columns.3.y,
            finalMapToOdomCorrection.columns.3.z)))
        let finalMapCorrectionRotationDeg = rotationAngleDegrees(finalMapToOdomCorrection)
        let finalOnlineLoopClosureCount = mTotalLoopClosures
        let finalReliableLoopClosureCount = mReliableLoopClosures
        let finalNodeCount = mMapNodes
        let finalDatabaseMemoryMB = mLatestDatabaseMemoryMB
        let finalKnownAreaM2 = scanSession.currentAreaM2
        let finalPriceTagCount = scanSession.priceTags.count
        let finalizationDate = Date()
        let finalizedAt = finalizationDate.getFormattedDate(
            format: "yyyy-MM-dd HH:mm:ss")
        let availableBytesAtFinalization = availableDiskBytes(at: segmentDirectory)
        let thermalStateAtFinalization = currentThermalStateText()

        var saveSucceeded = false
        var sidecarError: String?
        var processingEligibilityError: String?
        var sidecarCommitResult: SidecarCommitResult?
        var saveSeconds = 0.0
        var sidecarSeconds = 0.0
        var finalDatabaseBytes: UInt64 = 0
        var snapshot: ScanSegmentSidecarSnapshot?
        DispatchQueue.background(background: {
            let saveStartedAt = Date()
            saveSucceeded = self.rtabmap?.save(databasePath: databaseURL.path, savePreview: false) ?? false
            saveSeconds = Date().timeIntervalSince(saveStartedAt)
            if saveSucceeded {
                let sidecarStartedAt = Date()
                do {
                    // SQLite may flush WAL pages during save, so measure the
                    // database only after RTAB-Map has completed finalization.
                    finalDatabaseBytes = self.databaseStorageBytes(at: databaseURL)
                    self.recordStreamingPerformanceSample(
                        nodeCount: finalNodeCount,
                        databaseMemoryMB: finalDatabaseMemoryMB,
                        scanStorageBytes: self.captureDirectoryStorageBytes(
                            at: segmentDirectory),
                        force: true,
                        scanState: "finalizing")
                    let performanceWatermark =
                        scanSession.performanceEvidenceWatermark()
                    if !performanceWatermark.complete {
                        scanSession.appendScanEvent(
                            level: "warning",
                            event: "performance_evidence_incomplete",
                            message: "Map data was finalized, but performance qualification is incomplete",
                            fields: [
                                "sampleCount": "\(performanceWatermark.sampleCount)",
                                "writeFailureCount": "\(performanceWatermark.writeFailureCount)",
                                "mapDataPolicy": "retain_finite_map_and_close_performance_qualification",
                            ])
                    }
                    let isPriorMapScan =
                        scanSession.scanConfiguration.workflowMode == .priorMapLocalized
                    // V1R4 §7.2: a failed clock sidecar write blocks
                    // processing in every scan mode (fail closed).
                    var processingBlockers: [String] = []
                    if self.clockSidecarWriteFailure != nil {
                        processingBlockers.append("clock_sidecar_write_failed")
                    }
                    if isPriorMapScan {
                        if !priorMapDrainedWithinDeadline {
                            processingBlockers.append("prior_map_queue_not_drained")
                        }
                        if !localizationTransactionsDrainedWithinDeadline {
                            processingBlockers.append(
                                "localization_transaction_drain_timeout")
                        }
                        if boundary.captureHealth.localizationRequiredWriteFailureCount > 0 {
                            processingBlockers.append(
                                "localization_required_sidecar_write_failed")
                        }
                        if boundary.captureHealth.localizationTraceRecordCount == 0 {
                            processingBlockers.append("localization_trace_missing")
                        }
                        if boundary.captureHealth.localizationConstraintRecordCount == 0 {
                            processingBlockers.append("localization_constraints_missing")
                        }
                        if boundary.captureHealth.localizationStateEventCount == 0 {
                            processingBlockers.append("localization_state_events_missing")
                        }
                    }
                    // V1R4 §13.1: flush the tag burst sidecar before the
                    // metadata snapshot so the watermark reflects every
                    // observation ingested during the scan. A failed burst
                    // write blocks processing fail-closed (the sidecar is
                    // required and its count/last-ID/complete watermarks are
                    // validated by the PC side).
                    let burstFlushResult =
                        scanSession.flushTagObservationBursts(
                            allowDuringFinalization: true)
                    if !burstFlushResult.complete {
                        processingBlockers.append(
                            "tag_observation_burst_write_failed")
                    }
                    let shelfEvidenceWatermark: ShelfLocalizationEvidenceWatermark?
                    if isPriorMapScan {
                        let watermark = scanSession.sealShelfLocalizationEvidence(
                            expectedTrackingSessionId: scanSession.trackingSessionId,
                            allowDuringFinalization: true)
                        shelfEvidenceWatermark = watermark
                        if !watermark.complete {
                            processingBlockers.append(
                                "shelf_localization_evidence_write_failed")
                        }
                    } else {
                        shelfEvidenceWatermark = nil
                    }
                    // Clock evidence applies to every mode; prior-map
                    // evidence only to prior-map scans.
                    let metadataFinalized = processingBlockers.isEmpty
                    let processingEligibility: ScanProcessingEligibility?
                    if processingBlockers.isEmpty {
                        processingEligibility = isPriorMapScan
                            ? ScanProcessingEligibility(
                                status: "eligible", blockers: [])
                            : nil
                    } else {
                        processingEligibility = ScanProcessingEligibility(
                            status: "invalid", blockers: processingBlockers)
                    }
                    if !processingBlockers.isEmpty {
                        processingEligibilityError =
                            "Required scan evidence is incomplete: "
                            + processingBlockers.joined(separator: ", ")
                    }
                    let metadata = ScanSegmentMetadata(
                        format: "MarketScannerFinalizedSessionMetadata",
                        version: 1,
                        segmentIndex: 1,
                        scanMode: "continuous_streaming",
                        finalized: metadataFinalized,
                        processingProfile: "iphone_continuous_pc_offline_software_error_v2_no_fiducials",
                        exportedAt: finalizedAt,
                        finalizedAtUnix: metadataFinalized
                            ? Date().timeIntervalSince1970
                            : nil,
                        knownAreaM2: finalKnownAreaM2,
                        nodeCount: finalNodeCount,
                        databaseMemoryMB: finalDatabaseMemoryMB,
                        usedMemoryMB: usedMemory,
                        priceTagCount: finalPriceTagCount,
                        trackingSessionId: scanSession.trackingSessionId,
                        sensorStartPose: boundary.sensorStartPose,
                        sensorEndPose: boundary.sensorEndPose,
                        rtabmapStartPose: boundary.rtabmapStartPose,
                        rtabmapEndPose: boundary.rtabmapEndPose,
                        rtabmapOriginOffset: originOffset,
                        softwarePoseCorrection: softwarePoseCorrection,
                        rtabmapMapToOdomCorrection: rtabmapMapToOdomCorrection,
                        onlineLoopClosureCount: finalOnlineLoopClosureCount,
                        reliableLoopClosureCount: finalReliableLoopClosureCount,
                        databaseBytes: finalDatabaseBytes,
                        availableDiskBytes: availableBytesAtFinalization,
                        thermalState: thermalStateAtFinalization,
                        captureHealth: boundary.captureHealth,
                        processingEligibility: processingEligibility,
                        structureCoverage: scanSession.structureCoverageSummary(),
                        formatVersion: 2,
                        workflowMode: scanSession.scanConfiguration.workflowMode.rawValue,
                        priorMapId: scanSession.scanConfiguration.priorMapId,
                        priorMapSha256: scanSession.scanConfiguration.priorMapSha256,
                        priorMapCanonicalSourceSha256: scanSession
                            .scanConfiguration.priorMapCanonicalSourceSha256,
                        floorId: scanSession.scanConfiguration.floorId,
                        // B-08: the session records its store identity at
                        // finalization; the snapshot eligibility chain
                        // validates it fail-closed against the request.
                        storeId: scanSession.scanConfiguration.storeID,
                        scanDisplayName: scanSession.scanConfiguration.scanDisplayName,
                        initialMapPose: scanSession.scanConfiguration.initialMapPose,
                        localizationTrace: scanSession.scanConfiguration.workflowMode == .priorMapLocalized
                            ? "localization_trace.jsonl"
                            : nil,
                        manualLocalizationEvents: scanSession.scanConfiguration.workflowMode == .priorMapLocalized
                            ? "manual_localization_events.jsonl"
                            : nil,
                        localizationConstraints: scanSession.scanConfiguration.workflowMode == .priorMapLocalized
                            ? "localization_constraints.jsonl"
                            : nil,
                        localizationEvents: scanSession.scanConfiguration.workflowMode == .priorMapLocalized
                            ? "localization_events.jsonl"
                            : nil,
                        localizationRecoveryEvents: scanSession.scanConfiguration.workflowMode == .priorMapLocalized
                            ? "localization_recovery_events.jsonl"
                            : nil,
                        tagObservations: scanSession.scanConfiguration.workflowMode == .priorMapLocalized
                            ? "tag_observations.jsonl"
                            : nil,
                        localizedPriceTags: scanSession.scanConfiguration.workflowMode == .priorMapLocalized
                            ? "localized_price_tags.json"
                            : nil,
                        localizedPriceTagCount: scanSession.scanConfiguration.workflowMode == .priorMapLocalized
                            ? scanSession.confirmedLocalizedPriceTagCount()
                            : nil,
                        clockCorrelationCount: clockSidecarResult?.correlationCount,
                        clockNodeBindingCount: clockSidecarResult?.nodeBindingCount,
                        clockLastMonotonic: clockSidecarResult?.lastMonotonicSeconds,
                        clockLastUTC: clockSidecarResult?.lastUTCSeconds,
                        clockEvidenceComplete: clockSidecarResult?.evidenceComplete,
                        // V1R4 §13.1: exact tag burst watermarks from the
                        // durable sidecar write so processing can validate
                        // count/last-ID/complete fail-closed.
                        tagObservationBurstCount: burstFlushResult.count,
                        tagObservationBurstLastID: burstFlushResult.lastBurstID,
                        tagObservationBurstComplete: burstFlushResult.complete,
                        poseEpochTransitions: isPriorMapScan
                            ? PoseEpochTransitionRecord.fileName : nil,
                        poseEpochTransitionCount:
                            shelfEvidenceWatermark?.poseEpochTransitionCount,
                        poseEpochTransitionLastSequence:
                            shelfEvidenceWatermark?.poseEpochTransitionLastSequence,
                        corridorHypotheses: isPriorMapScan
                            ? CorridorHypothesesRecord.fileName : nil,
                        corridorHypothesisCount:
                            shelfEvidenceWatermark?.corridorHypothesisCount,
                        corridorHypothesisLastSequence:
                            shelfEvidenceWatermark?.corridorHypothesisLastSequence,
                        shelfObservationWindows: isPriorMapScan
                            ? ShelfObservationWindowRecord.fileName : nil,
                        shelfObservationWindowCount:
                            shelfEvidenceWatermark?.shelfObservationWindowCount,
                        shelfObservationWindowLastSequence:
                            shelfEvidenceWatermark?.shelfObservationWindowLastSequence,
                        shelfLoopEvents: isPriorMapScan
                            ? ShelfLoopEventRecord.fileName : nil,
                        shelfLoopEventCount:
                            shelfEvidenceWatermark?.shelfLoopEventCount,
                        shelfLoopEventLastSequence:
                            shelfEvidenceWatermark?.shelfLoopEventLastSequence,
                        shelfLocalizationEvidenceComplete:
                            shelfEvidenceWatermark?.complete,
                        shelfLocalizationCalibrationStatus: isPriorMapScan
                            ? ShelfLocalizationPolicy.calibrationStatus : nil,
                        performanceSamples: "performance_samples.jsonl",
                        performanceSampleIntervalSeconds: 5.0,
                        performanceSampleCount:
                            performanceWatermark.sampleCount,
                        performanceLastSequence:
                            performanceWatermark.lastSequence,
                        performanceLastTimestampUnix:
                            performanceWatermark.lastTimestampUnix,
                        performanceEvidenceComplete:
                            performanceWatermark.complete,
                        performanceWriteFailureCount:
                            performanceWatermark.writeFailureCount)
                    let finalSnapshot = scanSession.makeSidecarSnapshot(metadata: metadata)
                    snapshot = finalSnapshot
                    sidecarCommitResult = try scanSession.writeSidecarFiles(
                        to: segmentDirectory,
                        snapshot: finalSnapshot)
                    if let blockers = sidecarCommitResult?
                        .evidenceValidationBlockers,
                       !blockers.isEmpty {
                        processingEligibilityError =
                            "Persisted prior-map evidence bundle is invalid: "
                            + blockers.joined(separator: ", ")
                    }
                }
                catch {
                    sidecarError = error.localizedDescription
                }
                sidecarSeconds = Date().timeIntervalSince(sidecarStartedAt)
            }
        }, completion: {
            let disposition = SidecarFinalizationCoordinator.disposition(
                saveSucceeded: saveSucceeded,
                expectedFinalizedMetadata:
                    sidecarCommitResult?.finalizedMetadataCommitted == true,
                commitResult: sidecarCommitResult,
                preCommitError: sidecarError,
                eligibilityError: processingEligibilityError)
            let effects = ScanFinalizationEffectPlanner.effects(
                for: disposition)
            guard effects.closesSession,
                  let snapshot,
                  let sidecarCommitResult else {
                if didStartSecurityScope {
                    exportBaseDirectory?.stopAccessingSecurityScopedResource()
                }
                scanSession.endFinalization()
                resumeMobileWorkflowIfNeeded()
                scanSession.appendScanEvent(
                    level: "error",
                    event: "scan_finalization_failed",
                    message: sidecarError
                        ?? processingEligibilityError
                        ?? "Streaming database save failed")
                let failureMessage = sidecarError.map {
                    String(
                        format: self.localized("Streaming database was saved, but metadata failed: %@"),
                        $0)
                } ?? processingEligibilityError.map {
                    String(
                        format: self.localized("The database was saved, but required prior-map evidence is incomplete: %@"),
                        $0)
                } ?? self.localized("Streaming database save failed.")
                self.showToast(message: failureMessage, seconds: 7)
                self.setGLCamera(type: 0)
                self.startCamera(resetTracking: false)
                self.rtabmap?.setPausedMapping(
                    paused: false,
                    triggerNewMap: false)
                self.updateState(state: .STATE_MAPPING)
                completion?(.resumeRecording)
                return
            }

            let needsCheckpointCleanup =
                effects.preservesCheckpoint
                    && disposition == .terminalFinalizedNeedsCleanup
            let stoppedWithIneligibleEvidence =
                effects.preservesCheckpoint
                    && disposition == .terminalIneligibleEvidence

            scanSession.appendScanEvent(
                level: needsCheckpointCleanup || stoppedWithIneligibleEvidence
                    ? "warning"
                    : "info",
                event: needsCheckpointCleanup
                    ? "scan_finalized_needs_checkpoint_cleanup"
                    : stoppedWithIneligibleEvidence
                        ? "scan_stopped_ineligible_evidence"
                        : "scan_finalized",
                message: needsCheckpointCleanup
                    ? "Database and metadata were finalized, but the older checkpoint could not be removed"
                    : stoppedWithIneligibleEvidence
                        ? "Raw database was saved and closed, but required prior-map evidence is ineligible"
                        : "Continuous streaming database finalized",
                fields: [
                    "nodeCount": "\(snapshot.metadata.nodeCount)",
                    "databaseBytes": "\(finalDatabaseBytes)",
                    "loopClosures": "\(finalOnlineLoopClosureCount)",
                    "reliableLoopClosures": "\(finalReliableLoopClosureCount)",
                    "mapCorrectionTranslationM": String(format: "%.4f", finalMapCorrectionTranslationM),
                    "mapCorrectionRotationDeg": String(format: "%.3f", finalMapCorrectionRotationDeg),
                    "saveSeconds": String(format: "%.3f", saveSeconds),
                    "sidecarSeconds": String(format: "%.3f", sidecarSeconds),
                    "finalizationPhase": sidecarCommitResult.phase.rawValue,
                    "checkpointCleanupError":
                        sidecarCommitResult.cleanupError ?? ""
                ])
            let finalScanStorageBytes = self.captureDirectoryStorageBytes(at: segmentDirectory)

            // Detach RTAB-Map from the completed database before a background
            // external copy is allowed to remove the local capture directory.
            let tmpDatabase = self.getDocumentDirectory().appendingPathComponent(self.RTABMAP_TMP_DB)
            if let nativeHost = self.rtabmap {
                nativeHost.openDatabase(
                    databasePath: tmpDatabase.path,
                    databaseInMemory: false,
                    optimize: false,
                    clearDatabase: true)
            }
            else {
                // The completed database and metadata are already committed.
                // Losing the native host must not turn a successfully sealed
                // capture into a process crash; retain an explicit diagnostic
                // and finish releasing the immutable session.
                scanSession.appendScanEvent(
                    level: "warning",
                    event: "native_host_unavailable_after_finalization",
                    message: "The scan was finalized, but the native host was unavailable during scratch-database detach")
            }
            self.mMapNodes = 0
            self.mLatestDatabaseMemoryMB = 0
            self.mLatestScanStorageBytes = finalScanStorageBytes
            self.setGLCamera(type: 2)
            self.updateState(state: .STATE_IDLE)
            print(String(format: "Streaming scan finalized: save=%.2fs sidecar=%.2fs", saveSeconds, sidecarSeconds))

            // The verified local database is already complete. Release this
            // session now so the next scan can start while a large external
            // copy continues against captured immutable paths.
            MarketScannerCrashDiagnostics.shared.markScanCompleted(
                trackingSessionID: scanSession.trackingSessionId)
            scanSession.completeCurrentSession()
            scanSession.endFinalization()
            if mobileWorkflowFinalizationActive {
                MobileOnlyWorkflowCoordinator.shared.scanFinalizationCompleted()
            }
            self.activeScanConfiguration = .freeMapping
            self.clearPriorMapLocalization()
            self.showToast(
                message: needsCheckpointCleanup
                    ? self.localized("The scan database was finalized and remains closed, but checkpoint cleanup failed. Keep the local scan and use Verify and clean after restarting; do not resume recording or copy it to the PC yet.")
                    : stoppedWithIneligibleEvidence
                        ? self.localized("Required localization evidence failed. The raw RTAB-Map database was saved and closed as a recovery package, but this session is not eligible for prior-map processing. Start a new scan to continue prior-map work.")
                    : self.localized("Continuous streaming scan finalized as one database."),
                seconds: needsCheckpointCleanup || stoppedWithIneligibleEvidence
                    ? 9
                    : 3,
                replacingCurrent: true)
            completion?(disposition)

            if !effects.allowsExternalCopy {
                if didStartSecurityScope {
                    exportBaseDirectory?.stopAccessingSecurityScopedResource()
                }
            }
            else if let exportBaseDirectory = exportBaseDirectory {
                self.copyCaptureInBackground(
                    scanSession: scanSession,
                    captureDir: segmentDirectory,
                    exportBaseDirectory: exportBaseDirectory,
                    didStartSecurityScope: didStartSecurityScope,
                    localSaveSeconds: saveSeconds,
                    sidecarSeconds: sidecarSeconds)
            }
            else {
                if didStartSecurityScope {
                    exportBaseDirectory?.stopAccessingSecurityScopedResource()
                }
            }
        })
        }
        // The deadline starts when admission closes, not after a potentially
        // blocking lock acquisition. If it expires, keep the UI responsive and
        // mark the result ineligible, but continue waiting off-main until both
        // drains actually complete; snapshotting while an admitted writer can
        // still run would create a half-sealed evidence bundle.
        DispatchQueue.global(qos: .userInitiated).async {
            let priorMapDrainedWithinDeadline = priorMapDrain.wait(
                timeout: finalizationDrainDeadline) == .success
            let localizationTransactionsDrainedWithinDeadline =
                localizationTransactionDrain.wait(
                    timeout: finalizationDrainDeadline) == .success
            if !priorMapDrainedWithinDeadline
                || !localizationTransactionsDrainedWithinDeadline {
                DispatchQueue.main.async {
                    scanSession.appendScanEvent(
                        level: "error",
                        event: "scan_finalization_drain_timeout",
                        message: "Finalization admission closed, but pre-existing transactions exceeded the drain deadline",
                        fields: [
                            "prior_map_queue": priorMapDrainedWithinDeadline
                                ? "drained" : "timeout",
                            "localization_transactions":
                                localizationTransactionsDrainedWithinDeadline
                                    ? "drained" : "timeout",
                            "snapshot_started": "false",
                        ])
                    self.showToast(
                        message: self.localized("Finalization is still waiting for evidence writes. The app remains responsive; this scan will be marked ineligible if the deadline was exceeded."),
                        seconds: 6)
                }
            }
            if !priorMapDrainedWithinDeadline {
                _ = priorMapDrain.wait(timeout: .distantFuture)
            }
            if !localizationTransactionsDrainedWithinDeadline {
                _ = localizationTransactionDrain.wait(
                    timeout: .distantFuture)
            }
            DispatchQueue.main.async {
                continueFinalization(
                    priorMapDrainedWithinDeadline,
                    localizationTransactionsDrainedWithinDeadline)
            }
        }
    }

    private func copyCaptureInBackground(scanSession: SupermarketScanSession,
                                         captureDir: URL,
                                         exportBaseDirectory: URL,
                                         didStartSecurityScope: Bool,
                                         localSaveSeconds: Double,
                                         sidecarSeconds: Double,
                                         completion: (() -> Void)? = nil)
    {
        var copiedCapturePath: String?
        var copyErrorMessage: String?
        var copySeconds = 0.0
        DispatchQueue.background(background: {
            let copyStartedAt = Date()
            do {
                if let copiedCapture = try scanSession.copyCaptureToCustomBaseDirectory(
                    from: captureDir,
                    destinationBaseDirectory: exportBaseDirectory) {
                    copiedCapturePath = copiedCapture.path
                }
            }
            catch {
                copyErrorMessage = error.localizedDescription
                print("Could not copy scan to selected location: \(error)")
            }
            copySeconds = Date().timeIntervalSince(copyStartedAt)
        }, completion: {
            if didStartSecurityScope {
                exportBaseDirectory.stopAccessingSecurityScopedResource()
            }
            print(String(format: "Scan background copy timing: save=%.2fs sidecar=%.2fs copy=%.2fs",
                         localSaveSeconds, sidecarSeconds, copySeconds))
            if let copyErrorMessage = copyErrorMessage {
                self.showToast(message: String(format: self.localized("The scan was saved locally, but copying to the selected location failed: %@"), copyErrorMessage), seconds: 5)
            }
            else if copiedCapturePath != nil {
                self.showToast(message: String(format: self.localized("The scan was copied and verified in background; the local copy was retained. Copy: %.1fs."), copySeconds), seconds: 4)
            }
            completion?()
        })
    }

    func save()
    {
        //Step : 1
        let alert = UIAlertController(title: "Save Scan", message: "RTAB-Map Database Name (*.db):", preferredStyle: .alert )
        //Step : 2
        let save = UIAlertAction(title: "Save", style: .default) { (alertAction) in
            let textField = alert.textFields![0] as UITextField
            if textField.text != "" {
                //Read TextFields text data
                let fileName = textField.text!+".db"
                let filePath = self.getDocumentDirectory().appendingPathComponent(fileName).path
                if FileManager.default.fileExists(atPath: filePath) {
                    let alert = UIAlertController(title: "File Already Exists", message: "Do you want to overwrite the existing file?", preferredStyle: .alert)
                    let yes = UIAlertAction(title: "Yes", style: .default) {
                        (UIAlertAction) -> Void in
                        self.saveDatabase(fileName: fileName);
                    }
                    alert.addAction(yes)
                    let no = UIAlertAction(title: "No", style: .cancel) {
                        (UIAlertAction) -> Void in
                        if(self.mDataRecording) {
                            self.save() // We cannot skip saving after data recording
                        }
                    }
                    alert.addAction(no)
                    
                    self.present(alert, animated: true, completion: nil)
                } else {
                    self.saveDatabase(fileName: fileName);
                }
            }
            else
            {
                self.save()
            }
        }

        //Step : 3
        var placeholder = Date().getFormattedDate(format: "yyMMdd-HHmmss")
        if(mDataRecording) {
            placeholder += "-recording"
        }
        if self.openedDatabasePath != nil && !self.openedDatabasePath!.path.isEmpty
        {
            var components = self.openedDatabasePath!.lastPathComponent.components(separatedBy: ".")
            if components.count > 1 { // If there is a file extension
                components.removeLast()
                placeholder = components.joined(separator: ".")
            } else {
                placeholder = self.openedDatabasePath!.lastPathComponent
            }
        }
        alert.addTextField { (textField) in
                textField.text = placeholder
        }

        //Step : 4
        alert.addAction(save)
        //Cancel action
        if(!mDataRecording) {
            alert.addAction(UIAlertAction(title: "Cancel", style: .default) { (alertAction) in })
        }

        self.present(alert, animated: true) {
            alert.textFields?.first?.selectAll(nil)
        }
    }
    
    func saveDatabase(fileName: String)
    {
        let filePath = self.getDocumentDirectory().appendingPathComponent(fileName).path
        
        let indicator: UIActivityIndicatorView = UIActivityIndicatorView(style: .large)
        indicator.frame = CGRect(x: 0.0, y: 0.0, width: 60.0, height: 60.0)
        indicator.center = view.center
        view.addSubview(indicator)
        indicator.bringSubviewToFront(view)
        
        indicator.startAnimating()
        
        let previousState = mState;
        updateState(state: .STATE_PROCESSING);
        
        DispatchQueue.background(background: {
            self.rtabmap?.save(databasePath: filePath); // save
        }, completion:{
            // main thread
            indicator.stopAnimating()
            indicator.removeFromSuperview()
            
            self.openedDatabasePath = URL(fileURLWithPath: filePath)
            
            let alert = UIAlertController(title: "Database saved!", message: String(format: "Database \"%@\" successfully saved!", fileName), preferredStyle: .alert)
            let yes = UIAlertAction(title: "OK", style: .default) {
                (UIAlertAction) -> Void in
            }
            alert.addAction(yes)
            self.present(alert, animated: true, completion: nil)
            do {
                let tmpDatabase = self.getDocumentDirectory().appendingPathComponent(self.RTABMAP_TMP_DB)
                try FileManager.default.removeItem(at: tmpDatabase)
            }
            catch {
                print("Could not clear tmp database: \(error)")
            }
            self.updateDatabases()
            self.updateState(state: self.mDataRecording ? .STATE_WELCOME : previousState)
        })
    }
    
    private func export(isOBJ: Bool, meshing: Bool, regenerateCloud: Bool, optimized: Bool, optimizedMaxPolygons: Int, previousState: State)
    {
        let defaults = UserDefaults.standard
        let cloudVoxelSize = defaults.float(forKey: "VoxelSize")
        let textureSize = isOBJ ? defaults.integer(forKey: "TextureSize") : 0
        let textureCount = defaults.integer(forKey: "MaximumOutputTextures")
        let normalK = defaults.integer(forKey: "NormalK")
        let maxTextureDistance = defaults.float(forKey: "MaxTextureDistance")
        let minTextureClusterSize = defaults.integer(forKey: "MinTextureClusterSize")
        let optimizedVoxelSize = cloudVoxelSize
        let optimizedDepth = defaults.integer(forKey: "ReconstructionDepth")
        let optimizedColorRadius = defaults.float(forKey: "ColorRadius")
        let optimizedCleanWhitePolygons = defaults.bool(forKey: "CleanMesh")
        let optimizedMinClusterSize = defaults.integer(forKey: "PolygonFiltering")
        let textureVertexColorPolicy = defaults.integer(forKey: "TextureVertexColorPolicy")
        let blockRendering = false
        
        var indicator: UIActivityIndicatorView?
        
        let alertView = UIAlertController(title: "Assembling", message: "Please wait while assembling data...", preferredStyle: .alert)
        alertView.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: { _ in
            self.dismiss(animated: true, completion: {
                self.progressView = nil
                
                indicator = UIActivityIndicatorView(style: .large)
                indicator?.frame = CGRect(x: 0.0, y: 0.0, width: 60.0, height: 60.0)
                indicator?.center = self.view.center
                self.view.addSubview(indicator!)
                indicator?.bringSubviewToFront(self.view)
                
                indicator?.startAnimating()
                
                self.rtabmap!.cancelProcessing()
            })
            
        }))
	
        let previousState = mState
        
        updateState(state: .STATE_PROCESSING);
        
        present(alertView, animated: true, completion: {
            //  Add your progressbar after alert is shown (and measured)
            let margin:CGFloat = 8.0
            let rect = CGRect(x: margin, y: 84.0, width: alertView.view.frame.width - margin * 2.0 , height: 2.0)
            self.progressView = UIProgressView(frame: rect)
            self.progressView!.progress = 0
            self.progressView!.tintColor = self.view.tintColor
            alertView.view.addSubview(self.progressView!)
            
            self.progressStatusUpdate() // This will update memory usage during post processing
            
            var success : Bool = false
            DispatchQueue.background(background: {
                
                success = self.rtabmap!.exportMesh(
                    cloudVoxelSize: cloudVoxelSize,
                    regenerateCloud: regenerateCloud,
                    meshing: meshing,
                    textureSize: textureSize,
                    textureCount: textureCount,
                    normalK: normalK,
                    optimized: optimized,
                    optimizedVoxelSize: optimizedVoxelSize,
                    optimizedDepth: optimizedDepth,
                    optimizedMaxPolygons: optimizedMaxPolygons,
                    optimizedColorRadius: optimizedColorRadius,
                    optimizedCleanWhitePolygons: optimizedCleanWhitePolygons,
                    optimizedMinClusterSize: optimizedMinClusterSize,
                    optimizedMaxTextureDistance: maxTextureDistance,
                    optimizedMinTextureClusterSize: minTextureClusterSize,
                    textureVertexColorPolicy: textureVertexColorPolicy,
                    blockRendering: blockRendering)
                
            }, completion:{
                if(indicator != nil)
                {
                    indicator!.stopAnimating()
                    indicator!.removeFromSuperview()
                }
                if self.progressView != nil
                {
                    self.dismiss(animated: self.openedDatabasePath == nil, completion: {
                        if(success)
                        {
                            if(!meshing && cloudVoxelSize>0.0)
                            {
                                self.showToast(message: "Cloud assembled and voxelized at \(cloudVoxelSize) m.", seconds: 2)
                            }
                            
                            if(!meshing)
                            {
                                self.visualizationType = 0;
                                self.setMeshRendering(viewMode: 0)
                            }
                            else if(!isOBJ)
                            {
                                self.visualizationType = 1;
                                self.setMeshRendering(viewMode: 1)
                            }
                            else // isOBJ
                            {
                                self.visualizationType = 2;
                                self.setMeshRendering(viewMode: 2)
                            }

                            self.updateState(state: .STATE_VISUALIZING)
                            
                            self.rtabmap!.postExportation(visualize: true)
							
                            if previousState != .STATE_VISUALIZING
                            {
                                self.setGLCamera(type: 2)
                            }

                            if self.openedDatabasePath == nil
                            {
                                self.save();
                            }
                        }
                        else
                        {
                            self.updateState(state: previousState);
                            self.showToast(message: "Exporting map failed!", seconds: 4)
                        }
                    })
                }
                else
                {
                    self.showToast(message: "Export canceled", seconds: 2)
                    self.updateState(state: previousState);
                }
            })
        })
    }
    
    private func optimization(withStandardMeshExport: Bool = false, approach: Int)
    {
        guard mMapNodes > 0 else {
            showToast(message: localized("No mapping data to optimize yet."), seconds: 3)
            return
        }

        if(mState == State.STATE_VISUALIZING)
        {
            closeVisualization()
            rtabmap!.postExportation(visualize: false)
        }
        
        let alertView = UIAlertController(title: "Post-Processing", message: "Please wait while optimizing...", preferredStyle: .alert)
        alertView.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: { _ in
            self.dismiss(animated: true)
            self.progressView = nil
            self.rtabmap!.cancelProcessing()
        }))

        let previousState = mState
        
        updateState(state: .STATE_PROCESSING)
        
        //  Show it to your users
        present(alertView, animated: true, completion: {
            //  Add your progressbar after alert is shown (and measured)
            let margin:CGFloat = 8.0
            let rect = CGRect(x: margin, y: 72.0, width: alertView.view.frame.width - margin * 2.0 , height: 2.0)
            self.progressView = UIProgressView(frame: rect)
            self.progressView!.progress = 0
            self.progressView!.tintColor = self.view.tintColor
            alertView.view.addSubview(self.progressView!)
            
            self.progressStatusUpdate() // This will update memory usage during post processing
            
            var loopDetected : Int = -1
            DispatchQueue.background(background: {
                loopDetected = self.rtabmap!.postProcessing(approach: approach);
            }, completion:{
                // main thread
                if self.progressView != nil
                {
                    self.dismiss(animated: self.openedDatabasePath == nil, completion: {
                        self.progressView = nil
                        
                        if(loopDetected >= 0)
                        {
                            if(approach  == -1)
                            {
                                if(withStandardMeshExport)
                                {
                                    self.export(isOBJ: true, meshing: true, regenerateCloud: false, optimized: true, optimizedMaxPolygons: 200000, previousState: previousState);
                                }
                                else
                                {
                                    if self.openedDatabasePath == nil
                                    {
                                        self.save();
                                    }
                                }
                            }
                        }
                        else if(loopDetected < 0)
                        {
                            self.showToast(message: "Optimization failed!", seconds: 4.0)
                        }
                    })
                }
                else
                {
                    self.showToast(message: "Optimization canceled", seconds: 4.0)
                }
                self.updateState(state: .STATE_IDLE);
            })
        })
    }
    
    func stopMapping(ignoreSaving: Bool, offerPostProcessing: Bool = true)
    {
        cancelPriceTagCapture(
            reason: "mapping_stop_requested",
            userMessage: nil)
        // Any call reaching this method is an intentional terminal/safety path;
        // it must not be undone later by didBecomeActive.
        cancelAutomaticCaptureResume()
        let hasCurrentMapData = mMapNodes > 0

        // Continuous supermarket capture has one terminal action: finalize the
        // active on-disk database. No rollover/merge path is reachable here.
        if !ignoreSaving,
           !mDataRecording,
           hasCurrentMapData,
           let scanSession = supermarketSession,
           scanSession.rootDirectory != nil,
           !scanSession.isFinalizingScan {
            finalizeStreamingScan()
            return
        }

        session.pause()
        locationManager?.stopUpdatingLocation()
        rtabmap?.setPausedMapping(paused: true)
        rtabmap?.stopCamera()
        if(mDataRecording && hasCurrentMapData) {
            // this will show the trajectory before saving
            self.rtabmap!.setGraphOptimization(enabled: false)
        }
        setGLCamera(type: 2)
        if(mState == .STATE_VISUALIZING_CAMERA)
        {
            self.rtabmap?.setLocalizationMode(enabled: false)
        }
        updateState(state: mState == .STATE_VISUALIZING_CAMERA || mState == .STATE_VISUALIZING_AND_MEASURING ? .STATE_VISUALIZING : .STATE_IDLE);
        
        if !ignoreSaving && hasCurrentMapData
        {
            if(mDataRecording || !offerPostProcessing)
            {
                // Go directly to save
                self.save()
            }
            else
            {
                dismiss(animated: true, completion: {
                    var msg = self.localized("Do you want to do standard graph optimization and make a nice assembled mesh now? This can also be done later using the Optimize and Assemble menus.")
                    let depthUsed = self.depthSupported && UserDefaults.standard.bool(forKey: "LidarMode")
                    if !depthUsed
                    {
                        msg = self.localized("Do you want to do standard graph optimization now? This can also be done later using the Optimize menu.")
                    }
                    let alert = UIAlertController(title: self.localized("Mapping Stopped! Optimize Now?"), message: msg, preferredStyle: .alert)
                    if depthUsed {
                        let alertActionOnlyGraph = UIAlertAction(title: self.localized("Only Optimize"), style: .default)
                        {
                            (UIAlertAction) -> Void in
                            self.optimization(withStandardMeshExport: false, approach: -1)
                        }
                        alert.addAction(alertActionOnlyGraph)
                    }
                    let alertActionNo = UIAlertAction(title: self.localized("Save First"), style: .cancel) {
                        (UIAlertAction) -> Void in
                        self.save()
                    }
                    alert.addAction(alertActionNo)
                    let alertActionYes = UIAlertAction(title: self.localized("Yes"), style: .default) {
                        (UIAlertAction) -> Void in
                        self.optimization(withStandardMeshExport: depthUsed, approach: -1)
                    }
                    alert.addAction(alertActionYes)
                    self.present(alert, animated: true, completion: nil)
                })
            }
        }
        else if(!hasCurrentMapData)
        {
            updateState(state: State.STATE_WELCOME);
            statusLabel.text = ""
        }
    }
    func shareFile(_ fileUrl: URL) {
        let fileURL = NSURL(fileURLWithPath: fileUrl.path)

        // Create the Array which includes the files you want to share
        var filesToShare = [Any]()

        // Add the path of the file to the Array
        filesToShare.append(fileURL)

        // Make the activityViewContoller which shows the share-view
        let activityViewController = UIActivityViewController(activityItems: filesToShare, applicationActivities: nil)
        
        if let popoverController = activityViewController.popoverPresentationController {
            popoverController.sourceRect = CGRect(x: UIScreen.main.bounds.width / 2, y: UIScreen.main.bounds.height / 2, width: 0, height: 0)
            popoverController.sourceView = self.view
            popoverController.permittedArrowDirections = UIPopoverArrowDirection(rawValue: 0)
        }

        // Show the share-view
        self.present(activityViewController, animated: true, completion: nil)
    }
    
    func openDatabase(fileUrl: URL) {
        
        if(mState == .STATE_CAMERA) {
            stopMapping(ignoreSaving: true)
        }
        
        openedDatabasePath = fileUrl;
        let fileName: String = self.openedDatabasePath!.lastPathComponent
        
        var progressDialog = UIAlertController(title: "Loading", message: String(format: "Loading \"%@\". Please wait while point clouds and/or meshes are created...", fileName), preferredStyle: .alert)
        
        //  Show it to your users
        self.present(progressDialog, animated: true)

        updateState(state: .STATE_PROCESSING);
        var status = 0
        DispatchQueue.background(background: {
            self.optimizedGraphShown = true // Always reset to true when opening a database
            status = self.rtabmap!.openDatabase(databasePath: self.openedDatabasePath!.path, databaseInMemory: true, optimize: false, clearDatabase: false)
        }, completion:{
            // main thread
            if(status == -1) {
                self.dismiss(animated: true)
                self.showToast(message: "The map is loaded but optimization of the map's graph has failed, so the map cannot be shown. Change the Graph Optimizer approach used or enable/disable if the graph is optimized from graph end in \"Settings -> Mapping...\" and try opening again.", seconds: 4)
            }
            else if(status == -2) {
                self.dismiss(animated: true)
                self.showToast(message: "Failed to open database: Out of memory! Try again after lowering Point Cloud Density in Settings.", seconds: 4)
            }
            else {
                if(status >= 1 && status<=3) {
                    self.visualizationType = status-1;
                    self.updateState(state: .STATE_VISUALIZING);
                    self.resetNoTouchTimer(true);
                }
                else {
                    self.setGLCamera(type: 2);
                    self.updateState(state: .STATE_IDLE);
                    self.dismiss(animated: true)
                    self.showToast(message: "Database loaded!", seconds: 2)
                }
            }
            
        })
    }
    
    func closeVisualization()
    {
        updateState(state: .STATE_IDLE);
    }
    
    func rename(fileURL: URL)
    {
        //Step : 1
        let alert = UIAlertController(title: "Rename Scan", message: "RTAB-Map Database Name (*.db):", preferredStyle: .alert )
        //Step : 2
        let rename = UIAlertAction(title: "Rename", style: .default) { (alertAction) in
            let textField = alert.textFields![0] as UITextField
            if textField.text != "" {
                //Read TextFields text data
                let fileName = textField.text!+".db"
                let filePath = self.getDocumentDirectory().appendingPathComponent(fileName).path
                if FileManager.default.fileExists(atPath: filePath) {
                    let alert = UIAlertController(title: "File Already Exists", message: "Do you want to overwrite the existing file?", preferredStyle: .alert)
                    let yes = UIAlertAction(title: "Yes", style: .default) {
                        (UIAlertAction) -> Void in
                        
                        do {
                            try FileManager.default.moveItem(at: fileURL, to: URL(fileURLWithPath: filePath))
                            print("File \(fileURL) renamed to \(filePath)")
                        }
                        catch {
                            print("Error renaming file \(fileURL) to \(filePath)")
                        }
                        self.openLibrary()
                    }
                    alert.addAction(yes)
                    let no = UIAlertAction(title: "No", style: .cancel) {
                        (UIAlertAction) -> Void in
                    }
                    alert.addAction(no)
                    
                    self.present(alert, animated: true, completion: nil)
                } else {
                    do {
                        try FileManager.default.moveItem(at: fileURL, to: URL(fileURLWithPath: filePath))
                        print("File \(fileURL) renamed to \(filePath)")
                    }
                    catch {
                        print("Error renaming file \(fileURL) to \(filePath)")
                    }
                    self.openLibrary()
                }
            }
        }

        //Step : 3
        alert.addTextField { (textField) in
            var components = fileURL.lastPathComponent.components(separatedBy: ".")
            if components.count > 1 { // If there is a file extension
              components.removeLast()
                textField.text = components.joined(separator: ".")
            } else {
                textField.text = fileURL.lastPathComponent
            }
        }

        //Step : 4
        alert.addAction(rename)
        //Cancel action
        alert.addAction(UIAlertAction(title: "Cancel", style: .default) { (alertAction) in })

        self.present(alert, animated: true) {
            alert.textFields?.first?.selectAll(nil)
        }
    }
    
    func exportOBJPLY()
    {
        //Step : 1
        let alert = UIAlertController(title: "Export Scan", message: "Model Name:", preferredStyle: .alert )
        //Step : 2
        let save = UIAlertAction(title: "Ok", style: .default) { (alertAction) in
            let textField = alert.textFields![0] as UITextField
            if textField.text != "" {
                self.dismiss(animated: true)
                //Read TextFields text data
                let fileName = textField.text! + (self.exportOBJPLYButton.title(for: .normal)!.contains("LAZ") ? ".laz" : ".zip")
                let filePath = self.getDocumentDirectory().appendingPathComponent(fileName).path
                if FileManager.default.fileExists(atPath: filePath) {
                    let alert = UIAlertController(title: "File Already Exists", message: "\(fileName) already exists, do you want to overwrite it?", preferredStyle: .alert)
                    let yes = UIAlertAction(title: "Yes", style: .default) {
                        (UIAlertAction) -> Void in
                        self.writeExportedFiles(fileName: textField.text!);
                    }
                    alert.addAction(yes)
                    let no = UIAlertAction(title: "No", style: .cancel) {
                        (UIAlertAction) -> Void in
                    }
                    alert.addAction(no)
                    
                    self.present(alert, animated: true, completion: nil)
                } else {
                    self.writeExportedFiles(fileName: textField.text!);
                }
            }
        }

        //Step : 3
        alert.addTextField { (textField) in
            if self.openedDatabasePath != nil && !self.openedDatabasePath!.path.isEmpty
            {
                var components = self.openedDatabasePath!.lastPathComponent.components(separatedBy: ".")
                if components.count > 1 { // If there is a file extension
                    components.removeLast()
                    textField.text = components.joined(separator: ".")
                } else {
                    textField.text = self.openedDatabasePath!.lastPathComponent
                }
            }
            else {
                textField.text = Date().getFormattedDate(format: "yyMMdd-HHmmss")
            }
        }

        //Step : 4
        alert.addAction(save)
        //Cancel action
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { (alertAction) in })

        self.present(alert, animated: true) {
            alert.textFields?.first?.selectAll(nil)
        }
    }

    func writeExportedFiles(fileName: String)
    {
        let isLAZ = self.visualizationType==0 && self.exportOBJPLYButton.title(for: .normal)!.contains("LAZ")
        
        let alertView = UIAlertController(title: "Exporting", message: "Please wait while exporting data to \(fileName+(isLAZ ? ".laz" : ".zip"))...", preferredStyle: .alert)
        alertView.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: { _ in
            self.dismiss(animated: true)
            self.progressView = nil
            self.rtabmap!.cancelProcessing()
        }))
        
        let previousState = mState;

        updateState(state: .STATE_PROCESSING);
        
        present(alertView, animated: true, completion: {
            //  Add your progressbar after alert is shown (and measured)
            let margin:CGFloat = 8.0
            let rect = CGRect(x: margin, y: 84.0, width: alertView.view.frame.width - margin * 2.0 , height: 2.0)
            self.progressView = UIProgressView(frame: rect)
            self.progressView!.progress = 0
            self.progressView!.tintColor = self.view.tintColor
            alertView.view.addSubview(self.progressView!)
            
            let exportDir = self.getTmpDirectory().appendingPathComponent(self.RTABMAP_EXPORT_DIR)
           
            do {
                try FileManager.default.removeItem(at: exportDir)
            }
            catch
            {}
            
            do {
                try FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)
            }
            catch
            {
                print("Failed adding export directory \(exportDir)")
                return
            }
            
            var success : Bool = false
            var zipFileUrl : URL!
            DispatchQueue.background(background: {
                print("Exporting to directory \(exportDir.path) with name \(fileName)")
                if(self.rtabmap!.writeExportedMesh(directory: exportDir.path, name: fileName))
                {
                    do {
                        let fileURLs = try FileManager.default.contentsOfDirectory(at: exportDir, includingPropertiesForKeys: nil)
                        if(!fileURLs.isEmpty)
                        {
                            if(isLAZ)
                            {
                                zipFileUrl = self.getDocumentDirectory().appendingPathComponent(fileName+".laz")
                                do {
                                    if FileManager.default.fileExists(atPath: zipFileUrl.path)
                                    {
                                        try FileManager.default.removeItem(at: zipFileUrl)
                                    }
                                    try FileManager.default.moveItem(at: fileURLs.first!, to: zipFileUrl)
                                    print("LAZ file \(zipFileUrl.path) created (size=\(zipFileUrl.fileSizeString)")
                                    success = true
                                }
                                catch
                                {
                                    print("Failed moving \(fileURLs.first!) to \(zipFileUrl.path)")
                                    return
                                }
                            }
                            else
                            {
                                do {
                                    zipFileUrl = try Zip.quickZipFiles(fileURLs, fileName: fileName) // Zip
                                    print("Zip file \(zipFileUrl.path) created (size=\(zipFileUrl.fileSizeString)")
                                    success = true
                                }
                                catch {
                                    print("Something went wrong while zipping")
                                }
                            }
                        }
                    } catch {
                        print("No files exported to \(exportDir)")
                        return
                    }
                }
                
            }, completion:{
                if self.progressView != nil
                {
                    self.dismiss(animated: true)
                }
                if(success)
                {
                    let alertShare = UIAlertController(title: "Mesh/Cloud Saved!", message: "\(fileName+(isLAZ ? ".laz" : ".zip")) (\(zipFileUrl.fileSizeString) successfully exported in Documents of RTAB-Map! Share it?", preferredStyle: .alert)
                    let alertActionYes = UIAlertAction(title: "Yes", style: .default) {
                        (UIAlertAction) -> Void in
                        self.shareFile(zipFileUrl)
                    }
                    alertShare.addAction(alertActionYes)
                    let alertActionNo = UIAlertAction(title: "No", style: .cancel) {
                        (UIAlertAction) -> Void in
                       
                    }
                    alertShare.addAction(alertActionNo)
                    
                    self.present(alertShare, animated: true, completion: nil)
                }
                else
                {
                    self.showToast(message: "Exporting mesh/cloud canceled!", seconds: 2)
                }
                self.updateState(state: previousState);
            })
        })
    }
    
    func updateDatabases()
    {
        databases.removeAll()
        do {
            let fileURLs = try FileManager.default.contentsOfDirectory(at: getDocumentDirectory(), includingPropertiesForKeys: nil)
            // if you want to filter the directory contents you can do like this:
            
            let data = fileURLs.map { url in
                        (url, (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date.distantPast)
                    }
                    .sorted(by: { $0.1 > $1.1 }) // sort descending modification dates
                    .map { $0.0 } // extract file names
            databases = data.filter{ $0.pathExtension == "db" && $0.lastPathComponent != RTABMAP_TMP_DB && $0.lastPathComponent != RTABMAP_RECOVERY_DB }
            
        } catch {
            print("Error while enumerating files : \(error.localizedDescription)")
            return
        }
    }
    
    func openLibrary()
    {
        updateDatabases();
        
        if databases.isEmpty {
            return
        }
        
        let alertController = UIAlertController(title: "Library", message: nil, preferredStyle: .alert)
        let customView = VerticalScrollerView()
        customView.dataSource = self
        customView.delegate = self
        customView.reload()
        alertController.view.addSubview(customView)
        customView.translatesAutoresizingMaskIntoConstraints = false
        customView.topAnchor.constraint(equalTo: alertController.view.topAnchor, constant: 60).isActive = true
        customView.rightAnchor.constraint(equalTo: alertController.view.rightAnchor, constant: -10).isActive = true
        customView.leftAnchor.constraint(equalTo: alertController.view.leftAnchor, constant: 10).isActive = true
        customView.bottomAnchor.constraint(equalTo: alertController.view.bottomAnchor, constant: -45).isActive = true
        
        alertController.view.translatesAutoresizingMaskIntoConstraints = false
        alertController.view.heightAnchor.constraint(equalToConstant: 600).isActive = true
        alertController.view.widthAnchor.constraint(equalToConstant: 400).isActive = true

        customView.backgroundColor = .darkGray

        let selectAction = UIAlertAction(title: "Select", style: .default) { (action) in
            self.openDatabase(fileUrl: self.databases[self.currentDatabaseIndex])
        }
        
        let cancelAction = UIAlertAction(title: "Cancel", style: .cancel, handler: nil)
        alertController.addAction(selectAction)
        alertController.addAction(cancelAction)
        self.present(alertController, animated: true, completion: nil)
    }

    //MARK: Actions   
    @IBAction func stopAction(_ sender: UIButton) {
        stopMapping(ignoreSaving: false)
    }

    @IBAction func recordAction(_ sender: UIButton) {
        rtabmap?.setPausedMapping(paused: false);
        updateState(state: .STATE_MAPPING)
        if !mDataRecording {
            supermarketSession?.appendScanEvent(
                event: "mapping_started",
                message: "User started continuous mapping",
                fields: ["nodeCount": "\(mMapNodes)"])
        }
    }
    
    @IBAction func newScanAction(_ sender: UIButton) {
        presentNewScanModePicker()
    }
    
    @IBAction func closeVisualizationAction(_ sender: UIButton) {
        closeVisualization()
        rtabmap!.postExportation(visualize: false)
    }
    
    @IBAction func stopCameraAction(_ sender: UIButton) {
        stopMapping(ignoreSaving: true)
    }
    
    @IBAction func exportOBJPLYAction(_ sender: UIButton) {
        exportOBJPLY()
    }
    
    @IBAction func libraryAction(_ sender: UIButton) {
        openLibrary();
    }
    @IBAction func rotateGridAction(_ sender: UISlider) {
        rtabmap!.setGridRotation((Float(sender.value)-90.0)/2.0)
        self.view.setNeedsDisplay()
    }
    @IBAction func clipDistanceAction(_ sender: UISlider) {
        rtabmap!.setOrthoCropFactor(Float(120-sender.value)/20.0 - 3.0)
        self.view.setNeedsDisplay()
    }
    
    @IBAction func removeMeasureAction(_ sender: UIButton) {
        self.rtabmap!.removeMeasure()
    }
    @IBAction func addMeasureAction(_ sender: UIButton) {
        self.rtabmap!.addMeasureButtonClicked()
    }
    @IBAction func teleportButtonAction(_ sender: UIButton) {
        self.rtabmap!.teleportButtonClicked()
    }
    func clearMeasures()
    {
        self.rtabmap!.clearMeasures()
        self.resetNoTouchTimer(true)
    }
    @IBAction func startMeasuring(_ sender: UIButton) {
        self.setGLCamera(type: 0)
        self.updateState(state: .STATE_VISUALIZING_AND_MEASURING)
        self.startCamera()
    }
}

func clearBackgroundColor(of view: UIView) {
    if let effectsView = view as? UIVisualEffectView {
        effectsView.removeFromSuperview()
        return
    }

    view.backgroundColor = .clear
    view.subviews.forEach { (subview) in
        clearBackgroundColor(of: subview)
    }
}

extension ViewController: GLKViewControllerDelegate {
    
    // OPENGL UPDATE
    func glkViewControllerUpdate(_ controller: GLKViewController) {
        
    }
    
    // OPENGL DRAW
    override func glkView(_ view: GLKView, drawIn rect: CGRect) {
        if let rotation = UIApplication.shared.windows.first?.windowScene?.interfaceOrientation
        {
            let viewportSize = CGSize(width: rect.size.width * view.contentScaleFactor, height: rect.size.height * view.contentScaleFactor)
            rtabmap?.setupGraphic(size: viewportSize, orientation: rotation)
        }

        let value = rtabmap?.render()
        
        DispatchQueue.main.async {
            if(value != 0 && self.progressView != nil)
            {
                print("Render dismissing")
                self.dismiss(animated: true)
                self.progressView = nil
            }
            if(value == -1)
            {
                self.showToast(message: "Out of Memory!", seconds: 2)
            }
            else if(value == -2)
            {
                self.showToast(message: "Rendering Error!", seconds: 2)
            }
        }
    }
}

extension Date {
   func getFormattedDate(format: String) -> String {
        let dateformat = DateFormatter()
        dateformat.dateFormat = format
        return dateformat.string(from: self)
    }
    
    var millisecondsSince1970:Int64 {
        Int64((self.timeIntervalSince1970 * 1000.0).rounded())
    }
    
    init(milliseconds:Int64) {
        self = Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000)
    }
}

extension DispatchQueue {

    static func background(delay: Double = 0.0, background: (()->Void)? = nil, completion: (() -> Void)? = nil) {
        DispatchQueue.global(qos: .userInitiated).async {
            background?()
            if let completion = completion {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: {
                    completion()
                })
            }
        }
    }
}

extension ViewController: VerticalScrollerViewDelegate {
    func verticalScrollerView(_ horizontalScrollerView: VerticalScrollerView, didSelectViewAt index: Int) {
        guard databases.indices.contains(index),
              let databaseView = horizontalScrollerView.view(at: index) as? DatabaseView else {
            print("Ignoring invalid database scroller selection at index \(index)")
            return
        }
        if let previousDatabaseView = horizontalScrollerView.view(
                at: currentDatabaseIndex) as? DatabaseView {
            previousDatabaseView.highlightDatabase(false)
        }
        currentDatabaseIndex = index
        databaseView.highlightDatabase(true)
  }
}

extension ViewController: VerticalViewDataSource {
  func numberOfViews(in horizontalScrollerView: VerticalScrollerView) -> Int {
    return databases.count
  }
  
  func getScrollerViewItem(_ horizontalScrollerView: VerticalScrollerView, viewAt index: Int) -> UIView {
    print(databases[index].path)
    let databaseView = DatabaseView(frame: CGRect(x: 0, y: 0, width: 100, height: 100), databaseURL: databases[index])

    databaseView.delegate = self
    
    if currentDatabaseIndex == index {
        databaseView.highlightDatabase(true)
    } else {
        databaseView.highlightDatabase(false)
    }

    return databaseView
  }
}

extension ViewController: DatabaseViewDelegate {
    func databaseShared(databaseURL: URL) {
        self.dismiss(animated: true)
        self.shareFile(databaseURL)
    }
    
    func databaseRenamed(databaseURL: URL) {
        self.dismiss(animated: true)
        
        if(openedDatabasePath?.lastPathComponent == databaseURL.lastPathComponent)
        {
            let alertController = UIAlertController(title: "Rename Database", message: "Database \(databaseURL.lastPathComponent) is already opened, cannot rename it.", preferredStyle: .alert)
            let okAction = UIAlertAction(title: "OK", style: .default) { (action) in
            }
            alertController.addAction(okAction)
            present(alertController, animated: true)
            return
        }
        
        self.rename(fileURL: databaseURL)
    }
    
    func databaseDeleted(databaseURL: URL) {
        self.dismiss(animated: true)
        
        if(openedDatabasePath?.lastPathComponent == databaseURL.lastPathComponent)
        {
            let alertController = UIAlertController(title: "Delete Database", message: "Database \(databaseURL.lastPathComponent) is already opened, cannot delete it.", preferredStyle: .alert)
            let okAction = UIAlertAction(title: "OK", style: .default) { (action) in
            }
            alertController.addAction(okAction)
            present(alertController, animated: true)
            return
        }
        
        do {
            try FileManager.default.removeItem(at: databaseURL)
            print("File \(databaseURL) deleted")
        }
        catch {
            print("Error deleting file \(databaseURL)")
        }
        self.updateDatabases()
        if(!databases.isEmpty)
        {
            self.openLibrary()
        }
        else {
            self.updateState(state: self.mState)
        }
    }
  }

extension UserDefaults {
    func reset() {
        let defaults = UserDefaults.standard
        defaults.dictionaryRepresentation().keys.forEach(defaults.removeObject(forKey:))
        
        setDefaultsFromSettingsBundle()
    }
}

extension SKStoreReviewController {
    public static func requestReviewInCurrentScene() {
        if let scene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene {
            requestReview(in: scene)
        }
    }
}

/// V1R2 Gate D §8.3: real MarketScanner scan start.
///
/// The implementation must not stop at persisting the configuration. It
/// loads the phone-compiled package from the durable library, verifies
/// the package integrity SHA against the registered identity, builds the
/// `.priorMapLocalized` scan configuration with the committed initial
/// map pose, and starts the real ARKit/RTAB-Map scan (`newScan`) which
/// drives the ARSession, the RTAB-Map recording and the session metadata.
extension ViewController: MobileOnlyScanStarting {

    private struct MobileOnlyStartResources {
        let session: SupermarketScanSession
        let segmentDirectory: URL
        let databaseURL: URL
        let sidecarWritersReady: Bool
    }

    /// The coordinator calls the host on its serial workflow queue. Only the
    /// short UIKit/ARSession transactions are marshalled to the main thread;
    /// localizer construction, session/file setup and native database open
    /// remain off the main thread so progress UI can continue rendering.
    private func performMobileOnlyMain<T>(
        _ body: @escaping () throws -> T
    ) throws -> T {
        if Thread.isMainThread {
            return try body()
        }
        var result: Result<T, Error>!
        DispatchQueue.main.sync {
            result = Result { try body() }
        }
        return try result.get()
    }

    private func prepareMobileOnlyStartResources(
        configuration: PriorMapScanConfiguration
    ) throws -> MobileOnlyStartResources {
        guard !Thread.isMainThread else {
            throw MobileOnlyWorkflowError.invalidState(
                "mobile-only storage/database preparation must not run on the main thread")
        }
        guard let session = supermarketSession,
              let rtabmap = rtabmap else {
            throw MobileOnlyWorkflowError.invalidState(
                "scan session or native host unavailable")
        }

        let didStartSecurityScope =
            session.startAccessingBaseDirectorySecurityScope()
        defer {
            if didStartSecurityScope {
                session.stopAccessingBaseDirectorySecurityScope()
            }
        }

        try session.startNewSessionIfNeeded()
        session.resetCurrentSegment()
        session.configureScan(configuration)
        let segmentDirectory = try session.currentSegmentDirectory()
        let databaseURL = try session.streamingDatabaseURL()

        mDataRecording = false
        rtabmap.setDataRecorderMode(enabled: false)
        applyStreamingMappingSettings()
        rtabmap.setPreserveCameraOrigin(enabled: false)
        optimizedGraphShown = true
        let openStatus = rtabmap.openDatabase(
            databasePath: databaseURL.path,
            databaseInMemory: false,
            optimize: false,
            clearDatabase: true)
        guard openStatus >= 0 else {
            throw MobileOnlyWorkflowError.invalidState(
                "native streaming database initialization failed")
        }

        mLatestDatabaseMemoryMB = 0
        mLatestScanStorageBytes = 0
        resetStreamingPerformanceTelemetry()
        mLastStreamingCheckpointAt = 0
        mStreamingCheckpointInFlight = false
        mStreamingDiskWarningShown = false
        mStreamingCriticalStopRequested = false
        mStreamingThermalWarningShown = false
        mStreamingThermalPolicyLevel = 0
        mStreamingMemoryPressureLevel = 0
        mLastLoggedTrackingState = ""
        resetSoftwarePoseStabilizer()
        resetSupermarketScanQualityAdvisors()

        session.appendScanEvent(
            event: "scan_started",
            message: "Continuous streaming scan resources prepared",
            fields: [
                "database": databaseURL.lastPathComponent,
                "workingMemoryNodes": "\(supermarketIntDefault(supermarketStreamingMemoryNodesKey, fallback: supermarketDefaultStreamingMemoryNodes))",
                "errorOptimizationProfile": "software_only_no_fiducials",
                "fiducialsEnabled": "false",
                "onlinePoseCorrection": "rtabmap_map_to_odom_v1",
                "reliableLoopMinimumNodeSpan":
                    "\(mReliableLoopMinimumNodeSpan)",
                "structureCoverageAdvisor": "map_frame_world_grid_v2",
                "adaptiveDetectionRateHz": "1.0-2.0",
                "workflowMode": configuration.workflowMode.rawValue,
                "priorMapId": configuration.priorMapId ?? "",
                "floorId": configuration.floorId ?? "",
                "scanDisplayName": configuration.scanDisplayName ?? "",
            ])

        guard FileManager.default.fileExists(atPath: segmentDirectory.path),
              FileManager.default.fileExists(atPath: databaseURL.path) else {
            throw MobileOnlyWorkflowError.invalidState(
                "streaming database or segment directory missing after initialization")
        }
        let probe = segmentDirectory.appendingPathComponent(
            ".ms_sidecar_probe_\(UUID().uuidString)")
        let writable = FileManager.default.createFile(
            atPath: probe.path, contents: Data(), attributes: nil)
        try? FileManager.default.removeItem(at: probe)
        guard writable else {
            throw MobileOnlyWorkflowError.invalidState(
                "sidecar writers not ready (segment not writable)")
        }
        return MobileOnlyStartResources(
            session: session,
            segmentDirectory: segmentDirectory,
            databaseURL: databaseURL,
            sidecarWritersReady: true)
    }

    func startMobileOnlyScan(
        _ configuration: MobileScanConfiguration
    ) throws -> MobileScanStartReceipt {
        let identity = MobileBuildIdentity.loadFromBundle()
        guard identity.isUsable else {
            throw MobileOnlyWorkflowError.invalidState(
                "当前构建没有可追踪身份；请使用 RTABMapApp 默认 Release Run "
                    + "或 RTABMapApp-QualifiedDevice，从已提交且 tracked 文件干净的版本重新构建")
        }

        let entry = configuration.priorMap
        let package = configuration.preparedPackage
        guard package.directory.standardizedFileURL
                == entry.packageDirectory.standardizedFileURL,
              package.manifest.priorMapId == entry.priorMapID,
              package.packageSha256 == entry.packageSHA256,
              package.manifest.storeID == configuration.storeID,
              package.manifest.floors.contains(where: {
                  $0.id == configuration.floorID
              }) else {
            throw MobileOnlyWorkflowError.invalidState(
                "prepared prior-map identity, store or floor mismatch")
        }

        // Defense in depth: the setup screen already resolved the display
        // name, but the host re-runs the idempotent sanitization so no
        // caller path can inject an unsafe or empty value into session
        // metadata. Legacy/free scans without a name keep nil.
        let resolvedScanDisplayName = MarketScannerScanName.effectiveName(
            userInput: configuration.scanDisplayName,
            storeID: configuration.storeID,
            floorID: configuration.floorID)
        let scanConfiguration = PriorMapScanConfiguration(
            formatVersion: 1,
            workflowMode: .priorMapLocalized,
            packageDirectory: entry.packageDirectory,
            priorMapId: entry.priorMapID,
            priorMapSha256: entry.packageSHA256,
            priorMapCanonicalSourceSha256: entry.canonicalSourceSHA256,
            floorId: configuration.floorID,
            storeID: configuration.storeID,
            initialMapPose: PriorMapPose2D(
                xM: configuration.startXM,
                yM: configuration.startYM,
                yawRad: configuration.startYawRad),
            scanDisplayName: resolvedScanDisplayName)
        guard scanConfiguration.isReadyToStart else {
            throw MobileOnlyWorkflowError.invalidState(
                "prior-map scan configuration incomplete")
        }

        let authorization = try performMobileOnlyMain {
            () -> AVAuthorizationStatus in
            guard self.mState != .STATE_MAPPING else {
                throw MobileOnlyWorkflowError.invalidState(
                    "a scan is already in progress")
            }
            if self.mState == .STATE_VISUALIZING {
                self.closeVisualization()
            }
            self.applySupermarketSettings()
            self.mMapNodes = 0
            self.openedDatabasePath = nil
            return AVCaptureDevice.authorizationStatus(for: .video)
        }
        guard authorization == .authorized else {
            throw MobileOnlyWorkflowError.invalidState(
                authorization == .notDetermined
                    ? "camera permission must be granted before committing the scan start"
                    : "camera permission is disabled; enable it in iOS Settings")
        }

        guard let floorID = scanConfiguration.floorId,
              let initialPose = scanConfiguration.initialMapPose else {
            throw MobileOnlyWorkflowError.invalidState(
                "prior-map floor or initial pose missing")
        }
        let preparedLocalizer = try PriorMapStageOneLocalizer(
            package: package,
            floorId: floorID,
            initialMapPose: initialPose)

        var hostStateWasInstalled = false
        do {
            try performMobileOnlyMain {
                guard self.preparePriorMapLocalization(
                    configuration: scanConfiguration,
                    preparedPackage: package,
                    preparedLocalizer: preparedLocalizer) else {
                    throw MobileOnlyWorkflowError.invalidState(
                        "prior-map localizer installation failed")
                }
            }
            hostStateWasInstalled = true

            let resources = try prepareMobileOnlyStartResources(
                configuration: scanConfiguration)

            try performMobileOnlyMain {
                self.setGLCamera(type: 0)
                guard self.startCamera() else {
                    throw MobileOnlyWorkflowError.invalidState(
                        "ARSession/RTAB-Map camera start was refused")
                }
                // The product action starts real mapping immediately; there
                // is no second hidden Record step after configuration.
                self.rtabmap?.setPausedMapping(paused: false)
                self.updateState(state: .STATE_MAPPING)
                resources.session.appendScanEvent(
                    event: "mapping_started",
                    message: "Mobile-only workflow started continuous mapping",
                    fields: ["nodeCount": "\(self.mMapNodes)"])
                do {
                    try self.startClockCorrelationRecording(
                        segmentDirectory: resources.segmentDirectory,
                        trackingSessionID:
                            resources.session.trackingSessionId)
                } catch {
                    throw MobileOnlyWorkflowError.invalidState(
                        "clock evidence writer not ready: "
                            + error.localizedDescription)
                }
            }

            let databaseSize = (try? FileManager.default
                .attributesOfItem(atPath: resources.databaseURL.path)[.size]
                as? NSNumber)?.intValue ?? 0
            let cameraActive = try performMobileOnlyMain {
                self.mState == .STATE_MAPPING
            }
            guard cameraActive, databaseSize > 0 else {
                throw MobileOnlyWorkflowError.invalidState(
                    "camera or streaming database did not reach the recording state")
            }

            return MobileScanStartReceipt(
                trackingSessionID: resources.session.trackingSessionId,
                segmentDirectory: resources.segmentDirectory,
                databaseURL: resources.databaseURL,
                priorMapID: entry.priorMapID,
                priorMapSHA256: entry.packageSHA256,
                floorID: configuration.floorID,
                storeID: configuration.storeID,
                arSessionStarted: cameraActive,
                rtabMapRecordingStarted: true,
                requiredSidecarWritersReady:
                    resources.sidecarWritersReady,
                startedAtMonotonic:
                    ProcessInfo.processInfo.systemUptime,
                startedAtUTC: Date().timeIntervalSince1970,
                appGitSHA: identity.appGitSHA)
        } catch {
            if hostStateWasInstalled {
                try? performMobileOnlyMain {
                    self.rollbackMobileOnlyScanStart(
                        receipt: nil,
                        reason: "host_start_failed")
                }
            }
            if let workflowError = error as? MobileOnlyWorkflowError {
                throw workflowError
            }
            throw MobileOnlyWorkflowError.invalidState(
                "scan start failed: \(error.localizedDescription)")
        }
    }
}
