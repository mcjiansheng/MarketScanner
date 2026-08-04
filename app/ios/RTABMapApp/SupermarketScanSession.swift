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
    var finalized: Bool?
    /// Phone capture keeps a bounded online graph for feedback, while the PC
    /// re-extracts features and performs the authoritative global optimization.
    let processingProfile: String?
    let exportedAt: String
    var finalizedAtUnix: TimeInterval?
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
    var processingEligibility: ScanProcessingEligibility?
    /// Lightweight phone-side coverage guidance statistics. This is not a
    /// semantic shelf map; the authoritative geometry remains in the RGB-D
    /// database and is reconstructed on the PC.
    let structureCoverage: ScanStructureCoverageSummary?
    /// Business workflow mode is separate from `scanMode`, which remains the
    /// storage-layout compatibility marker (`continuous_streaming`).
    let formatVersion: Int?
    let workflowMode: String?
    let priorMapId: String?
    let priorMapSha256: String?
    let floorId: String?
    let initialMapPose: PriorMapPose2D?
    let localizationTrace: String?
    let manualLocalizationEvents: String?
    let localizationConstraints: String?
    let localizationEvents: String?
    let localizationRecoveryEvents: String?
    let tagObservations: String?
    let localizedPriceTags: String?
    let localizedPriceTagCount: Int?
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
    let localizedPriceTags: [LocalizedPriceTag]
}

struct ScanProcessingEligibility: Codable {
    let status: String
    let blockers: [String]
}

private struct LocalizationRecordWriteResult {
    let succeeded: Bool
    let errorReason: String?
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
    let localizationRequiredWriteFailureCount: Int
    let firstLocalizationRequiredWriteError: String?
    let localizationTraceRecordCount: Int
    let localizationConstraintRecordCount: Int
    let localizationStateEventCount: Int
    let localizationLastDurableState: String?
    let localizationEvidenceComplete: Bool
    /// P7R6 recovery lifecycle watermark. Exactly one durable record must
    /// exist per finished Recovery episode; finalization validates the
    /// sidecar against these counts instead of trusting an optional file.
    /// Decoded optional so pre-P7R6 metadata keeps the legacy schema, while
    /// new sessions always write non-nil values.
    let localizationRecoveryEventCount: Int?
    let localizationLastRecoveryEpisodeId: Int?
    let localizationLastRecoveryFinishedAtUptime: TimeInterval?
    let localizationRecoveryEvidenceComplete: Bool?
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
    let updatedAtUnix: TimeInterval?
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
    let workflowMode: String?
    let priorMapId: String?
    let priorMapSha256: String?
    let floorId: String?
    let initialMapPose: PriorMapPose2D?
}

struct ManualLocalizationEvent: Encodable {
    let format: String
    let version: Int
    let wallClockTimestamp: String
    let wallClockTimestampUnix: TimeInterval
    let frameTimestamp: TimeInterval
    let nodeTimebaseFrameTimestamp: TimeInterval
    let nodeTimebaseOffsetSeconds: TimeInterval
    let nearestNodeId: Int?
    let nearestNodeStamp: TimeInterval?
    let nodeTimeDeltaSeconds: TimeInterval?
    let nodeTimeSnapshotGeneration: UInt64
    let nodeBindingStatus: String
    let nodeBindingReason: String
    let alignmentVersion: Int
    let trackingSessionId: String
    let priorMapId: String?
    let priorMapSha256: String?
    let floorId: String?
    let reason: String
    let arkitPose: PriorMapPose2D
    let confirmedMapPose: PriorMapPose2D

    enum CodingKeys: String, CodingKey {
        case format
        case version
        case wallClockTimestamp = "wall_clock_timestamp"
        case wallClockTimestampUnix = "wall_clock_timestamp_unix"
        case frameTimestamp = "frame_timestamp"
        case nodeTimebaseFrameTimestamp = "node_timebase_frame_timestamp"
        case nodeTimebaseOffsetSeconds = "node_timebase_offset_seconds"
        case nearestNodeId = "nearest_node_id"
        case nearestNodeStamp = "nearest_node_stamp"
        case nodeTimeDeltaSeconds = "node_time_delta_seconds"
        case nodeTimeSnapshotGeneration = "node_time_snapshot_generation"
        case nodeBindingStatus = "node_binding_status"
        case nodeBindingReason = "node_binding_reason"
        case alignmentVersion = "alignment_version"
        case trackingSessionId = "tracking_session_id"
        case priorMapId = "prior_map_id"
        case priorMapSha256 = "prior_map_sha256"
        case floorId = "floor_id"
        case reason
        case arkitPose = "arkit_pose"
        case confirmedMapPose = "confirmed_map_pose"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(format, forKey: .format)
        try container.encode(version, forKey: .version)
        try container.encode(wallClockTimestamp, forKey: .wallClockTimestamp)
        try container.encode(wallClockTimestampUnix, forKey: .wallClockTimestampUnix)
        try container.encode(frameTimestamp, forKey: .frameTimestamp)
        try container.encode(
            nodeTimebaseFrameTimestamp, forKey: .nodeTimebaseFrameTimestamp)
        try container.encode(
            nodeTimebaseOffsetSeconds, forKey: .nodeTimebaseOffsetSeconds)
        if let nearestNodeId {
            try container.encode(nearestNodeId, forKey: .nearestNodeId)
        } else {
            try container.encodeNil(forKey: .nearestNodeId)
        }
        if let nearestNodeStamp {
            try container.encode(nearestNodeStamp, forKey: .nearestNodeStamp)
        } else {
            try container.encodeNil(forKey: .nearestNodeStamp)
        }
        if let nodeTimeDeltaSeconds {
            try container.encode(nodeTimeDeltaSeconds, forKey: .nodeTimeDeltaSeconds)
        } else {
            try container.encodeNil(forKey: .nodeTimeDeltaSeconds)
        }
        try container.encode(
            nodeTimeSnapshotGeneration,
            forKey: .nodeTimeSnapshotGeneration)
        try container.encode(nodeBindingStatus, forKey: .nodeBindingStatus)
        try container.encode(nodeBindingReason, forKey: .nodeBindingReason)
        try container.encode(alignmentVersion, forKey: .alignmentVersion)
        try container.encode(trackingSessionId, forKey: .trackingSessionId)
        try container.encodeIfPresent(priorMapId, forKey: .priorMapId)
        try container.encodeIfPresent(priorMapSha256, forKey: .priorMapSha256)
        try container.encodeIfPresent(floorId, forKey: .floorId)
        try container.encode(reason, forKey: .reason)
        try container.encode(arkitPose, forKey: .arkitPose)
        try container.encode(confirmedMapPose, forKey: .confirmedMapPose)
    }
}

