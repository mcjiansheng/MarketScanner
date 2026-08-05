// P7R6B: duplicate-object-key rejection performed on the raw UTF-8 bytes
// BEFORE JSONSerialization parses the line.
//
// JSONSerialization (and Python json.loads without an object_pairs_hook)
// silently applies last-key-wins: {"episode_id":999,"episode_id":1}
// decodes as episode_id == 1, and the original ambiguity is gone by the
// time schema validation runs. The coordinator could then canonical-encode
// the surviving value and acknowledge a record whose raw bytes carried two
// conflicting keys, which a fail-closed evidence contract must reject.
//
// This scanner is deliberately byte-level and iterative:
//   - strings are skipped correctly (escapes, \uXXXX, surrogate pairs),
//   - object/array structure is tracked with an explicit stack,
//   - only object keys are collected, per object,
//   - escaped keys are decoded to Swift String before comparison so
//     {"episode_id":1,"\u0065pisode_id":2} is a duplicate,
//   - depth and token counts are bounded, and no recursion is used, so a
//     hostile deeply-nested document cannot overflow the stack.
//
// The scanner only needs to stay structurally correct for documents that
// JSONSerialization will accept; every other syntax error is reported by
// the full parser afterwards.

import Foundation

enum StrictJSONKeyError: Error, Equatable {
    case duplicateKey(line: Int, key: String)
    case nestingTooDeep
    case tokenLimitExceeded
}

