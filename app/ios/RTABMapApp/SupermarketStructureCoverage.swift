//
//  SupermarketStructureCoverage.swift
//  RTABMapApp
//
//  Lightweight scan-time structural coverage advisor. This intentionally
//  accumulates incomplete RGB-D returns across time instead of requiring a
//  shelf, product face or end-cap to form a complete plane in one frame.
//

import ARKit
import CoreVideo
import Foundation
import simd

struct ScanStructureCoverageCell: Codable {
    let x: Int
    let z: Int
    let floorObservationCount: Int
    let elevatedObservationCount: Int
    let highObservationCount: Int
    let distinctTimeBucketCount: Int
    let viewDirectionMask: Int
    let highConfidenceObservationCount: Int
    let firstElevatedObservedAt: TimeInterval?
    let lastElevatedObservedAt: TimeInterval?
    let lastObservedAt: TimeInterval
}

struct ScanStructureCoverageSummary: Codable {
    let evaluatedDepthFrameCount: Int
    let depthUnavailableFrameCount: Int
    let validDepthSampleCount: Int
    let observedCellCount: Int
    let floorCellCount: Int
    let elevatedCellCount: Int
    let stableStructureCellCount: Int
    let multiViewStructureCellCount: Int
    let groundConflictCellCount: Int
    let singleViewStructureCellCount: Int
    let coverageScore: Double
    let currentDetectionRateHz: Double
}

struct ScanStructureCoverageSnapshot: Codable {
    let format: String
    let version: Int
    let updatedAt: String
    let cellSizeM: Double
    let floorHeightM: Double?
    let summary: ScanStructureCoverageSummary
    let cells: [ScanStructureCoverageCell]
}

struct ScanStructureCoverageFeedback {
    let processed: Bool
    let recommendedDetectionRateHz: Double
    let guidance: String?
    let newElevatedCellCount: Int
    let newlyStableCellCount: Int
    let newlyMultiViewCellCount: Int
    let currentFrameFloorCellCount: Int
    let currentFrameElevatedCellCount: Int
    let validDepthSampleCount: Int
}

private struct StructureCoverageGridCell: Hashable {
    let x: Int
    let z: Int
}

private struct StructureCoverageFrameObservation {
    var sawFloor = false
    var sawElevated = false
    var sawHigh = false
    var sawHighConfidence = false
    var viewDirectionMask = 0
}

private struct StructureCoverageCellState {
    var floorObservationCount = 0
    var elevatedObservationCount = 0
    var highObservationCount = 0
    var distinctTimeBucketCount = 0
    var lastTimeBucket = Int.min
    var viewDirectionMask = 0
    var highConfidenceObservationCount = 0
    var firstElevatedObservedAt: TimeInterval?
    var lastElevatedObservedAt: TimeInterval?
    var lastObservedAt: TimeInterval = 0
}

/// Builds a bounded, low-resolution evidence map for scan guidance. It does
/// not attempt phone-side semantic shelf recognition. Its job is to answer:
/// did this frame add persistent elevated structure, a second observation
/// time, a new viewing direction, or useful floor context?
final class SupermarketStructureCoverageAdvisor {
    private let cellSizeM: Double
    private let evaluationIntervalSeconds: TimeInterval
    private let timeBucketSeconds: TimeInterval
    private let maximumDepthM: Float
    private let pixelStride: Int
    private let maximumStoredCells: Int
    private var cells: [StructureCoverageGridCell: StructureCoverageCellState] = [:]
    private var lastEvaluationTimestamp: TimeInterval?
    private var floorHeightM: Double?
    private var evaluatedDepthFrameCount = 0
    private var depthUnavailableFrameCount = 0
    private var validDepthSampleCount = 0
    private var currentDetectionRateHz = 1.0

    init(
        cellSizeM: Double = 0.20,
        evaluationIntervalSeconds: TimeInterval = 0.60,
        timeBucketSeconds: TimeInterval = 3.0,
        maximumDepthM: Float = 5.0,
        pixelStride: Int = 10,
        maximumStoredCells: Int = 120_000
    ) {
        self.cellSizeM = cellSizeM
        self.evaluationIntervalSeconds = evaluationIntervalSeconds
        self.timeBucketSeconds = timeBucketSeconds
        self.maximumDepthM = maximumDepthM
        self.pixelStride = max(4, pixelStride)
        self.maximumStoredCells = max(10_000, maximumStoredCells)
    }

