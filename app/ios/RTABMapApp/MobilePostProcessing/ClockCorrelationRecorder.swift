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

/// Incrementally persists correlation + node-binding records as strict
/// JSONL. The writer never assembles the sidecar in memory: each record is
/// appended immediately and a bounded batch is fsynced before its durable
/// watermark advances. Finalization fsyncs the last partial batch.
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
    static let durabilityBatchRecordCount = 64

    private(set) var records: [ClockCorrelationRecord] = []
    let trackingSessionID: String
    private let lock = NSLock()
    private let parentDescriptor: Int32
    private var descriptor: Int32
    private let faultInjector: ((ClockSidecarWriteStage) throws -> Void)?
    private var lastPeriodicMonotonic: Double?
    private var writtenCorrelationCount = 0
    private var writtenNodeBindingCount = 0
    private var durableCorrelationCount = 0
    private var durableNodeBindingCount = 0
    private var recordsSinceDurableSync = 0
    private var lastWrittenMonotonicSeconds: Double?
    private var lastWrittenUTCSeconds: Double?
    private var failedReason: String?
    private var finished = false

    init(
        trackingSessionID: String,
        url: URL,
        faultInjector: ((ClockSidecarWriteStage) throws -> Void)? = nil
    ) throws {
        guard !trackingSessionID.isEmpty,
              url.lastPathComponent == "clock_correlations.jsonl" else {
            throw ClockSidecarWriteError.invalidInput
        }
        self.trackingSessionID = trackingSessionID
        self.faultInjector = faultInjector

        let parent = Darwin.open(
            url.deletingLastPathComponent().path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard parent >= 0 else {
            throw ClockSidecarWriteError.openFailed(
                "cannot open sidecar parent: errno \(errno)")
        }
        parentDescriptor = parent
        descriptor = -1
        do {
            try faultInjector?(.create)
            let output = Darwin.openat(
                parent,
                url.lastPathComponent,
                O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW,
                S_IRUSR | S_IWUSR)
            guard output >= 0 else {
                throw ClockSidecarWriteError.openFailed(
                    "cannot create sidecar: errno \(errno)")
            }
            descriptor = output
            var info = stat()
            guard fstat(output, &info) == 0,
                  (info.st_mode & S_IFMT) == S_IFREG,
                  info.st_nlink == 1 else {
                Darwin.close(output)
                descriptor = -1
                throw ClockSidecarWriteError.openFailed(
                    "sidecar is not one regular file")
            }
            try faultInjector?(.parentSync)
            guard fsync(parent) == 0 else {
                throw ClockSidecarWriteError.fsyncFailed(
                    "parent fsync failed with errno \(errno)")
            }
        } catch {
            if descriptor >= 0 {
                Darwin.close(descriptor)
                descriptor = -1
            }
            _ = Darwin.unlinkat(parent, url.lastPathComponent, 0)
            Darwin.close(parent)
            throw error
        }
    }

    deinit {
        if descriptor >= 0 {
            Darwin.close(descriptor)
        }
        Darwin.close(parentDescriptor)
    }

    func record(
        reason: Reason,
        monotonicSeconds: Double,
        utcUnixSeconds: Double,
        timezoneID: String,
        utcOffsetSeconds: Int
    ) throws {
        let value = ClockCorrelationRecord.make(
            trackingSessionID: trackingSessionID,
            monotonicSeconds: monotonicSeconds,
            utcUnixSeconds: utcUnixSeconds,
            timezoneID: timezoneID,
            utcOffsetSeconds: utcOffsetSeconds,
            reason: reason.rawValue
        )
        lock.lock()
        defer { lock.unlock() }
        try appendCorrelationLocked(value)
    }

    /// Records a periodic sample if at least 30 seconds elapsed since the
    /// previous one.
    func maybeRecordPeriodic(
        monotonicSeconds: Double,
        utcUnixSeconds: Double,
        timezoneID: String,
        utcOffsetSeconds: Int
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        if let previous = lastPeriodicMonotonic,
           monotonicSeconds - previous < Self.periodicIntervalSeconds {
            return
        }
        let value = ClockCorrelationRecord.make(
            trackingSessionID: trackingSessionID,
            monotonicSeconds: monotonicSeconds,
            utcUnixSeconds: utcUnixSeconds,
            timezoneID: timezoneID,
            utcOffsetSeconds: utcOffsetSeconds,
            reason: Reason.periodic.rawValue
        )
        try appendCorrelationLocked(value)
        lastPeriodicMonotonic = monotonicSeconds
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
    ) throws {
        let value = ClockNodeBindingRecord.make(
            trackingSessionID: trackingSessionID,
            nodeID: nodeID,
            nodeStamp: nodeStamp,
            sampledFrameTimestamp: sampledFrameTimestamp,
            systemUptime: systemUptime,
            utcUnixSeconds: utcUnixSeconds,
            timezoneID: timezoneID,
            utcOffsetSeconds: utcOffsetSeconds,
            reason: Reason.nodeBound.rawValue
        )
        lock.lock()
        defer { lock.unlock() }
        try requireWritableLocked()
        guard nodeID > 0,
              nodeStamp.isFinite,
              sampledFrameTimestamp.isFinite,
              systemUptime.isFinite,
              utcUnixSeconds.isFinite,
              !timezoneID.isEmpty else {
            throw failLocked(ClockSidecarWriteError.invalidInput)
        }
        do {
            try appendPayloadLocked(value.canonicalPayload)
            writtenNodeBindingCount += 1
            recordsSinceDurableSync += 1
            if recordsSinceDurableSync >= Self.durabilityBatchRecordCount {
                try synchronizeLocked()
            }
        } catch {
            throw failLocked(error)
        }
    }

    /// Flushes the last partial batch, closes the stream and returns only the
    /// fsync-proven watermark. Once this succeeds no further append is legal.
    func finish() throws -> ClockSidecarWriteResult {
        lock.lock()
        defer { lock.unlock() }
        try requireWritableLocked()
        guard writtenCorrelationCount + writtenNodeBindingCount > 0 else {
            throw failLocked(ClockSidecarWriteError.emptySidecar)
        }
        do {
            try synchronizeLocked()
            try faultInjector?(.close)
            guard Darwin.close(descriptor) == 0 else {
                throw ClockSidecarWriteError.closeFailed(
                    "close failed with errno \(errno)")
            }
            descriptor = -1
            finished = true
        } catch {
            throw failLocked(error)
        }
        return ClockSidecarWriteResult(
            correlationCount: durableCorrelationCount,
            nodeBindingCount: durableNodeBindingCount,
            lastMonotonicSeconds: lastWrittenMonotonicSeconds,
            lastUTCSeconds: lastWrittenUTCSeconds)
    }

    /// Abandons an in-flight writer after the session has already become
    /// ineligible. The partial sidecar remains as audit evidence, but no
    /// metadata watermark can be produced from it.
    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        if descriptor >= 0 {
            Darwin.close(descriptor)
            descriptor = -1
        }
        finished = true
    }

    /// Builds a piecewise-linear monotonic -> UTC mapping from the
    /// recorded correlations (device-uptime axis). Node-stamp mapping is
    /// built separately by `StrictClockEvidenceParser` (V1R4 §7.3).
    func buildUTCMapper() -> MonotonicUTCMapper {
        lock.lock()
        defer { lock.unlock() }
        return MonotonicUTCMapper(records: records)
    }

    private func appendCorrelationLocked(
        _ value: ClockCorrelationRecord
    ) throws {
        try requireWritableLocked()
        guard value.monotonicSeconds.isFinite,
              value.utcUnixSeconds.isFinite,
              !value.timezoneID.isEmpty else {
            throw failLocked(ClockSidecarWriteError.invalidInput)
        }
        do {
            try appendPayloadLocked(value.canonicalPayload)
            records.append(value)
            writtenCorrelationCount += 1
            recordsSinceDurableSync += 1
            lastWrittenMonotonicSeconds = value.monotonicSeconds
            lastWrittenUTCSeconds = value.utcUnixSeconds
            if recordsSinceDurableSync >= Self.durabilityBatchRecordCount {
                try synchronizeLocked()
            }
        } catch {
            throw failLocked(error)
        }
    }

    private func appendPayloadLocked(_ payload: [String: Any]) throws {
        try faultInjector?(.append)
        var data = try CanonicalJSONEncoder.encode(payload)
        data.append(0x0A)
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let count = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    rawBuffer.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw ClockSidecarWriteError.writeFailed(
                        "append failed with errno \(errno)")
                }
                guard count > 0 else {
                    throw ClockSidecarWriteError.writeFailed(
                        "append made no progress")
                }
                offset += count
            }
        }
    }

    private func synchronizeLocked() throws {
        guard recordsSinceDurableSync > 0 else { return }
        try faultInjector?(.dataSync)
        guard fsync(descriptor) == 0 else {
            throw ClockSidecarWriteError.fsyncFailed(
                "sidecar fsync failed with errno \(errno)")
        }
        durableCorrelationCount = writtenCorrelationCount
        durableNodeBindingCount = writtenNodeBindingCount
        recordsSinceDurableSync = 0
    }

    private func requireWritableLocked() throws {
        if let failedReason {
            throw ClockSidecarWriteError.writerFailed(failedReason)
        }
        guard !finished, descriptor >= 0 else {
            throw ClockSidecarWriteError.writerClosed
        }
    }

    private func failLocked(_ error: Error) -> ClockSidecarWriteError {
        let value: ClockSidecarWriteError
        if let typed = error as? ClockSidecarWriteError {
            value = typed
        } else {
            value = .writeFailed(error.localizedDescription)
        }
        failedReason = value.localizedDescription
        return value
    }
}

