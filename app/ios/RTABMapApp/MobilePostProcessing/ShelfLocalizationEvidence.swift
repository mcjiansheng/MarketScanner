import Foundation

/// Frozen shelf/corridor localization product contract (2026-08-15).
///
/// C-1/C-2/C-3 values are implementation starting points only. They remain
/// CALIBRATION_PENDING until a signed LiDAR device run freezes them in the
/// product specification; callers must expose that status in quality output.
enum ShelfLocalizationPolicy {
    /// v2 is retained for already-finalized manifest-v5 sessions. Its
    /// aggregate bridge counters are diagnostic-only and never authorize a
    /// cross-epoch shelf loop. v3 adds the native node-pair witnesses needed
    /// for a formally checkable bridge.
    static let contractVersion = 3
    static let supportedContractVersions = 2...contractVersion
    static let calibrationStatus = "CALIBRATION_PENDING"

    // S-7 / S-11 / S-12 are frozen product values, not calibration knobs.
    static let maximumPhoneShelfPenetrationM = 0.4
    static let maximumOnlineCorrectionStepM = 0.25
    static let manualAnchorTranslationSigmaM = 3.0
    static let manualAnchorYawSigmaRad = 15.0 * Double.pi / 180.0
    static let maximumPublishedShelfNormalResidualM = 0.5

    // C-1/C-2/C-3 initial values. Keep the marker in the names and reports.
    static let calibrationPendingLoopTranslationM = 0.5
    static let calibrationPendingLoopYawRad = 10.0 * Double.pi / 180.0
    static let calibrationPendingLoopInlierRatio = 0.70
    static let calibrationPendingMinimumOpposingNormalRad =
        120.0 * Double.pi / 180.0
    static let calibrationPendingLowConfidenceMargin = 0.15
    // C-1 starting values. They remain publication-ineligible until a signed
    // LiDAR field run freezes the calibration revision.
    static let calibrationPendingGeometryInlierResidualM = 0.20
    static let calibrationPendingGeometryScoreScaleM = 0.25
    // Broad candidate-only bound; it cannot accept or publish a shelf loop.
    static let maximumShelfGeometryCandidateResidualM = 0.75
    // Require structural evidence to be present without inventing another
    // field-calibration threshold beyond C-1/C-2/C-3.
    static let minimumPresentStructureBasinScore = 1.0e-9
    static let calibrationPendingReliableLoopDistanceM = 30.0
    static let calibrationPendingDynamicPersistenceSeconds = 10.0

    /// C-3a map-anchored static occluder classification (2026-09-03
    /// redesign). Scanning advances along a shelf at ~1-2 m/s, so a standing
    /// customer or parked cart occludes its shelf for the entire pass and
    /// occlusion duration carries no information. The prior map is
    /// authoritative (S-1): an interior observation gap along a mapped
    /// continuous shelf bounded by observations on both sides is a static
    /// occluder and the shelf behind it is presumed present but unobserved.
    /// Interior gaps below the minimum width are sampling noise; gaps above
    /// the maximum width get no presence assertion. Moving customers remain
    /// handled by the temporal `DynamicShelfEvidenceFilter` below. Parity
    /// implementation: `tools/PriorMap/shelf_occlusion_classifier.py`.
    static let mapAnchoredStaticOccluderMinGapM = 0.3
    static let mapAnchoredStaticOccluderMaxGapM = 2.5

    static let maximumCorridorHypotheses = 24
    static let maximumShelfCandidates = 24
    static let maximumBridgeEvidence = 16
    static let maximumBridgeLinks = 16

    static func isLowercaseSHA256(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
        }
    }
}

struct ShelfEvidenceTransform: Codable, Equatable {
    let dxM: Double
    let dyM: Double
    let dyawRad: Double

    enum CodingKeys: String, CodingKey {
        case dxM = "dx_m"
        case dyM = "dy_m"
        case dyawRad = "dyaw_rad"
    }

    var isFinite: Bool { dxM.isFinite && dyM.isFinite && dyawRad.isFinite }
}

struct PoseEpochBridgeEvidence: Codable, Equatable {
    let type: String
    let independentNodePairs: Int
    let consensusInlierRatio: Double
    let component: Int64?
    let consensusTransform: ShelfEvidenceTransform?
    let links: [PoseEpochBridgeLinkEvidence]?

    enum CodingKeys: String, CodingKey {
        case type
        case independentNodePairs = "independent_node_pairs"
        case consensusInlierRatio = "consensus_inlier_ratio"
        case component
        case consensusTransform = "consensus_transform"
        case links
    }
}

struct PoseEpochBridgeLinkEvidence: Codable, Equatable {
    let fromNodeID: Int64
    let toNodeID: Int64
    let fromEpoch: Int
    let toEpoch: Int
    let fromComponent: Int64
    let toComponent: Int64
    let nativeLinkType: String
    let measurement: ShelfEvidenceTransform
    let bridgeTransform: ShelfEvidenceTransform
    let consensusInlier: Bool

    enum CodingKeys: String, CodingKey {
        case fromNodeID = "from_node_id"
        case toNodeID = "to_node_id"
        case fromEpoch = "from_epoch"
        case toEpoch = "to_epoch"
        case fromComponent = "from_component"
        case toComponent = "to_component"
        case nativeLinkType = "native_link_type"
        case measurement
        case bridgeTransform = "bridge_transform"
        case consensusInlier = "consensus_inlier"
    }
}

struct PoseEpochTransitionRecord: Codable, Equatable {
    static let fileName = "pose_epoch_transitions.jsonl"
    static let formatName = "MarketScannerPoseEpochTransition"

    let format: String
    let version: Int
    let trackingSessionID: String
    let sequence: Int
    let fromEpoch: Int
    let toEpoch: Int
    let beforeFrameTimestamp: TimeInterval
    let afterFrameTimestamp: TimeInterval
    let beforeNodeID: Int64
    let afterNodeID: Int64
    let fromComponent: Int64?
    let toComponent: Int64?
    let transform: ShelfEvidenceTransform
    let bridgeEvidence: [PoseEpochBridgeEvidence]
    let reason: String
    let writeWatermark: Int

    enum CodingKeys: String, CodingKey {
        case format, version, sequence, transform, reason
        case trackingSessionID = "tracking_session_id"
        case fromEpoch = "from_epoch"
        case toEpoch = "to_epoch"
        case beforeFrameTimestamp = "before_frame_timestamp"
        case afterFrameTimestamp = "after_frame_timestamp"
        case beforeNodeID = "before_node_id"
        case afterNodeID = "after_node_id"
        case fromComponent = "from_component"
        case toComponent = "to_component"
        case bridgeEvidence = "bridge_evidence"
        case writeWatermark = "write_watermark"
    }

    var isValid: Bool {
        let commonValid = format == Self.formatName
            && ShelfLocalizationPolicy.supportedContractVersions.contains(version)
            && !trackingSessionID.isEmpty && sequence >= 1
            && fromEpoch >= 0 && toEpoch == fromEpoch + 1
            && beforeFrameTimestamp.isFinite && afterFrameTimestamp.isFinite
            && afterFrameTimestamp >= beforeFrameTimestamp
            && beforeNodeID > 0 && afterNodeID > 0 && transform.isFinite
            && bridgeEvidence.count <= ShelfLocalizationPolicy.maximumBridgeEvidence
            && !reason.isEmpty && writeWatermark == sequence
        guard commonValid else { return false }
        if version == 2 {
            return fromComponent == nil && toComponent == nil
                && bridgeEvidence.allSatisfy {
                    $0.type == "multi_link_consensus"
                        && $0.independentNodePairs >= 2
                        && $0.consensusInlierRatio.isFinite
                        && (ShelfLocalizationPolicy
                            .calibrationPendingLoopInlierRatio...1.0)
                            .contains($0.consensusInlierRatio)
                        && $0.component == nil
                        && $0.consensusTransform == nil
                        && $0.links == nil
                }
        }
        guard let fromComponent, let toComponent,
              fromComponent >= 0, toComponent >= 0 else {
            return false
        }
        let bridgeComponents = bridgeEvidence.compactMap(\.component)
        return bridgeComponents.count == bridgeEvidence.count
            && Set(bridgeComponents).count == bridgeComponents.count
            && bridgeEvidence.reduce(0) {
                $0 + ($1.links?.count ?? 0)
            } <= ShelfLocalizationPolicy.maximumBridgeLinks
            && bridgeEvidence.allSatisfy {
                PoseEpochBridgeConsensus.isValid(
                    evidence: $0,
                    fromEpoch: fromEpoch,
                    toEpoch: toEpoch,
                    beforeNodeID: beforeNodeID,
                    afterNodeID: afterNodeID,
                    fromComponent: fromComponent,
                    toComponent: toComponent,
                    expectedTransform: transform)
            }
    }
}

