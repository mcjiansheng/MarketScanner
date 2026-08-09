import Foundation
import Darwin

enum PriorMapShelfSchemaError: Error, LocalizedError, Equatable {
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let detail):
            return "shelves.json 无效：\(detail)"
        }
    }
}

private struct PriorMapShelfDynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

/// Production shelves-v2 DTO. The decoder rejects unknown fields and
/// validates every intrinsic geometric relation before a segment can be
/// consumed by either the scan-time package loader or post-processing.
struct PriorMapShelfSegmentV2: Codable, Equatable {
    let shelfSegmentID: String
    let shelfCode: String
    let floorID: String
    let longitudinalStartM: [Double]
    let longitudinalEndM: [Double]
    let longitudinalAxis: [Double]
    let frontNormal: [Double]
    let backNormal: [Double]
    let sideSemanticsVersion: Int
    let orientationProvenance: String

    private static let allowedProvenance: Set<String> = [
        "element_yaw", "unavailable",
    ]
    private static let vectorTolerance = 1.0e-6

    enum CodingKeys: String, CodingKey, CaseIterable {
        case shelfSegmentID = "shelf_segment_id"
        case shelfCode = "shelf_code"
        case floorID = "floor_id"
        case longitudinalStartM = "longitudinal_start_m"
        case longitudinalEndM = "longitudinal_end_m"
        case longitudinalAxis = "longitudinal_axis"
        case frontNormal = "front_normal"
        case backNormal = "back_normal"
        case sideSemanticsVersion = "side_semantics_version"
        case orientationProvenance = "orientation_provenance"
    }

    init(
        shelfSegmentID: String,
        shelfCode: String,
        floorID: String,
        longitudinalStartM: [Double],
        longitudinalEndM: [Double],
        longitudinalAxis: [Double],
        frontNormal: [Double],
        backNormal: [Double],
        sideSemanticsVersion: Int,
        orientationProvenance: String
    ) throws {
        self.shelfSegmentID = shelfSegmentID
        self.shelfCode = shelfCode
        self.floorID = floorID
        self.longitudinalStartM = longitudinalStartM
        self.longitudinalEndM = longitudinalEndM
        self.longitudinalAxis = longitudinalAxis
        self.frontNormal = frontNormal
        self.backNormal = backNormal
        self.sideSemanticsVersion = sideSemanticsVersion
        self.orientationProvenance = orientationProvenance
        try validateIntrinsicRelations()
    }

