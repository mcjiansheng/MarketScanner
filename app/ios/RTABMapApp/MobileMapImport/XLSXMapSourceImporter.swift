import Foundation

/// Imports a store map from a real Open XML `.xlsx` workbook.
///
/// Only the `Element Info` sheet is read. The workbook is first parsed
/// through the hardened ZIP reader (traversal / bomb defences), then the
/// sheet is located through workbook relationships — the sheet name is
/// never guessed. Formula cells in the `floor` / `element` columns are
/// rejected with `map_source_formula_not_supported`.
enum XLSXMapSourceImporter {
    static let floorColumn = "floor"
    static let elementColumn = "element"

    struct ImportOutcome {
        var elements: [PriorMapSourceElement]
        var warnings: [MapSourceWarning]
        var malformedRows: [[String: Any]]
    }

    static func importSource(
        data: Data,
        contract: CoordinateContract,
        strict: Bool = true
    ) throws -> ImportOutcome {
        let entries = try XLSXZipReader.readEntries(data: data)
        guard entries.count <= XLSXZipReader.maximumEntries else {
            throw MapSourceImportError.zipEntryTooMany(limit: XLSXZipReader.maximumEntries)
        }

        let sheets = try XLSXWorkbookReader.readSheets(entries: entries)
        guard let sheet = sheets.first(where: { $0.name == XLSXWorkbookReader.sheetName }) else {
            throw MapSourceImportError.xlsxSheetNotFound(name: XLSXWorkbookReader.sheetName)
        }
        let relationships = try XLSXWorkbookReader.readRelationships(entries: entries)
        let target = try XLSXWorkbookReader.worksheetTarget(
            relationships: relationships, for: sheet.relationshipID)
        let sharedStrings = try XLSXWorkbookReader.readSharedStrings(entries: entries)
        let worksheetEntry = try XLSXWorkbookReader.worksheetEntry(entries: entries, target: target)
        let rows = try XLSXWorksheetReader.readWorksheet(
            entry: worksheetEntry, sharedStrings: sharedStrings)

        return try mapRows(rows, contract: contract, strict: strict)
    }

    private static func mapRows(
        _ rows: [XLSXWorksheetReader.Row],
        contract: CoordinateContract,
        strict: Bool
    ) throws -> ImportOutcome {
        var elements: [PriorMapSourceElement] = []
        var warnings: [MapSourceWarning] = []
        var malformedRows: [[String: Any]] = []
        var headerColumns: [String: String] = [:] // column letter -> header name
        var dataRows = 0

        for row in rows {
            let cells = row.cells
            if headerColumns.isEmpty {
                for (column, cell) in cells.sorted(by: { Self.columnNumber($0.key) < Self.columnNumber($1.key) }) {
                    guard let value = cell.value else { continue }
                    let name = value.trimmingCharacters(in: .whitespaces)
                        .replacingOccurrences(of: "\u{FEFF}", with: "")
                    if !name.isEmpty {
                        headerColumns[column] = name
                    }
                }
                try validateHeader(headerColumns, firstRow: row.number)
                continue
            }
            dataRows += 1
            guard let floorColumn = headerColumns.first(where: { $0.value == Self.floorColumn })?.key,
                  let elementColumn = headerColumns.first(where: { $0.value == Self.elementColumn })?.key
            else {
                throw MapSourceImportError.missingHeader(column: Self.floorColumn)
            }
            guard let floorCell = cells[floorColumn], let floorValue = floorCell.value,
                  !floorValue.trimmingCharacters(in: .whitespaces).isEmpty
            else {
                throw MapSourceImportError.emptyFloor(row: row.number)
            }
            guard let elementCell = cells[elementColumn] else {
                throw MapSourceImportError.malformedRow(row: row.number, reason: "缺少 element 列。")
            }
            do {
                let raw = try parseElementJSON(elementCell.value ?? "", row: row.number)
                let element = ElementNormalizer.normalize(
                    floor: floorValue,
                    row: row.number,
                    raw: raw,
                    contract: contract,
                    warnings: &warnings
                )
                elements.append(element)
            } catch let error as MapSourceImportError {
                malformedRows.append([
                    "row": row.number,
                    "floor": floorValue,
                    "code": error.stableCode,
                    "message": error.message,
                ])
                if strict {
                    throw error
                }
            }
        }
        return ImportOutcome(elements: elements, warnings: warnings, malformedRows: malformedRows)
    }

    private static func validateHeader(_ headerColumns: [String: String], firstRow: Int) throws {
        guard headerColumns.values.contains(Self.floorColumn) else {
            throw MapSourceImportError.missingHeader(column: Self.floorColumn)
        }
        guard headerColumns.values.contains(Self.elementColumn) else {
            throw MapSourceImportError.missingHeader(column: Self.elementColumn)
        }
        var seen: Set<String> = []
        for name in headerColumns.values {
            if seen.contains(name) {
                throw MapSourceImportError.duplicateHeader(column: name)
            }
            seen.insert(name)
        }
    }

    private static func parseElementJSON(_ text: String, row: Int) throws -> [String: Any] {
        guard let data = text.data(using: .utf8) else {
            throw MapSourceImportError.invalidUTF8(detail: "第 \(row) 行 element 非法 UTF-8。")
        }
        do {
            let limits = StrictJSONDocumentLimits(
                maximumBytes: Int(MapSourceImportLimits.maximumCellBytes),
                maximumNestingDepth: MapSourceImportLimits.maximumJSONNestingDepth
            )
            guard let object = try StrictJSONDocumentParser.object(
                from: data, limits: limits) as? [String: Any]
            else {
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
            number = number * 26 + digit
        }
        return number
    }
}
