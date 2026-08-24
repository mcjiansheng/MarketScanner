import Foundation
import CryptoKit

/// Bundles the exact installed prior-map package a scan was bound to into the
/// finalized session directory (`<session>/prior_map/`) plus a sibling
/// receipt (`<session>/prior_map_receipt.json`), so PC post-processing can
/// always run structure-corrected localized optimization without depending on
/// the PC operator having the same workbook version.
///
/// Contract (fail-closed):
/// - Only the exact `(priorMapID, packageSHA256)` identity recorded in the
///   scan configuration may be bundled; the installed package is fully
///   re-verified through `MobileMapLibrary.map` before copying.
/// - When the session binding carries `priorMapCanonicalSourceSha256`, the
///   installed package canonical source SHA must equal it.
/// - The copied tree must exactly equal the package manifest artifact set and
///   every artifact digest is recomputed after copying.
/// - The receipt lives OUTSIDE `prior_map/` so the bundled directory remains a
///   byte-exact prior-map package (PC package integrity verification rejects
///   extra ordinary files inside a package).
/// - Bundling is idempotent: an existing valid bundle for the same package
///   identity is kept, never rewritten.
enum PriorMapSessionBundler {

    static let bundleDirectoryName = "prior_map"
    static let receiptFileName = "prior_map_receipt.json"
    private static let partialSuffix = ".prior_map.partial"
    static let receiptFormat = "MarketScannerPriorMapBundleReceipt"
    static let receiptVersion = 1

    struct Receipt: Codable, Equatable {
        let format: String
        let version: Int
        let bundled: Bool
        let priorMapId: String
        let packageSha256: String
        let canonicalSourceSha256: String?
        let name: String?
        let floorCount: Int
        let elementCount: Int
        let compilerVersion: String?
        let bundledAtUnix: Double
        let fileCount: Int
        let bundleContentSha256: String
        let files: [String: String]

        enum CodingKeys: String, CodingKey {
            case format
            case version
            case bundled
            case priorMapId = "prior_map_id"
            case packageSha256 = "package_sha256"
            case canonicalSourceSha256 = "canonical_source_sha256"
            case name
            case floorCount = "floor_count"
            case elementCount = "element_count"
            case compilerVersion = "compiler_version"
            case bundledAtUnix = "bundled_at_unix"
            case fileCount = "file_count"
            case bundleContentSha256 = "bundle_content_sha256"
            case files
        }
    }

    enum BundleError: Error, LocalizedError {
        case missingBinding(String)
        case notInstalled(String)
        case identityMismatch(String)
        case copyFailed(String)
        case verificationFailed(String)

        var errorDescription: String? {
            switch self {
            case .missingBinding(let d): return "扫描缺少先验地图绑定：\(d)"
            case .notInstalled(let d): return "手机地图库未安装该地图包：\(d)"
            case .identityMismatch(let d): return "地图包身份与会话绑定不一致：\(d)"
            case .copyFailed(let d): return "地图包捆绑复制失败：\(d)"
            case .verificationFailed(let d): return "地图包捆绑校验失败：\(d)"
            }
        }
    }

    static func bundledPackageDirectory(in sessionDirectory: URL) -> URL {
        return sessionDirectory.appendingPathComponent(
            bundleDirectoryName, isDirectory: true)
    }

    static func receiptURL(in sessionDirectory: URL) -> URL {
        return sessionDirectory.appendingPathComponent(receiptFileName)
    }

    // MARK: - Bundling

