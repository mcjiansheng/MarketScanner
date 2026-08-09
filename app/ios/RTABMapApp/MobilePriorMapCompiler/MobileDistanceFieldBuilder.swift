import Foundation
import CryptoKit

/// Deterministic multi-resolution distance fields, mirroring
/// `tools/PriorMap/distance_field.py` so the mobile compiler and the PC
/// golden oracle emit byte-identical `data_sha256` payloads.
enum MobileDistanceFieldBuilder {
    static let formatValue = "MarketScannerDistanceFields"
    static let versionValue = 1
    static let defaultResolutionsM: [Double] = [0.40, 0.20, 0.10]
    static let defaultTruncationM: Double = 2.0
    static let maximumDimensionCells = 20_000
    static let maximumCellsPerLevel = 8_000_000
    static let maximumTotalCells = 16_000_000
    static let maximumSeedSamplesPerSegment = 100_000

    struct Segment {
        var start: (Double, Double)
        var end: (Double, Double)
    }

    private struct Grid {
        var originX: Double
        var originY: Double
        var width: Int
        var height: Int
    }

    /// Builds the distance-fields artifact for the given elements and
    /// per-floor bounds.
    static func build(
        elements: [PriorMapSourceElement],
        floors: [[String: Any]],
        resolutionsM: [Double] = defaultResolutionsM,
        truncationM: Double = defaultTruncationM
    ) throws -> [String: Any] {
        guard !resolutionsM.isEmpty,
              resolutionsM.allSatisfy({ $0.isFinite && $0 > 0 }),
              truncationM.isFinite,
              truncationM > 0, truncationM <= 2.55 else {
            throw MapSourceImportError.invalidGeometry(
                shapeType: "distance_field",
                reason: "resolutions/truncation are invalid")
        }
        var gridsByFloor: [String: [Grid]] = [:]
        var totalCells: Int64 = 0
        for floor in floors {
            guard let floorID = floor["id"] as? String, !floorID.isEmpty,
                  gridsByFloor[floorID] == nil,
                  let bounds = floor["bounds"] as? [String: Any] else {
                throw MapSourceImportError.invalidGeometry(
                    shapeType: "distance_field",
                    reason: "floor identity/bounds are invalid or duplicated")
            }
            var floorGrids: [Grid] = []
            for resolution in resolutionsM {
                let grid = try validatedGrid(
                    bounds: bounds,
                    resolution: resolution,
                    truncationM: truncationM)
                totalCells += Int64(grid.width) * Int64(grid.height)
                guard totalCells <= Int64(maximumTotalCells) else {
                    throw MapSourceImportError.invalidGeometry(
                        shapeType: "distance_field",
                        reason: "total grid cell budget exceeds \(maximumTotalCells)")
                }
                floorGrids.append(grid)
            }
            gridsByFloor[floorID] = floorGrids
        }
        let segmentsByFloor = segments(elements)
        var payloadFloors: [String: Any] = [:]
        for floor in floors {
            guard let floorID = floor["id"] as? String,
                  let floorGrids = gridsByFloor[floorID] else {
                throw MapSourceImportError.invalidGeometry(
                    shapeType: "distance_field",
                    reason: "preflight grid is missing")
            }
            var levels: [[String: Any]] = []
            for (resolution, grid) in zip(resolutionsM, floorGrids) {
                levels.append(
                    try level(
                        segments: segmentsByFloor[floorID] ?? [],
                        resolution: resolution,
                        truncationM: truncationM,
                        grid: grid
                    )
                )
            }
            payloadFloors[floorID] = ["levels": levels]
        }
        return [
            "format": formatValue,
            "version": versionValue,
            "unit": "metre",
            "distance_encoding": "unsigned_centimetres",
            "truncation_distance_m": truncationM,
            "floors": payloadFloors,
        ]
    }

