//
//  PriceTagLocalizationCore.swift
//  RTABMapApp
//
//  Platform-neutral tag measurement result and shelf association.
//

import Foundation
import simd

struct PriorMapShelf: Codable {
    let id: String
    let floorId: String
    let code: String?
    let crossCode: String?
    let rowFlag: String?
    let geometry: PriorMapShelfGeometry

    enum CodingKeys: String, CodingKey {
        case id
        case floorId = "floor_id"
        case code
        case crossCode = "cross_code"
        case rowFlag = "row_flag"
        case geometry
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
    let rawMapPosition: PriorMapTagPoint3D?
    let measurementMethod: String
    let measurementConfidence: Double
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
        case rawMapPosition = "raw_map_position"
        case measurementMethod = "measurement_method"
        case measurementConfidence = "measurement_confidence"
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
}

private struct PriorMapShelfEdge {
    let side: String
    let start: SIMD2<Double>
    let end: SIMD2<Double>
    let length: Double
    let sourceIndex: Int
}

enum ShelfAssociation {
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

    private static func longSides(_ shelf: PriorMapShelf) -> [PriorMapShelfEdge] {
        let coordinates = shelf.geometry.coordinates
        guard coordinates.count >= 3 else { return [] }
        let points = coordinates.compactMap { value -> SIMD2<Double>? in
            guard value.count >= 2 else { return nil }
            return SIMD2<Double>(value[0], value[1])
        }
        guard points.count >= 3 else { return [] }
        let edges: [PriorMapShelfEdge] = points.indices.map { index in
            let following = (index + 1) % points.count
            let start = points[index]
            let end = points[following]
            let length = simd_length(end - start)
            return PriorMapShelfEdge(
                side: "",
                start: start,
                end: end,
                length: length,
                sourceIndex: index)
        }.sorted {
            $0.length == $1.length
                ? $0.sourceIndex < $1.sourceIndex
                : $0.length > $1.length
        }
        return edges.prefix(2).enumerated().map {
            PriorMapShelfEdge(
                side: $0.offset == 0 ? "A" : "B",
                start: $0.element.start,
                end: $0.element.end,
                length: $0.element.length,
                sourceIndex: $0.element.sourceIndex)
        }
    }

    private static func associationCandidates(
        rawPosition: PriorMapTagPoint3D,
        cameraPosition: SIMD2<Double>,
        shelves: [PriorMapShelf]
    ) -> [ShelfSideCandidate] {
        let tag = SIMD2<Double>(rawPosition.xM, rawPosition.yM)
        let cameraRay = tag - cameraPosition
        let rayLength = max(1.0e-9, simd_length(cameraRay))
        return shelves.flatMap { shelf in
            let sides = longSides(shelf)
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
                let occluded = sides.contains { other in
                    guard other.side != edge.side else { return false }
                    let otherDelta = other.end - other.start
                    let denominator =
                        cameraRay.x * otherDelta.y
                        - cameraRay.y * otherDelta.x
                    guard abs(denominator) > 1.0e-9 else { return false }
                    let originDelta = other.start - cameraPosition
                    let rayRatio =
                        (originDelta.x * otherDelta.y
                            - originDelta.y * otherDelta.x)
                        / denominator
                    let edgeRatio =
                        (originDelta.x * cameraRay.y
                            - originDelta.y * cameraRay.x)
                        / denominator
                    return rayRatio > 0.02
                        && rayRatio < 0.95
                        && edgeRatio >= 0
                        && edgeRatio <= 1
                }
                let score = max(
                    0,
                    1
                        - projected.distance / 1.20
                        - endpointPenalty
                        - (occluded ? 0.35 : 0)
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
                    occluded: occluded)
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
        floorId: String,
        maximumDistanceM: Double = 5.0
    ) -> PriorMapTagPoint3D? {
        let rayLength = simd_length(direction)
        guard rayLength > 1.0e-9 else { return nil }
        let ray = direction / rayLength
        var nearest: (distance: Double, point: SIMD2<Double>)?
        for shelf in shelves where shelf.floorId == floorId {
            for edge in longSides(shelf) {
                let deltaEdge = edge.end - edge.start
                let denominator =
                    ray.x * deltaEdge.y - ray.y * deltaEdge.x
                guard abs(denominator) > 1.0e-8 else { continue }
                let delta = edge.start - origin
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
                    nearest = (distance, point)
                }
            }
        }
        return nearest.map {
            PriorMapTagPoint3D(xM: $0.point.x, yM: $0.point.y, heightM: nil)
        }
    }

    static func localizedTag(
        observationId: String,
        payload: String,
        symbology: String,
        floorId: String,
        rawPosition: PriorMapTagPoint3D?,
        cameraPosition: SIMD2<Double>,
        shelves: [PriorMapShelf],
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
                shelves: shelves.filter { $0.floorId == floorId })
        } ?? []
        let best = candidates.first
        let second = candidates.dropFirst().first
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
