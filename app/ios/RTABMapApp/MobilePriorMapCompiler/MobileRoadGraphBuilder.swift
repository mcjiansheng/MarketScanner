import Foundation

/// Deterministic road graph and spatial index builders, mirroring
/// `tools/PriorMap/xlsx_to_prior_map.py::_road_graph` and `_spatial_index`
/// so the mobile compiler and the PC golden oracle agree on node/edge
/// identities and cell assignment.
enum MobileRoadGraphBuilder {
    static func build(
        elements: [PriorMapSourceElement],
        warnings: inout [MapSourceWarning]
    ) -> [String: Any] {
        // Crosses from MapCross elements.
        var crosses: [[String: Any]] = []
        var crossByKey: [String: [String: Any]] = [:] // floor|code -> cross
        for element in elements where element.visible
            && ElementRoleClassifier.role(for: element.shapeType) == .road
            && element.shapeType == "MapCross" {
            guard let geometry = element.geometry,
                  let coordinates = geometry["coordinates"] as? [[Double]]
            else { continue }
            let code = element.code.isEmpty ? element.id : element.code
            let key = "\(element.floorId)|\(code)"
            var graphID = code
            if crossByKey[key] != nil {
                graphID = "\(code)@\(element.id)"
                warnings.append(MapSourceWarning(
                    code: "duplicate_cross_id",
                    row: element.sourceRow,
                    floor: element.floorId,
                    shapeType: "MapCross",
                    message: "楼层内道路编号 \(code) 重复；道路点仍关联首次出现的道路，重复线已独立保留。"
                ))
            }
            let widthM = SourceGeometry.rounded(
                (element.source["lineWidth"] as? Double
                    ?? ElementNormalizer.asDouble(element.source["lineWidth"])
                    ?? 0.0) / 100.0
            )
            let cross: [String: Any] = [
                "id": graphID,
                "element_id": element.id,
                "floor_id": element.floorId,
                "points_m": coordinates,
                "width_m": widthM,
            ]
            crosses.append(cross)
            if crossByKey[key] == nil {
                crossByKey[key] = cross
            }
        }

        // Nodes from MapRoadPoint elements.
        var nodes: [[String: Any]] = []
        var nodesByCross: [String: [[String: Any]]] = [:]
        var usedNodeIDs: Set<String> = []
        for element in elements where element.visible
            && ElementRoleClassifier.role(for: element.shapeType) == .road
            && element.shapeType == "MapRoadPoint" {
            guard let geometry = element.geometry,
                  let coordinates = geometry["coordinates"] as? [Double],
                  coordinates.count >= 2
            else { continue }
            let rawCodes = element.source["crossCodes"]
            var crossCodes: [String] = []
            if let text = rawCodes as? String {
                crossCodes = [text]
            } else if let number = rawCodes as? Int {
                crossCodes = [String(number)]
            } else if let array = rawCodes as? [Any] {
                crossCodes = array.compactMap {
                    if let text = $0 as? String { return text }
                    if let number = $0 as? Int { return String(number) }
                    return nil
                }
            }
            let preferredID = element.code.isEmpty ? element.id : element.code
            var nodeID = preferredID
            if usedNodeIDs.contains(nodeID) {
                nodeID = "\(preferredID)@\(element.id)"
                warnings.append(MapSourceWarning(
                    code: "duplicate_road_point_id",
                    row: element.sourceRow,
                    floor: element.floorId,
                    shapeType: "MapRoadPoint",
                    message: "道路点编号 \(preferredID) 重复；已分配稳定唯一 ID，节点未丢失。"
                ))
            }
            usedNodeIDs.insert(nodeID)
            let node: [String: Any] = [
                "id": nodeID,
                "element_id": element.id,
                "floor_id": element.floorId,
                "position_m": coordinates,
                "cross_ids": crossCodes,
                "visible": element.visible,
            ]
            nodes.append(node)
            for code in crossCodes {
                let key = "\(element.floorId)|\(code)"
                // Formal source maps may keep road centreline drawings hidden
                // while visible road points still carry their `crossCodes`.
                // Preserve the membership now; after the complete inventory is
                // known we can deterministically recover a missing straight
                // centreline from two or more member points.
                nodesByCross[key, default: []].append(node)
            }
            if crossCodes.isEmpty {
                warnings.append(MapSourceWarning(
                    code: "road_point_without_cross",
                    row: element.sourceRow,
                    floor: element.floorId,
                    shapeType: "MapRoadPoint",
                    message: "道路点没有 crossCodes，已保留为孤立节点。"
                ))
            }
        }

        // Mirror the PC compiler's `road_point_membership_v1` recovery. The
        // active package manifest binds these visible road points. Hidden line
        // geometry cannot become authoritative until a future package schema
        // binds a dedicated topology source file.
        for key in nodesByCross.keys.sorted() where crossByKey[key] == nil {
            let crossNodes = (nodesByCross[key] ?? []).sorted {
                (($0["id"] as? String) ?? "") < (($1["id"] as? String) ?? "")
            }
            let parts = key.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            let floorID = parts.first.map(String.init) ?? ""
            let crossID = parts.count == 2 ? String(parts[1]) : ""
            guard crossNodes.count >= 2 else {
                let node = crossNodes.first
                warnings.append(MapSourceWarning(
                    code: "missing_cross",
                    row: 0,
                    floor: floorID,
                    shapeType: "MapRoadPoint",
                    message: "道路点引用了不存在的道路 \(crossID)，且成员不足，无法恢复道路边。"
                ))
                _ = node
                continue
            }
            var endpointPair: ([String: Any], [String: Any])?
            var endpointDistance = -Double.infinity
            var endpointIDs = ("", "")
            for firstIndex in 0..<(crossNodes.count - 1) {
                for secondIndex in (firstIndex + 1)..<crossNodes.count {
                    let first = crossNodes[firstIndex]
                    let second = crossNodes[secondIndex]
                    let firstPosition = (first["position_m"] as? [Double]) ?? []
                    let secondPosition = (second["position_m"] as? [Double]) ?? []
                    let candidateDistance = distance(firstPosition, secondPosition)
                    let candidateIDs = [
                        (first["id"] as? String) ?? "",
                        (second["id"] as? String) ?? "",
                    ].sorted()
                    if candidateDistance > endpointDistance + 1.0e-12
                        || (abs(candidateDistance - endpointDistance) <= 1.0e-12
                            && (candidateIDs[0] < endpointIDs.0
                                || (candidateIDs[0] == endpointIDs.0
                                    && candidateIDs[1] < endpointIDs.1))) {
                        endpointPair = (first, second)
                        endpointDistance = candidateDistance
                        endpointIDs = (candidateIDs[0], candidateIDs[1])
                    }
                }
            }
            guard let endpoints = endpointPair, endpointDistance > 1.0e-9,
                  var firstPoint = endpoints.0["position_m"] as? [Double],
                  var secondPoint = endpoints.1["position_m"] as? [Double],
                  firstPoint.count >= 2, secondPoint.count >= 2 else {
                warnings.append(MapSourceWarning(
                    code: "missing_cross",
                    row: 0,
                    floor: floorID,
                    shapeType: "MapRoadPoint",
                    message: "道路 \(crossID) 的成员点全部重合，无法恢复道路边。"
                ))
                continue
            }
            firstPoint = Array(firstPoint.prefix(2))
            secondPoint = Array(secondPoint.prefix(2))
            let firstID = (endpoints.0["id"] as? String) ?? ""
            let secondID = (endpoints.1["id"] as? String) ?? ""
            if secondPoint[0] < firstPoint[0]
                || (secondPoint[0] == firstPoint[0]
                    && (secondPoint[1] < firstPoint[1]
                        || (secondPoint[1] == firstPoint[1]
                            && secondID < firstID))) {
                swap(&firstPoint, &secondPoint)
            }
            let cross: [String: Any] = [
                "id": crossID,
                "element_id": "",
                "floor_id": floorID,
                "points_m": [firstPoint, secondPoint],
                "width_m": 0.0,
                "provenance": "road_point_membership_v1",
            ]
            crosses.append(cross)
            crossByKey[key] = cross
            warnings.append(MapSourceWarning(
                code: "road_cross_inferred_from_points",
                row: 0,
                floor: floorID,
                shapeType: "MapRoadPoint",
                message: "道路 \(crossID) 的线元素不可见或缺失，已由 \(crossNodes.count) 个可见道路点恢复拓扑。"
            ))
        }

        // Edges: consecutive nodes projected onto each cross polyline.
        var edgesByKey: [String: [String: Any]] = [:]
        for (key, crossNodes) in nodesByCross {
            guard let cross = crossByKey[key] else { continue }
            guard let points = cross["points_m"] as? [[Double]] else { continue }
            let ordered = crossNodes.sorted { lhs, rhs in
                let lhsPosition = (lhs["position_m"] as? [Double]) ?? []
                let rhsPosition = (rhs["position_m"] as? [Double]) ?? []
                let lhsAbscissa = polylineAbscissa(lhsPosition, polyline: points)
                let rhsAbscissa = polylineAbscissa(rhsPosition, polyline: points)
                let lhsID = (lhs["id"] as? String) ?? ""
                let rhsID = (rhs["id"] as? String) ?? ""
                if abs(lhsAbscissa - rhsAbscissa) > 1.0e-12 {
                    return lhsAbscissa < rhsAbscissa
                }
                return lhsID < rhsID
            }
            let floorID = (cross["floor_id"] as? String) ?? ""
            let crossID = (cross["id"] as? String) ?? ""
            for (first, second) in zip(ordered, ordered.dropFirst()) {
                let firstID = (first["id"] as? String) ?? ""
                let secondID = (second["id"] as? String) ?? ""
                if firstID == secondID { continue }
                let pair = [firstID, secondID].sorted()
                let edgeKey = "\(floorID)|\(pair[0])--\(pair[1])"
                let firstPosition = (first["position_m"] as? [Double]) ?? []
                let secondPosition = (second["position_m"] as? [Double]) ?? []
                let length = distance(firstPosition, secondPosition)
                if length <= 1.0e-9 {
                    warnings.append(MapSourceWarning(
                        code: "zero_length_road_edge",
                        row: 0,
                        floor: floorID,
                        shapeType: "MapRoadPoint",
                        message: "道路 \(crossID) 中存在重合道路点，未建立零长度边。"
                    ))
                    continue
                }
                var edge = edgesByKey[edgeKey] ?? [
                    "id": "\(floorID):\(pair[0])--\(pair[1])",
                    "floor_id": floorID,
                    "from": pair[0],
                    "to": pair[1],
                    "length_m": SourceGeometry.rounded(length),
                    "cross_ids": [],
                ]
                var crossIDs = (edge["cross_ids"] as? [String]) ?? []
                if !crossIDs.contains(crossID) {
                    crossIDs.append(crossID)
                    crossIDs.sort()
                }
                edge["cross_ids"] = crossIDs
                edgesByKey[edgeKey] = edge
            }
        }

        let edges = edgesByKey.values.sorted {
            (($0["id"] as? String) ?? "") < (($1["id"] as? String) ?? "")
        }
        var adjacency: [String: Set<String>] = [:]
        for node in nodes {
            adjacency[(node["id"] as? String) ?? ""] = []
        }
        for edge in edges {
            let from = (edge["from"] as? String) ?? ""
            let to = (edge["to"] as? String) ?? ""
            adjacency[from, default: []].insert(to)
            adjacency[to, default: []].insert(from)
        }
        var components = 0
        var unvisited = Set(adjacency.keys)
        while let start = unvisited.popFirst() {
            components += 1
            var queue = [start]
            while !queue.isEmpty {
                let nodeID = queue.removeFirst()
                for neighbour in adjacency[nodeID] ?? [] {
                    if unvisited.contains(neighbour) {
                        unvisited.remove(neighbour)
                        queue.append(neighbour)
                    }
                }
            }
        }
        let isolated = adjacency.keys
            .filter { (adjacency[$0] ?? []).isEmpty }
            .sorted()

        return [
            "format": "MarketScannerRoadGraph",
            "version": 1,
            "crosses": crosses.sorted {
                let lhs = (($0["floor_id"] as? String) ?? "", ($0["id"] as? String) ?? "")
                let rhs = (($1["floor_id"] as? String) ?? "", ($1["id"] as? String) ?? "")
                return lhs.0 == rhs.0 ? lhs.1 < rhs.1 : lhs.0 < rhs.0
            },
            "nodes": nodes.sorted {
                let lhs = (($0["floor_id"] as? String) ?? "", ($0["id"] as? String) ?? "")
                let rhs = (($1["floor_id"] as? String) ?? "", ($1["id"] as? String) ?? "")
                return lhs.0 == rhs.0 ? lhs.1 < rhs.1 : lhs.0 < rhs.0
            },
            "edges": edges,
            "statistics": [
                "cross_count": crosses.count,
                "node_count": nodes.count,
                "edge_count": edges.count,
                "connected_component_count": components,
                "isolated_node_count": isolated.count,
                "isolated_node_ids": isolated,
            ],
        ]
    }

