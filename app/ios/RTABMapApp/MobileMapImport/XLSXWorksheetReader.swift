import Foundation

private func xlsxXMLLocalName(_ qualified: String) -> String {
    return qualified.split(separator: ":").last.map(String.init) ?? qualified
}

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
        try XLSXWorkbookReader.validateXMLDeclarations(
            data: entry.data, name: entry.name)
        let handler = WorksheetHandler(sharedStrings: sharedStrings)
        let parser = XMLParser(data: entry.data)
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = true
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

    /// Counts non-empty business rows after the header without resolving
    /// shared strings or interpreting formula/business content. Shelf Info
    /// is a legacy audit-only worksheet, so formulae and stale values there
    /// must never block the authoritative Basic Info + Element Info import.
    static func countAuditOnlyBusinessRows(
        entry: XLSXZipReader.Entry
    ) throws -> Int {
        try XLSXWorkbookReader.validateXMLDeclarations(
            data: entry.data, name: entry.name)
        let handler = AuditOnlyRowCounter()
        let parser = XMLParser(data: entry.data)
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = true
        parser.delegate = handler
        guard parser.parse() else {
            if let error = handler.error { throw error }
            if let parserError = parser.parserError {
                throw MapSourceImportError.xlsxInvalidXML(
                    name: entry.name, reason: parserError.localizedDescription)
            }
            throw MapSourceImportError.xlsxInvalidXML(
                name: entry.name, reason: "审计行计数解析失败。")
        }
        return handler.businessRowCount
    }
}

private final class AuditOnlyRowCounter: NSObject, XMLParserDelegate {
    var businessRowCount = 0
    var error: Error?

