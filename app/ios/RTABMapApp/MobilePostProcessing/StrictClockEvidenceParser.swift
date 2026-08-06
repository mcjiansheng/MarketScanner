import Foundation

/// Strict `clock_correlations.jsonl` parser (V1R4 §7.3).
///
/// Fail-closed contract:
/// - exact identity: format/version/record_kind/schema and
///   tracking_session_id must match the expected session;
/// - exact count: the watermark written back into metadata
///   (`clockCorrelationCount`, `clockNodeBindingCount`) must match the
///   sidecar line counts exactly;
/// - final newline, no blank / partial lines;
/// - unknown fields are rejected (versioned extensions only);
/// - finite typed numbers, strict integers (Bool is never an Int);
/// - monotonic axes strictly increase: correlation `monotonic_seconds`
///   (device uptime) and binding `node_stamp`; duplicates, reordered or
///   partial samples are rejected;
/// - correlation records must be internally consistent (utc advances
///   with uptime; a backward clock is rejected);
/// - every node binding is cross-checked against the correlation
///   uptime->UTC mapping within tolerance;
/// - system clock jumps and timezone changes become explicit
///   discontinuity segments; the mapper never interpolates across them;
/// - processing-time timezone is never used as a formal fallback.
///
/// When evidence is missing/insufficient the caller must fail the
/// publish (or emit all-UNAVAILABLE DevicePositions); it must never
/// fabricate a plausible-looking time axis.
enum StrictClockEvidenceParser {
    /// V1R5 §7.1/§7.5 (review B-07): the sidecar must fit the product
    /// ceiling — 60k node bindings × ≈250 bytes each plus correlations
    /// and a safety factor (§4 contract), never the V1R4 8 MiB cap.
    static let maximumSidecarBytes = 256 * 1024 * 1024
    static let maximumRecordCount = 1_000_000
    /// A system clock jump is a utc delta that deviates from the
    /// uptime delta by more than this tolerance (seconds).
    static let discontinuityToleranceSeconds = 2.0
    /// Cross-check tolerance between a node binding's utc and the
    /// correlation uptime->utc mapping (seconds).
    static let bindingCrossCheckToleranceSeconds = 2.0
    /// Minimum evidence for an authoritative mapping.
    static let minimumCorrelationCount = 2
    static let minimumBindingCount = 2

    struct ParsedEvidence {
        var correlations: [ClockCorrelationRecord]
        var bindings: [ClockNodeBindingRecord]
    }

    enum ParseError: Error, LocalizedError {
        case missingSidecar(String)
        case tooLarge(String)
        case noFinalNewline
        case blankLine(Int)
        case partialLine(Int)
        case jsonInvalid(Int, String)
        case formatInvalid(Int)
        case versionUnsupportedLegacy(Int)
        case kindInvalid(Int)
        case sessionIdentityMismatch(Int)
        case unknownField(Int, String)
        case missingField(Int, String)
        case nonFiniteNumber(Int, String)
        case invalidInteger(Int, String)
        case invalidTimezone(Int, String)
        case nonIncreasingMonotonic(Int, String)
        case backwardClock(Int)
        case duplicateSample(Int, String)
        case duplicateNodeBinding(Int)
        case countMismatch(String)
        case bindingUTCMismatch(Int)