    private static func distance(_ first: [Double], _ second: [Double]) -> Double {
        guard first.count >= 2, second.count >= 2 else { return 0 }
        return hypot(first[0] - second[0], first[1] - second[1])
    }

    /// Arc length at the closest projection onto a possibly bent road,
    /// matching `_polyline_abscissa`.
    static func polylineAbscissa(_ point: [Double], polyline: [[Double]]) -> Double {
        guard polyline.count >= 2, point.count >= 2 else { return 0 }
        var bestDistance = Double.infinity
        var bestAbscissa = 0.0
        var accumulated = 0.0
        let px = point[0]
        let py = point[1]
        for index in 0..<(polyline.count - 1) {
            let start = polyline[index]
            let end = polyline[index + 1]
            let sx = start[0]
            let sy = start[1]
            let dx = end[0] - sx
            let dy = end[1] - sy
            let lengthSquared = dx * dx + dy * dy
            if lengthSquared <= 1.0e-18 { continue }
            let ratio = max(0.0, min(1.0, ((px - sx) * dx + (py - sy) * dy) / lengthSquared))
            let projectedX = sx + ratio * dx
            let projectedY = sy + ratio * dy
            let distanceToPoint = hypot(px - projectedX, py - projectedY)
            let segmentLength = sqrt(lengthSquared)
            let abscissa = accumulated + ratio * segmentLength
            if distanceToPoint < bestDistance - 1.0e-12
                || (abs(distanceToPoint - bestDistance) <= 1.0e-12 && abscissa < bestAbscissa) {
                bestDistance = distanceToPoint
                bestAbscissa = abscissa
            }
            accumulated += segmentLength
        }
        return bestAbscissa
    }
}