/// Deterministic, cross-platform bridge consensus. The C-1 starting bounds
/// are used only to decide whether independent native links agree with the
/// recorded epoch transform. They do not make the calibration production-
/// qualified: CALIBRATION_PENDING remains a production publication blocker,
/// while Debug may use the same values for an explicitly-scoped TEST result.
enum PoseEpochBridgeConsensus {
    private struct Selection {
        let centerIndex: Int
        let inlierIndices: Set<Int>
    }

    static func makeEvidence(
        candidates: [PoseEpochBridgeLinkEvidence],
        fromEpoch: Int,
        toEpoch: Int,
        beforeNodeID: Int64,
        afterNodeID: Int64,
        fromComponent: Int64,
        toComponent: Int64,
        expectedTransform: ShelfEvidenceTransform
    ) -> PoseEpochBridgeEvidence? {
        let ordered = candidates.sorted {
            ($0.fromNodeID, $0.toNodeID) < ($1.fromNodeID, $1.toNodeID)
        }
        guard structurallyValid(
                links: ordered,
                fromEpoch: fromEpoch,
                toEpoch: toEpoch,
                beforeNodeID: beforeNodeID,
                afterNodeID: afterNodeID,
                component: fromComponent,
                fromComponent: fromComponent,
                toComponent: toComponent),
              let selection = selection(
                links: ordered,
                expectedTransform: expectedTransform) else {
            return nil
        }
        let inlierCount = selection.inlierIndices.count
        let ratio = Double(inlierCount) / Double(ordered.count)
        guard inlierCount >= 2,
              ratio >= ShelfLocalizationPolicy
                .calibrationPendingLoopInlierRatio else {
            return nil
        }
        let finalizedLinks = ordered.enumerated().map { index, link in
            PoseEpochBridgeLinkEvidence(
                fromNodeID: link.fromNodeID,
                toNodeID: link.toNodeID,
                fromEpoch: link.fromEpoch,
                toEpoch: link.toEpoch,
                fromComponent: link.fromComponent,
                toComponent: link.toComponent,
                nativeLinkType: link.nativeLinkType,
                measurement: link.measurement,
                bridgeTransform: link.bridgeTransform,
                consensusInlier: selection.inlierIndices.contains(index))
        }
        return PoseEpochBridgeEvidence(
            type: "multi_link_consensus",
            independentNodePairs: inlierCount,
            consensusInlierRatio: ratio,
            component: fromComponent,
            consensusTransform:
                ordered[selection.centerIndex].bridgeTransform,
            links: finalizedLinks)
    }

    static func isValid(
        evidence: PoseEpochBridgeEvidence,
        fromEpoch: Int,
        toEpoch: Int,
        beforeNodeID: Int64,
        afterNodeID: Int64,
        fromComponent: Int64,
        toComponent: Int64,
        expectedTransform: ShelfEvidenceTransform
    ) -> Bool {
        guard evidence.type == "multi_link_consensus",
              let component = evidence.component,
              let consensusTransform = evidence.consensusTransform,
              let links = evidence.links,
              consensusTransform.isFinite,
              structurallyValid(
                links: links,
                fromEpoch: fromEpoch,
                toEpoch: toEpoch,
                beforeNodeID: beforeNodeID,
                afterNodeID: afterNodeID,
                component: component,
                fromComponent: fromComponent,
                toComponent: toComponent),
              let selection = selection(
                links: links,
                expectedTransform: expectedTransform) else {
            return false
        }
        let expectedInlierCount = selection.inlierIndices.count
        let expectedRatio = Double(expectedInlierCount) / Double(links.count)
        guard expectedInlierCount >= 2,
              expectedRatio >= ShelfLocalizationPolicy
                .calibrationPendingLoopInlierRatio,
              evidence.independentNodePairs == expectedInlierCount,
              evidence.consensusInlierRatio.isFinite,
              abs(evidence.consensusInlierRatio - expectedRatio) <= 1.0e-12,
              transformEqual(
                consensusTransform,
                links[selection.centerIndex].bridgeTransform) else {
            return false
        }
        return links.enumerated().allSatisfy { index, link in
            link.consensusInlier == selection.inlierIndices.contains(index)
        }
    }

    static func agrees(
        _ first: ShelfEvidenceTransform,
        _ second: ShelfEvidenceTransform
    ) -> Bool {
        hypot(first.dxM - second.dxM, first.dyM - second.dyM)
                <= ShelfLocalizationPolicy.calibrationPendingLoopTranslationM
            && angularDistance(first.dyawRad, second.dyawRad)
                <= ShelfLocalizationPolicy.calibrationPendingLoopYawRad
    }

    private static func structurallyValid(
        links: [PoseEpochBridgeLinkEvidence],
        fromEpoch: Int,
        toEpoch: Int,
        beforeNodeID: Int64,
        afterNodeID: Int64,
        component: Int64,
        fromComponent: Int64,
        toComponent: Int64
    ) -> Bool {
        guard fromEpoch >= 0, toEpoch == fromEpoch + 1,
              beforeNodeID > 0, afterNodeID > 0,
              component >= 0,
              fromComponent == component,
              toComponent == component,
              (2...ShelfLocalizationPolicy.maximumBridgeLinks)
                .contains(links.count) else {
            return false
        }
        var pairs = Set<String>()
        var endpoints = Set<Int64>()
        var previousNodePair: (Int64, Int64)?
        for link in links {
            guard link.fromNodeID > 0,
                  link.toNodeID > 0,
                  link.fromNodeID != link.toNodeID,
                  link.fromNodeID <= beforeNodeID,
                  link.toNodeID >= afterNodeID,
                  link.fromEpoch == fromEpoch,
                  link.toEpoch == toEpoch,
                  link.fromComponent == component,
                  link.toComponent == component,
                  ["global_visual", "local_space"]
                    .contains(link.nativeLinkType),
                  link.measurement.isFinite,
                  link.bridgeTransform.isFinite else {
                return false
            }
            let nodePair = (link.fromNodeID, link.toNodeID)
            if let previousNodePair,
               nodePair < previousNodePair {
                return false
            }
            previousNodePair = nodePair
            let low = min(link.fromNodeID, link.toNodeID)
            let high = max(link.fromNodeID, link.toNodeID)
            let pair = "\(low):\(high)"
            guard pairs.insert(pair).inserted,
                  endpoints.insert(link.fromNodeID).inserted,
                  endpoints.insert(link.toNodeID).inserted else {
                return false
            }
        }
        return true
    }

    private static func selection(
        links: [PoseEpochBridgeLinkEvidence],
        expectedTransform: ShelfEvidenceTransform
    ) -> Selection? {
        guard expectedTransform.isFinite else { return nil }
        var best: (index: Int, count: Int, residual: Double)?
        for (centerIndex, center) in links.enumerated() {
            guard agrees(center.bridgeTransform, expectedTransform) else {
                continue
            }
            var inliers = Set<Int>()
            var residual = 0.0
            for (index, candidate) in links.enumerated() {
                let agreesWithExpected = agrees(
                    candidate.bridgeTransform, expectedTransform)
                let agreesWithCenter = agrees(
                    candidate.bridgeTransform, center.bridgeTransform)
                if agreesWithExpected && agreesWithCenter {
                    inliers.insert(index)
                }
                residual += normalizedResidual(
                    candidate.bridgeTransform,
                    center.bridgeTransform)
            }
            if let existing = best {
                if inliers.count < existing.count
                    || (inliers.count == existing.count
                        && residual >= existing.residual - 1.0e-12) {
                    continue
                }
            }
            best = (centerIndex, inliers.count, residual)
        }
        guard let best else { return nil }
        let center = links[best.index].bridgeTransform
        let inliers = Set(links.indices.filter {
            agrees(links[$0].bridgeTransform, expectedTransform)
                && agrees(links[$0].bridgeTransform, center)
        })
        return Selection(centerIndex: best.index, inlierIndices: inliers)
    }

