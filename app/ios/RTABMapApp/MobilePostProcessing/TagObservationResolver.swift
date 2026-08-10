import Foundation

/// Resolves raw tag observations against the final optimized trajectory
/// and fuses multi-frame bursts into physical tag instances.
///
/// V1R5 time-axis contract (review B-03): the parser already bound every
/// observation to an EXACT snapshot-DB node (`boundNodeID`) on the node
/// timebase axis. The resolver never re-guesses a nearest node and never
/// compares relative session time against absolute node stamps. It uses
/// two O(1) indexes built once per run:
/// - `finalNodeByID`: id -> final optimized node pose;
/// - `rawNodeStampByID`: id -> raw snapshot-DB node stamp (the axis the
///   parser bound on).
/// For each observation: O(1) lookup by `boundNodeID`, exact stamp
/// re-verification (`|raw stamp - parser stamp| <= frozen delta`), then
/// P_final = T_final_node * inverse(T_raw_node) * P_raw. The V1R4 5-second
/// nearest-node fallback is deleted from the formal path.
///
/// Position propagation is
/// P_final = T_final_node * inverse(T_raw_node) * P_raw; 3D is preserved
/// internally, the business output is 2D. Same barcode on different
/// shelves/floors stays distinct instances — barcodes are never globally
/// deduplicated.
enum TagObservationResolver {

    /// O(1) lookup tables built once per run (V1R5 §6.5).
    struct NodeIndex {
        var finalNodeByID: [Int64: FinalNodePose]
        var rawNodeStampByID: [Int64: Double]

        init(
            finalNodes: [FinalNodePose],
            rawNodeStamps: [Int64: Double]
        ) {
            var finalByID: [Int64: FinalNodePose] = [:]
            finalByID.reserveCapacity(finalNodes.count)
            for node in finalNodes {
                finalByID[node.id] = node
            }
            finalNodeByID = finalByID
            rawNodeStampByID = rawNodeStamps
        }
    }

    struct RawObservation {
        var barcode: String
        var symbology: String
        var floorID: String
        /// Snapshot-DB node id produced by the strict parser's
        /// node-timebase binding (V1R4 §13.2 / V1R5 §6.4); never nil for
        /// resolved observations.
        var nodeID: Int64
        /// Node-timebase timestamp of the observation frame (the axis
        /// used for the strict binding); always present.
        var nodeTimestamp: Double
        var frameMonotonicSeconds: Double
        /// Raw map position in the snapshot (pre-optimization) frame;
        /// nil = unlocalized evidence that never reaches resolution.
        var rawPositionM: (Double, Double, Double)? // x, y, z
        var rawNodePose: SE2Transform
        var trackingSessionID: String
        /// V1R5 §5.4: verified-burst linkage (optional at resolution; the
        /// burst gate is enforced by the quality policy).
        var burstID: String?
        var frameID: String?
        var depthQuality: Double = 0
        var viewQuality: String = "unknown"
        var trackingQuality: String = "unknown"
        var measurementConfidence: Double = 0
        var localizationConfidence: Double = 0
        var needsReview: Bool = true
        var measurementMethod: String = "unavailable"
    }

    struct FinalNodePose {
        var id: Int64
        var monotonicSeconds: Double
        var pose: SE2Transform
        var floorID: String
        var uncertaintyM: Double? = nil
    }

    struct ResolvedObservation {
        var barcode: String
        var symbology: String
        var floorID: String
        var mapXM: Double
        var mapYM: Double
        var mapZM: Double
        var nodeID: Int64
        var nodeTimestamp: Double
        var frameMonotonicSeconds: Double
        var trackingSessionID: String
        var bindingMethod: String
        var burstID: String? = nil
        var frameID: String? = nil
        var depthQuality: Double = 0
        var viewQuality: String = "unknown"
        var trackingQuality: String = "unknown"
        var measurementConfidence: Double = 0
        var localizationConfidence: Double = 0
        var needsReview: Bool = true
        var measurementMethod: String = "unavailable"
        var nodeUncertaintyM: Double? = nil
    }

    enum ResolutionError: Error {
        case sessionMismatch
        case nodeMissing
        case rawNodeStampMissing
        case timeDeltaTooLarge
        case staleAlignment
        case unlocalized
    }

