//
//  RTABMap.swift
//  RTABMapApp
//
//  Created by Mathieu Labbe on 2020-12-31.
//

import Foundation
import ARKit
import simd

/// One atomic native publication snapshot. A named value prevents downstream
/// consumers from silently retaining an older tuple shape when the C/Swift
/// contract gains another identity or pose field.
struct RTABMapNodeBindingSnapshot {
    let nodeId: Int
    let nodeMapId: Int32
    let nodeStamp: TimeInterval
    let nodeTimebaseFrameTimestamp: TimeInterval
    let nodeTimebaseOffsetSeconds: TimeInterval
    let deltaSeconds: TimeInterval
    let generation: UInt64
    let openGLWorldFromNode: simd_float4x4
}

struct RTABMapLoopClosureLinkSnapshot {
    let fromNodeID: Int
    let toNodeID: Int
    let fromNodeMapID: Int32
    let toNodeMapID: Int32
    let nativeLinkType: String
    let generation: UInt64
    let measurement: simd_float4x4
}

class RTABMap {
    var native_rtabmap: UnsafeMutableRawPointer
    
    struct Observation {
        weak var observer: RTABMapObserver?
    }
    private var observations = [ObjectIdentifier : Observation]()
    
    func addObserver(_ observer: RTABMapObserver) {
        let id = ObjectIdentifier(observer)
        observations[id] = Observation(observer: observer)
    }

    func removeObserver(_ observer: RTABMapObserver) {
        let id = ObjectIdentifier(observer)
        observations.removeValue(forKey: id)
    }
    
    init() {
        native_rtabmap = UnsafeMutableRawPointer(mutating: createNativeApplication())
    }
    
    func setupCallbacksWithCPP()
    {
        setupCallbacksNative(native_rtabmap,
             UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
             //progressCallback
             {(observer, count, max) -> Void in
                guard let observer else { return }
                let mySelf = Unmanaged<RTABMap>.fromOpaque(observer)
                    .takeUnretainedValue()
                         // Call instance method:
                         //mySelf.TestMethod();
                for (id, observation) in mySelf.observations {
                    // If the observer is no longer in memory, we
                    // can clean up the observation for its ID
                    guard let observer = observation.observer else {
                        mySelf.observations.removeValue(forKey: id)
                        continue
                    }

                    observer.progressUpdated(mySelf, count: Int(count), max: Int(max))
                }
             },
             //initCallback
             {(observer, status, msg) -> Void in
                guard let observer, let msg else { return }
                let mySelf = Unmanaged<RTABMap>.fromOpaque(observer)
                    .takeUnretainedValue()
                         // Call instance method:
                         //mySelf.TestMethod();
                for (id, observation) in mySelf.observations {
                    // If the observer is no longer in memory, we
                    // can clean up the observation for its ID
                    guard let observer = observation.observer else {
                        mySelf.observations.removeValue(forKey: id)
                        continue
                    }

                    let str = String(cString: msg)
                    observer.initEventReceived(mySelf, status: Int(status), msg: str)
                }
             },
             //statsUpdatedCallback
             {(observer, nodes, words, points, polygons, updateTime, loopClosureId, highestHypId, databaseMemoryUsed, inliers, matches, featuresExtracted, hypothesis, nodesDrawn, fps, rejected, rehearsalValue, optimizationMaxError, optimizationMaxErrorRatio, distanceTravelled, fastMovement, landmarkDetected, loopClosureType, loopClosureCurrentId, loopClosureTargetId, mapCorrectionX, mapCorrectionY, mapCorrectionZ, mapCorrectionQx, mapCorrectionQy, mapCorrectionQz, mapCorrectionQw, x, y, z, roll, pitch, yaw) -> Void in
                guard let observer else { return }
                let mySelf = Unmanaged<RTABMap>.fromOpaque(observer)
                    .takeUnretainedValue()
                         // Call instance method:
                         //mySelf.TestMethod();
                for (id, observation) in mySelf.observations {
                    // If the observer is no longer in memory, we
                    // can clean up the observation for its ID
                    guard let observer = observation.observer else {
                        mySelf.observations.removeValue(forKey: id)
                        continue
                    }

                    observer.statsUpdated(mySelf, nodes: Int(nodes), words: Int(words), points: Int(points), polygons: Int(polygons), updateTime: updateTime, loopClosureId: Int(loopClosureId), highestHypId: Int(highestHypId), databaseMemoryUsed: Int(databaseMemoryUsed), inliers: Int(inliers), matches: Int(matches), featuresExtracted: Int(featuresExtracted), hypothesis: hypothesis, nodesDrawn: Int(nodesDrawn), fps: fps, rejected: Int(rejected), rehearsalValue: rehearsalValue, optimizationMaxError: optimizationMaxError, optimizationMaxErrorRatio: optimizationMaxErrorRatio, distanceTravelled: distanceTravelled, fastMovement: Int(fastMovement), landmarkDetected: Int(landmarkDetected), loopClosureType: Int(loopClosureType), loopClosureCurrentId: Int(loopClosureCurrentId), loopClosureTargetId: Int(loopClosureTargetId), mapCorrectionX: mapCorrectionX, mapCorrectionY: mapCorrectionY, mapCorrectionZ: mapCorrectionZ, mapCorrectionQx: mapCorrectionQx, mapCorrectionQy: mapCorrectionQy, mapCorrectionQz: mapCorrectionQz, mapCorrectionQw: mapCorrectionQw, x: x, y: y, z: z, roll: roll, pitch: pitch, yaw: yaw)
                }
             },
             //cameraInfoEventCallback
             {(observer, type, key, value) -> Void in
                guard let observer, let key, let value else { return }
                let mySelf = Unmanaged<RTABMap>.fromOpaque(observer)
                    .takeUnretainedValue()
                         // Call instance method:
                         //mySelf.TestMethod();
                for (id, observation) in mySelf.observations {
                    // If the observer is no longer in memory, we
                    // can clean up the observation for its ID
                    guard let observer = observation.observer else {
                        mySelf.observations.removeValue(forKey: id)
                        continue
                    }
					
                    let strKey = String(cString: key)
                    let strValue = String(cString: value)
                    observer.cameraInfoEventReceived(mySelf, type: Int(type), key: strKey, value: strValue)
                }
             })
    }
    
