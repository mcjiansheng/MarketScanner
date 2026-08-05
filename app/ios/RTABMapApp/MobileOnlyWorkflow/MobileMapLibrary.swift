import Foundation

/// Durable on-device prior-map library (V1R1 Gate A / Gate C).
///
/// Layout (mirrors the PC `Maps` contract):
/// ```
/// Application Support/MarketScanner/Maps/
///   staging/<task>/          # compile staging directory
///   packages/<prior-map-id>/<package-sha>/   # immutable compiled package
///   registry.json            # durable index (CAS-updated)
/// ```
///
/// A map only becomes visible to the app after its package directory is
/// fully written/fsynced and the registry update is committed. A crash at
/// any point leaves either an empty staging directory or the previous
/// registry; `rebuildRegistry()` restores the index from the packages.
enum MobileMapLibrary {

    struct MapEntry: Equatable {
        var priorMapID: String
        var name: String
        var packageSHA256: String
        var packageDirectory: URL
        var floorCount: Int
        var elementCount: Int
        var compiledAtUTC: Double
        var compilerVersion: String
        var canonicalSourceSHA256: String

        var manifestPayload: [String: Any] {
            return [
                "prior_map_id": priorMapID,
                "name": name,
                "package_sha256": packageSHA256,
                // Relative path under the packages root:
                // `<prior-map-id>/<package-sha>` (two levels).
                "package_directory": relativePackagePath,
                "floor_count": floorCount,
                "element_count": elementCount,
                "compiled_at_utc": compiledAtUTC,
                "compiler_version": compilerVersion,
                "canonical_source_sha256": canonicalSourceSHA256,
            ]
        }

        /// `packages/<prior-map-id>/<package-sha>` relative to the root.
        var relativePackagePath: String {
            return "\(priorMapID)/\(packageSHA256)"
        }
    }

    enum LibraryError: Error, LocalizedError {
        case cannotCreateRoot(String)
        case registryCorrupt(String)
        case notRegistered(String)
        case packageMissing(String)
        case cannotWriteRegistry(String)

        var errorDescription: String? {
            switch self {
            case .cannotCreateRoot(let d): return "无法创建地图库目录：\(d)"
            case .registryCorrupt(let d): return "地图注册表损坏：\(d)"
            case .notRegistered(let d): return "地图未注册：\(d)"
            case .packageMissing(let d): return "地图包缺失：\(d)"
            case .cannotWriteRegistry(let d): return "注册表写入失败：\(d)"
            }
        }
    }

    static let registryFileName = "registry.json"
    static let currentRegistryVersion = 2

    /// Test/embedding hook: when set, `root()` returns this directory
    /// instead of the Application Support location. The host suite uses
    /// it to keep runs inside a temporary directory.
    static var rootOverride: URL?

    // MARK: - Roots

    /// `Application Support/MarketScanner/Maps/` (or `rootOverride`).
    static func root() throws -> URL {
        if let rootOverride = rootOverride {
            try FileManager.default.createDirectory(
                at: rootOverride, withIntermediateDirectories: true)
            return rootOverride
        }
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true)
        let root = base
            .appendingPathComponent("MarketScanner", isDirectory: true)
            .appendingPathComponent("Maps", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
        return root
    }

