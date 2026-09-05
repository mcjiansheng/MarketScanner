//
//  main.swift
//  macOS host tests for the periodic maintenance core and mission store.
//
//  These tests compile the Foundation-only production sources directly
//  (PeriodicScanMaintenanceCore.swift / PeriodicScanMaintenanceStore.swift)
//  and drive them with injected monotonic clocks, byte counts, safety signals
//  and file-system faults. They deliberately avoid UIKit, XCTest and timers so
//  every case is deterministic on a build machine.
//
//  Run: tools/Qualification/swift-host-tests/run_periodic_maintenance_host_tests.sh
//

import Foundation

// MARK: - Tiny harness

final class Harness {
    private(set) var passed = 0
    private(set) var failures: [String] = []

    func expect(_ condition: Bool, _ message: String, file: String = #file, line: Int = #line) {
        if condition {
            passed += 1
        } else {
            failures.append("\(message) (line \(line))")
        }
    }

    func expectEqual<T: Equatable>(_ lhs: T, _ rhs: T, _ message: String, line: Int = #line) {
        if lhs == rhs {
            passed += 1
        } else {
            failures.append("\(message): expected \(rhs), got \(lhs) (line \(line))")
        }
    }

    func section(_ name: String) {
        print("— \(name)")
    }

    func report() -> Int32 {
        if failures.isEmpty {
            print("\nPASS: \(passed) assertions")
            return 0
        }
        print("\nFAIL: \(failures.count) of \(passed + failures.count) assertions")
        for failure in failures { print("  • \(failure)") }
        return 1
    }
}

let harness = Harness()

// MARK: - Fixtures

/// `Result<Void, Error>` is not `Equatable`, so transitions are compared
/// through these helpers instead of `==`.
func transitionSucceeded(_ result: Result<Void, PeriodicMaintenanceTransitionError>) -> Bool {
    if case .success = result { return true }
    return false
}

func transitionError(
    _ result: Result<Void, PeriodicMaintenanceTransitionError>
) -> PeriodicMaintenanceTransitionError? {
    if case .failure(let error) = result { return error }
    return nil
}

func makePolicy(
    interval: TimeInterval = 1800,
    softMax: UInt64? = nil,
    headroom: UInt64 = 100,
    enabled: Bool = true
) -> PeriodicMaintenancePolicy {
    var policy = PeriodicMaintenancePolicy()
    policy.calibrationIntervalS = interval
    policy.softMaxUnitBytes = softMax
    policy.finalizationHeadroomBytes = headroom
    policy.featureEnabled = enabled
    return policy
}

func makeEngine(policy: PeriodicMaintenancePolicy = makePolicy()) -> PeriodicMaintenanceEngine {
    var engine = PeriodicMaintenanceEngine(policy: policy)
    _ = engine.startUnit(index: 1, at: 0)
    return engine
}

func makeIdentity() -> MissionIdentity {
    MissionIdentity(
        missionId: "mission-0001",
        priorMapId: "map-01",
        priorMapPackageSha256: String(repeating: "a", count: 64),
        storeId: "store-01",
        floorId: "F1",
        buildIdentity: "build-20260905")
}

func makeUnit(
    index: Int,
    unitId: String = "unit-0001",
    previous: MissionUnitDescriptor? = nil,
    finalized: Bool = true
) -> MissionUnitDescriptor {
    var unit = MissionUnitDescriptor(
        unitId: unitId,
        unitIndex: index,
        relativePath: "units/SupermarketSession-20260904-100000-U\(String(format: "%04d", index))",
        trackingSessionId: "tracking-\(unitId)",
        databaseRelativePath: "units/SupermarketSession-20260904-100000-U\(String(format: "%04d", index))/segment_0001/rtabmap_segment_0001.db",
        metadataRelativePath: "units/SupermarketSession-20260904-100000-U\(String(format: "%04d", index))/segment_0001/metadata.json",
        finalized: finalized)
    unit.previousUnitId = previous?.unitId
    unit.previousUnitMetadataSha256 = previous?.metadataSha256
    unit.metadataSha256 = String(repeating: String(index % 10), count: 64)
    unit.databaseSha256 = String(repeating: String((index + 4) % 10), count: 64)
    unit.rolloverTrigger = .timeLimit
    unit.activeCaptureDurationS = 1800
    unit.unitStorageBytes = 1024
    unit.finalizedAtUnix = finalized ? 1_800_000_000 + Double(index) : nil
    return unit
}

func makeBoundaryEnd(
    unitId: String,
    index: Int,
    pose: (Double, Double, Double),
    outgoing: Bool
) -> MissionBoundaryEnd {
    MissionBoundaryEnd(
        unitId: unitId,
        unitIndex: index,
        trackingSessionId: "tracking-\(unitId)",
        nodeId: 100 + index,
        nodeStamp: 1000 + Double(index),
        nodeTimeSnapshotGeneration: 7,
        confirmedX: pose.0,
        confirmedY: pose.1,
        confirmedYaw: pose.2,
        manualEventSha256: outgoing ? String(repeating: "b", count: 64) : nil,
        startReceiptSha256: outgoing ? nil : String(repeating: "c", count: 64))
}

func makeBoundary(
    from: MissionUnitDescriptor,
    to: MissionUnitDescriptor,
    outgoing: Bool = true,
    incoming: Bool = true,
    pose: (Double, Double, Double) = (10, 20, 0.5),
    endPose: (Double, Double, Double)? = nil
) -> MissionBoundaryRecord {
    let end = endPose ?? pose
    var record = MissionBoundaryRecord(
        missionId: "mission-0001",
        boundaryId: "boundary-\(from.unitIndex)",
        identity: makeIdentity(),
        fromUnitId: from.unitId,
        toUnitId: to.unitId,
        confirmedX: pose.0,
        confirmedY: pose.1,
        confirmedYaw: pose.2)
    record.outgoing = outgoing ? makeBoundaryEnd(
        unitId: from.unitId, index: from.unitIndex, pose: end, outgoing: true) : nil
    record.incoming = incoming ? makeBoundaryEnd(
        unitId: to.unitId, index: to.unitIndex, pose: end, outgoing: false) : nil
    record.createdAtUnix = 1
    record.committedAtUnix = 2
    record.fileSha256 = String(repeating: "d", count: 64)
    return record
}

// MARK: 1. Time boundary (§5.1, §14.1)

