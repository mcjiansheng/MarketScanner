//
//  SupermarketScanSession.swift
//  RTABMapApp
//
//  Continuous supermarket capture support: bounded in-memory trajectory
//  summaries, an on-disk RTAB-Map database, health checkpoints and audit logs.
//

import Foundation
import Darwin

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
    /// Formal finalized-session schema identity. Older metadata that lacks
    /// these fields remains readable for diagnostics, but mobile processing
    /// never snapshots or publishes it.
    let format: String?
    let version: Int?
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
    let priorMapCanonicalSourceSha256: String?
    let floorId: String?
    /// Store identity of the scan (B-08): the snapshot eligibility
    /// chain validates it fail-closed against the processing request.
    let storeId: String?
    /// Optional human-readable scan display name chosen at scan start.
    /// Display-only metadata: PC and mobile consumers read it with `.get`
    /// semantics and older sessions simply decode it as nil.
    let scanDisplayName: String?
    let initialMapPose: PriorMapPose2D?
    let localizationTrace: String?
    let manualLocalizationEvents: String?
    let localizationConstraints: String?
    let localizationEvents: String?
    let localizationRecoveryEvents: String?
    let tagObservations: String?
    let localizedPriceTags: String?
    let localizedPriceTagCount: Int?
    /// Clock evidence watermark (V1R4 §7.2): exact counts/watermarks from
    /// the durable `clock_correlations.jsonl` write so processing can
    /// validate the sidecar against the metadata without trusting a
    /// partial write. `clockEvidenceComplete` is true only when the
    /// sidecar holds at least two correlations and two node bindings.
    let clockCorrelationCount: Int?
    let clockNodeBindingCount: Int?
    let clockLastMonotonic: Double?
    let clockLastUTC: Double?
    let clockEvidenceComplete: Bool?
    /// Tag burst evidence watermark (V1R4 §13.1): exact count/last burst ID
    /// from the durable `tag_observation_bursts.jsonl` write so processing
    /// can validate the sidecar against the metadata without trusting a
    /// partial write. `tagObservationBurstComplete` is true only when every
    /// observation ingested before finalization was flushed to a burst
    /// without a write failure; a failure leaves the count short and the
    /// flag false so the PC side blocks processing fail-closed.
    let tagObservationBurstCount: Int?
    let tagObservationBurstLastID: String?
    let tagObservationBurstComplete: Bool?
    /// P1-B manifest-v5 shelf localization evidence declarations and exact
    /// durable watermarks. Legacy metadata decodes nil and remains v1-v4.
    let poseEpochTransitions: String?
    let poseEpochTransitionCount: Int?
    let poseEpochTransitionLastSequence: Int?
    let corridorHypotheses: String?
    let corridorHypothesisCount: Int?
    let corridorHypothesisLastSequence: Int?
    let shelfObservationWindows: String?
    let shelfObservationWindowCount: Int?
    let shelfObservationWindowLastSequence: Int?
    let shelfLoopEvents: String?
    let shelfLoopEventCount: Int?
    let shelfLoopEventLastSequence: Int?
    let shelfLocalizationEvidenceComplete: Bool?
    let shelfLocalizationCalibrationStatus: String?
    /// Bounded scan-performance evidence. Unlike localization evidence, a
    /// telemetry failure does not invalidate finite map/trajectory data; it
    /// closes only the performance-qualified claim. The PC verifies these
    /// watermarks before publishing trends or aggregate statistics.
    let performanceSamples: String?
    let performanceSampleIntervalSeconds: Double?
    let performanceSampleCount: Int?
    let performanceLastSequence: Int?
    let performanceLastTimestampUnix: TimeInterval?
    let performanceEvidenceComplete: Bool?
    let performanceWriteFailureCount: Int?
}

struct ScanPerformanceSampleInput {
    let timestampUnix: TimeInterval
    let processUptimeSeconds: TimeInterval
    let scanState: String
    let trackingState: String
    let nodeCount: Int?
    let databaseMemoryMB: Int?
    let databaseBytes: UInt64?
    let scanStorageBytes: UInt64?
    let processMemoryFootprintMB: Int64?
    let availableMemoryMB: Int64?
    let processCPUTimeSeconds: Double?
    let processCPUPercent: Double?
    let thermalState: String
    let batteryPercent: Double?
    let batteryCharging: Bool?
    let availableDiskBytes: Int64?
    let renderingFPS: Double?
    let rtabmapUpdateTimeMS: Double?
    let wordCount: Int?
    let featureCount: Int?
    let pointCount: Int?
    let polygonCount: Int?
    let onlineLoopClosureCount: Int?
    let reliableLoopClosureCount: Int?
}

struct ShelfLocalizationEvidenceWatermark: Equatable {
    let poseEpochTransitionCount: Int
    let poseEpochTransitionLastSequence: Int?
    let corridorHypothesisCount: Int
    let corridorHypothesisLastSequence: Int?
    let shelfObservationWindowCount: Int
    let shelfObservationWindowLastSequence: Int?
    let shelfLoopEventCount: Int
    let shelfLoopEventLastSequence: Int?
    let writeFailureCount: Int
    let complete: Bool
}

private struct ScanPerformanceSampleRecord: Encodable {
    let format: String
    let version: Int
    let sequence: Int
    let timestampUnix: TimeInterval
    let processUptimeSeconds: TimeInterval
    let trackingSessionID: String
    let scanState: String
    let trackingState: String
    let nodeCount: Int?
    let databaseMemoryMB: Int?
    let databaseBytes: UInt64?
    let scanStorageBytes: UInt64?
    let processMemoryFootprintMB: Int64?
    let availableMemoryMB: Int64?
    let processCPUTimeSeconds: Double?
    let processCPUPercent: Double?
    let thermalState: String
    let batteryPercent: Double?
    let batteryCharging: Bool?
    let availableDiskBytes: Int64?
    let renderingFPS: Double?
    let rtabmapUpdateTimeMS: Double?
    let wordCount: Int?
    let featureCount: Int?
    let pointCount: Int?
    let polygonCount: Int?
    let onlineLoopClosureCount: Int?
    let reliableLoopClosureCount: Int?
    let gpuMetricStatus: String
    let gpuUtilizationPercent: Double?

    enum CodingKeys: String, CodingKey {
        case format
        case version
        case sequence
        case timestampUnix = "timestamp_unix"
        case processUptimeSeconds = "process_uptime_seconds"
        case trackingSessionID = "tracking_session_id"
        case scanState = "scan_state"
        case trackingState = "tracking_state"
        case nodeCount = "node_count"
        case databaseMemoryMB = "database_memory_mb"
        case databaseBytes = "database_bytes"
        case scanStorageBytes = "scan_storage_bytes"
        case processMemoryFootprintMB = "process_memory_footprint_mb"
        case availableMemoryMB = "available_memory_mb"
        case processCPUTimeSeconds = "process_cpu_time_seconds"
        case processCPUPercent = "process_cpu_percent"
        case thermalState = "thermal_state"
        case batteryPercent = "battery_percent"
        case batteryCharging = "battery_charging"
        case availableDiskBytes = "available_disk_bytes"
        case renderingFPS = "rendering_fps"
        case rtabmapUpdateTimeMS = "rtabmap_update_time_ms"
        case wordCount = "word_count"
        case featureCount = "feature_count"
        case pointCount = "point_count"
        case polygonCount = "polygon_count"
        case onlineLoopClosureCount = "online_loop_closure_count"
        case reliableLoopClosureCount = "reliable_loop_closure_count"
        case gpuMetricStatus = "gpu_metric_status"
        case gpuUtilizationPercent = "gpu_utilization_percent"
    }
}

struct PerformanceEvidenceWatermark {
    let sampleCount: Int
    let lastSequence: Int?
    let lastTimestampUnix: TimeInterval?
    let complete: Bool
    let writeFailureCount: Int
}

/// A durable burst of price-tag observations (V1R4 §13.1, V1R5 §5.2):
/// consecutive observations of the same barcode within a bounded time
/// window, written to `tag_observation_bursts.jsonl` as one JSON object
/// per line. Burst v2 stores the exact node binding and quality evidence
/// for every frame; summary fields are redundant audit values that the
/// parser recomputes from `frames`. `frameCount` is the number of UNIQUE
/// frames (V1R5 §5.1 fixes the V1R4 first-frame double count).
struct TagObservationBurstRecord: Codable {
    let format: String
    let version: Int
    let burstId: String
    let sequence: Int
    let barcode: String
    let symbology: String
    let priorMapId: String
    let priorMapSha256: String
    let floorId: String
    let frameCount: Int
    let firstFrameTimestamp: TimeInterval
    let lastFrameTimestamp: TimeInterval
    let boundNodeIdMin: Int64
    let boundNodeIdMax: Int64
    let depthQuality: Double
    let viewAngle: String
    let trackingQuality: String
    let localizationConfidenceMean: Double
    let trackingSessionId: String
    let complete: Bool
    let frames: [TagBurstFrameSample]

