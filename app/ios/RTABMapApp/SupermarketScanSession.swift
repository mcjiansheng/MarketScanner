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

    func updateArea(x: Float, z: Float) -> Double {
        currentAreaM2 = areaEstimator.update(x: x, z: z)
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

    private func csv(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
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
        let decoder = JSONDecoder()
        for segmentDirectory in segmentDirectories {
            if let data = try? Data(contentsOf: segmentDirectory.appendingPathComponent("scan_area_cells.json")),
               let cells = try? decoder.decode(ScanAreaCells.self, from: data) {
                areaCellsBySegment[cells.segmentIndex] = cells
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
        let allCells = areaCellsBySegment.values.flatMap { cells in
            cells.cells.map { (segment: cells.segmentIndex, x: $0[0], y: $0[1]) }
        }
        let minCellX = allCells.map { $0.x }.min() ?? 0
        let maxCellX = allCells.map { $0.x }.max() ?? 0
        let minCellY = allCells.map { $0.y }.min() ?? 0
        let maxCellY = allCells.map { $0.y }.max() ?? 0
        let marginCells = 8
        let originCellX = minCellX - marginCells
        let originCellY = minCellY - marginCells
        let width = max(1, maxCellX - minCellX + marginCells * 2 + 1)
        let height = max(1, maxCellY - minCellY + marginCells * 2 + 1)
        var freeCells = Set<String>()
        for cell in allCells {
            freeCells.insert("\(cell.x):\(cell.y)")
        }

        let imageSize = CGSize(width: width, height: height)
        let renderer = UIGraphicsImageRenderer(size: imageSize)
        let occupancyImage = renderer.image { context in
            UIColor(white: 0.74, alpha: 1.0).setFill()
            context.fill(CGRect(origin: .zero, size: imageSize))
            UIColor.white.setFill()
            for key in freeCells {
                let parts = key.split(separator: ":")
                guard parts.count == 2,
                      let x = Int(parts[0]),
                      let y = Int(parts[1]) else {
                    continue
                }
                let px = x - originCellX
                let py = height - 1 - (y - originCellY)
                context.fill(CGRect(x: px, y: py, width: 1, height: 1))
            }
        }
        try occupancyImage.pngData()?.write(to: mapDirectory.appendingPathComponent("occupancy_grid.png"), options: .atomic)

        let previewImage = renderer.image { context in
            occupancyImage.draw(in: CGRect(origin: .zero, size: imageSize))
            UIColor.systemGreen.setFill()
            for tag in tags {
                let cellX = Int(floor(Double(tag.x) / cellSize))
                let cellY = Int(floor(Double(tag.z) / cellSize))
                let px = cellX - originCellX
                let py = height - 1 - (cellY - originCellY)
                context.cgContext.fillEllipse(in: CGRect(x: px - 2, y: py - 2, width: 5, height: 5))
            }
        }
        try previewImage.pngData()?.write(to: mapDirectory.appendingPathComponent("preview.png"), options: .atomic)

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
                "preview.png",
                "semantic_layers.json",
                "price_tags.geojson",
                "quality_report.json"
            ]
        ], to: mapDirectory.appendingPathComponent("map.json"))

        try writeJSON([
            "layers": [
                ["id": "walkable_confirmed", "kind": "scan_coverage", "areaM2": scannedAreaM2],
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
                "freeCellCount": freeCells.count
            ],
            "priceTags": [
                "total": tags.count,
                "needsReview": tags.count
            ],
            "warnings": [
                "Mobile 2D map uses scan coverage sidecars and price tags only. Run the offline Supermarket2DMap tool for structural occupied layers from point clouds."
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
