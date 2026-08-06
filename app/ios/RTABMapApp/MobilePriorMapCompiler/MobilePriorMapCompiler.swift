import Foundation
import Darwin

/// Compiles a `MarketScannerPriorMapSource` into a self-validating
/// prior-map package on device, mirroring the PC
/// `convert_workbook` pipeline. The package is written to a staging
/// directory, self-validated with the production integrity validator and
/// only then atomically renamed into place — a failed compile never
/// overwrites an existing map.
enum MobilePriorMapCompiler {
    struct CompileResult {
        var priorMapID: String
        var packageSHA256: String
        var floorCount: Int
        var elementCount: Int
        var diagnostics: [String]
    }

    enum CompileError: Error {
        case noValidGeometry
        case outputNotUsable(String)
        case selfValidationFailed(String)
    }

    static func compile(
        canonicalSource: MarketScannerPriorMapSource,
        outputDirectory: URL
    ) throws -> CompileResult {
        let elements = canonicalSource.elements
        let warnings = canonicalSource.warnings

        // Floor inventory with merged bounds.
        var groupedBounds: [String: [SourceGeometry.Bounds]] = [:]
        for element in elements {
            guard let boundsValue = element.bounds,
                  let bounds = boundsFromDictionary(boundsValue)
            else { continue }
            groupedBounds[element.floorId, default: []].append(bounds)
        }
        guard !groupedBounds.isEmpty else {
            throw CompileError.noValidGeometry
        }
        var floors: [[String: Any]] = []
        for floorID in groupedBounds.keys.sorted() {
            let merged = SourceGeometry.mergeBounds(groupedBounds[floorID] ?? [])
            var floor: [String: Any] = [
                "id": floorID,
                "bounds": merged.asDictionary,
            ]
            let safeFloor = safeName(floorID)
            floor["preview_file"] = "preview_floor_\(String(format: "%03d", floors.count + 1))_\(safeFloor).png"
            floors.append(floor)
        }

        let sourceHash = canonicalSource.source.canonicalSourceSha256
        let safeBase = safeName(canonicalSource.mapName)
        let priorMapID = "\(safeBase)-\(String(sourceHash.prefix(12)))"

        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: outputDirectory.path) {
            var isDirectory: ObjCBool = false
            _ = fileManager.fileExists(atPath: outputDirectory.path, isDirectory: &isDirectory)
            let contents = try? fileManager.contentsOfDirectory(atPath: outputDirectory.path)
            if !isDirectory.boolValue || !(contents?.isEmpty ?? true) {
                throw CompileError.outputNotUsable(outputDirectory.path)
            }
            try fileManager.removeItem(at: outputDirectory)
        }
        try fileManager.createDirectory(
            at: outputDirectory.deletingLastPathComponent(),
            withIntermediateDirectories: true)

        let staging = outputDirectory.deletingLastPathComponent()
            .appendingPathComponent(".\(outputDirectory.lastPathComponent).staging-\(UUID().uuidString)")
        do {
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)

            var warningsCopy = warnings
            let graph = MobileRoadGraphBuilder.build(elements: elements, warnings: &warningsCopy)
            let spatial = MobileSpatialIndexBuilder.build(
                elements: elements, graph: graph, floors: floors)
            let distanceFields = try MobileDistanceFieldBuilder.build(elements: elements, floors: floors)

            let counts = Dictionary(grouping: elements, by: { $0.shapeType })
                .mapValues { $0.count }
                .sorted { $0.key < $1.key }
            var elementStatistics: [String: Any] = [:]
            for (key, value) in counts {
                elementStatistics[key] = value
            }

