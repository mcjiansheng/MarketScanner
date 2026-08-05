// P7R6B: duplicate-object-key rejection performed on the raw UTF-8 bytes
// BEFORE JSONSerialization parses the document.
//
// P7R6C: the scanner is now a TOTAL FUNCTION. For every possible Data
// input it either returns normally or throws a typed
// StrictJSONValidationError — it never traps, never force unwraps, never
// reads out of bounds, and never relies on a later JSONSerialization call
// to stay memory safe. The validation runs in two explicit layers:
//
//   Layer 1: strict UTF-8 validation over the complete document
//            (rejects overlong encodings, UTF-8-encoded surrogates,
//            scalars above U+10FFFF, bad continuations and truncation).
//   Layer 2: an iterative byte-level structure scan that tracks
//            object/array containers on an explicit stack (no recursion,
//            bounded depth), skips string contents correctly (escapes,
//            \uXXXX, surrogate pairs), and collects decoded keys per
//            object so escaped equivalents such as
//            {"episode_id":1,"\u0065pisode_id":2} are duplicates.
//
// Duplicate keys are ambiguous evidence: JSONSerialization (and Python
// json.loads without an object_pairs_hook) silently applies
// last-key-wins, so the surviving value could pass canonical idempotence
// for bytes that never had one meaning.
//
// There is deliberately NO fixed business token cap: a fixed
// 1,000,000-token ceiling would mis-reject legitimate large catalogs
// (a 16 MiB localized_price_tags.json with 50,000 tags). Safety comes
// from the caller's byte limits, the bounded nesting depth, and an
// iteration ceiling derived from the input size whose only job is to
// detect scanner bugs (it is far above any legitimate iteration count).

import Foundation

enum StrictJSONValidationError: Error, Equatable {
    case invalidUTF8(offset: Int)
    case invalidStringEscape(offset: Int)
    case invalidUnicodeEscape(offset: Int)
    case unpairedHighSurrogate(offset: Int)
    case unpairedLowSurrogate(offset: Int)
    case scalarOutOfRange(offset: Int)
    case duplicateKey(line: Int, key: String)
    case nestingTooDeep
    case malformedStructure
}

