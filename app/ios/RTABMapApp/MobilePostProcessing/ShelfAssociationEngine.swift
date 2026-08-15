import Foundation

/// Associates a finalized tag position with the nearest shelf segment
/// and the automatic quality gate that decides ACCEPTED,
/// LOW_CONFIDENCE or RESCAN_REQUIRED.
///
/// Shelf geometry follows V1R4 §13.5: the longitudinal axis, start/end,
/// front/back normals, closed polygon and side regions are computed from
/// the rotated polygon / axis; the AABB is only an index envelope and
/// can never replace the rotated geometry.
enum ShelfAssociationEngine {

    // MARK: - Geometry

    struct ShelfSegment {
        /// Stable primary key from the compiled package. Shelf codes are
        /// display/business labels and are not unique across an aisle.
        var shelfSegmentID: String
        var shelfCode: String
        var floorID: String
        /// Longitudinal axis start/end (metres, map frame).
        var startM: (Double, Double)
        var endM: (Double, Double)
        /// Unit longitudinal axis (start → end).
        var axisM: (Double, Double)
        /// Unit face normal; a tag with a positive lateral offset
        /// (dot(point - start, normal) > 0) is on the "front" side,
        /// otherwise on the "back" side (§13.5 side regions).
        var frontNormalM: (Double, Double)
        var backNormalM: (Double, Double)
        /// AABB used ONLY as an index envelope (§13.5).
        var boundsMinM: (Double, Double)
        var boundsMaxM: (Double, Double)
        /// Closed polygon vertices (metres) when the compiled package
        /// carries rotated geometry; nil when only bounds are available.
        var polygonM: [(Double, Double)]?
        /// V1R5 §12.2: "element_yaw" when the front normal came from the
        /// compiler's business semantics, "geometry" when derived from
        /// geometry, "unavailable" when the source carried no business
        /// orientation (side must then be SIDE_UNAVAILABLE).
        var orientationProvenance: String

        var lengthM: Double {
            return hypot(endM.0 - startM.0, endM.1 - startM.1)
        }

        /// Convenience initializer for the compiled element fields.
        init(
            shelfSegmentID: String? = nil,
            shelfCode: String,
            floorID: String,
            startM: (Double, Double),
            endM: (Double, Double),
            axisM: (Double, Double),
            frontNormalM: (Double, Double),
            backNormalM: (Double, Double)? = nil,
            boundsMinM: (Double, Double),
            boundsMaxM: (Double, Double),
            polygonM: [(Double, Double)]?,
            orientationProvenance: String = "geometry"
        ) {
            self.shelfSegmentID = shelfSegmentID ?? shelfCode
            self.shelfCode = shelfCode
            self.floorID = floorID
            self.startM = startM
            self.endM = endM
            self.axisM = axisM
            self.frontNormalM = frontNormalM
            self.backNormalM = backNormalM
                ?? (-frontNormalM.0, -frontNormalM.1)
            self.boundsMinM = boundsMinM
            self.boundsMaxM = boundsMaxM
            self.polygonM = polygonM
            self.orientationProvenance = orientationProvenance
        }

        /// Lateral offset (metres) of a point relative to the face
        /// normal: positive = front side, negative = back side.
        func lateralOffsetM(point: (Double, Double)) -> Double {
            return (point.0 - startM.0) * frontNormalM.0
                + (point.1 - startM.1) * frontNormalM.1
        }

        func side(for point: (Double, Double)) -> String {
            return lateralOffsetM(point: point) >= 0 ? "front" : "back"
        }

