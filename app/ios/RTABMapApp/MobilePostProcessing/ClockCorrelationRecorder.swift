import Foundation

/// Records `clock_correlations.jsonl` entries that bind the monotonic
/// processing clock to UTC and the current timezone. Every record keeps
/// the local timezone identifier and its UTC offset so final
/// device positions can be emitted in local wall-clock time without
/// guessing.
///
/// Schema v2 (V1R4 §7) freezes the clock axes at scan time:
/// - `correlation` records: device system uptime (ProcessInfo.systemUptime)
///   <-> UTC Unix seconds + timezone. Recording moments: session start,
///   every 30 seconds while scanning, will-resign-active,
///   did-become-active, system clock change, timezone change and session
///   end. Each system clock / timezone change starts a new segment.
/// - `node_binding` records: the RTAB-Map node timebase bound to the
///   ARKit frame timestamp, system uptime and UTC at node creation /
///   binding time (`node_id`, `node_stamp`, `sampled_frame_timestamp`,
///   `system_uptime`, `utc`). Post-processing MUST use these bindings to
///   map DB node stamps to UTC; it must never assume node stamps are UTC.
///
/// V1R4 §7.2: the sidecar write is durable (temp + fsync + rename +
/// parent fsync) and returns an exact watermark so the session metadata
/// can record `clockCorrelationCount`, `clockNodeBindingCount`,
/// `clockLastMonotonic`, `clockLastUTC` and `clockEvidenceComplete`.
struct ClockCorrelationRecord: Equatable {
    static let formatValue = "MarketScannerClockCorrelation"
    static let versionValue = 2
    static let kindCorrelation = "correlation"

    var format: String
    var version: Int
    var trackingSessionID: String
    var monotonicSeconds: Double
    var utcUnixSeconds: Double
    var timezoneID: String
    var utcOffsetSeconds: Int
    var reason: String

    var canonicalPayload: [String: Any] {
        return [
            "format": format,
            "version": version,
            "record_kind": Self.kindCorrelation,
            "tracking_session_id": trackingSessionID,
            "monotonic_seconds": monotonicSeconds,
            "utc_unix_seconds": utcUnixSeconds,
            "timezone_id": timezoneID,
            "utc_offset_seconds": utcOffsetSeconds,
            "reason": reason,
        ]
    }

    static func make(
        trackingSessionID: String,
        monotonicSeconds: Double,
        utcUnixSeconds: Double,
        timezoneID: String,
        utcOffsetSeconds: Int,
        reason: String
    ) -> ClockCorrelationRecord {
        return ClockCorrelationRecord(
            format: formatValue,
            version: versionValue,
            trackingSessionID: trackingSessionID,
            monotonicSeconds: monotonicSeconds,
            utcUnixSeconds: utcUnixSeconds,
            timezoneID: timezoneID,
            utcOffsetSeconds: utcOffsetSeconds,
            reason: reason
        )
    }
}

/// Node-timebase binding record (V1R4 §7.1). Persisted at node
/// creation/binding time so post-processing can map the RTAB-Map node
/// stamp axis to UTC without assuming node stamps are Unix UTC seconds.
struct ClockNodeBindingRecord: Equatable {
    static let kindNodeBinding = "node_binding"

    var format: String
    var version: Int
    var trackingSessionID: String
    var nodeID: Int
    var nodeStamp: Double
    var sampledFrameTimestamp: Double
    var systemUptime: Double
    var utcUnixSeconds: Double
    var timezoneID: String
    var utcOffsetSeconds: Int
    var reason: String

    var canonicalPayload: [String: Any] {
        return [
            "format": format,
            "version": version,
            "record_kind": Self.kindNodeBinding,
            "tracking_session_id": trackingSessionID,
            "node_id": nodeID,
            "node_stamp": nodeStamp,
            "sampled_frame_timestamp": sampledFrameTimestamp,
            "system_uptime": systemUptime,
            "utc_unix_seconds": utcUnixSeconds,
            "timezone_id": timezoneID,
            "utc_offset_seconds": utcOffsetSeconds,
            "reason": reason,
        ]
    }

