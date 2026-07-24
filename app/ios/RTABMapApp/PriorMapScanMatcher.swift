//
//  PriorMapScanMatcher.swift
//  RTABMapApp
//
//  Dependency-light multi-resolution distance-field matching and centralized
//  stage-two localization confidence/state.
//

import CryptoKit
import Foundation
import simd

struct PriorMapDistanceFieldFile: Codable {
    let format: String
    let version: Int
    let truncationDistanceM: Double
    let floors: [String: PriorMapDistanceFieldFloor]

    enum CodingKeys: String, CodingKey {
        case format
        case version
        case truncationDistanceM = "truncation_distance_m"
        case floors
    }
}

struct PriorMapDistanceFieldFloor: Codable {
    let levels: [PriorMapDistanceFieldLevel]
}

struct PriorMapDistanceFieldLevel: Codable {
    let resolutionM: Double
    let originM: [Double]
    let width: Int
    let height: Int
    let encoding: String
    let dataSha256: String
    let rows: [[Int]]

    enum CodingKeys: String, CodingKey {
        case resolutionM = "resolution_m"
        case originM = "origin_m"
        case width
        case height
        case encoding
        case dataSha256 = "data_sha256"
        case rows
    }

    func decodedValues() throws -> [UInt8] {
        guard resolutionM > 0,
              originM.count == 2,
              width > 0,
              height > 0,
              encoding == "row_rle_u8_cm",
              rows.count == height else {
            throw NSError(
                domain: "PriorMapDistanceField",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "距离场元数据无效。"])
        }
        var result = [UInt8]()
        result.reserveCapacity(width * height)
        for row in rows {
            guard row.count % 2 == 0 else {
                throw NSError(
                    domain: "PriorMapDistanceField",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "距离场压缩行无效。"])
            }
            var rowCount = 0
            for index in stride(from: 0, to: row.count, by: 2) {
                let count = row[index]
                let value = row[index + 1]
                guard count > 0, (0...255).contains(value) else {
                    throw NSError(
                        domain: "PriorMapDistanceField",
                        code: 3,
                        userInfo: [NSLocalizedDescriptionKey: "距离场压缩值无效。"])
                }
                result.append(contentsOf: repeatElement(UInt8(value), count: count))
                rowCount += count
            }
            guard rowCount == width else {
                throw NSError(
                    domain: "PriorMapDistanceField",
                    code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "距离场压缩宽度不一致。"])
            }
        }
        let canonicalRows = "[" + rows.map {
            "[" + $0.map(String.init).joined(separator: ",") + "]"
        }.joined(separator: ",") + "]"
        let digest = SHA256.hash(data: Data(canonicalRows.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        guard digest == dataSha256.lowercased() else {
            throw NSError(
                domain: "PriorMapDistanceField",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "距离场数据摘要不匹配。"])
        }
        guard result.contains(0) else {
            throw NSError(
                domain: "PriorMapDistanceField",
                code: 6,
                userInfo: [NSLocalizedDescriptionKey: "距离场没有可用于定位的可见结构。"])
        }
        return result
    }
}

struct PriorMapStructureObservation {
    let points: [SIMD2<Double>]
    let validPointCount: Int
    let coverageAngleRad: Double
    let floorHeightWorldM: Double?
    let source: String
}

struct PriorMapScanMatchCandidate: Codable, Equatable {
    let pose: PriorMapPose2D
    let cost: Double
    let score: Double
}

struct PriorMapScanMatchResult {
    let candidates: [PriorMapScanMatchCandidate]
    let uniqueness: Double
    let effectivePointCount: Int
    let acceptedByGeometry: Bool
    let rejectionReason: String
    let elapsedMs: Double
}

private struct DecodedDistanceLevel {
    let resolutionM: Double
    let origin: SIMD2<Double>
    let width: Int
    let height: Int
    let values: [UInt8]
    let truncationM: Double

    func distance(xM: Double, yM: Double) -> Double {
        let x = Int(floor((xM - origin.x) / resolutionM))
        let y = Int(floor((yM - origin.y) / resolutionM))
        guard x >= 0, y >= 0, x < width, y < height else {
            return truncationM
        }
        return min(truncationM, Double(values[y * width + x]) / 100.0)
    }
}

final class PriorMapScanMatcher {
    private let levels: [DecodedDistanceLevel]
    private let maximumPoints = 600