do {
    harness.section("time boundary 1799 / 1800 / 1801")

    var engine = makeEngine()
    var invalidStart = PeriodicMaintenanceEngine(policy: makePolicy())
    harness.expectEqual(
        transitionError(invalidStart.startUnit(index: 2, at: 0)),
        .invalidUnitIndex(expected: 1, actual: 2),
        "the first unit cannot skip index 1")
    var tick = engine.tick(monotonic: 1799, unitBytes: nil)
    harness.expect(!tick.enteredGate, "1799 s must not close the gate")
    harness.expectEqual(engine.state, PeriodicMaintenanceState.warning, "state is warning inside the last 5 minutes")
    harness.expect(engine.admission.ordinaryNodeWrites, "warning still records ordinary capture")

    tick = engine.tick(monotonic: 1800, unitBytes: nil)
    harness.expect(tick.enteredGate, "1800 s closes the gate")
    harness.expectEqual(tick.trigger, MaintenanceTrigger.timeLimit, "trigger is time_limit")
    harness.expectEqual(engine.state, PeriodicMaintenanceState.gate, "state is gate at 1800 s")

    var lateEngine = makeEngine()
    _ = lateEngine.tick(monotonic: 1801, unitBytes: nil)
    harness.expectEqual(lateEngine.state, PeriodicMaintenanceState.gate, "1801 s closes the gate")

    // A delayed timer must not grant extra capture time.
    var delayedEngine = makeEngine()
    _ = delayedEngine.tick(monotonic: 1700, unitBytes: nil)
    let delayed = delayedEngine.tick(monotonic: 1850, unitBytes: nil)
    harness.expect(delayed.enteredGate, "a delayed tick still closes the gate at the due instant")
}

// MARK: 2. Reminder ladder fires once each

do {
    harness.section("reminder ladder 5 min / 1 min / 30 s")

    var engine = makeEngine()
    let first = engine.tick(monotonic: 1500, unitBytes: nil)   // 300 s remaining
    harness.expectEqual(first.remindersFired, [MaintenanceReminder.first], "first reminder at 300 s remaining")

    let duplicate = engine.tick(monotonic: 1501, unitBytes: nil)
    harness.expect(duplicate.remindersFired.isEmpty, "the first reminder must not fire twice")

    let second = engine.tick(monotonic: 1740, unitBytes: nil)  // 60 s remaining
    harness.expectEqual(second.remindersFired, [MaintenanceReminder.second], "second reminder at 60 s remaining")

    let final = engine.tick(monotonic: 1770, unitBytes: nil)   // 30 s remaining
    harness.expectEqual(final.remindersFired, [MaintenanceReminder.final], "final reminder at 30 s remaining")

    let overdue = engine.tick(monotonic: 1799, unitBytes: nil)
    harness.expect(overdue.remindersFired.isEmpty, "no reminder is emitted again before the gate")
}

// MARK: 3. Monotonic clock anomalies and pauses

do {
    harness.section("monotonic accumulation")

    var engine = makeEngine()
    _ = engine.pauseEffectiveCapture(at: 600)      // backgrounded
    engine.resumeEffectiveCapture(at: 10_000)      // foregrounded 9400 s later
    harness.expectEqual(engine.activeElapsed(at: 10_100), 700, "background time must not count")

    var backwards = PeriodicMaintenanceEngine(policy: makePolicy())
    _ = backwards.startUnit(index: 1, at: 100)
    let accepted = backwards.pauseEffectiveCapture(at: 50)
    harness.expect(!accepted, "a backwards uptime sample is rejected")
    harness.expectEqual(backwards.clock.anomalyCount, 1, "the anomaly is recorded")
    harness.expectEqual(backwards.activeElapsed(at: 50), 0, "elapsed time never goes backwards")
    harness.expect(backwards.activeElapsed(at: 50) >= 0, "elapsed time is never negative")
    harness.expect(!backwards.clock.isRunning, "an anomalous sample stops accumulation")

    var restarted = makeEngine()
    restarted.clock.restore(accumulatedS: 1200)
    harness.expectEqual(restarted.activeElapsed(at: 0), 1200, "a restart restores the accumulated value")
    restarted.resumeEffectiveCapture(at: 600)
    let restartTick = restarted.tick(monotonic: 1200, unitBytes: nil)
    harness.expect(restartTick.enteredGate, "a restored elapsed value that is already due closes the gate")
    harness.expectEqual(restarted.activeElapsed(at: 1200), 1800, "only 600 new seconds were added to the restored 1200")

    var negative = makeEngine()
    negative.clock.restore(accumulatedS: -50)
    harness.expectEqual(negative.clock.accumulatedS, 0, "a corrupt negative value is clamped to zero")
}

// MARK: 4. Admission gating

do {
    harness.section("capture admission")

    let engine = makeEngine()
    harness.expect(engine.admission.ordinaryNodeWrites, "ordinary capture writes are open while scanning")
    harness.expect(engine.admission.priceTagConfirmation, "price-tag confirmations are open while scanning")

    var gated = makeEngine()
    _ = gated.tick(monotonic: 1800, unitBytes: nil)
    harness.expect(!gated.admission.ordinaryNodeWrites, "ordinary nodes are refused in the gate")
    harness.expect(!gated.admission.priceTagConfirmation, "price-tag confirmations are refused in the gate")
    harness.expect(!gated.admission.localizationCorrection, "localization corrections are refused in the gate")
    harness.expect(gated.admission.oneShotAnchorNode, "the one-shot anchor node stays available in the gate")

    var anchoring = gated
    _ = anchoring.beginAnchoring(at: 1800)
    harness.expect(anchoring.admission.oneShotAnchorNode, "the one-shot anchor stays available while anchoring")

    var finalizing = anchoring
    _ = finalizing.completeAnchoring(boundaryID: "boundary-1", at: 1810)
    harness.expectEqual(finalizing.state, PeriodicMaintenanceState.finalizingUnit, "anchoring leads to finalizing")
    harness.expect(!finalizing.admission.oneShotAnchorNode, "no writes at all during finalization")
}

// MARK: 5. Transition strictness

do {
    harness.section("state machine edges")

    var engine = makeEngine()
    harness.expectEqual(
        transitionError(engine.requestTransition(to: .finalizingUnit)),
        .denied(from: .scanning, to: .finalizingUnit),
        "scanning cannot jump straight to finalizingUnit")

    _ = engine.tick(monotonic: 1800, unitBytes: nil)
    harness.expect(transitionSucceeded(engine.beginAnchoring(at: 1800)), "gate -> anchoring is allowed")
    harness.expectEqual(
        transitionError(engine.completeAnchoring(boundaryID: "", at: 1800)),
        .denied(from: .anchoring, to: .finalizingUnit),
        "an empty boundary id cannot open finalization")

    var retry = engine
    retry.failAnchoring(code: "node_timeout", message: "no stable node", at: 1810)
    harness.expectEqual(retry.state, PeriodicMaintenanceState.gate, "a failed anchor returns to the gate")
    harness.expectEqual(retry.lastFailure?.code, "node_timeout", "the failure is recorded")

    var sealed = makeEngine()
    _ = sealed.tick(monotonic: 1800, unitBytes: nil)
    _ = sealed.beginAnchoring(at: 1800)
    _ = sealed.completeAnchoring(boundaryID: "boundary-1", at: 1805)
    harness.expect(
        transitionSucceeded(sealed.completeUnitFinalization(at: 1810)),
        "finalizingUnit -> preparingNextUnit is allowed after a time-limit rollover")
    harness.expectEqual(
        transitionError(sealed.completeNextUnitPreparation(unitIndex: 3, at: 1820)),
        .invalidUnitIndex(expected: 2, actual: 3),
        "preparing the wrong next index is rejected")
    harness.expect(
        transitionSucceeded(sealed.completeNextUnitPreparation(unitIndex: 2, at: 1820)),
        "preparing the correct next index resumes scanning")
    harness.expectEqual(sealed.unitIndex, 2, "the unit index advanced to 2")
    harness.expectEqual(sealed.activeElapsed(at: 1820), 0, "effective capture time restarts from zero")

    // An operator stop must never open a new unit.
    var stopping = makeEngine()
    _ = stopping.beginMissionFinalization(at: 400)
    harness.expectEqual(stopping.state, PeriodicMaintenanceState.finalizingMission, "operator stop enters finalizingMission")
    harness.expectEqual(
        transitionError(stopping.requestTransition(to: .preparingNextUnit)),
        .denied(from: .finalizingMission, to: .preparingNextUnit),
        "finalizingMission cannot start a new unit")
}

