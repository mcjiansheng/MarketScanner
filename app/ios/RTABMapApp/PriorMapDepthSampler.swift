//
//  PriorMapDepthSampler.swift
//  RTABMapApp
//
//  Bounded scene-depth sampling. Heavy work runs on the prior-map queue, never
//  synchronously in ARSessionDelegate.
//

import ARKit
import Foundation
import simd

private struct PriorMapWorldVoxel: Hashable {
    let x: Int
    let y: Int
    let z: Int
}

enum PriorMapDepthSampleResult {
    case noDepth
    case observationUnavailable
    case observation(PriorMapStructureObservation)

    var structureObservation: PriorMapStructureObservation? {
        guard case .observation(let value) = self else { return nil }
        return value
    }

    var recoveryFrameDisposition: PriorMapRecoveryFrameDisposition {
        switch self {
        case .noDepth:
            return .noDepth
        case .observationUnavailable, .observation:
            return .observationUnavailable
        }
    }
}

final class PriorMapDepthSampler {
    private let maximumOutputPoints = 1_200
    private let maximumHistoryVoxels = 8_000
    private var frameIndex = 0
    private var voxelHistory: [
        PriorMapWorldVoxel: (hits: Int, firstFrame: Int, lastFrame: Int)
    ] = [:]
    private let floorEstimator = PriorMapFloorPlaneEstimator()

    func reset() {
        frameIndex = 0
        voxelHistory.removeAll(keepingCapacity: true)
        floorEstimator.reset()
    }

    func sample(frame: ARFrame) -> PriorMapStructureObservation? {
        sampleResult(frame: frame).structureObservation
    }

