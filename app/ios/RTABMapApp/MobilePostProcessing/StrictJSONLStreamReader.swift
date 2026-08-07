import CryptoKit
import Foundation

/// Shared strict, genuinely streaming JSONL framing reader.
///
/// At most one bounded line plus one 64 KiB input chunk is resident. Raw
/// lines are delivered to the caller and immediately released; there is
/// no API that can return `[String]` for the whole sidecar.
enum StrictJSONLStreamReader {

    static let chunkBytes = 64 * 1024

    struct Limits {
        var maximumFileBytes: Int
        var maximumLineBytes: Int
        var maximumLineCount: Int

        init(
            maximumFileBytes: Int,
            maximumLineBytes: Int,
            maximumLineCount: Int
        ) {
            self.maximumFileBytes = maximumFileBytes
            self.maximumLineBytes = maximumLineBytes
            self.maximumLineCount = maximumLineCount
        }
    }

    struct Line {
        var number: Int
        var text: String
        var byteCount: Int
    }

    struct Summary: Equatable {
        var lineCount: Int
        var byteCount: Int
        var sha256: String
    }

    enum StreamError: Error, LocalizedError {
        case unreadable(String)
        case invalidLimits
        case fileTooLarge(Int)
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
            case .invalidLimits:
                return "证据流限制无效"
            case .fileTooLarge(let bytes):
                return "证据文件超限：\(bytes) bytes"
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

    @discardableResult
    static func forEachLine(
        from url: URL,
        limits: Limits,
        body: (Line) throws -> Void
    ) throws -> Summary {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw StreamError.unreadable(url.lastPathComponent)
        }
        defer { try? handle.close() }
        return try forEachLine(from: handle, limits: limits, body: body)
    }

    @discardableResult
    static func forEachLine(
        from handle: FileHandle,
        limits: Limits,
        body: (Line) throws -> Void
    ) throws -> Summary {
        guard limits.maximumFileBytes >= 0,
              limits.maximumLineBytes > 0,
              limits.maximumLineCount >= 0 else {
            throw StreamError.invalidLimits
        }

        var pending = Data()
        pending.reserveCapacity(min(limits.maximumLineBytes, chunkBytes))
        var lineNumber = 0
        var totalBytes = 0
        var lastByteWasNewline = false
        var hasher = SHA256()

        while true {
            let chunk: Data
            do {
                guard let value = try handle.read(upToCount: chunkBytes),
                      !value.isEmpty else {
                    break
                }
                chunk = value
            } catch {
                throw StreamError.unreadable("stream read failed: \(error)")
            }
            totalBytes += chunk.count
            guard totalBytes <= limits.maximumFileBytes else {
                throw StreamError.fileTooLarge(totalBytes)
            }
            hasher.update(data: chunk)
            lastByteWasNewline = chunk.last == 0x0A

            var segmentStart = chunk.startIndex
            var cursor = chunk.startIndex
            while cursor < chunk.endIndex {
                if chunk[cursor] == 0x0A {
                    pending.append(contentsOf: chunk[segmentStart..<cursor])
                    lineNumber += 1
                    guard lineNumber <= limits.maximumLineCount else {
                        throw StreamError.tooManyLines(lineNumber)
                    }
                    guard pending.count <= limits.maximumLineBytes else {
                        throw StreamError.lineTooLong(pending.count)
                    }
                    guard !pending.isEmpty else {
                        throw StreamError.blankLine(lineNumber)
                    }
                    guard let text = String(data: pending, encoding: .utf8) else {
                        throw StreamError.invalidUTF8(lineNumber)
                    }
                    // JSONSerialization and Foundation bridging create
                    // autoreleased objects for every strict JSON record.
                    // A command-line host (and some long-running queues) may
                    // otherwise retain hundreds of thousands of transient
                    // dictionaries/NSNumbers until an outer pool drains,
                    // defeating this reader's bounded-line memory contract.
                    // Drain one pool per line; values intentionally retained
                    // by `body` keep their normal strong references.
                    try autoreleasepool {
                        try body(Line(
                            number: lineNumber,
                            text: text,
                            byteCount: pending.count))
                    }
                    pending.removeAll(keepingCapacity: true)
                    segmentStart = chunk.index(after: cursor)
                }
                cursor = chunk.index(after: cursor)
            }
            if segmentStart < chunk.endIndex {
                pending.append(contentsOf: chunk[segmentStart..<chunk.endIndex])
                guard pending.count <= limits.maximumLineBytes else {
                    throw StreamError.lineTooLong(pending.count)
                }
            }
        }

        // Empty is a legal zero-record evidence file. Every non-empty
        // stream must end in LF and leave no partial bytes.
        if totalBytes > 0 && (!lastByteWasNewline || !pending.isEmpty) {
            throw StreamError.noFinalNewline
        }
        let digest = hasher.finalize().map {
            String(format: "%02x", $0)
        }.joined()
        return Summary(
            lineCount: lineNumber,
            byteCount: totalBytes,
            sha256: digest)
    }

    /// Parses one strict JSON object from one transient line. Duplicate
    /// keys are rejected before Foundation materialises the object.
    static func strictObject(
        from line: String,
        lineNumber: Int
    ) throws -> [String: Any] {
        guard let data = line.data(using: .utf8) else {
            throw StreamError.invalidUTF8(lineNumber)
        }
        do {
            // StrictJSONDocumentParser already performs the UTF-8,
            // duplicate-key and nesting scan before JSONSerialization.
            // Do not run the same O(line bytes) validator twice for every
            // record in a 200k evidence stream.
            guard let object = try StrictJSONDocumentParser.object(
                from: data,
                limits: StrictJSONDocumentLimits(
                    maximumBytes: data.count + 1)) as? [String: Any] else {
                throw StreamError.invalidJSON(
                    lineNumber, "cannot parse object")
            }
            return object
        } catch let error as StrictJSONValidationError {
            throw StreamError.invalidJSON(lineNumber, "\(error)")
        } catch let error as StreamError {
            throw error
        } catch {
            throw StreamError.invalidJSON(lineNumber, "\(error)")
        }
    }
}