// MARK: 6. Sticky failures block everything

do {
    harness.section("sticky failures")

    var engine = makeEngine()
    _ = engine.tick(monotonic: 1800, unitBytes: nil)
    _ = engine.beginAnchoring(at: 1800)
    _ = engine.completeAnchoring(boundaryID: "boundary-1", at: 1805)
    engine.failUnitFinalization(code: "metadata_finalized_false", message: "unit is dead", sticky: true, at: 1810)
    harness.expectEqual(engine.state, PeriodicMaintenanceState.terminalRecovery, "a sticky save failure is terminal")
    harness.expect(engine.blocksNextUnit, "a sticky failure blocks the next unit")
    harness.expectEqual(
        transitionError(engine.requestTransition(to: .scanning)),
        .denied(from: .terminalRecovery, to: .scanning),
        "terminal recovery cannot resume scanning")

    var recoverable = makeEngine()
    _ = recoverable.tick(monotonic: 1800, unitBytes: nil)
    _ = recoverable.beginAnchoring(at: 1800)
    _ = recoverable.completeAnchoring(boundaryID: "boundary-1", at: 1805)
    recoverable.failUnitFinalization(code: "db_save_failed", message: "retry", sticky: false, at: 1810)
    harness.expectEqual(recoverable.state, PeriodicMaintenanceState.gate, "a recoverable save failure returns to the gate")
    harness.expect(!recoverable.blocksNextUnit, "a recoverable failure does not block the next unit")
    harness.expect(
        transitionSucceeded(recoverable.retryUnitFinalization(at: 1811)),
        "a recoverable finalization failure can retry the same transaction")
    harness.expectEqual(
        recoverable.state, PeriodicMaintenanceState.finalizingUnit,
        "the finalization retry does not reopen capture")

    var preparationFailure = makeEngine()
    _ = preparationFailure.tick(monotonic: 1800, unitBytes: nil)
    _ = preparationFailure.beginAnchoring(at: 1800)
    _ = preparationFailure.completeAnchoring(boundaryID: "boundary-1", at: 1805)
    _ = preparationFailure.completeUnitFinalization(at: 1810)
    preparationFailure.failNextUnitPreparation(
        code: "receipt_failed", message: "retry", sticky: false, at: 1811)
    harness.expectEqual(
        preparationFailure.state, PeriodicMaintenanceState.gate,
        "a recoverable next-unit failure returns to the closed gate")
    harness.expect(
        transitionSucceeded(preparationFailure.retryNextUnitPreparation(at: 1812)),
        "next-unit preparation can retry without incrementing the index")
}

// MARK: 7. Safety priority (§5.3)

do {
    harness.section("safety priority")

    var engine = makeEngine()
    let tick = engine.tick(
        monotonic: 100,
        unitBytes: nil,
        safety: MaintenanceSafetySignal(evidenceOrDatabaseWriteFailure: true))
    harness.expect(tick.enteredTerminalRecovery, "an evidence failure is terminal")
    harness.expectEqual(engine.state, PeriodicMaintenanceState.terminalRecovery, "state is terminalRecovery")
    harness.expectEqual(engine.pendingTrigger, MaintenanceTrigger.safetyStop, "trigger is safety_stop")
    harness.expect(!(engine.pendingTrigger?.startsNextUnit ?? true), "a safety stop never starts the next unit")

    var lowDisk = makeEngine()
    _ = lowDisk.tick(
        monotonic: 100,
        unitBytes: nil,
        safety: MaintenanceSafetySignal(availableDiskBytes: 500 * 1024 * 1024))
    harness.expectEqual(lowDisk.state, PeriodicMaintenanceState.terminalRecovery, "below 1 GiB is terminal")

    var warmDisk = makeEngine()
    let warm = warmDisk.tick(
        monotonic: 100,
        unitBytes: nil,
        safety: MaintenanceSafetySignal(availableDiskBytes: 4 * 1024 * 1024 * 1024))
    harness.expect(!warm.enteredTerminalRecovery, "8 GiB is only a warning, not a stop")
    harness.expectEqual(warmDisk.state, PeriodicMaintenanceState.scanning, "capture continues on a disk warning")

    var thermal = makeEngine()
    _ = thermal.tick(monotonic: 100, unitBytes: nil, safety: MaintenanceSafetySignal(thermalCritical: true))
    harness.expectEqual(thermal.state, PeriodicMaintenanceState.terminalRecovery, "thermal critical is terminal")

    // Safety outranks both the size and the time gate.
    var overdue = makeEngine()
    let tick2 = overdue.tick(
        monotonic: 5000,
        unitBytes: 10_000,
        safety: MaintenanceSafetySignal(thermalCritical: true))
    harness.expectEqual(tick2.trigger, MaintenanceTrigger.safetyStop, "safety wins over time_limit")
}

// MARK: 8. Size gate (§5.3)

