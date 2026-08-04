import Foundation
import CryptoKit
import Darwin

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
    value["timestamp"] = 1.0
    value["nodeTimebaseTimestamp"] = 1.0
    value["nodeTimebaseOffsetSeconds"] = 0.0
    let pose: [String: Any] = ["x_m": 0.0, "y_m": 0.0, "yaw_rad": 0.0]
    switch format {
    case "MarketScannerLocalizationTrace":
        value["rawPose"] = pose
        value["estimatedPose"] = pose
        value["trackingState"] = "normal"
        value["localizationState"] = "stable"
        value["confidence"] = 1.0
    case "MarketScannerLocalizationConstraint":
        value["accepted"] = false
        value["predictedPose"] = pose
        value["uniqueness"] = 0.9
    case "MarketScannerLocalizationStateEvent":
        value["state"] = state ?? "stable"
        value["confidence"] = 1.0
    default:
        if let state { value["state"] = state }
    }
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
try Data().write(to: evidenceDirectory.appendingPathComponent(
    "localization_recovery_events.jsonl"))
try Data("[]".utf8).write(to: evidenceDirectory.appendingPathComponent(
    "localized_price_tags.json"))
let initialEvidenceBlockers = LocalizationEvidenceBundleValidator.blockers(
    in: evidenceDirectory,
    expectation: evidenceExpectation)
require(
    initialEvidenceBlockers.isEmpty,
    "a complete persisted evidence bundle must validate: \(initialEvidenceBlockers)")

// P7R5: a valid terminal Recovery lifecycle record validates through the
// uptime-based branch; an identity mismatch fails closed.
let recoveryEvidenceURL = evidenceDirectory.appendingPathComponent(
    "localization_recovery_events.jsonl")
let recoveryLifecycleRecord: [String: Any] = [
    "format": "MarketScannerRecoveryLifecycleEvent",
    "version": 1,
    "tracking_session_id": "session-a",
    "prior_map_id": "map-a",
    "prior_map_sha256": String(repeating: "a", count: 64),
    "floor_id": "1",
    "episode_id": 1,
    "reason": "reliable_rtabmap_loop",
    "outcome": "cancelled",
    "cancellation_reason": "scan_stopped",
    "episode_automatic": false,
    "started_at_uptime": 10.0,
    "finished_at_uptime": 14.5,
    "elapsed_ms": 4500.0,
    "valid_matcher_attempts": 7,
    "accepted_corrections": 2,
    "trigger_count": 1,
    "automatic_trigger_count": 0,
    "reliable_loop_trigger_count": 1,
    "last_trigger_reason": "reliable_rtabmap_loop",
    "last_trigger_at_uptime": 10.0,
    "fresh_support_frames": 4,
    "completion_frame_step_applied": false,
]
var recoveryLifecycleData = try JSONSerialization.data(
    withJSONObject: recoveryLifecycleRecord)
recoveryLifecycleData.append(0x0A)
try recoveryLifecycleData.write(to: recoveryEvidenceURL)
require(
    LocalizationEvidenceBundleValidator.blockers(
        in: evidenceDirectory,
        expectation: evidenceExpectation).isEmpty,
    "a valid recovery lifecycle record must validate")
var corruptedRecoveryRecord = recoveryLifecycleRecord
corruptedRecoveryRecord["tracking_session_id"] = "session-other"
var corruptedRecoveryData = try JSONSerialization.data(
    withJSONObject: corruptedRecoveryRecord)
corruptedRecoveryData.append(0x0A)
try corruptedRecoveryData.write(to: recoveryEvidenceURL)
require(
    LocalizationEvidenceBundleValidator.blockers(
        in: evidenceDirectory,
        expectation: evidenceExpectation).contains(
            "evidence_bundle_localization_recovery_events.jsonl_identity_mismatch"),
    "a recovery lifecycle identity mismatch must fail closed")
try Data().write(to: recoveryEvidenceURL)

let localizedTagsURL = evidenceDirectory.appendingPathComponent(
    "localized_price_tags.json")
try Data(repeating: 0x20, count: 16 * 1024 * 1024 + 1).write(to: localizedTagsURL)
require(
    LocalizationEvidenceBundleValidator.blockers(
        in: evidenceDirectory,
        expectation: evidenceExpectation).contains {
            $0.contains("localized_price_tags")
        },
    "the V1 production localized-tag memory budget must fail closed")
try Data("[]".utf8).write(to: localizedTagsURL)

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

try Data([0xFF, 0x0A]).write(to: traceEvidenceURL)
require(
    LocalizationEvidenceBundleValidator.blockers(
        in: evidenceDirectory,
        expectation: evidenceExpectation).contains {
            $0.contains("invalid_utf8_or_partial_line")
        },
    "invalid UTF-8 must block finalization")
try originalTrace.write(to: traceEvidenceURL)
var oversizedRecord = Data(repeating: 0x61, count: 1_000_001)
oversizedRecord.append(0x0A)
try oversizedRecord.write(to: traceEvidenceURL)
require(
    LocalizationEvidenceBundleValidator.blockers(
        in: evidenceDirectory,
        expectation: evidenceExpectation).contains {
            $0.contains("record_too_large")
        },
    "a record over 1 MB must block finalization")
try originalTrace.write(to: traceEvidenceURL)

let replacementDirectory = finalizationTemp.appendingPathComponent(
    "descriptor-replacement",
    isDirectory: true)
try FileManager.default.createDirectory(
    at: replacementDirectory,
    withIntermediateDirectories: true)
let replacementTarget = replacementDirectory.appendingPathComponent("target.jsonl")
let replacementCandidate = replacementDirectory.appendingPathComponent("new.jsonl")
try Data(repeating: 0x31, count: 128 * 1024).write(to: replacementTarget)
try Data("replacement\n".utf8).write(to: replacementCandidate)
var replacementRejected = false
var replaced = false
do {
    try SafeSessionPath.streamRegularFile(
        replacementTarget,
        within: finalizationTemp,
        maximumBytes: 1024 * 1024,
        chunkBytes: 4096
    ) { _ in
        if !replaced {
            replaced = true
            try FileManager.default.removeItem(at: replacementTarget)
            try FileManager.default.moveItem(
                at: replacementCandidate,
                to: replacementTarget)
        }
    }
}
catch {
    replacementRejected = true
}
require(replacementRejected, "a path inode replacement during streaming must fail closed")

let longEvidenceDirectory = finalizationTemp.appendingPathComponent(
    "evidence-100k",
    isDirectory: true)
try FileManager.default.createDirectory(
    at: longEvidenceDirectory,
    withIntermediateDirectories: true)
let longRecordCount = 100_000
let longMapHash = String(repeating: "b", count: 64)
func writeLongEvidence(
    _ fileName: String,
    format: String,
    recordBody: (Int) -> String
) throws {
    let url = longEvidenceDirectory.appendingPathComponent(fileName)
    FileManager.default.createFile(atPath: url.path, contents: nil)
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    var batch = Data()
    batch.reserveCapacity(1024 * 1024)
    for index in 1...longRecordCount {
        let identity = "\"format\":\"\(format)\",\"version\":1,"
            + "\"trackingSessionId\":\"session-long\","
            + "\"priorMapId\":\"map-long\","
            + "\"priorMapSha256\":\"\(longMapHash)\","
            + "\"floorId\":\"1\","
        batch.append(contentsOf: ("{" + identity + recordBody(index) + "}\n").utf8)
        if batch.count >= 1024 * 1024 {
            try handle.write(contentsOf: batch)
            batch.removeAll(keepingCapacity: true)
        }
    }
    if !batch.isEmpty { try handle.write(contentsOf: batch) }
    try handle.synchronize()
}
let poseJSON = "{\"x_m\":0,\"y_m\":0,\"yaw_rad\":0}"
try writeLongEvidence(
    "localization_trace.jsonl",
    format: "MarketScannerLocalizationTrace"
) { index in
    return "\"timestamp\":\(index),\"nodeTimebaseTimestamp\":\(index),"
        + "\"nodeTimebaseOffsetSeconds\":0,\"rawPose\":\(poseJSON),"
        + "\"estimatedPose\":\(poseJSON),\"trackingState\":\"normal\","
        + "\"localizationState\":\"stable\",\"confidence\":1"
}
try writeLongEvidence(
    "localization_constraints.jsonl",
    format: "MarketScannerLocalizationConstraint"
) { index in
    return "\"timestamp\":\(index),\"nodeTimebaseTimestamp\":\(index),"
        + "\"nodeTimebaseOffsetSeconds\":0,\"accepted\":false,"
        + "\"predictedPose\":\(poseJSON),\"uniqueness\":0.9"
}
try writeLongEvidence(
    "localization_events.jsonl",
    format: "MarketScannerLocalizationStateEvent"
) { index in
    return "\"timestamp\":\(index),\"nodeTimebaseTimestamp\":\(index),"
        + "\"nodeTimebaseOffsetSeconds\":0,\"state\":\"stable\","
        + "\"confidence\":1"
}
try Data().write(to: longEvidenceDirectory.appendingPathComponent(
    "manual_localization_events.jsonl"))
try Data().write(to: longEvidenceDirectory.appendingPathComponent(
    "tag_observations.jsonl"))
