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

extension Array {
    func size() -> Int {
        return MemoryLayout<Element>.stride * self.count
    }
}

class ViewController: GLKViewController, ARSessionDelegate, RTABMapObserver, UIPickerViewDataSource, UIPickerViewDelegate, CLLocationManagerDelegate, UIDocumentPickerDelegate {
    
    private let session = ARSession()
    private var locationManager: CLLocationManager?
    private var mLastKnownLocation: CLLocation?
    private var mLastLightEstimate: CGFloat?
    
    private var context: EAGLContext?
    private var rtabmap: RTABMap?
    private var supermarketSession: SupermarketScanSession?
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
    private var mTimeThr: Int = 0
    private var mMaxFeatures: Int = 0
    private var mLoopThr = 0.11
    private var mDataRecording = false
    
    private var mReviewRequested = false
    
    private var mMaximumMemory: Int = 0
    private var mLatestDatabaseMemoryMB: Int = 0
    private var mLatestScanStorageBytes: UInt64 = 0
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
    private var mStreamingMemoryPressureLevel = 0
    private var mLastLoggedTrackingState = ""
    private var mARPoseCorrection = matrix_identity_float4x4
    private var mLastAcceptedARPose: simd_float4x4?
    private var mLastAcceptedARTimestamp: TimeInterval?
    private var mTrackingWasDegraded = true
    private var mConsecutiveNormalTrackingFrames = 0
    private var mLastTrackingGuidanceAt: TimeInterval = 0
    private let mRequiredNormalFramesAfterTrackingRecovery = 6
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
    
    func showToast(message : String, seconds: Double){
        if(!self.toastLabel.isHidden)
        {
            return;
        }
        self.toastLabel.text = message
        self.toastLabel.isHidden = false
        DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + seconds) {
            self.toastLabel.isHidden = true
        }
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
        
        if(loopClosureId > 0)
        {
            mTotalLoopClosures += 1;
        }
        let previousNodes = mMapNodes
        mMapNodes = nodes;
        mLatestDatabaseMemoryMB = databaseMemoryUsed
        mLatestScanStorageBytes = scanStorageBytes
        mLatestPose = (x, y, z, roll, pitch, yaw)
        let estimatedArea = (self.mState == .STATE_MAPPING) ? (supermarketSession?.updateArea(timestamp: Date().timeIntervalSince1970, nodeCount: nodes, x: x, y: y, z: z, roll: roll, pitch: pitch, yaw: yaw) ?? 0.0) : (supermarketSession?.currentAreaM2 ?? 0.0)
        
