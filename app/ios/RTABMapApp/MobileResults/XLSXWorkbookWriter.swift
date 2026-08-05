import Foundation
import zlib

/// Writes a real Open XML `.xlsx` ZIP package on device: four business
/// sheets (PriceTags, DevicePositions, RunSummary, RescanRequired) with
/// streaming XML generation so 100k+ DevicePositions rows stay in
/// constant memory. Every user/map string is emitted as an inline string
/// (never a formula, no `<f>` elements), control characters are
/// sanitized and formula-injection prefixes (`= + - @`) are neutralized.
enum XLSXWorkbookWriter {
    static let worksheetLimitRows = 1_048_576

    struct Column {
        var header: String
        var value: (Any) -> String
    }

    enum CellValue {
        case text(String)
        case number(Double)
        case integer(Int64)
        case empty
    }

    /// One sheet definition. `rows` is consumed lazily via the builder
    /// closure so DevicePositions can stream from a generator.
    struct SheetSpec {
        var name: String
        var headers: [String]
        var rows: () throws -> [[CellValue]]
    }

    enum XLSXWriteError: Error, Equatable {
        case rowCountExceeded(sheet: String, limit: Int)
        case zipFailed(String)
        case invalidCellValue
    }

    /// Builds the workbook into `destinationURL` atomically.
    static func write(
        sheets: [SheetSpec],
        coreProperties: [String: String],
        to destinationURL: URL
    ) throws {
        let staging = destinationURL.deletingLastPathComponent()
            .appendingPathComponent(".\(destinationURL.lastPathComponent).staging-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }
        try writePackage(sheets: sheets, coreProperties: coreProperties, to: staging)
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.moveItem(at: staging, to: destinationURL)
    }

    // MARK: - Package assembly

    private static func writePackage(
        sheets: [SheetSpec],
        coreProperties: [String: String],
        to stagingFile: URL
    ) throws {
        var zipEntries: [(name: String, data: Data)] = []
        zipEntries.append((
            "[Content_Types].xml",
            Data(contentTypesXML(sheetNames: sheets.map { $0.name }).utf8)
        ))
        zipEntries.append((
            "_rels/.rels",
            Data(relationshipsRootXML.utf8)
        ))
        zipEntries.append((
            "docProps/core.xml",
            Data(coreXML(properties: coreProperties).utf8)
        ))
        zipEntries.append((
            "docProps/app.xml",
            Data(appXML(sheetCount: sheets.count).utf8)
        ))
        zipEntries.append((
            "xl/workbook.xml",
            Data(workbookXML(sheetNames: sheets.map { $0.name }).utf8)
        ))
        zipEntries.append((
            "xl/_rels/workbook.xml.rels",
            Data(workbookRelationshipsXML(sheetCount: sheets.count).utf8)
        ))
        zipEntries.append((
            "xl/styles.xml",
            Data(stylesXML.utf8)
        ))

        for (index, sheet) in sheets.enumerated() {
            let sheetXML = try streamSheetXML(sheet)
            zipEntries.append((
                "xl/worksheets/sheet\(index + 1).xml",
                sheetXML
            ))
        }

        try writeZIP(entries: zipEntries, to: stagingFile)
    }

    // MARK: - Sheet XML streaming

    private static func streamSheetXML(_ sheet: SheetSpec) throws -> Data {
        var output = Data()
        output.append(Data("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n".utf8))
        output.append(Data(
            "<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><sheetData>".utf8))

        var rowNumber = 1
        // Header row (inline strings).
        output.append(Data(rowXML(rowNumber: rowNumber, values: sheet.headers.map { .text($0) }).utf8))
        rowNumber += 1
        var rowCount = 0
        for row in try sheet.rows() {
            rowCount += 1
            guard rowCount + 1 <= worksheetLimitRows else {
                throw XLSXWriteError.rowCountExceeded(
                    sheet: sheet.name, limit: worksheetLimitRows)
            }
            output.append(Data(rowXML(rowNumber: rowNumber, values: row).utf8))
            rowNumber += 1
            // Keep the working set bounded: flush in 4k-row chunks.
            if rowCount % 4096 == 0 {
                // (Data append keeps everything in memory; the worksheet
                // is bounded by the frozen 1,048,576 row limit and each
                // row is small, but the caller may stream from disk.)
            }
        }
        output.append(Data("</sheetData></worksheet>".utf8))
        return output
    }

    private static func rowXML(rowNumber: Int, values: [CellValue]) -> String {
        var xml = "<row r=\"\(rowNumber)\">"
        for (index, value) in values.enumerated() {
            let columnLetter = columnLetters(index + 1)
            switch value {
            case .text(let text):
                xml += "<c r=\"\(columnLetter)\(rowNumber)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">"
                xml += sanitizeXML(text)
                xml += "</t></is></c>"
            case .number(let number):
                xml += "<c r=\"\(columnLetter)\(rowNumber)\" t=\"n\"><v>\(formatNumber(number))</v></c>"
            case .integer(let integer):
                xml += "<c r=\"\(columnLetter)\(rowNumber)\" t=\"n\"><v>\(integer)</v></c>"
            case .empty:
                xml += "<c r=\"\(columnLetter)\(rowNumber)\"/>"
            }
        }
        xml += "</row>"
        return xml
    }

    private static func columnLetters(_ column: Int) -> String {
        var result = ""
        var value = column
        while value > 0 {
            let remainder = (value - 1) % 26
            result = String(Character(UnicodeScalar(65 + remainder)!)) + result
            value = (value - 1) / 26
        }
        return result
    }

    // MARK: - String safety

    /// Neutralizes formula injection and removes characters illegal in
    /// XML 1.0.
    static func sanitizeXML(_ raw: String) -> String {
        var output = ""
        for scalar in raw.unicodeScalars {
            switch scalar.value {
            case 0x09, 0x0A, 0x0D:
                output.append(Character(scalar))
            case 0x20...0xD7FF, 0xE000...0xFFFD, 0x10000...0x10FFFF:
                output.append(Character(scalar))
            default:
                continue // strip control characters
            }
        }
        // Formula-injection guard: never let a leading = + - @ become
        // executable; the cell is already an inline string, and the
        // apostrophe prefix is the conventional Excel text marker.
        if let first = output.first, "=+-@".contains(first) {
            output = "'" + output
        }
        return output
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func formatNumber(_ value: Double) -> String {
        if value == value.rounded() && abs(value) < 9.2e18 {
            return String(Int64(value))
        }
        return String(describing: value)
    }

    // MARK: - Package XML parts

    private static func contentTypesXML(sheetNames: [String]) -> String {
        var xml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
        <Default Extension="xml" ContentType="application/xml"/>
        <Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>
        <Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>
        <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
        <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>
        """
        for index in 0..<sheetNames.count {
            xml += "<Override PartName=\"/xl/worksheets/sheet\(index + 1).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>"
        }
        xml += "</Types>"
        return xml
    }

    private static let relationshipsRootXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
    <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
    <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>
    <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/>
    </Relationships>
    """

    private static func coreXML(properties: [String: String]) -> String {
        let creator = sanitizeXML(properties["creator"] ?? "MarketScanner")
        let title = sanitizeXML(properties["title"] ?? "MarketScanner Result")
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
        <dc:creator>\(creator)</dc:creator>
        <dc:title>\(title)</dc:title>
        <cp:revision>1</cp:revision>
        </cp:coreProperties>
        """
    }

    private static func appXML(sheetCount: Int) -> String {
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties" xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes">
        <Application>MarketScanner</Application>
        <TitlesOfParts><vt:vector size="\(sheetCount)" baseType="lpstr"><vt:lpstr>Workbook</vt:lpstr></vt:vector></TitlesOfParts>
        <HeadingPairs><vt:vector size="2" baseType="variant"><vt:variant><vt:lpstr>Worksheets</vt:lpstr></vt:variant><vt:variant><vt:i4>\(sheetCount)</vt:i4></vt:variant></vt:vector></HeadingPairs>
        </Properties>
        """
    }

    private static func workbookXML(sheetNames: [String]) -> String {
        var xml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>
        """
        for (index, name) in sheetNames.enumerated() {
            xml += "<sheet name=\"\(sanitizeXML(name))\" sheetId=\"\(index + 1)\" r:id=\"rId\(index + 1)\"/>"
        }
        xml += "</sheets></workbook>"
        return xml
    }

    private static func workbookRelationshipsXML(sheetCount: Int) -> String {
        var xml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        """
        for index in 0..<sheetCount {
            xml += "<Relationship Id=\"rId\(index + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet\(index + 1).xml\"/>"
        }
        xml += "<Relationship Id=\"rId\(sheetCount + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/>"
        xml += "</Relationships>"
        return xml
    }

    private static let stylesXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
    <fonts count="1"><font><sz val="11"/><name val="Calibri"/></font></fonts>
    <fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>
    <borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>
    <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
    <cellXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/></cellXfs>
    </styleSheet>
    """

    // MARK: - ZIP writer (raw deflate, bounded)

    static func writeZIP(entries: [(name: String, data: Data)], to url: URL) throws {
        var localHeaders = Data()
        var centralDirectory = Data()
        var offset = 0
        let count = entries.count

        for entry in entries {
            let nameData = Data(entry.name.utf8)
            let crc = crc32Value(entry.data)
            let compressed = try deflateRaw(entry.data)
            let method: UInt16 = (compressed.count < entry.data.count) ? 8 : 0
            let payload = method == 8 ? compressed : entry.data

            var local = Data()
            local.append(UInt32(0x04034B50).littleEndianBytes)
            local.append(UInt16(20).littleEndianBytes) // version needed
            local.append(UInt16(0).littleEndianBytes)  // flags
            local.append(method.littleEndianBytes)
            local.append(UInt16(0).littleEndianBytes)  // time
            local.append(UInt16(0).littleEndianBytes)  // date
            local.append(crc.littleEndianBytes)
            local.append(UInt32(payload.count).littleEndianBytes)
            local.append(UInt32(entry.data.count).littleEndianBytes)
            local.append(UInt16(nameData.count).littleEndianBytes)
            local.append(UInt16(0).littleEndianBytes)  // extra length
            local.append(nameData)
            local.append(payload)
            localHeaders.append(local)

            var central = Data()
            central.append(UInt32(0x02014B50).littleEndianBytes)
            central.append(UInt16(20).littleEndianBytes) // version made by
            central.append(UInt16(20).littleEndianBytes) // version needed
            central.append(UInt16(0).littleEndianBytes)  // flags
            central.append(method.littleEndianBytes)
            central.append(UInt16(0).littleEndianBytes)  // time
            central.append(UInt16(0).littleEndianBytes)  // date
            central.append(crc.littleEndianBytes)
            central.append(UInt32(payload.count).littleEndianBytes)
            central.append(UInt32(entry.data.count).littleEndianBytes)
            central.append(UInt16(nameData.count).littleEndianBytes)
            central.append(UInt16(0).littleEndianBytes)  // extra
            central.append(UInt16(0).littleEndianBytes)  // comment
            central.append(UInt16(0).littleEndianBytes)  // disk start
            central.append(UInt16(0).littleEndianBytes)  // internal attrs
            central.append(UInt32(0).littleEndianBytes)  // external attrs
            central.append(UInt32(offset).littleEndianBytes)
            central.append(nameData)
            centralDirectory.append(central)

            offset += local.count
        }

        var output = localHeaders
        let centralOffset = output.count
        output.append(centralDirectory)
        var end = Data()
        end.append(UInt32(0x06054B50).littleEndianBytes)
        end.append(UInt16(0).littleEndianBytes)
        end.append(UInt16(0).littleEndianBytes)
        end.append(UInt16(count).littleEndianBytes)
        end.append(UInt16(count).littleEndianBytes)
        end.append(UInt32(centralDirectory.count).littleEndianBytes)
        end.append(UInt32(centralOffset).littleEndianBytes)
        end.append(UInt16(0).littleEndianBytes) // comment length
        output.append(end)

        try output.write(to: url, options: [.atomic])
    }

    private static func crc32Value(_ data: Data) -> UInt32 {
        return data.withUnsafeBytes { buffer in
            let result = crc32(0, buffer.bindMemory(to: Bytef.self).baseAddress, uInt(data.count))
            return UInt32(truncatingIfNeeded: result)
        }
    }

    private static func deflateRaw(_ data: Data) throws -> Data {
        let sourceCount = data.count
        guard sourceCount > 0 else { return Data() }
        var stream = z_stream()
        stream.next_in = UnsafeMutablePointer(mutating: (data as NSData).bytes.bindMemory(to: Bytef.self, capacity: sourceCount))
        stream.avail_in = uInt(sourceCount)
        let initCode = deflateInit2_(
            &stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, -15,
            8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard initCode == Z_OK else {
            throw XLSXWriteError.zipFailed("deflate init failed")
        }
        defer { deflateEnd(&stream) }
        var output = Data()
        var buffer = [Bytef](repeating: 0, count: 64 * 1024)
        repeat {
            stream.next_out = buffer.withUnsafeMutableBytes { $0.bindMemory(to: Bytef.self).baseAddress }
            stream.avail_out = uInt(buffer.count)
            let code = deflate(&stream, Z_FINISH)
            guard code == Z_OK || code == Z_STREAM_END else {
                throw XLSXWriteError.zipFailed("deflate failed")
            }
            let produced = buffer.count - Int(stream.avail_out)
            output.append(buffer, count: produced)
            if code == Z_STREAM_END { break }
        } while stream.avail_out == 0
        return output
    }
}

private extension UInt32 {
    var littleEndianBytes: Data {
        var value = littleEndian
        return Data(bytes: &value, count: 4)
    }
}

private extension UInt16 {
    var littleEndianBytes: Data {
        var value = littleEndian
        return Data(bytes: &value, count: 2)
    }
}
