import Foundation
import CryptoKit

final class InjectedSidecarWriter: ScanSidecarFileWriting {
    var storage: [URL: Data] = [:]
    var writeError: Error?
    var appendError: Error?
    var appendErrors: [URL: Error] = [:]
    var removeError: Error?

    func fileExists(at url: URL) -> Bool {
        return storage[url] != nil
    }

    func append(_ data: Data, to url: URL) throws {
        if let error = appendErrors[url] { throw error }
        if let appendError { throw appendError }
        storage[url, default: Data()].append(data)
    }

    func writeAtomic(_ data: Data, to url: URL) throws {
        if let writeError { throw writeError }
        storage[url] = data
    }

    func removeItem(at url: URL) throws {
        if let removeError { throw removeError }
        storage.removeValue(forKey: url)
    }
}

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        FileHandle.standardError.write(Data("FAILED: \(message)\n".utf8))
        exit(1)
    }
}

func close(_ first: Double, _ second: Double, tolerance: Double = 1.0e-9) -> Bool {
    return abs(first - second) <= tolerance
}

let injectedFailure = NSError(
    domain: "MarketScannerFinalizationTests",
    code: 1,
    userInfo: [NSLocalizedDescriptionKey: "injected failure"])
let metadataURL = URL(fileURLWithPath: "/tmp/metadata.json")
let checkpointURL = URL(fileURLWithPath: "/tmp/live_checkpoint.json")
let metadataData = Data("{\"finalized\":true}".utf8)

let metadataFailureWriter = InjectedSidecarWriter()
metadataFailureWriter.storage[checkpointURL] = Data("checkpoint".utf8)
metadataFailureWriter.writeError = injectedFailure
var metadataFailureObserved = false
do {
    _ = try SidecarFinalizationCoordinator.commitMetadata(
        metadataData,
        metadataURL: metadataURL,
        finalized: true,
        checkpointURL: checkpointURL,
        writer: metadataFailureWriter)
}
catch {
    metadataFailureObserved = true
}
require(metadataFailureObserved, "metadata write failure must remain pre-commit")
require(
    !metadataFailureWriter.fileExists(at: metadataURL),
    "failed metadata must not become visible")
require(
    SidecarFinalizationCoordinator.disposition(
        saveSucceeded: true,
        expectedFinalizedMetadata: true,
        commitResult: nil,
        preCommitError: "injected",
        eligibilityError: nil) == .resumeRecording,
    "pre-commit metadata failure may resume recording")

let cleanupFailureWriter = InjectedSidecarWriter()
cleanupFailureWriter.storage[checkpointURL] = Data("checkpoint".utf8)
cleanupFailureWriter.removeError = injectedFailure
let cleanupFailure = try SidecarFinalizationCoordinator.commitMetadata(
    metadataData,
    metadataURL: metadataURL,
    finalized: true,
    checkpointURL: checkpointURL,
    writer: cleanupFailureWriter)
require(cleanupFailure.metadataCommitted, "metadata must be committed before cleanup")
require(
    cleanupFailure.phase == .finalizedNeedsCleanup,
    "cleanup failure must enter terminal needs-cleanup")
require(
    cleanupFailureWriter.fileExists(at: checkpointURL),
    "failed cleanup must preserve checkpoint")
require(
    SidecarFinalizationCoordinator.disposition(
        saveSucceeded: true,
        expectedFinalizedMetadata: true,
        commitResult: cleanupFailure,
        preCommitError: nil,
        eligibilityError: nil) == .terminalFinalizedNeedsCleanup,
    "post-commit cleanup failure must never resume recording")

let successfulWriter = InjectedSidecarWriter()
successfulWriter.storage[checkpointURL] = Data("checkpoint".utf8)
let committed = try SidecarFinalizationCoordinator.commitMetadata(
    metadataData,
    metadataURL: metadataURL,
    finalized: true,
    checkpointURL: checkpointURL,
    writer: successfulWriter)
require(committed.phase == .checkpointCleaned, "successful cleanup phase")
require(
    !successfulWriter.fileExists(at: checkpointURL),
    "successful commit must remove the old checkpoint")
require(
    SidecarFinalizationCoordinator.disposition(
        saveSucceeded: true,
        expectedFinalizedMetadata: true,
        commitResult: committed,
        preCommitError: nil,
        eligibilityError: nil) == .terminalFinalized,
    "successful finalized metadata must end recording")

let invalidEvidenceWriter = InjectedSidecarWriter()
invalidEvidenceWriter.storage[checkpointURL] = Data("checkpoint".utf8)
let invalidMetadataCommit = try SidecarFinalizationCoordinator.commitMetadata(
    Data("{\"finalized\":false}".utf8),
    metadataURL: metadataURL,
    finalized: false,
    checkpointURL: checkpointURL,
    writer: invalidEvidenceWriter)
require(
    SidecarFinalizationCoordinator.disposition(
        saveSucceeded: true,
        expectedFinalizedMetadata: false,
        commitResult: invalidMetadataCommit,
        preCommitError: nil,
        eligibilityError: "required evidence failed")
        == .terminalIneligibleEvidence,
    "saved ineligible evidence must stop as a recovery package, not resume")
require(
    invalidEvidenceWriter.fileExists(at: checkpointURL),
    "ineligible recovery package must retain its checkpoint")

let resumeEffects = ScanFinalizationEffectPlanner.effects(
    for: .resumeRecording)
require(
    resumeEffects.resumesCameraAndMapping && !resumeEffects.closesSession,
    "only pre-commit failure may resume camera and mapping")
let finalizedEffects = ScanFinalizationEffectPlanner.effects(
    for: .terminalFinalized)
require(
    finalizedEffects.closesSession
        && finalizedEffects.allowsExternalCopy
        && !finalizedEffects.preservesCheckpoint
        && finalizedEffects.processingEligible,
    "normal finalization must close, clean and allow verified copy")
