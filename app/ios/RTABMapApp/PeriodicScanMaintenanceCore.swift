//
//  PeriodicScanMaintenanceCore.swift
//  RTABMapApp
//
//  Foundation-only core for the large-store periodic maintenance requirement
//  (`docs/map-assisted-localization/PERIODIC_MANUAL_CALIBRATION_AND_AUTO_ROLLOVER_REQUIREMENTS_2026-09-04.md`).
//
//  Scope of this file (phase 1 of the requirement document):
//    * policy, monotonic accumulation and warning/trigger decisions;
//    * the `scanning -> warning -> gate -> anchoring -> finalizingUnit ->
//      preparingNextUnit -> scanning` state machine with strict edges;
//    * capture admission gating (normal writes vs one-shot anchor node);
//    * unit storage growth estimation and the soft byte gate;
//    * mission / unit / boundary schema;
//    * idempotent crash-recovery planning and fail-closed validation.
//
//  This file performs no disk, UI, timer or wall-clock work. Every caller
//  input (monotonic uptime, byte counts, safety signals) is injected so the
//  same logic can be exercised by macOS host tests with deterministic fault
//  injection. UIKit integration, unit finalization and next-unit start
//  remain in `ViewController` / `SupermarketScanSession` (phases 2 and 3) and
//  are NOT implemented by this file.
//

import Foundation

// MARK: - Policy

/// Reminder ladder from §5.1. Remaining-time thresholds are inclusive on the
/// crossing tick; each reminder fires at most once per capture unit.
enum MaintenanceReminder: String, Codable, CaseIterable, Equatable {
    case first
    case second
    case final
}

/// Deployment-controlled maintenance policy.
///
/// `softMaxUnitBytes` stays `nil` until the device baseline freezes it
/// (§5.1/§5.3). While it is `nil`, only the time gate and the existing disk
/// safety gates are active; the core must never claim a strict byte ceiling.
struct PeriodicMaintenancePolicy: Equatable {
    static let currentPolicyVersion = 1

    var policyVersion: Int = PeriodicMaintenancePolicy.currentPolicyVersion
    /// Effective capture time per unit. Not operator-editable during a scan.
    var calibrationIntervalS: TimeInterval = 1800
    var firstReminderRemainingS: TimeInterval = 300
    var secondReminderRemainingS: TimeInterval = 60
    var finalReminderRemainingS: TimeInterval = 30
    /// §5.1: the gate closes at the due instant; there is no grace window.
    var gracePeriodS: TimeInterval = 0
    var growthProjectionHorizonS: TimeInterval = 60
    var minimumGrowthSamples: Int = 3
    var growthSampleCapacity: Int = 12
    var finalizationHeadroomBytes: UInt64 = 512 * 1024 * 1024
    var softMaxUnitBytes: UInt64?
    /// Phase-1 kill switch: when false the caller must keep the existing
    /// single continuous-database behaviour unchanged.
    var featureEnabled: Bool = false

    func threshold(for reminder: MaintenanceReminder) -> TimeInterval {
        switch reminder {
        case .first: return firstReminderRemainingS
        case .second: return secondReminderRemainingS
        case .final: return finalReminderRemainingS
        }
    }

    /// Phase-1 kill switch. Every engine entry point and the recovery planner
    /// check this flag: while the feature is off the existing single continuous
    /// database behaviour must be bit-for-bit unchanged.
    var isActive: Bool { featureEnabled && isValid }

    /// Configuration problems are fail-closed: an invalid policy must stop the
    /// feature rather than silently fall back to a different interval.
    func validationFindings() -> [MissionFinding] {
        var findings: [MissionFinding] = []
        if policyVersion != PeriodicMaintenancePolicy.currentPolicyVersion {
            findings.append(MissionFinding(
                severity: .fatal,
                code: "policy_version_unsupported",
                message: "Unsupported maintenance policy version \(policyVersion)."))
        }
        if !calibrationIntervalS.isFinite || calibrationIntervalS <= 0 {
            findings.append(MissionFinding(
                severity: .fatal,
                code: "policy_interval_invalid",
                message: "calibrationIntervalS must be finite and positive."))
        }
        let ladder = [firstReminderRemainingS, secondReminderRemainingS, finalReminderRemainingS]
        if ladder.contains(where: { !$0.isFinite || $0 < 0 }) {
            findings.append(MissionFinding(
                severity: .fatal,
                code: "policy_ladder_invalid",
                message: "Reminder thresholds must be finite and non-negative."))
        }
        if !(firstReminderRemainingS > secondReminderRemainingS)
            || !(secondReminderRemainingS > finalReminderRemainingS) {
            findings.append(MissionFinding(
                severity: .fatal,
                code: "policy_ladder_unordered",
                message: "Reminder thresholds must strictly decrease."))
        }
        if ladder.contains(where: { $0 >= calibrationIntervalS }) {
            findings.append(MissionFinding(
                severity: .fatal,
                code: "policy_ladder_out_of_range",
                message: "Reminder thresholds must be below the calibration interval."))
        }
        if !gracePeriodS.isFinite || gracePeriodS < 0 {
            findings.append(MissionFinding(
                severity: .fatal,
                code: "policy_grace_invalid",
                message: "gracePeriodS must be finite and non-negative."))
        } else if gracePeriodS != 0 {
            findings.append(MissionFinding(
                severity: .fatal,
                code: "policy_grace_unsupported",
                message: "The active policy does not allow a grace period."))
        }
        if !growthProjectionHorizonS.isFinite || growthProjectionHorizonS < 0 {
            findings.append(MissionFinding(
                severity: .fatal,
                code: "policy_growth_horizon_invalid",
                message: "growthProjectionHorizonS must be finite and non-negative."))
        }
        if minimumGrowthSamples < 2 {
            findings.append(MissionFinding(
                severity: .fatal,
                code: "policy_growth_samples_invalid",
                message: "minimumGrowthSamples must be at least 2."))
        }
        if growthSampleCapacity < minimumGrowthSamples {
            findings.append(MissionFinding(
                severity: .fatal,
                code: "policy_growth_capacity_invalid",
                message: "growthSampleCapacity must cover minimumGrowthSamples."))
        }
        if let limit = softMaxUnitBytes, limit <= finalizationHeadroomBytes {
            findings.append(MissionFinding(
                severity: .fatal,
                code: "policy_soft_max_invalid",
                message: "softMaxUnitBytes must exceed the finalization headroom."))
        }
        return findings
    }

    var isValid: Bool { validationFindings().isEmpty }
}

// MARK: - Findings

enum MissionFindingSeverity: String, Codable, Equatable {
    case info
    case warning
    case fatal
}

struct MissionFinding: Codable, Equatable {
    let severity: MissionFindingSeverity
    let code: String
    let message: String

    init(severity: MissionFindingSeverity, code: String, message: String) {
        self.severity = severity
        self.code = code
        self.message = message
    }
}

// MARK: - State machine

/// Maintenance states from §8.1. `finalizingMission` covers both the
/// operator Stop path and the safety-stop path; only `preparingNextUnit`
/// leads back to ordinary capture.
enum PeriodicMaintenanceState: String, Codable, CaseIterable, Equatable {
    case idle
    case scanning
    case warning
    case gate
    case anchoring
    case finalizingUnit
    case preparingNextUnit
    case finalizingMission
    case terminalRecovery
    case completed

    /// True only while ordinary walking capture is legal. `warning` still
    /// records nodes: it is a lead time, not a block.
    var ordinaryCaptureAllowed: Bool {
        switch self {
        case .scanning, .warning: return true
        case .idle, .gate, .anchoring, .finalizingUnit, .preparingNextUnit,
             .finalizingMission, .terminalRecovery, .completed:
            return false
        }
    }

    var isTerminal: Bool {
        switch self {
        case .completed, .terminalRecovery: return true
        default: return false
        }
    }
}

/// Why the maintenance gate was entered. Only `timeLimit` and `sizeLimit`
/// start a new unit; the two stop triggers seal the mission (§5.3).
enum MaintenanceTrigger: String, Codable, Equatable {
    case timeLimit = "time_limit"
    case sizeLimit = "size_limit"
    case operatorStop = "operator_stop"
    case safetyStop = "safety_stop"

    var startsNextUnit: Bool {
        switch self {
        case .timeLimit, .sizeLimit: return true
        case .operatorStop, .safetyStop: return false
        }
    }
}

enum PeriodicMaintenanceTransitionError: Error, Equatable, CustomStringConvertible {
    case denied(from: PeriodicMaintenanceState, to: PeriodicMaintenanceState)
    case invalidUnitIndex(expected: Int, actual: Int)

    var description: String {
        switch self {
        case .denied(let from, let to):
            return "maintenance_transition_denied:\(from.rawValue)->\(to.rawValue)"
        case .invalidUnitIndex(let expected, let actual):
            return "maintenance_unit_index_mismatch:expected=\(expected):actual=\(actual)"
        }
    }
}

