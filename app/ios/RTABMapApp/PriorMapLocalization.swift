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
    let sourceSha256: String
    let floors: [PriorMapFloor]
    let elementCount: Int
    let warningCount: Int

    enum CodingKeys: String, CodingKey {
        case format
        case version
        case priorMapId = "prior_map_id"
        case name
        case sourceSha256 = "source_sha256"
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
    let preview: UIImage
    let previewsByFloor: [String: UIImage]

    func preview(floorId: String) -> UIImage {
        return previewsByFloor[floorId] ?? preview
    }

    static func load(directory: URL) throws -> PriorMapPackage {
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
            let data = try Data(
                contentsOf: directory.appendingPathComponent(name))
            guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  payload["format"] as? String == expectedFormat,
                  payload["version"] as? Int == 1 else {
                throw NSError(
                    domain: "PriorMap",
                    code: 5,
                    userInfo: [NSLocalizedDescriptionKey: "\(name) 无法通过地图包格式校验。"])
            }
        }
        let manifestURL = directory.appendingPathComponent("manifest.json")
        let graphURL = directory.appendingPathComponent("road_graph.json")
        let spatialURL = directory.appendingPathComponent("spatial_index.json")
        let distanceURL = directory.appendingPathComponent("distance_fields.json")
        let shelvesURL = directory.appendingPathComponent("shelves.json")
        let previewURL = directory.appendingPathComponent("preview.png")
        let manifest = try decoder.decode(
            PriorMapManifest.self,
            from: Data(contentsOf: manifestURL))
        guard manifest.format == "MarketScannerPriorMap", manifest.version == 1 else {
            throw NSError(
                domain: "PriorMap",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "地图包版本不受支持。请先在 PC 工作台重新导入 Excel。"])
        }
        guard !manifest.priorMapId.isEmpty,
              manifest.priorMapId.count <= 128,
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
            from: Data(contentsOf: graphURL))
        let spatial = try decoder.decode(
            PriorMapSpatialIndexPayload.self,
            from: Data(contentsOf: spatialURL))
        let distanceFields = try decoder.decode(
            PriorMapDistanceFieldFile.self,
            from: Data(contentsOf: distanceURL))
        let shelvesPayload = try decoder.decode(
            PriorMapShelvesPayload.self,
            from: Data(contentsOf: shelvesURL))
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
              shelvesPayload.version == 1 else {
            throw NSError(
                domain: "PriorMap",
                code: 8,
                userInfo: [NSLocalizedDescriptionKey: "地图包的结构距离场或货架数据无效，请在 PC 工作台重新生成。"])
        }
        // Decode every level now so corrupted RLE or a checksum mismatch is
        // rejected before a scan can begin.
        for floor in distanceFields.floors.values {
            for level in floor.levels {
                _ = try level.decodedValues()
            }
        }
        guard let preview = UIImage(contentsOfFile: previewURL.path) else {
            throw NSError(
                domain: "PriorMap",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "地图预览无法读取。源 Excel 不受影响，请重新生成地图包。"])
        }
        var previewsByFloor: [String: UIImage] = [:]
        for floor in manifest.floors {
            guard let filename = floor.previewFile,
                  URL(fileURLWithPath: filename).lastPathComponent == filename,
                  let floorPreview = UIImage(
                    contentsOfFile: directory.appendingPathComponent(filename).path) else {
                throw NSError(
                    domain: "PriorMap",
                    code: 7,
                    userInfo: [NSLocalizedDescriptionKey: "楼层 \(floor.id) 的预览无法读取，请重新生成地图包。"])
            }
            previewsByFloor[floor.id] = floorPreview
        }
        return PriorMapPackage(
            directory: directory,
            manifest: manifest,
            roadGraph: graph,
            spatialIndex: spatial,
            distanceFields: distanceFields,
            shelves: shelvesPayload.shelves,
            preview: preview,
            previewsByFloor: previewsByFloor)
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

