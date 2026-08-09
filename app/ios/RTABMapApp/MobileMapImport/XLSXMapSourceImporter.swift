import Foundation

/// Imports either the standard three-sheet workbook or the explicitly
/// legacy Element-Info-only workbook. A standard workbook is identified by
/// `Basic Info`; its business identity/canvas and top-left coordinate
/// contract are authoritative. `Shelf Info` is counted for audit only and
/// is never parsed or merged into production geometry.
enum XLSXMapSourceImporter {
    static let elementSheetName = "Element Info"
    static let basicSheetName = "Basic Info"
    static let shelfSheetName = "Shelf Info"
    static let floorColumn = "floor"
    static let elementColumn = "element"

    struct ImportOutcome {
        var basicInfo: SourceMapInfo?
        var elements: [PriorMapSourceElement]
        var ignoredElements: [PriorMapSourceElement]
        var warnings: [MapSourceWarning]
        var malformedRows: [[String: Any]]
        var legacyShelfInfoPresent: Bool
        var legacyShelfInfoRowCount: Int
        var sourceElementCount: Int
    }

    static func importSource(
        data: Data,
        contract: CoordinateContract,
        strict: Bool = true,
        allowLegacyElementOnly: Bool = false
    ) throws -> ImportOutcome {
        let entries = try XLSXZipReader.readEntries(data: data)
        guard entries.count <= XLSXZipReader.maximumEntries else {
            throw MapSourceImportError.zipEntryTooMany(limit: XLSXZipReader.maximumEntries)
        }

        let sheets = try XLSXWorkbookReader.readSheets(entries: entries)
        try rejectDuplicateNamedSheets(sheets)
        guard let elementSheet = sheets.first(where: { $0.name == elementSheetName }) else {
            throw MapSourceImportError.xlsxSheetNotFound(name: elementSheetName)
        }
        let relationships = try XLSXWorkbookReader.readRelationships(entries: entries)
        try XLSXWorkbookReader.validateSheetAuthorities(
            sheets: sheets, relationships: relationships, entries: entries)
        let sharedStrings = try XLSXWorkbookReader.readSharedStrings(entries: entries)

        let basicInfo: SourceMapInfo?
        if let basicSheet = sheets.first(where: { $0.name == basicSheetName }) {
            basicInfo = try parseBasicInfo(try rows(
                for: basicSheet,
                relationships: relationships,
                sharedStrings: sharedStrings,
                entries: entries))
        } else {
            guard allowLegacyElementOnly else {
                throw MapSourceImportError.xlsxSheetNotFound(name: basicSheetName)
            }
            basicInfo = nil
        }

        let shelfSheet = sheets.first(where: { $0.name == shelfSheetName })
        let shelfRowCount: Int
        if let shelfSheet = shelfSheet {
            let target = try XLSXWorkbookReader.worksheetTarget(
                relationships: relationships,
                for: shelfSheet.relationshipID)
            let entry = try XLSXWorkbookReader.worksheetEntry(
                entries: entries, target: target)
            shelfRowCount = try XLSXWorksheetReader.countAuditOnlyBusinessRows(
                entry: entry)
        } else {
            shelfRowCount = 0
        }

        let elementRows = try rows(
            for: elementSheet,
            relationships: relationships,
            sharedStrings: sharedStrings,
            entries: entries)
        // Formal workbooks cannot be changed to bottom-left by a wizard
        // selection. Legacy element-only workbooks retain their old preset.
        let effectiveContract: CoordinateContract = basicInfo == nil ? contract : .topLeft
        let mapped = try mapRows(
            elementRows,
            contract: effectiveContract,
            canvas: basicInfo?.sourceCanvasBounds,
            strict: strict)
        var warnings = mapped.warnings
        let filtered = ElementRoleClassifier.productionElements(
            from: mapped.elements, warnings: &warnings)
        return ImportOutcome(
            basicInfo: basicInfo,
            elements: filtered.active,
            ignoredElements: filtered.ignored,
            warnings: warnings,
            malformedRows: mapped.malformedRows,
            legacyShelfInfoPresent: shelfSheet != nil,
            legacyShelfInfoRowCount: shelfRowCount,
            sourceElementCount: mapped.elements.count)
    }

    private static func rejectDuplicateNamedSheets(
        _ sheets: [XLSXWorkbookReader.SheetInfo]
    ) throws {
        for name in [basicSheetName, shelfSheetName, elementSheetName] {
            guard sheets.filter({ $0.name == name }).count <= 1 else {
                throw MapSourceImportError.xlsxInvalidXML(
                    name: "xl/workbook.xml",
                    reason: "工作表名称 \(name) 重复。")
            }
        }
    }