let cleanupEffects = ScanFinalizationEffectPlanner.effects(
    for: .terminalFinalizedNeedsCleanup)
require(
    cleanupEffects.closesSession
        && !cleanupEffects.resumesCameraAndMapping
        && !cleanupEffects.allowsExternalCopy
        && cleanupEffects.preservesCheckpoint,
    "post-commit cleanup failure must stay closed and local")
let ineligibleEffects = ScanFinalizationEffectPlanner.effects(
    for: .terminalIneligibleEvidence)
require(
    ineligibleEffects.closesSession
        && !ineligibleEffects.resumesCameraAndMapping
        && ineligibleEffects.preservesCheckpoint
        && !ineligibleEffects.processingEligible,
    "ineligible recovery package must close and retain checkpoint")

let traceURL = URL(fileURLWithPath: "/tmp/localization_trace.jsonl")
let constraintURL = URL(fileURLWithPath: "/tmp/localization_constraints.jsonl")
let stateURL = URL(fileURLWithPath: "/tmp/localization_events.jsonl")
let traceRecord = EncodedLocalizationSidecarRecord(
    fileName: "localization_trace.jsonl",
    data: Data("trace\n".utf8),
    url: traceURL)
let constraintRecord = EncodedLocalizationSidecarRecord(
    fileName: "localization_constraints.jsonl",
    data: Data("constraint\n".utf8),
    url: constraintURL)
let stateRecord = EncodedLocalizationSidecarRecord(
    fileName: "localization_events.jsonl",
    data: Data("state\n".utf8),
    url: stateURL)
for failedURL in [traceURL, constraintURL, stateURL] {
    let partialWriter = InjectedSidecarWriter()
    partialWriter.appendErrors[failedURL] = injectedFailure
    let result = LocalizationEvidenceWriteCoordinator.write(
        trace: traceRecord,
        constraint: constraintRecord,
        state: stateRecord,
        writer: partialWriter)
    require(!result.succeeded, "each required sidecar failure must be visible")
    require(
        result.failedRequiredFiles.count == 1,
        "partial success must identify exactly the failed required file")
    if failedURL == stateURL {
        require(!result.stateWritten, "failed state event must not be durable")
    }
}
let noStateWriter = InjectedSidecarWriter()
let noStateResult = LocalizationEvidenceWriteCoordinator.write(
    trace: traceRecord,
    constraint: constraintRecord,
    state: nil,
    writer: noStateWriter)
require(noStateResult.succeeded, "unchanged state must not require a state event")
require(!noStateResult.stateWriteRequired, "state write requirement must be explicit")

let cleanupMetadata = Data(
    "{\"finalized\":true,\"trackingSessionId\":\"session-a\",\"finalizedAtUnix\":20}".utf8)
let olderCheckpoint = Data(
    "{\"trackingSessionId\":\"session-a\",\"updatedAtUnix\":10}".utf8)
try FinalizedCheckpointCleanupValidator.validate(
    metadataData: cleanupMetadata,
    checkpointData: olderCheckpoint)
var newerCheckpointRejected = false
do {
    try FinalizedCheckpointCleanupValidator.validate(
        metadataData: cleanupMetadata,
        checkpointData: Data(
            "{\"trackingSessionId\":\"session-a\",\"updatedAtUnix\":21}".utf8))
}
catch FinalizedCheckpointCleanupValidationError.checkpointNewerThanCommit {
    newerCheckpointRejected = true
}
require(newerCheckpointRejected, "newer checkpoint cleanup must fail closed")

let finalizationTemp = FileManager.default.temporaryDirectory.appendingPathComponent(
    "MarketScannerFinalization-\(UUID().uuidString)",
    isDirectory: true)
try FileManager.default.createDirectory(
    at: finalizationTemp,
    withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: finalizationTemp) }
let foundationWriter = FoundationScanSidecarWriter()
let appendURL = finalizationTemp.appendingPathComponent("events.jsonl")
try foundationWriter.writeAtomic(Data("first\n".utf8), to: appendURL)
try foundationWriter.append(Data("second\n".utf8), to: appendURL)
let appendedContents = try String(contentsOf: appendURL, encoding: .utf8)
require(
    appendedContents == "first\nsecond\n",
    "Foundation writer must append complete records")
for failedStage in [
    AtomicWriteStage.write,
    AtomicWriteStage.flush,
    AtomicWriteStage.rename,
] {
    let stagedURL = finalizationTemp.appendingPathComponent(
        "atomic-\(failedStage.rawValue).json")
    try Data("old".utf8).write(to: stagedURL)
    let failingWriter = FoundationScanSidecarWriter(
        atomicWriteFault: { stage, _ in
            if stage == failedStage { throw injectedFailure }
        })
    var failureObserved = false
    do {
        try failingWriter.writeAtomic(Data("new".utf8), to: stagedURL)
    }
    catch {
        failureObserved = true
    }
    require(failureObserved, "each atomic write stage must be injectable")
    let retainedBytes = try Data(contentsOf: stagedURL)
    require(
        retainedBytes == Data("old".utf8),
        "pre-rename write/flush/rename failures must preserve old bytes")
    let temporaryFiles = try FileManager.default.contentsOfDirectory(
        at: finalizationTemp,
        includingPropertiesForKeys: nil).filter {
            $0.lastPathComponent.contains("atomic-\(failedStage.rawValue).json.")
                && $0.pathExtension == "tmp"
        }
    require(temporaryFiles.isEmpty, "failed atomic writes must clean temp files")
}

let evidenceDirectory = finalizationTemp.appendingPathComponent(
    "evidence",
    isDirectory: true)
try FileManager.default.createDirectory(
    at: evidenceDirectory,
    withIntermediateDirectories: true)