    /// Frozen binding re-verification delta (V1R5 §6.4: identical to the
    /// parser gate `maximumNodeTimeDeltaSeconds = 1.0`). The V1R4 5.0 s
    /// nearest-node fallback is deleted.
    static let maximumTimeDeltaSeconds = 1.0

    /// Resolves one raw observation against the final nodes via the
    /// O(1) node index (V1R5 §6.5). The parser-bound node id is the only
    /// resolution path — there is no nearest-node fallback.
    static func resolve(
        observation: RawObservation,
        index: NodeIndex,
        sessionID: String
    ) throws -> ResolvedObservation {
        guard observation.trackingSessionID == sessionID else {
            throw ResolutionError.sessionMismatch
        }
        // The strict parser bound the observation to an exact snapshot
        // node; the same node id must exist in the final optimized
        // reconstruction.
        guard let position = observation.rawPositionM else {
            throw ResolutionError.unlocalized
        }
        guard let node = index.finalNodeByID[observation.nodeID] else {
            throw ResolutionError.nodeMissing
        }
        // Exact stamp re-verification against the raw snapshot node
        // (V1R5 §6.4): the parser bound on the node-timebase axis, so the
        // raw DB stamp must agree with the parser's stamp within the
        // frozen delta. Relative-vs-absolute time comparison is gone.
        guard let rawStamp = index.rawNodeStampByID[observation.nodeID] else {
            throw ResolutionError.rawNodeStampMissing
        }
        let delta = abs(rawStamp - observation.nodeTimestamp)
        guard delta <= maximumTimeDeltaSeconds else {
            throw ResolutionError.timeDeltaTooLarge
        }
        guard node.floorID == observation.floorID else {
            throw ResolutionError.staleAlignment
        }
        // P_final = T_final_node * inverse(T_raw_node) * P_raw
        let local = observation.rawNodePose.inverse.applied(
            to: position.0, position.1)
        let final = node.pose.applied(to: local.0, local.1)
        return ResolvedObservation(
            barcode: observation.barcode,
            symbology: observation.symbology,
            floorID: observation.floorID,
            mapXM: final.0,
            mapYM: final.1,
            mapZM: position.2,
            nodeID: node.id,
            nodeTimestamp: node.monotonicSeconds,
            frameMonotonicSeconds: observation.frameMonotonicSeconds,
            trackingSessionID: sessionID,
            bindingMethod: "explicit_node",
            burstID: observation.burstID,
            frameID: observation.frameID,
            depthQuality: observation.depthQuality,
            viewQuality: observation.viewQuality,
            trackingQuality: observation.trackingQuality,
            measurementConfidence: observation.measurementConfidence,
            localizationConfidence: observation.localizationConfidence,
            needsReview: observation.needsReview,
            measurementMethod: observation.measurementMethod,
            nodeUncertaintyM: node.uncertaintyM
        )
    }

    /// A fused physical tag instance from a burst.
    struct TagInstance {
        var barcode: String
        var symbology: String
        var floorID: String
        var mapXM: Double
        var mapYM: Double
        var observationCount: Int
        var positionSpreadM: Double
        var localizationConfidence: Double
        var measurementConfidence: Double
        var minimumDepthQuality: Double
        var allViewsKnown: Bool
        var trackingQualitySufficient: Bool
        var needsReview: Bool
        var measurementMethodAccepted: Bool
        var maximumNodeUncertaintyM: Double?
        var uniqueVerifiedFrameCount: Int
        var effectiveSampleSize: Double
        var robustOutlierCount: Int
        var associationConfidence: Double
        var nodeIDs: [Int64]
        var burstIDs: Set<String>
        var trackingSessionID: String
    }

