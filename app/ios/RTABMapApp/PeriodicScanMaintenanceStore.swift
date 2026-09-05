//
//  PeriodicScanMaintenanceStore.swift
//  RTABMapApp
//
//  File-system layer for the large-store mission container (phase 1 of
//  `PERIODIC_MANUAL_CALIBRATION_AND_AUTO_ROLLOVER_REQUIREMENTS_2026-09-04.md`).
//
//  Responsibilities:
//    * mission / unit / boundary directory layout with collision-free naming;
//    * atomic commit of the running checkpoint, boundary files and the final
//      manifest (temp file + fsync + rename, never an in-place rewrite);
//    * SHA-256 of unit database and metadata for the hash chain;
//    * symlink / hardlink / path-escape rejection inside the mission root;
//    * observation of on-disk units for the crash-recovery planner.
//
//  This file is Foundation-only and every file operation goes through an
//  injectable writer, so macOS host tests can inject deterministic failures.
//  It does not start cameras, databases or any capture transaction: sealing
//  and next-unit start belong to phases 2 and 3.
//

import Foundation
import CryptoKit
import Darwin

// MARK: - Errors

enum MissionStoreError: Error, Equatable, CustomStringConvertible {
    case missionRootMissing(URL)
    case missionRootExists(String)
    case atomicWriteFailed(String)
    case unitDirectoryExists(String)
    case unitDirectoryMissing(String)
    case metadataMissing(String)
    case metadataUnreadable(String)
    case checkpointUnreadable(String)
    case manifestUnreadable(String)
    case linkDetected(String)
    case pathEscape(String)
    case hashUnavailable(String)
    case missionNotComplete(String)
    case invalidUnitIndex(Int)

    var description: String {
        switch self {
        case .missionRootMissing(let url):
            return "mission_root_missing:\(url.path)"
        case .missionRootExists(let path):
            return "mission_root_exists:\(path)"
        case .atomicWriteFailed(let reason):
            return "atomic_write_failed:\(reason)"
        case .unitDirectoryExists(let path):
            return "unit_directory_exists:\(path)"
        case .unitDirectoryMissing(let path):
            return "unit_directory_missing:\(path)"
        case .metadataMissing(let path):
            return "metadata_missing:\(path)"
        case .metadataUnreadable(let path):
            return "metadata_unreadable:\(path)"
        case .checkpointUnreadable(let path):
            return "checkpoint_unreadable:\(path)"
        case .manifestUnreadable(let path):
            return "manifest_unreadable:\(path)"
        case .linkDetected(let path):
            return "link_detected:\(path)"
        case .pathEscape(let path):
            return "path_escape:\(path)"
        case .hashUnavailable(let path):
            return "hash_unavailable:\(path)"
        case .missionNotComplete(let reason):
            return "mission_not_complete:\(reason)"
        case .invalidUnitIndex(let index):
            return "invalid_unit_index:\(index)"
        }
    }
}

// MARK: - Event log

/// Append-only mission audit record (§9.2: `mission_events.jsonl`).
struct MissionEventRecord: Codable, Equatable {
    static let format = "marketscanner_mission_event"

    let format: String
    let version: Int
    let event: String
    let atUnix: TimeInterval
    let monotonic: TimeInterval?
    let unitIndex: Int?
    let boundaryId: String?
    let detail: String?

    init(
        event: String,
        atUnix: TimeInterval,
        monotonic: TimeInterval? = nil,
        unitIndex: Int? = nil,
        boundaryId: String? = nil,
        detail: String? = nil
    ) {
        self.format = MissionEventRecord.format
        self.version = 1
        self.event = event
        self.atUnix = atUnix
        self.monotonic = monotonic
        self.unitIndex = unitIndex
        self.boundaryId = boundaryId
        self.detail = detail
    }
}

// MARK: - File writing