    enum CodingKeys: String, CodingKey {
        case format
        case version
        case burstId = "burst_id"
        case sequence
        case barcode
        case symbology
        case priorMapId = "prior_map_id"
        case priorMapSha256 = "prior_map_sha256"
        case floorId = "floor_id"
        case frameCount = "frame_count"
        case firstFrameTimestamp = "first_frame_timestamp"
        case lastFrameTimestamp = "last_frame_timestamp"
        case boundNodeIdMin = "bound_node_id_min"
        case boundNodeIdMax = "bound_node_id_max"
        case depthQuality = "depth_quality"
        case viewAngle = "view_angle"
        case trackingQuality = "tracking_quality"
        case localizationConfidenceMean = "localization_confidence_mean"
        case trackingSessionId = "tracking_session_id"
        case complete
        case frames
    }
}

/// Flush result returned by `flushTagObservationBursts()`: the durable
/// sidecar watermarks and whether the flush completed without write failure.
struct TagObservationBurstFlushResult {
    let count: Int
    let lastBurstID: String?
    let complete: Bool
}

struct TagObservationAppendResult {
    let observation: PriorMapTagObservationRecord
    let burstID: String
    let frameID: String
}

struct TagObservationCaptureCompletionResult {
    let burstID: String
    let frameCount: Int
    let observationIDs: [String]
    let persisted: Bool
    let sufficient: Bool
}

enum PriceTagConfirmationCommitFailure: String, Equatable {
    case finalizationInProgress = "finalization_in_progress"
    case duplicateReservation = "duplicate_reservation"
    case reservationMissing = "reservation_missing"
    case requiredEvidenceFailed = "required_evidence_failed"
    case captureBindingInvalid = "capture_binding_invalid"
    case sessionIdentityMismatch = "session_identity_mismatch"
    case activeSessionUnavailable = "active_session_unavailable"
    case persistenceFailed = "persistence_failed"
}

struct PriceTagConfirmationReservationOutcome: Equatable {
    let reserved: Bool
    let failure: PriceTagConfirmationCommitFailure?
}

struct PriceTagConfirmationCommitOutcome: Equatable {
    let persisted: Bool
    let failure: PriceTagConfirmationCommitFailure?
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

/// V1R4 §13.1 / V1R5 §5.1-§5.2: in-flight aggregation state for one tag
/// observation burst. Mutable and only touched under
/// `localizationTransactionLock`.
///
/// V1R5 fix (review B-01): `frameCount` counts UNIQUE frames only and
/// starts at 0 — `init` consumes the first frame exclusively through
/// `ingest`, so 1 real frame always yields `frameCount == 1` (the V1R4
/// init set `frameCount = 1` AND called `ingest`, double-counting the
/// first frame). A duplicate frame id inside one burst is rejected by
/// `ingest` (it can never increase the frame count); the observation is
/// still durably persisted but is not part of the verified burst and can
/// therefore never reach ACCEPTED on the PC side.
private struct PendingTagBurst {
    let burstId: String
    let sequence: Int
    let barcode: String
    let symbology: String
    let priorMapId: String
    let priorMapSha256: String
    let floorId: String
    let trackingSessionId: String
    var firstFrameTimestamp: TimeInterval
    var lastFrameTimestamp: TimeInterval
    var frameCount: Int
    var frameSamples: [TagBurstFrameSample]

    init(
        burstId: String,
        sequence: Int,
        observation: PriorMapTagObservationRecord,
        boundNodeID: Int64
    ) {
        self.burstId = burstId
        self.sequence = sequence
        self.barcode = observation.payload
        self.symbology = observation.symbology
        self.priorMapId = observation.priorMapId
        self.priorMapSha256 = observation.priorMapSha256
        self.floorId = observation.floorId
        self.trackingSessionId = observation.trackingSessionId
        self.firstFrameTimestamp = observation.frameTimestamp
        self.lastFrameTimestamp = observation.frameTimestamp
        // V1R5 B-01: the burst starts EMPTY; ingest() below counts the
        // first frame exactly once.
        self.frameCount = 0
        self.frameSamples = []
        _ = ingest(observation, boundNodeID: boundNodeID)
    }

    /// True when the observation carries a valid frame identity (both
    /// burst_id and frame_id assigned at persistence time, V1R5 §5.4).
    private static func frameIdentity(_ observation: PriorMapTagObservationRecord)
        -> (burstId: String, frameId: String)? {
        guard let burstId = observation.burstId,
              !burstId.isEmpty,
              let frameId = observation.frameId,
              !frameId.isEmpty else {
            return nil
        }
        return (burstId, frameId)
    }

    /// Ingests one observation. Returns false when the frame identity is
    /// missing or duplicated inside this burst (the observation is then
    /// NOT part of the verified burst; it stays in the observation
    /// sidecar but can never be accepted). All aggregated fields are
    /// updated through this single path (V1R5 §5.1).
    mutating func ingest(
        _ observation: PriorMapTagObservationRecord,
        boundNodeID: Int64
    ) -> Bool {
        guard let identity = Self.frameIdentity(observation),
              identity.burstId == burstId,
              boundNodeID > 0 else {
            return false
        }
        // V1R5 §5.2: frame ids must be unique inside one burst.
        guard !frameSamples.contains(where: { $0.frameId == identity.frameId }) else {
            return false
        }
        let view: String
        if let normal = observation.surfaceNormalCamera,
           normal.count == 3,
           normal.allSatisfy(\.isFinite) {
            if normal[2] < 0 { view = "front" }
            else if normal[2] > 0 { view = "back" }
            else { view = "unknown" }
        } else {
            view = "unknown"
        }
        frameSamples.append(TagBurstFrameSample(
            frameId: identity.frameId,
            observationId: observation.observationId,
            boundNodeId: boundNodeID,
            frameTimestamp: observation.frameTimestamp,
            nodeTimestamp: observation.nodeTimebaseFrameTimestamp,
            depth: observation.depthSampleCount > 0
                ? min(1, max(0, observation.depthInlierRatio)) : 0,
            view: view,
            tracking: observation.localizationState,
            confidence: min(1, max(0, observation.localizationConfidence))))
        frameCount += 1
        lastFrameTimestamp = observation.frameTimestamp
        return true
    }

    func depthQuality() -> Double {
        guard !frameSamples.isEmpty else { return 0 }
        return frameSamples.reduce(0) { $0 + $1.depth }
            / Double(frameSamples.count)
    }

    func dominantLocalizationState() -> String {
        return dominantVote(frameSamples.map(\.tracking))
    }

    func dominantViewAngle() -> String {
        return dominantVote(frameSamples.map(\.view))
    }

    private func dominantVote(_ values: [String]) -> String {
        var counts: [String: Int] = [:]
        values.forEach { counts[$0, default: 0] += 1 }
        guard let maximum = counts.values.max(), maximum > 0 else {
            return "unknown"
        }
        let winners = counts.filter { $0.value == maximum }
        guard winners.count == 1, let winner = winners.first else {
            return "unknown"
        }
        return winner.key
    }

    func record(complete: Bool) -> TagObservationBurstRecord? {
        guard !frameSamples.isEmpty else { return nil }
        let boundNodeIDs = frameSamples.map(\.boundNodeId)
        guard let minimumBoundNodeID = boundNodeIDs.min(),
              let maximumBoundNodeID = boundNodeIDs.max() else {
            return nil
        }
        return TagObservationBurstRecord(
            format: "MarketScannerPriceTagBurst",
            version: 2,
            burstId: burstId,
            sequence: sequence,
            barcode: barcode,
            symbology: symbology,
            priorMapId: priorMapId,
            priorMapSha256: priorMapSha256,
            floorId: floorId,
            frameCount: frameCount,
            firstFrameTimestamp: firstFrameTimestamp,
            lastFrameTimestamp: lastFrameTimestamp,
            boundNodeIdMin: minimumBoundNodeID,
            boundNodeIdMax: maximumBoundNodeID,
            depthQuality: depthQuality(),
            viewAngle: dominantViewAngle(),
            trackingQuality: dominantLocalizationState(),
            localizationConfidenceMean: frameSamples.reduce(0) {
                $0 + $1.confidence
            } / Double(frameSamples.count),
            trackingSessionId: trackingSessionId,
            complete: complete,
            frames: frameSamples)
    }
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
    /// Exact durable row count for `manual_localization_events.jsonl`.
    /// Optional only for decoding pre-contract local metadata; all newly
    /// finalized prior-map sessions write a non-nil value, including zero.
    let manualLocalizationEventCount: Int?
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
    let priorMapCanonicalSourceSha256: String?
    let floorId: String?
    let storeId: String?
    /// Optional human-readable scan display name; nil for older checkpoints
    /// and unnamed scans.
    let scanDisplayName: String?
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
    private let performanceLogLock = NSLock()
    private let localizationLogLock = NSLock()
    private let localizationTransactionLock = NSLock()
    private let localizationAdmissionGate = PriceTagSessionAdmissionGate()
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
    private var manualLocalizationEventCount = 0
    private var localizationStateEventCount = 0
    private var localizationRecoveryEventCount = 0
    private var localizationLastRecoveryEpisodeId: Int?
    private var localizationLastRecoveryFinishedAtUptime: TimeInterval?
    private var poseEpochTransitionCount = 0
    private var corridorHypothesisCount = 0
    private var shelfObservationWindowCount = 0
    private var shelfLoopEventCount = 0
    private var shelfLocalizationEvidenceWriteFailureCount = 0
    private var shelfLocalizationEvidenceSealed = false
    private var latestStructureCoverageSnapshot: ScanStructureCoverageSnapshot?
    private var latestStructureCoverageSummary: ScanStructureCoverageSummary?
    private var performanceSampleCount = 0
    private var performanceLastTimestampUnix: TimeInterval?
    private var performanceBytesWritten = 0
    private var performanceWriteFailureCount = 0
    private var performanceEvidenceSealed = false
    private let maximumTrajectorySamples = 50_000
    private let maximumPerformanceSampleCount =
        GeneratedMobileEvidenceContracts.File_performance_samples_jsonl
            .max_records
    private let maximumPerformanceBytes =
        GeneratedMobileEvidenceContracts.File_performance_samples_jsonl
            .max_file_bytes
    private let maximumPerformanceRecordBytes =
        GeneratedMobileEvidenceContracts.File_performance_samples_jsonl
            .max_record_bytes
    private var nextTagId: Int = 1
    private var lastLocalizationState: String?
    private(set) var scanConfiguration = PriorMapScanConfiguration.freeMapping