        var errorDescription: String? {
            switch self {
            case .missingSidecar(let detail): return "时钟证据缺失：\(detail)"
            case .tooLarge(let detail): return "时钟证据超过限制：\(detail)"
            case .noFinalNewline: return "时钟侧车缺少结尾换行"
            case .blankLine(let line): return "时钟侧车第 \(line) 行为空行"
            case .partialLine(let line): return "时钟侧车第 \(line) 行为不完整行"
            case .jsonInvalid(let line, let detail): return "时钟侧车第 \(line) 行 JSON 无效：\(detail)"
            case .formatInvalid(let line): return "时钟侧车第 \(line) 行 format 无效"
            case .versionUnsupportedLegacy(let line): return "时钟侧车第 \(line) 行为旧版本（v1 不支持权威映射）"
            case .kindInvalid(let line): return "时钟侧车第 \(line) 行 record_kind 无效"
            case .sessionIdentityMismatch(let line): return "时钟侧车第 \(line) 行 tracking_session_id 不匹配"
            case .unknownField(let line, let field): return "时钟侧车第 \(line) 行包含未知字段 \(field)"
            case .missingField(let line, let field): return "时钟侧车第 \(line) 行缺少字段 \(field)"
            case .nonFiniteNumber(let line, let field): return "时钟侧车第 \(line) 行字段 \(field) 非有限数"
            case .invalidInteger(let line, let field): return "时钟侧车第 \(line) 行字段 \(field) 不是严格整数"
            case .invalidTimezone(let line, let field): return "时钟侧车第 \(line) 行时区 \(field) 无效"
            case .nonIncreasingMonotonic(let line, let field): return "时钟侧车第 \(line) 行 \(field) 未严格递增"
            case .backwardClock(let line): return "时钟侧车第 \(line) 行时钟倒退"
            case .duplicateSample(let line, let field): return "时钟侧车第 \(line) 行 \(field) 重复"
            case .duplicateNodeBinding(let line): return "时钟侧车第 \(line) 行 node_id 重复"
            case .countMismatch(let detail): return "时钟侧车计数与 metadata 不一致：\(detail)"
            case .bindingUTCMismatch(let line): return "时钟侧车第 \(line) 行 node binding 与 correlation 映射不一致"
            }
        }
    }

    static let correlationKeys: Set<String> = [
        "format", "version", "record_kind", "tracking_session_id",
        "monotonic_seconds", "utc_unix_seconds", "timezone_id",
        "utc_offset_seconds", "reason",
    ]
    static let bindingKeys: Set<String> = [
        "format", "version", "record_kind", "tracking_session_id",
        "node_id", "node_stamp", "sampled_frame_timestamp",
        "system_uptime", "utc_unix_seconds", "timezone_id",
        "utc_offset_seconds", "reason",
    ]

    /// Strictly parses the sidecar from a file through the shared
    /// streaming JSONL reader (V1R5 §7.1 — the file is never loaded as
    /// one String; 60k/100k bindings stay bounded).
    static func parse(
        url: URL,
        expectedTrackingSessionID: String,
        expectedCorrelationCount: Int?,
        expectedBindingCount: Int?
    ) throws -> ParsedEvidence {
        let attributes = try FileManager.default
            .attributesOfItem(atPath: url.path)
        let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard fileSize <= Int64(maximumSidecarBytes) else {
            throw ParseError.tooLarge("\(fileSize) bytes")
        }
        let framing: StrictJSONLStreamReader.ParsedLines
        do {
            framing = try StrictJSONLStreamReader.readLines(
                from: url,
                maximumLineBytes: 1024 * 1024,
                maximumLineCount: maximumRecordCount)
        } catch let error as StrictJSONLStreamReader.StreamError {
            throw ParseError.tooLarge(error.localizedDescription)
        }
        var correlations: [ClockCorrelationRecord] = []
        var bindings: [ClockNodeBindingRecord] = []
        var correlationMonotonic: Double?
        var bindingStamp: Double?
        var seenNodeIDs = Set<Int>()
        for (offset, line) in framing.lines.enumerated() {
            let lineNumber = offset + 1
            let object: [String: Any]
            do {
                object = try StrictJSONLStreamReader.strictObject(
                    from: line, lineNumber: lineNumber)
            } catch {
                throw ParseError.jsonInvalid(
                    lineNumber, "cannot parse object")
            }
            try parseRecord(
                object,
                lineNumber: lineNumber,
                expectedTrackingSessionID: expectedTrackingSessionID,
                correlations: &correlations,
                bindings: &bindings,
                correlationMonotonic: &correlationMonotonic,
                bindingStamp: &bindingStamp,
                seenNodeIDs: &seenNodeIDs)
        }
        if let expectedCorrelationCount {
            guard correlations.count == expectedCorrelationCount else {
                throw ParseError.countMismatch(
                    "correlation \(correlations.count) != metadata \(expectedCorrelationCount)")
            }
        }
        if let expectedBindingCount {
            guard bindings.count == expectedBindingCount else {
                throw ParseError.countMismatch(
                    "node_binding \(bindings.count) != metadata \(expectedBindingCount)")
            }
        }
        try crossCheckBindings(correlations: correlations, bindings: bindings)
        return ParsedEvidence(
            correlations: correlations,
            bindings: bindings)
    }