/// Injected file primitives. The default implementation performs a real
/// atomic commit; tests inject failures at the write, flush or rename stage.
protocol MissionFileWriting {
    func fileExists(at url: URL) -> Bool
    func directoryExists(at url: URL) -> Bool
    func createDirectory(at url: URL) throws
    func contentsOfDirectory(at url: URL) throws -> [URL]
    func read(at url: URL) throws -> Data
    func writeAtomic(_ data: Data, to url: URL) throws
    func writeAtomicExclusive(_ data: Data, to url: URL) throws
    func append(_ data: Data, to url: URL) throws
    func removeItem(at url: URL) throws
    /// Returns true when the path itself is a symlink or carries more than one
    /// link, which the mission validator rejects (§9.2).
    func isLink(at url: URL) -> Bool
    func isRegularFile(at url: URL) -> Bool
}

enum MissionWriteStage: String, Equatable {
    case write
    case flush
    case rename
}

struct FoundationMissionFileWriter: MissionFileWriting {
    private let fileManager: FileManager
    private let fault: ((MissionWriteStage, URL) throws -> Void)?

    init(
        fileManager: FileManager = .default,
        fault: ((MissionWriteStage, URL) throws -> Void)? = nil
    ) {
        self.fileManager = fileManager
        self.fault = fault
    }

