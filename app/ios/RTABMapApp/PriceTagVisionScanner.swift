//
//  PriceTagVisionScanner.swift
//  RTABMapApp
//
//  User-triggered barcode detection on ARFrame.capturedImage and robust
//  depth/ray measurement. No second camera session is created.
//

import ARKit
import Foundation
import ImageIO
import Vision
import simd

struct PriceTagVisionDetection {
    let captureGeneration: UUID
    let observationId: String
    let payload: String
    let symbology: String
    let normalizedBounds: CGRect
    let frame: ARFrame
    /// Software-stabilized camera pose accepted for this exact capture frame.
    /// Depth, ray fallback and prior-map localization must not re-read the raw
    /// ARKit transform after the continuity gate has selected this authority.
    let cameraTransform: simd_float4x4
    let alignmentSnapshot: PriorMapAlignmentSnapshot
    let imageOrientation: PriorMapCapturedImageOrientation
}

struct PriceTagVisionScanResult {
    let generation: UUID
    let frame: ARFrame
    let cameraTransform: simd_float4x4
    let orientation: CGImagePropertyOrientation
    let alignmentSnapshot: PriorMapAlignmentSnapshot
    let candidates: [PriceTagBarcodeCandidate]

    func detection(for selected: PriceTagSelectedBarcode) -> PriceTagVisionDetection {
        return PriceTagVisionDetection(
            captureGeneration: generation,
            observationId: UUID().uuidString,
            payload: selected.candidate.payload,
            symbology: selected.candidate.symbology,
            normalizedBounds: PriorMapImageGeometry.nativeSensorBounds(
                visionBounds: selected.candidate.visionBounds,
                orientation: PriceTagVisionScanner.captureOrientation(orientation)),
            frame: frame,
            cameraTransform: cameraTransform,
            alignmentSnapshot: alignmentSnapshot,
            imageOrientation: PriceTagVisionScanner.captureOrientation(orientation))
    }
}

enum PriceTagVisionScannerError: Error, LocalizedError {
    case invalidRegionOfInterest
    case requestFailed(String)
    case workerCapacityExhausted

    var errorDescription: String? {
        switch self {
        case .invalidRegionOfInterest:
            return "price_tag_roi_invalid"
        case .requestFailed:
            return "price_tag_vision_request_failed"
        case .workerCapacityExhausted:
            return "price_tag_vision_worker_capacity_exhausted"
        }
    }
}

final class PriceTagVisionScanner {
    private let lock = NSLock()
    private let workerExecutor = PriceTagVisionWorkerExecutor(
        maximumWorkers: 2)
    private var requestTokens = PriceTagVisionRequestTokenGate()
    private var activeRequests: [UUID: [VNDetectBarcodesRequest]] = [:]

    private static let baseSymbologies: [VNBarcodeSymbology] = [
        .QR,
        .EAN8,
        .EAN13,
        .Code128,
        .Code39,
        .Code93,
        .I2of5,
        .ITF14,
        .UPCE,
        .PDF417,
        .DataMatrix,
        .Aztec,
    ]

    func activate(generation: UUID) {
        lock.lock()
        abandonActiveRequestLocked()
        requestTokens.activate(generation: generation)
        lock.unlock()
    }

    func cancel(generation: UUID? = nil) {
        lock.lock()
        if generation == nil || generation == requestTokens.activeGeneration {
            abandonActiveRequestLocked()
        }
        requestTokens.cancel(generation: generation)
        lock.unlock()
    }

    /// Revokes a request that exceeded the coordinator deadline without
    /// ending the capture generation. A fresh request may then be submitted
    /// while the old Vision callback is rejected by its stale request ID.
    @discardableResult
    func restart(generation: UUID) -> Bool {
        lock.lock()
        guard requestTokens.activeGeneration == generation else {
            lock.unlock()
            return false
        }
        abandonActiveRequestLocked()
        let restarted = requestTokens.restart(generation: generation)
        lock.unlock()
        return restarted
    }