        /// Signed centreline-to-face offset for the selected physical long
        /// edge. Rotated polygon geometry is authoritative; the AABB corners
        /// are a legacy-package fallback only.
        func faceOffsetM(side: String) -> Double {
            let vertices: [(Double, Double)]
            if let polygonM, polygonM.count >= 3 {
                vertices = polygonM
            } else {
                vertices = [
                    boundsMinM,
                    (boundsMinM.0, boundsMaxM.1),
                    boundsMaxM,
                    (boundsMaxM.0, boundsMinM.1),
                ]
            }
            let offsets = vertices.map { lateralOffsetM(point: $0) }
            guard let minimum = offsets.min(), let maximum = offsets.max() else {
                return 0
            }
            return side == "front" ? maximum : minimum
        }

        func boundsContains(x: Double, y: Double) -> Bool {
            return x >= boundsMinM.0 && x <= boundsMaxM.0
                && y >= boundsMinM.1 && y <= boundsMaxM.1
        }
    }

    /// Computes the shelf geometry from the compiled element fields
    /// (V1R4 §13.5). The rotated polygon, when present, defines the
    /// longitudinal axis (PCA of the vertex set); the AABB is only an
    /// index envelope. The front normal is the axis rotated -90 degrees
    /// (clockwise), giving a deterministic front/back split; a `yawRad`
    /// (when present) fixes the axis sign so the front side is
    /// reproducible across sessions.
    static func makeSegment(
        shelfSegmentID: String? = nil,
        shelfCode: String,
        floorID: String,
        polygonM: [(Double, Double)]?,
        boundsMinM: (Double, Double)?,
        boundsMaxM: (Double, Double)?,
        yawRad: Double?,
        compiledFrontNormal: (Double, Double)? = nil,
        orientationProvenance: String = "geometry"
    ) -> ShelfSegment? {
        var axis: (Double, Double)?
        var start: (Double, Double)?
        var end: (Double, Double)?
        var envelopeMin = boundsMinM
        var envelopeMax = boundsMaxM
        if let polygon = polygonM, polygon.count >= 4 {
            // Closed rotated polygon: PCA main axis (longest dimension).
            var centroidX = 0.0
            var centroidY = 0.0
            for vertex in polygon {
                centroidX += vertex.0
                centroidY += vertex.1
            }
            centroidX /= Double(polygon.count)
            centroidY /= Double(polygon.count)
            var sxx = 0.0
            var syy = 0.0
            var sxy = 0.0
            for vertex in polygon {
                let dx = vertex.0 - centroidX
                let dy = vertex.1 - centroidY
                sxx += dx * dx
                syy += dy * dy
                sxy += dx * dy
            }
            let theta = 0.5 * atan2(2.0 * sxy, sxx - syy)
            var computedAxis = (cos(theta), sin(theta))
            // Sign alignment with the optional yaw so the front side is
            // reproducible.
            if let yaw = yawRad, yaw.isFinite {
                let yawAxis = (cos(yaw), sin(yaw))
                if computedAxis.0 * yawAxis.0 + computedAxis.1 * yawAxis.1 < 0 {
                    computedAxis = (-computedAxis.0, -computedAxis.1)
                }
            }
            axis = computedAxis
            // start/end = the extreme projections on the main axis. The
            // axis passes through the centroid, so the endpoints are
            // centroid + t * axis; using vertex coordinates directly
            // would skew the segment direction off the axis (§13.5).
            var minProjection = Double.infinity
            var maxProjection = -Double.infinity
            for vertex in polygon {
                let projection =
                    (vertex.0 - centroidX) * computedAxis.0
                    + (vertex.1 - centroidY) * computedAxis.1
                minProjection = min(minProjection, projection)
                maxProjection = max(maxProjection, projection)
            }
            start = (
                centroidX + minProjection * computedAxis.0,
                centroidY + minProjection * computedAxis.1)
            end = (
                centroidX + maxProjection * computedAxis.0,
                centroidY + maxProjection * computedAxis.1)
            // Envelope from the polygon when bounds are missing.
            if envelopeMin == nil || envelopeMax == nil {
                var minX = Double.infinity
                var minY = Double.infinity
                var maxX = -Double.infinity
                var maxY = -Double.infinity
                for vertex in polygon {
                    minX = min(minX, vertex.0)
                    minY = min(minY, vertex.1)
                    maxX = max(maxX, vertex.0)
                    maxY = max(maxY, vertex.1)
                }
                envelopeMin = (minX, minY)
                envelopeMax = (maxX, maxY)
            }
        } else if let minBound = boundsMinM, let maxBound = boundsMaxM {
            // AABB-only fallback: the long side is the axis (the AABB is
            // still only an envelope; a rotated shelf without geometry is
            // degraded but resolvable).
            let horizontal = (maxBound.0 - minBound.0) >= (maxBound.1 - minBound.1)
            if horizontal {
                axis = (1.0, 0.0)
                start = (minBound.0, (minBound.1 + maxBound.1) / 2.0)
                end = (maxBound.0, (minBound.1 + maxBound.1) / 2.0)
            } else {
                axis = (0.0, 1.0)
                start = ((minBound.0 + maxBound.0) / 2.0, minBound.1)
                end = ((minBound.0 + maxBound.0) / 2.0, maxBound.1)
            }
            envelopeMin = minBound
            envelopeMax = maxBound
        }
        guard let axis = axis, let start = start, let end = end,
              let envelopeMin = envelopeMin, let envelopeMax = envelopeMax,
              envelopeMax.0 >= envelopeMin.0, envelopeMax.1 >= envelopeMin.1,
              hypot(end.0 - start.0, end.1 - start.1) > 1.0e-9 else {
            return nil
        }
        // V1R5 §12.2: the front normal is AUTHORITATIVE when the
        // compiler emitted business semantics (element_yaw). The axis
        // follows from the normal (axis = (-normal.y, normal.x) since
        // normal = (axis.y, -axis.x)); geometry only supplies the
        // longitudinal endpoints. With no business orientation the side
        // stays SIDE_UNAVAILABLE (never guessed).
        let normal: (Double, Double)
        if let compiled = compiledFrontNormal {
            normal = compiled
        } else {
            // Front normal = axis rotated clockwise 90 degrees.
            normal = (axis.1, -axis.0)
        }
        return ShelfSegment(
            shelfSegmentID: shelfSegmentID,
            shelfCode: shelfCode,
            floorID: floorID,
            startM: start,
            endM: end,
            axisM: axis,
            frontNormalM: normal,
            boundsMinM: envelopeMin,
            boundsMaxM: envelopeMax,
            polygonM: polygonM,
            orientationProvenance: orientationProvenance)
    }

