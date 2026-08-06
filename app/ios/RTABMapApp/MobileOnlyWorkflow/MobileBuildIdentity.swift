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
    var nativeCoreSHA256: String

    /// Strict field validation (§3.3): every field must be well-formed.
    var isUsable: Bool {
        return MobileBuildIdentity.isLowercaseHex(appGitSHA, length: 40)
            && MobileBuildIdentity.isLowercaseHex(nativeCoreSHA256, length: 64)
            && wave.hasPrefix("mobile-only-v1r4-")
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
            return MobileBuildIdentity(appGitSHA: "unknown", wave: "unknown", nativeCoreSHA256: "unknown")
        }
        // Version must match the unified contract (V1R4 §3.3).
        guard (object["version"] as? Int) == 2,
              (object["format"] as? String) == "MarketScannerBuildIdentity"
        else {
            return MobileBuildIdentity(appGitSHA: "unknown", wave: "unknown", nativeCoreSHA256: "unknown")
        }
        return MobileBuildIdentity(
            appGitSHA: object["app_git_sha"] as? String ?? "unknown",
            wave: object["wave"] as? String ?? "unknown",
            nativeCoreSHA256: object["native_core_sha256"] as? String ?? "unknown")
    }
}