    @discardableResult
    func detect(
        frame: ARFrame,
        orientation: CGImagePropertyOrientation,
        regionOfInterest: CGRect,
        generation: UUID,
        cameraTransform: simd_float4x4,
        alignmentSnapshot: PriorMapAlignmentSnapshot,
        completion: @escaping (Result<PriceTagVisionScanResult, Error>) -> Void
    ) -> Bool {
        guard regionOfInterest.minX >= 0,
              regionOfInterest.minY >= 0,
              regionOfInterest.maxX <= 1,
              regionOfInterest.maxY <= 1,
              !regionOfInterest.isEmpty else {
            completion(.failure(PriceTagVisionScannerError.invalidRegionOfInterest))
            return false
        }
        let request = Self.makeRequest(regionOfInterest: regionOfInterest)
        // Very close labels often extend slightly outside the visible guide.
        // Keep the fast exact ROI first, then perform one bounded expanded-ROI
        // retry only when the primary request found nothing.
        let expandedRegion = Self.expandedRegionOfInterest(regionOfInterest)
        let expandedRequest = Self.makeRequest(
            regionOfInterest: expandedRegion)
        lock.lock()
        guard let requestID = requestTokens.beginRequest(
                generation: generation) else {
            lock.unlock()
            return false
        }
        activeRequests[requestID] = [request, expandedRequest]
        let started = workerExecutor.submit(requestID: requestID) {
            let result: Result<PriceTagVisionScanResult, Error>
            do {
                let handler = VNImageRequestHandler(
                    cvPixelBuffer: frame.capturedImage,
                    orientation: orientation,
                    options: [:])
                try handler.perform([request])
                var candidates = Self.candidates(from: request)
                if candidates.isEmpty, expandedRegion != regionOfInterest {
                    let fallbackHandler = VNImageRequestHandler(
                        cvPixelBuffer: frame.capturedImage,
                        orientation: orientation,
                        options: [:])
                    try fallbackHandler.perform([expandedRequest])
                    candidates = Self.candidates(from: expandedRequest)
                }
                result = .success(
                    PriceTagVisionScanResult(
                        generation: generation,
                        frame: frame,
                        cameraTransform: cameraTransform,
                        orientation: orientation,
                        alignmentSnapshot: alignmentSnapshot,
                        candidates: candidates))
            }
            catch {
                result = .failure(
                    PriceTagVisionScannerError.requestFailed(
                        error.localizedDescription))
            }

            self.lock.lock()
            self.activeRequests.removeValue(forKey: requestID)
            let accepted = self.requestTokens.completeRequest(
                generation: generation,
                requestID: requestID)
            self.lock.unlock()
            if accepted {
                completion(result)
            }
        }
        guard started else {
            activeRequests.removeValue(forKey: requestID)
            _ = requestTokens.completeRequest(
                generation: generation,
                requestID: requestID)
            lock.unlock()
            completion(.failure(
                PriceTagVisionScannerError.workerCapacityExhausted))
            return true
        }
        lock.unlock()
        return true
    }

    /// Must be called with `lock` held. Cancelling the Vision request is best
    /// effort; the worker lane remains quarantined until synchronous
    /// `perform()` actually returns, so a truly wedged request cannot receive
    /// another queued job or mutate the replacement request's token.
    private func abandonActiveRequestLocked() {
        guard let generation = requestTokens.activeGeneration,
              let requestID = requestTokens.activeRequestID else {
            return
        }
        activeRequests[requestID]?.forEach { $0.cancel() }
        _ = workerExecutor.quarantine(requestID: requestID)
        _ = requestTokens.completeRequest(
            generation: generation,
            requestID: requestID)
    }

    private static func makeRequest(
        regionOfInterest: CGRect
    ) -> VNDetectBarcodesRequest {
        let request = VNDetectBarcodesRequest()
        if #available(iOS 17.0, *) {
            request.revision = VNDetectBarcodesRequestRevision4
            request.coalesceCompositeSymbologies = true
        }
        else if #available(iOS 16.0, *) {
            request.revision = VNDetectBarcodesRequestRevision3
        }
        else if #available(iOS 15.0, *) {
            request.revision = VNDetectBarcodesRequestRevision2
        }
        else {
            request.revision = VNDetectBarcodesRequestRevision1
        }
        var symbologies = baseSymbologies
        if #available(iOS 15.0, *) {
            symbologies.append(.codabar)
        }
        request.symbologies = symbologies
        request.regionOfInterest = regionOfInterest
        return request
    }

    private static func expandedRegionOfInterest(_ region: CGRect) -> CGRect {
        let horizontal = max(0.035, region.width * 0.16)
        let vertical = max(0.035, region.height * 0.28)
        return region.insetBy(dx: -horizontal, dy: -vertical)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    private static func candidates(
        from request: VNDetectBarcodesRequest
    ) -> [PriceTagBarcodeCandidate] {
        return (request.results ?? [])
            .compactMap { observation -> PriceTagBarcodeCandidate? in
                guard let payload = observation.payloadStringValue,
                      !payload.trimmingCharacters(
                        in: .whitespacesAndNewlines).isEmpty,
                      let fullImageBounds =
                        PriceTagVisionBoundingBoxNormalizer.fullImageBounds(
                            observationBounds: observation.boundingBox,
                            requestRegionOfInterest: request.regionOfInterest,
                            requestRevision: Int(request.revision)) else {
                    return nil
                }
                return PriceTagBarcodeCandidate(
                    payload: payload,
                    symbology: observation.symbology.rawValue,
                    visionBounds: fullImageBounds)
            }
    }

    static func captureOrientation(
        _ orientation: CGImagePropertyOrientation
    ) -> PriorMapCapturedImageOrientation {
        switch orientation {
        case .up:
            return .up
        case .down:
            return .down
        case .left:
            return .left
        default:
            return .right
        }
    }
}

