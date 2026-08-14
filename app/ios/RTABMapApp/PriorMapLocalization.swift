//
//  PriorMapLocalization.swift
//  RTABMapApp
//
//  Prior-map package loading, setup, ARKit prediction, bounded depth matching,
//  conservative road priors and an auditable 2D HUD.
//

import ARKit
import AVFoundation
import Foundation
import simd
import UIKit
import UniformTypeIdentifiers

struct PriorMapBounds: Codable {
    let minXM: Double
    let minYM: Double
    let maxXM: Double
    let maxYM: Double

    enum CodingKeys: String, CodingKey {
        case minXM = "min_x_m"
        case minYM = "min_y_m"
        case maxXM = "max_x_m"
        case maxYM = "max_y_m"
    }
}

struct PriorMapFloor: Codable {
    let id: String
    let bounds: PriorMapBounds
    let previewFile: String?

    enum CodingKeys: String, CodingKey {
        case id
        case bounds
        case previewFile = "preview_file"
    }
}

struct PriorMapManifest: Codable {
    let format: String
    let version: Int
    let priorMapId: String
    let name: String
    let storeID: String
    let sourceSha256: String
    let canonicalSourceSha256: String?
    let floors: [PriorMapFloor]
    let elementCount: Int
    let warningCount: Int

    enum CodingKeys: String, CodingKey {
        case format
        case version
        case priorMapId = "prior_map_id"
        case name
        case storeID = "store_id"
        case sourceSha256 = "source_sha256"
        case canonicalSourceSha256 = "canonical_source_sha256"
        case floors
        case elementCount = "element_count"
        case warningCount = "warning_count"
    }
}

struct PriorMapRoadNode: Codable {
    let id: String
    let floorId: String
    let positionM: [Double]

    enum CodingKeys: String, CodingKey {
        case id
        case floorId = "floor_id"
        case positionM = "position_m"
    }
}

struct PriorMapRoadEdge: Codable {
    let id: String
    let floorId: String
    let from: String
    let to: String

    enum CodingKeys: String, CodingKey {
        case id
        case floorId = "floor_id"
        case from
        case to
    }
}

struct PriorMapRoadGraph: Codable {
    let nodes: [PriorMapRoadNode]
    let edges: [PriorMapRoadEdge]
}

private struct PriorMapShelvesPayload: Codable {
    let format: String
    let version: Int
    let shelves: [PriorMapShelf]
    let shelfSegments: [PriorMapShelfSegmentV2]?

    enum CodingKeys: String, CodingKey {
        case format
        case version
        case shelves
        case shelfSegments = "shelf_segments"
    }
}

private struct PriorMapStructuresPayload: Codable {
    let format: String
    let version: Int
    let structures: [PriorMapFixedStructure]
}

struct PriorMapSpatialFloor: Codable {
    let cells: [String: [String]]
    let roadCells: [String: [String]]

    enum CodingKeys: String, CodingKey {
        case cells
        case roadCells = "road_cells"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cells = try container.decodeIfPresent([String: [String]].self, forKey: .cells) ?? [:]
        roadCells = try container.decodeIfPresent(
            [String: [String]].self,
            forKey: .roadCells) ?? [:]
    }
}

struct PriorMapSpatialIndexPayload: Codable {
    let format: String
    let version: Int
    let cellSizeM: Double
    let floors: [String: PriorMapSpatialFloor]

    enum CodingKeys: String, CodingKey {
        case format
        case version
        case cellSizeM = "cell_size_m"
        case floors
    }
}

struct PriorMapPackage {
    let directory: URL
    let manifest: PriorMapManifest
    let roadGraph: PriorMapRoadGraph
    let spatialIndex: PriorMapSpatialIndexPayload
    let distanceFields: PriorMapDistanceFieldFile
    let shelves: [PriorMapShelf]
    let shelfSegments: [PriorMapShelfSegmentV2]
    let fixedStructures: [PriorMapFixedStructure]
    let preview: UIImage
    let previewsByFloor: [String: UIImage]
    let packageSha256: String

    func preview(floorId: String) -> UIImage {
        return previewsByFloor[floorId] ?? preview
    }

    static func load(directory: URL) throws -> PriorMapPackage {
        // P7R6C: the package is read exactly once into an immutable
        // snapshot; integrity validation, format checks, model decoding
        // and previews all consume those same bytes, so the package SHA
        // can never describe content the loader never parsed.
        let snapshot = try PriorMapPackageSnapshotReader.read(
            directory: directory)
        return try load(snapshot: snapshot)
    }

    /// Decodes a package from an already captured immutable snapshot.
    /// Scan setup and scan start pass this typed object forward so the
    /// UI never performs a second or third full package read on the main
    /// thread.
    static func load(snapshot: PriorMapPackageSnapshot) throws -> PriorMapPackage {
        let packageSha256 = try PriorMapPackageIntegrity.validate(
            snapshot: snapshot)
        let decoder = JSONDecoder()
        let requiredJSONFormats = [
            "manifest.json": "MarketScannerPriorMap",
            "elements.json": "MarketScannerPriorMapElements",
            "shelves.json": "MarketScannerPriorMapShelves",
            "fixed_structures.json": "MarketScannerPriorMapStructures",
            "road_graph.json": "MarketScannerRoadGraph",
            "spatial_index.json": "MarketScannerSpatialIndex",
            "distance_fields.json": "MarketScannerDistanceFields",
            "validation_report.json": "MarketScannerPriorMapValidation",
        ]
        for (name, expectedFormat) in requiredJSONFormats {
            guard let payload = snapshot.artifactsByName[name]?.parsedJSON,
                  payload["format"] as? String == expectedFormat,
                  let version = StrictJSONScalar.integer(payload["version"]),
                  name == "shelves.json" ? (version == 1 || version == 2)
                    : (name == "manifest.json"
                        ? (version == 1 || version == 2)
                        : version == 1) else {
                throw NSError(
                    domain: "PriorMap",
                    code: 5,
                    userInfo: [NSLocalizedDescriptionKey: "\(name) 无法通过地图包格式校验。"])
            }
        }
        func artifactBytes(_ name: String) throws -> Data {
            guard let bytes = snapshot.artifactsByName[name]?.bytes else {
                throw NSError(
                    domain: "PriorMap",
                    code: 5,
                    userInfo: [NSLocalizedDescriptionKey: "\(name) 缺失于地图包快照。"])
            }
            return bytes
        }
        let manifest = try decoder.decode(
            PriorMapManifest.self,
            from: try artifactBytes("manifest.json"))
        guard manifest.format == "MarketScannerPriorMap",
              manifest.version == 1 || manifest.version == 2 else {
            throw NSError(
                domain: "PriorMap",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "地图包版本不受支持。请先在 PC 工作台重新导入 Excel。"])
        }
        guard !manifest.priorMapId.isEmpty,
              manifest.priorMapId.count <= 128,
              MapSourceBusinessIdentityPolicy.isValidStoreID(
                  manifest.storeID),
              manifest.sourceSha256.count == 64,
              manifest.sourceSha256.allSatisfy({ $0.isHexDigit }) else {
            throw NSError(
                domain: "PriorMap",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "地图包身份或来源摘要无效。源数据安全，请在 PC 工作台重新生成。"])
        }
        guard !manifest.floors.isEmpty else {
            throw NSError(
                domain: "PriorMap",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "地图包没有可用楼层。源数据安全，请返回 PC 查看验证报告。"])
        }
        let graph = try decoder.decode(
            PriorMapRoadGraph.self,
            from: try artifactBytes("road_graph.json"))
        let spatial = try decoder.decode(
            PriorMapSpatialIndexPayload.self,
            from: try artifactBytes("spatial_index.json"))
        let distanceFields = try decoder.decode(
            PriorMapDistanceFieldFile.self,
            from: try artifactBytes("distance_fields.json"))
        guard let shelvesObject = snapshot.artifactsByName["shelves.json"]?.parsedJSON else {
            throw NSError(
                domain: "PriorMap",
                code: 8,
                userInfo: [NSLocalizedDescriptionKey: "货架数据缺失，请重新生成地图包。"])
        }
        let parsedShelves: PriorMapShelvesSchema.ParsedDocument
        do {
            parsedShelves = try PriorMapShelvesSchema.parse(shelvesObject)
        } catch {
            throw NSError(
                domain: "PriorMap",
                code: 8,
                userInfo: [NSLocalizedDescriptionKey: "货架 schema 无效：\(error)"])
        }
        let shelvesPayload = try decoder.decode(
            PriorMapShelvesPayload.self,
            from: try artifactBytes("shelves.json"))
        let structuresPayload = try decoder.decode(
            PriorMapStructuresPayload.self,
            from: try artifactBytes("fixed_structures.json"))
        guard spatial.format == "MarketScannerSpatialIndex",
              spatial.version == 1,
              spatial.cellSizeM > 0 else {
            throw NSError(
                domain: "PriorMap",
                code: 6,
                userInfo: [NSLocalizedDescriptionKey: "地图空间索引无效，请在 PC 工作台重新生成。"])
        }
        guard distanceFields.format == "MarketScannerDistanceFields",
              distanceFields.version == 1,
              distanceFields.truncationDistanceM > 0,
              distanceFields.truncationDistanceM <= 2.55,
              Set(distanceFields.floors.keys) == Set(manifest.floors.map(\.id)),
              shelvesPayload.format == "MarketScannerPriorMapShelves",
              shelvesPayload.version == parsedShelves.version,
              (parsedShelves.version == 1
                ? (shelvesPayload.shelfSegments ?? []).isEmpty
                : shelvesPayload.shelfSegments == parsedShelves.segments),
              structuresPayload.format == "MarketScannerPriorMapStructures",
              structuresPayload.version == 1 else {
            throw NSError(
                domain: "PriorMap",
                code: 8,
                userInfo: [NSLocalizedDescriptionKey: "地图包的结构距离场或货架数据无效，请在 PC 工作台重新生成。"])
        }
        // Decode every level now so corrupted RLE or a checksum mismatch is
        // rejected before a scan can begin.
        var totalDistanceCells = 0
        for floor in distanceFields.floors.values {
            for level in floor.levels {
                let cellCount = try level.validatedCellCount()
                guard cellCount <= PriorMapDistanceFieldLevel.maximumTotalCells
                        - totalDistanceCells else {
                    throw NSError(
                        domain: "PriorMap",
                        code: 8,
                        userInfo: [NSLocalizedDescriptionKey:
                            "地图包距离场超过总资源预算，请在 PC 工作台重新生成。"])
                }
                totalDistanceCells += cellCount
                _ = try level.decodedValues()
            }
        }
        guard let previewBytes = snapshot.artifactsByName["preview.png"]?.bytes,
              let preview = UIImage(data: previewBytes) else {
            throw NSError(
                domain: "PriorMap",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "地图预览无法读取。源 Excel 不受影响，请重新生成地图包。"])
        }
        var previewsByFloor: [String: UIImage] = [:]
        for floor in manifest.floors {
            guard let filename = floor.previewFile,
                  URL(fileURLWithPath: filename).lastPathComponent == filename,
                  let floorPreviewBytes =
                      snapshot.artifactsByName[filename]?.bytes,
                  let floorPreview = UIImage(data: floorPreviewBytes) else {
                throw NSError(
                    domain: "PriorMap",
                    code: 7,
                    userInfo: [NSLocalizedDescriptionKey: "楼层 \(floor.id) 的预览无法读取，请重新生成地图包。"])
            }
            previewsByFloor[floor.id] = floorPreview
        }
        return PriorMapPackage(
            directory: snapshot.directory,
            manifest: manifest,
            roadGraph: graph,
            spatialIndex: spatial,
            distanceFields: distanceFields,
            shelves: shelvesPayload.shelves,
            shelfSegments: parsedShelves.segments,
            fixedStructures: structuresPayload.structures,
            preview: preview,
            previewsByFloor: previewsByFloor,
            packageSha256: packageSha256)
    }
}

struct PriorMapRoadCandidate: Codable {
    let edgeId: String
    let distanceM: Double
}

