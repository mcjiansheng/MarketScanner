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

        let resolvedStoreId = storeId ?? "default"
        let resolvedMapName = mapName
            ?? (originalFilename as NSString).deletingPathExtension

        let outcome: MapSourceImportOutcome
        switch format {
        case "xlsx":
            let imported = try XLSXMapSourceImporter.importSource(
                data: data, contract: contract, strict: strict)
            outcome = MapSourceImportOutcome(
                elements: imported.elements,
                warnings: imported.warnings,
                malformedRows: imported.malformedRows,
                jsonSourceIdentity: nil
            )
        case "csv":
            let imported = try CSVMapSourceImporter.importSource(
                data: data, contract: contract, strict: strict)
            outcome = MapSourceImportOutcome(
                elements: imported.elements,
                warnings: imported.warnings,
                malformedRows: imported.malformedRows,
                jsonSourceIdentity: nil
            )
        case "json":
            let imported = try JSONMapSourceImporter.importSource(data: data)
            outcome = MapSourceImportOutcome(
                elements: imported.elements,
                warnings: imported.warnings,
                malformedRows: [],
                jsonSourceIdentity: imported.sourceIdentity
            )
        default:
            throw MapSourceImportError.unknownFormat
        }

        var warnings = outcome.warnings
        let floors = Set(outcome.elements.map { $0.floorId }).sorted()
        let canonicalSource = MarketScannerPriorMapSource(
            format: MarketScannerPriorMapSource.formatValue,
            version: MarketScannerPriorMapSource.versionValue,
            storeId: resolvedStoreId,
            mapName: resolvedMapName,
            source: MapSourceIdentity(
                originalFormat: format,
                originalFilename: originalFilename,
                sourceFileSha256: sourceFileSha256,
                canonicalSourceSha256: ""
            ),
            coordinateContract: contract,
            elements: outcome.elements,
            warnings: warnings
        )

        let canonicalPayload = canonicalSource.canonicalPayload
        let canonicalData = try CanonicalJSONEncoder.encode(canonicalPayload)
        let canonicalSha256 = CanonicalSourceHasher.sha256(canonicalData)

        let finalSource = MarketScannerPriorMapSource(
            format: canonicalSource.format,
            version: canonicalSource.version,
            storeId: resolvedStoreId,
            mapName: resolvedMapName,
            source: MapSourceIdentity(
                originalFormat: format,
                originalFilename: originalFilename,
                sourceFileSha256: sourceFileSha256,
                canonicalSourceSha256: canonicalSha256
            ),
            coordinateContract: contract,
            elements: outcome.elements,
            warnings: warnings
        )

        return MapSourceImportReport(
            format: format,
            fileSizeBytes: fileSize,
            mapName: resolvedMapName,
            storeId: resolvedStoreId,
            floorCount: floors.count,
            elementCount: outcome.elements.count,
            sourceFileSha256: sourceFileSha256,
            canonicalSourceSha256: canonicalSha256,
            warningCount: warnings.count,
            malformedRowCount: outcome.malformedRows.count,
            coordinateContractOrigin: contract.origin.rawValue,
            canonicalSource: finalSource
        )
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
    var elements: [PriorMapSourceElement]
    var warnings: [MapSourceWarning]
    var malformedRows: [[String: Any]]
    var jsonSourceIdentity: MapSourceIdentity?
}