    /// Strictly parses the sidecar content (host-test entry point; the
    /// framing rules are identical to the file path).
    static func parse(
        content: String,
        expectedTrackingSessionID: String,
        expectedCorrelationCount: Int?,
        expectedBindingCount: Int?
    ) throws -> ParsedEvidence {
        guard !content.isEmpty else {
            throw ParseError.missingSidecar("empty sidecar")
        }
        guard content.utf8.count <= maximumSidecarBytes else {
            throw ParseError.tooLarge("\(content.utf8.count) bytes")
        }
        guard content.hasSuffix("\n") else {
            throw ParseError.noFinalNewline
        }
        // The trailing newline is the line terminator, not a blank line:
        // strip it before splitting so `\n`-terminated files do not yield
        // a phantom empty element. Interior blank lines are still
        // rejected below.
        let body = content.dropLast()
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count <= maximumRecordCount else {
            throw ParseError.tooLarge("\(lines.count) lines")
        }
        var correlations: [ClockCorrelationRecord] = []
        var bindings: [ClockNodeBindingRecord] = []
        var correlationMonotonic: Double?
        var bindingStamp: Double?
        var seenNodeIDs = Set<Int>()
        for (offset, rawLine) in lines.enumerated() {
            let lineNumber = offset + 1
            let line = String(rawLine)
            guard !line.isEmpty else {
                throw ParseError.blankLine(lineNumber)
            }
            guard let data = line.data(using: .utf8) else {
                throw ParseError.partialLine(lineNumber)
            }
            guard let object = try? StrictJSONDocumentParser.object(
                from: data,
                limits: StrictJSONDocumentLimits(maximumBytes: data.count + 1)
            ) as? [String: Any] else {
                throw ParseError.jsonInvalid(lineNumber, "cannot parse object")
            }
            try parseRecord(
                object,
                lineNumber: lineNumber,
                expectedTrackingSessionID: expectedTrackingSessionID,
                correlations: &correlations,
                bindings: &bindings,
                correlationMonotonic: &correlationMonotonic,
                bindingStamp: &bindingStamp,
                seenNodeIDs: &seenNodeIDs)
        }
        if let expectedCorrelationCount {
            guard correlations.count == expectedCorrelationCount else {
                throw ParseError.countMismatch(
                    "correlation \(correlations.count) != metadata \(expectedCorrelationCount)")
            }
        }
        if let expectedBindingCount {
            guard bindings.count == expectedBindingCount else {
                throw ParseError.countMismatch(
                    "node_binding \(bindings.count) != metadata \(expectedBindingCount)")
            }
        }
        try crossCheckBindings(correlations: correlations, bindings: bindings)
        return ParsedEvidence(
            correlations: correlations,
            bindings: bindings)
    }