    private static func normalizedResidual(
        _ first: ShelfEvidenceTransform,
        _ second: ShelfEvidenceTransform
    ) -> Double {
        hypot(first.dxM - second.dxM, first.dyM - second.dyM)
                / ShelfLocalizationPolicy.calibrationPendingLoopTranslationM
            + angularDistance(first.dyawRad, second.dyawRad)
                / ShelfLocalizationPolicy.calibrationPendingLoopYawRad
    }

    private static func angularDistance(_ first: Double, _ second: Double) -> Double {
        abs(atan2(sin(first - second), cos(first - second)))
    }

    private static func transformEqual(
        _ first: ShelfEvidenceTransform,
        _ second: ShelfEvidenceTransform
    ) -> Bool {
        abs(first.dxM - second.dxM) <= 1.0e-12
            && abs(first.dyM - second.dyM) <= 1.0e-12
            && angularDistance(first.dyawRad, second.dyawRad) <= 1.0e-12
    }
}

struct CorridorHypothesisEvidence: Codable, Equatable {
    let corridorID: String
    let distanceScore: Double
    let structureBasinScore: Double
    let topologyReachable: Bool
    let score: Double

    enum CodingKeys: String, CodingKey {
        case corridorID = "corridor_id"
        case distanceScore = "distance_score"
        case structureBasinScore = "structure_basin_score"
        case topologyReachable = "topology_reachable"
        case score
    }
}

struct ShelfPenetrationAudit: Codable, Equatable {
    let nodeInsideShelfCount: Int
    let segmentCrossingCount: Int

    enum CodingKeys: String, CodingKey {
        case nodeInsideShelfCount = "node_inside_shelf_count"
        case segmentCrossingCount = "segment_crossing_count"
    }
}

struct ShelfLocalizationCovariance: Codable, Equatable {
    let alongM: Double
    let crossM: Double
    let yawRad: Double

    enum CodingKeys: String, CodingKey {
        case alongM = "along_m"
        case crossM = "cross_m"
        case yawRad = "yaw_rad"
    }
}

struct CorridorHypothesesRecord: Codable, Equatable {
    static let fileName = "corridor_hypotheses.jsonl"
    static let formatName = "MarketScannerCorridorHypotheses"

    let format: String
    let version: Int
    let trackingSessionID: String
    let sequence: Int
    let nodeID: Int64
    let nodeTimestamp: TimeInterval
    let nodeMapID: Int
    let epoch: Int
    let component: Int64
    let hypotheses: [CorridorHypothesisEvidence]
    let top1Top2Margin: Double
    let trackingState: ShelfTrackingState
    let selectedCorridorID: String
    let selectedShelfSegmentID: String
    let selectedShelfSide: String
    let lowConfidenceReasons: [String]
    let penetrationAudit: ShelfPenetrationAudit
    let covariance: ShelfLocalizationCovariance
    let writeWatermark: Int

    enum CodingKeys: String, CodingKey {
        case format, version, sequence, epoch, component, hypotheses, covariance
        case trackingSessionID = "tracking_session_id"
        case nodeID = "node_id"
        case nodeTimestamp = "node_timestamp"
        case nodeMapID = "node_map_id"
        case top1Top2Margin = "top1_top2_margin"
        case trackingState = "tracking_state"
        case selectedCorridorID = "selected_corridor_id"
        case selectedShelfSegmentID = "selected_shelf_segment_id"
        case selectedShelfSide = "selected_shelf_side"
        case lowConfidenceReasons = "low_confidence_reasons"
        case penetrationAudit = "penetration_audit"
        case writeWatermark = "write_watermark"
    }

    var isValid: Bool {
        format == Self.formatName
            && ShelfLocalizationPolicy.supportedContractVersions.contains(version)
            && !trackingSessionID.isEmpty && sequence >= 1 && nodeID > 0
            && nodeTimestamp.isFinite && nodeMapID >= 0
            && epoch >= 0 && component == Int64(nodeMapID)
            && hypotheses.count <= ShelfLocalizationPolicy.maximumCorridorHypotheses
            && hypotheses.allSatisfy {
                !$0.corridorID.isEmpty && $0.score.isFinite
                    && (0.0...1.0).contains($0.score)
                    && $0.distanceScore.isFinite
                    && (0.0...1.0).contains($0.distanceScore)
                    && $0.structureBasinScore.isFinite
                    && (0.0...1.0).contains($0.structureBasinScore)
            }
            && Set(hypotheses.map(\.corridorID)).count == hypotheses.count
            && zip(hypotheses, hypotheses.dropFirst()).allSatisfy { pair in
                pair.0.score >= pair.1.score
            }
            && top1Top2Margin.isFinite && top1Top2Margin >= 0
            && (selectedCorridorID.isEmpty
                || hypotheses.first?.corridorID == selectedCorridorID)
            && (["unknown", "left", "right"].contains(selectedShelfSide))
            && (selectedShelfSegmentID.isEmpty
                == (selectedShelfSide == "unknown"))
            && Set(lowConfidenceReasons).count == lowConfidenceReasons.count
            && lowConfidenceReasons.allSatisfy { !$0.isEmpty }
            && (hypotheses.first.map {
                $0.structureBasinScore
                    >= ShelfLocalizationPolicy
                        .minimumPresentStructureBasinScore
                    || lowConfidenceReasons.contains(
                        "structure_basin_support_insufficient")
            } ?? true)
            && (hypotheses.first.map {
                $0.topologyReachable
                    || lowConfidenceReasons.contains(
                        "topology_reachability_failed")
            } ?? true)
            && (trackingState == .tracking
                ? lowConfidenceReasons.isEmpty
                : !lowConfidenceReasons.isEmpty)
            && (trackingState != .bootstrap || selectedCorridorID.isEmpty)
            && penetrationAudit.nodeInsideShelfCount >= 0
            && penetrationAudit.segmentCrossingCount >= 0
            && covariance.alongM.isFinite && covariance.alongM >= 0
            && covariance.crossM.isFinite && covariance.crossM >= 0
            && covariance.yawRad.isFinite && covariance.yawRad >= 0
            && writeWatermark == sequence
    }
}

struct ShelfFaceNormal: Codable, Equatable {
    let x: Double
    let y: Double

    var isFiniteUnit: Bool {
        guard x.isFinite, y.isFinite else { return false }
        return abs(hypot(x, y) - 1.0) <= 0.05
    }
}

struct ShelfCandidateEvidence: Codable, Equatable {
    let shelfSegmentID: String
    let score: Double

    enum CodingKeys: String, CodingKey {
        case shelfSegmentID = "shelf_segment_id"
        case score
    }
}

struct ShelfWindowGeometryEvidence: Codable, Equatable {
    let sampleCount: Int
    let inlierCount: Int
    let inlierRatio: Double
    let residualMedianM: Double
    let residualMaximumM: Double

    enum CodingKeys: String, CodingKey {
        case sampleCount = "sample_count"
        case inlierCount = "inlier_count"
        case inlierRatio = "inlier_ratio"
        case residualMedianM = "residual_median_m"
        case residualMaximumM = "residual_maximum_m"
    }

    var isValid: Bool {
        sampleCount >= 12 && inlierCount >= 0 && inlierCount <= sampleCount
            && inlierRatio.isFinite
            && abs(inlierRatio - Double(inlierCount) / Double(sampleCount))
                <= 1.0e-9
            && residualMedianM.isFinite && residualMedianM >= 0
            && residualMaximumM.isFinite
            && residualMaximumM >= residualMedianM
    }
}

struct ShelfObservationWindowRecord: Codable, Equatable {
    static let fileName = "shelf_observation_windows.jsonl"
    static let formatName = "MarketScannerShelfObservationWindow"