    /// Copies the verified installed package into `<session>/prior_map` and
    /// writes the receipt. Throws on any identity/verification failure.
    @discardableResult
    static func bundleInstalledPackage(
        into sessionDirectory: URL,
        priorMapID: String,
        packageSHA256: String,
        canonicalSourceSHA256: String?
    ) throws -> Receipt {
        guard !priorMapID.isEmpty, !packageSHA256.isEmpty else {
            throw BundleError.missingBinding("\(priorMapID)/\(packageSHA256)")
        }
        let destination = bundledPackageDirectory(in: sessionDirectory)
        if let existing = readReceipt(in: sessionDirectory),
           existing.bundled,
           existing.priorMapId == priorMapID,
           existing.packageSha256 == packageSHA256,
           FileManager.default.fileExists(atPath: destination.path),
           (try? verifyBundledPackage(in: sessionDirectory)) != nil {
            return existing
        }
        let entry: MobileMapLibrary.MapEntry
        do {
            entry = try MobileMapLibrary.map(
                priorMapID: priorMapID, packageSHA256: packageSHA256)
        } catch {
            throw BundleError.notInstalled("\(priorMapID)/\(packageSHA256): \(error)")
        }
        if let canonicalSourceSHA256 = canonicalSourceSHA256,
           !canonicalSourceSHA256.isEmpty,
           entry.canonicalSourceSHA256 != canonicalSourceSHA256 {
            throw BundleError.identityMismatch(
                "canonical \(entry.canonicalSourceSHA256) != session \(canonicalSourceSHA256)")
        }
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: entry.packageDirectory.path, isDirectory: &isDirectory),
            isDirectory.boolValue else {
            throw BundleError.notInstalled(entry.packageDirectory.path)
        }
        let partial = sessionDirectory.appendingPathComponent(
            partialSuffix + "-" + UUID().uuidString, isDirectory: true)
        if fileManager.fileExists(atPath: partial.path) {
            try? fileManager.removeItem(at: partial)
        }
        do {
            try fileManager.createDirectory(
                at: sessionDirectory, withIntermediateDirectories: true)
            try fileManager.copyItem(at: entry.packageDirectory, to: partial)
        } catch {
            try? fileManager.removeItem(at: partial)
            throw BundleError.copyFailed("\(error)")
        }
        let files: [String: String]
        do {
            files = try verifyPackageTree(
                at: partial, expectedPackageSHA256: packageSHA256,
                expectedPriorMapID: priorMapID,
                expectedCanonicalSourceSHA256: canonicalSourceSHA256)
        } catch {
            try? fileManager.removeItem(at: partial)
            throw error
        }
        if fileManager.fileExists(atPath: destination.path) {
            let stale = sessionDirectory.appendingPathComponent(
                partialSuffix + ".stale-" + UUID().uuidString, isDirectory: true)
            do {
                try fileManager.moveItem(at: destination, to: stale)
                try? fileManager.removeItem(at: stale)
            } catch {
                try? fileManager.removeItem(at: partial)
                throw BundleError.copyFailed("stale bundle removal failed: \(error)")
            }
        }
        do {
            try fileManager.moveItem(at: partial, to: destination)
        } catch {
            try? fileManager.removeItem(at: partial)
            throw BundleError.copyFailed("\(error)")
        }
        let receipt = Receipt(
            format: receiptFormat,
            version: receiptVersion,
            bundled: true,
            priorMapId: entry.priorMapID,
            packageSha256: entry.packageSHA256,
            canonicalSourceSha256: entry.canonicalSourceSHA256,
            name: entry.name,
            floorCount: entry.floorCount,
            elementCount: entry.elementCount,
            compilerVersion: entry.compilerVersion,
            bundledAtUnix: Date().timeIntervalSince1970,
            fileCount: files.count,
            bundleContentSha256: contentDigest(of: files),
            files: files)
        try writeReceipt(receipt, in: sessionDirectory)
        return receipt
    }

    /// Re-installs the bundled package into the map library when the exact
    /// bound identity is no longer registered (e.g. the operator removed it
    /// after the scan). This keeps on-device post-processing of finalized
    /// sessions independent from library housekeeping. Throws unless the
    /// bundled package verifies against the receipt fail-closed.
    ///
    /// `unregister` keeps the immutable package bytes, so the common restore
    /// reuses the content-addressed directory after re-verifying its digest;
    /// only when the bytes were physically removed is a fresh copy installed.
    @discardableResult
    static func restoreInstalledPackage(
        from sessionDirectory: URL
    ) throws -> MobileMapLibrary.MapEntry {
        let receipt = try verifyBundledPackage(in: sessionDirectory)
        do {
            return try MobileMapLibrary.map(
                priorMapID: receipt.priorMapId,
                packageSHA256: receipt.packageSha256)
        } catch {
            // Not registered anymore: restore from the bundle below.
        }
        let fileManager = FileManager.default
        let target = try MobileMapLibrary.packageDirectory(
            priorMapID: receipt.priorMapId,
            packageSHA: receipt.packageSha256)
        let targetParent = target.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: targetParent,
            withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: target.path) {
            // The content-addressed bytes survived `unregister`: reuse them
            // only when they still match the receipt exactly (fail-closed).
            _ = try verifyPackageTree(
                at: target,
                expectedPackageSHA256: receipt.packageSha256,
                expectedPriorMapID: receipt.priorMapId,
                expectedCanonicalSourceSHA256:
                    receipt.canonicalSourceSha256)
        } else {
            do {
                try fileManager.copyItem(
                    at: bundledPackageDirectory(in: sessionDirectory),
                    to: target)
            } catch {
                throw BundleError.copyFailed(
                    "cannot install restored package: \(error)")
            }
        }
        return try MobileMapLibrary.register(
            priorMapID: receipt.priorMapId,
            name: receipt.name ?? receipt.priorMapId,
            packageSHA256: receipt.packageSha256,
            packageURL: target,
            floorCount: receipt.floorCount,
            elementCount: receipt.elementCount,
            compilerVersion: receipt.compilerVersion ?? "swift-v1",
            canonicalSourceSHA256: receipt.canonicalSourceSha256
                ?? "")
    }

    // MARK: - Reading / verification

    static func readReceipt(in sessionDirectory: URL) -> Receipt? {
        let url = receiptURL(in: sessionDirectory)
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let receipt = try? JSONDecoder().decode(Receipt.self, from: data)
        else { return nil }
        guard receipt.format == receiptFormat,
              receipt.version == receiptVersion else { return nil }
        return receipt
    }

    /// Recomputes every bundled artifact digest and cross-checks the receipt.
    @discardableResult
    static func verifyBundledPackage(in sessionDirectory: URL) throws -> Receipt {
        guard let receipt = readReceipt(in: sessionDirectory) else {
            throw BundleError.verificationFailed("receipt missing or invalid")
        }
        guard receipt.bundled else {
            throw BundleError.verificationFailed("receipt declares bundled=false")
        }
        let destination = bundledPackageDirectory(in: sessionDirectory)
        let files = try verifyPackageTree(
            at: destination, expectedPackageSHA256: receipt.packageSha256,
            expectedPriorMapID: receipt.priorMapId,
            expectedCanonicalSourceSHA256: receipt.canonicalSourceSha256)
        guard contentDigest(of: files) == receipt.bundleContentSha256,
              files == receipt.files else {
            throw BundleError.verificationFailed("bundled files differ from receipt")
        }
        return receipt
    }

    // MARK: - Helpers

    /// Validates that `packageURL` is a complete prior-map package whose
    /// artifact digests, identity and canonical source SHA match the binding.
    /// Returns the relative-path → sha256 manifest of the artifact set.
    private static func verifyPackageTree(
        at packageURL: URL,
        expectedPackageSHA256: String,
        expectedPriorMapID: String,
        expectedCanonicalSourceSHA256: String?
    ) throws -> [String: String] {
        let fileManager = FileManager.default
        let packageManifestURL = packageURL.appendingPathComponent(
            "package_manifest.json")
        guard let packageManifestData = try? Data(contentsOf: packageManifestURL),
              let packageManifest = try? JSONSerialization.jsonObject(
                  with: packageManifestData) as? [String: Any] else {
            throw BundleError.verificationFailed("package_manifest.json unreadable")
        }
        guard packageManifest["package_sha256"] as? String
                == expectedPackageSHA256 else {
            throw BundleError.identityMismatch("package_manifest package_sha256")
        }
        guard let artifacts = packageManifest["artifacts"] as? [[String: Any]]
        else {
            throw BundleError.verificationFailed("package_manifest artifacts missing")
        }
        var files: [String: String] = [:]
        for artifact in artifacts {
            guard let name = artifact["file"] as? String,
                  !name.isEmpty, !name.contains("/"), !name.hasPrefix("."),
                  let sha = artifact["sha256"] as? String else {
                throw BundleError.verificationFailed("malformed artifact entry")
            }
            let url = packageURL.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url) else {
                throw BundleError.verificationFailed("artifact missing: \(name)")
            }
            let digest = sha256Hex(data)
            guard digest == sha else {
                throw BundleError.verificationFailed(
                    "artifact digest mismatch: \(name)")
            }
            files[name] = digest
        }
        // The copied tree must not carry anything beyond the artifact set
        // (package_manifest.json lists the other artifacts, never itself).
        guard let topLevel = try? fileManager.contentsOfDirectory(
            atPath: packageURL.path) else {
            throw BundleError.verificationFailed("cannot list bundled package")
        }
        let extras = topLevel.filter {
            !$0.hasPrefix(".") && $0 != "package_manifest.json"
                && files[$0] == nil
        }
        guard extras.isEmpty else {
            throw BundleError.verificationFailed(
                "unexpected extra files: \(extras.sorted().joined(separator: ","))")
        }
        let manifestURL = packageURL.appendingPathComponent("manifest.json")
        guard let manifestData = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONSerialization.jsonObject(
                  with: manifestData) as? [String: Any] else {
            throw BundleError.verificationFailed("manifest.json unreadable")
        }
        guard manifest["prior_map_id"] as? String == expectedPriorMapID else {
            throw BundleError.identityMismatch("manifest prior_map_id")
        }
        if let expectedCanonicalSourceSHA256 = expectedCanonicalSourceSHA256,
           !expectedCanonicalSourceSHA256.isEmpty {
            guard manifest["canonical_source_sha256"] as? String
                    == expectedCanonicalSourceSHA256 else {
                throw BundleError.identityMismatch("manifest canonical_source_sha256")
            }
        }
        return files
    }

    private static func writeReceipt(
        _ receipt: Receipt, in sessionDirectory: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(receipt)
        let url = receiptURL(in: sessionDirectory)
        let temporary = sessionDirectory.appendingPathComponent(
            receiptFileName + ".tmp-" + UUID().uuidString)
        try data.write(to: temporary, options: [.atomic])
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        try fileManager.moveItem(at: temporary, to: url)
    }

    private static func contentDigest(of files: [String: String]) -> String {
        let canonical = files.keys.sorted().map { "\($0)\0\(files[$0] ?? "")\n" }
            .joined()
        return sha256Hex(Data(canonical.utf8))
    }

    static func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