enum ClockSidecarWriteStage {
    case create
    case parentSync
    case append
    case dataSync
    case close
}

enum ClockSidecarWriteError: Error, LocalizedError {
    case invalidInput
    case emptySidecar
    case openFailed(String)
    case writeFailed(String)
    case fsyncFailed(String)
    case closeFailed(String)
    case writerFailed(String)
    case writerClosed

    var errorDescription: String? {
        switch self {
        case .invalidInput: return "时钟侧车记录字段无效"
        case .emptySidecar: return "时钟侧车为空"
        case .openFailed(let detail): return "时钟侧车打开失败：\(detail)"
        case .writeFailed(let detail): return "时钟侧车写入失败：\(detail)"
        case .fsyncFailed(let detail): return "时钟侧车 fsync 失败：\(detail)"
        case .closeFailed(let detail): return "时钟侧车关闭失败：\(detail)"
        case .writerFailed(let detail): return "时钟侧车 writer 已失败：\(detail)"
        case .writerClosed: return "时钟侧车 writer 已关闭"
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
        guard !samples.isEmpty else { return ("UTC", 0) }
        // Binary search keeps incidental callers bounded. The final
        // trajectory resampler uses its own monotonic pointer so a 48-hour
        // run remains O(output rows + clock samples), not O(S * C).
        var lower = 0
        var upper = samples.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if samples[middle].monotonicSeconds <= monotonic {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        let index = max(0, lower - 1)
        return (samples[index].timezoneID, samples[index].utcOffsetSeconds)
    }
}
