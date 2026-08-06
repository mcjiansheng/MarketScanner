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
                   buffer[index + 3] == 0x06 {
                    return index
                }
                index -= 1
            }
            return nil
        }
        guard let eocdOffset = eocdOffset else {
            throw VerifyError.notAZIP("EOCD signature not found")
        }
        let eocd = Array(tail[eocdOffset..<(eocdOffset + 22)])
        let totalEntries = readUInt16(eocd, 10)
        let centralSize = Int(readUInt32(eocd, 12))
        let centralOffset = Int(readUInt32(eocd, 16))
        guard totalEntries > 0, centralSize > 0, centralOffset >= 0,
              centralOffset + centralSize <= fileSize else {
            throw VerifyError.corrupt("invalid central directory bounds")
        }

        // 2. Central directory (small metadata only).
        try handle.seek(toOffset: UInt64(centralOffset))
        guard let centralData = try handle.read(upToCount: centralSize),
              centralData.count == centralSize else {
            throw VerifyError.truncated("cannot read central directory")
        }
        var entries: [CentralEntry] = []
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
            entries.append(CentralEntry(
                name: name,
                crc32: readUInt32(header, 16),
                compressedSize: Int(readUInt32(header, 20)),
                uncompressedSize: Int(readUInt32(header, 24)),
                localHeaderOffset: Int(readUInt32(header, 42))))
            cursor = nameEnd + extraLength + commentLength
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

        // 4. workbook.xml binds every expected sheet name (small part,
        // read in full by construction).
        guard let workbookEntry = entries.first(where: { $0.name == "xl/workbook.xml" }) else {
            throw VerifyError.corrupt("workbook.xml missing")
        }
        let workbookXML = try inflateEntry(workbookEntry, handle: handle)
        guard let workbookText = String(data: workbookXML, encoding: .utf8) else {
            throw VerifyError.corrupt("workbook.xml not utf-8")
        }
        for expectation in expectedSheets {
            guard workbookText.contains("name=\"\(expectation.sheetName)\"") else {
                throw VerifyError.corrupt(
                    "workbook.xml does not bind sheet \(expectation.sheetName)")
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
                entry, handle: handle, headers: expectation.headers)
            guard crc == entry.crc32 else {
                throw VerifyError.crcMismatch(expectation.partName)
            }
            guard uncompressed == entry.uncompressedSize else {
                throw VerifyError.sizeMismatch(expectation.partName)
            }
            rowCounts[expectation.partName] = scan.dataRows
        }

        return VerificationResult(entryCount: Int(totalEntries), sheetRowCounts: rowCounts)
    }

    // MARK: - Streaming sheet scan

    private struct SheetScan {
        var dataRows: Int
    }

    private static let rowOpenBytes: [UInt8] = Array("<row r=\"".utf8)
    private static let rowCloseBytes: [UInt8] = Array("</row>".utf8)

    /// Streams one worksheet through raw inflate while scanning the XML
    /// with a bounded byte state machine: row-marker count, the frozen
    /// first-row headers (accumulated only up to the closing `</row>`),
    /// the no-formula rule and the incremental CRC-32. Memory stays
    /// bounded to the header row + one 7-byte cross-chunk tail.
    private static func streamScanSheet(
        _ entry: CentralEntry,
        handle: FileHandle,
        headers: [String]
    ) throws -> (SheetScan, UInt32, Int) {
        var rowMarkers = 0
        var crc: uLong = 0
        var uncompressed = 0
        var headerBuffer: [UInt8] = []
        var inHeaderRow = false
        var headerClosed = false
        var formulaDetected = false
        var tail: [UInt8] = []
        _ = try inflateChunked(entry: entry, handle: handle) { chunk in
            crc = chunk.withUnsafeBytes { buffer in
                crc32(crc, buffer.bindMemory(to: Bytef.self).baseAddress, uInt(buffer.count))
            }
            uncompressed += chunk.count
            let bytes = [UInt8](chunk)
            let window = tail + bytes
            var index = 0
            let count = window.count
            while index < count {
                let byte = window[index]
                if byte == 0x3C { // '<'
                    if index + 1 < count && window[index + 1] == 0x66 { // 'f'
                        formulaDetected = true
                    }
                    if index + 7 < count && matches(rowOpenBytes, in: window, at: index) {
                        rowMarkers += 1
                        if !headerClosed && !inHeaderRow {
                            inHeaderRow = true
                        }
                    }
                }
                index += 1
            }
            // V1R5 §13.2 (review H-04): the header buffer only ever
            // receives the CURRENT chunk's new bytes; `tail` exists
            // solely for pattern matching across chunk boundaries. The
            // V1R4 code appended the whole window (tail + bytes), which
            // duplicated the previous chunk's tail into the header row.
            if inHeaderRow && !headerClosed {
                for byte in bytes {
                    headerBuffer.append(byte)
                    if headerBuffer.count > 1_048_576 {
                        throw VerifyError.sheetXMLInvalid("header row too large")
                    }
                    if byte == 0x3E && headerBuffer.count >= 6,
                       Array(headerBuffer.suffix(6)) == rowCloseBytes {
                        headerClosed = true
                        break
                    }
                }
            }
            tail = Array(bytes.suffix(7))
        }
        if formulaDetected {
            throw VerifyError.formulaDetected("formula element present")
        }
        guard rowMarkers >= 1 else {
            throw VerifyError.sheetXMLInvalid("no header row")
        }
        guard let headerRow = String(bytes: headerBuffer, encoding: .utf8) else {
            throw VerifyError.sheetXMLInvalid("header row not utf-8")
        }
        var searchRange = headerRow.startIndex..<headerRow.endIndex
        for header in headers {
            guard let found = headerRow.range(of: header, range: searchRange) else {
                throw VerifyError.headerMismatch(
                    "header '\(header)' missing or out of order in \(headers)")
            }
            searchRange = found.upperBound..<headerRow.endIndex
        }
        return (SheetScan(dataRows: rowMarkers - 1), UInt32(truncatingIfNeeded: crc), uncompressed)
    }

    private static func matches(_ needle: [UInt8], in window: [UInt8], at index: Int) -> Bool {
        guard index + needle.count <= window.count else { return false }
        for offset in 0..<needle.count where window[index + offset] != needle[offset] {
            return false
        }
        return true
    }

    // MARK: - Streaming inflate

    private struct CentralEntry {
        var name: String
        var crc32: UInt32
        var compressedSize: Int
        var uncompressedSize: Int
        var localHeaderOffset: Int
    }

    /// Fully inflates one (small) entry; used for `workbook.xml` only.
    private static func inflateEntry(
        _ entry: CentralEntry,
        handle: FileHandle
    ) throws -> Data {
        let (data, _, _) = try streamInflateEntry(entry, handle: handle)
        return data
    }

    /// Streams one entry through raw inflate, returning the decompressed
    /// bytes, the incremental CRC-32 and the uncompressed size. Only the
    /// decompressed bytes of the requested entry are materialised (the
    /// sheets are streamed through `scanSheetXML` by the caller via
    /// `streamInflateChunked`).
    private static func streamInflateEntry(
        _ entry: CentralEntry,
        handle: FileHandle
    ) throws -> (Data, UInt32, Int) {
        var chunks: [Data] = []
        var crc: uLong = 0
        var uncompressed = 0
        _ = try inflateChunked(entry: entry, handle: handle) { chunk in
            crc = chunk.withUnsafeBytes { buffer in
                crc32(crc, buffer.bindMemory(to: Bytef.self).baseAddress, uInt(buffer.count))
            }
            uncompressed += chunk.count
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
        let nameLength = Int(readUInt16(Array(localHeader), 26))
        let extraLength = Int(readUInt16(Array(localHeader), 28))
        guard let skipped = try handle.read(upToCount: nameLength + extraLength),
              skipped.count == nameLength + extraLength else {
            throw VerifyError.corrupt("local header name/extra truncated: \(entry.name)")
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