    private var rowCount = 0
    private var inRow = false
    private var inContent = false
    private var rowHasContent = false
    private var stack: [String] = []

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let localName = xlsxXMLLocalName(elementName)
        if stack.isEmpty,
           (localName != "worksheet"
            || namespaceURI != XLSXWorkbookReader.spreadsheetNamespace) {
            fail(parser, reason: "worksheet 根元素或命名空间无效。")
            return
        }
        if localName == "sheetData",
           (namespaceURI != XLSXWorkbookReader.spreadsheetNamespace
            || stack != ["worksheet"]) {
            fail(parser, reason: "sheetData 不在 worksheet 权威路径。")
            return
        }
        switch localName {
        case "row":
            guard namespaceURI == XLSXWorkbookReader.spreadsheetNamespace,
                  stack == ["worksheet", "sheetData"] else {
                fail(parser, reason: "审计 row 不在 worksheet/sheetData 权威路径。")
                return
            }
            rowCount += 1
            if rowCount > MapSourceImportLimits.maximumWorksheetRows {
                error = MapSourceImportError.xlsxRowTooMany(
                    limit: MapSourceImportLimits.maximumWorksheetRows)
                parser.abortParsing()
                return
            }
            inRow = true
            rowHasContent = false
        case "f":
            if inRow { rowHasContent = true }
            inContent = true
        case "v", "t":
            inContent = inRow
        default:
            break
        }
        stack.append(localName)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inContent,
           !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            rowHasContent = true
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        switch xlsxXMLLocalName(elementName) {
        case "f", "v", "t":
            inContent = false
        case "row":
            if rowCount > 1, rowHasContent { businessRowCount += 1 }
            inRow = false
        default:
            break
        }
        if !stack.isEmpty { stack.removeLast() }
    }

    private func fail(_ parser: XMLParser, reason: String) {
        if error == nil {
            error = MapSourceImportError.xlsxInvalidXML(
                name: "worksheet", reason: reason)
        }
        parser.abortParsing()
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
    private var currentCellUTF8Bytes = 0
    private var seenRowNumbers = Set<Int>()
    private var lastRowNumber = 0
    private var stack: [String] = []

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
        let localName = xlsxXMLLocalName(elementName)
        if stack.isEmpty,
           (localName != "worksheet"
            || namespaceURI != XLSXWorkbookReader.spreadsheetNamespace) {
            fail(parser, reason: "worksheet 根元素或命名空间无效。")
            return
        }
        if localName == "sheetData",
           (namespaceURI != XLSXWorkbookReader.spreadsheetNamespace
            || stack != ["worksheet"]) {
            fail(parser, reason: "sheetData 不在 worksheet 权威路径。")
            return
        }
        if ["row", "c", "f", "v", "is", "t"].contains(localName),
           namespaceURI != XLSXWorkbookReader.spreadsheetNamespace {
            fail(parser, reason: "工作表业务元素命名空间无效。")
            return
        }
        textBuffer = ""
        switch localName {
        case "row":
            guard stack == ["worksheet", "sheetData"],
                  currentRow == nil,
                  let rawNumber = attributeDict["r"],
                  !rawNumber.isEmpty,
                  rawNumber.first != "0",
                  rawNumber.unicodeScalars.allSatisfy({
                      $0.value >= 0x30 && $0.value <= 0x39
                  }),
                  let number = Int(rawNumber),
                  number > 0,
                  number <= MapSourceImportLimits.maximumWorksheetRows,
                  seenRowNumbers.insert(number).inserted,
                  number > lastRowNumber else {
                fail(
                    parser,
                    reason: "工作表 row.r 缺失、越界、重复或未严格递增。")
                return
            }
            lastRowNumber = number
            currentRow = XLSXWorksheetReader.Row(number: number, cells: [:])
        case "c":
            guard stack.last == "row",
                  currentCell == nil,
                  let row = currentRow,
                  let reference = attributeDict["r"],
                  let parsed = Self.parseCellReference(reference),
                  parsed.row == row.number,
                  row.cells[parsed.column] == nil else {
                fail(
                    parser,
                    reason: "单元格引用缺失、无效、重复或与 row.r 不一致。")
                return
            }
            currentCell = XLSXWorksheetReader.Cell(
                column: parsed.column,
                value: nil,
                isFormula: false
            )
            cellType = attributeDict["t"]
            currentCellUTF8Bytes = 0
        case "f":
            guard currentCell != nil, stack.last == "c" else {
                fail(parser, reason: "公式元素不在单元格中。")
                return
            }
            error = formulaError()
            parser.abortParsing()
            return
        case "v":
            guard currentCell != nil, stack.last == "c" else {
                fail(parser, reason: "单元格值不在 c 中。")
                return
            }
            inValue = true
        case "is":
            guard currentCell != nil, stack.last == "c" else {
                fail(parser, reason: "inline string 不在 c 中。")
                return
            }
        case "t":
            // Inside inline strings the <t> child carries the text.
            guard currentCell != nil, stack.contains("is") else {
                fail(parser, reason: "inline text 不在 is 中。")
                return
            }
            inInlineText = true
        default:
            break
        }
        stack.append(localName)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inValue || inInlineText {
            currentCellUTF8Bytes += string.lengthOfBytes(using: .utf8)
            if currentCellUTF8Bytes > Int(MapSourceImportLimits.maximumCellBytes) {
                fail(parser, reason: "工作表单元格超过 1 MiB 上限。")
                return
            }
            textBuffer += string
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        switch xlsxXMLLocalName(elementName) {
        case "v":
            inValue = false
            currentCell = XLSXWorksheetReader.Cell(
                column: currentCell?.column ?? "",
                value: textBuffer,
                isFormula: currentCell?.isFormula ?? false
            )
        case "t":
            inInlineText = false
            if cellType == "inlineStr", currentCell != nil {
                currentCell = XLSXWorksheetReader.Cell(
                    column: currentCell?.column ?? "",
                    value: (currentCell?.value ?? "") + textBuffer,
                    isFormula: false)
            }
        case "c":
            resolveCell(parser)
        case "row":
            guard error == nil, currentCell == nil else {
                currentRow = nil
                return
            }
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
        if !stack.isEmpty { stack.removeLast() }
    }

    private func resolveCell(_ parser: XMLParser) {
        guard let cell = currentCell else { return }
        defer { currentCell = nil; cellType = nil }
        guard var row = currentRow, !cell.column.isEmpty,
              row.cells[cell.column] == nil else {
            fail(parser, reason: "工作表包含重复或无效单元格引用。")
            return
        }
        if cell.isFormula {
            error = formulaError()
            parser.abortParsing()
            return
        }
        let resolved: XLSXWorksheetReader.Cell
        switch cellType {
        case "s":
            // Shared string index.
            guard let raw = cell.value?.trimmingCharacters(in: .whitespaces),
                  !raw.isEmpty,
                  raw.unicodeScalars.allSatisfy({
                      $0.value >= 0x30 && $0.value <= 0x39
                  }),
                  let index = Int(raw),
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
            guard let numeric = cell.value?
                    .trimmingCharacters(in: .whitespaces),
                  numeric == "0" || numeric == "1" else {
                fail(parser, reason: "布尔单元格只能是 0 或 1。")
                return
            }
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

    private func fail(_ parser: XMLParser, reason: String) {
        if error == nil {
            error = MapSourceImportError.xlsxInvalidXML(
                name: "worksheet", reason: reason)
        }
        parser.abortParsing()
    }

    static func parseCellReference(
        _ reference: String
    ) -> (column: String, row: Int)? {
        var letters = ""
        var digits = ""
        var readingDigits = false
        for scalar in reference.unicodeScalars {
            if scalar.value >= 0x41 && scalar.value <= 0x5A {
                guard !readingDigits else { return nil }
                letters.append(Character(scalar))
            } else if scalar.value >= 0x61 && scalar.value <= 0x7A {
                guard !readingDigits else { return nil }
                letters.append(Character(UnicodeScalar(scalar.value - 32)!))
            } else if scalar.value >= 0x30 && scalar.value <= 0x39 {
                readingDigits = true
                digits.append(Character(scalar))
            } else {
                return nil
            }
        }
        guard !letters.isEmpty, !digits.isEmpty,
              digits.first != "0",
              let row = Int(digits), row > 0,
              row <= MapSourceImportLimits.maximumWorksheetRows,
              validColumnNumber(letters) != nil else {
            return nil
        }
        return (letters, row)
    }

    private static func validColumnNumber(_ letters: String) -> Int? {
        var number = 0
        for scalar in letters.unicodeScalars {
            let value = Int(scalar.value)
            guard value >= 0x41, value <= 0x5A else { return nil }
            let digit = value - 0x40
            guard number <= (MapSourceImportLimits.maximumWorksheetColumns - digit) / 26 else {
                return nil
            }
            number = number * 26 + digit
        }
        return number > 0 && number <= MapSourceImportLimits.maximumWorksheetColumns
            ? number : nil
    }
}