    func reset() {
        cells.removeAll(keepingCapacity: true)
        lastEvaluationTimestamp = nil
        floorHeightM = nil
        evaluatedDepthFrameCount = 0
        depthUnavailableFrameCount = 0
        validDepthSampleCount = 0
        currentDetectionRateHz = 1.0
    }

    func setCurrentDetectionRateHz(_ value: Double) {
        currentDetectionRateHz = value
    }

    func evaluate(
        frame: ARFrame,
        correctedPose: simd_float4x4,
        thermalState: String
    ) -> ScanStructureCoverageFeedback {
        if let previous = lastEvaluationTimestamp,
           frame.timestamp - previous < evaluationIntervalSeconds {
            return emptyFeedback(rate: currentDetectionRateHz)
        }
        lastEvaluationTimestamp = frame.timestamp

        guard let sceneDepth = frame.sceneDepth else {
            depthUnavailableFrameCount += 1
            return ScanStructureCoverageFeedback(
                processed: true,
                recommendedDetectionRateHz: thermalLimitedRate(thermalState, preferred: 1.0),
                guidance: NSLocalizedString("Depth is temporarily unavailable. Point the camera at the aisle floor and shelf base.", comment: "Scan coverage guidance"),
                newElevatedCellCount: 0,
                newlyStableCellCount: 0,
                newlyMultiViewCellCount: 0,
                currentFrameFloorCellCount: 0,
                currentFrameElevatedCellCount: 0,
                validDepthSampleCount: 0)
        }

        let depthMap = sceneDepth.depthMap
        let confidenceMap = sceneDepth.confidenceMap
        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        guard width > 0, height > 0,
              CVPixelBufferGetPixelFormatType(depthMap) == kCVPixelFormatType_DepthFloat32 else {
            depthUnavailableFrameCount += 1
            return emptyFeedback(rate: thermalLimitedRate(thermalState, preferred: 1.0), processed: true)
        }

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

        guard let depthBaseAddress = CVPixelBufferGetBaseAddress(depthMap) else {
            depthUnavailableFrameCount += 1
            return emptyFeedback(rate: thermalLimitedRate(thermalState, preferred: 1.0), processed: true)
        }

        let imageResolution = frame.camera.imageResolution
        let scaleX = Float(width) / max(1.0, Float(imageResolution.width))
        let scaleY = Float(height) / max(1.0, Float(imageResolution.height))
        let intrinsics = frame.camera.intrinsics
        let fx = intrinsics[0, 0] * scaleX
        let fy = intrinsics[1, 1] * scaleY
        let cx = intrinsics[2, 0] * scaleX
        let cy = intrinsics[2, 1] * scaleY
        guard fx > 0, fy > 0 else {
            depthUnavailableFrameCount += 1
            return emptyFeedback(rate: thermalLimitedRate(thermalState, preferred: 1.0), processed: true)
        }

        let depthBytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)
        let confidenceBaseAddress = confidenceMap.flatMap { CVPixelBufferGetBaseAddress($0) }
        let confidenceBytesPerRow = confidenceMap.map { CVPixelBufferGetBytesPerRow($0) } ?? 0
        let confidenceWidth = confidenceMap.map { CVPixelBufferGetWidth($0) } ?? 0
        let confidenceHeight = confidenceMap.map { CVPixelBufferGetHeight($0) } ?? 0
        let cameraX = Double(correctedPose.columns.3.x)
        let cameraY = Double(correctedPose.columns.3.y)
        let cameraZ = Double(correctedPose.columns.3.z)
        var projectedSamples: [(StructureCoverageGridCell, Double, Int, Bool)] = []
        var possibleFloorHeights: [Double] = []
        projectedSamples.reserveCapacity((width / pixelStride + 1) * (height / pixelStride + 1))

