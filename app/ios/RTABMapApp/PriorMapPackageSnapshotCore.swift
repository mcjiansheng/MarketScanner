// P7R6C: one immutable snapshot for a prior-map package.
//
// Previously the integrity validator hashed each artifact with one read
// and parsed it with another (Data(contentsOf:) re-opens), and
// PriorMapPackage.load re-read everything a third time. Any replacement
// in between (file provider sync, concurrent write, recovery replay)
// produced hash-A/parse-B evidence: the returned package SHA described
// bytes the consumer never parsed.
//
// The snapshot reader reads every authoritative artifact exactly once
// through the descriptor-bound safe path (no-follow, regular file,
// st_nlink == 1, size bounded, pre/post read identity), hashes those
// exact bytes, strictly parses the same bytes (UTF-8, duplicate keys,
// bounded depth) and lets both the integrity validator and the package
// loader consume the same parsed snapshot.

import Foundation
import CryptoKit

/// Frozen size contract for prior-map package artifacts.
enum PriorMapPackageSnapshotLimits {
    static let packageManifestBytes = 2 * 1024 * 1024
    static let jsonArtifactBytes = 64 * 1024 * 1024
    static let previewArtifactBytes = 64 * 1024 * 1024
    static let totalPackageBytes = 512 * 1024 * 1024
    static let maximumArtifacts = 128
}

struct PriorMapArtifactSnapshot {
    let name: String
    let bytes: Data
    let byteCount: Int64
    let sha256: String
    let parsedJSON: [String: Any]?
    let device: UInt64
    let inode: UInt64
}

struct PriorMapPackageSnapshot {
    let directory: URL
    let packageManifest: [String: Any]
    let artifactsByName: [String: PriorMapArtifactSnapshot]
    let artifactNames: Set<String>
}

enum PriorMapPackageSnapshotError: Error, Equatable {
    case manifestUnreadable
    case manifestContractInvalid
    case artifactUnreadable(name: String)
    case artifactNotObject(name: String)
    case artifactDuplicateKey(name: String)
    case artifactInvalidUTF8(name: String)
    case artifactInvalidJSON(name: String)
    case artifactTooLarge(name: String)
    case packageTooLarge
    case tooManyArtifacts
    case fileSetChanged
}

enum PriorMapPackageSnapshotReader {
    static let packageManifestName = "package_manifest.json"

