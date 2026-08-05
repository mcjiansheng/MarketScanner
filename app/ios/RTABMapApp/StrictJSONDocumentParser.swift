// P7R6C: one strict entry point for decoding formal JSON documents.
//
// Formal evidence and prior-map packages must never call
// JSONSerialization.jsonObject(with:) directly: the bytes must first
// pass strict UTF-8 validation, duplicate-key rejection and the bounded
// nesting contract. This parser performs exactly those layers and then
// enforces the top-level type, so every consumer of a formal JSON
// document gets the same fail-closed behavior.

import Foundation

/// Frozen size/shape contract for one formal JSON document.
struct StrictJSONDocumentLimits {
    let maximumBytes: Int
    let maximumNestingDepth: Int

    init(
        maximumBytes: Int,
        maximumNestingDepth: Int = RecoveryLifecycleEvidenceLimits
            .maximumJSONNestingDepth
    ) {
        self.maximumBytes = maximumBytes
        self.maximumNestingDepth = maximumNestingDepth
    }
}

enum StrictJSONDocumentParseError: Error, Equatable {
    case documentTooLarge
    case invalidUTF8
    case duplicateJSONKey
    case invalidJSON
    case topLevelTypeMismatch
}

enum StrictJSONDocumentParser {
    static func object(
        from data: Data,
        limits: StrictJSONDocumentLimits
    ) throws -> [String: Any] {
        let value = try parseValue(from: data, limits: limits)
        guard let object = value as? [String: Any] else {
            throw StrictJSONDocumentParseError.topLevelTypeMismatch
        }
        return object
    }

    static func array(
        from data: Data,
        limits: StrictJSONDocumentLimits
    ) throws -> [Any] {
        let value = try parseValue(from: data, limits: limits)
        guard let array = value as? [Any] else {
            throw StrictJSONDocumentParseError.topLevelTypeMismatch
        }
        return array
    }

    /// Layer 1 strict UTF-8 -> layer 2 duplicate-key/structure scan ->
    /// JSONSerialization. The scanner is a total function; nothing here
    /// can trap on arbitrary bytes.
    private static func parseValue(
        from data: Data,
        limits: StrictJSONDocumentLimits
    ) throws -> Any {
        guard data.count <= limits.maximumBytes else {
            throw StrictJSONDocumentParseError.documentTooLarge
        }
        do {
            try StrictJSONKeyUniquenessValidator.validate(
                data, maximumNestingDepth: limits.maximumNestingDepth)
        }
        catch StrictJSONValidationError.duplicateKey(_, _) {
            throw StrictJSONDocumentParseError.duplicateJSONKey
        }
        catch StrictJSONValidationError.invalidUTF8 {
            throw StrictJSONDocumentParseError.invalidUTF8
        }
        catch StrictJSONValidationError.scalarOutOfRange {
            throw StrictJSONDocumentParseError.invalidUTF8
        }
        catch is StrictJSONValidationError {
            throw StrictJSONDocumentParseError.invalidJSON
        }
        let decoded: Any
        do {
            decoded = try JSONSerialization.jsonObject(with: data)
        }
        catch {
            throw StrictJSONDocumentParseError.invalidJSON
        }
        // The duplicate-key scanner already bounded the nesting depth;
        // JSONSerialization applies its own structural validation here.
        return decoded
    }
}