    deinit {
        destroyNativeApplication(native_rtabmap)
    }

    func latestNodeBinding(
        frameTimestamp: TimeInterval
    ) -> RTABMapNodeBindingSnapshot? {
        var nodeId: Int32 = 0
        var nodeMapId: Int32 = 0
        var nodeStamp = 0.0
        var epochOffset = 0.0
        var generation: UInt64 = 0
        var nodeX: Float = 0
        var nodeY: Float = 0
        var nodeZ: Float = 0
        var nodeQx: Float = 0
        var nodeQy: Float = 0
        var nodeQz: Float = 0
        var nodeQw: Float = 0
        guard frameTimestamp.isFinite,
              getNodeTimeSnapshotNative(
                native_rtabmap,
                &nodeId,
                &nodeMapId,
                &nodeStamp,
                &epochOffset,
                &generation,
                &nodeX, &nodeY, &nodeZ,
                &nodeQx, &nodeQy, &nodeQz, &nodeQw),
              nodeId > 0,
              nodeStamp.isFinite,
              epochOffset.isFinite,
              epochOffset != 0,
              generation > 0,
              [nodeX, nodeY, nodeZ, nodeQx, nodeQy, nodeQz, nodeQw]
                .allSatisfy(\.isFinite) else {
            return nil
        }
        let quaternion = simd_quatf(
            ix: nodeQx, iy: nodeQy, iz: nodeQz, r: nodeQw)
        guard abs(simd_length(quaternion.vector) - 1) <= 1.0e-3 else {
            return nil
        }
        var openGLWorldFromNode = simd_float4x4(quaternion)
        openGLWorldFromNode.columns.3 = SIMD4<Float>(nodeX, nodeY, nodeZ, 1)
        let nodeTimebaseFrameTimestamp = frameTimestamp + epochOffset
        let delta = abs(nodeTimebaseFrameTimestamp - nodeStamp)
        guard nodeTimebaseFrameTimestamp.isFinite, delta <= 1.0 else {
            return nil
        }
        return RTABMapNodeBindingSnapshot(
            nodeId: Int(nodeId),
            nodeMapId: nodeMapId,
            nodeStamp: nodeStamp,
            nodeTimebaseFrameTimestamp: nodeTimebaseFrameTimestamp,
            nodeTimebaseOffsetSeconds: epochOffset,
            deltaSeconds: delta,
            generation: generation,
            openGLWorldFromNode: openGLWorldFromNode)
    }

