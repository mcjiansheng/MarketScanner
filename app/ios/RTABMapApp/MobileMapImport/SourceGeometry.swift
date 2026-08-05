import Foundation

/// The single authoritative source-to-map coordinate conversion on the
/// mobile side, mirroring `tools/PriorMap/coordinate_system.py`.
///
/// Source documents use centimetres; internal map coordinates use metres
/// with +x right and +y up. The `CoordinateContract` preset chosen by the
/// user in the import wizard (top-left or bottom-left origin) determines
/// the vertical flip. Rotation is always clockwise-positive in source
/// degrees and becomes counter-clockwise-positive yaw in map radians.
enum SourceGeometry {
    static let centimetresPerMetre: Double = 100.0

    struct Bounds: Equatable {
        var minX_m: Double
        var minY_m: Double
        var maxX_m: Double
        var maxY_m: Double

        var widthM: Double { maxX_m - minX_m }
        var heightM: Double { maxY_m - minY_m }

        var asDictionary: [String: Double] {
            return [
                "min_x_m": rounded(minX_m),
                "min_y_m": rounded(minY_m),
                "max_x_m": rounded(maxX_m),
                "max_y_m": rounded(maxY_m),
                "width_m": rounded(widthM),
                "height_m": rounded(heightM),
            ]
        }
    }

    /// Python-compatible `round(value, 6)` with round-half-even and
    /// negative-zero normalization.
    static func rounded(_ value: Double, digits: Int = 6) -> Double {
        let factor = pow(10.0, Double(digits))
        let scaled = value * factor
        let lower = scaled.rounded(.down)
        let difference = scaled - lower
        var result: Double
        if difference < 0.5 {
            result = lower
        } else if difference > 0.5 {
            result = lower + 1
        } else {
            // Round half to even.
            let lowerIsEven = lower.truncatingRemainder(dividingBy: 2.0) == 0
            result = lowerIsEven ? lower : lower + 1
        }
        let finalValue = result / factor
        return finalValue == -0.0 ? 0.0 : finalValue
    }

    static func roundedRadians(_ value: Double) -> Double {
        let result = rounded(value, digits: 9)
        return result == -0.0 ? 0.0 : result
    }

    static func cmToM(_ value: Double) -> Double {
        return value / centimetresPerMetre
    }

    /// Source (x_cm, y_cm) → map (x_m, y_m) under the given contract.
    static func sourcePointToMap(_ xCm: Double, _ yCm: Double, contract: CoordinateContract) -> (Double, Double) {
        let xM = rounded(cmToM(xCm))
        let yM: Double
        switch contract.origin {
        case .topLeft:
            yM = rounded(-cmToM(yCm))
        case .bottomLeft:
            yM = rounded(cmToM(yCm))
        }
        return (xM, yM)
    }

    /// Source rotation in clockwise degrees → map yaw in
    /// counter-clockwise radians.
    static func sourceRotationToYaw(_ rotationDegrees: Double) -> Double {
        return roundedRadians(-rotationDegrees * Double.pi / 180.0)
    }

    /// Source rectangle (top-left x/y, width, height, clockwise rotation
    /// around the centre) → CCW map-space polygon, matching
    /// `source_rectangle_polygon`.
    static func sourceRectanglePolygon(
        xCm: Double,
        yCm: Double,
        widthCm: Double,
        heightCm: Double,
        rotationDegrees: Double,
        contract: CoordinateContract
    ) -> [[Double]] {
        let x = xCm
        let y = yCm
        let width = widthCm
        let height = heightCm
        let centerX = x + width / 2.0
        let centerY = y + height / 2.0
        let radians = rotationDegrees * Double.pi / 180.0
        let cosine = cos(radians)
        let sine = sin(radians)
        let sourceCorners: [(Double, Double)] = [
            (x, y),
            (x + width, y),
            (x + width, y + height),
            (x, y + height),
        ]
        var polygon: [[Double]] = []
        for (px, py) in sourceCorners {
            let dx = px - centerX
            let dy = py - centerY
            let rotatedX = centerX + dx * cosine - dy * sine
            let rotatedY = centerY + dx * sine + dy * cosine
            let (mapX, mapY) = sourcePointToMap(rotatedX, rotatedY, contract: contract)
            polygon.append([mapX, mapY])
        }
        // Flipping source y reverses winding. Restore CCW order. For the
        // bottom-left preset the winding is already CCW and stays as-is.
        if contract.origin == .topLeft {
            polygon.reverse()
        }
        return polygon
    }

    static func polygonBounds(_ polygon: [[Double]]) throws -> Bounds {
        guard !polygon.isEmpty else {
            throw MapSourceImportError.invalidGeometry(
                shapeType: "polygon", reason: "points must not be empty")
        }
        var minX = Double.infinity
        var minY = Double.infinity
        var maxX = -Double.infinity
        var maxY = -Double.infinity
        for point in polygon {
            guard point.count >= 2 else {
                throw MapSourceImportError.invalidGeometry(
                    shapeType: "polygon", reason: "point must have x and y")
            }
            let x = point[0]
            let y = point[1]
            minX = min(minX, x)
            minY = min(minY, y)
            maxX = max(maxX, x)
            maxY = max(maxY, y)
        }
        return Bounds(minX_m: minX, minY_m: minY, maxX_m: maxX, maxY_m: maxY)
    }

    static func mergeBounds(_ bounds: [Bounds]) -> Bounds {
        guard let first = bounds.first else {
            return Bounds(minX_m: 0, minY_m: 0, maxX_m: 0, maxY_m: 0)
        }
        var minX = first.minX_m
        var minY = first.minY_m
        var maxX = first.maxX_m
        var maxY = first.maxY_m
        for item in bounds.dropFirst() {
            minX = min(minX, item.minX_m)
            minY = min(minY, item.minY_m)
            maxX = max(maxX, item.maxX_m)
            maxY = max(maxY, item.maxY_m)
        }
        return Bounds(minX_m: minX, minY_m: minY, maxX_m: maxX, maxY_m: maxY)
    }

    /// Shortest-arc normalization to (-pi, pi].
    static func normalizeAngle(_ value: Double) -> Double {
        return atan2(sin(value), cos(value))
    }

    static func shortestAngleDifference(_ from: Double, _ to: Double) -> Double {
        return normalizeAngle(to - from)
    }
}

/// Frozen element type sets mirroring `tools/PriorMap/xlsx_to_prior_map.py`.
enum MobileElementTypes {
    static let rectangleTypes: Set<String> = [
        "MapShelf", "MapTable", "MapPillar", "MapTableFeature",
    ]
    static let structureTypes: Set<String> = rectangleTypes
    static let supportedTypes: Set<String> = rectangleTypes
        .union(["MapCross", "MapRoadPoint"])
}
