//
//  SupermarketScanSession.swift
//  RTABMapApp
//
//  Continuous supermarket capture support: bounded in-memory trajectory
//  summaries, an on-disk RTAB-Map database, health checkpoints and audit logs.
//

import Foundation

struct PriceTagRecord: Codable {
    let id: Int
    let tagIdentifier: String
    let payload: String
    let timestamp: TimeInterval
    let segmentIndex: Int
    let nodeCount: Int
    let x: Float
    let y: Float
    let z: Float
    let roll: Float
    let pitch: Float
    let yaw: Float
    let note: String
}

struct ScanSegmentMetadata: Codable {
    let segmentIndex: Int
    /// `continuous_streaming` means that all nodes belong to one uninterrupted
    /// RTAB-Map database. `segmented` is the legacy rollover workflow. PC
    /// tools use this marker to avoid applying segment-boundary alignment to a
    /// continuous graph.
    let scanMode: String?
    let finalized: Bool?
    /// Phone capture keeps a bounded online graph for feedback, while the PC
    /// re-extracts features and performs the authoritative global optimization.
    let processingProfile: String?
    let exportedAt: String
    let knownAreaM2: Double
    let nodeCount: Int
    let databaseMemoryMB: Int
    let usedMemoryMB: Int
    let priceTagCount: Int
    let trackingSessionId: String?
    let sensorStartPose: ScanSensorPose?
    let sensorEndPose: ScanSensorPose?
    let rtabmapStartPose: ScanPoseSample?
    let rtabmapEndPose: ScanPoseSample?
    let rtabmapOriginOffset: ScanTransform?
    let softwarePoseCorrection: ScanTransform?
    /// Latest RTAB-Map map→odom correction in the ARKit/OpenGL world frame.
    /// It is kept separate from `softwarePoseCorrection`, which only removes
    /// impossible discontinuities in the raw ARKit odometry stream.
    let rtabmapMapToOdomCorrection: ScanTransform?
    let onlineLoopClosureCount: Int?
    let reliableLoopClosureCount: Int?
    let databaseBytes: UInt64?
    let availableDiskBytes: Int64?
    let thermalState: String?
    let captureHealth: ScanCaptureHealth?
    /// Lightweight phone-side coverage guidance statistics. This is not a
    /// semantic shelf map; the authoritative geometry remains in the RGB-D
    /// database and is reconstructed on the PC.
    let structureCoverage: ScanStructureCoverageSummary?
}

struct ScanAreaCells: Codable {
    let segmentIndex: Int
    let cellSizeM: Double
    let scanRadiusM: Double
    let cells: [[Int]]
}

struct ScanPoseSample: Codable {
    let timestamp: TimeInterval
    let segmentIndex: Int
    let nodeCount: Int
    let x: Float
    let y: Float
    let z: Float
    let roll: Float
    let pitch: Float
    let yaw: Float
}

/// Raw ARKit device pose at a segment boundary. The matrix is stored in
/// column-major order, matching simd_float4x4, so adjacent segments can be
/// checked independently of RTAB-Map's origin correction.
struct ScanSensorPose: Codable {
    let timestamp: TimeInterval
    let matrixColumnMajor: [Float]
    let trackingState: String
}

struct ScanTransform: Codable {
    let x: Float
    let y: Float
    let z: Float
    let qx: Float
    let qy: Float
    let qz: Float
    let qw: Float
}

struct ScanSegmentSidecarSnapshot {
    let metadata: ScanSegmentMetadata
    let priceTags: [PriceTagRecord]
    let areaCells: ScanAreaCells
    let poseSamples: [ScanPoseSample]
    let structureCoverage: ScanStructureCoverageSnapshot?
}

struct ScanCaptureHealth: Codable {
    let sensorPoseCount: Int
    let normalTrackingPoseCount: Int
    let limitedTrackingPoseCount: Int
    let unavailableTrackingPoseCount: Int
    let longestSensorGapSeconds: Double
    let storedTrajectorySamples: Int
    let trajectorySampleStride: Int
    let evaluatedMappingFrameCount: Int
    let acceptedMappingFrameCount: Int
    let rejectedMappingFrameCount: Int
    let degradedTrackingRejectedFrameCount: Int
    let trackingRecoveryRejectedFrameCount: Int
    let poseDiscontinuityCompensationCount: Int
    let lowVisualFeatureFrameCount: Int
    let maximumObservedLinearSpeedMps: Double
    let maximumObservedAngularSpeedDegPerSecond: Double
}