struct PriorMapConstraintRecord: Codable {
    let format: String
    let version: Int
    let timestamp: TimeInterval
    let nodeTimebaseTimestamp: TimeInterval
    let nodeTimebaseOffsetSeconds: TimeInterval
    let trackingSessionId: String
    let priorMapId: String?
    let priorMapSha256: String?
    let floorId: String?
    let accepted: Bool
    let measurementAccepted: Bool
    let correctionStepApplied: Bool
    let confidenceAccepted: Bool
    let disposition: PriorMapConstraintDisposition
    let reason: String
    let predictedPose: PriorMapPose2D
    let estimatedPose: PriorMapPose2D
    let candidates: [PriorMapScanMatchCandidate]
    let uniqueness: Double
    let residualCost: Double?
    let effectivePointCount: Int
    let coverageAngleRad: Double
    let matcherElapsedMs: Double
}

struct PriorMapStateEvent: Codable {
    let format: String
    let version: Int
    let timestamp: TimeInterval
    let nodeTimebaseTimestamp: TimeInterval
    let nodeTimebaseOffsetSeconds: TimeInterval
    let trackingSessionId: String
    let priorMapId: String?
    let priorMapSha256: String?
    let floorId: String?
    let previousState: String?
    let state: String
    let confidence: Double
    let reason: String
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
    private let sidecarWriter: ScanSidecarFileWriting
    private let documentsDirectory: URL
    private let areaEstimator = FloorAreaEstimator()
    private let captureLock = NSRecursiveLock()
    private let sidecarWriteLock = NSLock()
    private let eventLogLock = NSLock()
    private let localizationLogLock = NSLock()
    private let localizationTransactionLock = NSLock()
    private var customBaseDirectory: URL?
    private(set) var rootDirectory: URL?
    private(set) var segmentIndex: Int = 0
    private(set) var currentAreaM2: Double = 0
    private(set) var priceTags: [PriceTagRecord] = []
    private(set) var poseSamples: [ScanPoseSample] = []
    private(set) var localizedPriceTags: [LocalizedPriceTag] = []
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
    private var localizationRequiredWriteFailureCount = 0
    private var firstLocalizationRequiredWriteError: String?
    private var localizationTraceRecordCount = 0
    private var localizationConstraintRecordCount = 0
    private var localizationStateEventCount = 0
    private var localizationRecoveryEventCount = 0
    private var localizationLastRecoveryEpisodeId: Int?
    private var localizationLastRecoveryFinishedAtUptime: TimeInterval?
    private var latestStructureCoverageSnapshot: ScanStructureCoverageSnapshot?
    private var latestStructureCoverageSummary: ScanStructureCoverageSummary?
    private let maximumTrajectorySamples = 50_000
    private var nextTagId: Int = 1
    private var lastLocalizationState: String?
    private(set) var scanConfiguration = PriorMapScanConfiguration.freeMapping

    private var finalizingScan = false
    var isFinalizingScan: Bool {
        get {
            captureLock.lock()
            defer { captureLock.unlock() }
            return finalizingScan
        }
        set {
            if newValue {
                localizationTransactionLock.lock()
            }
            captureLock.lock()
            finalizingScan = newValue
            captureLock.unlock()
            if newValue {
                localizationTransactionLock.unlock()
            }
        }
    }

    init(
        documentsDirectory: URL,
        sidecarWriter: ScanSidecarFileWriting = FoundationScanSidecarWriter()
    ) {
        self.documentsDirectory = documentsDirectory
        self.sidecarWriter = sidecarWriter
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

    func configureScan(_ configuration: PriorMapScanConfiguration) {
        captureLock.lock()
        defer { captureLock.unlock() }
        scanConfiguration = configuration
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
        scanConfiguration = .freeMapping
        resetCurrentSegment()
    }

    func resetCurrentSegment() {
        captureLock.lock()
        defer { captureLock.unlock() }
        areaEstimator.reset()
        currentAreaM2 = 0
        priceTags.removeAll()
        localizedPriceTags.removeAll()
        lastLocalizationState = nil
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
        localizationRequiredWriteFailureCount = 0
        firstLocalizationRequiredWriteError = nil
        localizationTraceRecordCount = 0
        localizationConstraintRecordCount = 0
        localizationStateEventCount = 0
        localizationRecoveryEventCount = 0
        localizationLastRecoveryEpisodeId = nil
        localizationLastRecoveryFinishedAtUptime = nil
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
        let localManifestBeforeCopy = try CaptureDirectoryIntegrity.manifest(
            for: localCaptureDirectory,
            fileManager: fileManager)
        try fileManager.createDirectory(at: exportRoot, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: exportCapture.path) {
            try fileManager.removeItem(at: exportCapture)
        }
        try fileManager.copyItem(at: localCaptureDirectory, to: exportCapture)
        let exportManifest = try CaptureDirectoryIntegrity.manifest(
            for: exportCapture,
            fileManager: fileManager)
        let localManifestAfterCopy = try CaptureDirectoryIntegrity.manifest(
            for: localCaptureDirectory,
            fileManager: fileManager)
        guard localManifestBeforeCopy == exportManifest,
              localManifestBeforeCopy == localManifestAfterCopy else {
            throw NSError(
                domain: "SupermarketScanSession",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("External copy SHA-256 verification failed or the source changed during copying. The local scan was kept.", comment: "Scan copy verification error")])
        }
        let packageId = UUID().uuidString.lowercased()
        let packageContentSha256 = try CaptureDirectoryIntegrity.manifestSHA256(
            exportManifest)
        let receipt = ExternalCopyVerificationReceipt(
            format: "MarketScannerExternalCopyVerification",
            version: 2,
            packageId: packageId,
            sessionId: trackingSessionId,
            verifiedAtUnix: Date().timeIntervalSince1970,
            providerDisplayName: exportBaseDirectory.lastPathComponent,
            sourceRelativePath: localCaptureDirectory.lastPathComponent,
            destinationRelativePath:
                "\(sessionDirectoryName)/\(exportCapture.lastPathComponent)",
            files: exportManifest,
            packageContentSha256: packageContentSha256,
            localCopyRetained: true,
            durabilityBoundary:
                "provider_copy_closed_and_reread_no_power_loss_guarantee")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try sidecarWriter.writeAtomic(
            try encoder.encode(receipt),
            to: exportRoot.appendingPathComponent(
                "copy_verification.json"))
        let receiptAndCaptureManifest = try CaptureDirectoryIntegrity.manifest(
            for: exportRoot,
            fileManager: fileManager)
        let packageManifest = ExternalCopyPackageManifest(
            format: "MarketScannerExternalCopyPackageManifest",
            version: 1,
            packageId: packageId,
            sessionId: trackingSessionId,
            providerDisplayName: exportBaseDirectory.lastPathComponent,
            packageContentSha256: try CaptureDirectoryIntegrity.manifestSHA256(
                receiptAndCaptureManifest),
            files: receiptAndCaptureManifest,
            localCopyRetained: true,
            durabilityQualificationStatus: "not_executed",
            durabilityExperimentHook:
                "reconnect_or_power_cycle_provider_then_rehash_manifest_on_real_device")
        try sidecarWriter.writeAtomic(
            try encoder.encode(packageManifest),
            to: exportRoot.appendingPathComponent(
                "copy_package_manifest.json"))
        return exportCapture
    }

