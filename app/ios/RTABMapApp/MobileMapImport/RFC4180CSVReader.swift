import Foundation

/// Streaming RFC 4180 CSV reader with strict safety rules (V1R1 §6.5).
///
/// State machine contract:
/// - A double quote may only *start* a quoted field; a quote inside an
///   unquoted field is a contract violation (blocked).
/// - After the closing quote only `,`, CR, LF or EOF may follow; any
///   other byte is a contract violation (blocked).
/// - `""` inside a quoted field decodes to one literal `"` (handled
///   correctly across chunk boundaries).
/// - Bare CR (without LF) ends a record: explicit frozen policy.
/// - Blank lines (records with only empty fields) are skipped anywhere,
///   not only at the start.
/// - Field size is enforced while accumulating; row count when a record
///   finishes.
///
/// Entry points:
/// - `parse(stream:)` reads an `InputStream` in 64 KiB chunks and never
///   materialises the whole file (no full-file extra copy).
/// - `parse(data:)` is a convenience wrapper for in-memory inputs.
enum RFC4180CSVReader {
    struct Row {
        var fields: [String]
    }

    /// Parses `stream` as CSV, invoking `record` for every record in
    /// order (including the header record).
    static func parse(
        stream: InputStream,
        maximumFieldBytes: Int64 = MapSourceImportLimits.maximumCSVFieldBytes,
        maximumRows: Int = MapSourceImportLimits.maximumCSVRows,
        record: (Row) throws -> Void
    ) throws {
        stream.open()
        defer { stream.close() }

        var fields: [String] = []
        var field = Data()
        var inQuotes = false
        /// A quote was read inside a quoted field but its meaning (escape
        /// pair vs closing quote) depends on the *next* byte.
        var quotePending = false
        var row = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)

        func finishField() throws {
            guard field.count <= maximumFieldBytes else {
                throw MapSourceImportError.csvFieldTooLarge(row: row + 1)
            }
            guard let text = String(data: field, encoding: .utf8) else {
                throw MapSourceImportError.invalidUTF8(detail: "CSV 第 \(row + 1) 行包含非法 UTF-8。")
            }
            fields.append(text)
            field.removeAll(keepingCapacity: true)
        }

        /// Emits the current record unless it is blank. `field` must be
        /// finished first (call `finishField()` before this).
        func finishRecord() throws {
            let current = fields
            fields.removeAll(keepingCapacity: true)
            if current.allSatisfy({ $0.isEmpty }) {
                return // blank line: skipped (explicit policy)
            }
            row += 1
            guard row <= maximumRows else {
                throw MapSourceImportError.csvRowTooMany(limit: maximumRows)
            }
            try record(Row(fields: current))
        }

        /// Processes one byte that is *not* inside quotes.
        func consumeUnquoted(_ byte: UInt8) throws {
            switch byte {
            case 0x22: // "
                if field.isEmpty {
                    inQuotes = true
                } else {
                    throw MapSourceImportError.malformedRow(
                        row: row + 1, reason: "双引号只能出现在字段开头。")
                }
            case 0x2C: // ,
                try finishField()
            case 0x0D: // CR — bare CR terminates a record (frozen policy)
                try finishField()
                try finishRecord()
            case 0x0A: // LF
                try finishField()
                try finishRecord()
            default:
                field.append(byte)
            }
        }

        /// Processes one byte while inside quotes, resolving any pending
        /// quote against it.
        func consumeQuoted(_ byte: UInt8) throws {
            if quotePending {
                if byte == 0x22 {
                    // Escape pair: one literal quote.
                    field.append(0x22)
                    quotePending = false
                    return
                }
                // The pending quote closed the field; process `byte` as
                // an unquoted byte after a closing quote.
                quotePending = false
                inQuotes = false
                try consumeAfterClosingQuote(byte)
                return
            }
            if byte == 0x22 {
                quotePending = true
            } else {
                field.append(byte)
            }
        }

        /// Byte after a closing quote: only `,` CR LF EOF are legal.
        /// Bytes that *start* a multi-byte UTF-8 sequence are deferred to
        /// the field so a broken multi-byte sequence surfaces as
        /// `invalid_utf8` (stable error contract) instead of a generic
        /// malformed-row rejection.
        func consumeAfterClosingQuote(_ byte: UInt8) throws {
            switch byte {
            case 0x2C:
                try finishField()
            case 0x0D:
                try finishField()
                try finishRecord()
            case 0x0A:
                try finishField()
                try finishRecord()
            default:
                if byte < 0x80 {
                    throw MapSourceImportError.malformedRow(
                        row: row + 1, reason: "关闭引号后出现非法字符。")
                }
                field.append(byte)
            }
        }

        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read < 0 {
                throw MapSourceImportError.invalidUTF8(
                    detail: "CSV 流读取失败。")
            }
            if read == 0 {
                break
            }
            for index in 0..<read {
                let byte = buffer[index]
                if byte == 0 {
                    throw MapSourceImportError.csvContainsNUL(row: row + 1)
                }
                if inQuotes {
                    try consumeQuoted(byte)
                } else {
                    try consumeUnquoted(byte)
                }
            }
        }
        // End of stream: a pending quote closes the field; afterwards only
        // EOF is legal.
        if quotePending {
            if inQuotes {
                inQuotes = false
                try finishField()
                try finishRecord()
            }
        } else if inQuotes {
            throw MapSourceImportError.malformedRow(
                row: row + 1, reason: "引号字段未闭合。")
        }
        if !field.isEmpty || !fields.isEmpty {
            try finishField()
            try finishRecord()
        }
    }

    /// Convenience wrapper for in-memory inputs (strips a UTF-8 BOM).
    static func parse(
        data: Data,
        maximumFieldBytes: Int64 = MapSourceImportLimits.maximumCSVFieldBytes,
        maximumRows: Int = MapSourceImportLimits.maximumCSVRows,
        record: (Row) throws -> Void
    ) throws {
        var bytes = data
        if bytes.count >= 3,
           bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF {
            bytes.removeFirst(3)
        }
        let stream = InputStream(data: bytes)
        try parse(
            stream: stream,
            maximumFieldBytes: maximumFieldBytes,
            maximumRows: maximumRows,
            record: record)
    }
}
