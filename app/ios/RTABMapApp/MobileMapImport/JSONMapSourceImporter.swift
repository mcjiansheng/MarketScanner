import Foundation

/// Imports a store map from a canonical `MarketScannerPriorMapSource`
/// v1 JSON document. The document goes through the strict parser first
/// (UTF-8, no duplicate keys, no NaN, depth/size limits); unknown
/// top-level or element fields are preserved verbatim and recorded as
/// warnings, never dropped.
enum JSONMapSourceImporter {
    struct ImportOutcome {
        var elements: [PriorMapSourceElement]
        var warnings: [MapSourceWarning]
        var sourceIdentity: MapSourceIdentity?
    }

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
        guard let version = root["version"] as? Int,
              version == MarketScannerPriorMapSource.versionValue else {
            throw MapSourceImportError.invalidJSON(detail: "缺少或错误的 version 字段。")
        }

        var warnings: [MapSourceWarning] = []
        let knownTopLevel: Set<String> = [
            "format", "version", "storeId", "mapName", "source",
            "coordinateContract", "elements", "warnings",
        ]
        for key in root.keys where !knownTopLevel.contains(key) {
            warnings.append(MapSourceWarning(
                code: "unknown_top_level_field",
                row: 0,
                floor: "",
                shapeType: nil,
                message: "未知顶层字段 \(key) 已保留。"
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
            guard let element = item as? [String: Any] else {
                throw MapSourceImportError.elementNotObject(row: index + 1)
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
        let row = element["source_row"] as? Int ?? (index + 1)
        let geometry = element["geometry"] as? [String: Any]
        var bounds: [String: Double]?
        if let boundsValue = element["bounds"] as? [String: Any] {
            var converted: [String: Double] = [:]
            for (key, value) in boundsValue {
                if let number = ElementNormalizer.asDouble(value) {
                    converted[key] = number
                }
            }
            bounds = converted
        }
        var center: [Double]?
        if let centerValue = element["center_m"] as? [Any] {
            center = centerValue.compactMap { ElementNormalizer.asDouble($0) }
        }
        let yawRad = element["yaw_rad"].flatMap { ElementNormalizer.asDouble($0) }
        let source = element["source"] as? [String: Any] ?? [:]

        let knownElementKeys: Set<String> = [
            "id", "source_row", "floor_id", "shape_type", "visible",
            "locked", "code", "cross_code", "row_flag", "subsection",
            "geometry", "bounds", "center_m", "yaw_rad", "source",
        ]
        for key in element.keys where !knownElementKeys.contains(key) {
            warnings.append(MapSourceWarning(
                code: "unknown_element_field",
                row: row,
                floor: String(describing: element["floor_id"] as? String ?? ""),
                shapeType: element["shape_type"] as? String,
                message: "元素包含未知字段 \(key) 已保留。"
            ))
        }

        return PriorMapSourceElement(
            id: String(describing: element["id"] as? String ?? "f\(row)"),
            sourceRow: row,
            floorId: stringValue(element["floor_id"], fallback: "1"),
            shapeType: String(describing: element["shape_type"] as? String ?? "Unknown"),
            visible: (element["visible"] as? Bool) ?? true,
            locked: (element["locked"] as? Bool) ?? false,
            code: stringValue(element["code"], fallback: ""),
            crossCode: String(describing: element["cross_code"] as? String ?? ""),
            rowFlag: String(describing: element["row_flag"] as? String ?? ""),
            subsection: element["subsection"] as? String,
            geometry: geometry,
            bounds: bounds,
            centerM: center,
            yawRad: yawRad,
            source: source
        )
    }

    private static func stringValue(_ value: Any?, fallback: String) -> String {
        if let text = value as? String { return text }
        if let number = value as? Int { return String(number) }
        return fallback
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