    let format: String
    let version: Int
    let trackingSessionID: String
    let sequence: Int
    let windowID: String
    let nodeRange: [Int64]
    let timeRange: [TimeInterval]
    let epoch: Int
    let component: Int64
    let side: String
    let faceNormalMap: ShelfFaceNormal
    let shelfCandidates: [ShelfCandidateEvidence]
    /// Number of distinct accepted RTAB-Map nodes summarized by this window.
    /// This is deliberately separate from geometry.sample_count (depth
    /// residuals) and from the numeric node-id span, which becomes sparse
    /// under the 1/2 and 1/4 evidence cadence.
    let observationNodeCount: Int
    let geometry: ShelfWindowGeometryEvidence
    let coverageAngleRad: Double
    let endcapVisible: Bool
    let dynamicRejectionCount: Int
    let priorMapSHA256: String
    let distanceFieldSHA256: String
    let writeWatermark: Int

    enum CodingKeys: String, CodingKey {
        case format, version, sequence, epoch, component, side
        case trackingSessionID = "tracking_session_id"
        case windowID = "window_id"
        case nodeRange = "node_range"
        case timeRange = "time_range"
        case faceNormalMap = "face_normal_map"
        case shelfCandidates = "shelf_candidates"
        case observationNodeCount = "observation_node_count"
        case geometry
        case coverageAngleRad = "coverage_angle_rad"
        case endcapVisible = "endcap_visible"
        case dynamicRejectionCount = "dynamic_rejection_count"
        case priorMapSHA256 = "prior_map_sha256"
        case distanceFieldSHA256 = "distance_field_sha256"
        case writeWatermark = "write_watermark"
    }

    var isValid: Bool {
        format == Self.formatName
            && ShelfLocalizationPolicy.supportedContractVersions.contains(version)
            && !trackingSessionID.isEmpty && sequence >= 1 && !windowID.isEmpty
            && nodeRange.count == 2 && nodeRange[0] > 0
            && nodeRange[1] >= nodeRange[0] && timeRange.count == 2
            && timeRange.allSatisfy(\.isFinite) && timeRange[1] >= timeRange[0]
            && epoch >= 0 && component >= 0 && ["left", "right"].contains(side)
            && faceNormalMap.isFiniteUnit && !shelfCandidates.isEmpty
            && observationNodeCount >= 1
            && Int64(observationNodeCount)
                <= nodeRange[1] - nodeRange[0] + 1
            && geometry.isValid
            && shelfCandidates.count <= ShelfLocalizationPolicy.maximumShelfCandidates
            && shelfCandidates.allSatisfy {
                !$0.shelfSegmentID.isEmpty && $0.score.isFinite
                    && (0.0...1.0).contains($0.score)
            }
            && Set(shelfCandidates.map(\.shelfSegmentID)).count
                == shelfCandidates.count
            && zip(shelfCandidates, shelfCandidates.dropFirst()).allSatisfy { pair in
                pair.0.score >= pair.1.score
            }
            && coverageAngleRad.isFinite && coverageAngleRad >= 0
            && dynamicRejectionCount >= 0
            && dynamicRejectionCount <= observationNodeCount
            && ShelfLocalizationPolicy.isLowercaseSHA256(priorMapSHA256)
            && ShelfLocalizationPolicy.isLowercaseSHA256(distanceFieldSHA256)
            && writeWatermark == sequence
    }
}

struct ShelfPhoneRelativePose: Codable, Equatable {
    let dxM: Double
    let dyM: Double
    let dyawRad: Double

    enum CodingKeys: String, CodingKey {
        case dxM = "dx_m"
        case dyM = "dy_m"
        case dyawRad = "dyaw_rad"
    }
}

struct ShelfLoopConsistency: Codable, Equatable {
    let relativePoseDeltaM: Double
    let relativePoseDeltaYawRad: Double
    let inlierRatio: Double
    let residualMedianM: Double
    let residualMaximumM: Double

    enum CodingKeys: String, CodingKey {
        case relativePoseDeltaM = "relative_pose_delta_m"
        case relativePoseDeltaYawRad = "relative_pose_delta_yaw_rad"
        case inlierRatio = "inlier_ratio"
        case residualMedianM = "residual_median_m"
        case residualMaximumM = "residual_maximum_m"
    }
}

/// Encodes the v1 compatibility field as an explicit JSON null. A normal
/// Optional would be omitted by synthesized Encodable and violate the strict
/// field-set contract.
struct ShelfLegacyLoopResidualNull: Codable, Equatable {
    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        guard container.decodeNil() else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription:
                    "rtab_loop_residual_m must be null in shelf contract v2")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encodeNil()
    }
}

struct ShelfLoopEventRecord: Codable, Equatable {
    static let fileName = "shelf_loop_events.jsonl"
    static let formatName = "MarketScannerShelfLoopEvent"

    let format: String
    let version: Int
    let trackingSessionID: String
    let sequence: Int
    let shelfSegmentID: String
    let windowIDs: [String]
    let sides: [String]
    let epoch: Int
    let component: Int64
    let loopFromNode: Int64
    let loopToNode: Int64
    let rtabLoopID: Int
    /// Version-1 compatibility key. Version 2 must encode this as null because
    /// RTAB-Map's optimizationMaxError callback is not a loop residual.
    let legacyRtabLoopResidualM: ShelfLegacyLoopResidualNull
    let rtabGraphOptimizationMaxError: Double
    let phoneShelfSE2: ShelfPhoneRelativePose
    let consistency: ShelfLoopConsistency
    let accepted: Bool
    let reason: String
    let calibrationStatus: String
    let writeWatermark: Int

    enum CodingKeys: String, CodingKey {
        case format, version, sequence, sides, epoch, component, consistency
        case accepted, reason
        case trackingSessionID = "tracking_session_id"
        case shelfSegmentID = "shelf_segment_id"
        case windowIDs = "window_ids"
        case loopFromNode = "loop_from_node"
        case loopToNode = "loop_to_node"
        case rtabLoopID = "rtab_loop_id"
        case legacyRtabLoopResidualM = "rtab_loop_residual_m"
        case rtabGraphOptimizationMaxError = "rtab_graph_optimization_max_error"
        case phoneShelfSE2 = "phone_shelf_se2"
        case calibrationStatus = "calibration_status"
        case writeWatermark = "write_watermark"
    }

    var isValid: Bool {
        let finite = rtabGraphOptimizationMaxError.isFinite
            && phoneShelfSE2.dxM.isFinite && phoneShelfSE2.dyM.isFinite
            && phoneShelfSE2.dyawRad.isFinite
            && consistency.relativePoseDeltaM.isFinite
            && consistency.relativePoseDeltaYawRad.isFinite
            && consistency.inlierRatio.isFinite
            && consistency.residualMedianM.isFinite
            && consistency.residualMaximumM.isFinite
        return format == Self.formatName
            && ShelfLocalizationPolicy.supportedContractVersions.contains(version)
            && !trackingSessionID.isEmpty && sequence >= 1
            && !shelfSegmentID.isEmpty && windowIDs.count == 2
            && windowIDs.allSatisfy { !$0.isEmpty } && Set(windowIDs).count == 2
            && sides.count == 2 && sides.allSatisfy { ["left", "right"].contains($0) }
            && sides[0] != sides[1] && epoch >= 0 && component >= 0
            && loopFromNode > 0 && loopToNode > 0 && rtabLoopID >= 0
            && finite && rtabGraphOptimizationMaxError >= 0
            && (0.0...1.0).contains(consistency.inlierRatio)
            && consistency.residualMedianM >= 0 && consistency.residualMaximumM >= 0
            && !reason.isEmpty
            && calibrationStatus == ShelfLocalizationPolicy.calibrationStatus
            && writeWatermark == sequence
    }
}

enum ShelfTrackingState: String, Codable, Equatable {
    case bootstrap = "BOOTSTRAP"
    case tracking = "TRACKING"
    case lowConfidence = "LOW_CONFIDENCE"
}

struct ShelfTrackingDecision: Equatable {
    let state: ShelfTrackingState
    let selectedCorridorID: String?
    let lowConfidenceReasons: [String]
}

/// S-8 single-best commit state machine. Ambiguity never blocks scanning or
/// coordinate persistence; it is made visible through LOW_CONFIDENCE.
struct ShelfTrackingStateMachine {
    private(set) var state: ShelfTrackingState = .bootstrap
    private(set) var selectedCorridorID: String?