struct PriorMapLocalizationUpdate: Codable {
    let format: String
    let version: Int
    let timestamp: TimeInterval
    let trackingState: String
    let localizationState: String
    let confidence: Double
    let rawPose: PriorMapPose2D
    let estimatedPose: PriorMapPose2D
    let roadCandidates: [PriorMapRoadCandidate]
    let structureSource: String
    let structurePointCount: Int
    let structureCoverageAngleRad: Double
    let matchCandidates: [PriorMapScanMatchCandidate]
    let matchUniqueness: Double
    let matchResidualCost: Double?
    let matcherElapsedMs: Double
    let constraintAccepted: Bool
    let constraintReason: String
    var measurementAccepted: Bool = false
    var hypothesisTrusted: Bool = false
    var correctionStepApplied: Bool = false
    var recoveryConvergedThisUpdate: Bool = false
    var confidenceAccepted: Bool = false
    var constraintDisposition: PriorMapConstraintDisposition = .rejected
    var postRecoveryTrustedLocalFrames: Int = 0
    var scanSearchPerformed: Bool = false
    var hypothesisSupportFrames: Int = 0
    var hypothesisScoreMargin: Double = 0
    var recoverySearch: Bool = false
    var correctionTranslationM: Double = 0
    var correctionYawDeg: Double = 0
    var mapFromArkitX: Double? = nil
    var mapFromArkitY: Double? = nil
    var mapFromArkitYawDeg: Double? = nil
    var selectedHypothesisId: Int? = nil
    var activeHypothesisTrackCount: Int = 0
    var hypothesisBestCost: Double? = nil
    var hypothesisSecondCost: Double? = nil
    var hypothesisReason: String = "no_hypothesis"
    var hypothesisTrackerElapsedMs: Double = 0
    var recoveryEpisodeId: Int? = nil
    var recoveryReason: String? = nil
    var recoveryOutcome: String? = nil
    var recoveryValidAttemptCount: Int? = nil
    var recoveryRemainingValidAttempts: Int? = nil
    var recoveryElapsedMs: Double? = nil
    var recoveryFreshSupportFrames: Int? = nil
    var recoveryTriggerCount: Int? = nil
    var recoveryFinishedAtUptime: TimeInterval? = nil
    var recoverySelectedHypothesisId: Int? = nil
    var recoveryFinalResidualTranslationM: Double? = nil
    var recoveryFinalResidualYawDeg: Double? = nil
    var recoveryCorrectionStepAppliedOnCompletionFrame: Bool? = nil
    var recoveryCooldownRemainingMs: Double = 0
    var recoveryAutomaticTriggerSuppressed: Bool = false
    var recoveryAutomaticTriggerReason: String? = nil
    var trackingSessionId: String? = nil
    var priorMapId: String? = nil
    var priorMapSha256: String? = nil
    var floorId: String? = nil
    var nodeTimebaseTimestamp: TimeInterval? = nil
    var nodeTimebaseOffsetSeconds: TimeInterval? = nil
}

private struct PriorMapRoadSegment {
    let id: String
    let start: SIMD2<Double>
    let end: SIMD2<Double>
}

private struct PriorMapProjectedCandidate {
    let segment: PriorMapRoadSegment
    let distanceM: Double
    let point: SIMD2<Double>
}

struct PriorMapShelfIdentityCandidate {
    let shelfSegmentId: String
    let shelfCode: String
    let distanceM: Double
    let nearestXM: Double
    let nearestYM: Double
    let longitudinalFraction: Double
}

/// Immutable two-phase manual-alignment proposal. Preparing a proposal never
/// changes the live alignment. The caller must first durably append the manual
/// localization event, then commit this exact proposal on the same serialized
/// localizer queue. This prevents an evidence write failure from leaving an
/// unaudited in-memory map correction behind.
struct PriorMapManualPositionCandidate {
    let arkitPose: PriorMapPose2D
    let confirmedMapPose: PriorMapPose2D
    let expectedAlignmentVersion: Int
    let committedAlignmentVersion: Int
}

final class PriorMapStageOneLocalizer {
    private let floorId: String
    private let alignmentAnchor: PriorMapLocalizationAnchor
    private let segmentsById: [String: PriorMapRoadSegment]
    private let roadCells: [String: [String]]
    private let cellSizeM: Double
    private let softGain = 0.15
    private let maximumCorrectionM = 0.25
    private let ambiguityMarginM = 0.35
    private let candidateRadiusM = 3.0
    private let depthSampler = PriorMapDepthSampler()
    private let matcher: PriorMapScanMatcher
    private let monotonicClock: PriorMapMonotonicClock
    private let confidenceManager = PriorMapConfidenceManager()
    private let hypothesisTracker = PriorMapHypothesisTracker()
    private let recoveryController = PriorMapRecoveryController()
    private let priorMapId: String
    private let priorMapSha256: String
    private let shelves: [PriorMapShelf]
    private let shelfSegments: [PriorMapShelfSegmentV2]
    private let fixedStructures: [PriorMapFixedStructure]
    private var latestFloorEstimate: PriorMapFloorEstimate?
    private(set) var latestEstimatedPose: PriorMapPose2D
    private(set) var latestConfidence = 0.0
    private(set) var latestPhase: PriorMapLocalizationPhase = .uninitialized
    private var alignmentVersion = 0
    private var consecutiveUntrustedFrames = 0
    private var pendingRecoveryCompletion: PriorMapRecoveryCompletion?
    private var terminalRecoveryCompletionsAwaitingEvidence:
        [PriorMapRecoveryCompletion] = []