            let bounds = SourceGeometry.mergeBounds(
                floors.compactMap { floor in
                    guard let floorBounds = floor["bounds"] as? [String: Double] else { return nil }
                    return boundsFromDictionary(floorBounds)
                } ?? [])
            let manifest: [String: Any] = [
                "format": "MarketScannerPriorMap",
                "version": 1,
                "prior_map_id": priorMapID,
                "name": canonicalSource.mapName,
                "store_id": canonicalSource.storeId,
                "source_file": canonicalSource.source.originalFilename,
                "source_sha256": canonicalSource.source.sourceFileSha256,
                "canonical_source_sha256": canonicalSource.source.canonicalSourceSha256,
                "source_coordinate_system": [
                    "unit": canonicalSource.coordinateContract.unit,
                    "origin": canonicalSource.coordinateContract.origin.rawValue,
                    "x_axis": canonicalSource.coordinateContract.xAxis,
                    "y_axis": canonicalSource.coordinateContract.yAxis,
                    "rotation": canonicalSource.coordinateContract.rotationDirection,
                    "rectangle_anchor": "top_left_rotated_about_center",
                ],
                "map_coordinate_system": [
                    "unit": "metre",
                    "origin": "source_origin",
                    "x_axis": "right",
                    "y_axis": "up",
                    "yaw": "counter_clockwise_radians",
                    "transform": "x_m=x_cm/100; y_m=-y_cm/100; yaw_rad=-rotation_deg*pi/180",
                ],
                "localization_scope": [
                    "floor_mode": "single_floor_per_scan",
                    "cross_floor_switching": false,
                    "vertical_motion": "ignored_in_prior_map_2d_preserved_in_raw_3d",
                ],
                "floors": floors,
                "bounds": bounds.asDictionary,
                "element_statistics": elementStatistics,
                "element_count": elements.count,
                "visible_element_count": elements.filter { $0.visible }.count,
                "hidden_element_count": elements.filter { !$0.visible }.count,
                "warning_count": warningsCopy.count,
                "distance_fields": [
                    "file": "distance_fields.json",
                    "format": MobileDistanceFieldBuilder.formatValue,
                    "version": MobileDistanceFieldBuilder.versionValue,
                    "resolutions_m": MobileDistanceFieldBuilder.defaultResolutionsM,
                    "truncation_distance_m": MobileDistanceFieldBuilder.defaultTruncationM,
                ],
            ]

            let shelves = elements.filter { $0.shapeType == "MapShelf" }
            let fixed = elements.filter {
                ["MapTable", "MapPillar", "MapTableFeature"].contains($0.shapeType)
            }

            try writeJSON(["format": "MarketScannerPriorMapElements", "version": 1, "elements": elements.map { $0.canonicalPayload }], to: staging, name: "elements.json")
            // V1R5 §12.2 (review B-14): the compiler emits EXPLICIT shelf
            // side semantics (front/back normals, longitudinal axis,
            // orientation provenance) so consumers never guess the
            // business side from geometry PCA. Version 2 keeps the legacy
            // `shelves` array for backward-compatible readers.
            try writeJSON([
                "format": "MarketScannerPriorMapShelves",
                "version": 2,
                "shelves": shelves.map { $0.canonicalPayload },
                "shelf_segments": compiledShelfSegments(shelves),
            ], to: staging, name: "shelves.json")
            try writeJSON(["format": "MarketScannerPriorMapStructures", "version": 1, "structures": fixed.map { $0.canonicalPayload }], to: staging, name: "fixed_structures.json")
            try writeJSON(manifest, to: staging, name: "manifest.json")
            try writeJSON(graph, to: staging, name: "road_graph.json")
            try writeJSON(spatial, to: staging, name: "spatial_index.json")
            try writeJSON(distanceFields, to: staging, name: "distance_fields.json")

            // Preview rendering (CoreGraphics PNGs).
            try MobilePreviewRenderer.render(
                elements: elements,
                floors: floors,
                directory: staging)

            let validationReport: [String: Any] = [
                "format": "MarketScannerPriorMapValidation",
                "version": 1,
                "valid": true,
                "summary": [
                    "element_count": elements.count,
                    "malformed_row_count": 0,
                    "warning_count": warningsCopy.count,
                    "floor_count": floors.count,
                ],
                "warnings": warningsCopy.map { $0.canonicalPayload },
                "malformed_rows": [],
            ]
            try writeJSON(validationReport, to: staging, name: "validation_report.json")