struct ScanBoundarySnapshot {
    let sensorStartPose: ScanSensorPose?
    let sensorEndPose: ScanSensorPose?
    let rtabmapStartPose: ScanPoseSample?
    let rtabmapEndPose: ScanPoseSample?
    let captureHealth: ScanCaptureHealth
}

struct ScanLiveCheckpoint: Codable {
    let format: String
    let version: Int
    let updatedAt: String
    let scanMode: String
    let finalized: Bool
    let trackingSessionId: String
    let nodeCount: Int
    let knownAreaM2: Double
    let databaseBytes: UInt64
    let availableDiskBytes: Int64?
    let usedMemoryMB: Int
    let thermalState: String
    let sensorEndPose: ScanSensorPose?
    let captureHealth: ScanCaptureHealth
    let structureCoverage: ScanStructureCoverageSummary?
}

struct ScanEventRecord: Codable {
    let format: String
    let version: Int
    let timestamp: String
    let timestampUnix: TimeInterval
    let level: String
    let event: String
    let message: String
    let trackingSessionId: String
    let fields: [String: String]
}

private struct FloorGridCell: Hashable {
    let x: Int
    let z: Int
}

final class FloorAreaEstimator {
    private let cellSize: Double
    private let scanRadius: Double
    private var occupiedCells = Set<FloorGridCell>()
    private var lastX: Double?
    private var lastZ: Double?

    init(cellSize: Double = 0.25, scanRadius: Double = 1.25) {
        self.cellSize = cellSize
        self.scanRadius = scanRadius
    }

    func reset() {
        occupiedCells.removeAll()
        lastX = nil
        lastZ = nil
    }

    func update(x: Float, z: Float) -> Double {
        let px = Double(x)
        let pz = Double(z)

        if let lx = lastX, let lz = lastZ {
            let distance = hypot(px - lx, pz - lz)
            let steps = max(1, Int(distance / max(cellSize, 0.01)))
            for i in 0...steps {
                let t = Double(i) / Double(steps)
                markDisk(x: lx + (px - lx) * t, z: lz + (pz - lz) * t)
            }
        } else {
            markDisk(x: px, z: pz)
        }

        lastX = px
        lastZ = pz
        return areaM2
    }

    var areaM2: Double {
        return Double(occupiedCells.count) * cellSize * cellSize
    }

    var cellSizeM: Double {
        return cellSize
    }

    var scanRadiusM: Double {
        return scanRadius
    }

    func occupiedCellCoordinates() -> [[Int]] {
        return occupiedCells.map { cell in
            return [cell.x, cell.z]
        }.sorted {
            if $0[0] == $1[0] {
                return $0[1] < $1[1]
            }
            return $0[0] < $1[0]
        }
    }

    private func markDisk(x: Double, z: Double) {
        let radiusCells = Int(ceil(scanRadius / cellSize))
        let cx = Int(floor(x / cellSize))
        let cz = Int(floor(z / cellSize))

        for ix in (cx - radiusCells)...(cx + radiusCells) {
            for iz in (cz - radiusCells)...(cz + radiusCells) {
                let dx = (Double(ix) + 0.5) * cellSize - x
                let dz = (Double(iz) + 0.5) * cellSize - z
                if dx * dx + dz * dz <= scanRadius * scanRadius {
                    occupiedCells.insert(FloorGridCell(x: ix, z: iz))
                }
            }
        }
    }
}

