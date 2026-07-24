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

final class PriorMapDepthSampler {
    private let maximumOutputPoints = 1_200
    private let maximumHistoryVoxels = 8_000
    private var frameIndex = 0
    private var voxelHistory: [PriorMapWorldVoxel: (hits: Int, lastFrame: Int)] = [:]

    func reset() {
        frameIndex = 0
        voxelHistory.removeAll(keepingCapacity: true)
    }

    func sample(frame: ARFrame) -> PriorMapStructureObservation? {
        let usesSmoothedDepth = frame.smoothedSceneDepth != nil
        guard let sceneDepth = frame.smoothedSceneDepth ?? frame.sceneDepth else {
            return nil
        }
        let depthMap = sceneDepth.depthMap
        let confidenceMap = sceneDepth.confidenceMap
        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        guard width > 1, height > 1 else { return nil }
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
            return nil
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
        guard fx > 0, fy > 0 else { return nil }

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
        var floorCandidates: [Double] = []
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
                if relativeHeight < -0.75 {
                    floorCandidates.append(Double(world.y))
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
                let hits = prior?.lastFrame == frameIndex
                    ? prior!.hits
                    : min(4, (prior?.hits ?? 0) + 1)
                voxelHistory[voxel] = (hits, frameIndex)
                // Two-frame evidence suppresses most walking people and depth
                // speckles without requiring semantic classification.
                guard hits >= 2 else { continue }
                guard emittedVoxels.insert(voxel).inserted else { continue }
                let horizontalWorld = SIMD2<Double>(
                    Double(world.x - cameraPosition.x),
                    Double(-(world.z - cameraPosition.z)))
                let local = SIMD2<Double>(
                    inverseCosine * horizontalWorld.x - inverseSine * horizontalWorld.y,
                    inverseSine * horizontalWorld.x + inverseCosine * horizontalWorld.y)
                let angle = atan2(local.x, max(0.001, local.y))
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
        guard !candidates.isEmpty else { return nil }
        let outputStride = max(1, candidates.count / maximumOutputPoints)
        let output = candidates.enumerated().compactMap {
            $0.offset % outputStride == 0 ? $0.element : nil
        }
        let angles = output.map(\.angle)
        let floorHeight: Double?
        if floorCandidates.count >= 8 {
            floorCandidates.sort()
            floorHeight = floorCandidates[floorCandidates.count / 2]
        }
        else {
            floorHeight = nil
        }
        return PriorMapStructureObservation(
            points: output.map(\.point),
            validPointCount: output.count,
            coverageAngleRad: max(0, (angles.max() ?? 0) - (angles.min() ?? 0)),
            floorHeightWorldM: floorHeight,
            source: usesSmoothedDepth
                ? "smoothed_scene_depth"
                : "scene_depth")
    }
}