            let packageManifest = try MobilePackageManifestBuilder.buildManifest(directory: staging)
            let packageData = try CanonicalJSONEncoder.encode(packageManifest)
            try packageData.write(to: staging.appendingPathComponent(MobilePackageManifestBuilder.manifestFileName))

            // Self-validation with the production integrity validator.
            try MobilePackageManifestBuilder.requiredFilesPresent(directory: staging)
            let digest: String
            do {
                digest = try PriorMapPackageIntegrity.validate(directory: staging)
            } catch {
                throw CompileError.selfValidationFailed("\(error)")
            }

            // fsync the staging files before the atomic rename.
            try syncDirectory(staging)

            try fileManager.moveItem(at: staging, to: outputDirectory)
            return CompileResult(
                priorMapID: priorMapID,
                packageSHA256: digest,
                floorCount: floors.count,
                elementCount: elements.count,
                diagnostics: warningsCopy.map { $0.code }
            )
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
    }

    private static func writeJSON(_ payload: [String: Any], to directory: URL, name: String) throws {
        let data = try CanonicalJSONEncoder.encode(payload)
        try data.write(to: directory.appendingPathComponent(name))
    }

    /// V1R5 §12.2 (review B-14): explicit business side semantics per
    /// shelf segment. The longitudinal axis and the front/back normals
    /// come from the ELEMENT's business yaw (`yaw_rad`) when present —
    /// never from a consumer-side geometry guess. `orientation_provenance`
    /// records where the semantics came from so a consumer can decide
    /// SIDE_UNAVAILABLE when no business orientation exists.
    static func compiledShelfSegments(
        _ shelves: [PriorMapSourceElement]
    ) -> [[String: Any]] {
        var segments: [[String: Any]] = []
        for element in shelves {
            var segment: [String: Any] = [
                "shelf_segment_id": element.id,
                "shelf_code": element.code,
                "floor_id": element.floorId,
                "side_semantics_version": 1,
            ]
            if let yaw = element.yawRad, yaw.isFinite {
                // Axis = (cos yaw, sin yaw); the front normal is the axis
                // rotated clockwise 90° (identical to the consumer's
                // makeSegment convention, but now authoritative).
                let axisX = cos(yaw)
                let axisY = sin(yaw)
                segment["longitudinal_axis"] = [axisX, axisY]
                segment["front_normal"] = [axisY, -axisX]
                segment["back_normal"] = [-axisY, axisX]
                segment["orientation_provenance"] = "element_yaw"
            } else {
                // No business orientation in the source: the consumer
                // must treat the side as UNAVAILABLE (never PCA-guess).
                segment["orientation_provenance"] = "unavailable"
            }
            segments.append(segment)
        }
        return segments
    }

    private static func boundsFromDictionary(_ value: [String: Double]) -> SourceGeometry.Bounds? {
        guard let minX = value["min_x_m"], let minY = value["min_y_m"],
              let maxX = value["max_x_m"], let maxY = value["max_y_m"]
        else { return nil }
        return SourceGeometry.Bounds(
            minX_m: minX, minY_m: minY, maxX_m: maxX, maxY_m: maxY)
    }

    /// Slugs a name like the PC `SAFE_NAME` contract.
    static func safeName(_ value: String) -> String {
        var result = ""
        var pendingDash = false
        for scalar in value.unicodeScalars {
            let allowed = (scalar.value >= 0x30 && scalar.value <= 0x39)
                || (scalar.value >= 0x41 && scalar.value <= 0x5A)
                || (scalar.value >= 0x61 && scalar.value <= 0x7A)
                || scalar.value == 0x2E || scalar.value == 0x5F || scalar.value == 0x2D
            if allowed {
                if pendingDash {
                    result.append("-")
                    pendingDash = false
                }
                result.append(Character(scalar))
            } else {
                pendingDash = true
            }
        }
        if pendingDash {
            result.append("-")
        }
        while result.hasPrefix("-") { result.removeFirst() }
        while result.hasSuffix("-") { result.removeLast() }
        return result.isEmpty ? "map" : result
    }

    private static func syncDirectory(_ directory: URL) throws {
        let descriptor = open(directory.path, O_RDONLY)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        fsync(descriptor)
    }
}