    init(
        package: PriorMapPackage,
        floorId: String,
        initialMapPose: PriorMapPose2D,
        monotonicClock: PriorMapMonotonicClock = PriorMapSystemMonotonicClock()
    ) throws {
        self.floorId = floorId
        self.alignmentAnchor = PriorMapLocalizationAnchor(
            initialMapPose: initialMapPose)
        self.monotonicClock = monotonicClock
        self.latestEstimatedPose = initialMapPose
        self.priorMapId = package.manifest.priorMapId
        self.priorMapSha256 = package.packageSha256
        self.shelves = package.shelves
        self.shelfSegments = package.shelfSegments.filter {
            $0.floorID == floorId
        }
        self.fixedStructures = package.fixedStructures
        guard let distanceFloor = package.distanceFields.floors[floorId] else {
            throw NSError(
                domain: "PriorMapLocalizer",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "所选楼层没有结构距离场。"])
        }
        self.matcher = try PriorMapScanMatcher(
            floor: distanceFloor,
            truncationM: package.distanceFields.truncationDistanceM)
        var positions: [String: SIMD2<Double>] = [:]
        for node in package.roadGraph.nodes
            where node.floorId == floorId && node.positionM.count >= 2 {
            positions[node.id] = SIMD2<Double>(node.positionM[0], node.positionM[1])
        }
        let segments: [PriorMapRoadSegment] = package.roadGraph.edges.compactMap { edge in
            guard edge.floorId == floorId,
                  let start = positions[edge.from],
                  let end = positions[edge.to] else {
                return nil
            }
            return PriorMapRoadSegment(id: edge.id, start: start, end: end)
        }
        self.segmentsById = Dictionary(
            uniqueKeysWithValues: segments.map { ($0.id, $0) })
        self.roadCells = package.spatialIndex.floors[floorId]?.roadCells ?? [:]
        self.cellSizeM = package.spatialIndex.cellSizeM
        confidenceManager.reset()
    }

    private func nearbySegments(_ point: SIMD2<Double>) -> [PriorMapRoadSegment] {
        guard !roadCells.isEmpty else {
            return segmentsById.keys.sorted().compactMap { segmentsById[$0] }
        }
        let minimumX = Int(floor((point.x - candidateRadiusM) / cellSizeM))
        let maximumX = Int(floor((point.x + candidateRadiusM) / cellSizeM))
        let minimumY = Int(floor((point.y - candidateRadiusM) / cellSizeM))
        let maximumY = Int(floor((point.y + candidateRadiusM) / cellSizeM))
        var identifiers = Set<String>()
        for cellX in minimumX...maximumX {
            for cellY in minimumY...maximumY {
                identifiers.formUnion(roadCells["\(cellX),\(cellY)"] ?? [])
            }
        }
        return identifiers.sorted().compactMap { segmentsById[$0] }
    }

    /// Called after a reliable RTAB-Map loop closure. The loop does not inject
    /// a pose prior by itself; it authorizes a bounded wider search whose result
    /// must still survive four-frame hypothesis tracking before any correction.
    private func beginRecovery(
        reason: String,
        now: TimeInterval,
        automatic: Bool = false
    ) {
        if recoveryController.request(
            reason: reason,
            now: now,
            automatic: automatic),
           let episode = recoveryController.activeEpisode {
            hypothesisTracker.beginRecoveryEpisode(id: episode.id)
        }
    }

    @discardableResult
    private func finishRecovery(
        outcome: PriorMapRecoveryOutcome,
        now: TimeInterval,
        selectedHypothesisId: Int? = nil,
        finalFreshSupportFrames: Int = 0,
        finalResidualTranslationM: Double? = nil,
        finalResidualYawRad: Double? = nil,
        correctionStepAppliedOnCompletionFrame: Bool = false,
        cancellationReason: PriorMapRecoveryCancellationReason? = nil
    ) -> PriorMapRecoveryCompletion? {
        guard let episode = recoveryController.activeEpisode else { return nil }
        hypothesisTracker.endRecoveryEpisode(id: episode.id, outcome: outcome)
        let completion = recoveryController.finish(
            outcome,
            now: now,
            selectedHypothesisId: selectedHypothesisId,
            finalFreshSupportFrames: finalFreshSupportFrames,
            finalResidualTranslationM: finalResidualTranslationM,
            finalResidualYawRad: finalResidualYawRad,
            correctionStepAppliedOnCompletionFrame:
                correctionStepAppliedOnCompletionFrame,
            cancellationReason: cancellationReason)
        pendingRecoveryCompletion = completion
        if let completion {
            terminalRecoveryCompletionsAwaitingEvidence.append(completion)
        }
        return completion
    }

    func requestRecovery(reason: String) {
        beginRecovery(
            reason: reason,
            now: monotonicClock.now)
    }

    /// Diagnostic-only top-K shelf identities near the current map pose.
    ///
    /// This does not alter the alignment and is deliberately separate from
    /// strict localization sidecars. It proves which concrete shelf segments
    /// are geometrically plausible after a reliable RTAB-Map loop so the
    /// phone can retain ambiguity instead of pretending that a whole-map
    /// distance-field basin already identifies one shelf.
    func nearbyShelfIdentityCandidates(
        limit: Int = 5,
        radiusM: Double = 6.0
    ) -> [PriorMapShelfIdentityCandidate] {
        let pose = latestEstimatedPose
        return shelfSegments.compactMap { segment in
            guard segment.longitudinalStartM.count == 2,
                  segment.longitudinalEndM.count == 2 else {
                return nil
            }
            let start = SIMD2<Double>(
                segment.longitudinalStartM[0],
                segment.longitudinalStartM[1])
            let end = SIMD2<Double>(
                segment.longitudinalEndM[0],
                segment.longitudinalEndM[1])
            let point = SIMD2<Double>(pose.xM, pose.yM)
            let delta = end - start
            let lengthSquared = simd_length_squared(delta)
            guard lengthSquared > 1.0e-12 else { return nil }
            let fraction = min(
                1.0,
                max(0.0, simd_dot(point - start, delta) / lengthSquared))
            let nearest = start + delta * fraction
            let distance = simd_distance(point, nearest)
            guard distance <= radiusM else { return nil }
            return PriorMapShelfIdentityCandidate(
                shelfSegmentId: segment.shelfSegmentID,
                shelfCode: segment.shelfCode,
                distanceM: distance,
                nearestXM: nearest.x,
                nearestYM: nearest.y,
                longitudinalFraction: fraction)
        }
        .sorted { first, second in
            if first.distanceM != second.distanceM {
                return first.distanceM < second.distanceM
            }
            return first.shelfSegmentId < second.shelfSegmentId
        }
        .prefix(max(1, min(5, limit)))
        .map { $0 }
    }

    /// Cancels the active Recovery episode and returns the terminal completion
    /// (F-02). Callers must persist the lifecycle evidence before unbinding
    /// the localizer; a teardown must never be fire-and-forget.
    @discardableResult
    func cancelRecovery(
        reason: PriorMapRecoveryCancellationReason,
        now: TimeInterval
    ) -> PriorMapRecoveryCompletion? {
        return finishRecovery(
            outcome: .cancelled,
            now: now,
            cancellationReason: reason)
    }

    /// P7R6 peek: returns every terminal completion not yet persisted as
    /// lifecycle evidence without removing it. Ordering preserves episode
    /// finish order; acknowledgements remove entries one by one so a failed
    /// write keeps the retryable state visible.
    func pendingTerminalRecoveryCompletions()
        -> [PriorMapRecoveryCompletion] {
        return terminalRecoveryCompletionsAwaitingEvidence
    }

    /// P7R6 ack: removes one completion after its durable append has been
    /// confirmed. Unknown episode IDs are ignored so a repeated ack after a
    /// crash-restart cannot corrupt the queue.
    func acknowledgeTerminalRecoveryCompletion(episodeId: Int) {
        guard let index = terminalRecoveryCompletionsAwaitingEvidence
            .firstIndex(where: { $0.episode.id == episodeId }) else {
            return
        }
        terminalRecoveryCompletionsAwaitingEvidence.remove(at: index)
    }

    /// P7R6: drops queued completions when the session identity is
    /// invalidated (generation change). Old completions must never enter a
    /// new session; the write side's identity guard remains the final check.
    func discardTerminalRecoveryCompletionsForInvalidatedSession() {
        terminalRecoveryCompletionsAwaitingEvidence.removeAll()
    }

    func update(
        frame: ARFrame,
        trackingState: String,
        poseOverride: simd_float4x4? = nil
    ) -> PriorMapLocalizationUpdate {
        // All location-bearing consumers of one accepted ARFrame must use the
        // same software-stabilized pose. Falling back to ARKit is retained for
        // isolated tests and non-production callers only.
        let transform = poseOverride ?? frame.camera.transform
        let timestamp = frame.timestamp
        let arkitPose = Self.pose(from: transform)
        let rawPose = alignmentAnchor.project(arkitPose: arkitPose)
        let projected = SIMD2<Double>(rawPose.xM, rawPose.yM)
        var candidates: [PriorMapProjectedCandidate] = []
        for segment in nearbySegments(projected) {
            let deltaX = segment.end.x - segment.start.x
            let deltaY = segment.end.y - segment.start.y
            let denominator = max(
                1.0e-12,
                deltaX * deltaX + deltaY * deltaY)
            let offsetX = projected.x - segment.start.x
            let offsetY = projected.y - segment.start.y
            let unboundedRatio =
                (offsetX * deltaX + offsetY * deltaY) / denominator
            let ratio = min(1.0, max(0.0, unboundedRatio))
            let point = SIMD2<Double>(
                segment.start.x + deltaX * ratio,
                segment.start.y + deltaY * ratio)
            let differenceX = projected.x - point.x
            let differenceY = projected.y - point.y
            let distance = sqrt(
                differenceX * differenceX + differenceY * differenceY)
            if distance <= candidateRadiusM {
                candidates.append(
                    PriorMapProjectedCandidate(
                        segment: segment,
                        distanceM: distance,
                        point: point))
            }
        }
        candidates.sort { first, second in
            first.distanceM == second.distanceM
                ? first.segment.id < second.segment.id
                : first.distanceM < second.distanceM
        }
        let topCandidates = Array(candidates.prefix(3))
        let unique = topCandidates.count == 1
            || (topCandidates.count > 1
                && topCandidates[1].distanceM - topCandidates[0].distanceM
                    >= ambiguityMarginM)
        var estimatedPose = rawPose
        var decision = PriorMapRecoveryDecision(
            measurementAccepted: false,
            hypothesisTrusted: false,
            correctionStepApplied: false,
            recoveryConvergedThisUpdate: false,
            confidenceAccepted: false,
            constraintDisposition: .rejected)
        var reason = trackingState == "normal"
            ? "structure_depth_unavailable"
            : "tracking_not_normal"
        let depthSample = trackingState == "normal"
            ? depthSampler.sampleResult(
                frame: frame,
                cameraTransform: transform)
            : nil
        let observation = depthSample?.structureObservation
        var recoveryFrameDisposition: PriorMapRecoveryFrameDisposition =
            trackingState == "normal"
                ? (depthSample?.recoveryFrameDisposition
                    ?? .observationUnavailable)
                : .trackingLimited
        let preMatchNow = monotonicClock.now
        let recoveryWasActiveAtUpdateStart = recoveryController.activeEpisode != nil
        var recoveryCompletionForUpdate = pendingRecoveryCompletion
        pendingRecoveryCompletion = nil
        let recoveryExpiredBeforeMatch = recoveryController
            .isWallClockExpired(now: preMatchNow)
        var automaticTriggerSuppressed = false
        var automaticTriggerReason: String?
        if recoveryController.activeEpisode == nil,
           recoveryCompletionForUpdate == nil,
           consecutiveUntrustedFrames == 6
            || (consecutiveUntrustedFrames > 6
                && consecutiveUntrustedFrames % 20 == 0) {
            if recoveryController.isAutomaticTriggerSuppressed(now: preMatchNow) {
                automaticTriggerSuppressed = true
                automaticTriggerReason = "automatic_recovery_cooldown"
            }
            else {
                beginRecovery(
                    reason: "persistent_weak_or_lost",
                    now: preMatchNow,
                    automatic: true)
            }
        }
        let recoverySearch = recoveryController.activeEpisode != nil
        let activeRecoveryReason = recoveryController.activeEpisode?.reason ?? "none"
        let match = recoveryCompletionForUpdate == nil
            && !recoveryExpiredBeforeMatch ? observation.map {
            matcher.match(
                predictedPose: rawPose,
                observation: $0,
                recoverySearch: recoverySearch)
        } : nil
        if let match {
            recoveryFrameDisposition = match.searchPerformed
                ? .searched : .insufficientPoints
        }
        let postMatchNow = monotonicClock.now
        let recoveryWallClockExpiredAfterMatch = recoverySearch
            && recoveryController.isWallClockExpired(now: postMatchNow)
        if let floorEstimate = observation?.floorEstimate {
            latestFloorEstimate = floorEstimate
        }
        let hypothesis = recoveryCompletionForUpdate == nil
            && !recoveryExpiredBeforeMatch
            && !recoveryWallClockExpiredAfterMatch
            ? hypothesisTracker.observe(
                arkitPose: arkitPose,
                candidates: match?.candidates ?? [],
                uniqueness: match?.uniqueness ?? 0,
                recoverySearch: recoverySearch)
            : nil
        var correctionTranslationM = 0.0
        var correctionYawDeg = 0.0
        var correctionYawRad = 0.0
        var correctionTarget: PriorMapPose2D?
        var geometryCandidate = false
        var geometryAndSafetyAccepted = false
        if let best = hypothesis?.candidate,
           let mapFromArkit = hypothesis?.mapFromArkit {
            // Reconstruct the target from the smoothed global alignment. The
            // latest scan-match candidate supplies geometry quality only; it
            // must not bypass temporal smoothing or turn invariance.
            let targetPose = PriorMapAlignmentMath.apply(
                mapFromArkit: mapFromArkit,
                arkitPose: arkitPose)
            correctionTarget = targetPose
            let correction = PriorMapCorrectionSafety.difference(
                from: rawPose,
                to: targetPose)
            correctionTranslationM = correction.translationM
            correctionYawRad = correction.yawRad
            correctionYawDeg = correction.yawRad * 180.0 / .pi
            geometryCandidate = best.cost <= 0.10
                && (match?.effectivePointCount ?? 0) >= 45
                && (observation?.coverageAngleRad ?? 0) >= 0.35
            geometryAndSafetyAccepted = geometryCandidate
                && PriorMapCorrectionSafety.isWithinGate(
                    current: rawPose,
                    target: targetPose,
                    recoverySearch: recoverySearch)
        }
        let residualCost = match?.candidates.first?.cost ?? 0.15
        let recoveryReduction = PriorMapRecoveryUpdateReducer.reduce(
            PriorMapRecoveryUpdateInput(
                timestamp: timestamp,
                preMatchNow: preMatchNow,
                postMatchNow: postMatchNow,
                recoveryWasActiveAtUpdateStart:
                    recoveryWasActiveAtUpdateStart,
                recoveryActiveForMatch: recoverySearch,
                pendingCompletionOutcome:
                    recoveryCompletionForUpdate?.outcome,
                frameDisposition: recoveryFrameDisposition,
                hypothesisTrusted: hypothesis?.trusted ?? false,
                geometryAndSafetyAccepted: geometryAndSafetyAccepted,
                residualTranslationM: correctionTranslationM,
                residualYawRad: correctionYawRad,
                trackingState: trackingState,
                validPointCount: observation?.validPointCount ?? 0,
                coverageAngleRad: observation?.coverageAngleRad ?? 0,
                uniqueness: match?.uniqueness ?? 0,
                residualCost: residualCost,
                mapMismatch: match?.rejectionReason == "map_mismatch"),
            recoveryController: recoveryController,
            confidenceManager: confidenceManager)
        decision = recoveryReduction.decision
        if decision.correctionStepApplied, let targetPose = correctionTarget {
            estimatedPose = PriorMapCorrectionSafety.boundedStep(
                current: rawPose,
                target: targetPose)
            // Move only the map/ARKit alignment anchor. ARKit world tracking
            // and the scan database are never reset.
            alignmentAnchor.retainAppliedCorrection(
                arkitPose: arkitPose,
                estimatedMapPose: estimatedPose)
            alignmentVersion += 1
            if recoverySearch {
                recoveryController.recordAcceptedCorrection()
            }
        }
        switch recoveryReduction.action {
        case .converged:
            reason = "recovery_converged:\(activeRecoveryReason)"
            recoveryCompletionForUpdate = finishRecovery(
                outcome: .converged,
                now: postMatchNow,
                selectedHypothesisId: hypothesis?.selectedHypothesisId,
                finalFreshSupportFrames: hypothesis?.supportFrames ?? 0,
                finalResidualTranslationM: correctionTranslationM,
                finalResidualYawRad: correctionYawRad,
                correctionStepAppliedOnCompletionFrame:
                    decision.correctionStepApplied)
            pendingRecoveryCompletion = nil
        case .timedOut:
            reason = recoveryReduction.reason
            recoveryCompletionForUpdate = finishRecovery(
                outcome: .timedOut,
                now: postMatchNow,
                selectedHypothesisId: hypothesis?.selectedHypothesisId,
                finalFreshSupportFrames: hypothesis?.supportFrames ?? 0,
                finalResidualTranslationM: correctionTranslationM,
                finalResidualYawRad: correctionYawRad,
                correctionStepAppliedOnCompletionFrame:
                    decision.correctionStepApplied)
            pendingRecoveryCompletion = nil
        case .none:
            if decision.correctionStepApplied {
                reason = recoverySearch
                    ? "provisional_recovery_step:\(activeRecoveryReason)"
                    : "trusted_structure_correction"
            }
            else if correctionTarget != nil && !geometryCandidate {
                reason = match?.rejectionReason ?? "structure_rejected"
            }
            else if correctionTarget != nil && !geometryAndSafetyAccepted {
                reason = "correction_exceeds_safety_gate"
            }
            else if observation != nil {
                reason = match?.rejectionReason ?? "no_structure_candidate"
            }
            else if trackingState == "normal", unique,
                    let bestRoad = topCandidates.first {
                var correction = (bestRoad.point - projected) * softGain
                let length = simd_length(correction)
                if length > maximumCorrectionM {
                    correction *= maximumCorrectionM / length
                }
                estimatedPose.xM += correction.x
                estimatedPose.yM += correction.y
                reason = "road_prior_display_only"
            }
            else {
                reason = hypothesis?.reason ?? reason
            }
        }
        if decision.confidenceAccepted {
            consecutiveUntrustedFrames = 0
        }
        else {
            consecutiveUntrustedFrames += 1
        }
        let confidence = recoveryReduction.nextConfidence
        latestEstimatedPose = estimatedPose
        latestConfidence = confidence.confidence
        latestPhase = confidence.phase
        var update = PriorMapLocalizationUpdate(
            format: "MarketScannerLocalizationTrace",
            version: 1,
            timestamp: timestamp,
            trackingState: trackingState,
            localizationState: confidence.phase.rawValue,
            confidence: confidence.confidence,
            rawPose: rawPose,
            estimatedPose: estimatedPose,
            roadCandidates: topCandidates.map {
                PriorMapRoadCandidate(
                    edgeId: $0.segment.id,
                    distanceM: $0.distanceM)
            },
            structureSource: observation?.source ?? "unavailable",
            structurePointCount: observation?.validPointCount ?? 0,
            structureCoverageAngleRad: observation?.coverageAngleRad ?? 0,
            matchCandidates: match?.candidates ?? [],
            matchUniqueness: match?.uniqueness ?? 0,
            matchResidualCost: match?.candidates.first?.cost,
            matcherElapsedMs: match?.elapsedMs ?? 0,
            constraintAccepted: recoveryReduction.finalConstraintAccepted,
            constraintReason: reason)
        update.measurementAccepted = decision.measurementAccepted
        update.hypothesisTrusted = decision.hypothesisTrusted
        update.correctionStepApplied = decision.correctionStepApplied
        update.recoveryConvergedThisUpdate =
            decision.recoveryConvergedThisUpdate
        update.confidenceAccepted = decision.confidenceAccepted
        update.constraintDisposition = decision.constraintDisposition
        update.postRecoveryTrustedLocalFrames =
            confidenceManager.postRecoveryTrustedLocalFrames
        update.scanSearchPerformed = match?.searchPerformed ?? false
        update.hypothesisSupportFrames = hypothesis?.supportFrames ?? 0
        update.hypothesisScoreMargin = hypothesis?.scoreMargin ?? 0
        update.recoverySearch = recoverySearch
        update.correctionTranslationM = correctionTranslationM
        update.correctionYawDeg = correctionYawDeg
        update.mapFromArkitX = hypothesis?.mapFromArkit?.translationXM
        update.mapFromArkitY = hypothesis?.mapFromArkit?.translationYM
        update.mapFromArkitYawDeg = hypothesis?.mapFromArkit.map {
            $0.yawRad * 180.0 / .pi
        }
        let hypothesisTraceBinding = PriorMapHypothesisTraceBinder.bind(
            completion: recoveryCompletionForUpdate,
            currentSelectedHypothesisId: hypothesis?.selectedHypothesisId)
        if hypothesisTraceBinding.currentHypothesisVisible {
            update.selectedHypothesisId =
                hypothesisTraceBinding.currentSelectedHypothesisId
            update.activeHypothesisTrackCount = hypothesis?.activeTrackCount ?? 0
            update.hypothesisBestCost = hypothesis?.bestCost
            update.hypothesisSecondCost = hypothesis?.secondCost
            update.hypothesisReason = hypothesis?.reason ?? "no_hypothesis"
            update.hypothesisTrackerElapsedMs = hypothesis?.trackerElapsedMs ?? 0
        }
        let diagnosticEpisode = recoveryCompletionForUpdate?.episode
            ?? recoveryController.activeEpisode
        update.recoveryEpisodeId = diagnosticEpisode?.id
        update.recoveryReason = diagnosticEpisode?.reason
        update.recoveryOutcome = recoveryCompletionForUpdate?.outcome.rawValue
            ?? (recoveryController.activeEpisode == nil ? nil : "active")
        update.recoveryValidAttemptCount = diagnosticEpisode?.validMatcherAttempts
        update.recoveryRemainingValidAttempts = diagnosticEpisode?.remainingValidAttempts
        update.recoveryElapsedMs = diagnosticEpisode.map {
            PriorMapRecoveryDiagnostics.elapsedMs(
                episode: $0,
                completion: recoveryCompletionForUpdate,
                now: postMatchNow)
        }
        update.recoveryFreshSupportFrames = recoveryCompletionForUpdate?
            .finalFreshSupportFrames
            ?? (recoverySearch ? hypothesis?.supportFrames : nil)
        update.recoveryTriggerCount = diagnosticEpisode?.triggerCount
        update.recoveryFinishedAtUptime = recoveryCompletionForUpdate?
            .finishedAtUptime
        update.recoverySelectedHypothesisId = hypothesisTraceBinding
            .recoverySelectedHypothesisId
        update.recoveryFinalResidualTranslationM = recoveryCompletionForUpdate?
            .finalResidualTranslationM
        update.recoveryFinalResidualYawDeg = recoveryCompletionForUpdate?
            .finalResidualYawRad.map { $0 * 180.0 / .pi }
        update.recoveryCorrectionStepAppliedOnCompletionFrame =
            recoveryCompletionForUpdate?
                .correctionStepAppliedOnCompletionFrame
        update.recoveryCooldownRemainingMs = recoveryController
            .automaticCooldownRemaining(now: postMatchNow) * 1000
        update.recoveryAutomaticTriggerSuppressed = automaticTriggerSuppressed
        update.recoveryAutomaticTriggerReason = automaticTriggerReason
        return update
    }

    func alignmentSnapshot(frameTimestamp: TimeInterval) -> PriorMapAlignmentSnapshot? {
        guard let arkitOrigin = alignmentAnchor.arkitOrigin else { return nil }
        return PriorMapAlignmentSnapshot(
            arkitOrigin: arkitOrigin,
            initialMapPose: alignmentAnchor.initialMapPose,
            floorEstimate: latestFloorEstimate,
            localizationState: latestPhase.rawValue,
            localizationConfidence: latestConfidence,
            alignmentVersion: alignmentVersion,
            frameTimestamp: frameTimestamp)
    }

    func prepareManualPosition(
        transform: simd_float4x4,
        mapPose: PriorMapPose2D
    ) -> PriorMapManualPositionCandidate {
        let arkitPose = Self.pose(from: transform)
        return PriorMapManualPositionCandidate(
            arkitPose: arkitPose,
            confirmedMapPose: mapPose,
            expectedAlignmentVersion: alignmentVersion,
            committedAlignmentVersion: alignmentVersion + 1)
    }

    /// Applies a proposal only if no automatic localization update changed the
    /// alignment after it was prepared. Callers serialize this with normal
    /// updates on `priorMapQueue`; the compare-and-swap guard remains an
    /// explicit defense against future queueing changes.
    @discardableResult
    func commitManualPosition(
        _ candidate: PriorMapManualPositionCandidate
    ) -> Bool {
        guard alignmentVersion == candidate.expectedAlignmentVersion,
              candidate.committedAlignmentVersion
                == candidate.expectedAlignmentVersion + 1 else {
            return false
        }
        alignmentAnchor.retainAppliedCorrection(
            arkitPose: candidate.arkitPose,
            estimatedMapPose: candidate.confirmedMapPose)
        alignmentVersion = candidate.committedAlignmentVersion
        latestEstimatedPose = candidate.confirmedMapPose
        confidenceManager.reset(manual: true)
        latestPhase = .manualCorrection
        latestConfidence = 0.35
        depthSampler.reset()
        if recoveryController.activeEpisode != nil {
            _ = finishRecovery(
                outcome: .manualReset,
                now: monotonicClock.now)
        }
        else {
            hypothesisTracker.reset()
            recoveryController.resetAutomaticCooldownAfterManualCorrection()
        }
        consecutiveUntrustedFrames = 0
        return true
    }

    /// Compatibility helper for host tests and non-production callers. The
    /// production UI uses prepare -> durable append -> commit instead.
    func confirmCurrentPosition(
        transform: simd_float4x4,
        mapPose: PriorMapPose2D
    ) -> (PriorMapPose2D, PriorMapPose2D) {
        let candidate = prepareManualPosition(
            transform: transform,
            mapPose: mapPose)
        precondition(commitManualPosition(candidate))
        return (candidate.arkitPose, candidate.confirmedMapPose)
    }

    func localizePriceTag(
        _ detection: PriceTagVisionDetection,
        trackingSessionId: String,
        nodeTimebaseOffsetSeconds: TimeInterval
    ) -> PriceTagLocalizedFrameResult {
        let snapshot = detection.alignmentSnapshot
        let origin = snapshot.arkitOrigin
        let mapPoint: (SIMD3<Float>) -> PriorMapTagPoint3D = { world in
            let pointPose = PriorMapPose2D(
                xM: Double(world.x),
                yM: Double(-world.z),
                yawRad: origin.yawRad)
            let projected = PriorMapStageOneMath.project(
                arkitPose: pointPose,
                arkitOrigin: origin,
                initialMapPose: snapshot.initialMapPose)
            return PriorMapTagPoint3D(
                xM: projected.xM,
                yM: projected.yM,
                heightM: nil)
        }
        let measurement = PriceTagFrameMeasurement.measure(
            detection: detection,
            floorId: floorId,
            shelves: shelves,
            fixedStructures: fixedStructures,
            floorEstimate: snapshot.floorEstimate,
            poseTimestampDeltaMs: abs(
                detection.frame.timestamp - snapshot.frameTimestamp) * 1000,
            mapPoint: mapPoint)
        let alignmentAgeMs = abs(
            detection.frame.timestamp - snapshot.frameTimestamp) * 1000
        let alignmentVersionLag = max(0, alignmentVersion - snapshot.alignmentVersion)
        let freshness = PriorMapAlignmentFreshness.evaluate(
            ageMs: alignmentAgeMs,
            versionLag: alignmentVersionLag,
            localizationState: snapshot.localizationState,
            localizationConfidence: snapshot.localizationConfidence)
        let alignmentFreshness = freshness.label
        let effectiveLocalizationState = freshness.localizationState
        let effectiveLocalizationConfidence = freshness.localizationConfidence
        let localized = ShelfAssociation.localizedTagResult(
            observationId: detection.observationId,
            payload: detection.payload,
            symbology: detection.symbology,
            floorId: floorId,
            rawPosition: measurement.rawMapPosition,
            cameraPosition: measurement.cameraMapPosition,
            shelves: shelves,
            fixedStructures: fixedStructures,
            localizationState: effectiveLocalizationState,
            localizationConfidence: effectiveLocalizationConfidence,
            measurementConfidence: measurement.confidence,
            measurementMethod: measurement.method,
            userConfirmed: false,
            trackingSessionId: trackingSessionId,
            priorMapId: priorMapId,
            priorMapSha256: priorMapSha256,
            timestamp: Date().timeIntervalSince1970)
        let observationTimestamp = Date().timeIntervalSince1970
        let bounds = detection.normalizedBounds
        let normalizedBounds: [Double] = [
            Double(bounds.minX),
            Double(bounds.minY),
            Double(bounds.width),
            Double(bounds.height),
        ]
        let nodeTimebaseFrameTimestamp =
            detection.frame.timestamp + nodeTimebaseOffsetSeconds
        let depthEvidence = measurement.depthEvidence
        let observation = PriorMapTagObservationRecord(
            format: "MarketScannerPriceTagObservation",
            version: 1,
            observationId: detection.observationId,
            timestamp: observationTimestamp,
            payload: detection.payload,
            symbology: detection.symbology,
            normalizedBounds: normalizedBounds,
            frameTimestamp: detection.frame.timestamp,
            nodeTimebaseFrameTimestamp: nodeTimebaseFrameTimestamp,
            nodeTimebaseOffsetSeconds: nodeTimebaseOffsetSeconds,
            poseTimestampDeltaMs: measurement.poseTimestampDeltaMs,
            alignmentVersion: snapshot.alignmentVersion,
            alignmentSnapshotTimestamp: snapshot.frameTimestamp,
            alignmentAgeMs: alignmentAgeMs,
            alignmentVersionLag: alignmentVersionLag,
            alignmentFreshness: alignmentFreshness,
            rawMapPosition: measurement.rawMapPosition,
            measurementMethod: measurement.method,
            measurementConfidence: measurement.confidence,
            depthSampleCount: depthEvidence.sampleCount,
            depthInlierCount: depthEvidence.inlierCount,
            depthInlierRatio: depthEvidence.inlierRatio,
            depthMedianM: depthEvidence.medianM,
            depthMadM: depthEvidence.madM,
            planeResidualM: depthEvidence.planeResidualM,
            surfaceNormalCamera: depthEvidence.surfaceNormalCamera,
            localizationState: effectiveLocalizationState,
            localizationConfidence: effectiveLocalizationConfidence,
            priorMapId: priorMapId,
            priorMapSha256: priorMapSha256,
            floorId: floorId,
            trackingSessionId: trackingSessionId,
            needsReview: localized.tag.needsReview,
            burstId: nil,
            frameId: nil)
        return PriceTagLocalizedFrameResult(
            observation: observation,
            association: localized)
    }

    static func pose(from transform: simd_float4x4) -> PriorMapPose2D {
        let forward = SIMD3<Float>(
            -transform.columns.2.x,
            -transform.columns.2.y,
            -transform.columns.2.z)
        return PriorMapStageOneMath.arkitHorizontalPose(
            positionX: Double(transform.columns.3.x),
            positionZ: Double(transform.columns.3.z),
            forwardX: Double(forward.x),
            forwardZ: Double(forward.z))
    }

}