    static func make(
        trackingSessionID: String,
        nodeID: Int,
        nodeStamp: Double,
        sampledFrameTimestamp: Double,
        systemUptime: Double,
        utcUnixSeconds: Double,
        timezoneID: String,
        utcOffsetSeconds: Int,
        reason: String
    ) -> ClockNodeBindingRecord {
        return ClockNodeBindingRecord(
            format: ClockCorrelationRecord.formatValue,
            version: ClockCorrelationRecord.versionValue,
            trackingSessionID: trackingSessionID,
            nodeID: nodeID,
            nodeStamp: nodeStamp,
            sampledFrameTimestamp: sampledFrameTimestamp,
            systemUptime: systemUptime,
            utcUnixSeconds: utcUnixSeconds,
            timezoneID: timezoneID,
            utcOffsetSeconds: utcOffsetSeconds,
            reason: reason
        )
    }
}

/// Exact watermark of one durable clock-sidecar write (V1R4 §7.2).
struct ClockSidecarWriteResult {
    var correlationCount: Int
    var nodeBindingCount: Int
    var lastMonotonicSeconds: Double?
    var lastUTCSeconds: Double?
    /// True only when the scan captured enough clock evidence to prove a
    /// node-stamp <-> UTC mapping: at least the session start/end
    /// correlations and at least two node bindings.
    var evidenceComplete: Bool {
        return correlationCount >= 2 && nodeBindingCount >= 2
    }
}

/// Collects correlation + node-binding records and serializes them
/// deterministically (one JSON object per line). The recorder is a pure
/// accumulator so the Swift host tests can drive it without Foundation
/// timers.
final class ClockCorrelationRecorder {
    enum Reason: String {
        case sessionStart = "session_start"
        case periodic = "periodic"
        case willResignActive = "will_resign_active"
        case didBecomeActive = "did_become_active"
        case systemClockChange = "system_clock_change"
        case timezoneChange = "timezone_change"
        case sessionEnd = "session_end"
        case nodeBound = "node_bound"
    }

    static let periodicIntervalSeconds: Double = 30.0

    private(set) var records: [ClockCorrelationRecord] = []
    private(set) var bindings: [ClockNodeBindingRecord] = []
    let trackingSessionID: String
    private var lastPeriodicMonotonic: Double?

    init(trackingSessionID: String) {
        self.trackingSessionID = trackingSessionID
    }

    func record(
        reason: Reason,
        monotonicSeconds: Double,
        utcUnixSeconds: Double,
        timezoneID: String,
        utcOffsetSeconds: Int
    ) {
        records.append(ClockCorrelationRecord.make(
            trackingSessionID: trackingSessionID,
            monotonicSeconds: monotonicSeconds,
            utcUnixSeconds: utcUnixSeconds,
            timezoneID: timezoneID,
            utcOffsetSeconds: utcOffsetSeconds,
            reason: reason.rawValue
        ))
    }

    /// Records a periodic sample if at least 30 seconds elapsed since the
    /// previous one.
    func maybeRecordPeriodic(
        monotonicSeconds: Double,
        utcUnixSeconds: Double,
        timezoneID: String,
        utcOffsetSeconds: Int
    ) {
        if let previous = lastPeriodicMonotonic,
           monotonicSeconds - previous < Self.periodicIntervalSeconds {
            return
        }
        lastPeriodicMonotonic = monotonicSeconds
        record(
            reason: .periodic,
            monotonicSeconds: monotonicSeconds,
            utcUnixSeconds: utcUnixSeconds,
            timezoneID: timezoneID,
            utcOffsetSeconds: utcOffsetSeconds
        )
    }

    /// Records a node-timebase binding (V1R4 §7.1) at node creation /
    /// binding time.
    func recordNodeBinding(
        nodeID: Int,
        nodeStamp: Double,
        sampledFrameTimestamp: Double,
        systemUptime: Double,
        utcUnixSeconds: Double,
        timezoneID: String,
        utcOffsetSeconds: Int
    ) {
        bindings.append(ClockNodeBindingRecord.make(
            trackingSessionID: trackingSessionID,
            nodeID: nodeID,
            nodeStamp: nodeStamp,
            sampledFrameTimestamp: sampledFrameTimestamp,
            systemUptime: systemUptime,
            utcUnixSeconds: utcUnixSeconds,
            timezoneID: timezoneID,
            utcOffsetSeconds: utcOffsetSeconds,
            reason: Reason.nodeBound.rawValue
        ))
    }

