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
    let floorEstimate: PriorMapFloorEstimate?
    let source: String
}

struct PriorMapFloorSample {
    let heightWorldM: Double
    let relativeHeightM: Double
    let upAlignment: Double
}

struct PriorMapFloorEstimate {
    let heightWorldM: Double
    let confidence: Double
    let inlierRatio: Double
    let residualM: Double
    let sampleCount: Int
    let stableFrameCount: Int
}

final class PriorMapFloorPlaneEstimator {
    private var filteredHeight: Double?
    private var stableFrameCount = 0

    func reset() {
        filteredHeight = nil
        stableFrameCount = 0
    }

    func update(samples: [PriorMapFloorSample]) -> PriorMapFloorEstimate? {
        let horizontal = samples.filter {
            $0.heightWorldM.isFinite
                && $0.relativeHeightM <= -1.0
                && $0.relativeHeightM >= -2.30
                && $0.upAlignment.isFinite
                && $0.upAlignment >= 0.88
        }
        guard horizontal.count >= 16 else { return nil }
        let heights = horizontal.map(\.heightWorldM).sorted()
        // The floor is normally the lowest persistent horizontal surface in
        // view. A lower quantile seed avoids letting carts or low shelves
        // dominate a simple global median.
        let seed = heights[min(heights.count - 1, heights.count / 5)]
        let inliers = horizontal.filter {
            abs($0.heightWorldM - seed) <= 0.06
        }
        guard inliers.count >= 12 else { return nil }
        let orderedInliers = inliers.map(\.heightWorldM).sorted()
        let rawHeight = orderedInliers[orderedInliers.count / 2]
        let deviations = orderedInliers.map { abs($0 - rawHeight) }.sorted()
        let residual = deviations[deviations.count / 2]
        let inlierRatio = Double(inliers.count) / Double(horizontal.count)
        guard residual <= 0.035, inlierRatio >= 0.20 else { return nil }

        let height: Double
        if let previous = filteredHeight {
            let delta = rawHeight - previous
            if abs(delta) <= 0.10 {
                stableFrameCount += 1
            }
            else {
                stableFrameCount = 1
            }
            // Preserve slow floor changes within one floor while preventing a
            // transient low object from instantly redefining tag height.
            height = previous + min(0.03, max(-0.03, delta))
        }
        else {
            stableFrameCount = 1
            height = rawHeight
        }
        filteredHeight = height
        let normalScore = inliers.map(\.upAlignment).reduce(0, +)
            / Double(inliers.count)
        let residualScore = max(0, 1 - residual / 0.035)
        let supportScore = min(1, Double(inliers.count) / 80.0)
        let stabilityScore = min(1, Double(stableFrameCount) / 5.0)
        let confidence = min(
            1,
            0.25 * normalScore
                + 0.25 * residualScore
                + 0.20 * supportScore
                + 0.15 * min(1, inlierRatio / 0.60)
                + 0.15 * stabilityScore)
        return PriorMapFloorEstimate(
            heightWorldM: height,
            confidence: confidence,
            inlierRatio: inlierRatio,
            residualM: residual,
            sampleCount: inliers.count,
            stableFrameCount: stableFrameCount)
    }
}

struct PriorMapScanMatchCandidate: Codable, Equatable {
    let pose: PriorMapPose2D
    let cost: Double
    let score: Double
}

enum PriorMapScanAttemptDisposition: String, Codable, Equatable {
    case notSearchedInsufficientPoints = "not_searched_insufficient_points"
    case searched
}

struct PriorMapScanMatchResult {
    let candidates: [PriorMapScanMatchCandidate]
    let uniqueness: Double
    let effectivePointCount: Int
    let acceptedByGeometry: Bool
    let rejectionReason: String
    let elapsedMs: Double
    let attemptDisposition: PriorMapScanAttemptDisposition

    var searchPerformed: Bool {
        attemptDisposition == .searched
    }
}

struct PriorMapHypothesisDecision {
    let candidate: PriorMapScanMatchCandidate?
    let mapFromArkit: PriorMapAlignmentTransform?
    let selectedHypothesisId: Int?
    let activeTrackCount: Int
    let bestCost: Double?
    let secondCost: Double?
    let trackerElapsedMs: Double
    let supportFrames: Int
    let scoreMargin: Double
    let trusted: Bool
    let reason: String
}

