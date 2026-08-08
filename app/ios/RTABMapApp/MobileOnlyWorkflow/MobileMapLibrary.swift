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
    private static let quarantineDiagnosticVersion = 3
    private static let maximumQuarantineDiagnosticBytes = 64 * 1024
    private static let maximumQuarantinePayloadEntries = 256
    private static let maximumQuarantinePayloadFileBytes: Int64 =
        512 * 1024 * 1024
    private static let maximumQuarantinePayloadTotalBytes: Int64 =
        1024 * 1024 * 1024
    private static let processLockFileName = ".map-library.lock"
    private static let quarantineDiagnosticRemovalSuffix =
        ".diagnostic.removing"

    enum QuarantineFaultPoint {
        case afterSourceThawBeforePayloadRename
        case afterPayloadRename
        case afterDiagnosticPlacementBeforeFreeze
        case afterDiagnosticPlacementAndFreeze
        case afterPublishRenameBeforeFreeze
        case afterPublishFreezeBeforeParentSync
        case afterPublishRenameAndParentSync
        case afterRollbackSourceModeRestoreBeforeIntentRemoval
    }

    /// Host-only fault injection for the quarantine transaction. Production
    /// leaves this nil; tests use thrown errors for rollback checks and a
    /// child process `_exit` for every durable transaction boundary.
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

    private struct ProcessLockHandle {
        let rootDescriptor: Int32
        let lockDescriptor: Int32
        let rootURL: URL
        let rootMetadata: stat
        let lockMetadata: stat
    }

    /// Every production entry that can reconcile or mutate the map library
    /// also holds this advisory process lock. `NSLock` protects threads only;
    /// without a shared `lockf` lock, a second app process could replace a
    /// diagnostic-bound source between its final identity check and intent
    /// removal.
    private static func acquireProcessLock() throws -> ProcessLockHandle {
        let mapRoot = try root()
        let openedRoot = try openStableDirectoryNoFollow(
            mapRoot, context: "map-library process-lock root")
        var keepRootDescriptor = false
        defer {
            if !keepRootDescriptor { _ = close(openedRoot.descriptor) }
        }
        let descriptor = openat(
            openedRoot.descriptor,
            processLockFileName,
            O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
            mode_t(0o600))
        guard descriptor >= 0 else {
            throw LibraryError.packageVerificationFailed(
                "cannot open map-library process lock: "
                    + String(cString: strerror(errno)))
        }
        var metadata = stat()
        var pathMetadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_nlink == 1,
              metadata.st_size == 0,
              metadata.st_mode & mode_t(0o777) == mode_t(0o600),
              fstatat(
                openedRoot.descriptor,
                processLockFileName,
                &pathMetadata,
                AT_SYMLINK_NOFOLLOW) == 0,
              sameRegularFileInode(metadata, pathMetadata) else {
            _ = close(descriptor)
            throw LibraryError.packageVerificationFailed(
                "map-library process lock identity/mode invalid")
        }
        do {
            try requireOpenDirectoryPath(
                descriptor: openedRoot.descriptor,
                url: mapRoot,
                expectedMetadata: openedRoot.metadata,
                context: "map-library process-lock root before lock")
        } catch {
            _ = close(descriptor)
            throw error
        }
        while lockf(descriptor, F_LOCK, 0) != 0 {
            if errno == EINTR { continue }
            let detail = String(cString: strerror(errno))
            _ = close(descriptor)
            throw LibraryError.packageVerificationFailed(
                "cannot acquire map-library process lock: \(detail)")
        }
        var lockedMetadata = stat()
        var lockedPathMetadata = stat()
        do {
            guard fstat(descriptor, &lockedMetadata) == 0,
                  fstatat(
                    openedRoot.descriptor,
                    processLockFileName,
                    &lockedPathMetadata,
                    AT_SYMLINK_NOFOLLOW) == 0,
                  sameRegularFileInode(metadata, lockedMetadata),
                  sameRegularFileInode(metadata, lockedPathMetadata),
                  lockedMetadata.st_nlink == 1,
                  lockedMetadata.st_size == 0,
                  lockedMetadata.st_mode & mode_t(0o777) == mode_t(0o600) else {
                throw LibraryError.packageVerificationFailed(
                    "map-library process lock pathname changed while acquiring")
            }
            try requireOpenDirectoryPath(
                descriptor: openedRoot.descriptor,
                url: mapRoot,
                expectedMetadata: openedRoot.metadata,
                context: "map-library process-lock root after lock")
        } catch {
            _ = lockf(descriptor, F_ULOCK, 0)
            _ = close(descriptor)
            throw error
        }
        keepRootDescriptor = true
        return ProcessLockHandle(
            rootDescriptor: openedRoot.descriptor,
            lockDescriptor: descriptor,
            rootURL: mapRoot,
            rootMetadata: openedRoot.metadata,
            lockMetadata: lockedMetadata)
    }

    private static func validateProcessLock(
        _ handle: ProcessLockHandle
    ) throws {
        var rootDescriptorMetadata = stat()
        var rootPathMetadata = stat()
        var lockDescriptorMetadata = stat()
        var lockPathMetadata = stat()
        guard fstat(handle.rootDescriptor, &rootDescriptorMetadata) == 0,
              lstat(handle.rootURL.path, &rootPathMetadata) == 0,
              sameDirectoryIdentity(
                handle.rootMetadata, rootDescriptorMetadata),
              sameDirectoryIdentity(handle.rootMetadata, rootPathMetadata),
              fstat(handle.lockDescriptor, &lockDescriptorMetadata) == 0,
              fstatat(
                handle.rootDescriptor,
                processLockFileName,
                &lockPathMetadata,
                AT_SYMLINK_NOFOLLOW) == 0,
              sameRegularFileInode(
                handle.lockMetadata, lockDescriptorMetadata),
              sameRegularFileInode(handle.lockMetadata, lockPathMetadata),
              lockDescriptorMetadata.st_nlink == 1,
              lockPathMetadata.st_nlink == 1,
              lockDescriptorMetadata.st_size == 0,
              lockPathMetadata.st_size == 0,
              lockDescriptorMetadata.st_mode & mode_t(0o777)
                == mode_t(0o600),
              lockPathMetadata.st_mode & mode_t(0o777)
                == mode_t(0o600) else {
            throw LibraryError.packageVerificationFailed(
                "map-library process lock/root binding changed while held")
        }
    }

    private static func releaseProcessLock(_ handle: ProcessLockHandle) {
        _ = lockf(handle.lockDescriptor, F_ULOCK, 0)
        _ = close(handle.lockDescriptor)
        _ = close(handle.rootDescriptor)
    }

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
        let processLock = try acquireProcessLock()
        defer { releaseProcessLock(processLock) }
        try recoverQuarantineTransactionsLocked(processLock: processLock)

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
        try writeRegistry(
            entries,
            expectedGeneration: payload.generation,
            processLock: processLock)
        try validateProcessLock(processLock)
        return entry
    }

    /// Removes a map from the durable index (package bytes are kept so a
    /// re-registration never needs a re-compile).
    static func unregister(priorMapID: String, packageSHA256: String? = nil) throws {
        libraryLock.lock()
        defer { libraryLock.unlock() }
        let processLock = try acquireProcessLock()
        defer { releaseProcessLock(processLock) }
        try recoverQuarantineTransactionsLocked(processLock: processLock)
        let payload = try readRegistryPayload()
        var entries = payload.entries
        if let packageSHA256 = packageSHA256 {
            entries.removeAll {
                $0.priorMapID == priorMapID && $0.packageSHA256 == packageSHA256
            }
        } else {
            entries.removeAll { $0.priorMapID == priorMapID }
        }
        try writeRegistry(
            entries,
            expectedGeneration: payload.generation,
            processLock: processLock)
        try validateProcessLock(processLock)
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
        let processLock = try acquireProcessLock()
        defer { releaseProcessLock(processLock) }
        try recoverQuarantineTransactionsLocked(processLock: processLock)
        // §14.2: every listed map is re-verified against its package
        // manifest/digest; a missing or corrupt package is dropped from
        // the reported list (the registry itself is untouched).
        let entries = try readRegistryPayload().entries.filter { entry in
            guard let digest = try? quickVerifyPackage(entry) else { return false }
            return digest == entry.packageSHA256
        }.sorted { $0.compiledAtUTC > $1.compiledAtUTC }
        try validateProcessLock(processLock)
        return entries
    }

    static func map(priorMapID: String, packageSHA256: String) throws -> MapEntry {
        libraryLock.lock()
        defer { libraryLock.unlock() }
        let processLock = try acquireProcessLock()
        defer { releaseProcessLock(processLock) }
        try recoverQuarantineTransactionsLocked(processLock: processLock)
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
        try validateProcessLock(processLock)
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
        expectedGeneration: Int,
        processLock: ProcessLockHandle
    ) throws {
        try validateProcessLock(processLock)
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
            try validateProcessLock(processLock)
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
            try validateProcessLock(processLock)
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
        let processLock = try acquireProcessLock()
        defer { releaseProcessLock(processLock) }
        try recoverQuarantineTransactionsLocked(processLock: processLock)
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
                        validationError: validationError,
                        processLock: processLock)
                }
            }
        }
        // A corrupt maps array can be rebuilt if (and only if) its durable
        // generation is still valid. Missing/illegal generation never
        // defaults to zero and is not overwritten silently.
        let expectedGeneration = try readDiskGeneration()
        try writeRegistry(
            entries,
            expectedGeneration: expectedGeneration,
            processLock: processLock)
        try validateProcessLock(processLock)
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

    /// §14.2 safe prior-map ID: non-empty, bounded, `[a-z0-9._-]` only,
    /// and never either POSIX self/parent path component.
    static func isSafeIdentifier(_ value: String, maximumLength: Int = 128) -> Bool {
        guard !value.isEmpty, value != ".", value != "..",
              value.unicodeScalars.count <= maximumLength else {
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
    static func makeImmutable(
        at root: URL,
        freezeRootDirectory: Bool = true
    ) throws {
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
        for url in directories.reversed() where url != root {
            try setPermissions(0o555, on: url)
        }
        try setPermissions(
            freezeRootDirectory ? 0o555 : 0o755,
            on: root)
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
        let payloadIdentity: ImmutableDirectoryPublication.Identity?
        let canonicalData: Data
    }

    private struct QuarantineRecoveryGroup {
        var pending: URL?
        var diagnosticTemporary: URL?
        var diagnosticRemovalTombstone: URL?
        var published: URL?
    }

    /// Reconciles every durable quarantine transaction while the caller holds
    /// `libraryLock`. This runs before registration, listing, loading and
    /// rebuild so a crash cannot strand a production package under a hidden
    /// name forever. The state machine accepts only these atomic-rename states:
    ///
    /// - v3 source + `.diagnostic.tmp`: the payload rename did not commit;
    ///   verify the exact dev/inode/tree, restore the source and remove intent;
    ///   legacy v2 incomplete transactions lack that durable inode binding and
    ///   remain preserved fail-closed (only a frozen v2 final is compatible);
    /// - `.pending` + `.diagnostic.tmp`: finish diagnostic placement/freeze;
    /// - `.pending` + embedded diagnostic: verify/freeze and publish;
    /// - final quarantine directory: verify and complete every parent fsync.
    ///
    /// Missing payloads, duplicate phase artifacts, unknown names, symlinks,
    /// hard links, non-canonical diagnostics or identity/path/hash conflicts
    /// fail closed. Recovery never guesses which bytes should win.
    private static func recoverQuarantineTransactionsLocked(
        processLock: ProcessLockHandle
    ) throws {
        try validateProcessLock(processLock)
        let mapRoot = try root()
        try requireRealDirectory(mapRoot, context: "map library root")
        let quarantineBase = mapRoot.appendingPathComponent(
            "quarantine", isDirectory: true)
        var baseStat = stat()
        if lstat(quarantineBase.path, &baseStat) != 0 {
            if errno == ENOENT {
                try validateProcessLock(processLock)
                return
            }
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
                enum ArtifactKind {
                    case pending, temporary, removalTombstone, published
                }
                let kind: ArtifactKind
                if name.hasPrefix("."), name.hasSuffix(".pending") {
                    transactionID = String(name.dropFirst().dropLast(".pending".count))
                    kind = .pending
                } else if name.hasPrefix("."),
                          name.hasSuffix(".diagnostic.tmp") {
                    transactionID = String(
                        name.dropFirst().dropLast(".diagnostic.tmp".count))
                    kind = .temporary
                } else if name.hasPrefix("."),
                          name.hasSuffix(quarantineDiagnosticRemovalSuffix) {
                    transactionID = String(
                        name.dropFirst().dropLast(
                            quarantineDiagnosticRemovalSuffix.count))
                    kind = .removalTombstone
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
                let isDirectory: Bool
                switch kind {
                case .pending, .published: isDirectory = true
                case .temporary, .removalTombstone: isDirectory = false
                }
                let url = quarantineRoot.appendingPathComponent(
                    name, isDirectory: isDirectory)
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
                case .removalTombstone:
                    guard group.diagnosticRemovalTombstone == nil else {
                        throw LibraryError.packageVerificationFailed(
                            "duplicate quarantine diagnostic removal tombstone")
                    }
                    group.diagnosticRemovalTombstone = url
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
                          group.diagnosticRemovalTombstone == nil,
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
                    try validateProcessLock(processLock)
                    try recoverInterruptedPublishedQuarantineIfNeeded(
                        published, diagnostic: diagnostic)
                    try verifyPublishedQuarantine(
                        published, diagnostic: diagnostic)
                    try syncQuarantineTree(published)
                    try syncDirectory(diagnostic.sourceURL.deletingLastPathComponent())
                    try syncDirectory(quarantineRoot)
                    try syncDirectory(quarantineBase)
                    try syncDirectory(mapRoot)
                    try validateProcessLock(processLock)
                    continue
                }

                if let pending = group.pending {
                    guard group.diagnosticRemovalTombstone == nil else {
                        throw LibraryError.packageVerificationFailed(
                            "pending quarantine conflicts with diagnostic removal tombstone")
                    }
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
                        guard diagnostic.payloadIdentity != nil else {
                            throw LibraryError.packageVerificationFailed(
                                "legacy quarantine pending transaction lacks durable payload identity")
                        }
                        try requireMissing(
                            diagnostic.sourceURL,
                            context: "quarantine source and pending both exist")
                        let actualPayloadSHA = try quarantinePayloadTreeSHA256(
                            at: pending, diagnosticIsEmbedded: false)
                        guard actualPayloadSHA == diagnostic.payloadTreeSHA256 else {
                            throw LibraryError.packageVerificationFailed(
                                "pending quarantine payload hash mismatch")
                        }
                        try validateProcessLock(processLock)
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
                        try validateProcessLock(processLock)
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
                        guard diagnostic.payloadIdentity != nil else {
                            throw LibraryError.packageVerificationFailed(
                                "legacy quarantine pending transaction lacks durable payload identity")
                        }
                        try requireMissing(
                            diagnostic.sourceURL,
                            context: "quarantine source and pending both exist")
                    }
                    try makeImmutable(
                        at: pending, freezeRootDirectory: false)
                    try verifyPreparedQuarantine(
                        pending, diagnostic: diagnostic)
                    try syncQuarantineTree(pending)
                    try publishPreparedQuarantine(
                        pending,
                        to: destination,
                        diagnostic: diagnostic,
                        injectFaults: false,
                        processLock: processLock)
                    try verifyPublishedQuarantine(
                        destination, diagnostic: diagnostic)
                    try syncQuarantineTree(destination)
                    try syncDirectory(diagnostic.sourceURL.deletingLastPathComponent())
                    try syncDirectory(quarantineRoot)
                    try syncDirectory(quarantineBase)
                    try syncDirectory(mapRoot)
                    try validateProcessLock(processLock)
                    continue
                }

                guard !(group.diagnosticTemporary != nil
                        && group.diagnosticRemovalTombstone != nil) else {
                    throw LibraryError.packageVerificationFailed(
                        "quarantine rollback has both temporary and removal tombstone")
                }
                guard let rollbackIntent = group.diagnosticTemporary
                        ?? group.diagnosticRemovalTombstone else {
                    throw LibraryError.packageVerificationFailed(
                        "empty quarantine transaction \(transactionID)")
                }
                let diagnostic = try readQuarantineDiagnostic(
                    at: rollbackIntent,
                    transactionID: transactionID,
                    priorMapID: priorMapID,
                    quarantineRoot: quarantineRoot)
                guard diagnostic.payloadIdentity != nil else {
                    throw LibraryError.packageVerificationFailed(
                        "legacy quarantine rollback lacks durable payload identity")
                }
                try restoreQuarantineSourceAndRemoveIntent(
                    rollbackIntent,
                    diagnostic: diagnostic,
                    quarantineRoot: quarantineRoot,
                    processLock: processLock)
            }
        }
        try validateProcessLock(processLock)
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
        validationError: Error,
        processLock: ProcessLockHandle
    ) throws {
        try validateProcessLock(processLock)
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
            "payload_device": String(UInt64(packageStat.st_dev)),
            "payload_inode": String(UInt64(packageStat.st_ino)),
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

        var payloadMoved = false
        var diagnosticMoved = false
        var published = false
        var diagnosticDurable = false

        func rollback(_ originalError: Error) throws -> Never {
            var failures: [String] = []
            do {
                let diagnostic = try readQuarantineDiagnostic(
                    at: diagnosticTemporary,
                    transactionID: quarantineID,
                    priorMapID: priorMapID,
                    quarantineRoot: quarantineRoot)
                guard diagnostic.payloadIdentity != nil else {
                    throw LibraryError.packageVerificationFailed(
                        "rollback diagnostic lacks durable payload identity")
                }
                if payloadMoved {
                    guard !diagnosticMoved, !published else {
                        throw LibraryError.packageVerificationFailed(
                            "rollback reached a durable embedded diagnostic state")
                    }
                    try restoreMovedQuarantinePayload(
                        pendingDestination,
                        to: package,
                        diagnostic: diagnostic,
                        quarantineRoot: quarantineRoot)
                    payloadMoved = false
                    published = false
                }
                // This helper is the only code allowed to remove the durable
                // diagnostic.  It first restores and hashes the exact v3-bound
                // source, then uses an identity-bound removal tombstone.  Any
                // post-unlink failure recreates the canonical diagnostic.
                try restoreQuarantineSourceAndRemoveIntent(
                    diagnosticTemporary,
                    diagnostic: diagnostic,
                    quarantineRoot: quarantineRoot,
                    processLock: processLock)
            } catch {
                failures.append(error.localizedDescription)
            }

            let suffix = failures.isEmpty
                ? ""
                : "; rollback failures: \(failures.joined(separator: ", "))"
            throw LibraryError.packageVerificationFailed(
                "quarantine transaction failed: \(originalError.localizedDescription)\(suffix)")
        }

        do {
            if (originalMode & mode_t(S_IWUSR)) == 0 {
                guard chmod(
                    package.path,
                    originalMode | mode_t(S_IWUSR)) == 0 else {
                    throw LibraryError.cannotMakeImmutable(package.path)
                }
                try syncDirectory(package)
                try quarantineFaultInjector?(
                    .afterSourceThawBeforePayloadRename)
            }
            try validateProcessLock(processLock)
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
            try validateProcessLock(processLock)
            try quarantineFaultInjector?(.afterPayloadRename)

            try validateProcessLock(processLock)
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
            try validateProcessLock(processLock)
            try quarantineFaultInjector?(.afterDiagnosticPlacementBeforeFreeze)
            try makeImmutable(
                at: pendingDestination, freezeRootDirectory: false)
            let diagnostic = try readQuarantineDiagnostic(
                at: diagnosticURL,
                transactionID: quarantineID,
                priorMapID: priorMapID,
                quarantineRoot: quarantineRoot)
            try verifyPreparedQuarantine(
                pendingDestination, diagnostic: diagnostic)
            try syncQuarantineTree(pendingDestination)
            try syncDirectory(quarantineRoot)
            try quarantineFaultInjector?(.afterDiagnosticPlacementAndFreeze)

            try publishPreparedQuarantine(
                pendingDestination,
                to: destination,
                diagnostic: diagnostic,
                injectFaults: true,
                processLock: processLock)
            published = true
            try verifyPublishedQuarantine(
                destination, diagnostic: diagnostic)
            try syncQuarantineTree(destination)
            try syncDirectory(sourceParent)
            try syncDirectory(quarantineRoot)
            try syncDirectory(quarantineBase)
            try syncDirectory(mapRoot)
            try quarantineFaultInjector?(.afterPublishRenameAndParentSync)
            try validateProcessLock(processLock)
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
        let uuidText = String(transactionID[uuidStart...])
        // Foundation accepts uppercase UUID text and normalizes it.  Durable
        // transaction names use the writer's one canonical lowercase form;
        // recovery must not alias a second spelling to the same UUID value.
        guard let uuid = UUID(uuidString: uuidText),
              uuid.uuidString.lowercased() == uuidText else {
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
              object["format"] as? String == quarantineDiagnosticFormat,
              let version = StrictJSONScalar.integer(object["version"]),
              version == 2 || version == quarantineDiagnosticVersion,
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
        let version2Keys = Set([
            "format", "version", "transaction_id", "reason",
            "quarantined_at_unix", "source_identity", "source_path",
            "source_mode", "quarantine_path", "payload_tree_sha256",
            "validator_detail",
        ])
        let version3Keys = version2Keys.union([
            "payload_device", "payload_inode",
        ])
        guard Set(object.keys) == (version == 2 ? version2Keys : version3Keys)
        else {
            throw LibraryError.packageVerificationFailed(
                "quarantine diagnostic field set invalid: \(url.path)")
        }
        let payloadIdentity: ImmutableDirectoryPublication.Identity?
        if version == quarantineDiagnosticVersion {
            guard let deviceText = object["payload_device"] as? String,
                  let inodeText = object["payload_inode"] as? String,
                  isCanonicalUnsignedDecimal(deviceText),
                  isCanonicalUnsignedDecimal(inodeText),
                  let device = UInt64(deviceText),
                  let inode = UInt64(inodeText) else {
                throw LibraryError.packageVerificationFailed(
                    "quarantine diagnostic payload identity invalid: \(url.path)")
            }
            payloadIdentity = ImmutableDirectoryPublication.Identity(
                device: device, inode: inode)
        } else {
            payloadIdentity = nil
        }
        // `StrictJSONDocumentParser` intentionally returns Foundation
        // `NSNumber` values. Re-encoding that untyped object would turn JSON
        // integers such as version/source_mode into `2.0`/`365.0`, even
        // though the writer emitted canonical integer tokens. Reconstruct the
        // already type-checked schema so canonical byte comparison preserves
        // the integer-vs-number contract instead of depending on NSNumber's
        // bridge representation.
        var normalizedCanonicalObject: [String: Any] = [
            "format": quarantineDiagnosticFormat,
            "version": version,
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
        if let payloadIdentity {
            normalizedCanonicalObject["payload_device"] = String(
                payloadIdentity.device)
            normalizedCanonicalObject["payload_inode"] = String(
                payloadIdentity.inode)
        }
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
            payloadTreeSHA256: payloadTreeSHA256,
            payloadIdentity: payloadIdentity,
            canonicalData: data)
    }

    private static func isCanonicalUnsignedDecimal(_ value: String) -> Bool {
        guard !value.isEmpty,
              value.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else {
            return false
        }
        return value == "0" || !value.hasPrefix("0")
    }

    private static func verifyPreparedQuarantine(
        _ directory: URL,
        diagnostic: QuarantineDiagnostic
    ) throws {
        try verifyQuarantine(
            directory,
            diagnostic: diagnostic,
            expectedRootMode: ImmutableDirectoryPublication.renameableMode)
    }

    private static func verifyPublishedQuarantine(
        _ directory: URL,
        diagnostic: QuarantineDiagnostic
    ) throws {
        try verifyQuarantine(
            directory,
            diagnostic: diagnostic,
            expectedRootMode: ImmutableDirectoryPublication.immutableMode)
    }

    private static func verifyQuarantine(
        _ directory: URL,
        diagnostic: QuarantineDiagnostic,
        expectedRootMode: mode_t
    ) throws {
        let parentURL = directory.deletingLastPathComponent()
        let openedParent = try openStableDirectoryNoFollow(
            parentURL, context: "quarantine payload parent")
        defer { _ = close(openedParent.descriptor) }
        let descriptor = openat(
            openedParent.descriptor,
            directory.lastPathComponent,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw LibraryError.packageVerificationFailed(
                "cannot open quarantine payload root without following links")
        }
        defer { _ = close(descriptor) }
        var opened = stat()
        var pathBefore = stat()
        guard fstat(descriptor, &opened) == 0,
              (opened.st_mode & S_IFMT) == S_IFDIR,
              fstatat(
                openedParent.descriptor,
                directory.lastPathComponent,
                &pathBefore,
                AT_SYMLINK_NOFOLLOW) == 0,
              sameStableFileIdentity(opened, pathBefore),
              opened.st_mode & mode_t(0o777) == expectedRootMode else {
            throw LibraryError.packageVerificationFailed(
                "quarantine directory mode is not "
                    + String(expectedRootMode, radix: 8))
        }
        if let expectedIdentity = diagnostic.payloadIdentity {
            let actualIdentity = ImmutableDirectoryPublication.Identity(
                device: UInt64(opened.st_dev),
                inode: UInt64(opened.st_ino))
            guard actualIdentity == expectedIdentity else {
                throw LibraryError.packageVerificationFailed(
                    "quarantine payload dev/inode identity mismatch")
            }
        }
        // The payload inventory intentionally excludes the embedded
        // diagnostic from its tree hash, so bind that file separately to the
        // exact canonical bytes that authorized this transaction.  Keep the
        // FD open across payload hashing and rebind the pathname afterwards.
        let openedDiagnostic = try openBoundQuarantineDiagnosticIntent(
            parentDescriptor: descriptor,
            basename: quarantineDiagnosticFileName,
            expectedData: diagnostic.canonicalData)
        defer { _ = close(openedDiagnostic.descriptor) }
        let actualPayloadSHA = try quarantinePayloadTreeSHA256(
            atBoundDirectoryDescriptor: descriptor,
            diagnosticIsEmbedded: true,
            requiredRootMode: expectedRootMode,
            requireImmutableDescendantModes: true)
        guard actualPayloadSHA == diagnostic.payloadTreeSHA256 else {
            throw LibraryError.packageVerificationFailed(
                "quarantine payload tree hash mismatch")
        }
        try requireBoundQuarantineDiagnosticIntent(
            descriptor: openedDiagnostic.descriptor,
            parentDescriptor: descriptor,
            basename: quarantineDiagnosticFileName,
            expectedDataSize: diagnostic.canonicalData.count)
        var openedAfter = stat()
        var pathAfter = stat()
        guard fstat(descriptor, &openedAfter) == 0,
              fstatat(
                openedParent.descriptor,
                directory.lastPathComponent,
                &pathAfter,
                AT_SYMLINK_NOFOLLOW) == 0,
              sameStableFileIdentity(opened, openedAfter),
              sameStableFileIdentity(opened, pathAfter) else {
            throw LibraryError.packageVerificationFailed(
                "quarantine payload root changed during verification")
        }
        try requireOpenDirectoryPath(
            descriptor: openedParent.descriptor,
            url: parentURL,
            expectedMetadata: openedParent.metadata,
            context: "quarantine payload parent after verification")
    }

    /// Restores a payload that was exclusively renamed to `.pending` before
    /// the diagnostic itself entered the payload.  The v3 diagnostic binds the
    /// directory dev/inode and tree hash; the durable diagnostic is deliberately
    /// left untouched here so any failure remains recoverable.
    private static func restoreMovedQuarantinePayload(
        _ pending: URL,
        to source: URL,
        diagnostic: QuarantineDiagnostic,
        quarantineRoot: URL
    ) throws {
        guard let expectedIdentity = diagnostic.payloadIdentity,
              source.path == diagnostic.sourceURL.path,
              pending.deletingLastPathComponent().path == quarantineRoot.path
        else {
            throw LibraryError.packageVerificationFailed(
                "quarantine payload rollback path/identity binding invalid")
        }
        let sourceParentURL = source.deletingLastPathComponent()
        let openedSourceParent = try openStableDirectoryNoFollow(
            sourceParentURL, context: "quarantine rollback source parent")
        defer { _ = close(openedSourceParent.descriptor) }
        let openedQuarantineRoot = try openStableDirectoryNoFollow(
            quarantineRoot, context: "quarantine rollback root")
        defer { _ = close(openedQuarantineRoot.descriptor) }

        let payloadDescriptor = openat(
            openedQuarantineRoot.descriptor,
            pending.lastPathComponent,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard payloadDescriptor >= 0 else {
            throw LibraryError.packageVerificationFailed(
                "cannot open moved quarantine payload: "
                    + String(cString: strerror(errno)))
        }
        defer { _ = close(payloadDescriptor) }

        try validateBoundQuarantineRollbackSource(
            descriptor: payloadDescriptor,
            expectedIdentity: expectedIdentity,
            expectedMode: nil,
            parentDescriptor: openedQuarantineRoot.descriptor,
            parentURL: quarantineRoot,
            parentMetadata: openedQuarantineRoot.metadata,
            basename: pending.lastPathComponent,
            diagnostic: diagnostic,
            context: "moved quarantine rollback payload")

        let renameableMode = diagnostic.sourceMode | mode_t(S_IWUSR)
        guard fchmod(payloadDescriptor, renameableMode) == 0,
              fsync(payloadDescriptor) == 0 else {
            throw LibraryError.cannotMakeImmutable(
                "cannot make moved quarantine payload rollback-safe")
        }
        try validateBoundQuarantineRollbackSource(
            descriptor: payloadDescriptor,
            expectedIdentity: expectedIdentity,
            expectedMode: renameableMode,
            parentDescriptor: openedQuarantineRoot.descriptor,
            parentURL: quarantineRoot,
            parentMetadata: openedQuarantineRoot.metadata,
            basename: pending.lastPathComponent,
            diagnostic: diagnostic,
            context: "renameable quarantine rollback payload")

        var sourceMetadata = stat()
        if fstatat(
            openedSourceParent.descriptor,
            source.lastPathComponent,
            &sourceMetadata,
            AT_SYMLINK_NOFOLLOW) == 0 || errno != ENOENT {
            throw LibraryError.packageVerificationFailed(
                "quarantine rollback source path is no longer absent")
        }
        try requireOpenDirectoryPath(
            descriptor: openedSourceParent.descriptor,
            url: sourceParentURL,
            expectedMetadata: openedSourceParent.metadata,
            context: "quarantine rollback source parent before rename")
        try requireOpenDirectoryPath(
            descriptor: openedQuarantineRoot.descriptor,
            url: quarantineRoot,
            expectedMetadata: openedQuarantineRoot.metadata,
            context: "quarantine rollback root before source rename")
        guard renameatx_np(
            openedQuarantineRoot.descriptor,
            pending.lastPathComponent,
            openedSourceParent.descriptor,
            source.lastPathComponent,
            UInt32(RENAME_EXCL)) == 0 else {
            throw LibraryError.packageVerificationFailed(
                "cannot restore source package: "
                    + String(cString: strerror(errno)))
        }

        var oldPathMetadata = stat()
        guard fstatat(
            openedQuarantineRoot.descriptor,
            pending.lastPathComponent,
            &oldPathMetadata,
            AT_SYMLINK_NOFOLLOW) != 0,
              errno == ENOENT else {
            throw LibraryError.packageVerificationFailed(
                "moved quarantine payload remained at the pending path")
        }
        guard fchmod(payloadDescriptor, diagnostic.sourceMode) == 0,
              fsync(payloadDescriptor) == 0,
              fsync(openedSourceParent.descriptor) == 0,
              fsync(openedQuarantineRoot.descriptor) == 0 else {
            throw LibraryError.cannotSync(
                "cannot durably restore moved quarantine payload")
        }
        try validateBoundQuarantineRollbackSource(
            descriptor: payloadDescriptor,
            expectedIdentity: expectedIdentity,
            expectedMode: diagnostic.sourceMode,
            parentDescriptor: openedSourceParent.descriptor,
            parentURL: sourceParentURL,
            parentMetadata: openedSourceParent.metadata,
            basename: source.lastPathComponent,
            diagnostic: diagnostic,
            context: "restored quarantine source")
        try requireOpenDirectoryPath(
            descriptor: openedQuarantineRoot.descriptor,
            url: quarantineRoot,
            expectedMetadata: openedQuarantineRoot.metadata,
            context: "quarantine rollback root after source rename")
    }

    /// Completes a source-only rollback transaction.  Diagnostic removal is a
    /// two-name protocol: `.diagnostic.tmp` is first exclusively renamed to an
    /// identity-bound `.diagnostic.removing` tombstone and fsynced.  Only after
    /// the exact v3 source is rebound and rehashed is that tombstone unlinked.
    /// If unlink/durability/post-validation detects any conflict, the canonical
    /// diagnostic bytes are recreated before returning an error.
    private static func restoreQuarantineSourceAndRemoveIntent(
        _ rollbackIntent: URL,
        diagnostic: QuarantineDiagnostic,
        quarantineRoot: URL,
        processLock: ProcessLockHandle
    ) throws {
        guard let expectedIdentity = diagnostic.payloadIdentity else {
            throw LibraryError.packageVerificationFailed(
                "legacy quarantine rollback lacks durable payload identity")
        }
        let temporaryBasename =
            ".\(diagnostic.transactionID).diagnostic.tmp"
        let removalBasename =
            ".\(diagnostic.transactionID)\(quarantineDiagnosticRemovalSuffix)"
        guard rollbackIntent.deletingLastPathComponent().path
                == quarantineRoot.path,
              rollbackIntent.lastPathComponent == temporaryBasename
                || rollbackIntent.lastPathComponent == removalBasename else {
            throw LibraryError.packageVerificationFailed(
                "quarantine rollback intent path binding invalid")
        }

        let sourceParentURL = diagnostic.sourceURL.deletingLastPathComponent()
        let openedSourceParent = try openStableDirectoryNoFollow(
            sourceParentURL, context: "quarantine rollback source parent")
        defer { _ = close(openedSourceParent.descriptor) }
        let sourceDescriptor = openat(
            openedSourceParent.descriptor,
            diagnostic.sourceURL.lastPathComponent,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard sourceDescriptor >= 0 else {
            throw LibraryError.packageVerificationFailed(
                "cannot open quarantine rollback source: "
                    + String(cString: strerror(errno)))
        }
        defer { _ = close(sourceDescriptor) }

        try validateBoundQuarantineRollbackSource(
            descriptor: sourceDescriptor,
            expectedIdentity: expectedIdentity,
            expectedMode: nil,
            parentDescriptor: openedSourceParent.descriptor,
            parentURL: sourceParentURL,
            parentMetadata: openedSourceParent.metadata,
            basename: diagnostic.sourceURL.lastPathComponent,
            diagnostic: diagnostic,
            context: "quarantine rollback source before mode restore")
        guard fchmod(sourceDescriptor, diagnostic.sourceMode) == 0,
              fsync(sourceDescriptor) == 0 else {
            throw LibraryError.cannotMakeImmutable(
                "cannot restore quarantine source mode")
        }
        try validateBoundQuarantineRollbackSource(
            descriptor: sourceDescriptor,
            expectedIdentity: expectedIdentity,
            expectedMode: diagnostic.sourceMode,
            parentDescriptor: openedSourceParent.descriptor,
            parentURL: sourceParentURL,
            parentMetadata: openedSourceParent.metadata,
            basename: diagnostic.sourceURL.lastPathComponent,
            diagnostic: diagnostic,
            context: "quarantine rollback source after mode restore")

        let openedQuarantineRoot = try openStableDirectoryNoFollow(
            quarantineRoot, context: "quarantine rollback root")
        defer { _ = close(openedQuarantineRoot.descriptor) }
        try quarantineFaultInjector?(
            .afterRollbackSourceModeRestoreBeforeIntentRemoval)
        // Rebind immediately after the externally visible fault/race window.
        // A replacement here must leave the original `.diagnostic.tmp` name
        // untouched; the removal tombstone is published only for an exact,
        // still-path-bound source.
        try validateBoundQuarantineRollbackSource(
            descriptor: sourceDescriptor,
            expectedIdentity: expectedIdentity,
            expectedMode: diagnostic.sourceMode,
            parentDescriptor: openedSourceParent.descriptor,
            parentURL: sourceParentURL,
            parentMetadata: openedSourceParent.metadata,
            basename: diagnostic.sourceURL.lastPathComponent,
            diagnostic: diagnostic,
            context: "quarantine rollback source after final race window")

        var conflictingMetadata = stat()
        let conflictingBasename = rollbackIntent.lastPathComponent
            == temporaryBasename ? removalBasename : temporaryBasename
        if fstatat(
            openedQuarantineRoot.descriptor,
            conflictingBasename,
            &conflictingMetadata,
            AT_SYMLINK_NOFOLLOW) == 0 || errno != ENOENT {
            throw LibraryError.packageVerificationFailed(
                "quarantine rollback has conflicting diagnostic intents")
        }

        let openedIntent = try openBoundQuarantineDiagnosticIntent(
            parentDescriptor: openedQuarantineRoot.descriptor,
            basename: rollbackIntent.lastPathComponent,
            expectedData: diagnostic.canonicalData)
        defer { _ = close(openedIntent.descriptor) }

        if rollbackIntent.lastPathComponent == temporaryBasename {
            guard renameatx_np(
                openedQuarantineRoot.descriptor,
                temporaryBasename,
                openedQuarantineRoot.descriptor,
                removalBasename,
                UInt32(RENAME_EXCL)) == 0 else {
                throw LibraryError.packageVerificationFailed(
                    "cannot publish quarantine diagnostic removal tombstone: "
                        + String(cString: strerror(errno)))
            }
            guard fsync(openedQuarantineRoot.descriptor) == 0 else {
                throw LibraryError.cannotSync(
                    "quarantine diagnostic removal tombstone")
            }
            var temporaryMetadata = stat()
            guard fstatat(
                openedQuarantineRoot.descriptor,
                temporaryBasename,
                &temporaryMetadata,
                AT_SYMLINK_NOFOLLOW) != 0,
                  errno == ENOENT else {
                throw LibraryError.packageVerificationFailed(
                    "quarantine diagnostic temporary remained after tombstone rename")
            }
        }
        try requireBoundQuarantineDiagnosticIntent(
            descriptor: openedIntent.descriptor,
            parentDescriptor: openedQuarantineRoot.descriptor,
            basename: removalBasename,
            expectedDataSize: diagnostic.canonicalData.count)
        try validateBoundQuarantineRollbackSource(
            descriptor: sourceDescriptor,
            expectedIdentity: expectedIdentity,
            expectedMode: diagnostic.sourceMode,
            parentDescriptor: openedSourceParent.descriptor,
            parentURL: sourceParentURL,
            parentMetadata: openedSourceParent.metadata,
            basename: diagnostic.sourceURL.lastPathComponent,
            diagnostic: diagnostic,
            context: "quarantine rollback source before intent removal")
        try requireOpenDirectoryPath(
            descriptor: openedQuarantineRoot.descriptor,
            url: quarantineRoot,
            expectedMetadata: openedQuarantineRoot.metadata,
            context: "quarantine rollback root before intent removal")
        try validateProcessLock(processLock)
        guard fsync(openedSourceParent.descriptor) == 0 else {
            throw LibraryError.cannotSync(
                "quarantine rollback source parent before intent removal")
        }

        do {
            // `unlinkat` itself has no inode-CAS variant.  Keep the verified
            // tombstone FD open across removal, prove that exact inode reached
            // nlink=0, and recreate canonical evidence on every mismatch.
            guard unlinkat(
                openedQuarantineRoot.descriptor,
                removalBasename,
                0) == 0 else {
                throw LibraryError.packageVerificationFailed(
                    "cannot remove quarantine diagnostic tombstone: "
                        + String(cString: strerror(errno)))
            }
            var removedMetadata = stat()
            var removedPathMetadata = stat()
            guard fstat(openedIntent.descriptor, &removedMetadata) == 0,
                  sameRegularFileInode(
                    openedIntent.metadata, removedMetadata),
                  removedMetadata.st_nlink == 0,
                  fstatat(
                    openedQuarantineRoot.descriptor,
                    removalBasename,
                    &removedPathMetadata,
                    AT_SYMLINK_NOFOLLOW) != 0,
                  errno == ENOENT,
                  fsync(openedQuarantineRoot.descriptor) == 0 else {
                throw LibraryError.packageVerificationFailed(
                    "quarantine diagnostic tombstone removal was not identity-stable")
            }
            try validateBoundQuarantineRollbackSource(
                descriptor: sourceDescriptor,
                expectedIdentity: expectedIdentity,
                expectedMode: diagnostic.sourceMode,
                parentDescriptor: openedSourceParent.descriptor,
                parentURL: sourceParentURL,
                parentMetadata: openedSourceParent.metadata,
                basename: diagnostic.sourceURL.lastPathComponent,
                diagnostic: diagnostic,
                context: "quarantine rollback source after intent removal")
            try requireOpenDirectoryPath(
                descriptor: openedQuarantineRoot.descriptor,
                url: quarantineRoot,
                expectedMetadata: openedQuarantineRoot.metadata,
                context: "quarantine rollback root after intent removal")
            try validateProcessLock(processLock)
        } catch {
            do {
                try restoreRemovedQuarantineDiagnostic(
                    diagnostic,
                    quarantineRootDescriptor: openedQuarantineRoot.descriptor,
                    temporaryBasename: temporaryBasename,
                    removalBasename: removalBasename)
            } catch let restorationError {
                throw LibraryError.packageVerificationFailed(
                    "\(error.localizedDescription); cannot restore durable "
                        + "quarantine diagnostic: "
                        + restorationError.localizedDescription)
            }
            throw error
        }
    }

    private static func validateBoundQuarantineRollbackSource(
        descriptor: Int32,
        expectedIdentity: ImmutableDirectoryPublication.Identity,
        expectedMode: mode_t?,
        parentDescriptor: Int32,
        parentURL: URL,
        parentMetadata: stat,
        basename: String,
        diagnostic: QuarantineDiagnostic,
        context: String
    ) throws {
        var parentDescriptorMetadata = stat()
        var parentPathMetadata = stat()
        var openedMetadata = stat()
        var pathMetadata = stat()
        guard fstat(parentDescriptor, &parentDescriptorMetadata) == 0,
              lstat(parentURL.path, &parentPathMetadata) == 0,
              sameDirectoryIdentity(parentMetadata, parentDescriptorMetadata),
              sameDirectoryIdentity(parentMetadata, parentPathMetadata),
              fstat(descriptor, &openedMetadata) == 0,
              fstatat(
                parentDescriptor,
                basename,
                &pathMetadata,
                AT_SYMLINK_NOFOLLOW) == 0,
              sameDirectoryIdentity(openedMetadata, pathMetadata),
              ImmutableDirectoryPublication.Identity(
                device: UInt64(openedMetadata.st_dev),
                inode: UInt64(openedMetadata.st_ino)) == expectedIdentity else {
            throw LibraryError.packageVerificationFailed(
                "\(context) dev/inode/path binding changed")
        }
        if let expectedMode,
           openedMetadata.st_mode & mode_t(0o777) != expectedMode
            || pathMetadata.st_mode & mode_t(0o777) != expectedMode {
            throw LibraryError.packageVerificationFailed(
                "\(context) root mode changed")
        }
        let payloadSHA = try quarantinePayloadTreeSHA256(
            atBoundDirectoryDescriptor: descriptor,
            diagnosticIsEmbedded: false,
            requiredRootMode: expectedMode)
        guard payloadSHA == diagnostic.payloadTreeSHA256 else {
            throw LibraryError.packageVerificationFailed(
                "\(context) payload hash mismatch")
        }
        var openedAfter = stat()
        var pathAfter = stat()
        guard fstat(descriptor, &openedAfter) == 0,
              fstatat(
                parentDescriptor,
                basename,
                &pathAfter,
                AT_SYMLINK_NOFOLLOW) == 0,
              sameDirectoryIdentity(openedMetadata, openedAfter),
              sameDirectoryIdentity(openedMetadata, pathAfter),
              ImmutableDirectoryPublication.Identity(
                device: UInt64(openedAfter.st_dev),
                inode: UInt64(openedAfter.st_ino)) == expectedIdentity else {
            throw LibraryError.packageVerificationFailed(
                "\(context) changed during payload verification")
        }
        if let expectedMode,
           openedAfter.st_mode & mode_t(0o777) != expectedMode
            || pathAfter.st_mode & mode_t(0o777) != expectedMode {
            throw LibraryError.packageVerificationFailed(
                "\(context) root mode changed during payload verification")
        }
    }

    private static func openBoundQuarantineDiagnosticIntent(
        parentDescriptor: Int32,
        basename: String,
        expectedData: Data
    ) throws -> (descriptor: Int32, metadata: stat) {
        let descriptor = openat(
            parentDescriptor,
            basename,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw LibraryError.packageVerificationFailed(
                "cannot open quarantine diagnostic intent: "
                    + String(cString: strerror(errno)))
        }
        do {
            var metadata = stat()
            var pathMetadata = stat()
            guard fstat(descriptor, &metadata) == 0,
                  (metadata.st_mode & S_IFMT) == S_IFREG,
                  metadata.st_nlink == 1,
                  metadata.st_mode & mode_t(0o777) == mode_t(0o444),
                  metadata.st_size == expectedData.count,
                  fstatat(
                    parentDescriptor,
                    basename,
                    &pathMetadata,
                    AT_SYMLINK_NOFOLLOW) == 0,
                  sameStableFileIdentity(metadata, pathMetadata) else {
                throw LibraryError.packageVerificationFailed(
                    "quarantine diagnostic intent identity/mode invalid")
            }
            var data = Data()
            data.reserveCapacity(expectedData.count)
            var buffer = [UInt8](repeating: 0, count: 16 * 1024)
            while data.count <= maximumQuarantineDiagnosticBytes {
                let count = Darwin.read(descriptor, &buffer, buffer.count)
                if count < 0 && errno == EINTR { continue }
                guard count >= 0 else {
                    throw LibraryError.packageVerificationFailed(
                        "cannot read quarantine diagnostic intent")
                }
                if count == 0 { break }
                data.append(buffer, count: count)
            }
            var after = stat()
            var pathAfter = stat()
            guard data == expectedData,
                  fstat(descriptor, &after) == 0,
                  fstatat(
                    parentDescriptor,
                    basename,
                    &pathAfter,
                    AT_SYMLINK_NOFOLLOW) == 0,
                  sameStableFileIdentity(metadata, after),
                  sameStableFileIdentity(metadata, pathAfter) else {
                throw LibraryError.packageVerificationFailed(
                    "quarantine diagnostic intent changed during read")
            }
            return (descriptor, metadata)
        } catch {
            _ = close(descriptor)
            throw error
        }
    }

    private static func requireBoundQuarantineDiagnosticIntent(
        descriptor: Int32,
        parentDescriptor: Int32,
        basename: String,
        expectedDataSize: Int
    ) throws {
        var openedMetadata = stat()
        var pathMetadata = stat()
        guard fstat(descriptor, &openedMetadata) == 0,
              fstatat(
                parentDescriptor,
                basename,
                &pathMetadata,
                AT_SYMLINK_NOFOLLOW) == 0,
              sameRegularFileInode(openedMetadata, pathMetadata),
              openedMetadata.st_nlink == 1,
              pathMetadata.st_nlink == 1,
              openedMetadata.st_mode & mode_t(0o777) == mode_t(0o444),
              pathMetadata.st_mode & mode_t(0o777) == mode_t(0o444),
              openedMetadata.st_size == expectedDataSize,
              pathMetadata.st_size == expectedDataSize else {
            throw LibraryError.packageVerificationFailed(
                "quarantine diagnostic tombstone path binding changed")
        }
    }

    private static func restoreRemovedQuarantineDiagnostic(
        _ diagnostic: QuarantineDiagnostic,
        quarantineRootDescriptor: Int32,
        temporaryBasename: String,
        removalBasename: String
    ) throws {
        for basename in [removalBasename, temporaryBasename] {
            var metadata = stat()
            if fstatat(
                quarantineRootDescriptor,
                basename,
                &metadata,
                AT_SYMLINK_NOFOLLOW) == 0 {
                do {
                    let opened = try openBoundQuarantineDiagnosticIntent(
                        parentDescriptor: quarantineRootDescriptor,
                        basename: basename,
                        expectedData: diagnostic.canonicalData)
                    _ = close(opened.descriptor)
                    guard fsync(quarantineRootDescriptor) == 0 else {
                        throw LibraryError.cannotSync(
                            "existing restored quarantine diagnostic")
                    }
                    return
                } catch {
                    if basename == temporaryBasename { throw error }
                    // Preserve a conflicting removal name and continue.  A
                    // canonical temporary can coexist with it fail-closed;
                    // recovery will reject the two-name conflict while still
                    // retaining the authoritative v3 evidence.
                }
                continue
            }
            guard errno == ENOENT else {
                throw LibraryError.packageVerificationFailed(
                    "cannot inspect quarantine diagnostic restoration path")
            }
        }
        try writeNewRegularFileDurably(
            diagnostic.canonicalData,
            parentDescriptor: quarantineRootDescriptor,
            basename: temporaryBasename)
        guard fsync(quarantineRootDescriptor) == 0 else {
            throw LibraryError.cannotSync(
                "restored quarantine diagnostic parent")
        }
    }

    private static func publishPreparedQuarantine(
        _ pending: URL,
        to destination: URL,
        diagnostic: QuarantineDiagnostic,
        injectFaults: Bool,
        processLock: ProcessLockHandle
    ) throws {
        guard let expectedIdentity = diagnostic.payloadIdentity else {
            throw LibraryError.packageVerificationFailed(
                "legacy quarantine diagnostic cannot authorize publication")
        }
        try validateProcessLock(processLock)
        do {
            try ImmutableDirectoryPublication.publish(
                source: pending,
                destination: destination,
                expectedIdentity: expectedIdentity,
                afterRenameBeforeFreeze: injectFaults ? {
                    try quarantineFaultInjector?(
                        .afterPublishRenameBeforeFreeze)
                } : nil,
                afterFreezeBeforeParentSync: injectFaults ? {
                    try quarantineFaultInjector?(
                        .afterPublishFreezeBeforeParentSync)
                } : nil)
            try validateProcessLock(processLock)
        } catch let error as LibraryError {
            throw error
        } catch {
            throw LibraryError.packageVerificationFailed(
                "quarantine publish transaction failed: "
                    + error.localizedDescription)
        }
    }

    private static func recoverInterruptedPublishedQuarantineIfNeeded(
        _ published: URL,
        diagnostic: QuarantineDiagnostic
    ) throws {
        let metadata = try lstatValue(published)
        let mode = metadata.st_mode & mode_t(0o777)
        guard mode == ImmutableDirectoryPublication.renameableMode
                || mode == ImmutableDirectoryPublication.immutableMode else {
            throw LibraryError.packageVerificationFailed(
                "published quarantine root mode is neither 0755 nor 0555")
        }
        if mode == ImmutableDirectoryPublication.immutableMode {
            if let expectedIdentity = diagnostic.payloadIdentity {
                do {
                    try ImmutableDirectoryPublication
                        .freezeInterruptedDestination(
                            published, expectedIdentity: expectedIdentity)
                } catch {
                    throw LibraryError.packageVerificationFailed(
                        "cannot resync interrupted quarantine publication: "
                            + error.localizedDescription)
                }
            }
            return
        }

        // A writable final is recoverable only because the durable embedded
        // diagnostic binds the transaction, path, payload tree and (for v3)
        // the source dev/inode.  No diagnostic means no permission repair.
        try verifyPreparedQuarantine(published, diagnostic: diagnostic)
        guard let expectedIdentity = diagnostic.payloadIdentity else {
            throw LibraryError.packageVerificationFailed(
                "writable published quarantine lacks durable payload identity")
        }
        do {
            try ImmutableDirectoryPublication.freezeInterruptedDestination(
                published, expectedIdentity: expectedIdentity)
        } catch {
            throw LibraryError.packageVerificationFailed(
                "cannot recover interrupted quarantine publication: "
                    + error.localizedDescription)
        }
    }

    private static func quarantinePayloadTreeSHA256(
        at directory: URL,
        diagnosticIsEmbedded: Bool
    ) throws -> String {
        let opened = try openStableDirectoryNoFollow(
            directory, context: "quarantine payload root")
        defer { _ = close(opened.descriptor) }
        let digest = try quarantinePayloadTreeSHA256(
            atBoundDirectoryDescriptor: opened.descriptor,
            diagnosticIsEmbedded: diagnosticIsEmbedded)
        var openedAfter = stat()
        var pathAfter = stat()
        guard fstat(opened.descriptor, &openedAfter) == 0,
              lstat(directory.path, &pathAfter) == 0,
              sameStableFileIdentity(opened.metadata, openedAfter),
              sameStableFileIdentity(opened.metadata, pathAfter) else {
            throw LibraryError.packageVerificationFailed(
                "quarantine payload root changed during inventory")
        }
        return digest
    }

    private static func quarantinePayloadTreeSHA256(
        atBoundDirectoryDescriptor descriptor: Int32,
        diagnosticIsEmbedded: Bool,
        requiredRootMode: mode_t? = nil,
        requireImmutableDescendantModes: Bool = false
    ) throws -> String {
        var before = stat()
        guard fstat(descriptor, &before) == 0,
              (before.st_mode & S_IFMT) == S_IFDIR else {
            throw LibraryError.packageVerificationFailed(
                "quarantine payload descriptor is not a directory")
        }
        if let requiredRootMode,
           before.st_mode & mode_t(0o777) != requiredRootMode {
            throw LibraryError.packageVerificationFailed(
                "quarantine payload root mode changed before inventory")
        }
        var records: [[String: Any]] = []
        var totalBytes: Int64 = 0
        try appendQuarantinePayloadInventory(
            directoryDescriptor: descriptor,
            relativePath: "",
            diagnosticIsEmbedded: diagnosticIsEmbedded,
            requireImmutableModes: requireImmutableDescendantModes,
            records: &records,
            totalBytes: &totalBytes)
        var after = stat()
        guard fstat(descriptor, &after) == 0,
              sameStableFileIdentity(before, after) else {
            throw LibraryError.packageVerificationFailed(
                "quarantine payload directory changed during inventory")
        }
        let data = try CanonicalJSONEncoder.encode(records)
        return SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
    }

    private static func appendQuarantinePayloadInventory(
        directoryDescriptor: Int32,
        relativePath: String,
        diagnosticIsEmbedded: Bool,
        requireImmutableModes: Bool,
        records: inout [[String: Any]],
        totalBytes: inout Int64
    ) throws {
        var before = stat()
        guard fstat(directoryDescriptor, &before) == 0,
              (before.st_mode & S_IFMT) == S_IFDIR else {
            throw LibraryError.packageVerificationFailed(
                "quarantine payload contains a non-directory component")
        }
        let names = try directoryEntryNames(
            atBoundDirectoryDescriptor: directoryDescriptor,
            maximumEntries: maximumQuarantinePayloadEntries + 1)
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
            var metadata = stat()
            guard fstatat(
                directoryDescriptor,
                name,
                &metadata,
                AT_SYMLINK_NOFOLLOW) == 0 else {
                throw LibraryError.packageVerificationFailed(
                    "cannot inspect quarantine payload entry: "
                        + String(cString: strerror(errno)))
            }
            switch metadata.st_mode & S_IFMT {
            case S_IFDIR:
                if requireImmutableModes,
                   metadata.st_mode & mode_t(0o777) != mode_t(0o555) {
                    throw LibraryError.packageVerificationFailed(
                        "quarantine nested directory mode is not 0555")
                }
                let childDescriptor = openat(
                    directoryDescriptor,
                    name,
                    O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
                guard childDescriptor >= 0 else {
                    throw LibraryError.packageVerificationFailed(
                        "cannot open quarantine payload directory without following links")
                }
                records.append(["path": relative, "type": "directory"])
                do {
                    defer { _ = close(childDescriptor) }
                    var opened = stat()
                    guard fstat(childDescriptor, &opened) == 0,
                          sameStableFileIdentity(metadata, opened) else {
                        throw LibraryError.packageVerificationFailed(
                            "quarantine payload directory identity changed before inventory")
                    }
                    try appendQuarantinePayloadInventory(
                        directoryDescriptor: childDescriptor,
                        relativePath: relative,
                        diagnosticIsEmbedded: diagnosticIsEmbedded,
                        requireImmutableModes: requireImmutableModes,
                        records: &records,
                        totalBytes: &totalBytes)
                    var openedAfter = stat()
                    var pathAfter = stat()
                    guard fstat(childDescriptor, &openedAfter) == 0,
                          fstatat(
                            directoryDescriptor,
                            name,
                            &pathAfter,
                            AT_SYMLINK_NOFOLLOW) == 0,
                          sameStableFileIdentity(opened, openedAfter),
                          sameStableFileIdentity(opened, pathAfter) else {
                        throw LibraryError.packageVerificationFailed(
                            "quarantine payload directory changed during inventory")
                    }
                }
            case S_IFREG:
                guard metadata.st_nlink == 1,
                      !requireImmutableModes
                        || metadata.st_mode & mode_t(0o777) == mode_t(0o444),
                      metadata.st_size >= 0,
                      metadata.st_size <= maximumQuarantinePayloadFileBytes,
                      totalBytes <= maximumQuarantinePayloadTotalBytes
                        - metadata.st_size else {
                    throw LibraryError.packageVerificationFailed(
                        "quarantine payload file/link/size limit invalid")
                }
                let digest = try sha256StableRegularFileNoFollow(
                    parentDescriptor: directoryDescriptor,
                    basename: name,
                    expected: metadata)
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
        var after = stat()
        guard fstat(directoryDescriptor, &after) == 0,
              sameStableFileIdentity(before, after) else {
            throw LibraryError.packageVerificationFailed(
                "quarantine payload directory changed during inventory")
        }
    }

    private static func directoryEntryNames(
        atBoundDirectoryDescriptor descriptor: Int32,
        maximumEntries: Int
    ) throws -> [String] {
        let enumerationDescriptor = openat(
            descriptor, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard enumerationDescriptor >= 0 else {
            throw LibraryError.packageVerificationFailed(
                "cannot duplicate quarantine payload directory for inventory")
        }
        guard let stream = fdopendir(enumerationDescriptor) else {
            _ = close(enumerationDescriptor)
            throw LibraryError.packageVerificationFailed(
                "cannot enumerate quarantine payload directory")
        }
        defer { _ = closedir(stream) }
        var names: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else {
                    throw LibraryError.packageVerificationFailed(
                        "cannot finish quarantine payload enumeration")
                }
                break
            }
            guard let name = withUnsafePointer(to: entry.pointee.d_name, {
                pointer -> String? in
                pointer.withMemoryRebound(
                    to: CChar.self,
                    capacity: Int(MAXNAMLEN) + 1
                ) { String(validatingUTF8: $0) }
            }) else {
                throw LibraryError.packageVerificationFailed(
                    "quarantine payload entry name is not valid UTF-8")
            }
            if name == "." || name == ".." { continue }
            guard !name.isEmpty, !name.contains("/") else {
                throw LibraryError.packageVerificationFailed(
                    "quarantine payload entry has an unsafe name")
            }
            guard names.count < maximumEntries else {
                throw LibraryError.packageVerificationFailed(
                    "quarantine payload entry limit exceeded during enumeration")
            }
            names.append(name)
        }
        return names.sorted()
    }

    private static func sha256StableRegularFileNoFollow(
        parentDescriptor: Int32,
        basename: String,
        expected: stat
    ) throws -> String {
        let descriptor = openat(
            parentDescriptor, basename, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
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
              fstatat(
                parentDescriptor,
                basename,
                &pathAfter,
                AT_SYMLINK_NOFOLLOW) == 0,
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

    private static func sameRegularFileInode(_ lhs: stat, _ rhs: stat) -> Bool {
        return (lhs.st_mode & S_IFMT) == S_IFREG
            && (rhs.st_mode & S_IFMT) == S_IFREG
            && lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
    }

    private static func lstatValue(_ url: URL) throws -> stat {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else {
            throw LibraryError.packageVerificationFailed(
                "cannot lstat \(url.path): " + String(cString: strerror(errno)))
        }
        return metadata
    }

    private static func sameDirectoryIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
        return (lhs.st_mode & S_IFMT) == S_IFDIR
            && (rhs.st_mode & S_IFMT) == S_IFDIR
            && lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
    }

    private static func openStableDirectoryNoFollow(
        _ url: URL,
        context: String
    ) throws -> (descriptor: Int32, metadata: stat) {
        let pathMetadata = try lstatValue(url)
        guard (pathMetadata.st_mode & S_IFMT) == S_IFDIR else {
            throw LibraryError.packageVerificationFailed(
                "\(context) is not a real directory")
        }
        let descriptor = open(
            url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw LibraryError.packageVerificationFailed(
                "cannot open \(context): " + String(cString: strerror(errno)))
        }
        var openedMetadata = stat()
        guard fstat(descriptor, &openedMetadata) == 0,
              sameStableFileIdentity(pathMetadata, openedMetadata) else {
            _ = close(descriptor)
            throw LibraryError.packageVerificationFailed(
                "\(context) changed while opening")
        }
        return (descriptor, openedMetadata)
    }

    private static func requireBoundDirectoryPath(
        descriptor: Int32,
        expectedIdentity: ImmutableDirectoryPublication.Identity,
        expectedMode: mode_t,
        parentDescriptor: Int32,
        parentURL: URL,
        parentMetadata: stat,
        basename: String,
        context: String
    ) throws {
        var parentDescriptorMetadata = stat()
        var parentPathMetadata = stat()
        var openedMetadata = stat()
        var pathMetadata = stat()
        guard fstat(parentDescriptor, &parentDescriptorMetadata) == 0,
              lstat(parentURL.path, &parentPathMetadata) == 0,
              sameDirectoryIdentity(parentMetadata, parentDescriptorMetadata),
              sameDirectoryIdentity(parentMetadata, parentPathMetadata),
              fstat(descriptor, &openedMetadata) == 0,
              fstatat(
                parentDescriptor,
                basename,
                &pathMetadata,
                AT_SYMLINK_NOFOLLOW) == 0,
              sameDirectoryIdentity(openedMetadata, pathMetadata),
              ImmutableDirectoryPublication.Identity(
                device: UInt64(openedMetadata.st_dev),
                inode: UInt64(openedMetadata.st_ino)) == expectedIdentity,
              openedMetadata.st_mode & mode_t(0o777) == expectedMode,
              pathMetadata.st_mode & mode_t(0o777) == expectedMode else {
            throw LibraryError.packageVerificationFailed(
                "\(context) dev/inode/path/mode binding changed")
        }
    }

    private static func requireOpenDirectoryPath(
        descriptor: Int32,
        url: URL,
        expectedMetadata: stat,
        context: String
    ) throws {
        var descriptorMetadata = stat()
        var pathMetadata = stat()
        guard fstat(descriptor, &descriptorMetadata) == 0,
              lstat(url.path, &pathMetadata) == 0,
              sameDirectoryIdentity(expectedMetadata, descriptorMetadata),
              sameDirectoryIdentity(expectedMetadata, pathMetadata) else {
            throw LibraryError.packageVerificationFailed(
                "\(context) dev/inode/path binding changed")
        }
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

    /// FD-relative variant used only when a removed rollback intent must be
    /// recreated inside the already-bound quarantine root.  It never follows
    /// or replaces a pathname and leaves any partial file fail-closed if the
    /// underlying storage reports a write/durability failure.
    private static func writeNewRegularFileDurably(
        _ data: Data,
        parentDescriptor: Int32,
        basename: String
    ) throws {
        let descriptor = openat(
            parentDescriptor,
            basename,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            mode_t(0o600))
        guard descriptor >= 0 else {
            throw LibraryError.packageVerificationFailed(
                "cannot recreate quarantine diagnostic: "
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
        guard completed,
              fchmod(descriptor, mode_t(0o444)) == 0,
              fsync(descriptor) == 0 else {
            throw LibraryError.packageVerificationFailed(
                "cannot durably recreate quarantine diagnostic")
        }
        var openedMetadata = stat()
        var pathMetadata = stat()
        guard fstat(descriptor, &openedMetadata) == 0,
              fstatat(
                parentDescriptor,
                basename,
                &pathMetadata,
                AT_SYMLINK_NOFOLLOW) == 0,
              sameRegularFileInode(openedMetadata, pathMetadata),
              openedMetadata.st_nlink == 1,
              openedMetadata.st_mode & mode_t(0o777) == mode_t(0o444),
              openedMetadata.st_size == data.count else {
            throw LibraryError.packageVerificationFailed(
                "recreated quarantine diagnostic path binding invalid")
        }
        guard close(descriptor) == 0 else {
            throw LibraryError.cannotSync(
                "recreated quarantine diagnostic close")
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