    static func stagingDirectory(for taskID: String) throws -> URL {
        let directory = try root()
            .appendingPathComponent("staging", isDirectory: true)
            .appendingPathComponent(taskID, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func packagesRoot() throws -> URL {
        let directory = try root().appendingPathComponent("packages", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func packageDirectory(priorMapID: String, packageSHA: String) throws -> URL {
        return try packagesRoot()
            .appendingPathComponent(priorMapID, isDirectory: true)
            .appendingPathComponent(packageSHA, isDirectory: true)
    }

    static func registryURL() throws -> URL {
        return try root().appendingPathComponent(registryFileName)
    }

    // MARK: - Registration

    /// Atomically registers a compiled package. The caller must have
    /// already moved the verified package into
    /// `packages/<prior-map-id>/<package-sha>/`; this function only
    /// updates the durable index (write temp -> fsync -> rename -> fsync
    /// parent).
    static func register(
        priorMapID: String,
        name: String,
        packageSHA256: String,
        packageURL: URL,
        floorCount: Int,
        elementCount: Int,
        compilerVersion: String,
        canonicalSourceSHA256: String
    ) throws -> MapEntry {
        var entries = try readRegistry()
        // Same (id, sha) re-registration is idempotent; a different sha
        // for the same id supersedes the old entry (never duplicates).
        entries.removeAll { $0.priorMapID == priorMapID && $0.packageSHA256 == packageSHA256 }
        let entry = MapEntry(
            priorMapID: priorMapID,
            name: name,
            packageSHA256: packageSHA256,
            packageDirectory: packageURL,
            floorCount: floorCount,
            elementCount: elementCount,
            compiledAtUTC: Date().timeIntervalSince1970,
            compilerVersion: compilerVersion,
            canonicalSourceSHA256: canonicalSourceSHA256)
        entries.append(entry)
        try writeRegistry(entries)
        return entry
    }

    /// Removes a map from the durable index (package bytes are kept so a
    /// re-registration never needs a re-compile).
    static func unregister(priorMapID: String, packageSHA256: String? = nil) throws {
        var entries = try readRegistry()
        if let packageSHA256 = packageSHA256 {
            entries.removeAll {
                $0.priorMapID == priorMapID && $0.packageSHA256 == packageSHA256
            }
        } else {
            entries.removeAll { $0.priorMapID == priorMapID }
        }
        try writeRegistry(entries)
    }

    // MARK: - Queries

    static func listMaps() throws -> [MapEntry] {
        let entries = try readRegistry()
        // A registered map whose package disappeared is dropped from the
        // reported list (the registry itself is untouched).
        return entries.filter { entry in
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(
                atPath: entry.packageDirectory.path, isDirectory: &isDirectory)
            return exists && isDirectory.boolValue
        }.sorted { $0.compiledAtUTC > $1.compiledAtUTC }
    }

    static func map(priorMapID: String, packageSHA256: String) throws -> MapEntry {
        guard let entry = try readRegistry().first(where: {
            $0.priorMapID == priorMapID && $0.packageSHA256 == packageSHA256
        }) else {
            throw LibraryError.notRegistered("\(priorMapID)/\(packageSHA256)")
        }
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: entry.packageDirectory.path, isDirectory: &isDirectory)
        guard exists && isDirectory.boolValue else {
            throw LibraryError.packageMissing(entry.packageDirectory.path)
        }
        return entry
    }

    // MARK: - Registry IO (CAS style)

    private static func readRegistry() throws -> [MapEntry] {
        let url = try registryURL()
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else {
            return []
        }
        let data = try Data(contentsOf: url)
        guard let object = try? StrictJSONDocumentParser.object(
            from: data,
            limits: StrictJSONDocumentLimits(maximumBytes: data.count + 1)) as? [String: Any],
              let version = object["version"] as? Int,
              version == currentRegistryVersion,
              let entries = object["maps"] as? [[String: Any]]
        else {
            throw LibraryError.registryCorrupt(url.path)
        }
        var result: [MapEntry] = []
        for raw in entries {
            guard let priorMapID = raw["prior_map_id"] as? String,
                  let name = raw["name"] as? String,
                  let packageSHA256 = raw["package_sha256"] as? String,
                  let packageDirName = raw["package_directory"] as? String,
                  let floorCount = raw["floor_count"] as? Int,
                  let elementCount = raw["element_count"] as? Int,
                  let compiledAtUTC = raw["compiled_at_utc"] as? Double,
                  let compilerVersion = raw["compiler_version"] as? String,
                  let canonicalSHA = raw["canonical_source_sha256"] as? String
            else { continue }
            result.append(MapEntry(
                priorMapID: priorMapID,
                name: name,
                packageSHA256: packageSHA256,
                packageDirectory: try packagesRoot().appendingPathComponent(packageDirName),
                floorCount: floorCount,
                elementCount: elementCount,
                compiledAtUTC: compiledAtUTC,
                compilerVersion: compilerVersion,
                canonicalSourceSHA256: canonicalSHA))
        }
        return result
    }

    private static func writeRegistry(_ entries: [MapEntry]) throws {
        let url = try registryURL()
        let payload: [String: Any] = [
            "format": "MarketScannerMapRegistry",
            "version": currentRegistryVersion,
            "map_count": entries.count,
            "maps": entries.map { $0.manifestPayload },
        ]
        let data: Data
        do {
            data = try CanonicalJSONEncoder.encode(payload)
        } catch {
            throw LibraryError.cannotWriteRegistry("\(error)")
        }
        // temp -> fsync -> rename -> parent fsync
        let directory = url.deletingLastPathComponent()
        let temp = directory.appendingPathComponent(".\(registryFileName).tmp-\(UUID().uuidString)")
        do {
            try data.write(to: temp)
            try syncFile(temp)
            try FileManager.default.replaceItemAt(
                url, withItemAt: temp,
                backupItemName: nil, options: [])
            try syncDirectory(directory)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw LibraryError.cannotWriteRegistry("\(error)")
        }
    }

    /// Rebuilds the registry by scanning `packages/`. Used when the index
    /// is corrupt; package manifests are the source of truth.
    static func rebuildRegistry() throws {
        let root = try packagesRoot()
        let fileManager = FileManager.default
        var entries: [MapEntry] = []
        let ids = try fileManager.contentsOfDirectory(atPath: root.path).sorted()
        for priorMapID in ids {
            let idDir = root.appendingPathComponent(priorMapID)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: idDir.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }
            let shas = try fileManager.contentsOfDirectory(atPath: idDir.path).sorted()
            for sha in shas {
                let package = idDir.appendingPathComponent(sha)
                var isPackage: ObjCBool = false
                guard fileManager.fileExists(atPath: package.path, isDirectory: &isPackage),
                      isPackage.boolValue else { continue }
                guard let manifest = try? readManifest(in: package) else { continue }
                guard let name = manifest["name"] as? String,
                      let floorCount = manifest["floor_count"] as? Int,
                      let elementCount = manifest["element_count"] as? Int,
                      let canonicalSHA = manifest["canonical_source_sha256"] as? String
                else { continue }
                entries.append(MapEntry(
                    priorMapID: priorMapID,
                    name: name,
                    packageSHA256: sha,
                    packageDirectory: package,
                    floorCount: floorCount,
                    elementCount: elementCount,
                    compiledAtUTC: 0,
                    compilerVersion: "rebuild",
                    canonicalSourceSHA256: canonicalSHA))
            }
        }
        try writeRegistry(entries)
    }

    private static func readManifest(in package: URL) throws -> [String: Any] {
        let url = package.appendingPathComponent("manifest.json")
        let data = try Data(contentsOf: url)
        guard let object = try? StrictJSONDocumentParser.object(
            from: data,
            limits: StrictJSONDocumentLimits(maximumBytes: data.count + 1)) as? [String: Any]
        else { throw LibraryError.registryCorrupt(url.path) }
        return object
    }

    // MARK: - File durability

    static func syncFile(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        fsync(descriptor)
    }

    static func syncDirectory(_ directory: URL) throws {
        let descriptor = open(directory.path, O_RDONLY)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        fsync(descriptor)
    }
}