    init(floor: PriorMapDistanceFieldFloor, truncationM: Double) throws {
        levels = try floor.levels
            .sorted { $0.resolutionM > $1.resolutionM }
            .map {
                DecodedDistanceLevel(
                    resolutionM: $0.resolutionM,
                    origin: SIMD2<Double>($0.originM[0], $0.originM[1]),
                    width: $0.width,
                    height: $0.height,
                    values: try $0.decodedValues(),
                    truncationM: truncationM)
            }
        guard levels.count == 3,
              abs(levels[0].resolutionM - 0.40) < 1.0e-9,
              abs(levels[1].resolutionM - 0.20) < 1.0e-9,
              abs(levels[2].resolutionM - 0.10) < 1.0e-9 else {
            throw NSError(
                domain: "PriorMapScanMatcher",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "地图包缺少 0.40/0.20/0.10 m 多分辨率距离场。"])
        }
    }

    private func transformed(
        _ point: SIMD2<Double>,
        pose: PriorMapPose2D
    ) -> SIMD2<Double> {
        let cosine = cos(pose.yawRad)
        let sine = sin(pose.yawRad)
        return SIMD2<Double>(
            pose.xM + cosine * point.x - sine * point.y,
            pose.yM + sine * point.x + cosine * point.y)
    }

    private func cost(
        pose: PriorMapPose2D,
        points: [SIMD2<Double>],
        level: DecodedDistanceLevel
    ) -> Double {
        guard !points.isEmpty else { return level.truncationM * level.truncationM }
        var total = 0.0
        let robustLimit = 0.45
        for point in points {
            let mapPoint = transformed(point, pose: pose)
            let distance = level.distance(xM: mapPoint.x, yM: mapPoint.y)
            let bounded = min(distance, robustLimit)
            total += bounded * bounded
        }
        return total / Double(points.count)
    }

    private func search(
        around center: PriorMapPose2D,
        points: [SIMD2<Double>],
        level: DecodedDistanceLevel,
        translationRadius: Double,
        translationStep: Double,
        yawRadiusDegrees: Double,
        yawStepDegrees: Double
    ) -> [PriorMapScanMatchCandidate] {
        var values: [PriorMapScanMatchCandidate] = []
        let translationSteps = Int(floor(translationRadius / translationStep))
        let yawSteps = Int(floor(yawRadiusDegrees / yawStepDegrees))
        for xIndex in -translationSteps...translationSteps {
            for yIndex in -translationSteps...translationSteps {
                for yawIndex in -yawSteps...yawSteps {
                    let pose = PriorMapPose2D(
                        xM: center.xM + Double(xIndex) * translationStep,
                        yM: center.yM + Double(yIndex) * translationStep,
                        yawRad: PriorMapStageOneMath.normalizeAngle(
                            center.yawRad
                                + Double(yawIndex)
                                * yawStepDegrees * .pi / 180.0))
                    let value = cost(pose: pose, points: points, level: level)
                    values.append(
                        PriorMapScanMatchCandidate(
                            pose: pose,
                            cost: value,
                            score: exp(-value / 0.08)))
                }
            }
        }
        return values.sorted { first, second in
            if first.cost != second.cost {
                return first.cost < second.cost
            }
            if first.pose.xM != second.pose.xM {
                return first.pose.xM < second.pose.xM
            }
            if first.pose.yM != second.pose.yM {
                return first.pose.yM < second.pose.yM
            }
            return first.pose.yawRad < second.pose.yawRad
        }
    }

    func match(
        predictedPose: PriorMapPose2D,
        observation: PriorMapStructureObservation
    ) -> PriorMapScanMatchResult {
        let started = ProcessInfo.processInfo.systemUptime
        let strideValue = max(1, observation.points.count / maximumPoints)
        let points = observation.points.enumerated().compactMap {
            $0.offset % strideValue == 0 ? $0.element : nil
        }
        guard points.count >= 30 else {
            return PriorMapScanMatchResult(
                candidates: [],
                uniqueness: 0,
                effectivePointCount: points.count,
                acceptedByGeometry: false,
                rejectionReason: "insufficient_structure_points",
                elapsedMs: (ProcessInfo.processInfo.systemUptime - started) * 1000.0)
        }
        let coarse = search(
            around: predictedPose,
            points: points,
            level: levels[0],
            translationRadius: 1.2,
            translationStep: max(0.4, levels[0].resolutionM),
            yawRadiusDegrees: 12,
            yawStepDegrees: 4)
        let mediumCenter = coarse.first?.pose ?? predictedPose
        let medium = search(
            around: mediumCenter,
            points: points,
            level: levels[min(1, levels.count - 1)],
            translationRadius: 0.4,
            translationStep: 0.2,
            yawRadiusDegrees: 4,
            yawStepDegrees: 2)
        let fineCenter = medium.first?.pose ?? mediumCenter
        let fine = search(
            around: fineCenter,
            points: points,
            level: levels.last!,
            translationRadius: 0.2,
            translationStep: 0.1,
            yawRadiusDegrees: 2,
            yawStepDegrees: 1)
        var top: [PriorMapScanMatchCandidate] = []
        for candidate in fine {
            let separated = top.allSatisfy {
                hypot(
                    candidate.pose.xM - $0.pose.xM,
                    candidate.pose.yM - $0.pose.yM) >= 0.25
                    || abs(PriorMapStageOneMath.normalizeAngle(
                        candidate.pose.yawRad - $0.pose.yawRad)) >= 4.0 * .pi / 180.0
            }
            if separated {
                top.append(candidate)
            }
            if top.count == 3 {
                break
            }
        }
        let bestCost = top.first?.cost ?? Double.infinity
        let secondCost = top.dropFirst().first?.cost ?? bestCost + 0.2
        let uniqueness = max(
            0,
            min(1, (secondCost - bestCost) / max(secondCost, 0.01)))
        let accepted = points.count >= 45
            && observation.coverageAngleRad >= 0.35
            && bestCost <= 0.10
            && uniqueness >= 0.10
        let reason: String
        if observation.coverageAngleRad < 0.35 {
            reason = "insufficient_angular_coverage"
        }
        else if bestCost > 0.10 {
            reason = "map_mismatch"
        }
        else if uniqueness < 0.10 {
            reason = "ambiguous_structure_match"
        }
        else {
            reason = "geometry_candidate"
        }
        return PriorMapScanMatchResult(
            candidates: top,
            uniqueness: uniqueness,
            effectivePointCount: points.count,
            acceptedByGeometry: accepted,
            rejectionReason: reason,
            elapsedMs: (ProcessInfo.processInfo.systemUptime - started) * 1000.0)
    }
}