do {
    harness.section("size gate")

    var limited = PeriodicMaintenanceEngine(policy: makePolicy(softMax: 1_000, headroom: 100))
    _ = limited.startUnit(index: 1, at: 0)
    limited.growth.record(monotonic: 0, bytes: 100)
    limited.growth.record(monotonic: 10, bytes: 200)
    limited.growth.record(monotonic: 20, bytes: 300)
    let rate = limited.growth.bytesPerSecond(minimumSamples: 3)
    harness.expect(rate != nil && abs((rate ?? 0) - 10) < 0.001, "the growth rate is estimated from three samples")
    harness.expectEqual(limited.growth.projectedBytes(minimumSamples: 3, horizonS: 60), 900, "60 s projection")

    let tick = limited.tick(monotonic: 30, unitBytes: 400)
    harness.expect(tick.enteredGate, "the projected size closes the gate before the soft limit")
    harness.expectEqual(tick.trigger, MaintenanceTrigger.sizeLimit, "trigger is size_limit")

    // Without a frozen device baseline the byte gate must stay inactive.
    var unfrozen = PeriodicMaintenanceEngine(policy: makePolicy(softMax: nil))
    _ = unfrozen.startUnit(index: 1, at: 0)
    for step in 0..<6 {
        _ = unfrozen.tick(monotonic: Double(step) * 5, unitBytes: UInt64(step) * 1_000_000)
    }
    harness.expectEqual(unfrozen.state, PeriodicMaintenanceState.scanning, "no byte gate exists before the baseline is frozen")

    var tooFew = PeriodicMaintenanceEngine(policy: makePolicy(softMax: 1_000, headroom: 100))
    _ = tooFew.startUnit(index: 1, at: 0)
    tooFew.growth.record(monotonic: 0, bytes: 900)
    harness.expectEqual(tooFew.growth.projectedBytes(minimumSamples: 3, horizonS: 60), nil, "one sample cannot project a rate")

    var saturated = StorageGrowthEstimator()
    saturated.record(monotonic: 0, bytes: 0)
    saturated.record(monotonic: 1, bytes: UInt64.max)
    harness.expectEqual(
        saturated.projectedBytes(minimumSamples: 2, horizonS: 10),
        UInt64.max,
        "an extreme projection saturates instead of trapping")
}

// MARK: 9. Path safety (§9.2)

do {
    harness.section("path safety")

    harness.expect((try? validatedMissionRelativePath("units/SupermarketSession-1-U0001")) != nil, "a relative unit path is accepted")
    for invalid in ["", "/units", "~/units", "../units", "units/../../etc", "units\\x", "units//x"] {
        do {
            _ = try validatedMissionRelativePath(invalid)
            harness.expect(false, "path \(invalid) must be rejected")
        } catch {
            harness.expect(error is MissionPathError, "path \(invalid) is rejected with a typed error")
        }
    }
    harness.expectEqual(unitIndex(from: "units/SupermarketSession-20260904-U0004"), 4, "unit index parsing")
    harness.expectEqual(unitIndex(from: "units/SupermarketSession-1"), nil, "unknown shapes do not guess an index")
}

// MARK: 10. Boundary completeness (§7.3)

do {
    harness.section("boundary completeness")

    let unit1 = makeUnit(index: 1, unitId: "unit-0001")
    let unit2 = makeUnit(index: 2, unitId: "unit-0002", previous: unit1)

    harness.expect(makeBoundary(from: unit1, to: unit2).isComplete, "a two-sided boundary is complete")
    harness.expect(!makeBoundary(from: unit1, to: unit2, incoming: false).isComplete, "a missing incoming end is incomplete")
    harness.expect(!makeBoundary(from: unit1, to: unit2, outgoing: false).isComplete, "a missing outgoing end is incomplete")
    harness.expect(
        !makeBoundary(from: unit1, to: unit2, endPose: (11, 20, 0.5)).isComplete,
        "an end pose that disagrees with the confirmed pose is incomplete")
    harness.expect(
        !makeBoundary(from: unit1, to: unit2, endPose: (10, 20, 1.5)).isComplete,
        "an end yaw that disagrees with the confirmed yaw is incomplete")
}

// MARK: 11. Structural validation (§11.1 mirror)

do {
    harness.section("structural validation")

    let identity = makeIdentity()
    let unit1 = makeUnit(index: 1, unitId: "unit-0001")
    let unit2 = makeUnit(index: 2, unitId: "unit-0002", previous: unit1)
    let unit3 = makeUnit(index: 3, unitId: "unit-0003", previous: unit2)

    let valid = validateMissionStructure(
        units: [unit1, unit2, unit3],
        boundaries: [makeBoundary(from: unit1, to: unit2), makeBoundary(from: unit2, to: unit3)],
        identity: identity)
    harness.expect(valid.isEmpty, "a complete three-unit mission validates: \(valid.map(\.code))")

    let missingBoundary = validateMissionStructure(
        units: [unit1, unit2], boundaries: [], identity: identity)
    harness.expect(
        missingBoundary.contains { $0.code == "mission_boundary_missing" },
        "a missing boundary is fatal")

    var brokenChain = unit3
    brokenChain.previousUnitMetadataSha256 = "0"
    let broken = validateMissionStructure(
        units: [unit1, unit2, brokenChain],
        boundaries: [makeBoundary(from: unit1, to: unit2), makeBoundary(from: unit2, to: unit3)],
        identity: identity)
    harness.expect(broken.contains { $0.code == "mission_hash_chain_broken" }, "a broken hash chain is fatal")

    let gap = validateMissionStructure(units: [unit1, unit3], boundaries: [], identity: identity)
    harness.expect(
        gap.contains { $0.code == "mission_unit_index_discontinuous" },
        "a unit index gap is fatal")

    let duplicate = validateMissionStructure(units: [unit1, unit1], boundaries: [], identity: identity)
    harness.expect(
        duplicate.contains { $0.code == "mission_duplicate_unit_id" },
        "a duplicate unit id is fatal")

    let unfinalized = validateMissionStructure(
        units: [unit1, makeUnit(index: 2, unitId: "unit-0002", previous: unit1, finalized: false)],
        boundaries: [makeBoundary(from: unit1, to: unit2)],
        identity: identity)
    harness.expect(
        unfinalized.contains { $0.code == "mission_unit_not_finalized" },
        "an unfinalized unit is fatal")

    let oneSided = validateMissionStructure(
        units: [unit1, unit2],
        boundaries: [makeBoundary(from: unit1, to: unit2, incoming: false)],
        identity: identity)
    harness.expect(
        oneSided.contains { $0.code == "mission_boundary_incomplete" },
        "a one-sided boundary is fatal")
}

// MARK: 12. Recovery planning (§10)