/// Allowed edges. Anything not listed is rejected fail-closed, including
/// "resume capture after a failed finalization" and "reopen a sealed unit".
func periodicMaintenanceAllowsTransition(
    from: PeriodicMaintenanceState,
    to: PeriodicMaintenanceState
) -> Bool {
    if from.isTerminal { return false }
    switch (from, to) {
    case (.idle, .scanning):
        return true
    case (.scanning, .warning),
         (.scanning, .gate),
         (.scanning, .finalizingMission),
         (.scanning, .terminalRecovery):
        return true
    case (.warning, .scanning),
         (.warning, .gate),
         (.warning, .finalizingMission),
         (.warning, .terminalRecovery):
        return true
    case (.gate, .anchoring),
         (.gate, .finalizingMission),
         (.gate, .terminalRecovery):
        return true
    case (.anchoring, .gate),
         (.anchoring, .finalizingUnit),
         (.anchoring, .finalizingMission),
         (.anchoring, .terminalRecovery):
        return true
    case (.finalizingUnit, .gate),
         (.finalizingUnit, .preparingNextUnit),
         (.finalizingUnit, .terminalRecovery):
        return true
    case (.preparingNextUnit, .scanning),
         (.preparingNextUnit, .gate),
         (.preparingNextUnit, .terminalRecovery):
        return true
    case (.finalizingMission, .completed),
         (.finalizingMission, .terminalRecovery):
        return true
    default:
        return false
    }
}

// MARK: - Admission

/// What the capture pipeline may accept right now.
///
/// §3.2 requires that after the gate closes, ordinary nodes, price-tag
/// confirmations and localization corrections are all zero, while the
/// one-shot exact-node anchor used by boundary calibration stays legal.
struct CaptureAdmission: Equatable {
    var ordinaryNodeWrites: Bool
    var priceTagConfirmation: Bool
    var localizationCorrection: Bool
    var oneShotAnchorNode: Bool

    static let open = CaptureAdmission(
        ordinaryNodeWrites: true,
        priceTagConfirmation: true,
        localizationCorrection: true,
        oneShotAnchorNode: true)

    /// Maintenance gate: only the narrow one-shot anchor path survives.
    static let maintenanceGate = CaptureAdmission(
        ordinaryNodeWrites: false,
        priceTagConfirmation: false,
        localizationCorrection: false,
        oneShotAnchorNode: true)

    static let closed = CaptureAdmission(
        ordinaryNodeWrites: false,
        priceTagConfirmation: false,
        localizationCorrection: false,
        oneShotAnchorNode: false)

    func admission(for state: PeriodicMaintenanceState) -> CaptureAdmission {
        switch state {
        case .scanning, .warning:
            return .open
        case .gate, .anchoring:
            return .maintenanceGate
        case .idle, .finalizingUnit, .preparingNextUnit, .finalizingMission,
             .terminalRecovery, .completed:
            return .closed
        }
    }
}

// MARK: - Monotonic accumulation

/// Effective-capture accumulator driven by `ProcessInfo.systemUptime`.
///
/// Only running intervals count: backgrounding, the maintenance gate,
/// finalization, external copy and next-unit preparation are excluded by
/// pausing the accumulator. Wall-clock time is never consulted, so a user
/// changing the device clock cannot grant or deny extra capture time.
struct MonotonicCaptureAccumulator: Equatable {
    private(set) var accumulatedS: TimeInterval = 0
    private(set) var runningSince: TimeInterval?
    private(set) var anomalyCount: Int = 0
    private(set) var lastAnomaly: String?

    var isRunning: Bool { runningSince != nil }

    mutating func resume(at monotonic: TimeInterval) {
        guard runningSince == nil else { return }
        guard monotonic.isFinite else {
            recordAnomaly("resume_non_finite")
            return
        }
        runningSince = monotonic
    }

    /// Returns false when the sample could not be trusted (non-finite input or
    /// an uptime that moved backwards, i.e. the process was restarted).
    @discardableResult
    mutating func pause(at monotonic: TimeInterval) -> Bool {
        guard let start = runningSince else { return true }
        guard monotonic.isFinite else {
            recordAnomaly("pause_non_finite")
            return false
        }
        guard monotonic >= start else {
            recordAnomaly("monotonic_went_backwards")
            runningSince = nil
            return false
        }
        accumulatedS += monotonic - start
        runningSince = nil
        return true
    }

    /// Elapsed effective capture time without mutating the accumulator. A
    /// backwards sample reports the last trustworthy value and flags an
    /// anomaly instead of producing a negative duration.
    func elapsed(at monotonic: TimeInterval) -> TimeInterval {
        guard let start = runningSince else { return accumulatedS }
        guard monotonic.isFinite, monotonic >= start else { return accumulatedS }
        return accumulatedS + (monotonic - start)
    }

    mutating func reset() {
        accumulatedS = 0
        runningSince = nil
    }

    /// Process restart path (§5.2): the accumulated value is restored from the
    /// checkpoint instead of restarting the 30 minutes.
    mutating func restore(accumulatedS value: TimeInterval) {
        accumulatedS = value.isFinite && value > 0 ? value : 0
        runningSince = nil
    }

    private mutating func recordAnomaly(_ reason: String) {
        anomalyCount += 1
        lastAnomaly = reason
    }
}

// MARK: - Storage growth estimation

struct StorageGrowthSample: Equatable {
    let monotonic: TimeInterval
    let bytes: UInt64
}

/// Predicts unit size so the byte gate can close the gate *before* the file
/// reaches the soft limit (§5.3). Estimation needs at least three samples and
/// a strictly positive time span; a negative or stalled rate is reported as
/// zero instead of being extrapolated.
struct StorageGrowthEstimator: Equatable {
    var samples: [StorageGrowthSample] = []
    var capacity: Int = 12

    mutating func record(monotonic: TimeInterval, bytes: UInt64) {
        guard monotonic.isFinite else { return }
        if let last = samples.last, monotonic < last.monotonic {
            // A restarted process invalidates the rate window.
            samples.removeAll()
        }
        samples.append(StorageGrowthSample(monotonic: monotonic, bytes: bytes))
        if samples.count > capacity {
            samples.removeFirst(samples.count - capacity)
        }
    }

    /// A negative rate (a database that shrank after a save) is clamped to
    /// zero instead of being extrapolated, so the estimate never reports less
    /// than the bytes already on disk.
    func bytesPerSecond(minimumSamples: Int) -> Double? {
        guard samples.count >= minimumSamples,
              let first = samples.first,
              let last = samples.last,
              last.monotonic > first.monotonic else { return nil }
        let deltaBytes = Double(last.bytes) - Double(first.bytes)
        return max(0, deltaBytes / (last.monotonic - first.monotonic))
    }

    func projectedBytes(
        minimumSamples: Int,
        horizonS: TimeInterval
    ) -> UInt64? {
        guard let current = samples.last?.bytes,
              let rate = bytesPerSecond(minimumSamples: minimumSamples),
              horizonS.isFinite,
              horizonS >= 0 else { return nil }
        let projected = Double(current) + rate * horizonS
        guard projected.isFinite, projected >= 0 else { return nil }
        if projected >= Double(UInt64.max) { return UInt64.max }
        return UInt64(projected.rounded(.down))
    }
}

// MARK: - Safety signals

/// Disk, thermal and evidence health. §5.3 fixes the priority as
/// evidence/database write failure > free space below 1 GiB > thermal
/// critical > size gate > time gate, and the first three never start a new
/// unit.
struct MaintenanceSafetySignal: Equatable {
    var evidenceOrDatabaseWriteFailure: Bool = false
    var thermalCritical: Bool = false
    var availableDiskBytes: Int64?
    var minimumDiskBytes: Int64 = 1_024 * 1_024 * 1_024
    var warningDiskBytes: Int64 = 8 * 1_024 * 1_024 * 1_024

    enum Level: Equatable {
        case nominal
        case diskWarning
        case terminal
    }

    var level: Level {
        if evidenceOrDatabaseWriteFailure { return .terminal }
        if let free = availableDiskBytes, free < minimumDiskBytes { return .terminal }
        if thermalCritical { return .terminal }
        if let free = availableDiskBytes, free < warningDiskBytes { return .diskWarning }
        return .nominal
    }

    var terminalReason: String? {
        if evidenceOrDatabaseWriteFailure { return "evidence_or_database_write_failure" }
        if let free = availableDiskBytes, free < minimumDiskBytes {
            return "available_disk_below_minimum"
        }
        if thermalCritical { return "thermal_critical" }
        return nil
    }
}

// MARK: - Tick result

struct MaintenanceTick: Equatable {
    var remindersFired: [MaintenanceReminder] = []
    var enteredGate: Bool = false
    var trigger: MaintenanceTrigger?
    var remainingS: TimeInterval?
    var projectedBytes: UInt64?
    var reason: String?
    var enteredTerminalRecovery: Bool = false
}

struct MaintenanceFailure: Equatable {
    let code: String
    let message: String
    let atMonotonic: TimeInterval?
    /// Sticky failures must not be cleared by retrying the same step: they
    /// require an explicit recovery transition (§10).
    let sticky: Bool

    init(code: String, message: String, atMonotonic: TimeInterval? = nil, sticky: Bool = false) {
        self.code = code
        self.message = message
        self.atMonotonic = atMonotonic
        self.sticky = sticky
    }
}

// MARK: - Engine

/// Deterministic maintenance engine. The engine owns decisions only; it never
/// touches the file system, the camera or the database.
struct PeriodicMaintenanceEngine: Equatable {
    var policy: PeriodicMaintenancePolicy
    var state: PeriodicMaintenanceState = .idle
    var clock = MonotonicCaptureAccumulator()
    var unitIndex: Int = 0
    var firedReminders: Set<MaintenanceReminder> = []
    var growth = StorageGrowthEstimator()
    var pendingTrigger: MaintenanceTrigger?
    var lastFailure: MaintenanceFailure?
    var pendingBoundaryID: String?
    var stickyFailure: MaintenanceFailure?