try Data().write(to: longEvidenceDirectory.appendingPathComponent(
    "localization_recovery_events.jsonl"))
try Data("[]".utf8).write(to: longEvidenceDirectory.appendingPathComponent(
    "localized_price_tags.json"))
let longExpectation = LocalizationEvidenceBundleExpectation(
    trackingSessionId: "session-long",
    priorMapId: "map-long",
    priorMapSha256: longMapHash,
    floorId: "1",
    traceRecordCount: longRecordCount,
    constraintRecordCount: longRecordCount,
    stateEventCount: longRecordCount,
    lastDurableState: "stable",
    localizedPriceTagCount: 0)
let longEvidenceBlockers = LocalizationEvidenceBundleValidator.blockers(
    in: longEvidenceDirectory,
    expectation: longExpectation)
require(
    longEvidenceBlockers.isEmpty,
    "100k trace/constraint/state records must validate: \(longEvidenceBlockers)")

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
    observation: PriorMapConfidenceObservation(
        trackingState: "normal",
        measurementAccepted: false,
        correctionStepApplied: false,
        recoveryActive: false,
        recoveryConvergedThisUpdate: false,
        recoveryFailedThisUpdate: false,
        validPointCount: 0,
        coverageAngleRad: 0,
        uniqueness: 0,
        residualCost: 0.15,
        mapMismatch: false))
require(initializing.phase == .initializing, "first unmatched frame must stay initializing")
confidenceManager.reset()
for timestamp in 1...3 {
    _ = confidenceManager.update(
        timestamp: Double(timestamp),
        observation: PriorMapConfidenceObservation(
            trackingState: "normal",
            measurementAccepted: true,
            correctionStepApplied: true,
            recoveryActive: false,
            recoveryConvergedThisUpdate: false,
            recoveryFailedThisUpdate: false,
            validPointCount: 100,
            coverageAngleRad: 1.2,
            uniqueness: 0.3,
            residualCost: 0.02,
            mapMismatch: false))
}
require(confidenceManager.phase == .stable, "three trusted observations must enter stable")
let weak = confidenceManager.update(
    timestamp: 4,
    observation: PriorMapConfidenceObservation(
        trackingState: "limited",
        measurementAccepted: false,
        correctionStepApplied: false,
        recoveryActive: false,
        recoveryConvergedThisUpdate: false,
        recoveryFailedThisUpdate: false,
        validPointCount: 40,
        coverageAngleRad: 0.2,
        uniqueness: 0,
        residualCost: 0.15,
        mapMismatch: false))
require(weak.phase == .weak, "limited tracking must degrade to weak")

func requirePoseClose(
    _ actual: PriorMapPose2D,
    _ expected: PriorMapPose2D,
    _ message: String
) {
    require(close(actual.xM, expected.xM), "\(message) x")
    require(close(actual.yM, expected.yM), "\(message) y")
    require(
        close(
            PriorMapStageOneMath.normalizeAngle(actual.yawRad - expected.yawRad),
            0),
        "\(message) yaw")
}

func requireAlignmentReconstruction(
    arkitPose: PriorMapPose2D,
    expectedMapFromArkit: PriorMapAlignmentTransform,
    _ message: String
) {
    let candidate = PriorMapAlignmentMath.apply(
        mapFromArkit: expectedMapFromArkit,
        arkitPose: arkitPose)
    let derived = PriorMapAlignmentMath.mapFromArkit(
        arkitPose: arkitPose,
        candidateMapPose: candidate)
    let reconstructed = PriorMapAlignmentMath.apply(
        mapFromArkit: derived,
        arkitPose: arkitPose)
    requirePoseClose(reconstructed, candidate, message)
    require(close(derived.translationXM, expectedMapFromArkit.translationXM), "\(message) tx")
    require(close(derived.translationYM, expectedMapFromArkit.translationYM), "\(message) ty")
    require(
        close(
            PriorMapStageOneMath.normalizeAngle(
                derived.yawRad - expectedMapFromArkit.yawRad),
            0),
        "\(message) alignment yaw")
}

// P7R2 T1-T6: exact SE(2) reconstruction across identity, translation,
// quarter-turn, combined motion, half-turn and the +/-pi wrap boundary.
requireAlignmentReconstruction(
    arkitPose: PriorMapPose2D(xM: 0, yM: 0, yawRad: 0),
    expectedMapFromArkit: PriorMapAlignmentTransform(
        translationXM: 0, translationYM: 0, yawRad: 0),
    "T1 identity")
requireAlignmentReconstruction(
    arkitPose: PriorMapPose2D(xM: 2, yM: -3, yawRad: 0),
    expectedMapFromArkit: PriorMapAlignmentTransform(
        translationXM: 4, translationYM: 1, yawRad: 0),
    "T2 translation at zero yaw")
requireAlignmentReconstruction(
    arkitPose: PriorMapPose2D(xM: 2, yM: -3, yawRad: .pi / 2),
    expectedMapFromArkit: PriorMapAlignmentTransform(
        translationXM: 4, translationYM: 1, yawRad: 0),
    "T2 translation at ninety degrees")
requireAlignmentReconstruction(
    arkitPose: PriorMapPose2D(xM: 3, yM: 2, yawRad: 0),
    expectedMapFromArkit: PriorMapAlignmentTransform(
        translationXM: 8, translationYM: -2, yawRad: .pi / 2),
    "T3 zero to ninety degree alignment")
requireAlignmentReconstruction(
    arkitPose: PriorMapPose2D(xM: -2.5, yM: 7.25, yawRad: -.pi / 3),
    expectedMapFromArkit: PriorMapAlignmentTransform(
        translationXM: 12.5, translationYM: -8.75, yawRad: .pi / 4),
    "T4 turn and translation")
requireAlignmentReconstruction(
    arkitPose: PriorMapPose2D(xM: 5, yM: 9, yawRad: .pi),
    expectedMapFromArkit: PriorMapAlignmentTransform(
        translationXM: -4, translationYM: 6, yawRad: .pi),
    "T5 one hundred eighty degrees")
requireAlignmentReconstruction(
    arkitPose: PriorMapPose2D(xM: 1, yM: 1, yawRad: .pi - 1.0e-10),
    expectedMapFromArkit: PriorMapAlignmentTransform(
        translationXM: 2, translationYM: 3, yawRad: -.pi + 2.0e-10),
    "T6 angle wrap")

let fixedAlignment = PriorMapAlignmentTransform(
    translationXM: 2.4,
    translationYM: -1.3,
    yawRad: 18.0 * .pi / 180.0)
let wrongAisleAlignment = PriorMapAlignmentTransform(
    translationXM: 2.4,
    translationYM: 1.7,
    yawRad: 18.0 * .pi / 180.0)
let hypothesisTracker = PriorMapHypothesisTracker()
func productionMatcherScore(_ cost: Double) -> Double {
    exp(-cost / 0.08)
}
var trackedDecision: PriorMapHypothesisDecision?
let serpentineArkitPoses = [
    PriorMapPose2D(xM: 0, yM: 0, yawRad: 0),
    PriorMapPose2D(xM: 1, yM: 0, yawRad: 0),
    PriorMapPose2D(xM: 2, yM: 0.5, yawRad: .pi / 4),
    PriorMapPose2D(xM: 2, yM: 1.5, yawRad: .pi / 2),
    PriorMapPose2D(xM: 1.5, yM: 2.5, yawRad: 3 * .pi / 4),
]
for (frame, arkitPose) in serpentineArkitPoses.enumerated() {
    let correct = PriorMapAlignmentMath.apply(
        mapFromArkit: fixedAlignment,
        arkitPose: arkitPose)
    let wrong = PriorMapAlignmentMath.apply(
        mapFromArkit: wrongAisleAlignment,
        arkitPose: arkitPose)
    // T8: during the turn, a fresh wrong aisle may have the higher frame
    // score, but it must not steal the established global-alignment track.
    let wrongCost = frame == 2 ? 0.005 : 0.055
    let correctCost = 0.02
    trackedDecision = hypothesisTracker.observe(
        arkitPose: arkitPose,
        candidates: [
            PriorMapScanMatchCandidate(
                pose: wrong,
                cost: wrongCost,
                score: productionMatcherScore(wrongCost)),
            PriorMapScanMatchCandidate(
                pose: correct,
                cost: correctCost,
                score: productionMatcherScore(correctCost)),
        ],
        uniqueness: 0.25,
        recoverySearch: false)
}
guard let serpentineDecision = trackedDecision,
      let trackedAlignment = serpentineDecision.mapFromArkit else {
    require(false, "S1 must retain a global-alignment hypothesis")
    exit(1)
}
require(serpentineDecision.trusted, "S1 serpentine alignment must become trusted")
require(serpentineDecision.supportFrames == serpentineArkitPoses.count,
        "S1 turns must not split the correct track")
require(close(trackedAlignment.translationXM, fixedAlignment.translationXM),
        "T8 wrong high-score aisle must not replace tx")
require(close(trackedAlignment.translationYM, fixedAlignment.translationYM),
        "T8 wrong high-score aisle must not replace ty")

// S4: short dynamic occlusion produces no candidates; the bounded tracker may
// retain history but cannot authorize a correction until evidence returns.
let occludedOne = hypothesisTracker.observe(
    arkitPose: serpentineArkitPoses.last!,
    candidates: [], uniqueness: 0, recoverySearch: false)