func evidenceRecord(format: String, state: String? = nil) throws -> Data {
    var value: [String: Any] = [
        "format": format,
        "version": 1,
        "trackingSessionId": "session-a",
        "priorMapId": "map-a",
        "priorMapSha256": String(repeating: "a", count: 64),
        "floorId": "1",
    ]
    if let state { value["state"] = state }
    var data = try JSONSerialization.data(withJSONObject: value)
    data.append(0x0A)
    return data
}
let evidenceExpectation = LocalizationEvidenceBundleExpectation(
    trackingSessionId: "session-a",
    priorMapId: "map-a",
    priorMapSha256: String(repeating: "a", count: 64),
    floorId: "1",
    traceRecordCount: 1,
    constraintRecordCount: 1,
    stateEventCount: 1,
    lastDurableState: "stable",
    localizedPriceTagCount: 0)
let traceEvidenceURL = evidenceDirectory.appendingPathComponent(
    "localization_trace.jsonl")
let constraintEvidenceURL = evidenceDirectory.appendingPathComponent(
    "localization_constraints.jsonl")
let stateEvidenceURL = evidenceDirectory.appendingPathComponent(
    "localization_events.jsonl")
try evidenceRecord(format: "MarketScannerLocalizationTrace")
    .write(to: traceEvidenceURL)
try evidenceRecord(format: "MarketScannerLocalizationConstraint")
    .write(to: constraintEvidenceURL)
try evidenceRecord(
    format: "MarketScannerLocalizationStateEvent",
    state: "stable").write(to: stateEvidenceURL)
try Data().write(to: evidenceDirectory.appendingPathComponent(
    "manual_localization_events.jsonl"))
try Data().write(to: evidenceDirectory.appendingPathComponent(
    "tag_observations.jsonl"))
try Data("[]".utf8).write(to: evidenceDirectory.appendingPathComponent(
    "localized_price_tags.json"))
require(
    LocalizationEvidenceBundleValidator.blockers(
        in: evidenceDirectory,
        expectation: evidenceExpectation).isEmpty,
    "a complete persisted evidence bundle must validate")

let originalTrace = try Data(contentsOf: traceEvidenceURL)
try FileManager.default.removeItem(at: traceEvidenceURL)
require(
    LocalizationEvidenceBundleValidator.blockers(
        in: evidenceDirectory,
        expectation: evidenceExpectation).contains {
            $0.contains("localization_trace.jsonl")
        },
    "a deleted required trace must block finalization")
try originalTrace.write(to: traceEvidenceURL)
try Data("{\"format\":".utf8).write(to: constraintEvidenceURL)
require(
    LocalizationEvidenceBundleValidator.blockers(
        in: evidenceDirectory,
        expectation: evidenceExpectation).contains {
            $0.contains("localization_constraints.jsonl")
        },
    "a truncated required constraint must block finalization")
try evidenceRecord(format: "MarketScannerLocalizationConstraint")
    .write(to: constraintEvidenceURL)
try Data().write(to: stateEvidenceURL)
require(
    LocalizationEvidenceBundleValidator.blockers(
        in: evidenceDirectory,
        expectation: evidenceExpectation).contains {
            $0.contains("localization_events.jsonl")
        },
    "an empty required state file must block finalization")
try evidenceRecord(
    format: "MarketScannerLocalizationStateEvent",
    state: "stable").write(to: stateEvidenceURL)
var wrongIdentity = try JSONSerialization.jsonObject(
    with: originalTrace) as! [String: Any]
wrongIdentity["trackingSessionId"] = "other-session"
var wrongIdentityData = try JSONSerialization.data(withJSONObject: wrongIdentity)
wrongIdentityData.append(0x0A)
try wrongIdentityData.write(to: traceEvidenceURL)
require(
    LocalizationEvidenceBundleValidator.blockers(
        in: evidenceDirectory,
        expectation: evidenceExpectation).contains {
            $0.contains("identity_mismatch")
        },
    "identity mismatch must block finalization")
try originalTrace.write(to: traceEvidenceURL)
let linkedTrace = evidenceDirectory.appendingPathComponent("linked-trace")
try FileManager.default.moveItem(at: traceEvidenceURL, to: linkedTrace)
try FileManager.default.createSymbolicLink(
    at: traceEvidenceURL,
    withDestinationURL: linkedTrace)
require(
    LocalizationEvidenceBundleValidator.blockers(
        in: evidenceDirectory,
        expectation: evidenceExpectation).contains {
            $0.contains("localization_trace.jsonl")
        },
    "a linked required sidecar must block finalization")
try FileManager.default.removeItem(at: traceEvidenceURL)
try FileManager.default.moveItem(at: linkedTrace, to: traceEvidenceURL)

let cleanupRoot = finalizationTemp.appendingPathComponent(
    "SupermarketSession-Cleanup",
    isDirectory: true)
let cleanupSegment = cleanupRoot.appendingPathComponent(
    "segment_0001",
    isDirectory: true)
try FileManager.default.createDirectory(
    at: cleanupSegment,
    withIntermediateDirectories: true)
try SafeSessionPath.validateDirectory(cleanupSegment, within: cleanupRoot)
require(
    !SafeSessionPath.isStrictlyContained(
        finalizationTemp.appendingPathComponent("SupermarketSession-Cleanup-Other"),
        in: cleanupRoot),
    "path-component containment must reject adjacent prefixes")
let safeCheckpointURL = cleanupSegment.appendingPathComponent(
    "live_checkpoint.json")
try olderCheckpoint.write(to: safeCheckpointURL)
let safeCheckpoint = try SafeSessionPath.readRegularFile(
    safeCheckpointURL,
    within: cleanupRoot)
try SafeSessionPath.append(
    Data("audit\n".utf8),
    to: cleanupSegment.appendingPathComponent("scan_events.jsonl"),
    within: cleanupRoot)
let outsideCheckpoint = finalizationTemp.appendingPathComponent(
    "outside-checkpoint.json")
try olderCheckpoint.write(to: outsideCheckpoint)
try FileManager.default.removeItem(at: safeCheckpointURL)
try FileManager.default.createSymbolicLink(
    at: safeCheckpointURL,
    withDestinationURL: outsideCheckpoint)
