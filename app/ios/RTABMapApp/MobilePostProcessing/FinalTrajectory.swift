import Foundation

/// Final optimized trajectory building and one-hertz resampling.
///
/// DevicePositions are one row per UTC second in
/// [ceil(session start), floor(session end)], interpolated only across
/// connected trajectory segments. Any second that falls inside a lost /
/// disconnected interval, a floor change, an over-long node gap or a
/// clock discontinuity is emitted as UNAVAILABLE — never guessed.
///
/// V1R5 §11.1 (review B-10): the resampler is ONE PASS with monotonic
/// multi-pointers over the clock samples, lost intervals and trajectory
/// nodes — O(S + C + L + N) in the number of output seconds, clock
/// samples, lost intervals and nodes. The V1R4 per-second full scans
/// (O(S × (C + L + N))) are gone.
enum FinalTrajectory {
    struct Node {
        var id: Int64
        var monotonicSeconds: Double
        var xM: Double
        var yM: Double
        var yawRad: Double
        /// Native uncertainty; nil = cannot be estimated (V1R5 §11.2:
        /// NEVER fabricated as 0.0 — a nil-uncertainty node cannot anchor
        /// an AVAILABLE row).
        var uncertaintyM: Double?
        var floorID: String
    }

    struct LostInterval {
        var fromMonotonic: Double
        var toMonotonic: Double
        var reason: String
    }

    /// Real trace state for the business row status (V1R5 §11.3/H-20):
    /// one record per trace sample, sorted by timestamp. The resampler
    /// uses the closest record to each interpolated row.
    struct TraceState {
        var timestamp: Double
        var trackingState: String
        var localizationState: String
        var confidence: Double?
        var floorID: String
    }

    struct Input {
        var nodes: [Node]
        var lostIntervals: [LostInterval]
        var sessionStartUTC: Double
        var sessionEndUTC: Double
        /// V1R5 §11.3: real per-row business state source.
        var traceStates: [TraceState] = []
    }

    /// One row of the DevicePositions worksheet.
    struct DevicePositionRow: Equatable {
        var sequence: Int
        var localTimestamp: String
        var utcTimestamp: String
        var unixTimeS: Int64
        var timezoneID: String
        var utcOffset: Int
        var sessionElapsedS: Double
        var storeID: String
        var floorID: String
        var mapXM: Double?
        var mapYM: Double?
        var yawDeg: Double?
        var positionStatus: String
        var positionSource: String
        var beforeNodeID: Int64?
        var afterNodeID: Int64?
        var interpolationRatio: Double?
        var localizationConfidence: Double?
        var estimatedUncertaintyM: Double?
        var uncertaintySource: String?
        var trackingState: String
        var graphQualityStatus: String
        var priorMapID: String
        var priorMapSha256: String
        var trackingSessionID: String
        var appGitSHA: String

        var canonicalPayload: [String: Any] {
            var payload: [String: Any] = [
                "sequence": sequence,
                "local_timestamp": localTimestamp,
                "utc_timestamp": utcTimestamp,
                "unix_time_s": unixTimeS,
                "timezone_id": timezoneID,
                "utc_offset": utcOffset,
                "session_elapsed_s": SourceGeometry.rounded(sessionElapsedS),
                "store_id": storeID,
                "floor_id": floorID,
                "position_status": positionStatus,
                "position_source": positionSource,
                "tracking_state": trackingState,
                "graph_quality_status": graphQualityStatus,
                "prior_map_id": priorMapID,
                "prior_map_sha256": priorMapSha256,
                "tracking_session_id": trackingSessionID,
                "app_git_sha": appGitSHA,
            ]
            if let mapXM = mapXM { payload["map_x_m"] = mapXM }
            if let mapYM = mapYM { payload["map_y_m"] = mapYM }
            if let yawDeg = yawDeg { payload["yaw_deg"] = yawDeg }
            if let before = beforeNodeID { payload["before_node_id"] = before }
            if let after = afterNodeID { payload["after_node_id"] = after }
            if let ratio = interpolationRatio { payload["interpolation_ratio"] = ratio }
            if let confidence = localizationConfidence { payload["localization_confidence"] = confidence }
            if let uncertainty = estimatedUncertaintyM { payload["estimated_uncertainty_m"] = uncertainty }
            if let source = uncertaintySource { payload["uncertainty_source"] = source }
            return payload
        }
    }

