// P7R6B: one Foundation-only helper for strict JSON scalar reads.
//
// Foundation bridges an NSNumber produced by JSONSerialization through
// `is Bool` and `as? Bool`: NSNumber(value: 1) can answer "true" for both,
// so a numeric 0/1 masquerades as a JSON boolean. The Python PC reader
// rejects that with `isinstance(value, bool)`, so every formal evidence
// schema on the device must use the same CoreFoundation type check or the
// device accepts evidence the PC reader refuses (device PASS / PC FAIL).
//
// Every formal evidence validator (Recovery parser, finalization bundle
// validator, prior-map package integrity) reads JSON booleans/numbers
// through this one helper.

import Foundation
import CoreFoundation

enum StrictJSONScalar {
    /// True only for a genuine JSON boolean. A numeric 0/1 bridged through
    /// NSNumber has the CFNumber type ID and returns nil, matching
    /// `isinstance(value, bool)` on the PC reader.
    static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else {
            return nil
        }
        return number.boolValue
    }

    /// Strict JSON integer: a real number (never a boolean, never a
    /// non-finite double, never a fractional double) that fits in Int.
    static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return nil
        }
        let double = number.doubleValue
        guard double.isFinite, double.rounded() == double else {
            return nil
        }
        return Int(exactly: double)
    }

    /// Strict JSON number: a real finite double, never a boolean.
    static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return nil
        }
        let result = number.doubleValue
        return result.isFinite ? result : nil
    }
}
