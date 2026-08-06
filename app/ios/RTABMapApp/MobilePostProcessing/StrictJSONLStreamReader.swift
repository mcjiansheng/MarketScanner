import Foundation

/// Shared strict JSONL framing reader (V1R5 §6.3).
///
/// Freezes the JSONL contract for every formal evidence sidecar:
/// - 64 KiB bounded chunks (never the whole file in memory);
/// - one bounded pending line (maximumLineBytes fail-closed);
/// - incremental line count;
/// - strict final newline (the file MUST end with `\n`);
/// - no blank / interior-empty lines;
/// - no partial UTF-8 sequences at chunk boundaries.
///
/// The reader yields lines one at a time; the caller parses each line as
/// a strict JSON object. A malformed framing throws
/// `StrictJSONLStreamError` immediately (no "skip the bad line and keep
/// going" path — that is how evidence parsers must behave).
enum StrictJSONLStreamReader {

    static let chunkBytes = 64 * 1024

    enum StreamError: Error, LocalizedError {
        case unreadable(String)
        case lineTooLong(Int)
        case noFinalNewline
        case blankLine(Int)
        case invalidUTF8(Int)
        case tooManyLines(Int)
        case invalidJSON(Int, String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let detail):
                return "证据文件不可读：\(detail)"
            case .lineTooLong(let bytes):
                return "单行超限：\(bytes) bytes"
            case .noFinalNewline:
                return "证据文件缺少结尾换行"
            case .blankLine(let line):
                return "证据文件第 \(line) 行为空行"
            case .invalidUTF8(let line):
                return "证据文件第 \(line) 行不是合法 UTF-8"
            case .tooManyLines(let count):
                return "证据文件行数超限：\(count)"
            case .invalidJSON(let line, let detail):
                return "证据文件第 \(line) 行 JSON 无效：\(detail)"
            }
        }
    }

    struct ParsedLines {
        var lines: [String]
        var lineCount: Int
    }

    /// Streams one JSONL file with the frozen framing contract and
    /// returns every non-empty line. `maximumLineBytes` and
    /// `maximumLineCount` are fail-closed gates.
    static func readLines(
        from url: URL,
        maximumLineBytes: Int,
        maximumLineCount: Int
    ) throws -> ParsedLines {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw StreamError.unreadable(url.lastPathComponent)
        }
        defer { try? handle.close() }
        return try readLines(
            from: handle,
            maximumLineBytes: maximumLineBytes,
            maximumLineCount: maximumLineCount)
    }

    /// Streams one JSONL source with the frozen framing contract. Used by
    /// host tests with an in-memory handle and by the pipeline with a
    /// file handle — the framing policy is identical either way.
    static func readLines(
        from handle: FileHandle,
        maximumLineBytes: Int,
        maximumLineCount: Int
    ) throws -> ParsedLines {
        var pending = Data()
        var lines: [String] = []
        var lineNumber = 0
        var sawNewline = false
        var sawAnyByte = false
        while true {
            // V1R5 fix: the chunk MUST be the data actually read from the
            // handle — reading into a pre-allocated buffer and then
            // discarding the returned Data would feed zero bytes to the
            // framing scanner.
            guard let chunk = try handle.read(upToCount: chunkBytes),
                  !chunk.isEmpty else {
                break
            }
            sawAnyByte = true
            var start = 0
            for (index, byte) in chunk.enumerated() {
                if byte == 0x0A {
                    sawNewline = true
                    pending.append(chunk[start..<index])
                    start = index + 1
                    lineNumber += 1
                    if lineNumber > maximumLineCount {
                        throw StreamError.tooManyLines(lineNumber)
                    }
                    guard pending.count <= maximumLineBytes else {
                        throw StreamError.lineTooLong(pending.count)
                    }
                    guard !pending.isEmpty else {
                        throw StreamError.blankLine(lineNumber)
                    }
                    guard let line = String(data: pending, encoding: .utf8) else {
                        throw StreamError.invalidUTF8(lineNumber)
                    }
                    lines.append(line)
                    pending.removeAll(keepingCapacity: true)
                }
            }
            // Any bytes after the last newline stay pending (bounded).
            pending.append(chunk[start...])
            guard pending.count <= maximumLineBytes else {
                throw StreamError.lineTooLong(pending.count)
            }
        }
        // An EMPTY file is a legal empty input (0 lines); any non-empty
        // file MUST end with `\n` (final newline policy).
        guard sawNewline || !sawAnyByte else {
            throw StreamError.noFinalNewline
        }
        // A trailing fragment after the final newline is impossible when
        // the file ends with `\n`; a non-empty pending buffer means the
        // final line had no terminator (covered by `sawNewline` policy
        // only when the file has at least one newline; a file whose last
        // line is unterminated still ends without a trailing `\n`, which
        // we detect by scanning for a trailing newline below).
        if !pending.isEmpty {
            // The last chunk contained data after the last `\n`: the file
            // ends with an unterminated line -> no final newline.
            throw StreamError.noFinalNewline
        }
        return ParsedLines(lines: lines, lineCount: lineNumber)
    }

    /// Parses one strict JSON object from a line. Rejects duplicate keys
    /// and unknown-field callers check their own whitelist.
    static func strictObject(
        from line: String,
        lineNumber: Int
    ) throws -> [String: Any] {
        guard let data = line.data(using: .utf8) else {
            throw StreamError.invalidUTF8(lineNumber)
        }
        do {
            try StrictJSONKeyUniquenessValidator.validate(data)
            guard let object = try StrictJSONDocumentParser.object(
                from: data,
                limits: StrictJSONDocumentLimits(maximumBytes: data.count + 1))
                    as? [String: Any] else {
                throw StreamError.invalidJSON(lineNumber, "cannot parse object")
            }
            return object
        } catch let error as StrictJSONValidationError {
            // duplicateKey / nested overflow are schema errors of the line.
            throw StreamError.invalidJSON(lineNumber, "\(error)")
        } catch {
            throw StreamError.invalidJSON(lineNumber, "\(error)")
        }
    }
}