/// Tracks map-alignment corrections instead of selecting a fresh best aisle on
/// every frame. Periodic shelves can produce several equally good basins; only
/// a basin that remains motion-consistent and separates from its competitors is
/// allowed to move the map/ARKit alignment.
final class PriorMapHypothesisTracker {
    private enum Limits {
        static let candidateCount = 5
        static let trackCount = 8
        static let maximumMissedFrames = 3
        static let associationTranslationM = 0.75
        static let associationYawRad = 12.0 * Double.pi / 180.0
        static let smoothingGain = 0.35
        static let localRequiredFrames = 3
        static let recoveryRequiredFrames = 4
        static let minimumMeanScore = 0.25
        static let minimumUniqueness = 0.10
        static let minimumScoreMargin = 0.12
        static let supportFrameCap = 120
    }

    private struct Track {
        let id: Int
        var mapFromArkit: PriorMapAlignmentTransform
        var candidate: PriorMapScanMatchCandidate
        var supportFrames: Int
        var missedFrames: Int
        var meanScore: Double
    }

    private var tracks: [Track] = []
    private var nextTrackId = 1
    private var activeRecoveryEpisodeId: Int?

    private func clearTracks() {
        tracks.removeAll()
        nextTrackId = 1
    }

    func reset() {
        clearTracks()
        activeRecoveryEpisodeId = nil
    }

    /// Recovery V1 intentionally discards lifetime local support. The currently
    /// applied map/ARKit anchor lives in the localizer, so clearing hypotheses
    /// cannot move the HUD; it only requires four fresh observations to move it.
    func beginRecoveryEpisode(id: Int) {
        clearTracks()
        activeRecoveryEpisodeId = id
    }

    /// All wide-search hypotheses are temporary. The selected alignment has
    /// already been applied to the localizer anchor before a converged exit.
    func endRecoveryEpisode(id: Int, outcome _: PriorMapRecoveryOutcome) {
        guard activeRecoveryEpisodeId == id else { return }
        clearTracks()
        activeRecoveryEpisodeId = nil
    }