    init(policy: PeriodicMaintenancePolicy = PeriodicMaintenancePolicy()) {
        self.policy = policy
        self.growth.capacity = max(policy.growthSampleCapacity, policy.minimumGrowthSamples)
    }

    // MARK: Queries

    func activeElapsed(at monotonic: TimeInterval) -> TimeInterval {
        clock.elapsed(at: monotonic)
    }

    func remainingS(at monotonic: TimeInterval) -> TimeInterval {
        max(0, policy.calibrationIntervalS - activeElapsed(at: monotonic))
    }

    var admission: CaptureAdmission {
        CaptureAdmission.open.admission(for: state)
    }

    /// True when a sticky failure forbids starting the next unit (§10).
    var blocksNextUnit: Bool { stickyFailure != nil }

    // MARK: Transitions

    /// Start a fresh unit and zero the effective-capture clock (§8.2 step 11).
    mutating func startUnit(
        index: Int,
        at monotonic: TimeInterval
    ) -> Result<Void, PeriodicMaintenanceTransitionError> {
        let expectedIndex = unitIndex + 1
        guard index == expectedIndex else {
            return .failure(.invalidUnitIndex(expected: expectedIndex, actual: index))
        }
        guard policy.isActive else {
            return .failure(.denied(from: state, to: .scanning))
        }
        guard requestedTransition(to: .scanning) else {
            return .failure(.denied(from: state, to: .scanning))
        }
        state = .scanning
        unitIndex = index
        clock.reset()
        clock.resume(at: monotonic)
        firedReminders.removeAll()
        growth = StorageGrowthEstimator()
        growth.capacity = max(policy.growthSampleCapacity, policy.minimumGrowthSamples)
        pendingTrigger = nil
        pendingBoundaryID = nil
        return .success(())
    }

    mutating func requestTransition(
        to target: PeriodicMaintenanceState
    ) -> Result<Void, PeriodicMaintenanceTransitionError> {
        guard requestedTransition(to: target) else {
            return .failure(.denied(from: state, to: target))
        }
        state = target
        return .success(())
    }

    private func requestedTransition(to target: PeriodicMaintenanceState) -> Bool {
        if stickyFailure != nil && target != .terminalRecovery && target != .completed {
            return false
        }
        return periodicMaintenanceAllowsTransition(from: state, to: target)
    }

    /// Pause effective capture while the operator is in the gate, while a unit
    /// is being sealed, or while the next unit is prepared (§5.2).
    @discardableResult
    mutating func pauseEffectiveCapture(at monotonic: TimeInterval) -> Bool {
        clock.pause(at: monotonic)
    }

    mutating func resumeEffectiveCapture(at monotonic: TimeInterval) {
        clock.resume(at: monotonic)
    }

    // MARK: Tick

    /// Called on every HUD/health tick with injected inputs. `unitBytes` may
    /// be nil when the background size probe has not produced a sample yet;
    /// the byte gate then stays inactive rather than guessing.
    mutating func tick(
        monotonic: TimeInterval,
        unitBytes: UInt64?,
        safety: MaintenanceSafetySignal = MaintenanceSafetySignal()
    ) -> MaintenanceTick {
        var result = MaintenanceTick()

        guard policy.isActive else {
            // Feature off (phase 1 default) or invalid policy: the engine must
            // not close gates, emit reminders or pause capture.
            result.reason = policy.featureEnabled ? "policy_invalid" : "feature_disabled"
            return result
        }
        guard !state.isTerminal, state != .idle else {
            result.reason = "state_\(state.rawValue)"
            return result
        }

        // Only ordinary capture feeds the growth estimate: bytes written while
        // sealed, anchoring or preparing the next unit would distort the rate.
        if let bytes = unitBytes, state == .scanning || state == .warning {
            growth.record(monotonic: monotonic, bytes: bytes)
        }

        // Safety first (§5.3): these never continue and never roll over.
        if let reason = safety.terminalReason, state != .finalizingMission {
            _ = pauseEffectiveCapture(at: monotonic)
            if periodicMaintenanceAllowsTransition(from: state, to: .terminalRecovery) {
                state = .terminalRecovery
                pendingTrigger = .safetyStop
                lastFailure = MaintenanceFailure(
                    code: reason,
                    message: "Safety stop: no next unit is started.",
                    atMonotonic: monotonic,
                    sticky: true)
                stickyFailure = lastFailure
                result.enteredTerminalRecovery = true
                result.trigger = .safetyStop
                result.reason = reason
            }
            return result
        }

        guard state == .scanning || state == .warning else {
            // In the gate, anchoring, finalizing or preparing: no capture time
            // accrues and no reminder is emitted from here.
            result.reason = "state_\(state.rawValue)"
            return result
        }

        let elapsed = activeElapsed(at: monotonic)
        let remaining = max(0, policy.calibrationIntervalS - elapsed)
        result.remainingS = remaining

        for reminder in MaintenanceReminder.allCases where !firedReminders.contains(reminder) {
            if remaining <= policy.threshold(for: reminder) {
                firedReminders.insert(reminder)
                result.remindersFired.append(reminder)
            }
        }
        result.remindersFired.sort { lhs, rhs in
            policy.threshold(for: lhs) > policy.threshold(for: rhs)
        }

        if let projected = growth.projectedBytes(
            minimumSamples: policy.minimumGrowthSamples,
            horizonS: policy.growthProjectionHorizonS),
           let limit = policy.softMaxUnitBytes {
            result.projectedBytes = projected
            let projectedWithHeadroom =
                projected.addingReportingOverflow(policy.finalizationHeadroomBytes)
            if projectedWithHeadroom.overflow || projectedWithHeadroom.partialValue >= limit {
                return closeGate(
                    trigger: .sizeLimit,
                    reason: "size_limit",
                    at: monotonic,
                    into: &result)
            }
        }

        if elapsed >= policy.calibrationIntervalS + policy.gracePeriodS {
            return closeGate(
                trigger: .timeLimit,
                reason: "time_limit",
                at: monotonic,
                into: &result)
        }

        state = remaining <= policy.threshold(for: .first) ? .warning : .scanning
        return result
    }

    private mutating func closeGate(
        trigger: MaintenanceTrigger,
        reason: String,
        at monotonic: TimeInterval,
        into result: inout MaintenanceTick
    ) -> MaintenanceTick {
        _ = pauseEffectiveCapture(at: monotonic)
        state = .gate
        pendingTrigger = trigger
        result.enteredGate = true
        result.trigger = trigger
        result.reason = reason
        result.remainingS = 0
        return result
    }

    // MARK: Calibration and rollover

    mutating func beginAnchoring(at monotonic: TimeInterval)
        -> Result<Void, PeriodicMaintenanceTransitionError> {
        let outcome = requestTransition(to: .anchoring)
        if case .success = outcome {
            _ = pauseEffectiveCapture(at: monotonic)
            lastFailure = nil
        }
        return outcome
    }

    /// Node/calibration failure (§10): the gate keeps the old database, the
    /// alignment is unchanged and the operator may retry.
    mutating func failAnchoring(
        code: String,
        message: String,
        at monotonic: TimeInterval
    ) {
        lastFailure = MaintenanceFailure(
            code: code, message: message, atMonotonic: monotonic, sticky: false)
        if periodicMaintenanceAllowsTransition(from: state, to: .gate) {
            state = .gate
        }
    }

    /// Boundary calibration committed durably (§7.2 step 5). Only this call
    /// may open unit finalization.
    mutating func completeAnchoring(
        boundaryID: String,
        at monotonic: TimeInterval
    ) -> Result<Void, PeriodicMaintenanceTransitionError> {
        guard !boundaryID.isEmpty else {
            return .failure(.denied(from: state, to: .finalizingUnit))
        }
        let outcome = requestTransition(to: .finalizingUnit)
        if case .success = outcome {
            pendingBoundaryID = boundaryID
            _ = pauseEffectiveCapture(at: monotonic)
        }
        return outcome
    }

    /// Recoverable save failure (§10): back to the gate for a retry.
    mutating func failUnitFinalization(
        code: String,
        message: String,
        sticky: Bool,
        at monotonic: TimeInterval
    ) {
        let failure = MaintenanceFailure(
            code: code, message: message, atMonotonic: monotonic, sticky: sticky)
        lastFailure = failure
        if sticky {
            stickyFailure = failure
            state = .terminalRecovery
            return
        }
        if periodicMaintenanceAllowsTransition(from: state, to: .gate) {
            state = .gate
        }
    }

    /// `metadata.finalized == true` for the outgoing unit.
    mutating func completeUnitFinalization(at monotonic: TimeInterval)
        -> Result<Void, PeriodicMaintenanceTransitionError> {
        guard let trigger = pendingTrigger, trigger.startsNextUnit,
              let boundaryID = pendingBoundaryID, !boundaryID.isEmpty else {
            return .failure(.denied(from: state, to: .preparingNextUnit))
        }
        let outcome = requestTransition(to: .preparingNextUnit)
        if case .success = outcome {
            _ = pauseEffectiveCapture(at: monotonic)
        }
        return outcome
    }