    /// Builds a production v2 shelf directly from compiler-authored
    /// start/end/axis/front/back semantics. Polygon and bounds are used
    /// only for the spatial-index envelope; they cannot change the
    /// business direction or side classification.
    static func makeCompiledSegment(
        _ compiled: PriorMapShelfSegmentV2,
        polygonM: [(Double, Double)]?,
        boundsMinM: (Double, Double)?,
        boundsMaxM: (Double, Double)?
    ) -> ShelfSegment? {
        var envelopeMin = boundsMinM
        var envelopeMax = boundsMaxM
        if envelopeMin == nil || envelopeMax == nil {
            let envelopePoints = (polygonM ?? [])
                + [
                    (compiled.longitudinalStartM[0], compiled.longitudinalStartM[1]),
                    (compiled.longitudinalEndM[0], compiled.longitudinalEndM[1]),
                ]
            guard !envelopePoints.isEmpty else { return nil }
            envelopeMin = (
                envelopePoints.map(\.0).min()!,
                envelopePoints.map(\.1).min()!)
            envelopeMax = (
                envelopePoints.map(\.0).max()!,
                envelopePoints.map(\.1).max()!)
        }
        guard let envelopeMin, let envelopeMax,
              envelopeMax.0 >= envelopeMin.0,
              envelopeMax.1 >= envelopeMin.1 else {
            return nil
        }
        return ShelfSegment(
            shelfSegmentID: compiled.shelfSegmentID,
            shelfCode: compiled.shelfCode,
            floorID: compiled.floorID,
            startM: (
                compiled.longitudinalStartM[0],
                compiled.longitudinalStartM[1]),
            endM: (
                compiled.longitudinalEndM[0],
                compiled.longitudinalEndM[1]),
            axisM: (
                compiled.longitudinalAxis[0],
                compiled.longitudinalAxis[1]),
            frontNormalM: (
                compiled.frontNormal[0], compiled.frontNormal[1]),
            backNormalM: (
                compiled.backNormal[0], compiled.backNormal[1]),
            boundsMinM: envelopeMin,
            boundsMaxM: envelopeMax,
            polygonM: polygonM,
            orientationProvenance: compiled.orientationProvenance)
    }