    private static func rows(
        for sheet: XLSXWorkbookReader.SheetInfo,
        relationships: [XLSXWorkbookReader.Relationship],
        sharedStrings: [String],
        entries: [XLSXZipReader.Entry]
    ) throws -> [XLSXWorksheetReader.Row] {
        let target = try XLSXWorkbookReader.worksheetTarget(
            relationships: relationships, for: sheet.relationshipID)
        let entry = try XLSXWorkbookReader.worksheetEntry(
            entries: entries, target: target)
        return try XLSXWorksheetReader.readWorksheet(
            entry: entry, sharedStrings: sharedStrings)
    }

    private static func parseBasicInfo(
        _ rows: [XLSXWorksheetReader.Row]
    ) throws -> SourceMapInfo {
        let populated = rows.filter { row in
            row.cells.values.contains { cell in
                !(cell.value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        }
        guard populated.count == 2 else {
            throw MapSourceImportError.malformedRow(
                row: populated.last?.number ?? 0,
                reason: "Basic Info 必须且只能包含一行地图数据。")
        }
        let header = populated[0]
        var columns: [String: String] = [:]
        for (column, cell) in header.cells {
            let name = (cell.value ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\u{FEFF}", with: "")
            if !name.isEmpty {
                guard columns[name] == nil else {
                    throw MapSourceImportError.duplicateHeader(column: name)
                }
                columns[name] = column
            }
        }
        let required = ["map_name", "width", "height", "storeCode"]
        for name in required where columns[name] == nil {
            throw MapSourceImportError.missingHeader(column: "Basic Info.\(name)")
        }
        let values = populated[1]
        func text(_ key: String, preserveIdentity: Bool = false) throws -> String {
            guard let column = columns[key],
                  let raw = values.cells[column]?.value else {
                throw MapSourceImportError.malformedRow(
                    row: values.number, reason: "Basic Info.\(key) 不能为空。")
            }
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else {
                throw MapSourceImportError.malformedRow(
                    row: values.number, reason: "Basic Info.\(key) 不能为空。")
            }
            if preserveIdentity, raw != value {
                throw MapSourceImportError.invalidBusinessIdentity(
                    field: key,
                    reason: "leading/trailing whitespace is forbidden")
            }
            return preserveIdentity ? raw : value
        }
        func number(_ key: String) throws -> Double {
            let raw = try text(key)
            guard let value = Double(raw), value.isFinite, value > 0 else {
                throw MapSourceImportError.malformedRow(
                    row: values.number, reason: "Basic Info.\(key) 必须是正有限数值。")
            }
            return value
        }
        let info = SourceMapInfo(
            mapName: try text("map_name", preserveIdentity: true),
            storeCode: try text("storeCode", preserveIdentity: true),
            widthCm: try number("width"),
            heightCm: try number("height"),
            scale: try columns["scale"].flatMap { column in
                let raw = values.cells[column]?.value?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return raw.isEmpty ? nil : raw
            }.map { raw in
                guard let value = Double(raw), value.isFinite, value > 0 else {
                    throw MapSourceImportError.malformedRow(
                        row: values.number,
                        reason: "Basic Info.scale 必须是正有限数值。")
                }
                return value
            })
        try MapSourceBusinessIdentityPolicy.validate(
            storeID: info.storeCode, mapName: info.mapName)
        return info
    }

    private struct MappedRows {
        var elements: [PriorMapSourceElement]
        var warnings: [MapSourceWarning]
        var malformedRows: [[String: Any]]
    }

    private static func mapRows(
        _ rows: [XLSXWorksheetReader.Row],
        contract: CoordinateContract,
        canvas: SourceGeometry.Bounds?,
        strict: Bool
    ) throws -> MappedRows {
        var elements: [PriorMapSourceElement] = []
        var warnings: [MapSourceWarning] = []
        var malformedRows: [[String: Any]] = []
        var headerColumns: [String: String] = [:]
        var sourceElementRowCount = 0

        for row in rows {
            let cells = row.cells
            if headerColumns.isEmpty {
                for (column, cell) in cells.sorted(by: {
                    columnNumber($0.key) < columnNumber($1.key)
                }) {
                    guard let value = cell.value else { continue }
                    let name = value.trimmingCharacters(in: .whitespaces)
                        .replacingOccurrences(of: "\u{FEFF}", with: "")
                    if !name.isEmpty { headerColumns[column] = name }
                }
                try validateHeader(headerColumns)
                continue
            }
            sourceElementRowCount += 1
            try enforceElementCount(sourceElementRowCount)
            guard let floorColumn = headerColumns.first(where: {
                $0.value == Self.floorColumn
            })?.key,
            let elementColumn = headerColumns.first(where: {
                $0.value == Self.elementColumn
            })?.key else {
                throw MapSourceImportError.missingHeader(column: Self.floorColumn)
            }
            guard let floorValue = cells[floorColumn]?.value,
                  !floorValue.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw MapSourceImportError.emptyFloor(row: row.number)
            }
            guard let elementCell = cells[elementColumn] else {
                throw MapSourceImportError.malformedRow(
                    row: row.number, reason: "缺少 element 列。")
            }
            do {
                let raw = try parseElementJSON(elementCell.value ?? "", row: row.number)
                let element = try ElementNormalizer.normalize(
                    floor: floorValue,
                    row: row.number,
                    raw: raw,
                    contract: contract,
                    rectangleSemantics: canvas == nil
                        ? .legacyCenterPivot : .topLeftAnchor,
                    strict: strict,
                    warnings: &warnings)
                let role = ElementRoleClassifier.role(for: element.shapeType)
                if strict, role.isProduction, element.visible,
                   let canvas = canvas,
                   !SourceGeometry.contains(geometry: element.geometry, in: canvas) {
                    throw MapSourceImportError.invalidGeometry(
                        shapeType: element.shapeType,
                        reason: "active geometry is outside Basic Info source canvas")
                }
                elements.append(element)
            } catch let error as MapSourceImportError {
                malformedRows.append([
                    "row": row.number,
                    "floor": floorValue,
                    "code": error.stableCode,
                    "message": error.message,
                ])
                if strict { throw error }
            }
        }
        return MappedRows(
            elements: elements, warnings: warnings,
            malformedRows: malformedRows)
    }

    /// The Element Info authority is bounded by source business rows, not
    /// merely by rows that happened to parse successfully. Otherwise a
    /// workbook could make the importer process hundreds of thousands of
    /// malformed rows while staying below the active-element limit.
    static func enforceElementCount(_ count: Int) throws {
        guard count <= MapSourceImportLimits.maximumElements else {
            throw MapSourceImportError.elementCountTooLarge(
                limit: MapSourceImportLimits.maximumElements)
        }
    }

    private static func validateHeader(_ columns: [String: String]) throws {
        guard columns.values.contains(floorColumn) else {
            throw MapSourceImportError.missingHeader(column: floorColumn)
        }
        guard columns.values.contains(elementColumn) else {
            throw MapSourceImportError.missingHeader(column: elementColumn)
        }
        var seen: Set<String> = []
        for name in columns.values {
            guard seen.insert(name).inserted else {
                throw MapSourceImportError.duplicateHeader(column: name)
            }
        }
    }

    private static func parseElementJSON(
        _ text: String,
        row: Int
    ) throws -> [String: Any] {
        guard let data = text.data(using: .utf8) else {
            throw MapSourceImportError.invalidUTF8(
                detail: "第 \(row) 行 element 非法 UTF-8。")
        }
        do {
            let limits = StrictJSONDocumentLimits(
                maximumBytes: Int(MapSourceImportLimits.maximumCellBytes),
                maximumNestingDepth: MapSourceImportLimits.maximumJSONNestingDepth)
            guard let object = try StrictJSONDocumentParser.object(
                from: data, limits: limits) as? [String: Any] else {
                throw MapSourceImportError.elementNotObject(row: row)
            }
            return object
        } catch let error as StrictJSONDocumentParseError {
            throw MapSourceImportError.malformedRow(
                row: row, reason: error.stableCode)
        } catch let error as MapSourceImportError {
            throw error
        }
    }

    static func columnNumber(_ letters: String) -> Int {
        var number = 0
        for scalar in letters.unicodeScalars {
            let value = Int(scalar.value)
            let digit = value >= 0x41 && value <= 0x5A ? value - 0x40
                : (value >= 0x61 && value <= 0x7A ? value - 0x60 : 0)
            guard digit > 0,
                  number <= (MapSourceImportLimits.maximumWorksheetColumns - digit) / 26 else {
                return Int.max
            }
            number = number * 26 + digit
        }
        return number > 0 && number <= MapSourceImportLimits.maximumWorksheetColumns
            ? number : Int.max
    }
}