    /// Re-enters the exact failed finalization transaction. The durable
    /// trigger and boundary id are required so an ordinary gate can never be
    /// mistaken for a save retry.
    mutating func retryUnitFinalization(at monotonic: TimeInterval)
        -> Result<Void, PeriodicMaintenanceTransitionError> {
        guard state == .gate, stickyFailure == nil,
              let trigger = pendingTrigger, trigger.startsNextUnit,
              let boundaryID = pendingBoundaryID, !boundaryID.isEmpty else {
            return .failure(.denied(from: state, to: .finalizingUnit))
        }
        state = .finalizingUnit
        _ = pauseEffectiveCapture(at: monotonic)
        lastFailure = nil
        return .success(())
    }

    /// New unit start failed (§10): the finished unit is never rolled back and
    /// the same next index is retried, so a retry cannot skip a unit number.
    mutating func failNextUnitPreparation(
        code: String,
        message: String,
        sticky: Bool,
        at monotonic: TimeInterval
    ) {
        let failure = MaintenanceFailure(
            code: code, message: message, atMonotonic: monotonic, sticky: sticky)
        lastFailure = failure
        if sticky {
            stickyFailure = failure
            state = .terminalRecovery
            return
        }
        if periodicMaintenanceAllowsTransition(from: state, to: .gate) {
            state = .gate
        }
    }

    /// Re-enters preparation without incrementing the in-memory unit index.
    /// The executor derives the pending index from the durable checkpoint.
    mutating func retryNextUnitPreparation(at monotonic: TimeInterval)
        -> Result<Void, PeriodicMaintenanceTransitionError> {
        guard state == .gate, stickyFailure == nil,
              let trigger = pendingTrigger, trigger.startsNextUnit,
              let boundaryID = pendingBoundaryID, !boundaryID.isEmpty else {
            return .failure(.denied(from: state, to: .preparingNextUnit))
        }
        state = .preparingNextUnit
        _ = pauseEffectiveCapture(at: monotonic)
        lastFailure = nil
        return .success(())
    }

    /// Next-unit receipt and incoming boundary binding are durable: ordinary
    /// capture resumes and the effective clock restarts from zero (§8.2-11).
    mutating func completeNextUnitPreparation(
        unitIndex nextIndex: Int,
        at monotonic: TimeInterval
    ) -> Result<Void, PeriodicMaintenanceTransitionError> {
        guard nextIndex == unitIndex + 1 else {
            return .failure(.invalidUnitIndex(expected: unitIndex + 1, actual: nextIndex))
        }
        let outcome = requestTransition(to: .scanning)
        guard case .success = outcome else { return outcome }
        unitIndex = nextIndex
        clock.reset()
        clock.resume(at: monotonic)
        firedReminders.removeAll()
        growth = StorageGrowthEstimator()
        growth.capacity = max(policy.growthSampleCapacity, policy.minimumGrowthSamples)
        pendingTrigger = nil
        pendingBoundaryID = nil
        lastFailure = nil
        return .success(())
    }

    mutating func beginMissionFinalization(at monotonic: TimeInterval)
        -> Result<Void, PeriodicMaintenanceTransitionError> {
        let outcome = requestTransition(to: .finalizingMission)
        if case .success = outcome {
            _ = pauseEffectiveCapture(at: monotonic)
        }
        return outcome
    }

    mutating func completeMission() -> Result<Void, PeriodicMaintenanceTransitionError> {
        requestTransition(to: .completed)
    }

    /// Publishes the engine state into the durable mission checkpoint. The
    /// checkpoint is the only recovery input after a crash, so elapsed time,
    /// the maintenance state and the pending trigger are all taken from the
    /// engine instead of being recomputed by the caller.
    mutating func apply(
        to checkpoint: inout MissionLiveCheckpoint,
        at monotonic: TimeInterval
    ) {
        checkpoint.activeCaptureElapsedS = activeElapsed(at: monotonic)
        checkpoint.nextMaintenanceAtActiveS = policy.calibrationIntervalS
        checkpoint.maintenanceState = state.rawValue
        checkpoint.pendingTrigger = pendingTrigger?.rawValue
        checkpoint.lastError = lastFailure?.code
        checkpoint.pendingBoundaryId = pendingBoundaryID
    }

    mutating func enterTerminalRecovery(
        code: String,
        message: String,
        at monotonic: TimeInterval
    ) {
        let failure = MaintenanceFailure(
            code: code, message: message, atMonotonic: monotonic, sticky: true)
        lastFailure = failure
        stickyFailure = failure
        state = .terminalRecovery
    }
}

// MARK: - Mission schema

struct MissionIdentity: Codable, Equatable {
    let missionId: String
    let priorMapId: String?
    let priorMapPackageSha256: String?
    let storeId: String?
    let floorId: String?
    let buildIdentity: String?

    init(
        missionId: String,
        priorMapId: String? = nil,
        priorMapPackageSha256: String? = nil,
        storeId: String? = nil,
        floorId: String? = nil,
        buildIdentity: String? = nil
    ) {
        self.missionId = missionId
        self.priorMapId = priorMapId
        self.priorMapPackageSha256 = priorMapPackageSha256
        self.storeId = storeId
        self.floorId = floorId
        self.buildIdentity = buildIdentity
    }

    /// §7.1: every unit of a mission must keep the same prior map, store and
    /// floor identity. A nil prior map is only legal for the legacy single
    /// session shape and is rejected for multi-unit missions.
    func matches(_ other: MissionIdentity) -> Bool {
        missionId == other.missionId
            && priorMapId == other.priorMapId
            && priorMapPackageSha256 == other.priorMapPackageSha256
            && storeId == other.storeId
            && floorId == other.floorId
            && buildIdentity == other.buildIdentity
    }
}

struct MissionUnitDescriptor: Codable, Equatable {
    let unitId: String
    let unitIndex: Int
    /// Mission-root-relative path; absolute paths and `..` are rejected by
    /// `validatedMissionRelativePath`.
    let relativePath: String
    let trackingSessionId: String
    let databaseRelativePath: String
    let metadataRelativePath: String
    var databaseSha256: String?
    var metadataSha256: String?
    var previousUnitId: String?
    var previousUnitMetadataSha256: String?
    var rolloverTrigger: MaintenanceTrigger?
    var activeCaptureDurationS: TimeInterval?
    var boundaryCheckpointId: String?
    var boundaryManualEventSha256: String?
    var unitStorageBytes: UInt64?
    var finalized: Bool
    /// nil while the unit is open: a live checkpoint must not be presented as
    /// a saved artifact (§6.4).
    var finalizedAtUnix: TimeInterval?

    init(
        unitId: String,
        unitIndex: Int,
        relativePath: String,
        trackingSessionId: String,
        databaseRelativePath: String,
        metadataRelativePath: String,
        finalized: Bool = false
    ) {
        self.unitId = unitId
        self.unitIndex = unitIndex
        self.relativePath = relativePath
        self.trackingSessionId = trackingSessionId
        self.databaseRelativePath = databaseRelativePath
        self.metadataRelativePath = metadataRelativePath
        self.finalized = finalized
    }
}

/// One end of a boundary: the exact node, its stamp, the node-time snapshot
/// generation and the receipt/event hash that makes the end verifiable.
struct MissionBoundaryEnd: Codable, Equatable {
    let unitId: String
    let unitIndex: Int
    let trackingSessionId: String
    let nodeId: Int
    let nodeStamp: TimeInterval
    let nodeTimeSnapshotGeneration: UInt64
    let confirmedX: Double
    let confirmedY: Double
    let confirmedYaw: Double
    var manualEventSha256: String?
    var startReceiptSha256: String?

    var poseIsFinite: Bool {
        confirmedX.isFinite && confirmedY.isFinite && confirmedYaw.isFinite
    }
}

struct MissionBoundaryRecord: Codable, Equatable {
    static let format = "marketscanner_mission_boundary"
    static let currentVersion = 1

    let format: String
    let version: Int
    let missionId: String
    let boundaryId: String
    let priorMapId: String?
    let priorMapPackageSha256: String?
    let storeId: String?
    let floorId: String?
    let fromUnitId: String
    let toUnitId: String
    let confirmedX: Double
    let confirmedY: Double
    let confirmedYaw: Double
    var outgoing: MissionBoundaryEnd?
    var incoming: MissionBoundaryEnd?
    var createdAtUnix: TimeInterval?
    var committedAtUnix: TimeInterval?
    var fileSha256: String?

    init(
        missionId: String,
        boundaryId: String,
        identity: MissionIdentity,
        fromUnitId: String,
        toUnitId: String,
        confirmedX: Double,
        confirmedY: Double,
        confirmedYaw: Double
    ) {
        self.format = MissionBoundaryRecord.format
        self.version = MissionBoundaryRecord.currentVersion
        self.missionId = missionId
        self.boundaryId = boundaryId
        self.priorMapId = identity.priorMapId
        self.priorMapPackageSha256 = identity.priorMapPackageSha256
        self.storeId = identity.storeId
        self.floorId = identity.floorId
        self.fromUnitId = fromUnitId
        self.toUnitId = toUnitId
        self.confirmedX = confirmedX
        self.confirmedY = confirmedY
        self.confirmedYaw = confirmedYaw
    }

