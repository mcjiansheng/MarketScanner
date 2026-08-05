import Foundation
import zlib

/// Writes a real Open XML `.xlsx` ZIP package on device (V1R1 §14):
/// four business sheets (PriceTags, DevicePositions, RunSummary,
/// RescanRequired). The sheet XML is generated row-by-row into a
/// temporary file and the ZIP is written with streaming deflate and data
/// descriptors — the whole sheet `Data` is never held in memory, so 100k+
/// DevicePositions rows stay in constant memory.
///
/// Contract:
/// - Every user/map string is an inline string (never a formula, no
///   `<f>` elements); no apostrophe prefix is added to barcodes (an
///   inline string cannot execute a formula, V1R1 §14.7).
/// - `.number` values must be finite; NaN/Inf block the export (§14.6).
/// - The destination is replaced atomically with a backup; a failed
///   export keeps the old workbook (§14.5).
enum XLSXWorkbookWriter {
    static let worksheetLimitRows = 1_048_576

    /// Row generator contract: rows are produced lazily one at a time so
    /// huge sheets never materialise as `[[CellValue]]` (V1R1 §14.3).
    protocol XLSXRowSequence {
        func forEachRow(_ body: ([CellValue]) throws -> Void) throws
    }

    /// Adapter over an in-memory array (small sheets / tests).
    struct XLSXRowArray: XLSXRowSequence {
        let rows: [[CellValue]]
        init(_ rows: [[CellValue]]) { self.rows = rows }
        func forEachRow(_ body: ([CellValue]) throws -> Void) throws {
            for row in rows { try body(row) }
        }
    }

    enum CellValue {
        case text(String)
        case number(Double)
        case integer(Int64)
        case empty
    }

    /// One sheet definition. `rows` is consumed lazily.
    struct SheetSpec {
        var name: String
        var headers: [String]
        var rows: XLSXRowSequence

        init(name: String, headers: [String], rows: XLSXRowSequence) {
            self.name = name
            self.headers = headers
            self.rows = rows
        }

        /// Convenience for small sheets backed by a lazily-produced
        /// array (keeps the original throwing-closure signature).
        init(name: String, headers: [String], rows: @escaping () throws -> [[CellValue]]) {
            self.init(
                name: name, headers: headers,
                rows: XLSXRowThrowingSequence(rows: rows))
        }
    }

    /// Lazy adapter over a throwing array producer.
    struct XLSXRowThrowingSequence: XLSXRowSequence {
        let rows: () throws -> [[CellValue]]
        func forEachRow(_ body: ([CellValue]) throws -> Void) throws {
            for row in try rows() { try body(row) }
        }
    }

    enum XLSXWriteError: Error, Equatable {
        case rowCountExceeded(sheet: String, limit: Int)
        case zipFailed(String)
        case invalidCellValue(String)
        case nonFiniteNumber
        case reopenValidationFailed(String)
    }

    // MARK: - Entry point

