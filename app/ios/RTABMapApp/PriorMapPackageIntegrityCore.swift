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
                try require(
                    child["format"] as? String == artifact["format"] as? String
                        && StrictJSONScalar.integer(child["version"])
                            == StrictJSONScalar.integer(artifact["version"]),
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

        guard let floors = manifest["floors"] as? [[String: Any]],
              let elements = elementsPayload["elements"] as? [[String: Any]],
              let shelves = shelvesPayload["shelves"] as? [[String: Any]],
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
            byId[identifier] = element
        }
        try require(
            byId.count == elements.count
                && StrictJSONScalar.integer(manifest["element_count"])
                    == elements.count,
            "地图包元素 ID 或数量不一致。")
        try validateSubset(
            shelves,
            expectedTypes: ["MapShelf"],
            elements: byId,
            label: "shelves.json")
        try validateSubset(
            structures,
            expectedTypes: ["MapTable", "MapPillar", "MapTableFeature"],
            elements: byId,
            label: "fixed_structures.json")

        var allPoints: [(Double, Double)] = []
        var pointsByFloor: [String: [(Double, Double)]] = [:]
        for element in elements {
            guard let identifier = element["id"] as? String else { continue }
            let points = geometryPoints(element["geometry"])
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
                      ["MapShelf", "MapTable", "MapPillar", "MapTableFeature"]
                        .contains(element["shape_type"] as? String ?? "") else {
                    return nil
                }
                return element["id"] as? String
            })
        try require(
            indexedStructures == expectedStructures && indexedRoads == edgeIds,
            "空间索引引用或覆盖范围与结构/道路不一致。")
        try require(
            StrictJSONScalar.boolean(validation["valid"]) == true,
            "PC 验证报告未标记为有效。")
    }

    private static func validateSubset(
        _ subset: [[String: Any]],
        expectedTypes: Set<String>,
        elements: [String: [String: Any]],
        label: String
    ) throws {
        let expected = Set(
            elements.compactMap { identifier, value in
                expectedTypes.contains(value["shape_type"] as? String ?? "")
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

    private static func indexedIds(_ value: Any?) -> Set<String> {
        guard let cells = value as? [String: Any] else { return [] }
        return Set(cells.values.flatMap { ($0 as? [String]) ?? [] })
    }
}