final class PriorMapStageOneLocalizer {
    private let floorId: String
    private var initialMapPose: PriorMapPose2D
    private let segmentsById: [String: PriorMapRoadSegment]
    private let roadCells: [String: [String]]
    private let cellSizeM: Double
    private var arkitOrigin: PriorMapPose2D?
    private let softGain = 0.15
    private let maximumCorrectionM = 0.25
    private let ambiguityMarginM = 0.35
    private let candidateRadiusM = 3.0
    private let depthSampler = PriorMapDepthSampler()
    private let matcher: PriorMapScanMatcher
    private let confidenceManager = PriorMapConfidenceManager()
    private var lastCandidatePose: PriorMapPose2D?
    private var consecutiveConsistentCandidates = 0
    private let priorMapId: String
    private let priorMapSha256: String
    private let shelves: [PriorMapShelf]
    private var latestFloorHeightWorldM: Double?
    private(set) var latestEstimatedPose: PriorMapPose2D
    private(set) var latestConfidence = 0.0
    private(set) var latestPhase: PriorMapLocalizationPhase = .uninitialized

    init(
        package: PriorMapPackage,
        floorId: String,
        initialMapPose: PriorMapPose2D
    ) throws {
        self.floorId = floorId
        self.initialMapPose = initialMapPose
        self.latestEstimatedPose = initialMapPose
        self.priorMapId = package.manifest.priorMapId
        self.priorMapSha256 = package.manifest.sourceSha256
        self.shelves = package.shelves
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

    func update(frame: ARFrame, trackingState: String) -> PriorMapLocalizationUpdate {
        let transform = frame.camera.transform
        let timestamp = frame.timestamp
        let arkitPose = Self.pose(from: transform)
        if arkitOrigin == nil {
            arkitOrigin = arkitPose
        }
        let origin = arkitOrigin!
        let rawPose = PriorMapStageOneMath.project(
            arkitPose: arkitPose,
            arkitOrigin: origin,
            initialMapPose: initialMapPose)
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
        var accepted = false
        var reason = trackingState == "normal"
            ? "structure_depth_unavailable"
            : "tracking_not_normal"
        let observation = trackingState == "normal"
            ? depthSampler.sample(frame: frame)
            : nil
        let match = observation.map {
            matcher.match(predictedPose: rawPose, observation: $0)
        }
        if let floorHeight = observation?.floorHeightWorldM {
            latestFloorHeightWorldM = floorHeight
        }
        if let best = match?.candidates.first {
            let translation = hypot(
                best.pose.xM - rawPose.xM,
                best.pose.yM - rawPose.yM)
            let yawDelta = abs(PriorMapStageOneMath.normalizeAngle(
                best.pose.yawRad - rawPose.yawRad))
            let consistent: Bool
            if let prior = lastCandidatePose {
                consistent = hypot(
                    best.pose.xM - prior.xM,
                    best.pose.yM - prior.yM) <= 0.30
                    && abs(PriorMapStageOneMath.normalizeAngle(
                        best.pose.yawRad - prior.yawRad)) <= 5.0 * .pi / 180.0
            }
            else {
                consistent = false
            }
            consecutiveConsistentCandidates = consistent
                ? consecutiveConsistentCandidates + 1
                : 1
            lastCandidatePose = best.pose
            if match?.acceptedByGeometry == true,
               translation <= 0.35,
               yawDelta <= 8.0 * .pi / 180.0,
               consecutiveConsistentCandidates >= 2 {
                let gain = 0.35
                estimatedPose = PriorMapPose2D(
                    xM: rawPose.xM + (best.pose.xM - rawPose.xM) * gain,
                    yM: rawPose.yM + (best.pose.yM - rawPose.yM) * gain,
                    yawRad: PriorMapStageOneMath.normalizeAngle(
                        rawPose.yawRad
                            + PriorMapStageOneMath.normalizeAngle(
                                best.pose.yawRad - rawPose.yawRad) * gain))
                // Move only the map/ARKit alignment anchor. ARKit world
                // tracking and the scan database are never reset.
                arkitOrigin = arkitPose
                initialMapPose = estimatedPose
                accepted = true
                reason = "trusted_structure_correction"
            }
            else if match?.acceptedByGeometry != true {
                reason = match?.rejectionReason ?? "structure_rejected"
            }
            else if translation > 0.35 || yawDelta > 8.0 * .pi / 180.0 {
                reason = "correction_exceeds_safety_gate"
            }
            else {
                reason = "awaiting_temporal_consistency"
            }
        }
        else {
            consecutiveConsistentCandidates = 0
            lastCandidatePose = nil
            if observation != nil {
                reason = match?.rejectionReason ?? "no_structure_candidate"
            }
            else if trackingState == "normal", unique, let bestRoad = topCandidates.first {
                var correction = (bestRoad.point - projected) * softGain
                let length = simd_length(correction)
                if length > maximumCorrectionM {
                    correction *= maximumCorrectionM / length
                }
                estimatedPose.xM += correction.x
                estimatedPose.yM += correction.y
                reason = "road_prior_display_only"
            }
        }
        let residualCost = match?.candidates.first?.cost ?? 0.15
        let confidence = confidenceManager.update(
            timestamp: timestamp,
            trackingState: trackingState,
            accepted: accepted,
            validPointCount: observation?.validPointCount ?? 0,
            coverageAngleRad: observation?.coverageAngleRad ?? 0,
            uniqueness: match?.uniqueness ?? 0,
            residualCost: residualCost,
            mapMismatch: match?.rejectionReason == "map_mismatch")
        latestEstimatedPose = estimatedPose
        latestConfidence = confidence.confidence
        latestPhase = confidence.phase
        return PriorMapLocalizationUpdate(
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
            constraintAccepted: accepted,
            constraintReason: reason)
    }

    func confirmCurrentPosition(
        transform: simd_float4x4,
        mapPose: PriorMapPose2D
    ) -> (PriorMapPose2D, PriorMapPose2D) {
        let arkitPose = Self.pose(from: transform)
        arkitOrigin = arkitPose
        initialMapPose = mapPose
        latestEstimatedPose = mapPose
        confidenceManager.reset(manual: true)
        latestPhase = .manualCorrection
        latestConfidence = 0.35
        depthSampler.reset()
        lastCandidatePose = nil
        consecutiveConsistentCandidates = 0
        return (arkitPose, mapPose)
    }

    func localizePriceTag(
        _ detection: PriceTagVisionDetection,
        trackingSessionId: String
    ) -> (PriorMapTagObservationRecord, LocalizedPriceTag) {
        let cameraPose = Self.pose(from: detection.frame.camera.transform)
        if arkitOrigin == nil {
            arkitOrigin = cameraPose
        }
        let origin = arkitOrigin!
        let mapPoint: (SIMD3<Float>) -> PriorMapTagPoint3D = { world in
            let pointPose = PriorMapPose2D(
                xM: Double(world.x),
                yM: Double(-world.z),
                yawRad: origin.yawRad)
            let projected = PriorMapStageOneMath.project(
                arkitPose: pointPose,
                arkitOrigin: origin,
                initialMapPose: self.initialMapPose)
            return PriorMapTagPoint3D(
                xM: projected.xM,
                yM: projected.yM,
                heightM: nil)
        }
        let measurement = PriceTagFrameMeasurement.measure(
            detection: detection,
            floorId: floorId,
            shelves: shelves,
            floorHeightWorldM: latestFloorHeightWorldM,
            mapPoint: mapPoint)
        let localized = ShelfAssociation.localizedTag(
            observationId: detection.observationId,
            payload: detection.payload,
            symbology: detection.symbology,
            floorId: floorId,
            rawPosition: measurement.rawMapPosition,
            cameraPosition: measurement.cameraMapPosition,
            shelves: shelves,
            localizationState: latestPhase.rawValue,
            localizationConfidence: latestConfidence,
            measurementConfidence: measurement.confidence,
            measurementMethod: measurement.method,
            userConfirmed: false,
            trackingSessionId: trackingSessionId,
            priorMapId: priorMapId,
            priorMapSha256: priorMapSha256,
            timestamp: Date().timeIntervalSince1970)
        let bounds = detection.normalizedBounds
        let observation = PriorMapTagObservationRecord(
            format: "MarketScannerPriceTagObservation",
            version: 1,
            observationId: detection.observationId,
            timestamp: Date().timeIntervalSince1970,
            payload: detection.payload,
            symbology: detection.symbology,
            normalizedBounds: [
                Double(bounds.minX),
                Double(bounds.minY),
                Double(bounds.width),
                Double(bounds.height),
            ],
            frameTimestamp: detection.frame.timestamp,
            poseTimestampDeltaMs: measurement.poseTimestampDeltaMs,
            rawMapPosition: measurement.rawMapPosition,
            measurementMethod: measurement.method,
            measurementConfidence: measurement.confidence,
            localizationState: latestPhase.rawValue,
            localizationConfidence: latestConfidence,
            priorMapId: priorMapId,
            priorMapSha256: priorMapSha256,
            floorId: floorId,
            trackingSessionId: trackingSessionId,
            needsReview: localized.needsReview)
        return (observation, localized)
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

final class PriorMapPosePickerView: UIView {
    private let imageView = UIImageView()
    private let arrow = CAShapeLayer()
    private(set) var pose: PriorMapPose2D
    private let boundsM: PriorMapBounds

    init(image: UIImage, bounds: PriorMapBounds, pose: PriorMapPose2D) {
        self.pose = pose
        self.boundsM = bounds
        super.init(frame: .zero)
        imageView.image = image
        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        addSubview(imageView)
        arrow.fillColor = UIColor.systemRed.cgColor
        imageView.layer.addSublayer(arrow)
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        imageView.addGestureRecognizer(tap)
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
        imageView.addGestureRecognizer(pinch)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.minimumNumberOfTouches = 2
        imageView.addGestureRecognizer(pan)
        backgroundColor = .secondarySystemBackground
        layer.cornerRadius = 10
        clipsToBounds = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        imageView.frame = bounds
        updateArrow()
    }

    func setYaw(_ yaw: Double) {
        pose.yawRad = yaw
        updateArrow()
    }

    func setPose(_ value: PriorMapPose2D) {
        pose = value
        updateArrow()
    }

    private func displayedImageRect() -> CGRect {
        guard let image = imageView.image,
              image.size.width > 0,
              image.size.height > 0,
              imageView.bounds.width > 0,
              imageView.bounds.height > 0 else {
            return imageView.bounds
        }
        let scale = min(
            imageView.bounds.width / image.size.width,
            imageView.bounds.height / image.size.height)
        let size = CGSize(
            width: image.size.width * scale,
            height: image.size.height * scale)
        return CGRect(
            x: (imageView.bounds.width - size.width) / 2.0,
            y: (imageView.bounds.height - size.height) / 2.0,
            width: size.width,
            height: size.height)
    }

    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: imageView)
        let imageRect = displayedImageRect()
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
    }

    @objc private func pinched(_ gesture: UIPinchGestureRecognizer) {
        imageView.transform = imageView.transform.scaledBy(x: gesture.scale, y: gesture.scale)
        gesture.scale = 1
    }

    @objc private func panned(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: self)
        imageView.transform = imageView.transform.translatedBy(
            x: translation.x / max(0.1, imageView.transform.a),
            y: translation.y / max(0.1, imageView.transform.d))
        gesture.setTranslation(.zero, in: self)
    }