    init(from decoder: Decoder) throws {
        let dynamic = try decoder.container(
            keyedBy: PriorMapShelfDynamicCodingKey.self)
        let allowed = Set(CodingKeys.allCases.map(\.rawValue))
        let unknown = Set(dynamic.allKeys.map(\.stringValue)).subtracting(allowed)
        guard unknown.isEmpty else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "unknown shelf-segment fields: \(unknown.sorted())"))
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        shelfSegmentID = try container.decode(String.self, forKey: .shelfSegmentID)
        shelfCode = try container.decode(String.self, forKey: .shelfCode)
        floorID = try container.decode(String.self, forKey: .floorID)
        longitudinalStartM = try container.decode([Double].self, forKey: .longitudinalStartM)
        longitudinalEndM = try container.decode([Double].self, forKey: .longitudinalEndM)
        longitudinalAxis = try container.decode([Double].self, forKey: .longitudinalAxis)
        frontNormal = try container.decode([Double].self, forKey: .frontNormal)
        backNormal = try container.decode([Double].self, forKey: .backNormal)
        sideSemanticsVersion = try container.decode(Int.self, forKey: .sideSemanticsVersion)
        orientationProvenance = try container.decode(String.self, forKey: .orientationProvenance)
        do {
            try validateIntrinsicRelations()
        } catch {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: String(describing: error)))
        }
    }

    var canonicalPayload: [String: Any] {
        return [
            CodingKeys.shelfSegmentID.rawValue: shelfSegmentID,
            CodingKeys.shelfCode.rawValue: shelfCode,
            CodingKeys.floorID.rawValue: floorID,
            CodingKeys.longitudinalStartM.rawValue: longitudinalStartM,
            CodingKeys.longitudinalEndM.rawValue: longitudinalEndM,
            CodingKeys.longitudinalAxis.rawValue: longitudinalAxis,
            CodingKeys.frontNormal.rawValue: frontNormal,
            CodingKeys.backNormal.rawValue: backNormal,
            CodingKeys.sideSemanticsVersion.rawValue: sideSemanticsVersion,
            CodingKeys.orientationProvenance.rawValue: orientationProvenance,
        ]
    }

    private func validateIntrinsicRelations() throws {
        guard !shelfSegmentID.isEmpty, !floorID.isEmpty else {
            throw PriorMapShelfSchemaError.invalid("segment/floor identity is empty")
        }
        guard sideSemanticsVersion == 1 else {
            throw PriorMapShelfSchemaError.invalid("unsupported side_semantics_version")
        }
        guard Self.allowedProvenance.contains(orientationProvenance) else {
            throw PriorMapShelfSchemaError.invalid("orientation_provenance is not allowed")
        }
        let vectors = [
            longitudinalStartM, longitudinalEndM, longitudinalAxis,
            frontNormal, backNormal,
        ]
        guard vectors.allSatisfy({
            $0.count == 2 && $0.allSatisfy(\.isFinite)
        }) else {
            throw PriorMapShelfSchemaError.invalid("vectors must be finite 2D values")
        }
        let dx = longitudinalEndM[0] - longitudinalStartM[0]
        let dy = longitudinalEndM[1] - longitudinalStartM[1]
        let segmentLength = hypot(dx, dy)
        guard segmentLength > Self.vectorTolerance else {
            throw PriorMapShelfSchemaError.invalid("longitudinal segment has zero length")
        }
        func isUnit(_ value: [Double]) -> Bool {
            return abs(hypot(value[0], value[1]) - 1.0)
                <= Self.vectorTolerance
        }
        guard isUnit(longitudinalAxis), isUnit(frontNormal), isUnit(backNormal) else {
            throw PriorMapShelfSchemaError.invalid("axis/normals must be unit vectors")
        }
        let axisFrontDot = longitudinalAxis[0] * frontNormal[0]
            + longitudinalAxis[1] * frontNormal[1]
        let axisBackDot = longitudinalAxis[0] * backNormal[0]
            + longitudinalAxis[1] * backNormal[1]
        guard abs(axisFrontDot) <= Self.vectorTolerance,
              abs(axisBackDot) <= Self.vectorTolerance else {
            throw PriorMapShelfSchemaError.invalid("axis and normals are not orthogonal")
        }
        guard abs(frontNormal[0] + backNormal[0]) <= Self.vectorTolerance,
              abs(frontNormal[1] + backNormal[1]) <= Self.vectorTolerance else {
            throw PriorMapShelfSchemaError.invalid("front/back normals are not opposite")
        }
        let directionDot = dx / segmentLength * longitudinalAxis[0]
            + dy / segmentLength * longitudinalAxis[1]
        guard directionDot >= 1.0 - Self.vectorTolerance else {
            throw PriorMapShelfSchemaError.invalid("start/end direction disagrees with axis")
        }
    }
}

/// Shared v1/v2 shelves document gate. V1 remains readable for legacy
/// packages; v2 is the only production-write format and is relation-bound
/// to the exact legacy shelf inventory carried in the same document.
enum PriorMapShelvesSchema {
    struct ParsedDocument {
        let version: Int
        let rawShelves: [[String: Any]]
        let segments: [PriorMapShelfSegmentV2]
    }