let occludedTwo = hypothesisTracker.observe(
    arkitPose: serpentineArkitPoses.last!,
    candidates: [], uniqueness: 0, recoverySearch: false)
require(!occludedOne.trusted && !occludedTwo.trusted,
        "S4 occlusion must fail closed")
let returnedPose = PriorMapPose2D(xM: 1, yM: 3, yawRad: .pi)
let returnedCandidate = PriorMapAlignmentMath.apply(
    mapFromArkit: fixedAlignment,
    arkitPose: returnedPose)
let afterOcclusion = hypothesisTracker.observe(
    arkitPose: returnedPose,
    candidates: [PriorMapScanMatchCandidate(
        pose: returnedCandidate,
        cost: 0.02,
        score: productionMatcherScore(0.02))],
    uniqueness: 0.3,
    recoverySearch: false)
require(afterOcclusion.trusted, "S4 stable evidence may resume the retained track")

// T9: equal parallel hypotheses remain ambiguous regardless of support.
hypothesisTracker.reset()
var ambiguousDecision: PriorMapHypothesisDecision?
let parallelA = PriorMapAlignmentTransform(
    translationXM: 0.3, translationYM: -0.6, yawRad: 0)
let parallelB = PriorMapAlignmentTransform(
    translationXM: 0.3, translationYM: 0.6, yawRad: 0)
for frame in 0..<4 {
    let arkitPose = PriorMapPose2D(xM: Double(frame), yM: 0, yawRad: 0)
    ambiguousDecision = hypothesisTracker.observe(
        arkitPose: arkitPose,
        candidates: [parallelA, parallelB].map {
            PriorMapScanMatchCandidate(
                pose: PriorMapAlignmentMath.apply(
                    mapFromArkit: $0, arkitPose: arkitPose),
                cost: 0.02,
                score: productionMatcherScore(0.02))
        },
        uniqueness: 0,
        recoverySearch: false)
}
require(ambiguousDecision?.trusted == false,
        "T9 equal parallel aisles must never silently switch")
require(ambiguousDecision?.activeTrackCount == 2,
        "T9 both ambiguous tracks must remain visible in diagnostics")

// T10/S2: unique recovery needs four frames; 5 m/30 degrees is inclusive,
// while either 5.01 m or 30.1 degrees is rejected by the safety contract.
hypothesisTracker.reset()
hypothesisTracker.beginRecoveryEpisode(id: 1)
let recoveryAlignment = PriorMapAlignmentTransform(
    translationXM: 4.8,
    translationYM: 0,
    yawRad: 29.0 * .pi / 180.0)
var recoveryDecision: PriorMapHypothesisDecision?
for frame in 0..<4 {
    let arkitPose = PriorMapPose2D(xM: Double(frame), yM: 0, yawRad: 0)
    recoveryDecision = hypothesisTracker.observe(
        arkitPose: arkitPose,
        candidates: [PriorMapScanMatchCandidate(
            pose: PriorMapAlignmentMath.apply(
                mapFromArkit: recoveryAlignment, arkitPose: arkitPose),
            cost: 0.02,
            score: productionMatcherScore(0.02))],
        uniqueness: 0.8,
        recoverySearch: true)
}
require(recoveryDecision?.trusted == true && recoveryDecision?.supportFrames == 4,
        "S2 unique recovery must require and pass four consistent frames")
hypothesisTracker.endRecoveryEpisode(id: 1, outcome: .converged)
let safetyOrigin = PriorMapPose2D(xM: 0, yM: 0, yawRad: 0)
require(PriorMapCorrectionSafety.isWithinGate(
    current: safetyOrigin,
    target: PriorMapPose2D(xM: 5, yM: 0, yawRad: 30 * .pi / 180),
    recoverySearch: true), "T10 inclusive recovery boundary")
require(!PriorMapCorrectionSafety.isWithinGate(
    current: safetyOrigin,
    target: PriorMapPose2D(xM: 5.01, yM: 0, yawRad: 0),
    recoverySearch: true), "T10 reject 5.01 m")
require(!PriorMapCorrectionSafety.isWithinGate(
    current: safetyOrigin,
    target: PriorMapPose2D(xM: 5, yM: 0, yawRad: 30.1 * .pi / 180),
    recoverySearch: true), "T10 reject 30.1 degrees")
let boundedRecoveryStep = PriorMapCorrectionSafety.boundedStep(
    current: safetyOrigin,
    target: PriorMapPose2D(xM: 4.8, yM: 0, yawRad: 29 * .pi / 180))
require(close(boundedRecoveryStep.xM, 0.35), "S2 recovery step translation cap")
require(close(boundedRecoveryStep.yawRad, 8 * .pi / 180),
        "S2 recovery step yaw cap")

// Reset (the same operation used by manual confirmation) clears track history.
hypothesisTracker.reset()
let postReset = hypothesisTracker.observe(
    arkitPose: safetyOrigin,
    candidates: [PriorMapScanMatchCandidate(
        pose: PriorMapPose2D(xM: 0.2, yM: 0, yawRad: 0),
        cost: 0.02,
        score: productionMatcherScore(0.02))],
    uniqueness: 0.5,
    recoverySearch: false)
require(!postReset.trusted && postReset.supportFrames == 1,
        "manual reset must require fresh temporal support")

// P7R3 R1: lifetime local support is discarded at episode start. The same
// alignment must earn four new observations before Recovery can trust it.
let staleAlignment = PriorMapAlignmentTransform(
    translationXM: 1.5, translationYM: -2.0, yawRad: 0.1)
hypothesisTracker.reset()
for frame in 0..<100 {
    let arkitPose = PriorMapPose2D(xM: Double(frame) * 0.05, yM: 0, yawRad: 0)
    let candidate = PriorMapAlignmentMath.apply(
        mapFromArkit: staleAlignment, arkitPose: arkitPose)
    _ = hypothesisTracker.observe(
        arkitPose: arkitPose,
        candidates: [PriorMapScanMatchCandidate(
            pose: candidate,
            cost: 0.02,
            score: productionMatcherScore(0.02))],
        uniqueness: 0.5,
        recoverySearch: false)
}
hypothesisTracker.beginRecoveryEpisode(id: 41)
var freshRecoveryDecision: PriorMapHypothesisDecision?
for frame in 1...4 {
    let arkitPose = PriorMapPose2D(xM: Double(frame), yM: 0, yawRad: 0)
    let candidate = PriorMapAlignmentMath.apply(
        mapFromArkit: staleAlignment, arkitPose: arkitPose)
    freshRecoveryDecision = hypothesisTracker.observe(
        arkitPose: arkitPose,
        candidates: [PriorMapScanMatchCandidate(
            pose: candidate,
            cost: 0.02,
            score: productionMatcherScore(0.02))],
        uniqueness: 0.5,
        recoverySearch: true)
    require(
        freshRecoveryDecision?.trusted == (frame == 4),
        "R1 Recovery trust must use exactly four fresh episode observations")
    require(
        freshRecoveryDecision?.supportFrames == frame,
        "R1 historical local support must not enter Recovery diagnostics")
}

// P7R3 R2: after local A has saturated support, a new episode ranks only its
// fresh evidence. Better B wins on the fourth Recovery observation.
hypothesisTracker.endRecoveryEpisode(id: 41, outcome: .cancelled)
let wrongHistoricalAlignment = PriorMapAlignmentTransform(
    translationXM: 0, translationYM: 3, yawRad: 0)
let correctRecoveryAlignment = PriorMapAlignmentTransform(
    translationXM: 0.2, translationYM: 0.1, yawRad: 0)
for frame in 0..<100 {
    let arkitPose = PriorMapPose2D(xM: Double(frame) * 0.02, yM: 0, yawRad: 0)
    let candidate = PriorMapAlignmentMath.apply(
        mapFromArkit: wrongHistoricalAlignment, arkitPose: arkitPose)
    _ = hypothesisTracker.observe(
        arkitPose: arkitPose,
        candidates: [PriorMapScanMatchCandidate(
            pose: candidate,
            cost: 0.04,
            score: productionMatcherScore(0.04))],
        uniqueness: 0.4,
        recoverySearch: false)
}
hypothesisTracker.beginRecoveryEpisode(id: 42)
var replacementDecision: PriorMapHypothesisDecision?
for frame in 0..<4 {
    let arkitPose = PriorMapPose2D(xM: Double(frame), yM: 0, yawRad: 0)
    replacementDecision = hypothesisTracker.observe(
        arkitPose: arkitPose,
        candidates: [
            PriorMapScanMatchCandidate(
                pose: PriorMapAlignmentMath.apply(
                    mapFromArkit: wrongHistoricalAlignment,
                    arkitPose: arkitPose),
                cost: 0.05,
                score: productionMatcherScore(0.05)),
            PriorMapScanMatchCandidate(
                pose: PriorMapAlignmentMath.apply(
                    mapFromArkit: correctRecoveryAlignment,
                    arkitPose: arkitPose),
                cost: 0.01,
                score: productionMatcherScore(0.01)),
        ],
        uniqueness: 0.5,
        recoverySearch: true)
}
require(replacementDecision?.trusted == true,
        "R2 the replacement hypothesis must become trusted on fresh frame four")
