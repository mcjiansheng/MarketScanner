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
    /// around the top-left anchor) → deterministic CCW map-space polygon.
    /// The first point remains the source anchor after winding correction.
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
            let dx = px - x
            let dy = py - y
            let rotatedX = x + dx * cosine - dy * sine
            let rotatedY = y + dx * sine + dy * cosine
            let (mapX, mapY) = sourcePointToMap(rotatedX, rotatedY, contract: contract)
            polygon.append([mapX, mapY])
        }
        // Flipping source y reverses winding. Restore CCW order while
        // retaining the anchor as P0: [P0, P3, P2, P1].
        if contract.origin == .topLeft {
            polygon = [polygon[0], polygon[3], polygon[2], polygon[1]]
        }
        return polygon
    }

    /// Frozen v1/v2 compatibility geometry for CSV, element-only XLSX and
    /// legacy JSON parity. New standard workbooks never call this path.
    static func legacyCenterPivotRectanglePolygon(
        xCm: Double,
        yCm: Double,
        widthCm: Double,
        heightCm: Double,
        rotationDegrees: Double,
        contract: CoordinateContract
    ) -> [[Double]] {
        let centerX = xCm + widthCm / 2.0
        let centerY = yCm + heightCm / 2.0
        let radians = rotationDegrees * Double.pi / 180.0
        let cosine = cos(radians)
        let sine = sin(radians)
        let sourceCorners = [
            (xCm, yCm),
            (xCm + widthCm, yCm),
            (xCm + widthCm, yCm + heightCm),
            (xCm, yCm + heightCm),
        ]
        var polygon = sourceCorners.map { px, py -> [Double] in
            let dx = px - centerX
            let dy = py - centerY
            let rotatedX = centerX + dx * cosine - dy * sine
            let rotatedY = centerY + dx * sine + dy * cosine
            let (mapX, mapY) = sourcePointToMap(
                rotatedX, rotatedY, contract: contract)
            return [mapX, mapY]
        }
        if contract.origin == .topLeft { polygon.reverse() }
        return polygon
    }

    /// Centroid of a top-left-anchored rotated rectangle in map metres.
    static func sourceRectangleCenter(
        xCm: Double,
        yCm: Double,
        widthCm: Double,
        heightCm: Double,
        rotationDegrees: Double,
        contract: CoordinateContract
    ) -> [Double] {
        let radians = rotationDegrees * Double.pi / 180.0
        let dx = widthCm / 2.0
        let dy = heightCm / 2.0
        let sourceX = xCm + dx * cos(radians) - dy * sin(radians)
        let sourceY = yCm + dx * sin(radians) + dy * cos(radians)
        let (mapX, mapY) = sourcePointToMap(sourceX, sourceY, contract: contract)
        return [mapX, mapY]
    }

    static func contains(
        geometry: [String: Any]?,
        in bounds: Bounds,
        tolerance: Double = 1.0e-6
    ) -> Bool {
        guard let geometry = geometry,
              let type = geometry["type"] as? String else { return false }
        let points: [[Double]]
        if type == "point", let point = geometry["coordinates"] as? [Double] {
            points = [point]
        } else if let coordinates = geometry["coordinates"] as? [[Double]] {
            points = coordinates
        } else {
            return false
        }
        return !points.isEmpty && points.allSatisfy { point in
            point.count >= 2
                && point[0] >= bounds.minX_m - tolerance
                && point[0] <= bounds.maxX_m + tolerance
                && point[1] >= bounds.minY_m - tolerance
                && point[1] <= bounds.maxY_m + tolerance
        }
    }

    /// Strict geometry-shape contract for active production elements.
    ///
    /// Canonical v3 JSON is an input format in its own right, so callers
    /// cannot assume every geometry was produced by `ElementNormalizer`.
    /// A role-correct element with a wrong geometry kind (for example a
    /// `MapShelf` carrying a line string) must fail before compilation,
    /// preview rendering, distance-field construction or package loading.
    static func validatedProductionGeometryPoints(
        shapeType: String,
        geometry: [String: Any]?
    ) -> [[Double]]? {
        guard let geometry = geometry,
              let geometryType = geometry["type"] as? String else {
            return nil
        }

        func point(_ raw: Any?) -> [Double]? {
            guard let values = raw as? [Any], values.count == 2,
                  let x = StrictJSONScalar.number(values[0]),
                  let y = StrictJSONScalar.number(values[1]) else {
                return nil
            }
            return [x, y]
        }

        func points(_ raw: Any?, count: ClosedRange<Int>) -> [[Double]]? {
            guard let values = raw as? [Any], count.contains(values.count) else {
                return nil
            }
            var result: [[Double]] = []
            result.reserveCapacity(values.count)
            for value in values {
                guard let converted = point(value) else { return nil }
                result.append(converted)
            }
            return result
        }

        switch shapeType {
        case "MapShelf", "MapTable", "MapTableFeature", "MapPillar":
            guard geometryType == "polygon",
                  let polygon = points(geometry["coordinates"], count: 4...4)
            else { return nil }
            var twiceArea = 0.0
            for index in polygon.indices {
                let following = polygon[(index + 1) % polygon.count]
                let current = polygon[index]
                guard hypot(
                    following[0] - current[0],
                    following[1] - current[1]) > 1.0e-9 else {
                    return nil
                }
                twiceArea += current[0] * following[1]
                    - following[0] * current[1]
            }
            guard abs(twiceArea) > 1.0e-12 else { return nil }
            return polygon

        case "MapCross":
            guard geometryType == "line_string",
                  let line = points(
                    geometry["coordinates"],
                    count: 2...MapSourceImportLimits.maximumElements)
            else { return nil }
            let hasNonzeroSegment = zip(line, line.dropFirst()).contains {
                hypot($1[0] - $0[0], $1[1] - $0[1]) > 1.0e-9
            }
            return hasNonzeroSegment ? line : nil

        case "MapRoadPoint":
            guard geometryType == "point",
                  let singlePoint = point(geometry["coordinates"])
            else { return nil }
            return [singlePoint]

        default:
            return nil
        }
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
enum PriorMapElementRole: String, Equatable {
    case shelf
    case fixedStructure = "fixed_structure"
    case road
    case presentationOnly = "presentation_only"
    case unsupported

    var isProduction: Bool {
        return self == .shelf || self == .fixedStructure || self == .road
    }
}

/// One versioned classifier is shared by import, canonical filtering,
/// compilation, preview, spatial indexing and distance-field generation.
enum ElementRoleClassifier {
    static let contractVersion = 1

    static let manifestContractPayload: [String: Any] = [
        "version": contractVersion,
        "shelf": ["MapShelf"],
        "fixed_structure": ["MapPillar", "MapTable", "MapTableFeature"],
        "road": ["MapCross", "MapRoadPoint"],
        "presentation_only": ["Circle", "MapMark", "Rect"],
    ]

    static func role(for shapeType: String) -> PriorMapElementRole {
        switch shapeType {
        case "MapShelf":
            return .shelf
        case "MapTable", "MapTableFeature", "MapPillar":
            return .fixedStructure
        case "MapCross", "MapRoadPoint":
            return .road
        case "Circle", "Rect", "MapMark":
            return .presentationOnly
        default:
            return .unsupported
        }
    }

    static func productionElements(
        from elements: [PriorMapSourceElement],
        warnings: inout [MapSourceWarning]
    ) -> (active: [PriorMapSourceElement], ignored: [PriorMapSourceElement]) {
        var active: [PriorMapSourceElement] = []
        var ignored: [PriorMapSourceElement] = []
        for element in elements {
            let role = role(for: element.shapeType)
            guard role.isProduction, element.visible else {
                ignored.append(element)
                let code: String
                let message: String
                if !element.visible, role.isProduction {
                    code = "hidden_element_ignored"
                    message = "元素 visible=false，已从生产地图元素中排除。"
                } else if role == .presentationOnly {
                    code = "presentation_only_element_ignored"
                    message = "展示元素仅用于源文件呈现，已从生产地图元素中排除。"
                } else {
                    code = "unsupported_element_ignored"
                    message = "不支持的元素类型已从生产地图元素中排除。"
                }
                if !warnings.contains(where: {
                    $0.code == code && $0.row == element.sourceRow
                        && $0.floor == element.floorId
                }) {
                    warnings.append(MapSourceWarning(
                        code: code,
                        row: element.sourceRow,
                        floor: element.floorId,
                        shapeType: element.shapeType,
                        message: message))
                }
                continue
            }
            active.append(element)
        }
        return (active, ignored)
    }
}

enum MobileElementTypes {
    static let rectangleTypes: Set<String> = [
        "MapShelf", "MapTable", "MapPillar", "MapTableFeature",
    ]
    static let structureTypes: Set<String> = rectangleTypes
    static let supportedTypes: Set<String> = rectangleTypes
        .union(["MapCross", "MapRoadPoint"])
}
