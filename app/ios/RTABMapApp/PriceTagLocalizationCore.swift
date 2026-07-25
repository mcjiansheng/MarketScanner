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
            if candidate.count >= 12
                && (
                    bestRange == nil
                    || depths[candidate.lowerBound] < depths[bestRange!.lowerBound] - 0.02
                    || (
                        abs(depths[candidate.lowerBound] - depths[bestRange!.lowerBound]) <= 0.02
                        && candidate.count > bestRange!.count
                    )
                ) {
                bestRange = candidate
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
        let containsGlobalMedian = globalMedian >= cluster.first!
            && globalMedian <= cluster.last!
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

    func withPlane(residualM: Double, normalCamera: SIMD3<Double>?) -> PriceTagDepthEvidence {
        let validNormal = normalCamera.flatMap { normal -> [Double]? in
            let length = simd_length(normal)
            guard length > 1.0e-9 else { return nil }
            let unit = normal / length
            return [unit.x, unit.y, unit.z]
        }
        let planeAccepted = accepted
            && residualM.isFinite
            && residualM <= 0.06
            && validNormal != nil
        let planeQuality = min(1, max(0, 1 - residualM / 0.06))
        return PriceTagDepthEvidence(
            sampleCount: sampleCount,
            inlierCount: inlierCount,
            inlierRatio: inlierRatio,
            medianM: medianM,
            madM: madM,
            planeResidualM: residualM,
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

struct PriorMapShelfGeometry: Codable {
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

struct PriorMapTagObservationRecord: Codable {
    let format: String
    let version: Int
    let observationId: String
    let timestamp: TimeInterval
    let payload: String
    let symbology: String
    let normalizedBounds: [Double]
    let frameTimestamp: TimeInterval
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

    enum CodingKeys: String, CodingKey {
        case format
        case version
        case observationId = "observation_id"
        case timestamp
        case payload
        case symbology
        case normalizedBounds = "normalized_bounds"
        case frameTimestamp = "frame_timestamp"
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
    }
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
    }
}

extension LocalizedPriceTag {
    func confirmedByUser() -> LocalizedPriceTag {
        return LocalizedPriceTag(
            format: format,
            version: version,
            tagId: tagId,
            observationId: observationId,
            payload: payload,
            symbology: symbology,
            floorId: floorId,
            timestamp: timestamp,
            trackingSessionId: trackingSessionId,
            priorMapId: priorMapId,
            priorMapSha256: priorMapSha256,
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
            userConfirmed: true)
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
                if nearest == nil || distance < nearest!.distance {
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
        let stateAllowsAutomatic = localizationState == "stable"
            || localizationState == "usable"
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
        return LocalizedPriceTag(
            format: "MarketScannerLocalizedPriceTag",
            version: 1,
            tagId: UUID().uuidString,
            observationId: observationId,
            payload: payload,
            symbology: symbology,
            floorId: floorId,
            timestamp: timestamp,
            trackingSessionId: trackingSessionId,
            priorMapId: priorMapId,
            priorMapSha256: priorMapSha256,
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
            userConfirmed: userConfirmed)
    }
}
