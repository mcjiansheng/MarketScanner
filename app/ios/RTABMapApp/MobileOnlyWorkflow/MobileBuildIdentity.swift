import Foundation

/// Build identity embedded into the app bundle at build time (V1R3 §4.4).
/// The Xcode "MarketScanner Build Identity" script phase writes
/// `MarketScannerBuildIdentity.json` into the app resources with the
/// exact git SHA, wave name and native-core source SHA. `unknown` must
/// never reach an eligible session (§8.1).
struct MobileBuildIdentity: Equatable {
    var appGitSHA: String
    var wave: String
    var nativeCoreSHA256: String

    var isUsable: Bool {
        return !appGitSHA.isEmpty && appGitSHA != "unknown"
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
        return MobileBuildIdentity(
            appGitSHA: object["app_git_sha"] as? String ?? "unknown",
            wave: object["wave"] as? String ?? "unknown",
            nativeCoreSHA256: object["native_core_sha256"] as? String ?? "unknown")
    }
}
