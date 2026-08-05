import Foundation

/// Records `clock_correlations.jsonl` entries that bind the monotonic
/// processing clock to UTC and the current timezone. Every record keeps
/// the local timezone identifier and its UTC offset so final
/// device positions can be emitted in local wall-clock time without
/// guessing.
///
/// Recording moments: session start, every 30 seconds while scanning,
/// will-resign-active, did-become-active, system clock change, timezone
/// change and session end. Each system clock / timezone change starts a
/// new correlation segment.
struct ClockCorrelationRecord: Equatable {
    static let formatValue = "MarketScannerClockCorrelation"
    static let versionValue = 1

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

/// Collects correlation records and serializes them deterministically
/// (one JSON object per line). The recorder is a pure accumulator so the
/// Swift host tests can drive it without Foundation timers.
final class ClockCorrelationRecorder {
    enum Reason: String {
        case sessionStart = "session_start"
        case periodic = "periodic"
        case willResignActive = "will_resign_active"
        case didBecomeActive = "did_become_active"
        case systemClockChange = "system_clock_change"
        case timezoneChange = "timezone_change"
        case sessionEnd = "session_end"
    }

    static let periodicIntervalSeconds: Double = 30.0

    private(set) var records: [ClockCorrelationRecord] = []
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

    /// Serializes the collected records as one strict-JSON object per
    /// line (sorted keys, compact), written atomically.
    func write(to url: URL) throws {
        var lines = Data()
        for record in records {
            let data = try CanonicalJSONEncoder.encode(record.canonicalPayload)
            lines.append(data)
            lines.append(0x0A)
        }
        try lines.write(to: url, options: [.atomic])
    }

    /// Builds a piecewise-linear monotonic -> UTC mapping from the
    /// recorded correlations. Records with non-increasing monotonic time
    /// are ignored; after a clock change a new segment starts implicitly
    /// at the first sample with a different offset.
    func buildUTCMapper() -> MonotonicUTCMapper {
        return MonotonicUTCMapper(records: records)
    }
}

/// Maps monotonic seconds to UTC seconds by interpolating between
/// correlation samples; used to attach wall-clock time to every final
/// trajectory row.
struct MonotonicUTCMapper {
    struct Sample {
        var monotonicSeconds: Double
        var utcUnixSeconds: Double
        var utcOffsetSeconds: Int
        var timezoneID: String
    }

    let samples: [Sample]

    init(records: [ClockCorrelationRecord]) {
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
    }

    /// UTC seconds for a monotonic time, or nil when the monotonic time
    /// is outside the recorded correlation span (never extrapolate).
    func utcSeconds(forMonotonic monotonic: Double) -> Double? {
        guard let first = samples.first, let last = samples.last else {
            return nil
        }
        if monotonic < first.monotonicSeconds || monotonic > last.monotonicSeconds {
            return nil
        }
        if samples.count == 1 {
            return first.utcUnixSeconds + (monotonic - first.monotonicSeconds)
        }
        for index in 0..<(samples.count - 1) {
            let a = samples[index]
            let b = samples[index + 1]
            if monotonic >= a.monotonicSeconds && monotonic <= b.monotonicSeconds {
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