    func nodeTimebase(frameTimestamp: TimeInterval) -> (
        timestamp: TimeInterval, offsetSeconds: TimeInterval
    )? {
        var offset = 0.0
        guard frameTimestamp.isFinite,
              getNodeTimeOffsetNative(native_rtabmap, &offset),
              offset.isFinite else {
            return nil
        }
        return (frameTimestamp + offset, offset)
    }

    /// Returns only the native graph edge frozen for the exact loop callback
    /// IDs. A later event, a missing edge or an unsupported link type cannot
    /// be substituted by mapCorrection or a visual inlier summary.
    func latestLoopClosureLink(
        fromNodeID expectedFromNodeID: Int,
        toNodeID expectedToNodeID: Int
    ) -> RTABMapLoopClosureLinkSnapshot? {
        guard expectedFromNodeID > 0, expectedToNodeID > 0,
              expectedFromNodeID <= Int(Int32.max),
              expectedToNodeID <= Int(Int32.max) else {
            return nil
        }
        var fromNodeID: Int32 = 0
        var toNodeID: Int32 = 0
        var fromNodeMapID: Int32 = 0
        var toNodeMapID: Int32 = 0
        var linkType: Int32 = 0
        var generation: UInt64 = 0
        var x: Float = 0
        var y: Float = 0
        var z: Float = 0
        var qx: Float = 0
        var qy: Float = 0
        var qz: Float = 0
        var qw: Float = 0
        guard getLoopClosureLinkSnapshotNative(
                native_rtabmap,
                Int32(expectedFromNodeID),
                Int32(expectedToNodeID),
                &fromNodeID, &toNodeID,
                &fromNodeMapID, &toNodeMapID,
                &linkType, &generation,
                &x, &y, &z, &qx, &qy, &qz, &qw),
              Int(fromNodeID) == expectedFromNodeID,
              Int(toNodeID) == expectedToNodeID,
              fromNodeMapID >= 0, toNodeMapID >= 0,
              generation > 0,
              [x, y, z, qx, qy, qz, qw].allSatisfy(\.isFinite) else {
            return nil
        }
        let nativeLinkType: String
        switch linkType {
        case 1:
            nativeLinkType = "global_visual"
        case 2:
            nativeLinkType = "local_space"
        default:
            return nil
        }
        let quaternion = simd_quatf(ix: qx, iy: qy, iz: qz, r: qw)
        guard abs(simd_length(quaternion.vector) - 1) <= 1.0e-3 else {
            return nil
        }
        var measurement = simd_float4x4(quaternion)
        measurement.columns.3 = SIMD4<Float>(x, y, z, 1)
        return RTABMapLoopClosureLinkSnapshot(
            fromNodeID: Int(fromNodeID),
            toNodeID: Int(toNodeID),
            fromNodeMapID: fromNodeMapID,
            toNodeMapID: toNodeMapID,
            nativeLinkType: nativeLinkType,
            generation: generation,
            measurement: measurement)
    }
    
    func initGlContent() {
        initGlContentNative(native_rtabmap)
    }
    
    func setupGraphic(size: CGSize, orientation: UIInterfaceOrientation) {
        var rotation: Int32
        switch orientation.rawValue {
        case 4:
            rotation=2
        case 1:
            rotation=3
        case 2:
            rotation=1
        default:
            rotation=0
        }
        //NSLog("Orientation: ios %d android %d, view=%dx%d", orientation.rawValue, rotation, Int32(size.width), Int32(size.height))
        setScreenRotationNative(native_rtabmap, rotation)
        setupGraphicNative(native_rtabmap, Int32(size.width), Int32(size.height));
    }
    
    func openDatabase(databasePath:String, databaseInMemory:Bool, optimize:Bool, clearDatabase: Bool) -> Int {
        databasePath.utf8CString.withUnsafeBufferPointer { buffer -> Int in
            return Int(openDatabaseNative(native_rtabmap, buffer.baseAddress, databaseInMemory, optimize, clearDatabase))
        }
    }
    
