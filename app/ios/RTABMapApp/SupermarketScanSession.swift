//
//  SupermarketScanSession.swift
//  RTABMapApp
//
//  First-pass supermarket scanning support: segment rollover, floor-area
//  estimation from the walking trajectory, and price-tag position records.
//

import Foundation
import UIKit

struct PriceTagRecord: Codable {
    let id: Int
    let tagIdentifier: String
    let payload: String
    let timestamp: TimeInterval
    let segmentIndex: Int
    let nodeCount: Int
    let x: Float
    let y: Float
    let z: Float
    let roll: Float
    let pitch: Float
    let yaw: Float
    let note: String
}

struct ScanSegmentMetadata: Codable {
    let segmentIndex: Int
    let exportedAt: String
    let knownAreaM2: Double
    let nodeCount: Int
    let databaseMemoryMB: Int
    let usedMemoryMB: Int
    let thresholdAreaM2: Double
    let thresholdDatabaseMB: Int
    let thresholdUsedMemoryMB: Int
    let priceTagCount: Int
}

struct ScanAreaCells: Codable {
    let segmentIndex: Int
    let cellSizeM: Double
    let scanRadiusM: Double
    let cells: [[Int]]
}

struct ScanPoseSample: Codable {
    let timestamp: TimeInterval
    let segmentIndex: Int
    let nodeCount: Int
    let x: Float
    let y: Float
    let z: Float
    let roll: Float
    let pitch: Float
    let yaw: Float
}

enum SegmentTriggerReason: String {
    case area
    case database
    case memory
    case manual

    var localizedText: String {
        switch self {
        case .area:
            return NSLocalizedString("area threshold reached", comment: "Segment trigger reason")
        case .database:
            return NSLocalizedString("database threshold reached", comment: "Segment trigger reason")
        case .memory:
            return NSLocalizedString("memory threshold reached", comment: "Segment trigger reason")
        case .manual:
            return NSLocalizedString("manual save", comment: "Segment trigger reason")
        }
    }
}

final class FloorAreaEstimator {
    private let cellSize: Double
    private let scanRadius: Double
    private var occupiedCells = Set<String>()
    private var lastX: Double?
    private var lastZ: Double?

    init(cellSize: Double = 0.25, scanRadius: Double = 1.25) {
        self.cellSize = cellSize
        self.scanRadius = scanRadius
    }

    func reset() {
        occupiedCells.removeAll()
        lastX = nil
        lastZ = nil
    }

    func update(x: Float, z: Float) -> Double {
        let px = Double(x)
        let pz = Double(z)

        if let lx = lastX, let lz = lastZ {
            let distance = hypot(px - lx, pz - lz)
            let steps = max(1, Int(distance / max(cellSize, 0.01)))
            for i in 0...steps {
                let t = Double(i) / Double(steps)
                markDisk(x: lx + (px - lx) * t, z: lz + (pz - lz) * t)
            }
        } else {
            markDisk(x: px, z: pz)
        }

        lastX = px
        lastZ = pz
        return areaM2
    }

    var areaM2: Double {
        return Double(occupiedCells.count) * cellSize * cellSize
    }

    var cellSizeM: Double {
        return cellSize
    }

    var scanRadiusM: Double {
        return scanRadius
    }

    func occupiedCellCoordinates() -> [[Int]] {
        return occupiedCells.compactMap { key in
            let parts = key.split(separator: ":")
            guard parts.count == 2,
                  let x = Int(parts[0]),
                  let y = Int(parts[1]) else {
                return nil
            }
            return [x, y]
        }.sorted {
            if $0[0] == $1[0] {
                return $0[1] < $1[1]
            }
            return $0[0] < $1[0]
        }
    }

    private func markDisk(x: Double, z: Double) {
        let radiusCells = Int(ceil(scanRadius / cellSize))
        let cx = Int(floor(x / cellSize))
        let cz = Int(floor(z / cellSize))

        for ix in (cx - radiusCells)...(cx + radiusCells) {
            for iz in (cz - radiusCells)...(cz + radiusCells) {
                let dx = (Double(ix) + 0.5) * cellSize - x
                let dz = (Double(iz) + 0.5) * cellSize - z
                if dx * dx + dz * dz <= scanRadius * scanRadius {
                    occupiedCells.insert("\(ix):\(iz)")
                }
            }
        }
    }
}

final class SupermarketScanSession {
    private let fileManager = FileManager.default
    private let documentsDirectory: URL
    private let areaEstimator = FloorAreaEstimator()
    private var customBaseDirectory: URL?
    private(set) var rootDirectory: URL?
    private(set) var segmentIndex: Int = 0
    private(set) var currentAreaM2: Double = 0
    private(set) var priceTags: [PriceTagRecord] = []
    private(set) var poseSamples: [ScanPoseSample] = []
    private var nextTagId: Int = 1