final class SupermarketScanSession {
    private let fileManager = FileManager.default
    private let documentsDirectory: URL
    private let areaEstimator = FloorAreaEstimator()
    private let captureLock = NSRecursiveLock()
    private let sidecarWriteLock = NSLock()
    private let eventLogLock = NSLock()
    private var customBaseDirectory: URL?
    private(set) var rootDirectory: URL?
    private(set) var segmentIndex: Int = 0
    private(set) var currentAreaM2: Double = 0
    private(set) var priceTags: [PriceTagRecord] = []
    private(set) var poseSamples: [ScanPoseSample] = []
    private(set) var sensorStartPose: ScanSensorPose?
    private(set) var sensorEndPose: ScanSensorPose?
    private(set) var trackingSessionId = UUID().uuidString
    private var sensorPoseCount = 0
    private var normalTrackingPoseCount = 0
    private var limitedTrackingPoseCount = 0
    private var unavailableTrackingPoseCount = 0
    private var longestSensorGapSeconds = 0.0
    private var previousSensorTimestamp: TimeInterval?
    private var trajectorySampleInputCount = 0
    private var trajectorySampleStride = 1
    private var evaluatedMappingFrameCount = 0
    private var acceptedMappingFrameCount = 0
    private var rejectedMappingFrameCount = 0
    private var degradedTrackingRejectedFrameCount = 0
    private var trackingRecoveryRejectedFrameCount = 0
    private var poseDiscontinuityCompensationCount = 0
    private var lowVisualFeatureFrameCount = 0
    private var maximumObservedLinearSpeedMps = 0.0
    private var maximumObservedAngularSpeedDegPerSecond = 0.0
    private var latestStructureCoverageSnapshot: ScanStructureCoverageSnapshot?
    private var latestStructureCoverageSummary: ScanStructureCoverageSummary?
    private let maximumTrajectorySamples = 50_000
    private var nextTagId: Int = 1

    private var finalizingScan = false
    var isFinalizingScan: Bool {
        get {
            captureLock.lock()
            defer { captureLock.unlock() }
            return finalizingScan
        }
        set {
            captureLock.lock()
            defer { captureLock.unlock() }
            finalizingScan = newValue
        }
    }

    init(documentsDirectory: URL) {
        self.documentsDirectory = documentsDirectory
    }

    var baseDirectory: URL {
        return documentsDirectory
    }

    var hasCustomBaseDirectory: Bool {
        return customBaseDirectory != nil
    }

    /// Capture the selected export location before asynchronous work. A new
    /// scan may start while an older database is still being copied.
    func customBaseDirectorySnapshot() -> URL? {
        return customBaseDirectory
    }

    func setCustomBaseDirectory(_ url: URL?) {
        customBaseDirectory = url
    }

    func clearCustomBaseDirectory() {
        customBaseDirectory = nil
    }

    func refreshUnsavedSessionLocation() {
        if segmentIndex <= 1 {
            let activeStreamingDatabase = rootDirectory?
                .appendingPathComponent("segment_0001", isDirectory: true)
                .appendingPathComponent("rtabmap_segment_0001.db")
            if let activeDatabase = activeStreamingDatabase,
               fileManager.fileExists(atPath: activeDatabase.path) {
                return
            }
            else {
                rootDirectory = nil
            }
        }
    }

    func startAccessingBaseDirectorySecurityScope() -> Bool {
        return customBaseDirectory?.startAccessingSecurityScopedResource() ?? false
    }

    func stopAccessingBaseDirectorySecurityScope() {
        customBaseDirectory?.stopAccessingSecurityScopedResource()
    }

    func startNewSessionIfNeeded() throws {
        if rootDirectory == nil {
            let stamp = Date().getFormattedDate(format: "yyyyMMdd-HHmmss")
            let baseName = "SupermarketSession-\(stamp)"
            var root = baseDirectory.appendingPathComponent(baseName, isDirectory: true)
            var collisionIndex = 2
            while fileManager.fileExists(atPath: root.path) {
                root = baseDirectory.appendingPathComponent(
                    "\(baseName)-\(collisionIndex)",
                    isDirectory: true)
                collisionIndex += 1
            }
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            rootDirectory = root
            segmentIndex = 1
            trackingSessionId = UUID().uuidString
            nextTagId = 1
            resetCurrentSegment()
        }
    }

    /// Release the active path after a finalized streaming scan. The files are
    /// deliberately kept on disk; clearing only the in-memory session identity
    /// guarantees that the next scan gets a new directory instead of opening
    /// the completed database with `clearDatabase=true`.
    func completeCurrentSession() {
        captureLock.lock()
        defer { captureLock.unlock() }
        rootDirectory = nil
        segmentIndex = 0
        nextTagId = 1
        resetCurrentSegment()
    }