struct PriceTagFrameMeasurement {
    let rawMapPosition: PriorMapTagPoint3D?
    /// ARKit/OpenGL world point used to derive the durable exact-node-local
    /// coordinate. Shelf-ray fallback deliberately has no 3D world point.
    let worldPoint: SIMD3<Float>?
    let cameraMapPosition: SIMD2<Double>
    let method: String
    let confidence: Double
    let poseTimestampDeltaMs: Double
    let depthEvidence: PriceTagDepthEvidence

    static func measure(
        detection: PriceTagVisionDetection,
        floorId: String,
        shelves: [PriorMapShelf],
        fixedStructures: [PriorMapFixedStructure],
        floorEstimate: PriorMapFloorEstimate?,
        poseTimestampDeltaMs: Double,
        mapPoint: (SIMD3<Float>) -> PriorMapTagPoint3D
    ) -> PriceTagFrameMeasurement {
        let frame = detection.frame
        let transform = detection.cameraTransform
        let cameraWorld = SIMD3<Float>(
            transform.columns.3.x,
            transform.columns.3.y,
            transform.columns.3.z)
        let cameraMap = mapPoint(cameraWorld)
        let camera2D = SIMD2<Double>(cameraMap.xM, cameraMap.yM)
        let depthSource = frame.smoothedSceneDepth ?? frame.sceneDepth
        var rejectedDepthEvidence = PriceTagDepthEvidence.unavailable
        if let depth = depthSource {
            let estimate = robustWorldPoint(
                frame: frame,
                depth: depth,
                bounds: detection.normalizedBounds,
                cameraTransform: transform)
            rejectedDepthEvidence = estimate.evidence
            if let worldPoint = estimate.worldPoint,
               estimate.evidence.accepted {
            let mapped = mapPoint(worldPoint)
            let height = floorEstimate.map {
                Double(worldPoint.y) - $0.heightWorldM
            }
            let floorConfidence = floorEstimate?.confidence ?? 0
            return PriceTagFrameMeasurement(
                rawMapPosition: PriorMapTagPoint3D(
                    xM: mapped.xM,
                    yM: mapped.yM,
                    heightM: height),
                worldPoint: worldPoint,
                cameraMapPosition: camera2D,
                method: frame.smoothedSceneDepth != nil
                    ? "smoothed_scene_depth"
                    : "scene_depth",
                confidence: min(
                    0.92,
                    estimate.evidence.confidence
                        + (height == nil ? 0 : 0.08 * floorConfidence)),
                poseTimestampDeltaMs: poseTimestampDeltaMs,
                depthEvidence: estimate.evidence)
            }
        }

        let bounds = detection.normalizedBounds
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let imageSize = frame.camera.imageResolution
        let pixel = SIMD2<Float>(
            Float(center.x) * Float(imageSize.width),
            Float(1 - center.y) * Float(imageSize.height))
        let intrinsics = frame.camera.intrinsics
        let rayCamera = SIMD4<Float>(
            (pixel.x - intrinsics[2, 0]) / intrinsics[0, 0],
            -(pixel.y - intrinsics[2, 1]) / intrinsics[1, 1],
            -1,
            0)
        let rayWorld4 = transform * rayCamera
        let secondMap = mapPoint(
            cameraWorld + SIMD3<Float>(rayWorld4.x, rayWorld4.y, rayWorld4.z))
        let fallback = ShelfAssociation.rayIntersection(
            origin: camera2D,
            direction: SIMD2<Double>(
                secondMap.xM - cameraMap.xM,
                secondMap.yM - cameraMap.yM),
            shelves: shelves,
            fixedStructures: fixedStructures,
            floorId: floorId)
        return PriceTagFrameMeasurement(
            rawMapPosition: fallback,
            worldPoint: nil,
            cameraMapPosition: camera2D,
            method: fallback == nil ? "unavailable" : "shelf_plane_ray",
            confidence: fallback == nil ? 0 : 0.42,
            poseTimestampDeltaMs: poseTimestampDeltaMs,
            depthEvidence: rejectedDepthEvidence)
    }

