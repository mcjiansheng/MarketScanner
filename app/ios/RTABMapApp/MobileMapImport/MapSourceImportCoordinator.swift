import Foundation
import Darwin

/// Reads an app-private staged import through one no-follow descriptor.
/// The bounded chunked read and pre/post identity checks prevent mmap
/// races, symlink/hardlink substitution, truncation and replacement.
enum StableMapSourceFileReader {
    private struct Identity: Equatable {
        let device: dev_t
        let inode: ino_t
        let size: off_t
        let modificationSeconds: Int
        let modificationNanoseconds: Int
        let changeSeconds: Int
        let changeNanoseconds: Int

        init(_ value: stat) {
            device = value.st_dev
            inode = value.st_ino
            size = value.st_size
            modificationSeconds = value.st_mtimespec.tv_sec
            modificationNanoseconds = value.st_mtimespec.tv_nsec
            changeSeconds = value.st_ctimespec.tv_sec
            changeNanoseconds = value.st_ctimespec.tv_nsec
        }
    }

    static func read(
        _ url: URL,
        maximumBytes: Int64 = MapSourceImportLimits.maximumSourceFileBytes
    ) throws -> Data {
        var pathBefore = stat()
        guard lstat(url.path, &pathBefore) == 0 else {
            throw MapSourceImportError.unreadableSource(
                reason: "cannot inspect staged source")
        }
        guard isSingleRegularFile(pathBefore) else {
            throw MapSourceImportError.unreadableSource(
                reason: "staged source is not a single regular file")
        }

        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw MapSourceImportError.unreadableSource(
                reason: "cannot open staged source without following links")
        }
        var needsClose = true
        defer {
            if needsClose { _ = close(descriptor) }
        }

        var descriptorBefore = stat()
        guard fstat(descriptor, &descriptorBefore) == 0,
              isSingleRegularFile(descriptorBefore),
              Identity(descriptorBefore) == Identity(pathBefore) else {
            throw MapSourceImportError.unreadableSource(
                reason: "staged source identity changed before read")
        }
        guard descriptorBefore.st_size >= 0 else {
            throw MapSourceImportError.unreadableSource(
                reason: "staged source has an invalid size")
        }
        guard descriptorBefore.st_size <= maximumBytes else {
            throw MapSourceImportError.fileTooLarge(limitBytes: maximumBytes)
        }

        var data = Data()
        data.reserveCapacity(Int(descriptorBefore.st_size))
        var buffer = [UInt8](repeating: 0, count: 256 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { rawBuffer -> Int in
                while true {
                    let result = Darwin.read(
                        descriptor, rawBuffer.baseAddress, rawBuffer.count)
                    if result < 0 && errno == EINTR { continue }
                    return result
                }
            }
            guard count >= 0 else {
                throw MapSourceImportError.unreadableSource(
                    reason: "staged source read failed")
            }
            if count == 0 { break }
            guard Int64(data.count) + Int64(count) <= maximumBytes else {
                throw MapSourceImportError.fileTooLarge(limitBytes: maximumBytes)
            }
            buffer.withUnsafeBytes { rawBuffer in
                data.append(
                    rawBuffer.bindMemory(to: UInt8.self).baseAddress!,
                    count: count)
            }
        }

        var descriptorAfter = stat()
        var pathAfter = stat()
        guard fstat(descriptor, &descriptorAfter) == 0,
              lstat(url.path, &pathAfter) == 0,
              isSingleRegularFile(descriptorAfter),
              isSingleRegularFile(pathAfter),
              Identity(descriptorBefore) == Identity(descriptorAfter),
              Identity(descriptorBefore) == Identity(pathAfter),
              Int64(data.count) == Int64(descriptorBefore.st_size) else {
            throw MapSourceImportError.unreadableSource(
                reason: "staged source changed while it was read")
        }
        guard close(descriptor) == 0 else {
            throw MapSourceImportError.unreadableSource(
                reason: "cannot close staged source")
        }
        needsClose = false
        return data
    }

    private static func isSingleRegularFile(_ value: stat) -> Bool {
        return (value.st_mode & S_IFMT) == S_IFREG && value.st_nlink == 1
    }
}

