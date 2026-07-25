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
    let observationId: String
    let payload: String
    let symbology: String
    let normalizedBounds: CGRect
    let frame: ARFrame
    let alignmentSnapshot: PriorMapAlignmentSnapshot
    let imageOrientation: PriorMapCapturedImageOrientation
}

final class PriceTagVisionScanner {
    private let queue = DispatchQueue(
        label: "com.introlab.rtabmap.price-tag-vision",
        qos: .userInitiated)
    private let lock = NSLock()
    private var pending = false
    private var inFlight = false
    private var generation = UUID()
    private var recentlySeen: [String: TimeInterval] = [:]

    func requestScan() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !pending, !inFlight else { return false }
        pending = true
        return true
    }

    func reset() {
        lock.lock()
        pending = false
        inFlight = false
        generation = UUID()
        recentlySeen.removeAll()
        lock.unlock()
    }

    func submitIfRequested(
        frame: ARFrame,
        orientation: CGImagePropertyOrientation,
        alignmentSnapshot: PriorMapAlignmentSnapshot,
        completion: @escaping (Result<PriceTagVisionDetection, Error>) -> Void
    ) {
        lock.lock()
        guard pending, !inFlight else {
            lock.unlock()
            return
        }
        pending = false
        inFlight = true
        let token = generation
        lock.unlock()

        queue.async {
            let result: Result<PriceTagVisionDetection, Error>
            do {
                let request = VNDetectBarcodesRequest()
                request.symbologies = [
                    .QR,
                    .EAN8,
                    .EAN13,
                    .Code128,
                    .UPCE,
                    .PDF417,
                ]
                let handler = VNImageRequestHandler(
                    cvPixelBuffer: frame.capturedImage,
                    orientation: orientation,
                    options: [:])
                try handler.perform([request])
                let candidates = (request.results ?? [])
                    .compactMap { observation -> VNBarcodeObservation? in
                        guard let payload = observation.payloadStringValue,
                              !payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                            return nil
                        }
                        return observation
                    }
                    .sorted {
                        ($0.boundingBox.width * $0.boundingBox.height)
                            > ($1.boundingBox.width * $1.boundingBox.height)
                    }
                guard let best = candidates.first,
                      let payload = best.payloadStringValue else {
                    throw NSError(
                        domain: "PriceTagVision",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "当前画面未识别到支持的条码，请靠近并保持稳定后重试。"])
                }
                result = .success(
                    PriceTagVisionDetection(
                        observationId: UUID().uuidString,
                        payload: payload,
                        symbology: best.symbology.rawValue,
                        normalizedBounds: PriorMapImageGeometry.nativeSensorBounds(
                            visionBounds: best.boundingBox,
                            orientation: Self.captureOrientation(orientation)),
                        frame: frame,
                        alignmentSnapshot: alignmentSnapshot,
                        imageOrientation: Self.captureOrientation(orientation)))
            }
            catch {
                result = .failure(error)
            }

            self.lock.lock()
            guard token == self.generation else {
                self.lock.unlock()
                return
            }
            self.inFlight = false
            if case .success(let detection) = result {
                let now = detection.frame.timestamp
                let previous = self.recentlySeen[detection.payload]
                self.recentlySeen = self.recentlySeen.filter {
                    now - $0.value <= 5
                }
                if let previous = previous, now - previous < 2 {
                    self.lock.unlock()
                    completion(.failure(NSError(
                        domain: "PriceTagVision",
                        code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "同一条码刚刚已经识别，请稍后再试。"])))
                    return
                }
                self.recentlySeen[detection.payload] = now
            }
            self.lock.unlock()
            completion(result)
        }
    }

    private static func captureOrientation(
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
        let transform = frame.camera.transform
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
                bounds: detection.normalizedBounds)
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
            cameraMapPosition: camera2D,
            method: fallback == nil ? "unavailable" : "shelf_plane_ray",
            confidence: fallback == nil ? 0 : 0.42,
            poseTimestampDeltaMs: poseTimestampDeltaMs,
            depthEvidence: rejectedDepthEvidence)
    }

    private static func robustWorldPoint(
        frame: ARFrame,
        depth: ARDepthData,
        bounds: CGRect
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
        let world = frame.camera.transform * cameraPoint
        return (SIMD3<Float>(world.x, world.y, world.z), planeEvidence)
    }
}
