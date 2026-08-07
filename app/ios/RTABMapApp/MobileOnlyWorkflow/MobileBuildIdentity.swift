import Foundation

/// Build identity embedded into the app bundle at build time (V1R3 §4.4,
/// V1R4 §3.3 unified contract). The Xcode "MarketScanner Build Identity"
/// script phase calls `tools/Qualification/market_scanner_build_identity.py`
/// — the SAME script CI uses — and writes
/// `MarketScannerBuildIdentity.json` into the app resources. `unknown`
/// must never reach an eligible session (§8.1).
struct MobileBuildIdentity: Equatable {
    var appGitSHA: String
    var wave: String
    var branch: String
    var baseBranch: String
    var baseSHA: String
    var implementationSHA: String
    var validationSHA: String
    var nativeCoreSHA256: String

    /// Strict runtime validation (§3.3): every field must be fully
    /// bound and well-formed. The build generator may carry the two exact
    /// pre-governance placeholders, but an app containing either one is
    /// deliberately ineligible for production processing.
    var isUsable: Bool {
        return MobileBuildIdentity.isLowercaseHex(appGitSHA, length: 40)
            && MobileBuildIdentity.isLowercaseHex(nativeCoreSHA256, length: 64)
            && MobileBuildIdentity.isSafeGovernanceName(wave)
            && MobileBuildIdentity.isSafeGovernanceName(branch)
            && MobileBuildIdentity.isSafeGovernanceName(baseBranch)
            && MobileBuildIdentity.isLowercaseHex(baseSHA, length: 40)
            && MobileBuildIdentity.isLowercaseHex(
                implementationSHA, length: 40)
            && MobileBuildIdentity.isLowercaseHex(validationSHA, length: 40)
    }

    private static func isLowercaseHex(_ value: String, length: Int) -> Bool {
        guard value.count == length else { return false }
        for scalar in value.unicodeScalars {
            let isDigit = scalar.value >= 0x30 && scalar.value <= 0x39
            let isLowerAF = scalar.value >= 0x61 && scalar.value <= 0x66
            if !isDigit && !isLowerAF { return false }
        }
        return true
    }

    private static func isSafeGovernanceName(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 128 else { return false }
        for (index, scalar) in value.unicodeScalars.enumerated() {
            let isLowercase = scalar.value >= 0x61 && scalar.value <= 0x7A
            let isDigit = scalar.value >= 0x30 && scalar.value <= 0x39
            let isPunctuation = scalar == "." || scalar == "_" || scalar == "-"
            if index == 0 {
                if !isLowercase && !isDigit { return false }
            } else if !isLowercase && !isDigit && !isPunctuation {
                return false
            }
        }
        return true
    }

    private static var unusable: MobileBuildIdentity {
        return MobileBuildIdentity(
            appGitSHA: "unknown",
            wave: "unknown",
            branch: "unknown",
            baseBranch: "unknown",
            baseSHA: "unknown",
            implementationSHA: "unknown",
            validationSHA: "unknown",
            nativeCoreSHA256: "unknown")
    }

    /// Reads the bundled identity; returns an unusable identity when the
    /// resource is missing (host tests, non-product builds).
    static func loadFromBundle() -> MobileBuildIdentity {
        guard let url = Bundle.main.url(
            forResource: "MarketScannerBuildIdentity", withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let object = try? StrictJSONDocumentParser.object(
                from: data,
                limits: StrictJSONDocumentLimits(maximumBytes: data.count + 1)) as? [String: Any]
        else {
            return unusable
        }
        // Version and exact fields must match the unified governance
        // contract. Unknown or missing fields fail closed.
        let expectedKeys: Set<String> = [
            "format", "version", "app_git_sha", "native_core_sha256",
            "wave", "branch", "base_branch", "base_sha",
            "implementation_sha", "validation_sha",
        ]
        guard Set(object.keys) == expectedKeys,
              StrictJSONScalar.integer(object["version"]) == 3,
              (object["format"] as? String) == "MarketScannerBuildIdentity"
        else {
            return unusable
        }
        return MobileBuildIdentity(
            appGitSHA: object["app_git_sha"] as? String ?? "unknown",
            wave: object["wave"] as? String ?? "unknown",
            branch: object["branch"] as? String ?? "unknown",
            baseBranch: object["base_branch"] as? String ?? "unknown",
            baseSHA: object["base_sha"] as? String ?? "unknown",
            implementationSHA:
                object["implementation_sha"] as? String ?? "unknown",
            validationSHA: object["validation_sha"] as? String ?? "unknown",
            nativeCoreSHA256: object["native_core_sha256"] as? String ?? "unknown")
    }
}