    // MARK: - Spatial index (V1R4 §13.3: shelf grid)

    /// Lightweight uniform grid over the shelf AABBs (per floor). Query
    /// is O(1) average: the point's cell plus its 3x3 neighbourhood;
    /// shelves are inserted into every cell their envelope covers.
    struct ShelfSpatialIndex {
        static let cellSizeM = 8.0

        private var cells: [String: [ShelfSegment]] = [:]

        init(shelves: [ShelfSegment]) {
            for shelf in shelves {
                let minCellX = Self.cellIndex(shelf.boundsMinM.0)
                let maxCellX = Self.cellIndex(shelf.boundsMaxM.0)
                let minCellY = Self.cellIndex(shelf.boundsMinM.1)
                let maxCellY = Self.cellIndex(shelf.boundsMaxM.1)
                for cellX in minCellX...maxCellX {
                    for cellY in minCellY...maxCellY {
                        let key = Self.key(floorID: shelf.floorID, cellX: cellX, cellY: cellY)
                        cells[key, default: []].append(shelf)
                    }
                }
            }
        }

        private static func cellIndex(_ coordinate: Double) -> Int {
            // Floor towards negative infinity so negative coordinates
            // land in the correct cells.
            return Int(floor(coordinate / cellSizeM))
        }

        private static func key(floorID: String, cellX: Int, cellY: Int) -> String {
            return "\(floorID):\(cellX):\(cellY)"
        }

        /// Candidate shelves whose envelope intersects the query cell
        /// neighbourhood (the tag may sit just outside a shelf's AABB).
        func candidates(point: (Double, Double), floorID: String) -> [ShelfSegment] {
            let centerX = Self.cellIndex(point.0)
            let centerY = Self.cellIndex(point.1)
            var result: [ShelfSegment] = []
            var seen = Set<String>()
            for cellX in (centerX - 1)...(centerX + 1) {
                for cellY in (centerY - 1)...(centerY + 1) {
                    guard let bucket = cells[Self.key(floorID: floorID, cellX: cellX, cellY: cellY)] else {
                        continue
                    }
                    for shelf in bucket where seen.insert(shelf.shelfSegmentID).inserted {
                        result.append(shelf)
                    }
                }
            }
            return result
        }
    }

    // MARK: - Association

    struct Association {
        var shelfSegmentID: String
        var shelfCode: String
        var shelfSide: String
        var distanceFromShelfStartCm: Double
        var positionRatio: Double
        var distanceToSegmentM: Double
        var distanceFromStartM: Double
        var segmentLengthM: Double
        var atEndpoint: Bool
        var projectedFaceXM: Double
        var projectedFaceYM: Double
        var normalResidualM: Double
        var longitudinalWithinSegment: Bool
        /// Distance to the second-closest candidate (parallel aisle
        /// ambiguity), nil when fewer than two candidates exist.
        var secondCandidateDistanceM: Double?
        /// second - first distance margin; small margins are ambiguous.
        var marginM: Double?
        /// True when a fixed structure lies between the tag and the
        /// shelf (occlusion check, §13.4/§13.6).
        var occludedByStructure: Bool
        /// V1R5 §12.2: business-side provenance of the associated shelf.
        var orientationProvenance: String
    }

