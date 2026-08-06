import Foundation

/// Final optimized trajectory building and one-hertz resampling.
///
/// DevicePositions are one row per UTC second in
/// [ceil(session start), floor(session end)], interpolated only across
/// connected trajectory segments. Any second that falls inside a lost /
/// disconnected interval, a floor change, an over-long node gap or a
/// clock discontinuity is emitted as UNAVAILABLE — never guessed.
enum FinalTrajectory {
    struct Node {
        var id: Int64
        var monotonicSeconds: Double
        var xM: Double
        var yM: Double
        var yawRad: Double
        var uncertaintyM: Double
        var floorID: String
    }

    struct LostInterval {
        var fromMonotonic: Double
        var toMonotonic: Double
        var reason: String
    }

    struct Input {
        var nodes: [Node]
        var lostIntervals: [LostInterval]
        var sessionStartUTC: Double
        var sessionEndUTC: Double
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
            return payload
        }
    }

    enum ResamplePolicy {
        /// Maximum monotonic gap between two trajectory nodes across
        /// which interpolation is allowed.
        static let maximumInterpolationGapSeconds = 3.0
    }

    /// Resamples the optimized trajectory to one row per UTC second.
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
        let startSecond = ceil(input.sessionStartUTC)
        let endSecond = floor(input.sessionEndUTC)
        guard startSecond <= endSecond, !nodes.isEmpty else {
            return []
        }
        var rows: [DevicePositionRow] = []
        var sequence = 0
        var target = startSecond
        while target <= endSecond {
            sequence += 1
            let targetUTC = target
            // Find the monotonic time for this UTC second.
            guard let monotonic = inverseMap(utcMapper: utcMapper, utc: targetUTC) else {
                rows.append(unavailableRow(
                    sequence: sequence, unixTimeS: Int64(targetUTC), monotonic: nil,
                    utcMapper: utcMapper, storeID: storeID, floorID: "",
                    priorMapID: priorMapID, priorMapSha256: priorMapSha256,
                    trackingSessionID: trackingSessionID, appGitSHA: appGitSHA,
                    reason: "clock_discontinuity"))
                target += 1
                continue
            }
            if insideLostInterval(monotonic, lostIntervals: input.lostIntervals) {
                let reason = input.lostIntervals.first {
                    monotonic >= $0.fromMonotonic && monotonic <= $0.toMonotonic
                }?.reason ?? "lost_interval"
                rows.append(unavailableRow(
                    sequence: sequence, unixTimeS: Int64(targetUTC), monotonic: monotonic,
                    utcMapper: utcMapper, storeID: storeID, floorID: "",
                    priorMapID: priorMapID, priorMapSha256: priorMapSha256,
                    trackingSessionID: trackingSessionID, appGitSHA: appGitSHA,
                    reason: reason))
                target += 1
                continue
            }
            if let position = interpolate(monotonic: monotonic, nodes: nodes) {
                rows.append(availableRow(
                    sequence: sequence, unixTimeS: Int64(targetUTC), monotonic: monotonic,
                    position: position, utcMapper: utcMapper, storeID: storeID,
                    priorMapID: priorMapID, priorMapSha256: priorMapSha256,
                    trackingSessionID: trackingSessionID, appGitSHA: appGitSHA))
            } else {
                rows.append(unavailableRow(
                    sequence: sequence, unixTimeS: Int64(targetUTC), monotonic: monotonic,
                    utcMapper: utcMapper, storeID: storeID, floorID: "",
                    priorMapID: priorMapID, priorMapSha256: priorMapSha256,
                    trackingSessionID: trackingSessionID, appGitSHA: appGitSHA,
                    reason: "no_reliable_position"))
            }
            target += 1
        }
        return rows
    }

    private struct InterpolatedPosition {
        var xM: Double
        var yM: Double
        var yawRad: Double
        var uncertaintyM: Double
        var beforeNodeID: Int64
        var afterNodeID: Int64
        var ratio: Double
        var floorID: String
    }

    private static func interpolate(monotonic: Double, nodes: [Node]) -> InterpolatedPosition? {
        var lower: Node?
        var upper: Node?
        for node in nodes {
            if node.monotonicSeconds <= monotonic {
                lower = node
            } else {
                upper = node
                break
            }
        }
        guard let before = lower, let after = upper else {
            return nil
        }
        guard after.floorID == before.floorID else {
            // Floor change: never interpolate across it.
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
        // Conservative uncertainty: upper bound of the two samples.
        let uncertaintyM = max(before.uncertaintyM, after.uncertaintyM)
        return InterpolatedPosition(
            xM: xM, yM: yM, yawRad: yawRad, uncertaintyM: uncertaintyM,
            beforeNodeID: before.id, afterNodeID: after.id, ratio: ratio,
            floorID: before.floorID)
    }

    private static func insideLostInterval(_ monotonic: Double, lostIntervals: [LostInterval]) -> Bool {
        return lostIntervals.contains { monotonic >= $0.fromMonotonic && monotonic <= $0.toMonotonic }
    }

    /// Inverts the monotonic -> UTC mapping by walking segments; returns
    /// the monotonic time whose mapped UTC equals (or is closest within
    /// one millisecond of) the target. Never inverts across a clock
    /// discontinuity edge (V1R4 §7.3); a bounded outer-edge
    /// extrapolation of at most the mapper's maximum is allowed.
    private static func inverseMap(utcMapper: MonotonicUTCMapper, utc: Double) -> Double? {
        let samples = utcMapper.samples
        guard samples.count >= 2 else { return nil }
        // The mapping is monotonic in utc when the clock is continuous;
        // walk adjacent samples and solve the linear segment. Discontinuity
        // edges (clock jumps / timezone changes) are never inverted across.
        for index in 0..<(samples.count - 1) {
            guard !utcMapper.discontinuityEdges.contains(index) else {
                continue
            }
            let a = samples[index]
            let b = samples[index + 1]
            let aUTC = a.utcUnixSeconds
            let bUTC = b.utcUnixSeconds
            if (utc >= aUTC && utc <= bUTC) || (utc <= aUTC && utc >= bUTC) {
                let spanUTC = bUTC - aUTC
                guard abs(spanUTC) > 1.0e-9 else { continue }
                let ratio = (utc - aUTC) / spanUTC
                return a.monotonicSeconds + (b.monotonicSeconds - a.monotonicSeconds) * ratio
            }
        }
        // Bounded outer-edge extrapolation (only when the adjacent edge is
        // continuous), so the first/last session seconds can still map.
        if let first = samples.first,
           !utcMapper.discontinuityEdges.contains(0),
           utc < first.utcUnixSeconds,
           samples.count >= 2,
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
           samples.count >= 2,
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
        appGitSHA: String
    ) -> DevicePositionRow {
        let context = utcMapper.context(forMonotonic: monotonic)
        let localTimestamp = formatLocalTimestamp(
            unixTimeS: Double(unixTimeS), offsetSeconds: context.utcOffsetSeconds)
        let utcTimestamp = formatUTCTimestamp(unixTimeS: Double(unixTimeS))
        return DevicePositionRow(
            sequence: sequence,
            localTimestamp: localTimestamp,
            utcTimestamp: utcTimestamp,
            unixTimeS: unixTimeS,
            timezoneID: context.timezoneID,
            utcOffset: context.utcOffsetSeconds,
            sessionElapsedS: monotonic,
            storeID: storeID,
            floorID: position.floorID,
            mapXM: SourceGeometry.rounded(position.xM),
            mapYM: SourceGeometry.rounded(position.yM),
            yawDeg: SourceGeometry.rounded(position.yawRad * 180.0 / Double.pi),
            positionStatus: "AVAILABLE",
            positionSource: "final_trajectory",
            beforeNodeID: position.beforeNodeID,
            afterNodeID: position.afterNodeID,
            interpolationRatio: SourceGeometry.rounded(position.ratio),
            localizationConfidence: nil,
            estimatedUncertaintyM: SourceGeometry.rounded(position.uncertaintyM),
            trackingState: "tracking",
            graphQualityStatus: "connected",
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
        reason: String
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
            floorID: floorID,
            mapXM: nil,
            mapYM: nil,
            yawDeg: nil,
            positionStatus: "UNAVAILABLE",
            positionSource: "final_trajectory",
            beforeNodeID: nil,
            afterNodeID: nil,
            interpolationRatio: nil,
            localizationConfidence: nil,
            estimatedUncertaintyM: nil,
            trackingState: "lost",
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