    /// Device-qualification hook. Call only after the named real provider
    /// reconnect or power-cycle experiment has actually occurred. This does
    /// not upgrade the initial copy receipt into a power-loss guarantee.
    @discardableResult
    func recordExternalCopyDurabilityQualification(
        at exportRoot: URL,
        experiment: String
    ) throws -> URL {
        let allowedExperiments = Set([
            "provider_reconnect",
            "provider_disconnect_reconnect",
            "device_power_cycle",
        ])
        guard allowedExperiments.contains(experiment) else {
            throw NSError(
                domain: "SupermarketScanSession",
                code: 40,
                userInfo: [NSLocalizedDescriptionKey:
                    "External-copy durability experiment name is not allowed."])
        }
        let packageManifestURL = exportRoot.appendingPathComponent(
            "copy_package_manifest.json")
        let packageManifestSnapshot = try SafeSessionPath.readRegularFile(
            packageManifestURL,
            within: exportRoot.deletingLastPathComponent(),
            maximumBytes: 32 * 1024 * 1024)
        let packageManifest = try JSONDecoder().decode(
            ExternalCopyPackageManifest.self,
            from: packageManifestSnapshot.data)
        guard packageManifest.format
                == "MarketScannerExternalCopyPackageManifest",
              packageManifest.version == 1,
              packageManifest.sessionId == trackingSessionId,
              packageManifest.localCopyRetained else {
            throw NSError(
                domain: "SupermarketScanSession",
                code: 42,
                userInfo: [NSLocalizedDescriptionKey:
                    "External-copy package identity is invalid."])
        }
        let currentFiles = try CaptureDirectoryIntegrity.manifest(
            for: exportRoot,
            fileManager: fileManager).filter {
                $0.relativePath != "copy_package_manifest.json"
                    && $0.relativePath != "copy_durability_qualification.json"
            }
        guard currentFiles == packageManifest.files,
              try CaptureDirectoryIntegrity.manifestSHA256(currentFiles)
                == packageManifest.packageContentSha256 else {
            throw NSError(
                domain: "SupermarketScanSession",
                code: 43,
                userInfo: [NSLocalizedDescriptionKey:
                    "External-copy package changed during durability qualification."])
        }
        let evidence = ExternalCopyDurabilityQualificationEvidence(
            format: "MarketScannerExternalCopyDurabilityQualification",
            version: 1,
            packageId: packageManifest.packageId,
            sessionId: packageManifest.sessionId,
            providerDisplayName: packageManifest.providerDisplayName,
            experiment: experiment,
            verifiedAtUnix: Date().timeIntervalSince1970,
            packageContentSha256: packageManifest.packageContentSha256,
            localCopyRetained: true,
            result: "verified_after_declared_real_device_experiment")
        let evidenceURL = exportRoot.appendingPathComponent(
            "copy_durability_qualification.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try sidecarWriter.writeAtomic(try encoder.encode(evidence), to: evidenceURL)
        return evidenceURL
    }

    func removeLocalCaptureDirectory(_ localCaptureDirectory: URL) throws {
        let sessionDirectory = localCaptureDirectory.deletingLastPathComponent()
        guard localCaptureDirectory.lastPathComponent == "segment_0001",
              sessionDirectory.lastPathComponent.hasPrefix(
                "SupermarketSession-") else {
            throw NSError(
                domain: "SupermarketScanSession",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Refused to delete a scan outside the local app sandbox.", comment: "Scan cleanup safety error")])
        }
        try SafeSessionPath.validateDirectory(
            sessionDirectory,
            within: documentsDirectory)
        try SafeSessionPath.validateDirectory(
            localCaptureDirectory,
            within: sessionDirectory)
        let segmentNames = try fileManager.contentsOfDirectory(
            at: sessionDirectory,
            includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("segment_") }
            .map(\.lastPathComponent)
            .sorted()
        guard segmentNames == ["segment_0001"] else {
            throw NSError(
                domain: "SupermarketScanSession",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey:
                    "Refused to delete a scan with an ambiguous segment layout."])
        }
        let metadata = try SafeSessionPath.readRegularFile(
            localCaptureDirectory.appendingPathComponent("metadata.json"),
            within: sessionDirectory)
        let cleanupMetadata = try JSONDecoder().decode(
            FinalizedCheckpointCleanupMetadata.self,
            from: metadata.data)
        guard cleanupMetadata.finalized == true,
              cleanupMetadata.trackingSessionId?.isEmpty == false else {
            throw NSError(
                domain: "SupermarketScanSession",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey:
                    "Refused to delete a scan without finalized identity evidence."])
        }
        if fileManager.fileExists(atPath: localCaptureDirectory.path) {
            try fileManager.removeItem(at: localCaptureDirectory)
        }
    }

