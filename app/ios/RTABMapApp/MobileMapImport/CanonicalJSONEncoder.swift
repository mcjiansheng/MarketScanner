import Foundation
import CryptoKit

/// Deterministic, compact JSON encoding used for the canonical source
/// digest and for internal result manifests.
///
/// The encoder is stable across XLSX / CSV / JSON imports for the same
/// store map: object keys are sorted lexicographically by Unicode scalar
/// value (matching the PC `sort_keys=True` contract), no insignificant
/// whitespace is emitted, and integers keep an integer representation.
/// `NaN` / infinity are rejected because the strict import pipeline
/// already rejected them.
enum CanonicalJSONEncoder {
    enum CanonicalJSONError: Error {
        case nonFiniteNumber
        case unsupportedValue(Any.Type)
    }

    static func encode(_ value: Any) throws -> Data {
        var output = Data()
        try write(value, into: &output)
        return output
    }

    static func encodeString(_ value: Any) throws -> String {
        let data = try encode(value)
        guard let text = String(data: data, encoding: .utf8) else {
            throw CanonicalJSONError.nonFiniteNumber
        }
        return text
    }

    private static func write(_ value: Any, into output: inout Data) throws {
        // Distinguish native Swift values from JSONSerialization
        // NSNumber products via the dynamic type: `as? Bool` / `as? Int`
        // bridge ANY non-zero NSNumber to Bool/Int, so native values are
        // matched first and NSNumber (with its CFBoolean trap) is handled
        // explicitly last.
        let dynamicType = type(of: value)
        if dynamicType == Bool.self {
            guard let boolean = value as? Bool else {
                throw CanonicalJSONError.unsupportedValue(dynamicType)
            }
            output.append(Data((boolean ? "true" : "false").utf8))
            return
        }
        if dynamicType == Int.self {
            guard let integer = value as? Int else {
                throw CanonicalJSONError.unsupportedValue(dynamicType)
            }
            output.append(Data(String(integer).utf8))
            return
        }
        if dynamicType == Int64.self {
            guard let integer = value as? Int64 else {
                throw CanonicalJSONError.unsupportedValue(dynamicType)
            }
            output.append(Data(String(integer).utf8))
            return
        }
        if dynamicType == UInt.self {
            guard let integer = value as? UInt else {
                throw CanonicalJSONError.unsupportedValue(dynamicType)
            }
            output.append(Data(String(integer).utf8))
            return
        }
        if dynamicType == UInt64.self {
            guard let integer = value as? UInt64 else {
                throw CanonicalJSONError.unsupportedValue(dynamicType)
            }
            output.append(Data(String(integer).utf8))
            return
        }
        if dynamicType == Double.self {
            guard let number = value as? Double else {
                throw CanonicalJSONError.unsupportedValue(dynamicType)
            }
            try writeFiniteNumber(number, into: &output)
            return
        }
        if dynamicType == Float.self {
            guard let number = value as? Float else {
                throw CanonicalJSONError.unsupportedValue(dynamicType)
            }
            try writeFiniteNumber(Double(number), into: &output)
            return
        }
        if let text = value as? String {
            // Covers Swift String and JSONSerialization NSString products
            // (e.g. NSTaggedPointerString), whose dynamic type is not
            // String.self.
            output.append(Data(escapedString(text).utf8))
            return
        }
        if value is NSNull {
            output.append(Data("null".utf8))
            return
        }
        if let number = value as? NSNumber {
            // JSONSerialization product: CFBoolean is the only way to tell
            // a JSON boolean apart from a JSON number here. Preserve the
            // parser's integer-vs-floating representation as well: Python's
            // strict JSON decoder keeps `1` as an integer and `1.0` as a
            // float, and those business scalars must produce byte-identical
            // canonical JSON on both platforms.
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                output.append(Data((number.boolValue ? "true" : "false").utf8))
            } else if foundationNumberIsFloatingPoint(number) {
                try writeFiniteNumber(number.doubleValue, into: &output)
            } else {
                output.append(Data(number.stringValue.utf8))
            }
            return
        }
        if let array = value as? [Any] {
            try writeArray(array, into: &output)
            return
        }
        if let dictionary = value as? [String: Any] {
            try writeDictionary(dictionary, into: &output)
            return
        }
        // Swift typed containers are NOT covariant to [Any], so
        // `as? [Any]` / `as? [String: Any]` fail for e.g. [String: Double];
        // the JSONSerialization fallback would then raise an ObjC
        // exception for such values, so normalize them explicitly.
        // Integer containers are matched BEFORE their Double counterparts
        // because NSDictionary/NSArray bridging converts Int to Double.
        if let dictionary = value as? [String: Int] {
            try writeDictionary(dictionary.mapValues { $0 as Any }, into: &output)
            return
        }
        if let dictionary = value as? [String: Double] {
            try writeDictionary(dictionary.mapValues { $0 as Any }, into: &output)
            return
        }
        if let dictionary = value as? [String: String] {
            try writeDictionary(dictionary.mapValues { $0 as Any }, into: &output)
            return
        }
        if let array = value as? [Int] {
            try writeArray(array.map { $0 as Any }, into: &output)
            return
        }
        if let array = value as? [Double] {
            try writeArray(array.map { $0 as Any }, into: &output)
            return
        }
        if let array = value as? [String] {
            try writeArray(array.map { $0 as Any }, into: &output)
            return
        }
        // Anything else (optionals, sets, custom types) would make
        // JSONSerialization raise an Objective-C exception, which Swift
        // cannot catch. Fail deterministically instead.
        throw CanonicalJSONError.unsupportedValue(dynamicType)
    }

    private static func writeArray(_ array: [Any], into output: inout Data) throws {
        output.append(Data("[" .utf8))
        var first = true
        for item in array {
            if !first {
                output.append(Data(",".utf8))
            }
            first = false
            try write(item, into: &output)
        }
        output.append(Data("]".utf8))
    }

    private static func writeDictionary(_ dictionary: [String: Any], into output: inout Data) throws {
        let keys = dictionary.keys.sorted { lhs, rhs in
            compareUnicodeScalars(lhs, rhs)
        }
        output.append(Data("{".utf8))
        var first = true
        for key in keys {
            if !first {
                output.append(Data(",".utf8))
            }
            first = false
            output.append(Data(escapedString(key).utf8))
            output.append(Data(":".utf8))
            // Dictionary subscripting yields Any?; unwrap so Optional
            // wrappers never leak into write() (type(of:) must see the
            // real value, not Optional<Any>).
            if let item = dictionary[key] {
                try write(item, into: &output)
            } else {
                output.append(Data("null".utf8))
            }
        }
        output.append(Data("}".utf8))
    }

    private static func writeFiniteNumber(_ double: Double, into output: inout Data) throws {
        guard double.isFinite else {
            throw CanonicalJSONError.nonFiniteNumber
        }
        output.append(Data(canonicalNumber(double).utf8))
    }

    /// `JSONSerialization` represents integer and floating JSON tokens with
    /// different NSNumber Objective-C encodings. Checking `as? Int` is not
    /// safe here because Foundation bridges integral doubles to Int too.
    private static func foundationNumberIsFloatingPoint(_ number: NSNumber) -> Bool {
        let encoding = String(cString: number.objCType)
        return encoding == "f" || encoding == "d"
    }

    /// Lexicographic comparison by Unicode scalar values, matching the
    /// PC `json.dumps(..., sort_keys=True)` ordering.
    static func compareUnicodeScalars(_ lhs: String, _ rhs: String) -> Bool {
        var lhsIterator = lhs.unicodeScalars.makeIterator()
        var rhsIterator = rhs.unicodeScalars.makeIterator()
        while let lhsScalar = lhsIterator.next() {
            guard let rhsScalar = rhsIterator.next() else {
                return false
            }
            if lhsScalar.value != rhsScalar.value {
                return lhsScalar.value < rhsScalar.value
            }
        }
        return rhsIterator.next() != nil
    }

    /// Shortest round-trip decimal representation, with an explicit
    /// `.0` suffix for integral values to match the PC repr contract.
    static func canonicalNumber(_ value: Double) -> String {
        if value == value.rounded() && abs(value) < 1e15 {
            // Integral double: emit one decimal place like Python repr.
            let integer = Int64(value)
            return "\(integer).0"
        }
        return String(describing: value)
    }

    static func escapedString(_ value: String) -> String {
        var output = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"":
                output += "\\\""
            case "\\":
                output += "\\\\"
            case "\n":
                output += "\\n"
            case "\r":
                output += "\\r"
            case "\t":
                output += "\\t"
            case "\u{08}":
                output += "\\b"
            case "\u{0C}":
                output += "\\f"
            default:
                if scalar.value < 0x20 {
                    output += String(format: "\\u%04x", scalar.value)
                } else {
                    output.append(Character(scalar))
                }
            }
        }
        output += "\""
        return output
    }
}

/// Canonical SHA-256 helpers used across mobile import and results.
enum CanonicalSourceHasher {
    static func sha256(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func sha256File(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if chunk.isEmpty {
                break
            }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