var linkedCheckpointRejected = false
do {
    _ = try SafeSessionPath.readRegularFile(
        safeCheckpointURL,
        within: cleanupRoot)
}
catch {
    linkedCheckpointRejected = true
}
require(linkedCheckpointRejected, "checkpoint no-follow must reject symlinks")
try FileManager.default.removeItem(at: safeCheckpointURL)
try safeCheckpoint.data.write(to: safeCheckpointURL)
let restoredCheckpoint = try SafeSessionPath.readRegularFile(
    safeCheckpointURL,
    within: cleanupRoot)
try SafeSessionPath.removeRegularFile(
    safeCheckpointURL,
    within: cleanupRoot,
    expected: restoredCheckpoint)
require(
    !FileManager.default.fileExists(atPath: safeCheckpointURL.path),
    "descriptor-validated checkpoint removal must delete the expected file")

let captureSource = finalizationTemp.appendingPathComponent(
    "capture-source",
    isDirectory: true)
let captureCopy = finalizationTemp.appendingPathComponent(
    "capture-copy",
    isDirectory: true)
try FileManager.default.createDirectory(
    at: captureSource,
    withIntermediateDirectories: true)
try Data("database-a".utf8).write(
    to: captureSource.appendingPathComponent("rtabmap_segment_0001.db"))
try Data("metadata-a".utf8).write(
    to: captureSource.appendingPathComponent("metadata.json"))
let sourceManifestBefore = try CaptureDirectoryIntegrity.manifest(for: captureSource)
try FileManager.default.copyItem(at: captureSource, to: captureCopy)
let copiedManifest = try CaptureDirectoryIntegrity.manifest(for: captureCopy)
require(
    sourceManifestBefore == copiedManifest,
    "per-file SHA-256 manifests must verify an unchanged capture copy")
try Data("database-b".utf8).write(
    to: captureSource.appendingPathComponent("rtabmap_segment_0001.db"))
let sourceManifestAfter = try CaptureDirectoryIntegrity.manifest(for: captureSource)
require(
    sourceManifestBefore != sourceManifestAfter,
    "same-size source mutation must be detected by per-file SHA-256")

require(PriorMapScanConfiguration.freeMapping.isReadyToStart, "free mapping must remain startable")
require(
    PriorMapScanConfiguration(
        formatVersion: 1,
        workflowMode: .priorMapLocalized,
        packageDirectory: nil,
        priorMapId: nil,
        priorMapSha256: nil,
        floorId: nil,
        initialMapPose: nil
    ).isReadyToStart == false,
    "incomplete prior-map setup must not start")

let ready = PriorMapScanConfiguration(
    formatVersion: 1,
    workflowMode: .priorMapLocalized,
    packageDirectory: URL(fileURLWithPath: "/tmp/PriorMap-fixture"),
    priorMapId: "fixture",
    priorMapSha256: String(repeating: "a", count: 64),
    floorId: "1",
    initialMapPose: PriorMapPose2D(xM: 2, yM: 3, yawRad: .pi / 2))
require(ready.isReadyToStart, "complete prior-map setup must start")

let identity = PriorMapStageOneMath.arkitHorizontalPose(
    positionX: 0,
    positionZ: 0,
    forwardX: 0,
    forwardZ: -1)
require(close(identity.xM, 0), "identity map x")
require(close(identity.yM, 0), "identity map y")
require(close(identity.yawRad, 0), "identity yaw must point toward map +y")

let forward = PriorMapStageOneMath.arkitHorizontalPose(
    positionX: 0,
    positionZ: -1,
    forwardX: 0,
    forwardZ: -1)
require(close(forward.xM, 0), "forward x")
require(close(forward.yM, 1), "ARKit -z forward must be map +y")

let backward = PriorMapStageOneMath.arkitHorizontalPose(
    positionX: 0,
    positionZ: 1,
    forwardX: 0,
    forwardZ: -1)
require(close(backward.yM, -1), "ARKit +z backward must be map -y")

let right = PriorMapStageOneMath.arkitHorizontalPose(
    positionX: 1,
    positionZ: 0,
    forwardX: 0,
    forwardZ: -1)
require(close(right.xM, 1), "ARKit +x must be map +x")

let leftTurn = PriorMapStageOneMath.arkitHorizontalPose(
    positionX: 0,
    positionZ: 0,
    forwardX: -1,
    forwardZ: 0)
require(close(leftTurn.yawRad, .pi / 2), "left turn must be positive map yaw")

let rightTurn = PriorMapStageOneMath.arkitHorizontalPose(
    positionX: 0,
    positionZ: 0,
    forwardX: 1,
    forwardZ: 0)
require(close(rightTurn.yawRad, -.pi / 2), "right turn must be negative map yaw")

let projected = PriorMapStageOneMath.project(
    arkitPose: PriorMapPose2D(xM: 11, yM: 20, yawRad: 0),
    arkitOrigin: PriorMapPose2D(xM: 10, yM: 20, yawRad: 0),
    initialMapPose: PriorMapPose2D(xM: 2, yM: 3, yawRad: .pi / 2))
require(close(projected.xM, 2), "rotated map x")
require(close(projected.yM, 4), "rotated map y")
require(close(projected.yawRad, .pi / 2), "map yaw")

let nonzeroOrigin = PriorMapStageOneMath.project(
    arkitPose: PriorMapPose2D(xM: 3, yM: 6, yawRad: .pi / 2),
    arkitOrigin: PriorMapPose2D(xM: 3, yM: 5, yawRad: .pi / 2),
    initialMapPose: PriorMapPose2D(xM: 10, yM: 20, yawRad: -.pi / 2))
require(close(nonzeroOrigin.xM, 10), "nonzero origin x")
require(close(nonzeroOrigin.yM, 19), "nonzero origin y")
require(close(nonzeroOrigin.yawRad, -.pi / 2), "nonzero origin yaw")

