import Foundation

/// Imports the canonical V1 CSV layout:
///
/// ```csv
/// floor,element
/// 1,"{""type"":""MapShelf"",...}"
/// ```
///
/// Every business row must be well formed; in the formal (default) mode
/// any malformed row is an import blocker — malformed rows are never
/// silently skipped. The parsed rows feed the same element normalizer as
/// the XLSX and JSON importers so the three formats produce one canonical
/// source.
enum CSVMapSourceImporter {
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
        var elements: [PriorMapSourceElement] = []
        var warnings: [MapSourceWarning] = []
        var malformedRows: [[String: Any]] = []
        var headerColumns: [String] = []
        var rowNumber = 0

        try RFC4180CSVReader.parse(data: data) { record in
            rowNumber += 1
            if rowNumber == 1 {
                headerColumns = record.fields.map { $0.trimmingCharacters(in: .whitespaces) }
                try validateHeader(headerColumns)
                return
            }
            let fields = record.fields
            guard fields.count == headerColumns.count else {
                throw MapSourceImportError.csvFieldCountMismatch(
                    row: rowNumber, expected: headerColumns.count, actual: fields.count)
            }
            var values: [String: String] = [:]
            for (index, column) in headerColumns.enumerated() {
                values[column] = fields[index]
            }
            guard let floorValue = values[Self.floorColumn], !floorValue.isEmpty else {
                throw MapSourceImportError.emptyFloor(row: rowNumber)
            }
            guard let elementValue = values[Self.elementColumn] else {
                throw MapSourceImportError.malformedRow(
                    row: rowNumber, reason: "缺少 element 列。")
            }
            do {
                let raw = try parseElementJSON(elementValue, row: rowNumber)
                let element = ElementNormalizer.normalize(
                    floor: floorValue,
                    row: rowNumber,
                    raw: raw,
                    contract: contract,
                    warnings: &warnings
                )
                elements.append(element)
            } catch let error as MapSourceImportError {
                malformedRows.append([
                    "row": rowNumber,
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

    private static func validateHeader(_ columns: [String]) throws {
        guard columns.contains(Self.floorColumn) else {
            throw MapSourceImportError.missingHeader(column: Self.floorColumn)
        }
        guard columns.contains(Self.elementColumn) else {
            throw MapSourceImportError.missingHeader(column: Self.elementColumn)
        }
        var seen: Set<String> = []
        for column in columns {
            guard !column.isEmpty else {
                throw MapSourceImportError.malformedRow(row: 1, reason: "存在空列名。")
            }
            if seen.contains(column) {
                throw MapSourceImportError.duplicateHeader(column: column)
            }
            seen.insert(column)
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
}

extension StrictJSONDocumentParseError {
    var stableCode: String {
        switch self {
        case .documentTooLarge: return "json_document_too_large"
        case .invalidUTF8: return "invalid_utf8"
        case .duplicateJSONKey: return "duplicate_json_key"
        case .invalidJSON: return "invalid_json"
        case .topLevelTypeMismatch: return "top_level_type_mismatch"
        }
    }
}