do {
    harness.section("recovery planning")

    let policy = makePolicy()
    let unit1 = makeUnit(index: 1, unitId: "unit-0001", finalized: false)

    func checkpoint(state: PeriodicMaintenanceState, elapsed: TimeInterval = 0) -> MissionLiveCheckpoint {
        var checkpoint = MissionLiveCheckpoint(
            missionId: "mission-0001", policyVersion: 1, identity: makeIdentity())
        if state == .preparingNextUnit {
            let finalized = makeUnit(index: 1, unitId: "unit-0001")
            checkpoint.finalizedUnits = [finalized]
            checkpoint.currentUnit = makeUnit(
                index: 2, unitId: "unit-0002", previous: finalized, finalized: false)
        } else {
            checkpoint.currentUnit = unit1
        }
        checkpoint.maintenanceState = state.rawValue
        checkpoint.activeCaptureElapsedS = elapsed
        if state == .gate || state == .anchoring || state == .finalizingUnit
            || state == .preparingNextUnit {
            checkpoint.pendingTrigger = MaintenanceTrigger.timeLimit.rawValue
        }
        if state == .finalizingUnit || state == .preparingNextUnit {
            checkpoint.pendingBoundaryId = "boundary-0001"
        }
        return checkpoint
    }

    let scanning = planMissionRecovery(MissionRecoveryInput(
        checkpoint: checkpoint(state: .scanning, elapsed: 600),
        observations: [MissionRecoveryObservation(
            relativePath: unit1.relativePath,
            metadataPresent: false,
            metadataFinalized: nil,
            databasePresent: true,
            liveCheckpointPresent: true)],
        monotonicNow: 0,
        policy: policy))
    harness.expect(scanning.action == .resumeScanning(unitIndex: 1), "an unfinished unit resumes scanning")
    harness.expect(!scanning.requiresOperatorConfirmation, "resuming does not need confirmation")

    let due = planMissionRecovery(MissionRecoveryInput(
        checkpoint: checkpoint(state: .scanning, elapsed: 1800),
        observations: [],
        monotonicNow: 0,
        policy: policy))
    harness.expect(
        due.action == .enterMaintenanceGate(unitIndex: 1, trigger: .timeLimit, reason: "restored_elapsed_already_due"),
        "a restored elapsed value that is already due enters the gate")
    harness.expect(due.requiresOperatorConfirmation, "the gate needs operator confirmation")

    let finalizing = planMissionRecovery(MissionRecoveryInput(
        checkpoint: checkpoint(state: .finalizingUnit),
        observations: [],
        monotonicNow: 0,
        policy: policy))
    harness.expect(
        finalizing.action == .retryUnitFinalization(unitIndex: 1, reason: "unit_not_finalized"),
        "an unsealed unit retries the same finalization")

    let preparing = planMissionRecovery(MissionRecoveryInput(
        checkpoint: checkpoint(state: .preparingNextUnit),
        observations: [],
        monotonicNow: 0,
        policy: policy))
    harness.expect(
        preparing.action == .retryNextUnitPreparation(unitIndex: 2, reason: "next_unit_not_started"),
        "a missing next unit retries the same next index")

    var deadCheckpoint = checkpoint(state: .scanning)
    deadCheckpoint.lastError = "metadata_finalized_false"
    let dead = planMissionRecovery(MissionRecoveryInput(
        checkpoint: deadCheckpoint,
        observations: [MissionRecoveryObservation(
            relativePath: "units/SupermarketSession-20260904-100000-U0001",
            metadataPresent: true,
            metadataFinalized: false,
            databasePresent: true,
            liveCheckpointPresent: false)],
        monotonicNow: 0,
        policy: policy))
    harness.expect(
        dead.action == .terminalRecovery(unitIndex: 1, reason: "unit_metadata_finalized_false"),
        "metadata with finalized=false is terminal")

    // Idempotency: replaying the same input yields the same plan and key.
    let replay = planMissionRecovery(MissionRecoveryInput(
        checkpoint: checkpoint(state: .finalizingUnit),
        observations: [],
        monotonicNow: 0,
        policy: policy))
    harness.expectEqual(replay.idempotencyKey, finalizing.idempotencyKey, "the idempotency key is stable")
    harness.expect(replay.action == finalizing.action, "replaying recovery yields the same action")

    // Orphans are quarantined, never adopted.
    let orphan = planMissionRecovery(MissionRecoveryInput(
        checkpoint: nil,
        observations: [MissionRecoveryObservation(
            relativePath: "units/SupermarketSession-20260904-100000-U0007",
            metadataPresent: true,
            metadataFinalized: true,
            databasePresent: true,
            liveCheckpointPresent: false)],
        monotonicNow: 0,
        policy: policy))
    harness.expect(
        orphan.action == .quarantineOrphan(paths: ["units/SupermarketSession-20260904-100000-U0007"], reason: "missing_mission_checkpoint"),
        "directories without a checkpoint are quarantined")

    // A malformed policy stops the feature instead of guessing.
    var badPolicy = makePolicy()
    badPolicy.calibrationIntervalS = 0
    let bad = planMissionRecovery(MissionRecoveryInput(
        checkpoint: checkpoint(state: .scanning),
        observations: [],
        monotonicNow: 0,
        policy: badPolicy))
    harness.expect(bad.action == .operatorReview(reason: "maintenance_policy_invalid"), "an invalid policy is fail-closed")
    harness.expect(!bad.findings.isEmpty, "policy findings are reported")

    var negativeElapsed = checkpoint(state: .scanning)
    negativeElapsed.activeCaptureElapsedS = -1
    let negative = planMissionRecovery(MissionRecoveryInput(
        checkpoint: negativeElapsed,
        observations: [],
        monotonicNow: 0,
        policy: policy))
    harness.expect(
        negative.action == .operatorReview(reason: "mission_checkpoint_malformed"),
        "negative elapsed time cannot resume capture")

    var unknownState = checkpoint(state: .scanning)
    unknownState.maintenanceState = "unknown_state"
    let unknown = planMissionRecovery(MissionRecoveryInput(
        checkpoint: unknownState,
        observations: [],
        monotonicNow: 0,
        policy: policy))
    harness.expect(
        unknown.action == .operatorReview(reason: "mission_checkpoint_malformed"),
        "an unknown checkpoint state is fail-closed")

    var missingTrigger = checkpoint(state: .gate)
    missingTrigger.pendingTrigger = nil
    let missing = planMissionRecovery(MissionRecoveryInput(
        checkpoint: missingTrigger,
        observations: [],
        monotonicNow: 0,
        policy: policy))
    harness.expect(
        missing.action == .operatorReview(reason: "mission_checkpoint_malformed"),
        "a gate with no durable trigger is fail-closed")

    let ghost = planMissionRecovery(MissionRecoveryInput(
        checkpoint: checkpoint(state: .scanning, elapsed: 10),
        observations: [],
        monotonicNow: 0,
        policy: policy))
    harness.expect(
        ghost.action == .operatorReview(reason: "current_unit_unobserved"),
        "a scanning checkpoint without an observed database cannot resume")

    harness.expectEqual(
        nextMissionUnitIndex(
            checkpoint: checkpoint(state: .preparingNextUnit),
            observations: []),
        2,
        "the next unit index is derived from the checkpoint")
}

// MARK: 13. Store: atomic commits and link rejection

