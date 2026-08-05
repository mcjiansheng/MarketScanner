import Foundation

/// Imports a store map from a canonical `MarketScannerPriorMapSource`
/// JSON document with a strict, total schema (V1R1 §6.6).
///
/// Required top-level fields: `format`, `version`, `storeId`, `mapName`,
/// `coordinateContract`, `elements`. Required element fields: `id`,
/// `source_row`, `floor_id`, `shape_type`, `visible`, `locked`, `code`,
/// `source`. Missing required fields are blockers — there is no default
/// floor (no `missing floor -> 1`) and no default shape (no
/// `missing shape -> Unknown`). Booleans are read through
/// `StrictJSONScalar.boolean`, integers through
/// `StrictJSONScalar.integer` and numbers through
/// `StrictJSONScalar.number`; a numeric 0/1 never passes as a boolean.
///
/// Unknown fields are preserved inside `source["extensions"]` — they are
/// never claimed as preserved and then dropped.
enum JSONMapSourceImporter {
    struct ImportOutcome {
        var elements: [PriorMapSourceElement]
        var warnings: [MapSourceWarning]
        var sourceIdentity: MapSourceIdentity?
    }

    private static let requiredTopLevel: Set<String> = [
        "format", "version", "storeId", "mapName",
        "coordinateContract", "elements",
    ]
    private static let knownTopLevel: Set<String> = requiredTopLevel.union([
        "source", "warnings",
    ])
    private static let requiredElementKeys: Set<String> = [
        "id", "source_row", "floor_id", "shape_type", "visible",
        "locked", "code", "source",
    ]
    private static let knownElementKeys: Set<String> = requiredElementKeys.union([
        "cross_code", "row_flag", "subsection", "geometry",
        "bounds", "center_m", "yaw_rad",
    ])

    static func importSource(data: Data) throws -> ImportOutcome {
        guard Int64(data.count) <= MapSourceImportLimits.maximumJSONBytes else {
            throw MapSourceImportError.jsonTooLarge(limitBytes: MapSourceImportLimits.maximumJSONBytes)
        }
        let limits = StrictJSONDocumentLimits(
            maximumBytes: Int(MapSourceImportLimits.maximumJSONBytes),
            maximumNestingDepth: MapSourceImportLimits.maximumJSONNestingDepth
        )
        let root: [String: Any]
        do {
            guard let object = try StrictJSONDocumentParser.object(
                from: data, limits: limits) as? [String: Any]
            else {
                throw MapSourceImportError.invalidJSON(detail: "顶层必须是对象。")
            }
            root = object
        } catch let error as StrictJSONDocumentParseError {
            throw MapSourceImportError.invalidJSON(detail: error.stableCode)
        }

        // Required top-level fields — no defaults (V1R1 §6.6).
        for key in requiredTopLevel where root[key] == nil {
            throw MapSourceImportError.invalidJSON(detail: "缺少必需顶层字段 \(key)。")
        }
        guard let format = root["format"] as? String,
              format == MarketScannerPriorMapSource.formatValue else {
            throw MapSourceImportError.invalidJSON(detail: "缺少或错误的 format 字段。")
        }
        guard let version = StrictJSONScalar.integer(root["version"]),
              version == MarketScannerPriorMapSource.versionValue else {
            throw MapSourceImportError.invalidJSON(detail: "缺少或错误的 version 字段。")
        }

        var warnings: [MapSourceWarning] = []
        var extensions: [String: Any] = [:]
        for key in root.keys where !knownTopLevel.contains(key) {
            extensions[key] = root[key]
            warnings.append(MapSourceWarning(
                code: "unknown_top_level_field",
                row: 0,
                floor: "",
                shapeType: nil,
                message: "未知顶层字段 \(key) 已保留到 extensions。"
            ))
        }

        guard let elementsValue = root["elements"] as? [Any] else {
            throw MapSourceImportError.invalidJSON(detail: "缺少 elements 数组。")
        }
        guard elementsValue.count <= MapSourceImportLimits.maximumElements else {
            throw MapSourceImportError.elementCountTooLarge(
                limit: MapSourceImportLimits.maximumElements)
        }

        var elements: [PriorMapSourceElement] = []
        for (index, item) in elementsValue.enumerated() {
            guard var element = item as? [String: Any] else {
                throw MapSourceImportError.elementNotObject(row: index + 1)
            }
            if !extensions.isEmpty {
                var source = element["source"] as? [String: Any] ?? [:]
                source["extensions"] = extensions
                element["source"] = source
            }
            elements.append(try decodeElement(element, index: index, warnings: &warnings))
        }

        let sourceIdentity: MapSourceIdentity?
        if let source = root["source"] as? [String: Any] {
            sourceIdentity = decodeIdentity(source)
        } else {
            sourceIdentity = nil
        }
        return ImportOutcome(elements: elements, warnings: warnings, sourceIdentity: sourceIdentity)
    }