    private static func robustWorldPoint(
        frame: ARFrame,
        depth: ARDepthData,
        bounds: CGRect,
        cameraTransform: simd_float4x4
    ) -> (worldPoint: SIMD3<Float>?, evidence: PriceTagDepthEvidence) {
        let buffer = depth.depthMap
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        guard width > 1, height > 1 else { return (nil, .unavailable) }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        let confidence = depth.confidenceMap
        if let confidence = confidence {
            CVPixelBufferLockBaseAddress(confidence, .readOnly)
        }
        defer {
            if let confidence = confidence {
                CVPixelBufferUnlockBaseAddress(confidence, .readOnly)
            }
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
        }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            return (nil, .unavailable)
        }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let confidenceBase = confidence.flatMap(CVPixelBufferGetBaseAddress)
        let confidenceBytesPerRow = confidence.map(CVPixelBufferGetBytesPerRow) ?? 0
        // Vision boxes often include shelf/background pixels. Sample a dense,
        // inset 9x9 grid so evidence comes from the barcode interior.
        var sampleOffsets: [(CGFloat, CGFloat)] = []
        sampleOffsets.reserveCapacity(81)
        for row in 0..<9 {
            let sampleY = CGFloat(0.18) + CGFloat(0.64) * CGFloat(row) / CGFloat(8)
            for column in 0..<9 {
                let sampleX = CGFloat(0.18) + CGFloat(0.64) * CGFloat(column) / CGFloat(8)
                sampleOffsets.append((sampleX, sampleY))
            }
        }
        var samples: [(depth: Float, x: Int, y: Int)] = []
        for offset in sampleOffsets {
            let normalizedX = bounds.minX + bounds.width * offset.0
            let normalizedY = bounds.minY + bounds.height * offset.1
            let x = min(width - 1, max(0, Int(normalizedX * CGFloat(width))))
            let y = min(height - 1, max(0, Int((1 - normalizedY) * CGFloat(height))))
            let row = base.advanced(by: y * bytesPerRow)
                .assumingMemoryBound(to: Float32.self)
            if let confidenceBase = confidenceBase {
                let confidenceRow = confidenceBase
                    .advanced(by: y * confidenceBytesPerRow)
                    .assumingMemoryBound(to: UInt8.self)
                if confidenceRow[x] == 0 {
                    continue
                }
            }
            let value = row[x]
            if value.isFinite, value >= 0.2, value <= 8 {
                samples.append((value, x, y))
            }
        }
        let evaluation = PriceTagDepthEvidence.evaluate(samples.map(\.depth))
        guard evaluation.accepted, let median = evaluation.medianM else {
            return (nil, evaluation)
        }
        let threshold = max(0.025, Float((evaluation.madM ?? 0.02) * 3))
        let retained = samples.filter { abs($0.depth - Float(median)) <= threshold }
        guard let chosen = retained.min(
            by: { abs($0.depth - Float(median)) < abs($1.depth - Float(median)) }) else {
            return (nil, evaluation)
        }
        let imageResolution = frame.camera.imageResolution
        let scaleX = Float(width) / Float(max(1, imageResolution.width))
        let scaleY = Float(height) / Float(max(1, imageResolution.height))
        let intrinsics = frame.camera.intrinsics
        let fx = intrinsics[0, 0] * scaleX
        let fy = intrinsics[1, 1] * scaleY
        let cx = intrinsics[2, 0] * scaleX
        let cy = intrinsics[2, 1] * scaleY
        guard fx > 0, fy > 0 else { return (nil, evaluation.rejected("invalid_intrinsics")) }
        let cameraPoints = retained.map { sample in
            SIMD3<Double>(
                Double((Float(sample.x) - cx) / fx * sample.depth),
                Double(-(Float(sample.y) - cy) / fy * sample.depth),
                Double(-sample.depth))
        }
        let centroid = cameraPoints.reduce(SIMD3<Double>(repeating: 0), +)
            / Double(max(1, cameraPoints.count))
        let left = cameraPoints.min { $0.x < $1.x }
        let right = cameraPoints.max { $0.x < $1.x }
        let top = cameraPoints.min { $0.y < $1.y }
        let bottom = cameraPoints.max { $0.y < $1.y }
        var normal: SIMD3<Double>?
        if let left, let right, let top, let bottom {
            let cross = simd_cross(right - left, bottom - top)
            if simd_length(cross) > 1.0e-8 {
                normal = cross / simd_length(cross)
            }
        }
        let residual = normal.map { surfaceNormal in
            let values = cameraPoints.map {
                abs(simd_dot($0 - centroid, surfaceNormal))
            }.sorted()
            return values[values.count / 2]
        } ?? .infinity
        let planeEvidence = evaluation.withPlane(
            residualM: residual,
            normalCamera: normal)
        guard planeEvidence.accepted else {
            return (nil, planeEvidence)
        }
        let cameraPoint = SIMD4<Float>(
            (Float(chosen.x) - cx) / fx * chosen.depth,
            -(Float(chosen.y) - cy) / fy * chosen.depth,
            -chosen.depth,
            1)
        let world = cameraTransform * cameraPoint
        return (SIMD3<Float>(world.x, world.y, world.z), planeEvidence)
    }
}