requirePoseClose(
    replacementDecision!.candidate!.pose,
    PriorMapAlignmentMath.apply(
        mapFromArkit: correctRecoveryAlignment,
        arkitPose: PriorMapPose2D(xM: 3, yM: 0, yawRad: 0)),
    "R2 stale historical A must not suppress better Recovery B")

// P7R3 R3-R5: only real matcher searches consume the bounded attempt budget,
// and a repeated trigger preserves identity, deadline, attempts, and support.
let recoveryController = PriorMapRecoveryController(
    maximumValidAttempts: 40,
    maximumWallClockSeconds: 30)
require(recoveryController.request(reason: "loop", now: 100),
        "R3 first request must start an episode")
let initialRecoveryEpisode = recoveryController.activeEpisode!
let invalidRecoveryDispositions: [PriorMapRecoveryFrameDisposition] = [
    .trackingLimited,
    .noDepth,
    .observationUnavailable,
    .insufficientPoints,
    .busy,
    .throttled,
]
for frame in 0..<20 {
    require(
        !recoveryController.recordFrameDisposition(
            invalidRecoveryDispositions[
                frame % invalidRecoveryDispositions.count]),
        "R3 invalid/dropped frames must not be recorded as searches")
}
require(recoveryController.activeEpisode?.validMatcherAttempts == 0,
        "R3 invalid frames must not consume attempts")
recoveryController.recordValidMatcherAttempt()
recoveryController.recordValidMatcherAttempt()
require(!recoveryController.request(reason: "another_loop", now: 110),
        "R5 repeated request must not create an episode")
require(recoveryController.activeEpisode?.id == initialRecoveryEpisode.id,
        "R5 repeated request must preserve episode ID")
require(recoveryController.activeEpisode?.deadlineUptime
        == initialRecoveryEpisode.deadlineUptime,
        "R5 repeated request must not extend the deadline")
require(recoveryController.activeEpisode?.validMatcherAttempts == 2,
        "R4/R5 valid attempt progress must survive a repeated trigger")
require(recoveryController.activeEpisode?.triggerCount == 2,
        "R5 repeated trigger must be bounded diagnostic evidence")

// P7R3 R6/R7/R10: every exit clears wide-search tracks. The selected map
// alignment is retained by the localizer anchor, never by a temporary track.
hypothesisTracker.endRecoveryEpisode(id: 42, outcome: .timedOut)
let localAfterTimeout = hypothesisTracker.observe(
    arkitPose: safetyOrigin,
    candidates: [PriorMapScanMatchCandidate(
        pose: PriorMapAlignmentMath.apply(
            mapFromArkit: correctRecoveryAlignment,
            arkitPose: safetyOrigin),
        cost: 0.01,
        score: productionMatcherScore(0.01))],
    uniqueness: 0.5,
    recoverySearch: false)
require(!localAfterTimeout.trusted && localAfterTimeout.supportFrames == 1,
        "R6 local mode must not inherit a timed-out wide-search track")
_ = recoveryController.finish(.manualReset, now: 112)
require(recoveryController.activeEpisode == nil,
        "R10 manual reset must terminate the active episode")

// P7R3 R8: the inclusive 5 m/30 degree boundary converges within the 40 valid
// attempt budget, while inserted nil-observation frames consume nothing.
let worstPathController = PriorMapRecoveryController(
    maximumValidAttempts: 40,
    maximumWallClockSeconds: 30)
_ = worstPathController.request(reason: "worst_path", now: 200)
var boundedPose = PriorMapPose2D(xM: 0, yM: 0, yawRad: 0)
let worstTarget = PriorMapPose2D(
    xM: 5, yM: 0, yawRad: 30 * .pi / 180)
var maximumStepTranslation = 0.0
var maximumStepYaw = 0.0
for validAttempt in 1...40 {
    if validAttempt % 3 == 0 {
        require(
            !worstPathController.recordFrameDisposition(
                .observationUnavailable),
            "R8 an intervening nil observation must not consume an attempt")
    }
    worstPathController.recordFrameDisposition(.searched)
    if validAttempt >= 4 {
        let next = PriorMapCorrectionSafety.boundedStep(
            current: boundedPose, target: worstTarget)
        let step = PriorMapCorrectionSafety.difference(
            from: boundedPose, to: next)
        maximumStepTranslation = max(maximumStepTranslation, step.translationM)
        maximumStepYaw = max(maximumStepYaw, step.yawRad)
        boundedPose = next
        let residual = PriorMapCorrectionSafety.difference(
            from: boundedPose, to: worstTarget)
        if residual.translationM <= 0.5,
           residual.yawRad <= 10 * .pi / 180 {
            worstPathController.recordAcceptedCorrection()
            _ = worstPathController.finish(.converged, now: 220)
            break
        }
    }
}
require(worstPathController.lastCompletion?.outcome == .converged,
        "R8 worst-path Recovery must converge within the valid-attempt budget")
require((worstPathController.lastCompletion?.episode.validMatcherAttempts ?? 41) <= 40,
        "R8 convergence must remain inside the configured budget")
require(maximumStepTranslation <= 0.35 + 1.0e-9,
        "R8 no Recovery translation step may exceed 0.35 m")
require(maximumStepYaw <= 8 * .pi / 180 + 1.0e-9,
        "R8 no Recovery yaw step may exceed 8 degrees")

// P7R4 T1/T2: accepting a 5 m Recovery hypothesis applies only a bounded,
// provisional step. It cannot become confidence-bearing or formally accepted.
let intermediateRecovery = PriorMapRecoveryDecisionEngine.evaluate(
    PriorMapRecoveryDecisionInput(
        recoveryActive: true,
        hypothesisTrusted: true,
        geometryAndSafetyAccepted: true,
        residualTranslationM: 5,
        residualYawRad: 30 * .pi / 180,
        wallClockExpired: false))
require(intermediateRecovery.measurementAccepted,
        "P7R4 T1 trusted Recovery measurement must remain observable")
require(intermediateRecovery.correctionStepApplied,
        "P7R4 T1 one bounded Recovery step may be applied")
require(!intermediateRecovery.recoveryConvergedThisUpdate,
        "P7R4 T1 a 5 m residual cannot be converged")
require(!intermediateRecovery.confidenceAccepted,
        "P7R4 T1 an intermediate Recovery step cannot raise confidence")
require(intermediateRecovery.constraintDisposition == .provisionalRecoveryStep,
        "P7R4 T1 an intermediate step must be provisional")

let recoveryConfidence = PriorMapConfidenceManager()
recoveryConfidence.reset()
for timestamp in 1...10 {
    let result = recoveryConfidence.update(
        timestamp: Double(timestamp),
        observation: PriorMapConfidenceObservation(
            trackingState: "normal",
            measurementAccepted: true,
            correctionStepApplied: true,
            recoveryActive: true,
            recoveryConvergedThisUpdate: false,
            recoveryFailedThisUpdate: false,
            validPointCount: 120,
            coverageAngleRad: 1.4,
            uniqueness: 0.5,
            residualCost: 0.01,
            mapMismatch: false))
    require(result.phase == .recovering,
            "P7R4 T2 every intermediate step must remain recovering")
    require(result.confidence <= 0.55,
            "P7R4 T2 Recovery confidence must stay capped")
}

// P7R4 T3/T4: convergence is at most usable, followed by three ordinary
// trusted Local observations; any rejection resets that post-Recovery gate.
let convergedRecovery = PriorMapRecoveryDecisionEngine.evaluate(
    PriorMapRecoveryDecisionInput(
        recoveryActive: true,
        hypothesisTrusted: true,
        geometryAndSafetyAccepted: true,
        residualTranslationM: 0.5,
        residualYawRad: 10 * .pi / 180,
        wallClockExpired: false))
require(convergedRecovery.recoveryConvergedThisUpdate,
        "P7R4 T3 inclusive convergence thresholds must converge")
let convergenceConfidence = recoveryConfidence.update(
    timestamp: 11,
    observation: PriorMapConfidenceObservation(
        trackingState: "normal",
        measurementAccepted: true,
        correctionStepApplied: true,
        recoveryActive: false,
        recoveryConvergedThisUpdate: true,
        recoveryFailedThisUpdate: false,
        validPointCount: 120,
        coverageAngleRad: 1.4,
        uniqueness: 0.5,
        residualCost: 0.01,
        mapMismatch: false))
require(convergenceConfidence.phase == .usable,
        "P7R4 T3 convergence frame must not be stable")

func trustedLocalObservation(_ accepted: Bool = true) -> PriorMapConfidenceObservation {
    PriorMapConfidenceObservation(
        trackingState: "normal",
        measurementAccepted: accepted,
        correctionStepApplied: accepted,
        recoveryActive: false,
        recoveryConvergedThisUpdate: false,
        recoveryFailedThisUpdate: false,
        validPointCount: accepted ? 120 : 0,
        coverageAngleRad: accepted ? 1.4 : 0,
        uniqueness: accepted ? 0.5 : 0,
        residualCost: accepted ? 0.01 : 0.15,
        mapMismatch: false)
}
_ = recoveryConfidence.update(
    timestamp: 12, observation: trustedLocalObservation())
_ = recoveryConfidence.update(
    timestamp: 13, observation: trustedLocalObservation())