    enum ResamplePolicy {
        /// Maximum monotonic gap between two trajectory nodes across
        /// which interpolation is allowed.
        static let maximumInterpolationGapSeconds = 3.0
    }

    /// Resamples the optimized trajectory to one row per UTC second with
    /// a single pass (V1R5 §11.1): monotonic pointers over the clock
    /// samples, lost intervals, trace states and trajectory nodes.
    static func resample(
        input: Input,
        utcMapper: MonotonicUTCMapper,
        storeID: String,
        priorMapID: String,
        priorMapSha256: String,
        trackingSessionID: String,
        appGitSHA: String
    ) -> [DevicePositionRow] {
        let nodes = input.nodes.sorted { $0.monotonicSeconds < $1.monotonicSeconds }
        let lostIntervals = input.lostIntervals.sorted {
            if $0.fromMonotonic == $1.fromMonotonic {
                return $0.toMonotonic < $1.toMonotonic
            }
            return $0.fromMonotonic < $1.fromMonotonic
        }
        let traceStates = input.traceStates.sorted { $0.timestamp < $1.timestamp }
        let startSecond = ceil(input.sessionStartUTC)
        let endSecond = floor(input.sessionEndUTC)
        guard startSecond <= endSecond, !nodes.isEmpty else {
            return []
        }
        var rows: [DevicePositionRow] = []
        // V1R5 §11.1 monotonic multi-pointers (each advances only).
        var clockIndex = 0
        var lostIndex = 0
        var nodeIndex = 0
        var traceIndex = 0
        var sequence = 0
        var lastKnownFloor: String?
        var target = startSecond
        while target <= endSecond {
            sequence += 1
            let targetUTC = target
            // Find the monotonic time for this UTC second (one pass).
            guard let monotonic = inverseMap(
                utcMapper: utcMapper,
                utc: targetUTC,
                clockIndex: &clockIndex) else {
                let floor = lastKnownFloor ?? ""
                rows.append(unavailableRow(
                    sequence: sequence, unixTimeS: Int64(targetUTC), monotonic: nil,
                    utcMapper: utcMapper, storeID: storeID, floorID: floor,
                    priorMapID: priorMapID, priorMapSha256: priorMapSha256,
                    trackingSessionID: trackingSessionID, appGitSHA: appGitSHA,
                    reason: "clock_discontinuity",
                    traceState: nearestTraceState(
                        monotonic: nil, traceStates: traceStates,
                        traceIndex: &traceIndex)))
                target += 1
                continue
            }
            let lostReason = insideLostInterval(
                monotonic, lostIntervals: lostIntervals,
                lostIndex: &lostIndex)
            if let lostReason {
                let floor = lastKnownFloor ?? ""
                rows.append(unavailableRow(
                    sequence: sequence, unixTimeS: Int64(targetUTC), monotonic: monotonic,
                    utcMapper: utcMapper, storeID: storeID, floorID: floor,
                    priorMapID: priorMapID, priorMapSha256: priorMapSha256,
                    trackingSessionID: trackingSessionID, appGitSHA: appGitSHA,
                    reason: lostReason,
                    traceState: nearestTraceState(
                        monotonic: monotonic, traceStates: traceStates,
                        traceIndex: &traceIndex)))
                target += 1
                continue
            }
            if let position = interpolate(
                monotonic: monotonic, nodes: nodes, nodeIndex: &nodeIndex) {
                if let floor = position.floorID {
                    lastKnownFloor = floor
                }
                rows.append(availableRow(
                    sequence: sequence, unixTimeS: Int64(targetUTC), monotonic: monotonic,
                    position: position, utcMapper: utcMapper, storeID: storeID,
                    priorMapID: priorMapID, priorMapSha256: priorMapSha256,
                    trackingSessionID: trackingSessionID, appGitSHA: appGitSHA,
                    traceState: nearestTraceState(
                        monotonic: monotonic, traceStates: traceStates,
                        traceIndex: &traceIndex)))
            } else {
                let floor = lastKnownFloor ?? ""
                rows.append(unavailableRow(
                    sequence: sequence, unixTimeS: Int64(targetUTC), monotonic: monotonic,
                    utcMapper: utcMapper, storeID: storeID, floorID: floor,
                    priorMapID: priorMapID, priorMapSha256: priorMapSha256,
                    trackingSessionID: trackingSessionID, appGitSHA: appGitSHA,
                    reason: "no_reliable_position",
                    traceState: nearestTraceState(
                        monotonic: monotonic, traceStates: traceStates,
                        traceIndex: &traceIndex)))
            }
            target += 1
        }
        return rows
    }