    // V1R4 §13.1: in-memory aggregation of consecutive same-barcode
    // observations into durable bursts. All access happens under
    // `localizationTransactionLock` (the same lock guarding
    // `appendTagObservation`), so no separate lock is needed.
    private var pendingTagBurst: PendingTagBurst?
    private var completedTagCaptureFrames: [String: Set<String>] = [:]
    private var completedTagCaptureOrder: [String] = []
    private var tagBurstSequence = 0
    private(set) var tagObservationBurstCount = 0
    private var lastTagObservationBurstID: String?
    private var tagBurstWriteFailureCount = 0
    /// Max wall-clock gap (frame timestamps) between observations that still
    /// merge into one burst (V1R4 §13.1 bounded window).
    private let tagBurstMaxGapSeconds: TimeInterval = 3.0
    /// Upper bound on raw 3D samples retained per burst; the newest samples
    /// are kept.

    var isFinalizingScan: Bool {
        return localizationAdmissionGate.isFinalizing
    }

    /// Foundation-only verification visibility for the finalization drain.
    /// Production code does not use this count for business decisions.
    var activeLocalizationTransactionCount: Int {
        return localizationAdmissionGate.activeTransactionCount
    }

    /// Closes ordinary localization/tag write admission with a short
    /// condition lock. It never waits for the serialized writer or performs
    /// file I/O, so callers may invoke it from the main thread.
    @discardableResult
    func beginFinalization() -> Bool {
        return localizationAdmissionGate.beginFinalization()
    }

    func endFinalization() {
        localizationAdmissionGate.endFinalization()
    }

    /// Waits for every transaction admitted before `beginFinalization()` and
    /// every confirmation reserved before that linearization point. Call only
    /// on a background queue; new ordinary writes are rejected meanwhile.
    func waitForFinalizationTransactionDrain() {
        localizationAdmissionGate.waitForFinalizationDrain()
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
        guard localizationAdmissionGate.beginTransaction() == nil else {
            return
        }
        defer { localizationAdmissionGate.endTransaction() }
        localizationTransactionLock.lock()
        defer { localizationTransactionLock.unlock() }
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
        guard localizationAdmissionGate.beginTransaction(
                allowDuringFinalization: true) == nil else {
            return
        }
        defer { localizationAdmissionGate.endTransaction() }
        localizationTransactionLock.lock()
        defer { localizationTransactionLock.unlock() }
        captureLock.lock()
        defer { captureLock.unlock() }
        rootDirectory = nil
        segmentIndex = 0
        nextTagId = 1
        scanConfiguration = .freeMapping
        resetCurrentSegmentLocked()
    }

    func resetCurrentSegment() {
        // Match the production write order (localization transaction before
        // capture state) so a session reset cannot deadlock with a localized
        // tag commit or leave burst watermarks from the previous scan.
        guard localizationAdmissionGate.beginTransaction() == nil else {
            return
        }
        defer { localizationAdmissionGate.endTransaction() }
        localizationTransactionLock.lock()
        defer { localizationTransactionLock.unlock() }
        captureLock.lock()
        defer { captureLock.unlock() }
        resetCurrentSegmentLocked()
    }

    private func resetCurrentSegmentLocked() {
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
        manualLocalizationEventCount = 0
        localizationStateEventCount = 0
        localizationRecoveryEventCount = 0
        localizationLastRecoveryEpisodeId = nil
        localizationLastRecoveryFinishedAtUptime = nil
        poseEpochTransitionCount = 0
        corridorHypothesisCount = 0
        shelfObservationWindowCount = 0
        shelfLoopEventCount = 0
        shelfLocalizationEvidenceWriteFailureCount = 0
        shelfLocalizationEvidenceSealed = false
        latestStructureCoverageSnapshot = nil
        latestStructureCoverageSummary = nil
        performanceLogLock.lock()
        performanceSampleCount = 0
        performanceLastTimestampUnix = nil
        performanceBytesWritten = 0
        performanceWriteFailureCount = 0
        performanceEvidenceSealed = false
        performanceLogLock.unlock()
        pendingTagBurst = nil
        completedTagCaptureFrames.removeAll()
        completedTagCaptureOrder.removeAll()
        tagBurstSequence = 0
        tagObservationBurstCount = 0
        lastTagObservationBurstID = nil
        tagBurstWriteFailureCount = 0
    }

    func currentSegmentDirectory() throws -> URL {
        try startNewSessionIfNeeded()
        guard let rootDirectory else {
            throw NSError(
                domain: "SupermarketScanSession",
                code: 60,
                userInfo: [NSLocalizedDescriptionKey:
                    "The scan session directory was not created."])
        }
        let dir = rootDirectory.appendingPathComponent(
            String(format: "segment_%04d", segmentIndex),
            isDirectory: true)
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
        return try Self.exportFinalizedCapture(
            from: localCaptureDirectory,
            localDocumentsDirectory: documentsDirectory,
            destinationBaseDirectory: exportBaseDirectory,
            expectedTrackingSessionID: trackingSessionId,
            sidecarWriter: sidecarWriter)
    }

    /// Exports a finalized historical scan without requiring the session to
    /// remain the active in-memory `SupermarketScanSession`. This is also the
    /// shared implementation used by scan-finalization background copies.
    ///
    /// The source remains on device. The method independently revalidates the
    /// finalized identity, rejects live/multi-segment/symlink/hardlink input,
    /// copies into a collision-free package directory, and compares SHA-256
    /// manifests before and after the provider copy. Call from a background
    /// queue after obtaining security-scoped access to the destination.
    @discardableResult
    static func exportFinalizedCapture(
        from localCaptureDirectory: URL,
        localDocumentsDirectory: URL,
        destinationBaseDirectory: URL,
        expectedTrackingSessionID: String,
        sidecarWriter: ScanSidecarFileWriting = FoundationScanSidecarWriter(),
        progress: ((Double, String) -> Void)? = nil
    ) throws -> URL {
        let fileManager = FileManager.default
        let sessionDirectory = localCaptureDirectory.deletingLastPathComponent()
        let sessionDirectoryName = sessionDirectory.lastPathComponent
        progress?(0.04, "正在校验历史扫描身份…")

        guard sessionDirectoryName.hasPrefix("SupermarketSession-"),
              localCaptureDirectory.lastPathComponent == "segment_0001",
              sessionDirectory.deletingLastPathComponent().standardizedFileURL
                == localDocumentsDirectory.standardizedFileURL,
              localCaptureDirectory.deletingLastPathComponent().standardizedFileURL
                == sessionDirectory.standardizedFileURL,
              !expectedTrackingSessionID.isEmpty else {
            throw NSError(
                domain: "SupermarketScanSession",
                code: 50,
                userInfo: [NSLocalizedDescriptionKey:
                    "Refused to export a scan outside the finalized local-session layout."])
        }
        try SafeSessionPath.validateDirectory(
            sessionDirectory,
            within: localDocumentsDirectory)
        try SafeSessionPath.validateDirectory(
            localCaptureDirectory,
            within: sessionDirectory)
        let segmentNames = try fileManager.contentsOfDirectory(
            at: sessionDirectory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles])
            .filter { $0.lastPathComponent.hasPrefix("segment_") }
            .map(\.lastPathComponent)
            .sorted()
        guard segmentNames == ["segment_0001"] else {
            throw NSError(
                domain: "SupermarketScanSession",
                code: 51,
                userInfo: [NSLocalizedDescriptionKey:
                    "Only one finalized continuous segment can be exported automatically."])
        }

        let metadataURL = localCaptureDirectory.appendingPathComponent(
            "metadata.json")
        let metadataSnapshot = try SafeSessionPath.readRegularFile(
            metadataURL,
            within: sessionDirectory,
            maximumBytes: 1024 * 1024)
        let metadata = try StrictJSONDocumentParser.object(
            from: metadataSnapshot.data,
            limits: StrictJSONDocumentLimits(
                maximumBytes: metadataSnapshot.data.count + 1))
        guard metadata["finalized"] as? Bool == true,
              metadata["scanMode"] as? String == "continuous_streaming",
              metadata["trackingSessionId"] as? String
                == expectedTrackingSessionID else {
            throw NSError(
                domain: "SupermarketScanSession",
                code: 52,
                userInfo: [NSLocalizedDescriptionKey:
                    "The historical scan is not finalized or its tracking identity changed."])
        }
        guard !fileManager.fileExists(atPath: localCaptureDirectory
                .appendingPathComponent("live_checkpoint.json").path) else {
            throw NSError(
                domain: "SupermarketScanSession",
                code: 53,
                userInfo: [NSLocalizedDescriptionKey:
                    "The scan still has a live checkpoint and cannot be exported as finalized."])
        }
        let databaseURL = localCaptureDirectory.appendingPathComponent(
            "rtabmap_segment_0001.db")
        var databaseMetadata = stat()
        guard lstat(databaseURL.path, &databaseMetadata) == 0,
              (databaseMetadata.st_mode & S_IFMT) == S_IFREG,
              databaseMetadata.st_nlink == 1 else {
            throw NSError(
                domain: "SupermarketScanSession",
                code: 54,
                userInfo: [NSLocalizedDescriptionKey:
                    "The finalized scan database is missing, linked, or unsafe to export."])
        }