    /// Serializes the collected records as one strict-JSON object per
    /// line (sorted keys, compact) with a final newline, then persists
    /// them durably: temp file + fsync + atomic rename + parent fsync
    /// (V1R4 §7.2). Returns the exact watermark for metadata write-back.
    /// Any write failure throws; callers must never swallow it (`try?`).
    func write(to url: URL) throws -> ClockSidecarWriteResult {
        var lines = Data()
        for record in records {
            let data = try CanonicalJSONEncoder.encode(record.canonicalPayload)
            lines.append(data)
            lines.append(0x0A)
        }
        for binding in bindings {
            let data = try CanonicalJSONEncoder.encode(binding.canonicalPayload)
            lines.append(data)
            lines.append(0x0A)
        }
        guard !lines.isEmpty else {
            throw ClockSidecarWriteError.emptySidecar
        }
        let temporary = url.appendingPathExtension("tmp-\(UUID().uuidString)")
        do {
            try lines.write(to: temporary, options: [])
            let fd = open(temporary.path, O_RDONLY)
            guard fd >= 0 else {
                throw ClockSidecarWriteError.fsyncFailed(
                    "cannot reopen temporary sidecar")
            }
            let fsyncResult = fsync(fd)
            close(fd)
            guard fsyncResult == 0 else {
                throw ClockSidecarWriteError.fsyncFailed(
                    "fsync failed with errno \(errno)")
            }
            guard rename(temporary.path, url.path) == 0 else {
                throw ClockSidecarWriteError.renameFailed(
                    "rename failed with errno \(errno)")
            }
            let directoryFD = open(
                url.deletingLastPathComponent().path, O_RDONLY)
            if directoryFD >= 0 {
                _ = fsync(directoryFD)
                close(directoryFD)
            }
        } catch let error as ClockSidecarWriteError {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw ClockSidecarWriteError.writeFailed(error.localizedDescription)
        }
        return ClockSidecarWriteResult(
            correlationCount: records.count,
            nodeBindingCount: bindings.count,
            lastMonotonicSeconds: records.last?.monotonicSeconds,
            lastUTCSeconds: records.last?.utcUnixSeconds)
    }

    /// Builds a piecewise-linear monotonic -> UTC mapping from the
    /// recorded correlations (device-uptime axis). Node-stamp mapping is
    /// built separately by `StrictClockEvidenceParser` (V1R4 §7.3).
    func buildUTCMapper() -> MonotonicUTCMapper {
        return MonotonicUTCMapper(records: records)
    }
}

enum ClockSidecarWriteError: Error, LocalizedError {
    case emptySidecar
    case writeFailed(String)
    case fsyncFailed(String)
    case renameFailed(String)

    var errorDescription: String? {
        switch self {
        case .emptySidecar: return "时钟侧车为空"
        case .writeFailed(let detail): return "时钟侧车写入失败：\(detail)"
        case .fsyncFailed(let detail): return "时钟侧车 fsync 失败：\(detail)"
        case .renameFailed(let detail): return "时钟侧车原子替换失败：\(detail)"
        }
    }
}

/// Maps monotonic seconds to UTC seconds by interpolating between
/// correlation samples; used to attach wall-clock time to every final
/// trajectory row. `discontinuityEdges` mark sample pairs across which
/// interpolation is forbidden (clock jumps / timezone changes, V1R4 §7.3).
struct MonotonicUTCMapper {
    struct Sample {
        var monotonicSeconds: Double
        var utcUnixSeconds: Double
        var utcOffsetSeconds: Int
        var timezoneID: String
    }

    let samples: [Sample]
    /// Edge indices `i` where interpolation between `samples[i]` and
    /// `samples[i+1]` is forbidden.
    let discontinuityEdges: Set<Int>
    /// Maximum outer-edge extrapolation span (bounded, never across a
    /// discontinuity).
    static let maximumOuterExtrapolationSeconds: Double = 3.0

