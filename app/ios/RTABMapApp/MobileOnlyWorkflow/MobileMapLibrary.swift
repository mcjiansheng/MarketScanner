import Foundation
import Darwin
import CryptoKit

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
/// - one prior-map ID may retain multiple immutable SHA versions; callers
///   must always select the exact `(priorMapID, packageSHA256)` identity;
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
    static let quarantineDiagnosticFileName = "quarantine_diagnostic.json"
    private static let quarantineDiagnosticFormat =
        "MarketScannerMapQuarantineDiagnostic"
    private static let quarantineDiagnosticVersion = 2
    private static let maximumQuarantineDiagnosticBytes = 64 * 1024
    private static let maximumQuarantinePayloadEntries = 256
    private static let maximumQuarantinePayloadFileBytes: Int64 =
        512 * 1024 * 1024
    private static let maximumQuarantinePayloadTotalBytes: Int64 =
        1024 * 1024 * 1024

    enum QuarantineFaultPoint {
        case afterPayloadRename
        case afterDiagnosticPlacementAndFreeze
        case afterPublishRenameAndParentSync
    }

    /// Host-only fault injection for the quarantine transaction. Production
    /// leaves this nil; tests use thrown errors for rollback checks and a
    /// child process `_exit` for the three real crash windows.
    static var quarantineFaultInjector: ((QuarantineFaultPoint) throws -> Void)?

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
        try recoverQuarantineTransactionsLocked()

        // §14.2: safe identity — anything else is rejected before any
        // filesystem mutation.
        guard isSafeIdentifier(priorMapID) else {
            throw LibraryError.unsafeIdentifier(priorMapID)
        }
        guard isSHA256(packageSHA256) else {
            throw LibraryError.unsafeIdentifier(packageSHA256)
        }
        guard isSHA256(canonicalSourceSHA256) else {
            throw LibraryError.unsafeIdentifier(canonicalSourceSHA256)
        }

        // V1R5 §13.4 (review H-08): the registered package URL must be
        // EXACTLY `packages/<priorMapID>/<packageSHA256>` — a package
        // stored anywhere else (even inside the root) would make the
        // registry point at a directory the identity does not imply.
        guard packageURL.lastPathComponent == packageSHA256,
              packageURL.deletingLastPathComponent().lastPathComponent
                == priorMapID else {
            throw LibraryError.packageNotContained(packageURL.path)
        }

        // §14.2: register re-verifies the package manifest and digest;
        // a corrupt package must never enter the library.
        _ = try verifyPackage(
            at: packageURL,
            priorMapID: priorMapID,
            packageSHA256: packageSHA256,
            expectedFloorCount: floorCount,
            expectedElementCount: elementCount,
            expectedCanonicalSourceSHA256: canonicalSourceSHA256)

        // §14.2: a registered package is immutable. A failed chmod
        // aborts registration before the registry is touched.
        try makeImmutable(at: packageURL)
        try verifyImmutable(at: packageURL)

        // read generation → build next registry → temp+fsync → compare →
        // atomic replace/create → fsync parent.
        let payload = try readRegistryPayload()
        // Version policy: same (id, sha) re-registration is idempotent;
        // a different SHA for the same map ID remains a separately
        // addressable immutable version. Selection is always exact-SHA.
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
        try recoverQuarantineTransactionsLocked()
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
        expectedElementCount: Int? = nil,
        expectedCanonicalSourceSHA256: String? = nil
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
        guard let canonicalSourceSHA256 = manifest["canonical_source_sha256"] as? String,
              isSHA256(canonicalSourceSHA256) else {
            throw LibraryError.packageVerificationFailed(
                "manifest canonical_source_sha256 无效")
        }
        if let expectedCanonicalSourceSHA256 = expectedCanonicalSourceSHA256 {
            guard canonicalSourceSHA256 == expectedCanonicalSourceSHA256 else {
                throw LibraryError.packageVerificationFailed(
                    "manifest canonical_source_sha256 不匹配")
            }
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

    /// Full per-entry re-check used by `listMaps()`. A self-declared hash
    /// from package_manifest.json is not evidence: recompute every
    /// artifact digest, cross-file relation, identity/count and mode.
    private static func quickVerifyPackage(_ entry: MapEntry) throws -> String {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: entry.packageDirectory.path, isDirectory: &isDirectory),
            isDirectory.boolValue else {
            throw LibraryError.packageMissing(entry.packageDirectory.path)
        }
        let digest = try verifyPackage(
            at: entry.packageDirectory,
            priorMapID: entry.priorMapID,
            packageSHA256: entry.packageSHA256,
            expectedFloorCount: entry.floorCount,
            expectedElementCount: entry.elementCount,
            expectedCanonicalSourceSHA256: entry.canonicalSourceSHA256)
        try verifyImmutable(at: entry.packageDirectory)
        return digest
    }

    // MARK: - Queries

    static func listMaps() throws -> [MapEntry] {
        libraryLock.lock()
        defer { libraryLock.unlock() }
        try recoverQuarantineTransactionsLocked()
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
        try recoverQuarantineTransactionsLocked()
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
            packageSHA256: packageSHA256,
            expectedFloorCount: entry.floorCount,
            expectedElementCount: entry.elementCount,
            expectedCanonicalSourceSHA256: entry.canonicalSourceSHA256)
        try verifyImmutable(at: entry.packageDirectory)
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
            object["format"] as? String == "MarketScannerMapRegistry",
            let version = StrictJSONScalar.integer(object["version"]),
            version == currentRegistryVersion,
            let entries = object["maps"] as? [[String: Any]],
            let generation = StrictJSONScalar.integer(object["generation"]),
            generation >= 0,
            StrictJSONScalar.integer(object["map_count"]) == entries.count
        else {
            throw LibraryError.registryCorrupt(url.path)
        }
        let packagesRoot = try packagesRoot()
        var result: [MapEntry] = []
        for (index, raw) in entries.enumerated() {
            guard let priorMapID = raw["prior_map_id"] as? String,
                  isSafeIdentifier(priorMapID),
                  let packageSHA256 = raw["package_sha256"] as? String,
                  isSHA256(packageSHA256),
                  let packageDirName = raw["package_directory"] as? String,
                  // §14.2: the stored path must be exactly `<id>/<sha>`;
                  // anything else (escape, mismatch) corrupts the index.
                  packageDirName == "\(priorMapID)/\(packageSHA256)",
                  let name = raw["name"] as? String,
                  MapSourceBusinessIdentityPolicy.isValidMapName(name),
                  let floorCount = StrictJSONScalar.integer(raw["floor_count"]),
                  let elementCount = StrictJSONScalar.integer(raw["element_count"]),
                  floorCount > 0, elementCount >= 0,
                  let compiledAtUTC = StrictJSONScalar.number(raw["compiled_at_utc"]),
                  compiledAtUTC.isFinite,
                  let compilerVersion = raw["compiler_version"] as? String,
                  let canonicalSHA = raw["canonical_source_sha256"] as? String,
                  isSHA256(canonicalSHA)
            else {
                // V1R5 §13.4 (review H-10): a persistent identity index
                // never drops entries silently — one corrupt entry marks
                // the whole registry corrupt and asks for a rebuild.
                throw LibraryError.registryCorrupt(
                    "\(url.path): entry \(index) invalid")
            }
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
        guard object["format"] as? String == "MarketScannerMapRegistry",
              StrictJSONScalar.integer(object["version"]) == currentRegistryVersion,
              let generation = StrictJSONScalar.integer(object["generation"]),
              generation >= 0 else {
            throw LibraryError.registryCorrupt("\(url.path): generation missing or invalid")
        }
        return generation
    }

    // MARK: - Rebuild

    /// Rebuilds the registry by scanning `packages/`. Used when the index
    /// is corrupt; package manifests are the source of truth. §14.2: the
    /// floor count is derived from the REAL manifest floors array (never
    /// a cached/absent field). Every candidate is full-verified against
    /// its package digest, identity and counts, frozen/verified immutable,
    /// and invalid valid-identity packages are moved to quarantine.
    static func rebuildRegistry() throws {
        libraryLock.lock()
        defer { libraryLock.unlock() }
        try recoverQuarantineTransactionsLocked()
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
                do {
                    let manifest = try readManifest(in: package)
                    guard let name = manifest["name"] as? String,
                          MapSourceBusinessIdentityPolicy.isValidMapName(name),
                          let storeID = manifest["store_id"] as? String,
                          MapSourceBusinessIdentityPolicy.isValidStoreID(storeID),
                          let floors = manifest["floors"] as? [[String: Any]],
                          !floors.isEmpty,
                          let elementCount = StrictJSONScalar.integer(
                            manifest["element_count"]),
                          elementCount >= 0,
                          let canonicalSHA = manifest["canonical_source_sha256"] as? String,
                          isSHA256(canonicalSHA),
                          manifest["prior_map_id"] as? String == priorMapID else {
                        throw LibraryError.packageVerificationFailed(
                            "manifest identity/counts invalid")
                    }
                    _ = try verifyPackage(
                        at: package,
                        priorMapID: priorMapID,
                        packageSHA256: sha,
                        expectedFloorCount: floors.count,
                        expectedElementCount: elementCount,
                        expectedCanonicalSourceSHA256: canonicalSHA)
                    try makeImmutable(at: package)
                    try verifyImmutable(at: package)
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
                } catch {
                    let validationError = error
                    try quarantinePackage(
                        package,
                        priorMapID: priorMapID,
                        packageSHA256: sha,
                        validationError: validationError)
                }
            }
        }
        // A corrupt maps array can be rebuilt if (and only if) its durable
        // generation is still valid. Missing/illegal generation never
        // defaults to zero and is not overwritten silently.
        let expectedGeneration = try readDiskGeneration()
        try writeRegistry(entries, expectedGeneration: expectedGeneration)
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
        // V1R5 §13.4 (review H-09): the V1R4 check walked the RESOLVED
        // path, so an original symlink component had already vanished and
        // could never be detected. Walk the ORIGINAL path components with
        // `attributesOfItem` (lstat semantics — a symlink reports
        // `.typeSymbolicLink`, never the target's directory type) and
        // reject ANY symlink component before the containment check.
        var rawProbe = URL(fileURLWithPath: root.resolvingSymlinksInPath()
            .standardizedFileURL.path)
        for component in url.standardizedFileURL.path
            .dropFirst(rootPath.count + 1).split(separator: "/") {
            rawProbe.appendPathComponent(String(component))
            let attributes = try? FileManager.default
                .attributesOfItem(atPath: rawProbe.path)
            guard let type = attributes?[.type] as? FileAttributeType else {
                throw LibraryError.packageNotContained(url.path)
            }
            guard type == .typeDirectory else {
                // A symlink (or non-directory) component anywhere on the
                // path is an escape/swap vector: reject fail-closed.
                throw LibraryError.packageNotContained(url.path)
            }
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

    /// Verifies the exact immutable mode/type contract after chmod and on
    /// every list/map/rebuild path. Prior-map packages are flat: any
    /// nested directory, symlink or non-regular artifact is invalid.
    static func verifyImmutable(at root: URL) throws {
        let rootAttributes = try FileManager.default.attributesOfItem(
            atPath: root.path)
        guard rootAttributes[.type] as? FileAttributeType == .typeDirectory,
              let rootMode = rootAttributes[.posixPermissions] as? NSNumber,
              rootMode.intValue & 0o777 == 0o555 else {
            throw LibraryError.cannotMakeImmutable(
                "\(root.path): directory mode/type is not 0555")
        }
        let children = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [])
        for child in children {
            let attributes = try FileManager.default.attributesOfItem(
                atPath: child.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  let mode = attributes[.posixPermissions] as? NSNumber,
                  mode.intValue & 0o777 == 0o444 else {
                throw LibraryError.cannotMakeImmutable(
                    "\(child.path): artifact mode/type is not regular 0444")
            }
        }
    }

    private struct QuarantineDiagnostic {
        let transactionID: String
        let priorMapID: String
        let packageSHA256: String
        let sourceURL: URL
        let sourceMode: mode_t
        let destinationURL: URL
        let payloadTreeSHA256: String
    }

    private struct QuarantineRecoveryGroup {
        var pending: URL?
        var diagnosticTemporary: URL?
        var published: URL?
    }

    /// Reconciles every durable quarantine transaction while the caller holds
    /// `libraryLock`. This runs before registration, listing, loading and
    /// rebuild so a crash cannot strand a production package under a hidden
    /// name forever. The state machine accepts only these atomic-rename states:
    ///
    /// - source + `.diagnostic.tmp`: the payload rename did not commit; remove
    ///   the verified temporary diagnostic and keep the source;
    /// - `.pending` + `.diagnostic.tmp`: finish diagnostic placement/freeze;
    /// - `.pending` + embedded diagnostic: verify/freeze and publish;
    /// - final quarantine directory: verify and complete every parent fsync.
    ///
    /// Missing payloads, duplicate phase artifacts, unknown names, symlinks,
    /// hard links, non-canonical diagnostics or identity/path/hash conflicts
    /// fail closed. Recovery never guesses which bytes should win.
    private static func recoverQuarantineTransactionsLocked() throws {
        let mapRoot = try root()
        try requireRealDirectory(mapRoot, context: "map library root")
        let quarantineBase = mapRoot.appendingPathComponent(
            "quarantine", isDirectory: true)
        var baseStat = stat()
        if lstat(quarantineBase.path, &baseStat) != 0 {
            if errno == ENOENT { return }
            throw LibraryError.packageVerificationFailed(
                "cannot inspect quarantine root: "
                    + String(cString: strerror(errno)))
        }
        guard (baseStat.st_mode & S_IFMT) == S_IFDIR else {
            throw LibraryError.packageVerificationFailed(
                "quarantine root is not a real directory")
        }

        let idNames = try FileManager.default.contentsOfDirectory(
            atPath: quarantineBase.path).sorted()
        for priorMapID in idNames {
            guard isSafeIdentifier(priorMapID) else {
                throw LibraryError.packageVerificationFailed(
                    "unknown quarantine root entry: \(priorMapID)")
            }
            let quarantineRoot = quarantineBase.appendingPathComponent(
                priorMapID, isDirectory: true)
            try requireRealDirectory(quarantineRoot, context: "quarantine map root")
            var groups: [String: QuarantineRecoveryGroup] = [:]
            let names = try FileManager.default.contentsOfDirectory(
                atPath: quarantineRoot.path).sorted()
            for name in names {
                let transactionID: String
                enum ArtifactKind { case pending, temporary, published }
                let kind: ArtifactKind
                if name.hasPrefix("."), name.hasSuffix(".pending") {
                    transactionID = String(name.dropFirst().dropLast(".pending".count))
                    kind = .pending
                } else if name.hasPrefix("."),
                          name.hasSuffix(".diagnostic.tmp") {
                    transactionID = String(
                        name.dropFirst().dropLast(".diagnostic.tmp".count))
                    kind = .temporary
                } else {
                    transactionID = name
                    kind = .published
                }
                guard quarantinePackageSHA(
                    transactionID: transactionID) != nil else {
                    throw LibraryError.packageVerificationFailed(
                        "unknown quarantine transaction entry: \(name)")
                }
                var group = groups[transactionID] ?? QuarantineRecoveryGroup()
                let url = quarantineRoot.appendingPathComponent(
                    name, isDirectory: kind != .temporary)
                switch kind {
                case .pending:
                    guard group.pending == nil else {
                        throw LibraryError.packageVerificationFailed(
                            "duplicate quarantine pending transaction")
                    }
                    try requireRealDirectory(url, context: "quarantine pending")
                    group.pending = url
                case .temporary:
                    guard group.diagnosticTemporary == nil else {
                        throw LibraryError.packageVerificationFailed(
                            "duplicate quarantine diagnostic temporary")
                    }
                    group.diagnosticTemporary = url
                case .published:
                    guard group.published == nil else {
                        throw LibraryError.packageVerificationFailed(
                            "duplicate published quarantine transaction")
                    }
                    try requireRealDirectory(url, context: "published quarantine")
                    group.published = url
                }
                groups[transactionID] = group
            }

            for transactionID in groups.keys.sorted() {
                guard let group = groups[transactionID] else { continue }
                let destination = quarantineRoot.appendingPathComponent(
                    transactionID, isDirectory: true)
                if let published = group.published {
                    guard group.pending == nil,
                          group.diagnosticTemporary == nil,
                          published.path == destination.path else {
                        throw LibraryError.packageVerificationFailed(
                            "conflicting published quarantine transaction \(transactionID)")
                    }
                    let diagnostic = try readQuarantineDiagnostic(
                        at: published.appendingPathComponent(
                            quarantineDiagnosticFileName),
                        transactionID: transactionID,
                        priorMapID: priorMapID,
                        quarantineRoot: quarantineRoot)
                    try requireMissing(
                        diagnostic.sourceURL,
                        context: "quarantine source and published payload both exist")
                    try verifyPublishedQuarantine(
                        published, diagnostic: diagnostic)
                    try syncQuarantineTree(published)
                    try syncDirectory(diagnostic.sourceURL.deletingLastPathComponent())
                    try syncDirectory(quarantineRoot)
                    try syncDirectory(quarantineBase)
                    try syncDirectory(mapRoot)
                    continue
                }

                if let pending = group.pending {
                    var diagnostic: QuarantineDiagnostic
                    let embeddedDiagnostic = pending.appendingPathComponent(
                        quarantineDiagnosticFileName)
                    var embeddedStat = stat()
                    let embeddedExists = lstat(
                        embeddedDiagnostic.path, &embeddedStat) == 0
                    if let temporary = group.diagnosticTemporary {
                        guard !embeddedExists else {
                            throw LibraryError.packageVerificationFailed(
                                "quarantine diagnostic exists in two phases")
                        }
                        diagnostic = try readQuarantineDiagnostic(
                            at: temporary,
                            transactionID: transactionID,
                            priorMapID: priorMapID,
                            quarantineRoot: quarantineRoot)
                        try requireMissing(
                            diagnostic.sourceURL,
                            context: "quarantine source and pending both exist")
                        let actualPayloadSHA = try quarantinePayloadTreeSHA256(
                            at: pending, diagnosticIsEmbedded: false)
                        guard actualPayloadSHA == diagnostic.payloadTreeSHA256 else {
                            throw LibraryError.packageVerificationFailed(
                                "pending quarantine payload hash mismatch")
                        }
                        guard renameatx_np(
                            AT_FDCWD, temporary.path,
                            AT_FDCWD, embeddedDiagnostic.path,
                            UInt32(RENAME_EXCL)) == 0 else {
                            throw LibraryError.packageVerificationFailed(
                                "recovery diagnostic placement failed: "
                                    + String(cString: strerror(errno)))
                        }
                        try syncFileNoFollow(embeddedDiagnostic)
                        try syncDirectory(pending)
                        try syncDirectory(quarantineRoot)
                    } else {
                        guard embeddedExists else {
                            throw LibraryError.packageVerificationFailed(
                                "pending quarantine has no durable diagnostic")
                        }
                        diagnostic = try readQuarantineDiagnostic(
                            at: embeddedDiagnostic,
                            transactionID: transactionID,
                            priorMapID: priorMapID,
                            quarantineRoot: quarantineRoot)
                        try requireMissing(
                            diagnostic.sourceURL,
                            context: "quarantine source and pending both exist")
                    }
                    try makeImmutable(at: pending)
                    try verifyPublishedQuarantine(pending, diagnostic: diagnostic)
                    try syncQuarantineTree(pending)
                    guard renameatx_np(
                        AT_FDCWD, pending.path,
                        AT_FDCWD, destination.path,
                        UInt32(RENAME_EXCL)) == 0 else {
                        throw LibraryError.packageVerificationFailed(
                            "recovery quarantine publish failed: "
                                + String(cString: strerror(errno)))
                    }
                    try syncQuarantineTree(destination)
                    try syncDirectory(diagnostic.sourceURL.deletingLastPathComponent())
                    try syncDirectory(quarantineRoot)
                    try syncDirectory(quarantineBase)
                    try syncDirectory(mapRoot)
                    continue
                }

                guard let temporary = group.diagnosticTemporary else {
                    throw LibraryError.packageVerificationFailed(
                        "empty quarantine transaction \(transactionID)")
                }
                let diagnostic = try readQuarantineDiagnostic(
                    at: temporary,
                    transactionID: transactionID,
                    priorMapID: priorMapID,
                    quarantineRoot: quarantineRoot)
                try requireRealDirectory(
                    diagnostic.sourceURL, context: "quarantine rollback source")
                let actualPayloadSHA = try quarantinePayloadTreeSHA256(
                    at: diagnostic.sourceURL, diagnosticIsEmbedded: false)
                guard actualPayloadSHA == diagnostic.payloadTreeSHA256 else {
                    throw LibraryError.packageVerificationFailed(
                        "quarantine rollback source hash mismatch")
                }
                // A crash may land after the source directory was made
                // writable but before the payload rename. Restore the exact
                // pre-transaction root mode recorded by the diagnostic.
                guard chmod(
                    diagnostic.sourceURL.path, diagnostic.sourceMode) == 0 else {
                    throw LibraryError.cannotMakeImmutable(
                        "cannot restore quarantine source mode")
                }
                try syncDirectory(diagnostic.sourceURL)
                guard unlink(temporary.path) == 0 else {
                    throw LibraryError.packageVerificationFailed(
                        "cannot remove recovered diagnostic temporary: "
                            + String(cString: strerror(errno)))
                }
                try syncDirectory(diagnostic.sourceURL.deletingLastPathComponent())
                try syncDirectory(quarantineRoot)
                try syncDirectory(quarantineBase)
                try syncDirectory(mapRoot)
            }
        }
    }

    /// Moves a valid-identity but invalid package out of the production
    /// package tree. Quarantine is outside `packages/`, so a later rebuild
    /// cannot rediscover the rejected bytes. The payload is first moved to a
    /// hidden pending path, paired with a durable immutable diagnostic, and
    /// only then published under its final quarantine name. A failure before
    /// diagnostic placement rolls back. Later failures intentionally preserve
    /// the fully described pending/final state for startup reconciliation.
    private static func quarantinePackage(
        _ package: URL,
        priorMapID: String,
        packageSHA256: String,
        validationError: Error
    ) throws {
        let mapRoot = try root()
        try requireRealDirectory(mapRoot, context: "map library root")
        let quarantineBase = mapRoot.appendingPathComponent(
            "quarantine", isDirectory: true)
        let quarantineRoot = quarantineBase.appendingPathComponent(
            priorMapID, isDirectory: true)
        // Never let `createDirectory(withIntermediateDirectories:)` follow a
        // pre-positioned quarantine symlink before the transaction writes its
        // diagnostic or renames the payload. Create one component at a time,
        // lstat every existing/created component and durably bind each parent.
        try ensureRealDirectory(
            quarantineBase,
            parent: mapRoot,
            context: "quarantine root")
        try ensureRealDirectory(
            quarantineRoot,
            parent: quarantineBase,
            context: "quarantine map root")
        try syncDirectory(mapRoot)
        try syncDirectory(quarantineBase)
        try syncDirectory(quarantineRoot)
        let quarantineID = "\(packageSHA256)-\(UUID().uuidString.lowercased())"
        let destination = quarantineRoot.appendingPathComponent(
            quarantineID, isDirectory: true)
        let pendingDestination = quarantineRoot.appendingPathComponent(
            ".\(quarantineID).pending", isDirectory: true)
        let diagnosticTemporary = quarantineRoot.appendingPathComponent(
            ".\(quarantineID).diagnostic.tmp")
        let diagnosticURL = pendingDestination.appendingPathComponent(
            quarantineDiagnosticFileName)
        let sourceParent = package.deletingLastPathComponent()

        guard package.path == (try packageDirectory(
            priorMapID: priorMapID, packageSHA: packageSHA256)).path else {
            throw LibraryError.packageNotContained(package.path)
        }

        var packageStat = stat()
        guard lstat(package.path, &packageStat) == 0,
              (packageStat.st_mode & S_IFMT) == S_IFDIR else {
            throw LibraryError.packageVerificationFailed(
                "quarantine source is not a directory")
        }
        let originalMode = mode_t(packageStat.st_mode & 0o777)
        let payloadTreeSHA256 = try quarantinePayloadTreeSHA256(
            at: package, diagnosticIsEmbedded: false)

        // At most 1,024 Unicode scalars is at most 4 KiB in UTF-8 and keeps
        // the diagnostic inside its strict bounded schema without splitting
        // a multi-byte scalar.
        let rawValidatorDetail = validationError.localizedDescription.isEmpty
            ? "unknown package validation failure"
            : validationError.localizedDescription
        let validatorDetail = String(
            rawValidatorDetail.unicodeScalars.prefix(1024))
        let diagnosticPayload: [String: Any] = [
            "format": quarantineDiagnosticFormat,
            "version": quarantineDiagnosticVersion,
            "transaction_id": quarantineID,
            "reason": "package_validation_failed",
            "quarantined_at_unix": Date().timeIntervalSince1970,
            "source_identity": [
                "prior_map_id": priorMapID,
                "package_sha256": packageSHA256,
            ],
            "source_path": package.path,
            "source_mode": Int(originalMode),
            "quarantine_path": destination.path,
            "payload_tree_sha256": payloadTreeSHA256,
            "validator_detail": validatorDetail,
        ]
        let diagnosticData: Data
        do {
            diagnosticData = try CanonicalJSONEncoder.encode(diagnosticPayload)
        } catch {
            throw LibraryError.packageVerificationFailed(
                "cannot encode quarantine diagnostic: \(error)")
        }
        do {
            try writeNewRegularFileDurably(
                diagnosticData, to: diagnosticTemporary)
            try syncDirectory(quarantineRoot)
        } catch {
            try? FileManager.default.removeItem(at: diagnosticTemporary)
            throw error
        }

        var modeChanged = false
        var payloadMoved = false
        var diagnosticMoved = false
        var published = false
        var diagnosticDurable = false
        if (originalMode & mode_t(S_IWUSR)) == 0 {
            guard chmod(package.path, originalMode | mode_t(S_IWUSR)) == 0 else {
                try? FileManager.default.removeItem(at: diagnosticTemporary)
                throw LibraryError.cannotMakeImmutable(package.path)
            }
            modeChanged = true
        }

        func rollback(_ originalError: Error) throws -> Never {
            var failures: [String] = []
            let activeDestination = published ? destination : pendingDestination
            if payloadMoved {
                var canRestorePayload = true
                if chmod(
                    activeDestination.path,
                    originalMode | mode_t(S_IWUSR)) != 0 {
                    failures.append("cannot restore quarantine write mode")
                    canRestorePayload = false
                }
                if diagnosticMoved,
                   unlink(activeDestination.appendingPathComponent(
                        quarantineDiagnosticFileName).path) != 0,
                   errno != ENOENT {
                    failures.append("cannot remove rolled-back diagnostic")
                    canRestorePayload = false
                }
                if canRestorePayload && renameatx_np(
                    AT_FDCWD, activeDestination.path,
                    AT_FDCWD, package.path,
                    UInt32(RENAME_EXCL)) != 0 {
                    failures.append(
                        "cannot restore source package: "
                            + String(cString: strerror(errno)))
                } else if canRestorePayload {
                    payloadMoved = false
                    published = false
                    if chmod(package.path, originalMode) != 0 {
                        failures.append("cannot restore source package mode")
                    }
                }
            } else if modeChanged, chmod(package.path, originalMode) != 0 {
                failures.append("cannot restore source package mode")
            }
            if FileManager.default.fileExists(atPath: diagnosticTemporary.path) {
                do {
                    try FileManager.default.removeItem(at: diagnosticTemporary)
                } catch {
                    failures.append("cannot remove diagnostic temporary file")
                }
            }
            do { try syncDirectory(sourceParent) }
            catch { failures.append("cannot sync source parent after rollback") }
            do { try syncDirectory(quarantineRoot) }
            catch { failures.append("cannot sync quarantine root after rollback") }
            do { try syncDirectory(quarantineBase) }
            catch { failures.append("cannot sync quarantine base after rollback") }
            do { try syncDirectory(mapRoot) }
            catch { failures.append("cannot sync map root after rollback") }

            let suffix = failures.isEmpty
                ? ""
                : "; rollback failures: \(failures.joined(separator: ", "))"
            throw LibraryError.packageVerificationFailed(
                "quarantine transaction failed: \(originalError.localizedDescription)\(suffix)")
        }

        do {
            guard renameatx_np(
                AT_FDCWD, package.path,
                AT_FDCWD, pendingDestination.path,
                UInt32(RENAME_EXCL)) == 0 else {
                throw LibraryError.packageVerificationFailed(
                    "quarantine payload rename failed: "
                        + String(cString: strerror(errno)))
            }
            payloadMoved = true
            try syncDirectory(sourceParent)
            try syncDirectory(quarantineRoot)
            try quarantineFaultInjector?(.afterPayloadRename)

            guard renameatx_np(
                AT_FDCWD, diagnosticTemporary.path,
                AT_FDCWD, diagnosticURL.path,
                UInt32(RENAME_EXCL)) == 0 else {
                throw LibraryError.packageVerificationFailed(
                    "quarantine diagnostic rename failed: "
                        + String(cString: strerror(errno)))
            }
            diagnosticMoved = true
            // From this point onward the state is self-describing: recovery
            // sees the diagnostic either at its old durable temp name or at
            // the embedded rename target. Preserve it instead of attempting
            // a lossy rollback after recursive chmod/fsync has started.
            diagnosticDurable = true
            try makeImmutable(at: pendingDestination)
            let diagnostic = try readQuarantineDiagnostic(
                at: diagnosticURL,
                transactionID: quarantineID,
                priorMapID: priorMapID,
                quarantineRoot: quarantineRoot)
            try verifyPublishedQuarantine(
                pendingDestination, diagnostic: diagnostic)
            try syncQuarantineTree(pendingDestination)
            try syncDirectory(quarantineRoot)
            try quarantineFaultInjector?(.afterDiagnosticPlacementAndFreeze)

            guard renameatx_np(
                AT_FDCWD, pendingDestination.path,
                AT_FDCWD, destination.path,
                UInt32(RENAME_EXCL)) == 0 else {
                throw LibraryError.packageVerificationFailed(
                    "quarantine publish rename failed: "
                        + String(cString: strerror(errno)))
            }
            published = true
            try syncQuarantineTree(destination)
            try syncDirectory(sourceParent)
            try syncDirectory(quarantineRoot)
            try syncDirectory(quarantineBase)
            try syncDirectory(mapRoot)
            try quarantineFaultInjector?(.afterPublishRenameAndParentSync)
        } catch {
            if diagnosticDurable || published {
                if let libraryError = error as? LibraryError {
                    throw libraryError
                }
                throw LibraryError.packageVerificationFailed(
                    "quarantine transaction preserved for recovery: \(error)")
            }
            try rollback(error)
        }
    }

    private static func quarantinePackageSHA(
        transactionID: String
    ) -> String? {
        guard transactionID.count == 101 else { return nil }
        let shaEnd = transactionID.index(
            transactionID.startIndex, offsetBy: 64)
        let sha = String(transactionID[..<shaEnd])
        guard isSHA256(sha), transactionID[shaEnd] == "-" else { return nil }
        let uuidStart = transactionID.index(after: shaEnd)
        guard UUID(uuidString: String(transactionID[uuidStart...])) != nil else {
            return nil
        }
        return sha
    }

    private static func readQuarantineDiagnostic(
        at url: URL,
        transactionID: String,
        priorMapID: String,
        quarantineRoot: URL
    ) throws -> QuarantineDiagnostic {
        let data = try readStableRegularFileNoFollow(
            url, maximumBytes: maximumQuarantineDiagnosticBytes,
            requiredMode: 0o444)
        guard let object = try? StrictJSONDocumentParser.object(
            from: data,
            limits: StrictJSONDocumentLimits(
                maximumBytes: maximumQuarantineDiagnosticBytes))
                as? [String: Any],
              Set(object.keys) == Set([
                "format", "version", "transaction_id", "reason",
                "quarantined_at_unix", "source_identity", "source_path",
                "source_mode", "quarantine_path", "payload_tree_sha256",
                "validator_detail",
              ]),
              object["format"] as? String == quarantineDiagnosticFormat,
              StrictJSONScalar.integer(object["version"])
                == quarantineDiagnosticVersion,
              object["transaction_id"] as? String == transactionID,
              object["reason"] as? String == "package_validation_failed",
              let quarantinedAt = StrictJSONScalar.number(
                object["quarantined_at_unix"]),
              quarantinedAt.isFinite, quarantinedAt > 0,
              let identity = object["source_identity"] as? [String: Any],
              Set(identity.keys) == Set(["prior_map_id", "package_sha256"]),
              identity["prior_map_id"] as? String == priorMapID,
              let packageSHA256 = identity["package_sha256"] as? String,
              packageSHA256 == quarantinePackageSHA(
                transactionID: transactionID),
              let sourcePath = object["source_path"] as? String,
              let sourceModeValue = StrictJSONScalar.integer(
                object["source_mode"]),
              sourceModeValue >= 0, sourceModeValue <= 0o777,
              let quarantinePath = object["quarantine_path"] as? String,
              let payloadTreeSHA256 = object["payload_tree_sha256"] as? String,
              isSHA256(payloadTreeSHA256),
              let validatorDetail = object["validator_detail"] as? String,
              !validatorDetail.isEmpty,
              validatorDetail.utf8.count <= 4096 else {
            throw LibraryError.packageVerificationFailed(
                "quarantine diagnostic schema/canonical form invalid: \(url.path)")
        }
        // `StrictJSONDocumentParser` intentionally returns Foundation
        // `NSNumber` values. Re-encoding that untyped object would turn JSON
        // integers such as version/source_mode into `2.0`/`365.0`, even
        // though the writer emitted canonical integer tokens. Reconstruct the
        // already type-checked schema so canonical byte comparison preserves
        // the integer-vs-number contract instead of depending on NSNumber's
        // bridge representation.
        let normalizedCanonicalObject: [String: Any] = [
            "format": quarantineDiagnosticFormat,
            "version": quarantineDiagnosticVersion,
            "transaction_id": transactionID,
            "reason": "package_validation_failed",
            "quarantined_at_unix": quarantinedAt,
            "source_identity": [
                "prior_map_id": priorMapID,
                "package_sha256": packageSHA256,
            ],
            "source_path": sourcePath,
            "source_mode": sourceModeValue,
            "quarantine_path": quarantinePath,
            "payload_tree_sha256": payloadTreeSHA256,
            "validator_detail": validatorDetail,
        ]
        guard let canonical = try? CanonicalJSONEncoder.encode(
                normalizedCanonicalObject),
              canonical == data else {
            throw LibraryError.packageVerificationFailed(
                "quarantine diagnostic canonical bytes invalid: \(url.path)")
        }
        let expectedSource = try packageDirectory(
            priorMapID: priorMapID, packageSHA: packageSHA256)
        let expectedDestination = quarantineRoot.appendingPathComponent(
            transactionID, isDirectory: true)
        guard sourcePath == expectedSource.path,
              quarantinePath == expectedDestination.path else {
            throw LibraryError.packageVerificationFailed(
                "quarantine diagnostic path binding mismatch")
        }
        return QuarantineDiagnostic(
            transactionID: transactionID,
            priorMapID: priorMapID,
            packageSHA256: packageSHA256,
            sourceURL: expectedSource,
            sourceMode: mode_t(sourceModeValue),
            destinationURL: expectedDestination,
            payloadTreeSHA256: payloadTreeSHA256)
    }

    private static func verifyPublishedQuarantine(
        _ directory: URL,
        diagnostic: QuarantineDiagnostic
    ) throws {
        try requireRealDirectory(directory, context: "quarantine payload")
        let rootStat = try lstatValue(directory)
        guard rootStat.st_mode & mode_t(0o777) == mode_t(0o555) else {
            throw LibraryError.packageVerificationFailed(
                "quarantine directory mode is not 0555")
        }
        try verifyQuarantineTreeModes(directory)
        let actualPayloadSHA = try quarantinePayloadTreeSHA256(
            at: directory, diagnosticIsEmbedded: true)
        guard actualPayloadSHA == diagnostic.payloadTreeSHA256 else {
            throw LibraryError.packageVerificationFailed(
                "quarantine payload tree hash mismatch")
        }
    }

    private static func verifyQuarantineTreeModes(_ directory: URL) throws {
        let names = try FileManager.default.contentsOfDirectory(
            atPath: directory.path).sorted()
        for name in names {
            let url = directory.appendingPathComponent(name)
            let metadata = try lstatValue(url)
            switch metadata.st_mode & S_IFMT {
            case S_IFDIR:
                guard metadata.st_mode & mode_t(0o777) == mode_t(0o555) else {
                    throw LibraryError.packageVerificationFailed(
                        "quarantine nested directory mode is not 0555")
                }
                try verifyQuarantineTreeModes(url)
            case S_IFREG:
                guard metadata.st_nlink == 1,
                      metadata.st_mode & mode_t(0o777) == mode_t(0o444) else {
                    throw LibraryError.packageVerificationFailed(
                        "quarantine file is not single-link regular 0444")
                }
            default:
                throw LibraryError.packageVerificationFailed(
                    "quarantine tree contains a link or special file")
            }
        }
    }

    private static func quarantinePayloadTreeSHA256(
        at directory: URL,
        diagnosticIsEmbedded: Bool
    ) throws -> String {
        var records: [[String: Any]] = []
        var totalBytes: Int64 = 0
        try appendQuarantinePayloadInventory(
            directory: directory,
            relativePath: "",
            diagnosticIsEmbedded: diagnosticIsEmbedded,
            records: &records,
            totalBytes: &totalBytes)
        let data = try CanonicalJSONEncoder.encode(records)
        return SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
    }

    private static func appendQuarantinePayloadInventory(
        directory: URL,
        relativePath: String,
        diagnosticIsEmbedded: Bool,
        records: inout [[String: Any]],
        totalBytes: inout Int64
    ) throws {
        let before = try lstatValue(directory)
        guard (before.st_mode & S_IFMT) == S_IFDIR else {
            throw LibraryError.packageVerificationFailed(
                "quarantine payload contains a non-directory component")
        }
        let names = try FileManager.default.contentsOfDirectory(
            atPath: directory.path).sorted()
        for name in names {
            if relativePath.isEmpty, name == quarantineDiagnosticFileName {
                guard diagnosticIsEmbedded else {
                    throw LibraryError.packageVerificationFailed(
                        "source package uses reserved quarantine diagnostic name")
                }
                continue
            }
            guard records.count < maximumQuarantinePayloadEntries else {
                throw LibraryError.packageVerificationFailed(
                    "quarantine payload entry limit exceeded")
            }
            let relative = relativePath.isEmpty ? name : "\(relativePath)/\(name)"
            let url = directory.appendingPathComponent(name)
            let metadata = try lstatValue(url)
            switch metadata.st_mode & S_IFMT {
            case S_IFDIR:
                records.append(["path": relative, "type": "directory"])
                try appendQuarantinePayloadInventory(
                    directory: url,
                    relativePath: relative,
                    diagnosticIsEmbedded: diagnosticIsEmbedded,
                    records: &records,
                    totalBytes: &totalBytes)
            case S_IFREG:
                guard metadata.st_nlink == 1,
                      metadata.st_size >= 0,
                      metadata.st_size <= maximumQuarantinePayloadFileBytes,
                      totalBytes <= maximumQuarantinePayloadTotalBytes
                        - metadata.st_size else {
                    throw LibraryError.packageVerificationFailed(
                        "quarantine payload file/link/size limit invalid")
                }
                let digest = try sha256StableRegularFileNoFollow(
                    url, expected: metadata)
                totalBytes += metadata.st_size
                records.append([
                    "path": relative,
                    "type": "regular",
                    "size": Int64(metadata.st_size),
                    "sha256": digest,
                ])
            default:
                throw LibraryError.packageVerificationFailed(
                    "quarantine payload contains a symlink or special file")
            }
        }
        let after = try lstatValue(directory)
        guard sameStableFileIdentity(before, after) else {
            throw LibraryError.packageVerificationFailed(
                "quarantine payload directory changed during inventory")
        }
    }

    private static func sha256StableRegularFileNoFollow(
        _ url: URL,
        expected: stat
    ) throws -> String {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw LibraryError.packageVerificationFailed(
                "cannot open quarantine payload file without following links")
        }
        defer { _ = close(descriptor) }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0,
              (opened.st_mode & S_IFMT) == S_IFREG,
              opened.st_nlink == 1,
              sameStableFileIdentity(expected, opened) else {
            throw LibraryError.packageVerificationFailed(
                "quarantine payload file identity changed before read")
        }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else {
                throw LibraryError.packageVerificationFailed(
                    "cannot read quarantine payload file")
            }
            if count == 0 { break }
            hasher.update(data: Data(buffer[0..<count]))
        }
        var after = stat()
        var pathAfter = stat()
        guard fstat(descriptor, &after) == 0,
              lstat(url.path, &pathAfter) == 0,
              sameStableFileIdentity(opened, after),
              sameStableFileIdentity(opened, pathAfter) else {
            throw LibraryError.packageVerificationFailed(
                "quarantine payload file changed during read")
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func readStableRegularFileNoFollow(
        _ url: URL,
        maximumBytes: Int,
        requiredMode: mode_t
    ) throws -> Data {
        var before = stat()
        guard lstat(url.path, &before) == 0,
              (before.st_mode & S_IFMT) == S_IFREG,
              before.st_nlink == 1,
              before.st_size > 0,
              before.st_size <= maximumBytes,
              before.st_mode & mode_t(0o777) == requiredMode else {
            throw LibraryError.packageVerificationFailed(
                "quarantine diagnostic type/link/size/mode invalid")
        }
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw LibraryError.packageVerificationFailed(
                "cannot open quarantine diagnostic without following links")
        }
        defer { _ = close(descriptor) }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0,
              sameStableFileIdentity(before, opened) else {
            throw LibraryError.packageVerificationFailed(
                "quarantine diagnostic identity changed before read")
        }
        var data = Data()
        data.reserveCapacity(Int(opened.st_size))
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while data.count < maximumBytes {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else {
                throw LibraryError.packageVerificationFailed(
                    "cannot read quarantine diagnostic")
            }
            if count == 0 { break }
            data.append(buffer, count: count)
        }
        var extra: UInt8 = 0
        guard data.count <= maximumBytes,
              Darwin.read(descriptor, &extra, 1) == 0 else {
            throw LibraryError.packageVerificationFailed(
                "quarantine diagnostic exceeds byte limit")
        }
        var after = stat()
        var pathAfter = stat()
        guard fstat(descriptor, &after) == 0,
              lstat(url.path, &pathAfter) == 0,
              sameStableFileIdentity(opened, after),
              sameStableFileIdentity(opened, pathAfter),
              data.count == Int(opened.st_size) else {
            throw LibraryError.packageVerificationFailed(
                "quarantine diagnostic changed during read")
        }
        return data
    }

    private static func sameStableFileIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
        return lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && lhs.st_mode == rhs.st_mode
            && lhs.st_nlink == rhs.st_nlink
            && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

    private static func lstatValue(_ url: URL) throws -> stat {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else {
            throw LibraryError.packageVerificationFailed(
                "cannot lstat \(url.path): " + String(cString: strerror(errno)))
        }
        return metadata
    }

    private static func requireRealDirectory(
        _ url: URL,
        context: String
    ) throws {
        let metadata = try lstatValue(url)
        guard (metadata.st_mode & S_IFMT) == S_IFDIR else {
            throw LibraryError.packageVerificationFailed(
                "\(context) is not a real directory: \(url.path)")
        }
    }

    /// Creates exactly one directory component without following an existing
    /// symlink. The parent must already be a physically verified directory.
    /// This is intentionally narrower than FileManager's recursive creation,
    /// which may traverse attacker-controlled intermediate links.
    private static func ensureRealDirectory(
        _ url: URL,
        parent: URL,
        context: String
    ) throws {
        guard url.deletingLastPathComponent().path == parent.path else {
            throw LibraryError.packageVerificationFailed(
                "\(context) parent binding mismatch")
        }
        try requireRealDirectory(parent, context: "\(context) parent")
        var metadata = stat()
        if lstat(url.path, &metadata) == 0 {
            guard (metadata.st_mode & S_IFMT) == S_IFDIR else {
                throw LibraryError.packageVerificationFailed(
                    "\(context) is not a real directory: \(url.path)")
            }
            return
        }
        guard errno == ENOENT else {
            throw LibraryError.packageVerificationFailed(
                "cannot inspect \(context): "
                    + String(cString: strerror(errno)))
        }
        if mkdir(url.path, mode_t(0o755)) != 0, errno != EEXIST {
            throw LibraryError.packageVerificationFailed(
                "cannot create \(context): "
                    + String(cString: strerror(errno)))
        }
        // EEXIST may mean another actor inserted a link between lstat and
        // mkdir. Only a physical directory is acceptable after the race.
        try requireRealDirectory(url, context: context)
        try syncDirectory(parent)
    }

    private static func requireMissing(_ url: URL, context: String) throws {
        var metadata = stat()
        if lstat(url.path, &metadata) == 0 || errno != ENOENT {
            throw LibraryError.packageVerificationFailed(context)
        }
    }

    private static func syncFileNoFollow(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw LibraryError.cannotSync(url.path) }
        var needsClose = true
        defer { if needsClose { _ = close(descriptor) } }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_nlink == 1,
              fsync(descriptor) == 0,
              close(descriptor) == 0 else {
            throw LibraryError.cannotSync(url.path)
        }
        needsClose = false
    }

    private static func syncQuarantineTree(_ directory: URL) throws {
        var directories: [URL] = [directory]
        let names = try FileManager.default.contentsOfDirectory(
            atPath: directory.path).sorted()
        for name in names {
            let url = directory.appendingPathComponent(name)
            let metadata = try lstatValue(url)
            switch metadata.st_mode & S_IFMT {
            case S_IFDIR:
                try collectQuarantineDirectoriesAndSyncFiles(
                    url, directories: &directories)
            case S_IFREG:
                try syncFileNoFollow(url)
            default:
                throw LibraryError.cannotSync(url.path)
            }
        }
        for item in directories.reversed() {
            try syncDirectory(item)
        }
    }

    private static func collectQuarantineDirectoriesAndSyncFiles(
        _ directory: URL,
        directories: inout [URL]
    ) throws {
        directories.append(directory)
        for name in try FileManager.default.contentsOfDirectory(
            atPath: directory.path).sorted() {
            let url = directory.appendingPathComponent(name)
            let metadata = try lstatValue(url)
            switch metadata.st_mode & S_IFMT {
            case S_IFDIR:
                try collectQuarantineDirectoriesAndSyncFiles(
                    url, directories: &directories)
            case S_IFREG:
                try syncFileNoFollow(url)
            default:
                throw LibraryError.cannotSync(url.path)
            }
        }
    }

    /// Creates one diagnostic without following links or replacing an
    /// existing path, handles partial writes/EINTR, freezes it to 0444 and
    /// fsyncs the same descriptor before it can enter the quarantine package.
    private static func writeNewRegularFileDurably(
        _ data: Data,
        to url: URL
    ) throws {
        let descriptor = open(
            url.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            mode_t(0o600))
        guard descriptor >= 0 else {
            throw LibraryError.packageVerificationFailed(
                "cannot create quarantine diagnostic: "
                    + String(cString: strerror(errno)))
        }
        var needsClose = true
        defer {
            if needsClose { _ = close(descriptor) }
        }
        var offset = 0
        let completed = data.withUnsafeBytes { rawBuffer -> Bool in
            guard let base = rawBuffer.baseAddress else { return data.isEmpty }
            while offset < rawBuffer.count {
                let count = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    rawBuffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                if count <= 0 { return false }
                offset += count
            }
            return true
        }
        guard completed else {
            throw LibraryError.packageVerificationFailed(
                "cannot write quarantine diagnostic")
        }
        guard fchmod(descriptor, mode_t(0o444)) == 0 else {
            throw LibraryError.cannotMakeImmutable(url.path)
        }
        guard fsync(descriptor) == 0 else {
            throw LibraryError.cannotSync(url.path)
        }
        guard close(descriptor) == 0 else {
            throw LibraryError.cannotSync(url.path)
        }
        needsClose = false
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
        let descriptor = open(
            directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw LibraryError.cannotSync(directory.path)
        }
        var needsClose = true
        defer {
            if needsClose { _ = close(descriptor) }
        }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFDIR else {
            throw LibraryError.cannotSync(directory.path)
        }
        guard fsync(descriptor) == 0 else {
            throw LibraryError.cannotSync(directory.path)
        }
        guard close(descriptor) == 0 else {
            throw LibraryError.cannotSync(directory.path)
        }
        needsClose = false
    }
}