    func fileExists(at url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path)
    }

    func directoryExists(at url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }

    func createDirectory(at url: URL) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func contentsOfDirectory(at url: URL) throws -> [URL] {
        try fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])
    }

    func read(at url: URL) throws -> Data {
        try Data(contentsOf: url, options: .mappedIfSafe)
    }

    func writeAtomic(_ data: Data, to url: URL) throws {
        try writeAtomic(data, to: url, replacing: true)
    }

    func writeAtomicExclusive(_ data: Data, to url: URL) throws {
        try writeAtomic(data, to: url, replacing: false)
    }

    private func writeAtomic(_ data: Data, to url: URL, replacing: Bool) throws {
        let directory = url.deletingLastPathComponent()
        if !directoryExists(at: directory) {
            try createDirectory(at: directory)
        }
        let temporaryURL = directory.appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let descriptor = Darwin.open(
            temporaryURL.path,
            O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW,
            S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw MissionStoreError.atomicWriteFailed("temporary_open_failed")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        var closed = false
        var committed = false
        defer {
            if !closed { try? handle.close() }
            if !committed {
                try? fileManager.removeItem(at: temporaryURL)
            }
        }
        try fault?(.write, url)
        try handle.write(contentsOf: data)
        try fault?(.flush, url)
        try handle.synchronize()
        try handle.close()
        closed = true
        try fault?(.rename, url)
        if replacing {
            guard Darwin.rename(temporaryURL.path, url.path) == 0 else {
                throw MissionStoreError.atomicWriteFailed("atomic_rename_failed")
            }
        } else {
            // `link` is an atomic create-if-absent commit on the same file
            // system. Unlike rename(2), it cannot replace an immutable
            // boundary or completion manifest between the preflight and the
            // commit syscall.
            guard Darwin.link(temporaryURL.path, url.path) == 0 else {
                throw MissionStoreError.atomicWriteFailed(
                    errno == EEXIST ? "destination_exists" : "atomic_link_failed")
            }
            guard Darwin.unlink(temporaryURL.path) == 0 else {
                throw MissionStoreError.atomicWriteFailed("temporary_unlink_failed")
            }
        }
        committed = true
        // The rename itself must survive a power loss, which requires fsync on
        // the containing directory, not only on the file.
        let directoryDescriptor = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY)
        guard directoryDescriptor >= 0 else {
            throw MissionStoreError.atomicWriteFailed("directory_open_failed")
        }
        defer { Darwin.close(directoryDescriptor) }
        guard Darwin.fsync(directoryDescriptor) == 0 else {
            throw MissionStoreError.atomicWriteFailed("directory_fsync_failed")
        }
    }

    func append(_ data: Data, to url: URL) throws {
        if !fileExists(at: url) {
            try writeAtomic(data, to: url)
            return
        }
        guard isRegularFile(at: url) else {
            throw MissionStoreError.linkDetected(url.lastPathComponent)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.synchronize()
    }

    func removeItem(at url: URL) throws {
        try fileManager.removeItem(at: url)
    }

    /// Uses `lstat`: `FileManager.attributesOfItem` follows symlinks, which
    /// would let a linked unit or metadata file masquerade as a real one.
    func isLink(at url: URL) -> Bool {
        var info = Darwin.stat()
        guard lstat(url.path, &info) == 0 else { return false }
        let type = info.st_mode & S_IFMT
        if type == S_IFLNK { return true }
        // Directories legitimately carry more than one link ("." and ".."),
        // so only files are checked for hard links.
        if type == S_IFDIR { return false }
        return info.st_nlink > 1
    }

    func isRegularFile(at url: URL) -> Bool {
        var info = Darwin.stat()
        guard lstat(url.path, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFREG
    }
}

// MARK: - Store

struct MissionStore {
    let root: URL
    let writer: MissionFileWriting

    init(root: URL, writer: MissionFileWriting = FoundationMissionFileWriter()) {
        self.root = root.standardizedFileURL
        self.writer = writer
    }

    var unitsRoot: URL {
        root.appendingPathComponent(MissionLayout.unitsDirectoryName, isDirectory: true)
    }

    var boundariesRoot: URL {
        root.appendingPathComponent(MissionLayout.boundariesDirectoryName, isDirectory: true)
    }

    var liveCheckpointURL: URL {
        root.appendingPathComponent(MissionLayout.liveCheckpointName)
    }

    var manifestURL: URL {
        root.appendingPathComponent(MissionLayout.manifestName)
    }

    var eventLogURL: URL {
        root.appendingPathComponent(MissionLayout.eventLogName)
    }

    // MARK: Layout

    /// Creates the mission root, `units/` and `boundaries/`. A mission root
    /// that already exists is never adopted: an existing directory means either
    /// a stale mission or a partially cleaned one, and silently reusing it
    /// would risk overwriting a finalized unit.
    @discardableResult
    func createMissionRoot() throws -> URL {
        guard !writer.fileExists(at: root) else {
            throw MissionStoreError.missionRootExists(root.lastPathComponent)
        }
        try writer.createDirectory(at: root)
        try writer.createDirectory(at: unitsRoot)
        try writer.createDirectory(at: boundariesRoot)
        return root
    }

    /// Creates `units/<SupermarketSession-...-U000N>`. The directory must not
    /// exist; a finalized unit is never reopened (§8.2 step 9).
    func createUnitDirectory(stamp: String, unitIndex index: Int) throws -> URL {
        guard index >= 1 else { throw MissionStoreError.invalidUnitIndex(index) }
        let name = MissionLayout.unitDirectoryName(stamp: stamp, unitIndex: index)
        let url = unitsRoot.appendingPathComponent(name, isDirectory: true)
        guard !writer.fileExists(at: url) else {
            throw MissionStoreError.unitDirectoryExists(name)
        }
        if writer.isLink(at: url) { throw MissionStoreError.linkDetected(name) }
        try writer.createDirectory(at: url)
        return url
    }

    func unitURL(name: String) throws -> URL {
        guard !name.isEmpty, name != ".", !name.contains("/") else {
            throw MissionStoreError.pathEscape(name)
        }
        _ = try validatedMissionRelativePath("\(MissionLayout.unitsDirectoryName)/\(name)")
        let url = unitsRoot.appendingPathComponent(name, isDirectory: true)
        guard url.path.hasPrefix(root.path + "/") else {
            throw MissionStoreError.pathEscape(name)
        }
        return url
    }

    // MARK: Checkpoint and manifest

    func writeLiveCheckpoint(_ checkpoint: MissionLiveCheckpoint) throws {
        guard checkpoint.isWellFormed else {
            throw MissionStoreError.checkpointUnreadable("malformed_checkpoint")
        }
        let data = try encodeJSON(checkpoint)
        try writer.writeAtomic(data, to: liveCheckpointURL)
    }

    func readLiveCheckpoint() throws -> MissionLiveCheckpoint? {
        guard writer.fileExists(at: liveCheckpointURL) else { return nil }
        guard !writer.isLink(at: liveCheckpointURL) else {
            throw MissionStoreError.linkDetected(MissionLayout.liveCheckpointName)
        }
        let data: Data
        do {
            data = try writer.read(at: liveCheckpointURL)
        } catch {
            throw MissionStoreError.checkpointUnreadable(error.localizedDescription)
        }
        do {
            let checkpoint = try decodeJSON(MissionLiveCheckpoint.self, from: data)
            guard checkpoint.isWellFormed else {
                throw MissionStoreError.checkpointUnreadable("unsupported_format")
            }
            return checkpoint
        } catch let error as MissionStoreError {
            throw error
        } catch {
            throw MissionStoreError.checkpointUnreadable(error.localizedDescription)
        }
    }

    func appendEvent(_ event: MissionEventRecord) throws {
        var data = try encodeJSON(event)
        data.append(0x0A)
        try writer.append(data, to: eventLogURL)
    }

    /// Writes `boundaries/boundary_NNNN.json` and returns the record with the
    /// file digest filled in. A boundary is only committed atomically once;
    /// the caller must not rewrite a committed boundary (§7.3).
    func writeBoundary(_ boundary: MissionBoundaryRecord, unitIndex index: Int) throws
        -> MissionBoundaryRecord {
        guard index >= 1 else { throw MissionStoreError.invalidUnitIndex(index) }
        guard boundary.isComplete,
              boundary.outgoing?.unitIndex == index,
              boundary.incoming?.unitIndex == index + 1 else {
            throw MissionStoreError.missionNotComplete("boundary_incomplete")
        }
        let url = boundariesRoot.appendingPathComponent(
            MissionLayout.boundaryFileName(unitIndex: index))
        guard !writer.fileExists(at: url) else {
            throw MissionStoreError.unitDirectoryExists(url.lastPathComponent)
        }
        var onDisk = boundary
        onDisk.fileSha256 = nil
        let data = try encodeJSON(onDisk)
        try writer.writeAtomicExclusive(data, to: url)
        var committed = onDisk
        committed.fileSha256 = Self.sha256(of: data)
        return committed
    }

    func readBoundaries() throws -> [MissionBoundaryRecord] {
        guard !writer.isLink(at: boundariesRoot) else {
            throw MissionStoreError.linkDetected(boundariesRoot.lastPathComponent)
        }
        guard writer.directoryExists(at: boundariesRoot) else {
            if writer.fileExists(at: boundariesRoot) {
                throw MissionStoreError.manifestUnreadable(boundariesRoot.lastPathComponent)
            }
            return []
        }
        var records: [MissionBoundaryRecord] = []
        for url in try writer.contentsOfDirectory(at: boundariesRoot) {
            if writer.isLink(at: url) {
                throw MissionStoreError.linkDetected(url.lastPathComponent)
            }
            guard writer.isRegularFile(at: url),
                  url.lastPathComponent.range(
                    of: #"^boundary_[0-9]+\.json$"#, options: .regularExpression) != nil else {
                throw MissionStoreError.manifestUnreadable(url.lastPathComponent)
            }
            let data = try writer.read(at: url)
            var record = try decodeJSON(MissionBoundaryRecord.self, from: data)
            guard record.format == MissionBoundaryRecord.format,
                  record.version == MissionBoundaryRecord.currentVersion else {
                throw MissionStoreError.manifestUnreadable(url.lastPathComponent)
            }
            guard record.isComplete else {
                throw MissionStoreError.manifestUnreadable("boundary_incomplete")
            }
            guard let outgoingIndex = record.outgoing?.unitIndex,
                  url.lastPathComponent
                    == MissionLayout.boundaryFileName(unitIndex: outgoingIndex) else {
                throw MissionStoreError.manifestUnreadable("boundary_filename_mismatch")
            }
            record.fileSha256 = Self.sha256(of: data)
            records.append(record)
        }
        return records.sorted { $0.boundaryId < $1.boundaryId }
    }

    /// Writes the immutable completion manifest. It is the only marker that a
    /// mission finished (§8.3); a running mission keeps only the live
    /// checkpoint and must never produce a manifest.
    func writeManifest(
        missionId: String,
        identity: MissionIdentity,
        units: [MissionUnitDescriptor],
        boundaries: [MissionBoundaryRecord],
        completedAtUnix: TimeInterval
    ) throws -> MissionManifest {
        guard missionId == identity.missionId, !missionId.isEmpty else {
            throw MissionStoreError.missionNotComplete("mission_identity_mismatch")
        }
        guard completedAtUnix.isFinite, completedAtUnix >= 0 else {
            throw MissionStoreError.missionNotComplete("completed_time_invalid")
        }
        guard !writer.fileExists(at: manifestURL), !writer.isLink(at: manifestURL) else {
            throw MissionStoreError.missionNotComplete("manifest_already_exists")
        }
        guard !writer.fileExists(at: liveCheckpointURL), !writer.isLink(at: liveCheckpointURL) else {
            throw MissionStoreError.missionNotComplete("live_checkpoint_present")
        }
        guard !units.isEmpty else {
            throw MissionStoreError.missionNotComplete("no_units")
        }
        guard units.allSatisfy({ $0.finalized }) else {
            throw MissionStoreError.missionNotComplete("unit_not_finalized")
        }
        let structural = validateMissionStructure(
            units: units, boundaries: boundaries, identity: identity)
        guard structural.isEmpty else {
            throw MissionStoreError.missionNotComplete(
                structural.map(\.code).joined(separator: ","))
        }
        for unit in units {
            let verified = try verifiedFinalizedUnit(unit, identity: identity)
            guard verified.databaseSha256 == unit.databaseSha256,
                  verified.metadataSha256 == unit.metadataSha256,
                  verified.unitStorageBytes == unit.unitStorageBytes else {
                throw MissionStoreError.missionNotComplete("unit_file_digest_mismatch")
            }
        }
        let committedBoundaries = try readBoundaries()
        guard committedBoundaries.count == boundaries.count else {
            throw MissionStoreError.missionNotComplete("boundary_file_count_mismatch")
        }
        var committedByID: [String: MissionBoundaryRecord] = [:]
        for boundary in committedBoundaries {
            guard committedByID.updateValue(boundary, forKey: boundary.boundaryId) == nil else {
                throw MissionStoreError.missionNotComplete("duplicate_boundary_file_id")
            }
        }
        for boundary in boundaries {
            guard let committed = committedByID[boundary.boundaryId],
                  committed.fileSha256 == boundary.fileSha256,
                  committed == boundary else {
                throw MissionStoreError.missionNotComplete("boundary_file_mismatch")
            }
        }
        var manifest = MissionManifest(
            missionId: missionId,
            identity: identity,
            units: units.sorted { $0.unitIndex < $1.unitIndex },
            boundaries: boundaries)
        manifest.completedAtUnix = completedAtUnix
        manifest.integrity = "verified"
        manifest.publishPermitted = true
        let data = try encodeJSON(manifest)
        try writer.writeAtomicExclusive(data, to: manifestURL)
        return manifest
    }

    func readManifest() throws -> MissionManifest? {
        guard writer.fileExists(at: manifestURL) else { return nil }
        if writer.isLink(at: manifestURL) {
            throw MissionStoreError.linkDetected(MissionLayout.manifestName)
        }
        let data: Data
        do {
            data = try writer.read(at: manifestURL)
        } catch {
            throw MissionStoreError.manifestUnreadable(error.localizedDescription)
        }
        do {
            let manifest = try decodeJSON(MissionManifest.self, from: data)
            guard manifest.format == MissionManifest.format,
                  manifest.version == MissionManifest.currentVersion else {
                throw MissionStoreError.manifestUnreadable("unsupported_format")
            }
            return manifest
        } catch let error as MissionStoreError {
            throw error
        } catch {
            throw MissionStoreError.manifestUnreadable(error.localizedDescription)
        }
    }

    // MARK: Observation

    /// Inspects `units/` for the recovery planner (§10). Values are read with
    /// `O_NOFOLLOW` semantics through the injected writer so a linked unit
    /// directory is reported instead of being followed.
    func observeUnits() throws -> [MissionRecoveryObservation] {
        guard !writer.isLink(at: unitsRoot) else {
            throw MissionStoreError.linkDetected(unitsRoot.lastPathComponent)
        }
        guard writer.directoryExists(at: unitsRoot) else {
            if writer.fileExists(at: unitsRoot) {
                throw MissionStoreError.unitDirectoryMissing(unitsRoot.lastPathComponent)
            }
            return []
        }
        let directories = try writer.contentsOfDirectory(at: unitsRoot)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var observations: [MissionRecoveryObservation] = []
        for directory in directories {
            let name = directory.lastPathComponent
            // A linked unit directory is never adopted silently: the recovery
            // planner must quarantine it instead of planning a resume.
            if writer.isLink(at: directory) {
                throw MissionStoreError.linkDetected(name)
            }
            guard writer.directoryExists(at: directory) else {
                throw MissionStoreError.unitDirectoryMissing(name)
            }
            let relativePath = "\(MissionLayout.unitsDirectoryName)/\(name)"
            let segment = directory.appendingPathComponent("segment_0001", isDirectory: true)
            let metadataURL = segment.appendingPathComponent("metadata.json")
            let checkpointURL = segment.appendingPathComponent("live_checkpoint.json")
            let databaseURL = segment.appendingPathComponent("rtabmap_segment_0001.db")
            for path in [segment, metadataURL, checkpointURL, databaseURL]
            where writer.isLink(at: path) {
                throw MissionStoreError.linkDetected(path.lastPathComponent)
            }
            var finalized: Bool?
            let metadataPresent = writer.fileExists(at: metadataURL)
            if metadataPresent {
                if let data = try? writer.read(at: metadataURL),
                   let object = try? JSONSerialization.jsonObject(with: data),
                   let dictionary = object as? [String: Any],
                   let value = dictionary["finalized"] as? Bool {
                    finalized = value
                } else {
                    finalized = nil
                }
            }
            observations.append(MissionRecoveryObservation(
                relativePath: relativePath,
                metadataPresent: metadataPresent,
                metadataFinalized: finalized,
                databasePresent: writer.fileExists(at: databaseURL),
                liveCheckpointPresent: writer.fileExists(at: checkpointURL)))
        }
        return observations
    }

    // MARK: Hashing

    static func sha256(of data: Data) -> String {
        var digest = SHA256()
        digest.update(data: data)
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Streams the file in bounded chunks: unit databases are gigabyte-scale
    /// and must never be loaded into memory just to compute a digest.
    func sha256OfFile(at url: URL) throws -> String {
        guard writer.isRegularFile(at: url), !writer.isLink(at: url) else {
            throw MissionStoreError.hashUnavailable(url.lastPathComponent)
        }
        var before = Darwin.stat()
        guard Darwin.lstat(url.path, &before) == 0,
              (before.st_mode & S_IFMT) == S_IFREG,
              before.st_nlink == 1 else {
            throw MissionStoreError.hashUnavailable(url.lastPathComponent)
        }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw MissionStoreError.hashUnavailable(url.lastPathComponent)
        }
        var opened = Darwin.stat()
        guard Darwin.fstat(descriptor, &opened) == 0,
              sameFileIdentity(before, opened) else {
            Darwin.close(descriptor)
            throw MissionStoreError.hashUnavailable(url.lastPathComponent)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        defer { try? handle.close() }
        var digest = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 8 * 1024 * 1024)
            if let chunk, !chunk.isEmpty {
                digest.update(data: chunk)
            } else {
                break
            }
        }
        var afterOpen = Darwin.stat()
        var afterPath = Darwin.stat()
        guard Darwin.fstat(descriptor, &afterOpen) == 0,
              Darwin.lstat(url.path, &afterPath) == 0,
              sameFileIdentity(before, afterOpen),
              sameFileIdentity(before, afterPath) else {
            throw MissionStoreError.hashUnavailable("\(url.lastPathComponent):changed_during_hash")
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func sameFileIdentity(_ lhs: Darwin.stat, _ rhs: Darwin.stat) -> Bool {
        lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_nlink == rhs.st_nlink
    }

    /// Seals a unit descriptor with the digests of the files that were actually
    /// written. The hash chain (`previousUnitMetadataSha256`) is only as strong
    /// as this call: a unit that reaches the manifest without it would let the
    /// PC validate a chain of `nil`s.
    func finalizedUnitDescriptor(
        _ unit: MissionUnitDescriptor,
        finalizedAtUnix: TimeInterval
    ) throws -> MissionUnitDescriptor {
        guard finalizedAtUnix.isFinite, finalizedAtUnix >= 0 else {
            throw MissionStoreError.missionNotComplete("finalized_time_invalid")
        }
        var sealed = unit
        let databaseURL = try safeFileURL(relativePath: unit.databaseRelativePath)
        let metadataURL = try safeFileURL(relativePath: unit.metadataRelativePath)
        let metadataData = try writer.read(at: metadataURL)
        guard let metadata = try JSONSerialization.jsonObject(with: metadataData)
                as? [String: Any],
              metadata["finalized"] as? Bool == true else {
            throw MissionStoreError.missionNotComplete("metadata_not_finalized")
        }
        sealed.databaseSha256 = try sha256OfFile(at: databaseURL)
        sealed.metadataSha256 = try sha256OfFile(at: metadataURL)
        sealed.unitStorageBytes = try totalRegularFileBytes(
            under: root.appendingPathComponent(unit.relativePath, isDirectory: true))
        sealed.finalized = true
        sealed.finalizedAtUnix = finalizedAtUnix
        return sealed
    }

    private func verifiedFinalizedUnit(
        _ unit: MissionUnitDescriptor,
        identity: MissionIdentity
    ) throws -> MissionUnitDescriptor {
        let metadataURL = try safeFileURL(relativePath: unit.metadataRelativePath)
        let data = try writer.read(at: metadataURL)
        guard let metadata = try JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              metadata["finalized"] as? Bool == true,
              metadata["scanMode"] as? String == "continuous_streaming",
              metadata["workflowMode"] as? String == "prior_map_localized",
              metadata["missionId"] as? String == identity.missionId,
              metadata["unitId"] as? String == unit.unitId,
              metadata["unitIndex"] as? Int == unit.unitIndex,
              metadata["trackingSessionId"] as? String == unit.trackingSessionId,
              metadata["priorMapId"] as? String == identity.priorMapId,
              metadata["priorMapSha256"] as? String == identity.priorMapPackageSha256,
              metadata["storeId"] as? String == identity.storeId,
              metadata["floorId"] as? String == identity.floorId,
              (metadata["buildIdentity"] as? String
                ?? metadata["appGitSHA"] as? String) == identity.buildIdentity,
              metadata["previousUnitId"] as? String == unit.previousUnitId,
              metadata["previousUnitMetadataSha256"] as? String
                == unit.previousUnitMetadataSha256 else {
            throw MissionStoreError.missionNotComplete("unit_metadata_identity_mismatch")
        }
        try validateRequiredSidecars(
            segment: metadataURL.deletingLastPathComponent(), unit: unit)
        return try finalizedUnitDescriptor(
            unit, finalizedAtUnix: unit.finalizedAtUnix ?? -1)
    }

    private func validateRequiredSidecars(
        segment: URL,
        unit: MissionUnitDescriptor
    ) throws {
        let databaseURL = try safeFileURL(relativePath: unit.databaseRelativePath)
        for suffix in ["-wal", "-shm", "-journal"]
        where writer.fileExists(at: URL(fileURLWithPath: databaseURL.path + suffix)) {
            throw MissionStoreError.missionNotComplete("database_residue_present")
        }
        let jsonShapes: [(String, Bool)] = [
            ("price_tags.json", true),
            ("scan_area_cells.json", false),
            ("structure_coverage_cells.json", false),
            ("trajectory_samples.json", true)
        ]
        for (name, allowsArray) in jsonShapes {
            let url = segment.appendingPathComponent(name)
            guard writer.isRegularFile(at: url), !writer.isLink(at: url) else {
                throw MissionStoreError.missionNotComplete("sidecar_missing:\(name)")
            }
            let object = try JSONSerialization.jsonObject(with: writer.read(at: url))
            let valid = object is [String: Any] || (allowsArray && object is [Any])
            guard valid else {
                throw MissionStoreError.missionNotComplete("sidecar_shape_invalid:\(name)")
            }
        }
        for name in ["price_tags.csv", "trajectory_samples.csv"] {
            let url = segment.appendingPathComponent(name)
            guard writer.isRegularFile(at: url), !writer.isLink(at: url) else {
                throw MissionStoreError.missionNotComplete("sidecar_missing:\(name)")
            }
            let data = try writer.read(at: url)
            guard String(data: data, encoding: .utf8) != nil,
                  data.isEmpty || data.last == 0x0A else {
                throw MissionStoreError.missionNotComplete("sidecar_text_invalid:\(name)")
            }
        }
        let eventsURL = segment.appendingPathComponent("scan_events.jsonl")
        guard writer.isRegularFile(at: eventsURL), !writer.isLink(at: eventsURL) else {
            throw MissionStoreError.missionNotComplete("sidecar_missing:scan_events.jsonl")
        }
        let eventData = try writer.read(at: eventsURL)
        guard !eventData.isEmpty, eventData.last == 0x0A,
              let eventText = String(data: eventData, encoding: .utf8) else {
            throw MissionStoreError.missionNotComplete("sidecar_text_invalid:scan_events.jsonl")
        }
        for line in eventText.split(separator: "\n", omittingEmptySubsequences: false).dropLast() {
            guard !line.isEmpty,
                  let object = try JSONSerialization.jsonObject(with: Data(line.utf8))
                    as? [String: Any],
                  !object.isEmpty else {
                throw MissionStoreError.missionNotComplete("sidecar_jsonl_invalid:scan_events.jsonl")
            }
        }
    }

    private func totalRegularFileBytes(under directory: URL) throws -> UInt64 {
        guard writer.directoryExists(at: directory), !writer.isLink(at: directory) else {
            throw MissionStoreError.unitDirectoryMissing(directory.lastPathComponent)
        }
        var pending = [directory]
        var total: UInt64 = 0
        while let current = pending.popLast() {
            for child in try writer.contentsOfDirectory(at: current) {
                if writer.isLink(at: child) {
                    throw MissionStoreError.linkDetected(child.lastPathComponent)
                }
                if writer.directoryExists(at: child) {
                    pending.append(child)
                } else {
                    guard writer.isRegularFile(at: child) else {
                        throw MissionStoreError.hashUnavailable(child.lastPathComponent)
                    }
                    var before = Darwin.stat()
                    guard Darwin.lstat(child.path, &before) == 0,
                          (before.st_mode & S_IFMT) == S_IFREG,
                          before.st_nlink == 1,
                          before.st_size >= 0 else {
                        throw MissionStoreError.hashUnavailable(child.lastPathComponent)
                    }
                    var after = Darwin.stat()
                    guard Darwin.lstat(child.path, &after) == 0,
                          sameFileIdentity(before, after) else {
                        throw MissionStoreError.hashUnavailable(
                            "\(child.lastPathComponent):changed_during_size")
                    }
                    let added = total.addingReportingOverflow(UInt64(before.st_size))
                    guard !added.overflow else {
                        throw MissionStoreError.hashUnavailable("unit_size_overflow")
                    }
                    total = added.partialValue
                }
            }
        }
        return total
    }

    private func safeFileURL(relativePath: String) throws -> URL {
        _ = try validatedMissionRelativePath(relativePath)
        var cursor = root
        for component in relativePath.split(separator: "/") {
            cursor.appendPathComponent(String(component))
            if writer.isLink(at: cursor) {
                throw MissionStoreError.linkDetected(String(component))
            }
        }
        let url = root.appendingPathComponent(relativePath).standardizedFileURL
        guard url.path.hasPrefix(root.path + "/"),
              writer.isRegularFile(at: url),
              !writer.isLink(at: url) else {
            throw MissionStoreError.pathEscape(relativePath)
        }
        return url
    }

    // MARK: Encoding

    private func encodeJSON<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private func decodeJSON<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        return try decoder.decode(type, from: data)
    }
}
