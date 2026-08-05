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
        var nodeID: Int64?
        var nodeTimestamp: Double?
        var frameMonotonicSeconds: Double
        var rawPositionM: (Double, Double, Double) // x, y, z
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
        let candidate: FinalNodePose
        let method: String
        if let nodeID = observation.nodeID {
            guard let node = finalNodes.first(where: { $0.id == nodeID }) else {
                throw ResolutionError.nodeMissing
            }
            if let nodeTimestamp = observation.nodeTimestamp {
                let delta = abs(node.monotonicSeconds - nodeTimestamp)
                guard delta <= maximumTimeDeltaSeconds else {
                    throw ResolutionError.timeDeltaTooLarge
                }
            }
            candidate = node
            method = "explicit_node"
        } else if let nodeTimestamp = observation.nodeTimestamp {
            let nearby = finalNodes
                .filter { abs($0.monotonicSeconds - nodeTimestamp) <= maximumTimeDeltaSeconds }
                .sorted { abs($0.monotonicSeconds - nodeTimestamp) < abs($1.monotonicSeconds - nodeTimestamp) }
            guard let nearest = nearby.first else {
                throw ResolutionError.nodeMissing
            }
            if nearby.count >= 2 {
                let secondDelta = abs(nearby[1].monotonicSeconds - nodeTimestamp)
                let firstDelta = abs(nearby[0].monotonicSeconds - nodeTimestamp)
                if secondDelta - firstDelta <= maximumNodeAmbiguityDeltaSeconds {
                    throw ResolutionError.ambiguousNearbyNodes
                }
            }
            candidate = nearest
            method = "nearest_node_timestamp"
        } else {
            let nearby = finalNodes
                .filter { abs($0.monotonicSeconds - observation.frameMonotonicSeconds) <= maximumTimeDeltaSeconds }
                .sorted { abs($0.monotonicSeconds - observation.frameMonotonicSeconds) < abs($1.monotonicSeconds - observation.frameMonotonicSeconds) }
            guard let nearest = nearby.first else {
                throw ResolutionError.nodeMissing
            }
            candidate = nearest
            method = "frame_monotonic_timestamp"
        }
        guard candidate.floorID == observation.floorID else {
            throw ResolutionError.staleAlignment
        }
        // P_final = T_final_node * inverse(T_raw_node) * P_raw
        let local = observation.rawNodePose.inverse.applied(
            to: observation.rawPositionM.0, observation.rawPositionM.1)
        let final = candidate.pose.applied(to: local.0, local.1)
        return ResolvedObservation(
            barcode: observation.barcode,
            symbology: observation.symbology,
            floorID: observation.floorID,
            mapXM: final.0,
            mapYM: final.1,
            mapZM: observation.rawPositionM.2,
            nodeID: candidate.id,
            nodeTimestamp: candidate.monotonicSeconds,
            frameMonotonicSeconds: observation.frameMonotonicSeconds,
            trackingSessionID: sessionID,
            bindingMethod: method
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
            associationConfidence: 1.0,
            nodeIDs: observations.map { $0.nodeID },
            trackingSessionID: observations[0].trackingSessionID
        )
    }

    /// Clusters resolved observations into physical instances: same
    /// barcode, same floor and spatial proximity form one instance;
    /// distant same-barcode groups stay separate instances.
    static func clusterInstances(
        observations: [ResolvedObservation],
        clusterRadiusM: Double = 1.5
    ) -> [TagInstance] {
        var instances: [TagInstance] = []
        var remaining = observations
        while !remaining.isEmpty {
            let seed = remaining.removeFirst()
            var cluster = [seed]
            var changed = true
            while changed {
                changed = false
                var kept: [ResolvedObservation] = []
                for observation in remaining {
                    let near = cluster.contains {
                        $0.barcode == observation.barcode
                            && $0.floorID == observation.floorID
                            && hypot($0.mapXM - observation.mapXM, $0.mapYM - observation.mapYM) <= clusterRadiusM
                    }
                    if near {
                        cluster.append(observation)
                        changed = true
                    } else {
                        kept.append(observation)
                    }
                }
                remaining = kept
            }
            if let instance = fuse(observations: cluster) {
                instances.append(instance)
            }
        }
        return instances.sorted {
            ($0.barcode, $0.floorID, $0.mapXM) < ($1.barcode, $1.floorID, $1.mapXM)
        }
    }
}