    /// Reads the whole package once. The manifest's declared artifact
    /// names drive the read list; every artifact is read exactly once and
    /// its bytes are both hashed and (for JSON) strictly parsed.
    static func read(
        directory: URL
    ) throws -> PriorMapPackageSnapshot {
        let manifestSnapshot = try stableRead(
            directory.appendingPathComponent(packageManifestName),
            within: directory,
            maximumBytes: Int64(PriorMapPackageSnapshotLimits
                .packageManifestBytes),
            name: packageManifestName)
        let manifest: [String: Any]
        do {
            manifest = try StrictJSONDocumentParser.object(
                from: manifestSnapshot.bytes,
                limits: StrictJSONDocumentLimits(
                    maximumBytes: PriorMapPackageSnapshotLimits
                        .packageManifestBytes))
        }
        catch StrictJSONDocumentParseError.documentTooLarge {
            throw PriorMapPackageSnapshotError.artifactTooLarge(
                name: packageManifestName)
        }
        catch StrictJSONDocumentParseError.duplicateJSONKey {
            throw PriorMapPackageSnapshotError.artifactDuplicateKey(
                name: packageManifestName)
        }
        catch StrictJSONDocumentParseError.invalidUTF8 {
            throw PriorMapPackageSnapshotError.artifactInvalidUTF8(
                name: packageManifestName)
        }
        catch StrictJSONDocumentParseError.topLevelTypeMismatch {
            throw PriorMapPackageSnapshotError.artifactNotObject(
                name: packageManifestName)
        }
        catch is StrictJSONDocumentParseError {
            throw PriorMapPackageSnapshotError.artifactInvalidJSON(
                name: packageManifestName)
        }
        guard let artifacts = manifest["artifacts"] as? [[String: Any]],
              artifacts.count
                  <= PriorMapPackageSnapshotLimits.maximumArtifacts,
              artifacts.allSatisfy({
                      ($0["file"] as? String) != nil })
        else {
            throw PriorMapPackageSnapshotError.manifestContractInvalid
        }
        let names = artifacts.compactMap { $0["file"] as? String }
        // Every artifact must be a direct child of the package directory
        // with a safe, unique, non-manifest name.
        guard Set(names).count == names.count,
              names.allSatisfy({
                  !$0.isEmpty
                      && URL(fileURLWithPath: $0).lastPathComponent == $0
                      && $0 != packageManifestName
              })
        else {
            throw PriorMapPackageSnapshotError.manifestContractInvalid
        }
        // The directory file set is captured before and after the reads;
        // any change while reading fails the whole snapshot.
        let fileSetBefore = try regularFileNames(in: directory)
        var artifactsByName: [String: PriorMapArtifactSnapshot] = [:]
        var totalBytes: Int64 = Int64(manifestSnapshot.bytes.count)
        for name in names {
            let isJSON = name.lowercased().hasSuffix(".json")
            let limit = isJSON
                ? Int64(PriorMapPackageSnapshotLimits.jsonArtifactBytes)
                : Int64(PriorMapPackageSnapshotLimits.previewArtifactBytes)
            let artifact = try stableRead(
                directory.appendingPathComponent(name),
                within: directory,
                maximumBytes: limit,
                name: name)
            totalBytes += artifact.byteCount
            guard totalBytes
                    <= Int64(PriorMapPackageSnapshotLimits.totalPackageBytes)
            else {
                throw PriorMapPackageSnapshotError.packageTooLarge
            }
            let parsedJSON: [String: Any]?
            if isJSON {
                do {
                    parsedJSON = try StrictJSONDocumentParser.object(
                        from: artifact.bytes,
                        limits: StrictJSONDocumentLimits(
                            maximumBytes: Int(limit)))
                }
                catch StrictJSONDocumentParseError.duplicateJSONKey {
                    throw PriorMapPackageSnapshotError.artifactDuplicateKey(
                        name: name)
                }
                catch StrictJSONDocumentParseError.invalidUTF8 {
                    throw PriorMapPackageSnapshotError.artifactInvalidUTF8(
                        name: name)
                }
                catch StrictJSONDocumentParseError.topLevelTypeMismatch {
                    throw PriorMapPackageSnapshotError.artifactNotObject(
                        name: name)
                }
                catch is StrictJSONDocumentParseError {
                    throw PriorMapPackageSnapshotError.artifactInvalidJSON(
                        name: name)
                }
            }
            else {
                parsedJSON = nil
            }
            artifactsByName[name] = PriorMapArtifactSnapshot(
                name: name,
                bytes: artifact.bytes,
                byteCount: artifact.byteCount,
                sha256: artifact.sha256,
                parsedJSON: parsedJSON,
                device: artifact.device,
                inode: artifact.inode)
        }
        let fileSetAfter = try regularFileNames(in: directory)
        guard fileSetBefore == fileSetAfter else {
            throw PriorMapPackageSnapshotError.fileSetChanged
        }
        return PriorMapPackageSnapshot(
            directory: directory,
            packageManifest: manifest,
            artifactsByName: artifactsByName,
            artifactNames: fileSetBefore)
    }

    private struct StableArtifactBytes {
        let bytes: Data
        let byteCount: Int64
        let sha256: String
        let device: UInt64
        let inode: UInt64
    }

    private static func stableRead(
        _ url: URL,
        within root: URL,
        maximumBytes: Int64,
        name: String
    ) throws -> StableArtifactBytes {
        do {
            let snapshot = try SafeSessionPath.readRegularFile(
                url,
                within: root,
                maximumBytes: maximumBytes)
            return StableArtifactBytes(
                bytes: snapshot.data,
                byteCount: snapshot.byteCount,
                sha256: snapshot.sha256,
                device: snapshot.device,
                inode: snapshot.inode)
        }
        catch {
            throw PriorMapPackageSnapshotError.artifactUnreadable(
                name: name)
        }
    }

    /// Lists regular files directly inside the package directory,
    /// ignoring macOS metadata noise, matching the integrity validator's
    /// authoritative-file definition.
    private static func regularFileNames(in directory: URL) throws -> Set<String> {
        do {
            let urls = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [])
            return Set(
                urls.filter {
                    (try? $0.resourceValues(forKeys: [.isRegularFileKey])
                        .isRegularFile) == true
                        && $0.lastPathComponent != packageManifestName
                        && $0.lastPathComponent != ".DS_Store"
                        && !$0.lastPathComponent.hasPrefix("._")
                }.map(\.lastPathComponent))
        }
        catch {
            throw PriorMapPackageSnapshotError.fileSetChanged
        }
    }
}