    var areaThresholdM2: Double = 250
    var databaseThresholdMB: Int = 900
    var usedMemoryThresholdMB: Int = 2500
    var minimumNodesBeforeRollover: Int = 30
    var isExportingSegment = false

    init(documentsDirectory: URL) {
        self.documentsDirectory = documentsDirectory
    }

    var baseDirectory: URL {
        return documentsDirectory
    }

    var hasCustomBaseDirectory: Bool {
        return customBaseDirectory != nil
    }

    func setCustomBaseDirectory(_ url: URL?) {
        customBaseDirectory = url
    }

    func clearCustomBaseDirectory() {
        customBaseDirectory = nil
    }

    func refreshUnsavedSessionLocation() {
        if segmentIndex <= 1 {
            rootDirectory = nil
        }
    }

    func startAccessingBaseDirectorySecurityScope() -> Bool {
        return customBaseDirectory?.startAccessingSecurityScopedResource() ?? false
    }

    func stopAccessingBaseDirectorySecurityScope() {
        customBaseDirectory?.stopAccessingSecurityScopedResource()
    }

    func startNewSessionIfNeeded() throws {
        if rootDirectory == nil {
            let stamp = Date().getFormattedDate(format: "yyyyMMdd-HHmmss")
            let root = baseDirectory.appendingPathComponent("SupermarketSession-\(stamp)", isDirectory: true)
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            rootDirectory = root
            segmentIndex = 1
            resetCurrentSegment()
        }
    }

    func resetCurrentSegment() {
        areaEstimator.reset()
        currentAreaM2 = 0
        priceTags.removeAll()
        poseSamples.removeAll()
    }

    func nextSegment() {
        segmentIndex += 1
        resetCurrentSegment()
    }