    /// Fuses all resolved observations of one physical instance (same
    /// barcode + same floor + spatial proximity). Returns nil when the
    /// burst has no samples.
    static func fuse(
        observations: [ResolvedObservation],
        maximumSpreadM: Double = 0.15,
        minimumBurstSamples: Int = 3
    ) -> TagInstance? {
        guard !observations.isEmpty else { return nil }
        let count = observations.count
        // Robust, evidence-weighted center. Quality weights come from the
        // formal measurement/localization/depth evidence and native node
        // uncertainty; sample count never fabricates confidence.
        let baseWeights = observations.map { observation -> Double in
            guard let uncertainty = observation.nodeUncertaintyM,
                  uncertainty.isFinite, uncertainty > 0 else { return 1.0e-6 }
            let evidence = observation.depthQuality
                * observation.measurementConfidence
                * observation.localizationConfidence
            return max(1.0e-6, evidence / max(uncertainty * uncertainty, 0.0004))
        }
        func weightedCenter(_ weights: [Double]) -> (Double, Double) {
            let total = max(weights.reduce(0, +), 1.0e-9)
            let x = zip(observations, weights).reduce(0.0) {
                $0 + $1.0.mapXM * $1.1
            } / total
            let y = zip(observations, weights).reduce(0.0) {
                $0 + $1.0.mapYM * $1.1
            } / total
            return (x, y)
        }
        var robustWeights = baseWeights
        var center = weightedCenter(robustWeights)
        let huberDelta = max(0.02, maximumSpreadM * 0.5)
        for _ in 0..<3 {
            robustWeights = zip(observations, baseWeights).map { observation, weight in
                let residual = hypot(
                    observation.mapXM - center.0,
                    observation.mapYM - center.1)
                let multiplier = residual <= huberDelta
                    ? 1.0 : huberDelta / max(residual, 1.0e-9)
                return weight * multiplier
            }
            center = weightedCenter(robustWeights)
        }
        let centerX = center.0
        let centerY = center.1
        let maxSpread = observations.reduce(0.0) { current, observation in
            max(current, hypot(observation.mapXM - centerX, observation.mapYM - centerY))
        }
        let weightSum = robustWeights.reduce(0, +)
        let squaredWeightSum = robustWeights.reduce(0) { $0 + $1 * $1 }
        let effectiveSampleSize = squaredWeightSum > 0
            ? weightSum * weightSum / squaredWeightSum : 0
        let frameKeys = observations.compactMap { observation -> String? in
            guard let burstID = observation.burstID, !burstID.isEmpty,
                  let frameID = observation.frameID, !frameID.isEmpty else {
                return nil
            }
            return burstID + "\u{0}" + frameID
        }
        let uncertainties = observations.compactMap(\.nodeUncertaintyM)
        let allUncertaintiesPresent = uncertainties.count == observations.count
        return TagInstance(
            barcode: observations[0].barcode,
            symbology: observations[0].symbology,
            floorID: observations[0].floorID,
            mapXM: SourceGeometry.rounded(centerX),
            mapYM: SourceGeometry.rounded(centerY),
            observationCount: count,
            positionSpreadM: SourceGeometry.rounded(maxSpread),
            localizationConfidence: observations.map(\.localizationConfidence).min() ?? 0,
            measurementConfidence: observations.map(\.measurementConfidence).min() ?? 0,
            minimumDepthQuality: observations.map(\.depthQuality).min() ?? 0,
            allViewsKnown: observations.allSatisfy {
                $0.viewQuality == "front" || $0.viewQuality == "back"
            },
            trackingQualitySufficient: observations.allSatisfy {
                $0.trackingQuality == "stable"
            },
            needsReview: observations.contains { $0.needsReview },
            measurementMethodAccepted: observations.allSatisfy {
                $0.measurementMethod != "unavailable"
            },
            maximumNodeUncertaintyM: allUncertaintiesPresent
                ? uncertainties.max() : nil,
            uniqueVerifiedFrameCount: Set(frameKeys).count,
            effectiveSampleSize: effectiveSampleSize,
            robustOutlierCount: zip(observations, robustWeights).filter {
                observation, _ in
                hypot(observation.mapXM - centerX, observation.mapYM - centerY)
                    > huberDelta
            }.count,
            // Association confidence reflects the internal spread headroom:
            // zero spread is fully confident, a spread at the gate's
            // maximum is borderline (V1R4 §13.2: never a fixed 1.0).
            associationConfidence: max(0.0, min(1.0,
                1.0 - maxSpread / max(maximumSpreadM, 1.0e-9))),
            nodeIDs: observations.map { $0.nodeID },
            burstIDs: Set(observations.compactMap(\.burstID)),
            trackingSessionID: observations[0].trackingSessionID
        )
    }

