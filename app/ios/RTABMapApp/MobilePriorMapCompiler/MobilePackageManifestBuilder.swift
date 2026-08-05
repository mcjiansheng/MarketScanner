import Foundation
import CryptoKit

/// Builds `package_manifest.json` and verifies a compiled package with
/// the same rules as `tools/PriorMap/prior_map_schema.py`.
enum MobilePackageManifestBuilder {
    static let packageFormat = "MarketScannerPriorMap"
    static let packageVersion = 1
    static let manifestFormat = "MarketScannerPriorMapPackageManifest"
    static let manifestFileName = "package_manifest.json"

    static func buildManifest(directory: URL) throws -> [String: Any] {
        let fileManager = FileManager.default
        let names = try fileManager.contentsOfDirectory(
            atPath: directory.path).sorted()
        var artifacts: [[String: Any]] = []
        for name in names {
            guard name != manifestFileName,
                  !name.hasPrefix("._"),
                  name != ".DS_Store"
            else { continue }
            let url = directory.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue
            else { continue }
            let data = try Data(contentsOf: url)
            let sha = CanonicalSourceHasher.sha256(data)
            let isPNG = name.lowercased().hasSuffix(".png")
            var record: [String: Any] = [
                "file": name,
                "bytes": data.count,
                "sha256": sha,
                "media_type": isPNG ? "image/png" : "application/json",
            ]
            if name.lowercased().hasSuffix(".json") {
                let limits = StrictJSONDocumentLimits(
                    maximumBytes: data.count + 1,
                    maximumNestingDepth: MapSourceImportLimits.maximumJSONNestingDepth
                )
                guard let object = try? StrictJSONDocumentParser.object(
                    from: data, limits: limits) as? [String: Any]
                else {
                    throw MapSourceImportError.invalidJSON(detail: "\(name) 顶层必须是对象。")
                }
                record["format"] = object["format"] as? String ?? ""
                record["version"] = object["version"] as? Int ?? 0
            }
            artifacts.append(record)
        }
        return [
            "format": manifestFormat,
            "version": packageVersion,
            "hash_algorithm": "sha256",
            "artifact_count": artifacts.count,
            "artifacts": artifacts,
            "package_sha256": packageDigest(artifacts),
        ]
    }

    /// Canonical digest over the sorted artifact records, matching
    /// `package_digest` (NUL-separated fields, newline-terminated rows).
    static func packageDigest(_ artifacts: [[String: Any]]) -> String {
        var canonical = ""
        for item in artifacts {
            let fields = [
                stringField(item, "file"),
                stringField(item, "bytes"),
                stringField(item, "sha256"),
                stringField(item, "format"),
                stringField(item, "version"),
            ]
            canonical += fields.joined(separator: "\0") + "\n"
        }
        return CanonicalSourceHasher.sha256(Data(canonical.utf8))
    }

    private static func stringField(_ item: [String: Any], _ key: String) -> String {
        guard let value = item[key] else { return "" }
        if let number = value as? Int { return String(number) }
        if let text = value as? String { return text }
        return ""
    }

    /// Checks that every required package file exists before commit.
    static func requiredFilesPresent(directory: URL) throws {
        let required = [
            "manifest.json", "elements.json", "shelves.json",
            "fixed_structures.json", "road_graph.json", "spatial_index.json",
            "distance_fields.json", "preview.png", "validation_report.json",
        ]
        let fileManager = FileManager.default
        for name in required {
            guard fileManager.fileExists(
                atPath: directory.appendingPathComponent(name).path)
            else {
                throw MapSourceImportError.unreadableSource(
                    reason: "编译产物缺少 \(name)。")
            }
        }
    }
}