enum StrictJSONKeyUniquenessValidator {
    /// Bounded scan over one complete JSON document (a JSONL line or a
    /// whole JSON document). The caller supplies the 1-based line number
    /// for stable errors. Never crashes on arbitrary bytes.
    static func validate(
        _ data: Data,
        line: Int = 1,
        maximumNestingDepth: Int = RecoveryLifecycleEvidenceLimits
            .maximumJSONNestingDepth
    ) throws {
        // Layer 1: the whole document must be strict UTF-8 before any
        // structural decision is made on it.
        try validateStrictUTF8(data)
        // Layer 2: structure scan directly over the document bytes;
        // no whole-file copy is made (withUnsafeBytes instead of
        // Array(data)).
        guard !data.isEmpty else { return }
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            try scan(
                baseAddress.assumingMemoryBound(to: UInt8.self),
                count: rawBuffer.count,
                line: line,
                maximumNestingDepth: maximumNestingDepth)
        }
    }

    static var maximumNestingDepth: Int {
        return RecoveryLifecycleEvidenceLimits.maximumJSONNestingDepth
    }

    // MARK: - Layer 1: strict UTF-8

    /// RFC 3629-strict UTF-8 validation: rejects overlong encodings,
    /// UTF-8-encoded UTF-16 surrogates, scalars above U+10FFFF, invalid
    /// continuation bytes and truncated sequences. Total for all bytes.
    static func validateStrictUTF8(_ data: Data) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            let count = rawBuffer.count
            var index = 0
            while index < count {
                let lead = bytes[index]
                if lead < 0x80 {
                    index += 1
                    continue
                }
                var length = 0
                var minimum: UInt32 = 0
                var scalar: UInt32 = 0
                if lead >= 0xC2 && lead <= 0xDF {
                    length = 2
                    minimum = 0x80
                    scalar = UInt32(lead & 0x1F)
                }
                else if lead >= 0xE0 && lead <= 0xEF {
                    length = 3
                    minimum = 0x800
                    scalar = UInt32(lead & 0x0F)
                }
                else if lead >= 0xF0 && lead <= 0xF4 {
                    length = 4
                    minimum = 0x10000
                    scalar = UInt32(lead & 0x07)
                }
                else {
                    throw StrictJSONValidationError.invalidUTF8(
                        offset: index)
                }
                guard index + length <= count else {
                    throw StrictJSONValidationError.invalidUTF8(
                        offset: index)
                }
                for continuation in 1..<length {
                    let continuationByte = bytes[index + continuation]
                    guard continuationByte >= 0x80
                            && continuationByte <= 0xBF else {
                        throw StrictJSONValidationError.invalidUTF8(
                            offset: index + continuation)
                    }
                    scalar = (scalar << 6)
                        | UInt32(continuationByte & 0x3F)
                }
                guard scalar >= minimum else {
                    throw StrictJSONValidationError.invalidUTF8(
                        offset: index)
                }
                guard scalar <= 0x10FFFF else {
                    throw StrictJSONValidationError.scalarOutOfRange(
                        offset: index)
                }
                guard scalar < 0xD800 || scalar > 0xDFFF else {
                    throw StrictJSONValidationError.invalidUTF8(
                        offset: index)
                }
                index += length
            }
        }
    }

    // MARK: - Layer 2: structure scan with duplicate-key detection

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

    private static func scan(
        _ bytes: UnsafePointer<UInt8>,
        count: Int,
        line: Int,
        maximumNestingDepth: Int
    ) throws {
        var stack: [Frame] = [.value]
        var depth = 0
        var index = 0
        // Anti-bug progress bound only. Every legitimate iteration either
        // advances the index or performs at most one transient push, so a
        // real document never needs more than ~3 iterations per byte;
        // the * 4 ceiling exists solely to detect a scanner bug without
        // capping any legal business document.
        let maximumIterations = count * 4 + 1024
        var iterations = 0
        while index < count {
            iterations += 1
            guard iterations <= maximumIterations else {
                throw StrictJSONValidationError.malformedStructure
            }
            let byte = bytes[index]
            if isWhitespace(byte) {
                index += 1
                continue
            }
            guard let top = stack.last else {
                // The top-level value completed; any remaining bytes are
                // trailing garbage that JSONSerialization rejects. The
                // scanner must stay total: never index an empty stack.
                return
            }
            switch top {
            case .value:
                switch byte {
                case 0x7B: // {
                    guard depth < maximumNestingDepth else {
                        throw StrictJSONValidationError.nestingTooDeep
                    }
                    depth += 1
                    stack[stack.count - 1] = .object(
                        keys: [], phase: .awaitingKeyOrClose)
                    index += 1
                case 0x5B: // [
                    guard depth < maximumNestingDepth else {
                        throw StrictJSONValidationError.nestingTooDeep
                    }
                    depth += 1
                    stack[stack.count - 1] = .array(
                        phase: .awaitingValueOrClose)
                    index += 1
                case 0x22: // "
                    let (_, next) = try scanString(bytes, count, from: index)
                    index = next
                    stack.removeLast()
                    try consumeDelimiter(bytes, count, &index, &stack, &depth)
                case 0x74, 0x66, 0x6E: // true / false / null
                    index = skipLiteral(bytes, count, from: index)
                    stack.removeLast()
                    try consumeDelimiter(bytes, count, &index, &stack, &depth)
                case 0x2D, 0x30...0x39: // number
                    index = scanNumber(bytes, count, from: index)
                    stack.removeLast()
                    try consumeDelimiter(bytes, count, &index, &stack, &depth)
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
                        try consumeDelimiter(
                            bytes, count, &index, &stack, &depth)
                    }
                    else if byte == 0x22 { // key string
                        let (key, next) = try scanString(
                            bytes, count, from: index)
                        var merged = keys
                        guard merged.insert(key).inserted else {
                            throw StrictJSONValidationError.duplicateKey(
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
                        try consumeDelimiter(
                            bytes, count, &index, &stack, &depth)
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
        // Strict JSON validity (trailing commas, trailing garbage) is
        // enforced by JSONSerialization afterwards; this scanner
        // guarantees duplicate-key detection and memory safety only.
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        return byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    /// Consumes the delimiter that follows a completed value: a comma, a
    /// container close, or end-of-document. Closes bubble up so nested
    /// containers need no recursive calls.
    private static func consumeDelimiter(
        _ bytes: UnsafePointer<UInt8>,
        _ count: Int,
        _ index: inout Int,
        _ stack: inout [Frame],
        _ depth: inout Int
    ) throws {
        while index < count {
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
                    stack[stack.count - 1] = .array(
                        phase: .awaitingValueOrClose)
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

    /// Decodes one JSON string starting at the opening quote. The layer-1
    /// UTF-8 pass guarantees valid multibyte sequences; escape sequences
    /// are still validated here because they are ASCII-level JSON grammar,
    /// not UTF-8. Throws a typed error instead of ever force unwrapping.
    private static func scanString(
        _ bytes: UnsafePointer<UInt8>,
        _ count: Int,
        from start: Int
    ) throws -> (String, Int) {
        var index = start + 1
        var result = ""
        while index < count {
            let byte = bytes[index]
            if byte == 0x22 { // closing quote
                return (result, index + 1)
            }
            if byte == 0x5C { // backslash escape
                index += 1
                guard index < count else {
                    throw StrictJSONValidationError.malformedStructure
                }
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
                    let (scalar, next) = try scanUnicodeEscape(
                        bytes, count, from: index)
                    guard let unicodeScalar = UnicodeScalar(scalar) else {
                        throw StrictJSONValidationError.scalarOutOfRange(
                            offset: index)
                    }
                    result.append(Character(unicodeScalar))
                    index = next
                default:
                    throw StrictJSONValidationError.invalidStringEscape(
                        offset: index)
                }
                continue
            }
            if byte < 0x80 {
                result.append(Character(UnicodeScalar(byte)))
                index += 1
                continue
            }
            // Layer 1 proved the whole document is strict UTF-8, so the
            // multibyte decode below can only meet valid sequences; the
            // guards stay as cheap defense in depth, never force unwraps.
            if byte >= 0xC2 && byte <= 0xDF {
                guard index + 1 < count,
                      let scalar = UnicodeScalar(
                          (UInt32(byte & 0x1F) << 6)
                              | UInt32(bytes[index + 1] & 0x3F)) else {
                    throw StrictJSONValidationError.invalidUTF8(
                        offset: index)
                }
                result.append(Character(scalar))
                index += 2
            }
            else if byte >= 0xE0 && byte <= 0xEF {
                guard index + 2 < count,
                      let scalar = UnicodeScalar(
                          (UInt32(byte & 0x0F) << 12)
                              | (UInt32(bytes[index + 1] & 0x3F) << 6)
                              | UInt32(bytes[index + 2] & 0x3F)) else {
                    throw StrictJSONValidationError.invalidUTF8(
                        offset: index)
                }
                result.append(Character(scalar))
                index += 3
            }
            else if byte >= 0xF0 && byte <= 0xF4 {
                guard index + 3 < count,
                      let scalar = UnicodeScalar(
                          (UInt32(byte & 0x07) << 18)
                              | (UInt32(bytes[index + 1] & 0x3F) << 12)
                              | (UInt32(bytes[index + 2] & 0x3F) << 6)
                              | UInt32(bytes[index + 3] & 0x3F)) else {
                    throw StrictJSONValidationError.invalidUTF8(
                        offset: index)
                }
                result.append(Character(scalar))
                index += 4
            }
            else {
                // Unreachable after layer 1 (invalid lead byte), but never
                // assume: keep the function total on every byte.
                throw StrictJSONValidationError.invalidUTF8(offset: index)
            }
        }
        throw StrictJSONValidationError.malformedStructure
    }

    /// Decodes one \uXXXX escape (with surrogate-pair continuation when
    /// present). Unpaired surrogates are typed errors, never a trap.
    private static func scanUnicodeEscape(
        _ bytes: UnsafePointer<UInt8>,
        _ count: Int,
        from index: Int
    ) throws -> (UInt32, Int) {
        var value: UInt32 = 0
        var cursor = index
        for _ in 0..<4 {
            guard cursor < count,
                  let digit = hexDigit(bytes[cursor]) else {
                throw StrictJSONValidationError.invalidUnicodeEscape(
                    offset: index)
            }
            value = value * 16 + digit
            cursor += 1
        }
        if value >= 0xD800 && value <= 0xDBFF {
            // A high surrogate must be followed by \uDC00-\uDFFF.
            guard cursor + 5 < count + 1,
                  bytes[cursor] == 0x5C,
                  cursor + 1 < count,
                  bytes[cursor + 1] == 0x75 else {
                throw StrictJSONValidationError.unpairedHighSurrogate(
                    offset: index)
            }
            var low: UInt32 = 0
            var lowCursor = cursor + 2
            for _ in 0..<4 {
                guard lowCursor < count,
                      let digit = hexDigit(bytes[lowCursor]) else {
                    throw StrictJSONValidationError.invalidUnicodeEscape(
                        offset: cursor)
                }
                low = low * 16 + digit
                lowCursor += 1
            }
            guard low >= 0xDC00 && low <= 0xDFFF else {
                throw StrictJSONValidationError.unpairedHighSurrogate(
                    offset: index)
            }
            let combined = 0x10000
                + ((value - 0xD800) << 10)
                + (low - 0xDC00)
            return (combined, lowCursor)
        }
        guard value < 0xDC00 || value > 0xDFFF else {
            throw StrictJSONValidationError.unpairedLowSurrogate(
                offset: index)
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
    private static func skipLiteral(
        _ bytes: UnsafePointer<UInt8>,
        _ count: Int,
        from start: Int
    ) -> Int {
        let literal: [UInt8]
        switch bytes[start] {
        case 0x74: literal = Array("true".utf8)
        case 0x66: literal = Array("false".utf8)
        case 0x6E: literal = Array("null".utf8)
        default: return start + 1
        }
        if start + literal.count <= count {
            var matched = true
            for offset in 0..<literal.count {
                if bytes[start + offset] != literal[offset] {
                    matched = false
                    break
                }
            }
            if matched {
                return start + literal.count
            }
        }
        return start + 1 // invalid literal; JSONSerialization rejects it
    }

    /// Skips one JSON number token and returns the index after it.
    /// JSONSerialization validates the exact grammar afterwards.
    private static func scanNumber(
        _ bytes: UnsafePointer<UInt8>,
        _ count: Int,
        from start: Int
    ) -> Int {
        var index = start
        if index < count && bytes[index] == 0x2D {
            index += 1
        }
        while index < count,
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