    /// Shared per-record validation for both entry points.
    private static func parseRecord(
        _ object: [String: Any],
        lineNumber: Int,
        expectedTrackingSessionID: String,
        correlations: inout [ClockCorrelationRecord],
        bindings: inout [ClockNodeBindingRecord],
        correlationMonotonic: inout Double?,
        bindingStamp: inout Double?,
        seenNodeIDs: inout Set<Int>
    ) throws {
        guard object["format"] as? String == ClockCorrelationRecord.formatValue else {
            throw ParseError.formatInvalid(lineNumber)
        }
        guard let version = strictInt(object["version"], line: lineNumber) else {
            throw ParseError.missingField(lineNumber, "version")
        }
        if version != ClockCorrelationRecord.versionValue {
            throw ParseError.versionUnsupportedLegacy(lineNumber)
        }
        guard let kind = object["record_kind"] as? String,
              kind == ClockCorrelationRecord.kindCorrelation
                || kind == ClockNodeBindingRecord.kindNodeBinding else {
            throw ParseError.kindInvalid(lineNumber)
        }
        guard object["tracking_session_id"] as? String
                == expectedTrackingSessionID else {
            throw ParseError.sessionIdentityMismatch(lineNumber)
        }
        guard let reason = object["reason"] as? String, !reason.isEmpty else {
            throw ParseError.missingField(lineNumber, "reason")
        }
        // V1R5 §7.2 (review B-07): a REAL IANA timezone id is required —
        // a non-empty string is not enough.
        guard let timezoneID = object["timezone_id"] as? String,
              !timezoneID.isEmpty,
              TimeZone(identifier: timezoneID) != nil else {
            throw ParseError.invalidTimezone(lineNumber, "timezone_id")
        }
        guard let utcOffset = strictInt(
            object["utc_offset_seconds"], line: lineNumber),
            abs(utcOffset) <= 24 * 3600 else {
            throw ParseError.invalidInteger(lineNumber, "utc_offset_seconds")
        }

        if kind == ClockCorrelationRecord.kindCorrelation {
            for key in object.keys where !correlationKeys.contains(key) {
                throw ParseError.unknownField(lineNumber, key)
            }
            guard let monotonic = finiteDouble(
                object["monotonic_seconds"], line: lineNumber) else {
                throw ParseError.nonFiniteNumber(lineNumber, "monotonic_seconds")
            }
            guard let utc = finiteDouble(
                object["utc_unix_seconds"], line: lineNumber) else {
                throw ParseError.nonFiniteNumber(lineNumber, "utc_unix_seconds")
            }
            if let previous = correlationMonotonic {
                guard monotonic > previous else {
                    if monotonic == previous {
                        throw ParseError.duplicateSample(
                            lineNumber, "monotonic_seconds")
                    }
                    throw ParseError.nonIncreasingMonotonic(
                        lineNumber, "monotonic_seconds")
                }
            }
            if let previous = correlations.last, utc < previous.utcUnixSeconds {
                throw ParseError.backwardClock(lineNumber)
            }
            correlationMonotonic = monotonic
            correlations.append(ClockCorrelationRecord.make(
                trackingSessionID: expectedTrackingSessionID,
                monotonicSeconds: monotonic,
                utcUnixSeconds: utc,
                timezoneID: timezoneID,
                utcOffsetSeconds: utcOffset,
                reason: reason))
        } else {
            for key in object.keys where !bindingKeys.contains(key) {
                throw ParseError.unknownField(lineNumber, key)
            }
            guard let nodeID = strictInt(object["node_id"], line: lineNumber),
                  nodeID > 0 else {
                throw ParseError.invalidInteger(lineNumber, "node_id")
            }
            guard let nodeStamp = finiteDouble(
                object["node_stamp"], line: lineNumber) else {
                throw ParseError.nonFiniteNumber(lineNumber, "node_stamp")
            }
            guard let frameTimestamp = finiteDouble(
                object["sampled_frame_timestamp"], line: lineNumber) else {
                throw ParseError.nonFiniteNumber(
                    lineNumber, "sampled_frame_timestamp")
            }
            guard let uptime = finiteDouble(
                object["system_uptime"], line: lineNumber) else {
                throw ParseError.nonFiniteNumber(lineNumber, "system_uptime")
            }
            guard let utc = finiteDouble(
                object["utc_unix_seconds"], line: lineNumber) else {
                throw ParseError.nonFiniteNumber(lineNumber, "utc_unix_seconds")
            }
            guard !seenNodeIDs.contains(nodeID) else {
                throw ParseError.duplicateNodeBinding(lineNumber)
            }
            if let previous = bindingStamp {
                guard nodeStamp > previous else {
                    if nodeStamp == previous {
                        throw ParseError.duplicateSample(
                            lineNumber, "node_stamp")
                    }
                    throw ParseError.nonIncreasingMonotonic(
                        lineNumber, "node_stamp")
                }
            }
            bindingStamp = nodeStamp
            seenNodeIDs.insert(nodeID)
            bindings.append(ClockNodeBindingRecord.make(
                trackingSessionID: expectedTrackingSessionID,
                nodeID: nodeID,
                nodeStamp: nodeStamp,
                sampledFrameTimestamp: frameTimestamp,
                systemUptime: uptime,
                utcUnixSeconds: utc,
                timezoneID: timezoneID,
                utcOffsetSeconds: utcOffset,
                reason: reason))
        }
    }

    /// V1R5 §7.4 (review B-07): every binding must cross-check against
    /// the correlation uptime->UTC mapping. A binding that CANNOT be
    /// cross-checked (sampled inside a discontinuity segment) is
    /// REJECTED — it is never skipped "and the rest continues".
    private static func crossCheckBindings(
        correlations: [ClockCorrelationRecord],
        bindings: [ClockNodeBindingRecord]
    ) throws {
        guard correlations.count >= 2, !bindings.isEmpty else { return }
        let correlationEdges = discontinuityEdges(of: correlations)
        for (index, binding) in bindings.enumerated() {
            guard let expected = mappedUTC(
                uptime: binding.systemUptime,
                correlations: correlations,
                edges: correlationEdges) else {
                // Inside a discontinuity segment: cannot attribute the
                // binding to either side -> fail closed.
                throw ParseError.bindingUTCMismatch(index + 1)
            }
            if abs(expected - binding.utcUnixSeconds)
                > bindingCrossCheckToleranceSeconds {
                throw ParseError.bindingUTCMismatch(index + 1)
            }
        }
    }