    /// Projects point P onto segment A-B and classifies the side:
    /// s = dot(P-A, d)/|d|, u = s/|d|, distance_from_shelf_start_cm =
    /// s*100; shelfSide is derived from the face normal (front/back).
    static func associate(
        point: (Double, Double),
        shelf: ShelfSegment,
        floorID: String,
        observerPoint: (Double, Double)? = nil,
        endpointMarginM: Double = 0.15,
        occludedByStructure: Bool = false
    ) -> Association? {
        guard shelf.floorID == floorID else { return nil }
        let dx = shelf.endM.0 - shelf.startM.0
        let dy = shelf.endM.1 - shelf.startM.1
        let length = hypot(dx, dy)
        guard length > 1.0e-9 else { return nil }
        let px = point.0 - shelf.startM.0
        let py = point.1 - shelf.startM.1
        let unclampedRatio = (px * dx + py * dy) / (length * length)
        let ratio = max(0.0, min(1.0, unclampedRatio))
        let s = ratio * length
        let sidePoint: (Double, Double)
        if let observerPoint,
           observerPoint.0.isFinite, observerPoint.1.isFinite {
            sidePoint = observerPoint
        } else {
            sidePoint = point
        }
        let shelfSide = shelf.side(for: sidePoint)
        let faceOffset = shelf.faceOffsetM(side: shelfSide)
        let projectedX = shelf.startM.0 + ratio * dx
            + shelf.frontNormalM.0 * faceOffset
        let projectedY = shelf.startM.1 + ratio * dy
            + shelf.frontNormalM.1 * faceOffset
        let distanceToSegment = hypot(point.0 - projectedX, point.1 - projectedY)
        let faceNormal = shelfSide == "front"
            ? shelf.frontNormalM : shelf.backNormalM
        let normalResidual = abs(
            (point.0 - projectedX) * faceNormal.0
                + (point.1 - projectedY) * faceNormal.1)
        let atEndpoint = s < endpointMarginM || s > length - endpointMarginM
        return Association(
            shelfSegmentID: shelf.shelfSegmentID,
            shelfCode: shelf.shelfCode,
            shelfSide: shelfSide,
            distanceFromShelfStartCm: SourceGeometry.rounded(s * 100.0),
            positionRatio: SourceGeometry.rounded(ratio),
            distanceToSegmentM: SourceGeometry.rounded(distanceToSegment),
            distanceFromStartM: SourceGeometry.rounded(s),
            segmentLengthM: SourceGeometry.rounded(length),
            atEndpoint: atEndpoint,
            projectedFaceXM: SourceGeometry.rounded(projectedX),
            projectedFaceYM: SourceGeometry.rounded(projectedY),
            normalResidualM: SourceGeometry.rounded(normalResidual),
            longitudinalWithinSegment: unclampedRatio >= 0 && unclampedRatio <= 1,
            secondCandidateDistanceM: nil,
            marginM: nil,
            occludedByStructure: occludedByStructure,
            orientationProvenance: shelf.orientationProvenance
        )
    }

