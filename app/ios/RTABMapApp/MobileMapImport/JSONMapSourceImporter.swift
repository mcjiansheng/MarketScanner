import Foundation

/// Imports a store map from a `MarketScannerPriorMapSource` JSON
/// document with a strict, total schema (V1R4 §14.1).
///
/// Version 2 (the canonical snake_case document produced by
/// `CanonicalPriorMapBusinessSourceV2`) is the primary format and is
/// self round-trippable: the document carries `store_id`, `map_name` and
/// `coordinate_contract` (which override the caller-provided wizard
/// parameters), and re-importing a canonical payload yields the same
/// business payload and digest. `source_row` and `source` are audit-only
/// in v2: a missing `source_row` defaults to the array position and a
/// missing `source` is reconstructed from the canonical element id so
/// stable identities survive the round trip.
///
/// Legacy version 1 documents (camelCase top level) are decoded by the
/// separate `LegacyV1JSONMapSourceDecoder` and keep their original field
/// rules (required `source_row`, required `source`, no document-level
/// store/name/contract recovery).
///
/// Required top-level fields (v2): `format`, `version`, `store_id`,
/// `map_name`, `coordinate_contract`, `elements`. Required element
/// fields: `id`, `floor_id`, `shape_type`, `visible`, `locked`, `code`.
/// Missing required fields are blockers — there is no default floor (no
/// `missing floor -> 1`) and no default shape (no
/// `missing shape -> Unknown`). Booleans are read through
/// `StrictJSONScalar.boolean`, integers through
/// `StrictJSONScalar.integer` and numbers through
/// `StrictJSONScalar.number`; a numeric 0/1 never passes as a boolean.
///
/// Unknown fields are preserved inside `source["extensions"]` — they are
/// never claimed as preserved and then dropped.
enum JSONMapSourceImporter {
    struct ImportOutcome {
        /// Document format version (1 = legacy, 2 = canonical).
        var documentVersion: Int
        /// Document-level identity (canonical v2 only; legacy keeps the
        /// caller-provided wizard parameters).
        var storeId: String?
        var mapName: String?
        var coordinateContract: CoordinateContract?
        var elements: [PriorMapSourceElement]
        var warnings: [MapSourceWarning]
        var sourceIdentity: MapSourceIdentity?
    }

    private static let v2RequiredTopLevel: Set<String> = [
        "format", "version", "store_id", "map_name",
        "coordinate_contract", "elements",
    ]
    /// Top-level keys known across both document versions (v2 snake_case
    /// and legacy v1 camelCase); anything else is preserved in
    /// `source["extensions"]` with a warning.
    static let knownTopLevel: Set<String> = v2RequiredTopLevel.union([
        "storeId", "mapName", "coordinateContract",
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

        guard let format = root["format"] as? String,
              format == MarketScannerPriorMapSource.formatValue else {
            throw MapSourceImportError.invalidJSON(detail: "缺少或错误的 format 字段。")
        }
        guard let version = StrictJSONScalar.integer(root["version"]) else {
            throw MapSourceImportError.invalidJSON(detail: "缺少或错误的 version 字段。")
        }
        switch version {
        case 2:
            return try decodeV2(root: root)
        case 1:
            // V1R4 §14.1: legacy v1 documents use a separate decoder.
            return try LegacyV1JSONMapSourceDecoder.decode(root: root)
        default:
            throw MapSourceImportError.invalidJSON(detail: "不支持的 version 字段。")
        }
    }

    // MARK: - Canonical v2

    private static func decodeV2(root: [String: Any]) throws -> ImportOutcome {
        // Required top-level fields — no defaults (V1R4 §14.1).
        for key in v2RequiredTopLevel where root[key] == nil {
            throw MapSourceImportError.invalidJSON(detail: "缺少必需顶层字段 \(key)。")
        }
        guard let storeID = root["store_id"] as? String, !storeID.isEmpty else {
            throw MapSourceImportError.invalidJSON(detail: "store_id 不能为空。")
        }
        guard let mapName = root["map_name"] as? String, !mapName.isEmpty else {
            throw MapSourceImportError.invalidJSON(detail: "map_name 不能为空。")
        }
        try MapSourceBusinessIdentityPolicy.validate(
            storeID: storeID, mapName: mapName)
        let contract = try decodeCoordinateContract(root["coordinate_contract"])

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

        let elements = try decodeElements(
            root: root, extensions: extensions, warnings: &warnings,
            sourceRowRequired: false, sourceRequired: false)

        let sourceIdentity: MapSourceIdentity?
        if let source = root["source"] as? [String: Any] {
            sourceIdentity = decodeIdentity(source)
        } else {
            sourceIdentity = nil
        }
        return ImportOutcome(
            documentVersion: 2,
            storeId: storeID,
            mapName: mapName,
            coordinateContract: contract,
            elements: elements,
            warnings: warnings,
            sourceIdentity: sourceIdentity)
    }

    // MARK: - Shared element decoding

    static func decodeElements(
        root: [String: Any],
        extensions: [String: Any],
        warnings: inout [MapSourceWarning],
        sourceRowRequired: Bool,
        sourceRequired: Bool
    ) throws -> [PriorMapSourceElement] {
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
            elements.append(try decodeElement(
                element, index: index,
                sourceRowRequired: sourceRowRequired,
                sourceRequired: sourceRequired,
                warnings: &warnings))
        }
        return elements
    }