    func resetCurrentSegment() {
        captureLock.lock()
        defer { captureLock.unlock() }
        areaEstimator.reset()
        currentAreaM2 = 0
        priceTags.removeAll()
        poseSamples.removeAll()
        sensorStartPose = nil
        sensorEndPose = nil
        sensorPoseCount = 0
        normalTrackingPoseCount = 0
        limitedTrackingPoseCount = 0
        unavailableTrackingPoseCount = 0
        longestSensorGapSeconds = 0
        previousSensorTimestamp = nil
        trajectorySampleInputCount = 0
        trajectorySampleStride = 1
        evaluatedMappingFrameCount = 0
        acceptedMappingFrameCount = 0
        rejectedMappingFrameCount = 0
        degradedTrackingRejectedFrameCount = 0
        trackingRecoveryRejectedFrameCount = 0
        poseDiscontinuityCompensationCount = 0
        lowVisualFeatureFrameCount = 0
        maximumObservedLinearSpeedMps = 0
        maximumObservedAngularSpeedDegPerSecond = 0
        latestStructureCoverageSnapshot = nil
        latestStructureCoverageSummary = nil
    }

    func currentSegmentDirectory() throws -> URL {
        try startNewSessionIfNeeded()
        let dir = rootDirectory!.appendingPathComponent(String(format: "segment_%04d", segmentIndex), isDirectory: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A streaming scan is stored as one continuously growing RTAB-Map
    /// database. Keeping it in segment_0001 preserves compatibility with the
    /// existing PC tools, while no actual segment rollover is performed.
    func streamingDatabaseURL() throws -> URL {
        let directory = try currentSegmentDirectory()
        return directory.appendingPathComponent("rtabmap_segment_0001.db")
    }

    func copyCaptureToCustomBaseDirectory(
        from localCaptureDirectory: URL,
        destinationBaseDirectory: URL? = nil
    ) throws -> URL? {
        guard let exportBaseDirectory = destinationBaseDirectory ?? customBaseDirectory else {
            return nil
        }

        let sessionDirectoryName = localCaptureDirectory.deletingLastPathComponent().lastPathComponent
        let exportRoot = exportBaseDirectory.appendingPathComponent(sessionDirectoryName, isDirectory: true)
        // `segment_0001` remains an on-disk schema compatibility name. A
        // continuous capture never rolls over to a second directory.
        let exportCapture = exportRoot.appendingPathComponent(localCaptureDirectory.lastPathComponent, isDirectory: true)
        let localSummary = try directoryFileSummary(localCaptureDirectory)
        try fileManager.createDirectory(at: exportRoot, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: exportCapture.path) {
            try fileManager.removeItem(at: exportCapture)
        }
        try fileManager.copyItem(at: localCaptureDirectory, to: exportCapture)
        let exportSummary = try directoryFileSummary(exportCapture)
        guard localSummary == exportSummary else {
            throw NSError(
                domain: "SupermarketScanSession",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("External copy verification failed. The local scan was kept.", comment: "Scan copy verification error")])
        }
        return exportCapture
    }

    func removeLocalCaptureDirectory(_ localCaptureDirectory: URL) throws {
        guard localCaptureDirectory.path.hasPrefix(documentsDirectory.path) else {
            throw NSError(
                domain: "SupermarketScanSession",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Refused to delete a scan outside the local app sandbox.", comment: "Scan cleanup safety error")])
        }
        if fileManager.fileExists(atPath: localCaptureDirectory.path) {
            try fileManager.removeItem(at: localCaptureDirectory)
        }
    }

    private func directoryFileSummary(_ directory: URL) throws -> (files: Int, bytes: UInt64) {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]) else {
            throw NSError(
                domain: "SupermarketScanSession",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Unable to read the scan directory contents.", comment: "Scan directory read error")])
        }

        var fileCount = 0
        var totalBytes: UInt64 = 0
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values.isRegularFile == true {
                fileCount += 1
                totalBytes += UInt64(values.fileSize ?? 0)
            }
        }
        return (fileCount, totalBytes)
    }