require(
    close(PriorMapStageOneMath.normalizeAngle(3 * .pi), .pi),
    "angle normalization")

let updateGate = PriorMapUpdateGate(minimumInterval: 0.5)
guard case .accepted(let firstTicket) = updateGate.begin(timestamp: 10.0) else {
    require(false, "first update must be accepted")
    exit(1)
}
require(
    updateGate.begin(timestamp: 10.1) == .throttled,
    "updates inside the interval must be throttled")
require(
    updateGate.begin(timestamp: 10.6) == .busy(droppedCount: 1),
    "a new update must be dropped while one is in flight")
updateGate.reset()
guard case .accepted(let secondTicket) = updateGate.begin(timestamp: 1.0) else {
    require(false, "reset must accept a new generation")
    exit(1)
}
updateGate.finish(ticket: firstTicket)
require(
    updateGate.begin(timestamp: 2.0) == .busy(droppedCount: 1),
    "a stale completion must not release a newer update")
updateGate.finish(ticket: secondTicket)
guard case .accepted = updateGate.begin(timestamp: 2.0) else {
    require(false, "the active ticket completion must release the gate")
    exit(1)
}

let confidenceManager = PriorMapConfidenceManager()
confidenceManager.reset()
let initializing = confidenceManager.update(
    timestamp: 1,
    trackingState: "normal",
    accepted: false,
    validPointCount: 0,
    coverageAngleRad: 0,
    uniqueness: 0,
    residualCost: 0.15,
    mapMismatch: false)
require(initializing.phase == .initializing, "first unmatched frame must stay initializing")
confidenceManager.reset()
for timestamp in 1...3 {
    _ = confidenceManager.update(
        timestamp: Double(timestamp),
        trackingState: "normal",
        accepted: true,
        validPointCount: 100,
        coverageAngleRad: 1.2,
        uniqueness: 0.3,
        residualCost: 0.02,
        mapMismatch: false)
}
require(confidenceManager.phase == .stable, "three trusted observations must enter stable")
let weak = confidenceManager.update(
    timestamp: 4,
    trackingState: "limited",
    accepted: false,
    validPointCount: 40,
    coverageAngleRad: 0.2,
    uniqueness: 0,
    residualCost: 0.15,
    mapMismatch: false)
require(weak.phase == .weak, "limited tracking must degrade to weak")

let temporalGate = PriorMapTemporalCorrectionGate()
let firstMovingCandidate = temporalGate.observe(
    rawPose: PriorMapPose2D(xM: 0, yM: 0, yawRad: 0),
    candidatePose: PriorMapPose2D(xM: 0.2, yM: 0.05, yawRad: 0.02))
let secondMovingCandidate = temporalGate.observe(
    rawPose: PriorMapPose2D(xM: 1.2, yM: 0, yawRad: 0),
    candidatePose: PriorMapPose2D(xM: 1.4, yM: 0.05, yawRad: 0.02))
require(!firstMovingCandidate, "one correction must not pass the temporal gate")
require(
    secondMovingCandidate,
    "normal walking with a stable correction transform must pass")
temporalGate.reset()
_ = temporalGate.observe(
    rawPose: PriorMapPose2D(xM: 0, yM: 0, yawRad: .pi / 2),
    candidatePose: PriorMapPose2D(xM: 0, yM: 0.2, yawRad: .pi / 2 + 0.02))
require(
    temporalGate.observe(
        rawPose: PriorMapPose2D(xM: 0, yM: 1, yawRad: .pi / 2),
        candidatePose: PriorMapPose2D(xM: 0, yM: 1.2, yawRad: .pi / 2 + 0.02)),
    "turning motion must be removed before comparing correction transforms")
temporalGate.reset()
_ = temporalGate.observe(
    rawPose: PriorMapPose2D(xM: 0, yM: 0, yawRad: 0),
    candidatePose: PriorMapPose2D(xM: 0.2, yM: 0, yawRad: 0))
// Simulate an ambiguous/mismatch/unsafe frame. Production calls reset before
// observing any rejected geometry.
temporalGate.reset()
require(
    !temporalGate.observe(
        rawPose: PriorMapPose2D(xM: 1, yM: 0, yawRad: 0),
        candidatePose: PriorMapPose2D(xM: 1.2, yM: 0, yawRad: 0)),
    "a rejected frame must not preheat the next accepted correction")
require(
    temporalGate.observe(
        rawPose: PriorMapPose2D(xM: 2, yM: 0, yawRad: 0),
        candidatePose: PriorMapPose2D(xM: 2.2, yM: 0, yawRad: 0)),
    "two post-reset consistent frames are required")

let orientedBounds = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
let rightBounds = PriorMapImageGeometry.nativeSensorBounds(
    visionBounds: orientedBounds,
    orientation: .right)
require(close(rightBounds.origin.x, 0.4), "right orientation x mapping")
require(close(rightBounds.origin.y, 0.1), "right orientation y mapping")
require(close(rightBounds.width, 0.4), "right orientation width mapping")
require(close(rightBounds.height, 0.3), "right orientation height mapping")
let leftBounds = PriorMapImageGeometry.nativeSensorBounds(
    visionBounds: orientedBounds,
    orientation: .left)
require(close(leftBounds.origin.x, 0.2), "left orientation x mapping")
require(close(leftBounds.origin.y, 0.6), "left orientation y mapping")
let downBounds = PriorMapImageGeometry.nativeSensorBounds(
    visionBounds: orientedBounds,
    orientation: .down)
require(close(downBounds.origin.x, 0.6), "down orientation x mapping")
require(close(downBounds.origin.y, 0.4), "down orientation y mapping")
let upBounds = PriorMapImageGeometry.nativeSensorBounds(
    visionBounds: orientedBounds,
    orientation: .up)
require(close(upBounds.origin.x, 0.1), "up orientation x mapping")
require(close(upBounds.origin.y, 0.2), "up orientation y mapping")