    @discardableResult
    func save(databasePath:String, savePreview: Bool = true) -> Bool {
        databasePath.utf8CString.withUnsafeBufferPointer { buffer in
            saveNative(native_rtabmap, buffer.baseAddress, savePreview)
        }
    }
    
    func recover(from: String, to: String) -> Bool {
        from.utf8CString.withUnsafeBufferPointer { bufferFrom -> Bool in
            to.utf8CString.withUnsafeBufferPointer { bufferTo -> Bool in
                return recoverNative(native_rtabmap, bufferFrom.baseAddress, bufferTo.baseAddress)
            }
        }
    }

    func mergeDatabases(inputDatabasePaths: [String], outputDatabasePath: String) -> Bool {
        inputDatabasePaths.joined(separator: ";").utf8CString.withUnsafeBufferPointer { bufferInput -> Bool in
            outputDatabasePath.utf8CString.withUnsafeBufferPointer { bufferOutput -> Bool in
                return mergeDatabasesNative(native_rtabmap, bufferInput.baseAddress, bufferOutput.baseAddress)
            }
        }
    }
    
    func removeMeasure() {
        removeMeasureNative(native_rtabmap)
    }
    func addMeasureButtonClicked() {
        addMeasureNative(native_rtabmap)
    }
    func teleportButtonClicked() {
        teleportNative(native_rtabmap)
    }
    func setMeasuringMode(_ mode: Int) {
        setMeasuringModeNative(native_rtabmap, Int32(mode))
    }
    func setMetricSystem(_ enabled: Bool) {
        setMetricSystemNative(native_rtabmap, enabled)
    }
    func setMeasuringTextSize(_ size: Float32) {
        setMeasuringTextSizeNative(native_rtabmap, size)
    }
    func clearMeasures() {
        clearMeasuresNative(native_rtabmap)
    }
    func cancelProcessing() {
        cancelProcessingNative(native_rtabmap);
    }
    
    func postProcessing(approach: Int) -> Int {
        return Int(postProcessingNative(native_rtabmap, Int32(approach)))
    }
    
    func exportMesh(
        cloudVoxelSize: Float,
        regenerateCloud: Bool,
        meshing: Bool,
        textureSize: Int,
        textureCount: Int,
        normalK: Int,
        optimized: Bool,
        optimizedVoxelSize: Float,
        optimizedDepth: Int,
        optimizedMaxPolygons: Int,
        optimizedColorRadius: Float,
        optimizedCleanWhitePolygons: Bool,
        optimizedMinClusterSize: Int,
        optimizedMaxTextureDistance: Float,
        optimizedMinTextureClusterSize: Int,
        textureVertexColorPolicy: Int,
        blockRendering: Bool) -> Bool
    {
       return exportMeshNative(native_rtabmap,
                                    cloudVoxelSize,
                                    regenerateCloud,
                                    meshing,
                                    Int32(textureSize),
                                    Int32(textureCount),
                                    Int32(normalK),
                                    optimized,
                                    optimizedVoxelSize,
                                    Int32(optimizedDepth),
                                    Int32(optimizedMaxPolygons),
                                    optimizedColorRadius,
                                    optimizedCleanWhitePolygons,
                                    Int32(optimizedMinClusterSize),
                                    optimizedMaxTextureDistance,
                                    Int32(optimizedMinTextureClusterSize),
                            		Int32(textureVertexColorPolicy),
                                    blockRendering)
    }
    
    func postExportation(visualize: Bool) -> Bool
    {
        return postExportationNative(native_rtabmap, visualize)
    }
    
    func writeExportedMesh(directory: String, name: String) -> Bool
    {
        directory.utf8CString.withUnsafeBufferPointer { bufferDir in
            name.utf8CString.withUnsafeBufferPointer { bufferName in
                return writeExportedMeshNative(native_rtabmap, bufferDir.baseAddress, bufferName.baseAddress)
            }
        }
    }
    
    func onTouchEvent(touch_count: Int, event: Int, x0: Float, y0: Float, x1: Float, y1: Float) {
        onTouchEventNative(native_rtabmap, Int32(touch_count), Int32(event), x0, y0, x1, y1)
    }
    
    func setPausedMapping(paused: Bool, triggerNewMap: Bool = true) {
        setPausedMappingNative(native_rtabmap, paused, triggerNewMap)
    }
    
    func render() -> Int {
        return Int(renderNative(native_rtabmap))
    }
    
