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
                    orientation: .right,
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
                        // Vision receives the native landscape sensor buffer
                        // with EXIF .right. Convert its oriented, bottom-left
                        // box back to native sensor-normalized coordinates so
                        // the same-frame depth lookup addresses matching pixels.
                        normalizedBounds: Self.nativeSensorBounds(
                            visionBounds: best.boundingBox),
                        frame: frame))
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

    private static func nativeSensorBounds(visionBounds: CGRect) -> CGRect {
        let corners = [
            CGPoint(x: visionBounds.minX, y: visionBounds.minY),
            CGPoint(x: visionBounds.maxX, y: visionBounds.minY),
            CGPoint(x: visionBounds.minX, y: visionBounds.maxY),
            CGPoint(x: visionBounds.maxX, y: visionBounds.maxY),
        ].map { point in
            CGPoint(x: 1 - point.y, y: point.x)
        }
        let minimumX = corners.map(\.x).min() ?? 0
        let maximumX = corners.map(\.x).max() ?? 0
        let minimumY = corners.map(\.y).min() ?? 0
        let maximumY = corners.map(\.y).max() ?? 0
        return CGRect(
            x: minimumX,
            y: minimumY,
            width: maximumX - minimumX,
            height: maximumY - minimumY)
    }
}

struct PriceTagFrameMeasurement {
    let rawMapPosition: PriorMapTagPoint3D?
    let cameraMapPosition: SIMD2<Double>
    let method: String
    let confidence: Double
    let poseTimestampDeltaMs: Double

    static func measure(
        detection: PriceTagVisionDetection,
        floorId: String,
        shelves: [PriorMapShelf],
        floorHeightWorldM: Double?,
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
        if let depth = depthSource,
           let worldPoint = robustWorldPoint(
                frame: frame,
                depth: depth,
                bounds: detection.normalizedBounds) {
            let mapped = mapPoint(worldPoint)
            let height = floorHeightWorldM.map { Double(worldPoint.y) - $0 }
            return PriceTagFrameMeasurement(
                rawMapPosition: PriorMapTagPoint3D(
                    xM: mapped.xM,
                    yM: mapped.yM,
                    heightM: height),
                cameraMapPosition: camera2D,
                method: frame.smoothedSceneDepth != nil
                    ? "smoothed_scene_depth"
                    : "scene_depth",
                confidence: height == nil ? 0.72 : 0.90,
                poseTimestampDeltaMs: 0)
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
            floorId: floorId)
        return PriceTagFrameMeasurement(
            rawMapPosition: fallback,
            cameraMapPosition: camera2D,
            method: fallback == nil ? "unavailable" : "shelf_plane_ray",
            confidence: fallback == nil ? 0 : 0.42,
            poseTimestampDeltaMs: 0)
    }

    private static func robustWorldPoint(
        frame: ARFrame,
        depth: ARDepthData,
        bounds: CGRect
    ) -> SIMD3<Float>? {
        let buffer = depth.depthMap
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        guard width > 1, height > 1 else { return nil }
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
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let confidenceBase = confidence.flatMap(CVPixelBufferGetBaseAddress)
        let confidenceBytesPerRow = confidence.map(CVPixelBufferGetBytesPerRow) ?? 0
        let sampleOffsets: [(CGFloat, CGFloat)] = [
            (0.5, 0.5), (0.3, 0.3), (0.7, 0.3),
            (0.3, 0.7), (0.7, 0.7), (0.5, 0.3), (0.5, 0.7),
        ]
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
        guard samples.count >= 3 else { return nil }
        let ordered = samples.map(\.depth).sorted()
        let median = ordered[ordered.count / 2]
        let deviations = ordered.map { abs($0 - median) }.sorted()
        let mad = max(0.015, deviations[deviations.count / 2])
        let retained = samples.filter { abs($0.depth - median) <= 3 * mad }
        guard let chosen = retained.min(by: { abs($0.depth - median) < abs($1.depth - median) }) else {
            return nil
        }
        let imageResolution = frame.camera.imageResolution
        let scaleX = Float(width) / Float(max(1, imageResolution.width))
        let scaleY = Float(height) / Float(max(1, imageResolution.height))
        let intrinsics = frame.camera.intrinsics
        let fx = intrinsics[0, 0] * scaleX
        let fy = intrinsics[1, 1] * scaleY
        let cx = intrinsics[2, 0] * scaleX
        let cy = intrinsics[2, 1] * scaleY
        guard fx > 0, fy > 0 else { return nil }
        let cameraPoint = SIMD4<Float>(
            (Float(chosen.x) - cx) / fx * chosen.depth,
            -(Float(chosen.y) - cy) / fy * chosen.depth,
            -chosen.depth,
            1)
        let world = frame.camera.transform * cameraPoint
        return SIMD3<Float>(world.x, world.y, world.z)
    }
}