    /// Returns only sessions whose finalized metadata and older checkpoint
    /// share one tracking identity. Older schemas without Unix commit times
    /// are intentionally not offered for automatic cleanup.
    func finalizedSegmentsNeedingCheckpointCleanup() -> [URL] {
        guard let sessions = try? fileManager.contentsOfDirectory(
            at: documentsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]) else {
            return []
        }
        return sessions.compactMap { sessionDirectory -> URL? in
            guard sessionDirectory.lastPathComponent.hasPrefix(
                "SupermarketSession-") else {
                return nil
            }
            let segment = sessionDirectory.appendingPathComponent(
                "segment_0001",
                isDirectory: true)
            let metadata = segment.appendingPathComponent("metadata.json")
            let checkpoint = segment.appendingPathComponent(
                "live_checkpoint.json")
            let events = segment.appendingPathComponent("scan_events.jsonl")
            guard (try? SafeSessionPath.validateDirectory(
                    sessionDirectory,
                    within: documentsDirectory)) != nil,
                  (try? SafeSessionPath.validateDirectory(
                    segment,
                    within: sessionDirectory)) != nil,
                  let segmentEntries = try? fileManager.contentsOfDirectory(
                    at: sessionDirectory,
                    includingPropertiesForKeys: nil),
                  segmentEntries.filter({
                    $0.lastPathComponent.hasPrefix("segment_")
                  }).map(\.lastPathComponent).sorted() == ["segment_0001"],
                  let metadataSnapshot = try? SafeSessionPath.readRegularFile(
                    metadata,
                    within: sessionDirectory),
                  let checkpointSnapshot = try? SafeSessionPath.readRegularFile(
                    checkpoint,
                    within: sessionDirectory),
                  (!fileManager.fileExists(atPath: events.path)
                    || (try? SafeSessionPath.readRegularFile(
                        events,
                        within: sessionDirectory)) != nil),
                  (try? FinalizedCheckpointCleanupValidator.validate(
                    metadataData: metadataSnapshot.data,
                    checkpointData: checkpointSnapshot.data)) != nil else {
                return nil
            }
            return segment
        }.sorted { $0.path < $1.path }
    }

    func cleanupFinalizedCheckpoint(in segmentDirectory: URL) throws {
        let sessionDirectory = segmentDirectory.deletingLastPathComponent()
        guard segmentDirectory.lastPathComponent == "segment_0001" else {
            throw NSError(
                domain: "SupermarketScanSession",
                code: 30,
                userInfo: [NSLocalizedDescriptionKey:
                    "Refused checkpoint cleanup outside a local scan segment."])
        }
        try SafeSessionPath.validateDirectory(
            sessionDirectory,
            within: documentsDirectory)
        try SafeSessionPath.validateDirectory(
            segmentDirectory,
            within: sessionDirectory)
        let segmentNames = try fileManager.contentsOfDirectory(
            at: sessionDirectory,
            includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("segment_") }
            .map(\.lastPathComponent)
            .sorted()
        guard segmentNames == ["segment_0001"] else {
            throw NSError(
                domain: "SupermarketScanSession",
                code: 31,
                userInfo: [NSLocalizedDescriptionKey:
                    "Checkpoint cleanup requires exactly one segment_0001."])
        }
        let metadataURL = segmentDirectory.appendingPathComponent("metadata.json")
        let checkpointURL = segmentDirectory.appendingPathComponent(
            "live_checkpoint.json")
        let metadataSnapshot = try SafeSessionPath.readRegularFile(
            metadataURL,
            within: sessionDirectory)
        let checkpointSnapshot = try SafeSessionPath.readRegularFile(
            checkpointURL,
            within: sessionDirectory)
        let metadataData = metadataSnapshot.data
        let checkpointData = checkpointSnapshot.data
        try FinalizedCheckpointCleanupValidator.validate(
            metadataData: metadataData,
            checkpointData: checkpointData)
        let metadata = try JSONDecoder().decode(
            FinalizedCheckpointCleanupMetadata.self,
            from: metadataData)
        guard let trackingSessionId = metadata.trackingSessionId else {
            throw FinalizedCheckpointCleanupValidationError.missingIdentityOrTime
        }
        try appendRecoveryAuditEvent(
            to: segmentDirectory,
            trackingSessionId: trackingSessionId,
            event: "finalization_checkpoint_cleanup_authorized",
            message: "User authorized cleanup of an older checkpoint after finalized metadata commit")
        do {
            // Re-read after the pre-delete audit append so a concurrently
            // changed file can never be removed under stale evidence.
            let currentMetadata = try SafeSessionPath.readRegularFile(
                metadataURL,
                within: sessionDirectory)
            let currentCheckpoint = try SafeSessionPath.readRegularFile(
                checkpointURL,
                within: sessionDirectory)
            guard currentMetadata == metadataSnapshot,
                  currentCheckpoint == checkpointSnapshot else {
                throw FinalizedCheckpointCleanupValidationError
                    .checkpointNewerThanCommit
            }
            try FinalizedCheckpointCleanupValidator.validate(
                metadataData: currentMetadata.data,
                checkpointData: currentCheckpoint.data)
            try SafeSessionPath.removeRegularFile(
                checkpointURL,
                within: sessionDirectory,
                expected: currentCheckpoint)
        }
        catch {
            do {
                try appendRecoveryAuditEvent(
                    to: segmentDirectory,
                    trackingSessionId: trackingSessionId,
                    event: "finalization_checkpoint_cleanup_failed",
                    message: "Finalized checkpoint cleanup failed: \(error.localizedDescription)")
            }
            catch {
                print("Finalized checkpoint cleanup failure audit degraded: \(error)")
            }
            throw error
        }
        do {
            try appendRecoveryAuditEvent(
                to: segmentDirectory,
                trackingSessionId: trackingSessionId,
                event: "finalization_checkpoint_cleanup_completed",
                message: "Finalized checkpoint cleanup completed")
        }
        catch {
            // Cleanup is already complete and PC eligibility has changed. Do
            // not report a failed cleanup (or encourage an unsafe retry) only
            // because the post-delete audit append failed.
            print("Finalized checkpoint cleanup audit append failed: \(error)")
        }
    }

    private func appendRecoveryAuditEvent(
        to segmentDirectory: URL,
        trackingSessionId: String,
        event: String,
        message: String
    ) throws {
        let now = Date()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let record = ScanEventRecord(
            format: "SupermarketScanEvent",
            version: 1,
            timestamp: formatter.string(from: now),
            timestampUnix: now.timeIntervalSince1970,
            level: "warning",
            event: event,
            message: message,
            trackingSessionId: trackingSessionId,
            fields: ["cleanup_policy": "finalized_same_identity_older_checkpoint_v1"])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(record)
        data.append(0x0A)
        try SafeSessionPath.append(
            data,
            to: segmentDirectory.appendingPathComponent("scan_events.jsonl"),
            within: segmentDirectory.deletingLastPathComponent())
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
            structureCoverage: latestStructureCoverageSnapshot,
            localizedPriceTags: localizedPriceTags)
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

    func confirmedLocalizedPriceTagCount() -> Int {
        captureLock.lock()
        defer { captureLock.unlock() }
        return localizedPriceTags.count
    }

    func localizedPriceTagSnapshot() -> [LocalizedPriceTag] {
        captureLock.lock()
        defer { captureLock.unlock() }
        return localizedPriceTags
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
        let now = Date()
        return ScanLiveCheckpoint(
            format: "SupermarketLiveCheckpoint",
            version: 2,
            updatedAt: now.getFormattedDate(format: "yyyy-MM-dd HH:mm:ss"),
            updatedAtUnix: now.timeIntervalSince1970,
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
            structureCoverage: latestStructureCoverageSummary,
            workflowMode: scanConfiguration.workflowMode.rawValue,
            priorMapId: scanConfiguration.priorMapId,
            priorMapSha256: scanConfiguration.priorMapSha256,
            floorId: scanConfiguration.floorId,
            initialMapPose: scanConfiguration.initialMapPose)
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
            maximumObservedAngularSpeedDegPerSecond: maximumObservedAngularSpeedDegPerSecond,
            localizationRequiredWriteFailureCount:
                localizationRequiredWriteFailureCount,
            firstLocalizationRequiredWriteError:
                firstLocalizationRequiredWriteError,
            localizationTraceRecordCount: localizationTraceRecordCount,
            localizationConstraintRecordCount:
                localizationConstraintRecordCount,
            localizationStateEventCount: localizationStateEventCount,
            localizationLastDurableState: lastLocalizationState,
            localizationEvidenceComplete:
                scanConfiguration.workflowMode != .priorMapLocalized
                    || (localizationRequiredWriteFailureCount == 0
                        && localizationTraceRecordCount > 0
                        && localizationConstraintRecordCount > 0
                        && localizationStateEventCount > 0),
            localizationRecoveryEventCount: localizationRecoveryEventCount,
            localizationLastRecoveryEpisodeId:
                localizationLastRecoveryEpisodeId,
            localizationLastRecoveryFinishedAtUptime:
                localizationLastRecoveryFinishedAtUptime,
            localizationRecoveryEvidenceComplete:
                scanConfiguration.workflowMode != .priorMapLocalized
                    || localizationRequiredWriteFailureCount == 0)
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
        try sidecarWriter.writeAtomic(
            data,
            to: segmentDirectory.appendingPathComponent("live_checkpoint.json"))
    }

    func writeSidecarFiles(
        to segmentDirectory: URL,
        snapshot: ScanSegmentSidecarSnapshot
    ) throws -> SidecarCommitResult {
        sidecarWriteLock.lock()
        defer { sidecarWriteLock.unlock() }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let tagsData = try encoder.encode(snapshot.priceTags)
        try sidecarWriter.writeAtomic(
            tagsData,
            to: segmentDirectory.appendingPathComponent("price_tags.json"))

        try sidecarWriter.writeAtomic(
            Data(priceTagsCSV(snapshot.priceTags).utf8),
            to: segmentDirectory.appendingPathComponent("price_tags.csv"))

        let areaCellsData = try encoder.encode(snapshot.areaCells)
        try sidecarWriter.writeAtomic(
            areaCellsData,
            to: segmentDirectory.appendingPathComponent("scan_area_cells.json"))

        let poseSamplesData = try encoder.encode(snapshot.poseSamples)
        try sidecarWriter.writeAtomic(
            poseSamplesData,
            to: segmentDirectory.appendingPathComponent("trajectory_samples.json"))

        try sidecarWriter.writeAtomic(
            Data(trajectorySamplesCSV(snapshot.poseSamples).utf8),
            to: segmentDirectory.appendingPathComponent("trajectory_samples.csv"))

        if let structureCoverage = snapshot.structureCoverage {
            let structureCoverageData = try encoder.encode(structureCoverage)
            try sidecarWriter.writeAtomic(
                structureCoverageData,
                to: segmentDirectory.appendingPathComponent("structure_coverage_cells.json"))
        }

        // Expected recovery watermark for this finalization. A legacy
        // checkpoint without the P7R6 watermark fields decodes nil and falls
        // back to the legacy zero expectation.
        let expectedRecoveryEventCount =
            snapshot.metadata.captureHealth?.localizationRecoveryEventCount ?? 0
        if scanConfiguration.workflowMode == .priorMapLocalized {
            for fileName in [
                "manual_localization_events.jsonl",
                "tag_observations.jsonl",
            ] {
                let url = segmentDirectory.appendingPathComponent(fileName)
                if !sidecarWriter.fileExists(at: url) {
                    try sidecarWriter.writeAtomic(Data(), to: url)
                }
            }
            // Finalization must never rebuild lost recovery evidence as an
            // empty file: creating the sidecar is only allowed while no
            // episode is expected. A missing file with a positive watermark
            // is a blocker and stays missing for the validator.
            let recoveryURL = segmentDirectory.appendingPathComponent(
                PriorMapRecoveryLifecycleRecord.fileName)
            if !sidecarWriter.fileExists(at: recoveryURL) {
                if expectedRecoveryEventCount == 0 {
                    try sidecarWriter.writeAtomic(Data(), to: recoveryURL)
                }
            }
            let localizedTagsData = try encoder.encode(snapshot.localizedPriceTags)
            try sidecarWriter.writeAtomic(
                localizedTagsData,
                to: segmentDirectory.appendingPathComponent("localized_price_tags.json"))
        }

        var committedMetadata = snapshot.metadata
        var evidenceValidationBlockers: [String] = []
        if scanConfiguration.workflowMode == .priorMapLocalized,
           committedMetadata.finalized == true {
            if let trackingSessionId = committedMetadata.trackingSessionId,
               let priorMapId = committedMetadata.priorMapId,
               let priorMapSha256 = committedMetadata.priorMapSha256,
               let floorId = committedMetadata.floorId,
               let captureHealth = committedMetadata.captureHealth,
               let lastDurableState =
                captureHealth.localizationLastDurableState {
                if expectedRecoveryEventCount > 0,
                   !sidecarWriter.fileExists(at: segmentDirectory
                    .appendingPathComponent(
                        PriorMapRecoveryLifecycleRecord.fileName)) {
                    evidenceValidationBlockers.append(
                        "evidence_bundle_recovery_file_missing_blocker")
                }
                evidenceValidationBlockers +=
                    LocalizationEvidenceBundleValidator.blockers(
                        in: segmentDirectory,
                        expectation: LocalizationEvidenceBundleExpectation(
                            trackingSessionId: trackingSessionId,
                            priorMapId: priorMapId,
                            priorMapSha256: priorMapSha256,
                            floorId: floorId,
                            traceRecordCount:
                                captureHealth.localizationTraceRecordCount,
                            constraintRecordCount:
                                captureHealth.localizationConstraintRecordCount,
                            stateEventCount:
                                captureHealth.localizationStateEventCount,
                            lastDurableState: lastDurableState,
                            localizedPriceTagCount:
                                committedMetadata.localizedPriceTagCount ?? 0,
                            recoveryEventCount:
                                captureHealth.localizationRecoveryEventCount
                                    ?? 0,
                            lastRecoveryEpisodeId:
                                captureHealth
                                    .localizationLastRecoveryEpisodeId,
                            lastRecoveryFinishedAtUptime:
                                captureHealth
                                    .localizationLastRecoveryFinishedAtUptime))
            }
            else {
                evidenceValidationBlockers = [
                    "evidence_bundle_identity_or_watermark_missing"
                ]
            }
            if !evidenceValidationBlockers.isEmpty {
                let existing = committedMetadata.processingEligibility?.blockers ?? []
                committedMetadata.finalized = false
                committedMetadata.finalizedAtUnix = nil
                committedMetadata.processingEligibility = ScanProcessingEligibility(
                    status: "invalid",
                    blockers: Array(Set(
                        existing + evidenceValidationBlockers)).sorted())
            }
        }

        // metadata.json is the commit marker for a completed sidecar bundle.
        // Write it only after every referenced artifact has succeeded.
        let metadataData = try encoder.encode(committedMetadata)
        return try SidecarFinalizationCoordinator.commitMetadata(
            metadataData,
            metadataURL: segmentDirectory.appendingPathComponent("metadata.json"),
            finalized: committedMetadata.finalized == true,
            checkpointURL: segmentDirectory.appendingPathComponent(
                "live_checkpoint.json"),
            writer: sidecarWriter,
            evidenceValidationBlockers: evidenceValidationBlockers)
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
            try sidecarWriter.append(data, to: logURL)
        }
        catch {
            print("Could not append scan event log: \(error)")
        }
    }

    func appendLocalizationTrace(
        _ update: PriorMapLocalizationUpdate,
        expectedTrackingSessionId: String,
        nodeTimebaseOffsetSeconds: TimeInterval
    ) -> LocalizationWriteResult {
        localizationTransactionLock.lock()
        defer { localizationTransactionLock.unlock() }
        if hasLocalizationRequiredWriteFailure() {
            return LocalizationWriteResult(
                traceWritten: false,
                constraintWritten: false,
                stateWriteRequired: false,
                stateWritten: false,
                failureReasons: [
                    "localization_session": "required_write_health_already_failed"
                ])
        }
        let stateWriteRequired = lastLocalizationState != update.localizationState
        var trace = update
        guard nodeTimebaseOffsetSeconds.isFinite else {
            let failures = [
                "localization_trace.jsonl": "node_timebase_offset_invalid",
                "localization_constraints.jsonl": "node_timebase_offset_invalid",
                "localization_events.jsonl": "node_timebase_offset_invalid",
            ]
            var requiredFailures = failures
            if !stateWriteRequired {
                requiredFailures.removeValue(forKey: "localization_events.jsonl")
            }
            recordLocalizationEvidenceFailures(requiredFailures)
            appendScanEvent(
                level: "error",
                event: "localization_sidecar_write_failed",
                message: "Required localization evidence was not persisted",
                fields: [
                    "failed_files": requiredFailures.keys.sorted().joined(separator: ","),
                    "reason": "node_timebase_offset_invalid",
                ])
            return LocalizationWriteResult(
                traceWritten: false,
                constraintWritten: false,
                stateWriteRequired: stateWriteRequired,
                stateWritten: !stateWriteRequired,
                failureReasons: requiredFailures)
        }
        trace.nodeTimebaseTimestamp = update.timestamp + nodeTimebaseOffsetSeconds
        trace.nodeTimebaseOffsetSeconds = nodeTimebaseOffsetSeconds
        trace.trackingSessionId = expectedTrackingSessionId
        trace.priorMapId = scanConfiguration.priorMapId
        trace.priorMapSha256 = scanConfiguration.priorMapSha256
        trace.floorId = scanConfiguration.floorId
        let constraint = PriorMapConstraintRecord(
            format: "MarketScannerLocalizationConstraint",
            version: 1,
            timestamp: update.timestamp,
            nodeTimebaseTimestamp: update.timestamp + nodeTimebaseOffsetSeconds,
            nodeTimebaseOffsetSeconds: nodeTimebaseOffsetSeconds,
            trackingSessionId: expectedTrackingSessionId,
            priorMapId: scanConfiguration.priorMapId,
            priorMapSha256: scanConfiguration.priorMapSha256,
            floorId: scanConfiguration.floorId,
            accepted: update.constraintAccepted,
            measurementAccepted: update.measurementAccepted,
            correctionStepApplied: update.correctionStepApplied,
            confidenceAccepted: update.confidenceAccepted,
            disposition: update.constraintDisposition,
            reason: update.constraintReason,
            predictedPose: update.rawPose,
            estimatedPose: update.estimatedPose,
            candidates: update.matchCandidates,
            uniqueness: update.matchUniqueness,
            residualCost: update.matchResidualCost,
            effectivePointCount: update.structurePointCount,
            coverageAngleRad: update.structureCoverageAngleRad,
            matcherElapsedMs: update.matcherElapsedMs)
        var stateEvent: PriorMapStateEvent?
        if stateWriteRequired {
            stateEvent = PriorMapStateEvent(
                format: "MarketScannerLocalizationStateEvent",
                version: 1,
                timestamp: update.timestamp,
                nodeTimebaseTimestamp: update.timestamp + nodeTimebaseOffsetSeconds,
                nodeTimebaseOffsetSeconds: nodeTimebaseOffsetSeconds,
                trackingSessionId: expectedTrackingSessionId,
                priorMapId: scanConfiguration.priorMapId,
                priorMapSha256: scanConfiguration.priorMapSha256,
                floorId: scanConfiguration.floorId,
                previousState: lastLocalizationState,
                state: update.localizationState,
                confidence: update.confidence,
                reason: update.constraintReason)
        }
        let result: LocalizationWriteResult
        do {
            let directory = try activeLocalizationDirectory(
                expectedTrackingSessionId: expectedTrackingSessionId)
            let traceRecord = try encodedLocalizationRecord(
                trace,
                fileName: "localization_trace.jsonl",
                directory: directory)
            let constraintRecord = try encodedLocalizationRecord(
                constraint,
                fileName: "localization_constraints.jsonl",
                directory: directory)
            let stateRecord = try stateEvent.map {
                try encodedLocalizationRecord(
                    $0,
                    fileName: "localization_events.jsonl",
                    directory: directory)
            }
            result = LocalizationEvidenceWriteCoordinator.write(
                trace: traceRecord,
                constraint: constraintRecord,
                state: stateRecord,
                writer: sidecarWriter)
        }
        catch {
            var failures = [
                "localization_trace.jsonl": error.localizedDescription,
                "localization_constraints.jsonl": error.localizedDescription,
            ]
            if stateWriteRequired {
                failures["localization_events.jsonl"] = error.localizedDescription
            }
            result = LocalizationWriteResult(
                traceWritten: false,
                constraintWritten: false,
                stateWriteRequired: stateWriteRequired,
                stateWritten: !stateWriteRequired,
                failureReasons: failures)
        }
        if stateWriteRequired && result.stateWritten {
            // The state watermark represents synchronized file evidence, not
            // merely the in-memory localization state.
            lastLocalizationState = update.localizationState
        }
        recordLocalizationEvidenceSuccesses(
            traceWritten: result.traceWritten,
            constraintWritten: result.constraintWritten,
            stateWritten: stateWriteRequired && result.stateWritten)
        if !result.succeeded {
            recordLocalizationEvidenceFailures(result.failureReasons)
            appendScanEvent(
                level: "error",
                event: "localization_sidecar_write_failed",
                message: "Required localization evidence was not persisted",
                fields: [
                    "failed_files": result.failedRequiredFiles.joined(separator: ","),
                    "first_error": result.failedRequiredFiles.first.flatMap {
                        result.failureReasons[$0]
                    } ?? "write_failed",
                ])
        }
        return result
    }

    @discardableResult
    func appendTagObservation(_ observation: PriorMapTagObservationRecord) -> Bool {
        localizationTransactionLock.lock()
        defer { localizationTransactionLock.unlock() }
        guard !hasLocalizationRequiredWriteFailure() else {
            return false
        }
        let result = appendLocalizationRecord(
            observation,
            fileName: "tag_observations.jsonl",
            expectedTrackingSessionId: observation.trackingSessionId)
        if !result.succeeded {
            let failures = [
                "tag_observations.jsonl": result.errorReason ?? "write_failed"
            ]
            recordLocalizationEvidenceFailures(failures)
            appendScanEvent(
                level: "error",
                event: "tag_observation_write_failed",
                message: "Required price-tag observation evidence was not persisted",
                fields: ["reason": failures["tag_observations.jsonl"]!])
        }
        return result.succeeded
    }

    @discardableResult
    func recordLocalizedPriceTag(_ tag: LocalizedPriceTag) -> Bool {
        localizationTransactionLock.lock()
        defer { localizationTransactionLock.unlock() }
        captureLock.lock()
        guard !finalizingScan,
              localizationRequiredWriteFailureCount == 0,
              tag.trackingSessionId == trackingSessionId,
              let root = rootDirectory,
              segmentIndex == 1 else {
            captureLock.unlock()
            return false
        }
        let directory = root.appendingPathComponent(
            "segment_0001",
            isDirectory: true)
        localizedPriceTags.append(tag)
        let snapshot = localizedPriceTags
        captureLock.unlock()
        do {
            guard fileManager.fileExists(atPath: directory.path) else {
                throw NSError(
                    domain: "SupermarketScanSession",
                    code: 20,
                    userInfo: [NSLocalizedDescriptionKey: "The active scan directory no longer exists."])
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(snapshot)
            sidecarWriteLock.lock()
            defer { sidecarWriteLock.unlock() }
            try sidecarWriter.writeAtomic(
                data,
                to: directory.appendingPathComponent("localized_price_tags.json"))
            return true
        }
        catch {
            captureLock.lock()
            localizedPriceTags.removeAll { $0.tagId == tag.tagId }
            captureLock.unlock()
            recordLocalizationEvidenceFailures([
                "localized_price_tags.json": error.localizedDescription
            ])
            appendScanEvent(
                level: "error",
                event: "localized_price_tag_write_failed",
                message: "Required confirmed price-tag state was not persisted",
                fields: ["reason": error.localizedDescription])
            print("Could not persist localized price tag: \(error)")
            return false
        }
    }

    @discardableResult
    func appendManualLocalizationEvent(
        reason: String,
        arkitPose: PriorMapPose2D,
        confirmedMapPose: PriorMapPose2D,
        wallClock: Date,
        frameTimestamp: TimeInterval,
        nodeTimebaseFrameTimestamp: TimeInterval,
        nodeTimebaseOffsetSeconds: TimeInterval,
        nearestNodeId: Int?,
        nearestNodeStamp: TimeInterval?,
        nodeTimeDeltaSeconds: TimeInterval?,
        nodeTimeSnapshotGeneration: UInt64,
        alignmentVersion: Int,
        expectedTrackingSessionId: String
    ) -> Bool {
        localizationTransactionLock.lock()
        defer { localizationTransactionLock.unlock() }
        guard frameTimestamp.isFinite,
              nodeTimebaseFrameTimestamp.isFinite,
              nodeTimebaseOffsetSeconds.isFinite,
              abs(
                frameTimestamp + nodeTimebaseOffsetSeconds
                    - nodeTimebaseFrameTimestamp
              ) <= 0.000_001,
              let nearestNodeId,
              nearestNodeId > 0,
              let nearestNodeStamp,
              nearestNodeStamp.isFinite,
              let nodeTimeDeltaSeconds,
              nodeTimeDeltaSeconds.isFinite,
              nodeTimeDeltaSeconds >= 0,
              nodeTimeDeltaSeconds <= 1.0,
              abs(nodeTimeDeltaSeconds - abs(
                nodeTimebaseFrameTimestamp - nearestNodeStamp)) <= 0.000_001,
              nodeTimeSnapshotGeneration > 0,
              alignmentVersion > 0 else {
            print("Refused to persist an invalid manual localization v3 event")
            let failures = [
                "manual_localization_events.jsonl": "manual_event_validation_failed"
            ]
            recordLocalizationEvidenceFailures(failures)
            appendScanEvent(
                level: "error",
                event: "manual_localization_event_write_failed",
                message: "Manual localization evidence failed validation",
                fields: ["reason": "manual_event_validation_failed"])
            return false
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let event = ManualLocalizationEvent(
            format: "MarketScannerManualLocalizationEvent",
            version: 3,
            wallClockTimestamp: formatter.string(from: wallClock),
            wallClockTimestampUnix: wallClock.timeIntervalSince1970,
            frameTimestamp: frameTimestamp,
            nodeTimebaseFrameTimestamp: nodeTimebaseFrameTimestamp,
            nodeTimebaseOffsetSeconds: nodeTimebaseOffsetSeconds,
            nearestNodeId: nearestNodeId,
            nearestNodeStamp: nearestNodeStamp,
            nodeTimeDeltaSeconds: nodeTimeDeltaSeconds,
            nodeTimeSnapshotGeneration: nodeTimeSnapshotGeneration,
            nodeBindingStatus: "matched",
            nodeBindingReason: "native_atomic_node_time_snapshot",
            alignmentVersion: alignmentVersion,
            trackingSessionId: expectedTrackingSessionId,
            priorMapId: scanConfiguration.priorMapId,
            priorMapSha256: scanConfiguration.priorMapSha256,
            floorId: scanConfiguration.floorId,
            reason: reason,
            arkitPose: arkitPose,
            confirmedMapPose: confirmedMapPose)
        let result = appendLocalizationRecord(
            event,
            fileName: "manual_localization_events.jsonl",
            expectedTrackingSessionId: expectedTrackingSessionId)
        if !result.succeeded {
            let failures = [
                "manual_localization_events.jsonl":
                    result.errorReason ?? "write_failed"
            ]
            recordLocalizationEvidenceFailures(failures)
        }
        return result.succeeded
    }

    /// Persists one terminal Recovery lifecycle record (F-02). Required
    /// evidence: a write failure marks the session processing-ineligible
    /// while the raw database stays saved. Allowed during finalization
    /// because scan-stop teardown must commit the terminal state before the
    /// sidecar snapshot, and identity guards still reject stale generations.
    @discardableResult
    func appendRecoveryLifecycleEvent(
        _ completion: PriorMapRecoveryCompletion,
        expectedTrackingSessionId: String
    ) -> Bool {
        localizationTransactionLock.lock()
        defer { localizationTransactionLock.unlock() }
        guard let priorMapId = scanConfiguration.priorMapId,
              let priorMapSha256 = scanConfiguration.priorMapSha256,
              let floorId = scanConfiguration.floorId,
              completion.episode.startedAtUptime.isFinite,
              completion.finishedAtUptime.isFinite,
              completion.finishedAtUptime
                  >= completion.episode.startedAtUptime,
              !completion.episode.reason.isEmpty,
              !completion.episode.lastTriggerReason.isEmpty,
              completion.episode.triggerCount >= 1 else {
            print("Refused to persist an invalid recovery lifecycle event")
            let failures = [
                PriorMapRecoveryLifecycleRecord.fileName:
                    "recovery_event_validation_failed"
            ]
            recordLocalizationEvidenceFailures(failures)
            appendScanEvent(
                level: "error",
                event: "recovery_lifecycle_event_write_failed",
                message: "Recovery lifecycle evidence failed validation",
                fields: ["reason": "recovery_event_validation_failed"])
            return false
        }
        let record = PriorMapRecoveryLifecycleRecord(
            trackingSessionId: expectedTrackingSessionId,
            priorMapId: priorMapId,
            priorMapSha256: priorMapSha256,
            floorId: floorId,
            completion: completion)
        let result = appendLocalizationRecord(
            record,
            fileName: PriorMapRecoveryLifecycleRecord.fileName,
            expectedTrackingSessionId: expectedTrackingSessionId,
            allowDuringFinalization: true)
        if result.succeeded {
            // Advance the capture watermark only after the durable append is
            // confirmed; finalization validates the sidecar against it.
            captureLock.lock()
            localizationRecoveryEventCount += 1
            localizationLastRecoveryEpisodeId = completion.episode.id
            localizationLastRecoveryFinishedAtUptime =
                completion.finishedAtUptime
            captureLock.unlock()
        }
        if !result.succeeded {
            let failures = [
                PriorMapRecoveryLifecycleRecord.fileName:
                    result.errorReason ?? "write_failed"
            ]
            recordLocalizationEvidenceFailures(failures)
            appendScanEvent(
                level: "error",
                event: "recovery_lifecycle_event_write_failed",
                message: "Required recovery lifecycle evidence was not persisted",
                fields: [
                    "reason":
                        failures[PriorMapRecoveryLifecycleRecord.fileName]!,
                ])
        }
        return result.succeeded
    }

    /// P7R6 idempotence strategy A: stable read of the already-persisted
    /// lifecycle lines, taken before any append so a crash between durable
    /// write and acknowledgement can be detected instead of duplicating the
    /// episode. A missing file means nothing has been persisted yet; a
    /// truncated tail line is returned as-is so the coordinator fails closed.
    func persistedRecoveryLifecycleLines(
        expectedTrackingSessionId: String
    ) throws -> [Data] {
        let directory = try activeLocalizationDirectory(
            expectedTrackingSessionId: expectedTrackingSessionId,
            allowDuringFinalization: true)
        let url = directory.appendingPathComponent(
            PriorMapRecoveryLifecycleRecord.fileName)
        guard fileManager.fileExists(atPath: url.path) else {
            return []
        }
        let snapshot = try SafeSessionPath.readRegularFile(
            url,
            within: directory,
            maximumBytes: 16 * 1024 * 1024)
        var lines: [Data] = []
        var pending = snapshot.data
        while let newline = pending.firstIndex(of: 0x0A) {
            lines.append(pending.subdata(in: pending.startIndex..<newline))
            pending.removeSubrange(pending.startIndex...newline)
        }
        if !pending.isEmpty {
            lines.append(pending)
        }
        return lines
    }

    @discardableResult
    private func appendLocalizationRecord<T: Encodable>(
        _ record: T,
        fileName: String,
        expectedTrackingSessionId: String,
        allowDuringFinalization: Bool = false
    ) -> LocalizationRecordWriteResult {
        let directory: URL
        do {
            directory = try activeLocalizationDirectory(
                expectedTrackingSessionId: expectedTrackingSessionId,
                allowDuringFinalization: allowDuringFinalization)
        }
        catch {
            return LocalizationRecordWriteResult(
                succeeded: false,
                errorReason: error.localizedDescription)
        }
        localizationLogLock.lock()
        defer { localizationLogLock.unlock() }
        do {
            let encoded = try encodedLocalizationRecord(
                record,
                fileName: fileName,
                directory: directory)
            try sidecarWriter.append(encoded.data, to: encoded.url)
            return LocalizationRecordWriteResult(
                succeeded: true,
                errorReason: nil)
        }
        catch {
            print("Could not append localization record: \(error)")
            return LocalizationRecordWriteResult(
                succeeded: false,
                errorReason: error.localizedDescription)
        }
    }

    private func activeLocalizationDirectory(
        expectedTrackingSessionId: String,
        allowDuringFinalization: Bool = false
    ) throws -> URL {
        captureLock.lock()
        guard (allowDuringFinalization || !finalizingScan),
              expectedTrackingSessionId == trackingSessionId,
              let root = rootDirectory,
              segmentIndex == 1 else {
            captureLock.unlock()
            throw NSError(
                domain: "SupermarketScanSession",
                code: 21,
                userInfo: [NSLocalizedDescriptionKey:
                    "session_not_writable_or_identity_mismatch"])
        }
        let directory = root.appendingPathComponent(
            "segment_0001",
            isDirectory: true)
        captureLock.unlock()
        guard fileManager.fileExists(atPath: directory.path) else {
            print("Could not append localization record: active directory is unavailable")
            throw NSError(
                domain: "SupermarketScanSession",
                code: 22,
                userInfo: [NSLocalizedDescriptionKey: "active_directory_unavailable"])
        }
        return directory
    }

    private func encodedLocalizationRecord<T: Encodable>(
        _ record: T,
        fileName: String,
        directory: URL
    ) throws -> EncodedLocalizationSidecarRecord {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(record)
        data.append(0x0A)
        return EncodedLocalizationSidecarRecord(
            fileName: fileName,
            data: data,
            url: directory.appendingPathComponent(fileName))
    }

    private func recordLocalizationEvidenceFailures(
        _ failures: [String: String]
    ) {
        guard !failures.isEmpty else { return }
        captureLock.lock()
        defer { captureLock.unlock() }
        guard scanConfiguration.workflowMode == .priorMapLocalized else {
            return
        }
        localizationRequiredWriteFailureCount += failures.count
        if firstLocalizationRequiredWriteError == nil,
           let firstFile = failures.keys.sorted().first {
            firstLocalizationRequiredWriteError =
                "\(firstFile): \(failures[firstFile] ?? "write_failed")"
        }
    }

    func hasLocalizationRequiredWriteFailure() -> Bool {
        captureLock.lock()
        defer { captureLock.unlock() }
        return scanConfiguration.workflowMode == .priorMapLocalized
            && localizationRequiredWriteFailureCount > 0
    }

    /// P7R6: coordinator-level Recovery persistence failures (unreadable
    /// evidence snapshot, duplicated persisted episodes, byte conflicts,
    /// missing prior-map identity) never reach the writer path, but they
    /// must still mark the session processing-ineligible fail-closed.
    func recordRecoveryPersistenceFailure(_ reason: String) {
        recordLocalizationEvidenceFailures(
            [PriorMapRecoveryLifecycleRecord.fileName: reason])
        appendScanEvent(
            level: "error",
            event: "recovery_lifecycle_event_write_failed",
            message: "Recovery lifecycle persistence transaction failed",
            fields: ["reason": reason])
    }

    private func recordLocalizationEvidenceSuccesses(
        traceWritten: Bool,
        constraintWritten: Bool,
        stateWritten: Bool
    ) {
        captureLock.lock()
        defer { captureLock.unlock() }
        if traceWritten {
            localizationTraceRecordCount += 1
        }
        if constraintWritten {
            localizationConstraintRecordCount += 1
        }
        if stateWritten {
            localizationStateEventCount += 1
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