    func sampleResult(frame: ARFrame) -> PriorMapDepthSampleResult {
        let usesSmoothedDepth = frame.smoothedSceneDepth != nil
        guard let sceneDepth = frame.smoothedSceneDepth ?? frame.sceneDepth else {
            return .noDepth
        }
        let depthMap = sceneDepth.depthMap
        let confidenceMap = sceneDepth.confidenceMap
        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        guard width > 1, height > 1 else { return .observationUnavailable }
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        if let confidenceMap = confidenceMap {
            CVPixelBufferLockBaseAddress(confidenceMap, .readOnly)
        }
        defer {
            if let confidenceMap = confidenceMap {
                CVPixelBufferUnlockBaseAddress(confidenceMap, .readOnly)
            }
            CVPixelBufferUnlockBaseAddress(depthMap, .readOnly)
        }
        guard let depthBase = CVPixelBufferGetBaseAddress(depthMap) else {
            return .observationUnavailable
        }
        let depthStride = CVPixelBufferGetBytesPerRow(depthMap) / MemoryLayout<Float32>.stride
        let confidenceStride = confidenceMap.map {
            CVPixelBufferGetBytesPerRow($0) / MemoryLayout<UInt8>.stride
        } ?? 0
        let confidenceBase = confidenceMap.flatMap(CVPixelBufferGetBaseAddress)
        let imageResolution = frame.camera.imageResolution
        let scaleX = Float(width) / Float(max(1, imageResolution.width))
        let scaleY = Float(height) / Float(max(1, imageResolution.height))
        let intrinsics = frame.camera.intrinsics
        let fx = intrinsics[0, 0] * scaleX
        let fy = intrinsics[1, 1] * scaleY
        let cx = intrinsics[2, 0] * scaleX
        let cy = intrinsics[2, 1] * scaleY
        guard fx > 0, fy > 0 else { return .observationUnavailable }

        frameIndex += 1
        let step = max(1, Int(sqrt(Double(width * height) / 3_600.0)))
        let cameraTransform = frame.camera.transform
        let cameraPosition = SIMD3<Float>(
            cameraTransform.columns.3.x,
            cameraTransform.columns.3.y,
            cameraTransform.columns.3.z)
        let forward = SIMD3<Float>(
            -cameraTransform.columns.2.x,
            -cameraTransform.columns.2.y,
            -cameraTransform.columns.2.z)
        let horizontalPose = PriorMapStageOneMath.arkitHorizontalPose(
            positionX: Double(cameraPosition.x),
            positionZ: Double(cameraPosition.z),
            forwardX: Double(forward.x),
            forwardZ: Double(forward.z))
        let inverseCosine = cos(-horizontalPose.yawRad)
        let inverseSine = sin(-horizontalPose.yawRad)
        var candidates: [(point: SIMD2<Double>, angle: Double)] = []
        var floorCandidates: [PriorMapFloorSample] = []
        var emittedVoxels = Set<PriorMapWorldVoxel>()

        for pixelY in stride(from: 0, to: height, by: step) {
            let depthRow = depthBase
                .advanced(by: pixelY * CVPixelBufferGetBytesPerRow(depthMap))
                .assumingMemoryBound(to: Float32.self)
            let confidenceRow = confidenceBase?
                .advanced(by: pixelY * (confidenceStride * MemoryLayout<UInt8>.stride))
                .assumingMemoryBound(to: UInt8.self)
            for pixelX in stride(from: 0, to: width, by: step) {
                let depth = depthRow[min(pixelX, depthStride - 1)]
                guard depth.isFinite, depth >= 0.25, depth <= 8.0 else {
                    continue
                }
                if let confidenceRow = confidenceRow, confidenceRow[pixelX] == 0 {
                    continue
                }
                let cameraPoint = SIMD4<Float>(
                    (Float(pixelX) - cx) / fx * depth,
                    -(Float(pixelY) - cy) / fy * depth,
                    -depth,
                    1)
                let world = cameraTransform * cameraPoint
                let relativeHeight = Double(world.y - cameraPosition.y)
                if relativeHeight <= -0.90, relativeHeight >= -2.30 {
                    let neighborX = min(width - 1, pixelX + step)
                    let neighborY = min(height - 1, pixelY + step)
                    let rightDepth = depthRow[min(neighborX, depthStride - 1)]
                    let downRow = depthBase
                        .advanced(by: neighborY * CVPixelBufferGetBytesPerRow(depthMap))
                        .assumingMemoryBound(to: Float32.self)
                    let downDepth = downRow[min(pixelX, depthStride - 1)]
                    if rightDepth.isFinite, downDepth.isFinite,
                       rightDepth >= 0.25, rightDepth <= 8,
                       downDepth >= 0.25, downDepth <= 8 {
                        let rightCamera = SIMD4<Float>(
                            (Float(neighborX) - cx) / fx * rightDepth,
                            -(Float(pixelY) - cy) / fy * rightDepth,
                            -rightDepth,
                            1)
                        let downCamera = SIMD4<Float>(
                            (Float(pixelX) - cx) / fx * downDepth,
                            -(Float(neighborY) - cy) / fy * downDepth,
                            -downDepth,
                            1)
                        let rightWorld4 = cameraTransform * rightCamera
                        let downWorld4 = cameraTransform * downCamera
                        let world3 = SIMD3<Float>(world.x, world.y, world.z)
                        let rightWorld = SIMD3<Float>(
                            rightWorld4.x, rightWorld4.y, rightWorld4.z)
                        let downWorld = SIMD3<Float>(
                            downWorld4.x, downWorld4.y, downWorld4.z)
                        let crossValue = simd_cross(
                            rightWorld - world3,
                            downWorld - world3)
                        let length = simd_length(crossValue)
                        if length > 1.0e-6 {
                            let alignment = abs(Double(crossValue.y / length))
                            floorCandidates.append(
                                PriorMapFloorSample(
                                    heightWorldM: Double(world.y),
                                    relativeHeightM: relativeHeight,
                                    upAlignment: alignment))
                        }
                    }
                    continue
                }
                // Remove likely floor/ceiling while retaining shelf faces,
                // pillars and fixed counters across normal handheld heights.
                guard relativeHeight >= -0.70, relativeHeight <= 1.25 else {
                    continue
                }
                let voxel = PriorMapWorldVoxel(
                    x: Int(floor(Double(world.x) / 0.15)),
                    y: Int(floor(Double(world.y) / 0.20)),
                    z: Int(floor(Double(world.z) / 0.15)))
                let prior = voxelHistory[voxel]
                // Multiple depth pixels may land in one voxel in the same
                // frame. Count frame-to-frame persistence, not pixel density.
                let continuesRecentTrack = prior.map {
                    frameIndex - $0.lastFrame <= 2
                } ?? false
                let hits = prior?.lastFrame == frameIndex
                    ? prior!.hits
                    : continuesRecentTrack
                        ? min(6, (prior?.hits ?? 0) + 1)
                        : 1
                let firstFrame = continuesRecentTrack
                    ? (prior?.firstFrame ?? frameIndex)
                    : frameIndex
                voxelHistory[voxel] = (hits, firstFrame, frameIndex)
                // Require three recent frames and a non-zero time span. A cart
                // moving through a voxel must restart its evidence instead of
                // accumulating stale hits whenever it revisits that cell.
                guard hits >= 4, frameIndex - firstFrame >= 3 else { continue }
                guard emittedVoxels.insert(voxel).inserted else { continue }
                let horizontalWorld = SIMD2<Double>(
                    Double(world.x - cameraPosition.x),
                    Double(-(world.z - cameraPosition.z)))
                let local = SIMD2<Double>(
                    inverseCosine * horizontalWorld.x - inverseSine * horizontalWorld.y,
                    inverseSine * horizontalWorld.x + inverseCosine * horizontalWorld.y)
                // Local +x is camera-forward under the canonical map yaw
                // contract (0 = map +x). Measure field-of-view coverage from
                // that axis; the previous +y reference belonged to the old
                // 90-degree-shifted heading convention.
                let angle = atan2(local.y, max(0.001, local.x))
                candidates.append((local, angle))
            }
        }
        if voxelHistory.count > maximumHistoryVoxels {
            let cutoff = frameIndex - 20
            voxelHistory = voxelHistory.filter { $0.value.lastFrame >= cutoff }
            if voxelHistory.count > maximumHistoryVoxels {
                let newest = voxelHistory.sorted {
                    $0.value.lastFrame > $1.value.lastFrame
                }.prefix(maximumHistoryVoxels)
                voxelHistory = Dictionary(
                    uniqueKeysWithValues: newest.map { ($0.key, $0.value) })
            }
        }
        guard !candidates.isEmpty else { return .observationUnavailable }
        let outputStride = max(1, candidates.count / maximumOutputPoints)
        let output = candidates.enumerated().compactMap {
            $0.offset % outputStride == 0 ? $0.element : nil
        }
        let angles = output.map(\.angle)
        let floorEstimate = floorEstimator.update(samples: floorCandidates)
        return .observation(PriorMapStructureObservation(
            points: output.map(\.point),
            validPointCount: output.count,
            coverageAngleRad: max(0, (angles.max() ?? 0) - (angles.min() ?? 0)),
            floorEstimate: floorEstimate,
            source: usesSmoothedDepth
                ? "smoothed_scene_depth"
                : "scene_depth"))
    }
}