/// One UIKit projection for the canonical map heading contract.
///
/// Map yaw is standard SE(2): 0 points along map +x (east/right) and +pi/2
/// points along map +y (north/up). UIKit's y axis points down, therefore map
/// yaw is rendered with exactly one sign inversion and no quarter-turn bias.
enum PriorMapHeadingUI {
    static func screenTransform(yawRad: Double) -> CGAffineTransform {
        return CGAffineTransform(rotationAngle: CGFloat(-yawRad))
    }

    /// Returns a compact arrow whose unrotated tip points right (+x).
    static func rightPointingArrowPath(
        length: CGFloat,
        halfWidth: CGFloat,
        notch: CGFloat
    ) -> CGPath {
        let path = UIBezierPath()
        path.move(to: CGPoint(x: length, y: 0))
        path.addLine(to: CGPoint(x: -length * 0.75, y: halfWidth))
        path.addLine(to: CGPoint(x: -notch, y: 0))
        path.addLine(to: CGPoint(x: -length * 0.75, y: -halfWidth))
        path.close()
        return path.cgPath
    }
}

final class PriorMapPosePickerView: UIView,
    UIScrollViewDelegate,
    UIGestureRecognizerDelegate {
    private let zoomScrollView = UIScrollView()
    private let canvasView = UIView()
    private let imageView = UIImageView()
    private let arrow = CAShapeLayer()
    private(set) var pose: PriorMapPose2D
    private let boundsM: PriorMapBounds
    private var baseCanvasSize = CGSize.zero
    private lazy var markerPan = UIPanGestureRecognizer(
        target: self,
        action: #selector(markerPanned(_:)))
    var onPoseChanged: ((PriorMapPose2D) -> Void)?

    init(image: UIImage, bounds: PriorMapBounds, pose: PriorMapPose2D) {
        self.pose = pose
        self.boundsM = bounds
        super.init(frame: .zero)
        zoomScrollView.delegate = self
        zoomScrollView.minimumZoomScale = 1
        zoomScrollView.maximumZoomScale = 8
        zoomScrollView.bouncesZoom = true
        zoomScrollView.alwaysBounceHorizontal = false
        zoomScrollView.alwaysBounceVertical = false
        zoomScrollView.showsHorizontalScrollIndicator = true
        zoomScrollView.showsVerticalScrollIndicator = true
        zoomScrollView.decelerationRate = .fast
        addSubview(zoomScrollView)

        zoomScrollView.addSubview(canvasView)
        imageView.image = image
        imageView.contentMode = .scaleToFill
        imageView.isUserInteractionEnabled = true
        canvasView.addSubview(imageView)
        arrow.fillColor = UIColor.systemRed.cgColor
        arrow.strokeColor = UIColor.white.withAlphaComponent(0.9).cgColor
        arrow.lineWidth = 1.5
        arrow.shadowColor = UIColor.black.cgColor
        arrow.shadowOpacity = 0.45
        arrow.shadowRadius = 2
        canvasView.layer.addSublayer(arrow)

        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        canvasView.addGestureRecognizer(tap)
        let doubleTap = UITapGestureRecognizer(
            target: self,
            action: #selector(doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        canvasView.addGestureRecognizer(doubleTap)
        tap.require(toFail: doubleTap)

        markerPan.minimumNumberOfTouches = 1
        markerPan.maximumNumberOfTouches = 1
        markerPan.delegate = self
        canvasView.addGestureRecognizer(markerPan)
        // A drag that starts on the red marker belongs to the marker. A drag
        // elsewhere fails `markerPan` immediately and falls through to the
        // scroll view, making one-finger map panning deterministic at zoom.
        zoomScrollView.panGestureRecognizer.require(toFail: markerPan)
        let rotation = UIRotationGestureRecognizer(
            target: self,
            action: #selector(rotated(_:)))
        rotation.delegate = self
        canvasView.addGestureRecognizer(rotation)
        backgroundColor = .secondarySystemBackground
        layer.cornerRadius = 10
        clipsToBounds = true
        accessibilityLabel = "人工定位地图"
        accessibilityHint = "双指缩放；放大后单指平移；点击或拖动红色箭头设置位置"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        zoomScrollView.frame = bounds
        guard let image = imageView.image,
              image.size.width > 0,
              image.size.height > 0,
              bounds.width > 0,
              bounds.height > 0 else {
            return
        }
        let scale = min(
            bounds.width / image.size.width,
            bounds.height / image.size.height)
        let fittedSize = CGSize(
            width: max(1, image.size.width * scale),
            height: max(1, image.size.height * scale))
        if abs(fittedSize.width - baseCanvasSize.width) > 0.5
            || abs(fittedSize.height - baseCanvasSize.height) > 0.5 {
            baseCanvasSize = fittedSize
            zoomScrollView.setZoomScale(1, animated: false)
            canvasView.transform = .identity
            canvasView.bounds = CGRect(origin: .zero, size: fittedSize)
            canvasView.frame = CGRect(origin: .zero, size: fittedSize)
            imageView.frame = canvasView.bounds
            zoomScrollView.contentSize = fittedSize
        }
        centerCanvas()
        updateArrow()
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        return canvasView
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerCanvas()
    }

    private func centerCanvas() {
        let scaledWidth = canvasView.bounds.width * zoomScrollView.zoomScale
        let scaledHeight = canvasView.bounds.height * zoomScrollView.zoomScale
        zoomScrollView.contentInset = UIEdgeInsets(
            top: max(0, (zoomScrollView.bounds.height - scaledHeight) / 2),
            left: max(0, (zoomScrollView.bounds.width - scaledWidth) / 2),
            bottom: max(0, (zoomScrollView.bounds.height - scaledHeight) / 2),
            right: max(0, (zoomScrollView.bounds.width - scaledWidth) / 2))
    }

    func resetViewport(animated: Bool) {
        zoomScrollView.setZoomScale(1, animated: animated)
    }

    func focusOnPose(animated: Bool) {
        let visibleWidth = zoomScrollView.bounds.width
            / max(1, zoomScrollView.zoomScale)
        let visibleHeight = zoomScrollView.bounds.height
            / max(1, zoomScrollView.zoomScale)
        let rect = CGRect(
            x: arrow.position.x - visibleWidth / 2,
            y: arrow.position.y - visibleHeight / 2,
            width: visibleWidth,
            height: visibleHeight)
        zoomScrollView.scrollRectToVisible(rect, animated: animated)
    }

    func setYaw(_ yaw: Double) {
        pose.yawRad = PriorMapStageOneMath.normalizeAngle(yaw)
        updateArrow()
        onPoseChanged?(pose)
    }

    func setPose(_ value: PriorMapPose2D) {
        pose = PriorMapPose2D(
            xM: min(boundsM.maxXM, max(boundsM.minXM, value.xM)),
            yM: min(boundsM.maxYM, max(boundsM.minYM, value.yM)),
            yawRad: PriorMapStageOneMath.normalizeAngle(value.yawRad))
        updateArrow()
        onPoseChanged?(pose)
    }

    func nudge(dxM: Double, dyM: Double) {
        setPose(PriorMapPose2D(
            xM: pose.xM + dxM,
            yM: pose.yM + dyM,
            yawRad: pose.yawRad))
    }

    func rotate(byDegrees degrees: Double) {
        setYaw(pose.yawRad + degrees * .pi / 180.0)
    }

    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: canvasView)
        setPose(at: point)
    }

    @objc private func doubleTapped(_ gesture: UITapGestureRecognizer) {
        if zoomScrollView.zoomScale > 1.05 {
            resetViewport(animated: true)
            return
        }
        let targetScale = min(3, zoomScrollView.maximumZoomScale)
        let point = gesture.location(in: canvasView)
        let width = zoomScrollView.bounds.width / targetScale
        let height = zoomScrollView.bounds.height / targetScale
        zoomScrollView.zoom(
            to: CGRect(
                x: point.x - width / 2,
                y: point.y - height / 2,
                width: width,
                height: height),
            animated: true)
    }

    private func setPose(at point: CGPoint) {
        let imageRect = canvasView.bounds
        guard imageRect.width > 0,
              imageRect.height > 0,
              imageRect.contains(point) else {
            return
        }
        let xRatio = min(
            1.0,
            max(0.0, Double((point.x - imageRect.minX) / imageRect.width)))
        let yRatio = min(
            1.0,
            max(0.0, Double((point.y - imageRect.minY) / imageRect.height)))
        pose.xM = boundsM.minXM + xRatio * (boundsM.maxXM - boundsM.minXM)
        pose.yM = boundsM.maxYM - yRatio * (boundsM.maxYM - boundsM.minYM)
        updateArrow()
        onPoseChanged?(pose)
    }

    @objc private func markerPanned(_ gesture: UIPanGestureRecognizer) {
        let point = gesture.location(in: canvasView)
        if gesture.state == .began || gesture.state == .changed {
            setPose(at: point)
        }
    }

    @objc private func rotated(_ gesture: UIRotationGestureRecognizer) {
        pose.yawRad = PriorMapStageOneMath.normalizeAngle(
            pose.yawRad - Double(gesture.rotation))
        gesture.rotation = 0
        updateArrow()
        onPoseChanged?(pose)
    }

    override func gestureRecognizerShouldBegin(
        _ gestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        guard gestureRecognizer === markerPan else { return true }
        let point = gestureRecognizer.location(in: canvasView)
        let hitRadius = 44 / max(1, zoomScrollView.zoomScale)
        return hypot(
            point.x - arrow.position.x,
            point.y - arrow.position.y) <= hitRadius
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer:
            UIGestureRecognizer
    ) -> Bool {
        // UIScrollView owns translation and pinch. A two-finger rotation may
        // update heading without disabling the map's native zoom behavior.
        return gestureRecognizer is UIRotationGestureRecognizer
            || otherGestureRecognizer is UIRotationGestureRecognizer
    }

    private func updateArrow() {
        let width = max(0.001, boundsM.maxXM - boundsM.minXM)
        let height = max(0.001, boundsM.maxYM - boundsM.minYM)
        let imageRect = canvasView.bounds
        let x = imageRect.minX
            + CGFloat((pose.xM - boundsM.minXM) / width) * imageRect.width
        let y = imageRect.minY
            + CGFloat((boundsM.maxYM - pose.yM) / height) * imageRect.height
        arrow.path = PriorMapHeadingUI.rightPointingArrowPath(
            length: 10,
            halfWidth: 6,
            notch: 4)
        arrow.position = CGPoint(x: x, y: y)
        arrow.setAffineTransform(
            PriorMapHeadingUI.screenTransform(yawRad: pose.yawRad))
    }
}

enum PriorMapManualPoseSubmissionOutcome {
    case applied
    case rejected(message: String)
}

final class PriorMapPoseSelectionViewController: UIViewController {
    private let picker: PriorMapPosePickerView
    private let initialPose: PriorMapPose2D
    private let completion: (
        PriorMapPose2D,
        @escaping (PriorMapManualPoseSubmissionOutcome) -> Void
    ) -> Void
    private let coordinateLabel = UILabel()
    private let xField = UITextField()
    private let yField = UITextField()
    private let yawField = UITextField()
    private let stepControl = UISegmentedControl(
        items: ["0.1 m", "0.5 m", "1.0 m"])
    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()
    private let submissionStatusLabel = UILabel()
    private let cancelButton = UIButton(type: .system)
    private let confirmButton = UIButton(type: .system)
    private var submissionInFlight = false

    init(
        package: PriorMapPackage,
        floorId: String,
        pose: PriorMapPose2D,
        completion: @escaping (
            PriorMapPose2D,
            @escaping (PriorMapManualPoseSubmissionOutcome) -> Void
        ) -> Void
    ) {
        let floor = package.manifest.floors.first { $0.id == floorId }!
        picker = PriorMapPosePickerView(
            image: package.preview(floorId: floorId),
            bounds: floor.bounds,
            pose: pose)
        self.initialPose = pose
        self.completion = completion
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .formSheet
        preferredContentSize = CGSize(width: 620, height: 760)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let title = UILabel()
        title.font = .preferredFont(forTextStyle: .title2)
        title.text = "在地图上重新定位"
        let instructions = UILabel()
        instructions.numberOfLines = 0
        instructions.textColor = .secondaryLabel
        instructions.text = "双指缩放地图，放大后单指平移；点击地图或拖动红色箭头设置位置。可用下方按钮精确平移和旋转。坐标合同固定为 0°=+X/东/屏幕右、90°=+Y/北/屏幕上，逆时针为正；界面数值就是写入审计记录的 canonical SE(2)，不会再次转换。"
        coordinateLabel.font = UIFont.monospacedDigitSystemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .subheadline).pointSize,
            weight: .semibold)
        coordinateLabel.numberOfLines = 0
        coordinateLabel.adjustsFontForContentSizeCategory = true
        configureCoordinateField(xField, label: "X（m）")
        configureCoordinateField(yField, label: "Y（m）")
        configureCoordinateField(yawField, label: "朝向（°）")
        // Commit after editing ends. Updating on every keystroke would clamp
        // intermediate values (for example the first digit of "12.5") and
        // make precise manual correction feel uncontrollable.
        xField.addTarget(self, action: #selector(coordinateFieldChanged), for: .editingDidEnd)
        yField.addTarget(self, action: #selector(coordinateFieldChanged), for: .editingDidEnd)
        yawField.addTarget(self, action: #selector(coordinateFieldChanged), for: .editingDidEnd)
        let coordinateFields = UIStackView(arrangedSubviews: [
            labeledCoordinateField("X（m）", field: xField),
            labeledCoordinateField("Y（m）", field: yField),
            labeledCoordinateField("朝向（°）", field: yawField),
        ])
        coordinateFields.axis = .horizontal
        coordinateFields.spacing = 8
        coordinateFields.distribution = .fillEqually
        stepControl.selectedSegmentIndex = 1
        stepControl.accessibilityLabel = "人工定位平移步长"
        let positionPad = makePositionPad()
        let viewportControls = makeViewportControls()
        let rotationRow = makeRotationRow()
        let cardinalControl = UISegmentedControl(
            items: ["东 0°", "北 90°", "西 180°", "南 −90°"])
        cardinalControl.selectedSegmentIndex = UISegmentedControl.noSegment
        cardinalControl.accessibilityLabel = "人工定位朝向快捷选择"
        cardinalControl.addTarget(
            self, action: #selector(cardinalChanged(_:)), for: .valueChanged)
        picker.onPoseChanged = { [weak self] _ in
            self?.refreshCoordinateControls()
        }
        submissionStatusLabel.font = .preferredFont(forTextStyle: .footnote)
        submissionStatusLabel.textColor = .secondaryLabel
        submissionStatusLabel.numberOfLines = 0
        submissionStatusLabel.text = "确认后会等待与已接受帧严格时间匹配的 RTAB-Map 节点；只有审计记录成功落盘后，新的位置才会生效。"
        cancelButton.setTitle("取消", for: .normal)
        cancelButton.addTarget(self, action: #selector(cancelled), for: .touchUpInside)
        confirmButton.setTitle("确认位置", for: .normal)
        confirmButton.addTarget(self, action: #selector(confirmed), for: .touchUpInside)
        let buttons = UIStackView(arrangedSubviews: [cancelButton, UIView(), confirmButton])
        buttons.axis = .horizontal
        contentStack.axis = .vertical
        contentStack.spacing = 12
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        [
            title,
            instructions,
            picker,
            viewportControls,
            coordinateLabel,
            coordinateFields,
            stepControl,
            positionPad,
            cardinalControl,
            rotationRow,
            submissionStatusLabel,
            buttons,
        ].forEach(contentStack.addArrangedSubview)
        scrollView.alwaysBounceVertical = true
        scrollView.keyboardDismissMode = .interactive
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        scrollView.addSubview(contentStack)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            contentStack.topAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.topAnchor,
                constant: 16),
            contentStack.leadingAnchor.constraint(
                equalTo: scrollView.frameLayoutGuide.leadingAnchor,
                constant: 16),
            contentStack.trailingAnchor.constraint(
                equalTo: scrollView.frameLayoutGuide.trailingAnchor,
                constant: -16),
            contentStack.bottomAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.bottomAnchor,
                constant: -24),
            picker.heightAnchor.constraint(equalToConstant: 360),
        ])
        refreshCoordinateControls()
    }

    private func configureCoordinateField(_ field: UITextField, label: String) {
        field.borderStyle = .roundedRect
        field.keyboardType = .numbersAndPunctuation
        field.placeholder = label
        field.accessibilityLabel = label
        field.adjustsFontForContentSizeCategory = true
        field.font = UIFont.monospacedDigitSystemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .body).pointSize,
            weight: .regular)
    }

    private func labeledCoordinateField(
        _ text: String,
        field: UITextField
    ) -> UIView {
        let label = UILabel()
        label.text = text
        label.font = .preferredFont(forTextStyle: .caption1)
        label.textColor = .secondaryLabel
        label.adjustsFontForContentSizeCategory = true
        let stack = UIStackView(arrangedSubviews: [label, field])
        stack.axis = .vertical
        stack.spacing = 4
        return stack
    }

    private var translationStepM: Double {
        switch stepControl.selectedSegmentIndex {
        case 0: return 0.1
        case 2: return 1.0
        default: return 0.5
        }
    }

    private func controlButton(
        _ title: String,
        accessibilityLabel: String,
        action: Selector
    ) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.accessibilityLabel = accessibilityLabel
        button.backgroundColor = .tertiarySystemBackground
        button.layer.cornerRadius = 9
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        button.addTarget(self, action: action, for: .touchUpInside)
        return button
    }

    private func makePositionPad() -> UIView {
        let up = controlButton("↑ +Y", accessibilityLabel: "向地图北侧移动", action: #selector(nudgeUp))
        let down = controlButton("↓ −Y", accessibilityLabel: "向地图南侧移动", action: #selector(nudgeDown))
        let left = controlButton("← −X", accessibilityLabel: "向地图西侧移动", action: #selector(nudgeLeft))
        let right = controlButton("+X →", accessibilityLabel: "向地图东侧移动", action: #selector(nudgeRight))
        let centre = controlButton(
            "复位",
            accessibilityLabel: "恢复打开人工定位时的位置和朝向",
            action: #selector(resetPose))
        let top = UIStackView(arrangedSubviews: [UIView(), up, UIView()])
        let middle = UIStackView(arrangedSubviews: [left, centre, right])
        let bottom = UIStackView(arrangedSubviews: [UIView(), down, UIView()])
        for row in [top, middle, bottom] {
            row.axis = .horizontal
            row.spacing = 8
            row.distribution = .fillEqually
        }
        let result = UIStackView(arrangedSubviews: [top, middle, bottom])
        result.axis = .vertical
        result.spacing = 6
        return result
    }

    private func makeRotationRow() -> UIView {
        let values: [(String, String, Selector)] = [
            ("−15°", "朝向顺时针旋转十五度", #selector(rotateMinus15)),
            ("−5°", "朝向顺时针旋转五度", #selector(rotateMinus5)),
            ("−1°", "朝向顺时针旋转一度", #selector(rotateMinus1)),
            ("+1°", "朝向逆时针旋转一度", #selector(rotatePlus1)),
            ("+5°", "朝向逆时针旋转五度", #selector(rotatePlus5)),
            ("+15°", "朝向逆时针旋转十五度", #selector(rotatePlus15)),
        ]
        let row = UIStackView(arrangedSubviews: values.map {
            controlButton($0.0, accessibilityLabel: $0.1, action: $0.2)
        })
        row.axis = .horizontal
        row.spacing = 6
        row.distribution = .fillEqually
        return row
    }

    private func makeViewportControls() -> UIView {
        let fit = controlButton(
            "适配全图",
            accessibilityLabel: "将地图缩放为完整可见",
            action: #selector(resetViewport))
        let focus = controlButton(
            "定位红色箭头",
            accessibilityLabel: "将当前人工定位箭头移到视图中央",
            action: #selector(focusOnPose))
        let row = UIStackView(arrangedSubviews: [fit, focus])
        row.axis = .horizontal
        row.spacing = 8
        row.distribution = .fillEqually
        return row
    }

    private func refreshCoordinateControls() {
        let pose = picker.pose
        xField.text = String(format: "%.3f", pose.xM)
        yField.text = String(format: "%.3f", pose.yM)
        let degrees = PriorMapStageOneMath.normalizeAngle(pose.yawRad) * 180.0 / .pi
        yawField.text = String(format: "%.1f", degrees)
        coordinateLabel.text = String(
            format: "canonical SE(2)：X %.3f m · Y %.3f m · yaw %.1f°",
            pose.xM,
            pose.yM,
            degrees)
    }

    @discardableResult
    private func applyCoordinateFields(showError: Bool) -> Bool {
        guard let xText = xField.text,
              let yText = yField.text,
              let yawText = yawField.text,
              let x = Double(xText.replacingOccurrences(of: ",", with: ".")),
              let y = Double(yText.replacingOccurrences(of: ",", with: ".")),
              let yawDegrees = Double(
                yawText.replacingOccurrences(of: ",", with: ".")),
              x.isFinite, y.isFinite, yawDegrees.isFinite else {
            if showError {
                submissionStatusLabel.textColor = .systemRed
                submissionStatusLabel.text = "坐标或方向不是有效数字，请修正后再确认。当前位置尚未提交。"
            }
            return false
        }
        picker.setPose(PriorMapPose2D(
            xM: x,
            yM: y,
            yawRad: yawDegrees * .pi / 180.0))
        return true
    }

    @objc private func coordinateFieldChanged() {
        _ = applyCoordinateFields(showError: true)
    }

    @objc private func nudgeUp() { picker.nudge(dxM: 0, dyM: translationStepM) }
    @objc private func nudgeDown() { picker.nudge(dxM: 0, dyM: -translationStepM) }
    @objc private func nudgeLeft() { picker.nudge(dxM: -translationStepM, dyM: 0) }
    @objc private func nudgeRight() { picker.nudge(dxM: translationStepM, dyM: 0) }
    @objc private func rotateMinus15() { picker.rotate(byDegrees: -15) }
    @objc private func rotateMinus5() { picker.rotate(byDegrees: -5) }
    @objc private func rotateMinus1() { picker.rotate(byDegrees: -1) }
    @objc private func rotatePlus1() { picker.rotate(byDegrees: 1) }
    @objc private func rotatePlus5() { picker.rotate(byDegrees: 5) }
    @objc private func rotatePlus15() { picker.rotate(byDegrees: 15) }
    @objc private func resetPose() { picker.setPose(initialPose) }
    @objc private func resetViewport() { picker.resetViewport(animated: true) }
    @objc private func focusOnPose() { picker.focusOnPose(animated: true) }

    @objc private func cardinalChanged(_ sender: UISegmentedControl) {
        switch sender.selectedSegmentIndex {
        case 1: picker.setYaw(.pi / 2)
        case 2: picker.setYaw(.pi)
        case 3: picker.setYaw(-.pi / 2)
        default: picker.setYaw(0)
        }
        sender.selectedSegmentIndex = UISegmentedControl.noSegment
    }

    @objc private func cancelled() {
        guard !submissionInFlight else { return }
        dismiss(animated: true)
    }

    @objc private func confirmed() {
        guard !submissionInFlight else { return }
        view.endEditing(true)
        guard applyCoordinateFields(showError: true) else { return }
        let value = picker.pose
        submissionInFlight = true
        view.isUserInteractionEnabled = false
        submissionStatusLabel.textColor = .systemOrange
        submissionStatusLabel.text = "正在等待时间匹配的稳定节点并写入人工校准审计记录…"
        completion(value) { [weak self] outcome in
            DispatchQueue.main.async {
                guard let self else { return }
                switch outcome {
                case .applied:
                    self.submissionStatusLabel.textColor = .systemGreen
                    self.submissionStatusLabel.text = "位置和方向已写入审计记录并生效。"
                    self.dismiss(animated: true)
                case .rejected(let message):
                    self.submissionInFlight = false
                    self.view.isUserInteractionEnabled = true
                    self.submissionStatusLabel.textColor = .systemRed
                    self.submissionStatusLabel.text = message
                    UIAccessibility.post(
                        notification: .announcement,
                        argument: message)
                }
            }
        }
    }
}

final class PriorMapWizardViewController: UIViewController, UIDocumentPickerDelegate {
    private let completion: (PriorMapScanConfiguration) -> Void
    private let onCancel: () -> Void
    private var package: PriorMapPackage?
    private var step = 0
    private var selectedFloorIndex = 0
    private var selectedPose = PriorMapPose2D(xM: 0, yM: 0, yawRad: 0)
    private var hasSelectedInitialPose = false
    private let titleLabel = UILabel()
    private let content = UIStackView()
    private let backButton = UIButton(type: .system)
    private let nextButton = UIButton(type: .system)
    private var cameraPermissionRequestInFlight = false

    private let steps = [
        "1. 选择地图",
        "2. 选择楼层",
        "3. 确认起点和朝向",
        "4. 设备检查",
        "5. 开始扫描",
    ]

    init(
        completion: @escaping (PriorMapScanConfiguration) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.completion = completion
        self.onCancel = onCancel
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .formSheet
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        titleLabel.font = .preferredFont(forTextStyle: .title2)
        titleLabel.numberOfLines = 0
        content.axis = .vertical
        content.spacing = 12
        content.alignment = .fill
        backButton.setTitle("上一步", for: .normal)
        nextButton.setTitle("下一步", for: .normal)
        backButton.addTarget(self, action: #selector(goBack), for: .touchUpInside)
        nextButton.addTarget(self, action: #selector(goNext), for: .touchUpInside)
        let cancel = UIButton(type: .system)
        cancel.setTitle("取消", for: .normal)
        cancel.addTarget(self, action: #selector(cancelWizard), for: .touchUpInside)
        let buttons = UIStackView(arrangedSubviews: [cancel, backButton, UIView(), nextButton])
        buttons.axis = .horizontal
        buttons.spacing = 12
        let root = UIStackView(arrangedSubviews: [titleLabel, content, buttons])
        root.axis = .vertical
        root.spacing = 18
        root.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 22),
            root.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -22),
            root.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 22),
            root.bottomAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -22),
            content.heightAnchor.constraint(greaterThanOrEqualToConstant: 360),
        ])
        renderStep()
    }

    private func renderStep() {
        content.arrangedSubviews.forEach {
            content.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        titleLabel.text = steps[step]
        backButton.isEnabled = step > 0
        nextButton.setTitle(step == steps.count - 1 ? "开始连续扫描" : "下一步", for: .normal)
        switch step {
        case 0:
            addText("选择由 PC 工作台生成的 PriorMap-* 文件夹。地图包会被复制到本机应用目录，原文件保持不变。")
            let choose = UIButton(type: .system)
            choose.setTitle(package == nil ? "选择地图包" : "重新选择地图包", for: .normal)
            choose.addTarget(self, action: #selector(choosePackage), for: .touchUpInside)
            content.addArrangedSubview(choose)
            if let package = package {
                addText("\(package.manifest.name) · \(package.manifest.elementCount) 个元素 · \(package.manifest.warningCount) 条警告")
                addPreview(package.preview, height: 260)
            }
            nextButton.isEnabled = package != nil
        case 1:
            guard let package = package else { return }
            addText("请选择本次扫描所在楼层。本次连续扫描将始终绑定该楼层，不支持扫描中切换或跨楼层定位。楼层内坡道、地面起伏等少量竖直位移不会改变二维先验地图位置。")
            let control = UISegmentedControl(items: package.manifest.floors.map { $0.id })
            control.selectedSegmentIndex = min(selectedFloorIndex, package.manifest.floors.count - 1)
            control.addTarget(self, action: #selector(floorChanged(_:)), for: .valueChanged)
            content.addArrangedSubview(control)
            addPreview(
                package.preview(floorId: package.manifest.floors[selectedFloorIndex].id),
                height: 280)
            nextButton.isEnabled = true
        case 2:
            guard let package = package else { return }
            let floor = package.manifest.floors[selectedFloorIndex]
            if !hasSelectedInitialPose {
                selectedPose.xM = (floor.bounds.minXM + floor.bounds.maxXM) / 2.0
                selectedPose.yM = (floor.bounds.minYM + floor.bounds.maxYM) / 2.0
                hasSelectedInitialPose = true
            }
            addText("点击地图设置起点；双指缩放/平移。拖动下方方向滑杆调整箭头。起点和方向错误会影响定位。")
            let picker = PriorMapPosePickerView(
                image: package.preview(floorId: floor.id),
                bounds: floor.bounds,
                pose: selectedPose)
            picker.heightAnchor.constraint(equalToConstant: 300).isActive = true
            picker.tag = 9001
            content.addArrangedSubview(picker)
            let floorNodes = package.roadGraph.nodes
                .filter { $0.floorId == floor.id && $0.positionM.count >= 2 }
                .sorted { $0.id < $1.id }
            if !floorNodes.isEmpty {
                let anchorButton = UIButton(type: .system)
                anchorButton.setTitle("选择道路锚点（可选）", for: .normal)
                anchorButton.showsMenuAsPrimaryAction = true
                anchorButton.menu = UIMenu(children: floorNodes.prefix(20).enumerated().map {
                    index, node in
                    UIAction(
                        title: String(
                            format: "锚点 %d · %.1f, %.1f m",
                            index + 1,
                            node.positionM[0],
                            node.positionM[1])
                    ) { [weak self, weak picker] _ in
                        guard let self = self else { return }
                        self.selectedPose.xM = node.positionM[0]
                        self.selectedPose.yM = node.positionM[1]
                        self.hasSelectedInitialPose = true
                        picker?.setPose(self.selectedPose)
                    }
                })
                content.addArrangedSubview(anchorButton)
            }
            let slider = UISlider()
            slider.minimumValue = -Float.pi
            slider.maximumValue = Float.pi
            slider.value = Float(selectedPose.yawRad)
            slider.addTarget(self, action: #selector(yawChanged(_:)), for: .valueChanged)
            content.addArrangedSubview(slider)
            addText("比例尺和真实尺寸来自地图包，内部单位为米。")
            nextButton.isEnabled = true
        case 3:
            addText("设备检查")
            let cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
            let camera = cameraStatus == .authorized
            if cameraStatus == .notDetermined && !cameraPermissionRequestInFlight {
                cameraPermissionRequestInFlight = true
                AVCaptureDevice.requestAccess(for: .video) { [weak self] _ in
                    DispatchQueue.main.async {
                        self?.cameraPermissionRequestInFlight = false
                        self?.renderStep()
                    }
                }
            }
            let arkitSupported = ARWorldTrackingConfiguration.isSupported
            let depth = ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
            let thermal = ProcessInfo.processInfo.thermalState
            let thermalOK = thermal != .critical
            let freeBytes = ((try? FileManager.default.attributesOfFileSystem(
                forPath: NSHomeDirectory())[.systemFreeSize]) as? NSNumber)?.int64Value ?? 0
            let cameraDetail: String
            if camera {
                cameraDetail = "可用"
            }
            else if cameraStatus == .notDetermined {
                cameraDetail = "正在请求系统权限"
            }
            else {
                cameraDetail = "未授权，请到系统设置允许相机"
            }
            addCheck("相机权限", camera, cameraDetail)
            addCheck(
                "ARKit 设备支持",
                arkitSupported,
                arkitSupported ? "支持世界跟踪" : "此设备不支持 ARKit 世界跟踪")
            addInfo("ARKit tracking", "待扫描启动后实时监测；不稳定时保留原始扫描")
            addCheck("LiDAR / 深度", depth, depth ? "可用，可进行结构匹配和价签深度测量" : "不可用；仅保留 ARKit 预测、道路弱先验和价签射线回退")
            addCheck("剩余空间", freeBytes > 2_000_000_000, String(format: "%.1f GB", Double(freeBytes) / 1_000_000_000.0))
            addCheck("温度", thermalOK, "\(thermal)")
            addCheck("先验地图完整性", package != nil, package == nil ? "未选择" : "已通过版本检查")
            addCheck("保存位置", true, "连续数据库和 sidecar 写入当前扫描目录")
            nextButton.isEnabled = camera && arkitSupported && thermalOK && package != nil
        default:
            guard let package = package else { return }
            addText("即将开始已有地图辅助扫描。手机仍会连续写入完整 RTAB-Map 三维数据库；二维先验定位只使用选定楼层，楼层内少量竖直位移保留在原始数据中但不参与二维位置计算。道路只做小幅软约束，不会跨通道强制跳转。")
            addText("地图：\(package.manifest.name)\n楼层：\(package.manifest.floors[selectedFloorIndex].id)\n起点：\(String(format: "%.2f, %.2f m", selectedPose.xM, selectedPose.yM))")
            addText("结构候选只有在唯一、连续一致且修正幅度安全时才会调整地图对齐。定位较弱或丢失时，原始扫描继续保存；价签不会自动确认。")
            nextButton.isEnabled = true
        }
    }

    private func addText(_ text: String) {
        let label = UILabel()
        label.text = text
        label.numberOfLines = 0
        label.textColor = .secondaryLabel
        content.addArrangedSubview(label)
    }

    private func addPreview(_ image: UIImage, height: CGFloat) {
        let preview = UIImageView(image: image)
        preview.contentMode = .scaleAspectFit
        preview.backgroundColor = .secondarySystemBackground
        preview.layer.cornerRadius = 8
        preview.clipsToBounds = true
        preview.heightAnchor.constraint(equalToConstant: height).isActive = true
        content.addArrangedSubview(preview)
    }

    private func addCheck(_ title: String, _ success: Bool, _ detail: String) {
        let label = UILabel()
        label.numberOfLines = 0
        label.text = "\(success ? "✓" : "!") \(title)：\(detail)"
        label.textColor = success ? .systemGreen : .systemOrange
        content.addArrangedSubview(label)
    }

    private func addInfo(_ title: String, _ detail: String) {
        let label = UILabel()
        label.numberOfLines = 0
        label.text = "○ \(title)：\(detail)"
        label.textColor = .secondaryLabel
        content.addArrangedSubview(label)
    }

    @objc private func choosePackage() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
        picker.delegate = self
        picker.allowsMultipleSelection = false
        present(picker, animated: true)
    }

    func documentPicker(
        _ controller: UIDocumentPickerViewController,
        didPickDocumentsAt urls: [URL]
    ) {
        guard let source = urls.first else { return }
        let accessed = source.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                source.stopAccessingSecurityScopedResource()
            }
        }
        do {
            let importedRoot = try FileManager.default.url(
                for: .documentDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true)
                .appendingPathComponent("PriorMaps", isDirectory: true)
            try FileManager.default.createDirectory(
                at: importedRoot,
                withIntermediateDirectories: true)
            let temporary = importedRoot.appendingPathComponent(
                ".import-\(UUID().uuidString)",
                isDirectory: true)
            defer {
                if FileManager.default.fileExists(atPath: temporary.path) {
                    try? FileManager.default.removeItem(at: temporary)
                }
            }
            try FileManager.default.copyItem(at: source, to: temporary)
            let validatedPackage = try PriorMapPackage.load(directory: temporary)
            let manifest = validatedPackage.manifest
            let destination = importedRoot.appendingPathComponent(
                "PriorMap-\(manifest.sourceSha256.prefix(16))",
                isDirectory: true)
            if FileManager.default.fileExists(atPath: destination.path) {
                let backupName = ".backup-\(UUID().uuidString)"
                _ = try FileManager.default.replaceItemAt(
                    destination,
                    withItemAt: temporary,
                    backupItemName: backupName,
                    options: [])
                let backup = importedRoot.appendingPathComponent(
                    backupName,
                    isDirectory: true)
                if FileManager.default.fileExists(atPath: backup.path) {
                    try? FileManager.default.removeItem(at: backup)
                }
            }
            else {
                try FileManager.default.moveItem(
                    at: temporary,
                    to: destination)
            }
            package = try PriorMapPackage.load(directory: destination)
            selectedFloorIndex = 0
            selectedPose = PriorMapPose2D(xM: 0, yM: 0, yawRad: 0)
            hasSelectedInitialPose = false
            renderStep()
        }
        catch {
            let alert = UIAlertController(
                title: "无法导入地图",
                message: "\(error.localizedDescription)\n\n源地图没有被修改。请在 PC 工作台查看验证报告后重试。",
                preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "知道了", style: .default))
            present(alert, animated: true)
        }
    }

    @objc private func floorChanged(_ sender: UISegmentedControl) {
        selectedFloorIndex = max(0, sender.selectedSegmentIndex)
        selectedPose = PriorMapPose2D(xM: 0, yM: 0, yawRad: selectedPose.yawRad)
        hasSelectedInitialPose = false
        renderStep()
    }

    @objc private func yawChanged(_ sender: UISlider) {
        selectedPose.yawRad = Double(sender.value)
        (content.arrangedSubviews.first { $0.tag == 9001 } as? PriorMapPosePickerView)?
            .setYaw(selectedPose.yawRad)
    }

    @objc private func goBack() {
        step = max(0, step - 1)
        renderStep()
    }

    @objc private func goNext() {
        if let picker = content.arrangedSubviews.first(where: { $0.tag == 9001 }) as? PriorMapPosePickerView {
            selectedPose = picker.pose
        }
        if step < steps.count - 1 {
            step += 1
            renderStep()
            return
        }
        guard let package = package else { return }
        let configuration = PriorMapScanConfiguration(
            formatVersion: 1,
            workflowMode: .priorMapLocalized,
            packageDirectory: package.directory,
            priorMapId: package.manifest.priorMapId,
            priorMapSha256: package.packageSha256,
            priorMapCanonicalSourceSha256:
                package.manifest.canonicalSourceSha256,
            floorId: package.manifest.floors[selectedFloorIndex].id,
            storeID: package.manifest.storeID,
            initialMapPose: selectedPose)
        dismiss(animated: true) {
            self.completion(configuration)
        }
    }

    @objc private func cancelWizard() {
        dismiss(animated: true, completion: onCancel)
    }
}

final class PriorMapLiveMapView: UIView {
    let confirmButton = UIButton(type: .system)
    let reselectButton = UIButton(type: .system)
    let scanPriceTagButton = UIButton(type: .system)
    private let previewView = UIImageView()
    private let statusLabel = UILabel()
    private let evidenceWarningLabel = UILabel()
    private let roadLabel = UILabel()
    private let diagnosticsButton = UIButton(type: .system)
    private let diagnosticsLabel = UILabel()
    private let arrow = CAShapeLayer()
    private let trajectoryLayer = CAShapeLayer()
    private let confirmedTagLayer = CAShapeLayer()
    private let pendingTagLayer = CAShapeLayer()
    private let routeLayer = CAShapeLayer()
    private var recentTrajectory: [PriorMapPose2D] = []
    private let boundsM: PriorMapBounds

    init(package: PriorMapPackage, floorId: String) {
        self.boundsM = package.manifest.floors.first(where: { $0.id == floorId })!.bounds
        super.init(frame: .zero)
        backgroundColor = UIColor.systemBackground.withAlphaComponent(0.94)
        layer.cornerRadius = 12
        layer.borderColor = UIColor.separator.cgColor
        layer.borderWidth = 1
        previewView.image = package.preview(floorId: floorId)
        previewView.contentMode = .scaleAspectFit
        arrow.path = PriorMapHeadingUI.rightPointingArrowPath(
            length: 8,
            halfWidth: 5,
            notch: 3)
        routeLayer.strokeColor = UIColor.systemTeal.withAlphaComponent(0.65).cgColor
        routeLayer.fillColor = UIColor.clear.cgColor
        routeLayer.lineWidth = 2
        routeLayer.lineDashPattern = [6, 4]
        trajectoryLayer.strokeColor = UIColor.systemBlue.cgColor
        trajectoryLayer.fillColor = UIColor.clear.cgColor
        trajectoryLayer.lineWidth = 2
        confirmedTagLayer.fillColor = UIColor.systemGreen.cgColor
        pendingTagLayer.fillColor = UIColor.systemOrange.cgColor
        previewView.layer.addSublayer(routeLayer)
        previewView.layer.addSublayer(trajectoryLayer)
        previewView.layer.addSublayer(confirmedTagLayer)
        previewView.layer.addSublayer(pendingTagLayer)
        previewView.layer.addSublayer(arrow)
        arrow.fillColor = UIColor.systemRed.cgColor
        statusLabel.font = .preferredFont(forTextStyle: .headline)
        evidenceWarningLabel.font = .preferredFont(forTextStyle: .caption1)
        evidenceWarningLabel.textColor = .systemRed
        evidenceWarningLabel.numberOfLines = 0
        evidenceWarningLabel.isHidden = true
        roadLabel.font = .preferredFont(forTextStyle: .caption1)
        roadLabel.textColor = .secondaryLabel
        roadLabel.numberOfLines = 2
        diagnosticsButton.setTitle("定位诊断 ▸", for: .normal)
        diagnosticsButton.contentHorizontalAlignment = .left
        diagnosticsButton.addTarget(
            self,
            action: #selector(toggleDiagnostics),
            for: .touchUpInside)
        diagnosticsLabel.font = .preferredFont(forTextStyle: .caption2)
        diagnosticsLabel.textColor = .secondaryLabel
        diagnosticsLabel.numberOfLines = 2
        diagnosticsLabel.isHidden = true
        confirmButton.setTitle("确认当前位置", for: .normal)
        reselectButton.setTitle("重新选择位置", for: .normal)
        scanPriceTagButton.setTitle("扫描价签条码", for: .normal)
        let buttons = UIStackView(arrangedSubviews: [confirmButton, reselectButton])
        buttons.axis = .horizontal
        buttons.distribution = .fillEqually
        let stack = UIStackView(
            arrangedSubviews: [
                statusLabel,
                evidenceWarningLabel,
                roadLabel,
                diagnosticsButton,
                diagnosticsLabel,
                previewView,
                buttons,
                scanPriceTagButton,
            ])
        stack.axis = .vertical
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            previewView.heightAnchor.constraint(equalToConstant: 150),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showEvidenceWriteFailure(_ message: String) {
        evidenceWarningLabel.text = message
        evidenceWarningLabel.isHidden = false
    }

    @objc private func toggleDiagnostics() {
        diagnosticsLabel.isHidden.toggle()
        diagnosticsButton.setTitle(
            diagnosticsLabel.isHidden ? "定位诊断 ▸" : "定位诊断 ▾",
            for: .normal)
    }

    private func displayedPreviewRect() -> CGRect {
        guard let image = previewView.image,
              image.size.width > 0,
              image.size.height > 0,
              previewView.bounds.width > 0,
              previewView.bounds.height > 0 else {
            return previewView.bounds
        }
        let scale = min(
            previewView.bounds.width / image.size.width,
            previewView.bounds.height / image.size.height)
        let size = CGSize(
            width: image.size.width * scale,
            height: image.size.height * scale)
        return CGRect(
            x: (previewView.bounds.width - size.width) / 2.0,
            y: (previewView.bounds.height - size.height) / 2.0,
            width: size.width,
            height: size.height)
    }

    func update(_ value: PriorMapLocalizationUpdate) {
        let labels = [
            "uninitialized": ("定位未初始化", UIColor.secondaryLabel),
            "initializing": ("定位初始化中", UIColor.systemOrange),
            "stable": ("定位稳定", UIColor.systemGreen),
            "usable": ("定位可用", UIColor.systemBlue),
            "recovering": ("正在恢复定位 Recovering", UIColor.systemOrange),
            "weak": ("定位较弱", UIColor.systemOrange),
            "lost": ("定位已丢失", UIColor.systemRed),
            "manualCorrection": ("人工修正后验证中", UIColor.systemOrange),
        ]
        let state = labels[value.localizationState] ?? ("定位较弱", UIColor.systemOrange)
        statusLabel.text = "\(state.0) · \(Int(value.confidence * 100))%"
        statusLabel.textColor = state.1
        let acceptedText = value.constraintAccepted ? "已安全修正" : "继续采集"
        if value.localizationState == "lost" {
            roadLabel.text = "已超出自动局部恢复窗口，请点击“重新选择位置”人工重定位"
        }
        else {
            roadLabel.text = value.roadCandidates.first.map {
                "当前通道：\($0.edgeId) · \(acceptedText)；走向交叉口或货架端头"
            } ?? "当前通道未确认 · \(acceptedText)；走向交叉口或货架端头"
        }
        if let candidate = value.matchCandidates.first {
            diagnosticsLabel.text = String(
                format: "结构 %.2f · 唯一性 %.2f · 轨道 %d 帧/%.2f · %d 点 · %.1f ms",
                candidate.score,
                value.matchUniqueness,
                value.hypothesisSupportFrames,
                value.hypothesisScoreMargin,
                value.structurePointCount,
                value.matcherElapsedMs)
        }
        else {
            diagnosticsLabel.text = value.roadCandidates.first.map {
                "道路距离 \(String(format: "%.2f m", $0.distanceM)) · \(value.constraintReason)"
            } ?? "无候选 · \(value.constraintReason)"
        }
        layoutIfNeeded()
        recentTrajectory.append(value.estimatedPose)
        if recentTrajectory.count > 2000 {
            recentTrajectory.removeFirst(recentTrajectory.count - 2000)
        }
        let trajectory = UIBezierPath()
        for (index, pose) in recentTrajectory.enumerated() {
            let point = previewPoint(xM: pose.xM, yM: pose.yM)
            index == 0 ? trajectory.move(to: point) : trajectory.addLine(to: point)
        }
        trajectoryLayer.path = trajectory.cgPath
        let arrowPoint = previewPoint(
            xM: value.estimatedPose.xM,
            yM: value.estimatedPose.yM)
        arrow.position = arrowPoint
        arrow.setAffineTransform(
            PriorMapHeadingUI.screenTransform(
                yawRad: value.estimatedPose.yawRad))
    }

    func updateTagLayers(
        confirmed: [PriorMapTagPoint3D],
        pending: [PriorMapTagPoint3D],
        route: [PriorMapPose2D] = []
    ) {
        func markerPath(_ values: [PriorMapTagPoint3D]) -> CGPath {
            let path = UIBezierPath()
            for value in values {
                let point = previewPoint(xM: value.xM, yM: value.yM)
                path.append(UIBezierPath(
                    ovalIn: CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)))
            }
            return path.cgPath
        }
        confirmedTagLayer.path = markerPath(confirmed)
        pendingTagLayer.path = markerPath(pending)
        let path = UIBezierPath()
        for (index, pose) in route.enumerated() {
            let point = previewPoint(xM: pose.xM, yM: pose.yM)
            index == 0 ? path.move(to: point) : path.addLine(to: point)
        }
        routeLayer.path = path.cgPath
    }

    private func previewPoint(xM: Double, yM: Double) -> CGPoint {
        let width = max(0.001, boundsM.maxXM - boundsM.minXM)
        let height = max(0.001, boundsM.maxYM - boundsM.minYM)
        let imageRect = displayedPreviewRect()
        let normalizedX = min(1, max(0, (xM - boundsM.minXM) / width))
        let normalizedY = min(1, max(0, (boundsM.maxYM - yM) / height))
        return CGPoint(
            x: imageRect.minX + CGFloat(normalizedX) * imageRect.width,
            y: imageRect.minY + CGFloat(normalizedY) * imageRect.height)
    }
}

// P7R6: the stage-one localizer is the peek/ack source consumed by
// RecoveryLifecyclePersistenceCoordinator.
extension PriorMapStageOneLocalizer: RecoveryCompletionDraining {
}