    /// Chooses the best (closest) shelf for a tag point via the spatial
    /// index; the second-closest candidate distance and the margin
    /// (second - first) are reported for the ambiguity gate (§13.4).
    static func bestAssociation(
        point: (Double, Double),
        shelves: [ShelfSegment],
        index: ShelfSpatialIndex?,
        floorID: String,
        observerPoint: (Double, Double)? = nil,
        occludedByStructure: (ShelfSegment) -> Bool
    ) -> Association? {
        let candidates = index?.candidates(point: point, floorID: floorID)
            ?? shelves.filter { $0.floorID == floorID }
        var first: (Association, Double)?
        var secondDistance = Double.infinity
        var evaluatedSegmentIDs = Set<String>()
        for shelf in candidates {
            guard evaluatedSegmentIDs.insert(shelf.shelfSegmentID).inserted else {
                continue
            }
            guard let association = associate(
                point: point,
                shelf: shelf,
                floorID: floorID,
                observerPoint: observerPoint,
                occludedByStructure: occludedByStructure(shelf)) else {
                continue
            }
            let distance = association.distanceToSegmentM
            if let current = first {
                if distance < current.1 {
                    secondDistance = current.1
                    first = (association, distance)
                } else if distance < secondDistance {
                    secondDistance = distance
                }
            } else {
                first = (association, distance)
            }
        }
        guard var best = first else { return nil }
        if secondDistance.isFinite {
            best.0.secondCandidateDistanceM = secondDistance
            best.0.marginM = secondDistance - best.1
        }
        return best.0
    }

    // MARK: - Occlusion

    /// Fixed structures from `fixed_structures.json` (polygon or AABB
    /// envelope) used for the occlusion check.
    struct FixedStructure {
        var structureCode: String
        var floorID: String
        var polygonM: [(Double, Double)]?
        var boundsMinM: (Double, Double)
        var boundsMaxM: (Double, Double)

        func boundsContains(x: Double, y: Double) -> Bool {
            return x >= boundsMinM.0 && x <= boundsMaxM.0
                && y >= boundsMinM.1 && y <= boundsMaxM.1
        }
    }

    /// Ray-casting point-in-polygon for a closed polygon.
    static func pointInPolygon(point: (Double, Double), polygon: [(Double, Double)]) -> Bool {
        guard polygon.count >= 3 else { return false }
        var inside = false
        var previous = polygon[polygon.count - 1]
        for vertex in polygon {
            let crosses = (vertex.1 > point.1) != (previous.1 > point.1)
                && point.0 < (previous.0 - vertex.0) * (point.1 - vertex.1)
                    / (previous.1 - vertex.1) + vertex.0
            if crosses { inside.toggle() }
            previous = vertex
        }
        return inside
    }

    /// Occlusion: the complete tag-to-shelf sight segment intersects a fixed
    /// structure polygon (or its explicit AABB fallback) on the same floor.
    /// A midpoint-only test misses thin pillars and structures close to either
    /// endpoint, so every polygon edge is tested. The intersection must remain
    /// within `maximumDistanceM` of the shelf projection to avoid far-away
    /// structures producing false hits.
    static func isOccluded(
        tagPoint: (Double, Double),
        shelf: ShelfSegment,
        structures: [FixedStructure],
        maximumDistanceM: Double = 2.0
    ) -> Bool {
        let dx = shelf.endM.0 - shelf.startM.0
        let dy = shelf.endM.1 - shelf.startM.1
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 1.0e-9 else { return false }
        let px = tagPoint.0 - shelf.startM.0
        let py = tagPoint.1 - shelf.startM.1
        let ratio = max(0.0, min(1.0, (px * dx + py * dy) / lengthSquared))
        let projection = (
            shelf.startM.0 + ratio * dx,
            shelf.startM.1 + ratio * dy)
        for structure in structures where structure.floorID == shelf.floorID {
            let sightMinX = min(tagPoint.0, projection.0)
            let sightMaxX = max(tagPoint.0, projection.0)
            let sightMinY = min(tagPoint.1, projection.1)
            let sightMaxY = max(tagPoint.1, projection.1)
            guard sightMaxX >= structure.boundsMinM.0,
                  sightMinX <= structure.boundsMaxM.0,
                  sightMaxY >= structure.boundsMinM.1,
                  sightMinY <= structure.boundsMaxM.1 else {
                continue
            }
            let polygon = structure.polygonM ?? [
                structure.boundsMinM,
                (structure.boundsMaxM.0, structure.boundsMinM.1),
                structure.boundsMaxM,
                (structure.boundsMinM.0, structure.boundsMaxM.1),
            ]
            if segmentIntersectsPolygonNearShelf(
                start: tagPoint,
                end: projection,
                polygon: polygon,
                maximumDistanceFromEndM: maximumDistanceM) {
                return true
            }
        }
        return false
    }

