import Foundation
import Darwin

/// Durable on-device prior-map library (V1R1 Gate A / Gate C, hardened
/// by V1R4 §14.2: serial actor + generation CAS + immutable packages).
///
/// Layout (mirrors the PC `Maps` contract):
/// ```
/// Application Support/MarketScanner/Maps/
///   staging/<task>/          # compile staging directory
///   packages/<prior-map-id>/<package-sha>/   # immutable compiled package
///   registry.json            # durable index (generation CAS-updated)
/// ```
///
/// V1R4 §14.2 contract:
/// - registry mutations run under a serializing lock and follow
///   read generation → build next registry → temp+fsync → compare
///   generation → atomic replace/create → fsync parent;
/// - the first registry is created with rename, never by fabricating a
///   `replaceItemAt` target;
/// - ids/SHAs are validated (safe identifier / 64-lowercase-hex SHA);
/// - stored package paths must be exactly `<id>/<sha>` and stay
///   contained under the packages root without symlink components;
/// - register/list/map re-verify the package manifest/digest;
/// - registered packages are frozen immutable (chmod 555/444);
/// - rebuild derives `floorCount` from the REAL manifest floors;
/// - fsync failures throw (never silently ignored).
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
        case packageNotContained(String)
        case unsafeIdentifier(String)
        case packageVerificationFailed(String)
        case cannotMakeImmutable(String)
        case cannotSync(String)
        case registryGenerationConflict(expected: Int, actual: Int)

        var errorDescription: String? {
            switch self {
            case .cannotCreateRoot(let d): return "无法创建地图库目录：\(d)"
            case .registryCorrupt(let d): return "地图注册表损坏：\(d)"
            case .notRegistered(let d): return "地图未注册：\(d)"
            case .packageMissing(let d): return "地图包缺失：\(d)"
            case .cannotWriteRegistry(let d): return "注册表写入失败：\(d)"
            case .packageNotContained(let d): return "地图包越界或含符号链接：\(d)"
            case .unsafeIdentifier(let d): return "不安全的地图标识：\(d)"
            case .packageVerificationFailed(let d): return "地图包验证失败：\(d)"
            case .cannotMakeImmutable(let d): return "地图包置为只读失败：\(d)"
            case .cannotSync(let d): return "文件同步失败：\(d)"
            case .registryGenerationConflict(let expected, let actual):
                return "注册表代际冲突：期望 \(expected) 实际 \(actual)"
            }
        }
    }

    static let registryFileName = "registry.json"
    static let currentRegistryVersion = 2

    /// Test/embedding hook: when set, `root()` returns this directory
    /// instead of the Application Support location. The host suite uses
    /// it to keep runs inside a temporary directory.
    static var rootOverride: URL?

    /// Serializes every registry mutation (§14.2 serial actor). All
    /// read-modify-write cycles run under this lock; the generation CAS
    /// inside `writeRegistry` additionally guards against external
    /// writers (crash recovery, another process).
    private static let libraryLock = NSLock()

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

    /// §14.2: identity safety is enforced at the boundary; a caller may
    /// only ever address `<safe-id>/<sha256>` package paths.
    static func packageDirectory(priorMapID: String, packageSHA: String) throws -> URL {
        guard isSafeIdentifier(priorMapID) else {
            throw LibraryError.unsafeIdentifier(priorMapID)
        }
        guard isSHA256(packageSHA) else {
            throw LibraryError.unsafeIdentifier(packageSHA)
        }
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
    /// `packages/<prior-map-id>/<package-sha>/`; this function re-verifies
    /// the full package manifest/digest, freezes it immutable and then
    /// updates the durable index through the generation CAS
    /// (read generation → build next registry → temp+fsync → compare →
    /// atomic replace/create → fsync parent).
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
        libraryLock.lock()
        defer { libraryLock.unlock() }

        // §14.2: safe identity — anything else is rejected before any
        // filesystem mutation.
        guard isSafeIdentifier(priorMapID) else {
            throw LibraryError.unsafeIdentifier(priorMapID)
        }
        guard isSHA256(packageSHA256) else {
            throw LibraryError.unsafeIdentifier(packageSHA256)
        }

        // §14.2: register re-verifies the package manifest and digest;
        // a corrupt package must never enter the library.
        _ = try verifyPackage(
            at: packageURL,
            priorMapID: priorMapID,
            packageSHA256: packageSHA256,
            expectedFloorCount: floorCount,
            expectedElementCount: elementCount)

        // §14.2: a registered package is immutable. A failed chmod
        // aborts registration before the registry is touched.
        try makeImmutable(at: packageURL)

        // read generation → build next registry → temp+fsync → compare →
        // atomic replace/create → fsync parent.
        let payload = try readRegistryPayload()
        // Same (id, sha) re-registration is idempotent; a different sha
        // for the same id supersedes the old entry (never duplicates).
        var entries = payload.entries
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
        try writeRegistry(entries, expectedGeneration: payload.generation)
        return entry
    }

    /// Removes a map from the durable index (package bytes are kept so a
    /// re-registration never needs a re-compile).
    static func unregister(priorMapID: String, packageSHA256: String? = nil) throws {
        libraryLock.lock()
        defer { libraryLock.unlock() }
        let payload = try readRegistryPayload()
        var entries = payload.entries
        if let packageSHA256 = packageSHA256 {
            entries.removeAll {
                $0.priorMapID == priorMapID && $0.packageSHA256 == packageSHA256
            }
        } else {
            entries.removeAll { $0.priorMapID == priorMapID }
        }
        try writeRegistry(entries, expectedGeneration: payload.generation)
    }

    // MARK: - Package verification

    /// §14.2 shared re-validation used by `register`, `map` and the
    /// import chain's existing-target reuse: containment (no symlink
    /// escape) + full package manifest/digest + identity and (when
    /// given) floor/element counts. Returns the validated digest.
    static func verifyPackage(
        at packageURL: URL,
        priorMapID: String,
        packageSHA256: String,
        expectedFloorCount: Int? = nil,
        expectedElementCount: Int? = nil
    ) throws -> String {
        try verifyContainment(at: packageURL, under: packagesRoot())
        let digest: String
        do {
            digest = try PriorMapPackageIntegrity.validate(directory: packageURL)
        } catch {
            throw LibraryError.packageVerificationFailed("\(error)")
        }
        guard digest == packageSHA256 else {
            throw LibraryError.packageVerificationFailed(
                "digest \(String(digest.prefix(16)))… != \(String(packageSHA256.prefix(16)))…")
        }
        let manifest = try readManifest(in: packageURL)
        guard manifest["prior_map_id"] as? String == priorMapID else {
            throw LibraryError.packageVerificationFailed("manifest prior_map_id 不匹配")
        }
        if let expectedFloorCount = expectedFloorCount {
            guard (manifest["floors"] as? [[String: Any]])?.count == expectedFloorCount else {
                throw LibraryError.packageVerificationFailed("manifest floor 数量不匹配")
            }
        }
        if let expectedElementCount = expectedElementCount {
            guard StrictJSONScalar.integer(manifest["element_count"]) == expectedElementCount else {
                throw LibraryError.packageVerificationFailed("manifest element_count 不匹配")
            }
        }
        return digest
    }

    /// Fast per-entry re-check used by `listMaps()`: the package
    /// directory exists, stays contained, and its `package_manifest.json`
    /// digest matches the registry entry (manifest identity too).
    private static func quickVerifyPackage(_ entry: MapEntry) throws -> String {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: entry.packageDirectory.path, isDirectory: &isDirectory),
            isDirectory.boolValue else {
            throw LibraryError.packageMissing(entry.packageDirectory.path)
        }
        try verifyContainment(at: entry.packageDirectory, under: packagesRoot())
        let packageManifestURL = entry.packageDirectory.appendingPathComponent(
            MobilePackageManifestBuilder.manifestFileName)
        let data = try Data(contentsOf: packageManifestURL)
        guard let object = try? StrictJSONDocumentParser.object(
            from: data,
            limits: StrictJSONDocumentLimits(maximumBytes: data.count + 1)) as? [String: Any],
            let packageSHA = object["package_sha256"] as? String,
            packageSHA == entry.packageSHA256 else {
            throw LibraryError.packageVerificationFailed(
                "\(entry.packageDirectory.lastPathComponent) package digest 不匹配")
        }
        let manifestData = try Data(contentsOf: entry.packageDirectory.appendingPathComponent("manifest.json"))
        guard let manifest = try? StrictJSONDocumentParser.object(
            from: manifestData,
            limits: StrictJSONDocumentLimits(maximumBytes: manifestData.count + 1)) as? [String: Any],
            manifest["prior_map_id"] as? String == entry.priorMapID,
            (manifest["floors"] as? [[String: Any]])?.isEmpty == false else {
            throw LibraryError.packageVerificationFailed(
                "\(entry.packageDirectory.lastPathComponent) manifest.json 无效")
        }
        return packageSHA
    }

    // MARK: - Queries

    static func listMaps() throws -> [MapEntry] {
        libraryLock.lock()
        defer { libraryLock.unlock() }
        // §14.2: every listed map is re-verified against its package
        // manifest/digest; a missing or corrupt package is dropped from
        // the reported list (the registry itself is untouched).
        return try readRegistryPayload().entries.filter { entry in
            guard let digest = try? quickVerifyPackage(entry) else { return false }
            return digest == entry.packageSHA256
        }.sorted { $0.compiledAtUTC > $1.compiledAtUTC }
    }

    static func map(priorMapID: String, packageSHA256: String) throws -> MapEntry {
        libraryLock.lock()
        defer { libraryLock.unlock() }
        guard isSafeIdentifier(priorMapID), isSHA256(packageSHA256) else {
            throw LibraryError.unsafeIdentifier("\(priorMapID)/\(packageSHA256)")
        }
        guard let entry = try readRegistryPayload().entries.first(where: {
            $0.priorMapID == priorMapID && $0.packageSHA256 == packageSHA256
        }) else {
            throw LibraryError.notRegistered("\(priorMapID)/\(packageSHA256)")
        }
        // §14.2: mapping re-validates the full package manifest/digest.
        _ = try verifyPackage(
            at: entry.packageDirectory,
            priorMapID: priorMapID,
            packageSHA256: packageSHA256)
        return entry
    }

    // MARK: - Registry IO (generation CAS)

    private static func readRegistryPayload() throws -> (entries: [MapEntry], generation: Int) {
        let url = try registryURL()
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else {
            // A missing registry is generation 0 (first write uses the
            // rename path, never replaceItemAt on a non-existent target).
            return ([], 0)
        }
        let data = try Data(contentsOf: url)
        guard let object = try? StrictJSONDocumentParser.object(
            from: data,
            limits: StrictJSONDocumentLimits(maximumBytes: data.count + 1)) as? [String: Any],
            let version = StrictJSONScalar.integer(object["version"]),
            version == currentRegistryVersion,
            let entries = object["maps"] as? [[String: Any]]
        else {
            throw LibraryError.registryCorrupt(url.path)
        }
        // Legacy v2 registries have no generation field; treat them as 0.
        let generation = StrictJSONScalar.integer(object["generation"]) ?? 0
        let packagesRoot = try packagesRoot()
        var result: [MapEntry] = []
        for raw in entries {
            guard let priorMapID = raw["prior_map_id"] as? String,
                  isSafeIdentifier(priorMapID),
                  let packageSHA256 = raw["package_sha256"] as? String,
                  isSHA256(packageSHA256),
                  let packageDirName = raw["package_directory"] as? String,
                  // §14.2: the stored path must be exactly `<id>/<sha>`;
                  // anything else (escape, mismatch) is dropped.
                  packageDirName == "\(priorMapID)/\(packageSHA256)",
                  let name = raw["name"] as? String,
                  let floorCount = StrictJSONScalar.integer(raw["floor_count"]),
                  let elementCount = StrictJSONScalar.integer(raw["element_count"]),
                  let compiledAtUTC = raw["compiled_at_utc"] as? Double,
                  let compilerVersion = raw["compiler_version"] as? String,
                  let canonicalSHA = raw["canonical_source_sha256"] as? String
            else { continue }
            // Rebuild the URL from the validated identity instead of
            // trusting the stored relative path.
            result.append(MapEntry(
                priorMapID: priorMapID,
                name: name,
                packageSHA256: packageSHA256,
                packageDirectory: packagesRoot
                    .appendingPathComponent(priorMapID, isDirectory: true)
                    .appendingPathComponent(packageSHA256, isDirectory: true),
                floorCount: floorCount,
                elementCount: elementCount,
                compiledAtUTC: compiledAtUTC,
                compilerVersion: compilerVersion,
                canonicalSourceSHA256: canonicalSHA))
        }
        return (result, generation)
    }

    /// Writes the next registry through the §14.2 CAS:
    /// temp + fsync → compare generation → atomic replace/create →
    /// fsync parent. The caller holds `libraryLock`; a generation
    /// mismatch means an external writer changed the registry, which
    /// fails closed.
    private static func writeRegistry(
        _ entries: [MapEntry],
        expectedGeneration: Int
    ) throws {
        let url = try registryURL()
        let nextGeneration = expectedGeneration + 1
        let payload: [String: Any] = [
            "format": "MarketScannerMapRegistry",
            "version": currentRegistryVersion,
            "generation": nextGeneration,
            "map_count": entries.count,
            "maps": entries.map { $0.manifestPayload },
        ]
        let data: Data
        do {
            data = try CanonicalJSONEncoder.encode(payload)
        } catch {
            throw LibraryError.cannotWriteRegistry("\(error)")
        }
        let directory = url.deletingLastPathComponent()
        let temp = directory.appendingPathComponent(".\(registryFileName).tmp-\(UUID().uuidString)")
        do {
            try data.write(to: temp)
            try syncFile(temp)
            // Compare generation right before the commit. Under the
            // serializing lock this can only differ if an external
            // writer (or a crash-recovery sequence) touched the file.
            let current = try readDiskGeneration()
            guard current == expectedGeneration else {
                try? FileManager.default.removeItem(at: temp)
                throw LibraryError.registryGenerationConflict(
                    expected: expectedGeneration, actual: current)
            }
            let fileManager = FileManager.default
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.replaceItemAt(
                    url, withItemAt: temp,
                    backupItemName: nil, options: [])
            } else {
                // §14.2: the first registry is created with rename;
                // replaceItemAt must not fabricate a missing target.
                try fileManager.moveItem(at: temp, to: url)
            }
            try syncDirectory(directory)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            if let libraryError = error as? LibraryError {
                throw libraryError
            }
            throw LibraryError.cannotWriteRegistry("\(error)")
        }
    }

    private static func readDiskGeneration() throws -> Int {
        let url = try registryURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
        let data = try Data(contentsOf: url)
        guard let object = try? StrictJSONDocumentParser.object(
            from: data,
            limits: StrictJSONDocumentLimits(maximumBytes: data.count + 1)) as? [String: Any]
        else {
            throw LibraryError.registryCorrupt(url.path)
        }
        return StrictJSONScalar.integer(object["generation"]) ?? 0
    }

    // MARK: - Rebuild

    /// Rebuilds the registry by scanning `packages/`. Used when the index
    /// is corrupt; package manifests are the source of truth. §14.2: the
    /// floor count is derived from the REAL manifest floors array (never
    /// a cached/absent field), ids/SHAs are validated, symlinked or
    /// unverifiable packages are skipped.
    static func rebuildRegistry() throws {
        libraryLock.lock()
        defer { libraryLock.unlock() }
        let root = try packagesRoot()
        let fileManager = FileManager.default
        var entries: [MapEntry] = []
        let ids = try fileManager.contentsOfDirectory(atPath: root.path).sorted()
        for priorMapID in ids {
            guard isSafeIdentifier(priorMapID) else { continue }
            let idDir = root.appendingPathComponent(priorMapID)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: idDir.path, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  (try? fileManager.attributesOfItem(atPath: idDir.path)[.type] as? FileAttributeType) == .typeDirectory
            else { continue }
            let shas = try fileManager.contentsOfDirectory(atPath: idDir.path).sorted()
            for sha in shas {
                guard isSHA256(sha) else { continue }
                let package = idDir.appendingPathComponent(sha)
                var isPackage: ObjCBool = false
                guard fileManager.fileExists(atPath: package.path, isDirectory: &isPackage),
                      isPackage.boolValue,
                      (try? fileManager.attributesOfItem(atPath: package.path)[.type] as? FileAttributeType) == .typeDirectory
                else { continue }
                guard let manifest = try? readManifest(in: package) else { continue }
                guard let name = manifest["name"] as? String,
                      let floors = manifest["floors"] as? [[String: Any]],
                      let elementCount = StrictJSONScalar.integer(manifest["element_count"]),
                      let canonicalSHA = manifest["canonical_source_sha256"] as? String,
                      manifest["prior_map_id"] as? String == priorMapID
                else { continue }
                // §14.2: floorCount comes from the REAL manifest floors.
                entries.append(MapEntry(
                    priorMapID: priorMapID,
                    name: name,
                    packageSHA256: sha,
                    packageDirectory: package,
                    floorCount: floors.count,
                    elementCount: elementCount,
                    compiledAtUTC: 0,
                    compilerVersion: "rebuild",
                    canonicalSourceSHA256: canonicalSHA))
            }
        }
        let payload = try readRegistryPayload()
        try writeRegistry(entries, expectedGeneration: payload.generation)
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

    // MARK: - Safety

    /// §14.2 safe prior-map ID: non-empty, bounded, `[a-z0-9._-]` only.
    static func isSafeIdentifier(_ value: String, maximumLength: Int = 128) -> Bool {
        guard !value.isEmpty, value.unicodeScalars.count <= maximumLength else {
            return false
        }
        for scalar in value.unicodeScalars {
            let allowed = (scalar.value >= 0x30 && scalar.value <= 0x39)
                || (scalar.value >= 0x61 && scalar.value <= 0x7A)
                || scalar.value == 0x2D || scalar.value == 0x5F || scalar.value == 0x2E
            guard allowed else { return false }
        }
        return true
    }

    /// §14.2 package SHA: exactly 64 lowercase hex characters.
    static func isSHA256(_ value: String) -> Bool {
        guard value.unicodeScalars.count == 64 else { return false }
        for scalar in value.unicodeScalars {
            let allowed = (scalar.value >= 0x30 && scalar.value <= 0x39)
                || (scalar.value >= 0x61 && scalar.value <= 0x66)
            guard allowed else { return false }
        }
        return true
    }

    /// §14.2 containment/no symlink: the resolved path of `url` must
    /// live strictly below the resolved `root`, and every path component
    /// between them must be a real directory (a symlink component is
    /// rejected).
    static func verifyContainment(at url: URL, under root: URL) throws {
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        let urlPath = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard urlPath.hasPrefix(rootPath + "/") else {
            throw LibraryError.packageNotContained(url.path)
        }
        var probe = URL(fileURLWithPath: rootPath)
        for component in urlPath.dropFirst(rootPath.count + 1).split(separator: "/") {
            probe.appendPathComponent(String(component))
            let attributes = try? FileManager.default.attributesOfItem(atPath: probe.path)
            guard let type = attributes?[.type] as? FileAttributeType,
                  type == .typeDirectory else {
                throw LibraryError.packageNotContained(url.path)
            }
        }
    }

    // MARK: - Immutability

    /// §14.2: freezes a registered package — files 0o444, directories
    /// 0o555, recursive. Any chmod failure aborts registration.
    static func makeImmutable(at root: URL) throws {
        var directories: [URL] = [root]
        if let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []) {
            for case let url as URL in enumerator {
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
                if values?.isDirectory == true {
                    directories.append(url)
                } else {
                    try setPermissions(0o444, on: url)
                }
            }
        }
        // Directories deepest-first so a parent write-bit removal never
        // blocks chmodding its children.
        for url in directories.reversed() {
            try setPermissions(0o555, on: url)
        }
    }

    private static func setPermissions(_ mode: mode_t, on url: URL) throws {
        guard chmod(url.path, mode) == 0 else {
            throw LibraryError.cannotMakeImmutable(url.path)
        }
    }

    // MARK: - File durability

    /// §14.2: fsync failures THROW; a silently ignored sync would let a
    /// crash lose a committed registry update.
    static func syncFile(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else {
            throw LibraryError.cannotSync(url.path)
        }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw LibraryError.cannotSync(url.path)
        }
    }

    static func syncDirectory(_ directory: URL) throws {
        let descriptor = open(directory.path, O_RDONLY)
        guard descriptor >= 0 else {
            throw LibraryError.cannotSync(directory.path)
        }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw LibraryError.cannotSync(directory.path)
        }
    }
}