    /// A boundary is only a cross-unit anchor when both ends are durable
    /// (§7.3). One-sided evidence keeps the previous unit individually
    /// processable but never publishes the mission.
    var isComplete: Bool {
        guard let outgoing, let incoming else { return false }
        guard let createdAtUnix, let committedAtUnix else { return false }
        return !missionId.isEmpty
            && !boundaryId.isEmpty
            && !fromUnitId.isEmpty
            && !toUnitId.isEmpty
            && fromUnitId != toUnitId
            && createdAtUnix.isFinite
            && committedAtUnix.isFinite
            && createdAtUnix >= 0
            && committedAtUnix >= createdAtUnix
            && confirmedX.isFinite
            && confirmedY.isFinite
            && confirmedYaw.isFinite
            && outgoing.poseIsFinite
            && incoming.poseIsFinite
            && outgoing.unitId == fromUnitId
            && incoming.unitId == toUnitId
            && outgoing.unitIndex >= 1
            && incoming.unitIndex == outgoing.unitIndex + 1
            && outgoing.trackingSessionId.isEmpty == false
            && incoming.trackingSessionId.isEmpty == false
            && outgoing.nodeId > 0
            && incoming.nodeId > 0
            && outgoing.nodeStamp.isFinite
            && incoming.nodeStamp.isFinite
            && outgoing.nodeStamp >= 0
            && incoming.nodeStamp >= 0
            && outgoing.nodeTimeSnapshotGeneration > 0
            && incoming.nodeTimeSnapshotGeneration > 0
            // The outgoing end is authorized by the manual calibration event;
            // the incoming end is authorized by the next-unit start receipt.
            // The shared schema permits the opposite-role hashes to be absent,
            // but rejects them if a producer does include malformed values.
            && isSHA256(outgoing.manualEventSha256)
            && isNilOrSHA256(outgoing.startReceiptSha256)
            && isNilOrSHA256(incoming.manualEventSha256)
            && isSHA256(incoming.startReceiptSha256)
            && abs(outgoing.confirmedX - confirmedX) <= Self.poseToleranceMeters
            && abs(incoming.confirmedX - confirmedX) <= Self.poseToleranceMeters
            && abs(outgoing.confirmedY - confirmedY) <= Self.poseToleranceMeters
            && abs(incoming.confirmedY - confirmedY) <= Self.poseToleranceMeters
            && normalizedYawDelta(outgoing.confirmedYaw, confirmedYaw) <= Self.yawToleranceRadians
            && normalizedYawDelta(incoming.confirmedYaw, confirmedYaw) <= Self.yawToleranceRadians
    }

    static let poseToleranceMeters = 1e-6
    static let yawToleranceRadians = 1e-6
}

private func isSHA256(_ value: String?) -> Bool {
    guard let value, value.utf8.count == 64 else { return false }
    return value.utf8.allSatisfy { byte in
        (byte >= 48 && byte <= 57)
            || (byte >= 65 && byte <= 70)
            || (byte >= 97 && byte <= 102)
    }
}

private func isNilOrSHA256(_ value: String?) -> Bool {
    value == nil || isSHA256(value)
}

private func normalizedYawDelta(_ lhs: Double, _ rhs: Double) -> Double {
    var delta = (lhs - rhs).remainder(dividingBy: 2 * Double.pi)
    if delta < -Double.pi { delta += 2 * Double.pi }
    if delta > Double.pi { delta -= 2 * Double.pi }
    return abs(delta)
}

/// Running mission state. Its presence means the mission is NOT finished:
/// `mission_manifest.json` is the only completion marker (§8.3).
struct MissionLiveCheckpoint: Codable, Equatable {
    static let format = "marketscanner_mission_live_checkpoint"
    static let currentVersion = 1

    let format: String
    let version: Int
    let missionId: String
    let policyVersion: Int
    let identity: MissionIdentity
    var currentUnit: MissionUnitDescriptor?
    var finalizedUnits: [MissionUnitDescriptor] = []
    var pendingBoundaryId: String?
    var pendingBoundaryOutgoingComplete: Bool = false
    var pendingBoundaryIncomingComplete: Bool = false
    var activeCaptureElapsedS: TimeInterval = 0
    var nextMaintenanceAtActiveS: TimeInterval = PeriodicMaintenancePolicy().calibrationIntervalS
    /// Raw value of the trigger that closed the gate, persisted so recovery
    /// does not have to guess why the mission stopped.
    var pendingTrigger: String? = nil
    var maintenanceState: String = PeriodicMaintenanceState.idle.rawValue
    var lastCommittedAtUnix: TimeInterval?
    var externalCopyQueue: [String] = []
    var lastError: String?

    init(
        missionId: String,
        policyVersion: Int,
        identity: MissionIdentity,
        nextMaintenanceAtActiveS: TimeInterval = 1800
    ) {
        self.format = MissionLiveCheckpoint.format
        self.version = MissionLiveCheckpoint.currentVersion
        self.missionId = missionId
        self.policyVersion = policyVersion
        self.identity = identity
        self.nextMaintenanceAtActiveS = nextMaintenanceAtActiveS
    }

    var state: PeriodicMaintenanceState? {
        PeriodicMaintenanceState(rawValue: maintenanceState)
    }

    var isWellFormed: Bool {
        guard format == MissionLiveCheckpoint.format
            && version == MissionLiveCheckpoint.currentVersion
            && policyVersion == PeriodicMaintenancePolicy.currentPolicyVersion
            && !missionId.isEmpty
            && identity.missionId == missionId
            && identity.priorMapId?.isEmpty == false
            && isSHA256(identity.priorMapPackageSha256)
            && identity.storeId?.isEmpty == false
            && identity.floorId?.isEmpty == false
            && identity.buildIdentity?.isEmpty == false
            && activeCaptureElapsedS.isFinite
            && activeCaptureElapsedS >= 0
            && nextMaintenanceAtActiveS.isFinite
            && nextMaintenanceAtActiveS > 0
            && state != nil else {
            return false
        }
        if let rawTrigger = pendingTrigger,
           MaintenanceTrigger(rawValue: rawTrigger) == nil {
            return false
        }
        let ownedUnits = finalizedUnits + [currentUnit].compactMap { $0 }
        if ownedUnits.contains(where: {
            $0.unitIndex < 1 || $0.unitId.isEmpty || $0.trackingSessionId.isEmpty
        }) {
            return false
        }
        if Set(ownedUnits.map(\.unitIndex)).count != ownedUnits.count
            || Set(ownedUnits.map(\.unitId)).count != ownedUnits.count {
            return false
        }
        if finalizedUnits.contains(where: { !$0.finalized }) {
            return false
        }
        let finalizedIndices = finalizedUnits.map(\.unitIndex).sorted()
        let expectedFinalizedIndices = finalizedUnits.isEmpty
            ? []
            : Array(1...finalizedUnits.count)
        guard finalizedIndices == expectedFinalizedIndices else {
            return false
        }
        if let currentUnit {
            guard currentUnit.relativePath.hasPrefix("units/"),
                  currentUnit.databaseRelativePath
                    == currentUnit.relativePath + "/segment_0001/rtabmap_segment_0001.db",
                  currentUnit.metadataRelativePath
                    == currentUnit.relativePath + "/segment_0001/metadata.json" else {
                return false
            }
            do {
                _ = try validatedMissionRelativePath(currentUnit.relativePath)
                _ = try validatedMissionRelativePath(currentUnit.databaseRelativePath)
                _ = try validatedMissionRelativePath(currentUnit.metadataRelativePath)
            } catch {
                return false
            }
        }
        switch state {
        case .scanning, .warning:
            return currentUnit != nil
                && currentUnit?.finalized == false
                && currentUnit?.unitIndex == finalizedUnits.count + 1
                && pendingTrigger == nil
        case .gate, .anchoring:
            return currentUnit != nil
                && currentUnit?.finalized == false
                && currentUnit?.unitIndex == finalizedUnits.count + 1
                && decodedPendingTrigger?.startsNextUnit == true
        case .finalizingUnit, .preparingNextUnit:
            return currentUnit != nil
                && currentUnit?.finalized == false
                && currentUnit?.unitIndex == finalizedUnits.count + 1
                && decodedPendingTrigger?.startsNextUnit == true
                && pendingBoundaryId?.isEmpty == false
        case .finalizingMission:
            return currentUnit != nil && currentUnit?.unitIndex == finalizedUnits.count + 1
        case .idle, .terminalRecovery, .completed:
            return true
        case .none:
            return false
        }
    }

    /// The stored trigger, decoded fail-closed: an unknown value is reported
    /// as nil so recovery cannot act on a trigger it does not understand.
    var decodedPendingTrigger: MaintenanceTrigger? {
        guard let raw = pendingTrigger else { return nil }
        return MaintenanceTrigger(rawValue: raw)
    }
}

/// Immutable mission completion manifest (§8.3).
struct MissionManifest: Codable, Equatable {
    static let format = "marketscanner_mission_manifest"
    static let currentVersion = 1

    let format: String
    let version: Int
    let missionId: String
    let identity: MissionIdentity
    let units: [MissionUnitDescriptor]
    let boundaries: [MissionBoundaryRecord]
    var completedAtUnix: TimeInterval?
    var integrity: String = "unverified"
    var publishPermitted: Bool = false

    init(
        missionId: String,
        identity: MissionIdentity,
        units: [MissionUnitDescriptor],
        boundaries: [MissionBoundaryRecord]
    ) {
        self.format = MissionManifest.format
        self.version = MissionManifest.currentVersion
        self.missionId = missionId
        self.identity = identity
        self.units = units
        self.boundaries = boundaries
    }
}