do {
    harness.section("mission store")

    let fileManager = FileManager.default
    let base = fileManager.temporaryDirectory
        .appendingPathComponent("mission-host-tests-\(UUID().uuidString)", isDirectory: true)
    try? fileManager.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: base) }

    let root = base.appendingPathComponent("SupermarketMission-20260904-100000", isDirectory: true)
    let store = MissionStore(root: root)
    try store.createMissionRoot()
    harness.expect(fileManager.fileExists(atPath: root.path), "the mission root is created")
    harness.expect(fileManager.fileExists(atPath: store.unitsRoot.path), "the units directory is created")

    do {
        try store.createMissionRoot()
        harness.expect(false, "an existing mission root must not be adopted")
    } catch let error as MissionStoreError {
        harness.expect(error == .missionRootExists(root.lastPathComponent), "reuse of a mission root is refused")
    }

    let unitURL = try store.createUnitDirectory(stamp: "20260904-100000", unitIndex: 1)
    harness.expect(fileManager.fileExists(atPath: unitURL.path), "the unit directory is created")
    do {
        _ = try store.createUnitDirectory(stamp: "20260904-100000", unitIndex: 1)
        harness.expect(false, "a finalized unit directory must never be recreated")
    } catch let error as MissionStoreError {
        harness.expect(error == .unitDirectoryExists("SupermarketSession-20260904-100000-U0001"), "unit collisions are refused")
    }
    do {
        _ = try store.createUnitDirectory(stamp: "20260904-100000", unitIndex: 0)
        harness.expect(false, "unit index 0 is invalid")
    } catch let error as MissionStoreError {
        harness.expect(error == .invalidUnitIndex(0), "unit index 0 is rejected")
    }

    var checkpoint = MissionLiveCheckpoint(
        missionId: "mission-0001", policyVersion: 1, identity: makeIdentity())
    let unit1 = makeUnit(index: 1, unitId: "unit-0001")
    checkpoint.currentUnit = unit1
    try store.writeLiveCheckpoint(checkpoint)
    let reread = try store.readLiveCheckpoint()
    harness.expectEqual(reread?.missionId, "mission-0001", "the live checkpoint round-trips")
    harness.expectEqual(reread?.currentUnit?.unitIndex, 1, "the current unit round-trips")

    try store.appendEvent(MissionEventRecord(event: "maintenance_gate_entered", atUnix: 1, monotonic: 2))
    let eventData = try Data(contentsOf: store.eventLogURL)
    harness.expect(eventData.last == 0x0A, "the event log is newline terminated")

    do {
        _ = try store.writeManifest(
            missionId: "mission-0001",
            identity: makeIdentity(),
            units: [makeUnit(index: 1, unitId: "unit-0001", finalized: false)],
            boundaries: [],
            completedAtUnix: 10)
        harness.expect(false, "an unfinalized unit cannot produce a manifest")
    } catch is MissionStoreError {
        harness.expect(true, "an unfinalized unit cannot produce a manifest")
    }

    let boundary = makeBoundary(from: unit1, to: makeUnit(index: 2, unitId: "unit-0002", previous: unit1))
    do {
        _ = try store.writeBoundary(
            makeBoundary(
                from: unit1,
                to: makeUnit(index: 2, unitId: "unit-0002", previous: unit1),
                incoming: false),
            unitIndex: 1)
        harness.expect(false, "an incomplete boundary must not be committed")
    } catch is MissionStoreError {
        harness.expect(true, "an incomplete boundary is refused before the immutable write")
    }
    let committed = try store.writeBoundary(boundary, unitIndex: 1)
    harness.expect(committed.fileSha256 != nil, "the committed boundary carries its file digest")
    do {
        _ = try store.writeBoundary(boundary, unitIndex: 1)
        harness.expect(false, "a committed boundary must not be rewritten")
    } catch is MissionStoreError {
        harness.expect(true, "a committed boundary must not be rewritten")
    }
    let boundaries = try store.readBoundaries()
    harness.expectEqual(boundaries.count, 1, "the boundary round-trips")

    let duplicateBoundaryURL = store.boundariesRoot.appendingPathComponent("boundary_0002.json")
    try fileManager.copyItem(
        at: store.boundariesRoot.appendingPathComponent("boundary_0001.json"),
        to: duplicateBoundaryURL)
    do {
        _ = try store.readBoundaries()
        harness.expect(false, "a boundary file under the wrong index must not be accepted")
    } catch is MissionStoreError {
        harness.expect(true, "a boundary file under the wrong index is rejected without trapping")
    }
    try fileManager.removeItem(at: duplicateBoundaryURL)

    let phantomRoot = base.appendingPathComponent("SupermarketMission-phantom", isDirectory: true)
    let phantomStore = MissionStore(root: phantomRoot)
    try phantomStore.createMissionRoot()
    do {
        _ = try phantomStore.writeManifest(
            missionId: "mission-0001",
            identity: makeIdentity(),
            units: [makeUnit(index: 1, unitId: "unit-0001")],
            boundaries: [],
            completedAtUnix: 10)
        harness.expect(false, "a descriptor cannot publish files that do not exist")
    } catch is MissionStoreError {
        harness.expect(true, "a phantom finalized unit cannot produce a manifest")
    }
    harness.expect(
        !fileManager.fileExists(atPath: phantomStore.manifestURL.path),
        "a failed phantom-unit check leaves no manifest")

    // Symlinked unit directories are refused instead of being followed.
    let outside = base.appendingPathComponent("outside", isDirectory: true)
    try fileManager.createDirectory(at: outside, withIntermediateDirectories: true)
    let linkedUnit = try store.createUnitDirectory(stamp: "20260904-100000", unitIndex: 2)
    try fileManager.removeItem(at: linkedUnit)
    try fileManager.createSymbolicLink(atPath: linkedUnit.path, withDestinationPath: outside.path)
    do {
        _ = try store.observeUnits()
        harness.expect(false, "a symlinked unit must be refused")
    } catch let error as MissionStoreError {
        harness.expect(error == .linkDetected("SupermarketSession-20260904-100000-U0002"), "the symlink is named")
    }
    try fileManager.removeItem(at: linkedUnit)
}

// MARK: 14. Store fault injection

do {
    harness.section("store fault injection")

    let fileManager = FileManager.default
    let base = fileManager.temporaryDirectory
        .appendingPathComponent("mission-host-faults-\(UUID().uuidString)", isDirectory: true)
    try? fileManager.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: base) }

    let failing = FoundationMissionFileWriter(fault: { stage, _ in
        if stage == .rename {
            throw MissionStoreError.hashUnavailable("injected_rename_failure")
        }
    })
    let root = base.appendingPathComponent("SupermarketMission-fault", isDirectory: true)
    let store = MissionStore(root: root, writer: failing)
    try store.createMissionRoot()
    let checkpoint = MissionLiveCheckpoint(
        missionId: "mission-fault", policyVersion: 1, identity: makeIdentity())
    do {
        try store.writeLiveCheckpoint(checkpoint)
        harness.expect(false, "an injected rename failure must surface")
    } catch {
        harness.expect(true, "an injected rename failure must surface")
    }
    harness.expect(
        !fileManager.fileExists(atPath: store.liveCheckpointURL.path),
        "no partial checkpoint survives a failed rename")

    // A flush failure leaves no file behind either.
    let flushFailure = FoundationMissionFileWriter(fault: { stage, _ in
        if stage == .flush {
            throw MissionStoreError.hashUnavailable("injected_flush_failure")
        }
    })
    let secondRoot = base.appendingPathComponent("SupermarketMission-flush", isDirectory: true)
    let secondStore = MissionStore(root: secondRoot, writer: flushFailure)
    try secondStore.createMissionRoot()
    do {
        try secondStore.writeLiveCheckpoint(checkpoint)
        harness.expect(false, "an injected flush failure must surface")
    } catch {
        harness.expect(true, "an injected flush failure must surface")
    }
    harness.expect(
        !fileManager.fileExists(atPath: secondStore.liveCheckpointURL.path),
        "no partial checkpoint survives a failed flush")
}