        for v in stride(from: pixelStride / 2, to: height, by: pixelStride) {
            let depthRow = depthBaseAddress
                .advanced(by: v * depthBytesPerRow)
                .assumingMemoryBound(to: Float32.self)
            for u in stride(from: pixelStride / 2, to: width, by: pixelStride) {
                let depth = Float(depthRow[u])
                guard depth.isFinite, depth >= 0.20, depth <= maximumDepthM else {
                    continue
                }

                var confidence = 2
                if let confidenceBaseAddress = confidenceBaseAddress,
                   confidenceWidth > 0, confidenceHeight > 0 {
                    let confidenceU = min(confidenceWidth - 1, u * confidenceWidth / width)
                    let confidenceV = min(confidenceHeight - 1, v * confidenceHeight / height)
                    let confidenceRow = confidenceBaseAddress
                        .advanced(by: confidenceV * confidenceBytesPerRow)
                        .assumingMemoryBound(to: UInt8.self)
                    confidence = Int(confidenceRow[confidenceU])
                    // Low-confidence LiDAR returns are too unstable to drive
                    // scan guidance, especially on reflective packaging.
                    if confidence == 0 {
                        continue
                    }
                }

                let localX = (Float(u) - cx) * depth / fx
                let localY = -(Float(v) - cy) * depth / fy
                let localPoint = SIMD4<Float>(localX, localY, -depth, 1)
                let worldPoint = simd_mul(correctedPose, localPoint)
                guard worldPoint.x.isFinite, worldPoint.y.isFinite, worldPoint.z.isFinite else {
                    continue
                }
                let worldX = Double(worldPoint.x)
                let worldY = Double(worldPoint.y)
                let worldZ = Double(worldPoint.z)
                let cell = StructureCoverageGridCell(
                    x: Int(floor(worldX / cellSizeM)),
                    z: Int(floor(worldZ / cellSizeM)))
                let direction = viewDirectionBit(
                    cameraX: cameraX,
                    cameraZ: cameraZ,
                    cell: cell)
                projectedSamples.append((cell, worldY, direction, confidence >= 2))
                if worldY < cameraY - 0.45 && worldY > cameraY - 2.0 {
                    possibleFloorHeights.append(worldY)
                }
            }
        }

        evaluatedDepthFrameCount += 1
        validDepthSampleCount += projectedSamples.count
        updateFloorEstimate(possibleFloorHeights, cameraY: cameraY)
        guard let floorHeightM = floorHeightM else {
            return ScanStructureCoverageFeedback(
                processed: true,
                recommendedDetectionRateHz: thermalLimitedRate(thermalState, preferred: 1.5),
                guidance: NSLocalizedString("Floor reference is incomplete. Tilt the camera slightly downward while keeping the shelf base visible.", comment: "Scan coverage guidance"),
                newElevatedCellCount: 0,
                newlyStableCellCount: 0,
                newlyMultiViewCellCount: 0,
                currentFrameFloorCellCount: 0,
                currentFrameElevatedCellCount: 0,
                validDepthSampleCount: projectedSamples.count)
        }

        var frameObservations: [StructureCoverageGridCell: StructureCoverageFrameObservation] = [:]
        for (cell, worldY, direction, highConfidence) in projectedSamples {
            let heightAboveFloor = worldY - floorHeightM
            var observation = frameObservations[cell] ?? StructureCoverageFrameObservation()
            if heightAboveFloor >= -0.12 && heightAboveFloor <= 0.18 {
                observation.sawFloor = true
            }
            if heightAboveFloor >= 0.32 && heightAboveFloor <= 2.20 {
                observation.sawElevated = true
                observation.sawHigh = observation.sawHigh || heightAboveFloor >= 0.90
                observation.sawHighConfidence = observation.sawHighConfidence || highConfidence
                observation.viewDirectionMask |= direction
            }
            frameObservations[cell] = observation
        }

        let timeBucket = Int(floor(frame.timestamp / timeBucketSeconds))
        var newElevatedCellCount = 0
        var newlyStableCellCount = 0
        var newlyMultiViewCellCount = 0
        var frameFloorCellCount = 0
        var frameElevatedCellCount = 0

        for (cell, observation) in frameObservations {
            if cells[cell] == nil && cells.count >= maximumStoredCells {
                continue
            }
            var state = cells[cell] ?? StructureCoverageCellState()
            let wasStable = isStableStructure(state)
            let wasMultiView = isMultiViewStructure(state)
            let wasElevated = state.elevatedObservationCount > 0
            if observation.sawFloor {
                state.floorObservationCount += 1
                frameFloorCellCount += 1
            }
            if observation.sawElevated {
                if state.firstElevatedObservedAt == nil {
                    state.firstElevatedObservedAt = frame.timestamp
                }
                state.lastElevatedObservedAt = frame.timestamp
                state.elevatedObservationCount += 1
                state.highObservationCount += observation.sawHigh ? 1 : 0
                state.highConfidenceObservationCount += observation.sawHighConfidence ? 1 : 0
                state.viewDirectionMask |= observation.viewDirectionMask
                frameElevatedCellCount += 1
                if state.lastTimeBucket != timeBucket {
                    state.lastTimeBucket = timeBucket
                    state.distinctTimeBucketCount += 1
                }
            }
            state.lastObservedAt = frame.timestamp
            cells[cell] = state
            if observation.sawElevated && !wasElevated {
                newElevatedCellCount += 1
            }
            if !wasStable && isStableStructure(state) {
                newlyStableCellCount += 1
            }
            if !wasMultiView && isMultiViewStructure(state) {
                newlyMultiViewCellCount += 1
            }
        }