/// Orchestrates a map-source import from a stable, app-private staged
/// copy of the provider document.
///
/// The document picker (UIKit layer) is responsible for acquiring the
/// security-scoped resource and copying it into the app staging
/// directory; this coordinator never reads the provider URL. It
/// identifies the format, runs the matching importer, computes the
/// canonical source digest and produces a `MapSourceImportReport`.
enum MapSourceImportCoordinator {
    static func importMap(
        stagedURL: URL,
        originalFilename: String,
        contract: CoordinateContract,
        storeId: String? = nil,
        mapName: String? = nil,
        strict: Bool = true
    ) throws -> MapSourceImportReport {
        let data: Data
        do {
            data = try StableMapSourceFileReader.read(stagedURL)
        } catch let error as MapSourceImportError {
            throw error
        } catch {
            throw MapSourceImportError.unreadableSource(
                reason: "stable staged-source read failed")
        }
        let fileSize = Int64(data.count)
        let sourceFileSha256 = CanonicalSourceHasher.sha256(data)
        let format = try detectFormat(filename: originalFilename, data: data)

        // V1R5 §13.5 (review H-13): the store ID is business identity —
        // a defaulted "default" can collide across stores and sessions.
        // XLSX/CSV imports REQUIRE an explicit, user-confirmed store ID;
        // canonical JSON carries its own identity and overrides below.
        guard format == "json" || (storeId.map({ !$0.isEmpty }) ?? false) else {
            throw MapSourceImportError.storeIDRequired
        }
        let resolvedStoreId = storeId ?? "default"
        let resolvedMapName = mapName
            ?? (originalFilename as NSString).deletingPathExtension

        let outcome: MapSourceImportOutcome
        switch format {
        case "xlsx":
            let imported = try XLSXMapSourceImporter.importSource(
                data: data, contract: contract, strict: strict)
            outcome = MapSourceImportOutcome(
                storeId: nil,
                mapName: nil,
                coordinateContract: nil,
                elements: imported.elements,
                warnings: imported.warnings,
                malformedRows: imported.malformedRows,
                jsonSourceIdentity: nil
            )
        case "csv":
            let imported = try CSVMapSourceImporter.importSource(
                data: data, contract: contract, strict: strict)
            outcome = MapSourceImportOutcome(
                storeId: nil,
                mapName: nil,
                coordinateContract: nil,
                elements: imported.elements,
                warnings: imported.warnings,
                malformedRows: imported.malformedRows,
                jsonSourceIdentity: nil
            )
        case "json":
            let imported = try JSONMapSourceImporter.importSource(data: data)
            outcome = MapSourceImportOutcome(
                storeId: imported.storeId,
                mapName: imported.mapName,
                coordinateContract: imported.coordinateContract,
                elements: imported.elements,
                warnings: imported.warnings,
                malformedRows: [],
                jsonSourceIdentity: imported.sourceIdentity
            )
        default:
            throw MapSourceImportError.unknownFormat
        }

        // V1R4 §14.1: canonical v2 documents carry their own identity
        // (store/map/contract) and override the wizard parameters so the
        // canonical self round trip is byte-identical. Legacy v1 and
        // XLSX/CSV documents keep the caller-provided values.
        let finalStoreID = outcome.storeId ?? resolvedStoreId
        let finalMapName = outcome.mapName ?? resolvedMapName
        let finalContract = outcome.coordinateContract ?? contract
        try MapSourceBusinessIdentityPolicy.validate(
            storeID: finalStoreID, mapName: finalMapName)

        // V1R4 §14.1: official element ids must be globally unique in the
        // store/map context; a duplicate identity is a blocker, never a
        // merge.
        var seenStableIDs: Set<String> = []
        for element in outcome.elements {
            let stableID = CanonicalPriorMapBusinessSourceV2.stableElementID(
                for: element, storeID: finalStoreID, mapName: finalMapName)
            guard seenStableIDs.insert(stableID).inserted else {
                throw MapSourceImportError.duplicateElementIdentity(duplicateID: stableID)
            }
        }

        var warnings = outcome.warnings
        let floors = Set(outcome.elements.map { $0.floorId }).sorted()
        let canonicalSource = MarketScannerPriorMapSource(
            format: MarketScannerPriorMapSource.formatValue,
            version: MarketScannerPriorMapSource.versionValue,
            storeId: finalStoreID,
            mapName: finalMapName,
            source: MapSourceIdentity(
                originalFormat: format,
                originalFilename: originalFilename,
                sourceFileSha256: sourceFileSha256,
                canonicalSourceSha256: ""
            ),
            coordinateContract: finalContract,
            elements: outcome.elements,
            warnings: warnings
        )

        let canonicalPayload = canonicalSource.canonicalPayload
        let canonicalData = try CanonicalJSONEncoder.encode(canonicalPayload)
        let canonicalSha256 = CanonicalSourceHasher.sha256(canonicalData)

        let finalSource = MarketScannerPriorMapSource(
            format: canonicalSource.format,
            version: canonicalSource.version,
            storeId: finalStoreID,
            mapName: finalMapName,
            source: MapSourceIdentity(
                originalFormat: format,
                originalFilename: originalFilename,
                sourceFileSha256: sourceFileSha256,
                canonicalSourceSha256: canonicalSha256
            ),
            coordinateContract: finalContract,
            elements: outcome.elements,
            warnings: warnings
        )

        return MapSourceImportReport(
            format: format,
            fileSizeBytes: fileSize,
            mapName: finalMapName,
            storeId: finalStoreID,
            floorCount: floors.count,
            elementCount: outcome.elements.count,
            sourceFileSha256: sourceFileSha256,
            canonicalSourceSha256: canonicalSha256,
            warningCount: warnings.count,
            malformedRowCount: outcome.malformedRows.count,
            coordinateContractOrigin: finalContract.origin.rawValue,
            canonicalSource: finalSource,
            audit: MapImportAudit(
                format: format,
                sourceRows: outcome.elements.map { $0.sourceRow },
                warnings: outcome.warnings,
                rawFields: outcome.elements.map { $0.source }))
    }

    static func detectFormat(filename: String, data: Data) throws -> String {
        let lowercased = filename.lowercased()
        if lowercased.hasSuffix(".xlsx") {
            return "xlsx"
        }
        if lowercased.hasSuffix(".csv") {
            return "csv"
        }
        if lowercased.hasSuffix(".json") {
            return "json"
        }
        // Magic-byte fallback: ZIP header for xlsx, leading { or [ for JSON.
        if data.count >= 4,
           data[0] == 0x50, data[1] == 0x4B,
           data[2] == 0x03 || data[2] == 0x05 || data[2] == 0x07 {
            return "xlsx"
        }
        if let first = data.first, first == 0x7B || first == 0x5B {
            return "json"
        }
        throw MapSourceImportError.unknownFormat
    }
}

private struct MapSourceImportOutcome {
    /// Document-level identity for canonical v2 JSON documents; nil for
    /// legacy v1 and XLSX/CSV (caller-provided parameters win).
    var storeId: String?
    var mapName: String?
    var coordinateContract: CoordinateContract?
    var elements: [PriorMapSourceElement]
    var warnings: [MapSourceWarning]
    var malformedRows: [[String: Any]]
    var jsonSourceIdentity: MapSourceIdentity?
}