    func observe(
        arkitPose: PriorMapPose2D,
        candidates: [PriorMapScanMatchCandidate],
        uniqueness: Double,
        recoverySearch: Bool
    ) -> PriorMapHypothesisDecision {
        let start = ProcessInfo.processInfo.systemUptime
        var updated = Set<Int>()
        for candidate in candidates.prefix(Limits.candidateCount) {
            let mapFromArkit = PriorMapAlignmentMath.mapFromArkit(
                arkitPose: arkitPose,
                candidateMapPose: candidate.pose)
            var matchIndex: Int?
            var matchDistance = Double.infinity
            for index in tracks.indices where !updated.contains(index) {
                let translation = hypot(
                    mapFromArkit.translationXM
                        - tracks[index].mapFromArkit.translationXM,
                    mapFromArkit.translationYM
                        - tracks[index].mapFromArkit.translationYM)
                let yaw = abs(PriorMapStageOneMath.normalizeAngle(
                    mapFromArkit.yawRad
                        - tracks[index].mapFromArkit.yawRad))
                let combined = translation + yaw
                if translation <= Limits.associationTranslationM,
                   yaw <= Limits.associationYawRad,
                   combined < matchDistance {
                    matchIndex = index
                    matchDistance = combined
                }
            }
            if let index = matchIndex {
                tracks[index].mapFromArkit = PriorMapAlignmentMath.interpolate(
                    from: tracks[index].mapFromArkit,
                    to: mapFromArkit,
                    gain: Limits.smoothingGain)
                tracks[index].candidate = candidate
                tracks[index].supportFrames = min(
                    Limits.supportFrameCap,
                    tracks[index].supportFrames + 1)
                tracks[index].missedFrames = 0
                tracks[index].meanScore = tracks[index].meanScore * 0.7
                    + candidate.score * 0.3
                updated.insert(index)
            }
            else {
                tracks.append(
                    Track(
                        id: nextTrackId,
                        mapFromArkit: mapFromArkit,
                        candidate: candidate,
                        supportFrames: 1,
                        missedFrames: 0,
                        meanScore: candidate.score))
                nextTrackId += 1
                updated.insert(tracks.count - 1)
            }
        }
        for index in tracks.indices where !updated.contains(index) {
            tracks[index].missedFrames += 1
        }
        tracks = tracks.filter {
            $0.missedFrames <= Limits.maximumMissedFrames
        }
            .sorted { first, second in
                if first.supportFrames != second.supportFrames {
                    return first.supportFrames > second.supportFrames
                }
                if first.meanScore != second.meanScore {
                    return first.meanScore > second.meanScore
                }
                if first.candidate.cost != second.candidate.cost {
                    return first.candidate.cost < second.candidate.cost
                }
                return first.id < second.id
            }
        if tracks.count > Limits.trackCount {
            tracks.removeLast(tracks.count - Limits.trackCount)
        }
        let activeTracks = tracks.filter { $0.missedFrames == 0 }
        guard let best = activeTracks.first else {
            return PriorMapHypothesisDecision(
                candidate: nil,
                mapFromArkit: nil,
                selectedHypothesisId: nil,
                activeTrackCount: 0,
                bestCost: nil,
                secondCost: nil,
                trackerElapsedMs:
                    (ProcessInfo.processInfo.systemUptime - start) * 1000,
                supportFrames: 0,
                scoreMargin: 0,
                trusted: false,
                reason: "no_hypothesis")
        }
        let second = activeTracks.dropFirst().first
        let supportMargin = second.map {
            Double(best.supportFrames - $0.supportFrames) * 0.05
        } ?? 0
        let scoreMargin = max(
            0,
            min(1, best.meanScore - (second?.meanScore ?? best.meanScore) + supportMargin))
        let requiredFrames = recoverySearch
            ? Limits.recoveryRequiredFrames : Limits.localRequiredFrames
        let recoveryEpisodeIsActive = !recoverySearch
            || activeRecoveryEpisodeId != nil
        let trusted = recoveryEpisodeIsActive
            && best.supportFrames >= requiredFrames
            && best.meanScore >= Limits.minimumMeanScore
            && (uniqueness >= Limits.minimumUniqueness
                || scoreMargin >= Limits.minimumScoreMargin)
        return PriorMapHypothesisDecision(
            candidate: best.candidate,
            mapFromArkit: best.mapFromArkit,
            selectedHypothesisId: best.id,
            activeTrackCount: activeTracks.count,
            bestCost: best.candidate.cost,
            secondCost: second?.candidate.cost,
            trackerElapsedMs:
                (ProcessInfo.processInfo.systemUptime - start) * 1000,
            supportFrames: best.supportFrames,
            scoreMargin: scoreMargin,
            trusted: trusted,
            reason: trusted
                ? (recoverySearch ? "trusted_recovery_hypothesis" : "trusted_local_hypothesis")
                : recoverySearch && activeRecoveryEpisodeId == nil
                    ? "recovery_episode_not_started"
                    : "awaiting_unique_temporal_hypothesis")
    }
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
    static let minimumSearchPointCount = 30

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

    private func separatedCandidates(
        _ candidates: [PriorMapScanMatchCandidate],
        limit: Int,
        translationSeparationM: Double = 0.25,
        yawSeparationDegrees: Double = 4
    ) -> [PriorMapScanMatchCandidate] {
        var selected: [PriorMapScanMatchCandidate] = []
        let yawSeparation = yawSeparationDegrees * .pi / 180.0
        for candidate in candidates {
            let independent = selected.allSatisfy {
                hypot(
                    candidate.pose.xM - $0.pose.xM,
                    candidate.pose.yM - $0.pose.yM) >= translationSeparationM
                    || abs(PriorMapStageOneMath.normalizeAngle(
                        candidate.pose.yawRad - $0.pose.yawRad)) >= yawSeparation
            }
            if independent {
                selected.append(candidate)
            }
            if selected.count == limit {
                break
            }
        }
        return selected
    }

    private func refine(
        centers: [PriorMapScanMatchCandidate],
        fallback: PriorMapPose2D,
        points: [SIMD2<Double>],
        level: DecodedDistanceLevel,
        translationRadius: Double,
        translationStep: Double,
        yawRadiusDegrees: Double,
        yawStepDegrees: Double,
        hypothesisLimit: Int
    ) -> [PriorMapScanMatchCandidate] {
        let poses = centers.isEmpty
            ? [fallback]
            : centers.map(\.pose)
        let expanded = poses.flatMap {
            search(
                around: $0,
                points: points,
                level: level,
                translationRadius: translationRadius,
                translationStep: translationStep,
                yawRadiusDegrees: yawRadiusDegrees,
                yawStepDegrees: yawStepDegrees)
        }.sorted {
            if $0.cost != $1.cost {
                return $0.cost < $1.cost
            }
            if $0.pose.xM != $1.pose.xM {
                return $0.pose.xM < $1.pose.xM
            }
            if $0.pose.yM != $1.pose.yM {
                return $0.pose.yM < $1.pose.yM
            }
            return $0.pose.yawRad < $1.pose.yawRad
        }
        return separatedCandidates(expanded, limit: hypothesisLimit)
    }