        let noveltyPoints = newElevatedCellCount + newlyStableCellCount * 2 + newlyMultiViewCellCount * 2
        let noveltyRatio = Double(noveltyPoints) / Double(max(1, frameElevatedCellCount))
        let preferredRate: Double
        if noveltyRatio >= 0.35 || newlyStableCellCount >= 8 {
            preferredRate = 2.0
        }
        else if noveltyRatio >= 0.15 || newElevatedCellCount >= 8 {
            preferredRate = 1.5
        }
        else {
            preferredRate = 1.0
        }
        let recommendedRate = thermalLimitedRate(thermalState, preferred: preferredRate)
        let guidance = coverageGuidance(
            validSamples: projectedSamples.count,
            frameFloorCells: frameFloorCellCount,
            frameElevatedCells: frameElevatedCellCount,
            newElevatedCells: newElevatedCellCount,
            newlyStableCells: newlyStableCellCount,
            newlyMultiViewCells: newlyMultiViewCellCount)
        return ScanStructureCoverageFeedback(
            processed: true,
            recommendedDetectionRateHz: recommendedRate,
            guidance: guidance,
            newElevatedCellCount: newElevatedCellCount,
            newlyStableCellCount: newlyStableCellCount,
            newlyMultiViewCellCount: newlyMultiViewCellCount,
            currentFrameFloorCellCount: frameFloorCellCount,
            currentFrameElevatedCellCount: frameElevatedCellCount,
            validDepthSampleCount: projectedSamples.count)
    }

    func snapshot() -> ScanStructureCoverageSnapshot {
        let sortedCells = cells.map { key, state in
            ScanStructureCoverageCell(
                x: key.x,
                z: key.z,
                floorObservationCount: state.floorObservationCount,
                elevatedObservationCount: state.elevatedObservationCount,
                highObservationCount: state.highObservationCount,
                distinctTimeBucketCount: state.distinctTimeBucketCount,
                viewDirectionMask: state.viewDirectionMask,
                highConfidenceObservationCount: state.highConfidenceObservationCount,
                firstElevatedObservedAt: state.firstElevatedObservedAt,
                lastElevatedObservedAt: state.lastElevatedObservedAt,
                lastObservedAt: state.lastObservedAt)
        }.sorted {
            if $0.x == $1.x {
                return $0.z < $1.z
            }
            return $0.x < $1.x
        }
        return ScanStructureCoverageSnapshot(
            format: "SupermarketStructureCoverage",
            version: 1,
            updatedAt: Date().getFormattedDate(format: "yyyy-MM-dd HH:mm:ss"),
            cellSizeM: cellSizeM,
            floorHeightM: floorHeightM,
            summary: summary(),
            cells: sortedCells)
    }

    func summary() -> ScanStructureCoverageSummary {
        var floorCellCount = 0
        var elevatedCellCount = 0
        var stableStructureCellCount = 0
        var multiViewStructureCellCount = 0
        var groundConflictCellCount = 0
        var singleViewStructureCellCount = 0
        for state in cells.values {
            floorCellCount += state.floorObservationCount >= 2 ? 1 : 0
            elevatedCellCount += state.elevatedObservationCount > 0 ? 1 : 0
            if isStableStructure(state) {
                stableStructureCellCount += 1
                if isMultiViewStructure(state) {
                    multiViewStructureCellCount += 1
                }
                else {
                    singleViewStructureCellCount += 1
                }
                let conflictRatio = Double(state.floorObservationCount) /
                    Double(max(1, state.floorObservationCount + state.elevatedObservationCount))
                if state.floorObservationCount >= 2 && conflictRatio > 0.66 {
                    groundConflictCellCount += 1
                }
            }
        }
        let stableDenominator = max(1, stableStructureCellCount)
        let multiViewRatio = Double(multiViewStructureCellCount) / Double(stableDenominator)
        let conflictRatio = Double(groundConflictCellCount) / Double(stableDenominator)
        let coverageScore = max(0.0, min(1.0, multiViewRatio * (1.0 - conflictRatio)))
        return ScanStructureCoverageSummary(
            evaluatedDepthFrameCount: evaluatedDepthFrameCount,
            depthUnavailableFrameCount: depthUnavailableFrameCount,
            validDepthSampleCount: validDepthSampleCount,
            observedCellCount: cells.count,
            floorCellCount: floorCellCount,
            elevatedCellCount: elevatedCellCount,
            stableStructureCellCount: stableStructureCellCount,
            multiViewStructureCellCount: multiViewStructureCellCount,
            groundConflictCellCount: groundConflictCellCount,
            singleViewStructureCellCount: singleViewStructureCellCount,
            coverageScore: coverageScore,
            currentDetectionRateHz: currentDetectionRateHz)
    }

    private func updateFloorEstimate(_ candidates: [Double], cameraY: Double) {
        guard candidates.count >= 20 else {
            return
        }
        let sorted = candidates.sorted()
        let index = min(sorted.count - 1, max(0, Int(Double(sorted.count - 1) * 0.18)))
        let candidate = sorted[index]
        guard candidate >= cameraY - 2.0, candidate <= cameraY - 0.55 else {
            return
        }
        if let previous = floorHeightM {
            floorHeightM = previous * 0.92 + candidate * 0.08
        }
        else {
            floorHeightM = candidate
        }
    }

    private func viewDirectionBit(
        cameraX: Double,
        cameraZ: Double,
        cell: StructureCoverageGridCell
    ) -> Int {
        let centerX = (Double(cell.x) + 0.5) * cellSizeM
        let centerZ = (Double(cell.z) + 0.5) * cellSizeM
        var angle = atan2(cameraZ - centerZ, cameraX - centerX)
        if angle < 0 {
            angle += 2 * .pi
        }
        let bin = min(7, max(0, Int(floor(angle / (2 * .pi) * 8))))
        return 1 << bin
    }

    private func isStableStructure(_ state: StructureCoverageCellState) -> Bool {
        let observationSpan = (state.lastElevatedObservedAt ?? 0) -
            (state.firstElevatedObservedAt ?? 0)
        // Medium-confidence returns from small or irregular product faces are
        // useful when they persist. Requiring a high-confidence return here
        // would systematically discard exactly those hard-to-scan surfaces.
        // The elapsed-time check prevents two adjacent samples on a time-bucket
        // boundary from being mistaken for persistent structure.
        return state.elevatedObservationCount >= 2 &&
            state.distinctTimeBucketCount >= 2 &&
            observationSpan >= 0.75
    }

    private func isMultiViewStructure(_ state: StructureCoverageCellState) -> Bool {
        return isStableStructure(state) && state.viewDirectionMask.nonzeroBitCount >= 2
    }

    private func thermalLimitedRate(_ thermalState: String, preferred: Double) -> Double {
        switch thermalState {
        case "critical", "serious":
            return min(preferred, 1.0)
        case "fair":
            return min(preferred, 1.5)
        default:
            return preferred
        }
    }

    private func coverageGuidance(
        validSamples: Int,
        frameFloorCells: Int,
        frameElevatedCells: Int,
        newElevatedCells: Int,
        newlyStableCells: Int,
        newlyMultiViewCells: Int
    ) -> String? {
        if validSamples < 80 {
            return NSLocalizedString("Reliable depth is sparse. Move closer and avoid reflective packaging filling the view.", comment: "Scan coverage guidance")
        }
        if frameElevatedCells >= 12 && frameFloorCells * 4 < frameElevatedCells {
            return NSLocalizedString("Shelf structure is visible, but floor context is weak. Tilt slightly downward without losing the shelf base.", comment: "Scan coverage guidance")
        }
        if newlyStableCells >= 6 || newElevatedCells >= 16 {
            return NSLocalizedString("New shelf structure detected. Move slowly for a second observation.", comment: "Scan coverage guidance")
        }
        if frameElevatedCells >= 10 && newlyMultiViewCells == 0 {
            return NSLocalizedString("This shelf is mostly single-view. Shift the viewing angle gradually while keeping the aisle floor visible.", comment: "Scan coverage guidance")
        }
        return nil
    }

    private func emptyFeedback(
        rate: Double,
        processed: Bool = false
    ) -> ScanStructureCoverageFeedback {
        return ScanStructureCoverageFeedback(
            processed: processed,
            recommendedDetectionRateHz: rate,
            guidance: nil,
            newElevatedCellCount: 0,
            newlyStableCellCount: 0,
            newlyMultiViewCellCount: 0,
            currentFrameFloorCellCount: 0,
            currentFrameElevatedCellCount: 0,
            validDepthSampleCount: 0)
    }
}