// MARK: 15. Policy validation

do {
    harness.section("policy validation")

    harness.expect(makePolicy().isValid, "the default policy is valid")

    var unordered = makePolicy()
    unordered.firstReminderRemainingS = 30
    harness.expect(!unordered.isValid, "an unordered reminder ladder is refused")

    let zeroInterval = makePolicy(interval: 0)
    harness.expect(!zeroInterval.isValid, "a zero interval is refused")

    let badSoftMax = makePolicy(softMax: 50, headroom: 100)
    harness.expect(!badSoftMax.isValid, "a soft limit below the headroom is refused")

    var wrongVersion = makePolicy()
    wrongVersion.policyVersion = 99
    harness.expect(!wrongVersion.isValid, "an unsupported policy version is refused")

    let disabled = makePolicy(enabled: false)
    harness.expect(disabled.isValid, "the feature flag does not invalidate the policy")
    harness.expect(!disabled.featureEnabled, "the feature is disabled by default in phase 1")
}

// MARK: 16. Feature-flag default (§13 phase 1)

do {
    harness.section("feature flag default")
    let policy = PeriodicMaintenancePolicy()
    harness.expect(!policy.featureEnabled, "phase 1 ships with the feature flag off")
    harness.expectEqual(policy.calibrationIntervalS, 1800, "the default interval is 30 minutes")
    harness.expectEqual(policy.gracePeriodS, 0, "there is no grace period")
    harness.expectEqual(policy.softMaxUnitBytes, nil, "no byte ceiling is claimed before the device baseline")
    harness.expectEqual(policy.policyVersion, 1, "policy version 1")
}

// MARK: 17. Feature flag is honoured by the engine (review P1-8)

do {
    harness.section("feature flag honoured")

    var disabled = PeriodicMaintenanceEngine(policy: PeriodicMaintenancePolicy())
    harness.expect(
        transitionError(disabled.startUnit(index: 1, at: 0)) != nil,
        "a disabled feature cannot start a maintenance unit")
    let tick = disabled.tick(monotonic: 100_000, unitBytes: 9_000_000_000)
    harness.expect(!tick.enteredGate, "a disabled feature never closes a gate")
    harness.expectEqual(tick.reason, "feature_disabled", "the tick explains why nothing happened")
    harness.expectEqual(disabled.state, PeriodicMaintenanceState.idle, "state stays idle")

    let disabledPlan = planMissionRecovery(MissionRecoveryInput(
        checkpoint: nil,
        observations: [MissionRecoveryObservation(
            relativePath: "units/SupermarketSession-20260904-100000-U0001",
            metadataPresent: true,
            metadataFinalized: true,
            databasePresent: true,
            liveCheckpointPresent: false)],
        monotonicNow: 0))
    harness.expect(
        disabledPlan.action == .operatorReview(reason: "maintenance_feature_disabled"),
        "recovery planning refuses to act while the feature is disabled")
}

// MARK: 18. Engine state reaches the durable checkpoint (review P1-4)

do {
    harness.section("checkpoint bridge")

    var engine = makeEngine()
    _ = engine.tick(monotonic: 1500, unitBytes: nil)
    var checkpoint = MissionLiveCheckpoint(
        missionId: "mission-0001", policyVersion: 1, identity: makeIdentity())
    engine.apply(to: &checkpoint, at: 1500)
    harness.expectEqual(checkpoint.activeCaptureElapsedS, 1500, "elapsed time is persisted")
    harness.expectEqual(checkpoint.maintenanceState, "warning", "the maintenance state is persisted")
    harness.expectEqual(checkpoint.nextMaintenanceAtActiveS, 1800, "the next due point is persisted")
    harness.expectEqual(checkpoint.decodedPendingTrigger, nil, "no trigger before the gate")

    _ = engine.tick(monotonic: 1800, unitBytes: nil)
    engine.apply(to: &checkpoint, at: 1800)
    harness.expectEqual(checkpoint.maintenanceState, "gate", "the gate state is persisted")
    harness.expectEqual(checkpoint.decodedPendingTrigger, .timeLimit, "the trigger is persisted")
    harness.expectEqual(checkpoint.lastError, nil, "no error is invented for a clean gate")

    _ = engine.beginAnchoring(at: 1801)
    _ = engine.completeAnchoring(boundaryID: "boundary-1", at: 1802)
    engine.failUnitFinalization(code: "db_save_failed", message: "retry", sticky: false, at: 1810)
    engine.apply(to: &checkpoint, at: 1810)
    harness.expectEqual(checkpoint.lastError, "db_save_failed", "the failure code is persisted")
    _ = engine.retryUnitFinalization(at: 1811)
    engine.apply(to: &checkpoint, at: 1811)
    harness.expectEqual(checkpoint.lastError, nil, "a successful retry clears stale checkpoint errors")
}

// MARK: 19. Unit sealing fills the hash chain (review P1-5)