enum MobileSpatialIndexBuilder {
    static let maximumCellAssignments = 8_000_000

    /// `floors` names every manifest floor so the spatial index keys
    /// exactly match `manifest.floors` (the production integrity
    /// validator requires the exact set).
    static func build(
        elements: [PriorMapSourceElement],
        graph: [String: Any],
        floors: [[String: Any]]
    ) throws -> [String: Any] {
        let cellSizeM = 5.0
        var totalAssignments: Int64 = 0
        var floorsByID: [String: Any] = [:]
        var elementRoles: [String: Any] = [:]
        for floor in floors {
            guard let floorID = floor["id"] as? String else { continue }
            floorsByID[floorID] = [
                "cells": [String: [String]](),
                "road_cells": [String: [String]](),
            ]
        }
        var byFloor: [String: [[String: Any]]] = [:]
        for element in elements {
            let role = ElementRoleClassifier.role(for: element.shapeType)
            if (role == .shelf || role == .fixedStructure), element.visible,
               element.bounds != nil {
                byFloor[element.floorId, default: []].append(element.canonicalPayload)
                elementRoles[element.id] = [
                    "role": role.rawValue,
                    "shape_type": element.shapeType,
                ]
            }
        }
        for floorID in byFloor.keys.sorted() {
            let floorElements = byFloor[floorID] ?? []
            var cells: [String: [String]] = [:]
            for element in floorElements {
                guard let bounds = element["bounds"] as? [String: Double],
                      let minXValue = bounds["min_x_m"],
                      let maxXValue = bounds["max_x_m"],
                      let minYValue = bounds["min_y_m"],
                      let maxYValue = bounds["max_y_m"] else {
                    throw MapSourceImportError.invalidGeometry(
                        shapeType: "spatial_index",
                        reason: "structure bounds are missing")
                }
                let ranges = try cellRanges(
                    minX: minXValue, maxX: maxXValue,
                    minY: minYValue, maxY: maxYValue,
                    cellSizeM: cellSizeM)
                totalAssignments += ranges.assignmentCount
                guard totalAssignments <= Int64(maximumCellAssignments) else {
                    throw MapSourceImportError.invalidGeometry(
                        shapeType: "spatial_index",
                        reason: "cell assignment budget exceeds \(maximumCellAssignments)")
                }
                let elementID = (element["id"] as? String) ?? ""
                for cellX in ranges.x {
                    for cellY in ranges.y {
                        cells["\(cellX),\(cellY)", default: []].append(elementID)
                    }
                }
            }
            var floor = (floorsByID[floorID] as? [String: Any]) ?? ["cells": [String: [String]](), "road_cells": [String: [String]]()]
            floor["cells"] = cells.mapValues { Array(Set($0)).sorted() }
            floorsByID[floorID] = floor
        }

        var nodePositions: [String: [Double]] = [:]
        if let nodes = graph["nodes"] as? [[String: Any]] {
            for node in nodes {
                if let position = node["position_m"] as? [Double], position.count >= 2 {
                    nodePositions[(node["id"] as? String) ?? ""] = position
                }
            }
        }
        var roadCellsByFloor: [String: [String: [String]]] = [:]
        if let edges = graph["edges"] as? [[String: Any]] {
            for edge in edges {
                guard let from = nodePositions[(edge["from"] as? String) ?? ""],
                      let to = nodePositions[(edge["to"] as? String) ?? ""]
                else { continue }
                let floorID = (edge["floor_id"] as? String) ?? ""
                let edgeID = (edge["id"] as? String) ?? ""
                let ranges = try cellRanges(
                    minX: min(from[0], to[0]),
                    maxX: max(from[0], to[0]),
                    minY: min(from[1], to[1]),
                    maxY: max(from[1], to[1]),
                    cellSizeM: cellSizeM)
                totalAssignments += ranges.assignmentCount
                guard totalAssignments <= Int64(maximumCellAssignments) else {
                    throw MapSourceImportError.invalidGeometry(
                        shapeType: "spatial_index",
                        reason: "cell assignment budget exceeds \(maximumCellAssignments)")
                }
                for cellX in ranges.x {
                    for cellY in ranges.y {
                        var floorCells = roadCellsByFloor[floorID] ?? [:]
                        floorCells["\(cellX),\(cellY)", default: []].append(edgeID)
                        roadCellsByFloor[floorID] = floorCells
                    }
                }
            }
        }
        for floorID in roadCellsByFloor.keys.sorted() {
            var floor = (floorsByID[floorID] as? [String: Any]) ?? ["cells": [String: [String]](), "road_cells": [String: [String]]()]
            floor["road_cells"] = roadCellsByFloor[floorID]?.mapValues { Array(Set($0)).sorted() } ?? [:]
            floorsByID[floorID] = floor
        }

        return [
            "format": "MarketScannerSpatialIndex",
            "version": 1,
            "cell_size_m": cellSizeM,
            "element_roles": elementRoles,
            "floors": floorsByID,
        ]
    }