let rejectedPostRecovery = recoveryConfidence.update(
    timestamp: 14, observation: trustedLocalObservation(false))
require(rejectedPostRecovery.phase != .stable
        && recoveryConfidence.postRecoveryTrustedLocalFrames == 0,
        "P7R4 T4 rejection must reset post-Recovery Local trust")
for timestamp in 15...16 {
    let result = recoveryConfidence.update(
        timestamp: Double(timestamp), observation: trustedLocalObservation())
    require(result.phase != .stable,
            "P7R4 T4 fewer than three fresh Local frames cannot be stable")
}
let stableAfterRecovery = recoveryConfidence.update(
    timestamp: 17, observation: trustedLocalObservation())
require(stableAfterRecovery.phase == .stable,
        "P7R4 T4 three consecutive ordinary Local frames may restore stable")

final class FakeMonotonicClock: PriorMapMonotonicClock {
    var now: TimeInterval
    init(_ now: TimeInterval) { self.now = now }
}

func recoveryUpdateInput(
    timestamp: TimeInterval,
    preMatchNow: TimeInterval,
    postMatchNow: TimeInterval,
    recoveryActive: Bool,
    disposition: PriorMapRecoveryFrameDisposition,
    trusted: Bool = false,
    geometryAccepted: Bool = false,
    residualTranslationM: Double = 0,
    residualYawRad: Double = 0,
    pendingCompletion: PriorMapRecoveryOutcome? = nil
) -> PriorMapRecoveryUpdateInput {
    PriorMapRecoveryUpdateInput(
        timestamp: timestamp,
        preMatchNow: preMatchNow,
        postMatchNow: postMatchNow,
        recoveryWasActiveAtUpdateStart: recoveryActive,
        recoveryActiveForMatch: recoveryActive,
        pendingCompletionOutcome: pendingCompletion,
        frameDisposition: disposition,
        hypothesisTrusted: trusted,
        geometryAndSafetyAccepted: geometryAccepted,
        residualTranslationM: residualTranslationM,
        residualYawRad: residualYawRad,
        trackingState: "normal",
        validPointCount: trusted ? 120 : 0,
        coverageAngleRad: trusted ? 1.4 : 0,
        uniqueness: trusted ? 0.5 : 0,
        residualCost: trusted ? 0.01 : 0.15,
        mapMismatch: false)
}

// P7R4 T5: a safe final-attempt step remains provisional when the episode
// times out; immutable completion evidence preserves the episode hypothesis.
let finalAttemptController = PriorMapRecoveryController(
    maximumValidAttempts: 40,
    maximumWallClockSeconds: 30)
_ = finalAttemptController.request(reason: "persistent_weak_or_lost", now: 0,
                                   automatic: true)
for _ in 0..<39 { finalAttemptController.recordFrameDisposition(.searched) }
let finalAttemptConfidence = PriorMapConfidenceManager()
finalAttemptConfidence.reset()
let finalAttemptUpdate = PriorMapRecoveryUpdateReducer.reduce(
    recoveryUpdateInput(
        timestamp: 10,
        preMatchNow: 10,
        postMatchNow: 10,
        recoveryActive: true,
        disposition: .searched,
        trusted: true,
        geometryAccepted: true,
        residualTranslationM: 4.2,
        residualYawRad: 0.2),
    recoveryController: finalAttemptController,
    confidenceManager: finalAttemptConfidence)
require(finalAttemptController.activeEpisode?.validMatcherAttempts == 40,
        "P7R4 T5 the production reducer must record attempt 40/40")
require(finalAttemptUpdate.action == .timedOut
        && finalAttemptUpdate.decision.correctionStepApplied,
        "P7R4 T5 attempt 40 may retain one safe step but must time out")
require(!finalAttemptUpdate.decision.confidenceAccepted
        && !finalAttemptUpdate.finalConstraintAccepted
        && finalAttemptUpdate.decision.constraintDisposition
            == .provisionalRecoveryStep,
        "P7R4 T5 the final step must remain provisional and non-confidence-bearing")
require(finalAttemptUpdate.nextConfidence.phase == .weak
        && finalAttemptUpdate.reason.contains("timed_out"),
        "P7R4 T5 timeout must emit weak phase and explicit timed_out diagnostics")
let finalAttemptCompletion = finalAttemptController.finish(
    .timedOut,
    now: 10,
    selectedHypothesisId: 77,
    finalFreshSupportFrames: 4,
    finalResidualTranslationM: 4.2,
    finalResidualYawRad: 0.2,
    correctionStepAppliedOnCompletionFrame:
        finalAttemptUpdate.decision.correctionStepApplied)
require(finalAttemptCompletion?.outcome == .timedOut
        && finalAttemptCompletion?.correctionStepAppliedOnCompletionFrame == true,
        "P7R4 T5 timeout must not reinterpret a provisional step as success")
require(finalAttemptCompletion?.selectedHypothesisId == 77,
        "P7R4 T10 completion must bind the episode hypothesis")
let completionIsolation = PriorMapHypothesisTraceBinder.bind(
    completion: finalAttemptCompletion,
    currentSelectedHypothesisId: 901)
require(!completionIsolation.currentHypothesisVisible
        && completionIsolation.currentSelectedHypothesisId == nil,
        "P7R4 T10 a new Local candidate cannot enter flat fields on an old completion frame")
require(completionIsolation.recoverySelectedHypothesisId == 77,
        "P7R4 T10 completion diagnostics must retain the old episode hypothesis")

// P7R4 T6/T7: a matcher crossing the deadline records a real attempt but the
// post-match decision cannot mutate the alignment. Equality is expired too.
let fakeClock = FakeMonotonicClock(0)
let deadlineController = PriorMapRecoveryController(
    maximumValidAttempts: 40,
    maximumWallClockSeconds: 30)
_ = deadlineController.request(reason: "deadline", now: fakeClock.now)
let deadlineConfidence = PriorMapConfidenceManager()
deadlineConfidence.reset()
let deadlineAnchor = PriorMapLocalizationAnchor(
    initialMapPose: PriorMapPose2D(xM: 4, yM: 5, yawRad: 0.1))
let deadlineArkitPose = PriorMapPose2D(xM: 1, yM: 2, yawRad: 0.2)
let anchorBeforeExpiredMatch = deadlineAnchor.project(
    arkitPose: deadlineArkitPose)
fakeClock.now = 29.8
require(!deadlineController.isWallClockExpired(now: fakeClock.now),
        "P7R4 T6 matcher may start before deadline")
fakeClock.now = 31.3
let expiredUpdate = PriorMapRecoveryUpdateReducer.reduce(
    recoveryUpdateInput(
        timestamp: fakeClock.now,
        preMatchNow: 29.8,
        postMatchNow: fakeClock.now,
        recoveryActive: true,
        disposition: .searched,
        trusted: true,
        geometryAccepted: true,
        residualTranslationM: 1),
    recoveryController: deadlineController,
    confidenceManager: deadlineConfidence)
require(deadlineController.activeEpisode?.validMatcherAttempts == 1,
        "P7R4 T6 a deadline-crossing real search still counts")
require(expiredUpdate.action == .timedOut
        && !expiredUpdate.decision.correctionStepApplied,
        "P7R4 T6 no post-deadline Recovery correction may be applied")
let deadlineCompletion = deadlineController.finish(
    .timedOut,
    now: fakeClock.now,
    correctionStepAppliedOnCompletionFrame:
        expiredUpdate.decision.correctionStepApplied)
require(deadlineCompletion?.outcome == .timedOut
        && expiredUpdate.nextConfidence.phase == .weak,
        "P7R4 T6 deadline crossing must finish timed_out and enter weak")
requirePoseClose(
    deadlineAnchor.project(arkitPose: deadlineArkitPose),
    anchorBeforeExpiredMatch,
    "P7R4 T6 an expired matcher result cannot mutate the localizer anchor")
require(!deadlineController.isWallClockExpired(now: 30),
        "P7R4 T7 completed controller no longer has an active deadline")

let exactDeadlineController = PriorMapRecoveryController()
_ = exactDeadlineController.request(reason: "exact_deadline", now: 0)
let exactDeadlineConfidence = PriorMapConfidenceManager()
exactDeadlineConfidence.reset()
let exactDeadlineUpdate = PriorMapRecoveryUpdateReducer.reduce(
    recoveryUpdateInput(
        timestamp: 30,
        preMatchNow: 30,
        postMatchNow: 30,
        recoveryActive: true,
        disposition: .observationUnavailable),
    recoveryController: exactDeadlineController,
    confidenceManager: exactDeadlineConfidence)
require(exactDeadlineUpdate.action == .timedOut
        && !exactDeadlineUpdate.searchedAttemptRecorded,
        "P7R4 T7 now equal to deadline expires before search/correction")

// P7R4 T12: every production frame disposition goes through the same attempt
// reducer. Invalid/dropped frames advance the FakeClock but never the attempt
// counter, and wall-clock expiry remains fail-closed.
let dispositionClock = FakeMonotonicClock(0)
let dispositionController = PriorMapRecoveryController(
    maximumValidAttempts: 40,
    maximumWallClockSeconds: 30)
_ = dispositionController.request(
    reason: "invalid_frame_timeout", now: dispositionClock.now,
    automatic: true)
