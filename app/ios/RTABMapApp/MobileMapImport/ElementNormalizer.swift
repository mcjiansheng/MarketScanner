import Foundation

/// Normalizes one raw source element into a `PriorMapSourceElement`,
/// structurally identical to the PC `_normalized_element` so mobile and
/// PC compilers share one element contract.
///
/// Geometry problems never silently drop the element: they become typed
/// warnings and the raw business fields stay preserved.
enum ElementNormalizer {
    enum RectangleSemantics: Equatable {
        case legacyCenterPivot
        case topLeftAnchor
    }

    static func normalize(
        floor: String,
        row: Int,
        raw: [String: Any],
        contract: CoordinateContract,
        rectangleSemantics: RectangleSemantics = .legacyCenterPivot,
        strict: Bool = true,
        warnings: inout [MapSourceWarning]
    ) throws -> PriorMapSourceElement {
        let shapeType = String(describing: raw["shapeType"] as? String ?? "Unknown")
        let role = ElementRoleClassifier.role(for: shapeType)
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
                let polygon: [[Double]]
                switch rectangleSemantics {
                case .legacyCenterPivot:
                    polygon = SourceGeometry.legacyCenterPivotRectanglePolygon(
                        xCm: x, yCm: y, widthCm: width, heightCm: height,
                        rotationDegrees: rotation, contract: contract)
                case .topLeftAnchor:
                    polygon = SourceGeometry.sourceRectanglePolygon(
                        xCm: x, yCm: y, widthCm: width, heightCm: height,
                        rotationDegrees: rotation, contract: contract)
                }
                geometry = ["type": "polygon", "coordinates": polygon]
                bounds = try SourceGeometry.polygonBounds(polygon).asDictionary
                if rectangleSemantics == .topLeftAnchor {
                    center = SourceGeometry.sourceRectangleCenter(
                        xCm: x, yCm: y, widthCm: width, heightCm: height,
                        rotationDegrees: rotation, contract: contract)
                } else {
                    let (centerX, centerY) = SourceGeometry.sourcePointToMap(
                        x + width / 2.0, y + height / 2.0,
                        contract: contract)
                    center = [centerX, centerY]
                }
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
            } else if role == .presentationOnly {
                warnings.append(MapSourceWarning(
                    code: "presentation_only_element_ignored",
                    row: row,
                    floor: floor,
                    shapeType: shapeType,
                    message: "展示元素 \(shapeType) 仅保留在导入审计中，不参与生产地图。"
                ))
            } else if role == .unsupported {
                warnings.append(MapSourceWarning(
                    code: "unsupported_element_ignored",
                    row: row,
                    floor: floor,
                    shapeType: shapeType,
                    message: "不支持的元素类型 \(shapeType) 仅保留在导入审计中。"
                ))
            }
        } catch let error as MapSourceImportError {
            if strict && visible && role.isProduction {
                throw error
            }
            warnings.append(MapSourceWarning(
                code: "invalid_geometry",
                row: row,
                floor: floor,
                shapeType: shapeType,
                message: "元素几何无效：\(error.message)；原始数据已保留。"
            ))
        } catch {
            if strict && visible && role.isProduction {
                throw MapSourceImportError.invalidGeometry(
                    shapeType: shapeType, reason: String(describing: error))
            }
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
                code: "hidden_element_ignored",
                row: row,
                floor: floor,
                shapeType: shapeType,
                message: "元素 visible=false，仅保留在导入审计中并从生产地图排除。"
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
            subsection: raw["subsection"],
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
                subsection: raw["subsection"],
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
        guard let number = StrictJSONScalar.number(value) else {
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
        return StrictJSONScalar.number(value)
    }
}