    private static func segmentIntersectsPolygonNearShelf(
        start: (Double, Double),
        end: (Double, Double),
        polygon: [(Double, Double)],
        maximumDistanceFromEndM: Double
    ) -> Bool {
        guard polygon.count >= 3,
              maximumDistanceFromEndM >= 0 else { return false }
        if pointInPolygon(point: end, polygon: polygon) {
            return true
        }
        var previous = polygon[polygon.count - 1]
        for vertex in polygon {
            if let ratio = segmentIntersectionRatio(
                start: start,
                end: end,
                edgeStart: previous,
                edgeEnd: vertex) {
                let intersection = (
                    start.0 + ratio * (end.0 - start.0),
                    start.1 + ratio * (end.1 - start.1))
                if hypot(
                    end.0 - intersection.0,
                    end.1 - intersection.1) <= maximumDistanceFromEndM {
                    return true
                }
            }
            previous = vertex
        }
        return false
    }

    /// Returns the ratio on `start...end` where it intersects an edge.
    /// Collinear overlap is conservatively treated as an intersection.
    private static func segmentIntersectionRatio(
        start: (Double, Double),
        end: (Double, Double),
        edgeStart: (Double, Double),
        edgeEnd: (Double, Double)
    ) -> Double? {
        let ray = (end.0 - start.0, end.1 - start.1)
        let edge = (edgeEnd.0 - edgeStart.0, edgeEnd.1 - edgeStart.1)
        let delta = (edgeStart.0 - start.0, edgeStart.1 - start.1)
        let denominator = ray.0 * edge.1 - ray.1 * edge.0
        let epsilon = 1.0e-9
        if abs(denominator) <= epsilon {
            let cross = delta.0 * ray.1 - delta.1 * ray.0
            guard abs(cross) <= epsilon else { return nil }
            let rayLengthSquared = ray.0 * ray.0 + ray.1 * ray.1
            guard rayLengthSquared > epsilon else { return nil }
            let first = (delta.0 * ray.0 + delta.1 * ray.1)
                / rayLengthSquared
            let edgeDelta = (edgeEnd.0 - start.0, edgeEnd.1 - start.1)
            let second = (edgeDelta.0 * ray.0 + edgeDelta.1 * ray.1)
                / rayLengthSquared
            let overlapStart = max(0.0, min(first, second))
            let overlapEnd = min(1.0, max(first, second))
            return overlapStart <= overlapEnd + epsilon
                ? max(0.0, min(1.0, overlapStart))
                : nil
        }
        let rayRatio = (delta.0 * edge.1 - delta.1 * edge.0)
            / denominator
        let edgeRatio = (delta.0 * ray.1 - delta.1 * ray.0)
            / denominator
        guard rayRatio >= -epsilon, rayRatio <= 1.0 + epsilon,
              edgeRatio >= -epsilon, edgeRatio <= 1.0 + epsilon else {
            return nil
        }
        return max(0.0, min(1.0, rayRatio))
    }
}

/// The automatic quality gate. Uncertain results become
/// LOW_CONFIDENCE; the system never guesses or silently drops a complete,
/// exactly bound observation burst.
enum AutomaticQualityGate {
    struct TagQualityInput {
        var observationCount: Int
        var uniqueVerifiedFrameCount: Int
        var effectiveSampleSize: Double
        var positionSpreadM: Double
        var minimumBurstSamples: Int
        var maximumSpreadM: Double
        var minimumDepthQuality: Double
        var viewQualitySufficient: Bool
        var trackingQualitySufficient: Bool
        var localizationConfidence: Double
        var measurementConfidence: Double
        var needsReview: Bool
        var measurementMethodAccepted: Bool
        var maximumNodeUncertaintyM: Double?
        var bindingMethod: String
        var association: ShelfAssociationEngine.Association
        var maximumEndpointDistanceM: Double
        var maximumAssociationDistanceM: Double
        /// First/second candidate margin below this is ambiguous
        /// (parallel aisle, §13.6).
        var minimumAssociationMarginM: Double
        var graphQualityPassed: Bool
        var mapSessionIdentityConsistent: Bool
    }