let dispositionConfidence = PriorMapConfidenceManager()
dispositionConfidence.reset()
let dispositionGate = PriorMapUpdateGate(minimumInterval: 0.5)
let acceptedGateDecision = dispositionGate.begin(timestamp: 1.0)
guard case .accepted(let dispositionTicket) = acceptedGateDecision else {
    fatalError("P7R4 T12 first gate update must be accepted")
}
let busyGateDecision = dispositionGate.begin(timestamp: 2.0)
require(busyGateDecision.recoveryFrameDisposition == .busy,
        "P7R4 T12 a busy gate must expose the production busy disposition")
dispositionGate.finish(ticket: dispositionTicket)
let throttledGateDecision = dispositionGate.begin(timestamp: 1.1)
require(throttledGateDecision.recoveryFrameDisposition == .throttled,
        "P7R4 T12 a throttled gate must expose the production throttled disposition")
for (index, disposition) in invalidRecoveryDispositions.enumerated() {
    dispositionClock.now = Double(index + 1) * 4.9
    let invalidUpdate = PriorMapRecoveryUpdateReducer.reduce(
        recoveryUpdateInput(
            timestamp: dispositionClock.now,
            preMatchNow: dispositionClock.now,
            postMatchNow: dispositionClock.now,
            recoveryActive: true,
            disposition: disposition),
        recoveryController: dispositionController,
        confidenceManager: dispositionConfidence)
    require(!invalidUpdate.searchedAttemptRecorded
            && invalidUpdate.action == .none,
            "P7R4 T12 \(disposition.rawValue) must consume wall time but not an attempt")
}
require(dispositionController.activeEpisode?.validMatcherAttempts == 0,
        "P7R4 T12 all invalid/dropped paths must leave attempts at zero")
dispositionClock.now = 30
let invalidTimeoutUpdate = PriorMapRecoveryUpdateReducer.reduce(
    recoveryUpdateInput(
        timestamp: dispositionClock.now,
        preMatchNow: dispositionClock.now,
        postMatchNow: dispositionClock.now,
        recoveryActive: true,
        disposition: .observationUnavailable),
    recoveryController: dispositionController,
    confidenceManager: dispositionConfidence)
require(invalidTimeoutUpdate.action == .timedOut
        && !invalidTimeoutUpdate.searchedAttemptRecorded
        && invalidTimeoutUpdate.recoveryFailedThisUpdate
        && invalidTimeoutUpdate.nextConfidence.phase == .weak,
        "P7R4 T12 invalid frames must reach timed_out/weak without a searched attempt")
_ = dispositionController.finish(.timedOut, now: dispositionClock.now)
for weakTimestamp in [30.1, 35.0, 49.9] {
    let cooldownWeakUpdate = PriorMapRecoveryUpdateReducer.reduce(
        recoveryUpdateInput(
            timestamp: weakTimestamp,
            preMatchNow: weakTimestamp,
            postMatchNow: weakTimestamp,
            recoveryActive: false,
            disposition: .observationUnavailable),
        recoveryController: dispositionController,
        confidenceManager: dispositionConfidence)
    require(cooldownWeakUpdate.nextConfidence.phase == .weak,
            "P7R4 T12 timeout must remain weak throughout automatic cooldown")
    require(!dispositionController.request(
        reason: "persistent_weak_or_lost",
        now: weakTimestamp,
        automatic: true),
        "P7R4 T12 continuous weak frames cannot start Recovery during cooldown")
}

// P7R4 T8/T9: automatic timeout creates a bounded cooldown. A reliable loop
// may bypass it, while a repeated trigger only merges into the active episode.
let cooldownController = PriorMapRecoveryController()
_ = cooldownController.request(
    reason: "persistent_weak_or_lost", now: 100, automatic: true)
_ = cooldownController.finish(.timedOut, now: 130)
require(!cooldownController.request(
    reason: "persistent_weak_or_lost", now: 149, automatic: true),
    "P7R4 T8 automatic Recovery must be suppressed during cooldown")
require(cooldownController.isAutomaticTriggerSuppressed(now: 149),
        "P7R4 T8 cooldown suppression must be diagnostic")
require(cooldownController.request(reason: "reliable_rtabmap_loop", now: 149),
        "P7R4 T9 reliable loop may bypass automatic cooldown")
let bypassEpisode = cooldownController.activeEpisode!
require(!cooldownController.request(reason: "reliable_rtabmap_loop", now: 150),
        "P7R4 T9 an active loop trigger must merge")
require(cooldownController.activeEpisode?.id == bypassEpisode.id
        && cooldownController.activeEpisode?.deadlineUptime
            == bypassEpisode.deadlineUptime,
        "P7R4 T9 merged trigger must not reset identity or deadline")
_ = cooldownController.finish(.cancelled, now: 150)
require(cooldownController.request(
    reason: "persistent_weak_or_lost", now: 150, automatic: true),
    "P7R4 T8 a new automatic episode must be allowed exactly when cooldown expires")

// P7R4 T11: exercise the production localizer anchor with competing Recovery
// hypotheses. B wins fresh evidence, advances through multiple bounded steps,
// survives tracker cleanup, and remains the basis of the next ordinary Local
// frame; historical A has neither support nor authority to move the anchor.
let retainedAnchor = PriorMapLocalizationAnchor(
    initialMapPose: PriorMapPose2D(xM: 0, yM: 0, yawRad: 0))
let anchorTracker = PriorMapHypothesisTracker()
anchorTracker.beginRecoveryEpisode(id: 700)
let historicalA = PriorMapAlignmentTransform(
    translationXM: -2, translationYM: 0, yawRad: 0)
let selectedB = PriorMapAlignmentTransform(
    translationXM: 2, translationYM: 0.4, yawRad: 6 * .pi / 180)
var retainedStepCount = 0
var retainedRecoveryConverged = false
var lastAnchorArkitPose = PriorMapPose2D(xM: 0, yM: 0, yawRad: 0)
for attempt in 0..<20 {
    let arkitPose = PriorMapPose2D(
        xM: Double(attempt) * 0.1,
        yM: Double(attempt) * 0.02,
        yawRad: Double(attempt) * 0.002)
    lastAnchorArkitPose = arkitPose
    let rawAnchorPose = retainedAnchor.project(arkitPose: arkitPose)
    let anchorDecision = anchorTracker.observe(
        arkitPose: arkitPose,
        candidates: [
            PriorMapScanMatchCandidate(
                pose: PriorMapAlignmentMath.apply(
                    mapFromArkit: historicalA,
                    arkitPose: arkitPose),
                cost: 0.08,
                score: productionMatcherScore(0.08)),
            PriorMapScanMatchCandidate(
                pose: PriorMapAlignmentMath.apply(
                    mapFromArkit: selectedB,
                    arkitPose: arkitPose),
                cost: 0.01,
                score: productionMatcherScore(0.01)),
        ],
        uniqueness: 0.5,
        recoverySearch: true)
    guard anchorDecision.trusted,
          let trustedB = anchorDecision.mapFromArkit else {
        continue
    }
    require(trustedB.translationXM > 1.5,
            "P7R4 T11 fresh Recovery evidence must select B rather than historical A")
    let targetB = PriorMapAlignmentMath.apply(
        mapFromArkit: trustedB,
        arkitPose: arkitPose)
    let residual = PriorMapCorrectionSafety.difference(
        from: rawAnchorPose,
        to: targetB)
    let boundedAnchorPose = PriorMapCorrectionSafety.boundedStep(
        current: rawAnchorPose,
        target: targetB)
    retainedAnchor.retainAppliedCorrection(
        arkitPose: arkitPose,
        estimatedMapPose: boundedAnchorPose)
    retainedStepCount += 1
    if residual.translationM
            <= PriorMapRecoveryDecisionEngine.convergenceTranslationM,
       residual.yawRad <= PriorMapRecoveryDecisionEngine.convergenceYawRad {
        retainedRecoveryConverged = true
        break
    }
}
require(retainedRecoveryConverged && retainedStepCount > 1,
        "P7R4 T11 B must converge through multiple bounded anchor steps")
anchorTracker.endRecoveryEpisode(id: 700, outcome: .converged)
let nextAnchorArkitPose = PriorMapPose2D(
    xM: lastAnchorArkitPose.xM + 0.2,
    yM: lastAnchorArkitPose.yM + 0.04,
    yawRad: lastAnchorArkitPose.yawRad + 0.004)
let projectedFromRetainedB = retainedAnchor.project(
    arkitPose: nextAnchorArkitPose)
let expectedFromB = PriorMapAlignmentMath.apply(
    mapFromArkit: selectedB,
    arkitPose: nextAnchorArkitPose)
let expectedFromA = PriorMapAlignmentMath.apply(
    mapFromArkit: historicalA,
    arkitPose: nextAnchorArkitPose)
let distanceToB = PriorMapCorrectionSafety.difference(
    from: projectedFromRetainedB,
    to: expectedFromB).translationM
let distanceToA = PriorMapCorrectionSafety.difference(
    from: projectedFromRetainedB,
    to: expectedFromA).translationM
require(distanceToB <= 0.5 && distanceToA > 3.0,
        "P7R4 T11 next Local frame must continue from retained B without jumping to A")