    static func segments(_ elements: [PriorMapSourceElement]) -> [String: [Segment]] {
        var result: [String: [Segment]] = [:]
        for element in elements {
            let role = ElementRoleClassifier.role(for: element.shapeType)
            guard (role == .shelf || role == .fixedStructure), element.visible,
                  let geometry = element.geometry,
                  let coordinates = geometry["coordinates"] as? [[Double]],
                  coordinates.count >= 2
            else { continue }
            var points = coordinates
            if points.first != points.last {
                points.append(points.first!)
            }
            var floorSegments = result[element.floorId] ?? []
            for index in 0..<(points.count - 1) {
                floorSegments.append(Segment(
                    start: (points[index][0], points[index][1]),
                    end: (points[index + 1][0], points[index + 1][1])
                ))
            }
            result[element.floorId] = floorSegments
        }
        return result
    }

    private static func seedCells(
        segments: [Segment],
        originX: Double,
        originY: Double,
        resolution: Double,
        width: Int,
        height: Int
    ) throws -> Set<Int64> {
        var seeds = Set<Int64>()
        for segment in segments {
            let dx = segment.end.0 - segment.start.0
            let dy = segment.end.1 - segment.start.1
            let length = hypot(dx, dy)
            let rawSteps = ceil(length / max(resolution * 0.45, 0.01))
            guard length.isFinite, rawSteps.isFinite,
                  rawSteps <= Double(maximumSeedSamplesPerSegment),
                  let convertedSteps = Int(exactly: rawSteps) else {
                throw MapSourceImportError.invalidGeometry(
                    shapeType: "distance_field",
                    reason: "segment seed sampling exceeds the resource budget")
            }
            let steps = max(1, convertedSteps)
            for index in 0...steps {
                let ratio = Double(index) / Double(steps)
                let x = segment.start.0 + dx * ratio
                let y = segment.start.1 + dy * ratio
                let cellX = Int(floor((x - originX) / resolution))
                let cellY = Int(floor((y - originY) / resolution))
                if cellX >= 0, cellY >= 0, cellX < width, cellY < height {
                    seeds.insert(Int64(cellY) * Int64(width) + Int64(cellX))
                }
            }
        }
        return seeds
    }

    private static func rowRLE(
        width: Int,
        height: Int,
        distances: [Int64: Double],
        truncationCm: Int
    ) -> [[Int]] {
        var rows: [[Int]] = []
        for y in 0..<height {
            var encoded: [Int] = []
            var previous: Int?
            var count = 0
            for x in 0..<width {
                let meters = distances[Int64(y) * Int64(width) + Int64(x)]
                    ?? Double(truncationCm) / 100.0
                let value = min(truncationCm, Int((meters * 100.0).rounded()))
                if previous == nil || value == previous {
                    count += 1
                } else {
                    encoded.append(count)
                    encoded.append(previous!)
                    count = 1
                }
                previous = value
            }
            if let previous = previous {
                encoded.append(count)
                encoded.append(previous)
            }
            rows.append(encoded)
        }
        return rows
    }

    private static func validatedGrid(
        bounds: [String: Any],
        resolution: Double,
        truncationM: Double
    ) throws -> Grid {
        guard let minX = StrictJSONScalar.number(bounds["min_x_m"]),
              let minY = StrictJSONScalar.number(bounds["min_y_m"]),
              let maxX = StrictJSONScalar.number(bounds["max_x_m"]),
              let maxY = StrictJSONScalar.number(bounds["max_y_m"]),
              minX <= maxX, minY <= maxY else {
            throw MapSourceImportError.invalidGeometry(
                shapeType: "distance_field", reason: "bounds are invalid")
        }
        let originX = floor((minX - truncationM) / resolution) * resolution
        let originY = floor((minY - truncationM) / resolution) * resolution
        let maximumX = ceil((maxX + truncationM) / resolution) * resolution
        let maximumY = ceil((maxY + truncationM) / resolution) * resolution
        let rawWidth = ((maximumX - originX) / resolution).rounded() + 1
        let rawHeight = ((maximumY - originY) / resolution).rounded() + 1
        guard originX.isFinite, originY.isFinite,
              maximumX.isFinite, maximumY.isFinite,
              rawWidth.isFinite, rawHeight.isFinite,
              rawWidth >= 1, rawHeight >= 1,
              rawWidth <= Double(maximumDimensionCells),
              rawHeight <= Double(maximumDimensionCells),
              let width = Int(exactly: rawWidth),
              let height = Int(exactly: rawHeight),
              Int64(width) * Int64(height) <= Int64(maximumCellsPerLevel) else {
            throw MapSourceImportError.invalidGeometry(
                shapeType: "distance_field",
                reason: "grid exceeds dimension/cell budget")
        }
        return Grid(originX: originX, originY: originY, width: width, height: height)
    }

