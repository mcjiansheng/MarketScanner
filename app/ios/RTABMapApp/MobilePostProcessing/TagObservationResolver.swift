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
    }

    struct FinalNodePose {
        var id: Int64
        var monotonicSeconds: Double
        var pose: SE2Transform
        var floorID: String
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
            bindingMethod: "explicit_node"
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
        var associationConfidence: Double
        var nodeIDs: [Int64]
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
        let centerX = observations.map { $0.mapXM }.reduce(0, +) / Double(count)
        let centerY = observations.map { $0.mapYM }.reduce(0, +) / Double(count)
        let maxSpread = observations.reduce(0.0) { current, observation in
            max(current, hypot(observation.mapXM - centerX, observation.mapYM - centerY))
        }
        return TagInstance(
            barcode: observations[0].barcode,
            symbology: observations[0].symbology,
            floorID: observations[0].floorID,
            mapXM: SourceGeometry.rounded(centerX),
            mapYM: SourceGeometry.rounded(centerY),
            observationCount: count,
            positionSpreadM: SourceGeometry.rounded(maxSpread),
            localizationConfidence: min(1.0, Double(count) / Double(max(minimumBurstSamples, 1))),
            // Association confidence reflects the internal spread headroom:
            // zero spread is fully confident, a spread at the gate's
            // maximum is borderline (V1R4 §13.2: never a fixed 1.0).
            associationConfidence: max(0.0, min(1.0,
                1.0 - maxSpread / max(maximumSpreadM, 1.0e-9))),
            nodeIDs: observations.map { $0.nodeID },
            trackingSessionID: observations[0].trackingSessionID
        )
    }

    /// Clusters resolved observations into physical instances with a
    /// bounded diameter (V1R4 §13.2): same barcode + same floor form one
    /// instance only when every observation lies within `clusterRadiusM`
    /// of the seed. Chained expansion across gaps is NOT allowed — a
    /// distant same-barcode group (e.g. on the next shelf) starts its own
    /// instance and is quality-gated independently.
    static func clusterInstances(
        observations: [ResolvedObservation],
        clusterRadiusM: Double = 1.5
    ) -> [TagInstance] {
        var instances: [TagInstance] = []
        var remaining = observations
        while !remaining.isEmpty {
            let seed = remaining.removeFirst()
            var cluster = [seed]
            var kept: [ResolvedObservation] = []
            for observation in remaining {
                if observation.barcode == seed.barcode
                    && observation.floorID == seed.floorID
                    && hypot(observation.mapXM - seed.mapXM,
                             observation.mapYM - seed.mapYM) <= clusterRadiusM {
                    cluster.append(observation)
                } else {
                    kept.append(observation)
                }
            }
            remaining = kept
            if let instance = fuse(observations: cluster) {
                instances.append(instance)
            }
        }
        return instances.sorted {
            ($0.barcode, $0.floorID, $0.mapXM) < ($1.barcode, $1.floorID, $1.mapXM)
        }
    }
}