    mutating func update(
        hypotheses: [CorridorHypothesisEvidence],
        distanceSinceReliableLoopM: Double,
        recentTrackingDegradationCount: Int,
        manualRelocalizationConverged: Bool = false
    ) -> ShelfTrackingDecision {
        let ordered = hypotheses
            .filter { !$0.corridorID.isEmpty && $0.score.isFinite }
            .sorted { lhs, rhs in
                lhs.score == rhs.score
                    ? lhs.corridorID < rhs.corridorID : lhs.score > rhs.score
            }
        selectedCorridorID = ordered.first?.corridorID
        var reasons: [String] = []
        if ordered.isEmpty {
            reasons.append("candidate_unavailable")
        } else if ordered.count > 1 {
            let denominator = max(abs(ordered[0].score), 1.0e-9)
            let relativeMargin = (ordered[0].score - ordered[1].score) / denominator
            if relativeMargin < ShelfLocalizationPolicy
                .calibrationPendingLowConfidenceMargin {
                reasons.append("top1_top2_margin_below_calibration_pending_threshold")
            }
        }
        if let best = ordered.first,
           best.structureBasinScore
            < ShelfLocalizationPolicy.minimumPresentStructureBasinScore {
            reasons.append("structure_basin_support_insufficient")
        }
        if let best = ordered.first, !best.topologyReachable {
            reasons.append("topology_reachability_failed")
        }
        if distanceSinceReliableLoopM.isFinite
            && distanceSinceReliableLoopM
                > ShelfLocalizationPolicy.calibrationPendingReliableLoopDistanceM {
            reasons.append("reliable_loop_distance_exceeded")
        }
        if recentTrackingDegradationCount >= 3 {
            reasons.append("tracking_degradation_frequency_high")
        }
        if manualRelocalizationConverged && selectedCorridorID != nil {
            reasons.removeAll()
        }
        if selectedCorridorID == nil {
            state = .bootstrap
        } else {
            state = reasons.isEmpty ? .tracking : .lowConfidence
        }
        return ShelfTrackingDecision(
            state: state,
            selectedCorridorID: selectedCorridorID,
            lowConfidenceReasons: reasons)
    }
}

enum ShelfLoopVerifier {
    static func candidateRelativeMargin(
        _ window: ShelfObservationWindowRecord
    ) -> Double {
        guard window.shelfCandidates.count >= 2 else { return 1.0 }
        let first = window.shelfCandidates[0].score
        let second = window.shelfCandidates[1].score
        guard first.isFinite, second.isFinite else { return 0 }
        return max(0, (first - second) / max(abs(first), 1.0e-9))
    }

    static func opposingNormalAngle(
        _ first: ShelfFaceNormal,
        _ second: ShelfFaceNormal
    ) -> Double? {
        guard first.isFiniteUnit, second.isFiniteUnit else { return nil }
        let dot = max(-1.0, min(1.0, first.x * second.x + first.y * second.y))
        return acos(dot)
    }

    static func accepts(
        first: ShelfObservationWindowRecord,
        second: ShelfObservationWindowRecord,
        relativePoseDeltaM: Double,
        relativePoseDeltaYawRad: Double,
        inlierRatio: Double,
        hasEpochBridge: Bool,
        dominantDynamicEvidence: Bool
    ) -> Bool {
        guard first.isValid, second.isValid,
              first.windowID != second.windowID,
              first.shelfCandidates.first?.shelfSegmentID
                == second.shelfCandidates.first?.shelfSegmentID,
              first.side != second.side,
              first.component == second.component,
              first.epoch == second.epoch || hasEpochBridge,
              candidateRelativeMargin(first)
                >= ShelfLocalizationPolicy.calibrationPendingLowConfidenceMargin,
              candidateRelativeMargin(second)
                >= ShelfLocalizationPolicy.calibrationPendingLowConfidenceMargin,
              first.geometry.inlierRatio
                >= ShelfLocalizationPolicy.calibrationPendingLoopInlierRatio,
              second.geometry.inlierRatio
                >= ShelfLocalizationPolicy.calibrationPendingLoopInlierRatio,
              !dominantDynamicEvidence,
              let angle = opposingNormalAngle(
                first.faceNormalMap, second.faceNormalMap) else {
            return false
        }
        return angle > ShelfLocalizationPolicy
                .calibrationPendingMinimumOpposingNormalRad
            && relativePoseDeltaM.isFinite
            && relativePoseDeltaM
                <= ShelfLocalizationPolicy.calibrationPendingLoopTranslationM
            && relativePoseDeltaYawRad.isFinite
            && abs(relativePoseDeltaYawRad)
                <= ShelfLocalizationPolicy.calibrationPendingLoopYawRad
            && inlierRatio.isFinite
            && inlierRatio >= ShelfLocalizationPolicy
                .calibrationPendingLoopInlierRatio
    }
}

enum ShelfFreeSpaceAuditor {
    /// Frozen S-7 phone-point model. Depth samples are deliberately absent:
    /// only the phone pose point and the swept accepted-node segment can
    /// reject a localization candidate.
    static func audit(
        previous: PriorMapPose2D?,
        current: PriorMapPose2D,
        shelfPolygons: [[PriorMapPose2D]]
    ) -> ShelfPenetrationAudit {
        let nodeViolation = shelfPolygons.contains {
            penetrationDepth(point: current, polygon: $0)
                > ShelfLocalizationPolicy.maximumPhoneShelfPenetrationM
        }
        var segmentViolation = false
        if let previous {
            let deltaX = current.xM - previous.xM
            let deltaY = current.yM - previous.yM
            // `Int(ceil(x))` traps on NaN/infinity. A degenerate pose pair
            // would otherwise crash the scan loop here; falling back to the
            // node-only result is the conservative but safe outcome.
            guard deltaX.isFinite, deltaY.isFinite else {
                return ShelfPenetrationAudit(
                    nodeInsideShelfCount: nodeViolation ? 1 : 0,
                    segmentCrossingCount: 0)
            }
            let distance = hypot(deltaX, deltaY)
            // Bounded at 256 samples even for a hostile discontinuity. The
            // pose-jump gate rejects such edges separately.
            let steps = min(256, max(1, Int(ceil(distance / 0.1))))
            if steps > 1 {
                for index in 1..<steps {
                    let fraction = Double(index) / Double(steps)
                    let sample = PriorMapPose2D(
                        xM: previous.xM + (current.xM - previous.xM) * fraction,
                        yM: previous.yM + (current.yM - previous.yM) * fraction,
                        yawRad: current.yawRad)
                    if shelfPolygons.contains(where: {
                        penetrationDepth(point: sample, polygon: $0)
                            > ShelfLocalizationPolicy.maximumPhoneShelfPenetrationM
                    }) {
                        segmentViolation = true
                        break
                    }
                }
            }
        }
        return ShelfPenetrationAudit(
            nodeInsideShelfCount: nodeViolation ? 1 : 0,
            segmentCrossingCount: segmentViolation ? 1 : 0)
    }

    private static func penetrationDepth(
        point: PriorMapPose2D,
        polygon: [PriorMapPose2D]
    ) -> Double {
        guard polygon.count >= 3, contains(point: point, polygon: polygon) else {
            return 0
        }
        var result = Double.infinity
        for index in polygon.indices {
            let start = polygon[index]
            let end = polygon[(index + 1) % polygon.count]
            let dx = end.xM - start.xM
            let dy = end.yM - start.yM
            let denominator = dx * dx + dy * dy
            let t = denominator > 0
                ? max(0, min(1, ((point.xM - start.xM) * dx
                    + (point.yM - start.yM) * dy) / denominator)) : 0
            result = min(
                result,
                hypot(
                    point.xM - (start.xM + t * dx),
                    point.yM - (start.yM + t * dy)))
        }
        return result.isFinite ? result : 0
    }

    private static func contains(
        point: PriorMapPose2D,
        polygon: [PriorMapPose2D]
    ) -> Bool {
        var inside = false
        var previous = polygon.count - 1
        for current in polygon.indices {
            let first = polygon[current]
            let second = polygon[previous]
            let crosses = (first.yM > point.yM) != (second.yM > point.yM)
                && point.xM < (second.xM - first.xM)
                    * (point.yM - first.yM)
                    / ((second.yM - first.yM) == 0
                        ? Double.leastNonzeroMagnitude
                        : (second.yM - first.yM)) + first.xM
            if crosses { inside.toggle() }
            previous = current
        }
        return inside
    }
}

