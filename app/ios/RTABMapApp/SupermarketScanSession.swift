//
//  SupermarketScanSession.swift
//  RTABMapApp
//
//  First-pass supermarket scanning support: segment rollover, floor-area
//  estimation from the walking trajectory, and price-tag position records.
//

import Foundation

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

enum SegmentTriggerReason: String {
    case area
    case database
    case memory
    case manual
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

    func startNewSessionIfNeeded() throws {
        if rootDirectory == nil {
            let stamp = Date().getFormattedDate(format: "yyyyMMdd-HHmmss")
            let root = documentsDirectory.appendingPathComponent("SupermarketSession-\(stamp)", isDirectory: true)
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
}