    private static func decodeElement(
        _ element: [String: Any],
        index: Int,
        warnings: inout [MapSourceWarning]
    ) throws -> PriorMapSourceElement {
        // Required element fields — no defaults.
        for key in requiredElementKeys where element[key] == nil {
            throw MapSourceImportError.malformedRow(
                row: index + 1, reason: "缺少必需字段 \(key)。")
        }
        guard let sourceRow = StrictJSONScalar.integer(element["source_row"]) else {
            throw MapSourceImportError.malformedRow(
                row: index + 1, reason: "source_row 必须是非负整数。")
        }
        guard let floorID = element["floor_id"] as? String, !floorID.isEmpty else {
            throw MapSourceImportError.malformedRow(
                row: index + 1, reason: "floor_id 不能为空（禁止默认楼层）。")
        }
        guard let shapeType = element["shape_type"] as? String, !shapeType.isEmpty else {
            throw MapSourceImportError.malformedRow(
                row: index + 1, reason: "shape_type 不能为空（禁止默认类型）。")
        }
        guard let visible = StrictJSONScalar.boolean(element["visible"]) else {
            throw MapSourceImportError.malformedRow(
                row: index + 1, reason: "visible 必须是 JSON 布尔值。")
        }
        guard let locked = StrictJSONScalar.boolean(element["locked"]) else {
            throw MapSourceImportError.malformedRow(
                row: index + 1, reason: "locked 必须是 JSON 布尔值。")
        }
        guard let code = element["code"] as? String else {
            throw MapSourceImportError.malformedRow(
                row: index + 1, reason: "code 必须是字符串。")
        }
        let id: String
        if let idValue = element["id"] as? String, !idValue.isEmpty {
            id = idValue
        } else {
            id = "f\(floorID)-r\(sourceRow)"
        }

        let geometry = element["geometry"] as? [String: Any]
        var bounds: [String: Double]?
        if let boundsValue = element["bounds"] as? [String: Any] {
            var converted: [String: Double] = [:]
            for (key, value) in boundsValue {
                if let number = StrictJSONScalar.number(value) {
                    converted[key] = number
                } else {
                    throw MapSourceImportError.malformedRow(
                        row: sourceRow, reason: "bounds.\(key) 必须是有限数值。")
                }
            }
            bounds = converted
        }
        var center: [Double]?
        if let centerValue = element["center_m"] as? [Any] {
            var converted: [Double] = []
            for value in centerValue {
                guard let number = StrictJSONScalar.number(value) else {
                    throw MapSourceImportError.malformedRow(
                        row: sourceRow, reason: "center_m 必须是有限数值数组。")
                }
                converted.append(number)
            }
            center = converted
        }
        let yawRad: Double?
        if element["yaw_rad"] != nil {
            guard let value = StrictJSONScalar.number(element["yaw_rad"]) else {
                throw MapSourceImportError.malformedRow(
                    row: sourceRow, reason: "yaw_rad 必须是有限数值。")
            }
            yawRad = value
        } else {
            yawRad = nil
        }
        guard let source = element["source"] as? [String: Any] else {
            throw MapSourceImportError.malformedRow(
                row: sourceRow, reason: "缺少 source 原始字段。")
        }

        for key in element.keys where !knownElementKeys.contains(key) {
            warnings.append(MapSourceWarning(
                code: "unknown_element_field",
                row: sourceRow,
                floor: floorID,
                shapeType: shapeType,
                message: "元素包含未知字段 \(key)，已保留到 extensions。"
            ))
        }

        return PriorMapSourceElement(
            id: id,
            sourceRow: sourceRow,
            floorId: floorID,
            shapeType: shapeType,
            visible: visible,
            locked: locked,
            code: code,
            crossCode: element["cross_code"] as? String ?? "",
            rowFlag: element["row_flag"] as? String ?? "",
            subsection: element["subsection"] as? String,
            geometry: geometry,
            bounds: bounds,
            centerM: center,
            yawRad: yawRad,
            source: source
        )
    }

    private static func decodeIdentity(_ source: [String: Any]) -> MapSourceIdentity {
        return MapSourceIdentity(
            originalFormat: String(describing: source["originalFormat"] as? String ?? "json"),
            originalFilename: String(describing: source["originalFilename"] as? String ?? ""),
            sourceFileSha256: String(describing: source["sourceFileSha256"] as? String ?? ""),
            canonicalSourceSha256: String(describing: source["canonicalSourceSha256"] as? String ?? "")
        )
    }
}