    static func parse(_ object: [String: Any]) throws -> ParsedDocument {
        guard object["format"] as? String == "MarketScannerPriorMapShelves",
              let version = StrictJSONScalar.integer(object["version"]),
              let rawShelves = object["shelves"] as? [[String: Any]] else {
            throw PriorMapShelfSchemaError.invalid("top-level format/version/shelves")
        }
        switch version {
        case 1:
            let unknown = Set(object.keys).subtracting(["format", "version", "shelves"])
            guard unknown.isEmpty else {
                throw PriorMapShelfSchemaError.invalid(
                    "legacy document has unknown fields: \(unknown.sorted())")
            }
            _ = try shelfInventory(rawShelves)
            return ParsedDocument(version: 1, rawShelves: rawShelves, segments: [])
        case 2:
            let allowed: Set<String> = ["format", "version", "shelves", "shelf_segments"]
            let unknown = Set(object.keys).subtracting(allowed)
            guard unknown.isEmpty,
                  let rawSegments = object["shelf_segments"] as? [[String: Any]] else {
                throw PriorMapShelfSchemaError.invalid(
                    "v2 document fields/shelf_segments are invalid")
            }
            let inventory = try shelfInventory(rawShelves)
            var segments: [PriorMapShelfSegmentV2] = []
            var seen = Set<String>()
            for rawSegment in rawSegments {
                let data = try JSONSerialization.data(
                    withJSONObject: rawSegment, options: [.sortedKeys])
                let segment: PriorMapShelfSegmentV2
                do {
                    segment = try JSONDecoder().decode(
                        PriorMapShelfSegmentV2.self, from: data)
                } catch {
                    throw PriorMapShelfSchemaError.invalid(
                        "segment DTO decode failed: \(error)")
                }
                guard seen.insert(segment.shelfSegmentID).inserted else {
                    throw PriorMapShelfSchemaError.invalid("duplicate shelf_segment_id")
                }
                guard let shelf = inventory[segment.shelfSegmentID],
                      shelf.floorID == segment.floorID,
                      shelf.code == segment.shelfCode else {
                    throw PriorMapShelfSchemaError.invalid(
                        "segment does not exactly reference its shelf/floor/code")
                }
                segments.append(segment)
            }
            guard segments.count == inventory.count,
                  Set(segments.map(\.shelfSegmentID)) == Set(inventory.keys) else {
                throw PriorMapShelfSchemaError.invalid(
                    "v2 shelf/segment inventories are not one-to-one")
            }
            return ParsedDocument(version: 2, rawShelves: rawShelves, segments: segments)
        default:
            throw PriorMapShelfSchemaError.invalid("unsupported shelves version \(version)")
        }
    }