    private struct InterpolatedPosition {
        var xM: Double
        var yM: Double
        var yawRad: Double
        /// Nil when neither endpoint carries a native uncertainty
        /// (V1R5 §11.2: never 0.0).
        var uncertaintyM: Double?
        var beforeNodeID: Int64
        var afterNodeID: Int64
        var ratio: Double
        var floorID: String?
    }

    /// Interpolates with a monotonic node pointer (V1R5 §11.1): each
    /// query only advances `nodeIndex`. Input nodes must be sorted.
    private static func interpolate(
        monotonic: Double,
        nodes: [Node],
        nodeIndex: inout Int
    ) -> InterpolatedPosition? {
        // Advance the pointer while the next node is still at/before the
        // query time.
        while nodeIndex + 1 < nodes.count,
              nodes[nodeIndex + 1].monotonicSeconds <= monotonic {
            nodeIndex += 1
        }
        guard nodeIndex + 1 < nodes.count else {
            // Past the last node; the pointer stays put (the next query
            // is later, so the loop above cannot rewind).
            if nodes[nodeIndex].monotonicSeconds <= monotonic {
                return nil
            }
            // Before the first node (nodeIndex was advanced by a previous
            // query): cannot interpolate.
            return nil
        }
        let before = nodes[nodeIndex]
        let after = nodes[nodeIndex + 1]
        guard before.monotonicSeconds <= monotonic,
              after.monotonicSeconds >= monotonic else {
            return nil
        }
        // Floor change: never interpolate across it.
        guard after.floorID == before.floorID else {
            return nil
        }
        let span = after.monotonicSeconds - before.monotonicSeconds
        guard span > 1.0e-9, span <= ResamplePolicy.maximumInterpolationGapSeconds else {
            return nil
        }
        let ratio = (monotonic - before.monotonicSeconds) / span
        let xM = before.xM + (after.xM - before.xM) * ratio
        let yM = before.yM + (after.yM - before.yM) * ratio
        let yawRad = before.yawRad + SourceGeometry.shortestAngleDifference(before.yawRad, after.yawRad) * ratio
        // V1R5 §11.2: conservative upper bound of the two samples when
        // both are known; nil when either is unknown (never 0.0).
        let uncertaintyM: Double?
        if let beforeU = before.uncertaintyM, let afterU = after.uncertaintyM {
            uncertaintyM = max(beforeU, afterU)
        } else {
            uncertaintyM = nil
        }
        return InterpolatedPosition(
            xM: xM, yM: yM, yawRad: yawRad, uncertaintyM: uncertaintyM,
            beforeNodeID: before.id, afterNodeID: after.id, ratio: ratio,
            floorID: before.floorID)
    }

