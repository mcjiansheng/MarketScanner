import Foundation

/// Normalizes one raw source element into a `PriorMapSourceElement`,
/// structurally identical to the PC `_normalized_element` so mobile and
/// PC compilers share one element contract.
///
/// Geometry problems never silently drop the element: they become typed
/// warnings and the raw business fields stay preserved.
enum ElementNormalizer {
    static func normalize(
        floor: String,
        row: Int,
        raw: [String: Any],
        contract: CoordinateContract,
        warnings: inout [MapSourceWarning]
    ) -> PriorMapSourceElement {
        let shapeType = String(describing: raw["shapeType"] as? String ?? "Unknown")
        let identifier = "f\(floor)-r\(row)"
        let visible = (raw["visible"] as? Bool) ?? true
        let code: String = {
            if let text = raw["code"] as? String { return text }
            if let number = raw["code"] as? Int { return String(number) }
            return ""
        }()
        var geometry: [String: Any]?
        var bounds: [String: Double]?
        var center: [Double]?
        var yawRad: Double?

        do {
            if MobileElementTypes.rectangleTypes.contains(shapeType) {
                let x = try numeric(raw, key: "x", shapeType: shapeType)
                let y = try numeric(raw, key: "y", shapeType: shapeType)
                let width = try numeric(raw, key: "width", shapeType: shapeType)
                let height = try numeric(raw, key: "height", shapeType: shapeType)
                let rotation = try optionalNumeric(raw, key: "rotation", shapeType: shapeType) ?? 0.0
                guard width > 0, height > 0 else {
                    throw MapSourceImportError.invalidGeometry(
                        shapeType: shapeType, reason: "width and height must be positive")
                }
                let polygon = SourceGeometry.sourceRectanglePolygon(
                    xCm: x, yCm: y, widthCm: width, heightCm: height,
                    rotationDegrees: rotation, contract: contract)
                geometry = ["type": "polygon", "coordinates": polygon]
                bounds = try SourceGeometry.polygonBounds(polygon).asDictionary
                let (centerX, centerY) = SourceGeometry.sourcePointToMap(
                    x + width / 2.0, y + height / 2.0, contract: contract)
                center = [centerX, centerY]
                yawRad = SourceGeometry.sourceRotationToYaw(rotation)
            } else if shapeType == "MapCross" {
                guard let points = raw["points"] as? [Any],
                      points.count >= 4, points.count % 2 == 0
                else {
                    throw MapSourceImportError.invalidGeometry(
                        shapeType: shapeType, reason: "points must contain at least two x/y pairs")
                }
                var coordinates: [[Double]] = []
                for index in stride(from: 0, to: points.count, by: 2) {
                    let (px, py) = try coordinatePair(points, index: index, shapeType: shapeType)
                    let (mapX, mapY) = SourceGeometry.sourcePointToMap(px, py, contract: contract)
                    coordinates.append([mapX, mapY])
                }
                geometry = ["type": "line_string", "coordinates": coordinates]
                bounds = try SourceGeometry.polygonBounds(coordinates).asDictionary
            } else if shapeType == "MapRoadPoint" {
                let x = try numeric(raw, key: "x", shapeType: shapeType)
                let y = try numeric(raw, key: "y", shapeType: shapeType)
                let (mapX, mapY) = SourceGeometry.sourcePointToMap(x, y, contract: contract)
                let point = [mapX, mapY]
                geometry = ["type": "point", "coordinates": point]
                bounds = [
                    "min_x_m": mapX, "min_y_m": mapY,
                    "max_x_m": mapX, "max_y_m": mapY,
                    "width_m": 0.0, "height_m": 0.0,
                ]
                center = point
            } else if !MobileElementTypes.supportedTypes.contains(shapeType) {
                warnings.append(MapSourceWarning(
                    code: "unknown_shape_type",
                    row: row,
                    floor: floor,
                    shapeType: shapeType,
                    message: "发现未知元素类型 \(shapeType)；原始数据已保留但不会参与定位。"
                ))
            }
        } catch let error as MapSourceImportError {
            warnings.append(MapSourceWarning(
                code: "invalid_geometry",
                row: row,
                floor: floor,
                shapeType: shapeType,
                message: "元素几何无效：\(error.message)；原始数据已保留。"
            ))
        } catch {
            warnings.append(MapSourceWarning(
                code: "invalid_geometry",
                row: row,
                floor: floor,
                shapeType: shapeType,
                message: "元素几何无效：\(error)；原始数据已保留。"
            ))
        }

        if !visible {
            warnings.append(MapSourceWarning(
                code: "hidden_element",
                row: row,
                floor: floor,
                shapeType: shapeType,
                message: "元素 visible=false，已保留并从默认定位索引中排除。"
            ))
        }

        var element = PriorMapSourceElement(
            id: identifier,
            sourceRow: row,
            floorId: floor,
            shapeType: shapeType,
            visible: visible,
            locked: (raw["locked"] as? Bool) ?? false,
            code: code,
            crossCode: String(describing: raw["crossCode"] as? String ?? ""),
            rowFlag: String(describing: raw["rowFlag"] as? String ?? ""),
            subsection: raw["subsection"] as? String,
            geometry: geometry,
            bounds: bounds,
            centerM: center,
            yawRad: yawRad,
            source: raw
        )
        if geometry == nil {
            // Preserve the PC shape where geometry is omitted entirely.
            element = PriorMapSourceElement(
                id: identifier,
                sourceRow: row,
                floorId: floor,
                shapeType: shapeType,
                visible: visible,
                locked: (raw["locked"] as? Bool) ?? false,
                code: element.code,
                crossCode: element.crossCode,
                rowFlag: element.rowFlag,
                subsection: raw["subsection"] as? String,
                geometry: nil,
                bounds: nil,
                centerM: nil,
                yawRad: nil,
                source: raw
            )
        }
        return element
    }

    private static func numeric(_ raw: [String: Any], key: String, shapeType: String) throws -> Double {
        guard let value = raw[key] else {
            throw MapSourceImportError.invalidGeometry(shapeType: shapeType, reason: "\(key) must be numeric")
        }
        if value is Bool {
            throw MapSourceImportError.invalidGeometry(shapeType: shapeType, reason: "\(key) must be numeric")
        }
        guard let number = asDouble(value), number.isFinite else {
            throw MapSourceImportError.invalidGeometry(shapeType: shapeType, reason: "\(key) must be numeric")
        }
        return number
    }

    private static func optionalNumeric(_ raw: [String: Any], key: String, shapeType: String) throws -> Double? {
        guard raw[key] != nil else { return nil }
        return try numeric(raw, key: key, shapeType: shapeType)
    }

    private static func coordinatePair(_ points: [Any], index: Int, shapeType: String) throws -> (Double, Double) {
        guard let px = asDouble(points[index]), let py = asDouble(points[index + 1]) else {
            throw MapSourceImportError.invalidGeometry(
                shapeType: shapeType, reason: "coordinate must be numeric")
        }
        return (px, py)
    }

    static func asDouble(_ value: Any) -> Double? {
        switch value {
        case let number as Double: return number
        case let number as Int: return Double(number)
        case let number as Int64: return Double(number)
        case let number as NSNumber:
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            return number.doubleValue
        default: return nil
        }
    }
}