    private static func shelfInventory(
        _ rawShelves: [[String: Any]]
    ) throws -> [String: (floorID: String, code: String?)] {
        var inventory: [String: (floorID: String, code: String?)] = [:]
        for shelf in rawShelves {
            guard let identifier = shelf["id"] as? String,
                  !identifier.isEmpty,
                  let floorID = shelf["floor_id"] as? String,
                  !floorID.isEmpty,
                  inventory[identifier] == nil else {
                throw PriorMapShelfSchemaError.invalid(
                    "legacy shelf identity/floor/code is invalid or duplicated")
            }
            if let codeValue = shelf["code"], !(codeValue is String) {
                throw PriorMapShelfSchemaError.invalid(
                    "legacy shelf code must be a string when present")
            }
            inventory[identifier] = (floorID, shelf["code"] as? String)
        }
        return inventory
    }
}

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
        case invalidShelf(String)
        case durabilityFailure(String)
    }

    static func compile(
        canonicalSource: MarketScannerPriorMapSource,
        outputDirectory: URL
    ) throws -> CompileResult {
        do {
            try MapSourceBusinessIdentityPolicy.validate(
                storeID: canonicalSource.storeId,
                mapName: canonicalSource.mapName)
        } catch {
            throw CompileError.outputNotUsable(
                "invalid store/map identity: \(error)")
        }
        var warnings = canonicalSource.warnings
        let filtered = ElementRoleClassifier.productionElements(
            from: canonicalSource.elements, warnings: &warnings)
        let elements = filtered.active
        guard elements.count <= MapSourceImportLimits.maximumElements else {
            throw CompileError.outputNotUsable(
                "active element count exceeds \(MapSourceImportLimits.maximumElements)")
        }
        if (canonicalSource.importSummary?.malformedRowCount ?? 0) != 0 {
            throw CompileError.outputNotUsable(
                "strict production compilation rejects malformed source rows")
        }

        var activeElementIDs = Set<String>()
        var stableBusinessIDs = Set<String>()
        for element in elements {
            guard !element.id.isEmpty,
                  activeElementIDs.insert(element.id).inserted else {
                throw CompileError.outputNotUsable(
                    "active element id is empty or duplicated: \(element.id)")
            }
            let stableBusinessID = CanonicalPriorMapBusinessSourceV2
                .stableElementID(
                    for: element,
                    storeID: canonicalSource.storeId,
                    mapName: canonicalSource.mapName)
            guard !stableBusinessID.isEmpty,
                  stableBusinessIDs.insert(stableBusinessID).inserted else {
                throw CompileError.outputNotUsable(
                    "active stable business identity is empty or duplicated: "
                        + stableBusinessID)
            }
            guard let points = SourceGeometry.validatedProductionGeometryPoints(
                    shapeType: element.shapeType,
                    geometry: element.geometry),
                  let boundsValue = element.bounds,
                  let bounds = boundsFromDictionary(boundsValue),
                  let geometryBounds = try? SourceGeometry.polygonBounds(points),
                  boundsMatch(bounds, geometryBounds) else {
                throw CompileError.outputNotUsable(
                    "active element \(element.id) has an invalid role/geometry contract")
            }
            if let canvas = canonicalSource.sourceMapInfo?.sourceCanvasBounds,
               !SourceGeometry.contains(geometry: element.geometry, in: canvas) {
                throw CompileError.outputNotUsable(
                    "active element \(element.id) is outside the Basic Info canvas")
            }
        }

        // Formal v3 packages use the immutable Basic Info canvas for every
        // floor. Legacy sources retain their frozen geometry-union behavior.
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
            let merged = canonicalSource.sourceMapInfo?.sourceCanvasBounds
                ?? SourceGeometry.mergeBounds(groupedBounds[floorID] ?? [])
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
            let distanceFields = try MobileDistanceFieldBuilder.build(elements: elements, floors: floors)
            let spatial = try MobileSpatialIndexBuilder.build(
                elements: elements, graph: graph, floors: floors)

            let counts = Dictionary(grouping: elements, by: { $0.shapeType })
                .mapValues { $0.count }
                .sorted { $0.key < $1.key }
            var elementStatistics: [String: Any] = [:]
            for (key, value) in counts {
                elementStatistics[key] = value
            }

            let bounds = canonicalSource.sourceMapInfo?.sourceCanvasBounds
                ?? SourceGeometry.mergeBounds(
                floors.compactMap { floor in
                    guard let floorBounds = floor["bounds"] as? [String: Double] else { return nil }
                    return boundsFromDictionary(floorBounds)
                })
            let manifestVersion = canonicalSource.sourceMapInfo == nil ? 1 : 2
            let summary = canonicalSource.importSummary
            let shelfCount = elements.filter {
                ElementRoleClassifier.role(for: $0.shapeType) == .shelf
            }.count
            let fixedStructureCount = elements.filter {
                ElementRoleClassifier.role(for: $0.shapeType) == .fixedStructure
            }.count
            let roadElementCount = elements.filter {
                ElementRoleClassifier.role(for: $0.shapeType) == .road
            }.count
            var manifest: [String: Any] = [
                "format": "MarketScannerPriorMap",
                "version": manifestVersion,
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
                    "rotation_direction": canonicalSource.coordinateContract.rotationDirection,
                    "rectangle_anchor": canonicalSource.sourceMapInfo == nil
                        ? "top_left_rotated_about_center" : "top_left",
                    "rotation_pivot": canonicalSource.sourceMapInfo == nil
                        ? "rectangle_center" : "top_left_anchor",
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
                "hidden_element_count": manifestVersion == 2
                    ? (summary?.hiddenElementCount ?? 0)
                    : elements.filter { !$0.visible }.count,
                "warning_count": warningsCopy.count,
                "distance_fields": [
                    "file": "distance_fields.json",
                    "format": MobileDistanceFieldBuilder.formatValue,
                    "version": MobileDistanceFieldBuilder.versionValue,
                    "resolutions_m": MobileDistanceFieldBuilder.defaultResolutionsM,
                    "truncation_distance_m": MobileDistanceFieldBuilder.defaultTruncationM,
                ],
            ]
            if let sourceMapInfo = canonicalSource.sourceMapInfo {
                manifest["source_map_info"] = sourceMapInfo.canonicalPayload
                manifest["source_canvas"] = [
                    "width_cm": SourceGeometry.rounded(sourceMapInfo.widthCm),
                    "height_cm": SourceGeometry.rounded(sourceMapInfo.heightCm),
                    "source_scale": sourceMapInfo.scale.map {
                        SourceGeometry.rounded($0)
                    } ?? NSNull(),
                ]
                manifest["element_role_contract"] =
                    ElementRoleClassifier.manifestContractPayload
                manifest["source_element_count"] = summary?.sourceElementCount
                    ?? elements.count
                manifest["active_element_count"] = elements.count
                manifest["shelf_count"] = shelfCount
                manifest["fixed_structure_count"] = fixedStructureCount
                manifest["road_element_count"] = roadElementCount
                manifest["presentation_ignored_count"] =
                    summary?.presentationIgnoredCount ?? 0
                manifest["unsupported_ignored_count"] =
                    summary?.unsupportedIgnoredCount ?? 0
                manifest["invalid_geometry_ignored_count"] =
                    summary?.invalidGeometryIgnoredCount ?? 0
                manifest["ignored_by_shape_type"] =
                    summary?.ignoredByShapeType ?? [:]
                manifest["legacy_shelf_info"] = [
                    "present": summary?.legacyShelfInfoPresent ?? false,
                    "row_count": summary?.legacyShelfInfoRowCount ?? 0,
                    "authority": false,
                ]
            }

            let shelves = elements.filter {
                ElementRoleClassifier.role(for: $0.shapeType) == .shelf
            }
            let fixed = elements.filter {
                ElementRoleClassifier.role(for: $0.shapeType) == .fixedStructure
            }

            let packageElements = elements.map(packageElementPayload)
            var packageElementsByID: [String: [String: Any]] = [:]
            for payload in packageElements {
                guard let identifier = payload["id"] as? String,
                      !identifier.isEmpty,
                      packageElementsByID[identifier] == nil else {
                    throw CompileError.outputNotUsable(
                        "compiled package element id is missing or duplicated")
                }
                packageElementsByID[identifier] = payload
            }
            try writeJSON(["format": "MarketScannerPriorMapElements", "version": 1, "elements": packageElements], to: staging, name: "elements.json")
            // V1R5 §12.2 (review B-14): the compiler emits EXPLICIT shelf
            // side semantics (front/back normals, longitudinal axis,
            // orientation provenance) so consumers never guess the
            // business side from geometry PCA. Version 2 keeps the legacy
            // `shelves` array for backward-compatible readers.
            try writeJSON([
                "format": "MarketScannerPriorMapShelves",
                "version": 2,
                "shelves": shelves.compactMap { packageElementsByID[$0.id] },
                "shelf_segments": try compiledShelfSegments(shelves)
                    .map(\.canonicalPayload),
            ], to: staging, name: "shelves.json")
            try writeJSON(["format": "MarketScannerPriorMapStructures", "version": 1, "structures": fixed.compactMap { packageElementsByID[$0.id] }], to: staging, name: "fixed_structures.json")
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
                    "source_element_count": manifestVersion == 2
                        ? (summary?.sourceElementCount ?? elements.count)
                        : elements.count,
                    "active_element_count": elements.count,
                    "shelf_count": shelfCount,
                    "fixed_structure_count": fixedStructureCount,
                    "road_element_count": roadElementCount,
                    "presentation_ignored_count":
                        summary?.presentationIgnoredCount ?? 0,
                    "unsupported_ignored_count":
                        summary?.unsupportedIgnoredCount ?? 0,
                    "hidden_element_count": summary?.hiddenElementCount ?? 0,
                    "invalid_geometry_ignored_count":
                        summary?.invalidGeometryIgnoredCount ?? 0,
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

            // Durability contract: every generated artifact (including
            // previews and package_manifest.json) is individually fsynced,
            // then the staging directory, rename, and parent directory are
            // synced. open/fsync failures are fatal.
            try syncRegularFiles(in: staging)
            try syncDirectory(staging)

            try fileManager.moveItem(at: staging, to: outputDirectory)
            try syncDirectory(outputDirectory.deletingLastPathComponent())
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

    private static func packageElementPayload(
        _ element: PriorMapSourceElement
    ) -> [String: Any] {
        var payload = element.canonicalPayload
        payload["role"] = ElementRoleClassifier.role(
            for: element.shapeType).rawValue
        return payload
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
    ) throws -> [PriorMapShelfSegmentV2] {
        var segments: [PriorMapShelfSegmentV2] = []
        for element in shelves {
            guard let geometry = element.geometry,
                  let rawCoordinates = geometry["coordinates"] as? [[Double]],
                  rawCoordinates.count >= 3,
                  rawCoordinates.allSatisfy({
                      $0.count >= 2 && $0[0].isFinite && $0[1].isFinite
                  }) else {
                throw CompileError.invalidShelf(
                    "\(element.id): missing finite polygon geometry")
            }
            let points = rawCoordinates.map { ($0[0], $0[1]) }
            let centerX = points.map(\.0).reduce(0, +) / Double(points.count)
            let centerY = points.map(\.1).reduce(0, +) / Double(points.count)

            let axis: (Double, Double)
            let provenance: String
            if let yaw = element.yawRad, yaw.isFinite {
                axis = (cos(yaw), sin(yaw))
                provenance = "element_yaw"
            } else {
                // A package still needs a deterministic segment for
                // distance association. Without business yaw, use the
                // longest explicit polygon edge, mark provenance
                // unavailable, and force the final quality gate to RESCAN.
                var longest = (length: 0.0, axis: (1.0, 0.0))
                for index in points.indices {
                    let next = points[(index + 1) % points.count]
                    let dx = next.0 - points[index].0
                    let dy = next.1 - points[index].1
                    let length = hypot(dx, dy)
                    if length > longest.length {
                        longest = (length, (dx / length, dy / length))
                    }
                }
                guard longest.length > 1.0e-9 else {
                    throw CompileError.invalidShelf(
                        "\(element.id): polygon has no nonzero edge")
                }
                axis = longest.axis
                provenance = "unavailable"
            }

            var minimumProjection = Double.infinity
            var maximumProjection = -Double.infinity
            for point in points {
                let projection = (point.0 - centerX) * axis.0
                    + (point.1 - centerY) * axis.1
                minimumProjection = min(minimumProjection, projection)
                maximumProjection = max(maximumProjection, projection)
            }
            let start = [
                centerX + minimumProjection * axis.0,
                centerY + minimumProjection * axis.1,
            ]
            let end = [
                centerX + maximumProjection * axis.0,
                centerY + maximumProjection * axis.1,
            ]
            do {
                segments.append(try PriorMapShelfSegmentV2(
                    shelfSegmentID: element.id,
                    shelfCode: element.code,
                    floorID: element.floorId,
                    longitudinalStartM: start,
                    longitudinalEndM: end,
                    longitudinalAxis: [axis.0, axis.1],
                    frontNormal: [axis.1, -axis.0],
                    backNormal: [-axis.1, axis.0],
                    sideSemanticsVersion: 1,
                    orientationProvenance: provenance))
            } catch {
                throw CompileError.invalidShelf("\(element.id): \(error)")
            }
        }
        return segments
    }

    private static func boundsFromDictionary(_ value: [String: Double]) -> SourceGeometry.Bounds? {
        guard let minX = value["min_x_m"], let minY = value["min_y_m"],
              let maxX = value["max_x_m"], let maxY = value["max_y_m"],
              let width = value["width_m"], let height = value["height_m"],
              [minX, minY, maxX, maxY, width, height].allSatisfy(\.isFinite),
              minX <= maxX, minY <= maxY, width >= 0, height >= 0,
              abs(width - (maxX - minX)) <= 1.0e-8,
              abs(height - (maxY - minY)) <= 1.0e-8 else { return nil }
        return SourceGeometry.Bounds(
            minX_m: minX, minY_m: minY, maxX_m: maxX, maxY_m: maxY)
    }

    private static func boundsMatch(
        _ lhs: SourceGeometry.Bounds,
        _ rhs: SourceGeometry.Bounds
    ) -> Bool {
        return abs(lhs.minX_m - rhs.minX_m) <= 1.0e-8
            && abs(lhs.minY_m - rhs.minY_m) <= 1.0e-8
            && abs(lhs.maxX_m - rhs.maxX_m) <= 1.0e-8
            && abs(lhs.maxY_m - rhs.maxY_m) <= 1.0e-8
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

    private static func syncRegularFiles(in directory: URL) throws {
        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [])
        } catch {
            throw CompileError.durabilityFailure(
                "cannot enumerate \(directory.path): \(error)")
        }
        for url in urls {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else {
                throw CompileError.durabilityFailure(
                    "non-regular compiler artifact: \(url.lastPathComponent)")
            }
            try syncFile(url)
        }
    }

    private static func syncFile(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else {
            throw CompileError.durabilityFailure(
                "open failed for \(url.path): \(String(cString: strerror(errno)))")
        }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw CompileError.durabilityFailure(
                "fsync failed for \(url.path): \(String(cString: strerror(errno)))")
        }
    }

    private static func syncDirectory(_ directory: URL) throws {
        let descriptor = open(directory.path, O_RDONLY)
        guard descriptor >= 0 else {
            throw CompileError.durabilityFailure(
                "open failed for \(directory.path): \(String(cString: strerror(errno)))")
        }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw CompileError.durabilityFailure(
                "fsync failed for \(directory.path): \(String(cString: strerror(errno)))")
        }
    }
}