/// P2 bounded temporal-voxel filter. It never arbitrates map correctness:
/// transient/moving structure is excluded after the C-3 warm-up while the
/// prior map remains authoritative (S-1). C-3 is explicitly pending field
/// calibration.
///
/// 2026-09-03 policy refinement: the persistence gate below only ever gates
/// *unmatched* (off-map) transient structure. A static occluder standing in
/// front of a mapped shelf never produces matched depth on the shelf
/// itself, so duration cannot decide shelf presence; those observation gaps
/// are classified geometrically by the map-anchored rule instead (see
/// `mapAnchoredStaticOccluderMinGapM/MaxGapM` and
/// `tools/PriorMap/shelf_occlusion_classifier.py`).
final class DynamicShelfEvidenceFilter {
    private struct Cell {
        var firstSeen: TimeInterval
        var lastSeen: TimeInterval
        var hitFrames: Int
        var lastFrameSequence: Int
    }

    private let cellSizeM = 0.25
    private let maximumCells = 50_000
    private var cells: [String: Cell] = [:]
    private var firstTimestamp: TimeInterval?
    private var frameSequence = 0

    func reset() {
        cells.removeAll(keepingCapacity: true)
        firstTimestamp = nil
        frameSequence = 0
    }

    func filter(
        localPoints: [PriorMapPose2D],
        mapPose: PriorMapPose2D,
        timestamp: TimeInterval,
        authoritativeShelfPolygons: [[PriorMapPose2D]] = []
    ) -> (points: [PriorMapPose2D], rejectedCount: Int) {
        guard timestamp.isFinite else { return (localPoints, 0) }
        // A non-finite pose would propagate into the grid key below, and
        // `Int(floor(x))` traps on NaN/infinity -- a hard crash rather than a
        // rejected sample. Reject the whole frame's filtering instead by
        // passing the points through untouched.
        guard mapPose.xM.isFinite, mapPose.yM.isFinite, mapPose.yawRad.isFinite
        else {
            return (localPoints, 0)
        }
        if firstTimestamp == nil { firstTimestamp = timestamp }
        if frameSequence < Int.max { frameSequence += 1 }
        let cosine = cos(mapPose.yawRad)
        let sine = sin(mapPose.yawRad)
        var retained: [PriorMapPose2D] = []
        retained.reserveCapacity(localPoints.count)
        var rejected = 0
        // Round-2 remediation: the previous code called
        // `distanceToBoundary` for every (point, polygon, edge) triple. On a
        // real Sam package that is ~1197 polygons x 4 edges x 600 points =
        // ~2.9M distance evaluations *per frame*, which is what drove the
        // sustained ~112% CPU and the 921 ms update spikes seen in the field.
        // Pre-computing bounding boxes once per call turns the common case
        // into an O(1) reject; only points near a shelf pay for exact
        // geometry. The result is bit-for-bit identical.
        let supportBoxes = authoritativeShelfPolygons.map { polygon -> Bounds in
            var minX = Double.infinity
            var minY = Double.infinity
            var maxX = -Double.infinity
            var maxY = -Double.infinity
            for point in polygon {
                if point.xM < minX { minX = point.xM }
                if point.xM > maxX { maxX = point.xM }
                if point.yM < minY { minY = point.yM }
                if point.yM > maxY { maxY = point.yM }
            }
            return Bounds(minX: minX, minY: minY, maxX: maxX, maxY: maxY)
        }
        // Hard ceiling on the evidence grid. Previously the trim only ran on
        // every 100th frame, so a slow frame rate could let `cells` grow past
        // the documented 50k cap before anything reclaimed memory.
        if cells.count > maximumCells {
            let keep = cells.sorted {
                $0.value.lastSeen > $1.value.lastSeen
            }.prefix(maximumCells)
            cells = Dictionary(
                uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        let warmedUp = timestamp - (firstTimestamp ?? timestamp)
            >= ShelfLocalizationPolicy.calibrationPendingDynamicPersistenceSeconds
        for point in localPoints {
            // Individually degenerate depth samples must be skipped rather
            // than converted: `Int(floor(x))` traps on non-finite input.
            guard point.xM.isFinite, point.yM.isFinite else { continue }
            let mapX = mapPose.xM + cosine * point.xM - sine * point.yM
            let mapY = mapPose.yM + sine * point.xM + cosine * point.yM
            guard mapX.isFinite, mapY.isFinite else { continue }
            let key = "\(Int(floor(mapX / cellSizeM))),\(Int(floor(mapY / cellSizeM)))"
            var cell = cells[key] ?? Cell(
                firstSeen: timestamp,
                lastSeen: timestamp,
                hitFrames: 0,
                lastFrameSequence: -1)
            if cell.lastFrameSequence != frameSequence {
                cell.hitFrames = min(Int.max - 1, cell.hitFrames + 1)
                cell.lastFrameSequence = frameSequence
            }
            cell.lastSeen = timestamp
            cells[key] = cell
            let persistent = timestamp - cell.firstSeen
                >= ShelfLocalizationPolicy.calibrationPendingDynamicPersistenceSeconds
                && cell.hitFrames >= 3
            // S-1 keeps the prior map authoritative: depth samples already
            // supported by a mapped shelf face must remain usable immediately.
            // The 10-second persistence gate applies only to unmatched
            // transient structure such as customers and carts.
            let mapSupported = Self.isMapSupported(
                x: mapX,
                y: mapY,
                polygons: authoritativeShelfPolygons,
                boxes: supportBoxes,
                toleranceM: 0.5)
            if !warmedUp || persistent || mapSupported {
                retained.append(point)
            } else {
                rejected += 1
            }
        }
        if frameSequence % 100 == 0 {
            let cutoff = timestamp
                - ShelfLocalizationPolicy.calibrationPendingDynamicPersistenceSeconds * 2
            cells = cells.filter { $0.value.lastSeen >= cutoff }
            if cells.count > maximumCells {
                let keep = cells.sorted {
                    $0.value.lastSeen > $1.value.lastSeen
                }.prefix(maximumCells)
                cells = Dictionary(
                    uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
            }
        }
        return (retained, rejected)
    }

    /// Axis-aligned extent used to reject a point before paying for exact
    /// point-to-segment geometry.
    private struct Bounds {
        let minX: Double
        let minY: Double
        let maxX: Double
        let maxY: Double
    }

    /// Two-stage map-support test.
    ///
    /// Stage 1 rejects any polygon whose expanded bounding box cannot contain
    /// the sample. Stage 2 runs the original exact distance test only for the
    /// handful of polygons that survive. Semantically identical to
    /// `authoritativeShelfPolygons.contains { distanceToBoundary(...) <= tol }`
    /// but with the per-frame cost moved from O(points x edges) to
    /// O(points + near-matches x edges).
    private static func isMapSupported(
        x: Double,
        y: Double,
        polygons: [[PriorMapPose2D]],
        boxes: [Bounds],
        toleranceM: Double
    ) -> Bool {
        guard polygons.count == boxes.count,
              x.isFinite, y.isFinite, toleranceM.isFinite else {
            // A non-finite sample cannot be "supported" by any mapped
            // geometry. Bailing out early also keeps NaN from defeating the
            // bounding-box reject below (NaN comparisons are all false, which
            // would otherwise send the sample through the exact path for every
            // polygon and silently undo the optimisation).
            return false
        }
        for index in polygons.indices {
            let box = boxes[index]
            if x < box.minX - toleranceM || x > box.maxX + toleranceM
                || y < box.minY - toleranceM || y > box.maxY + toleranceM {
                continue
            }
            if distanceToBoundary(
                x: x, y: y, polygon: polygons[index]
            ) <= toleranceM {
                return true
            }
        }
        return false
    }

    private static func distanceToBoundary(
        x: Double,
        y: Double,
        polygon: [PriorMapPose2D]
    ) -> Double {
        guard polygon.count >= 2 else { return .infinity }
        var result = Double.infinity
        for index in polygon.indices {
            let start = polygon[index]
            let end = polygon[(index + 1) % polygon.count]
            let dx = end.xM - start.xM
            let dy = end.yM - start.yM
            let denominator = dx * dx + dy * dy
            let ratio = denominator > 0
                ? max(0, min(1,
                    ((x - start.xM) * dx + (y - start.yM) * dy)
                        / denominator)) : 0
            result = min(
                result,
                hypot(
                    x - (start.xM + ratio * dx),
                    y - (start.yM + ratio * dy)))
        }
        return result
    }
}

struct ShelfLocalizationEvidenceBundleSummary: Equatable {
    let poseEpochTransitionCount: Int
    let corridorHypothesisCount: Int
    let shelfObservationWindowCount: Int
    let shelfLoopEventCount: Int
}

/// Strict, streaming mobile-side validator for the four manifest-v5 files.
/// Unknown root fields, duplicate keys, framing errors, invalid finite values,
/// non-monotonic watermarks and metadata count drift all fail closed.
enum ShelfLocalizationEvidenceParser {
    enum ParseError: Error, LocalizedError {
        case record(String, Int, String)
        case count(String, Int, Int)

        var errorDescription: String? {
            switch self {
            case .record(let file, let line, let reason):
                return "\(file) 第 \(line) 行无效：\(reason)"
            case .count(let file, let actual, let expected):
                return "\(file) 计数不匹配：\(actual) != \(expected)"
            }
        }
    }

    private static let poseFieldsV2: Set<String> = [
        "format", "version", "tracking_session_id", "sequence",
        "from_epoch", "to_epoch", "before_frame_timestamp",
        "after_frame_timestamp", "before_node_id", "after_node_id",
        "transform", "bridge_evidence", "reason", "write_watermark",
    ]
    private static let poseFieldsV3 = poseFieldsV2.union([
        "from_component", "to_component",
    ])
    private static let corridorFields: Set<String> = [
        "format", "version", "tracking_session_id", "sequence", "node_id",
        "node_timestamp", "node_map_id", "epoch", "component", "hypotheses",
        "top1_top2_margin", "tracking_state", "selected_corridor_id",
        "selected_shelf_segment_id", "selected_shelf_side",
        "low_confidence_reasons", "penetration_audit", "covariance",
        "write_watermark",
    ]
    private static let windowFields: Set<String> = [
        "format", "version", "tracking_session_id", "sequence", "window_id",
        "node_range", "time_range", "epoch", "component", "side",
        "face_normal_map", "shelf_candidates", "coverage_angle_rad",
        "observation_node_count", "geometry",
        "endcap_visible", "dynamic_rejection_count", "prior_map_sha256",
        "distance_field_sha256", "write_watermark",
    ]
    private static let loopFields: Set<String> = [
        "format", "version", "tracking_session_id", "sequence",
        "shelf_segment_id", "window_ids", "sides", "epoch", "component",
        "loop_from_node", "loop_to_node", "rtab_loop_id",
        "rtab_loop_residual_m", "rtab_graph_optimization_max_error",
        "phone_shelf_se2", "consistency", "accepted",
        "reason", "calibration_status", "write_watermark",
    ]

    static func validateBundle(
        directory: URL,
        trackingSessionID: String,
        poseEpochTransitionCount: Int,
        corridorHypothesisCount: Int,
        shelfObservationWindowCount: Int,
        shelfLoopEventCount: Int
    ) throws -> ShelfLocalizationEvidenceBundleSummary {
        let poses: [PoseEpochTransitionRecord] = try parse(
            directory: directory,
            fileName: PoseEpochTransitionRecord.fileName,
            expectedCount: poseEpochTransitionCount,
            expectedTrackingSessionID: trackingSessionID,
            limits: .init(
                maximumFileBytes: GeneratedMobileEvidenceContracts
                    .File_pose_epoch_transitions_jsonl.max_file_bytes,
                maximumLineBytes: GeneratedMobileEvidenceContracts
                    .File_pose_epoch_transitions_jsonl.max_record_bytes,
                maximumLineCount: GeneratedMobileEvidenceContracts
                    .File_pose_epoch_transitions_jsonl.max_records),
            knownFields: poseFieldsV3,
            requiredFields: poseFieldsV2,
            valid: { $0.isValid },
            sequence: { $0.sequence },
            session: { $0.trackingSessionID })
        let corridors: [CorridorHypothesesRecord] = try parse(
            directory: directory,
            fileName: CorridorHypothesesRecord.fileName,
            expectedCount: corridorHypothesisCount,
            expectedTrackingSessionID: trackingSessionID,
            limits: .init(
                maximumFileBytes: GeneratedMobileEvidenceContracts
                    .File_corridor_hypotheses_jsonl.max_file_bytes,
                maximumLineBytes: GeneratedMobileEvidenceContracts
                    .File_corridor_hypotheses_jsonl.max_record_bytes,
                maximumLineCount: GeneratedMobileEvidenceContracts
                    .File_corridor_hypotheses_jsonl.max_records),
            knownFields: corridorFields,
            requiredFields: corridorFields,
            valid: { $0.isValid }, sequence: { $0.sequence },
            session: { $0.trackingSessionID })
        let windows: [ShelfObservationWindowRecord] = try parse(
            directory: directory,
            fileName: ShelfObservationWindowRecord.fileName,
            expectedCount: shelfObservationWindowCount,
            expectedTrackingSessionID: trackingSessionID,
            limits: .init(
                maximumFileBytes: GeneratedMobileEvidenceContracts
                    .File_shelf_observation_windows_jsonl.max_file_bytes,
                maximumLineBytes: GeneratedMobileEvidenceContracts
                    .File_shelf_observation_windows_jsonl.max_record_bytes,
                maximumLineCount: GeneratedMobileEvidenceContracts
                    .File_shelf_observation_windows_jsonl.max_records),
            knownFields: windowFields,
            requiredFields: windowFields,
            valid: { $0.isValid }, sequence: { $0.sequence },
            session: { $0.trackingSessionID })
        let loops: [ShelfLoopEventRecord] = try parse(
            directory: directory,
            fileName: ShelfLoopEventRecord.fileName,
            expectedCount: shelfLoopEventCount,
            expectedTrackingSessionID: trackingSessionID,
            limits: .init(
                maximumFileBytes: GeneratedMobileEvidenceContracts
                    .File_shelf_loop_events_jsonl.max_file_bytes,
                maximumLineBytes: GeneratedMobileEvidenceContracts
                    .File_shelf_loop_events_jsonl.max_record_bytes,
                maximumLineCount: GeneratedMobileEvidenceContracts
                    .File_shelf_loop_events_jsonl.max_records),
            knownFields: loopFields,
            requiredFields: loopFields,
            valid: { $0.isValid }, sequence: { $0.sequence },
            session: { $0.trackingSessionID })
        let windowsByID = Dictionary(
            windows.map { ($0.windowID, $0) },
            uniquingKeysWith: { _, _ in
                // Duplicate identities are rejected explicitly below.
                windows[0]
            })
        guard windowsByID.count == windows.count else {
            throw ParseError.record(
                ShelfObservationWindowRecord.fileName, 0,
                "duplicate_window_identity")
        }
        let transitionFromEpochs = poses.map(\.fromEpoch)
        guard Set(transitionFromEpochs).count == transitionFromEpochs.count else {
            throw ParseError.record(
                PoseEpochTransitionRecord.fileName, 0,
                "duplicate_pose_epoch_transition")
        }
        let bridgedEpochComponents = Set(poses.flatMap { record in
            guard record.version >= 3 else {
                // Legacy aggregate counters did not bind native node pairs,
                // component identity or a reproducible transform.
                return [String]()
            }
            return record.bridgeEvidence.compactMap { evidence in
                guard let component = evidence.component else { return nil }
                return "\(record.fromEpoch):\(component)"
            }
        })
        for loop in loops {
            guard let first = windowsByID[loop.windowIDs[0]],
                  let second = windowsByID[loop.windowIDs[1]],
                  first.shelfCandidates.first?.shelfSegmentID
                    == loop.shelfSegmentID,
                  second.shelfCandidates.first?.shelfSegmentID
                    == loop.shelfSegmentID,
                  loop.sides == [first.side, second.side],
                  loop.component == first.component,
                  loop.epoch == first.epoch || loop.epoch == second.epoch,
                  first.nodeRange[0] <= loop.loopFromNode,
                  loop.loopFromNode <= first.nodeRange[1],
                  second.nodeRange[0] <= loop.loopToNode,
                  loop.loopToNode <= second.nodeRange[1] else {
                throw ParseError.record(
                    ShelfLoopEventRecord.fileName, loop.sequence,
                    "loop_window_identity_mismatch")
            }
            if first.component != second.component {
                guard !loop.accepted else {
                    throw ParseError.record(
                        ShelfLoopEventRecord.fileName, loop.sequence,
                        "accepted_loop_crosses_graph_component")
                }
                continue
            }
            let lowerEpoch = min(first.epoch, second.epoch)
            let upperEpoch = max(first.epoch, second.epoch)
            let hasBridge = lowerEpoch == upperEpoch
                || (lowerEpoch..<upperEpoch).allSatisfy {
                    bridgedEpochComponents.contains("\($0):\(loop.component)")
                }
            let dominantDynamicEvidence =
                first.dynamicRejectionCount * 2
                    > first.observationNodeCount
                || second.dynamicRejectionCount * 2
                    > second.observationNodeCount
            let qualifies = ShelfLoopVerifier.accepts(
                first: first,
                second: second,
                relativePoseDeltaM:
                    loop.consistency.relativePoseDeltaM,
                relativePoseDeltaYawRad:
                    loop.consistency.relativePoseDeltaYawRad,
                inlierRatio: loop.consistency.inlierRatio,
                hasEpochBridge: hasBridge,
                dominantDynamicEvidence: dominantDynamicEvidence)
            let expectedGeometryInlierRatio = min(
                first.geometry.inlierRatio,
                second.geometry.inlierRatio)
            let expectedGeometryMedian = max(
                first.geometry.residualMedianM,
                second.geometry.residualMedianM)
            let expectedGeometryMaximum = max(
                first.geometry.residualMaximumM,
                second.geometry.residualMaximumM)
            guard abs(loop.consistency.inlierRatio
                    - expectedGeometryInlierRatio) <= 1.0e-9,
                  abs(loop.consistency.residualMedianM
                    - expectedGeometryMedian) <= 1.0e-9,
                  abs(loop.consistency.residualMaximumM
                    - expectedGeometryMaximum) <= 1.0e-9 else {
                throw ParseError.record(
                    ShelfLoopEventRecord.fileName, loop.sequence,
                    "loop_geometry_summary_mismatch")
            }
            guard loop.accepted == qualifies else {
                throw ParseError.record(
                    ShelfLoopEventRecord.fileName, loop.sequence,
                    "loop_acceptance_disagrees_with_frozen_criteria")
            }
        }
        return ShelfLocalizationEvidenceBundleSummary(
            poseEpochTransitionCount: poses.count,
            corridorHypothesisCount: corridors.count,
            shelfObservationWindowCount: windows.count,
            shelfLoopEventCount: loops.count)
    }

    private static func parse<Record: Decodable>(
        directory: URL,
        fileName: String,
        expectedCount: Int,
        expectedTrackingSessionID: String,
        limits: StrictJSONLStreamReader.Limits,
        knownFields: Set<String>,
        requiredFields: Set<String>,
        valid: (Record) -> Bool,
        sequence: (Record) -> Int,
        session: (Record) -> String
    ) throws -> [Record] {
        var records: [Record] = []
        records.reserveCapacity(min(expectedCount, 1024))
        let decoder = JSONDecoder()
        let summary = try StrictJSONLStreamReader.forEachLine(
            from: directory.appendingPathComponent(fileName),
            limits: limits
        ) { line in
            let object = try StrictJSONLStreamReader.strictObject(
                from: line.text, lineNumber: line.number)
            let observedFields = Set(object.keys)
            guard observedFields.isSubset(of: knownFields),
                  requiredFields.isSubset(of: observedFields),
                  rootFieldsAreExact(fileName: fileName, object: object),
                  nestedFieldsAreExact(fileName: fileName, object: object) else {
                throw ParseError.record(fileName, line.number, "field_set_mismatch")
            }
            guard let data = line.text.data(using: .utf8),
                  let record = try? decoder.decode(Record.self, from: data),
                  valid(record), session(record) == expectedTrackingSessionID,
                  sequence(record) == line.number else {
                throw ParseError.record(fileName, line.number, "schema_or_watermark_invalid")
            }
            records.append(record)
        }
        guard summary.lineCount == expectedCount else {
            throw ParseError.count(fileName, summary.lineCount, expectedCount)
        }
        return records
    }

    private static func nestedFieldsAreExact(
        fileName: String,
        object: [String: Any]
    ) -> Bool {
        func exactObject(_ value: Any?, _ fields: Set<String>) -> Bool {
            guard let object = value as? [String: Any] else { return false }
            return Set(object.keys) == fields
        }
        func exactObjects(_ value: Any?, _ fields: Set<String>) -> Bool {
            guard let values = value as? [[String: Any]] else { return false }
            return values.allSatisfy { Set($0.keys) == fields }
        }
        switch fileName {
        case PoseEpochTransitionRecord.fileName:
            guard exactObject(
                    object["transform"], ["dx_m", "dy_m", "dyaw_rad"]),
                  let version = object["version"] as? Int else {
                return false
            }
            if version == 2 {
                return exactObjects(
                    object["bridge_evidence"], [
                        "type", "independent_node_pairs",
                        "consensus_inlier_ratio",
                    ])
            }
            guard version == ShelfLocalizationPolicy.contractVersion,
                  let evidence = object["bridge_evidence"] as? [[String: Any]] else {
                return false
            }
            return evidence.allSatisfy { bridge in
                guard Set(bridge.keys) == [
                        "type", "independent_node_pairs",
                        "consensus_inlier_ratio", "component",
                        "consensus_transform", "links",
                    ],
                    exactObject(
                        bridge["consensus_transform"],
                        ["dx_m", "dy_m", "dyaw_rad"]),
                    let links = bridge["links"] as? [[String: Any]] else {
                    return false
                }
                return links.allSatisfy { link in
                    Set(link.keys) == [
                        "from_node_id", "to_node_id", "from_epoch",
                        "to_epoch", "from_component", "to_component",
                        "native_link_type", "measurement",
                        "bridge_transform", "consensus_inlier",
                    ]
                        && exactObject(
                            link["measurement"],
                            ["dx_m", "dy_m", "dyaw_rad"])
                        && exactObject(
                            link["bridge_transform"],
                            ["dx_m", "dy_m", "dyaw_rad"])
                }
            }
        case CorridorHypothesesRecord.fileName:
            return exactObjects(
                    object["hypotheses"], [
                        "corridor_id", "distance_score",
                        "structure_basin_score", "topology_reachable", "score",
                    ])
                && exactObject(
                    object["penetration_audit"],
                    ["node_inside_shelf_count", "segment_crossing_count"])
                && exactObject(
                    object["covariance"], ["along_m", "cross_m", "yaw_rad"])
        case ShelfObservationWindowRecord.fileName:
            return exactObject(object["face_normal_map"], ["x", "y"])
                && exactObjects(
                    object["shelf_candidates"], ["shelf_segment_id", "score"])
                && exactObject(
                    object["geometry"], [
                        "sample_count", "inlier_count", "inlier_ratio",
                        "residual_median_m", "residual_maximum_m",
                    ])
        case ShelfLoopEventRecord.fileName:
            return exactObject(
                    object["phone_shelf_se2"], ["dx_m", "dy_m", "dyaw_rad"])
                && exactObject(
                    object["consistency"], [
                        "relative_pose_delta_m", "relative_pose_delta_yaw_rad",
                        "inlier_ratio", "residual_median_m",
                        "residual_maximum_m",
                    ])
        default:
            return false
        }
    }

    private static func rootFieldsAreExact(
        fileName: String,
        object: [String: Any]
    ) -> Bool {
        let observed = Set(object.keys)
        guard let version = object["version"] as? Int,
              ShelfLocalizationPolicy.supportedContractVersions
                .contains(version) else {
            return false
        }
        if fileName == PoseEpochTransitionRecord.fileName {
            return observed == (version == 2 ? poseFieldsV2 : poseFieldsV3)
        }
        switch fileName {
        case CorridorHypothesesRecord.fileName:
            return observed == corridorFields
        case ShelfObservationWindowRecord.fileName:
            return observed == windowFields
        case ShelfLoopEventRecord.fileName:
            return observed == loopFields
        default:
            return false
        }
    }
}