let floorEstimator = PriorMapFloorPlaneEstimator()
let floorSamples = (0..<80).map {
    PriorMapFloorSample(
        heightWorldM: -1.5 + Double($0 % 5 - 2) * 0.002,
        relativeHeightM: -1.5,
        upAlignment: 0.98)
}
let firstFloor = floorEstimator.update(samples: floorSamples)
var stableFloor = firstFloor
for _ in 0..<5 {
    stableFloor = floorEstimator.update(samples: floorSamples)
}
require(firstFloor != nil, "a supported horizontal floor plane must be estimated")
require(
    (stableFloor?.confidence ?? 0) > (firstFloor?.confidence ?? 1),
    "floor confidence must depend on temporal stability")
floorEstimator.reset()
require(
    floorEstimator.update(
        samples: floorSamples.map { sample in
            PriorMapFloorSample(
                heightWorldM: sample.heightWorldM,
                relativeHeightM: sample.relativeHeightM,
                upAlignment: 0.3)
        }) == nil,
    "non-horizontal low objects must not become the floor")
floorEstimator.reset()
require(
    floorEstimator.update(
        samples: floorSamples.map { _ in
            PriorMapFloorSample(
                heightWorldM: -0.7,
                relativeHeightM: -0.7,
                upAlignment: 0.99)
        }) == nil,
    "a horizontal low shelf or cart must not become the floor")

let shelf = PriorMapShelf(
    id: "shelf-1",
    floorId: "1",
    code: "S1",
    crossCode: "C1",
    rowFlag: "R1",
    geometry: PriorMapShelfGeometry(
        type: "Polygon",
        coordinates: [[0, 0], [4, 0], [4, 1], [0, 1], [0, 0]]))
let localized = ShelfAssociation.localizedTag(
    observationId: "observation",
    payload: "6900000000000",
    symbology: "EAN13",
    floorId: "1",
    rawPosition: PriorMapTagPoint3D(xM: 2, yM: -0.1, heightM: 1.4),
    cameraPosition: SIMD2<Double>(2, -2),
    shelves: [shelf],
    localizationState: "stable",
    localizationConfidence: 0.9,
    measurementConfidence: 0.9,
    measurementMethod: "scene_depth",
    userConfirmed: false)
require(localized.shelfCode == "S1", "tag must associate with the expected shelf")
require(localized.distanceFromShelfStartCm != nil, "tag must retain along-shelf offset")
require(localized.heightCm == 140, "tag height must be expressed in centimetres")

let oppositeSide = ShelfAssociation.localizedTag(
    observationId: "opposite",
    payload: "opposite",
    symbology: "EAN13",
    floorId: "1",
    rawPosition: PriorMapTagPoint3D(xM: 2, yM: 1.1, heightM: 1.2),
    cameraPosition: SIMD2<Double>(2, 2),
    shelves: [shelf],
    localizationState: "stable",
    localizationConfidence: 0.9,
    measurementConfidence: 0.9,
    measurementMethod: "scene_depth",
    userConfirmed: false)
require(
    localized.shelfSide != oppositeSide.shelfSide,
    "opposite long faces must retain different shelf sides")

let backside = ShelfAssociation.localizedTag(
    observationId: "backside",
    payload: "backside",
    symbology: "EAN13",
    floorId: "1",
    rawPosition: PriorMapTagPoint3D(xM: 2, yM: 0.9, heightM: 1.2),
    cameraPosition: SIMD2<Double>(2, -2),
    shelves: [shelf],
    localizationState: "stable",
    localizationConfidence: 0.9,
    measurementConfidence: 0.9,
    measurementMethod: "scene_depth",
    userConfirmed: false)
require(backside.needsReview, "a shelf face hidden behind the near face requires review")

let rearShelf = PriorMapShelf(
    id: "rear",
    floorId: "1",
    code: "REAR",
    crossCode: nil,
    rowFlag: nil,
    geometry: PriorMapShelfGeometry(
        type: "Polygon",
        coordinates: [[0, 2], [4, 2], [4, 3], [0, 3], [0, 2]]))
let blockedRear = ShelfAssociation.localizedTag(
    observationId: "blocked-rear",
    payload: "blocked-rear",
    symbology: "QR",
    floorId: "1",
    rawPosition: PriorMapTagPoint3D(xM: 2, yM: 1.95, heightM: 1.2),
    cameraPosition: SIMD2<Double>(2, -2),
    shelves: [shelf, rearShelf],
    localizationState: "stable",
    localizationConfidence: 0.9,
    measurementConfidence: 0.9,
    measurementMethod: "scene_depth",
    userConfirmed: false)
require(blockedRear.shelfCode == nil, "a rear shelf hidden by another shelf must not be preselected")
require(blockedRear.needsReview, "cross-shelf occlusion must require review")

let counter = PriorMapFixedStructure(
    id: "counter",
    floorId: "1",
    shapeType: "MapTable",
    code: "COUNTER",
    crossCode: "C2",
    rowFlag: nil,
    geometry: PriorMapShelfGeometry(
        type: "Polygon",
        coordinates: [[6, 0], [10, 0], [10, 1], [8, 1.5], [6, 1], [6, 0]]))
let counterTag = ShelfAssociation.localizedTag(
    observationId: "counter",
    payload: "counter",
    symbology: "QR",
    floorId: "1",
    rawPosition: PriorMapTagPoint3D(xM: 8, yM: -0.1, heightM: 1.0),
    cameraPosition: SIMD2<Double>(8, -2),
    shelves: [],
    fixedStructures: [counter],
    localizationState: "stable",
    localizationConfidence: 0.9,
    measurementConfidence: 0.9,
    measurementMethod: "scene_depth",
    userConfirmed: false)
require(counterTag.shelfCode == "COUNTER", "fixed counters must be associable")
let pillar = PriorMapFixedStructure(
    id: "pillar",
    floorId: "1",
    shapeType: "MapPillar",
    code: "P1",
    crossCode: nil,
    rowFlag: nil,
    geometry: PriorMapShelfGeometry(
        type: "Polygon",
        coordinates: [[7.7, -0.3], [8.3, -0.3], [8.3, 0.3], [7.7, 0.3], [7.7, -0.3]]))
