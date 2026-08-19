//
//  PriceTagLocalizationCore.swift
//  RTABMapApp
//
//  Platform-neutral tag measurement result and shelf association.
//

import Foundation
import CoreGraphics
import simd

enum PriorMapCapturedImageOrientation: String, Codable {
    case up
    case down
    case left
    case right
}

enum PriorMapImageGeometry {
    static func nativeSensorBounds(
        visionBounds: CGRect,
        orientation: PriorMapCapturedImageOrientation
    ) -> CGRect {
        let corners = [
            CGPoint(x: visionBounds.minX, y: visionBounds.minY),
            CGPoint(x: visionBounds.maxX, y: visionBounds.minY),
            CGPoint(x: visionBounds.minX, y: visionBounds.maxY),
            CGPoint(x: visionBounds.maxX, y: visionBounds.maxY),
        ].map { point -> CGPoint in
            switch orientation {
            case .up:
                return point
            case .down:
                return CGPoint(x: 1 - point.x, y: 1 - point.y)
            case .right:
                return CGPoint(x: 1 - point.y, y: point.x)
            case .left:
                return CGPoint(x: point.y, y: 1 - point.x)
            }
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

struct PriceTagDepthEvidence: Codable, Equatable {
    let sampleCount: Int
    let inlierCount: Int
    let inlierRatio: Double
    let medianM: Double?
    let madM: Double?
    let planeResidualM: Double?
    let surfaceNormalCamera: [Double]?
    let confidence: Double
    let accepted: Bool
    let rejectionReason: String?

    static let unavailable = PriceTagDepthEvidence(
        sampleCount: 0,
        inlierCount: 0,
        inlierRatio: 0,
        medianM: nil,
        madM: nil,
        planeResidualM: nil,
        surfaceNormalCamera: nil,
        confidence: 0,
        accepted: false,
        rejectionReason: "depth_unavailable")

    static func evaluate(_ rawDepths: [Float]) -> PriceTagDepthEvidence {
        let depths = rawDepths.filter {
            $0.isFinite && $0 >= 0.2 && $0 <= 8
        }.sorted()
        guard depths.count >= 12 else {
            return PriceTagDepthEvidence(
                sampleCount: depths.count,
                inlierCount: 0,
                inlierRatio: 0,
                medianM: nil,
                madM: nil,
                planeResidualM: nil,
                surfaceNormalCamera: nil,
                confidence: 0,
                accepted: false,
                rejectionReason: "insufficient_depth_samples")
        }
        let globalMedian = depths[depths.count / 2]
        // Find the nearest coherent surface cluster. It must also contain the
        // global median; otherwise foreground/background evidence is
        // ambiguous and the depth result is not trusted.
        var bestRange: Range<Int>?
        var end = 0
        for start in depths.indices {
            end = max(end, start)
            while end < depths.count, depths[end] - depths[start] <= 0.10 {
                end += 1
            }
            let candidate = start..<end
            if candidate.count >= 12 {
                if let currentBest = bestRange {
                    let candidateDepth = depths[candidate.lowerBound]
                    let currentDepth = depths[currentBest.lowerBound]
                    if candidateDepth < currentDepth - 0.02
                        || (abs(candidateDepth - currentDepth) <= 0.02
                            && candidate.count > currentBest.count) {
                        bestRange = candidate
                    }
                }
                else {
                    bestRange = candidate
                }
            }
        }
        guard let range = bestRange, !range.isEmpty else {
            return .unavailable
        }
        let cluster = Array(depths[range])
        let median = cluster[cluster.count / 2]
        let deviations = cluster.map { abs($0 - median) }.sorted()
        let mad = deviations[deviations.count / 2]
        let inlierThreshold = max(0.02, 3 * mad)
        let inliers = cluster.filter { abs($0 - median) <= inlierThreshold }
        let ratio = Double(inliers.count) / Double(depths.count)
        guard let clusterFirst = cluster.first,
              let clusterLast = cluster.last else {
            return .unavailable
        }
        let containsGlobalMedian = globalMedian >= clusterFirst
            && globalMedian <= clusterLast
        let accepted = inliers.count >= 12
            && ratio >= 0.55
            && mad <= 0.045
            && containsGlobalMedian
        let densityQuality = min(1, Double(inliers.count) / 36)
        let ratioQuality = min(1, max(0, (ratio - 0.45) / 0.45))
        let dispersionQuality = min(1, max(0, 1 - Double(mad) / 0.05))
        let confidence = accepted
            ? min(0.90, 0.48 + 0.18 * densityQuality
                    + 0.16 * ratioQuality + 0.08 * dispersionQuality)
            : min(0.49, 0.20 * densityQuality + 0.20 * ratioQuality)
        return PriceTagDepthEvidence(
            sampleCount: depths.count,
            inlierCount: inliers.count,
            inlierRatio: ratio,
            medianM: Double(median),
            madM: Double(mad),
            // Without a stable local plane fit we expose dispersion as a
            // conservative residual and leave the normal explicitly absent.
            planeResidualM: Double(mad) * 1.4826,
            surfaceNormalCamera: nil,
            confidence: confidence,
            accepted: accepted,
            rejectionReason: accepted ? nil : (
                containsGlobalMedian ? "unreliable_depth_surface" : "ambiguous_depth_layers"
            ))
    }

    func rejected(_ reason: String) -> PriceTagDepthEvidence {
        return PriceTagDepthEvidence(
            sampleCount: sampleCount,
            inlierCount: inlierCount,
            inlierRatio: inlierRatio,
            medianM: medianM,
            madM: madM,
            planeResidualM: planeResidualM,
            surfaceNormalCamera: surfaceNormalCamera,
            confidence: min(confidence, 0.49),
            accepted: false,
            rejectionReason: reason)
    }

    func withPlane(
        residualM: Double?,
        normalCamera: SIMD3<Double>?
    ) -> PriceTagDepthEvidence {
        let validNormal = normalCamera.flatMap { normal -> [Double]? in
            let length = simd_length(normal)
            guard length.isFinite, length > 1.0e-9,
                  normal.x.isFinite,
                  normal.y.isFinite,
                  normal.z.isFinite else {
                return nil
            }
            let unit = normal / length
            return [unit.x, unit.y, unit.z]
        }
        // A nearly degenerate depth patch has no stable plane normal. The
        // previous implementation used +infinity as the residual in that
        // case and then copied it into the Codable observation. JSONEncoder
        // rejects non-finite floating-point values, which made one ordinary
        // bad depth frame poison the required sidecar health for the whole
        // continuous scan. Absence is the truthful representation here: the
        // frame remains measurement-unavailable/low-confidence, while the
        // next ARFrame may still supply valid evidence.
        let finiteResidual = residualM.flatMap {
            $0.isFinite && $0 >= 0 ? $0 : nil
        }
        let planeAccepted = accepted
            && finiteResidual.map { $0 <= 0.06 } == true
            && validNormal != nil
        let planeQuality = finiteResidual.map {
            min(1, max(0, 1 - $0 / 0.06))
        } ?? 0
        return PriceTagDepthEvidence(
            sampleCount: sampleCount,
            inlierCount: inlierCount,
            inlierRatio: inlierRatio,
            medianM: medianM,
            madM: madM,
            planeResidualM: finiteResidual,
            surfaceNormalCamera: validNormal,
            confidence: planeAccepted
                ? min(0.92, confidence * (0.82 + 0.18 * planeQuality))
                : min(0.49, confidence),
            accepted: planeAccepted,
            rejectionReason: planeAccepted ? nil : "unstable_depth_plane")
    }
}

struct PriorMapAlignmentSnapshot {
    let arkitOrigin: PriorMapPose2D
    let initialMapPose: PriorMapPose2D
    let floorEstimate: PriorMapFloorEstimate?
    let localizationState: String
    let localizationConfidence: Double
    let alignmentVersion: Int
    let frameTimestamp: TimeInterval
}

struct PriorMapAlignmentFreshnessResult: Equatable {
    let label: String
    let localizationState: String
    let localizationConfidence: Double
}

enum PriorMapAlignmentFreshness {
    static func evaluate(
        ageMs: Double,
        versionLag: Int,
        localizationState: String,
        localizationConfidence: Double
    ) -> PriorMapAlignmentFreshnessResult {
        if ageMs <= 250, versionLag == 0 {
            return PriorMapAlignmentFreshnessResult(
                label: "fresh",
                localizationState: localizationState,
                localizationConfidence: localizationConfidence)
        }
        if ageMs <= 600, versionLag == 0 {
            return PriorMapAlignmentFreshnessResult(
                label: "aging",
                localizationState: "weak",
                localizationConfidence: min(0.55, localizationConfidence * 0.70))
        }
        return PriorMapAlignmentFreshnessResult(
            label: versionLag > 0 ? "version_stale" : "timestamp_stale",
            localizationState: "lost",
            localizationConfidence: min(0.30, localizationConfidence * 0.35))
    }
}

final class PriorMapAlignmentSnapshotStore {
    private let lock = NSLock()
    private var value: PriorMapAlignmentSnapshot?

    func publish(_ snapshot: PriorMapAlignmentSnapshot) {
        lock.lock()
        value = snapshot
        lock.unlock()
    }

    func snapshot() -> PriorMapAlignmentSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func reset() {
        lock.lock()
        value = nil
        lock.unlock()
    }
}

struct PriorMapShelf: Codable {
    let id: String
    let floorId: String
    let code: String?
    let crossCode: String?
    let rowFlag: String?
    let geometry: PriorMapShelfGeometry
    let shapeType: String?
    let yawRad: Double?
    let source: PriorMapShelfSource?

    enum CodingKeys: String, CodingKey {
        case id
        case floorId = "floor_id"
        case code
        case crossCode = "cross_code"
        case rowFlag = "row_flag"
        case geometry
        case shapeType = "shape_type"
        case yawRad = "yaw_rad"
        case source
    }

    init(
        id: String,
        floorId: String,
        code: String?,
        crossCode: String?,
        rowFlag: String?,
        geometry: PriorMapShelfGeometry,
        shapeType: String? = "MapShelf",
        yawRad: Double? = nil,
        source: PriorMapShelfSource? = nil
    ) {
        self.id = id
        self.floorId = floorId
        self.code = code
        self.crossCode = crossCode
        self.rowFlag = rowFlag
        self.geometry = geometry
        self.shapeType = shapeType
        self.yawRad = yawRad
        self.source = source
    }
}

struct PriorMapShelfSource: Codable {
    let width: Double?
    let height: Double?
}

struct PriorMapFixedStructure: Codable {
    let id: String
    let floorId: String
    let shapeType: String
    let code: String?
    let crossCode: String?
    let rowFlag: String?
    let geometry: PriorMapShelfGeometry
    let yawRad: Double?
    let source: PriorMapShelfSource?

    enum CodingKeys: String, CodingKey {
        case id
        case floorId = "floor_id"
        case shapeType = "shape_type"
        case code
        case crossCode = "cross_code"
        case rowFlag = "row_flag"
        case geometry
        case yawRad = "yaw_rad"
        case source
    }

    init(
        id: String,
        floorId: String,
        shapeType: String,
        code: String?,
        crossCode: String?,
        rowFlag: String?,
        geometry: PriorMapShelfGeometry,
        yawRad: Double? = nil,
        source: PriorMapShelfSource? = nil
    ) {
        self.id = id
        self.floorId = floorId
        self.shapeType = shapeType
        self.code = code
        self.crossCode = crossCode
        self.rowFlag = rowFlag
        self.geometry = geometry
        self.yawRad = yawRad
        self.source = source
    }

    var associationSurface: PriorMapShelf? {
        guard shapeType == "MapTable" || shapeType == "MapTableFeature" else {
            return nil
        }
        return PriorMapShelf(
            id: id,
            floorId: floorId,
            code: code,
            crossCode: crossCode,
            rowFlag: rowFlag,
            geometry: geometry,
            shapeType: shapeType,
            yawRad: yawRad,
            source: source)
    }
}

struct PriorMapShelfGeometry: Codable, Equatable {
    let type: String
    let coordinates: [[Double]]
}

struct PriorMapTagPoint3D: Codable, Equatable {
    let xM: Double
    let yM: Double
    let heightM: Double?

    enum CodingKeys: String, CodingKey {
        case xM = "x_m"
        case yM = "y_m"
        case heightM = "height_m"
    }
}

/// Exact price-tag point expressed in the capture-bound RTAB-Map node frame.
/// Unlike `PriorMapTagPoint3D`, `zM` is a geometric node-local coordinate;
/// display height above the selected floor is carried separately.
struct PriorMapTagNodeLocalPoint3D: Codable, Equatable {
    let xM: Double
    let yM: Double
    let zM: Double

    enum CodingKeys: String, CodingKey {
        case xM = "x_m"
        case yM = "y_m"
        case zM = "z_m"
    }
}

struct PriorMapTagObservationRecord: Codable {
    let format: String
    let version: Int
    let observationId: String
    let timestamp: TimeInterval
    let payload: String
    let symbology: String
    let normalizedBounds: [Double]
    let frameTimestamp: TimeInterval
    let nodeTimebaseFrameTimestamp: TimeInterval
    let nodeTimebaseOffsetSeconds: TimeInterval
    let poseTimestampDeltaMs: Double
    let alignmentVersion: Int
    let alignmentSnapshotTimestamp: TimeInterval
    let alignmentAgeMs: Double
    let alignmentVersionLag: Int
    let alignmentFreshness: String
    let rawMapPosition: PriorMapTagPoint3D?
    let measurementMethod: String
    let measurementConfidence: Double
    let depthSampleCount: Int
    let depthInlierCount: Int
    let depthInlierRatio: Double
    let depthMedianM: Double?
    let depthMadM: Double?
    let planeResidualM: Double?
    let surfaceNormalCamera: [Double]?
    let localizationState: String
    let localizationConfidence: Double
    let priorMapId: String
    let priorMapSha256: String
    let floorId: String
    let trackingSessionId: String
    let needsReview: Bool
    /// V1R5 §5.2/§5.4: durable burst linkage. `burstId` is the identity
    /// of the verified burst this observation belongs to; `frameId` is
    /// the capture-frame identity (unique inside one burst). Both are
    /// assigned by `appendTagObservation` at persistence time — nil on
    /// legacy records written before V1R5, which are never accepted for
    /// ACCEPTED price tags (they cannot satisfy the verified-burst gate).
    let burstId: String?
    let frameId: String?
    /// Schema v2 coordinate authority. These values come from the same
    /// atomic native node snapshot used for burst binding. Legacy v1 records
    /// decode with nil values and are retained only as rescan-required
    /// business evidence by post-processing.
    let boundNodeId: Int64?
    let boundNodeStamp: TimeInterval?
    let boundNodeMapId: Int32?
    let coordinateFrame: String?
    let pointInBoundNodeFrame: PriorMapTagNodeLocalPoint3D?
    let measurementHeightM: Double?
    var epoch: Int? = nil
    var component: Int64? = nil

    enum CodingKeys: String, CodingKey {
        case format
        case version
        case observationId = "observation_id"
        case timestamp
        case payload
        case symbology
        case normalizedBounds = "normalized_bounds"
        case frameTimestamp = "frame_timestamp"
        case nodeTimebaseFrameTimestamp = "node_timebase_frame_timestamp"
        case nodeTimebaseOffsetSeconds = "node_timebase_offset_seconds"
        case poseTimestampDeltaMs = "pose_timestamp_delta_ms"
        case alignmentVersion = "alignment_version"
        case alignmentSnapshotTimestamp = "alignment_snapshot_timestamp"
        case alignmentAgeMs = "alignment_age_ms"
        case alignmentVersionLag = "alignment_version_lag"
        case alignmentFreshness = "alignment_freshness"
        case rawMapPosition = "raw_map_position"
        case measurementMethod = "measurement_method"
        case measurementConfidence = "measurement_confidence"
        case depthSampleCount = "depth_sample_count"
        case depthInlierCount = "depth_inlier_count"
        case depthInlierRatio = "depth_inlier_ratio"
        case depthMedianM = "depth_median_m"
        case depthMadM = "depth_mad_m"
        case planeResidualM = "plane_residual_m"
        case surfaceNormalCamera = "surface_normal_camera"
        case localizationState = "localization_state"
        case localizationConfidence = "localization_confidence"
        case priorMapId = "prior_map_id"
        case priorMapSha256 = "prior_map_sha256"
        case floorId = "floor_id"
        case trackingSessionId = "tracking_session_id"
        case needsReview = "needs_review"
        case burstId = "burst_id"
        case frameId = "frame_id"
        case boundNodeId = "bound_node_id"
        case boundNodeStamp = "bound_node_stamp"
        case boundNodeMapId = "bound_node_map_id"
        case coordinateFrame = "coordinate_frame"
        case pointInBoundNodeFrame = "point_in_bound_node_frame"
        case measurementHeightM = "measurement_height_m"
        case epoch
        case component
    }

    /// Preflight for the strict JSONL writer. A frame-local numeric failure
    /// must be skipped before persistence, never be misreported as a disk or
    /// framing failure that invalidates an otherwise healthy scan session.
    var hasFinitePersistenceNumbers: Bool {
        func validPoint(_ point: PriorMapTagPoint3D?) -> Bool {
            guard let point else { return true }
            return point.xM.isFinite
                && point.yM.isFinite
                && (point.heightM?.isFinite ?? true)
        }
        func validNodePoint(_ point: PriorMapTagNodeLocalPoint3D?) -> Bool {
            guard let point else { return true }
            return point.xM.isFinite && point.yM.isFinite && point.zM.isFinite
        }
        guard normalizedBounds.count == 4 else { return false }
        let x = normalizedBounds[0]
        let y = normalizedBounds[1]
        let width = normalizedBounds[2]
        let height = normalizedBounds[3]
        let boundsValid = [x, y, width, height].allSatisfy { $0.isFinite }
            && x >= 0 && x <= 1
            && y >= 0 && y <= 1
            && width > 0 && width <= 1
            && height > 0 && height <= 1
            && x + width <= 1 + 1.0e-9
            && y + height <= 1 + 1.0e-9
        let expectedInlierRatio = depthSampleCount == 0
            ? 0 : Double(depthInlierCount) / Double(depthSampleCount)
        let normalValid = surfaceNormalCamera.map { normal in
            guard normal.count == 3,
                  normal.allSatisfy({ $0.isFinite }) else { return false }
            let norm = sqrt(normal.reduce(0) { $0 + $1 * $1 })
            return norm.isFinite && abs(norm - 1) <= 1.0e-3
        } ?? true
        let isDepthMeasurement = measurementMethod == "scene_depth"
            || measurementMethod == "smoothed_scene_depth"
        let isNonDepthMeasurement = measurementMethod == "shelf_plane_ray"
            || measurementMethod == "unavailable"
        let epochComponentValid = if epoch == nil && component == nil {
            true
        }
        else if let epoch, let component, let boundNodeMapId {
            epoch >= 0 && component == Int64(boundNodeMapId)
        }
        else {
            false
        }
        let v2CoordinateContractValid = version != 2 || (
            boundNodeId.map { $0 > 0 } == true
                && (boundNodeStamp?.isFinite ?? false)
                && boundNodeMapId != nil
                && coordinateFrame == "RTABMAP_BOUND_NODE_LOCAL"
                && epochComponentValid
                && (!isDepthMeasurement || pointInBoundNodeFrame != nil)
                && (!isNonDepthMeasurement || pointInBoundNodeFrame == nil)
        )
        return timestamp.isFinite
            && boundsValid
            && frameTimestamp.isFinite
            && nodeTimebaseFrameTimestamp.isFinite
            && nodeTimebaseOffsetSeconds.isFinite
            && abs(
                frameTimestamp + nodeTimebaseOffsetSeconds
                    - nodeTimebaseFrameTimestamp) <= 1.0e-6
            && poseTimestampDeltaMs.isFinite
            && poseTimestampDeltaMs >= 0
            && alignmentVersion > 0
            && alignmentVersionLag >= 0
            && alignmentVersionLag < alignmentVersion
            && alignmentSnapshotTimestamp.isFinite
            && alignmentAgeMs.isFinite
            && alignmentAgeMs >= 0
            && measurementConfidence.isFinite
            && measurementConfidence >= 0
            && measurementConfidence <= 1
            && (measurementMethod != "unavailable"
                || measurementConfidence == 0)
            && depthSampleCount >= 0
            && depthInlierCount >= 0
            && depthInlierCount <= depthSampleCount
            && depthInlierRatio.isFinite
            && depthInlierRatio >= 0
            && depthInlierRatio <= 1
            && abs(depthInlierRatio - expectedInlierRatio) <= 1.0e-6
            && (depthMedianM.map { $0.isFinite && $0 >= 0.2 && $0 <= 8 }
                ?? true)
            && (depthMadM.map { $0.isFinite && $0 >= 0 && $0 <= 8 }
                ?? true)
            && (planeResidualM.map { $0.isFinite && $0 >= 0 && $0 <= 8 }
                ?? true)
            && (depthSampleCount != 0
                || (depthMedianM == nil && depthMadM == nil
                    && planeResidualM == nil))
            && normalValid
            && localizationConfidence.isFinite
            && localizationConfidence >= 0
            && localizationConfidence <= 1
            && validPoint(rawMapPosition)
            && (boundNodeStamp?.isFinite ?? true)
            && validNodePoint(pointInBoundNodeFrame)
            && (measurementHeightM?.isFinite ?? true)
            && v2CoordinateContractValid
    }

    /// V1R5: returns a copy bound to the durable burst/frame identity
    /// assigned at persistence time. The original record never mutates.
    func bindingBurst(burstId: String?, frameId: String?) -> PriorMapTagObservationRecord {
        var result = PriorMapTagObservationRecord(
            format: format,
            version: version,
            observationId: observationId,
            timestamp: timestamp,
            payload: payload,
            symbology: symbology,
            normalizedBounds: normalizedBounds,
            frameTimestamp: frameTimestamp,
            nodeTimebaseFrameTimestamp: nodeTimebaseFrameTimestamp,
            nodeTimebaseOffsetSeconds: nodeTimebaseOffsetSeconds,
            poseTimestampDeltaMs: poseTimestampDeltaMs,
            alignmentVersion: alignmentVersion,
            alignmentSnapshotTimestamp: alignmentSnapshotTimestamp,
            alignmentAgeMs: alignmentAgeMs,
            alignmentVersionLag: alignmentVersionLag,
            alignmentFreshness: alignmentFreshness,
            rawMapPosition: rawMapPosition,
            measurementMethod: measurementMethod,
            measurementConfidence: measurementConfidence,
            depthSampleCount: depthSampleCount,
            depthInlierCount: depthInlierCount,
            depthInlierRatio: depthInlierRatio,
            depthMedianM: depthMedianM,
            depthMadM: depthMadM,
            planeResidualM: planeResidualM,
            surfaceNormalCamera: surfaceNormalCamera,
            localizationState: localizationState,
            localizationConfidence: localizationConfidence,
            priorMapId: priorMapId,
            priorMapSha256: priorMapSha256,
            floorId: floorId,
            trackingSessionId: trackingSessionId,
            needsReview: needsReview,
            burstId: burstId,
            frameId: frameId,
            boundNodeId: boundNodeId,
            boundNodeStamp: boundNodeStamp,
            boundNodeMapId: boundNodeMapId,
            coordinateFrame: coordinateFrame,
            pointInBoundNodeFrame: pointInBoundNodeFrame,
            measurementHeightM: measurementHeightM)
        result.epoch = epoch
        result.component = component
        return result
    }
}

struct PriceTagShelfPreviewPoint: Codable, Equatable {
    let xM: Double
    let yM: Double
}

struct PriceTagShelfCandidate: Codable, Equatable {
    let shelfSegmentId: String
    let shelfCode: String?
    let rowFlag: String?
    let crossCode: String?
    let side: String
    let distanceFromStartCm: Double
    let distanceToShelfM: Double
    let associationConfidence: Double
    let occluded: Bool
    let blockedByOtherStructure: Bool
    let snappedPosition: PriorMapTagPoint3D
    let outline: [PriceTagShelfPreviewPoint]

    var isSelectable: Bool {
        return !occluded
            && !blockedByOtherStructure
            && associationConfidence >= 0.65
    }
}

struct PriceTagShelfAssociationResult {
    let tag: LocalizedPriceTag
    let candidates: [PriceTagShelfCandidate]
    let algorithmCandidateReliable: Bool
}

struct PriceTagLocalizedFrameResult {
    let observation: PriorMapTagObservationRecord
    let association: PriceTagShelfAssociationResult
}

enum ShelfConfirmationDecision: Equatable {
    case confirmedAlgorithmCandidate
    case selectedAlternative(segmentID: String, side: String)
    case rescan
    case observationOnly
}

struct LocalizedPriceTag: Codable, Equatable {
    let format: String
    let version: Int
    let tagId: String
    let observationId: String
    let payload: String
    let symbology: String
    let floorId: String
    let timestamp: TimeInterval
    let trackingSessionId: String
    let priorMapId: String
    let priorMapSha256: String
    /// Legacy/current display fields retain the algorithm candidate. User
    /// confirmation is persisted separately below and never overwrites it.
    let shelfSegmentId: String?
    let shelfCode: String?
    let rowFlag: String?
    let crossCode: String?
    let shelfSide: String?
    let distanceFromShelfStartCm: Double?
    let heightCm: Double?
    let rawMapPosition: PriorMapTagPoint3D?
    let snappedMapPosition: PriorMapTagPoint3D?
    let localizationConfidence: Double
    let measurementConfidence: Double
    let associationConfidence: Double
    let measurementMethod: String
    let needsReview: Bool
    let userConfirmed: Bool
    /// Additive v2 capture and confirmation audit. Legacy v1 records decode
    /// with nil values and continue to use the fields above.
    let captureId: String?
    let frameObservationIds: [String]?
    let algorithmShelfSegmentId: String?
    let algorithmShelfCode: String?
    let algorithmSide: String?
    let algorithmDistanceFromShelfStartCm: Double?
    let algorithmAssociationConfidence: Double?
    let confirmationStatus: String?
    let userConfirmedShelfSegmentId: String?
    let userConfirmedShelfCode: String?
    let userConfirmedSide: String?
    let userConfirmedDistanceFromShelfStartCm: Double?
    let confirmedAtUTC: TimeInterval?
    let confirmedAtMonotonic: TimeInterval?
    let confirmationSource: String?

    enum CodingKeys: String, CodingKey {
        case format
        case version
        case tagId = "tag_id"
        case observationId = "observation_id"
        case payload
        case symbology
        case floorId = "floor_id"
        case timestamp
        case trackingSessionId = "tracking_session_id"
        case priorMapId = "prior_map_id"
        case priorMapSha256 = "prior_map_sha256"
        case shelfSegmentId = "shelf_segment_id"
        case shelfCode = "shelf_code"
        case rowFlag = "row_flag"
        case crossCode = "cross_code"
        case shelfSide = "shelf_side"
        case distanceFromShelfStartCm = "distance_from_shelf_start_cm"
        case heightCm = "height_cm"
        case rawMapPosition = "raw_map_position"
        case snappedMapPosition = "snapped_map_position"
        case localizationConfidence = "localization_confidence"
        case measurementConfidence = "measurement_confidence"
        case associationConfidence = "association_confidence"
        case measurementMethod = "measurement_method"
        case needsReview = "needs_review"
        case userConfirmed = "user_confirmed"
        case captureId = "capture_id"
        case frameObservationIds = "frame_observation_ids"
        case algorithmShelfSegmentId = "algorithm_shelf_segment_id"
        case algorithmShelfCode = "algorithm_shelf_code"
        case algorithmSide = "algorithm_side"
        case algorithmDistanceFromShelfStartCm =
            "algorithm_distance_from_shelf_start_cm"
        case algorithmAssociationConfidence =
            "algorithm_association_confidence"
        case confirmationStatus = "confirmation_status"
        case userConfirmedShelfSegmentId = "user_confirmed_shelf_segment_id"
        case userConfirmedShelfCode = "user_confirmed_shelf_code"
        case userConfirmedSide = "user_confirmed_side"
        case userConfirmedDistanceFromShelfStartCm =
            "user_confirmed_distance_from_shelf_start_cm"
        case confirmedAtUTC = "confirmed_at_utc"
        case confirmedAtMonotonic = "confirmed_at_monotonic"
        case confirmationSource = "confirmation_source"
    }

    init(
        format: String,
        version: Int,
        tagId: String,
        observationId: String,
        payload: String,
        symbology: String,
        floorId: String,
        timestamp: TimeInterval,
        trackingSessionId: String,
        priorMapId: String,
        priorMapSha256: String,
        shelfSegmentId: String? = nil,
        shelfCode: String?,
        rowFlag: String?,
        crossCode: String?,
        shelfSide: String?,
        distanceFromShelfStartCm: Double?,
        heightCm: Double?,
        rawMapPosition: PriorMapTagPoint3D?,
        snappedMapPosition: PriorMapTagPoint3D?,
        localizationConfidence: Double,
        measurementConfidence: Double,
        associationConfidence: Double,
        measurementMethod: String,
        needsReview: Bool,
        userConfirmed: Bool,
        captureId: String? = nil,
        frameObservationIds: [String]? = nil,
        algorithmShelfSegmentId: String? = nil,
        algorithmShelfCode: String? = nil,
        algorithmSide: String? = nil,
        algorithmDistanceFromShelfStartCm: Double? = nil,
        algorithmAssociationConfidence: Double? = nil,
        confirmationStatus: String? = nil,
        userConfirmedShelfSegmentId: String? = nil,
        userConfirmedShelfCode: String? = nil,
        userConfirmedSide: String? = nil,
        userConfirmedDistanceFromShelfStartCm: Double? = nil,
        confirmedAtUTC: TimeInterval? = nil,
        confirmedAtMonotonic: TimeInterval? = nil,
        confirmationSource: String? = nil
    ) {
        self.format = format
        self.version = version
        self.tagId = tagId
        self.observationId = observationId
        self.payload = payload
        self.symbology = symbology
        self.floorId = floorId
        self.timestamp = timestamp
        self.trackingSessionId = trackingSessionId
        self.priorMapId = priorMapId
        self.priorMapSha256 = priorMapSha256
        self.shelfSegmentId = shelfSegmentId
        self.shelfCode = shelfCode
        self.rowFlag = rowFlag
        self.crossCode = crossCode
        self.shelfSide = shelfSide
        self.distanceFromShelfStartCm = distanceFromShelfStartCm
        self.heightCm = heightCm
        self.rawMapPosition = rawMapPosition
        self.snappedMapPosition = snappedMapPosition
        self.localizationConfidence = localizationConfidence
        self.measurementConfidence = measurementConfidence
        self.associationConfidence = associationConfidence
        self.measurementMethod = measurementMethod
        self.needsReview = needsReview
        self.userConfirmed = userConfirmed
        self.captureId = captureId
        self.frameObservationIds = frameObservationIds
        self.algorithmShelfSegmentId = algorithmShelfSegmentId
        self.algorithmShelfCode = algorithmShelfCode
        self.algorithmSide = algorithmSide
        self.algorithmDistanceFromShelfStartCm =
            algorithmDistanceFromShelfStartCm
        self.algorithmAssociationConfidence = algorithmAssociationConfidence
        self.confirmationStatus = confirmationStatus
        self.userConfirmedShelfSegmentId = userConfirmedShelfSegmentId
        self.userConfirmedShelfCode = userConfirmedShelfCode
        self.userConfirmedSide = userConfirmedSide
        self.userConfirmedDistanceFromShelfStartCm =
            userConfirmedDistanceFromShelfStartCm
        self.confirmedAtUTC = confirmedAtUTC
        self.confirmedAtMonotonic = confirmedAtMonotonic
        self.confirmationSource = confirmationSource
    }
}

extension LocalizedPriceTag {
    func bindingCapture(
        captureID: UUID,
        observationIDs: [String]
    ) -> LocalizedPriceTag {
        return LocalizedPriceTag(
            format: format,
            version: max(2, version),
            tagId: tagId,
            observationId: observationId,
            payload: payload,
            symbology: symbology,
            floorId: floorId,
            timestamp: timestamp,
            trackingSessionId: trackingSessionId,
            priorMapId: priorMapId,
            priorMapSha256: priorMapSha256,
            shelfSegmentId: shelfSegmentId,
            shelfCode: shelfCode,
            rowFlag: rowFlag,
            crossCode: crossCode,
            shelfSide: shelfSide,
            distanceFromShelfStartCm: distanceFromShelfStartCm,
            heightCm: heightCm,
            rawMapPosition: rawMapPosition,
            snappedMapPosition: snappedMapPosition,
            localizationConfidence: localizationConfidence,
            measurementConfidence: measurementConfidence,
            associationConfidence: associationConfidence,
            measurementMethod: measurementMethod,
            needsReview: needsReview,
            userConfirmed: userConfirmed,
            captureId: captureID.uuidString.lowercased(),
            frameObservationIds: observationIDs,
            algorithmShelfSegmentId:
                algorithmShelfSegmentId ?? shelfSegmentId,
            algorithmShelfCode: algorithmShelfCode ?? shelfCode,
            algorithmSide: algorithmSide ?? shelfSide,
            algorithmDistanceFromShelfStartCm:
                algorithmDistanceFromShelfStartCm
                    ?? distanceFromShelfStartCm,
            algorithmAssociationConfidence:
                algorithmAssociationConfidence ?? associationConfidence,
            confirmationStatus: confirmationStatus ?? "ALGORITHM_ONLY",
            userConfirmedShelfSegmentId: userConfirmedShelfSegmentId,
            userConfirmedShelfCode: userConfirmedShelfCode,
            userConfirmedSide: userConfirmedSide,
            userConfirmedDistanceFromShelfStartCm:
                userConfirmedDistanceFromShelfStartCm,
            confirmedAtUTC: confirmedAtUTC,
            confirmedAtMonotonic: confirmedAtMonotonic,
            confirmationSource: confirmationSource)
    }

    func applyingConfirmation(
        decision: ShelfConfirmationDecision,
        candidates: [PriceTagShelfCandidate],
        confirmedAtUTC: TimeInterval,
        confirmedAtMonotonic: TimeInterval
    ) -> LocalizedPriceTag? {
        let candidate: PriceTagShelfCandidate
        let status: String
        switch decision {
        case .confirmedAlgorithmCandidate:
            guard let segmentID = algorithmShelfSegmentId ?? shelfSegmentId,
                  let value = candidates.first(where: {
                      $0.shelfSegmentId == segmentID
                          && $0.side == (algorithmSide ?? shelfSide)
                  }), value.isSelectable else {
                return nil
            }
            candidate = value
            status = "USER_CONFIRMED"
        case .selectedAlternative(let segmentID, let side):
            guard let value = candidates.first(where: {
                $0.shelfSegmentId == segmentID
                    && $0.side == side
                    && $0.isSelectable
            }) else {
                return nil
            }
            candidate = value
            status = candidate.shelfSegmentId
                == (algorithmShelfSegmentId ?? shelfSegmentId)
                && candidate.side == (algorithmSide ?? shelfSide)
                ? "USER_CONFIRMED"
                : "USER_OVERRIDDEN"
        case .rescan, .observationOnly:
            return nil
        }
        return LocalizedPriceTag(
            format: format,
            version: max(2, version),
            tagId: tagId,
            observationId: observationId,
            payload: payload,
            symbology: symbology,
            floorId: floorId,
            timestamp: timestamp,
            trackingSessionId: trackingSessionId,
            priorMapId: priorMapId,
            priorMapSha256: priorMapSha256,
            shelfSegmentId: shelfSegmentId,
            shelfCode: shelfCode,
            rowFlag: rowFlag,
            crossCode: crossCode,
            shelfSide: shelfSide,
            distanceFromShelfStartCm: distanceFromShelfStartCm,
            heightCm: heightCm,
            rawMapPosition: rawMapPosition,
            snappedMapPosition: snappedMapPosition,
            localizationConfidence: localizationConfidence,
            measurementConfidence: measurementConfidence,
            associationConfidence: associationConfidence,
            measurementMethod: measurementMethod,
            needsReview: needsReview,
            userConfirmed: true,
            captureId: captureId,
            frameObservationIds: frameObservationIds,
            algorithmShelfSegmentId:
                algorithmShelfSegmentId ?? shelfSegmentId,
            algorithmShelfCode: algorithmShelfCode ?? shelfCode,
            algorithmSide: algorithmSide ?? shelfSide,
            algorithmDistanceFromShelfStartCm:
                algorithmDistanceFromShelfStartCm
                    ?? distanceFromShelfStartCm,
            algorithmAssociationConfidence:
                algorithmAssociationConfidence ?? associationConfidence,
            confirmationStatus: status,
            userConfirmedShelfSegmentId: candidate.shelfSegmentId,
            userConfirmedShelfCode: candidate.shelfCode,
            userConfirmedSide: candidate.side,
            userConfirmedDistanceFromShelfStartCm:
                candidate.distanceFromStartCm,
            confirmedAtUTC: confirmedAtUTC,
            confirmedAtMonotonic: confirmedAtMonotonic,
            confirmationSource: "on_device_operator")
    }
}

private struct ShelfSideCandidate {
    let shelf: PriorMapShelf
    let side: String
    let start: SIMD2<Double>
    let end: SIMD2<Double>
    let snapped: SIMD2<Double>
    let offsetM: Double
    let distanceM: Double
    let score: Double
    let occluded: Bool
    let blockedByOtherStructure: Bool
}

private struct PriorMapShelfEdge {
    let side: String
    let start: SIMD2<Double>
    let end: SIMD2<Double>
    let length: Double
    let sourceIndex: Int
}

enum ShelfAssociation {
    private struct OccludingStructure {
        let id: String
        let geometry: PriorMapShelfGeometry
        let associateable: Bool
    }

    private static func projection(
        point: SIMD2<Double>,
        start: SIMD2<Double>,
        end: SIMD2<Double>
    ) -> (point: SIMD2<Double>, ratio: Double, distance: Double) {
        let delta = end - start
        let denominator = max(1.0e-12, simd_dot(delta, delta))
        let ratio = min(1, max(0, simd_dot(point - start, delta) / denominator))
        let projected = start + delta * ratio
        return (projected, ratio, simd_length(point - projected))
    }

    private static func associationEdges(_ shelf: PriorMapShelf) -> [PriorMapShelfEdge] {
        let coordinates = shelf.geometry.coordinates
        guard coordinates.count >= 3 else { return [] }
        let points = coordinates.compactMap { value -> SIMD2<Double>? in
            guard value.count >= 2 else { return nil }
            return SIMD2<Double>(value[0], value[1])
        }
        guard points.count >= 3 else { return [] }
        let rawEdges: [PriorMapShelfEdge] = points.indices.compactMap { index in
            let following = (index + 1) % points.count
            var start = points[index]
            var end = points[following]
            let length = simd_length(end - start)
            guard length > 1.0e-9 else { return nil }
            if start.x > end.x || (start.x == end.x && start.y > end.y) {
                swap(&start, &end)
            }
            return PriorMapShelfEdge(
                side: "",
                start: start,
                end: end,
                length: length,
                sourceIndex: index)
        }
        guard !rawEdges.isEmpty else { return [] }

        if shelf.shapeType != "MapShelf" {
            return rawEdges.sorted {
                let firstMidpoint = ($0.start + $0.end) * 0.5
                let secondMidpoint = ($1.start + $1.end) * 0.5
                if firstMidpoint.x != secondMidpoint.x {
                    return firstMidpoint.x < secondMidpoint.x
                }
                if firstMidpoint.y != secondMidpoint.y {
                    return firstMidpoint.y < secondMidpoint.y
                }
                return $0.length < $1.length
            }.enumerated().map {
                PriorMapShelfEdge(
                    side: String(format: "E%02d", $0.offset + 1),
                    start: $0.element.start,
                    end: $0.element.end,
                    length: $0.element.length,
                    sourceIndex: $0.element.sourceIndex)
            }
        }

        // MapShelf business faces are the two edges parallel to the stable
        // local long axis. Width/yaw are authoritative even for square or
        // near-square rectangles; principal-axis fallback is deterministic.
        let center = points.reduce(SIMD2<Double>(repeating: 0), +)
            / Double(points.count)
        let axis: SIMD2<Double>
        if let yaw = shelf.yawRad {
            let widthIsLong = (shelf.source?.width ?? 0) >= (shelf.source?.height ?? 0)
            let angle = yaw + (widthIsLong ? 0 : .pi / 2)
            axis = SIMD2<Double>(cos(angle), sin(angle))
        }
        else {
            let centered = points.map { $0 - center }
            let xx = centered.reduce(0) { $0 + $1.x * $1.x }
            let yy = centered.reduce(0) { $0 + $1.y * $1.y }
            let xy = centered.reduce(0) { $0 + $1.x * $1.y }
            let anisotropy = hypot(xx - yy, 2 * xy)
            let angle = anisotropy <= max(1.0e-9, (xx + yy) * 1.0e-6)
                ? 0
                : 0.5 * atan2(2 * xy, xx - yy)
            var value = SIMD2<Double>(cos(angle), sin(angle))
            if value.x < 0 || (abs(value.x) <= 1.0e-9 && value.y < 0) {
                value *= -1
            }
            axis = value
        }
        let aligned = rawEdges
            .filter {
                abs(simd_dot(($0.end - $0.start) / $0.length, axis)) >= cos(.pi / 6)
            }
            .sorted {
                abs(simd_dot(($0.end - $0.start) / $0.length, axis))
                    > abs(simd_dot(($1.end - $1.start) / $1.length, axis))
            }
        let selected = Array(aligned.prefix(2))
        let positiveNormal = SIMD2<Double>(-axis.y, axis.x)
        return selected.map { edge in
            var start = edge.start
            var end = edge.end
            if simd_dot(end - start, axis) < 0 {
                swap(&start, &end)
            }
            let midpoint = (start + end) * 0.5
            return PriorMapShelfEdge(
                side: simd_dot(midpoint - center, positiveNormal) >= 0 ? "A" : "B",
                start: start,
                end: end,
                length: edge.length,
                sourceIndex: edge.sourceIndex)
        }.sorted { $0.side < $1.side }
    }

    private static func boundaryEdges(
        _ geometry: PriorMapShelfGeometry
    ) -> [(SIMD2<Double>, SIMD2<Double>)] {
        let points = geometry.coordinates.compactMap { value -> SIMD2<Double>? in
            guard value.count >= 2 else { return nil }
            return SIMD2<Double>(value[0], value[1])
        }
        guard points.count >= 3 else { return [] }
        return points.indices.compactMap { index in
            let following = (index + 1) % points.count
            let start = points[index]
            let end = points[following]
            return simd_length(end - start) > 1.0e-9 ? (start, end) : nil
        }
    }

    private static func segmentIntersectsBeforeTarget(
        origin: SIMD2<Double>,
        target: SIMD2<Double>,
        edgeStart: SIMD2<Double>,
        edgeEnd: SIMD2<Double>
    ) -> Bool {
        let ray = target - origin
        let edge = edgeEnd - edgeStart
        let denominator = ray.x * edge.y - ray.y * edge.x
        guard abs(denominator) > 1.0e-9 else { return false }
        let delta = edgeStart - origin
        let rayRatio = (delta.x * edge.y - delta.y * edge.x) / denominator
        let edgeRatio = (delta.x * ray.y - delta.y * ray.x) / denominator
        return rayRatio > 0.02
            && rayRatio < 0.95
            && edgeRatio >= 0
            && edgeRatio <= 1
    }

    private static func associationCandidates(
        rawPosition: PriorMapTagPoint3D,
        cameraPosition: SIMD2<Double>,
        shelves: [PriorMapShelf],
        fixedStructures: [PriorMapFixedStructure]
    ) -> [ShelfSideCandidate] {
        let tag = SIMD2<Double>(rawPosition.xM, rawPosition.yM)
        let cameraRay = tag - cameraPosition
        let rayLength = max(1.0e-9, simd_length(cameraRay))
        let associationSurfaces = shelves + fixedStructures.compactMap(\.associationSurface)
        let occluders = shelves.map {
            OccludingStructure(id: $0.id, geometry: $0.geometry, associateable: true)
        } + fixedStructures.map {
            OccludingStructure(
                id: $0.id,
                geometry: $0.geometry,
                associateable: $0.associationSurface != nil)
        }
        return associationSurfaces.flatMap { shelf in
            let sides = associationEdges(shelf)
            return sides.compactMap { edge -> ShelfSideCandidate? in
                let projected = projection(
                    point: tag,
                    start: edge.start,
                    end: edge.end)
                guard projected.distance <= 1.20 else { return nil }
                let delta = edge.end - edge.start
                let edgeLength = max(1.0e-9, edge.length)
                var normal = SIMD2<Double>(
                    -delta.y / edgeLength,
                    delta.x / edgeLength)
                if simd_dot(cameraPosition - projected.point, normal) < 0 {
                    normal *= -1
                }
                let facing = max(
                    0,
                    simd_dot(-cameraRay / rayLength, normal))
                let endpointPenalty = projected.ratio <= 0.02 || projected.ratio >= 0.98
                    ? 0.18
                    : 0
                let blockedByOtherStructure = occluders.contains { structure in
                    guard structure.id != shelf.id else { return false }
                    return boundaryEdges(structure.geometry).contains { blocker in
                        segmentIntersectsBeforeTarget(
                            origin: cameraPosition,
                            target: projected.point,
                            edgeStart: blocker.0,
                            edgeEnd: blocker.1)
                    }
                }
                let hiddenByOwnFarFace = sides
                    .filter { $0.side != edge.side }
                    .contains { blocker in
                        segmentIntersectsBeforeTarget(
                            origin: cameraPosition,
                            target: projected.point,
                            edgeStart: blocker.start,
                            edgeEnd: blocker.end)
                    }
                let occluded = blockedByOtherStructure || hiddenByOwnFarFace
                let score = max(
                    0,
                    1
                        - projected.distance / 1.20
                        - endpointPenalty
                        + 0.20 * facing)
                return ShelfSideCandidate(
                    shelf: shelf,
                    side: edge.side,
                    start: edge.start,
                    end: edge.end,
                    snapped: projected.point,
                    offsetM: projected.ratio * edgeLength,
                    distanceM: projected.distance,
                    score: min(1, score),
                    occluded: occluded,
                    blockedByOtherStructure: blockedByOtherStructure)
            }
        }.sorted { first, second in
            if first.score != second.score {
                return first.score > second.score
            }
            if first.shelf.id != second.shelf.id {
                return first.shelf.id < second.shelf.id
            }
            return first.side < second.side
        }
    }

    static func rayIntersection(
        origin: SIMD2<Double>,
        direction: SIMD2<Double>,
        shelves: [PriorMapShelf],
        fixedStructures: [PriorMapFixedStructure] = [],
        floorId: String,
        maximumDistanceM: Double = 5.0
    ) -> PriorMapTagPoint3D? {
        let rayLength = simd_length(direction)
        guard rayLength > 1.0e-9 else { return nil }
        let ray = direction / rayLength
        var nearest: (distance: Double, point: SIMD2<Double>, associateable: Bool)?
        let structures = shelves
            .filter { $0.floorId == floorId }
            .map { OccludingStructure(id: $0.id, geometry: $0.geometry, associateable: true) }
            + fixedStructures
                .filter { $0.floorId == floorId }
                .map {
                    OccludingStructure(
                        id: $0.id,
                        geometry: $0.geometry,
                        associateable: $0.associationSurface != nil)
                }
        for structure in structures {
            for edge in boundaryEdges(structure.geometry) {
                let deltaEdge = edge.1 - edge.0
                let denominator =
                    ray.x * deltaEdge.y - ray.y * deltaEdge.x
                guard abs(denominator) > 1.0e-8 else { continue }
                let delta = edge.0 - origin
                let distance =
                    (delta.x * deltaEdge.y - delta.y * deltaEdge.x)
                    / denominator
                let edgeRatio = (delta.x * ray.y - delta.y * ray.x) / denominator
                guard distance >= 0.2,
                      distance <= maximumDistanceM,
                      edgeRatio >= 0,
                      edgeRatio <= 1 else {
                    continue
                }
                let point = origin + ray * distance
                if nearest.map({ distance < $0.distance }) ?? true {
                    nearest = (distance, point, structure.associateable)
                }
            }
        }
        guard let nearest, nearest.associateable else { return nil }
        return PriorMapTagPoint3D(
            xM: nearest.point.x,
            yM: nearest.point.y,
            heightM: nil)
    }

    static func localizedTag(
        observationId: String,
        payload: String,
        symbology: String,
        floorId: String,
        rawPosition: PriorMapTagPoint3D?,
        cameraPosition: SIMD2<Double>,
        shelves: [PriorMapShelf],
        fixedStructures: [PriorMapFixedStructure] = [],
        localizationState: String,
        localizationConfidence: Double,
        measurementConfidence: Double,
        measurementMethod: String,
        userConfirmed: Bool,
        trackingSessionId: String = "",
        priorMapId: String = "",
        priorMapSha256: String = "",
        timestamp: TimeInterval = 0
    ) -> LocalizedPriceTag {
        return localizedTagResult(
            observationId: observationId,
            payload: payload,
            symbology: symbology,
            floorId: floorId,
            rawPosition: rawPosition,
            cameraPosition: cameraPosition,
            shelves: shelves,
            fixedStructures: fixedStructures,
            localizationState: localizationState,
            localizationConfidence: localizationConfidence,
            measurementConfidence: measurementConfidence,
            measurementMethod: measurementMethod,
            userConfirmed: userConfirmed,
            trackingSessionId: trackingSessionId,
            priorMapId: priorMapId,
            priorMapSha256: priorMapSha256,
            timestamp: timestamp).tag
    }

    static func localizedTagResult(
        observationId: String,
        payload: String,
        symbology: String,
        floorId: String,
        rawPosition: PriorMapTagPoint3D?,
        cameraPosition: SIMD2<Double>,
        shelves: [PriorMapShelf],
        fixedStructures: [PriorMapFixedStructure] = [],
        localizationState: String,
        localizationConfidence: Double,
        measurementConfidence: Double,
        measurementMethod: String,
        userConfirmed: Bool,
        trackingSessionId: String = "",
        priorMapId: String = "",
        priorMapSha256: String = "",
        timestamp: TimeInterval = 0
    ) -> PriceTagShelfAssociationResult {
        let candidates = rawPosition.map {
            associationCandidates(
                rawPosition: $0,
                cameraPosition: cameraPosition,
                shelves: shelves.filter { $0.floorId == floorId },
                fixedStructures: fixedStructures.filter { $0.floorId == floorId })
        } ?? []
        // If the geometrically best surface is hidden, do not silently select
        // a farther surface. The UI may still retain the raw observation for
        // explicit review, but it receives no default structure assignment.
        let best = candidates.first?.blockedByOtherStructure == false
            ? candidates.first
            : nil
        let second = best == nil ? nil : candidates.dropFirst().first
        let margin = best.map { $0.score - (second?.score ?? 0) } ?? 0
        let associationConfidence = best.map {
            min(1, max(0, $0.score * min(1, margin / 0.20 + 0.35)))
        } ?? 0
        let endpointAmbiguous = best.map {
            let length = simd_length($0.end - $0.start)
            return $0.offsetM <= 0.05 || $0.offsetM >= max(0, length - 0.05)
        } ?? true
        // Only ordinary Local evidence that has reached stable may authorize
        // automatic confirmation. Recovery-active, just-converged/usable, and
        // timed-out evidence always remains review-only.
        let stateAllowsAutomatic = localizationState == "stable"
        let needsReview = !stateAllowsAutomatic
            || rawPosition == nil
            || rawPosition?.heightM == nil
            || measurementConfidence < 0.65
            || associationConfidence < 0.65
            || endpointAmbiguous
            || (best?.occluded ?? false)
            || best == nil
        let snapped = best.map {
            PriorMapTagPoint3D(
                xM: $0.snapped.x,
                yM: $0.snapped.y,
                heightM: rawPosition?.heightM)
        }
        let publicCandidates = candidates.prefix(5).map { candidate in
            PriceTagShelfCandidate(
                shelfSegmentId: candidate.shelf.id,
                shelfCode: candidate.shelf.code,
                rowFlag: candidate.shelf.rowFlag,
                crossCode: candidate.shelf.crossCode,
                side: candidate.side,
                distanceFromStartCm: candidate.offsetM * 100,
                distanceToShelfM: candidate.distanceM,
                associationConfidence: min(1, max(0, candidate.score)),
                occluded: candidate.occluded,
                blockedByOtherStructure: candidate.blockedByOtherStructure,
                snappedPosition: PriorMapTagPoint3D(
                    xM: candidate.snapped.x,
                    yM: candidate.snapped.y,
                    heightM: rawPosition?.heightM),
                outline: candidate.shelf.geometry.coordinates.compactMap {
                    guard $0.count >= 2,
                          $0[0].isFinite,
                          $0[1].isFinite else {
                        return nil
                    }
                    return PriceTagShelfPreviewPoint(xM: $0[0], yM: $0[1])
                })
        }
        let tag = LocalizedPriceTag(
            format: "MarketScannerLocalizedPriceTag",
            version: 2,
            tagId: UUID().uuidString,
            observationId: observationId,
            payload: payload,
            symbology: symbology,
            floorId: floorId,
            timestamp: timestamp,
            trackingSessionId: trackingSessionId,
            priorMapId: priorMapId,
            priorMapSha256: priorMapSha256,
            shelfSegmentId: best?.shelf.id,
            shelfCode: best?.shelf.code,
            rowFlag: best?.shelf.rowFlag,
            crossCode: best?.shelf.crossCode,
            shelfSide: best?.side,
            distanceFromShelfStartCm: best.map { $0.offsetM * 100.0 },
            heightCm: rawPosition.flatMap(\.heightM).map { $0 * 100.0 },
            rawMapPosition: rawPosition,
            snappedMapPosition: snapped,
            localizationConfidence: localizationConfidence,
            measurementConfidence: measurementConfidence,
            associationConfidence: associationConfidence,
            measurementMethod: measurementMethod,
            needsReview: needsReview,
            userConfirmed: userConfirmed,
            algorithmShelfSegmentId: best?.shelf.id,
            algorithmShelfCode: best?.shelf.code,
            algorithmSide: best?.side,
            algorithmDistanceFromShelfStartCm:
                best.map { $0.offsetM * 100 },
            algorithmAssociationConfidence: associationConfidence,
            confirmationStatus: "ALGORITHM_ONLY")
        return PriceTagShelfAssociationResult(
            tag: tag,
            candidates: publicCandidates,
            algorithmCandidateReliable: !needsReview && best != nil)
    }
}