    func updateArea(timestamp: TimeInterval, nodeCount: Int, x: Float, y: Float, z: Float, roll: Float, pitch: Float, yaw: Float) -> Double {
        captureLock.lock()
        defer { captureLock.unlock() }
        currentAreaM2 = areaEstimator.update(x: x, z: z)
        trajectorySampleInputCount += 1
        if trajectorySampleInputCount % trajectorySampleStride == 0 {
            poseSamples.append(ScanPoseSample(
                timestamp: timestamp,
                segmentIndex: segmentIndex,
                nodeCount: nodeCount,
                x: x,
                y: y,
                z: z,
                roll: roll,
                pitch: pitch,
                yaw: yaw))
        }
        if poseSamples.count >= maximumTrajectorySamples {
            // Preserve the full time span while bounding sidecar RAM. The
            // SQLite Node graph remains the lossless authoritative trajectory.
            poseSamples = poseSamples.enumerated().compactMap { index, sample in
                index % 2 == 0 ? sample : nil
            }
            trajectorySampleStride *= 2
        }
        return currentAreaM2
    }

    func updateSensorPose(timestamp: TimeInterval, matrixColumnMajor: [Float], trackingState: String) {
        guard matrixColumnMajor.count == 16 else {
            return
        }
        captureLock.lock()
        defer { captureLock.unlock() }
        let pose = ScanSensorPose(
            timestamp: timestamp,
            matrixColumnMajor: matrixColumnMajor,
            trackingState: trackingState)
        if sensorStartPose == nil {
            sensorStartPose = pose
        }
        sensorEndPose = pose
        sensorPoseCount += 1
        if trackingState == "normal" {
            normalTrackingPoseCount += 1
        }
        else if trackingState.hasPrefix("limited") {
            limitedTrackingPoseCount += 1
        }
        else {
            unavailableTrackingPoseCount += 1
        }
        if let previous = previousSensorTimestamp, timestamp >= previous {
            longestSensorGapSeconds = max(longestSensorGapSeconds, timestamp - previous)
        }
        previousSensorTimestamp = timestamp

    }

    func recordMappingFrameQuality(
        accepted: Bool,
        rejectionReason: String? = nil,
        rawFeatureCount: Int,
        linearSpeedMps: Double? = nil,
        angularSpeedDegPerSecond: Double? = nil
    ) {
        captureLock.lock()
        defer { captureLock.unlock() }
        evaluatedMappingFrameCount += 1
        if accepted {
            acceptedMappingFrameCount += 1
        }
        else {
            rejectedMappingFrameCount += 1
            switch rejectionReason {
            case "degraded_tracking":
                degradedTrackingRejectedFrameCount += 1
            case "tracking_recovery":
                trackingRecoveryRejectedFrameCount += 1
            case "pose_discontinuity":
                poseDiscontinuityCompensationCount += 1
            default:
                break
            }
        }
        if rawFeatureCount < 50 {
            lowVisualFeatureFrameCount += 1
        }
        if let linearSpeedMps = linearSpeedMps, linearSpeedMps.isFinite {
            maximumObservedLinearSpeedMps = max(maximumObservedLinearSpeedMps, linearSpeedMps)
        }
        if let angularSpeedDegPerSecond = angularSpeedDegPerSecond,
           angularSpeedDegPerSecond.isFinite {
            maximumObservedAngularSpeedDegPerSecond = max(
                maximumObservedAngularSpeedDegPerSecond,
                angularSpeedDegPerSecond)
        }
    }

    func addPriceTag(tagIdentifier: String, payload: String, timestamp: TimeInterval, nodeCount: Int, x: Float, y: Float, z: Float, roll: Float, pitch: Float, yaw: Float, note: String = "") -> PriceTagRecord {
        let record = PriceTagRecord(
            id: nextTagId,
            tagIdentifier: tagIdentifier,
            payload: payload,
            timestamp: timestamp,
            segmentIndex: segmentIndex,
            nodeCount: nodeCount,
            x: x,
            y: y,
            z: z,
            roll: roll,
            pitch: pitch,
            yaw: yaw,
            note: note)
        nextTagId += 1
        priceTags.append(record)
        return record
    }

    func makeSidecarSnapshot(metadata: ScanSegmentMetadata) -> ScanSegmentSidecarSnapshot {
        captureLock.lock()
        defer { captureLock.unlock() }
        return ScanSegmentSidecarSnapshot(
            metadata: metadata,
            priceTags: priceTags,
            areaCells: ScanAreaCells(
                segmentIndex: metadata.segmentIndex,
                cellSizeM: areaEstimator.cellSizeM,
                scanRadiusM: areaEstimator.scanRadiusM,
                cells: areaEstimator.occupiedCellCoordinates()),
            poseSamples: poseSamples,
            structureCoverage: latestStructureCoverageSnapshot)
    }