let pillarTag = ShelfAssociation.localizedTag(
    observationId: "pillar",
    payload: "pillar",
    symbology: "QR",
    floorId: "1",
    rawPosition: PriorMapTagPoint3D(xM: 8, yM: 0, heightM: 1),
    cameraPosition: SIMD2<Double>(8, -2),
    shelves: [],
    fixedStructures: [pillar],
    localizationState: "stable",
    localizationConfidence: 0.9,
    measurementConfidence: 0.9,
    measurementMethod: "scene_depth",
    userConfirmed: false)
require(pillarTag.shelfCode == nil, "pillars must remain blockers, not tag surfaces")
require(pillarTag.needsReview, "a pillar-only hit must require review")

let endpoint = ShelfAssociation.localizedTag(
    observationId: "endpoint",
    payload: "endpoint",
    symbology: "QR",
    floorId: "1",
    rawPosition: PriorMapTagPoint3D(xM: 0, yM: -0.05, heightM: 1),
    cameraPosition: SIMD2<Double>(0, -2),
    shelves: [shelf],
    localizationState: "stable",
    localizationConfidence: 0.9,
    measurementConfidence: 0.9,
    measurementMethod: "scene_depth",
    userConfirmed: false)
require(endpoint.shelfCode == "S1", "shelf endpoint must remain associable")
require(endpoint.needsReview, "endpoint ambiguity must require review")

let duplicateShelf = PriorMapShelf(
    id: "shelf-duplicate",
    floorId: "1",
    code: "S2",
    crossCode: nil,
    rowFlag: nil,
    geometry: shelf.geometry)
let ambiguous = ShelfAssociation.localizedTag(
    observationId: "ambiguous",
    payload: "ambiguous",
    symbology: "QR",
    floorId: "1",
    rawPosition: PriorMapTagPoint3D(xM: 2, yM: -0.1, heightM: 1),
    cameraPosition: SIMD2<Double>(2, -2),
    shelves: [shelf, duplicateShelf],
    localizationState: "stable",
    localizationConfidence: 0.9,
    measurementConfidence: 0.9,
    measurementMethod: "scene_depth",
    userConfirmed: false)
require(ambiguous.needsReview, "overlapping shelves must be marked ambiguous")

let rotatedShelf = PriorMapShelf(
    id: "rotated",
    floorId: "1",
    code: "ROT",
    crossCode: nil,
    rowFlag: nil,
    geometry: PriorMapShelfGeometry(
        type: "Polygon",
        coordinates: [[0, 0], [2, 2], [1.5, 2.5], [-0.5, 0.5], [0, 0]]))
let rotated = ShelfAssociation.localizedTag(
    observationId: "rotated",
    payload: "rotated",
    symbology: "QR",
    floorId: "1",
    rawPosition: PriorMapTagPoint3D(xM: 0.8, yM: 1.3, heightM: 1),
    cameraPosition: SIMD2<Double>(-1, 2),
    shelves: [rotatedShelf],
    localizationState: "stable",
    localizationConfidence: 0.9,
    measurementConfidence: 0.9,
    measurementMethod: "scene_depth",
    userConfirmed: false)
require(rotated.shelfCode == "ROT", "rotated shelf geometry must be supported")

let outOfRange = ShelfAssociation.localizedTag(
    observationId: "far",
    payload: "far",
    symbology: "QR",
    floorId: "1",
    rawPosition: PriorMapTagPoint3D(xM: 20, yM: 20, heightM: 1),
    cameraPosition: SIMD2<Double>(19, 19),
    shelves: [shelf],
    localizationState: "stable",
    localizationConfidence: 0.9,
    measurementConfidence: 0.9,
    measurementMethod: "scene_depth",
    userConfirmed: false)
require(outOfRange.shelfCode == nil, "out-of-range observations must not snap")
require(outOfRange.needsReview, "out-of-range observations require review")

let unsafe = ShelfAssociation.localizedTag(
    observationId: "unsafe",
    payload: "unsafe",
    symbology: "QR",
    floorId: "1",
    rawPosition: PriorMapTagPoint3D(xM: 2, yM: -0.1, heightM: 1.4),
    cameraPosition: SIMD2<Double>(2, -2),
    shelves: [shelf],
    localizationState: "lost",
    localizationConfidence: 0,
    measurementConfidence: 0.9,
    measurementMethod: "scene_depth",
    userConfirmed: false)
require(unsafe.needsReview, "lost localization may never auto-confirm a tag")

func distanceLevel(
    resolution: Double,
    verticalLines: [Double]
) -> PriorMapDistanceFieldLevel {
    let origin = [-2.0, -2.0]
    let width = Int(4.0 / resolution)
    let height = Int(4.0 / resolution)
    let rowValues: [Int] = (0..<width).map { column in
        let center = origin[0] + (Double(column) + 0.5) * resolution
        let distance = verticalLines.map {
            max(0, abs(center - $0) - resolution / 2)
        }.min() ?? 2.55
        return min(255, Int((distance * 100).rounded()))
    }
    var encodedRow: [Int] = []
    for value in rowValues {
        if encodedRow.count >= 2, encodedRow[encodedRow.count - 1] == value {
            encodedRow[encodedRow.count - 2] += 1
        }
        else {
            encodedRow.append(1)
            encodedRow.append(value)
        }
    }
    let rows = Array(repeating: encodedRow, count: height)
    let canonical = "[" + rows.map {
        "[" + $0.map(String.init).joined(separator: ",") + "]"
    }.joined(separator: ",") + "]"
    let digest = SHA256.hash(data: Data(canonical.utf8))
        .map { String(format: "%02x", $0) }
        .joined()
    return PriorMapDistanceFieldLevel(
        resolutionM: resolution,
        originM: origin,
        width: width,
        height: height,
        encoding: "row_rle_u8_cm",
        dataSha256: digest,
        rows: rows)
}