    static func decodeElement(
        _ element: [String: Any],
        index: Int,
        sourceRowRequired: Bool,
        sourceRequired: Bool,
        warnings: inout [MapSourceWarning]
    ) throws -> PriorMapSourceElement {
        // Required element fields — no defaults. In canonical v2 the
        // audit-only fields (`source_row`, `source`) are optional.
        var required = requiredElementKeys
        if !sourceRowRequired {
            required.remove("source_row")
        }
        if !sourceRequired {
            required.remove("source")
        }
        for key in required where element[key] == nil {
            throw MapSourceImportError.malformedRow(
                row: index + 1, reason: "缺少必需字段 \(key)。")
        }
        let sourceRow: Int
        if let value = StrictJSONScalar.integer(element["source_row"]) {
            guard value >= 0 else {
                throw MapSourceImportError.malformedRow(
                    row: index + 1, reason: "source_row 必须是非负整数。")
            }
            sourceRow = value
        } else if sourceRowRequired {
            throw MapSourceImportError.malformedRow(
                row: index + 1, reason: "source_row 必须是非负整数。")
        } else {
            sourceRow = index + 1
        }
        guard let floorID = element["floor_id"] as? String, !floorID.isEmpty else {
            throw MapSourceImportError.malformedRow(
                row: sourceRow, reason: "floor_id 不能为空（禁止默认楼层）。")
        }
        guard let shapeType = element["shape_type"] as? String, !shapeType.isEmpty else {
            throw MapSourceImportError.malformedRow(
                row: sourceRow, reason: "shape_type 不能为空（禁止默认类型）。")
        }
        guard let visible = StrictJSONScalar.boolean(element["visible"]) else {
            throw MapSourceImportError.malformedRow(
                row: sourceRow, reason: "visible 必须是 JSON 布尔值。")
        }
        guard let locked = StrictJSONScalar.boolean(element["locked"]) else {
            throw MapSourceImportError.malformedRow(
                row: sourceRow, reason: "locked 必须是 JSON 布尔值。")
        }
        guard let code = element["code"] as? String else {
            throw MapSourceImportError.malformedRow(
                row: sourceRow, reason: "code 必须是字符串。")
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
        let source: [String: Any]
        if let rawSource = element["source"] as? [String: Any] {
            source = rawSource
        } else if sourceRequired {
            throw MapSourceImportError.malformedRow(
                row: sourceRow, reason: "缺少 source 原始字段。")
        } else {
            // Canonical v2 payloads never carry raw fields; identity is
            // restored from the element id so stable ids survive round
            // trips (the id becomes the official source id again).
            source = ["id": id]
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

    /// Strict coordinate-contract decode; a present-but-invalid contract
    /// is a blocker (V1R4 §14.1 round trip never falls back silently).
    static func decodeCoordinateContract(_ raw: Any?) throws -> CoordinateContract {
        guard let object = raw as? [String: Any] else {
            throw MapSourceImportError.invalidJSON(detail: "coordinate_contract 必须是对象。")
        }
        guard let unit = object["unit"] as? String,
              let originRaw = object["origin"] as? String,
              let origin = CoordinateContract.Origin(rawValue: originRaw),
              let xAxis = object["x_axis"] as? String,
              let yAxis = object["y_axis"] as? String,
              let rotationDirection = object["rotation_direction"] as? String
        else {
            throw MapSourceImportError.invalidJSON(detail: "coordinate_contract 字段不完整。")
        }
        return CoordinateContract(
            unit: unit, origin: origin, xAxis: xAxis,
            yAxis: yAxis, rotationDirection: rotationDirection)
    }

    static func decodeIdentity(_ source: [String: Any]) -> MapSourceIdentity {
        return MapSourceIdentity(
            originalFormat: String(describing: source["originalFormat"] as? String ?? "json"),
            originalFilename: String(describing: source["originalFilename"] as? String ?? ""),
            sourceFileSha256: String(describing: source["sourceFileSha256"] as? String ?? ""),
            canonicalSourceSha256: String(describing: source["canonicalSourceSha256"] as? String ?? "")
        )
    }
}

/// Separate decoder for legacy version 1 `MarketScannerPriorMapSource`
/// documents (V1R4 §14.1). Top level is camelCase
/// (`storeId` / `mapName` / `coordinateContract`); element fields are the
/// same snake_case keys as v2. Legacy documents never override the
/// caller-provided store/name/contract: those stay coordinator
/// parameters, preserving the original v1 behavior.
enum LegacyV1JSONMapSourceDecoder {
    private static let requiredTopLevel: Set<String> = [
        "format", "version", "storeId", "mapName",
        "coordinateContract", "elements",
    ]

    static func decode(root: [String: Any]) throws -> JSONMapSourceImporter.ImportOutcome {
        // Required top-level fields — no defaults (V1R1 §6.6).
        for key in requiredTopLevel where root[key] == nil {
            throw MapSourceImportError.invalidJSON(detail: "缺少必需顶层字段 \(key)。")
        }
        guard let storeID = root["storeId"] as? String,
              let mapName = root["mapName"] as? String else {
            throw MapSourceImportError.invalidJSON(
                detail: "storeId/mapName 必须是字符串。")
        }
        try MapSourceBusinessIdentityPolicy.validate(
            storeID: storeID, mapName: mapName)

        var warnings: [MapSourceWarning] = []
        var extensions: [String: Any] = [:]
        for key in root.keys where !JSONMapSourceImporter.knownTopLevel.contains(key) {
            extensions[key] = root[key]
            warnings.append(MapSourceWarning(
                code: "unknown_top_level_field",
                row: 0,
                floor: "",
                shapeType: nil,
                message: "未知顶层字段 \(key) 已保留到 extensions。"
            ))
        }

        let elements = try JSONMapSourceImporter.decodeElements(
            root: root, extensions: extensions, warnings: &warnings,
            sourceRowRequired: true, sourceRequired: true)

        let sourceIdentity: MapSourceIdentity?
        if let source = root["source"] as? [String: Any] {
            sourceIdentity = JSONMapSourceImporter.decodeIdentity(source)
        } else {
            sourceIdentity = nil
        }
        return JSONMapSourceImporter.ImportOutcome(
            documentVersion: 1,
            storeId: nil,
            mapName: nil,
            coordinateContract: nil,
            elements: elements,
            warnings: warnings,
            sourceIdentity: sourceIdentity)
    }
}