    func updateStructureCoverageSnapshot(_ snapshot: ScanStructureCoverageSnapshot) {
        captureLock.lock()
        defer { captureLock.unlock() }
        latestStructureCoverageSnapshot = snapshot
        latestStructureCoverageSummary = snapshot.summary
    }

    func updateStructureCoverageSummary(_ summary: ScanStructureCoverageSummary) {
        captureLock.lock()
        defer { captureLock.unlock() }
        latestStructureCoverageSummary = summary
    }

    func structureCoverageSummary() -> ScanStructureCoverageSummary? {
        captureLock.lock()
        defer { captureLock.unlock() }
        return latestStructureCoverageSummary
    }

    func boundarySnapshot() -> ScanBoundarySnapshot {
        captureLock.lock()
        defer { captureLock.unlock() }
        return ScanBoundarySnapshot(
            sensorStartPose: sensorStartPose,
            sensorEndPose: sensorEndPose,
            rtabmapStartPose: poseSamples.first,
            rtabmapEndPose: poseSamples.last,
            captureHealth: captureHealthLocked())
    }

    func makeLiveCheckpoint(
        nodeCount: Int,
        databaseBytes: UInt64,
        availableDiskBytes: Int64?,
        usedMemoryMB: Int,
        thermalState: String
    ) -> ScanLiveCheckpoint {
        captureLock.lock()
        defer { captureLock.unlock() }
        return ScanLiveCheckpoint(
            format: "SupermarketLiveCheckpoint",
            version: 1,
            updatedAt: Date().getFormattedDate(format: "yyyy-MM-dd HH:mm:ss"),
            scanMode: "continuous_streaming",
            finalized: false,
            trackingSessionId: trackingSessionId,
            nodeCount: nodeCount,
            knownAreaM2: currentAreaM2,
            databaseBytes: databaseBytes,
            availableDiskBytes: availableDiskBytes,
            usedMemoryMB: usedMemoryMB,
            thermalState: thermalState,
            sensorEndPose: sensorEndPose,
            captureHealth: captureHealthLocked(),
            structureCoverage: latestStructureCoverageSummary)
    }

    private func captureHealthLocked() -> ScanCaptureHealth {
        return ScanCaptureHealth(
            sensorPoseCount: sensorPoseCount,
            normalTrackingPoseCount: normalTrackingPoseCount,
            limitedTrackingPoseCount: limitedTrackingPoseCount,
            unavailableTrackingPoseCount: unavailableTrackingPoseCount,
            longestSensorGapSeconds: longestSensorGapSeconds,
            storedTrajectorySamples: poseSamples.count,
            trajectorySampleStride: trajectorySampleStride,
            evaluatedMappingFrameCount: evaluatedMappingFrameCount,
            acceptedMappingFrameCount: acceptedMappingFrameCount,
            rejectedMappingFrameCount: rejectedMappingFrameCount,
            degradedTrackingRejectedFrameCount: degradedTrackingRejectedFrameCount,
            trackingRecoveryRejectedFrameCount: trackingRecoveryRejectedFrameCount,
            poseDiscontinuityCompensationCount: poseDiscontinuityCompensationCount,
            lowVisualFeatureFrameCount: lowVisualFeatureFrameCount,
            maximumObservedLinearSpeedMps: maximumObservedLinearSpeedMps,
            maximumObservedAngularSpeedDegPerSecond: maximumObservedAngularSpeedDegPerSecond)
    }