    func startCamera(imageOverlayInFirstPerson: Bool = true) -> Bool {
        return startCameraNative(native_rtabmap)
    }
    
    func stopCamera() {
        stopCameraNative(native_rtabmap)
    }

    func setPreserveCameraOrigin(enabled: Bool) {
        setPreserveCameraOriginNative(native_rtabmap, enabled)
    }

    func cameraOriginOffset() -> [Float]? {
        var x: Float = 0
        var y: Float = 0
        var z: Float = 0
        var qx: Float = 0
        var qy: Float = 0
        var qz: Float = 0
        var qw: Float = 1
        guard getCameraOriginOffsetNative(native_rtabmap, &x, &y, &z, &qx, &qy, &qz, &qw) else {
            return nil
        }
        return [x, y, z, qx, qy, qz, qw]
    }

    func setStreamingMapMode(enabled: Bool, maxRenderedNodes: Int) {
        setStreamingMapModeNative(native_rtabmap, enabled, Int32(maxRenderedNodes))
    }
    
    func setCamera(type: Int) {
        setCameraNative(native_rtabmap, Int32(type))
    }

    func postOdometryEvent(
        frame: ARFrame,
        orientation: UIInterfaceOrientation,
        viewport: CGSize,
        poseOverride: simd_float4x4? = nil
    ) -> Bool {
        // The image/depth calibration still comes from the ARFrame. Only the
        // global VIO pose may be rebased to remove an impossible ARKit jump.
        let pose = poseOverride ?? frame.camera.transform
        let rotation = GLKMatrix3(
            m: (pose[0,0], pose[0,1], pose[0,2],
            pose[1,0], pose[1,1], pose[1,2],
            pose[2,0], pose[2,1], pose[2,2]))
        
        let quat = GLKQuaternionMakeWithMatrix3(rotation)
                
        let confMap = frame.sceneDepth?.confidenceMap
        let depthMap = frame.sceneDepth?.depthMap
        let points = frame.rawFeaturePoints?.points

        var submitted = false
        if let points, depthMap != nil || !points.isEmpty
        {
            var v = frame.camera.viewMatrix(for: orientation)
            if let poseOverride = poseOverride {
                // Keep the first-person projection in the same rebased world
                // frame as the odometry pose. C = correctedWorld_T_rawWorld,
                // therefore corrected view = raw view * inverse(C).
                let correction = simd_mul(poseOverride, simd_inverse(frame.camera.transform))
                v = simd_mul(v, simd_inverse(correction))
            }
            let p = frame.camera.projectionMatrix(for: orientation, viewportSize: viewport, zNear: 0.5, zFar: 50.0)
            
            let rotation = GLKMatrix3(
                m: (v[0,0], v[0,1], v[0,2],
                    v[1,0], v[1,1], v[1,2],
                    v[2,0], v[2,1], v[2,2]))
            
            let quatv = GLKQuaternionMakeWithMatrix3(rotation)
            
            let texX1 = (1-(2*frame.camera.intrinsics[0,0]/Float(frame.camera.imageResolution.width)) / p[0,0])/2
            let texY1 = (1-(2*frame.camera.intrinsics[1,1]/Float(frame.camera.imageResolution.height)) / p[1,1])/2
            
            let texX2 = (1-(2*frame.camera.intrinsics[0,0]/Float(frame.camera.imageResolution.width)) / p[1,1])/2
            let texY2 = (1-(2*frame.camera.intrinsics[1,1]/Float(frame.camera.imageResolution.height)) / p[0,0])/2
            
            //11 10 01 00 // portrait
            //01 11 00 10 // right
            //10 00 11 01 // left
            //00 01 10 11 // down
            var texCoord: [Float]
            switch orientation {
            case .portrait:
                texCoord = [1-texX2, 1-texY2, 1-texX2,texY2, texX2, 1-texY2, texX2, texY2]
            case .landscapeRight:
                texCoord = [texX1, 1-texY1, 1-texX1, 1-texY1, texX1, texY1, 1-texX1, texY1]
            case .landscapeLeft:
                texCoord = [1-texX1, texY1, texX1, texY1, 1-texX1, 1-texY1, texX1, 1-texY1]
            default: // down
                texCoord = [texX2, texY2, texX2, 1-texY2, 1-texX2, texY2, 1-texX2, 1-texY2]
            }
            
            points.withUnsafeBufferPointer { bufferPoints in
                let readOnly = CVPixelBufferLockFlags.readOnly
                guard CVPixelBufferLockBaseAddress(
                        frame.capturedImage, readOnly) == kCVReturnSuccess else {
                    return
                }
                defer {
                    CVPixelBufferUnlockBaseAddress(frame.capturedImage, readOnly)
                }
                guard CVPixelBufferGetPlaneCount(frame.capturedImage) >= 2,
                      let capturedYPlane = CVPixelBufferGetBaseAddressOfPlane(
                        frame.capturedImage, 0),
                      let capturedUVPlane = CVPixelBufferGetBaseAddressOfPlane(
                        frame.capturedImage, 1) else {
                    return
                }
                var depthDataPtr: UnsafeMutableRawPointer?
                var depthSize: Int32 = 0
                var depthWidth: Int32 = 0
                var depthHeight: Int32 = 0
                var depthFormat: Int32 = 0
                var lockedDepthMap: CVPixelBuffer?
                if let depthMap,
                   CVPixelBufferLockBaseAddress(depthMap, readOnly)
                        == kCVReturnSuccess {
                    if let baseAddress = CVPixelBufferGetBaseAddress(depthMap) {
                        lockedDepthMap = depthMap
                        depthDataPtr = baseAddress
                        depthSize = Int32(CVPixelBufferGetDataSize(depthMap))
                        depthWidth = Int32(CVPixelBufferGetWidth(depthMap))
                        depthHeight = Int32(CVPixelBufferGetHeight(depthMap))
                        depthFormat = Int32(
                            CVPixelBufferGetPixelFormatType(depthMap))
                    }
                    else {
                        CVPixelBufferUnlockBaseAddress(depthMap, readOnly)
                    }
                }
                defer {
                    if let lockedDepthMap {
                        CVPixelBufferUnlockBaseAddress(lockedDepthMap, readOnly)
                    }
                }
                
                var confDataPtr: UnsafeMutableRawPointer?
                var confSize: Int32 = 0
                var confWidth: Int32 = 0
                var confHeight: Int32 = 0
                var confFormat: Int32 = 0
                var lockedConfidenceMap: CVPixelBuffer?
                if let confMap,
                   CVPixelBufferLockBaseAddress(confMap, readOnly)
                        == kCVReturnSuccess {
                    if let baseAddress = CVPixelBufferGetBaseAddress(confMap) {
                        lockedConfidenceMap = confMap
                        confDataPtr = baseAddress
                        confSize = Int32(CVPixelBufferGetDataSize(confMap))
                        confWidth = Int32(CVPixelBufferGetWidth(confMap))
                        confHeight = Int32(CVPixelBufferGetHeight(confMap))
                        confFormat = Int32(
                            CVPixelBufferGetPixelFormatType(confMap))
                    }
                    else {
                        CVPixelBufferUnlockBaseAddress(confMap, readOnly)
                    }
                }
                defer {
                    if let lockedConfidenceMap {
                        CVPixelBufferUnlockBaseAddress(
                            lockedConfidenceMap, readOnly)
                    }
                }

                guard depthDataPtr != nil || !points.isEmpty else { return }
                
                if let lightEstimate = frame.lightEstimate {
                    addEnvSensor(
                        type: 4,
                        value: Float(lightEstimate.ambientIntensity))
                }
                
                var lost = false
                switch frame.camera.trackingState {
                case .normal:
                    lost = false
                case .limited(.excessiveMotion):
                    lost = false
                case .limited(.insufficientFeatures):
                    lost = false
                default:
                    lost = true
                }
                // Notify lost with pose=null

                postOdometryEventNative(native_rtabmap,
                                        !lost ? pose[3,0]:0, !lost ? pose[3,1]:0, !lost ? pose[3,2]:0, !lost ? quat.x:0, !lost ? quat.y:0, !lost ? quat.z:0, !lost ? quat.w:0,
                                        frame.camera.intrinsics[0,0], // fx
                                        frame.camera.intrinsics[1,1], // fy
                                        frame.camera.intrinsics[2,0], // cx
                                        frame.camera.intrinsics[2,1], // cy
                                        frame.timestamp,
                                        capturedYPlane,                                             // y plane pointer
                                        nil,                                                         // u plane pointer
                                        capturedUVPlane,                                            // v plane pointer
                                        Int32(CVPixelBufferGetBytesPerRowOfPlane(frame.capturedImage, 0)) * Int32(CVPixelBufferGetHeightOfPlane(frame.capturedImage, 0)),  // yPlaneLen
                                        Int32(CVPixelBufferGetWidth(frame.capturedImage)),           // rgb width
                                        Int32(CVPixelBufferGetHeight(frame.capturedImage)),          // rgb height
                                        Int32(CVPixelBufferGetPixelFormatType(frame.capturedImage)), // rgb format
                                        depthDataPtr, // depth pointer
                                        depthSize,    // depth size
                                        depthWidth,   // depth width
                                        depthHeight,  // depth height
                                        depthFormat,  // depth format
                                        confDataPtr, // conf pointer
                                        confSize,    // conf size
                                        confWidth,   // conf width
                                        confHeight,  // conf height
                                        confFormat,  // conf format
                                        bufferPoints.baseAddress, Int32(points.count), 4,
                                        v[3,0], v[3,1], v[3,2], quatv.x, quatv.y, quatv.z, quatv.w,
                                        p[0,0], p[1,1], p[2,0], p[2,1], p[2,2], p[2,3], p[3,2],
                                        texCoord[0],texCoord[1],texCoord[2],texCoord[3],texCoord[4],texCoord[5],texCoord[6],texCoord[7])
                submitted = true
            }
        }
        return submitted
    }
        