    /// Lost-interval membership with a monotonic pointer (V1R5 §11.1):
    /// intervals are sorted by `fromMonotonic`; the pointer skips
    /// intervals that end before the query time.
    private static func insideLostInterval(
        _ monotonic: Double,
        lostIntervals: [LostInterval],
        lostIndex: inout Int
    ) -> String? {
        while lostIndex < lostIntervals.count,
              lostIntervals[lostIndex].toMonotonic < monotonic {
            lostIndex += 1
        }
        if lostIndex < lostIntervals.count,
           monotonic >= lostIntervals[lostIndex].fromMonotonic,
           monotonic <= lostIntervals[lostIndex].toMonotonic {
            return lostIntervals[lostIndex].reason
        }
        return nil
    }

    /// Nearest trace state with a monotonic pointer (V1R5 §11.3): the
    /// pointer advances while the next trace is still closer to the query
    /// time. `nil` monotonic (clock discontinuity) keeps the pointer.
    private static func nearestTraceState(
        monotonic: Double?,
        traceStates: [TraceState],
        traceIndex: inout Int
    ) -> TraceState? {
        guard !traceStates.isEmpty else { return nil }
        guard let monotonic else {
            return traceStates[max(0, min(traceIndex, traceStates.count - 1))]
        }
        while traceIndex + 1 < traceStates.count,
              abs(traceStates[traceIndex + 1].timestamp - monotonic)
                < abs(traceStates[traceIndex].timestamp - monotonic) {
            traceIndex += 1
        }
        return traceStates[traceIndex]
    }

    /// Inverts the monotonic -> UTC mapping with a monotonic segment
    /// pointer (V1R5 §11.1). Non-discontinuity segments are contiguous in
    /// UTC (utc is monotonic across them), so each query only advances
    /// `clockIndex`; discontinuity edges are skipped and never inverted
    /// across. A bounded outer-edge extrapolation of at most the mapper's
    /// maximum is allowed.
    private static func inverseMap(
        utcMapper: MonotonicUTCMapper,
        utc: Double,
        clockIndex: inout Int
    ) -> Double? {
        let samples = utcMapper.samples
        guard samples.count >= 2 else { return nil }
        // Bounded outer-edge extrapolation (only when the adjacent edge
        // is continuous), so the first/last session seconds can still map.
        if let first = samples.first,
           !utcMapper.discontinuityEdges.contains(0),
           utc < first.utcUnixSeconds,
           first.utcUnixSeconds - utc
            <= MonotonicUTCMapper.maximumOuterExtrapolationSeconds {
            let b = samples[1]
            let spanUTC = b.utcUnixSeconds - first.utcUnixSeconds
            if abs(spanUTC) > 1.0e-9 {
                let ratio = (utc - first.utcUnixSeconds) / spanUTC
                return first.monotonicSeconds
                    + (b.monotonicSeconds - first.monotonicSeconds) * ratio
            }
        }
        if let last = samples.last,
           !utcMapper.discontinuityEdges.contains(samples.count - 2),
           utc > last.utcUnixSeconds,
           utc - last.utcUnixSeconds
            <= MonotonicUTCMapper.maximumOuterExtrapolationSeconds {
            let a = samples[samples.count - 2]
            let spanUTC = last.utcUnixSeconds - a.utcUnixSeconds
            if abs(spanUTC) > 1.0e-9 {
                let ratio = (utc - a.utcUnixSeconds) / spanUTC
                return a.monotonicSeconds
                    + (last.monotonicSeconds - a.monotonicSeconds) * ratio
            }
        }
        // Slight tolerance at the edges.
        if let first = samples.first, abs(utc - first.utcUnixSeconds) < 0.001 {
            return first.monotonicSeconds
        }
        if let last = samples.last, abs(utc - last.utcUnixSeconds) < 0.001 {
            return last.monotonicSeconds
        }
        // Monotonic segment scan: non-discontinuity segments tile the
        // continuous UTC span, so the pointer never rewinds.
        var index = max(0, min(clockIndex, samples.count - 2))
        while index < samples.count - 1 {
            if utcMapper.discontinuityEdges.contains(index) {
                index += 1
                continue
            }
            let a = samples[index]
            let b = samples[index + 1]
            let aUTC = a.utcUnixSeconds
            let bUTC = b.utcUnixSeconds
            if (utc >= aUTC && utc <= bUTC) || (utc <= aUTC && utc >= bUTC) {
                let spanUTC = bUTC - aUTC
                guard abs(spanUTC) > 1.0e-9 else {
                    index += 1
                    continue
                }
                let ratio = (utc - aUTC) / spanUTC
                clockIndex = index
                return a.monotonicSeconds
                    + (b.monotonicSeconds - a.monotonicSeconds) * ratio
            }
            if utc < min(aUTC, bUTC) {
                // Continuous segments are ordered in utc, so no later
                // segment can cover this target: fail closed.
                return nil
            }
            index += 1
        }
        return nil
    }

