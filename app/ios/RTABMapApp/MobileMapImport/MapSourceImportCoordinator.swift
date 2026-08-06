import Foundation

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
        let attributes = try FileManager.default.attributesOfItem(atPath: stagedURL.path)
        let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard fileSize <= MapSourceImportLimits.maximumSourceFileBytes else {
            throw MapSourceImportError.fileTooLarge(limitBytes: MapSourceImportLimits.maximumSourceFileBytes)
        }
        let data: Data
        do {
            data = try Data(contentsOf: stagedURL, options: [.mappedIfSafe])
        } catch {
            throw MapSourceImportError.unreadableSource(reason: error.localizedDescription)
        }
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