        let destinationValues = try destinationBaseDirectory.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard destinationValues.isDirectory == true,
              destinationValues.isSymbolicLink != true else {
            throw NSError(
                domain: "SupermarketScanSession",
                code: 55,
                userInfo: [NSLocalizedDescriptionKey:
                    "The selected export destination is not a real directory."])
        }

        progress?(0.12, "正在计算原始扫描校验清单…")
        let localManifestBeforeCopy = try CaptureDirectoryIntegrity.manifest(
            for: localCaptureDirectory,
            fileManager: fileManager)
        guard !localManifestBeforeCopy.isEmpty else {
            throw NSError(
                domain: "SupermarketScanSession",
                code: 56,
                userInfo: [NSLocalizedDescriptionKey:
                    "The finalized scan contains no exportable files."])
        }

        let exportRoot = uniqueExternalExportRoot(
            baseDirectory: destinationBaseDirectory,
            sessionDirectoryName: sessionDirectoryName,
            fileManager: fileManager)
        let exportCapture = exportRoot.appendingPathComponent(
            localCaptureDirectory.lastPathComponent,
            isDirectory: true)
        var exportRootCreated = false
        do {
            progress?(0.28, "正在复制完整原始扫描…")
            try fileManager.createDirectory(
                at: exportRoot,
                withIntermediateDirectories: false)
            exportRootCreated = true
            try fileManager.copyItem(
                at: localCaptureDirectory,
                to: exportCapture)

            progress?(0.74, "正在复核导出文件 SHA-256…")
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
                    userInfo: [NSLocalizedDescriptionKey: NSLocalizedString(
                        "External copy SHA-256 verification failed or the source changed during copying. The local scan was kept.",
                        comment: "Scan copy verification error")])
            }

