import Foundation
import zlib

/// Streaming verification of a written `.xlsx` package (V1R4 §16.2).
///
/// The reopen check never materialises the package: it reads the EOCD and
/// the central directory (small metadata), then streams each worksheet
/// entry through raw inflate while validating CRC-32, the frozen first-row
/// headers, the row count and the no-formula rule. `workbook.xml` is the
/// only part read fully in memory (it is tiny by construction).
///
/// Contract checked:
/// - EOCD + central directory structure and entry count;
/// - every required part present (`[Content_Types].xml`, relationships,
///   docProps, workbook, styles, all four worksheets);
/// - each worksheet: exact CRC-32, exact uncompressed size, headers of row
///   1 match the frozen business headers in order, data row count > 0,
///   no `<f>` formula element anywhere in the sheet XML;
/// - each sheet part is referenced by `workbook.xml` under its name.
enum XLSXWorkbookVerifier {
    struct SheetExpectation {
        /// ZIP part name, e.g. `xl/worksheets/sheet1.xml`.
        var partName: String
        /// Sheet display name that must appear in `workbook.xml`.
        var sheetName: String
        /// Frozen business headers of the first row, in order.
        var headers: [String]

        var minimumDataRows: Int
        var maximumDataRows: Int?

        init(
            partName: String,
            sheetName: String,
            headers: [String],
            minimumDataRows: Int? = nil,
            maximumDataRows: Int? = nil
        ) {
            self.partName = partName
            self.sheetName = sheetName
            self.headers = headers
            switch sheetName {
            case "DevicePositions":
                self.minimumDataRows = minimumDataRows ?? 1
                self.maximumDataRows = maximumDataRows
            case "RunSummary":
                self.minimumDataRows = minimumDataRows ?? 1
                self.maximumDataRows = maximumDataRows ?? 1
            default:
                self.minimumDataRows = minimumDataRows ?? 0
                self.maximumDataRows = maximumDataRows
            }
        }
    }

    struct VerificationResult {
        var entryCount: Int
        /// partName -> data rows (excluding the header row).
        var sheetRowCounts: [String: Int]
    }

    enum VerifyError: Error, CustomStringConvertible {
        case notAZIP(String)
        case truncated(String)
        case corrupt(String)
        case crcMismatch(String)
        case sizeMismatch(String)
        case sheetXMLInvalid(String)
        case headerMismatch(String)
        case emptySheet(String)
        case formulaDetected(String)
        case entryTooLarge(String)

        var description: String {
            switch self {
            case .notAZIP(let d): return "not a zip package: \(d)"
            case .truncated(let d): return "truncated package: \(d)"
            case .corrupt(let d): return "corrupt package: \(d)"
            case .crcMismatch(let d): return "crc mismatch: \(d)"
            case .sizeMismatch(let d): return "size mismatch: \(d)"
            case .sheetXMLInvalid(let d): return "invalid sheet xml: \(d)"
            case .headerMismatch(let d): return "header mismatch: \(d)"
            case .emptySheet(let d): return "empty sheet: \(d)"
            case .formulaDetected(let d): return "formula detected: \(d)"
            case .entryTooLarge(let d): return "entry too large: \(d)"
            }
        }
    }

    /// The fixed non-sheet parts every workbook written by
    /// `XLSXWorkbookWriter` must contain.
    static let requiredParts: Set<String> = [
        "[Content_Types].xml",
        "_rels/.rels",
        "docProps/core.xml",
        "docProps/app.xml",
        "xl/workbook.xml",
        "xl/_rels/workbook.xml.rels",
        "xl/styles.xml",
    ]