    /// Builds the workbook into `destinationURL` atomically (staging ->
    /// fsync -> reopen validation -> backup -> rename -> fsync parent ->
    /// delete backup). On failure the previous workbook is preserved.
    static func write(
        sheets: [SheetSpec],
        coreProperties: [String: String],
        to destinationURL: URL
    ) throws {
        let fileManager = FileManager.default
        let directory = destinationURL.deletingLastPathComponent()
        let staging = directory
            .appendingPathComponent(".\(destinationURL.lastPathComponent).staging-\(UUID().uuidString)")
        let backup = directory
            .appendingPathComponent(".\(destinationURL.lastPathComponent).backup-\(UUID().uuidString)")
        defer {
            try? fileManager.removeItem(at: staging)
            try? fileManager.removeItem(at: backup)
        }

        try writePackage(sheets: sheets, coreProperties: coreProperties, to: staging)
        try syncFile(staging)

        // Reopen validation with the production reader: CRC + required
        // parts + parse (V1R1 §14.8). This validates our own output, so
        // the limits are raised beyond the frozen *import* policy (a 100k
        // DevicePositions sheet exceeds the 64 MiB import entry cap).
        do {
            let entries = try XLSXZipReader.readEntries(
                data: Data(contentsOf: staging, options: .mappedIfSafe),
                maximumEntries: 64,
                maximumEntryBytes: 512 * 1024 * 1024,
                maximumTotalBytes: 2 * 1024 * 1024 * 1024,
                maximumRatio: 10_000)
            let names = Set(entries.map { $0.name })
            guard names.contains("xl/workbook.xml"),
                  names.contains("[Content_Types].xml") else {
                throw XLSXWriteError.reopenValidationFailed("required parts missing")
            }
        } catch let error as XLSXWriteError {
            throw error
        } catch {
            throw XLSXWriteError.reopenValidationFailed("\(error)")
        }

        // Atomic replacement with backup.
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.moveItem(at: destinationURL, to: backup)
        }
        do {
            try fileManager.moveItem(at: staging, to: destinationURL)
            try syncDirectory(directory)
        } catch {
            // Restore the previous workbook before rethrowing.
            if fileManager.fileExists(atPath: backup.path) {
                try? fileManager.moveItem(at: backup, to: destinationURL)
            }
            throw error
        }
        try? fileManager.removeItem(at: backup)
    }

    // MARK: - Package assembly (streaming ZIP)

    private static func writePackage(
        sheets: [SheetSpec],
        coreProperties: [String: String],
        to stagingFile: URL
    ) throws {
        let directory = stagingFile.deletingLastPathComponent()
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        // Small XML parts stay in memory.
        let smallParts: [(String, Data)] = [
            ("[Content_Types].xml", Data(contentTypesXML(sheetNames: sheets.map { $0.name }).utf8)),
            ("_rels/.rels", Data(relationshipsRootXML.utf8)),
            ("docProps/core.xml", Data(coreXML(properties: coreProperties).utf8)),
            ("docProps/app.xml", Data(appXML(sheetCount: sheets.count).utf8)),
            ("xl/workbook.xml", Data(workbookXML(sheetNames: sheets.map { $0.name }).utf8)),
            ("xl/_rels/workbook.xml.rels", Data(workbookRelationshipsXML(sheetCount: sheets.count).utf8)),
            ("xl/styles.xml", Data(stylesXML.utf8)),
        ]

        // Sheet XML is streamed into temporary files, never held fully in
        // memory (V1R1 §14.3/§14.4).
        var sources: [ZipSource] = smallParts.map { .data($0.0, $0.1) }
        var sheetFiles: [URL] = []
        // IMPORTANT: the temporary sheet files must outlive the ZIP write;
        // a `defer` inside the loop would delete each file at the end of
        // its iteration and the ZIP would read empty entries.
        for (index, sheet) in sheets.enumerated() {
            let sheetFile = directory
                .appendingPathComponent(".sheet\(index + 1).xml-\(UUID().uuidString)")
            try streamSheetXML(sheet, to: sheetFile)
            sheetFiles.append(sheetFile)
            sources.append(.file("xl/worksheets/sheet\(index + 1).xml", sheetFile))
        }
        defer {
            for sheetFile in sheetFiles {
                try? fileManager.removeItem(at: sheetFile)
            }
        }

        try writeZIPStreaming(sources: sources, to: stagingFile)
    }

    // MARK: - Sheet XML streaming

    /// Writes one worksheet XML to `fileURL` row by row; memory stays
    /// bounded to one row.
    private static func streamSheetXML(_ sheet: SheetSpec, to fileURL: URL) throws {
        let handle: FileHandle
        if !FileManager.default.createFile(atPath: fileURL.path, contents: nil) {
            throw XLSXWriteError.zipFailed("cannot create sheet file")
        }
        handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }

        func write(_ text: String) throws {
            try handle.write(contentsOf: Data(text.utf8))
        }

        try write("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n")
        try write("<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><sheetData>")

        var rowNumber = 1
        try write(rowXML(rowNumber: rowNumber, values: sheet.headers.map { .text($0) }))
        rowNumber += 1
        var rowCount = 0
        try sheet.rows.forEachRow { row in
            rowCount += 1
            guard rowCount + 1 <= worksheetLimitRows else {
                throw XLSXWriteError.rowCountExceeded(
                    sheet: sheet.name, limit: worksheetLimitRows)
            }
            // NaN/Inf numbers block the export (V1R1 §14.6).
            for value in row {
                if case .number(let number) = value, !number.isFinite {
                    throw XLSXWriteError.nonFiniteNumber
                }
            }
            try write(rowXML(rowNumber: rowNumber, values: row))
            rowNumber += 1
        }
        try write("</sheetData></worksheet>")
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

    // MARK: - String / number safety

    /// Removes characters illegal in XML 1.0. No apostrophe prefix is
    /// added: the cell is an inline string so a leading `=` can never
    /// execute as a formula (V1R1 §14.7) and barcodes keep their value.
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

    // MARK: - Streaming ZIP writer (data descriptors, bounded memory)

    enum ZipSource {
        case data(String, Data)
        case file(String, URL)
    }

    /// Writes a ZIP with streaming deflate: local header (with data
    /// descriptor) -> streamed deflated payload -> data descriptor;
    /// the central directory keeps only small metadata.
    static func writeZIPStreaming(sources: [ZipSource], to url: URL) throws {
        guard let output = OutputStream(url: url, append: false) else {
            throw XLSXWriteError.zipFailed("cannot open output stream")
        }
        output.open()
        defer { output.close() }

        var centralDirectory = Data()
        var offset = 0
        let count = sources.count

        for source in sources {
            let name: String
            switch source {
            case .data(let entryName, _): name = entryName
            case .file(let entryName, _): name = entryName
            }
            let nameData = Data(name.utf8)

            // Local header with data-descriptor flag (bit 3); sizes are
            // zero here and filled by the descriptor after the payload.
            var local = Data()
            local.append(UInt32(0x04034B50).littleEndianBytes)
            local.append(UInt16(20).littleEndianBytes) // version needed
            local.append(UInt16(0x0008).littleEndianBytes) // flags: data descriptor
            local.append(UInt16(8).littleEndianBytes)  // method: deflate
            local.append(UInt16(0).littleEndianBytes)  // time
            local.append(UInt16(0).littleEndianBytes)  // date
            local.append(UInt32(0).littleEndianBytes)  // crc (in descriptor)
            local.append(UInt32(0).littleEndianBytes)  // compressed size
            local.append(UInt32(0).littleEndianBytes)  // uncompressed size
            local.append(UInt16(nameData.count).littleEndianBytes)
            local.append(UInt16(0).littleEndianBytes)  // extra length
            local.append(nameData)
            let localHeaderLength = local.count
            try writeAll(local, to: output)

            // Stream the deflated payload and compute CRC/sizes.
            let (crc, compressedSize, uncompressedSize) = try streamDeflate(
                source: source, to: output)

            // Data descriptor (signature + crc + sizes).
            var descriptor = Data()
            descriptor.append(UInt32(0x08074B50).littleEndianBytes)
            descriptor.append(UInt32(crc).littleEndianBytes)
            descriptor.append(UInt32(compressedSize).littleEndianBytes)
            descriptor.append(UInt32(uncompressedSize).littleEndianBytes)
            let descriptorLength = descriptor.count
            try writeAll(descriptor, to: output)

            // Central directory entry (metadata only).
            var central = Data()
            central.append(UInt32(0x02014B50).littleEndianBytes)
            central.append(UInt16(20).littleEndianBytes) // version made by
            central.append(UInt16(20).littleEndianBytes) // version needed
            central.append(UInt16(0x0008).littleEndianBytes) // flags
            central.append(UInt16(8).littleEndianBytes)  // method: deflate
            central.append(UInt16(0).littleEndianBytes)  // time
            central.append(UInt16(0).littleEndianBytes)  // date
            central.append(UInt32(crc).littleEndianBytes)
            central.append(UInt32(compressedSize).littleEndianBytes)
            central.append(UInt32(uncompressedSize).littleEndianBytes)
            central.append(UInt16(nameData.count).littleEndianBytes)
            central.append(UInt16(0).littleEndianBytes)  // extra
            central.append(UInt16(0).littleEndianBytes)  // comment
            central.append(UInt16(0).littleEndianBytes)  // disk start
            central.append(UInt16(0).littleEndianBytes)  // internal attrs
            central.append(UInt32(0).littleEndianBytes)  // external attrs
            central.append(UInt32(offset).littleEndianBytes)
            central.append(nameData)
            centralDirectory.append(central)
            // The next local header starts after this entry's full
            // record: local header + deflated payload + descriptor.
            offset += localHeaderLength + Int(compressedSize) + descriptorLength
        }

        // Central directory + EOCD.
        let centralOffset = offset
        try writeAll(centralDirectory, to: output)
        var end = Data()
        end.append(UInt32(0x06054B50).littleEndianBytes)
        end.append(UInt16(0).littleEndianBytes)
        end.append(UInt16(0).littleEndianBytes)
        end.append(UInt16(count).littleEndianBytes)
        end.append(UInt16(count).littleEndianBytes)
        end.append(UInt32(centralDirectory.count).littleEndianBytes)
        end.append(UInt32(centralOffset).littleEndianBytes)
        end.append(UInt16(0).littleEndianBytes) // comment length
        try writeAll(end, to: output)
    }

    /// Compatibility entry point used by tests: same streaming writer
    /// with in-memory sources.
    static func writeZIP(entries: [(name: String, data: Data)], to url: URL) throws {
        let sources = entries.map { ZipSource.data($0.name, $0.data) }
        try writeZIPStreaming(sources: sources, to: url)
    }

    /// Streams `source` through raw deflate into `output`, returning
    /// (crc32, compressedBytes, uncompressedBytes).
    private static func streamDeflate(
        source: ZipSource,
        to output: OutputStream
    ) throws -> (UInt32, Int, Int) {
        let input: InputStream
        switch source {
        case .data(_, let data):
            input = InputStream(data: data)
        case .file(_, let url):
            guard let stream = InputStream(url: url) else {
                throw XLSXWriteError.zipFailed("cannot open source file")
            }
            input = stream
        }
        input.open()
        defer { input.close() }

        var stream = z_stream()
        let initCode = deflateInit2_(
            &stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, -15,
            8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard initCode == Z_OK else {
            throw XLSXWriteError.zipFailed("deflate init failed")
        }
        defer { deflateEnd(&stream) }

        var crc: uLong = 0
        var compressedSize = 0
        var uncompressedSize = 0
        var inputBuffer = [UInt8](repeating: 0, count: 256 * 1024)
        var outputBuffer = [Bytef](repeating: 0, count: 256 * 1024)

        while input.hasBytesAvailable {
            let read = input.read(&inputBuffer, maxLength: inputBuffer.count)
            if read < 0 {
                throw XLSXWriteError.zipFailed("source read failed")
            }
            if read == 0 { break }
            crc = inputBuffer.withUnsafeBytes { buffer in
                crc32(crc, buffer.bindMemory(to: Bytef.self).baseAddress, uInt(read))
            }
            uncompressedSize += read
            stream.next_in = inputBuffer.withUnsafeMutableBytes {
                $0.bindMemory(to: Bytef.self).baseAddress
            }
            stream.avail_in = uInt(read)
            // Drain with Z_NO_FLUSH until the input is consumed.
            repeat {
                stream.next_out = outputBuffer.withUnsafeMutableBytes {
                    $0.bindMemory(to: Bytef.self).baseAddress
                }
                stream.avail_out = uInt(outputBuffer.count)
                let code = deflate(&stream, Z_NO_FLUSH)
                guard code == Z_OK else {
                    throw XLSXWriteError.zipFailed("deflate failed")
                }
                let produced = outputBuffer.count - Int(stream.avail_out)
                if produced > 0 {
                    try writeAll(Data(outputBuffer[0..<produced]), to: output)
                    compressedSize += produced
                }
            } while stream.avail_in > 0
        }
        // Finish the stream.
        repeat {
            stream.next_out = outputBuffer.withUnsafeMutableBytes {
                $0.bindMemory(to: Bytef.self).baseAddress
            }
            stream.avail_out = uInt(outputBuffer.count)
            let code = deflate(&stream, Z_FINISH)
            guard code == Z_OK || code == Z_STREAM_END else {
                throw XLSXWriteError.zipFailed("deflate finish failed")
            }
            let produced = outputBuffer.count - Int(stream.avail_out)
            if produced > 0 {
                try writeAll(Data(outputBuffer[0..<produced]), to: output)
                compressedSize += produced
            }
            if code == Z_STREAM_END { break }
        } while stream.avail_out == 0

        return (UInt32(truncatingIfNeeded: crc), compressedSize, uncompressedSize)
    }

    private static func writeAll(_ data: Data, to output: OutputStream) throws {
        var written = 0
        while written < data.count {
            let result = data.withUnsafeBytes { buffer in
                output.write(buffer.bindMemory(to: UInt8.self).baseAddress! + written, maxLength: data.count - written)
            }
            if result < 0 {
                throw XLSXWriteError.zipFailed("output write failed")
            }
            written += result
        }
    }

    // MARK: - Durability

    static func syncFile(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        fsync(descriptor)
    }

    static func syncDirectory(_ directory: URL) throws {
        let descriptor = open(directory.path, O_RDONLY)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        fsync(descriptor)
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
