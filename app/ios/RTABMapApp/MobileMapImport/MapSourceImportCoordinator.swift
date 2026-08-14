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
            let appended = buffer.withUnsafeBytes { rawBuffer -> Bool in
                guard let baseAddress = rawBuffer.bindMemory(
                        to: UInt8.self).baseAddress else {
                    return false
                }
                data.append(baseAddress, count: count)
                return true
            }
            guard appended else {
                throw MapSourceImportError.unreadableSource(
                    reason: "staged source buffer was unavailable")
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
        strict: Bool = true,
        allowLegacyXLSX: Bool = false
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

        let resolvedMapName = mapName
            ?? (originalFilename as NSString).deletingPathExtension

        let outcome: MapSourceImportOutcome
        switch format {
        case "xlsx":
            let imported = try XLSXMapSourceImporter.importSource(
                data: data,
                contract: contract,
                strict: strict,
                allowLegacyElementOnly: allowLegacyXLSX)
            if let basic = imported.basicInfo {
                if let storeId = storeId, storeId != basic.storeCode {
                    throw MapSourceImportError.invalidBusinessIdentity(
                        field: "store_id",
                        reason: "must exactly match Basic Info.storeCode")
                }
                if let mapName = mapName, mapName != basic.mapName {
                    throw MapSourceImportError.invalidBusinessIdentity(
                        field: "map_name",
                        reason: "must exactly match Basic Info.map_name")
                }
            }
            outcome = MapSourceImportOutcome(
                storeId: imported.basicInfo?.storeCode,
                mapName: imported.basicInfo?.mapName,
                coordinateContract: imported.basicInfo == nil ? nil : .topLeft,
                sourceMapInfo: imported.basicInfo,
                elements: imported.elements,
                ignoredElements: imported.ignoredElements,
                auditElements: imported.elements + imported.ignoredElements,
                warnings: imported.warnings,
                malformedRows: imported.malformedRows,
                legacyShelfInfoPresent: imported.legacyShelfInfoPresent,
                legacyShelfInfoRowCount: imported.legacyShelfInfoRowCount,
                sourceElementCount: imported.sourceElementCount,
                jsonSourceIdentity: nil
            )
        case "csv":
            let imported = try CSVMapSourceImporter.importSource(
                data: data, contract: contract, strict: strict)
            outcome = MapSourceImportOutcome(
                storeId: nil,
                mapName: nil,
                coordinateContract: nil,
                sourceMapInfo: nil,
                elements: imported.elements,
                ignoredElements: [],
                auditElements: imported.elements,
                warnings: imported.warnings,
                malformedRows: imported.malformedRows,
                legacyShelfInfoPresent: false,
                legacyShelfInfoRowCount: 0,
                sourceElementCount: imported.elements.count,
                jsonSourceIdentity: nil
            )
        case "json":
            let imported = try JSONMapSourceImporter.importSource(data: data)
            outcome = MapSourceImportOutcome(
                storeId: imported.storeId,
                mapName: imported.mapName,
                coordinateContract: imported.coordinateContract,
                sourceMapInfo: imported.sourceMapInfo,
                elements: imported.elements,
                ignoredElements: [],
                auditElements: imported.elements,
                warnings: imported.warnings,
                malformedRows: [],
                legacyShelfInfoPresent: false,
                legacyShelfInfoRowCount: 0,
                sourceElementCount: imported.elements.count,
                jsonSourceIdentity: imported.sourceIdentity
            )
        default:
            throw MapSourceImportError.unknownFormat
        }

        // V1R4 §14.1: canonical v2 documents carry their own identity
        // (store/map/contract) and override the wizard parameters so the
        // canonical self round trip is byte-identical. Legacy v1 and
        // XLSX/CSV documents keep the caller-provided values.
        guard let finalStoreID = outcome.storeId ?? storeId,
              !finalStoreID.isEmpty else {
            // Standard XLSX obtains identity from Basic Info. CSV and
            // explicit legacy XLSX still require caller confirmation.
            throw MapSourceImportError.storeIDRequired
        }
        let finalMapName = outcome.mapName ?? resolvedMapName
        let finalContract = outcome.coordinateContract ?? contract
        try MapSourceBusinessIdentityPolicy.validate(
            storeID: finalStoreID, mapName: finalMapName)

        // V1R4 §14.1: official element ids must be globally unique in the
        // store/map context; a duplicate identity is a blocker, never a
        // merge.
        var warnings = outcome.warnings
        let filtered = ElementRoleClassifier.productionElements(
            from: outcome.elements, warnings: &warnings)
        let productionElements = filtered.active
        let ignoredElements = outcome.ignoredElements + filtered.ignored
        var ignoredByShapeType: [String: Int] = [:]
        for element in outcome.auditElements
        where ElementRoleClassifier.role(for: element.shapeType) == .presentationOnly {
            ignoredByShapeType[element.shapeType, default: 0] += 1
        }
        let importSummary = SourceImportSummary(
            sourceElementCount: outcome.sourceElementCount,
            presentationIgnoredCount: ignoredByShapeType.values.reduce(0, +),
            unsupportedIgnoredCount: outcome.auditElements.filter {
                ElementRoleClassifier.role(for: $0.shapeType) == .unsupported
            }.count,
            hiddenElementCount: outcome.auditElements.filter {
                ElementRoleClassifier.role(for: $0.shapeType).isProduction && !$0.visible
            }.count,
            invalidGeometryIgnoredCount: outcome.auditElements.filter {
                ElementRoleClassifier.role(for: $0.shapeType).isProduction
                    && $0.visible && $0.geometry == nil
            }.count,
            ignoredByShapeType: ignoredByShapeType,
            legacyShelfInfoPresent: outcome.legacyShelfInfoPresent,
            legacyShelfInfoRowCount: outcome.legacyShelfInfoRowCount,
            malformedRowCount: outcome.malformedRows.count)
        var seenStableIDs: Set<String> = []
        for element in productionElements {
            let stableID = CanonicalPriorMapBusinessSourceV2.stableElementID(
                for: element, storeID: finalStoreID, mapName: finalMapName)
            guard seenStableIDs.insert(stableID).inserted else {
                throw MapSourceImportError.duplicateElementIdentity(duplicateID: stableID)
            }
        }
        if strict {
            for element in productionElements {
                guard SourceGeometry.validatedProductionGeometryPoints(
                        shapeType: element.shapeType,
                        geometry: element.geometry) != nil,
                      element.bounds != nil else {
                    throw MapSourceImportError.invalidGeometry(
                        shapeType: element.shapeType,
                        reason: "active production element geometry kind, point count, or coordinates are invalid")
                }
                if let mapInfo = outcome.sourceMapInfo,
                   !SourceGeometry.contains(
                    geometry: element.geometry,
                    in: mapInfo.sourceCanvasBounds) {
                    throw MapSourceImportError.invalidGeometry(
                        shapeType: element.shapeType,
                        reason: "active geometry is outside Basic Info source canvas")
                }
            }
        }

        let floors = Set(productionElements.map { $0.floorId }).sorted()
        let canonicalSource = MarketScannerPriorMapSource(
            format: MarketScannerPriorMapSource.formatValue,
            version: outcome.sourceMapInfo == nil
                ? CanonicalPriorMapBusinessSourceV2.versionValue
                : CanonicalPriorMapBusinessSourceV3.versionValue,
            storeId: finalStoreID,
            mapName: finalMapName,
            source: MapSourceIdentity(
                originalFormat: format,
                originalFilename: originalFilename,
                sourceFileSha256: sourceFileSha256,
                canonicalSourceSha256: ""
            ),
            coordinateContract: finalContract,
            sourceMapInfo: outcome.sourceMapInfo,
            importSummary: importSummary,
            elements: productionElements,
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
            sourceMapInfo: outcome.sourceMapInfo,
            importSummary: importSummary,
            elements: productionElements,
            warnings: warnings
        )

        return MapSourceImportReport(
            format: format,
            fileSizeBytes: fileSize,
            mapName: finalMapName,
            storeId: finalStoreID,
            floorCount: floors.count,
            elementCount: productionElements.count,
            sourceFileSha256: sourceFileSha256,
            canonicalSourceSha256: canonicalSha256,
            warningCount: warnings.count,
            malformedRowCount: outcome.malformedRows.count,
            coordinateContractOrigin: finalContract.origin.rawValue,
            ignoredElementCount: ignoredElements.count,
            legacyShelfInfoPresent: outcome.legacyShelfInfoPresent,
            legacyShelfInfoRowCount: outcome.legacyShelfInfoRowCount,
            sourceCanvasBounds: outcome.sourceMapInfo?.sourceCanvasBounds.asDictionary,
            canonicalSource: finalSource,
            audit: MapImportAudit(
                format: format,
                sourceRows: outcome.auditElements.map { $0.sourceRow },
                warnings: warnings,
                rawFields: outcome.auditElements.map { $0.source },
                ignoredElementCount: ignoredElements.count,
                legacyShelfInfoPresent: outcome.legacyShelfInfoPresent,
                legacyShelfInfoRowCount: outcome.legacyShelfInfoRowCount,
                sourceElementCount: outcome.sourceElementCount))
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
    var sourceMapInfo: SourceMapInfo?
    var elements: [PriorMapSourceElement]
    var ignoredElements: [PriorMapSourceElement]
    var auditElements: [PriorMapSourceElement]
    var warnings: [MapSourceWarning]
    var malformedRows: [[String: Any]]
    var legacyShelfInfoPresent: Bool
    var legacyShelfInfoRowCount: Int
    var sourceElementCount: Int
    var jsonSourceIdentity: MapSourceIdentity?
}