        let formattedDate = Date().getFormattedDate(format: "HH:mm:ss.SSS")
        
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
                    self.statusLabel.text! +
                    String(format: self.localized("Status: %@\n"), self.getStateString(state: self.mState)) +
                    String(format: self.localized("RAM Usage (MB): %d / %d"), usedMem, self.mMaximumMemory) +
                    String(format: self.localized("\nScan Storage: %@"), self.formattedStorageSize(scanStorageBytes)) +
                    String(format: self.localized("\nScanned Area: %.1f m2"), estimatedArea)
            }
            if self.debugShown {
                self.statusLabel.text =
                    self.statusLabel.text! + "\n"
                var gpsString = "\n"
                if(UserDefaults.standard.bool(forKey: "SaveGPS"))
                {
                    if(self.mLastKnownLocation != nil)
                    {
                        let secondsOld = (Date().timeIntervalSince1970 - self.mLastKnownLocation!.timestamp.timeIntervalSince1970)
                        var bearing = 0.0
                        if(self.mLastKnownLocation!.course > 0.0) {
                            bearing = self.mLastKnownLocation!.course
                            
                        }
                        gpsString = String(format: "GPS: %.2f %.2f %.2fm %ddeg %.0fm [%d sec old]\n",
                                           self.mLastKnownLocation!.coordinate.longitude,
                                           self.mLastKnownLocation!.coordinate.latitude,
                                           self.mLastKnownLocation!.altitude,
                                           Int(bearing),
                                           self.mLastKnownLocation!.horizontalAccuracy,
                                           Int(secondsOld));
                    }
                    else
                    {
                        gpsString = "GPS: [not yet available]\n";
                    }
                }
                var lightString = "\n"
                if(self.mLastLightEstimate != nil)
                {
                    lightString = String("Light (lm): \(Int(self.mLastLightEstimate!))\n")
                }
                
                self.statusLabel.text =
                    self.statusLabel.text! +
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
                            fields: ["loopClosureId": "\(loopClosureId)", "nodeCount": "\(nodes)", "inliers": "\(inliers)"])
                    }
                    if(self.mState == .STATE_VISUALIZING_CAMERA) {
                        self.showToast(message: self.localized("Localized!"), seconds: 1);
                    }
                    else {
                        self.showToast(message: self.localized("Loop closure detected!"), seconds: 1);
                    }
                }
                else if(rejected > 0)
                {
                    if self.mState == .STATE_MAPPING {
                        self.supermarketSession?.appendScanEvent(
                            level: "warning",
                            event: "loop_closure_rejected",
                            message: "Loop closure candidate was rejected",
                            fields: ["nodeCount": "\(nodes)", "inliers": "\(inliers)", "matches": "\(matches)", "optimizationMaxError": "\(optimizationMaxError)"])
                    }
                    if(inliers >= UserDefaults.standard.integer(forKey: "MinInliers"))
                    {
                        if(optimizationMaxError > 0.0)
                        {
                            self.showToast(message: String(format: self.localized("Loop closure rejected, too high graph optimization error (%.3fm: ratio=%.3f < factor=%.1fx)."), optimizationMaxError, optimizationMaxErrorRatio, UserDefaults.standard.float(forKey: "MaxOptimizationError")), seconds: 1);
                        }
                        else
                        {
                            self.showToast(message: self.localized("Loop closure rejected, graph optimization failed! You may try a different Graph Optimizer in Mapping settings."), seconds: 1);
                        }
                    }
                    else
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
        if mState == .STATE_MAPPING || mState == .STATE_CAMERA {
            suspendCaptureForSystemInterruption(reason: "application resigned active")
        }
        else if mState == .STATE_VISUALIZING_CAMERA || mState == .STATE_VISUALIZING_AND_MEASURING {
            stopMapping(ignoreSaving: true)
        }
    }

    private func suspendCaptureForSystemInterruption(reason: String)
    {
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
        rtabmap!.setCamera(type: type);
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
            let format = UserDefaults.standard.string(forKey: "ExportPointCloudFormat")!;
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
            UIAction(title: localized("New Data Recording"), image: UIImage(systemName: "plus.app"), attributes: actionNewDataRecording ? [] : .disabled, state: .off, handler: { _ in
            	self.newScan(dataRecordingMode: true)
        	})
        ])
        
        // Measuring menu
        let measuringMenu = UIMenu(title: localized("Measuring..."), image: UIImage(systemName: "ruler"), children: [
            UIAction(title: localized("Plane to Plane Mode"), image: measuringMode == 0 ? UIImage(systemName: "checkmark.circle") : UIImage(systemName: "circle"), handler: { _ in
                self.measuringMode = 0
                self.rtabmap!.setMeasuringMode(self.measuringMode)
                self.resetNoTouchTimer(true)
            }),
            UIAction(title: localized("Point to Point Mode"), image: measuringMode == 2 ? UIImage(systemName: "checkmark.circle") : UIImage(systemName: "circle"), handler: { _ in
                self.measuringMode = 2
                self.rtabmap!.setMeasuringMode(self.measuringMode)
                self.resetNoTouchTimer(true)
            }),
            UIAction(title: localized("Clear All Measures"), image: UIImage(systemName: "trash"), state: .off, handler: { _ in
                self.clearMeasures();
                self.resetNoTouchTimer(true)
            })
        ])
                
        var fileMenuChildren: [UIMenuElement] = []
        fileMenuChildren.append(UIAction(title: localized("New Mapping Session"), image: UIImage(systemName: "plus.app"), attributes: actionNewScanEnabled ? [] : .disabled, state: .off, handler: { _ in
            self.newScan()
        }))
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
        
        // File menu
        let fileMenu = UIMenu(title: localized("File"), options: .displayInline, children: fileMenuChildren)
        
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
                self.rtabmap!.setOdomCloudShown(shown: self.odomShown)
                self.resetNoTouchTimer(true)
            }),
            UIAction(title: localized("Graph Visible"), image: graphShown ? UIImage(systemName: "checkmark.circle") : UIImage(systemName: "circle"), attributes: (self.mState == .STATE_MAPPING || self.mState == .STATE_CAMERA || self.mState == .STATE_IDLE) ? [] : .disabled, handler: { _ in
                self.graphShown = !self.graphShown
                self.rtabmap!.setGraphVisible(visible: self.graphShown)
                self.resetNoTouchTimer(true)
            }),
            UIAction(title: localized("Grid Visible"), image: gridShown ? UIImage(systemName: "checkmark.circle") : UIImage(systemName: "circle"), handler: { _ in
                self.gridShown = !self.gridShown
                self.rtabmap!.setGridVisible(visible: self.gridShown)
                self.resetNoTouchTimer(true)
            }),
            UIAction(title: localized("Optimized Graph"), image: optimizedGraphShown ? UIImage(systemName: "checkmark.circle") : UIImage(systemName: "circle"), attributes: (self.mState == .STATE_IDLE) ? [] : .disabled, handler: { _ in
                self.optimizedGraphShown = !self.optimizedGraphShown
                self.rtabmap!.setGraphOptimization(enabled: self.optimizedGraphShown)
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

        menuButton.menu = UIMenu(title: "", children: [fileMenu, settingsMenu])
        menuButton.addTarget(self, action: #selector(ViewController.menuOpened(_:)), for: .menuActionTriggered)
        
        // Camera menu
        let renderingMenu = UIMenu(title: "Rendering", options: .displayInline, children: [
            UIAction(title: "Texture/Color Blend", image: self.textureColorSeamsShown ? UIImage(systemName: "checkmark.circle") : UIImage(systemName: "circle"), attributes: self.mState == .STATE_VISUALIZING || self.mState == .STATE_VISUALIZING_CAMERA || self.mState == .STATE_VISUALIZING_AND_MEASURING || self.mState == .STATE_VISUALIZING_WHILE_LOADING ? [] : .disabled, handler: { _ in
                self.textureColorSeamsShown = !self.textureColorSeamsShown
                self.rtabmap!.setTextureColorSeamsHidden(hidden: !self.textureColorSeamsShown)
                self.resetNoTouchTimer(true)
            }),
            UIAction(title: "Wireframe", image: self.wireframeShown ? UIImage(systemName: "checkmark.circle") : UIImage(systemName: "circle"), handler: { _ in
                self.wireframeShown = !self.wireframeShown
                self.rtabmap!.setWireframe(enabled: self.wireframeShown)
                self.resetNoTouchTimer(true)
            }),
            UIAction(title: "Lighting", image: self.lightingShown ? UIImage(systemName: "checkmark.circle") : UIImage(systemName: "circle"), attributes: self.mState == .STATE_VISUALIZING || self.mState == .STATE_VISUALIZING_CAMERA || self.mState == .STATE_VISUALIZING_AND_MEASURING || self.mState == .STATE_VISUALIZING_WHILE_LOADING ? [] : .disabled, handler: { _ in
                self.lightingShown = !self.lightingShown
                self.rtabmap!.setLighting(enabled: self.lightingShown)
                self.resetNoTouchTimer(true)
            }),
            UIAction(title: "Backface", image: self.backfaceShown ? UIImage(systemName: "checkmark.circle") : UIImage(systemName: "circle"), handler: { _ in
                self.backfaceShown = !self.backfaceShown
                self.rtabmap!.setBackfaceCulling(enabled: !self.backfaceShown)
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
        mLastAcceptedARPose = nil
        mLastAcceptedARTimestamp = nil
        mTrackingWasDegraded = true
        mConsecutiveNormalTrackingFrames = 0
        mLastTrackingGuidanceAt = 0
    }

    private func rotationAngleDegrees(_ transform: simd_float4x4) -> Double
    {
        let trace = transform.columns.0.x + transform.columns.1.y + transform.columns.2.z
        let cosine = min(Float(1), max(Float(-1), (trace - 1) / 2))
        return Double(acos(cosine) * 180 / .pi)
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
            supermarketSession?.appendScanEvent(
                event: "tracking_recovery_stabilized",
                message: "ARKit tracking remained normal long enough to resume mapping frames",
                fields: ["normalFrames": "\(mConsecutiveNormalTrackingFrames)"])
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

                // A walking scanner cannot move this far between submitted
                // frames. Treat it as an ARKit coordinate jump, keep the last
                // continuous pose and rebase subsequent raw poses into that
                // coordinate system. PC loop closures can then correct drift
                // without inheriting a false neighbor edge.
                let translationLimit = max(0.45, min(elapsed, 2.0) * 3.0)
                let rotationLimit = max(35.0, min(elapsed, 2.0) * 180.0)
                if distance > translationLimit || rotation > rotationLimit {
                    mARPoseCorrection = simd_mul(previousPose, simd_inverse(rawPose))
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
                            "angularSpeedDegPerSecond": String(format: "%.2f", angularSpeed ?? 0)
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
        
        if !status.isEmpty && mLastLightEstimate != nil && mLastLightEstimate! < 100 && accept {
            status = "Camera Is Occluded Or Lighting Is Too Dark"
        }

        if let rotation = UIApplication.shared.windows.first?.windowScene?.interfaceOrientation
        {
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
                    rtabmap?.postOdometryEvent(
                        frame: frame,
                        orientation: rotation,
                        viewport: self.view.frame.size,
                        poseOverride: correctedPose)
                }
            }
            else if accept {
                rtabmap?.postOdometryEvent(frame: frame, orientation: rotation, viewport: self.view.frame.size)
            }
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
        mLastKnownLocation = locations.last!
        rtabmap?.setGPS(location: locations.last!);
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
            if locationManager != nil {
                if(locationManager!.accuracyAuthorization == .reducedAccuracy) {
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
            guard let orientation = UIApplication.shared.windows.first?.windowScene?.interfaceOrientation else {
                #if DEBUG
                fatalError("Could not obtain UIInterfaceOrientation from a valid windowScene")
                #else
                return nil
                #endif
            }
            return orientation
        }
    }
        
    deinit {
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
        if (firstTouch != nil && secondTouch == nil)
        {
            let pose = firstTouch!.location(in: self.view)
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
        guard rtabmap != nil else {
            return
        }
 
        //let appendMode = defaults.bool(forKey: "AppendMode")
        
        // update preference
        rtabmap!.setOnlineBlending(enabled: defaults.bool(forKey: "Blending"));
        rtabmap!.setNodesFiltering(enabled: defaults.bool(forKey: "NodesFiltering"));
        rtabmap!.setFullResolution(enabled: defaults.bool(forKey: "HDMode"));
        rtabmap!.setSmoothing(enabled: defaults.bool(forKey: "Smoothing"));
        rtabmap!.setDepthBleedingError(value: defaults.float(forKey: "DepthBleedingError"));
        rtabmap!.setAppendMode(enabled: defaults.bool(forKey: "AppendMode"));
        rtabmap!.setUpstreamRelocalizationAccThr(value: defaults.float(forKey: "UpstreamRelocalizationFilteringAccThr"));
        rtabmap!.setExportPointCloudFormat(format: defaults.string(forKey: "ExportPointCloudFormat")!);
        
        mTimeThr = (defaults.string(forKey: "TimeLimit")! as NSString).integerValue
        mMaxFeatures = (defaults.string(forKey: "MaxFeaturesExtractedLoopClosure")! as NSString).integerValue
        
        // Mapping parameters
        rtabmap!.setMappingParameter(key: "Rtabmap/DetectionRate", value: defaults.string(forKey: "UpdateRate")!);
        rtabmap!.setMappingParameter(key: "Rtabmap/TimeThr", value: defaults.string(forKey: "TimeLimit")!);
        rtabmap!.setMappingParameter(key: "Rtabmap/MemoryThr", value: defaults.string(forKey: "MemoryLimit")!);
        rtabmap!.setMappingParameter(key: "RGBD/LinearSpeedUpdate", value: defaults.string(forKey: "MaximumMotionSpeed")!);
        let motionSpeed = ((defaults.string(forKey: "MaximumMotionSpeed")!) as NSString).floatValue/2.0;
        rtabmap!.setMappingParameter(key: "RGBD/AngularSpeedUpdate", value: NSString(format: "%.2f", motionSpeed) as String);
        rtabmap!.setMappingParameter(key: "Rtabmap/LoopThr", value: defaults.string(forKey: "LoopClosureThreshold")!);
        rtabmap!.setMappingParameter(key: "Mem/RehearsalSimilarity", value: defaults.string(forKey: "SimilarityThreshold")!);
        rtabmap!.setMappingParameter(key: "Kp/MaxFeatures", value: defaults.string(forKey: "MaxFeaturesExtractedVocabulary")!);
        rtabmap!.setMappingParameter(key: "Vis/MaxFeatures", value: defaults.string(forKey: "MaxFeaturesExtractedLoopClosure")!);
        rtabmap!.setMappingParameter(key: "Vis/MinInliers", value: defaults.string(forKey: "MinInliers")!);
        rtabmap!.setMappingParameter(key: "RGBD/OptimizeMaxError", value: defaults.string(forKey: "MaxOptimizationError")!);
        rtabmap!.setMappingParameter(key: "Kp/DetectorStrategy", value: defaults.string(forKey: "FeatureType")!);
        rtabmap!.setMappingParameter(key: "Vis/FeatureType", value: defaults.string(forKey: "FeatureType")!);
        rtabmap!.setMappingParameter(key: "Mem/NotLinkedNodesKept", value: defaults.bool(forKey: "SaveAllFramesInDatabase") ? "true" : "false");
        rtabmap!.setMappingParameter(key: "RGBD/OptimizeFromGraphEnd", value: defaults.bool(forKey: "OptimizationfromGraphEnd") ? "true" : "false");
        rtabmap!.setMappingParameter(key: "RGBD/MaxOdomCacheSize", value: defaults.string(forKey: "MaximumOdometryCacheSize")!);
        rtabmap!.setMappingParameter(key: "Optimizer/Strategy", value: defaults.string(forKey: "GraphOptimizer")!);
        rtabmap!.setMappingParameter(key: "RGBD/ProximityBySpace", value: defaults.string(forKey: "ProximityDetection")!);
        applyStreamingMappingSettings()

        let markerDetection = defaults.integer(forKey: "ArUcoMarkerDetection")
        // Continuous supermarket scanning currently uses the software-only
        // profile. Do not let an old Settings value silently add AprilTag,
        // ArUco or landmark constraints to this graph.
        if(markerDetection == -1 || !mDataRecording)
        {
            rtabmap!.setMappingParameter(key: "RGBD/MarkerDetection", value: "false");
        }
        else
        {
            rtabmap!.setMappingParameter(key: "RGBD/MarkerDetection", value: "true");
            rtabmap!.setMappingParameter(key: "Marker/Dictionary", value: defaults.string(forKey: "ArUcoMarkerDetection")!);
            rtabmap!.setMappingParameter(key: "Marker/CornerRefinementMethod", value: (markerDetection > 16 ? "3":"0"));
            rtabmap!.setMappingParameter(key: "Marker/MaxDepthError", value: defaults.string(forKey: "MarkerDepthErrorEstimation")!);
            rtabmap!.setMappingParameter(key: "Marker/MaxRange", value: defaults.string(forKey: "MarkerMaxRange")!);
            if let val = NumberFormatter().number(from: defaults.string(forKey: "MarkerSize")!)?.doubleValue
            {
                rtabmap!.setMappingParameter(key: "Marker/Length", value: String(format: "%f", val/100.0))
            }
            else{
                rtabmap!.setMappingParameter(key: "Marker/Length", value: "0")
            }
        }

        // Rendering
        rtabmap!.setCloudDensityLevel(value: defaults.integer(forKey: "PointCloudDensity"));
        rtabmap!.setMaxCloudDepth(value: defaults.float(forKey: "MaxDepth"));
        rtabmap!.setMinCloudDepth(value: defaults.float(forKey: "MinDepth"));
        rtabmap!.setDepthConfidence(value: defaults.integer(forKey: "DepthConfidence"));
        rtabmap!.setPointSize(value: defaults.float(forKey: "PointSize"));
        rtabmap!.setMeshAngleTolerance(value: defaults.float(forKey: "MeshAngleTolerance"));
        rtabmap!.setMeshTriangleSize(value: defaults.integer(forKey: "MeshTriangleSize"));
        rtabmap!.setMeshDecimationFactor(value: defaults.float(forKey: "MeshDecimationFactor"));
        let bgColor = defaults.float(forKey: "BackgroundColor");
        rtabmap!.setBackgroundColor(gray: bgColor);
        
        DispatchQueue.main.async {
            self.statusLabel.textColor = bgColor>=0.6 ? UIColor(white: 0.0, alpha: 1) : UIColor(white: 1.0, alpha: 1)
        }
    
        rtabmap!.setClusterRatio(value: defaults.float(forKey: "NoiseFilteringRatio"));
        rtabmap!.setMaxGainRadius(value: defaults.float(forKey: "ColorCorrectionRadius"));
        rtabmap!.setRenderingTextureDecimation(value: defaults.integer(forKey: "TextureResolution"));
        
        rtabmap!.setMetricSystem(defaults.integer(forKey: "MeasuringUnits") == 0);
        rtabmap!.setMeasuringTextSize(defaults.float(forKey: "MeasuringTextSize"));
        
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
            rtabmap!.postExportation(visualize: false)
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
    
    func newScan(dataRecordingMode: Bool = false)
    {
        guard mState != .STATE_MAPPING else {
            showToast(
                message: localized("A scan is in progress. Use the Stop button before starting another scan."),
                seconds: 4)
            return
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
        if(!(self.mState == State.STATE_CAMERA || self.mState == State.STATE_MAPPING) &&
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
                    self.newScan(dataRecordingMode: dataRecordingMode)
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
                            self.view.addSubview(indicator!)
                            indicator?.bringSubviewToFront(self.view)
                            
                            indicator?.startAnimating()
                            self.rtabmap!.cancelProcessing();
                        })
                    }
                    alertView.addAction(alertViewActionCancel)
                    
                    let previousState = self.mState
                    self.updateState(state: .STATE_PROCESSING);
                    
                    self.present(alertView, animated: true, completion: {
                        //  Add your progressbar after alert is shown (and measured)
                        let margin:CGFloat = 8.0
                        let rect = CGRect(x: margin, y: 84.0, width: alertView.view.frame.width - margin * 2.0 , height: 2.0)
                        self.progressView = UIProgressView(frame: rect)
                        self.progressView!.progress = 0
                        self.progressView!.tintColor = self.view.tintColor
                        alertView.view.addSubview(self.progressView!)
                        
                        var success : Bool = false
                        DispatchQueue.background(background: {
                            
                            success = self.rtabmap!.recover(from: tmpDatabase.path, to: outputDbPath)
                            
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
            }
            catch {
                showToast(message: String(format: localized("Could not create supermarket session: %@"), error.localizedDescription), seconds: 4)
                if didStartSecurityScope {
                    supermarketSession?.stopAccessingBaseDirectorySecurityScope()
                }
                return
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
                    return
                }
            }
            let inMemory = dataRecordingMode ? UserDefaults.standard.bool(forKey: "DatabaseInMemory") : false
            mDataRecording = dataRecordingMode
            self.rtabmap!.setDataRecorderMode(enabled: dataRecordingMode)
            applyStreamingMappingSettings()
            self.rtabmap!.setPreserveCameraOrigin(enabled: false)
            self.optimizedGraphShown = true // Always reset to true when opening a database
            self.rtabmap!.openDatabase(databasePath: activeDatabase.path, databaseInMemory: inMemory, optimize: false, clearDatabase: true)
            self.mLatestDatabaseMemoryMB = 0
            self.mLatestScanStorageBytes = 0
            self.mLastStreamingCheckpointAt = 0
            self.mStreamingCheckpointInFlight = false
            self.mStreamingDiskWarningShown = false
            self.mStreamingCriticalStopRequested = false
            self.mStreamingThermalWarningShown = false
            self.mStreamingMemoryPressureLevel = 0
            self.mLastLoggedTrackingState = ""
            self.resetSoftwarePoseStabilizer()
            if !dataRecordingMode {
                self.supermarketSession?.appendScanEvent(
                    event: "scan_started",
                    message: "Continuous streaming scan started",
                    fields: [
                        "database": activeDatabase.lastPathComponent,
                        "workingMemoryNodes": "\(self.supermarketIntDefault(self.supermarketStreamingMemoryNodesKey, fallback: self.supermarketDefaultStreamingMemoryNodes))",
                        "errorOptimizationProfile": "software_only_no_fiducials",
                        "fiducialsEnabled": "false"
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
                self.startCamera();
            }
        }
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
            // Keep enough phone-side visual feedback to catch bad coverage and
            // obvious loop closures, while PC reprocessing remains authoritative.
            rtabmap.setMappingParameter(key: "Kp/MaxFeatures", value: "500")
            rtabmap.setMappingParameter(key: "Rtabmap/MaxRetrieved", value: "3")
            rtabmap.setMappingParameter(key: "Rtabmap/LoopThr", value: "0.15")
            rtabmap.setMappingParameter(key: "RGBD/MaxLocalRetrieved", value: "3")
            rtabmap.setMappingParameter(key: "RGBD/ProximityByTime", value: "true")
            rtabmap.setMappingParameter(key: "RGBD/ProximityBySpace", value: "true")
            rtabmap.setMappingParameter(key: "RGBD/ProximityOdomGuess", value: "true")
            rtabmap.setMappingParameter(key: "RGBD/OptimizeMaxError", value: "2.0")
            rtabmap.setMappingParameter(key: "RGBD/OptimizeMaxErrorRepairRadius", value: "1.0")
            rtabmap.setMappingParameter(key: "Vis/MinInliers", value: "40")
            rtabmap.setMappingParameter(key: "Mem/UseOdomGravity", value: "true")
            rtabmap.setMappingParameter(key: "Optimizer/Iterations", value: "30")
            rtabmap.setMappingParameter(key: "Optimizer/GravitySigma", value: "0.2")
            rtabmap.setMappingParameter(key: "Optimizer/Robust", value: "true")
            rtabmap.setMappingParameter(key: "Optimizer/PriorsIgnored", value: "true")
            rtabmap.setMappingParameter(key: "Optimizer/LandmarksIgnored", value: "true")
            rtabmap.setMappingParameter(key: "RGBD/MarkerDetection", value: "false")
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

    private func finalizeStreamingScan(completion: ((Bool) -> Void)? = nil)
    {
        guard let scanSession = supermarketSession,
              !scanSession.isFinalizingScan,
              mMapNodes > 0 else {
            completion?(false)
            return
        }

        let segmentDirectory: URL
        let databaseURL: URL
        do {
            segmentDirectory = try scanSession.currentSegmentDirectory()
            databaseURL = try scanSession.streamingDatabaseURL()
        }
        catch {
            showToast(message: String(format: localized("Could not finalize streaming scan: %@"), error.localizedDescription), seconds: 4)
            completion?(false)
            return
        }

        scanSession.isFinalizingScan = true
        scanSession.appendScanEvent(
            event: "scan_finalization_started",
            message: "Finalizing the continuous streaming database",
            fields: ["nodeCount": "\(mMapNodes)", "scanStorageBytes": "\(mLatestScanStorageBytes)"])
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
        let finalNodeCount = mMapNodes
        let finalDatabaseMemoryMB = mLatestDatabaseMemoryMB
        let finalKnownAreaM2 = scanSession.currentAreaM2
        let finalPriceTagCount = scanSession.priceTags.count
        let finalizedAt = Date().getFormattedDate(format: "yyyy-MM-dd HH:mm:ss")
        let availableBytesAtFinalization = availableDiskBytes(at: segmentDirectory)
        let thermalStateAtFinalization = currentThermalStateText()

        session.pause()
        locationManager?.stopUpdatingLocation()
        rtabmap?.setPausedMapping(paused: true)
        rtabmap?.stopCamera()
        updateState(state: .STATE_PROCESSING)
        showToast(message: localized("Finalizing continuous streaming database..."), seconds: 2)

        var saveSucceeded = false
        var sidecarError: String?
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
                    let metadata = ScanSegmentMetadata(
                        segmentIndex: 1,
                        scanMode: "continuous_streaming",
                        finalized: true,
                        processingProfile: "iphone_continuous_pc_offline_software_error_v2_no_fiducials",
                        exportedAt: finalizedAt,
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
                        databaseBytes: finalDatabaseBytes,
                        availableDiskBytes: availableBytesAtFinalization,
                        thermalState: thermalStateAtFinalization,
                        captureHealth: boundary.captureHealth)
                    let finalSnapshot = scanSession.makeSidecarSnapshot(metadata: metadata)
                    snapshot = finalSnapshot
                    try scanSession.writeSidecarFiles(to: segmentDirectory, snapshot: finalSnapshot)
                }
                catch {
                    sidecarError = error.localizedDescription
                }
                sidecarSeconds = Date().timeIntervalSince(sidecarStartedAt)
            }
        }, completion: {
            guard saveSucceeded, sidecarError == nil, let snapshot = snapshot else {
                if didStartSecurityScope {
                    exportBaseDirectory?.stopAccessingSecurityScopedResource()
                }
                scanSession.isFinalizingScan = false
                scanSession.appendScanEvent(
                    level: "error",
                    event: "scan_finalization_failed",
                    message: sidecarError ?? "Streaming database save failed")
                self.showToast(message: sidecarError.map { String(format: self.localized("Streaming database was saved, but metadata failed: %@"), $0) } ?? self.localized("Streaming database save failed."), seconds: 5)
                self.setGLCamera(type: 0)
                self.startCamera(resetTracking: false)
                self.rtabmap?.setPausedMapping(paused: false)
                self.updateState(state: .STATE_MAPPING)
                completion?(false)
                return
            }

            scanSession.appendScanEvent(
                event: "scan_finalized",
                message: "Continuous streaming database finalized",
                fields: [
                    "nodeCount": "\(snapshot.metadata.nodeCount)",
                    "databaseBytes": "\(finalDatabaseBytes)",
                    "saveSeconds": String(format: "%.3f", saveSeconds),
                    "sidecarSeconds": String(format: "%.3f", sidecarSeconds)
                ])
            let finalScanStorageBytes = self.captureDirectoryStorageBytes(at: segmentDirectory)

            // Detach RTAB-Map from the completed database before a background
            // external copy is allowed to remove the local capture directory.
            let tmpDatabase = self.getDocumentDirectory().appendingPathComponent(self.RTABMAP_TMP_DB)
            self.rtabmap!.openDatabase(databasePath: tmpDatabase.path, databaseInMemory: false, optimize: false, clearDatabase: true)
            self.mMapNodes = 0
            self.mLatestDatabaseMemoryMB = 0
            self.mLatestScanStorageBytes = finalScanStorageBytes
            self.setGLCamera(type: 2)
            self.updateState(state: .STATE_IDLE)
            print(String(format: "Streaming scan finalized: save=%.2fs sidecar=%.2fs", saveSeconds, sidecarSeconds))

            // The verified local database is already complete. Release this
            // session now so the next scan can start while a large external
            // copy continues against captured immutable paths.
            scanSession.completeCurrentSession()
            scanSession.isFinalizingScan = false
            self.showToast(message: self.localized("Continuous streaming scan finalized as one database."), seconds: 3)
            completion?(true)

            if let exportBaseDirectory = exportBaseDirectory {
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
        var cleanupErrorMessage: String?
        var localCaptureRemoved = false
        var copySeconds = 0.0
        DispatchQueue.background(background: {
            let copyStartedAt = Date()
            do {
                if let copiedCapture = try scanSession.copyCaptureToCustomBaseDirectory(
                    from: captureDir,
                    destinationBaseDirectory: exportBaseDirectory) {
                    copiedCapturePath = copiedCapture.path
                    do {
                        try scanSession.removeLocalCaptureDirectory(captureDir)
                        localCaptureRemoved = true
                    }
                    catch {
                        cleanupErrorMessage = error.localizedDescription
                        print("Could not remove local scan after external copy: \(error)")
                    }
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
            else if copiedCapturePath != nil, let cleanupErrorMessage = cleanupErrorMessage {
                self.showToast(message: String(format: self.localized("The scan was copied to the selected location, but local cleanup failed: %@"), cleanupErrorMessage), seconds: 5)
            }
            else if copiedCapturePath != nil && localCaptureRemoved {
                self.showToast(message: String(format: self.localized("The scan was copied in background and the local copy was removed. Copy: %.1fs."), copySeconds), seconds: 3)
            }
            else if copiedCapturePath != nil {
                self.showToast(message: String(format: self.localized("The scan was copied to the selected location in background. Copy: %.1fs."), copySeconds), seconds: 3)
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
        newScan()
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
    //1
    let previousDatabaseView = horizontalScrollerView.view(at: currentDatabaseIndex) as! DatabaseView
    previousDatabaseView.highlightDatabase(false)
    //2
    currentDatabaseIndex = index
    //3
    let databaseView = horizontalScrollerView.view(at: currentDatabaseIndex) as! DatabaseView
    databaseView.highlightDatabase(true)
    //4
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