let freshLocalB = anchorTracker.observe(
    arkitPose: nextAnchorArkitPose,
    candidates: [PriorMapScanMatchCandidate(
        pose: expectedFromB,
        cost: 0.01,
        score: productionMatcherScore(0.01))],
    uniqueness: 0.5,
    recoverySearch: false)
require(!freshLocalB.trusted && freshLocalB.supportFrames == 1,
        "P7R4 T11 tracker cleanup must require fresh Local support")
requirePoseClose(
    retainedAnchor.project(arkitPose: nextAnchorArkitPose),
    projectedFromRetainedB,
    "P7R4 T11 untrusted fresh Local evidence cannot move retained B anchor")

// Legacy coordinate reconstruction coverage, including arbitrary turns.
var randomState: UInt64 = 0x5eed5eed
func deterministicUnit() -> Double {
    randomState = randomState &* 6364136223846793005 &+ 1442695040888963407
    return Double(randomState >> 11) / Double(UInt64.max >> 11)
}
for index in 0..<100 {
    let arkitPose = PriorMapPose2D(
        xM: deterministicUnit() * 200 - 100,
        yM: deterministicUnit() * 200 - 100,
        yawRad: deterministicUnit() * 2 * .pi - .pi)
    let alignment = PriorMapAlignmentTransform(
        translationXM: deterministicUnit() * 200 - 100,
        translationYM: deterministicUnit() * 200 - 100,
        yawRad: deterministicUnit() * 2 * .pi - .pi)
    requireAlignmentReconstruction(
        arkitPose: arkitPose,
        expectedMapFromArkit: alignment,
        "T11 randomized case \(index)")
}

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
let justConvergedUsableTag = ShelfAssociation.localizedTag(
    observationId: "just-converged",
    payload: "6900000000001",
    symbology: "EAN13",
    floorId: "1",
    rawPosition: PriorMapTagPoint3D(xM: 2, yM: -0.1, heightM: 1.4),
    cameraPosition: SIMD2<Double>(2, -2),
    shelves: [shelf],
    localizationState: "usable",
    localizationConfidence: 0.79,
    measurementConfidence: 0.9,
    measurementMethod: "scene_depth",
    userConfirmed: false)
require(justConvergedUsableTag.needsReview,
        "P7R4 T14 usable/just-converged tags cannot auto-confirm")

func tagForLocalizationState(
    observationId: String,
    state: String
) -> LocalizedPriceTag {
    ShelfAssociation.localizedTag(
        observationId: observationId,
        payload: "6900000000099",
        symbology: "EAN13",
        floorId: "1",
        rawPosition: PriorMapTagPoint3D(
            xM: 2, yM: -0.1, heightM: 1.4),
        cameraPosition: SIMD2<Double>(2, -2),
        shelves: [shelf],
        localizationState: state,
        localizationConfidence: 0.95,
        measurementConfidence: 0.95,
        measurementMethod: "scene_depth",
        userConfirmed: false)
}
let tagConfidenceMatrix: [
    (label: String, state: String, mustNeedReview: Bool)
] = [
    ("recovery_active", "recovering", true),
    ("recovery_timed_out", "weak", true),
    ("just_converged", "usable", true),
    ("usable", "usable", true),
    ("stable", "stable", false),
]
for matrixCase in tagConfidenceMatrix {
    let result = tagForLocalizationState(
        observationId: matrixCase.label,
        state: matrixCase.state)
    require(result.needsReview == matrixCase.mustNeedReview,
            "P7R4 T14 \(matrixCase.label) auto-confirm safety matrix")
}
require(!localized.needsReview,
        "P7R4 T14 a fully qualified stable tag must retain the positive auto-confirm path")

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
    let points29 = PriorMapStructureObservation(
        points: Array(observation.points.prefix(29)),
        validPointCount: 29,
        coverageAngleRad: 1.2,
        floorEstimate: nil,
        source: "test")
    let points30 = PriorMapStructureObservation(
        points: Array(observation.points.prefix(30)),
        validPointCount: 30,
        coverageAngleRad: 1.2,
        floorEstimate: nil,
        source: "test")
    let notSearched = periodicMatcher.match(
        predictedPose: PriorMapPose2D(xM: 0.3, yM: 0, yawRad: 0),
        observation: points29)
    let searched = periodicMatcher.match(
        predictedPose: PriorMapPose2D(xM: 0.3, yM: 0, yawRad: 0),
        observation: points30)
    require(!notSearched.searchPerformed
        && notSearched.attemptDisposition == .notSearchedInsufficientPoints,
        "P7R4 T13 29 points must not report a real search")
    require(searched.searchPerformed
        && searched.attemptDisposition == .searched,
        "P7R4 T13 30 points must use the matcher-owned threshold")
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

// MARK: - P7R5 F-01: cooldown reconciles against the terminal outcome.

// C1: automatic timeout starts a cooldown, a reliable loop bypasses it and
// converges before expiry; the stale cooldown is cleared exactly at
// convergence so the next Local frames are never forced weak.
let p7r5C1Controller = PriorMapRecoveryController(
    maximumValidAttempts: 40,
    maximumWallClockSeconds: 30)
_ = p7r5C1Controller.request(
    reason: "persistent_weak_or_lost", now: 0, automatic: true)
_ = p7r5C1Controller.finish(.timedOut, now: 5)
require(p7r5C1Controller.isAutomaticTriggerSuppressed(now: 6),
        "P7R5 C1 automatic timeout must suppress automatic triggers")
require(!p7r5C1Controller.request(
    reason: "persistent_weak_or_lost", now: 6, automatic: true),
        "P7R5 C1 automatic retry stays suppressed during cooldown")
require(p7r5C1Controller.request(
    reason: "reliable_rtabmap_loop", now: 6),
        "P7R5 C1 a reliable loop must bypass the automatic cooldown")
let p7r5C1Completion = p7r5C1Controller.finish(
    .converged, now: 8, selectedHypothesisId: 5, finalFreshSupportFrames: 4)
require(p7r5C1Completion?.outcome == .converged
        && p7r5C1Completion?.cancellationReason == nil,
        "P7R5 C1 convergence carries no cancellation reason")
require(p7r5C1Controller.nextAutomaticRecoveryAllowedAt == 0,
        "P7R5 C1 convergence must clear the stale cooldown exactly")
require(p7r5C1Controller.request(
    reason: "persistent_weak_or_lost", now: 9, automatic: true),
        "P7R5 C1 automatic triggers are allowed immediately after convergence")
_ = p7r5C1Controller.finish(.cancelled, now: 9)
let p7r5C1Confidence = PriorMapConfidenceManager()
p7r5C1Confidence.reset()
let p7r5C1Converged = p7r5C1Confidence.update(
    timestamp: 20,
    observation: PriorMapConfidenceObservation(
        trackingState: "normal",
        measurementAccepted: true,
        correctionStepApplied: true,
        recoveryActive: false,
        recoveryConvergedThisUpdate: true,
        recoveryFailedThisUpdate: false,
        validPointCount: 120,
        coverageAngleRad: 1.4,
        uniqueness: 0.5,
        residualCost: 0.01,
        mapMismatch: false))
require(p7r5C1Converged.phase == .usable,
        "P7R5 C1 a cleared-cooldown convergence stays usable")
for timestamp in 21...22 {
    let result = p7r5C1Confidence.update(
        timestamp: Double(timestamp), observation: trustedLocalObservation())
    require(result.phase != .weak,
            "P7R5 C1 a cleared cooldown must not force Local frames weak")
}
let p7r5C1Stable = p7r5C1Confidence.update(
    timestamp: 23, observation: trustedLocalObservation())
require(p7r5C1Stable.phase == .stable,
        "P7R5 C1 three Local frames restore stable after the cooldown clear")

// C2: a reliable-loop timeout also extends the cooldown, measured from the
// second failure, regardless of how the episode was triggered.
let p7r5C2Controller = PriorMapRecoveryController(
    maximumValidAttempts: 40,
    maximumWallClockSeconds: 30)
_ = p7r5C2Controller.request(
    reason: "persistent_weak_or_lost", now: 100, automatic: true)
_ = p7r5C2Controller.finish(.timedOut, now: 105)
require(!p7r5C2Controller.request(
    reason: "persistent_weak_or_lost", now: 110, automatic: true),
        "P7R5 C2 first timeout suppresses automatic retries")
require(p7r5C2Controller.request(reason: "reliable_rtabmap_loop", now: 110),
        "P7R5 C2 reliable loop bypasses the first cooldown")
_ = p7r5C2Controller.finish(.timedOut, now: 112)
require(p7r5C2Controller.nextAutomaticRecoveryAllowedAt == 132,
        "P7R5 C2 a reliable-loop timeout extends cooldown from its own finish")
require(!p7r5C2Controller.request(
    reason: "persistent_weak_or_lost", now: 131, automatic: true),
        "P7R5 C2 automatic retry stays suppressed before the second expiry")
require(p7r5C2Controller.request(
    reason: "persistent_weak_or_lost", now: 132, automatic: true),
        "P7R5 C2 automatic retry allowed exactly at the second expiry")
_ = p7r5C2Controller.finish(.cancelled, now: 132)