    func currentSegmentDirectory() throws -> URL {
        try startNewSessionIfNeeded()
        let dir = rootDirectory!.appendingPathComponent(String(format: "segment_%04d", segmentIndex), isDirectory: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func savedSegmentDatabaseURLs() -> [URL] {
        guard let rootDirectory = rootDirectory,
              segmentIndex > 1 else {
            return []
        }

        var roots = [rootDirectory]
        if let customBaseDirectory = customBaseDirectory {
            roots.append(customBaseDirectory.appendingPathComponent(rootDirectory.lastPathComponent, isDirectory: true))
        }

        var urlsByPath = [String: URL]()
        for root in roots {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]) else {
                continue
            }

            for case let fileURL as URL in enumerator {
                guard fileURL.pathExtension == "db",
                      fileURL.lastPathComponent.hasPrefix("rtabmap_segment_") else {
                    continue
                }
                if let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]),
                   values.isRegularFile == true {
                    urlsByPath[fileURL.path] = fileURL
                }
            }
        }

        return urlsByPath.values.sorted { $0.path < $1.path }
    }

    func savedSegmentDatabaseCount() -> Int {
        return savedSegmentDatabaseURLs().count
    }

    func copySegmentToCustomBaseDirectory(from localSegmentDirectory: URL) throws -> URL? {
        guard let customBaseDirectory = customBaseDirectory, let rootDirectory = rootDirectory else {
            return nil
        }

        let exportRoot = customBaseDirectory.appendingPathComponent(rootDirectory.lastPathComponent, isDirectory: true)
        let exportSegment = exportRoot.appendingPathComponent(localSegmentDirectory.lastPathComponent, isDirectory: true)
        let localSummary = try directoryFileSummary(localSegmentDirectory)
        try fileManager.createDirectory(at: exportRoot, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: exportSegment.path) {
            try fileManager.removeItem(at: exportSegment)
        }
        try fileManager.copyItem(at: localSegmentDirectory, to: exportSegment)
        let exportSummary = try directoryFileSummary(exportSegment)
        guard localSummary == exportSummary else {
            throw NSError(
                domain: "SupermarketScanSession",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("External copy verification failed. The local segment was kept.", comment: "Segment copy verification error")])
        }
        return exportSegment
    }

    func removeLocalSegmentDirectory(_ localSegmentDirectory: URL) throws {
        guard localSegmentDirectory.path.hasPrefix(documentsDirectory.path) else {
            throw NSError(
                domain: "SupermarketScanSession",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Refused to delete a segment outside the local app sandbox.", comment: "Segment cleanup safety error")])
        }
        if fileManager.fileExists(atPath: localSegmentDirectory.path) {
            try fileManager.removeItem(at: localSegmentDirectory)
        }
    }

    private func directoryFileSummary(_ directory: URL) throws -> (files: Int, bytes: UInt64) {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]) else {
            throw NSError(
                domain: "SupermarketScanSession",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Unable to read the segment directory contents.", comment: "Segment directory read error")])
        }

        var fileCount = 0
        var totalBytes: UInt64 = 0
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values.isRegularFile == true {
                fileCount += 1
                totalBytes += UInt64(values.fileSize ?? 0)
            }
        }
        return (fileCount, totalBytes)
    }

    func updateArea(timestamp: TimeInterval, nodeCount: Int, x: Float, y: Float, z: Float, roll: Float, pitch: Float, yaw: Float) -> Double {
        currentAreaM2 = areaEstimator.update(x: x, z: z)
        poseSamples.append(ScanPoseSample(
            timestamp: timestamp,
            segmentIndex: segmentIndex,
            nodeCount: nodeCount,
            x: x,
            y: y,
            z: z,
            roll: roll,
            pitch: pitch,
            yaw: yaw))
        return currentAreaM2
    }

    func rolloverReason(nodes: Int, databaseMemoryMB: Int, usedMemoryMB: Int) -> SegmentTriggerReason? {
        guard nodes >= minimumNodesBeforeRollover, !isExportingSegment else {
            return nil
        }
        if currentAreaM2 >= areaThresholdM2 {
            return .area
        }
        if databaseMemoryMB >= databaseThresholdMB {
            return .database
        }
        if usedMemoryMB >= usedMemoryThresholdMB {
            return .memory
        }
        return nil
    }

    func addPriceTag(tagIdentifier: String, payload: String, timestamp: TimeInterval, nodeCount: Int, x: Float, y: Float, z: Float, roll: Float, pitch: Float, yaw: Float, note: String = "") -> PriceTagRecord {
        let record = PriceTagRecord(
            id: nextTagId,
            tagIdentifier: tagIdentifier,
            payload: payload,
            timestamp: timestamp,
            segmentIndex: segmentIndex,
            nodeCount: nodeCount,
            x: x,
            y: y,
            z: z,
            roll: roll,
            pitch: pitch,
            yaw: yaw,
            note: note)
        nextTagId += 1
        priceTags.append(record)
        return record
    }

    func writeSidecarFiles(to segmentDirectory: URL, metadata: ScanSegmentMetadata) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let metadataData = try encoder.encode(metadata)
        try metadataData.write(to: segmentDirectory.appendingPathComponent("metadata.json"), options: .atomic)

        let tagsData = try encoder.encode(priceTags)
        try tagsData.write(to: segmentDirectory.appendingPathComponent("price_tags.json"), options: .atomic)

        try priceTagsCSV().write(
            to: segmentDirectory.appendingPathComponent("price_tags.csv"),
            atomically: true,
            encoding: .utf8)

        let areaCells = ScanAreaCells(
            segmentIndex: metadata.segmentIndex,
            cellSizeM: areaEstimator.cellSizeM,
            scanRadiusM: areaEstimator.scanRadiusM,
            cells: areaEstimator.occupiedCellCoordinates())
        let areaCellsData = try encoder.encode(areaCells)
        try areaCellsData.write(to: segmentDirectory.appendingPathComponent("scan_area_cells.json"), options: .atomic)

        let poseSamplesData = try encoder.encode(poseSamples)
        try poseSamplesData.write(to: segmentDirectory.appendingPathComponent("trajectory_samples.json"), options: .atomic)

        try trajectorySamplesCSV().write(
            to: segmentDirectory.appendingPathComponent("trajectory_samples.csv"),
            atomically: true,
            encoding: .utf8)
    }

    private func priceTagsCSV() -> String {
        var rows = ["id,tagIdentifier,payload,timestamp,segmentIndex,nodeCount,x,y,z,roll,pitch,yaw,note"]
        for tag in priceTags {
            rows.append([
                String(tag.id),
                csv(tag.tagIdentifier),
                csv(tag.payload),
                String(format: "%.6f", tag.timestamp),
                String(tag.segmentIndex),
                String(tag.nodeCount),
                String(format: "%.4f", tag.x),
                String(format: "%.4f", tag.y),
                String(format: "%.4f", tag.z),
                String(format: "%.5f", tag.roll),
                String(format: "%.5f", tag.pitch),
                String(format: "%.5f", tag.yaw),
                csv(tag.note)
            ].joined(separator: ","))
        }
        return rows.joined(separator: "\n") + "\n"
    }

    private func trajectorySamplesCSV() -> String {
        var rows = ["timestamp,segmentIndex,nodeCount,x,y,z,roll,pitch,yaw"]
        for sample in poseSamples {
            rows.append([
                String(format: "%.6f", sample.timestamp),
                String(sample.segmentIndex),
                String(sample.nodeCount),
                String(format: "%.4f", sample.x),
                String(format: "%.4f", sample.y),
                String(format: "%.4f", sample.z),
                String(format: "%.5f", sample.roll),
                String(format: "%.5f", sample.pitch),
                String(format: "%.5f", sample.yaw)
            ].joined(separator: ","))
        }
        return rows.joined(separator: "\n") + "\n"
    }

    private func csv(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }

    private func cellKey(_ x: Int, _ y: Int) -> String {
        return "\(x):\(y)"
    }

    private func parseCellKey(_ key: String) -> (x: Int, y: Int)? {
        let parts = key.split(separator: ":")
        guard parts.count == 2,
              let x = Int(parts[0]),
              let y = Int(parts[1]) else {
            return nil
        }
        return (x, y)
    }

    private func dilatedCells(_ cells: Set<String>, radius: Int) -> Set<String> {
        guard radius > 0 else {
            return cells
        }
        var result = cells
        for key in cells {
            guard let cell = parseCellKey(key) else {
                continue
            }
            for dx in (-radius)...radius {
                for dy in (-radius)...radius {
                    result.insert(cellKey(cell.x + dx, cell.y + dy))
                }
            }
        }
        return result
    }

    private func erodedCells(_ cells: Set<String>, radius: Int) -> Set<String> {
        guard radius > 0 else {
            return cells
        }
        var result = Set<String>()
        for key in cells {
            guard let cell = parseCellKey(key) else {
                continue
            }
            var keep = true
            for dx in (-radius)...radius {
                for dy in (-radius)...radius where !cells.contains(cellKey(cell.x + dx, cell.y + dy)) {
                    keep = false
                    break
                }
                if !keep {
                    break
                }
            }
            if keep {
                result.insert(key)
            }
        }
        return result
    }

    private func removeSmallComponents(_ cells: Set<String>, minCells: Int) -> (cells: Set<String>, removed: Int) {
        guard minCells > 1, !cells.isEmpty else {
            return (cells, 0)
        }

        var visited = Set<String>()
        var components = [[String]]()
        let neighbors = [
            (-1, -1), (0, -1), (1, -1),
            (-1, 0),           (1, 0),
            (-1, 1),  (0, 1),  (1, 1)
        ]

        for key in cells where !visited.contains(key) {
            guard let start = parseCellKey(key) else {
                continue
            }
            var stack = [(start.x, start.y)]
            var component = [String]()
            visited.insert(key)

            while let current = stack.popLast() {
                let currentKey = cellKey(current.0, current.1)
                component.append(currentKey)
                for offset in neighbors {
                    let nextKey = cellKey(current.0 + offset.0, current.1 + offset.1)
                    if cells.contains(nextKey), !visited.contains(nextKey) {
                        visited.insert(nextKey)
                        stack.append((current.0 + offset.0, current.1 + offset.1))
                    }
                }
            }
            components.append(component)
        }

        let keptComponents = components.filter { $0.count >= minCells }
        if keptComponents.isEmpty, let largest = components.max(by: { $0.count < $1.count }) {
            return (Set(largest), max(0, cells.count - largest.count))
        }

        let result = Set(keptComponents.flatMap { $0 })
        return (result, max(0, cells.count - result.count))
    }

    private func smoothedCoverageCells(_ rawCells: Set<String>, cellSize: Double) -> (cells: Set<String>, removedIslands: Int, addedByClosing: Int) {
        let closed = erodedCells(dilatedCells(rawCells, radius: 1), radius: 1)
        let minIslandAreaM2 = 0.5
        let minIslandCells = max(3, Int(ceil(minIslandAreaM2 / max(cellSize * cellSize, 0.0001))))
        let filtered = removeSmallComponents(closed, minCells: minIslandCells)
        return (
            cells: filtered.cells,
            removedIslands: filtered.removed,
            addedByClosing: max(0, closed.count - rawCells.count)
        )
    }

    private func boundaryCells(_ cells: Set<String>) -> Set<String> {
        var result = Set<String>()
        let neighbors = [(0, -1), (-1, 0), (1, 0), (0, 1)]
        for key in cells {
            guard let cell = parseCellKey(key) else {
                continue
            }
            for offset in neighbors where !cells.contains(cellKey(cell.x + offset.0, cell.y + offset.1)) {
                result.insert(key)
                break
            }
        }
        return result
    }

    func generate2DMapPackage() throws -> URL {
        guard let rootDirectory = rootDirectory else {
            throw NSError(
                domain: "SupermarketScanSession",
                code: 10,
                userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("No supermarket scan session is available.", comment: "2D map generation error")])
        }

        let outputRoot: URL
        if let customBaseDirectory = customBaseDirectory {
            outputRoot = customBaseDirectory.appendingPathComponent(rootDirectory.lastPathComponent, isDirectory: true)
        }
        else {
            outputRoot = rootDirectory
        }
        try fileManager.createDirectory(at: outputRoot, withIntermediateDirectories: true)

        let segmentDirectories = savedSegmentDirectories()
        guard !segmentDirectories.isEmpty else {
            throw NSError(
                domain: "SupermarketScanSession",
                code: 11,
                userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("No saved segments are available for 2D map generation.", comment: "2D map generation error")])
        }

        var areaCellsBySegment = [Int: ScanAreaCells]()
        var tags = [PriceTagRecord]()
        var metadataList = [ScanSegmentMetadata]()
        var trajectorySamples = [ScanPoseSample]()
        let decoder = JSONDecoder()
        for segmentDirectory in segmentDirectories {
            if let data = try? Data(contentsOf: segmentDirectory.appendingPathComponent("scan_area_cells.json")),
               let cells = try? decoder.decode(ScanAreaCells.self, from: data) {
                areaCellsBySegment[cells.segmentIndex] = cells
            }
            if let data = try? Data(contentsOf: segmentDirectory.appendingPathComponent("trajectory_samples.json")),
               let samples = try? decoder.decode([ScanPoseSample].self, from: data) {
                trajectorySamples.append(contentsOf: samples)
            }
            if let data = try? Data(contentsOf: segmentDirectory.appendingPathComponent("price_tags.json")),
               let segmentTags = try? decoder.decode([PriceTagRecord].self, from: data) {
                tags.append(contentsOf: segmentTags)
            }
            if let data = try? Data(contentsOf: segmentDirectory.appendingPathComponent("metadata.json")),
               let metadata = try? decoder.decode(ScanSegmentMetadata.self, from: data) {
                metadataList.append(metadata)
            }
        }

        guard !areaCellsBySegment.isEmpty else {
            throw NSError(
                domain: "SupermarketScanSession",
                code: 12,
                userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Saved segments do not contain 2D scan coverage sidecar files. Save a new segment before generating a mobile 2D map.", comment: "2D map generation error")])
        }

        let mapDirectory = outputRoot.appendingPathComponent("Map2D-\(Date().getFormattedDate(format: "yyyyMMdd-HHmmss"))", isDirectory: true)
        try fileManager.createDirectory(at: mapDirectory, withIntermediateDirectories: true)

        let cellSize = areaCellsBySegment.values.map { $0.cellSizeM }.min() ?? 0.25
        var allCells = areaCellsBySegment.values.flatMap { cells in
            cells.cells.map { (segment: cells.segmentIndex, x: $0[0], y: $0[1]) }
        }
        allCells.append(contentsOf: trajectorySamples.map {
            (segment: $0.segmentIndex, x: Int(floor(Double($0.x) / cellSize)), y: Int(floor(Double($0.z) / cellSize)))
        })
        allCells.append(contentsOf: tags.map {
            (segment: $0.segmentIndex, x: Int(floor(Double($0.x) / cellSize)), y: Int(floor(Double($0.z) / cellSize)))
        })
        let minCellX = allCells.map { $0.x }.min() ?? 0
        let maxCellX = allCells.map { $0.x }.max() ?? 0
        let minCellY = allCells.map { $0.y }.min() ?? 0
        let maxCellY = allCells.map { $0.y }.max() ?? 0
        let marginCells = 8
        let originCellX = minCellX - marginCells
        let originCellY = minCellY - marginCells
        let width = max(1, maxCellX - originCellX + marginCells + 1)
        let height = max(1, maxCellY - originCellY + marginCells + 1)
        var rawFreeCells = Set<String>()
        for cells in areaCellsBySegment.values {
            for cell in cells.cells {
                rawFreeCells.insert(cellKey(cell[0], cell[1]))
            }
        }
        let smoothing = smoothedCoverageCells(rawFreeCells, cellSize: cellSize)
        let freeCells = smoothing.cells
        let observedBoundaryCells = boundaryCells(freeCells)

        func imagePoint(x: Float, z: Float) -> CGPoint {
            let cellX = Int(floor(Double(x) / cellSize))
            let cellY = Int(floor(Double(z) / cellSize))
            return CGPoint(
                x: CGFloat(cellX - originCellX) + 0.5,
                y: CGFloat(height - 1 - (cellY - originCellY)) + 0.5)
        }

        func segmentColor(_ segment: Int) -> UIColor {
            let hue = CGFloat((segment * 47) % 360) / 360.0
            return UIColor(hue: hue, saturation: 0.72, brightness: 0.88, alpha: 1.0)
        }

        func cellRect(_ key: String) -> CGRect? {
            guard let cell = parseCellKey(key) else {
                return nil
            }
            return CGRect(
                x: CGFloat(cell.x - originCellX),
                y: CGFloat(height - 1 - (cell.y - originCellY)),
                width: 1,
                height: 1)
        }

        func drawObservedBoundary(_ cg: CGContext, lineWidth: CGFloat) {
            cg.saveGState()
            cg.setStrokeColor(UIColor(white: 0.18, alpha: 0.95).cgColor)
            cg.setLineCap(.square)
            cg.setLineWidth(lineWidth)
            for key in observedBoundaryCells {
                guard let cell = parseCellKey(key) else {
                    continue
                }
                let px = CGFloat(cell.x - originCellX)
                let py = CGFloat(height - 1 - (cell.y - originCellY))
                if !freeCells.contains(cellKey(cell.x - 1, cell.y)) {
                    cg.move(to: CGPoint(x: px, y: py))
                    cg.addLine(to: CGPoint(x: px, y: py + 1))
                }
                if !freeCells.contains(cellKey(cell.x + 1, cell.y)) {
                    cg.move(to: CGPoint(x: px + 1, y: py))
                    cg.addLine(to: CGPoint(x: px + 1, y: py + 1))
                }
                if !freeCells.contains(cellKey(cell.x, cell.y + 1)) {
                    cg.move(to: CGPoint(x: px, y: py))
                    cg.addLine(to: CGPoint(x: px + 1, y: py))
                }
                if !freeCells.contains(cellKey(cell.x, cell.y - 1)) {
                    cg.move(to: CGPoint(x: px, y: py + 1))
                    cg.addLine(to: CGPoint(x: px + 1, y: py + 1))
                }
            }
            cg.strokePath()
            cg.restoreGState()
        }

        func drawDirectionArrow(_ cg: CGContext, from: CGPoint, to: CGPoint, color: UIColor, size: CGFloat) {
            let dx = to.x - from.x
            let dy = to.y - from.y
            let length = max(0.001, sqrt(dx * dx + dy * dy))
            let ux = dx / length
            let uy = dy / length
            let px = -uy
            let py = ux
            let tip = to
            let left = CGPoint(x: tip.x - ux * size + px * size * 0.45, y: tip.y - uy * size + py * size * 0.45)
            let right = CGPoint(x: tip.x - ux * size - px * size * 0.45, y: tip.y - uy * size - py * size * 0.45)
            cg.saveGState()
            cg.setFillColor(color.withAlphaComponent(0.9).cgColor)
            cg.beginPath()
            cg.move(to: tip)
            cg.addLine(to: left)
            cg.addLine(to: right)
            cg.closePath()
            cg.fillPath()
            cg.restoreGState()
        }

        let imageSize = CGSize(width: width, height: height)
        let renderer = UIGraphicsImageRenderer(size: imageSize)
        let occupancyImage = renderer.image { context in
            UIColor(white: 0.74, alpha: 1.0).setFill()
            context.fill(CGRect(origin: .zero, size: imageSize))
            UIColor.white.setFill()
            for key in freeCells {
                if let rect = cellRect(key) {
                    context.fill(rect)
                }
            }
        }
        try occupancyImage.pngData()?.write(to: mapDirectory.appendingPathComponent("occupancy_grid.png"), options: .atomic)

        let maxOverviewPixels = 4096
        let maxGridDimension = max(width, height)
        let pixelsPerCell = CGFloat(max(1, min(8, maxOverviewPixels / max(1, maxGridDimension))))
        let overviewSize = CGSize(width: CGFloat(width) * pixelsPerCell, height: CGFloat(height) * pixelsPerCell)
        let overviewRenderer = UIGraphicsImageRenderer(size: overviewSize)
        let overviewImage = overviewRenderer.image { context in
            let cg = context.cgContext
            cg.setAllowsAntialiasing(true)
            cg.setShouldAntialias(true)
            UIColor(red: 0.88, green: 0.90, blue: 0.91, alpha: 1.0).setFill()
            context.fill(CGRect(origin: .zero, size: overviewSize))
            cg.saveGState()
            cg.scaleBy(x: pixelsPerCell, y: pixelsPerCell)

            let gridStepCells = max(1, Int(round(1.0 / max(cellSize, 0.01))))
            cg.setStrokeColor(UIColor(white: 0.62, alpha: 0.22).cgColor)
            cg.setLineWidth(max(0.08, 1.0 / pixelsPerCell))
            if gridStepCells > 0 {
                var gx = CGFloat(gridStepCells)
                while gx < CGFloat(width) {
                    cg.move(to: CGPoint(x: gx, y: 0))
                    cg.addLine(to: CGPoint(x: gx, y: CGFloat(height)))
                    gx += CGFloat(gridStepCells)
                }
                var gy = CGFloat(gridStepCells)
                while gy < CGFloat(height) {
                    cg.move(to: CGPoint(x: 0, y: gy))
                    cg.addLine(to: CGPoint(x: CGFloat(width), y: gy))
                    gy += CGFloat(gridStepCells)
                }
                cg.strokePath()
            }

            UIColor(red: 0.98, green: 0.975, blue: 0.94, alpha: 1.0).setFill()
            for key in freeCells {
                if let rect = cellRect(key) {
                    context.fill(rect)
                }
            }
            drawObservedBoundary(cg, lineWidth: max(0.35, 2.0 / pixelsPerCell))

            let samplesBySegment = Dictionary(grouping: trajectorySamples.sorted {
                if $0.segmentIndex == $1.segmentIndex {
                    return $0.timestamp < $1.timestamp
                }
                return $0.segmentIndex < $1.segmentIndex
            }, by: { $0.segmentIndex })
            for (segment, samples) in samplesBySegment.sorted(by: { $0.key < $1.key }) where samples.count > 1 {
                let color = segmentColor(segment)
                color.setStroke()
                cg.setLineCap(.round)
                cg.setLineJoin(.round)
                cg.setLineWidth(max(0.45, 3.0 / pixelsPerCell))
                cg.beginPath()
                let first = imagePoint(x: samples[0].x, z: samples[0].z)
                cg.move(to: first)
                for sample in samples.dropFirst() {
                    cg.addLine(to: imagePoint(x: sample.x, z: sample.z))
                }
                cg.strokePath()

                let arrowStride = max(8, samples.count / 8)
                if samples.count > arrowStride {
                    for index in stride(from: arrowStride, to: samples.count, by: arrowStride) {
                        let from = imagePoint(x: samples[index - 1].x, z: samples[index - 1].z)
                        let to = imagePoint(x: samples[index].x, z: samples[index].z)
                        drawDirectionArrow(cg, from: from, to: to, color: color, size: max(1.2, 7.0 / pixelsPerCell))
                    }
                }
            }

            UIColor.systemGreen.setFill()
            for tag in tags {
                let point = imagePoint(x: tag.x, z: tag.z)
                let radius = max(1.4, 5.0 / pixelsPerCell)
                context.cgContext.fillEllipse(in: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
            }

            let scaleBarMeters = 5.0
            let scaleBarCells = CGFloat(scaleBarMeters / max(cellSize, 0.01))
            let scaleBarOrigin = CGPoint(x: 6, y: CGFloat(height) - 6)
            cg.setStrokeColor(UIColor(white: 0.12, alpha: 0.9).cgColor)
            cg.setLineWidth(max(0.5, 3.0 / pixelsPerCell))
            cg.move(to: scaleBarOrigin)
            cg.addLine(to: CGPoint(x: min(CGFloat(width) - 6, scaleBarOrigin.x + scaleBarCells), y: scaleBarOrigin.y))
            cg.strokePath()
            cg.restoreGState()
        }
        try overviewImage.pngData()?.write(to: mapDirectory.appendingPathComponent("overview_map.png"), options: .atomic)
        try overviewImage.pngData()?.write(to: mapDirectory.appendingPathComponent("preview.png"), options: .atomic)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let trajectoryData = try encoder.encode(trajectorySamples)
        try trajectoryData.write(to: mapDirectory.appendingPathComponent("trajectory_samples.json"), options: .atomic)

        let originX = Double(originCellX) * cellSize
        let originY = Double(originCellY) * cellSize
        let gridAreaM2 = Double(width * height) * cellSize * cellSize
        let scannedAreaM2 = Double(freeCells.count) * cellSize * cellSize
        let unknownAreaM2 = max(0, gridAreaM2 - scannedAreaM2)

        try writeText(
            [
                "image: occupancy_grid.png",
                String(format: "resolution: %.6f", cellSize),
                String(format: "origin: [%.6f, %.6f, 0.0]", originX, originY),
                "negate: 0",
                "occupied_thresh: 0.65",
                "free_thresh: 0.20",
                ""
            ].joined(separator: "\n"),
            to: mapDirectory.appendingPathComponent("occupancy_grid.yaml"))

        try writeJSON([
            "format": "SupermarketMobileMap2D",
            "version": 1,
            "generatedAt": Date().getFormattedDate(format: "yyyy-MM-dd HH:mm:ss"),
            "sourceSession": rootDirectory.lastPathComponent,
            "coordinateFrame": [
                "name": "map_2d",
                "horizontalAxes": "x/z",
                "origin": [originX, originY],
                "resolutionM": cellSize
            ],
            "outputs": [
                "occupancy_grid.png",
                "occupancy_grid.yaml",
                "overview_map.png",
                "preview.png",
                "trajectory_samples.json",
                "semantic_layers.json",
                "price_tags.geojson",
                "quality_report.json"
            ]
        ], to: mapDirectory.appendingPathComponent("map.json"))

        try writeJSON([
            "layers": [
                ["id": "walkable_confirmed", "kind": "scan_coverage", "areaM2": scannedAreaM2],
                ["id": "observed_boundary", "kind": "estimated_coverage_boundary", "cellCount": observedBoundaryCells.count],
                ["id": "unknown", "kind": "unobserved", "areaM2": unknownAreaM2]
            ]
        ], to: mapDirectory.appendingPathComponent("semantic_layers.json"))

        try writeJSON(priceTagsGeoJSON(tags: tags), to: mapDirectory.appendingPathComponent("price_tags.geojson"))

        try writeJSON([
            "generatedAt": Date().getFormattedDate(format: "yyyy-MM-dd HH:mm:ss"),
            "session": rootDirectory.lastPathComponent,
            "segmentCount": segmentDirectories.count,
            "segments": metadataList.map {
                [
                    "segmentIndex": $0.segmentIndex,
                    "nodeCount": $0.nodeCount,
                    "knownAreaM2": $0.knownAreaM2,
                    "databaseMemoryMB": $0.databaseMemoryMB,
                    "usedMemoryMB": $0.usedMemoryMB,
                    "priceTagCount": $0.priceTagCount
                ]
            },
            "grid": [
                "width": width,
                "height": height,
                "resolutionM": cellSize,
                "scannedAreaM2": scannedAreaM2,
                "unknownAreaM2": unknownAreaM2,
                "rawFreeCellCount": rawFreeCells.count,
                "freeCellCount": freeCells.count,
                "boundaryCellCount": observedBoundaryCells.count,
                "edgeSmoothing": [
                    "method": "close_radius_1_remove_small_islands",
                    "addedByClosing": smoothing.addedByClosing,
                    "removedIslandCells": smoothing.removedIslands
                ]
            ],
            "trajectory": [
                "sampleCount": trajectorySamples.count,
                "segmentsWithSamples": Set(trajectorySamples.map { $0.segmentIndex }).count
            ],
            "priceTags": [
                "total": tags.count,
                "needsReview": tags.count
            ],
            "warnings": [
                "Mobile 2D overview uses smoothed scan coverage, estimated observed boundary, trajectory sidecars and price tags. It is a top-down evidence map, not a measured shelf/wall occupied layer.",
                "Structural occupied layers for shelves/walls require point-cloud or local-grid extraction; use offline Supermarket2DMap for that richer map."
            ]
        ], to: mapDirectory.appendingPathComponent("quality_report.json"))

        return mapDirectory
    }

    func latest2DMapPackage() -> URL? {
        guard let rootDirectory = rootDirectory else {
            return nil
        }

        var roots = [rootDirectory]
        if let customBaseDirectory = customBaseDirectory {
            roots.append(customBaseDirectory.appendingPathComponent(rootDirectory.lastPathComponent, isDirectory: true))
        }

        var latest: URL?
        var latestDate = Date.distantPast
        for root in roots {
            guard let children = try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey], options: [.skipsHiddenFiles]) else {
                continue
            }
            for child in children where child.lastPathComponent.hasPrefix("Map2D-") {
                guard let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey]),
                      values.isDirectory == true,
                      fileManager.fileExists(atPath: child.appendingPathComponent("preview.png").path) else {
                    continue
                }
                let date = values.contentModificationDate ?? Date.distantPast
                if date > latestDate {
                    latestDate = date
                    latest = child
                }
            }
        }
        return latest
    }

    private func savedSegmentDirectories() -> [URL] {
        guard let rootDirectory = rootDirectory else {
            return []
        }

        var roots = [rootDirectory]
        if let customBaseDirectory = customBaseDirectory {
            roots.append(customBaseDirectory.appendingPathComponent(rootDirectory.lastPathComponent, isDirectory: true))
        }

        var directoriesByIndex = [Int: URL]()
        for root in roots {
            guard let children = try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
                continue
            }
            for child in children where child.lastPathComponent.hasPrefix("segment_") {
                guard let values = try? child.resourceValues(forKeys: [.isDirectoryKey]),
                      values.isDirectory == true,
                      let index = Int(child.lastPathComponent.replacingOccurrences(of: "segment_", with: "")) else {
                    continue
                }
                directoriesByIndex[index] = child
            }
        }

        return directoriesByIndex.keys.sorted().compactMap { directoriesByIndex[$0] }
    }

    private func priceTagsGeoJSON(tags: [PriceTagRecord]) -> [String: Any] {
        return [
            "type": "FeatureCollection",
            "features": tags.map { tag in
                [
                    "type": "Feature",
                    "properties": [
                        "tag_id": tag.tagIdentifier,
                        "payload": tag.payload,
                        "segment": tag.segmentIndex,
                        "node_count": tag.nodeCount,
                        "confidence": 0.35,
                        "needs_review": true,
                        "timestamp": tag.timestamp
                    ],
                    "geometry": [
                        "type": "Point",
                        "coordinates": [tag.x, tag.z]
                    ]
                ]
            }
        ]
    }

    private func writeText(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func writeJSON(_ object: Any, to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }
}