    private static func level(
        segments: [Segment],
        resolution: Double,
        truncationM: Double,
        grid: Grid
    ) throws -> [String: Any] {
        let originX = grid.originX
        let originY = grid.originY
        let width = grid.width
        let height = grid.height
        let truncationCm = Int((truncationM * 100.0).rounded())

        let seeds = try seedCells(
            segments: segments, originX: originX, originY: originY,
            resolution: resolution, width: width, height: height)
        var distances: [Int64: Double] = [:]
        var heap = Heap<HeapNode>()
        for seed in seeds {
            distances[seed] = 0.0
            heap.push(HeapNode(distance: 0.0, x: Int(seed % Int64(width)), y: Int(seed / Int64(width))))
        }
        let neighbours: [(Int, Int, Double)] = [
            (-1, 0, 1.0), (1, 0, 1.0), (0, -1, 1.0), (0, 1, 1.0),
            (-1, -1, sqrt(2.0)), (-1, 1, sqrt(2.0)), (1, -1, sqrt(2.0)), (1, 1, sqrt(2.0)),
        ]
        while let node = heap.pop() {
            let nodeKey = Int64(node.y) * Int64(width) + Int64(node.x)
            let recorded = distances[nodeKey] ?? truncationM
            if node.distance > recorded + 1.0e-12 {
                continue
            }
            for (dx, dy, scale) in neighbours {
                let followingX = node.x + dx
                let followingY = node.y + dy
                let followingDistance = node.distance + resolution * scale
                let key = Int64(followingY) * Int64(width) + Int64(followingX)
                if followingDistance > truncationM
                    || followingX < 0 || followingY < 0
                    || followingX >= width || followingY >= height
                    || followingDistance >= (distances[key] ?? truncationM) {
                    continue
                }
                distances[key] = followingDistance
                heap.push(HeapNode(distance: followingDistance, x: followingX, y: followingY))
            }
        }

        let rows = rowRLE(width: width, height: height, distances: distances, truncationCm: truncationCm)
        let canonical = try CanonicalJSONEncoder.encode(rows)
        let sha = CanonicalSourceHasher.sha256(canonical)
        return [
            "resolution_m": resolution,
            "origin_m": [SourceGeometry.rounded(originX), SourceGeometry.rounded(originY)],
            "width": width,
            "height": height,
            "encoding": "row_rle_u8_cm",
            "data_sha256": sha,
            "rows": rows,
        ]
    }
}

private struct HeapNode: Comparable {
    var distance: Double
    var x: Int
    var y: Int

    static func < (lhs: HeapNode, rhs: HeapNode) -> Bool {
        return lhs.distance < rhs.distance
    }
}

/// Minimal binary min-heap used by the distance-field Dijkstra pass.
struct Heap<Element: Comparable> {
    private var storage: [Element] = []

    var isEmpty: Bool { storage.isEmpty }

    mutating func push(_ element: Element) {
        storage.append(element)
        var index = storage.count - 1
        while index > 0 {
            let parent = (index - 1) / 2
            if storage[index] < storage[parent] {
                storage.swapAt(index, parent)
                index = parent
            } else {
                break
            }
        }
    }

    mutating func pop() -> Element? {
        guard !storage.isEmpty else { return nil }
        if storage.count == 1 { return storage.removeLast() }
        let first = storage[0]
        storage[0] = storage.removeLast()
        var index = 0
        while true {
            let left = 2 * index + 1
            let right = 2 * index + 2
            var smallest = index
            if left < storage.count && storage[left] < storage[smallest] {
                smallest = left
            }
            if right < storage.count && storage[right] < storage[smallest] {
                smallest = right
            }
            if smallest == index { break }
            storage.swapAt(index, smallest)
            index = smallest
        }
        return first
    }
}