do {
    harness.section("unit sealing")

    let fileManager = FileManager.default
    let base = fileManager.temporaryDirectory
        .appendingPathComponent("mission-seal-\(UUID().uuidString)", isDirectory: true)
    try? fileManager.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: base) }

    let root = base.appendingPathComponent("SupermarketMission-seal", isDirectory: true)
    let store = MissionStore(root: root)
    try store.createMissionRoot()
    let firstDir = try store.createUnitDirectory(stamp: "20260904-100000", unitIndex: 1)
    let secondDir = try store.createUnitDirectory(stamp: "20260904-100000", unitIndex: 2)
    for (index, directory) in [firstDir, secondDir].enumerated() {
        let segment = directory.appendingPathComponent("segment_0001", isDirectory: true)
        try fileManager.createDirectory(at: segment, withIntermediateDirectories: true)
        try Data("database-\(index + 1)".utf8).write(
            to: segment.appendingPathComponent("rtabmap_segment_0001.db"))
        let unitID = "unit-\(String(format: "%04d", index + 1))"
        let metadata = try JSONSerialization.data(withJSONObject: [
            "finalized": true,
            "scanMode": "continuous_streaming",
            "workflowMode": "prior_map_localized",
            "missionId": "mission-0001",
            "unitId": unitID,
            "unitIndex": index + 1,
            "trackingSessionId": "tracking-\(unitID)",
            "priorMapId": "map-01",
            "priorMapSha256": String(repeating: "a", count: 64),
            "storeId": "store-01",
            "floorId": "F1",
            "buildIdentity": "build-20260905"
        ], options: [.sortedKeys])
        try metadata.write(to: segment.appendingPathComponent("metadata.json"))
        try Data("[]".utf8).write(to: segment.appendingPathComponent("price_tags.json"))
        try Data("{}".utf8).write(to: segment.appendingPathComponent("scan_area_cells.json"))
        try Data("{}".utf8).write(
            to: segment.appendingPathComponent("structure_coverage_cells.json"))
        try Data("[]".utf8).write(
            to: segment.appendingPathComponent("trajectory_samples.json"))
        try Data("barcode\n".utf8).write(to: segment.appendingPathComponent("price_tags.csv"))
        try Data("timestamp\n".utf8).write(
            to: segment.appendingPathComponent("trajectory_samples.csv"))
        try Data("{\"event\":\"scan_finalized\"}\n".utf8).write(
            to: segment.appendingPathComponent("scan_events.jsonl"))
    }

    let first = try store.finalizedUnitDescriptor(
        makeUnit(index: 1, unitId: "unit-0001", finalized: false), finalizedAtUnix: 1)
    harness.expect(first.databaseSha256 != nil, "the sealed unit carries a database digest")
    harness.expect(first.metadataSha256 != nil, "the sealed unit carries a metadata digest")
    harness.expect(first.finalized, "sealing marks the unit finalized")
    harness.expect((first.unitStorageBytes ?? 0) > 0, "sealing records the database size")

    let secondMetadataURL = secondDir
        .appendingPathComponent("segment_0001/metadata.json")
    var secondMetadata = (try JSONSerialization.jsonObject(
        with: Data(contentsOf: secondMetadataURL)) as? [String: Any]) ?? [:]
    secondMetadata["previousUnitId"] = first.unitId
    secondMetadata["previousUnitMetadataSha256"] = first.metadataSha256
    try JSONSerialization.data(withJSONObject: secondMetadata, options: [.sortedKeys])
        .write(to: secondMetadataURL)
    var second = makeUnit(index: 2, unitId: "unit-0002", previous: first, finalized: false)
    second = try store.finalizedUnitDescriptor(second, finalizedAtUnix: 2)
    harness.expectEqual(
        second.previousUnitMetadataSha256, first.metadataSha256,
        "the previous metadata digest comes from the sealed predecessor")

    let boundary = makeBoundary(from: first, to: second)
    let findings = validateMissionStructure(
        units: [first, second], boundaries: [boundary], identity: makeIdentity())
    harness.expect(findings.isEmpty, "a sealed two-unit mission validates: \(findings.map(\.code))")

    let committedBoundary = try store.writeBoundary(boundary, unitIndex: 1)
    let requiredSidecar = secondDir
        .appendingPathComponent("segment_0001/price_tags.csv")
    try fileManager.removeItem(at: requiredSidecar)
    do {
        _ = try store.writeManifest(
            missionId: "mission-0001",
            identity: makeIdentity(),
            units: [first, second],
            boundaries: [committedBoundary],
            completedAtUnix: 3)
        harness.expect(false, "a missing required sidecar must block the manifest")
    } catch is MissionStoreError {
        harness.expect(true, "required sidecars are verified before manifest commit")
    }
    try Data("barcode\n".utf8).write(to: requiredSidecar)
    do {
        _ = try store.writeManifest(
            missionId: "foreign-mission",
            identity: makeIdentity(),
            units: [first, second],
            boundaries: [committedBoundary],
            completedAtUnix: 3)
        harness.expect(false, "the manifest mission id must match its identity")
    } catch is MissionStoreError {
        harness.expect(true, "a mismatched top-level mission id is refused")
    }
    let manifest = try store.writeManifest(
        missionId: "mission-0001",
        identity: makeIdentity(),
        units: [first, second],
        boundaries: [committedBoundary],
        completedAtUnix: 3)
    harness.expect(manifest.publishPermitted, "verified files can produce a completion manifest")
    do {
        _ = try store.writeManifest(
            missionId: "mission-0001",
            identity: makeIdentity(),
            units: [first, second],
            boundaries: [committedBoundary],
            completedAtUnix: 4)
        harness.expect(false, "an immutable manifest must not be overwritten")
    } catch is MissionStoreError {
        harness.expect(true, "a second manifest write is refused")
    }

    // A unit declared without digests cannot form a verifiable chain.
    let unsealed = validateMissionStructure(
        units: [makeUnit(index: 1, unitId: "unit-0001", finalized: false),
                makeUnit(index: 2, unitId: "unit-0002", previous: first)],
        boundaries: [boundary],
        identity: makeIdentity())
    harness.expect(!unsealed.isEmpty, "an unsealed unit cannot validate")

    do {
        _ = try store.sha256OfFile(
            at: root.appendingPathComponent("does-not-exist.db"))
        harness.expect(false, "hashing a missing file must fail")
    } catch is MissionStoreError {
        harness.expect(true, "hashing a missing file must fail")
    }
}

// MARK: 20. Orphan directories block auto-continue (review P1-3)

do {
    harness.section("orphan quarantine")

    var checkpoint = MissionLiveCheckpoint(
        missionId: "mission-0001", policyVersion: 1, identity: makeIdentity())
    checkpoint.currentUnit = makeUnit(index: 1, unitId: "unit-0001", finalized: false)
    checkpoint.maintenanceState = PeriodicMaintenanceState.scanning.rawValue
    checkpoint.activeCaptureElapsedS = 10

    let plan = planMissionRecovery(MissionRecoveryInput(
        checkpoint: checkpoint,
        observations: [
            MissionRecoveryObservation(
                relativePath: "units/SupermarketSession-20260904-100000-U0001",
                metadataPresent: false,
                metadataFinalized: nil,
                databasePresent: true,
                liveCheckpointPresent: true),
            MissionRecoveryObservation(
                relativePath: "units/SupermarketSession-20260904-100000-U0009",
                metadataPresent: true,
                metadataFinalized: true,
                databasePresent: true,
                liveCheckpointPresent: false),
        ],
        monotonicNow: 0,
        policy: makePolicy()))
    harness.expect(
        plan.action == .quarantineOrphan(
            paths: ["units/SupermarketSession-20260904-100000-U0009"],
            reason: "directories_not_referenced_by_checkpoint"),
        "an unreferenced unit directory stops the mission instead of being adopted")
    harness.expect(plan.requiresOperatorConfirmation, "quarantine needs operator review")
}

// MARK: 21. Growth samples only come from ordinary capture (review P2-3)

do {
    harness.section("growth sampling scope")

    var engine = makeEngine()
    _ = engine.tick(monotonic: 1800, unitBytes: nil)
    harness.expectEqual(engine.state, PeriodicMaintenanceState.gate, "the gate is closed")
    _ = engine.tick(monotonic: 1810, unitBytes: 1_000_000)
    _ = engine.tick(monotonic: 1820, unitBytes: 2_000_000)
    _ = engine.tick(monotonic: 1830, unitBytes: 3_000_000)
    harness.expect(engine.growth.samples.isEmpty, "bytes written inside the gate do not feed the growth estimate")
}

exit(harness.report())