enum StrictJSONKeyUniquenessValidator {
    /// Bounded scan over one complete JSON document (one JSONL line).
    /// The caller supplies the 1-based line number for stable errors.
    static func validate(_ data: Data, line: Int = 1) throws {
        let bytes = Array(data)
        var stack: [Frame] = [.value]
        var depth = 0
        var tokens = 0
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if isWhitespace(byte) {
                index += 1
                continue
            }
            tokens += 1
            guard tokens <= maximumTokenCount else {
                throw StrictJSONKeyError.tokenLimitExceeded
            }
            switch stack.last! {
            case .value:
                switch byte {
                case 0x7B: // {
                    guard depth < maximumNestingDepth else {
                        throw StrictJSONKeyError.nestingTooDeep
                    }
                    depth += 1
                    stack[stack.count - 1] = .object(
                        keys: [], phase: .awaitingKeyOrClose)
                    index += 1
                case 0x5B: // [
                    guard depth < maximumNestingDepth else {
                        throw StrictJSONKeyError.nestingTooDeep
                    }
                    depth += 1
                    stack[stack.count - 1] = .array(phase: .awaitingValueOrClose)
                    index += 1
                case 0x22: // "
                    let (_, next) = scanString(bytes, from: index)
                    index = next
                    stack.removeLast()
                    try consumeDelimiter(bytes, &index, &stack, &depth)
                case 0x74, 0x66, 0x6E: // true / false / null
                    index = skipLiteral(bytes, from: index)
                    stack.removeLast()
                    try consumeDelimiter(bytes, &index, &stack, &depth)
                case 0x2D, 0x30...0x39: // number
                    index = scanNumber(bytes, from: index)
                    stack.removeLast()
                    try consumeDelimiter(bytes, &index, &stack, &depth)
                default:
                    // Invalid JSON: let JSONSerialization report it exactly.
                    index += 1
                }
            case .object(let keys, let phase):
                switch phase {
                case .awaitingKeyOrClose:
                    if byte == 0x7D { // }
                        stack.removeLast()
                        depth -= 1
                        index += 1
                        try consumeDelimiter(bytes, &index, &stack, &depth)
                    }
                    else if byte == 0x22 { // key string
                        let (key, next) = scanString(bytes, from: index)
                        var merged = keys
                        guard merged.insert(key).inserted else {
                            throw StrictJSONKeyError.duplicateKey(
                                line: line, key: key)
                        }
                        stack[stack.count - 1] = .object(
                            keys: merged, phase: .awaitingColon)
                        index = next
                    }
                    else {
                        // Invalid JSON: let JSONSerialization report it.
                        index += 1
                    }
                case .awaitingColon:
                    if byte == 0x3A { // :
                        stack[stack.count - 1] = .object(
                            keys: keys, phase: .awaitingValue)
                        index += 1
                    }
                    else {
                        index += 1
                    }
                case .awaitingValue:
                    stack.append(.value)
                default:
                    // Objects never await a bare array value; unreachable.
                    index += 1
                }
            case .array(let phase):
                switch phase {
                case .awaitingValueOrClose:
                    if byte == 0x5D { // ]
                        stack.removeLast()
                        depth -= 1
                        index += 1
                        try consumeDelimiter(bytes, &index, &stack, &depth)
                    }
                    else {
                        stack.append(.value)
                    }
                default:
                    // Arrays only ever await a value or their closing
                    // bracket; any other phase is unreachable.
                    index += 1
                }
            }
        }
        // Strict JSON validity (unterminated strings, trailing commas,
        // trailing garbage) is enforced by JSONSerialization afterwards;
        // this scanner only guarantees duplicate-key detection.
    }

    // P7R6B B4: unified limits land in RecoveryLifecycleEvidenceLimits;
    // until then the scanner keeps its own bounded depth so the duplicate-
    // key path never depends on a not-yet-unified constant.
    private static let maximumNestingDepth = 32

    private static let maximumTokenCount = 1_000_000

    private enum Phase {
        case awaitingKeyOrClose
        case awaitingColon
        case awaitingValue
        case awaitingValueOrClose
    }

    private enum Frame {
        case value
        case object(keys: Set<String>, phase: Phase)
        case array(phase: Phase)
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        return byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    /// Consumes the delimiter that follows a completed value: a comma, a
    /// container close, or end-of-document. Closes bubble up so nested
    /// containers need no recursive calls.
    private static func consumeDelimiter(
        _ bytes: [UInt8],
        _ index: inout Int,
        _ stack: inout [Frame],
        _ depth: inout Int
    ) throws {
        while index < bytes.count {
            let byte = bytes[index]
            if isWhitespace(byte) {
                index += 1
                continue
            }
            if stack.isEmpty {
                return // top-level value complete; trailing bytes are
                // JSONSerialization's problem
            }
            switch stack.last! {
            case .object(let keys, _):
                if byte == 0x2C { // ,
                    stack[stack.count - 1] = .object(
                        keys: keys, phase: .awaitingKeyOrClose)
                    index += 1
                    return
                }
                if byte == 0x7D { // }
                    stack.removeLast()
                    depth -= 1
                    index += 1
                    continue
                }
                index += 1 // invalid; JSONSerialization rejects
                return
            case .array:
                if byte == 0x2C { // ,
                    stack[stack.count - 1] = .array(phase: .awaitingValueOrClose)
                    index += 1
                    return
                }
                if byte == 0x5D { // ]
                    stack.removeLast()
                    depth -= 1
                    index += 1
                    continue
                }
                index += 1
                return
            case .value:
                return // unreachable: value frames are transient
            }
        }
    }

    /// Decodes one JSON string starting at the opening quote. Returns the
    /// decoded Swift String and the index just past the closing quote.
    /// Malformed escapes are skipped (JSONSerialization rejects them), but
    /// every escape valid JSON defines is decoded correctly, including
    /// surrogate pairs, so escaped keys compare equal to their raw bytes.
    private static func scanString(_ bytes: [UInt8], from start: Int) -> (String, Int) {
        var index = start + 1
        var result = ""
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x22 { // closing quote
                return (result, index + 1)
            }
            if byte == 0x5C { // backslash escape
                index += 1
                guard index < bytes.count else { break }
                let escape = bytes[index]
                switch escape {
                case 0x22: result.append("\""); index += 1
                case 0x5C: result.append("\\"); index += 1
                case 0x2F: result.append("/"); index += 1
                case 0x62: result.append("\u{08}"); index += 1
                case 0x66: result.append("\u{0C}"); index += 1
                case 0x6E: result.append("\n"); index += 1
                case 0x72: result.append("\r"); index += 1
                case 0x74: result.append("\t"); index += 1
                case 0x75: // \uXXXX
                    index += 1
                    let (scalar, next) = scanUnicodeEscape(bytes, from: index)
                    result.append(Character(UnicodeScalar(scalar)!))
                    index = next
                default:
                    index += 1 // invalid escape; JSONSerialization rejects
                }
                continue
            }
            if byte < 0x80 {
                result.append(Character(UnicodeScalar(byte)))
                index += 1
            }
            else if byte >= 0xC2 && byte <= 0xDF {
                guard index + 1 < bytes.count else { break }
                let scalar = (UInt32(byte & 0x1F) << 6)
                    | UInt32(bytes[index + 1] & 0x3F)
                result.append(Character(UnicodeScalar(scalar)!))
                index += 2
            }
            else if byte >= 0xE0 && byte <= 0xEF {
                guard index + 2 < bytes.count else { break }
                let scalar = (UInt32(byte & 0x0F) << 12)
                    | (UInt32(bytes[index + 1] & 0x3F) << 6)
                    | UInt32(bytes[index + 2] & 0x3F)
                result.append(Character(UnicodeScalar(scalar)!))
                index += 3
            }
            else if byte >= 0xF0 && byte <= 0xF4 {
                guard index + 3 < bytes.count else { break }
                let scalar = (UInt32(byte & 0x07) << 18)
                    | (UInt32(bytes[index + 1] & 0x3F) << 12)
                    | (UInt32(bytes[index + 2] & 0x3F) << 6)
                    | UInt32(bytes[index + 3] & 0x3F)
                result.append(Character(UnicodeScalar(scalar)!))
                index += 4
            }
            else {
                index += 1 // invalid UTF-8; JSONSerialization rejects
            }
        }
        return (result, index)
    }

    /// Decodes one \uXXXX escape (with surrogate-pair continuation when
    /// present). Invalid sequences map to U+FFFD; JSONSerialization reports
    /// the exact syntax error for the line.
    private static func scanUnicodeEscape(
        _ bytes: [UInt8],
        from index: Int
    ) -> (UInt32, Int) {
        var value: UInt32 = 0
        var cursor = index
        for _ in 0..<4 {
            guard cursor < bytes.count,
                  let digit = hexDigit(bytes[cursor]) else {
                return (0xFFFD, cursor)
            }
            value = value * 16 + digit
            cursor += 1
        }
        if value >= 0xD800 && value <= 0xDBFF {
            if cursor + 1 < bytes.count + 1,
               bytes[cursor] == 0x5C,
               cursor + 1 < bytes.count,
               bytes[cursor + 1] == 0x75 {
                var low: UInt32 = 0
                var lowCursor = cursor + 2
                for _ in 0..<4 {
                    guard lowCursor < bytes.count,
                          let digit = hexDigit(bytes[lowCursor]) else {
                        return (0xFFFD, cursor)
                    }
                    low = low * 16 + digit
                    lowCursor += 1
                }
                if low >= 0xDC00 && low <= 0xDFFF {
                    let combined = 0x10000
                        + ((value - 0xD800) << 10)
                        + (low - 0xDC00)
                    return (combined, lowCursor)
                }
            }
            return (0xFFFD, cursor)
        }
        if value >= 0xDC00 && value <= 0xDFFF {
            return (0xFFFD, cursor)
        }
        return (value, cursor)
    }

    private static func hexDigit(_ byte: UInt8) -> UInt32? {
        switch byte {
        case 0x30...0x39: return UInt32(byte - 0x30)
        case 0x41...0x46: return UInt32(byte - 0x41) + 10
        case 0x61...0x66: return UInt32(byte - 0x61) + 10
        default: return nil
        }
    }

    /// Skips one JSON literal (`true`/`false`/`null`) entirely. Skipping a
    /// single byte would desynchronize the delimiter scan and could report
    /// a false duplicate key on a valid document.
    private static func skipLiteral(_ bytes: [UInt8], from start: Int) -> Int {
        let literal: [UInt8]
        switch bytes[start] {
        case 0x74: literal = Array("true".utf8)
        case 0x66: literal = Array("false".utf8)
        case 0x6E: literal = Array("null".utf8)
        default: return start + 1
        }
        if start + literal.count <= bytes.count,
           Array(bytes[start..<(start + literal.count)]) == literal {
            return start + literal.count
        }
        return start + 1 // invalid literal; JSONSerialization rejects it
    }

    /// Skips one JSON number token and returns the index after it.
    /// JSONSerialization validates the exact grammar afterwards.
    private static func scanNumber(_ bytes: [UInt8], from start: Int) -> Int {
        var index = start
        if index < bytes.count && bytes[index] == 0x2D {
            index += 1
        }
        while index < bytes.count,
              isNumberByte(bytes[index]) {
            index += 1
        }
        return index
    }

    private static func isNumberByte(_ byte: UInt8) -> Bool {
        return (byte >= 0x30 && byte <= 0x39)
            || byte == 0x2E || byte == 0x45 || byte == 0x65
            || byte == 0x2B || byte == 0x2D
    }
}