// MARK: - Path safety

enum MissionPathError: Error, Equatable, CustomStringConvertible {
    case emptyPath
    case absolutePath(String)
    case parentEscape(String)
    case emptyComponent(String)
    case backslash(String)
    case duplicateUnitId(String)
    case duplicateUnitIndex(Int)

    var description: String {
        switch self {
        case .emptyPath:
            return "mission_path_empty"
        case .absolutePath(let path):
            return "mission_path_absolute:\(path)"
        case .parentEscape(let path):
            return "mission_path_parent_escape:\(path)"
        case .emptyComponent(let path):
            return "mission_path_empty_component:\(path)"
        case .backslash(let path):
            return "mission_path_backslash:\(path)"
        case .duplicateUnitId(let id):
            return "mission_duplicate_unit_id:\(id)"
        case .duplicateUnitIndex(let index):
            return "mission_duplicate_unit_index:\(index)"
        }
    }
}

/// Canonical, mission-root-relative path validation (§9.2). Symlinks and
/// hard links are rejected at the file system layer by
/// `PeriodicScanMaintenanceStore`, because that check needs a real path.
func validatedMissionRelativePath(_ candidate: String) throws -> String {
    guard !candidate.isEmpty else { throw MissionPathError.emptyPath }
    guard !candidate.hasPrefix("/") && !candidate.hasPrefix("~") else {
        throw MissionPathError.absolutePath(candidate)
    }
    guard !candidate.contains("\\") else { throw MissionPathError.backslash(candidate) }
    let components = candidate.split(separator: "/", omittingEmptySubsequences: false)
    for component in components {
        guard !component.isEmpty else { throw MissionPathError.emptyComponent(candidate) }
        guard component != "." else { continue }
        guard component != ".." else { throw MissionPathError.parentEscape(candidate) }
    }
    return candidate
}

// MARK: - Structural validation

/// Unit index continuity, hash chain and boundary coverage for a set of
/// units. Used by the phone before writing a manifest and mirrored on the PC
/// side so both ends fail closed on the same inputs (§11.1).
func validateMissionStructure(
    units: [MissionUnitDescriptor],
    boundaries: [MissionBoundaryRecord],
    identity: MissionIdentity
) -> [MissionFinding] {
    var findings: [MissionFinding] = []

    if units.isEmpty {
        findings.append(MissionFinding(
            severity: .fatal,
            code: "mission_no_units",
            message: "A mission must contain at least one finalized unit."))
        return findings
    }

    let requiredIdentityValues = [
        identity.missionId,
        identity.priorMapId ?? "",
        identity.priorMapPackageSha256 ?? "",
        identity.storeId ?? "",
        identity.floorId ?? "",
        identity.buildIdentity ?? ""
    ]
    if requiredIdentityValues.contains(where: { $0.isEmpty })
        || !isSHA256(identity.priorMapPackageSha256) {
        findings.append(MissionFinding(
            severity: .fatal,
            code: "mission_identity_incomplete",
            message: "Mission/map/package/store/floor/build identity must be complete."))
    }

    let indices = units.map(\.unitIndex).sorted()
    let expected = Array(1...units.count)
    if indices != expected {
        findings.append(MissionFinding(
            severity: .fatal,
            code: "mission_unit_index_discontinuous",
            message: "Unit indices must be 1..N without gaps or duplicates."))
    }

    var seenIds = Set<String>()
    var seenTracking = Set<String>()
    for unit in units {
        if unit.unitId.isEmpty || unit.trackingSessionId.isEmpty || unit.unitIndex < 1 {
            findings.append(MissionFinding(
                severity: .fatal,
                code: "mission_unit_identity_incomplete",
                message: "Unit \(unit.unitIndex) has an empty id or tracking session."))
        }
        if !seenIds.insert(unit.unitId).inserted {
            findings.append(MissionFinding(
                severity: .fatal,
                code: "mission_duplicate_unit_id",
                message: "Duplicate unit id \(unit.unitId)."))
        }
        if !seenTracking.insert(unit.trackingSessionId).inserted {
            findings.append(MissionFinding(
                severity: .fatal,
                code: "mission_duplicate_tracking_session",
                message: "Duplicate tracking session \(unit.trackingSessionId)."))
        }
        do {
            _ = try validatedMissionRelativePath(unit.relativePath)
            _ = try validatedMissionRelativePath(unit.databaseRelativePath)
            _ = try validatedMissionRelativePath(unit.metadataRelativePath)
            let expectedDatabase = unit.relativePath
                + "/segment_0001/rtabmap_segment_0001.db"
            let expectedMetadata = unit.relativePath + "/segment_0001/metadata.json"
            if unit.databaseRelativePath != expectedDatabase
                || unit.metadataRelativePath != expectedMetadata {
                findings.append(MissionFinding(
                    severity: .fatal,
                    code: "mission_unit_declared_path_mismatch",
                    message: "Unit \(unit.unitIndex) file paths do not match its directory."))
            }
        } catch {
            findings.append(MissionFinding(
                severity: .fatal,
                code: "mission_unit_path_invalid",
                message: "\(error)"))
        }
        if !unit.finalized {
            findings.append(MissionFinding(
                severity: .fatal,
                code: "mission_unit_not_finalized",
                message: "Unit \(unit.unitIndex) is not finalized."))
        }
        if !isSHA256(unit.databaseSha256) || !isSHA256(unit.metadataSha256) {
            findings.append(MissionFinding(
                severity: .fatal,
                code: "mission_unit_digest_missing",
                message: "Unit \(unit.unitIndex) must carry database and metadata SHA-256."))
        }
        if unit.activeCaptureDurationS == nil
            || unit.activeCaptureDurationS?.isFinite != true
            || (unit.activeCaptureDurationS ?? -1) < 0 {
            findings.append(MissionFinding(
                severity: .fatal,
                code: "mission_unit_duration_invalid",
                message: "Unit \(unit.unitIndex) active duration is invalid."))
        }
        if unit.rolloverTrigger == nil {
            findings.append(MissionFinding(
                severity: .fatal,
                code: "mission_unit_trigger_missing",
                message: "Unit \(unit.unitIndex) has no finalization trigger."))
        }
        if unit.unitStorageBytes == nil || unit.unitStorageBytes == 0 {
            findings.append(MissionFinding(
                severity: .fatal,
                code: "mission_unit_storage_missing",
                message: "Unit \(unit.unitIndex) has no verified storage size."))
        }
        if let finalizedAt = unit.finalizedAtUnix,
           !finalizedAt.isFinite || finalizedAt < 0 {
            findings.append(MissionFinding(
                severity: .fatal,
                code: "mission_unit_finalized_time_invalid",
                message: "Unit \(unit.unitIndex) finalized time is invalid."))
        } else if unit.finalizedAtUnix == nil {
            findings.append(MissionFinding(
                severity: .fatal,
                code: "mission_unit_finalized_time_missing",
                message: "Unit \(unit.unitIndex) has no finalization timestamp."))
        }
    }

    let ordered = units.sorted { $0.unitIndex < $1.unitIndex }
    for index in 1..<ordered.count {
        let previous = ordered[index - 1]
        let current = ordered[index]
        if current.previousUnitId != previous.unitId {
            findings.append(MissionFinding(
                severity: .fatal,
                code: "mission_previous_unit_id_mismatch",
                message: "Unit \(current.unitIndex) points at an unexpected previous unit."))
        }
        if current.previousUnitMetadataSha256 != previous.metadataSha256 {
            findings.append(MissionFinding(
                severity: .fatal,
                code: "mission_hash_chain_broken",
                message: "Unit \(current.unitIndex) metadata hash chain is broken."))
        }
        if current.previousUnitMetadataSha256 == nil {
            findings.append(MissionFinding(
                severity: .fatal,
                code: "mission_hash_chain_missing",
                message: "Unit \(current.unitIndex) does not carry the previous metadata hash."))
        }
        if ordered[index].unitIndex <= previous.unitIndex {
            findings.append(MissionFinding(
                severity: .fatal,
                code: "mission_unit_order_invalid",
                message: "Unit indices must strictly increase."))
        }
    }
    if ordered.first?.previousUnitId != nil
        || ordered.first?.previousUnitMetadataSha256 != nil {
        findings.append(MissionFinding(
            severity: .fatal,
            code: "mission_first_unit_has_predecessor",
            message: "Unit 1 must not declare a predecessor."))
    }

    // Exactly one complete boundary between every adjacent pair.
    let boundaryIndex = Dictionary(
        boundaries.map { ("\($0.fromUnitId)->\($0.toUnitId)", $0) },
        uniquingKeysWith: { first, _ in first })
    var boundaryIds = Set<String>()
    for boundary in boundaries where !boundaryIds.insert(boundary.boundaryId).inserted {
        findings.append(MissionFinding(
            severity: .fatal,
            code: "mission_duplicate_boundary_id",
            message: "Duplicate boundary id \(boundary.boundaryId)."))
    }
    if boundaries.count > boundaryIndex.count {
        findings.append(MissionFinding(
            severity: .fatal,
            code: "mission_duplicate_boundary_pair",
            message: "More than one boundary links the same unit pair."))
    }
    if boundaries.count != max(0, units.count - 1) {
        findings.append(MissionFinding(
            severity: .fatal,
            code: "mission_boundary_count_invalid",
            message: "A mission must contain exactly one boundary per adjacent unit pair."))
    }
    for index in 1..<ordered.count {
        let previous = ordered[index - 1]
        let current = ordered[index]
        guard let boundary = boundaryIndex["\(previous.unitId)->\(current.unitId)"] else {
            findings.append(MissionFinding(
                severity: .fatal,
                code: "mission_boundary_missing",
                message: "No boundary links unit \(previous.unitIndex) and \(current.unitIndex)."))
            continue
        }
        if boundary.missionId != identity.missionId {
            findings.append(MissionFinding(
                severity: .fatal,
                code: "mission_boundary_mission_mismatch",
                message: "Boundary \(boundary.boundaryId) belongs to another mission."))
        }
        if boundary.priorMapId != identity.priorMapId
            || boundary.priorMapPackageSha256 != identity.priorMapPackageSha256
            || boundary.storeId != identity.storeId
            || boundary.floorId != identity.floorId {
            findings.append(MissionFinding(
                severity: .fatal,
                code: "mission_boundary_identity_mismatch",
                message: "Boundary \(boundary.boundaryId) identity differs from the mission."))
        }
        if boundary.outgoing?.unitIndex != previous.unitIndex
            || boundary.incoming?.unitIndex != current.unitIndex
            || boundary.outgoing?.trackingSessionId != previous.trackingSessionId
            || boundary.incoming?.trackingSessionId != current.trackingSessionId {
            findings.append(MissionFinding(
                severity: .fatal,
                code: "mission_boundary_unit_mismatch",
                message: "Boundary \(boundary.boundaryId) end identity differs from its units."))
        }
        if !isSHA256(boundary.fileSha256) {
            findings.append(MissionFinding(
                severity: .fatal,
                code: "mission_boundary_digest_missing",
                message: "Boundary \(boundary.boundaryId) has no file SHA-256."))
        }
        if !boundary.isComplete {
            findings.append(MissionFinding(
                severity: .fatal,
                code: "mission_boundary_incomplete",
                message: "Boundary \(boundary.boundaryId) lacks durable two-sided evidence."))
        }
    }

    let expectedPairs = Set((1..<ordered.count).map {
        "\(ordered[$0 - 1].unitId)->\(ordered[$0].unitId)"
    })
    for boundary in boundaries
    where !expectedPairs.contains("\(boundary.fromUnitId)->\(boundary.toUnitId)") {
        findings.append(MissionFinding(
            severity: .fatal,
            code: "mission_boundary_nonadjacent",
            message: "Boundary \(boundary.boundaryId) does not link adjacent units."))
    }

    return findings
}