    static func verify(
        workbookURL: URL,
        expectedSheets: [SheetExpectation],
        maximumEntryBytes: Int64 = 512 * 1024 * 1024
    ) throws -> VerificationResult {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: workbookURL)
        } catch {
            throw VerifyError.truncated("cannot open \(workbookURL.lastPathComponent)")
        }
        defer { try? handle.close() }

        let fileSize = try handle.seekToEnd()
        guard fileSize > 0 else {
            throw VerifyError.truncated("empty file")
        }

        // 1. EOCD: scan the tail (comment can be up to 64 KiB).
        let tailSize = min(Int(fileSize), 65_557)
        try handle.seek(toOffset: fileSize - UInt64(tailSize))
        guard let tail = try handle.read(upToCount: tailSize), tail.count == tailSize else {
            throw VerifyError.truncated("cannot read tail")
        }
        let eocdOffset = tail.withUnsafeBytes { bytes -> Int? in
            let buffer = bytes.bindMemory(to: UInt8.self)
            var index = buffer.count - 22
            while index >= 0 {
                if buffer[index] == 0x50,
                   index + 3 < buffer.count,
                   buffer[index + 1] == 0x4B,
                   buffer[index + 2] == 0x05,
                   buffer[index + 3] == 0x06,
                   index + 22 <= buffer.count {
                    let commentLength = Int(buffer[index + 20])
                        | (Int(buffer[index + 21]) << 8)
                    if index + 22 + commentLength == buffer.count {
                        return index
                    }
                }
                index -= 1
            }
            return nil
        }
        guard let eocdOffset = eocdOffset else {
            throw VerifyError.notAZIP("EOCD signature not found")
        }
        let eocd = Array(tail[eocdOffset..<(eocdOffset + 22)])
        guard readUInt16(eocd, 4) == 0,
              readUInt16(eocd, 6) == 0,
              readUInt16(eocd, 8) == readUInt16(eocd, 10),
              readUInt16(eocd, 10) != 0xFFFF else {
            throw VerifyError.corrupt("multi-disk/ZIP64 EOCD is unsupported")
        }
        let totalEntries = readUInt16(eocd, 10)
        let centralSize = Int(readUInt32(eocd, 12))
        let centralOffset = Int(readUInt32(eocd, 16))
        let absoluteEOCDOffset = Int(fileSize) - tailSize + eocdOffset
        guard totalEntries > 0, centralSize > 0, centralOffset >= 0,
              centralOffset + centralSize == absoluteEOCDOffset else {
            throw VerifyError.corrupt("invalid central directory bounds")
        }

        // 2. Central directory (small metadata only).
        try handle.seek(toOffset: UInt64(centralOffset))
        guard let centralData = try handle.read(upToCount: centralSize),
              centralData.count == centralSize else {
            throw VerifyError.truncated("cannot read central directory")
        }
        var entries: [CentralEntry] = []
        var seenNames = Set<String>()
        var cursor = 0
        for _ in 0..<totalEntries {
            guard cursor + 46 <= centralData.count else {
                throw VerifyError.corrupt("central entry header truncated")
            }
            let header = Array(centralData[cursor..<(cursor + 46)])
            guard readUInt32(header, 0) == 0x02014B50 else {
                throw VerifyError.corrupt("bad central entry signature")
            }
            let nameLength = Int(readUInt16(header, 28))
            let extraLength = Int(readUInt16(header, 30))
            let commentLength = Int(readUInt16(header, 32))
            let nameStart = cursor + 46
            let nameEnd = nameStart + nameLength
            guard nameEnd + extraLength + commentLength <= centralData.count else {
                throw VerifyError.corrupt("central entry truncated")
            }
            guard let name = String(
                data: centralData[nameStart..<nameEnd], encoding: .utf8) else {
                throw VerifyError.corrupt("central entry name not utf-8")
            }
            try validateEntryName(name)
            let canonicalName = name.precomposedStringWithCanonicalMapping
            guard seenNames.insert(canonicalName).inserted else {
                throw VerifyError.corrupt("duplicate entry name: \(name)")
            }
            let flags = readUInt16(header, 8)
            let method = readUInt16(header, 10)
            try validateFlags(flags, name: name)
            guard method == 0 || method == 8,
                  readUInt16(header, 34) == 0,
                  readUInt32(header, 20) != 0xFFFFFFFF,
                  readUInt32(header, 24) != 0xFFFFFFFF,
                  readUInt32(header, 42) != 0xFFFFFFFF else {
                throw VerifyError.corrupt("unsupported ZIP entry: \(name)")
            }
            entries.append(CentralEntry(
                name: name,
                flags: flags,
                method: method,
                crc32: readUInt32(header, 16),
                compressedSize: Int(readUInt32(header, 20)),
                uncompressedSize: Int(readUInt32(header, 24)),
                localHeaderOffset: Int(readUInt32(header, 42))))
            cursor = nameEnd + extraLength + commentLength
        }
        guard cursor == centralData.count else {
            throw VerifyError.corrupt("central directory length mismatch")
        }

        // 3. Required parts are present.
        let names = Set(entries.map { $0.name })
        for part in requiredParts where !names.contains(part) {
            throw VerifyError.corrupt("required part missing: \(part)")
        }
        let expectedPartNames = Set(expectedSheets.map { $0.partName })
        for part in expectedPartNames where !names.contains(part) {
            throw VerifyError.corrupt("required sheet part missing: \(part)")
        }
        // No unexpected worksheet parts beyond the expected sheets.
        for name in names where name.hasPrefix("xl/worksheets/") {
            guard expectedPartNames.contains(name) else {
                throw VerifyError.corrupt("unexpected worksheet part: \(name)")
            }
        }
        let allowedParts = requiredParts.union(expectedPartNames)
        guard names == allowedParts else {
            let unexpected = names.subtracting(allowedParts).sorted()
            throw VerifyError.corrupt(
                "unexpected package parts: \(unexpected.joined(separator: ","))")
        }

        // 4. Parse workbook.xml and its relationship part as exact XML
        // relations: ordered unique sheet names/ids/r:ids must resolve
        // to the exact expected worksheet parts.
        guard let workbookEntry = entries.first(where: { $0.name == "xl/workbook.xml" }) else {
            throw VerifyError.corrupt("workbook.xml missing")
        }
        let workbookXML = try inflateAndVerifyEntry(
            workbookEntry, handle: handle,
            maximumBytes: min(maximumEntryBytes, 1_048_576))
        guard workbookXML.count <= 1_048_576,
              let relationshipsEntry = entries.first(where: {
                  $0.name == "xl/_rels/workbook.xml.rels"
              }) else {
            throw VerifyError.corrupt("workbook metadata missing/too large")
        }
        let relationshipsXML = try inflateAndVerifyEntry(
            relationshipsEntry, handle: handle,
            maximumBytes: min(maximumEntryBytes, 1_048_576))
        guard relationshipsXML.count <= 1_048_576 else {
            throw VerifyError.corrupt("workbook relationships too large")
        }
        // Every required non-sheet XML part is a real ZIP payload, not
        // merely a name in the central directory. Validate local/central
        // headers, bounded decompression, CRC and exact uncompressed size.
        for part in requiredParts
            where part != "xl/workbook.xml"
                && part != "xl/_rels/workbook.xml.rels" {
            guard let entry = entries.first(where: { $0.name == part }) else {
                throw VerifyError.corrupt("required part missing: \(part)")
            }
            try verifyEntryIntegrity(
                entry, handle: handle, maximumBytes: maximumEntryBytes)
        }
        let sheetRecords = try parseWorkbookSheets(workbookXML)
        let relationshipTargets = try parseWorkbookRelationships(
            relationshipsXML)
        guard sheetRecords.count == expectedSheets.count else {
            throw VerifyError.corrupt("workbook sheet count mismatch")
        }
        var sheetNames = Set<String>()
        var relationshipIDs = Set<String>()
        for (index, expectation) in expectedSheets.enumerated() {
            let record = sheetRecords[index]
            let expectedID = "rId\(index + 1)"
            guard record.name == expectation.sheetName,
                  record.sheetID == index + 1,
                  record.relationshipID == expectedID,
                  sheetNames.insert(record.name).inserted,
                  relationshipIDs.insert(record.relationshipID).inserted,
                  relationshipTargets[expectedID] == expectation.partName else {
                throw VerifyError.corrupt(
                    "workbook sheet relation mismatch at index \(index)")
            }
        }

        // 5. Stream every worksheet: CRC, size, header row, row count,
        // no formula — a bounded byte state machine, never the whole
        // sheet in memory (V1R4 §16.2).
        var rowCounts: [String: Int] = [:]
        for expectation in expectedSheets {
            guard let entry = entries.first(where: { $0.name == expectation.partName }) else {
                throw VerifyError.corrupt("sheet part missing: \(expectation.partName)")
            }
            guard Int64(entry.uncompressedSize) <= maximumEntryBytes else {
                throw VerifyError.entryTooLarge("\(expectation.partName)")
            }
            let (scan, crc, uncompressed) = try streamScanSheet(
                entry, handle: handle, headers: expectation.headers,
                maximumBytes: maximumEntryBytes)
            guard crc == entry.crc32 else {
                throw VerifyError.crcMismatch(expectation.partName)
            }
            guard uncompressed == entry.uncompressedSize else {
                throw VerifyError.sizeMismatch(expectation.partName)
            }
            guard scan.dataRows >= expectation.minimumDataRows else {
                throw VerifyError.emptySheet(
                    "\(expectation.sheetName) requires at least "
                    + "\(expectation.minimumDataRows) data rows")
            }
            if let maximum = expectation.maximumDataRows,
               scan.dataRows > maximum {
                throw VerifyError.sheetXMLInvalid(
                    "\(expectation.sheetName) exceeds \(maximum) data rows")
            }
            rowCounts[expectation.partName] = scan.dataRows
        }

        return VerificationResult(entryCount: Int(totalEntries), sheetRowCounts: rowCounts)
    }

    // MARK: - Streaming sheet scan

    private struct SheetScan {
        var dataRows: Int
    }

    /// Streams one worksheet through raw inflate while scanning exact XML
    /// tag names. Comments/CDATA/DOCTYPE are rejected (the writer never
    /// emits them), a real `<f>` element is detected without confusing
    /// `<foo>`, and only the bounded first row is retained for exact cell
    /// reference/value verification.
    private static func streamScanSheet(
        _ entry: CentralEntry,
        handle: FileHandle,
        headers: [String],
        maximumBytes: Int64
    ) throws -> (SheetScan, UInt32, Int) {
        var crc: uLong = 0
        var uncompressed = 0
        var scanner = WorksheetTokenScanner()
        _ = try inflateChunked(entry: entry, handle: handle) { chunk in
            crc = chunk.withUnsafeBytes { buffer in
                crc32(crc, buffer.bindMemory(to: Bytef.self).baseAddress, uInt(buffer.count))
            }
            uncompressed += chunk.count
            guard Int64(uncompressed) <= maximumBytes else {
                throw VerifyError.entryTooLarge(entry.name)
            }
            guard uncompressed <= entry.uncompressedSize else {
                throw VerifyError.sizeMismatch(entry.name)
            }
            try scanner.consume(chunk)
        }
        try scanner.finish()
        guard scanner.rowCount >= 1,
              let headerRow = scanner.headerRow else {
            throw VerifyError.sheetXMLInvalid("no header row")
        }
        try verifyHeaderRow(headerRow, expectedHeaders: headers)
        return (
            SheetScan(dataRows: scanner.rowCount - 1),
            UInt32(truncatingIfNeeded: crc),
            uncompressed)
    }

    private struct WorksheetTokenScanner {
        private var inTag = false
        private var quote: UInt8?
        private var tag = [UInt8]()
        private var captureHeader = false
        private(set) var headerRow: Data?
        private var headerBytes = Data()
        private(set) var rowCount = 0

        mutating func consume(_ data: Data) throws {
            for byte in data {
                if captureHeader {
                    headerBytes.append(byte)
                    guard headerBytes.count <= 1_048_576 else {
                        throw VerifyError.sheetXMLInvalid(
                            "header row exceeds 1 MiB")
                    }
                }
                if !inTag {
                    if byte == 0x3C { // '<'
                        inTag = true
                        quote = nil
                        tag = [byte]
                    }
                    continue
                }
                if !(captureHeader && tag.isEmpty) {
                    tag.append(byte)
                }
                guard tag.count <= 64 * 1024 else {
                    throw VerifyError.sheetXMLInvalid("XML tag too large")
                }
                if let activeQuote = quote {
                    if byte == activeQuote { quote = nil }
                    continue
                }
                if byte == 0x22 || byte == 0x27 { // quote
                    quote = byte
                    continue
                }
                if byte == 0x3E { // '>'
                    try finishTag()
                    inTag = false
                    tag.removeAll(keepingCapacity: true)
                }
            }
        }

        mutating func finish() throws {
            guard !inTag, !captureHeader else {
                throw VerifyError.sheetXMLInvalid(
                    "unterminated XML tag/header row")
            }
        }

        private mutating func finishTag() throws {
            guard tag.count >= 3,
                  let text = String(bytes: tag, encoding: .utf8) else {
                throw VerifyError.sheetXMLInvalid("invalid UTF-8 XML tag")
            }
            if text.hasPrefix("<?") {
                guard text.hasSuffix("?>") else {
                    throw VerifyError.sheetXMLInvalid(
                        "invalid processing instruction")
                }
                return
            }
            if text.hasPrefix("<!") {
                throw VerifyError.sheetXMLInvalid(
                    "DOCTYPE/comment/CDATA is not allowed")
            }
            let trimmed = text.dropFirst().dropLast()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let isEnd = trimmed.hasPrefix("/")
            let nameStart = isEnd ? trimmed.index(after: trimmed.startIndex)
                : trimmed.startIndex
            let remainder = trimmed[nameStart...]
            let name = String(remainder.prefix { character in
                !character.isWhitespace && character != "/"
            })
            guard !name.isEmpty else {
                throw VerifyError.sheetXMLInvalid("empty XML tag name")
            }
            if !isEnd && name == "f" {
                throw VerifyError.formulaDetected("formula element present")
            }
            if !isEnd && name == "row" {
                rowCount += 1
                if rowCount == 1 {
                    captureHeader = true
                    headerBytes = Data(tag)
                }
            } else if isEnd && name == "row" && captureHeader {
                captureHeader = false
                headerRow = headerBytes
            }
        }
    }

    private struct WorkbookSheetRecord {
        var name: String
        var sheetID: Int
        var relationshipID: String
    }

    private static func parseWorkbookSheets(
        _ data: Data
    ) throws -> [WorkbookSheetRecord] {
        let delegate = WorkbookSheetXMLDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), delegate.failure == nil else {
            throw VerifyError.corrupt(
                "invalid workbook.xml: \(delegate.failure ?? parser.parserError?.localizedDescription ?? "parse failed")")
        }
        return delegate.records
    }

    private static func parseWorkbookRelationships(
        _ data: Data
    ) throws -> [String: String] {
        let delegate = WorkbookRelationshipsXMLDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), delegate.failure == nil else {
            throw VerifyError.corrupt(
                "invalid workbook relationships: \(delegate.failure ?? parser.parserError?.localizedDescription ?? "parse failed")")
        }
        return delegate.worksheetTargets
    }

    private static func verifyHeaderRow(
        _ rowData: Data,
        expectedHeaders: [String]
    ) throws {
        var wrapper = Data(
            "<root xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\">".utf8)
        wrapper.append(rowData)
        wrapper.append(Data("</root>".utf8))
        let delegate = HeaderRowXMLDelegate()
        let parser = XMLParser(data: wrapper)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), delegate.failure == nil else {
            throw VerifyError.headerMismatch(
                delegate.failure ?? parser.parserError?.localizedDescription
                    ?? "header XML parse failed")
        }
        guard delegate.rowReference == 1,
              delegate.cells.count == expectedHeaders.count else {
            throw VerifyError.headerMismatch(
                "header row/cell count mismatch")
        }
        for (index, expected) in expectedHeaders.enumerated() {
            let expectedReference = columnLetters(index + 1) + "1"
            let cell = delegate.cells[index]
            guard cell.reference == expectedReference,
                  cell.type == "inlineStr",
                  cell.value == expected else {
                throw VerifyError.headerMismatch(
                    "expected \(expectedReference)=\(expected), got "
                    + "\(cell.reference)=\(cell.value)")
            }
        }
    }

    private static func columnLetters(_ column: Int) -> String {
        var value = column
        var result = ""
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        while value > 0 {
            let remainder = (value - 1) % 26
            guard alphabet.indices.contains(remainder) else { return "" }
            result = String(alphabet[remainder]) + result
            value = (value - 1) / 26
        }
        return result
    }

    private final class WorkbookSheetXMLDelegate: NSObject, XMLParserDelegate {
        var records: [WorkbookSheetRecord] = []
        var failure: String?
        private var relationshipIDs = Set<String>()
        private var names = Set<String>()

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            guard elementName == "sheet" else { return }
            guard let name = attributeDict["name"], !name.isEmpty,
                  let rawSheetID = attributeDict["sheetId"],
                  let sheetID = Int(rawSheetID), sheetID > 0,
                  let relationshipID = attributeDict["r:id"],
                  !relationshipID.isEmpty,
                  names.insert(name).inserted,
                  relationshipIDs.insert(relationshipID).inserted else {
                failure = "invalid/duplicate sheet attributes"
                parser.abortParsing()
                return
            }
            records.append(WorkbookSheetRecord(
                name: name,
                sheetID: sheetID,
                relationshipID: relationshipID))
        }

        func parser(
            _ parser: XMLParser,
            foundExternalEntityDeclarationWithName name: String,
            publicID: String?,
            systemID: String?
        ) {
            failure = "external entity is forbidden"
            parser.abortParsing()
        }
    }

    private final class WorkbookRelationshipsXMLDelegate:
        NSObject, XMLParserDelegate {
        var worksheetTargets: [String: String] = [:]
        var failure: String?
        private let worksheetType =
            "http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet"
        private var allIDs = Set<String>()

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            guard elementName == "Relationship" else { return }
            guard let identifier = attributeDict["Id"],
                  let type = attributeDict["Type"],
                  let target = attributeDict["Target"],
                  allIDs.insert(identifier).inserted else {
                failure = "invalid/duplicate relationship"
                parser.abortParsing()
                return
            }
            guard type == worksheetType else { return }
            guard !target.isEmpty, !target.hasPrefix("/"),
                  !target.contains("\\"),
                  target.split(separator: "/", omittingEmptySubsequences: false)
                    .allSatisfy({ $0 != "." && $0 != ".." && !$0.isEmpty }) else {
                failure = "unsafe worksheet relationship target"
                parser.abortParsing()
                return
            }
            worksheetTargets[identifier] = "xl/\(target)"
        }

        func parser(
            _ parser: XMLParser,
            foundExternalEntityDeclarationWithName name: String,
            publicID: String?,
            systemID: String?
        ) {
            failure = "external entity is forbidden"
            parser.abortParsing()
        }
    }

    private final class HeaderRowXMLDelegate: NSObject, XMLParserDelegate {
        struct Cell {
            var reference: String
            var type: String
            var value: String
        }

        var rowReference: Int?
        var cells: [Cell] = []
        var failure: String?
        private var currentReference: String?
        private var currentType: String?
        private var currentText = ""
        private var inText = false

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            switch elementName {
            case "row":
                guard rowReference == nil,
                      let raw = attributeDict["r"],
                      let value = Int(raw) else {
                    failure = "invalid/duplicate header row"
                    parser.abortParsing()
                    return
                }
                rowReference = value
            case "c":
                guard currentReference == nil,
                      let reference = attributeDict["r"],
                      let type = attributeDict["t"] else {
                    failure = "invalid nested header cell"
                    parser.abortParsing()
                    return
                }
                currentReference = reference
                currentType = type
                currentText = ""
            case "t":
                guard currentReference != nil, !inText else {
                    failure = "text outside/duplicated in header cell"
                    parser.abortParsing()
                    return
                }
                inText = true
            case "f":
                failure = "formula in header"
                parser.abortParsing()
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inText { currentText += string }
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            if elementName == "t" {
                inText = false
            } else if elementName == "c" {
                guard let reference = currentReference,
                      let type = currentType else {
                    failure = "header cell end without start"
                    parser.abortParsing()
                    return
                }
                cells.append(Cell(
                    reference: reference, type: type, value: currentText))
                currentReference = nil
                currentType = nil
                currentText = ""
            }
        }

        func parser(
            _ parser: XMLParser,
            foundExternalEntityDeclarationWithName name: String,
            publicID: String?,
            systemID: String?
        ) {
            failure = "external entity is forbidden"
            parser.abortParsing()
        }
    }

    // MARK: - Streaming inflate

    private struct CentralEntry {
        var name: String
        var flags: UInt16
        var method: UInt16
        var crc32: UInt32
        var compressedSize: Int
        var uncompressedSize: Int
        var localHeaderOffset: Int
    }

    /// Fully inflates and verifies one bounded small entry.
    private static func inflateAndVerifyEntry(
        _ entry: CentralEntry,
        handle: FileHandle,
        maximumBytes: Int64
    ) throws -> Data {
        guard Int64(entry.uncompressedSize) <= maximumBytes else {
            throw VerifyError.entryTooLarge(entry.name)
        }
        let (data, crc, uncompressed) = try streamInflateEntry(
            entry, handle: handle, maximumBytes: maximumBytes)
        guard crc == entry.crc32 else {
            throw VerifyError.crcMismatch(entry.name)
        }
        guard uncompressed == entry.uncompressedSize else {
            throw VerifyError.sizeMismatch(entry.name)
        }
        return data
    }

    private static func verifyEntryIntegrity(
        _ entry: CentralEntry,
        handle: FileHandle,
        maximumBytes: Int64
    ) throws {
        guard Int64(entry.uncompressedSize) <= maximumBytes else {
            throw VerifyError.entryTooLarge(entry.name)
        }
        var crc: uLong = 0
        var uncompressed = 0
        _ = try inflateChunked(entry: entry, handle: handle) { chunk in
            uncompressed += chunk.count
            guard Int64(uncompressed) <= maximumBytes else {
                throw VerifyError.entryTooLarge(entry.name)
            }
            guard uncompressed <= entry.uncompressedSize else {
                throw VerifyError.sizeMismatch(entry.name)
            }
            crc = chunk.withUnsafeBytes { buffer in
                crc32(
                    crc, buffer.bindMemory(to: Bytef.self).baseAddress,
                    uInt(buffer.count))
            }
        }
        guard UInt32(truncatingIfNeeded: crc) == entry.crc32 else {
            throw VerifyError.crcMismatch(entry.name)
        }
        guard uncompressed == entry.uncompressedSize else {
            throw VerifyError.sizeMismatch(entry.name)
        }
    }

    /// Streams one entry through raw inflate, returning the decompressed
    /// bytes, the incremental CRC-32 and the uncompressed size. Only the
    /// decompressed bytes of the requested entry are materialised (the
    /// sheets are streamed through `scanSheetXML` by the caller via
    /// `streamInflateChunked`).
    private static func streamInflateEntry(
        _ entry: CentralEntry,
        handle: FileHandle,
        maximumBytes: Int64
    ) throws -> (Data, UInt32, Int) {
        var chunks: [Data] = []
        var crc: uLong = 0
        var uncompressed = 0
        _ = try inflateChunked(entry: entry, handle: handle) { chunk in
            crc = chunk.withUnsafeBytes { buffer in
                crc32(crc, buffer.bindMemory(to: Bytef.self).baseAddress, uInt(buffer.count))
            }
            uncompressed += chunk.count
            guard Int64(uncompressed) <= maximumBytes else {
                throw VerifyError.entryTooLarge(entry.name)
            }
            guard uncompressed <= entry.uncompressedSize else {
                throw VerifyError.sizeMismatch(entry.name)
            }
            chunks.append(chunk)
        }
        return (chunks.reduce(into: Data(), { $0.append($1) }), UInt32(truncatingIfNeeded: crc), uncompressed)
    }

    /// Inflates `entry` in bounded chunks, invoking `body` per chunk.
    /// Verifies the compressed payload length matches the central
    /// directory record.
    private static func inflateChunked(
        entry: CentralEntry,
        handle: FileHandle,
        body: (Data) throws -> Void
    ) throws {
        // Local header: 30-byte fixed part + name + extra.
        try handle.seek(toOffset: UInt64(entry.localHeaderOffset))
        guard let localHeader = try handle.read(upToCount: 30), localHeader.count == 30 else {
            throw VerifyError.corrupt("local header truncated: \(entry.name)")
        }
        guard readUInt32(Array(localHeader), 0) == 0x04034B50 else {
            throw VerifyError.corrupt("bad local header signature: \(entry.name)")
        }
        let localBytes = Array(localHeader)
        let localFlags = readUInt16(localBytes, 6)
        let localMethod = readUInt16(localBytes, 8)
        let localCRC = readUInt32(localBytes, 14)
        let localCompressedSize = readUInt32(localBytes, 18)
        let localUncompressedSize = readUInt32(localBytes, 22)
        let nameLength = Int(readUInt16(localBytes, 26))
        let extraLength = Int(readUInt16(localBytes, 28))
        guard localFlags == entry.flags, localMethod == entry.method else {
            throw VerifyError.corrupt(
                "local/central flags or method mismatch: \(entry.name)")
        }
        guard let skipped = try handle.read(upToCount: nameLength + extraLength),
              skipped.count == nameLength + extraLength else {
            throw VerifyError.corrupt("local header name/extra truncated: \(entry.name)")
        }
        guard let localName = String(
            data: skipped.prefix(nameLength), encoding: .utf8),
              localName == entry.name else {
            throw VerifyError.corrupt(
                "local/central name mismatch: \(entry.name)")
        }
        let usesDataDescriptor = entry.flags & 0x0008 != 0
        if usesDataDescriptor {
            guard (localCRC == 0 || localCRC == entry.crc32),
                  (localCompressedSize == 0
                    || Int(localCompressedSize) == entry.compressedSize),
                  (localUncompressedSize == 0
                    || Int(localUncompressedSize) == entry.uncompressedSize) else {
                throw VerifyError.corrupt(
                    "local/central descriptor fields mismatch: \(entry.name)")
            }
        } else {
            guard localCRC == entry.crc32,
                  Int(localCompressedSize) == entry.compressedSize,
                  Int(localUncompressedSize) == entry.uncompressedSize else {
                throw VerifyError.corrupt(
                    "local/central size or CRC mismatch: \(entry.name)")
            }
        }

        if entry.method == 0 {
            var remaining = entry.compressedSize
            while remaining > 0 {
                guard let chunk = try handle.read(
                    upToCount: min(remaining, 256 * 1024)),
                      !chunk.isEmpty else {
                    throw VerifyError.truncated(
                        "stored payload truncated: \(entry.name)")
                }
                remaining -= chunk.count
                try body(chunk)
            }
            if usesDataDescriptor {
                try validateDataDescriptor(entry, handle: handle)
            }
            return
        }

        var stream = z_stream()
        let initCode = inflateInit2_(
            &stream, -15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard initCode == Z_OK else {
            throw VerifyError.corrupt("inflate init failed: \(entry.name)")
        }
        defer { inflateEnd(&stream) }

        var inputBuffer = [UInt8](repeating: 0, count: 256 * 1024)
        var outputBuffer = [Bytef](repeating: 0, count: 256 * 1024)
        var remaining = entry.compressedSize
        var finished = false
        var outOfBounds = false

        while remaining > 0 {
            let toRead = min(remaining, inputBuffer.count)
            guard let chunk = try handle.read(upToCount: toRead) else {
                throw VerifyError.truncated("payload truncated: \(entry.name)")
            }
            guard chunk.count > 0 else {
                throw VerifyError.truncated("payload truncated: \(entry.name)")
            }
            remaining -= chunk.count
            stream.next_in = chunk.withUnsafeBytes { rawBuffer in
                UnsafeMutablePointer(mutating: rawBuffer.bindMemory(to: Bytef.self).baseAddress)
            }
            stream.avail_in = uInt(chunk.count)
            repeat {
                stream.next_out = outputBuffer.withUnsafeMutableBytes {
                    $0.bindMemory(to: Bytef.self).baseAddress
                }
                stream.avail_out = uInt(outputBuffer.count)
                let code = inflate(&stream, Z_NO_FLUSH)
                guard code == Z_OK || code == Z_STREAM_END else {
                    throw VerifyError.corrupt("inflate failed: \(entry.name)")
                }
                let produced = outputBuffer.count - Int(stream.avail_out)
                if produced > 0 {
                    try body(Data(outputBuffer[0..<produced]))
                }
                if code == Z_STREAM_END {
                    finished = true
                    if stream.avail_in > 0 {
                        outOfBounds = true
                    }
                    break
                }
            } while stream.avail_in > 0
            if finished { break }
        }
        if !finished {
            // Drain any remaining output with Z_FINISH semantics.
            repeat {
                stream.next_out = outputBuffer.withUnsafeMutableBytes {
                    $0.bindMemory(to: Bytef.self).baseAddress
                }
                stream.avail_out = uInt(outputBuffer.count)
                let code = inflate(&stream, Z_FINISH)
                guard code == Z_OK || code == Z_STREAM_END else {
                    throw VerifyError.corrupt("inflate finish failed: \(entry.name)")
                }
                let produced = outputBuffer.count - Int(stream.avail_out)
                if produced > 0 {
                    try body(Data(outputBuffer[0..<produced]))
                }
                if code == Z_STREAM_END {
                    finished = true
                    break
                }
            } while stream.avail_out == 0
        }
        guard finished else {
            throw VerifyError.corrupt("stream did not terminate: \(entry.name)")
        }
        guard !outOfBounds else {
            throw VerifyError.corrupt("payload exceeds central record: \(entry.name)")
        }
        guard remaining == 0 else {
            throw VerifyError.corrupt("payload shorter than central record: \(entry.name)")
        }
        if usesDataDescriptor {
            try validateDataDescriptor(entry, handle: handle)
        }
    }

    private static func validateDataDescriptor(
        _ entry: CentralEntry,
        handle: FileHandle
    ) throws {
        guard let descriptor = try handle.read(upToCount: 16),
              descriptor.count == 16 else {
            throw VerifyError.truncated(
                "data descriptor truncated: \(entry.name)")
        }
        let bytes = Array(descriptor)
        guard readUInt32(bytes, 0) == 0x08074B50,
              readUInt32(bytes, 4) == entry.crc32,
              Int(readUInt32(bytes, 8)) == entry.compressedSize,
              Int(readUInt32(bytes, 12)) == entry.uncompressedSize else {
            throw VerifyError.corrupt(
                "data descriptor mismatch: \(entry.name)")
        }
    }

    private static func validateFlags(
        _ flags: UInt16,
        name: String
    ) throws {
        // The verifier explicitly supports bit 3 data descriptors and
        // bit 11 UTF-8 names. Encryption/strong encryption and every
        // other unsupported semantic flag are rejected.
        let supported: UInt16 = 0x0008 | 0x0800
        guard flags & 0x0001 == 0,
              flags & 0x0040 == 0,
              flags & ~supported == 0 else {
            throw VerifyError.corrupt(
                "unsupported/encrypted flags for \(name)")
        }
    }

    private static func validateEntryName(_ name: String) throws {
        guard !name.isEmpty, !name.hasPrefix("/"),
              !name.hasPrefix("\\"), !name.contains("\\"),
              !(name.count >= 2
                && name[name.index(after: name.startIndex)] == ":") else {
            throw VerifyError.corrupt("unsafe ZIP entry name: \(name)")
        }
        let components = name.split(
            separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({
            !$0.isEmpty && $0 != "." && $0 != ".."
        }) else {
            throw VerifyError.corrupt("unsafe ZIP entry path: \(name)")
        }
    }

    // MARK: - Little-endian readers

    private static func readUInt16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private static func readUInt32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        return UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }
}
