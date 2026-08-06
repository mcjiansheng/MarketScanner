import Foundation

/// Resolves raw tag observations against the final optimized trajectory
/// and fuses multi-frame bursts into physical tag instances.
///
/// Binding priority (per the product contract): explicit node ID with a
/// matching timestamp, then nearest node timestamp, then the frame
/// monotonic timestamp. Position propagation is
/// P_final = T_final_node * inverse(T_raw_node) * P_raw; 3D is preserved
/// internally, the business output is 2D. Same barcode on different
/// shelves/floors stays distinct instances — barcodes are never globally
/// deduplicated.
enum TagObservationResolver {
    struct RawObservation {
        var barcode: String
        var symbology: String
        var floorID: String
        /// Snapshot-DB node id produced by the strict parser's
        /// node-timebase binding (V1R4 §13.2); never nil for resolved
        /// observations.
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
        case timeDeltaTooLarge
        case ambiguousNearbyNodes
        case staleAlignment
        case unlocalized
    }

    static let maximumTimeDeltaSeconds = 5.0
    static let maximumNodeAmbiguityDeltaSeconds = 0.5

    /// Resolves one raw observation against the final nodes.
    static func resolve(
        observation: RawObservation,
        finalNodes: [FinalNodePose],
        sessionID: String
    ) throws -> ResolvedObservation {
        guard observation.trackingSessionID == sessionID else {
            throw ResolutionError.sessionMismatch
        }
        // The strict parser bound the observation to an exact snapshot
        // node (V1R4 §13.2); the same node id must exist in the final
        // optimized reconstruction.
        guard let position = observation.rawPositionM else {
            throw ResolutionError.unlocalized
        }
        guard let node = finalNodes.first(where: { $0.id == observation.nodeID }) else {
            throw ResolutionError.nodeMissing
        }
        let delta = abs(node.monotonicSeconds - observation.nodeTimestamp)
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