    // Parameters
    func setOnlineBlending(enabled: Bool) {
        setOnlineBlendingNative(native_rtabmap, enabled)
    }
    func setMapCloudShown(shown: Bool) {
        setMapCloudShownNative(native_rtabmap, shown)
    }
    func setOdomCloudShown(shown: Bool) {
        setOdomCloudShownNative(native_rtabmap, shown)
    }
    func setMeshRendering(enabled: Bool, withTexture: Bool) {
        setMeshRenderingNative(native_rtabmap, enabled, withTexture)
    }
    func setPointSize(value: Float) {
        setPointSizeNative(native_rtabmap, value)
    }
    func setFOV(angle: Float) {
        setFOVNative(native_rtabmap, angle)
    }
    func setOrthoCropFactor(value: Float) {
        setOrthoCropFactorNative(native_rtabmap, value)
    }
    func setGridRotation(value: Float) {
        setGridRotationNative(native_rtabmap, value)
    }
    func setLighting(enabled: Bool) {
        setLightingNative(native_rtabmap, enabled)
    }
    func setBackfaceCulling(enabled: Bool) {
        setBackfaceCullingNative(native_rtabmap, enabled)
    }
    func setWireframe(enabled: Bool) {
        setWireframeNative(native_rtabmap, enabled)
    }
    func setTextureColorSeamsHidden(hidden: Bool) {
        setTextureColorSeamsHiddenNative(native_rtabmap, hidden)
    }
    func setLocalizationMode(enabled: Bool) {
        setLocalizationModeNative(native_rtabmap, enabled)
    }
    func setDataRecorderMode(enabled: Bool) {
        setDataRecorderModeNative(native_rtabmap, enabled)
    }
    func setGraphOptimization(enabled: Bool) {
        setGraphOptimizationNative(native_rtabmap, enabled)
    }
    func setNodesFiltering(enabled: Bool) {
        setNodesFilteringNative(native_rtabmap, enabled)
    }
    func setGraphVisible(visible: Bool) {
        setGraphVisibleNative(native_rtabmap, visible)
    }
    func setGridVisible(visible: Bool) {
        setGridVisibleNative(native_rtabmap, visible)
    }
    func setFullResolution(enabled: Bool) {
        setFullResolutionNative(native_rtabmap, enabled)
    }
    func setSmoothing(enabled: Bool) {
        setSmoothingNative(native_rtabmap, enabled)
    }
    func setDepthBleedingError(value: Float) {
        setDepthBleedingErrorNative(native_rtabmap, value)
    }
    func setAppendMode(enabled: Bool) {
        setAppendModeNative(native_rtabmap, enabled)
    }
    func setUpstreamRelocalizationAccThr(value: Float) {
        setUpstreamRelocalizationAccThrNative(native_rtabmap, value)
    }
    func setMaxCloudDepth(value: Float) {
        setMaxCloudDepthNative(native_rtabmap, value)
    }
    func setMinCloudDepth(value: Float) {
        setMinCloudDepthNative(native_rtabmap, value)
    }
    func setCloudDensityLevel(value: Int) {
        setCloudDensityLevelNative(native_rtabmap, Int32(value))
    }
    func setMeshAngleTolerance(value: Float) {
        setMeshAngleToleranceNative(native_rtabmap, value)
    }
    func setMeshDecimationFactor(value: Float) {
        setMeshDecimationFactorNative(native_rtabmap, value)
    }
    func setMeshTriangleSize(value: Int) {
        setMeshTriangleSizeNative(native_rtabmap, Int32(value))
    }
    func setClusterRatio(value: Float) {
        setClusterRatioNative(native_rtabmap, value)
    }
    func setMaxGainRadius(value: Float) {
        setMaxGainRadiusNative(native_rtabmap, value)
    }
    func setRenderingTextureDecimation(value: Int) {
        setRenderingTextureDecimationNative(native_rtabmap, Int32(value))
    }
    func setBackgroundColor(gray: Float) {
        setBackgroundColorNative(native_rtabmap, gray)
    }
    func setDepthConfidence(value: Int) {
        setDepthConfidenceNative(native_rtabmap, Int32(value))
    }
    func setExportPointCloudFormat(format: String) {
        format.utf8CString.withUnsafeBufferPointer { bufferFormat in
            return setExportPointCloudFormatNative(native_rtabmap, bufferFormat.baseAddress)
        }
    }
    func setMappingParameter(key: String, value: String) {
        key.utf8CString.withUnsafeBufferPointer { bufferKey in
            value.utf8CString.withUnsafeBufferPointer { bufferValue in
                setMappingParameterNative(native_rtabmap, bufferKey.baseAddress, bufferValue.baseAddress)
            }
        }
    }
    func setGPS(location: CLLocation)
    {
        setGPSNative(native_rtabmap, location.timestamp.timeIntervalSince1970, location.coordinate.longitude, location.coordinate.latitude, location.altitude, location.horizontalAccuracy, location.course < 0.0 ? 0.0 : location.course)
    }
    func addEnvSensor(type: Int, value: Float)
    {
        addEnvSensorNative(native_rtabmap, Int32(type), value)
    }
    func setOrthoCropFactor(_ value: Float)
    {
        setOrthoCropFactorNative(native_rtabmap, value)
    }
    func setGridRotation(_ value: Float)
    {
        setGridRotationNative(native_rtabmap, value)
    }
}