    private static func cellRanges(
        minX: Double,
        maxX: Double,
        minY: Double,
        maxY: Double,
        cellSizeM: Double
    ) throws -> (x: ClosedRange<Int>, y: ClosedRange<Int>, assignmentCount: Int64) {
        guard minX.isFinite, maxX.isFinite, minY.isFinite, maxY.isFinite,
              minX <= maxX, minY <= maxY,
              cellSizeM.isFinite, cellSizeM > 0 else {
            throw MapSourceImportError.invalidGeometry(
                shapeType: "spatial_index", reason: "bounds are invalid")
        }
        let lowerX = floor(minX / cellSizeM)
        let upperX = floor(maxX / cellSizeM)
        let lowerY = floor(minY / cellSizeM)
        let upperY = floor(maxY / cellSizeM)
        let spanX = upperX - lowerX + 1
        let spanY = upperY - lowerY + 1
        guard lowerX.isFinite, upperX.isFinite,
              lowerY.isFinite, upperY.isFinite,
              spanX >= 1, spanY >= 1,
              spanX <= Double(maximumCellAssignments),
              spanY <= Double(maximumCellAssignments),
              let minimumX = Int(exactly: lowerX),
              let maximumX = Int(exactly: upperX),
              let minimumY = Int(exactly: lowerY),
              let maximumY = Int(exactly: upperY),
              let width = Int64(exactly: spanX),
              let height = Int64(exactly: spanY),
              width <= Int64(maximumCellAssignments) / height else {
            throw MapSourceImportError.invalidGeometry(
                shapeType: "spatial_index",
                reason: "cell span exceeds the resource budget")
        }
        return (
            minimumX...maximumX,
            minimumY...maximumY,
            width * height)
    }
}