    private func updateArrow() {
        let width = max(0.001, boundsM.maxXM - boundsM.minXM)
        let height = max(0.001, boundsM.maxYM - boundsM.minYM)
        let imageRect = displayedImageRect()
        let x = imageRect.minX
            + CGFloat((pose.xM - boundsM.minXM) / width) * imageRect.width
        let y = imageRect.minY
            + CGFloat((boundsM.maxYM - pose.yM) / height) * imageRect.height
        let path = UIBezierPath()
        path.move(to: CGPoint(x: 0, y: -14))
        path.addLine(to: CGPoint(x: 8, y: 10))
        path.addLine(to: CGPoint(x: 0, y: 6))
        path.addLine(to: CGPoint(x: -8, y: 10))
        path.close()
        arrow.path = path.cgPath
        arrow.position = CGPoint(x: x, y: y)
        arrow.setAffineTransform(CGAffineTransform(rotationAngle: CGFloat(-pose.yawRad)))
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
            priorMapSha256: package.manifest.sourceSha256,
            floorId: package.manifest.floors[selectedFloorIndex].id,
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
    private let roadLabel = UILabel()
    private let arrow = CAShapeLayer()
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
        previewView.layer.addSublayer(arrow)
        arrow.fillColor = UIColor.systemRed.cgColor
        statusLabel.font = .preferredFont(forTextStyle: .headline)
        roadLabel.font = .preferredFont(forTextStyle: .caption1)
        roadLabel.textColor = .secondaryLabel
        roadLabel.numberOfLines = 2
        confirmButton.setTitle("确认当前位置", for: .normal)
        reselectButton.setTitle("重新选择位置", for: .normal)
        scanPriceTagButton.setTitle("扫描价签条码", for: .normal)
        let buttons = UIStackView(arrangedSubviews: [confirmButton, reselectButton])
        buttons.axis = .horizontal
        buttons.distribution = .fillEqually
        let stack = UIStackView(
            arrangedSubviews: [
                statusLabel,
                roadLabel,
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
            previewView.heightAnchor.constraint(equalToConstant: 180),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
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
            "weak": ("定位较弱", UIColor.systemOrange),
            "lost": ("定位已丢失", UIColor.systemRed),
            "manualCorrection": ("人工修正后验证中", UIColor.systemOrange),
        ]
        let state = labels[value.localizationState] ?? ("定位较弱", UIColor.systemOrange)
        statusLabel.text = "\(state.0) · \(Int(value.confidence * 100))%"
        statusLabel.textColor = state.1
        if let candidate = value.matchCandidates.first {
            roadLabel.text = String(
                format: "结构匹配 %.2f · 唯一性 %.2f · %d 点 · %.1f ms",
                candidate.score,
                value.matchUniqueness,
                value.structurePointCount,
                value.matcherElapsedMs)
        }
        else {
            roadLabel.text = value.roadCandidates.first.map {
                "道路先验：\($0.edgeId) · \(String(format: "%.2f m", $0.distanceM))；继续走向交叉口、柱子或端头"
            } ?? "当前没有可靠结构候选；继续走向交叉口、柱子或端头"
        }
        layoutIfNeeded()
        let width = max(0.001, boundsM.maxXM - boundsM.minXM)
        let height = max(0.001, boundsM.maxYM - boundsM.minYM)
        let imageRect = displayedPreviewRect()
        let x = imageRect.minX
            + CGFloat((value.estimatedPose.xM - boundsM.minXM) / width) * imageRect.width
        let y = imageRect.minY
            + CGFloat((boundsM.maxYM - value.estimatedPose.yM) / height) * imageRect.height
        let path = UIBezierPath()
        path.move(to: CGPoint(x: 0, y: -11))
        path.addLine(to: CGPoint(x: 7, y: 8))
        path.addLine(to: CGPoint(x: 0, y: 5))
        path.addLine(to: CGPoint(x: -7, y: 8))
        path.close()
        arrow.path = path.cgPath
        arrow.position = CGPoint(x: x, y: y)
        arrow.setAffineTransform(
            CGAffineTransform(rotationAngle: CGFloat(-value.estimatedPose.yawRad)))
    }
}
