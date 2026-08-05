import Foundation

/// Streaming parser for one worksheet part, returning rows keyed by
/// column letter. Cells whose value comes from a formula (`<f>`) or from
/// a formula-only type (`t="str"`) are rejected — the mobile device can
/// never trust cached workbook calculation results.
enum XLSXWorksheetReader {
    struct Cell {
        var column: String
        var value: String?
        var isFormula: Bool
    }

    struct Row {
        var number: Int
        var cells: [String: Cell]
    }

    static func readWorksheet(
        entry: XLSXZipReader.Entry,
        sharedStrings: [String]
    ) throws -> [Row] {
        let handler = WorksheetHandler(sharedStrings: sharedStrings)
        let parser = XMLParser(data: entry.data)
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = false
        parser.delegate = handler
        guard parser.parse() else {
            if let handlerError = handler.error {
                throw handlerError
            }
            if let parserError = parser.parserError {
                throw MapSourceImportError.xlsxInvalidXML(
                    name: entry.name, reason: parserError.localizedDescription)
            }
            throw MapSourceImportError.xlsxInvalidXML(name: entry.name, reason: "解析失败。")
        }
        return handler.rows
    }
}

/// SAX state machine for `sheetData`:
/// `row → c[@r,@t] → (f | v | is > t)`.
private final class WorksheetHandler: NSObject, XMLParserDelegate {
    var rows: [XLSXWorksheetReader.Row] = []
    var error: Error?

    private let sharedStrings: [String]
    private var currentRow: XLSXWorksheetReader.Row?
    private var currentCell: XLSXWorksheetReader.Cell?
    private var cellType: String?
    private var inValue = false
    private var inInlineText = false
    private var textBuffer = ""
    private var currentElement = ""

    init(sharedStrings: [String]) {
        self.sharedStrings = sharedStrings
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        currentElement = elementName
        textBuffer = ""
        switch elementName {
        case "row":
            let number = Int(attributeDict["r"] ?? "") ?? 0
            currentRow = XLSXWorksheetReader.Row(number: number, cells: [:])
        case "c":
            let reference = attributeDict["r"] ?? ""
            currentCell = XLSXWorksheetReader.Cell(
                column: Self.columnLetters(from: reference),
                value: nil,
                isFormula: false
            )
            cellType = attributeDict["t"]
        case "f":
            if currentCell != nil {
                error = formulaError()
                parser.abortParsing()
            }
        case "v":
            inValue = true
        case "is":
            break
        case "t":
            // Inside inline strings the <t> child carries the text.
            inInlineText = true
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inValue || inInlineText {
            textBuffer += string
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        switch elementName {
        case "v":
            inValue = false
            currentCell = XLSXWorksheetReader.Cell(
                column: currentCell?.column ?? "",
                value: textBuffer,
                isFormula: currentCell?.isFormula ?? false
            )
        case "t":
            inInlineText = false
        case "c":
            resolveCell(parser)
        case "row":
            if let row = currentRow {
                if rows.count + 1 > MapSourceImportLimits.maximumWorksheetRows {
                    error = MapSourceImportError.xlsxRowTooMany(
                        limit: MapSourceImportLimits.maximumWorksheetRows)
                    parser.abortParsing()
                    return
                }
                rows.append(row)
            }
            currentRow = nil
        default:
            break
        }
    }

    private func resolveCell(_ parser: XMLParser) {
        guard let cell = currentCell else { return }
        defer { currentCell = nil; cellType = nil }
        guard var row = currentRow, !cell.column.isEmpty else { return }
        if cell.isFormula {
            error = formulaError()
            parser.abortParsing()
            return
        }
        let resolved: XLSXWorksheetReader.Cell
        switch cellType {
        case "s":
            // Shared string index.
            guard let raw = cell.value,
                  let index = Int(raw.trimmingCharacters(in: .whitespaces)),
                  index >= 0, index < sharedStrings.count
            else {
                error = MapSourceImportError.xlsxInvalidXML(
                    name: "worksheet", reason: "共享字符串索引越界。")
                parser.abortParsing()
                return
            }
            resolved = XLSXWorksheetReader.Cell(
                column: cell.column, value: sharedStrings[index], isFormula: false)
        case "inlineStr":
            resolved = XLSXWorksheetReader.Cell(
                column: cell.column, value: cell.value, isFormula: false)
        case "b":
            let numeric = (cell.value?.trimmingCharacters(in: .whitespaces) == "1") ? "1" : "0"
            resolved = XLSXWorksheetReader.Cell(
                column: cell.column, value: numeric, isFormula: false)
        case "str":
            // Formula-only cell type; never trust cached results.
            error = formulaError()
            parser.abortParsing()
            return
        default:
            resolved = XLSXWorksheetReader.Cell(
                column: cell.column, value: cell.value, isFormula: false)
        }
        row.cells[cell.column] = resolved
        currentRow = row
    }

    private func formulaError() -> Error {
        return MapSourceImportError.formulaNotSupported(
            row: currentRow?.number ?? 0,
            column: currentCell?.column ?? ""
        )
    }

    static func columnLetters(from reference: String) -> String {
        var letters = ""
        for scalar in reference.unicodeScalars {
            if scalar.value >= 0x41 && scalar.value <= 0x5A {
                letters.append(Character(scalar))
            } else if scalar.value >= 0x61 && scalar.value <= 0x7A {
                letters.append(Character(UnicodeScalar(scalar.value - 32)!))
            } else {
                break
            }
        }
        return letters
    }
}