do {
    let periodicFloor = PriorMapDistanceFieldFloor(
        levels: [0.4, 0.2, 0.1].map {
            distanceLevel(resolution: $0, verticalLines: [0, 0.6])
        })
    let periodicMatcher = try PriorMapScanMatcher(
        floor: periodicFloor,
        truncationM: 2.55)
    let observation = PriorMapStructureObservation(
        points: (0..<80).map {
            SIMD2<Double>(0, -1.5 + Double($0) * 3.0 / 79.0)
        },
        validPointCount: 80,
        coverageAngleRad: 1.2,
        floorEstimate: nil,
        source: "test")
    let periodic = periodicMatcher.match(
        predictedPose: PriorMapPose2D(xM: 0.3, yM: 0, yawRad: 0),
        observation: observation)
    require(
        !periodic.acceptedByGeometry,
        "periodic equal-cost structure basins must fail closed")
    require(
        periodic.uniqueness < 0.10,
        "uniqueness must compare independent global basins")
}
catch {
    require(false, "periodic matcher fixture must load: \(error)")
}

let coherentDepth = PriceTagDepthEvidence.evaluate(
    (0..<64).map { 1.20 + Float($0 % 5 - 2) * 0.002 })
require(coherentDepth.accepted, "dense coherent barcode depth must be accepted")
require(coherentDepth.inlierCount >= 48, "coherent depth must retain dense inliers")
require(coherentDepth.confidence >= 0.65, "high confidence must be evidence-derived")
let sparseDepth = PriceTagDepthEvidence.evaluate([1.0, 1.01, 0.99, 1.0])
require(!sparseDepth.accepted, "a few valid depth pixels must not imply confidence")
require(sparseDepth.confidence < 0.5, "sparse depth confidence must stay low")
let backgroundMajority = PriceTagDepthEvidence.evaluate(
    (0..<24).map { 0.9 + Float($0 % 3) * 0.002 }
        + (0..<57).map { 2.4 + Float($0 % 5) * 0.003 })
require(
    !backgroundMajority.accepted,
    "a foreground/background split with wrong-depth majority must fail closed")
require(
    backgroundMajority.rejectionReason == "ambiguous_depth_layers",
    "ambiguous depth layers must be auditable")
let fresh0 = PriorMapAlignmentFreshness.evaluate(
    ageMs: 0, versionLag: 0, localizationState: "stable", localizationConfidence: 0.9)
let fresh100 = PriorMapAlignmentFreshness.evaluate(
    ageMs: 100, versionLag: 0, localizationState: "stable", localizationConfidence: 0.9)
let aging300 = PriorMapAlignmentFreshness.evaluate(
    ageMs: 300, versionLag: 0, localizationState: "stable", localizationConfidence: 0.9)
let stale800 = PriorMapAlignmentFreshness.evaluate(
    ageMs: 800, versionLag: 0, localizationState: "stable", localizationConfidence: 0.9)
let versionStale = PriorMapAlignmentFreshness.evaluate(
    ageMs: 100, versionLag: 1, localizationState: "stable", localizationConfidence: 0.9)
require(fresh0.label == "fresh" && fresh100.label == "fresh", "0/100 ms must stay fresh")
require(aging300.label == "aging" && aging300.localizationState == "weak", "300 ms must be pending/weak")
require(stale800.label == "timestamp_stale" && stale800.localizationState == "lost", "800 ms must be stale")
require(versionStale.label == "version_stale", "alignment changes after scan must invalidate the snapshot")

let squareGeometry = PriorMapShelfGeometry(
    type: "Polygon",
    coordinates: [[0, 0], [2, 0], [2, 2], [0, 2]])
let reversedSquareGeometry = PriorMapShelfGeometry(
    type: "Polygon",
    coordinates: [[2, 2], [2, 0], [0, 0], [0, 2]])
let squareSource = PriorMapShelfSource(width: 200, height: 200)
let square = PriorMapShelf(
    id: "square",
    floorId: "1",
    code: "SQ",
    crossCode: nil,
    rowFlag: nil,
    geometry: squareGeometry,
    yawRad: 0,
    source: squareSource)
let reversedSquare = PriorMapShelf(
    id: "square",
    floorId: "1",
    code: "SQ",
    crossCode: nil,
    rowFlag: nil,
    geometry: reversedSquareGeometry,
    yawRad: 0,
    source: squareSource)
func squareTag(_ value: PriorMapShelf) -> LocalizedPriceTag {
    ShelfAssociation.localizedTag(
        observationId: "square",
        payload: "square",
        symbology: "QR",
        floorId: "1",
        rawPosition: PriorMapTagPoint3D(xM: 0.6, yM: -0.05, heightM: 1),
        cameraPosition: SIMD2<Double>(0.6, -2),
        shelves: [value],
        localizationState: "stable",
        localizationConfidence: 0.9,
        measurementConfidence: 0.9,
        measurementMethod: "scene_depth",
        userConfirmed: false)
}
let squareForward = squareTag(square)
let squareReversed = squareTag(reversedSquare)
require(squareForward.shelfSide == squareReversed.shelfSide, "square side ID must ignore ring order")
require(
    close(
        squareForward.distanceFromShelfStartCm ?? -1,
        squareReversed.distanceFromShelfStartCm ?? -2),
    "square offset start must be stable under reversed ring order")

if CommandLine.arguments.count == 2 {
    do {
        let digest = try PriorMapPackageIntegrity.validate(
            directory: URL(fileURLWithPath: CommandLine.arguments[1]))
        print("Package integrity passed \(digest)")
    }
    catch {
        FileHandle.standardError.write(Data("Package integrity failed: \(error)\n".utf8))
        exit(2)
    }
}

print("PriorMapLocalizationCore Swift tests passed")