// C3: a successful Recovery clears the cooldown exactly at convergence.
let p7r5C3Controller = PriorMapRecoveryController()
_ = p7r5C3Controller.request(
    reason: "persistent_weak_or_lost", now: 0, automatic: true)
_ = p7r5C3Controller.finish(.timedOut, now: 10)
require(p7r5C3Controller.nextAutomaticRecoveryAllowedAt == 30,
        "P7R5 C3 timeout must set the 20 second cooldown")
_ = p7r5C3Controller.request(reason: "reliable_rtabmap_loop", now: 11)
_ = p7r5C3Controller.finish(.converged, now: 12)
require(p7r5C3Controller.nextAutomaticRecoveryAllowedAt == 0,
        "P7R5 C3 convergence clears the cooldown exactly at completion")

// C4: a manual correction clears the cooldown.
let p7r5C4Controller = PriorMapRecoveryController()
_ = p7r5C4Controller.request(
    reason: "persistent_weak_or_lost", now: 0, automatic: true)
_ = p7r5C4Controller.finish(.timedOut, now: 10)
_ = p7r5C4Controller.request(reason: "reliable_rtabmap_loop", now: 11)
_ = p7r5C4Controller.finish(.manualReset, now: 12)
require(p7r5C4Controller.nextAutomaticRecoveryAllowedAt == 0,
        "P7R5 C4 manual reset clears the cooldown")
require(p7r5C4Controller.request(
    reason: "persistent_weak_or_lost", now: 12, automatic: true),
        "P7R5 C4 automatic triggers allowed immediately after manual reset")

// C5 + F-04: a reliable loop bypasses cooldown but never duplicates the
// active episode; repeated triggers retain a bounded source summary.
let p7r5C5Controller = PriorMapRecoveryController()
_ = p7r5C5Controller.request(
    reason: "persistent_weak_or_lost", now: 0, automatic: true)
_ = p7r5C5Controller.finish(.timedOut, now: 5)
require(p7r5C5Controller.request(reason: "reliable_rtabmap_loop", now: 6),
        "P7R5 C5 reliable loop bypasses cooldown")
let p7r5C5EpisodeId = p7r5C5Controller.activeEpisode?.id
require(!p7r5C5Controller.request(reason: "reliable_rtabmap_loop", now: 7),
        "P7R5 C5 repeated triggers must not duplicate the active episode")
require(p7r5C5Controller.activeEpisode?.id == p7r5C5EpisodeId
        && p7r5C5Controller.activeEpisode?.deadlineUptime == 36,
        "P7R5 C5 episode identity and deadline survive repeated triggers")
if let p7r5C5Episode = p7r5C5Controller.activeEpisode {
    require(p7r5C5Episode.triggerCount == 2
            && p7r5C5Episode.automaticTriggerCount == 0
            && p7r5C5Episode.reliableLoopTriggerCount == 2,
            "P7R5 F-04 trigger source counts must be auditable")
    require(p7r5C5Episode.lastTriggerReason == "reliable_rtabmap_loop"
            && p7r5C5Episode.lastTriggerAtUptime == 7,
            "P7R5 F-04 last trigger reason and time must be retained")
    require(p7r5C5Episode.triggerRecords.count == 2
            && p7r5C5Episode.triggerRecords.first?.atUptime == 6
            && p7r5C5Episode.triggerRecords.last?.automatic == false,
            "P7R5 F-04 trigger records must keep ordered source evidence")
}
for index in 0..<12 {
    _ = p7r5C5Controller.request(
        reason: "reliable_rtabmap_loop_\(index)",
        now: 8 + Double(index))
}
if let p7r5C5CappedEpisode = p7r5C5Controller.activeEpisode {
    require(p7r5C5CappedEpisode.triggerRecords.count
                == PriorMapRecoveryEpisode.maximumRetainedTriggerRecords,
            "P7R5 F-04 trigger records must be capped at eight")
    require(p7r5C5CappedEpisode.triggerRecords.last?.reason
                == "reliable_rtabmap_loop_11",
            "P7R5 F-04 the newest trigger must survive record eviction")
    require(p7r5C5CappedEpisode.triggerCount == 14,
            "P7R5 F-04 triggerCount keeps counting beyond the record cap")
}
let p7r5TriggerBoundController = PriorMapRecoveryController(
    maximumTriggerCount: 3)
_ = p7r5TriggerBoundController.request(reason: "initial", now: 0)
for _ in 0..<10 {
    _ = p7r5TriggerBoundController.request(reason: "repeat", now: 1)
}
require(p7r5TriggerBoundController.activeEpisode?.triggerCount == 3,
        "P7R5 F-04 triggerCount must stay bounded by maximumTriggerCount")

// MARK: - P7R5 F-02: cancellations persist terminal evidence and reconcile.

// E1: scan-stop cancellation persists its reason and suppresses automatic
// retry; E2: map unload persists its reason without throttling retries.
let p7r5E1Controller = PriorMapRecoveryController()
_ = p7r5E1Controller.request(
    reason: "persistent_weak_or_lost", now: 0, automatic: true)
let p7r5E1Completion = p7r5E1Controller.finish(
    .cancelled, now: 4, cancellationReason: .scanStopped)
require(p7r5E1Completion?.outcome == .cancelled
        && p7r5E1Completion?.cancellationReason == .scanStopped,
        "P7R5 E1 scan-stop cancellation must persist the terminal reason")
require(p7r5E1Controller.nextAutomaticRecoveryAllowedAt == 24,
        "P7R5 E1 scan-stopped cancellation suppresses automatic retry")
let p7r5E2Controller = PriorMapRecoveryController()
_ = p7r5E2Controller.request(reason: "reliable_rtabmap_loop", now: 0)
let p7r5E2Completion = p7r5E2Controller.finish(
    .cancelled, now: 4, cancellationReason: .mapUnloaded)
require(p7r5E2Completion?.cancellationReason == .mapUnloaded,
        "P7R5 E2 map-unload cancellation must persist the terminal reason")
require(p7r5E2Controller.nextAutomaticRecoveryAllowedAt == 0,
        "P7R5 E2 map unload must not throttle future automatic triggers")

// E4: no active episode means no fake completion.
let p7r5E4Controller = PriorMapRecoveryController()
require(p7r5E4Controller.finish(
    .cancelled, now: 0, cancellationReason: .scanStopped) == nil,
        "P7R5 E4 cancellation without an active episode returns nil")

// Lifecycle record builder: snake_case contract fields and bounded elapsed.
if let p7r5E1Completion {
    let p7r5LifecycleRecord = PriorMapRecoveryLifecycleRecord(
        trackingSessionId: "session-1",
        priorMapId: "map-1",
        priorMapSha256: "sha-1",
        floorId: "1",
        completion: p7r5E1Completion)
    require(p7r5LifecycleRecord.format
                == PriorMapRecoveryLifecycleRecord.formatName
            && p7r5LifecycleRecord.version
                == PriorMapRecoveryLifecycleRecord.formatVersion,
            "P7R5 lifecycle record must carry the v1 contract identity")
    require(p7r5LifecycleRecord.outcome == "cancelled"
            && p7r5LifecycleRecord.cancellationReason == "scan_stopped",
            "P7R5 lifecycle record must expose terminal outcome and reason")
    require(p7r5LifecycleRecord.elapsedMs == 4000
            && p7r5LifecycleRecord.finishedAtUptime == 4,
            "P7R5 lifecycle elapsed must be bound to the finish time")
    require(p7r5LifecycleRecord.episodeAutomatic
            && p7r5LifecycleRecord.triggerCount == 1
            && p7r5LifecycleRecord.lastTriggerReason
                == "persistent_weak_or_lost",
            "P7R5 lifecycle record must retain the trigger summary")
    if let encoded = try? JSONEncoder().encode(p7r5LifecycleRecord),
       let json = (try? JSONSerialization.jsonObject(with: encoded))
            as? [String: Any] {
        require(json["cancellation_reason"] as? String == "scan_stopped"
                && json["finished_at_uptime"] != nil
                && json["episode_automatic"] as? Bool == true,
                "P7R5 lifecycle record must encode snake_case contract keys")
    }
    else {
        require(false, "P7R5 lifecycle record must encode as JSON")
    }
}

// MARK: - P7R5 F-03: pending completion elapsed binds to finishedAt.
let p7r5F03Controller = PriorMapRecoveryController()
_ = p7r5F03Controller.request(reason: "deadline", now: 100)
let p7r5F03Completion = p7r5F03Controller.finish(.manualReset, now: 110)
if let p7r5F03Completion {
    require(PriorMapRecoveryDiagnostics.elapsedMs(
        episode: p7r5F03Completion.episode,
        completion: p7r5F03Completion,
        now: 200) == 10000,
            "P7R5 F-03 a consumed completion must not extend elapsed time")
    require(PriorMapRecoveryDiagnostics.elapsedMs(
        episode: p7r5F03Completion.episode,
        completion: nil,
        now: 130) == 30000,
            "P7R5 F-03 an active episode still uses the frame clock")
}

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

var finalizationResourceUsage = rusage()
if getrusage(RUSAGE_SELF, &finalizationResourceUsage) == 0 {
    print("Finalization test peak RSS bytes: \(finalizationResourceUsage.ru_maxrss)")
}
print("PriorMapLocalizationCore Swift tests passed")