// MARK: - Crash recovery planning

struct MissionRecoveryObservation: Equatable {
    let relativePath: String
    var metadataPresent: Bool
    var metadataFinalized: Bool?
    var databasePresent: Bool
    var liveCheckpointPresent: Bool

    init(
        relativePath: String,
        metadataPresent: Bool,
        metadataFinalized: Bool?,
        databasePresent: Bool,
        liveCheckpointPresent: Bool
    ) {
        self.relativePath = relativePath
        self.metadataPresent = metadataPresent
        self.metadataFinalized = metadataFinalized
        self.databasePresent = databasePresent
        self.liveCheckpointPresent = liveCheckpointPresent
    }
}

struct MissionRecoveryInput: Equatable {
    var checkpoint: MissionLiveCheckpoint?
    var observations: [MissionRecoveryObservation]
    var monotonicNow: TimeInterval
    var policy: PeriodicMaintenancePolicy

    init(
        checkpoint: MissionLiveCheckpoint?,
        observations: [MissionRecoveryObservation],
        monotonicNow: TimeInterval,
        policy: PeriodicMaintenancePolicy = PeriodicMaintenancePolicy()
    ) {
        self.checkpoint = checkpoint
        self.observations = observations
        self.monotonicNow = monotonicNow
        self.policy = policy
    }
}

/// What the app must do when it comes back from a crash, a kill or a
/// foreground resume. The planner is pure and deterministic: replaying the
/// same input yields the same action and the same idempotency key, so a
/// repeated reconciliation can never mint a second unit index or a second
/// boundary id (§10).
enum MissionRecoveryAction: Equatable {
    case startNewMission
    case resumeScanning(unitIndex: Int)
    case enterMaintenanceGate(unitIndex: Int, trigger: MaintenanceTrigger, reason: String)
    case retryUnitFinalization(unitIndex: Int, reason: String)
    case retryCheckpointCleanup(unitIndex: Int, reason: String)
    case retryNextUnitPreparation(unitIndex: Int, reason: String)
    case quarantineOrphan(paths: [String], reason: String)
    case terminalRecovery(unitIndex: Int?, reason: String)
    case operatorReview(reason: String)
}

struct MissionRecoveryPlan: Equatable {
    let action: MissionRecoveryAction
    let findings: [MissionFinding]
    /// True when the UI must not auto-continue: the operator has to confirm.
    let requiresOperatorConfirmation: Bool
    /// Stable key computed from the observation set; identical input produces
    /// an identical key so the executor can deduplicate repeated runs.
    let idempotencyKey: String
}

/// The next unit index to use. Derived from the checkpoint and the observed
/// directories only, never from a mutable counter kept in memory.
func nextMissionUnitIndex(
    checkpoint: MissionLiveCheckpoint?,
    observations: [MissionRecoveryObservation]
) -> Int {
    let finalizedMax = checkpoint?.finalizedUnits.map(\.unitIndex).max() ?? 0
    if let current = checkpoint?.currentUnit,
       !current.finalized,
       current.unitIndex == finalizedMax + 1 {
        return current.unitIndex
    }
    return finalizedMax + 1
}