    func match(
        predictedPose: PriorMapPose2D,
        observation: PriorMapStructureObservation,
        recoverySearch: Bool = false
    ) -> PriorMapScanMatchResult {
        let started = ProcessInfo.processInfo.systemUptime
        let strideValue = max(1, observation.points.count / maximumPoints)
        let points = observation.points.enumerated().compactMap {
            $0.offset % strideValue == 0 ? $0.element : nil
        }
        guard points.count >= Self.minimumSearchPointCount else {
            return PriorMapScanMatchResult(
                candidates: [],
                uniqueness: 0,
                effectivePointCount: points.count,
                acceptedByGeometry: false,
                rejectionReason: "insufficient_structure_points",
                elapsedMs: (ProcessInfo.processInfo.systemUptime - started) * 1000.0,
                attemptDisposition: .notSearchedInsufficientPoints)
        }
        let coarse = search(
            around: predictedPose,
            points: points,
            level: levels[0],
            translationRadius: recoverySearch ? 5.0 : 1.2,
            translationStep: recoverySearch
                ? 0.8
                : max(0.4, levels[0].resolutionM),
            yawRadiusDegrees: recoverySearch ? 30 : 12,
            yawStepDegrees: recoverySearch ? 10 : 4)
        // Preserve spatially independent basins at every level. Selecting only
        // the best coarse basin makes periodic aisles appear falsely unique.
        let coarseHypotheses = separatedCandidates(
            coarse,
            limit: 8,
            translationSeparationM: 0.35)
        let medium = refine(
            centers: coarseHypotheses,
            fallback: predictedPose,
            points: points,
            level: levels[min(1, levels.count - 1)],
            translationRadius: recoverySearch ? 0.5 : 0.4,
            translationStep: 0.2,
            yawRadiusDegrees: recoverySearch ? 6 : 4,
            yawStepDegrees: 2,
            hypothesisLimit: 8)
        let fine = refine(
            centers: medium,
            fallback: predictedPose,
            points: points,
            level: levels.last!,
            translationRadius: 0.2,
            translationStep: 0.1,
            yawRadiusDegrees: 2,
            yawStepDegrees: 1,
            hypothesisLimit: 8)
        let top = Array(fine.prefix(5))
        let bestCost = top.first?.cost ?? Double.infinity
        let secondCost = top.dropFirst().first?.cost
        // A missing second independent minimum is absence of evidence, not
        // proof of uniqueness. Fail closed instead of synthesizing a cost.
        let uniqueness = secondCost.map {
            max(0, min(1, ($0 - bestCost) / max($0, 0.01)))
        } ?? 0
        let accepted = points.count >= 45
            && observation.coverageAngleRad >= 0.35
            && bestCost <= 0.10
            && secondCost != nil
            && uniqueness >= 0.10
        let reason: String
        if observation.coverageAngleRad < 0.35 {
            reason = "insufficient_angular_coverage"
        }
        else if bestCost > 0.10 {
            reason = "map_mismatch"
        }
        else if secondCost == nil || uniqueness < 0.10 {
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
            elapsedMs: (ProcessInfo.processInfo.systemUptime - started) * 1000.0,
            attemptDisposition: .searched)
    }
}

enum PriorMapLocalizationPhase: String, Codable {
    case uninitialized
    case initializing
    case stable
    case usable
    case recovering
    case weak
    case lost
    case manualCorrection
}

struct PriorMapConfidenceResult {
    let phase: PriorMapLocalizationPhase
    let confidence: Double
}

struct PriorMapConfidenceObservation {
    let trackingState: String
    let measurementAccepted: Bool
    let correctionStepApplied: Bool
    let recoveryActive: Bool
    let recoveryConvergedThisUpdate: Bool
    let recoveryFailedThisUpdate: Bool
    let validPointCount: Int
    let coverageAngleRad: Double
    let uniqueness: Double
    let residualCost: Double
    let mapMismatch: Bool
}