    private static func availableRow(
        sequence: Int,
        unixTimeS: Int64,
        monotonic: Double,
        position: InterpolatedPosition,
        utcMapper: MonotonicUTCMapper,
        storeID: String,
        priorMapID: String,
        priorMapSha256: String,
        trackingSessionID: String,
        appGitSHA: String,
        traceState: TraceState?
    ) -> DevicePositionRow {
        let context = utcMapper.context(forMonotonic: monotonic)
        let localTimestamp = formatLocalTimestamp(
            unixTimeS: Double(unixTimeS), offsetSeconds: context.utcOffsetSeconds)
        let utcTimestamp = formatUTCTimestamp(unixTimeS: Double(unixTimeS))
        // V1R5 §11.2: a row without a native uncertainty must not pretend
        // perfect determinism. It stays AVAILABLE only with an explicit
        // conservative upper bound sourced as such; with no uncertainty
        // evidence at all the position is emitted as UNAVAILABLE.
        let uncertaintyM = position.uncertaintyM
        let positionStatus = uncertaintyM.map { _ in "AVAILABLE" } ?? "UNAVAILABLE"
        return DevicePositionRow(
            sequence: sequence,
            localTimestamp: localTimestamp,
            utcTimestamp: utcTimestamp,
            unixTimeS: unixTimeS,
            timezoneID: context.timezoneID,
            utcOffset: context.utcOffsetSeconds,
            sessionElapsedS: monotonic,
            storeID: storeID,
            floorID: position.floorID ?? "",
            mapXM: positionStatus == "AVAILABLE" ? SourceGeometry.rounded(position.xM) : nil,
            mapYM: positionStatus == "AVAILABLE" ? SourceGeometry.rounded(position.yM) : nil,
            yawDeg: positionStatus == "AVAILABLE"
                ? SourceGeometry.rounded(position.yawRad * 180.0 / Double.pi) : nil,
            positionStatus: positionStatus,
            positionSource: "final_trajectory",
            beforeNodeID: positionStatus == "AVAILABLE" ? position.beforeNodeID : nil,
            afterNodeID: positionStatus == "AVAILABLE" ? position.afterNodeID : nil,
            interpolationRatio: positionStatus == "AVAILABLE"
                ? SourceGeometry.rounded(position.ratio) : nil,
            localizationConfidence: traceState?.confidence,
            estimatedUncertaintyM: uncertaintyM.map { SourceGeometry.rounded($0) },
            uncertaintySource: uncertaintyM.map { _ in "native_covariance_upper_bound" },
            trackingState: traceState?.trackingState ?? "unknown",
            graphQualityStatus: positionStatus == "AVAILABLE" ? "connected" : "unavailable",
            priorMapID: priorMapID,
            priorMapSha256: priorMapSha256,
            trackingSessionID: trackingSessionID,
            appGitSHA: appGitSHA
        )
    }