    /// Clusters resolved observations into physical instances with a
    /// bounded seed radius (V1R4 §13.2). Identity includes barcode,
    /// symbology, floor and tracking session. Every observation admitted
    /// to a cluster lies within `clusterRadiusM` of that cluster's seed;
    /// chained expansion across gaps is deliberately forbidden.
    ///
    /// RC-B16: a radius-sized spatial hash limits every seed lookup to its
    /// 3×3 neighbouring cells. Once an observation joins a cluster it is
    /// marked inactive in O(1), eliminating the previous removeFirst +
    /// scan-all-remaining O(M²) path while preserving seed-radius semantics.
    static func clusterInstances(
        observations: [ResolvedObservation],
        clusterRadiusM: Double = 1.5
    ) -> [TagInstance] {
        func ordered(_ instances: [TagInstance]) -> [TagInstance] {
            return instances.sorted {
                ($0.barcode, $0.symbology, $0.floorID,
                 $0.trackingSessionID, $0.mapXM, $0.mapYM)
                    < ($1.barcode, $1.symbology, $1.floorID,
                       $1.trackingSessionID, $1.mapXM, $1.mapYM)
            }
        }

        guard clusterRadiusM.isFinite, clusterRadiusM > 0 else {
            return ordered(observations.compactMap {
                fuse(observations: [$0])
            })
        }

        struct ClusterIdentity: Hashable {
            let barcode: String
            let symbology: String
            let floorID: String
            let trackingSessionID: String
        }
        struct CellKey: Hashable {
            let identity: ClusterIdentity
            let x: Int64
            let y: Int64
        }

        // Leave one cell of headroom so ±1 neighbour enumeration cannot
        // overflow. Formal map coordinates are finite and many orders of
        // magnitude smaller; out-of-range values fail safe as singletons.
        let cellLimit = Double(Int64.max / 2)
        func cellCoordinate(_ value: Double) -> Int64? {
            let scaled = floor(value / clusterRadiusM)
            guard scaled.isFinite,
                  scaled >= -cellLimit,
                  scaled <= cellLimit else {
                return nil
            }
            return Int64(scaled)
        }
        func cellKey(_ observation: ResolvedObservation) -> CellKey? {
            guard let x = cellCoordinate(observation.mapXM),
                  let y = cellCoordinate(observation.mapYM) else {
                return nil
            }
            return CellKey(
                identity: ClusterIdentity(
                    barcode: observation.barcode,
                    symbology: observation.symbology,
                    floorID: observation.floorID,
                    trackingSessionID: observation.trackingSessionID),
                x: x,
                y: y)
        }

        var cells: [CellKey: [Int]] = [:]
        cells.reserveCapacity(observations.count)
        var keysByIndex = Array<CellKey?>(
            repeating: nil, count: observations.count)
        for index in observations.indices {
            guard let key = cellKey(observations[index]) else { continue }
            keysByIndex[index] = key
            cells[key, default: []].append(index)
        }

        var instances: [TagInstance] = []
        instances.reserveCapacity(observations.count)
        var active = Array(repeating: true, count: observations.count)
        for seedIndex in observations.indices where active[seedIndex] {
            active[seedIndex] = false
            let seed = observations[seedIndex]
            guard let seedKey = keysByIndex[seedIndex] else {
                if let instance = fuse(observations: [seed]) {
                    instances.append(instance)
                }
                continue
            }

            var clusterIndices = [seedIndex]
            for deltaX in -1...1 {
                for deltaY in -1...1 {
                    let neighbour = CellKey(
                        identity: seedKey.identity,
                        x: seedKey.x + Int64(deltaX),
                        y: seedKey.y + Int64(deltaY))
                    guard let candidates = cells[neighbour] else { continue }
                    for candidateIndex in candidates where active[candidateIndex] {
                        let candidate = observations[candidateIndex]
                        if hypot(
                            candidate.mapXM - seed.mapXM,
                            candidate.mapYM - seed.mapYM) <= clusterRadiusM {
                            active[candidateIndex] = false
                            clusterIndices.append(candidateIndex)
                        }
                    }
                }
            }
            // Match the legacy input-order accumulation so floating-point
            // centroids remain reproducible across the algorithm change.
            clusterIndices.sort()
            let cluster = clusterIndices.map { observations[$0] }
            if let instance = fuse(observations: cluster) {
                instances.append(instance)
            }
        }
        return ordered(instances)
    }
}