final class PriorMapConfidenceManager {
    private(set) var phase: PriorMapLocalizationPhase = .uninitialized
    private var consecutiveTrusted = 0
    private var consecutiveRejected = 0
    private var lastAcceptedTimestamp: TimeInterval?
    private(set) var postRecoveryTrustedLocalFrames = 0
    private var requiresPostRecoveryLocalTrust = false

    func reset(manual: Bool = false) {
        phase = manual ? .manualCorrection : .initializing
        consecutiveTrusted = 0
        consecutiveRejected = 0
        lastAcceptedTimestamp = nil
        postRecoveryTrustedLocalFrames = 0
        requiresPostRecoveryLocalTrust = false
    }

    func update(
        timestamp: TimeInterval,
        observation: PriorMapConfidenceObservation
    ) -> PriorMapConfidenceResult {
        if observation.trackingState == "notAvailable" {
            phase = .lost
            consecutiveTrusted = 0
            postRecoveryTrustedLocalFrames = 0
            return PriorMapConfidenceResult(phase: phase, confidence: 0)
        }
        if observation.recoveryFailedThisUpdate {
            phase = .weak
            consecutiveTrusted = 0
            consecutiveRejected += 1
            postRecoveryTrustedLocalFrames = 0
            return PriorMapConfidenceResult(
                phase: phase,
                confidence: min(
                    0.55,
                    confidenceScore(
                        timestamp: timestamp,
                        observation: observation)))
        }
        if observation.recoveryActive
            && !observation.recoveryConvergedThisUpdate {
            consecutiveTrusted = 0
            consecutiveRejected += 1
            postRecoveryTrustedLocalFrames = 0
            phase = .recovering
            return PriorMapConfidenceResult(
                phase: phase,
                confidence: min(
                    0.55,
                    confidenceScore(
                        timestamp: timestamp,
                        observation: observation)))
        }
        if observation.recoveryConvergedThisUpdate {
            requiresPostRecoveryLocalTrust = true
            postRecoveryTrustedLocalFrames = 0
            consecutiveTrusted = 0
            consecutiveRejected = 0
            lastAcceptedTimestamp = timestamp
            phase = .usable
            return PriorMapConfidenceResult(
                phase: phase,
                confidence: min(
                    0.79,
                    confidenceScore(
                        timestamp: timestamp,
                        observation: observation)))
        }
        if observation.measurementAccepted {
            consecutiveTrusted += 1
            consecutiveRejected = 0
            lastAcceptedTimestamp = timestamp
            if requiresPostRecoveryLocalTrust {
                postRecoveryTrustedLocalFrames += 1
            }
        }
        else {
            consecutiveRejected += 1
            consecutiveTrusted = 0
            if requiresPostRecoveryLocalTrust {
                postRecoveryTrustedLocalFrames = 0
            }
        }
        let staleSeconds = lastAcceptedTimestamp.map { max(0, timestamp - $0) }
            ?? Double.infinity
        if lastAcceptedTimestamp == nil {
            phase = consecutiveRejected >= 3 ? .weak : .initializing
        }
        else if staleSeconds > 10 {
            phase = .lost
        }
        else if observation.trackingState != "normal"
            || staleSeconds > 4
            || consecutiveRejected >= 3
            || observation.mapMismatch {
            phase = .weak
        }
        else if observation.measurementAccepted
            && consecutiveTrusted >= 3
            && observation.validPointCount >= 80
            && observation.uniqueness >= 0.22
            && (!requiresPostRecoveryLocalTrust
                || postRecoveryTrustedLocalFrames >= 3) {
            phase = .stable
            requiresPostRecoveryLocalTrust = false
        }
        else if observation.measurementAccepted || staleSeconds <= 4 {
            phase = .usable
        }
        else {
            phase = .initializing
        }
        let confidence = confidenceScore(
            timestamp: timestamp,
            observation: observation)
        return PriorMapConfidenceResult(phase: phase, confidence: confidence)
    }

    private func confidenceScore(
        timestamp: TimeInterval,
        observation: PriorMapConfidenceObservation
    ) -> Double {
        let staleSeconds = lastAcceptedTimestamp.map { max(0, timestamp - $0) }
            ?? Double.infinity
        let trackingScore = observation.trackingState == "normal" ? 1.0 : 0.35
        let pointScore = min(1, Double(observation.validPointCount) / 120.0)
        let coverageScore = min(1, observation.coverageAngleRad / 1.4)
        let uniquenessScore = min(1, observation.uniqueness / 0.35)
        let residualScore = max(0, 1 - observation.residualCost / 0.15)
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
        return confidence
    }
}