    func writeLiveCheckpoint(to segmentDirectory: URL, checkpoint: ScanLiveCheckpoint) throws {
        sidecarWriteLock.lock()
        defer { sidecarWriteLock.unlock() }
        guard !isFinalizingScan else {
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(checkpoint)
        try data.write(
            to: segmentDirectory.appendingPathComponent("live_checkpoint.json"),
            options: .atomic)
    }

    func writeSidecarFiles(to segmentDirectory: URL, snapshot: ScanSegmentSidecarSnapshot) throws {
        sidecarWriteLock.lock()
        defer { sidecarWriteLock.unlock() }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let metadataData = try encoder.encode(snapshot.metadata)
        try metadataData.write(to: segmentDirectory.appendingPathComponent("metadata.json"), options: .atomic)

        let tagsData = try encoder.encode(snapshot.priceTags)
        try tagsData.write(to: segmentDirectory.appendingPathComponent("price_tags.json"), options: .atomic)

        try priceTagsCSV(snapshot.priceTags).write(
            to: segmentDirectory.appendingPathComponent("price_tags.csv"),
            atomically: true,
            encoding: .utf8)

        let areaCellsData = try encoder.encode(snapshot.areaCells)
        try areaCellsData.write(to: segmentDirectory.appendingPathComponent("scan_area_cells.json"), options: .atomic)

        let poseSamplesData = try encoder.encode(snapshot.poseSamples)
        try poseSamplesData.write(to: segmentDirectory.appendingPathComponent("trajectory_samples.json"), options: .atomic)

        try trajectorySamplesCSV(snapshot.poseSamples).write(
            to: segmentDirectory.appendingPathComponent("trajectory_samples.csv"),
            atomically: true,
            encoding: .utf8)

        if let structureCoverage = snapshot.structureCoverage {
            let structureCoverageData = try encoder.encode(structureCoverage)
            try structureCoverageData.write(
                to: segmentDirectory.appendingPathComponent("structure_coverage_cells.json"),
                options: .atomic)
        }

        if snapshot.metadata.finalized == true {
            // A final metadata.json supersedes the crash-recovery heartbeat.
            try? fileManager.removeItem(
                at: segmentDirectory.appendingPathComponent("live_checkpoint.json"))
        }
    }

    func appendScanEvent(
        level: String = "info",
        event: String,
        message: String,
        fields: [String: String] = [:]
    ) {
        let directory: URL
        do {
            directory = try currentSegmentDirectory()
        }
        catch {
            print("Could not create scan event log directory: \(error)")
            return
        }

        let now = Date()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let record = ScanEventRecord(
            format: "SupermarketScanEvent",
            version: 1,
            timestamp: formatter.string(from: now),
            timestampUnix: now.timeIntervalSince1970,
            level: level,
            event: event,
            message: message,
            trackingSessionId: trackingSessionId,
            fields: fields)

        eventLogLock.lock()
        defer { eventLogLock.unlock() }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            var data = try encoder.encode(record)
            data.append(0x0A)
            let logURL = directory.appendingPathComponent("scan_events.jsonl")
            if !fileManager.fileExists(atPath: logURL.path) {
                try data.write(to: logURL, options: .atomic)
            }
            else {
                let handle = try FileHandle(forWritingTo: logURL)
                handle.seekToEndOfFile()
                handle.write(data)
                handle.synchronizeFile()
                handle.closeFile()
            }
        }
        catch {
            print("Could not append scan event log: \(error)")
        }
    }

    private func priceTagsCSV(_ tags: [PriceTagRecord]) -> String {
        var rows = ["id,tagIdentifier,payload,timestamp,segmentIndex,nodeCount,x,y,z,roll,pitch,yaw,note"]
        for tag in tags {
            rows.append([
                String(tag.id),
                csv(tag.tagIdentifier),
                csv(tag.payload),
                String(format: "%.6f", tag.timestamp),
                String(tag.segmentIndex),
                String(tag.nodeCount),
                String(format: "%.4f", tag.x),
                String(format: "%.4f", tag.y),
                String(format: "%.4f", tag.z),
                String(format: "%.5f", tag.roll),
                String(format: "%.5f", tag.pitch),
                String(format: "%.5f", tag.yaw),
                csv(tag.note)
            ].joined(separator: ","))
        }
        return rows.joined(separator: "\n") + "\n"
    }

    private func trajectorySamplesCSV(_ samples: [ScanPoseSample]) -> String {
        var rows = ["timestamp,segmentIndex,nodeCount,x,y,z,roll,pitch,yaw"]
        for sample in samples {
            rows.append([
                String(format: "%.6f", sample.timestamp),
                String(sample.segmentIndex),
                String(sample.nodeCount),
                String(format: "%.4f", sample.x),
                String(format: "%.4f", sample.y),
                String(format: "%.4f", sample.z),
                String(format: "%.5f", sample.roll),
                String(format: "%.5f", sample.pitch),
                String(format: "%.5f", sample.yaw)
            ].joined(separator: ","))
        }
        return rows.joined(separator: "\n") + "\n"
    }

    private func csv(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }

}