func planMissionRecovery(_ input: MissionRecoveryInput) -> MissionRecoveryPlan {
    var findings: [MissionFinding] = []
    let observations = input.observations.sorted { $0.relativePath < $1.relativePath }
    let idempotencyKey = missionRecoveryIdempotencyKey(input: input, observations: observations)

    // Phase 1 ships disabled: recovery must not plan mission actions, adopt
    // directories or quarantine files on behalf of a feature that never ran.
    guard input.policy.featureEnabled else {
        findings.append(MissionFinding(
            severity: .info,
            code: "recovery_feature_disabled",
            message: "Periodic maintenance is disabled; no mission recovery action is planned."))
        return MissionRecoveryPlan(
            action: .operatorReview(reason: "maintenance_feature_disabled"),
            findings: findings,
            requiresOperatorConfirmation: true,
            idempotencyKey: idempotencyKey)
    }

    // §10: a unit whose metadata was committed with finalized=false is dead.
    // It must never be reopened, and the mission may not continue as a
    // prior-map mission.
    for observation in observations where observation.metadataPresent
        && observation.metadataFinalized == false {
        findings.append(MissionFinding(
            severity: .fatal,
            code: "recovery_unit_finalized_false",
            message: "\(observation.relativePath) committed metadata with finalized=false."))
        let index = unitIndex(from: observation.relativePath)
        return MissionRecoveryPlan(
            action: .terminalRecovery(
                unitIndex: index,
                reason: "unit_metadata_finalized_false"),
            findings: findings,
            requiresOperatorConfirmation: true,
            idempotencyKey: idempotencyKey)
    }

    guard let checkpoint = input.checkpoint else {
        if observations.isEmpty {
            return MissionRecoveryPlan(
                action: .startNewMission,
                findings: findings,
                requiresOperatorConfirmation: false,
                idempotencyKey: idempotencyKey)
        }
        findings.append(MissionFinding(
            severity: .warning,
            code: "recovery_no_checkpoint",
            message: "Unit directories exist without a mission checkpoint."))
        return MissionRecoveryPlan(
            action: .quarantineOrphan(
                paths: observations.map(\.relativePath),
                reason: "missing_mission_checkpoint"),
            findings: findings,
            requiresOperatorConfirmation: true,
            idempotencyKey: idempotencyKey)
    }

    if !checkpoint.isWellFormed {
        findings.append(MissionFinding(
            severity: .fatal,
            code: "recovery_checkpoint_malformed",
            message: "The mission checkpoint format or policy version is unsupported."))
        return MissionRecoveryPlan(
            action: .operatorReview(reason: "mission_checkpoint_malformed"),
            findings: findings,
            requiresOperatorConfirmation: true,
            idempotencyKey: idempotencyKey)
    }

    if !input.policy.isValid {
        findings.append(MissionFinding(
            severity: .fatal,
            code: "recovery_policy_invalid",
            message: "The maintenance policy failed validation."))
        return MissionRecoveryPlan(
            action: .operatorReview(reason: "maintenance_policy_invalid"),
            findings: findings + input.policy.validationFindings(),
            requiresOperatorConfirmation: true,
            idempotencyKey: idempotencyKey)
    }


    // Directories on disk that the checkpoint does not own are orphans and are
    // never silently adopted.
    let knownPaths = Set(
        ([checkpoint.currentUnit?.relativePath].compactMap { $0 }
            + checkpoint.finalizedUnits.map(\.relativePath)))
    let orphans = observations.map(\.relativePath).filter { !knownPaths.contains($0) }
    if !orphans.isEmpty {
        findings.append(MissionFinding(
            severity: .warning,
            code: "recovery_orphan_directories",
            message: "\(orphans.count) directory(ies) are not referenced by the checkpoint."))
        // Fail closed (§10/§15): an unreferenced directory is quarantined for
        // operator review. It is never adopted as a unit and the mission never
        // auto-continues while one exists.
        return MissionRecoveryPlan(
            action: .quarantineOrphan(
                paths: orphans.sorted(),
                reason: "directories_not_referenced_by_checkpoint"),
            findings: findings,
            requiresOperatorConfirmation: true,
            idempotencyKey: idempotencyKey)
    }

    guard let state = checkpoint.state else {
        findings.append(MissionFinding(
            severity: .fatal,
            code: "recovery_checkpoint_state_unknown",
            message: "The checkpoint maintenance state is unknown."))
        return MissionRecoveryPlan(
            action: .operatorReview(reason: "mission_checkpoint_state_unknown"),
            findings: findings,
            requiresOperatorConfirmation: true,
            idempotencyKey: idempotencyKey)
    }
    let currentIndex = checkpoint.currentUnit?.unitIndex ?? 0

    switch state {
    case .completed:
        return MissionRecoveryPlan(
            action: .operatorReview(reason: "mission_already_completed"),
            findings: findings,
            requiresOperatorConfirmation: true,
            idempotencyKey: idempotencyKey)

    case .terminalRecovery:
        return MissionRecoveryPlan(
            action: .terminalRecovery(
                unitIndex: currentIndex > 0 ? currentIndex : nil,
                reason: checkpoint.lastError ?? "terminal_recovery"),
            findings: findings,
            requiresOperatorConfirmation: true,
            idempotencyKey: idempotencyKey)

    case .finalizingUnit:
        // The outgoing unit is not sealed yet. Retrying keeps the same index
        // and must not create a second unit.
        return MissionRecoveryPlan(
            action: .retryUnitFinalization(
                unitIndex: currentIndex,
                reason: checkpoint.lastError ?? "unit_not_finalized"),
            findings: findings,
            requiresOperatorConfirmation: true,
            idempotencyKey: idempotencyKey)

    case .preparingNextUnit:
        let next = nextMissionUnitIndex(
            checkpoint: checkpoint, observations: observations)
        return MissionRecoveryPlan(
            action: .retryNextUnitPreparation(
                unitIndex: next,
                reason: checkpoint.lastError ?? "next_unit_not_started"),
            findings: findings,
            requiresOperatorConfirmation: true,
            idempotencyKey: idempotencyKey)

    case .gate, .anchoring:
        guard let trigger = checkpoint.decodedPendingTrigger else {
            findings.append(MissionFinding(
                severity: .fatal,
                code: "recovery_trigger_missing",
                message: "The maintenance gate has no valid durable trigger."))
            return MissionRecoveryPlan(
                action: .operatorReview(reason: "maintenance_trigger_missing"),
                findings: findings,
                requiresOperatorConfirmation: true,
                idempotencyKey: idempotencyKey)
        }
        return MissionRecoveryPlan(
            action: .enterMaintenanceGate(
                unitIndex: currentIndex,
                trigger: trigger,
                reason: "resume_maintenance_gate"),
            findings: findings,
            requiresOperatorConfirmation: true,
            idempotencyKey: idempotencyKey)

    case .finalizingMission:
        return MissionRecoveryPlan(
            action: .operatorReview(reason: "mission_finalization_interrupted"),
            findings: findings,
            requiresOperatorConfirmation: true,
            idempotencyKey: idempotencyKey)

    case .idle:
        return MissionRecoveryPlan(
            action: .operatorReview(reason: "idle_mission_checkpoint"),
            findings: findings,
            requiresOperatorConfirmation: true,
            idempotencyKey: idempotencyKey)

    case .scanning, .warning:
        // §5.2: a restart never grants a fresh 30 minutes. If the restored
        // elapsed time is already due, the app goes straight to the gate.
        let elapsed = checkpoint.activeCaptureElapsedS
        if elapsed >= input.policy.calibrationIntervalS + input.policy.gracePeriodS {
            return MissionRecoveryPlan(
                action: .enterMaintenanceGate(
                    unitIndex: currentIndex,
                    trigger: .timeLimit,
                    reason: "restored_elapsed_already_due"),
                findings: findings,
                requiresOperatorConfirmation: true,
                idempotencyKey: idempotencyKey)
        }
        guard let current = checkpoint.currentUnit, currentIndex > 0 else {
            findings.append(MissionFinding(
                severity: .fatal,
                code: "recovery_current_unit_missing",
                message: "A scanning checkpoint has no current unit."))
            return MissionRecoveryPlan(
                action: .operatorReview(reason: "current_unit_missing"),
                findings: findings,
                requiresOperatorConfirmation: true,
                idempotencyKey: idempotencyKey)
        }
        if current.finalized {
            findings.append(MissionFinding(
                severity: .fatal,
                code: "recovery_current_unit_finalized",
                message: "The checkpoint marks a finalized unit as the current unit."))
            return MissionRecoveryPlan(
                action: .operatorReview(reason: "current_unit_already_finalized"),
                findings: findings,
                requiresOperatorConfirmation: true,
                idempotencyKey: idempotencyKey)
        }
        guard let observation = observations.first(where: {
            $0.relativePath == current.relativePath
        }) else {
            findings.append(MissionFinding(
                severity: .fatal,
                code: "recovery_current_unit_unobserved",
                message: "The current unit directory is not present on disk."))
            return MissionRecoveryPlan(
                action: .operatorReview(reason: "current_unit_unobserved"),
                findings: findings,
                requiresOperatorConfirmation: true,
                idempotencyKey: idempotencyKey)
        }
        if observation.metadataFinalized == true,
           observation.liveCheckpointPresent {
            // §10: the unit sealed itself but the live checkpoint survived.
            // Finish the identity-checked CAS cleanup before continuing.
            return MissionRecoveryPlan(
                action: .retryCheckpointCleanup(
                    unitIndex: currentIndex,
                    reason: "live_checkpoint_present_after_finalize"),
                findings: findings,
                requiresOperatorConfirmation: true,
                idempotencyKey: idempotencyKey)
        }
        guard observation.databasePresent,
              observation.liveCheckpointPresent,
              (!observation.metadataPresent || observation.metadataFinalized == false) else {
            findings.append(MissionFinding(
                severity: .fatal,
                code: "recovery_capture_evidence_incomplete",
                message: "The current database/checkpoint state cannot prove a live capture."))
            return MissionRecoveryPlan(
                action: .operatorReview(reason: "capture_evidence_incomplete"),
                findings: findings,
                requiresOperatorConfirmation: true,
                idempotencyKey: idempotencyKey)
        }
        return MissionRecoveryPlan(
            action: .resumeScanning(unitIndex: currentIndex),
            findings: findings,
            requiresOperatorConfirmation: false,
            idempotencyKey: idempotencyKey)
    }
}

private func missionRecoveryIdempotencyKey(
    input: MissionRecoveryInput,
    observations: [MissionRecoveryObservation]
) -> String {
    let checkpointPart = input.checkpoint.map { checkpoint in
        [
            checkpoint.missionId,
            checkpoint.maintenanceState,
            String(checkpoint.currentUnit?.unitIndex ?? 0),
            String(checkpoint.finalizedUnits.count),
            checkpoint.pendingBoundaryId ?? "-",
            String(checkpoint.activeCaptureElapsedS)
        ].joined(separator: ":")
    } ?? "no-checkpoint"
    let observationPart = observations.map { observation in
        [
            observation.relativePath,
            observation.metadataPresent ? "m1" : "m0",
            observation.metadataFinalized.map { $0 ? "f1" : "f0" } ?? "f?",
            observation.databasePresent ? "d1" : "d0",
            observation.liveCheckpointPresent ? "c1" : "c0"
        ].joined(separator: ",")
    }.joined(separator: "|")
    return "\(checkpointPart)#\(observationPart)"
}

/// `.../SupermarketSession-<stamp>-U0003` -> 3. Unknown shapes return nil
/// rather than guessing a number for the executor to reuse.
func unitIndex(from relativePath: String) -> Int? {
    let base = (relativePath as NSString).lastPathComponent
    guard let range = base.range(of: "-U", options: .backwards) else { return nil }
    let suffix = base[range.upperBound...]
    guard suffix.count == 4, let value = Int(suffix), value > 0 else { return nil }
    return value
}

// MARK: - Unit naming

enum MissionLayout {
    static let missionDirectoryPrefix = "SupermarketMission-"
    static let unitDirectoryPrefix = "SupermarketSession-"
    static let unitsDirectoryName = "units"
    static let boundariesDirectoryName = "boundaries"
    static let liveCheckpointName = "mission_live_checkpoint.json"
    static let manifestName = "mission_manifest.json"
    static let eventLogName = "mission_events.jsonl"

    static func missionDirectoryName(stamp: String) -> String {
        "\(missionDirectoryPrefix)\(stamp)"
    }

    /// `U%04d` keeps lexicographic order equal to numeric order, which makes a
    /// directory listing a valid ordering witness for the PC validator.
    static func unitDirectoryName(stamp: String, unitIndex: Int) -> String {
        "\(unitDirectoryPrefix)\(stamp)-U\(String(format: "%04d", unitIndex))"
    }

    static func boundaryFileName(unitIndex: Int) -> String {
        "boundary_\(String(format: "%04d", unitIndex)).json"
    }
}