    /// Discontinuity edges on the correlation timeline (shared by the
    /// cross-check and the mapper): a system clock jump or a timezone
    /// change. The jump test is RELATIVE — a constant non-1:1 clock
    /// scale (e.g. 2× uptime under background throttling) is not a
    /// discontinuity, so the edge test compares each segment's
    /// utc/uptime ratio against the median ratio of the run.
    static func discontinuityEdges(
        of correlations: [ClockCorrelationRecord]
    ) -> Set<Int> {
        var edges = Set<Int>()
        guard correlations.count >= 2 else { return edges }
        var ratios: [Double] = []
        for index in 0..<(correlations.count - 1) {
            let a = correlations[index]
            let b = correlations[index + 1]
            let utcDelta = b.utcUnixSeconds - a.utcUnixSeconds
            let uptimeDelta = b.monotonicSeconds - a.monotonicSeconds
            if abs(uptimeDelta) > 1.0e-9 {
                ratios.append(utcDelta / uptimeDelta)
            }
        }
        guard !ratios.isEmpty else { return edges }
        let sorted = ratios.sorted()
        let median = sorted[sorted.count / 2]
        let medianMagnitude = max(abs(median), 1.0e-9)
        for index in 0..<(correlations.count - 1) {
            let a = correlations[index]
            let b = correlations[index + 1]
            let utcDelta = b.utcUnixSeconds - a.utcUnixSeconds
            let uptimeDelta = b.monotonicSeconds - a.monotonicSeconds
            let timezoneChanged = a.timezoneID != b.timezoneID
            var jump = false
            if abs(uptimeDelta) > 1.0e-9 {
                let ratio = utcDelta / uptimeDelta
                if abs(ratio - median) / medianMagnitude
                    > discontinuityToleranceSeconds * 0.25 {
                    jump = true
                }
            }
            if timezoneChanged || jump {
                edges.insert(index)
            }
        }
        return edges
    }

    /// Piecewise correlation mapping used by the binding cross-check:
    /// interpolates on continuous segments only; a monotonic time inside
    /// a discontinuity segment cannot be attributed to either side and
    /// returns nil (the binding is skipped, never mis-verified). A
    /// bounded outer-edge extrapolation is allowed on continuous edges.
    private static func mappedUTC(
        uptime: Double,
        correlations: [ClockCorrelationRecord],
        edges: Set<Int>
    ) -> Double? {
        if let exact = correlations.first(where: {
            abs($0.monotonicSeconds - uptime) <= 1.0e-9
        }) {
            return exact.utcUnixSeconds
        }
        guard correlations.count >= 2 else { return nil }
        for index in 0..<(correlations.count - 1) {
            let a = correlations[index]
            let b = correlations[index + 1]
            if uptime >= a.monotonicSeconds && uptime <= b.monotonicSeconds {
                guard !edges.contains(index) else { return nil }
                let span = b.monotonicSeconds - a.monotonicSeconds
                guard span > 1.0e-9 else { return a.utcUnixSeconds }
                let ratio = (uptime - a.monotonicSeconds) / span
                return a.utcUnixSeconds
                    + (b.utcUnixSeconds - a.utcUnixSeconds) * ratio
            }
        }
        if let first = correlations.first, uptime < first.monotonicSeconds {
            guard !edges.contains(0),
                  first.monotonicSeconds - uptime
                    <= MonotonicUTCMapper.maximumOuterExtrapolationSeconds else {
                return nil
            }
            let a = correlations[0]
            let b = correlations[1]
            let span = b.monotonicSeconds - a.monotonicSeconds
            guard span > 1.0e-9 else { return nil }
            let ratio = (uptime - a.monotonicSeconds) / span
            return a.utcUnixSeconds
                + (b.utcUnixSeconds - a.utcUnixSeconds) * ratio
        }
        if let last = correlations.last, uptime > last.monotonicSeconds {
            guard correlations.count >= 2,
                  !edges.contains(correlations.count - 2),
                  uptime - last.monotonicSeconds
                    <= MonotonicUTCMapper.maximumOuterExtrapolationSeconds else {
                return nil
            }
            let a = correlations[correlations.count - 2]
            let span = last.monotonicSeconds - a.monotonicSeconds
            guard span > 1.0e-9 else { return nil }
            let ratio = (uptime - a.monotonicSeconds) / span
            return a.utcUnixSeconds
                + (last.utcUnixSeconds - a.utcUnixSeconds) * ratio
        }
        return nil
    }