    enum QualityStatus: String {
        case accepted = "ACCEPTED"
        case lowConfidence = "LOW_CONFIDENCE"
        case rescanRequired = "RESCAN_REQUIRED"
    }

    static let minimumDepthQuality = 0.65
    static let minimumLocalizationConfidence = 0.65
    static let minimumMeasurementConfidence = 0.65
    static let maximumNodeUncertaintyM = 0.20
    static let minimumEffectiveSampleSize = 2.5

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
        guard input.uniqueVerifiedFrameCount >= input.minimumBurstSamples else {
            return (.rescanRequired, "insufficient_burst_samples")
        }
        guard input.effectiveSampleSize >= minimumEffectiveSampleSize else {
            return (.lowConfidence, "insufficient_effective_samples")
        }
        guard !input.needsReview else {
            return (.lowConfidence, "measurement_needs_review")
        }
        guard input.measurementMethodAccepted else {
            return (.rescanRequired, "measurement_method_unavailable")
        }
        guard input.trackingQualitySufficient else {
            return (.lowConfidence, "tracking_quality_insufficient")
        }
        guard input.viewQualitySufficient else {
            return (.lowConfidence, "view_quality_insufficient")
        }
        guard input.minimumDepthQuality >= minimumDepthQuality else {
            return (.lowConfidence, "depth_quality_insufficient")
        }
        guard input.localizationConfidence >= minimumLocalizationConfidence else {
            return (.lowConfidence, "localization_confidence_insufficient")
        }
        guard input.measurementConfidence >= minimumMeasurementConfidence else {
            return (.lowConfidence, "measurement_confidence_insufficient")
        }
        guard let uncertainty = input.maximumNodeUncertaintyM else {
            return (.lowConfidence, "node_uncertainty_unavailable")
        }
        guard uncertainty <= maximumNodeUncertaintyM else {
            return (.lowConfidence, "node_uncertainty_exceeded")
        }
        guard input.positionSpreadM <= input.maximumSpreadM else {
            return (.lowConfidence, "position_spread_exceeded")
        }
        guard input.association.normalResidualM.isFinite,
              input.association.normalResidualM
                <= input.maximumAssociationDistanceM else {
            return (.lowConfidence, "shelf_association_distance_exceeded")
        }
        guard input.association.longitudinalWithinSegment else {
            return (.lowConfidence, "shelf_association_longitudinal_out_of_segment")
        }
        // Parallel-aisle ambiguity: the second-closest shelf is nearly as
        // close as the first.
        if let second = input.association.secondCandidateDistanceM,
           let margin = input.association.marginM,
           second.isFinite,
           margin < input.minimumAssociationMarginM {
            return (.lowConfidence, "shelf_association_margin_insufficient")
        }
        guard !input.association.atEndpoint else {
            return (.lowConfidence, "shelf_endpoint_ambiguity")
        }
        guard input.association.shelfSide == "front" || input.association.shelfSide == "back" else {
            return (.lowConfidence, "shelf_side_ambiguous")
        }
        // V1R5 §12.2 (review B-14): a side derived WITHOUT business
        // semantics (source carried no orientation) can never be
        // ACCEPTED — the consumer must not guess front/back.
        guard input.association.orientationProvenance != "unavailable" else {
            return (.lowConfidence, "shelf_side_unavailable")
        }
        guard !input.association.occludedByStructure else {
            return (.lowConfidence, "shelf_occluded_by_structure")
        }
        return (.accepted, "")
    }
}