    init(records: [ClockCorrelationRecord]) {
        self.init(records: records, discontinuityEdges: [])
    }

    init(records: [ClockCorrelationRecord], discontinuityEdges: Set<Int>) {
        var collected: [Sample] = []
        for record in records {
            collected.append(Sample(
                monotonicSeconds: record.monotonicSeconds,
                utcUnixSeconds: record.utcUnixSeconds,
                utcOffsetSeconds: record.utcOffsetSeconds,
                timezoneID: record.timezoneID
            ))
        }
        // Keep strictly increasing monotonic time; duplicates are dropped.
        var ordered: [Sample] = []
        for sample in collected.sorted(by: { $0.monotonicSeconds < $1.monotonicSeconds }) {
            if let last = ordered.last, sample.monotonicSeconds <= last.monotonicSeconds {
                continue
            }
            ordered.append(sample)
        }
        samples = ordered
        self.discontinuityEdges = discontinuityEdges
    }

    init(samples: [Sample], discontinuityEdges: Set<Int>) {
        self.samples = samples
        self.discontinuityEdges = discontinuityEdges
    }

    /// UTC seconds for a monotonic time, or nil when the monotonic time
    /// is outside the recorded correlation span (never extrapolate
    /// across a discontinuity; a bounded outer-edge extrapolation of at
    /// most `maximumOuterExtrapolationSeconds` is allowed).
    func utcSeconds(forMonotonic monotonic: Double) -> Double? {
        guard let first = samples.first, let last = samples.last else {
            return nil
        }
        // Exact sample hit.
        if let exact = samples.first(where: {
            abs($0.monotonicSeconds - monotonic) <= 1.0e-9
        }) {
            return exact.utcUnixSeconds
        }
        if monotonic < first.monotonicSeconds {
            guard samples.count >= 2,
                  !discontinuityEdges.contains(0),
                  first.monotonicSeconds - monotonic
                    <= Self.maximumOuterExtrapolationSeconds else {
                return nil
            }
            let span = samples[1].monotonicSeconds - first.monotonicSeconds
            guard span > 1.0e-9 else { return nil }
            let ratio = (monotonic - first.monotonicSeconds) / span
            return first.utcUnixSeconds
                + (samples[1].utcUnixSeconds - first.utcUnixSeconds) * ratio
        }
        if monotonic > last.monotonicSeconds {
            guard samples.count >= 2,
                  !discontinuityEdges.contains(samples.count - 2),
                  monotonic - last.monotonicSeconds
                    <= Self.maximumOuterExtrapolationSeconds else {
                return nil
            }
            let a = samples[samples.count - 2]
            let span = last.monotonicSeconds - a.monotonicSeconds
            guard span > 1.0e-9 else { return nil }
            let ratio = (monotonic - a.monotonicSeconds) / span
            return a.utcUnixSeconds
                + (last.utcUnixSeconds - a.utcUnixSeconds) * ratio
        }
        if samples.count == 1 {
            return first.utcUnixSeconds + (monotonic - first.monotonicSeconds)
        }
        for index in 0..<(samples.count - 1) {
            let a = samples[index]
            let b = samples[index + 1]
            if monotonic >= a.monotonicSeconds && monotonic <= b.monotonicSeconds {
                guard !discontinuityEdges.contains(index) else {
                    return nil
                }
                let span = b.monotonicSeconds - a.monotonicSeconds
                guard span > 1.0e-9 else {
                    return a.utcUnixSeconds
                }
                let ratio = (monotonic - a.monotonicSeconds) / span
                return a.utcUnixSeconds + (b.utcUnixSeconds - a.utcUnixSeconds) * ratio
            }
        }
        return last.utcUnixSeconds
    }

    /// Timezone context at a monotonic time (the most recent sample).
    func context(forMonotonic monotonic: Double) -> (timezoneID: String, utcOffsetSeconds: Int) {
        var best = samples.first
        for sample in samples where sample.monotonicSeconds <= monotonic {
            best = sample
        }
        return (best?.timezoneID ?? "UTC", best?.utcOffsetSeconds ?? 0)
    }
}