    private static func unavailableRow(
        sequence: Int,
        unixTimeS: Int64,
        monotonic: Double?,
        utcMapper: MonotonicUTCMapper,
        storeID: String,
        floorID: String,
        priorMapID: String,
        priorMapSha256: String,
        trackingSessionID: String,
        appGitSHA: String,
        reason: String,
        traceState: TraceState?
    ) -> DevicePositionRow {
        let context: (timezoneID: String, utcOffsetSeconds: Int)
        if let monotonic = monotonic {
            context = utcMapper.context(forMonotonic: monotonic)
        } else {
            context = (utcMapper.samples.first?.timezoneID ?? "UTC",
                       utcMapper.samples.first?.utcOffsetSeconds ?? 0)
        }
        return DevicePositionRow(
            sequence: sequence,
            localTimestamp: formatLocalTimestamp(
                unixTimeS: Double(unixTimeS), offsetSeconds: context.utcOffsetSeconds),
            utcTimestamp: formatUTCTimestamp(unixTimeS: Double(unixTimeS)),
            unixTimeS: unixTimeS,
            timezoneID: context.timezoneID,
            utcOffset: context.utcOffsetSeconds,
            sessionElapsedS: monotonic ?? -1,
            storeID: storeID,
            // V1R5 §11.4: keep the last known trusted floor when known;
            // the caller passes "" when truly unknown.
            floorID: floorID,
            mapXM: nil,
            mapYM: nil,
            yawDeg: nil,
            positionStatus: "UNAVAILABLE",
            positionSource: "final_trajectory",
            beforeNodeID: nil,
            afterNodeID: nil,
            interpolationRatio: nil,
            localizationConfidence: traceState?.confidence,
            estimatedUncertaintyM: nil,
            uncertaintySource: nil,
            trackingState: traceState?.trackingState ?? "lost",
            graphQualityStatus: "unavailable",
            priorMapID: priorMapID,
            priorMapSha256: priorMapSha256,
            trackingSessionID: trackingSessionID,
            appGitSHA: appGitSHA
        )
    }

    /// Formats `yyyy-MM-dd HH:mm:ss.SSS +HH:mm` in the given offset —
    /// deterministic, locale-independent.
    static func formatLocalTimestamp(unixTimeS: Double, offsetSeconds: Int) -> String {
        let shifted = unixTimeS + Double(offsetSeconds)
        let whole = Int64(floor(shifted))
        let milliseconds = Int((shifted - Double(whole)) * 1000.0)
        let components = utcComponents(whole)
        let offsetSign = offsetSeconds < 0 ? "-" : "+"
        let offsetAbs = abs(offsetSeconds)
        let offsetHours = offsetAbs / 3600
        let offsetMinutes = (offsetAbs % 3600) / 60
        return String(
            format: "%04d-%02d-%02d %02d:%02d:%02d.%03d %@%02d:%02d",
            components.year, components.month, components.day,
            components.hour, components.minute, components.second,
            milliseconds, offsetSign, offsetHours, offsetMinutes)
    }

    static func formatUTCTimestamp(unixTimeS: Double) -> String {
        let whole = Int64(floor(unixTimeS))
        let milliseconds = Int((unixTimeS - Double(whole)) * 1000.0)
        let components = utcComponents(whole)
        return String(
            format: "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ",
            components.year, components.month, components.day,
            components.hour, components.minute, components.second,
            milliseconds)
    }

    private static func utcComponents(_ seconds: Int64) -> (year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int) {
        var remaining = seconds
        let days = remaining / 86400
        remaining %= 86400
        if remaining < 0 {
            remaining += 86400
        }
        let hour = Int(remaining / 3600)
        remaining %= 3600
        let minute = Int(remaining / 60)
        let second = Int(remaining % 60)
        // Civil-from-days (Howard Hinnant's algorithm).
        let z = days + 719468
        let era = z >= 0 ? z : z - 146096
        let eraDays = era % 146097
        let correctedEra = eraDays >= 0 ? eraDays : eraDays + 146097
        let doe = correctedEra
        let year = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
        let doy = doe - (365 * year + year / 4 - year / 100)
        let mp = (5 * doy + 2) / 153
        let day = Int(doy - (153 * mp + 2) / 5 + 1)
        let month = Int(mp < 10 ? mp + 3 : mp - 9)
        let civilYear = Int(year) + (month <= 2 ? 1 : 0)
        return (civilYear, month, day, hour, minute, second)
    }
}
