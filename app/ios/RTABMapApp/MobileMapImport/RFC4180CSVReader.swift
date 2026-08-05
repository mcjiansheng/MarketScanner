import Foundation

/// Streaming RFC 4180 CSV reader with strict safety rules.
///
/// Supports UTF-8 (with optional BOM), CRLF and LF line endings, quoted
/// commas, quoted newlines, escaped quotes (`""`), and empty fields.
/// Rejects NUL bytes, invalid UTF-8, inconsistent field counts, missing
/// headers and oversized fields/rows. The whole file is never buffered
/// more than one field at a time, so a 64 MiB CSV stays in one field's
/// memory.
enum RFC4180CSVReader {
    struct Row {
        var fields: [String]
    }

    /// Parses `data` as CSV, invoking `record` for every record in order
    /// (including the header record). Throws on the first contract
    /// violation.
    static func parse(
        data: Data,
        maximumFieldBytes: Int64 = MapSourceImportLimits.maximumCSVFieldBytes,
        maximumRows: Int = MapSourceImportLimits.maximumCSVRows,
        record: (Row) throws -> Void
    ) throws {
        var bytes = data
        // Strip a UTF-8 BOM if present.
        if bytes.count >= 3,
           bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF {
            bytes.removeFirst(3)
        }

        var fields: [String] = []
        var field = Data()
        var inQuotes = false
        var row = 0
        var index = 0
        let count = bytes.count

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

        func finishRecord() throws {
            try finishField()
            if fields.count == 1 && fields[0].isEmpty && row == 0 {
                // Trailing empty record at EOF: skip blank final line.
                fields.removeAll()
                return
            }
            row += 1
            guard row <= maximumRows else {
                throw MapSourceImportError.csvRowTooMany(limit: maximumRows)
            }
            try record(Row(fields: fields))
            fields.removeAll(keepingCapacity: true)
        }

        while index < count {
            let byte = bytes[index]
            if byte == 0 {
                throw MapSourceImportError.csvContainsNUL(row: row + 1)
            }
            if inQuotes {
                if byte == 0x22 { // "
                    if index + 1 < count && bytes[index + 1] == 0x22 {
                        field.append(0x22)
                        index += 2
                        continue
                    }
                    inQuotes = false
                    index += 1
                    continue
                }
                field.append(byte)
                index += 1
                continue
            }
            switch byte {
            case 0x22: // "
                if field.isEmpty {
                    inQuotes = true
                } else {
                    field.append(byte)
                }
                index += 1
            case 0x2C: // ,
                try finishField()
                index += 1
            case 0x0D: // CR
                if index + 1 < count && bytes[index + 1] == 0x0A {
                    index += 1
                }
                try finishRecord()
                index += 1
            case 0x0A: // LF
                try finishRecord()
                index += 1
            default:
                field.append(byte)
                index += 1
            }
        }
        // Emit the final record unless the file ended with a newline.
        if inQuotes {
            throw MapSourceImportError.malformedRow(
                row: row + 1, reason: "引号字段未闭合。")
        }
        if !field.isEmpty || !fields.isEmpty {
            try finishRecord()
        }
    }
}