func getPreviewImage(databasePath: String) -> UIImage?
{
    let imageOut = databasePath.utf8CString.withUnsafeBufferPointer { buffer -> UIImage? in
        var image = ImageNative()
        image = getPreviewImageNative(buffer.baseAddress)
        if let dataPtr = UnsafeRawPointer(image.data)
        {
            // copy data in swift
            let data = Data(bytes: dataPtr, count: Int(image.width*image.height*image.channels))
            // release memory
            releasePreviewImageNative(image)
            // Create bitmap image
            let bitmap = CIImage(bitmapData: data, bytesPerRow: Int(image.width*image.channels), size: CGSize(width: Int(image.width), height: Int(image.height)), format: CIFormat.BGRA8, colorSpace: nil)
            return UIImage(ciImage: bitmap)
        }
        return UIImage(named: "RTAB-Map1024")
    }
    return imageOut
}

protocol RTABMapObserver: class {
    func progressUpdated(_ rtabmap: RTABMap, count: Int, max: Int)
    func initEventReceived(_ rtabmap: RTABMap, status: Int, msg: String)
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
    func cameraInfoEventReceived(_ rtabmap: RTABMap, type: Int, key: String, value: String)
}

extension String {

  func toPointer() -> UnsafePointer<UInt8>? {
    guard let data = self.data(using: String.Encoding.utf8) else { return nil }

    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: data.count)
    let stream = OutputStream(toBuffer: buffer, capacity: data.count)

    stream.open()
    data.withUnsafeBytes({ (p: UnsafePointer<UInt8>) -> Void in
      stream.write(p, maxLength: data.count)
    })

    stream.close()

    return UnsafePointer<UInt8>(buffer)
  }
}