            progress?(0.90, "正在写入导出验证凭证…")
            let packageId = UUID().uuidString.lowercased()
            let packageContentSha256 = try CaptureDirectoryIntegrity
                .manifestSHA256(exportManifest)
            let receipt = ExternalCopyVerificationReceipt(
                format: "MarketScannerExternalCopyVerification",
                version: 2,
                packageId: packageId,
                sessionId: expectedTrackingSessionID,
                verifiedAtUnix: Date().timeIntervalSince1970,
                providerDisplayName: destinationBaseDirectory.lastPathComponent,
                sourceRelativePath:
                    "\(sessionDirectoryName)/\(localCaptureDirectory.lastPathComponent)",
                destinationRelativePath:
                    "\(exportRoot.lastPathComponent)/\(exportCapture.lastPathComponent)",
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
            let receiptAndCaptureManifest = try CaptureDirectoryIntegrity
                .manifest(for: exportRoot, fileManager: fileManager)
            let packageManifest = ExternalCopyPackageManifest(
                format: "MarketScannerExternalCopyPackageManifest",
                version: 1,
                packageId: packageId,
                sessionId: expectedTrackingSessionID,
                providerDisplayName: destinationBaseDirectory.lastPathComponent,
                packageContentSha256: try CaptureDirectoryIntegrity
                    .manifestSHA256(receiptAndCaptureManifest),
                files: receiptAndCaptureManifest,
                localCopyRetained: true,
                durabilityQualificationStatus: "not_executed",
                durabilityExperimentHook:
                    "reconnect_or_power_cycle_provider_then_rehash_manifest_on_real_device")
            try sidecarWriter.writeAtomic(
                try encoder.encode(packageManifest),
                to: exportRoot.appendingPathComponent(
                    "copy_package_manifest.json"))
            progress?(1.0, "原始历史扫描已导出并通过校验")
            exportRootCreated = false
            return exportCapture
        } catch {
            if exportRootCreated {
                try? fileManager.removeItem(at: exportRoot)
            }
            throw error
        }
    }

    private static func uniqueExternalExportRoot(
        baseDirectory: URL,
        sessionDirectoryName: String,
        fileManager: FileManager
    ) -> URL {
        let preferred = baseDirectory.appendingPathComponent(
            sessionDirectoryName,
            isDirectory: true)
        guard fileManager.fileExists(atPath: preferred.path) else {
            return preferred
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let baseName = sessionDirectoryName + "-Export-"
            + formatter.string(from: Date())
        var candidate = baseDirectory.appendingPathComponent(
            baseName,
            isDirectory: true)
        var index = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = baseDirectory.appendingPathComponent(
                "\(baseName)-\(index)",
                isDirectory: true)
            index += 1
        }
        return candidate
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

    func updateSensorPose(
        timestamp: TimeInterval,
        matrixColumnMajor: [Float],
        trackingState: String,
        acceptedForLocation: Bool = true
    ) {
        guard matrixColumnMajor.count == 16 else {
            return
        }
        captureLock.lock()
        defer { captureLock.unlock() }
        let pose = ScanSensorPose(
            timestamp: timestamp,
            matrixColumnMajor: matrixColumnMajor,
            trackingState: trackingState)
        // Tracking-health counters include every callback, but location
        // boundary poses must come only from the same continuity-gated pose
        // authority used by RTAB-Map/prior-map/ESL. A rejected raw ARKit frame
        // is therefore counted without becoming a location sidecar value.
        if acceptedForLocation {
            if sensorStartPose == nil {
                sensorStartPose = pose
            }
            sensorEndPose = pose
        }
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
            case "tracking_recovery_epoch_rebase":
                trackingRecoveryRejectedFrameCount += 1
                poseDiscontinuityCompensationCount += 1
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
            priorMapCanonicalSourceSha256:
                scanConfiguration.priorMapCanonicalSourceSha256,
            floorId: scanConfiguration.floorId,
            storeId: scanConfiguration.storeID,
            scanDisplayName: scanConfiguration.scanDisplayName,
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
            manualLocalizationEventCount: manualLocalizationEventCount,
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

        // Performance evidence is observability, not coordinate authority.
        // Keep the declared file present even when the first write failed so
        // the false watermark is auditable instead of looking like an export
        // omission. The PC will not qualify an empty/incomplete stream.
        if snapshot.metadata.performanceSamples == "performance_samples.jsonl" {
            let performanceURL = segmentDirectory.appendingPathComponent(
                "performance_samples.jsonl")
            if !sidecarWriter.fileExists(at: performanceURL),
               snapshot.metadata.performanceSampleCount == 0 {
                try sidecarWriter.writeAtomic(Data(), to: performanceURL)
            }
        }

        // Expected recovery watermark for this finalization. A legacy
        // checkpoint without the P7R6 watermark fields decodes nil and falls
        // back to the legacy zero expectation.
        let expectedRecoveryEventCount =
            snapshot.metadata.captureHealth?.localizationRecoveryEventCount ?? 0
        let expectedManualEventCount =
            snapshot.metadata.captureHealth?.manualLocalizationEventCount ?? 0
        if scanConfiguration.workflowMode == .priorMapLocalized {
            for fileName in ["tag_observations.jsonl"] {
                let url = segmentDirectory.appendingPathComponent(fileName)
                if !sidecarWriter.fileExists(at: url) {
                    try sidecarWriter.writeAtomic(Data(), to: url)
                }
            }
            let manualURL = segmentDirectory.appendingPathComponent(
                "manual_localization_events.jsonl")
            if !sidecarWriter.fileExists(at: manualURL),
               expectedManualEventCount == 0 {
                try sidecarWriter.writeAtomic(Data(), to: manualURL)
            }
            // V1R4 §13.1: a burst sidecar is required for processing. An
            // empty file is only created when no burst is expected; a
            // missing file with a positive watermark is a blocker and stays
            // missing for the validator.
            let expectedBurstCount =
                snapshot.metadata.tagObservationBurstCount ?? 0
            let burstsURL = segmentDirectory.appendingPathComponent(
                "tag_observation_bursts.jsonl")
            if !sidecarWriter.fileExists(at: burstsURL) {
                if expectedBurstCount == 0 {
                    try sidecarWriter.writeAtomic(Data(), to: burstsURL)
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
                if expectedManualEventCount > 0,
                   !sidecarWriter.fileExists(at: segmentDirectory
                    .appendingPathComponent(
                        "manual_localization_events.jsonl")) {
                    evidenceValidationBlockers.append(
                        "evidence_bundle_manual_file_missing_blocker")
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
                            manualLocalizationEventCount:
                                captureHealth.manualLocalizationEventCount ?? 0,
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
                                    .localizationLastRecoveryFinishedAtUptime,
                            // V1R4 §13.1: exact tag burst watermarks; a
                            // short count, a mismatched last ID, or a failed
                            // flush blocks finalization fail-closed.
                            tagBurstCount:
                                committedMetadata.tagObservationBurstCount ?? 0,
                            tagBurstLastID:
                                committedMetadata.tagObservationBurstLastID,
                            tagBurstComplete:
                                committedMetadata.tagObservationBurstComplete ?? false,
                            requiresShelfEpochComponent:
                                committedMetadata
                                    .shelfLocalizationEvidenceComplete == true))
                if committedMetadata.shelfLocalizationEvidenceComplete == true,
                   let poseCount = committedMetadata.poseEpochTransitionCount,
                   let corridorCount = committedMetadata.corridorHypothesisCount,
                   let windowCount = committedMetadata.shelfObservationWindowCount,
                   let loopCount = committedMetadata.shelfLoopEventCount {
                    do {
                        _ = try ShelfLocalizationEvidenceParser.validateBundle(
                            directory: segmentDirectory,
                            trackingSessionID: trackingSessionId,
                            poseEpochTransitionCount: poseCount,
                            corridorHypothesisCount: corridorCount,
                            shelfObservationWindowCount: windowCount,
                            shelfLoopEventCount: loopCount)
                    } catch {
                        evidenceValidationBlockers.append(
                            "shelf_localization_evidence_invalid:\(error.localizedDescription)")
                    }
                } else {
                    evidenceValidationBlockers.append(
                        "shelf_localization_evidence_watermark_missing")
                }
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

        _ = appendScanEvent(
            level: level,
            event: event,
            message: message,
            fields: fields,
            directory: directory,
            trackingSessionId: trackingSessionId)
    }

    /// Appends one durable, bounded performance sample. The caller rate-limits
    /// normal samples; this writer enforces identity, finite values, sequence,
    /// strictly increasing wall time, file/sample bounds and a sticky failure
    /// watermark. Whole-device GPU utilization is deliberately unavailable:
    /// iOS exposes no general public API for that metric.
    @discardableResult
    func appendPerformanceSample(
        _ input: ScanPerformanceSampleInput,
        sealAfterAppend: Bool = false
    ) -> Bool {
        guard input.timestampUnix.isFinite,
              input.timestampUnix > 0,
              input.processUptimeSeconds.isFinite,
              input.processUptimeSeconds >= 0,
              !input.scanState.isEmpty,
              !input.trackingState.isEmpty,
              !input.thermalState.isEmpty,
              performanceInputIsFinite(input) else {
            recordPerformanceWriteFailure(seal: sealAfterAppend)
            return false
        }
        let directory: URL
        do {
            directory = try currentSegmentDirectory()
        } catch {
            recordPerformanceWriteFailure(seal: sealAfterAppend)
            return false
        }

        performanceLogLock.lock()
        defer {
            if sealAfterAppend {
                performanceEvidenceSealed = true
            }
            performanceLogLock.unlock()
        }
        // A callback racing after the finalizing sample is expected to be
        // ignored. It must not mutate the terminal watermark or manufacture a
        // write failure after the evidence stream has been sealed.
        guard !performanceEvidenceSealed else {
            return true
        }
        guard performanceSampleCount < maximumPerformanceSampleCount,
              performanceLastTimestampUnix.map({ input.timestampUnix > $0 }) ?? true else {
            performanceWriteFailureCount += 1
            return false
        }
        let sequence = performanceSampleCount + 1
        let record = ScanPerformanceSampleRecord(
            format: "MarketScannerPerformanceSample",
            version: 1,
            sequence: sequence,
            timestampUnix: input.timestampUnix,
            processUptimeSeconds: input.processUptimeSeconds,
            trackingSessionID: trackingSessionId,
            scanState: input.scanState,
            trackingState: input.trackingState,
            nodeCount: input.nodeCount,
            databaseMemoryMB: input.databaseMemoryMB,
            databaseBytes: input.databaseBytes,
            scanStorageBytes: input.scanStorageBytes,
            processMemoryFootprintMB: input.processMemoryFootprintMB,
            availableMemoryMB: input.availableMemoryMB,
            processCPUTimeSeconds: input.processCPUTimeSeconds,
            processCPUPercent: input.processCPUPercent,
            thermalState: input.thermalState,
            batteryPercent: input.batteryPercent,
            batteryCharging: input.batteryCharging,
            availableDiskBytes: input.availableDiskBytes,
            renderingFPS: input.renderingFPS,
            rtabmapUpdateTimeMS: input.rtabmapUpdateTimeMS,
            wordCount: input.wordCount,
            featureCount: input.featureCount,
            pointCount: input.pointCount,
            polygonCount: input.polygonCount,
            onlineLoopClosureCount: input.onlineLoopClosureCount,
            reliableLoopClosureCount: input.reliableLoopClosureCount,
            gpuMetricStatus: "not_available_public_ios_api",
            gpuUtilizationPercent: nil)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            var data = try encoder.encode(record)
            data.append(0x0A)
            guard data.count <= maximumPerformanceRecordBytes,
                  data.count <= maximumPerformanceBytes - performanceBytesWritten else {
                performanceWriteFailureCount += 1
                return false
            }
            try sidecarWriter.append(
                data,
                to: directory.appendingPathComponent("performance_samples.jsonl"))
            performanceSampleCount = sequence
            performanceLastTimestampUnix = input.timestampUnix
            performanceBytesWritten += data.count
            return true
        } catch {
            performanceWriteFailureCount += 1
            print("Could not append performance sample: \(error)")
            return false
        }
    }

    func performanceEvidenceWatermark() -> PerformanceEvidenceWatermark {
        performanceLogLock.lock()
        defer { performanceLogLock.unlock() }
        return PerformanceEvidenceWatermark(
            sampleCount: performanceSampleCount,
            lastSequence: performanceSampleCount > 0 ? performanceSampleCount : nil,
            lastTimestampUnix: performanceLastTimestampUnix,
            complete: performanceSampleCount > 0
                && performanceEvidenceSealed
                && performanceWriteFailureCount == 0,
            writeFailureCount: performanceWriteFailureCount)
    }

    private func recordPerformanceWriteFailure(seal: Bool) {
        performanceLogLock.lock()
        performanceWriteFailureCount += 1
        if seal {
            performanceEvidenceSealed = true
        }
        performanceLogLock.unlock()
    }

    private func performanceInputIsFinite(
        _ input: ScanPerformanceSampleInput
    ) -> Bool {
        let optionalDoubles = [
            input.processCPUTimeSeconds,
            input.processCPUPercent,
            input.batteryPercent,
            input.renderingFPS,
            input.rtabmapUpdateTimeMS,
        ]
        guard optionalDoubles.allSatisfy({ $0.map { $0.isFinite && $0 >= 0 } ?? true }) else {
            return false
        }
        let optionalIntegers: [Int64?] = [
            input.nodeCount.map(Int64.init),
            input.databaseMemoryMB.map(Int64.init),
            input.processMemoryFootprintMB,
            input.availableMemoryMB,
            input.availableDiskBytes,
            input.wordCount.map(Int64.init),
            input.featureCount.map(Int64.init),
            input.pointCount.map(Int64.init),
            input.polygonCount.map(Int64.init),
            input.onlineLoopClosureCount.map(Int64.init),
            input.reliableLoopClosureCount.map(Int64.init),
        ]
        return optionalIntegers.allSatisfy { $0.map { $0 >= 0 } ?? true }
    }

    /// Appends a late/asynchronous audit record only when the exact scan is
    /// still active. Unlike appendScanEvent(), this method never creates a
    /// session directory. Its admission is included in the finalization drain,
    /// so an audit admitted before finalization finishes before snapshotting;
    /// one arriving after admission closes is rejected without mutating a
    /// finalized package or creating an empty successor session. The explicit
    /// override is reserved for finalization-owned scan-stop audit records.
    @discardableResult
    func appendScanEventIfSessionActive(
        expectedTrackingSessionId: String,
        allowDuringFinalization: Bool = false,
        level: String = "info",
        event: String,
        message: String,
        fields: [String: String] = [:]
    ) -> Bool {
        guard localizationAdmissionGate.beginTransaction(
                allowDuringFinalization: allowDuringFinalization) == nil else {
            return false
        }
        defer { localizationAdmissionGate.endTransaction() }

        captureLock.lock()
        guard !expectedTrackingSessionId.isEmpty,
              expectedTrackingSessionId == trackingSessionId,
              let root = rootDirectory,
              segmentIndex == 1 else {
            captureLock.unlock()
            return false
        }
        let directory = root.appendingPathComponent(
            "segment_0001",
            isDirectory: true)
        let recordTrackingSessionId = trackingSessionId
        captureLock.unlock()
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(
                atPath: directory.path,
                isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return false
        }
        return appendScanEvent(
            level: level,
            event: event,
            message: message,
            fields: fields,
            directory: directory,
            trackingSessionId: recordTrackingSessionId)
    }

    @discardableResult
    private func appendScanEvent(
        level: String,
        event: String,
        message: String,
        fields: [String: String],
        directory: URL,
        trackingSessionId: String
    ) -> Bool {

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
            return true
        }
        catch {
            print("Could not append scan event log: \(error)")
            return false
        }
    }

    @discardableResult
    func appendPoseEpochTransition(
        _ record: PoseEpochTransitionRecord,
        expectedTrackingSessionId: String
    ) -> Bool {
        appendShelfLocalizationEvidence(
            record,
            fileName: PoseEpochTransitionRecord.fileName,
            expectedTrackingSessionId: expectedTrackingSessionId,
            sequence: record.sequence,
            valid: record.isValid,
            counter: .poseEpochTransition)
    }

    @discardableResult
    func appendCorridorHypotheses(
        _ record: CorridorHypothesesRecord,
        expectedTrackingSessionId: String
    ) -> Bool {
        appendShelfLocalizationEvidence(
            record,
            fileName: CorridorHypothesesRecord.fileName,
            expectedTrackingSessionId: expectedTrackingSessionId,
            sequence: record.sequence,
            valid: record.isValid,
            counter: .corridorHypothesis)
    }

    @discardableResult
    func appendShelfObservationWindow(
        _ record: ShelfObservationWindowRecord,
        expectedTrackingSessionId: String
    ) -> Bool {
        appendShelfLocalizationEvidence(
            record,
            fileName: ShelfObservationWindowRecord.fileName,
            expectedTrackingSessionId: expectedTrackingSessionId,
            sequence: record.sequence,
            valid: record.isValid,
            counter: .shelfObservationWindow)
    }

    @discardableResult
    func appendShelfLoopEvent(
        _ record: ShelfLoopEventRecord,
        expectedTrackingSessionId: String
    ) -> Bool {
        appendShelfLocalizationEvidence(
            record,
            fileName: ShelfLoopEventRecord.fileName,
            expectedTrackingSessionId: expectedTrackingSessionId,
            sequence: record.sequence,
            valid: record.isValid,
            counter: .shelfLoopEvent)
    }

    private enum ShelfEvidenceCounter {
        case poseEpochTransition
        case corridorHypothesis
        case shelfObservationWindow
        case shelfLoopEvent
    }

    private func shelfEvidenceCountLocked(_ counter: ShelfEvidenceCounter) -> Int {
        switch counter {
        case .poseEpochTransition: return poseEpochTransitionCount
        case .corridorHypothesis: return corridorHypothesisCount
        case .shelfObservationWindow: return shelfObservationWindowCount
        case .shelfLoopEvent: return shelfLoopEventCount
        }
    }

    private func incrementShelfEvidenceCountLocked(_ counter: ShelfEvidenceCounter) {
        switch counter {
        case .poseEpochTransition: poseEpochTransitionCount += 1
        case .corridorHypothesis: corridorHypothesisCount += 1
        case .shelfObservationWindow: shelfObservationWindowCount += 1
        case .shelfLoopEvent: shelfLoopEventCount += 1
        }
    }

    private func appendShelfLocalizationEvidence<T: Encodable>(
        _ record: T,
        fileName: String,
        expectedTrackingSessionId: String,
        sequence: Int,
        valid: Bool,
        counter: ShelfEvidenceCounter
    ) -> Bool {
        guard localizationAdmissionGate.beginTransaction() == nil else {
            return false
        }
        defer { localizationAdmissionGate.endTransaction() }
        localizationTransactionLock.lock()
        defer { localizationTransactionLock.unlock() }
        captureLock.lock()
        let expectedSequence = shelfEvidenceCountLocked(counter) + 1
        let identityValid = expectedTrackingSessionId == trackingSessionId
        let writable = !shelfLocalizationEvidenceSealed
        captureLock.unlock()
        guard valid, identityValid, writable, sequence == expectedSequence else {
            captureLock.lock()
            shelfLocalizationEvidenceWriteFailureCount += 1
            captureLock.unlock()
            recordLocalizationEvidenceFailures([
                fileName: "invalid_identity_sequence_or_schema"
            ])
            return false
        }
        let result = appendLocalizationRecord(
            record,
            fileName: fileName,
            expectedTrackingSessionId: expectedTrackingSessionId)
        captureLock.lock()
        if result.succeeded {
            incrementShelfEvidenceCountLocked(counter)
        } else {
            shelfLocalizationEvidenceWriteFailureCount += 1
        }
        captureLock.unlock()
        if !result.succeeded {
            recordLocalizationEvidenceFailures([
                fileName: result.errorReason ?? "write_failed"
            ])
        }
        return result.succeeded
    }

    /// Makes all four v5 files explicit, including valid zero-record streams,
    /// then freezes their exact count/sequence watermarks for metadata.
    func sealShelfLocalizationEvidence(
        expectedTrackingSessionId: String,
        allowDuringFinalization: Bool = false
    ) -> ShelfLocalizationEvidenceWatermark {
        guard localizationAdmissionGate.beginTransaction(
                allowDuringFinalization: allowDuringFinalization) == nil else {
            captureLock.lock()
            shelfLocalizationEvidenceWriteFailureCount += 1
            let watermark = shelfLocalizationEvidenceWatermarkLocked(complete: false)
            captureLock.unlock()
            return watermark
        }
        defer { localizationAdmissionGate.endTransaction() }
        localizationTransactionLock.lock()
        defer { localizationTransactionLock.unlock() }
        var failed = false
        do {
            let directory = try activeLocalizationDirectory(
                expectedTrackingSessionId: expectedTrackingSessionId,
                allowDuringFinalization: allowDuringFinalization)
            for fileName in [
                PoseEpochTransitionRecord.fileName,
                CorridorHypothesesRecord.fileName,
                ShelfObservationWindowRecord.fileName,
                ShelfLoopEventRecord.fileName,
            ] {
                let url = directory.appendingPathComponent(fileName)
                if !fileManager.fileExists(atPath: url.path) {
                    try sidecarWriter.writeAtomic(Data(), to: url)
                }
            }
        } catch {
            failed = true
            recordLocalizationEvidenceFailures([
                "shelf_localization_evidence": error.localizedDescription
            ])
        }
        captureLock.lock()
        if failed { shelfLocalizationEvidenceWriteFailureCount += 1 }
        shelfLocalizationEvidenceSealed = !failed
        let watermark = shelfLocalizationEvidenceWatermarkLocked(
            complete: !failed && shelfLocalizationEvidenceWriteFailureCount == 0)
        captureLock.unlock()
        return watermark
    }

    private func shelfLocalizationEvidenceWatermarkLocked(
        complete: Bool
    ) -> ShelfLocalizationEvidenceWatermark {
        ShelfLocalizationEvidenceWatermark(
            poseEpochTransitionCount: poseEpochTransitionCount,
            poseEpochTransitionLastSequence: poseEpochTransitionCount > 0
                ? poseEpochTransitionCount : nil,
            corridorHypothesisCount: corridorHypothesisCount,
            corridorHypothesisLastSequence: corridorHypothesisCount > 0
                ? corridorHypothesisCount : nil,
            shelfObservationWindowCount: shelfObservationWindowCount,
            shelfObservationWindowLastSequence: shelfObservationWindowCount > 0
                ? shelfObservationWindowCount : nil,
            shelfLoopEventCount: shelfLoopEventCount,
            shelfLoopEventLastSequence: shelfLoopEventCount > 0
                ? shelfLoopEventCount : nil,
            writeFailureCount: shelfLocalizationEvidenceWriteFailureCount,
            complete: complete)
    }

    func appendLocalizationTrace(
        _ update: PriorMapLocalizationUpdate,
        expectedTrackingSessionId: String,
        nodeTimebaseOffsetSeconds: TimeInterval
    ) -> LocalizationWriteResult {
        guard localizationAdmissionGate.beginTransaction() == nil else {
            return LocalizationWriteResult(
                traceWritten: false,
                constraintWritten: false,
                stateWriteRequired: false,
                stateWritten: false,
                failureReasons: [
                    "localization_session": "finalization_in_progress"
                ])
        }
        defer { localizationAdmissionGate.endTransaction() }
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
    func appendTagObservation(
        _ observation: PriorMapTagObservationRecord,
        boundNodeID: Int64
    ) -> Bool {
        return appendTagObservationForCapture(
            observation,
            boundNodeID: boundNodeID,
            captureID: nil) != nil
    }

    /// Barcode Capture Mode entry point. `captureID` is also the durable
    /// burst identity, so an active capture cannot accidentally merge with a
    /// previous/next scan merely because the payload and frame gap match.
    @discardableResult
    func appendTagObservationForCapture(
        _ observation: PriorMapTagObservationRecord,
        boundNodeID: Int64,
        captureID: UUID?
    ) -> TagObservationAppendResult? {
        guard localizationAdmissionGate.beginTransaction() == nil else {
            return nil
        }
        defer { localizationAdmissionGate.endTransaction() }
        localizationTransactionLock.lock()
        defer { localizationTransactionLock.unlock() }
        guard !hasLocalizationRequiredWriteFailure(), boundNodeID > 0,
              observation.version != 2
                || observation.boundNodeId == boundNodeID else {
            return nil
        }
        // V1R5 §5.4: assign the durable burst/frame identity BEFORE the
        // record is persisted so every observation carries its burst
        // linkage. The frame id is the capture-frame timestamp (unique
        // inside one burst; the burst ingest rejects duplicates).
        let burstID = captureID?.uuidString.lowercased()
            ?? tagBurstIdentity(for: observation)
        let frameID = String(format: "%.9f", observation.frameTimestamp)
        let bound = observation.bindingBurst(
            burstId: burstID, frameId: frameID)
        let result = appendLocalizationRecord(
            bound,
            fileName: "tag_observations.jsonl",
            expectedTrackingSessionId: bound.trackingSessionId)
        if !result.succeeded {
            let failureReason = result.errorReason ?? "write_failed"
            let failures = [
                "tag_observations.jsonl": failureReason
            ]
            recordLocalizationEvidenceFailures(failures)
            appendScanEvent(
                level: "error",
                event: "tag_observation_write_failed",
                message: "Required price-tag observation evidence was not persisted",
                fields: ["reason": failureReason])
            return nil
        }
        // V1R4 §13.1: only observations durably persisted to the main
        // sidecar may enter burst aggregation. A burst flush failure marks
        // the session processing-ineligible fail-closed (watermark count
        // stays short and the finalization flag flips false).
        guard ingestTagObservationBurst(bound, boundNodeID: boundNodeID) else {
            // The observation is already durable and carries burst/frame
            // identity. If it cannot enter the matching burst, the bundle
            // can no longer satisfy the two-way exact binding contract.
            // Mark the required evidence health sticky immediately instead
            // of waiting for finalization to discover the orphan record.
            recordTagBurstWriteFailure(
                "burst_ingest_rejected_after_observation_persisted")
            return nil
        }
        return TagObservationAppendResult(
            observation: bound,
            burstID: burstID,
            frameID: frameID)
    }

    // MARK: - Tag burst aggregation (V1R4 §13.1)

    /// V1R5 §5.4: returns the burst identity an observation belongs to.
    /// The observation joins the in-flight burst only when barcode /
    /// symbology / floor / tracking session and the frame-time gap all
    /// match; otherwise a NEW burst id is minted (the burst is created
    /// later, after the record is durably persisted).
    private func tagBurstIdentity(for observation: PriorMapTagObservationRecord)
        -> String {
        guard scanConfiguration.workflowMode == .priorMapLocalized,
              observation.frameTimestamp.isFinite,
              observation.nodeTimebaseFrameTimestamp.isFinite else {
            // Non-localized workflow: the observation is stored without
            // burst linkage (it can never reach ACCEPTED; V1R5 §5.4).
            return UUID().uuidString
        }
        if let pending = pendingTagBurst {
            let sameBarcode = pending.barcode == observation.payload
                && pending.symbology == observation.symbology
                && pending.priorMapId == observation.priorMapId
                && pending.priorMapSha256 == observation.priorMapSha256
                && pending.floorId == observation.floorId
                && pending.trackingSessionId == observation.trackingSessionId
            // V1R5 review fix: a frame timestamp going BACKWARD (clock
            // rollback) can never join the burst — the gap must be
            // non-negative, otherwise first/last timestamps would drift
            // and the burst time range would no longer contain its
            // observations.
            let gap = observation.frameTimestamp - pending.lastFrameTimestamp
            let withinGap = gap >= 0 && gap <= tagBurstMaxGapSeconds
            if sameBarcode, withinGap {
                return pending.burstId
            }
        }
        return UUID().uuidString
    }

    @discardableResult
    private func ingestTagObservationBurst(
        _ observation: PriorMapTagObservationRecord,
        boundNodeID: Int64
    ) -> Bool {
        guard scanConfiguration.workflowMode == .priorMapLocalized,
              observation.frameTimestamp.isFinite,
              observation.nodeTimebaseFrameTimestamp.isFinite else {
            return false
        }
        if var pending = pendingTagBurst {
            let sameBurst = pending.burstId == observation.burstId
            let sameBarcode = pending.barcode == observation.payload
                && pending.symbology == observation.symbology
                && pending.priorMapId == observation.priorMapId
                && pending.priorMapSha256 == observation.priorMapSha256
                && pending.floorId == observation.floorId
                && pending.trackingSessionId == observation.trackingSessionId
            // V1R5 review fix: negative gaps (clock rollback) never join
            // the burst (see `tagBurstIdentity`).
            let gap = observation.frameTimestamp - pending.lastFrameTimestamp
            let withinGap = gap >= 0 && gap <= tagBurstMaxGapSeconds
            if sameBurst, sameBarcode, withinGap {
                let accepted = pending.ingest(
                    observation,
                    boundNodeID: boundNodeID)
                pendingTagBurst = pending
                return accepted
            }
            _ = flushPendingTagBurstLocked()
        }
        tagBurstSequence += 1
        pendingTagBurst = PendingTagBurst(
            burstId: observation.burstId ?? UUID().uuidString,
            sequence: tagBurstSequence,
            observation: observation,
            boundNodeID: boundNodeID)
        return pendingTagBurst?.frameCount == 1
    }

    /// Flushes the in-flight burst (if any) as a complete durable record.
    /// On write failure the burst is dropped (it can never be made complete
    /// in memory), the failure is recorded fail-closed, and the watermark
    /// count stays short so the PC side blocks processing.
    private func flushPendingTagBurstLocked() -> TagObservationBurstRecord? {
        guard let pending = pendingTagBurst else { return nil }
        pendingTagBurst = nil
        // A malformed/duplicate first frame must make the evidence
        // incomplete, never terminate the shipping app through the
        // `PendingTagBurst.record` precondition.
        guard !pending.frameSamples.isEmpty else {
            recordTagBurstWriteFailure("empty_complete_burst")
            return nil
        }
        let directory = rootDirectory?.appendingPathComponent(
            "segment_0001", isDirectory: true)
        guard let directory,
              fileManager.fileExists(atPath: directory.path) else {
            recordTagBurstWriteFailure("active_directory_unavailable")
            return nil
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            guard let record = pending.record(complete: true) else {
                recordTagBurstWriteFailure("empty_complete_burst")
                return nil
            }
            var data = try encoder.encode(record)
            data.append(0x0A)
            sidecarWriteLock.lock()
            defer { sidecarWriteLock.unlock() }
            try sidecarWriter.append(
                data,
                to: directory.appendingPathComponent("tag_observation_bursts.jsonl"))
            tagObservationBurstCount += 1
            lastTagObservationBurstID = pending.burstId
            completedTagCaptureFrames[pending.burstId] = Set(
                pending.frameSamples.map(\.observationId))
            completedTagCaptureOrder.append(pending.burstId)
            while completedTagCaptureOrder.count > 512 {
                let oldest = completedTagCaptureOrder.removeFirst()
                completedTagCaptureFrames.removeValue(forKey: oldest)
            }
            return record
        }
        catch {
            recordTagBurstWriteFailure(error.localizedDescription)
            return nil
        }
    }

    private func recordTagBurstWriteFailure(_ reason: String) {
        tagBurstWriteFailureCount += 1
        recordLocalizationEvidenceFailures([
            "tag_observation_bursts.jsonl": reason
        ])
        appendScanEvent(
            level: "error",
            event: "tag_observation_burst_write_failed",
            message: "Required tag burst evidence was not persisted",
            fields: ["reason": reason])
    }

    /// Finalization entry point: flushes the last in-flight burst and
    /// returns the durable sidecar watermarks for metadata commit. Called
    /// exactly once per finalization, before the metadata snapshot is built.
    func flushTagObservationBursts(
        allowDuringFinalization: Bool = false
    ) -> TagObservationBurstFlushResult {
        guard localizationAdmissionGate.beginTransaction(
                allowDuringFinalization: allowDuringFinalization) == nil else {
            return TagObservationBurstFlushResult(
                count: 0,
                lastBurstID: nil,
                complete: false)
        }
        defer { localizationAdmissionGate.endTransaction() }
        localizationTransactionLock.lock()
        defer { localizationTransactionLock.unlock() }
        _ = flushPendingTagBurstLocked()
        return TagObservationBurstFlushResult(
            count: tagObservationBurstCount,
            lastBurstID: lastTagObservationBurstID,
            complete: tagBurstWriteFailureCount == 0)
    }

    /// Closes one UI capture as a durable complete burst. A short capture is
    /// still retained for audit, but `sufficient` stays false and the UI may
    /// not create a user-confirmed localized tag from it.
    func finalizeTagObservationCapture(
        captureID: UUID,
        minimumFrameCount: Int
    ) -> TagObservationCaptureCompletionResult? {
        guard localizationAdmissionGate.beginTransaction() == nil else {
            return nil
        }
        defer { localizationAdmissionGate.endTransaction() }
        localizationTransactionLock.lock()
        defer { localizationTransactionLock.unlock() }
        let identity = captureID.uuidString.lowercased()
        guard let pending = pendingTagBurst,
              pending.burstId == identity else {
            return nil
        }
        let frameCount = pending.frameSamples.count
        let observationIDs = pending.frameSamples.map(\.observationId)
        let record = flushPendingTagBurstLocked()
        return TagObservationCaptureCompletionResult(
            burstID: identity,
            frameCount: frameCount,
            observationIDs: observationIDs,
            persisted: record != nil,
            sufficient: record != nil
                && frameCount >= max(0, minimumFrameCount))
    }

    private func validLocalizedPriceTagCaptureLocked(
        _ tag: LocalizedPriceTag
    ) -> Bool {
        // Legacy v1 decode/write compatibility remains intact. New field UX
        // must use v2 and prove it references an already durable complete
        // multi-frame burst before any user-confirmed tag can be committed.
        guard tag.version >= 2 else { return tag.version == 1 }
        guard tag.format == "MarketScannerLocalizedPriceTag",
              tag.userConfirmed,
              !tag.needsReview,
              let captureID = tag.captureId,
              let parsedCaptureID = UUID(uuidString: captureID),
              parsedCaptureID.uuidString.lowercased() == captureID,
              let durableFrames = completedTagCaptureFrames[captureID],
              let frameObservationIDs = tag.frameObservationIds,
              frameObservationIDs.count >= 3,
              Set(frameObservationIDs).count == frameObservationIDs.count,
              Set(frameObservationIDs) == durableFrames,
              durableFrames.count >= 3,
              frameObservationIDs.contains(tag.observationId),
              let algorithmSegmentID = tag.algorithmShelfSegmentId,
              !algorithmSegmentID.isEmpty,
              tag.shelfSegmentId == algorithmSegmentID,
              let algorithmSide = tag.algorithmSide,
              !algorithmSide.isEmpty,
              tag.shelfSide == algorithmSide,
              let algorithmConfidence = tag.algorithmAssociationConfidence,
              algorithmConfidence.isFinite,
              (0...1).contains(algorithmConfidence),
              let status = tag.confirmationStatus,
              status == "USER_CONFIRMED" || status == "USER_OVERRIDDEN",
              let userSegmentID = tag.userConfirmedShelfSegmentId,
              !userSegmentID.isEmpty,
              let userSide = tag.userConfirmedSide,
              !userSide.isEmpty,
              let confirmedAtUTC = tag.confirmedAtUTC,
              confirmedAtUTC.isFinite,
              confirmedAtUTC > 0,
              let confirmedAtMonotonic = tag.confirmedAtMonotonic,
              confirmedAtMonotonic.isFinite,
              confirmedAtMonotonic >= 0,
              tag.confirmationSource == "on_device_operator" else {
            return false
        }
        let sameCandidate = algorithmSegmentID == userSegmentID
            && algorithmSide == userSide
        return status == "USER_CONFIRMED" ? sameCandidate : !sameCandidate
    }

    func reserveLocalizedPriceTagConfirmation(
        _ tag: LocalizedPriceTag,
        authority: PriceTagConfirmationCommitAuthority
    ) -> PriceTagConfirmationReservationOutcome {
        captureLock.lock()
        let validationFailure: PriceTagConfirmationCommitFailure?
        if localizationRequiredWriteFailureCount > 0 {
            validationFailure = .requiredEvidenceFailed
        }
        else if !PriceTagConfirmationIdentityValidator.matches(
            tag: tag,
            authority: authority,
            configuration: scanConfiguration,
            trackingSessionID: trackingSessionId
        ) {
            validationFailure = .sessionIdentityMismatch
        }
        else if rootDirectory == nil || segmentIndex != 1 {
            validationFailure = .activeSessionUnavailable
        }
        else {
            validationFailure = nil
        }
        captureLock.unlock()
        if let validationFailure {
            return PriceTagConfirmationReservationOutcome(
                reserved: false,
                failure: validationFailure)
        }
        switch localizationAdmissionGate.reserveConfirmation(authority) {
        case .reserved:
            return PriceTagConfirmationReservationOutcome(
                reserved: true,
                failure: nil)
        case .rejected(.finalizationInProgress):
            return PriceTagConfirmationReservationOutcome(
                reserved: false,
                failure: .finalizationInProgress)
        case .rejected(.duplicateReservation):
            return PriceTagConfirmationReservationOutcome(
                reserved: false,
                failure: .duplicateReservation)
        case .rejected(.reservationMissing):
            return PriceTagConfirmationReservationOutcome(
                reserved: false,
                failure: .reservationMissing)
        }
    }

    func cancelLocalizedPriceTagConfirmationReservation(
        authority: PriceTagConfirmationCommitAuthority
    ) {
        localizationAdmissionGate.cancelConfirmationReservation(authority)
    }

    @discardableResult
    func recordLocalizedPriceTag(
        _ tag: LocalizedPriceTag,
        authority: PriceTagConfirmationCommitAuthority
    ) -> PriceTagConfirmationCommitOutcome {
        if let admissionFailure = localizationAdmissionGate.beginTransaction(
            reservedConfirmation: authority
        ) {
            let failure: PriceTagConfirmationCommitFailure
            switch admissionFailure {
            case .finalizationInProgress:
                failure = .finalizationInProgress
            case .duplicateReservation:
                failure = .duplicateReservation
            case .reservationMissing:
                failure = .reservationMissing
            }
            return PriceTagConfirmationCommitOutcome(
                persisted: false,
                failure: failure)
        }
        defer {
            localizationAdmissionGate.endTransaction(
                reservedConfirmation: authority)
        }
        localizationTransactionLock.lock()
        defer { localizationTransactionLock.unlock() }
        captureLock.lock()
        let validationFailure: PriceTagConfirmationCommitFailure?
        if localizationRequiredWriteFailureCount > 0 {
            validationFailure = .requiredEvidenceFailed
        }
        else if !validLocalizedPriceTagCaptureLocked(tag) {
            validationFailure = .captureBindingInvalid
        }
        else if !PriceTagConfirmationIdentityValidator.matches(
                tag: tag,
                authority: authority,
                configuration: scanConfiguration,
                trackingSessionID: trackingSessionId) {
            validationFailure = .sessionIdentityMismatch
        }
        else if rootDirectory == nil || segmentIndex != 1 {
            validationFailure = .activeSessionUnavailable
        }
        else {
            validationFailure = nil
        }
        guard validationFailure == nil,
              let root = rootDirectory else {
            captureLock.unlock()
            return PriceTagConfirmationCommitOutcome(
                persisted: false,
                failure: validationFailure ?? .activeSessionUnavailable)
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
            if let captureID = tag.captureId {
                completedTagCaptureFrames.removeValue(forKey: captureID)
                completedTagCaptureOrder.removeAll { $0 == captureID }
            }
            return PriceTagConfirmationCommitOutcome(
                persisted: true,
                failure: nil)
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
            return PriceTagConfirmationCommitOutcome(
                persisted: false,
                failure: .persistenceFailed)
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
        guard localizationAdmissionGate.beginTransaction() == nil else {
            return false
        }
        defer { localizationAdmissionGate.endTransaction() }
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
        } else {
            // Advance only after appendLocalizationRecord confirms the
            // durable JSONL append, matching the recovery watermark rule.
            captureLock.lock()
            manualLocalizationEventCount += 1
            captureLock.unlock()
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
        expectedTrackingSessionId: String,
        allowDuringFinalization: Bool = false
    ) -> Bool {
        guard localizationAdmissionGate.beginTransaction(
                allowDuringFinalization: allowDuringFinalization) == nil else {
            return false
        }
        defer { localizationAdmissionGate.endTransaction() }
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
            allowDuringFinalization: allowDuringFinalization)
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
            let failureReason = result.errorReason ?? "write_failed"
            let failures = [
                PriorMapRecoveryLifecycleRecord.fileName:
                    failureReason
            ]
            recordLocalizationEvidenceFailures(failures)
            appendScanEvent(
                level: "error",
                event: "recovery_lifecycle_event_write_failed",
                message: "Required recovery lifecycle evidence was not persisted",
                fields: [
                    "reason": failureReason,
                ])
        }
        return result.succeeded
    }

    /// P7R6/P7R6A idempotence strategy A: one stable read of the
    /// already-persisted lifecycle evidence, taken before any append so a
    /// crash between durable write and acknowledgement can be detected
    /// instead of duplicating the episode. The reader only reads: it never
    /// splits lines or parses JSON, and it never swallows a truncated tail.
    /// A missing file means nothing has been persisted yet (empty Data).
    /// The shared strict parser owns every JSONL decision on the returned
    /// snapshot.
    func persistedRecoveryLifecycleSnapshot(
        expectedTrackingSessionId: String
    ) throws -> Data {
        let directory = try activeLocalizationDirectory(
            expectedTrackingSessionId: expectedTrackingSessionId,
            allowDuringFinalization: true)
        let url = directory.appendingPathComponent(
            PriorMapRecoveryLifecycleRecord.fileName)
        guard fileManager.fileExists(atPath: url.path) else {
            return Data()
        }
        let snapshot = try SafeSessionPath.readRegularFile(
            url,
            within: directory,
            maximumBytes: Int64(
                RecoveryLifecycleEvidenceLimits.maximumFileBytes))
        return snapshot.data
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
        // PriceTagSessionAdmissionGate is the single write-admission
        // linearization point. A transaction admitted just before
        // beginFinalization() may wait behind localizationTransactionLock and
        // must still finish while the finalization drain waits for it. Do not
        // re-read the global finalization state here and reject that admitted
        // writer. Finalization-owned operations are authorized at their public
        // entry point; this helper keeps enforcing the exact session identity.
        _ = allowDuringFinalization
        guard expectedTrackingSessionId == trackingSessionId,
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

    /// A durable manual event followed by a failed in-memory CAS would make
    /// that event ambiguous to downstream consumers. This is an integrity
    /// failure, not a low-confidence localization result: preserve the raw
    /// scan and event for diagnosis, but make certified processing ineligible.
    func recordManualLocalizationCommitConflict() {
        recordLocalizationEvidenceFailures([
            "manual_localization_events.jsonl":
                "manual_alignment_commit_conflict"
        ])
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