enum PriorMapLocalizationPhase: String, Codable {
    case uninitialized
    case initializing
    case stable
    case usable
    case weak
    case lost
    case manualCorrection
}

struct PriorMapConfidenceResult {
    let phase: PriorMapLocalizationPhase
    let confidence: Double
}

final class PriorMapConfidenceManager {
    private(set) var phase: PriorMapLocalizationPhase = .uninitialized
    private var consecutiveTrusted = 0
    private var consecutiveRejected = 0
    private var lastAcceptedTimestamp: TimeInterval?

    func reset(manual: Bool = false) {
        phase = manual ? .manualCorrection : .initializing
        consecutiveTrusted = 0
        consecutiveRejected = 0
        lastAcceptedTimestamp = nil
    }

    func update(
        timestamp: TimeInterval,
        trackingState: String,
        accepted: Bool,
        validPointCount: Int,
        coverageAngleRad: Double,
        uniqueness: Double,
        residualCost: Double,
        mapMismatch: Bool
    ) -> PriorMapConfidenceResult {
        if trackingState == "notAvailable" {
            phase = .lost
            consecutiveTrusted = 0
            return PriorMapConfidenceResult(phase: phase, confidence: 0)
        }
        if accepted {
            consecutiveTrusted += 1
            consecutiveRejected = 0
            lastAcceptedTimestamp = timestamp
        }
        else {
            consecutiveRejected += 1
            consecutiveTrusted = 0
        }
        let staleSeconds = lastAcceptedTimestamp.map { max(0, timestamp - $0) }
            ?? Double.infinity
        if lastAcceptedTimestamp == nil {
            phase = consecutiveRejected >= 3 ? .weak : .initializing
        }
        else if staleSeconds > 10 {
            phase = .lost
        }
        else if trackingState != "normal"
            || staleSeconds > 4
            || consecutiveRejected >= 3
            || mapMismatch {
            phase = .weak
        }
        else if accepted
            && consecutiveTrusted >= 3
            && validPointCount >= 80
            && uniqueness >= 0.22 {
            phase = .stable
        }
        else if accepted || staleSeconds <= 4 {
            phase = .usable
        }
        else {
            phase = .initializing
        }
        let trackingScore = trackingState == "normal" ? 1.0 : 0.35
        let pointScore = min(1, Double(validPointCount) / 120.0)
        let coverageScore = min(1, coverageAngleRad / 1.4)
        let uniquenessScore = min(1, uniqueness / 0.35)
        let residualScore = max(0, 1 - residualCost / 0.15)
        let freshnessScore = staleSeconds.isFinite
            ? max(0, 1 - staleSeconds / 10.0)
            : 0
        let confidence = max(
            0,
            min(
                1,
                0.20 * trackingScore
                    + 0.18 * pointScore
                    + 0.12 * coverageScore
                    + 0.22 * uniquenessScore
                    + 0.18 * residualScore
                    + 0.10 * freshnessScore))
        return PriorMapConfidenceResult(phase: phase, confidence: confidence)
    }
}