    /// Builds the authoritative node-stamp -> UTC mapper from the
    /// node bindings (V1R4 §7.1/§7.3). The monotonic axis is
    /// `node_stamp - sessionStartStamp`; UTC comes from the binding.
    /// System clock jumps and timezone changes (detected on the
    /// correlation timeline and mapped onto the binding timeline via
    /// system uptime) become explicit discontinuity edges.
    static func buildMapper(
        evidence: ParsedEvidence,
        sessionStartStamp: Double
    ) -> MonotonicUTCMapper {
        let correlations = evidence.correlations
        let bindings = evidence.bindings.sorted {
            $0.nodeStamp < $1.nodeStamp
        }
        // 1. Discontinuity edges on the correlation timeline (relative
        //    scale-aware detection, shared with the parser cross-check).
        let correlationEdges = discontinuityEdges(of: correlations)
        // 2. Map correlation edges onto binding pairs via system uptime:
        //    a binding pair whose span crosses an uptime-span that is a
        //    discontinuity is itself a discontinuity edge.
        var bindingEdges = Set<Int>()
        if bindings.count >= 2 && !correlationEdges.isEmpty {
            var edgeUptimeSpans: [(from: Double, to: Double)] = []
            for index in correlationEdges {
                edgeUptimeSpans.append((
                    correlations[index].monotonicSeconds,
                    correlations[index + 1].monotonicSeconds))
            }
            for pair in 0..<(bindings.count - 1) {
                let a = bindings[pair]
                let b = bindings[pair + 1]
                let pairFrom = min(a.systemUptime, b.systemUptime)
                let pairTo = max(a.systemUptime, b.systemUptime)
                let crossesDiscontinuity = edgeUptimeSpans.contains { span in
                    pairFrom < span.to && pairTo > span.from
                }
                let timezoneChanged = a.timezoneID != b.timezoneID
                if timezoneChanged || crossesDiscontinuity {
                    bindingEdges.insert(pair)
                }
            }
        }
        // 3. Direct binding-level sanity: utc must not move backward
        //    while node stamps advance (a one-off backward jump is a
        //    discontinuity edge, not a global rejection; the parser
        //    already rejected backward correlation clocks).
        if bindings.count >= 2 {
            for pair in 0..<(bindings.count - 1) {
                if bindingEdges.contains(pair) { continue }
                let a = bindings[pair]
                let b = bindings[pair + 1]
                if b.utcUnixSeconds < a.utcUnixSeconds {
                    bindingEdges.insert(pair)
                }
            }
        }
        let samples = bindings.map {
            MonotonicUTCMapper.Sample(
                monotonicSeconds: $0.nodeStamp - sessionStartStamp,
                utcUnixSeconds: $0.utcUnixSeconds,
                utcOffsetSeconds: $0.utcOffsetSeconds,
                timezoneID: $0.timezoneID)
        }
        return MonotonicUTCMapper(
            samples: samples,
            discontinuityEdges: bindingEdges)
    }

    /// Minimum evidence for an authoritative mapping (V1R4 §7.3):
    /// at least two correlations and two node bindings.
    static func isEvidenceSufficient(_ evidence: ParsedEvidence) -> Bool {
        return evidence.correlations.count >= minimumCorrelationCount
            && evidence.bindings.count >= minimumBindingCount
    }

    /// V1R5 §6.1: strict integers via the shared scalar helper (a
    /// fractional number or a numeric Bool never passes — the V1R4
    /// `NSNumber.intValue` truncated 1.9 into 1).
    private static func strictInt(_ value: Any?, line: Int) -> Int? {
        return StrictJSONScalar.integer(value)
    }

    private static func finiteDouble(_ value: Any?, line: Int) -> Double? {
        return StrictJSONScalar.number(value)
    }
}
