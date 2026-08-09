//
//  PriorMapPackageIntegrityCore.swift
//  RTABMapApp
//
//  Platform-neutral, fail-closed prior-map package integrity validation.
//
//  P7R6C: the validator consumes one immutable package snapshot. The
//  bytes that were hashed are exactly the bytes that were parsed; the
//  relationship checks below never re-open any file.

import CryptoKit
import Foundation

enum PriorMapPackageIntegrityError: LocalizedError {
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let message):
            return message
        }
    }
}

enum PriorMapPackageIntegrity {
    private static let packageManifestName = "package_manifest.json"

    /// Reads the package once and validates the resulting snapshot.
    static func validate(directory: URL) throws -> String {
        let snapshot = try PriorMapPackageSnapshotReader.read(
            directory: directory)
        return try validate(snapshot: snapshot)
    }

    /// Validates an already-read immutable package snapshot. Callers that
    /// also load the package model (PriorMapPackage.load) must pass the
    /// same snapshot so hash and parse can never diverge.
    static func validate(
        snapshot: PriorMapPackageSnapshot
    ) throws -> String {
        let package = snapshot.packageManifest
        try require(
            package["format"] as? String == "MarketScannerPriorMapPackageManifest"
                && StrictJSONScalar.integer(package["version"]) == 1
                && package["hash_algorithm"] as? String == "sha256",
            "地图包完整性清单格式无效。")
        guard let artifacts = package["artifacts"] as? [[String: Any]],
              StrictJSONScalar.integer(package["artifact_count"])
                  == artifacts.count else {
            throw PriorMapPackageIntegrityError.invalid("地图包完整性清单缺少文件记录。")
        }
        let expectedNames = Set(artifacts.compactMap { $0["file"] as? String })
        try require(
            expectedNames.count == artifacts.count
                && expectedNames.allSatisfy {
                    !$0.isEmpty
                        && URL(fileURLWithPath: $0).lastPathComponent == $0
                        && $0 != packageManifestName
                },
            "地图包完整性清单包含重复或不安全的文件名。")
        try require(
            expectedNames == snapshot.artifactNames,
            "地图包文件集合与完整性清单不一致。")

        var digestInput = ""
        for artifact in artifacts {
            guard let name = artifact["file"] as? String,
                  let expectedHash = artifact["sha256"] as? String,
                  let expectedBytes =
                      StrictJSONScalar.integer(artifact["bytes"]) else {
                throw PriorMapPackageIntegrityError.invalid("地图包文件记录无效。")
            }
            guard let artifactSnapshot = snapshot.artifactsByName[name] else {
                throw PriorMapPackageIntegrityError.invalid(
                    "\(name) 缺失于地图包快照。")
            }
            try require(
                artifactSnapshot.byteCount == Int64(expectedBytes),
                "\(name) 文件长度校验失败。")
            try require(
                artifactSnapshot.sha256 == expectedHash,
                "\(name) SHA-256 校验失败。")
            if name.lowercased().hasSuffix(".json") {
                guard let child = artifactSnapshot.parsedJSON else {
                    throw PriorMapPackageIntegrityError.invalid(
                        "\(name) 无法解析为 JSON 对象。")
                }
                guard let childVersion = StrictJSONScalar.integer(
                        child["version"]),
                      let artifactVersion = StrictJSONScalar.integer(
                        artifact["version"]) else {
                    throw PriorMapPackageIntegrityError.invalid(
                        "\(name) 的版本必须是严格 JSON 整数。")
                }
                try require(
                    child["format"] as? String == artifact["format"] as? String
                        && childVersion == artifactVersion,
                    "\(name) 的格式或版本与完整性清单不一致。")
            }
            let format = artifact["format"] as? String ?? ""
            let version = StrictJSONScalar.integer(artifact["version"])
                .map(String.init) ?? ""
            digestInput += "\(name)\0\(expectedBytes)\0\(expectedHash)\0\(format)\0\(version)\n"
        }
        let packageHash = SHA256.hash(data: Data(digestInput.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        try require(
            package["package_sha256"] as? String == packageHash,
            "地图包规范化 SHA-256 校验失败。")
        try validateRelationships(snapshot: snapshot)
        return packageHash
    }

    private static func validateRelationships(
        snapshot: PriorMapPackageSnapshot
    ) throws {
        let manifest = try object(snapshot, "manifest.json")
        let elementsPayload = try object(snapshot, "elements.json")
        let shelvesPayload = try object(snapshot, "shelves.json")
        let structuresPayload = try object(snapshot, "fixed_structures.json")
        let graph = try object(snapshot, "road_graph.json")
        let spatial = try object(snapshot, "spatial_index.json")
        let distance = try object(snapshot, "distance_fields.json")
        let validation = try object(snapshot, "validation_report.json")

        guard manifest["format"] as? String == "MarketScannerPriorMap",
              let manifestVersion = StrictJSONScalar.integer(manifest["version"]),
              manifestVersion == 1 || manifestVersion == 2 else {
            throw PriorMapPackageIntegrityError.invalid(
                "地图包 manifest 版本不受支持。")
        }

        guard let storeID = manifest["store_id"] as? String,
              let mapName = manifest["name"] as? String,
              MapSourceBusinessIdentityPolicy.isValidStoreID(storeID),
              MapSourceBusinessIdentityPolicy.isValidMapName(mapName) else {
            throw PriorMapPackageIntegrityError.invalid(
                "地图包 store_id/name 不符合统一业务标识策略。")
        }
        if manifestVersion == 2 {
            guard let priorMapID = manifest["prior_map_id"] as? String,
                  !priorMapID.isEmpty,
                  let sourceSHA256 = manifest["source_sha256"] as? String,
                  isValidSHA256(sourceSHA256),
                  let canonicalSHA256 = manifest["canonical_source_sha256"]
                    as? String,
                  isValidSHA256(canonicalSHA256),
                  priorMapID == "\(MobilePriorMapCompiler.safeName(mapName))-"
                    + String(canonicalSHA256.prefix(12)) else {
                throw PriorMapPackageIntegrityError.invalid(
                    "v2 prior_map_id 未绑定合法 canonical source SHA-256。")
            }
            guard let localizationScope = manifest["localization_scope"]
                    as? [String: Any],
                  Set(localizationScope.keys) == Set([
                    "floor_mode", "cross_floor_switching", "vertical_motion",
                  ]),
                  localizationScope["floor_mode"] as? String
                    == "single_floor_per_scan",
                  StrictJSONScalar.boolean(
                    localizationScope["cross_floor_switching"]) == false,
                  localizationScope["vertical_motion"] as? String
                    == "ignored_in_prior_map_2d_preserved_in_raw_3d" else {
                throw PriorMapPackageIntegrityError.invalid(
                    "v2 地图包 localization_scope 无效。")
            }
        }

        let parsedShelves: PriorMapShelvesSchema.ParsedDocument
        do {
            parsedShelves = try PriorMapShelvesSchema.parse(shelvesPayload)
        } catch {
            throw PriorMapPackageIntegrityError.invalid("\(error)")
        }
        try require(
            manifestVersion != 2 || parsedShelves.version == 2,
            "v2 正式地图包必须携带 shelves.json v2 显式方向合同。")
        if manifestVersion == 2 {
            guard let rawSegments = shelvesPayload["shelf_segments"]
                    as? [[String: Any]],
                  rawSegments.allSatisfy({
                      StrictJSONScalar.integer(
                        $0["side_semantics_version"]) == 1
                  }) else {
                throw PriorMapPackageIntegrityError.invalid(
                    "v2 shelf segment side_semantics_version 必须是严格整数 1。")
            }
        }
        guard let floors = manifest["floors"] as? [[String: Any]],
              let elements = elementsPayload["elements"] as? [[String: Any]],
              let structures = structuresPayload["structures"] as? [[String: Any]],
              let nodes = graph["nodes"] as? [[String: Any]],
              let edges = graph["edges"] as? [[String: Any]],
              let spatialFloors = spatial["floors"] as? [String: Any],
              let distanceFloors = distance["floors"] as? [String: Any] else {
            throw PriorMapPackageIntegrityError.invalid("地图包跨文件结构无效。")
        }
        let floorIds = Set(floors.compactMap { string($0["id"]) })
        try require(
            !floorIds.isEmpty && floorIds.count == floors.count
                && Set(spatialFloors.keys) == floorIds
                && Set(distanceFloors.keys) == floorIds,
            "地图包楼层集合不一致。")
        var byId: [String: [String: Any]] = [:]
        for element in elements {
            guard let identifier = element["id"] as? String,
                  !identifier.isEmpty,
                  byId[identifier] == nil else {
                throw PriorMapPackageIntegrityError.invalid("地图包元素 ID 缺失或重复。")
            }
            if manifestVersion == 2 {
                guard let shapeType = element["shape_type"] as? String else {
                    throw PriorMapPackageIntegrityError.invalid(
                        "v2 active element 缺少 shape_type。")
                }
                let role = ElementRoleClassifier.role(for: shapeType)
                try require(
                    role.isProduction
                        && StrictJSONScalar.boolean(element["visible"]) == true
                        && element["role"] as? String == role.rawValue,
                    "v2 elements.json 含 presentation/unsupported/hidden/错误角色元素。")
            }
            byId[identifier] = element
        }
        try require(
            byId.count == elements.count
                && StrictJSONScalar.integer(manifest["element_count"])
                    == elements.count,
            "地图包元素 ID 或数量不一致。")
        if manifestVersion == 2 {
            var expectedElementStatistics: [String: Int] = [:]
            for element in elements {
                guard let shapeType = element["shape_type"] as? String else {
                    throw PriorMapPackageIntegrityError.invalid(
                        "v2 地图包元素缺少 shape_type。")
                }
                expectedElementStatistics[shapeType, default: 0] += 1
            }
            guard let declaredElementStatistics = manifest["element_statistics"]
                    as? [String: Any],
                  Set(declaredElementStatistics.keys)
                    == Set(expectedElementStatistics.keys),
                  expectedElementStatistics.allSatisfy({ shapeType, count in
                      StrictJSONScalar.integer(
                        declaredElementStatistics[shapeType]) == count
                  }) else {
                throw PriorMapPackageIntegrityError.invalid(
                    "v2 manifest element_statistics 与 active elements 不一致。")
            }
            let ignoredByShape = manifest["ignored_by_shape_type"]
                as? [String: Any]
            let presentationCount = ignoredByShape?.reduce(0) { partial, item in
                guard ["Circle", "Rect", "MapMark"].contains(item.key),
                      let count = StrictJSONScalar.integer(item.value), count >= 0 else {
                    return Int.min
                }
                return partial == Int.min ? Int.min : partial + count
            } ?? Int.min
            let shelfCount = elements.filter {
                ElementRoleClassifier.role(
                    for: $0["shape_type"] as? String ?? "") == .shelf
            }.count
            let fixedCount = elements.filter {
                ElementRoleClassifier.role(
                    for: $0["shape_type"] as? String ?? "") == .fixedStructure
            }.count
            let roadCount = elements.filter {
                ElementRoleClassifier.role(
                    for: $0["shape_type"] as? String ?? "") == .road
            }.count
            let unsupported = StrictJSONScalar.integer(
                manifest["unsupported_ignored_count"])
            let hidden = StrictJSONScalar.integer(manifest["hidden_element_count"])
            let invalid = StrictJSONScalar.integer(
                manifest["invalid_geometry_ignored_count"])
            try require(
                presentationCount >= 0
                    && unsupported != nil && unsupported! >= 0
                    && hidden != nil && hidden! >= 0
                    && invalid != nil && invalid! >= 0
                    && StrictJSONScalar.integer(manifest["active_element_count"])
                        == elements.count
                    && StrictJSONScalar.integer(manifest["visible_element_count"])
                        == elements.count
                    && StrictJSONScalar.integer(manifest["shelf_count"])
                        == shelfCount
                    && StrictJSONScalar.integer(manifest["fixed_structure_count"])
                        == fixedCount
                    && StrictJSONScalar.integer(manifest["road_element_count"])
                        == roadCount
                    && StrictJSONScalar.integer(manifest["presentation_ignored_count"])
                        == presentationCount
                    && StrictJSONScalar.integer(manifest["source_element_count"])
                        == elements.count + presentationCount
                            + unsupported! + hidden! + invalid!,
                "v2 source/active/role/ignored 元素统计不一致。")
        }
        try validateSubset(
            parsedShelves.rawShelves,
            expectedTypes: ["MapShelf"],
            elements: byId,
            label: "shelves.json")
        try validateSubset(
            structures,
            expectedTypes: ["MapTable", "MapPillar", "MapTableFeature"],
            elements: byId,
            label: "fixed_structures.json")
        if manifestVersion == 2 {
            try validateShelfSegmentSourceBindings(
                parsedShelves.segments, elements: byId)
        }

        var allPoints: [(Double, Double)] = []
        var pointsByFloor: [String: [(Double, Double)]] = [:]
        for element in elements {
            guard let identifier = element["id"] as? String else { continue }
            let points: [(Double, Double)]
            if manifestVersion == 2 {
                guard let shapeType = element["shape_type"] as? String,
                      let validated = SourceGeometry
                        .validatedProductionGeometryPoints(
                            shapeType: shapeType,
                            geometry: element["geometry"] as? [String: Any])
                else {
                    throw PriorMapPackageIntegrityError.invalid(
                        "v2 元素 \(identifier) 的几何类型、点数或坐标无效。")
                }
                points = validated.map { ($0[0], $0[1]) }
            } else {
                points = geometryPoints(element["geometry"])
            }
            if !points.isEmpty {
                guard let floorId = string(element["floor_id"]),
                      floorIds.contains(floorId) else {
                    throw PriorMapPackageIntegrityError.invalid("元素引用了未知楼层。")
                }
                try require(
                    boundsMatch(element["bounds"], points: points),
                    "元素 \(identifier) 的 bounds 与几何不一致。")
                allPoints.append(contentsOf: points)
                pointsByFloor[floorId, default: []].append(contentsOf: points)
            }
        }
        if manifestVersion == 1 {
            for floor in floors {
                guard let floorId = string(floor["id"]),
                      let points = pointsByFloor[floorId], !points.isEmpty else {
                    throw PriorMapPackageIntegrityError.invalid("地图包楼层缺少几何。")
                }
                try require(
                    boundsMatch(floor["bounds"], points: points),
                    "楼层 \(floorId) bounds 与几何不一致。")
            }
            try require(
                !allPoints.isEmpty && boundsMatch(manifest["bounds"], points: allPoints),
                "地图包总体 bounds 与几何不一致。")
        } else {
            guard let sourceCanvas = manifest["source_canvas"] as? [String: Any],
                  let widthCm = StrictJSONScalar.number(sourceCanvas["width_cm"]),
                  widthCm > 0,
                  let heightCm = StrictJSONScalar.number(sourceCanvas["height_cm"]),
                  heightCm > 0,
                  let sourceMapInfo = manifest["source_map_info"] as? [String: Any],
                  sourceMapInfo["map_name"] as? String == mapName,
                  sourceMapInfo["store_code"] as? String == storeID,
                  StrictJSONScalar.number(sourceMapInfo["width_cm"]) == widthCm,
                  StrictJSONScalar.number(sourceMapInfo["height_cm"]) == heightCm,
                  let roleContract = manifest["element_role_contract"]
                    as? [String: Any],
                  let sourceCoordinates = manifest["source_coordinate_system"]
                    as? [String: Any] else {
                throw PriorMapPackageIntegrityError.invalid(
                    "v2 地图包缺少 source_canvas/role/anchor 合同。")
            }
            let expectedSourceCoordinates: [String: Any] = [
                "unit": "centimetre",
                "origin": "top_left",
                "x_axis": "right",
                "y_axis": "down",
                "rotation_direction": "clockwise_degrees",
                "rectangle_anchor": "top_left",
                "rotation_pivot": "top_left_anchor",
            ]
            let declaredSourceCoordinates = try canonicalData(
                sourceCoordinates)
            let canonicalExpectedSourceCoordinates = try canonicalData(
                expectedSourceCoordinates)
            try require(
                declaredSourceCoordinates == canonicalExpectedSourceCoordinates,
                "v2 source coordinate contract 不完整或不一致。")
            let declaredRoleContract = try canonicalData(roleContract)
            let expectedRoleContract = try canonicalData(
                ElementRoleClassifier.manifestContractPayload)
            try require(
                declaredRoleContract == expectedRoleContract,
                "v2 element_role_contract 与唯一角色表不一致。")
            let canvasScale = sourceCanvas["source_scale"]
            let infoScale = sourceMapInfo["scale"]
            let scaleValid: Bool
            if canvasScale == nil || canvasScale is NSNull {
                scaleValid = infoScale == nil || infoScale is NSNull
            } else if let canvasNumber = StrictJSONScalar.number(canvasScale),
                      let infoNumber = StrictJSONScalar.number(infoScale) {
                scaleValid = canvasNumber > 0 && infoNumber == canvasNumber
            } else {
                scaleValid = false
            }
            try require(scaleValid, "v2 source scale metadata 无效或不一致。")
            let canvasBounds = SourceGeometry.Bounds(
                minX_m: 0,
                minY_m: SourceGeometry.rounded(-SourceGeometry.cmToM(heightCm)),
                maxX_m: SourceGeometry.rounded(SourceGeometry.cmToM(widthCm)),
                maxY_m: 0).asDictionary
            try require(
                boundsEqual(manifest["bounds"], canvasBounds),
                "v2 地图包总体 bounds 必须等于 Basic Info source_canvas。")
            for floor in floors {
                guard let floorId = string(floor["id"]),
                      let points = pointsByFloor[floorId], !points.isEmpty else {
                    throw PriorMapPackageIntegrityError.invalid("地图包楼层缺少几何。")
                }
                try require(
                    boundsEqual(floor["bounds"], canvasBounds),
                    "v2 楼层 \(floorId) bounds 必须等于 source_canvas。")
                try require(
                    pointsContained(points, in: canvasBounds),
                    "v2 楼层 \(floorId) 存在超出 Basic Info 画布的 active geometry。")
            }
        }

        let nodeIds = Set(nodes.compactMap { $0["id"] as? String })
        try require(nodeIds.count == nodes.count, "道路节点 ID 缺失或重复。")
        let edgeIds = Set(edges.compactMap { $0["id"] as? String })
        try require(edgeIds.count == edges.count, "道路边 ID 缺失或重复。")
        for edge in edges {
            try require(
                nodeIds.contains(string(edge["from"]) ?? "")
                    && nodeIds.contains(string(edge["to"]) ?? "")
                    && floorIds.contains(string(edge["floor_id"]) ?? ""),
                "道路边引用了不存在的节点或楼层。")
        }
        if manifestVersion == 2 {
            let sourceElements = try elements.map(sourceElement)
            let stableBusinessIDs = sourceElements.map {
                CanonicalPriorMapBusinessSourceV2.stableElementID(
                    for: $0, storeID: storeID, mapName: mapName)
            }
            try require(
                stableBusinessIDs.allSatisfy { !$0.isEmpty }
                    && Set(stableBusinessIDs).count == sourceElements.count,
                "v2 elements.json 含重复 stable business identity。")
            do {
                try validateDistanceFieldIntegerTokens(distance)
                guard let sourceMapInfo = manifest["source_map_info"]
                        as? [String: Any],
                      let sourceMapName = sourceMapInfo["map_name"] as? String,
                      let sourceStoreCode = sourceMapInfo["store_code"] as? String,
                      let widthCM = StrictJSONScalar.number(
                        sourceMapInfo["width_cm"]),
                      let heightCM = StrictJSONScalar.number(
                        sourceMapInfo["height_cm"]) else {
                    throw PriorMapPackageIntegrityError.invalid(
                        "v2 source_map_info 无法重建 canonical source。")
                }
                let sourceScale: Double?
                if sourceMapInfo["scale"] == nil
                    || sourceMapInfo["scale"] is NSNull {
                    sourceScale = nil
                } else {
                    guard let value = StrictJSONScalar.number(
                            sourceMapInfo["scale"]) else {
                        throw PriorMapPackageIntegrityError.invalid(
                            "v2 source_map_info.scale 无效。")
                    }
                    sourceScale = value
                }
                let sourceInfo = SourceMapInfo(
                    mapName: sourceMapName,
                    storeCode: sourceStoreCode,
                    widthCm: widthCM,
                    heightCm: heightCM,
                    scale: sourceScale)
                let businessSource = CanonicalPriorMapBusinessSourceV3(
                    storeID: storeID,
                    mapName: mapName,
                    coordinateContract: .topLeft,
                    sourceMapInfo: sourceInfo,
                    roleContractVersion: ElementRoleClassifier.contractVersion,
                    elements: sourceElements)
                let businessData = try CanonicalJSONEncoder.encode(
                    businessSource.payload)
                let recomputedCanonicalSHA = CanonicalSourceHasher.sha256(
                    businessData)
                try require(
                    manifest["canonical_source_sha256"] as? String
                        == recomputedCanonicalSHA,
                    "v2 canonical_source_sha256 与权威业务内容不一致。")
                var graphWarnings: [MapSourceWarning] = []
                let expectedGraph = MobileRoadGraphBuilder.build(
                    elements: sourceElements, warnings: &graphWarnings)
                let expectedGraphData = try canonicalData(expectedGraph)
                let graphData = try canonicalData(graph)
                try require(
                    expectedGraphData == graphData,
                    "v2 road_graph 未确定性绑定道路元素。")
                let expectedSpatial = try MobileSpatialIndexBuilder.build(
                    elements: sourceElements,
                    graph: expectedGraph,
                    floors: floors)
                let expectedSpatialData = try canonicalData(expectedSpatial)
                let spatialData = try canonicalData(spatial)
                try require(
                    expectedSpatialData == spatialData,
                    "v2 spatial_index 未确定性绑定 elements/road_graph。")
                let expectedDistance = try MobileDistanceFieldBuilder.build(
                    elements: sourceElements, floors: floors)
                let expectedDistanceData = try canonicalData(expectedDistance)
                let distanceData = try canonicalData(distance)
                try require(
                    expectedDistanceData == distanceData,
                    "v2 distance_fields 未确定性绑定 elements/floor bounds。")
            } catch let error as PriorMapPackageIntegrityError {
                throw error
            } catch {
                throw PriorMapPackageIntegrityError.invalid(
                    "v2 派生空间工件无法从权威元素确定性重建：\(error)")
            }
        }
        var indexedStructures = Set<String>()
        var indexedRoads = Set<String>()
        for value in spatialFloors.values {
            guard let floor = value as? [String: Any] else {
                throw PriorMapPackageIntegrityError.invalid("空间索引楼层无效。")
            }
            indexedStructures.formUnion(indexedIds(floor["cells"]))
            indexedRoads.formUnion(indexedIds(floor["road_cells"]))
        }
        let expectedStructures = Set(
            elements.compactMap { element -> String? in
                guard StrictJSONScalar.boolean(element["visible"]) == true,
                      let shapeType = element["shape_type"] as? String,
                      [PriorMapElementRole.shelf, .fixedStructure]
                        .contains(ElementRoleClassifier.role(for: shapeType)) else {
                    return nil
                }
                return element["id"] as? String
            })
        if manifestVersion == 2 {
            guard let declaredRoles = spatial["element_roles"]
                    as? [String: Any],
                  Set(declaredRoles.keys) == expectedStructures else {
                throw PriorMapPackageIntegrityError.invalid(
                    "v2 spatial_index.element_roles 未精确覆盖结构元素。")
            }
            for identifier in expectedStructures {
                guard let record = declaredRoles[identifier] as? [String: Any],
                      let element = byId[identifier],
                      let shapeType = element["shape_type"] as? String,
                      record["shape_type"] as? String == shapeType,
                      record["role"] as? String
                        == ElementRoleClassifier.role(for: shapeType).rawValue else {
                    throw PriorMapPackageIntegrityError.invalid(
                        "v2 spatial_index.element_roles 与 elements.json 不一致。")
                }
            }
        }
        try require(
            indexedStructures == expectedStructures && indexedRoads == edgeIds,
            "空间索引引用或覆盖范围与结构/道路不一致。")
        try require(
            StrictJSONScalar.boolean(validation["valid"]) == true,
            "PC 验证报告未标记为有效。")
        guard let validationSummary = validation["summary"] as? [String: Any],
              StrictJSONScalar.integer(validationSummary["element_count"])
                == elements.count,
              StrictJSONScalar.integer(validationSummary["floor_count"])
                == floors.count else {
            throw PriorMapPackageIntegrityError.invalid(
                "validation_report.json 基础统计与地图包不一致。")
        }
        if manifestVersion == 2 {
            for key in [
                "source_element_count", "active_element_count", "shelf_count",
                "fixed_structure_count", "road_element_count",
                "presentation_ignored_count", "unsupported_ignored_count",
                "hidden_element_count", "invalid_geometry_ignored_count",
            ] {
                try require(
                    StrictJSONScalar.integer(validationSummary[key])
                        == StrictJSONScalar.integer(manifest[key]),
                    "validation_report.json 的 \(key) 与 manifest 不一致。")
            }
        }
    }

    private static func validateSubset(
        _ subset: [[String: Any]],
        expectedTypes: Set<String>,
        elements: [String: [String: Any]],
        label: String
    ) throws {
        let expected = Set(
            elements.compactMap { identifier, value in
                StrictJSONScalar.boolean(value["visible"]) == true
                    && expectedTypes.contains(value["shape_type"] as? String ?? "")
                    ? identifier
                    : nil
            })
        let actual = Set(subset.compactMap { $0["id"] as? String })
        try require(actual == expected && actual.count == subset.count, "\(label) 子集不一致。")
        for value in subset {
            guard let identifier = value["id"] as? String,
                  let original = elements[identifier] else {
                throw PriorMapPackageIntegrityError.invalid("\(label) 包含未知元素。")
            }
            let subsetData = try canonicalData(value)
            let originalData = try canonicalData(original)
            try require(subsetData == originalData, "\(label) 内容与 elements.json 不一致。")
        }
    }

    private static func validateShelfSegmentSourceBindings(
        _ segments: [PriorMapShelfSegmentV2],
        elements: [String: [String: Any]]
    ) throws {
        let tolerance = 1.0e-8
        func vectorsEqual(_ lhs: [Double], _ rhs: [Double]) -> Bool {
            return lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { pair in
                abs(pair.0 - pair.1) <= tolerance
            }
        }
        for segment in segments {
            guard let raw = elements[segment.shelfSegmentID],
                  raw["shape_type"] as? String == "MapShelf",
                  let identifier = raw["id"] as? String,
                  let floorID = raw["floor_id"] as? String,
                  let code = raw["code"] as? String,
                  let geometry = raw["geometry"] as? [String: Any] else {
                throw PriorMapPackageIntegrityError.invalid(
                    "v2 shelf segment 缺少对应 elements.json 货架。")
            }
            let element = PriorMapSourceElement(
                id: identifier,
                sourceRow: StrictJSONScalar.integer(raw["source_row"]) ?? 0,
                floorId: floorID,
                shapeType: "MapShelf",
                visible: StrictJSONScalar.boolean(raw["visible"]) == true,
                locked: StrictJSONScalar.boolean(raw["locked"]) == true,
                code: code,
                crossCode: raw["cross_code"] as? String ?? "",
                rowFlag: raw["row_flag"] as? String ?? "",
                subsection: raw["subsection"],
                geometry: geometry,
                bounds: raw["bounds"] as? [String: Double],
                centerM: raw["center_m"] as? [Double],
                yawRad: StrictJSONScalar.number(raw["yaw_rad"]),
                source: raw["source"] as? [String: Any] ?? [:])
            let expected: PriorMapShelfSegmentV2
            do {
                guard let value = try MobilePriorMapCompiler
                        .compiledShelfSegments([element]).first else {
                    throw PriorMapShelfSchemaError.invalid(
                        "expected shelf segment is missing")
                }
                expected = value
            } catch {
                throw PriorMapPackageIntegrityError.invalid(
                    "v2 shelf segment 无法由 elements.json 确定重建：\(error)")
            }
            try require(
                segment.shelfSegmentID == expected.shelfSegmentID
                    && segment.shelfCode == expected.shelfCode
                    && segment.floorID == expected.floorID
                    && segment.sideSemanticsVersion
                        == expected.sideSemanticsVersion
                    && segment.orientationProvenance
                        == expected.orientationProvenance
                    && vectorsEqual(
                        segment.longitudinalStartM,
                        expected.longitudinalStartM)
                    && vectorsEqual(
                        segment.longitudinalEndM,
                        expected.longitudinalEndM)
                    && vectorsEqual(
                        segment.longitudinalAxis,
                        expected.longitudinalAxis)
                    && vectorsEqual(segment.frontNormal, expected.frontNormal)
                    && vectorsEqual(segment.backNormal, expected.backNormal),
                "v2 shelf segment 未确定性绑定对应货架 geometry/yaw。")
        }
    }

    private static func sourceElement(
        _ raw: [String: Any]
    ) throws -> PriorMapSourceElement {
        guard let identifier = raw["id"] as? String, !identifier.isEmpty,
              let sourceRow = StrictJSONScalar.integer(raw["source_row"]),
              sourceRow > 0,
              let floorID = raw["floor_id"] as? String, !floorID.isEmpty,
              let shapeType = raw["shape_type"] as? String,
              let visible = StrictJSONScalar.boolean(raw["visible"]),
              let locked = StrictJSONScalar.boolean(raw["locked"]),
              let code = raw["code"] as? String,
              let crossCode = raw["cross_code"] as? String,
              let rowFlag = raw["row_flag"] as? String,
              let geometry = raw["geometry"] as? [String: Any],
              let source = raw["source"] as? [String: Any] else {
            throw PriorMapPackageIntegrityError.invalid(
                "v2 elements.json 无法重建确定性派生工件。")
        }
        var bounds: [String: Double]?
        if let rawBounds = raw["bounds"] as? [String: Any] {
            let requiredBoundsKeys: Set<String> = [
                "min_x_m", "min_y_m", "max_x_m", "max_y_m",
                "width_m", "height_m",
            ]
            guard let minX = StrictJSONScalar.number(rawBounds["min_x_m"]),
                  let minY = StrictJSONScalar.number(rawBounds["min_y_m"]),
                  let maxX = StrictJSONScalar.number(rawBounds["max_x_m"]),
                  let maxY = StrictJSONScalar.number(rawBounds["max_y_m"]),
                  let width = StrictJSONScalar.number(rawBounds["width_m"]),
                  let height = StrictJSONScalar.number(rawBounds["height_m"]),
                  Set(rawBounds.keys) == requiredBoundsKeys,
                  minX <= maxX, minY <= maxY,
                  abs(width - (maxX - minX)) <= 1.0e-8,
                  abs(height - (maxY - minY)) <= 1.0e-8 else {
                throw PriorMapPackageIntegrityError.invalid(
                    "v2 element bounds 无法用于确定性派生。")
            }
            bounds = [
                "min_x_m": minX, "min_y_m": minY,
                "max_x_m": maxX, "max_y_m": maxY,
                "width_m": width, "height_m": height,
            ]
        }
        var center: [Double]?
        if let rawCenter = raw["center_m"] as? [Any] {
            guard rawCenter.count == 2,
                  let x = StrictJSONScalar.number(rawCenter[0]),
                  let y = StrictJSONScalar.number(rawCenter[1]) else {
                throw PriorMapPackageIntegrityError.invalid(
                    "v2 element center_m 无法用于确定性派生。")
            }
            center = [x, y]
        }
        let subsection = raw["subsection"] is NSNull
            ? nil : raw["subsection"]
        let yaw: Double?
        if raw["yaw_rad"] == nil || raw["yaw_rad"] is NSNull {
            yaw = nil
        } else {
            guard let value = StrictJSONScalar.number(raw["yaw_rad"]) else {
                throw PriorMapPackageIntegrityError.invalid(
                    "v2 element yaw_rad 无法用于确定性派生。")
            }
            yaw = value
        }
        return PriorMapSourceElement(
            id: identifier,
            sourceRow: sourceRow,
            floorId: floorID,
            shapeType: shapeType,
            visible: visible,
            locked: locked,
            code: code,
            crossCode: crossCode,
            rowFlag: rowFlag,
            subsection: subsection,
            geometry: geometry,
            bounds: bounds,
            centerM: center,
            yawRad: yaw,
            source: source)
    }

    private static func validateDistanceFieldIntegerTokens(
        _ distance: [String: Any]
    ) throws {
        guard let floors = distance["floors"] as? [String: Any] else {
            throw PriorMapPackageIntegrityError.invalid(
                "v2 distance_fields.floors 无效。")
        }
        for value in floors.values {
            guard let floor = value as? [String: Any],
                  let levels = floor["levels"] as? [[String: Any]] else {
                throw PriorMapPackageIntegrityError.invalid(
                    "v2 distance field levels 无效。")
            }
            for level in levels {
                guard StrictJSONScalar.integer(level["width"]) != nil,
                      StrictJSONScalar.integer(level["height"]) != nil,
                      let rows = level["rows"] as? [Any] else {
                    throw PriorMapPackageIntegrityError.invalid(
                        "v2 distance field dimensions 必须是严格整数。")
                }
                for rawRow in rows {
                    guard let row = rawRow as? [Any],
                          row.allSatisfy({
                              StrictJSONScalar.integer($0) != nil
                          }) else {
                        throw PriorMapPackageIntegrityError.invalid(
                            "v2 distance field RLE 必须只含严格整数。")
                    }
                }
            }
        }
    }

    /// One parsed artifact from the immutable snapshot. Missing or
    /// non-object content fails closed; nothing is re-opened here.
    private static func object(
        _ snapshot: PriorMapPackageSnapshot,
        _ name: String
    ) throws -> [String: Any] {
        guard let object = snapshot.artifactsByName[name]?.parsedJSON else {
            throw PriorMapPackageIntegrityError.invalid(
                "\(name) 缺失或顶层必须是对象。")
        }
        return object
    }

    private static func canonicalData(_ value: Any) throws -> Data {
        return try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }

    private static func string(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let value = value as? NSNumber {
            guard CFGetTypeID(value) != CFBooleanGetTypeID() else {
                return nil
            }
            return value.stringValue
        }
        return nil
    }

    private static func require(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) throws {
        if !condition() {
            throw PriorMapPackageIntegrityError.invalid(message)
        }
    }

    private static func isValidSHA256(_ value: String) -> Bool {
        return value.count == 64 && value.unicodeScalars.allSatisfy {
            ($0.value >= 0x30 && $0.value <= 0x39)
                || ($0.value >= 0x61 && $0.value <= 0x66)
        }
    }

    /// P7R6C: geometry coordinates are strict JSON numbers; a boolean
    /// bridged through NSNumber can no longer read as 1.0.
    private static func geometryPoints(_ value: Any?) -> [(Double, Double)] {
        guard let geometry = value as? [String: Any] else { return [] }
        var coordinates = geometry["coordinates"]
        if geometry["type"] as? String == "point", let point = coordinates {
            coordinates = [point]
        }
        guard let rawPoints = coordinates as? [[Any]] else { return [] }
        return rawPoints.compactMap {
            guard $0.count >= 2,
                  let x = StrictJSONScalar.number($0[0]),
                  let y = StrictJSONScalar.number($0[1]) else {
                return nil
            }
            return (x, y)
        }
    }

    private static func boundsMatch(
        _ value: Any?,
        points: [(Double, Double)]
    ) -> Bool {
        guard !points.isEmpty, let bounds = value as? [String: Any] else { return false }
        let expected = [
            "min_x_m": points.map(\.0).min()!,
            "min_y_m": points.map(\.1).min()!,
            "max_x_m": points.map(\.0).max()!,
            "max_y_m": points.map(\.1).max()!,
        ]
        return expected.allSatisfy {
            guard let actual = StrictJSONScalar.number(bounds[$0.key]) else {
                return false
            }
            return abs(actual - $0.value) <= 1.0e-5
        }
    }

    private static func boundsEqual(_ lhs: Any?, _ rhs: Any?) -> Bool {
        guard let left = lhs as? [String: Any],
              let right = rhs as? [String: Any] else { return false }
        let keys: Set<String> = [
            "min_x_m", "min_y_m", "max_x_m", "max_y_m",
            "width_m", "height_m",
        ]
        guard Set(left.keys) == keys, Set(right.keys) == keys else {
            return false
        }
        return keys.allSatisfy {
            guard let a = StrictJSONScalar.number(left[$0]),
                  let b = StrictJSONScalar.number(right[$0]) else { return false }
            return abs(a - b) <= 1.0e-8
        }
    }

    private static func pointsContained(
        _ points: [(Double, Double)],
        in rawBounds: [String: Any]
    ) -> Bool {
        guard let minX = StrictJSONScalar.number(rawBounds["min_x_m"]),
              let minY = StrictJSONScalar.number(rawBounds["min_y_m"]),
              let maxX = StrictJSONScalar.number(rawBounds["max_x_m"]),
              let maxY = StrictJSONScalar.number(rawBounds["max_y_m"]) else {
            return false
        }
        return points.allSatisfy {
            $0.0 >= minX - 1.0e-6 && $0.0 <= maxX + 1.0e-6
                && $0.1 >= minY - 1.0e-6 && $0.1 <= maxY + 1.0e-6
        }
    }

    private static func indexedIds(_ value: Any?) -> Set<String> {
        guard let cells = value as? [String: Any] else { return [] }
        return Set(cells.values.flatMap { ($0 as? [String]) ?? [] })
    }
}
