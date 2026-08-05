import Foundation

/// Associates a finalized tag position with the nearest shelf segment
/// and the automatic quality gate that decides ACCEPTED vs
/// RESCAN_REQUIRED.
enum ShelfAssociationEngine {
    struct ShelfSegment {
        var shelfCode: String
        var floorID: String
        var startM: (Double, Double)
        var endM: (Double, Double)
        var side: String // "front" | "back"
    }

    struct Association {
        var shelfCode: String
        var shelfSide: String
        var distanceFromShelfStartCm: Double
        var positionRatio: Double
        var distanceToSegmentM: Double
        var distanceFromStartM: Double
        var segmentLengthM: Double
        var atEndpoint: Bool
    }

    /// Projects point P onto segment A-B:
    /// s = dot(P-A, d)/|d|, u = s/|d|, distance_from_shelf_start_cm = s*100.
    static func associate(
        point: (Double, Double),
        shelf: ShelfSegment,
        floorID: String,
        endpointMarginM: Double = 0.15
    ) -> Association? {
        guard shelf.floorID == floorID else { return nil }
        let dx = shelf.endM.0 - shelf.startM.0
        let dy = shelf.endM.1 - shelf.startM.1
        let length = hypot(dx, dy)
        guard length > 1.0e-9 else { return nil }
        let px = point.0 - shelf.startM.0
        let py = point.1 - shelf.startM.1
        let ratio = max(0.0, min(1.0, (px * dx + py * dy) / (length * length)))
        let s = ratio * length
        let projectedX = shelf.startM.0 + ratio * dx
        let projectedY = shelf.startM.1 + ratio * dy
        let distanceToSegment = hypot(point.0 - projectedX, point.1 - projectedY)
        let atEndpoint = s < endpointMarginM || s > length - endpointMarginM
        return Association(
            shelfCode: shelf.shelfCode,
            shelfSide: shelf.side,
            distanceFromShelfStartCm: SourceGeometry.rounded(s * 100.0),
            positionRatio: SourceGeometry.rounded(ratio),
            distanceToSegmentM: SourceGeometry.rounded(distanceToSegment),
            distanceFromStartM: SourceGeometry.rounded(s),
            segmentLengthM: SourceGeometry.rounded(length),
            atEndpoint: atEndpoint
        )
    }

    /// Chooses the best (closest) shelf for a tag point across the
    /// candidate segments of the floor.
    static func bestAssociation(
        point: (Double, Double),
        shelves: [ShelfSegment],
        floorID: String
    ) -> Association? {
        var best: Association?
        var bestDistance = Double.infinity
        for shelf in shelves {
            guard let association = associate(point: point, shelf: shelf, floorID: floorID) else {
                continue
            }
            if association.distanceToSegmentM < bestDistance {
                bestDistance = association.distanceToSegmentM
                best = association
            }
        }
        return best
    }
}

/// The automatic quality gate. Uncertain results become
/// RESCAN_REQUIRED; the system never guesses.
enum AutomaticQualityGate {
    struct TagQualityInput {
        var observationCount: Int
        var positionSpreadM: Double
        var minimumBurstSamples: Int
        var maximumSpreadM: Double
        var bindingMethod: String
        var association: ShelfAssociationEngine.Association
        var maximumEndpointDistanceM: Double
        var maximumAssociationDistanceM: Double
        var graphQualityPassed: Bool
        var mapSessionIdentityConsistent: Bool
    }

    enum QualityStatus: String {
        case accepted = "ACCEPTED"
        case rescanRequired = "RESCAN_REQUIRED"
    }

    static func evaluate(_ input: TagQualityInput) -> (QualityStatus, String) {
        guard input.mapSessionIdentityConsistent else {
            return (.rescanRequired, "map_session_identity_mismatch")
        }
        guard input.graphQualityPassed else {
            return (.rescanRequired, "graph_quality_failed")
        }
        guard input.bindingMethod != "stale_alignment" else {
            return (.rescanRequired, "stale_alignment")
        }
        guard input.observationCount >= input.minimumBurstSamples else {
            return (.rescanRequired, "insufficient_burst_samples")
        }
        guard input.positionSpreadM <= input.maximumSpreadM else {
            return (.rescanRequired, "position_spread_exceeded")
        }
        guard input.association.distanceToSegmentM <= input.maximumAssociationDistanceM else {
            return (.rescanRequired, "shelf_association_distance_exceeded")
        }
        guard !input.association.atEndpoint else {
            return (.rescanRequired, "shelf_endpoint_ambiguity")
        }
        guard input.association.shelfSide == "front" || input.association.shelfSide == "back" else {
            return (.rescanRequired, "shelf_side_ambiguous")
        }
        return (.accepted, "")
    }
}
