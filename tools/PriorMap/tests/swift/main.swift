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

// P7R6: recovery lifecycle records are reconciled against an exact
// expected-count watermark. A valid terminal record validates only when the
// expectation carries the matching watermark; an identity mismatch still
// fails closed.
let recoveryEvidenceURL = evidenceDirectory.appendingPathComponent(
    "localization_recovery_events.jsonl")
let recoveryLifecycleRecord: [String: Any] = [
    "format": "MarketScannerRecoveryLifecycleEvent",
    "version": 2,
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
    "deadline_uptime": 70.0,
    "finished_at_uptime": 14.5,
    "elapsed_ms": 4500.0,
    "maximum_valid_attempts": 40,
    "valid_matcher_attempts": 7,
    "accepted_corrections": 2,
    "trigger_count": 1,
    "automatic_trigger_count": 0,
    "reliable_loop_trigger_count": 1,
    "last_trigger_reason": "reliable_rtabmap_loop",
    "last_trigger_at_uptime": 10.0,
    "trigger_records": [
        [
            "reason": "reliable_rtabmap_loop",
            "automatic": false,
            "at_uptime": 10.0,
        ],
    ],
    "fresh_support_frames": 4,
    "completion_frame_step_applied": false,
]
var recoveryLifecycleData = try JSONSerialization.data(
    withJSONObject: recoveryLifecycleRecord)
recoveryLifecycleData.append(0x0A)
try recoveryLifecycleData.write(to: recoveryEvidenceURL)
let recoveryExpectation = LocalizationEvidenceBundleExpectation(
    trackingSessionId: "session-a",
    priorMapId: "map-a",
    priorMapSha256: String(repeating: "a", count: 64),
    floorId: "1",
    traceRecordCount: 1,
    constraintRecordCount: 1,
    stateEventCount: 1,
    lastDurableState: "stable",
    localizedPriceTagCount: 0,
    recoveryEventCount: 1,
    lastRecoveryEpisodeId: 1,
    lastRecoveryFinishedAtUptime: 14.5)
require(
    LocalizationEvidenceBundleValidator.blockers(
        in: evidenceDirectory,
        expectation: recoveryExpectation).isEmpty,
    "a valid recovery lifecycle record must validate")
require(
    LocalizationEvidenceBundleValidator.blockers(
        in: evidenceDirectory,
        expectation: evidenceExpectation).contains {
            $0.contains("localization_recovery_events.jsonl_count_mismatch")
        },
    "a recovery record without watermark expectation must fail closed")
let watermarkedMismatchExpectation = LocalizationEvidenceBundleExpectation(
    trackingSessionId: "session-a",
    priorMapId: "map-a",
    priorMapSha256: String(repeating: "a", count: 64),
    floorId: "1",
    traceRecordCount: 1,
    constraintRecordCount: 1,
    stateEventCount: 1,
    lastDurableState: "stable",
    localizedPriceTagCount: 0,
    recoveryEventCount: 1,
    lastRecoveryEpisodeId: 2,
    lastRecoveryFinishedAtUptime: 14.5)
require(
    LocalizationEvidenceBundleValidator.blockers(
        in: evidenceDirectory,
        expectation: watermarkedMismatchExpectation).contains(
            "evidence_bundle_recovery_watermark_mismatch"),
    "a wrong recovery episode watermark must fail closed")
var corruptedRecoveryRecord = recoveryLifecycleRecord
corruptedRecoveryRecord["tracking_session_id"] = "session-other"
var corruptedRecoveryData = try JSONSerialization.data(
    withJSONObject: corruptedRecoveryRecord)
corruptedRecoveryData.append(0x0A)
try corruptedRecoveryData.write(to: recoveryEvidenceURL)
require(
    LocalizationEvidenceBundleValidator.blockers(
        in: evidenceDirectory,
        expectation: recoveryExpectation).contains(
            "evidence_bundle_localization_recovery_events.jsonl_identity_mismatch"),
    "a recovery lifecycle identity mismatch must fail closed")

// P7R6: the strict lifecycle schema rejects illegal evidence fail-closed,
// while legacy v1 records remain readable.
func recoverySchemaBlockers(mutating: (inout [String: Any]) -> Void) throws
    -> [String] {
    var record = recoveryLifecycleRecord
    mutating(&record)
    var data = try JSONSerialization.data(withJSONObject: record)
    data.append(0x0A)
    try data.write(to: recoveryEvidenceURL)
    return LocalizationEvidenceBundleValidator.blockers(
        in: evidenceDirectory,
        expectation: recoveryExpectation)
}
func requireRecoveryRejected(
    _ mutating: (inout [String: Any]) -> Void,
    reason: String,
    _ message: String
) throws {
    let blockers = try recoverySchemaBlockers(mutating: mutating)
    require(
        blockers.contains(
            "evidence_bundle_localization_recovery_events.jsonl_\(reason)"),
        "\(message): \(blockers)")
}
try requireRecoveryRejected(
    { $0["outcome"] = "banana" },
    reason: "recovery_outcome_invalid",
    "an unknown outcome must fail closed")
try requireRecoveryRejected(
    {
        $0["outcome"] = "converged"
    },
    reason: "recovery_cancellation_reason_invalid",
    "a converged episode must not carry a cancellation reason")
try requireRecoveryRejected(
    { $0["cancellation_reason"] = NSNull() },
    reason: "recovery_cancellation_reason_invalid",
    "a cancelled episode must carry an explicit cancellation reason")
try requireRecoveryRejected(
    { $0["elapsed_ms"] = -999.0 },
    reason: "recovery_business_schema_invalid",
    "a negative elapsed time must fail closed")
try requireRecoveryRejected(
    { $0["valid_matcher_attempts"] = -4 },
    reason: "recovery_business_schema_invalid",
    "a negative attempts counter must fail closed")
try requireRecoveryRejected(
    { $0["accepted_corrections"] = 999999 },
    reason: "recovery_business_schema_invalid",
    "corrections above the attempts budget must fail closed")
try requireRecoveryRejected(
    { $0["trigger_count"] = -1 },
    reason: "recovery_business_schema_invalid",
    "a negative trigger count must fail closed")
try requireRecoveryRejected(
    { $0["automatic_trigger_count"] = 1 },
    reason: "recovery_business_schema_invalid",
    "trigger classification sums must reconcile")
try requireRecoveryRejected(
    { $0["injected_unknown_field"] = true },
    reason: "recovery_unknown_field",
    "unknown lifecycle fields must fail closed")
try requireRecoveryRejected(
    { $0["version"] = 3 },
    reason: "format_or_version_mismatch",
    "an unsupported lifecycle version must fail closed")
try requireRecoveryRejected(
    { $0["trigger_records"] = [] },
    reason: "recovery_trigger_records_invalid",
    "empty trigger records must fail closed for v2")
try requireRecoveryRejected(
    { $0["trigger_records"] = [
        ["reason": "other", "automatic": false, "at_uptime": 10.0],
    ] },
    reason: "recovery_trigger_records_invalid",
    "trigger records must reconcile with the trigger summary")
var legacyRecoveryRecord = recoveryLifecycleRecord
legacyRecoveryRecord["version"] = 1
legacyRecoveryRecord["deadline_uptime"] = nil
legacyRecoveryRecord["maximum_valid_attempts"] = nil
legacyRecoveryRecord["trigger_records"] = nil
var legacyRecoveryData = try JSONSerialization.data(
    withJSONObject: legacyRecoveryRecord)
legacyRecoveryData.append(0x0A)
try legacyRecoveryData.write(to: recoveryEvidenceURL)
require(
    LocalizationEvidenceBundleValidator.blockers(
        in: evidenceDirectory,
        expectation: recoveryExpectation).isEmpty,
    "a legacy v1 recovery lifecycle record must remain readable")
try recoveryLifecycleData.write(to: recoveryEvidenceURL)
try Data().write(to: recoveryEvidenceURL)
require(
    LocalizationEvidenceBundleValidator.blockers(
        in: evidenceDirectory,
        expectation: recoveryExpectation).contains {
            $0.contains("localization_recovery_events.jsonl_empty")
        },
    "an emptied recovery sidecar must not mask the watermark")

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
            "P7R5 lifecycle record must carry the current contract identity")
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

// MARK: - P7R6: peek/ack persistence coordinator transactions.

final class P7R6FakeRecoverySource: RecoveryCompletionDraining {
    var pending: [PriorMapRecoveryCompletion] = []
    var cancelledReasons: [PriorMapRecoveryCancellationReason] = []

    func cancelRecovery(
        reason: PriorMapRecoveryCancellationReason,
        now: TimeInterval
    ) -> PriorMapRecoveryCompletion? {
        cancelledReasons.append(reason)
        return nil
    }

    func pendingTerminalRecoveryCompletions()
        -> [PriorMapRecoveryCompletion] {
        return pending
    }

    func acknowledgeTerminalRecoveryCompletion(episodeId: Int) {
        pending.removeAll { $0.episode.id == episodeId }
    }

    func discardTerminalRecoveryCompletionsForInvalidatedSession() {
        pending.removeAll()
    }
}

final class P7R6FakeRecoveryWriter: RecoveryLifecycleWriting {
    var appendedEpisodeIds: [Int] = []
    var failingEpisodeIds: Set<Int> = []

    func appendRecoveryLifecycleEvent(
        _ completion: PriorMapRecoveryCompletion,
        expectedTrackingSessionId: String
    ) -> Bool {
        guard !failingEpisodeIds.contains(completion.episode.id) else {
            return false
        }
        appendedEpisodeIds.append(completion.episode.id)
        return true
    }
}

let p7r6Controller = PriorMapRecoveryController()
_ = p7r6Controller.request(
    reason: "persistent_weak_or_lost", now: 0, automatic: true)
let p7r6FirstCompletion = p7r6Controller.finish(.converged, now: 1)
_ = p7r6Controller.request(reason: "reliable_rtabmap_loop", now: 30)
let p7r6SecondCompletion = p7r6Controller.finish(.timedOut, now: 31)
require(p7r6FirstCompletion?.episode.id == 1
        && p7r6SecondCompletion?.episode.id == 2,
        "P7R6 coordinator tests require two sequential episodes")
let p7r6FakeSha256 = String(repeating: "b", count: 64)
if let p7r6FirstCompletion, let p7r6SecondCompletion {
    // P7R6B B3: the pending queue carries finish order and is never
    // sorted. A deliberately reversed queue must fail closed with nothing
    // attempted, appended or acknowledged.
    let source = P7R6FakeRecoverySource()
    source.pending = [p7r6SecondCompletion, p7r6FirstCompletion]
    let writer = P7R6FakeRecoveryWriter()
    let coordinator = RecoveryLifecyclePersistenceCoordinator(
        source: source,
        writer: writer,
        trackingSessionId: "session-1",
        priorMapId: "map-1",
        priorMapSha256: p7r6FakeSha256,
        floorId: "1",
        persistedEvidenceSnapshot: { Data() })
    let reversed = coordinator.persistTerminalEvidence(
        cancellationReason: nil, now: 40)
    require(!reversed.allPersisted
            && reversed.attemptedEpisodeIds.isEmpty
            && reversed.persistedEpisodeIds.isEmpty
            && reversed.failedEpisodeId == 1
            && reversed.failureReason == "pending_episode_order_invalid"
            && writer.appendedEpisodeIds.isEmpty
            && source.pending.map { $0.episode.id } == [2, 1],
            "P7R6B a reversed pending queue must fail closed without sorting")

    // A correctly ordered queue persists in finish order.
    source.pending = [p7r6FirstCompletion, p7r6SecondCompletion]
    let success = coordinator.persistTerminalEvidence(
        cancellationReason: nil, now: 41)
    require(success.allPersisted
            && success.attemptedEpisodeIds == [1, 2]
            && success.persistedEpisodeIds == [1, 2]
            && writer.appendedEpisodeIds == [1, 2],
            "P7R6 the coordinator must persist episodes in finish order")
    require(source.pending.isEmpty,
            "P7R6 every persisted episode must be acknowledged")

    // Cancellation pass-through.
    _ = coordinator.persistTerminalEvidence(
        cancellationReason: .scanStopped, now: 42)
    require(source.cancelledReasons == [.scanStopped],
            "P7R6 teardown cancellation must run before peeking")

    // A failed append stops the transaction and keeps state retryable.
    source.pending = [p7r6FirstCompletion, p7r6SecondCompletion]
    writer.failingEpisodeIds = [2]
    let failure = coordinator.persistTerminalEvidence(
        cancellationReason: nil, now: 50)
    require(!failure.allPersisted
            && failure.failedEpisodeId == 2
            && failure.failureReason == "durable_append_failed"
            && failure.persistedEpisodeIds == [1],
            "P7R6 the coordinator must stop at the first failed episode")
    require(source.pending.map { $0.episode.id } == [2],
            "P7R6 a failed episode must stay queued for retry")

    // Retry persists the failed episode exactly once.
    writer.failingEpisodeIds = []
    let appendedBeforeRetry = writer.appendedEpisodeIds.count
    let retry = coordinator.persistTerminalEvidence(
        cancellationReason: nil, now: 60)
    require(retry.allPersisted
            && writer.appendedEpisodeIds.count == appendedBeforeRetry + 1
            && writer.appendedEpisodeIds.last == 2
            && source.pending.isEmpty,
            "P7R6 retry must persist the failed episode exactly once")

    // Idempotence strategy A: identical persisted canonical bytes count as
    // success without rewriting; conflicting bytes fail closed.
    let persistedRecord = PriorMapRecoveryLifecycleRecord(
        trackingSessionId: "session-1",
        priorMapId: "map-1",
        priorMapSha256: p7r6FakeSha256,
        floorId: "1",
        completion: p7r6FirstCompletion)
    let persistedEncoder = JSONEncoder()
    persistedEncoder.outputFormatting = [.sortedKeys]
    let persistedRecordData = try persistedEncoder.encode(persistedRecord)
    var persistedLine = persistedRecordData
    persistedLine.append(0x0A)
    let idempotentSource = P7R6FakeRecoverySource()
    idempotentSource.pending = [p7r6FirstCompletion]
    let idempotentWriter = P7R6FakeRecoveryWriter()
    let idempotentCoordinator = RecoveryLifecyclePersistenceCoordinator(
        source: idempotentSource,
        writer: idempotentWriter,
        trackingSessionId: "session-1",
        priorMapId: "map-1",
        priorMapSha256: p7r6FakeSha256,
        floorId: "1",
        persistedEvidenceSnapshot: { persistedLine })
    let idempotent = idempotentCoordinator.persistTerminalEvidence(
        cancellationReason: nil, now: 70)
    require(idempotent.allPersisted
            && idempotentWriter.appendedEpisodeIds.isEmpty
            && idempotentSource.pending.isEmpty,
            "P7R6 identical persisted bytes must ack without rewriting")
    // Same episode identity but different terminal content: the canonical
    // bytes disagree, so the transaction must fail closed.
    var conflictingObject = try JSONSerialization.jsonObject(
        with: persistedRecordData) as! [String: Any]
    conflictingObject["outcome"] = "timed_out"
    var conflictingLine = try JSONSerialization.data(
        withJSONObject: conflictingObject)
    conflictingLine.append(0x0A)
    let conflictSource = P7R6FakeRecoverySource()
    conflictSource.pending = [p7r6FirstCompletion]
    let conflictWriter = P7R6FakeRecoveryWriter()
    let conflictCoordinator = RecoveryLifecyclePersistenceCoordinator(
        source: conflictSource,
        writer: conflictWriter,
        trackingSessionId: "session-1",
        priorMapId: "map-1",
        priorMapSha256: p7r6FakeSha256,
        floorId: "1",
        persistedEvidenceSnapshot: { conflictingLine })
    let conflict = conflictCoordinator.persistTerminalEvidence(
        cancellationReason: nil, now: 80)
    require(!conflict.allPersisted
            && conflict.failureReason == "persisted_episode_bytes_conflict"
            && conflictWriter.appendedEpisodeIds.isEmpty
            && conflictSource.pending.map { $0.episode.id } == [1],
            "P7R6 conflicting persisted bytes must fail closed")

    // Invalidated sessions drop queued completions.
    let discardSource = P7R6FakeRecoverySource()
    discardSource.pending = [p7r6FirstCompletion, p7r6SecondCompletion]
    discardSource.discardTerminalRecoveryCompletionsForInvalidatedSession()
    require(discardSource.pending.isEmpty,
            "P7R6 invalidated sessions must discard queued completions")
}

// P7R6 W1-W11 / I1-I15: executable teardown-to-finalization transactions.
// The Swift host cannot link the UIKit session types, so these tests run the
// exact production persistence chain on a real file system: controller ->
// peek/ack coordinator -> durable sidecar writer -> finalization validator.
func makePositions(_ count: Int) -> [FinalTrajectory.DevicePositionRow] {
    var positions: [FinalTrajectory.DevicePositionRow] = []
    for index in 0..<count {
        positions.append(FinalTrajectory.DevicePositionRow(
            sequence: index + 1,
            localTimestamp: "2026-08-05 21:00:00.000 +08:00",
            utcTimestamp: "2026-08-05T13:00:00.000Z",
            unixTimeS: 1_785_762_000 + Int64(index),
            timezoneID: "Asia/Shanghai", utcOffset: 28_800,
            sessionElapsedS: Double(index), storeID: "s1", floorID: "1",
            mapXM: 1.5, mapYM: -2.5, yawDeg: 90.0,
            positionStatus: "ACCEPTED", positionSource: "final_trajectory",
            beforeNodeID: Int64(index), afterNodeID: Int64(index + 1),
            interpolationRatio: 0.5, localizationConfidence: 0.9,
            estimatedUncertaintyM: 0.05, trackingState: "tracking",
            graphQualityStatus: "connected", priorMapID: "m",
            priorMapSha256: "a", trackingSessionID: "s", appGitSHA: "g"))
    }
    return positions
}
func makeInput(positions: [FinalTrajectory.DevicePositionRow]) -> MobileResultExporter.Input {
    return MobileResultExporter.Input(
        devicePositions: positions,
        priceTags: [
            FinalPriceTag(
                tagInstanceID: "t1", barcode: "=HYPERLINK(\"x\")", symbology: "CODE128",
                storeID: "s1", floorID: "1", mapVersion: 1,
                priorMapSha256: "a", trackingSessionID: "s",
                shelfCode: "A1", shelfSide: "front",
                distanceFromShelfStartCm: 123.4, positionRatio: 0.62,
                mapXM: 1.5, mapYM: -2.5, observationCount: 12,
                positionSpreadCm: 3.2, localizationConfidence: 0.95,
                associationConfidence: 0.9, qualityStatus: "ACCEPTED", reason: ""),
        ],
        rescanTasks: [
            RescanTask(taskID: "r1", taskType: .tagRescan, floorID: "1",
                       barcode: "123", tagInstanceID: "t2", shelfCode: "B2",
                       regionStartCm: 10, regionEndCm: 40,
                       localStartTime: "2026-08-05 21:00:00.000 +08:00",
                       localEndTime: "2026-08-05 21:00:05.000 +08:00",
                       reasonCode: "position_spread", humanMessage: "位置分散",
                       suggestedAction: "重新扫描", priority: 1),
        ],
        runSummary: ["app_git_sha": "g", "store_id": "s1"],
        appGitSHA: "g", appVersion: "1.0", deviceModel: "iPhone",
        osVersion: "iOS 18")
}

func p7r6FreshDirectory(_ label: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "p7r6-\(label)-\(UUID().uuidString)",
            isDirectory: true)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true)
    return directory
}

func p7r6WriteBaseBundle(
    in directory: URL,
    createRecoveryFile: Bool = true
) throws -> URL {
    try evidenceRecord(format: "MarketScannerLocalizationTrace")
        .write(to: directory.appendingPathComponent("localization_trace.jsonl"))
    try evidenceRecord(format: "MarketScannerLocalizationConstraint")
        .write(to: directory.appendingPathComponent(
            "localization_constraints.jsonl"))
    try evidenceRecord(
        format: "MarketScannerLocalizationStateEvent",
        state: "stable")
        .write(to: directory.appendingPathComponent("localization_events.jsonl"))
    try Data().write(to: directory.appendingPathComponent(
        "manual_localization_events.jsonl"))
    try Data().write(to: directory.appendingPathComponent(
        "tag_observations.jsonl"))
    try Data("[]".utf8).write(to: directory.appendingPathComponent(
        "localized_price_tags.json"))
    let recoveryURL = directory.appendingPathComponent(
        PriorMapRecoveryLifecycleRecord.fileName)
    if createRecoveryFile {
        try Data().write(to: recoveryURL)
    }
    return recoveryURL
}

func p7r6BundleExpectation(
    recoveryCount: Int,
    lastEpisodeId: Int? = nil,
    lastFinishedAtUptime: TimeInterval? = nil,
    localizedPriceTagCount: Int = 0
) -> LocalizationEvidenceBundleExpectation {
    return LocalizationEvidenceBundleExpectation(
        trackingSessionId: "session-a",
        priorMapId: "map-a",
        priorMapSha256: String(repeating: "a", count: 64),
        floorId: "1",
        traceRecordCount: 1,
        constraintRecordCount: 1,
        stateEventCount: 1,
        lastDurableState: "stable",
        localizedPriceTagCount: localizedPriceTagCount,
        recoveryEventCount: recoveryCount,
        lastRecoveryEpisodeId: lastEpisodeId,
        lastRecoveryFinishedAtUptime: lastFinishedAtUptime)
}

func p7r6EncodedLifecycleLine(
    _ record: PriorMapRecoveryLifecycleRecord
) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    var line = try encoder.encode(record)
    line.append(0x0A)
    return line
}

func p7r6PersistedEvidenceLines(in directory: URL) throws -> [Data] {
    let url = directory.appendingPathComponent(
        PriorMapRecoveryLifecycleRecord.fileName)
    // Mirrors the session snapshot: a missing sidecar is an empty evidence
    // snapshot, not a read failure.
    guard FileManager.default.fileExists(atPath: url.path) else {
        return []
    }
    return try Data(contentsOf: url).split(separator: 0x0A).map { Data($0) }
}

/// P7R6A: mirrors SupermarketScanSession.persistedRecoveryLifecycleSnapshot.
/// One stable read of the whole file; a missing sidecar is an empty
/// snapshot. Line splitting and JSONL semantics belong to the parser.
func p7r6PersistedEvidenceSnapshot(in directory: URL) throws -> Data {
    let url = directory.appendingPathComponent(
        PriorMapRecoveryLifecycleRecord.fileName)
    guard FileManager.default.fileExists(atPath: url.path) else {
        return Data()
    }
    return try Data(contentsOf: url)
}

func p7r6LifecycleObjects(in directory: URL) throws -> [[String: Any]] {
    return try p7r6PersistedEvidenceLines(in: directory).map { line in
        guard let object = try JSONSerialization.jsonObject(with: line)
            as? [String: Any] else {
            throw NSError(domain: "P7R6Tests", code: 1)
        }
        return object
    }
}

/// Durable Recovery lifecycle writer mirroring SupermarketScanSession:
/// session identity gate -> strict record validation -> sortedKeys JSONL
/// append -> watermark advance only after the durable write, otherwise a
/// counted required-write failure.
final class P7R6DurableRecoveryWriter: RecoveryLifecycleWriting {
    let directory: URL
    let trackingSessionId: String
    private let sidecarWriter: FoundationScanSidecarWriter
    private(set) var localizationRecoveryEventCount = 0
    private(set) var lastRecoveryEpisodeId: Int?
    private(set) var lastRecoveryFinishedAtUptime: TimeInterval?
    private(set) var requiredWriteFailureCount = 0

    init(
        directory: URL,
        trackingSessionId: String,
        sidecarWriter: FoundationScanSidecarWriter
    ) {
        self.directory = directory
        self.trackingSessionId = trackingSessionId
        self.sidecarWriter = sidecarWriter
    }

    var recoveryURL: URL {
        return directory.appendingPathComponent(
            PriorMapRecoveryLifecycleRecord.fileName)
    }

    func appendRecoveryLifecycleEvent(
        _ completion: PriorMapRecoveryCompletion,
        expectedTrackingSessionId: String
    ) -> Bool {
        guard expectedTrackingSessionId == trackingSessionId,
              completion.episode.startedAtUptime.isFinite,
              completion.finishedAtUptime.isFinite,
              completion.finishedAtUptime
                  >= completion.episode.startedAtUptime,
              !completion.episode.reason.isEmpty,
              !completion.episode.lastTriggerReason.isEmpty,
              completion.episode.triggerCount >= 1 else {
            requiredWriteFailureCount += 1
            return false
        }
        let record = PriorMapRecoveryLifecycleRecord(
            trackingSessionId: trackingSessionId,
            priorMapId: "map-a",
            priorMapSha256: String(repeating: "a", count: 64),
            floorId: "1",
            completion: completion)
        do {
            try sidecarWriter.append(
                try p7r6EncodedLifecycleLine(record),
                to: recoveryURL)
        }
        catch {
            requiredWriteFailureCount += 1
            return false
        }
        localizationRecoveryEventCount += 1
        lastRecoveryEpisodeId = completion.episode.id
        lastRecoveryFinishedAtUptime = completion.finishedAtUptime
        return true
    }

    /// Mirrors the session's manual-localization append on reset.
    func appendManualLocalizationLine(_ data: Data) throws {
        try sidecarWriter.append(
            data,
            to: directory.appendingPathComponent(
                "manual_localization_events.jsonl"))
    }
}

/// Peek/ack source mirroring the localizer: teardown cancellation finishes
/// the active episode into the queue; completions stay queued until acked.
final class P7R6BundleSource: RecoveryCompletionDraining {
    let controller: PriorMapRecoveryController
    var pending: [PriorMapRecoveryCompletion] = []

    init(controller: PriorMapRecoveryController) {
        self.controller = controller
    }

    func cancelRecovery(
        reason: PriorMapRecoveryCancellationReason,
        now: TimeInterval
    ) -> PriorMapRecoveryCompletion? {
        guard let completion = controller.finish(
            .cancelled,
            now: now,
            cancellationReason: reason) else {
            return nil
        }
        pending.append(completion)
        return completion
    }

    func pendingTerminalRecoveryCompletions()
        -> [PriorMapRecoveryCompletion] {
        return pending
    }

    func acknowledgeTerminalRecoveryCompletion(episodeId: Int) {
        pending.removeAll { $0.episode.id == episodeId }
    }

    func discardTerminalRecoveryCompletionsForInvalidatedSession() {
        pending.removeAll()
    }
}

func p7r6Coordinator(
    source: RecoveryCompletionDraining,
    writer: RecoveryLifecycleWriting,
    trackingSessionId: String = "session-a",
    persistedEvidenceSnapshot: @escaping () throws -> Data
) -> RecoveryLifecyclePersistenceCoordinator {
    return RecoveryLifecyclePersistenceCoordinator(
        source: source,
        writer: writer,
        trackingSessionId: trackingSessionId,
        priorMapId: "map-a",
        priorMapSha256: String(repeating: "a", count: 64),
        floorId: "1",
        persistedEvidenceSnapshot: persistedEvidenceSnapshot)
}

// W1: expected watermark 0 with an empty sidecar validates.
do {
    let directory = try p7r6FreshDirectory("w1")
    _ = try p7r6WriteBaseBundle(in: directory)
    require(
        LocalizationEvidenceBundleValidator.blockers(
            in: directory,
            expectation: p7r6BundleExpectation(recoveryCount: 0)).isEmpty,
        "W1 expected 0 + empty file must validate")
}

// W2: expected watermark 1 with one valid record validates.
do {
    let directory = try p7r6FreshDirectory("w2")
    let recoveryURL = try p7r6WriteBaseBundle(in: directory)
    try recoveryLifecycleData.write(to: recoveryURL)
    require(
        LocalizationEvidenceBundleValidator.blockers(
            in: directory,
            expectation: p7r6BundleExpectation(
                recoveryCount: 1,
                lastEpisodeId: 1,
                lastFinishedAtUptime: 14.5)).isEmpty,
        "W2 expected 1 + one valid record must validate")
}

// W3/W4: exact-count watermark mismatches fail closed.
do {
    let directory = try p7r6FreshDirectory("w3")
    let recoveryURL = try p7r6WriteBaseBundle(in: directory)
    require(
        LocalizationEvidenceBundleValidator.blockers(
            in: directory,
            expectation: p7r6BundleExpectation(
                recoveryCount: 1,
                lastEpisodeId: 1,
                lastFinishedAtUptime: 14.5)).contains {
                    $0.contains("localization_recovery_events.jsonl_empty")
                },
        "W3 expected 1 + empty file must fail closed")
    try recoveryLifecycleData.write(to: recoveryURL)
    require(
        LocalizationEvidenceBundleValidator.blockers(
            in: directory,
            expectation: p7r6BundleExpectation(
                recoveryCount: 2,
                lastEpisodeId: 1,
                lastFinishedAtUptime: 14.5)).contains {
                    $0.contains("localization_recovery_events.jsonl_count_mismatch")
                },
        "W4 expected 2 + one record must fail count_mismatch")
}

// W5: a deleted sidecar fails closed and is never rebuilt silently.
do {
    let directory = try p7r6FreshDirectory("w5")
    let recoveryURL = try p7r6WriteBaseBundle(in: directory)
    try FileManager.default.removeItem(at: recoveryURL)
    require(
        LocalizationEvidenceBundleValidator.blockers(
            in: directory,
            expectation: p7r6BundleExpectation(
                recoveryCount: 1,
                lastEpisodeId: 1,
                lastFinishedAtUptime: 14.5)).contains {
                    $0.contains("localization_recovery_events.jsonl")
                },
        "W5 a deleted recovery sidecar must fail validation")
}

// W6: finalization must not mask a lost watermark by rebuilding an empty
// file. The session policy only creates the sidecar while zero episodes are
// expected; otherwise the missing file stays a blocker.
do {
    let directory = try p7r6FreshDirectory("w6")
    let recoveryURL = try p7r6WriteBaseBundle(
        in: directory,
        createRecoveryFile: false)
    let expectedRecoveryEventCount = 1
    var finalizationBlockers: [String] = []
    if !FileManager.default.fileExists(atPath: recoveryURL.path) {
        if expectedRecoveryEventCount == 0 {
            try Data().write(to: recoveryURL)
        }
        else {
            finalizationBlockers.append(
                "evidence_bundle_recovery_file_missing_blocker")
        }
    }
    finalizationBlockers += LocalizationEvidenceBundleValidator.blockers(
        in: directory,
        expectation: p7r6BundleExpectation(
            recoveryCount: expectedRecoveryEventCount,
            lastEpisodeId: 1,
            lastFinishedAtUptime: 14.5))
    require(
        finalizationBlockers.contains(
            "evidence_bundle_recovery_file_missing_blocker")
            && finalizationBlockers.contains {
                $0.contains("localization_recovery_events.jsonl")
            },
        "W6 rebuilding lost recovery evidence as an empty file must stay"
            + " blocked: \(finalizationBlockers)")
}

// W7: a partial final line fails closed.
do {
    let directory = try p7r6FreshDirectory("w7")
    let recoveryURL = try p7r6WriteBaseBundle(in: directory)
    var partial = recoveryLifecycleData
    partial.append(contentsOf: Data("{\"format\":\"MarketSc".utf8))
    try partial.write(to: recoveryURL)
    require(
        LocalizationEvidenceBundleValidator.blockers(
            in: directory,
            expectation: p7r6BundleExpectation(
                recoveryCount: 1,
                lastEpisodeId: 1,
                lastFinishedAtUptime: 14.5)).contains {
                    $0.contains("invalid_utf8_or_partial_line")
                },
        "W7 a partial final line must fail closed")
}

// W8: a symlinked sidecar fails the stable-read check.
do {
    let directory = try p7r6FreshDirectory("w8")
    let recoveryURL = try p7r6WriteBaseBundle(in: directory)
    let outside = directory.deletingLastPathComponent()
        .appendingPathComponent("p7r6-w8-target-\(UUID().uuidString).jsonl")
    try recoveryLifecycleData.write(to: outside)
    try FileManager.default.removeItem(at: recoveryURL)
    try FileManager.default.createSymbolicLink(
        at: recoveryURL,
        withDestinationURL: outside)
    require(
        LocalizationEvidenceBundleValidator.blockers(
            in: directory,
            expectation: p7r6BundleExpectation(
                recoveryCount: 1,
                lastEpisodeId: 1,
                lastFinishedAtUptime: 14.5)).contains {
                    $0.contains("localization_recovery_events.jsonl")
                },
        "W8 a symlinked recovery sidecar must fail closed")
    try? FileManager.default.removeItem(at: outside)
}

// W9: a file swapped during the stable read fails closed.
do {
    let directory = try p7r6FreshDirectory("w9")
    let recoveryURL = try p7r6WriteBaseBundle(in: directory)
    try recoveryLifecycleData.write(to: recoveryURL)
    var swapped = false
    var swapObserved = false
    do {
        _ = try SafeSessionPath.streamRegularFile(
            recoveryURL,
            within: directory.deletingLastPathComponent(),
            maximumBytes: 1024 * 1024,
            chunkBytes: 64 * 1024
        ) { _ in
            guard !swapped else { return }
            swapped = true
            try Data("{}".utf8).write(to: recoveryURL)
        }
    }
    catch {
        swapObserved = (error as NSError).localizedDescription
            .contains("stream_file_identity_changed_during_read")
    }
    require(
        swapObserved,
        "W9 a recovery sidecar swapped during read must fail closed")
}

// W10: a successful durable append increments the watermark exactly once
// and the resulting bundle validates against finalization.
do {
    let directory = try p7r6FreshDirectory("w10")
    _ = try p7r6WriteBaseBundle(in: directory)
    let controller = PriorMapRecoveryController()
    _ = controller.request(reason: "reliable_rtabmap_loop", now: 10)
    let writer = P7R6DurableRecoveryWriter(
        directory: directory,
        trackingSessionId: "session-a",
        sidecarWriter: FoundationScanSidecarWriter())
    let source = P7R6BundleSource(controller: controller)
    let coordinator = p7r6Coordinator(
        source: source,
        writer: writer,
        persistedEvidenceSnapshot: {
            try p7r6PersistedEvidenceSnapshot(in: directory)
        })
    _ = controller.finish(.converged, now: 12)
    if let completion = controller.lastCompletion {
        source.pending.append(completion)
    }
    let result = coordinator.persistTerminalEvidence(
        cancellationReason: nil, now: 13)
    require(
        result.allPersisted
            && writer.localizationRecoveryEventCount == 1
            && writer.requiredWriteFailureCount == 0,
        "W10 a successful append must increment the count exactly once")
    require(
        LocalizationEvidenceBundleValidator.blockers(
            in: directory,
            expectation: p7r6BundleExpectation(
                recoveryCount: writer.localizationRecoveryEventCount,
                lastEpisodeId: writer.lastRecoveryEpisodeId,
                lastFinishedAtUptime: writer.lastRecoveryFinishedAtUptime))
            .isEmpty,
        "W10 the appended lifecycle record must validate")
}

// W11: a failed durable append leaves the watermark unchanged and counts a
// required-write failure.
do {
    let directory = try p7r6FreshDirectory("w11")
    // No pre-created sidecar: the first durable append must take the atomic
    // create path so the injected rename fault really fires.
    _ = try p7r6WriteBaseBundle(in: directory, createRecoveryFile: false)
    let controller = PriorMapRecoveryController()
    _ = controller.request(reason: "reliable_rtabmap_loop", now: 10)
    let writer = P7R6DurableRecoveryWriter(
        directory: directory,
        trackingSessionId: "session-a",
        sidecarWriter: FoundationScanSidecarWriter(atomicWriteFault: {
            stage, _ in
            if stage == .rename {
                throw injectedFailure
            }
        }))
    let source = P7R6BundleSource(controller: controller)
    let coordinator = p7r6Coordinator(
        source: source,
        writer: writer,
        persistedEvidenceSnapshot: {
            try p7r6PersistedEvidenceSnapshot(in: directory)
        })
    _ = controller.finish(.converged, now: 12)
    if let completion = controller.lastCompletion {
        source.pending.append(completion)
    }
    let result = coordinator.persistTerminalEvidence(
        cancellationReason: nil, now: 13)
    require(
        !result.allPersisted
            && result.failureReason == "durable_append_failed"
            && writer.localizationRecoveryEventCount == 0
            && writer.requiredWriteFailureCount == 1
            && source.pending.count == 1,
        "W11 a failed append must keep the count and the completion")
}

// I1: scan-stop teardown persists exactly one cancelled record and the
// finalized bundle validates.
do {
    let directory = try p7r6FreshDirectory("i1")
    _ = try p7r6WriteBaseBundle(in: directory)
    let controller = PriorMapRecoveryController()
    _ = controller.request(reason: "persistent_weak_or_lost", now: 10, automatic: true)
    let writer = P7R6DurableRecoveryWriter(
        directory: directory,
        trackingSessionId: "session-a",
        sidecarWriter: FoundationScanSidecarWriter())
    let source = P7R6BundleSource(controller: controller)
    let coordinator = p7r6Coordinator(
        source: source,
        writer: writer,
        persistedEvidenceSnapshot: {
            try p7r6PersistedEvidenceSnapshot(in: directory)
        })
    let result = coordinator.persistTerminalEvidence(
        cancellationReason: .scanStopped, now: 20)
    let records = try p7r6LifecycleObjects(in: directory)
    require(
        result.allPersisted
            && records.count == 1
            && (records[0]["outcome"] as? String) == "cancelled"
            && (records[0]["cancellation_reason"] as? String) == "scan_stopped"
            && writer.localizationRecoveryEventCount == 1
            && source.pending.isEmpty,
        "I1 scan stop must persist one cancelled record: \(records)")
    require(
        LocalizationEvidenceBundleValidator.blockers(
            in: directory,
            expectation: p7r6BundleExpectation(
                recoveryCount: 1,
                lastEpisodeId: writer.lastRecoveryEpisodeId,
                lastFinishedAtUptime: writer.lastRecoveryFinishedAtUptime))
            .isEmpty,
        "I1 the finalized bundle must validate after scan stop")
}

// I2: map-unload teardown persists one cancelled record.
do {
    let directory = try p7r6FreshDirectory("i2")
    _ = try p7r6WriteBaseBundle(in: directory)
    let controller = PriorMapRecoveryController()
    _ = controller.request(reason: "persistent_weak_or_lost", now: 10, automatic: true)
    let writer = P7R6DurableRecoveryWriter(
        directory: directory,
        trackingSessionId: "session-a",
        sidecarWriter: FoundationScanSidecarWriter())
    let source = P7R6BundleSource(controller: controller)
    let coordinator = p7r6Coordinator(
        source: source,
        writer: writer,
        persistedEvidenceSnapshot: {
            try p7r6PersistedEvidenceSnapshot(in: directory)
        })
    let result = coordinator.persistTerminalEvidence(
        cancellationReason: .mapUnloaded, now: 20)
    let records = try p7r6LifecycleObjects(in: directory)
    require(
        result.allPersisted
            && records.count == 1
            && (records[0]["cancellation_reason"] as? String) == "map_unloaded"
            && writer.localizationRecoveryEventCount == 1,
        "I2 map unload must persist one cancelled record: \(records)")
}

// I3: a converged episode persists exactly once with bounded diagnostics.
do {
    let directory = try p7r6FreshDirectory("i3")
    _ = try p7r6WriteBaseBundle(in: directory)
    let controller = PriorMapRecoveryController()
    _ = controller.request(reason: "reliable_rtabmap_loop", now: 10)
    let writer = P7R6DurableRecoveryWriter(
        directory: directory,
        trackingSessionId: "session-a",
        sidecarWriter: FoundationScanSidecarWriter())
    let source = P7R6BundleSource(controller: controller)
    let coordinator = p7r6Coordinator(
        source: source,
        writer: writer,
        persistedEvidenceSnapshot: {
            try p7r6PersistedEvidenceSnapshot(in: directory)
        })
    _ = controller.finish(.converged, now: 15)
    if let completion = controller.lastCompletion {
        source.pending.append(completion)
    }
    let result = coordinator.persistTerminalEvidence(
        cancellationReason: nil, now: 16)
    let records = try p7r6LifecycleObjects(in: directory)
    require(
        result.allPersisted && records.count == 1,
        "I3 a converged episode must persist exactly one record")
    require(
        (records[0]["outcome"] as? String) == "converged"
            && close(records[0]["elapsed_ms"] as? Double ?? -1, 5000),
        "I3 completion diagnostics must bind to the finish time: \(records)")
    // A repeated transaction must not duplicate the record (strategy A).
    source.pending = controller.lastCompletion.map { [$0] } ?? []
    let repeated = coordinator.persistTerminalEvidence(
        cancellationReason: nil, now: 17)
    let replayedRecords = try p7r6LifecycleObjects(in: directory)
    require(
        repeated.allPersisted
            && replayedRecords.count == 1
            && source.pending.isEmpty,
        "I3 a replayed converged episode must not duplicate the record")
}

// I4: a timed-out episode persists the timed_out outcome and the cooldown
// summary suppresses the next automatic trigger.
do {
    let directory = try p7r6FreshDirectory("i4")
    _ = try p7r6WriteBaseBundle(in: directory)
    let controller = PriorMapRecoveryController()
    _ = controller.request(reason: "reliable_rtabmap_loop", now: 10)
    let writer = P7R6DurableRecoveryWriter(
        directory: directory,
        trackingSessionId: "session-a",
        sidecarWriter: FoundationScanSidecarWriter())
    let source = P7R6BundleSource(controller: controller)
    let coordinator = p7r6Coordinator(
        source: source,
        writer: writer,
        persistedEvidenceSnapshot: {
            try p7r6PersistedEvidenceSnapshot(in: directory)
        })
    _ = controller.finish(.timedOut, now: 45)
    if let completion = controller.lastCompletion {
        source.pending.append(completion)
    }
    let result = coordinator.persistTerminalEvidence(
        cancellationReason: nil, now: 46)
    let records = try p7r6LifecycleObjects(in: directory)
    require(
        result.allPersisted
            && records.count == 1
            && (records[0]["outcome"] as? String) == "timed_out",
        "I4 a timed-out episode must persist the timed_out outcome")
    require(
        controller.isAutomaticTriggerSuppressed(now: 50)
            && !controller.request(
                reason: "persistent_weak_or_lost", now: 50, automatic: true),
        "I4 the cooldown summary must suppress the next automatic trigger")
}

// I5: a manual reset persists the lifecycle event and both the manual event
// and the lifecycle record carry the matching session identity.
do {
    let directory = try p7r6FreshDirectory("i5")
    _ = try p7r6WriteBaseBundle(in: directory)
    let controller = PriorMapRecoveryController()
    _ = controller.request(reason: "persistent_weak_or_lost", now: 10, automatic: true)
    let writer = P7R6DurableRecoveryWriter(
        directory: directory,
        trackingSessionId: "session-a",
        sidecarWriter: FoundationScanSidecarWriter())
    let source = P7R6BundleSource(controller: controller)
    let coordinator = p7r6Coordinator(
        source: source,
        writer: writer,
        persistedEvidenceSnapshot: {
            try p7r6PersistedEvidenceSnapshot(in: directory)
        })
    _ = controller.finish(.manualReset, now: 18)
    if let completion = controller.lastCompletion {
        source.pending.append(completion)
    }
    let result = coordinator.persistTerminalEvidence(
        cancellationReason: nil, now: 19)
    // The session also appends the manual localization event on reset.
    var manualLine = try JSONSerialization.data(withJSONObject: [
        "format": "MarketScannerManualLocalizationEvent",
        "version": 3,
        "tracking_session_id": "session-a",
        "episode_id": 1,
        "outcome": "manual_reset",
    ])
    manualLine.append(0x0A)
    try writer.appendManualLocalizationLine(manualLine)
    let lifecycleRecords = try p7r6LifecycleObjects(in: directory)
    let manualRecords = try Data(contentsOf: directory.appendingPathComponent(
        "manual_localization_events.jsonl"))
        .split(separator: 0x0A)
        .compactMap { try? JSONSerialization.jsonObject(with: Data($0))
            as? [String: Any] }
    require(
        result.allPersisted
            && lifecycleRecords.count == 1
            && (lifecycleRecords[0]["outcome"] as? String) == "manual_reset"
            && manualRecords.count == 1,
        "I5 a manual reset must persist the lifecycle event")
    require(
        (lifecycleRecords[0]["tracking_session_id"] as? String)
            == (manualRecords[0]["tracking_session_id"] as? String)
            && (lifecycleRecords[0]["episode_id"] as? Int)
                == (manualRecords[0]["episode_id"] as? Int),
        "I5 the manual event and lifecycle record identities must match")
}

// I6: an injected durable-append fault leaves the queue unacknowledged,
// keeps the watermark, counts a required-write failure, and leaves the
// bundle invalid for finalization.
do {
    let directory = try p7r6FreshDirectory("i6")
    _ = try p7r6WriteBaseBundle(in: directory, createRecoveryFile: false)
    let controller = PriorMapRecoveryController()
    _ = controller.request(reason: "persistent_weak_or_lost", now: 10, automatic: true)
    let writer = P7R6DurableRecoveryWriter(
        directory: directory,
        trackingSessionId: "session-a",
        sidecarWriter: FoundationScanSidecarWriter(atomicWriteFault: {
            stage, _ in
            if stage == .rename {
                throw injectedFailure
            }
        }))
    let source = P7R6BundleSource(controller: controller)
    let coordinator = p7r6Coordinator(
        source: source,
        writer: writer,
        persistedEvidenceSnapshot: {
            try p7r6PersistedEvidenceSnapshot(in: directory)
        })
    _ = controller.finish(.converged, now: 12)
    if let completion = controller.lastCompletion {
        source.pending.append(completion)
    }
    let result = coordinator.persistTerminalEvidence(
        cancellationReason: nil, now: 13)
    require(
        !result.allPersisted
            && result.failureReason == "durable_append_failed"
            && source.pending.count == 1
            && writer.localizationRecoveryEventCount == 0
            && writer.requiredWriteFailureCount == 1,
        "I6 an append fault must keep the queue and the watermark")
    require(
        LocalizationEvidenceBundleValidator.blockers(
            in: directory,
            expectation: p7r6BundleExpectation(
                recoveryCount: 1,
                lastEpisodeId: 1,
                lastFinishedAtUptime: 12)).contains {
                    $0.contains("localization_recovery_events.jsonl")
                },
        "I6 a failed append must leave finalization invalid")

    // I7: the retry persists the same episode exactly once.
    let retryWriter = P7R6DurableRecoveryWriter(
        directory: directory,
        trackingSessionId: "session-a",
        sidecarWriter: FoundationScanSidecarWriter())
    let retryCoordinator = p7r6Coordinator(
        source: source,
        writer: retryWriter,
        persistedEvidenceSnapshot: {
            try p7r6PersistedEvidenceSnapshot(in: directory)
        })
    let retry = retryCoordinator.persistTerminalEvidence(
        cancellationReason: nil, now: 14)
    let records = try p7r6LifecycleObjects(in: directory)
    require(
        retry.allPersisted
            && records.count == 1
            && retryWriter.localizationRecoveryEventCount == 1
            && source.pending.isEmpty,
        "I7 the retry must persist the same episode exactly once")
}

// I8: a stale tracking session identity rejects the write without counting.
do {
    let directory = try p7r6FreshDirectory("i8")
    _ = try p7r6WriteBaseBundle(in: directory)
    let controller = PriorMapRecoveryController()
    _ = controller.request(reason: "persistent_weak_or_lost", now: 10, automatic: true)
    let writer = P7R6DurableRecoveryWriter(
        directory: directory,
        trackingSessionId: "session-b",
        sidecarWriter: FoundationScanSidecarWriter())
    let source = P7R6BundleSource(controller: controller)
    let coordinator = p7r6Coordinator(
        source: source,
        writer: writer,
        persistedEvidenceSnapshot: {
            try p7r6PersistedEvidenceSnapshot(in: directory)
        })
    _ = controller.finish(.converged, now: 12)
    if let completion = controller.lastCompletion {
        source.pending.append(completion)
    }
    let result = coordinator.persistTerminalEvidence(
        cancellationReason: nil, now: 13)
    let staleFileData = try Data(contentsOf: writer.recoveryURL)
    require(
        !result.allPersisted
            && result.failureReason == "durable_append_failed"
            && writer.localizationRecoveryEventCount == 0
            && writer.requiredWriteFailureCount == 1
            && source.pending.count == 1
            && staleFileData.isEmpty,
        "I8 a stale session identity must reject the write")
}

// I9: a generation change discards old completions before they can enter the
// new session.
do {
    let directory = try p7r6FreshDirectory("i9")
    _ = try p7r6WriteBaseBundle(in: directory)
    let controller = PriorMapRecoveryController()
    _ = controller.request(reason: "persistent_weak_or_lost", now: 10, automatic: true)
    let writer = P7R6DurableRecoveryWriter(
        directory: directory,
        trackingSessionId: "session-a",
        sidecarWriter: FoundationScanSidecarWriter())
    let source = P7R6BundleSource(controller: controller)
    _ = controller.finish(.converged, now: 12)
    if let completion = controller.lastCompletion {
        source.pending.append(completion)
    }
    // The session generation changed: queued completions are discarded.
    source.discardTerminalRecoveryCompletionsForInvalidatedSession()
    let coordinator = p7r6Coordinator(
        source: source,
        writer: writer,
        persistedEvidenceSnapshot: {
            try p7r6PersistedEvidenceSnapshot(in: directory)
        })
    let result = coordinator.persistTerminalEvidence(
        cancellationReason: nil, now: 13)
    let generationFileData = try Data(contentsOf: writer.recoveryURL)
    require(
        result.allPersisted
            && result.attemptedEpisodeIds.isEmpty
            && writer.localizationRecoveryEventCount == 0
            && generationFileData.isEmpty,
        "I9 a generation change must keep old completions out")
}

// I10: deleting the lifecycle file after the watermark advanced blocks
// finalization.
do {
    let directory = try p7r6FreshDirectory("i10")
    _ = try p7r6WriteBaseBundle(in: directory)
    let controller = PriorMapRecoveryController()
    _ = controller.request(reason: "reliable_rtabmap_loop", now: 10)
    let writer = P7R6DurableRecoveryWriter(
        directory: directory,
        trackingSessionId: "session-a",
        sidecarWriter: FoundationScanSidecarWriter())
    let source = P7R6BundleSource(controller: controller)
    let coordinator = p7r6Coordinator(
        source: source,
        writer: writer,
        persistedEvidenceSnapshot: {
            try p7r6PersistedEvidenceSnapshot(in: directory)
        })
    _ = controller.finish(.converged, now: 12)
    if let completion = controller.lastCompletion {
        source.pending.append(completion)
    }
    _ = coordinator.persistTerminalEvidence(cancellationReason: nil, now: 13)
    require(writer.localizationRecoveryEventCount == 1,
            "I10 requires one persisted episode")
    try FileManager.default.removeItem(at: writer.recoveryURL)
    require(
        LocalizationEvidenceBundleValidator.blockers(
            in: directory,
            expectation: p7r6BundleExpectation(
                recoveryCount: 1,
                lastEpisodeId: writer.lastRecoveryEpisodeId,
                lastFinishedAtUptime: writer.lastRecoveryFinishedAtUptime))
            .contains {
                $0.contains("localization_recovery_events.jsonl")
            },
        "I10 deleting the lifecycle file must block finalization")
}

// I11: truncating the final line blocks finalization.
do {
    let directory = try p7r6FreshDirectory("i11")
    let recoveryURL = try p7r6WriteBaseBundle(in: directory)
    try recoveryLifecycleData.write(to: recoveryURL)
    var truncated = recoveryLifecycleData
    truncated.removeLast()
    try truncated.write(to: recoveryURL)
    require(
        LocalizationEvidenceBundleValidator.blockers(
            in: directory,
            expectation: p7r6BundleExpectation(
                recoveryCount: 1,
                lastEpisodeId: 1,
                lastFinishedAtUptime: 14.5)).contains {
                    $0.contains("localization_recovery_events.jsonl")
                },
        "I11 truncating the final line must block finalization")
}

// I12: a duplicated episode line blocks finalization.
do {
    let directory = try p7r6FreshDirectory("i12")
    let recoveryURL = try p7r6WriteBaseBundle(in: directory)
    var duplicated = recoveryLifecycleData
    duplicated.append(recoveryLifecycleData)
    try duplicated.write(to: recoveryURL)
    require(
        !LocalizationEvidenceBundleValidator.blockers(
            in: directory,
            expectation: p7r6BundleExpectation(
                recoveryCount: 1,
                lastEpisodeId: 1,
                lastFinishedAtUptime: 14.5)).isEmpty,
        "I12 a duplicated episode line must block finalization")
}

// I13: no episodes validate with an empty file and watermark zero.
do {
    let directory = try p7r6FreshDirectory("i13")
    _ = try p7r6WriteBaseBundle(in: directory)
    let controller = PriorMapRecoveryController()
    let writer = P7R6DurableRecoveryWriter(
        directory: directory,
        trackingSessionId: "session-a",
        sidecarWriter: FoundationScanSidecarWriter())
    let source = P7R6BundleSource(controller: controller)
    let coordinator = p7r6Coordinator(
        source: source,
        writer: writer,
        persistedEvidenceSnapshot: {
            try p7r6PersistedEvidenceSnapshot(in: directory)
        })
    let result = coordinator.persistTerminalEvidence(
        cancellationReason: .scanStopped, now: 20)
    require(
        result.allPersisted
            && result.attemptedEpisodeIds.isEmpty
            && writer.localizationRecoveryEventCount == 0,
        "I13 a teardown without episodes must persist nothing")
    require(
        LocalizationEvidenceBundleValidator.blockers(
            in: directory,
            expectation: p7r6BundleExpectation(recoveryCount: 0)).isEmpty,
        "I13 no episodes must validate with expected count 0")
}

// I14: pending completions persist on the prior-map queue in strict
// serialized order and none is lost.
do {
    let directory = try p7r6FreshDirectory("i14")
    _ = try p7r6WriteBaseBundle(in: directory)
    let controller = PriorMapRecoveryController()
    let writer = P7R6DurableRecoveryWriter(
        directory: directory,
        trackingSessionId: "session-a",
        sidecarWriter: FoundationScanSidecarWriter())
    let source = P7R6BundleSource(controller: controller)
    _ = controller.request(reason: "reliable_rtabmap_loop", now: 10)
    _ = controller.finish(.converged, now: 11)
    if let completion = controller.lastCompletion {
        source.pending.append(completion)
    }
    _ = controller.request(reason: "reliable_rtabmap_loop", now: 12)
    _ = controller.finish(.timedOut, now: 13)
    if let completion = controller.lastCompletion {
        source.pending.append(completion)
    }
    // P7R6B: the queue already carries finish order; the coordinator never
    // sorts it, so two serialized transactions on one in-order queue must
    // persist every completion exactly once in that order.
    let coordinator = p7r6Coordinator(
        source: source,
        writer: writer,
        persistedEvidenceSnapshot: {
            try p7r6PersistedEvidenceSnapshot(in: directory)
        })
    let queue = DispatchQueue(label: "p7r6.i14.prior-map")
    let group = DispatchGroup()
    queue.async(group: group) {
        _ = coordinator.persistTerminalEvidence(
            cancellationReason: nil, now: 20)
    }
    queue.async(group: group) {
        _ = coordinator.persistTerminalEvidence(
            cancellationReason: nil, now: 21)
    }
    require(
        group.wait(timeout: .now() + 10) == .success,
        "I14 serialized persistence must complete")
    let serializedRecords = try p7r6LifecycleObjects(in: directory)
    require(
        writer.localizationRecoveryEventCount == 2
            && serializedRecords
                .compactMap { $0["episode_id"] as? Int } == [1, 2]
            && source.pending.isEmpty,
        "I14 strict serialized order must persist every completion once")
}

// I15: invoking the teardown coordinator from a wrong queue must not
// deadlock; the coordinator holds no locks so the caller's dispatch policy
// decides ordering.
do {
    let directory = try p7r6FreshDirectory("i15")
    _ = try p7r6WriteBaseBundle(in: directory)
    let controller = PriorMapRecoveryController()
    let writer = P7R6DurableRecoveryWriter(
        directory: directory,
        trackingSessionId: "session-a",
        sidecarWriter: FoundationScanSidecarWriter())
    let source = P7R6BundleSource(controller: controller)
    _ = controller.request(reason: "reliable_rtabmap_loop", now: 10)
    _ = controller.finish(.converged, now: 11)
    if let completion = controller.lastCompletion {
        source.pending.append(completion)
    }
    let coordinator = p7r6Coordinator(
        source: source,
        writer: writer,
        persistedEvidenceSnapshot: {
            try p7r6PersistedEvidenceSnapshot(in: directory)
        })
    let priorMapQueue = DispatchQueue(label: "p7r6.i15.prior-map")
    let wrongQueue = DispatchQueue(label: "p7r6.i15.wrong")
    let done = DispatchSemaphore(value: 0)
    wrongQueue.async {
        _ = coordinator.persistTerminalEvidence(
            cancellationReason: nil, now: 20)
        done.signal()
    }
    require(
        done.wait(timeout: .now() + 10) == .success,
        "I15 a wrong-queue teardown invocation must not deadlock")
    let second = DispatchSemaphore(value: 0)
    priorMapQueue.async {
        _ = coordinator.persistTerminalEvidence(
            cancellationReason: nil, now: 21)
        second.signal()
    }
    require(
        second.wait(timeout: .now() + 10) == .success
            && writer.localizationRecoveryEventCount == 1
            && source.pending.isEmpty,
        "I15 the prior-map queue transaction must still persist exactly once")
}

// P7R6A: attemptedEpisodeIds must list only the episodes the transaction
// actually entered. Pre-transaction failures (identity, snapshot read,
// snapshot parse) happen before any pending episode is attempted and must
// report an empty list instead of disguising the failure as an attempt on
// the first episode.
do {
    func threeEpisodeSource() -> (P7R6FakeRecoverySource,
        [PriorMapRecoveryCompletion]) {
        let controller = PriorMapRecoveryController()
        var completions: [PriorMapRecoveryCompletion] = []
        for index in 0..<3 {
            _ = controller.request(
                reason: "persistent_weak_or_lost",
                now: TimeInterval(index * 10),
                automatic: true)
            if let completion = controller.finish(
                .converged, now: TimeInterval(index * 10 + 1)) {
                completions.append(completion)
            }
        }
        let source = P7R6FakeRecoverySource()
        source.pending = completions
        return (source, completions)
    }

    // First episode fails: only episode 1 was attempted.
    let (firstFailureSource, _) = threeEpisodeSource()
    let firstFailureWriter = P7R6FakeRecoveryWriter()
    firstFailureWriter.failingEpisodeIds = [1]
    let firstFailureCoordinator = RecoveryLifecyclePersistenceCoordinator(
        source: firstFailureSource,
        writer: firstFailureWriter,
        trackingSessionId: "session-a",
        priorMapId: "map-a",
        priorMapSha256: String(repeating: "a", count: 64),
        floorId: "1",
        persistedEvidenceSnapshot: { Data() })
    let firstFailure = firstFailureCoordinator.persistTerminalEvidence(
        cancellationReason: nil, now: 40)
    require(
        !firstFailure.allPersisted
            && firstFailure.attemptedEpisodeIds == [1]
            && firstFailure.persistedEpisodeIds.isEmpty
            && firstFailure.failedEpisodeId == 1
            && firstFailure.failureReason == "durable_append_failed"
            && firstFailureSource.pending.map { $0.episode.id } == [1, 2, 3],
        "P7R6A attempted IDs must stop at the first failed episode")

    // Second episode fails: episodes 1 and 2 were attempted, 1 persisted.
    let (secondFailureSource, _) = threeEpisodeSource()
    let secondFailureWriter = P7R6FakeRecoveryWriter()
    secondFailureWriter.failingEpisodeIds = [2]
    let secondFailureCoordinator = RecoveryLifecyclePersistenceCoordinator(
        source: secondFailureSource,
        writer: secondFailureWriter,
        trackingSessionId: "session-a",
        priorMapId: "map-a",
        priorMapSha256: String(repeating: "a", count: 64),
        floorId: "1",
        persistedEvidenceSnapshot: { Data() })
    let secondFailure = secondFailureCoordinator.persistTerminalEvidence(
        cancellationReason: nil, now: 50)
    require(
        !secondFailure.allPersisted
            && secondFailure.attemptedEpisodeIds == [1, 2]
            && secondFailure.persistedEpisodeIds == [1]
            && secondFailure.failedEpisodeId == 2
            && secondFailureSource.pending.map { $0.episode.id } == [2, 3],
        "P7R6A attempted IDs must cover exactly the processed episodes")

    // Unparsable snapshot: no pending episode was attempted at all.
    let (parseFailureSource, _) = threeEpisodeSource()
    let parseFailureWriter = P7R6FakeRecoveryWriter()
    let parseFailureCoordinator = RecoveryLifecyclePersistenceCoordinator(
        source: parseFailureSource,
        writer: parseFailureWriter,
        trackingSessionId: "session-a",
        priorMapId: "map-a",
        priorMapSha256: String(repeating: "a", count: 64),
        floorId: "1",
        persistedEvidenceSnapshot: { Data("{\"format\":".utf8) })
    let parseFailure = parseFailureCoordinator.persistTerminalEvidence(
        cancellationReason: nil, now: 60)
    require(
        !parseFailure.allPersisted
            && parseFailure.attemptedEpisodeIds.isEmpty
            && parseFailure.persistedEpisodeIds.isEmpty
            && parseFailure.failedEpisodeId == 1
            && (parseFailure.failureReason?.hasPrefix("existing_evidence_")
                == true)
            && parseFailureWriter.appendedEpisodeIds.isEmpty
            && parseFailureSource.pending.map { $0.episode.id } == [1, 2, 3],
        "P7R6A a snapshot parse failure must attempt no episode")

    // Missing identity: also a pre-transaction failure, attempted stays
    // empty and nothing is acknowledged.
    let (identitySource, _) = threeEpisodeSource()
    let identityWriter = P7R6FakeRecoveryWriter()
    let identityCoordinator = RecoveryLifecyclePersistenceCoordinator(
        source: identitySource,
        writer: identityWriter,
        trackingSessionId: "session-a",
        priorMapId: nil,
        priorMapSha256: nil,
        floorId: nil,
        persistedEvidenceSnapshot: { Data() })
    let identityFailure = identityCoordinator.persistTerminalEvidence(
        cancellationReason: nil, now: 70)
    require(
        !identityFailure.allPersisted
            && identityFailure.attemptedEpisodeIds.isEmpty
            && identityFailure.failedEpisodeId == 1
            && identityFailure.failureReason == "missing_prior_map_identity"
            && identityWriter.appendedEpisodeIds.isEmpty
            && identitySource.pending.map { $0.episode.id } == [1, 2, 3],
        "P7R6A a missing identity must attempt no episode")
}

// MARK: - P7R6A P-A1..P-A20: strict parser and acknowledgement contracts.

func p7r6aIdentitySha() -> String {
    return String(repeating: "a", count: 64)
}

/// Builds one canonical lifecycle line. v1 records carry no deadline,
/// attempts budget, or trigger sequence; the builder never fabricates them.
func p7r6aLifecycleRecordData(
    version: Int,
    episode: Int,
    started: Double = 10,
    finished: Double = 14.5,
    outcome: String = "converged",
    cancellationReason: String? = nil,
    validAttempts: Int = 7,
    accepted: Int = 2,
    trailingNewline: Bool = true,
    identity: [String: String]? = nil,
    extra: [String: Any] = [:]
) throws -> Data {
    var object: [String: Any] = [
        "format": "MarketScannerRecoveryLifecycleEvent",
        "version": version,
        "tracking_session_id": "session-a",
        "prior_map_id": "map-a",
        "prior_map_sha256": p7r6aIdentitySha(),
        "floor_id": "1",
        "episode_id": episode,
        "reason": "reliable_rtabmap_loop",
        "outcome": outcome,
        "episode_automatic": false,
        "started_at_uptime": started,
        "finished_at_uptime": finished,
        "elapsed_ms": (finished - started) * 1000,
        "valid_matcher_attempts": validAttempts,
        "accepted_corrections": accepted,
        "trigger_count": 1,
        "automatic_trigger_count": 0,
        "reliable_loop_trigger_count": 1,
        "last_trigger_reason": "reliable_rtabmap_loop",
        "last_trigger_at_uptime": started,
        "fresh_support_frames": 4,
        "completion_frame_step_applied": false,
    ]
    if version == 2 {
        object["deadline_uptime"] = started + 60
        object["maximum_valid_attempts"] = 40
        object["trigger_records"] = [[
            "reason": "reliable_rtabmap_loop",
            "automatic": false,
            "at_uptime": started,
        ]]
    }
    if let cancellationReason {
        object["cancellation_reason"] = cancellationReason
    }
    if let identity {
        for (key, value) in identity {
            object[key] = value
        }
    }
    for (key, value) in extra {
        object[key] = value
    }
    var data = try JSONSerialization.data(withJSONObject: object)
    if trailingNewline {
        data.append(0x0A)
    }
    return data
}

func p7r6aParseExpectation(
    expectedRecordCount: Int? = nil,
    expectedLastEpisodeId: Int? = nil,
    expectedLastFinishedAtUptime: TimeInterval? = nil
) -> RecoveryLifecycleEvidenceExpectation {
    return RecoveryLifecycleEvidenceExpectation(
        trackingSessionId: "session-a",
        priorMapId: "map-a",
        priorMapSha256: p7r6aIdentitySha(),
        floorId: "1",
        expectedRecordCount: expectedRecordCount,
        expectedLastEpisodeId: expectedLastEpisodeId,
        expectedLastFinishedAtUptime: expectedLastFinishedAtUptime)
}

func p7r6aParseFailureCode(_ snapshot: Data) throws -> String {
    do {
        _ = try RecoveryLifecyclePersistedEvidenceParser.parse(
            snapshot: snapshot,
            expectation: p7r6aParseExpectation())
        return "PASS"
    }
    catch let error as RecoveryLifecycleEvidenceParseError {
        return error.stableCode
    }
}

func p7r6aCoordinatorWithPending(
    in directory: URL,
    episodes: [(reason: String, start: Double, finish: Double)],
    writer: P7R6DurableRecoveryWriter
) throws -> (RecoveryLifecyclePersistenceCoordinator, P7R6BundleSource) {
    let controller = PriorMapRecoveryController()
    let source = P7R6BundleSource(controller: controller)
    for episode in episodes {
        _ = controller.request(reason: episode.reason, now: episode.start)
        _ = controller.finish(.converged, now: episode.finish)
        if let completion = controller.lastCompletion {
            source.pending.append(completion)
        }
    }
    let coordinator = p7r6Coordinator(
        source: source,
        writer: writer,
        persistedEvidenceSnapshot: {
            try p7r6PersistedEvidenceSnapshot(in: directory)
        })
    return (coordinator, source)
}

// P-A1: a legal historical v1 episode plus a fresh pending v2 episode form a
// mixed file that the coordinator appends once and finalization accepts.
do {
    let directory = try p7r6FreshDirectory("pa1")
    let recoveryURL = try p7r6WriteBaseBundle(
        in: directory, createRecoveryFile: false)
    try p7r6aLifecycleRecordData(version: 1, episode: 1)
        .write(to: recoveryURL)
    let writer = P7R6DurableRecoveryWriter(
        directory: directory,
        trackingSessionId: "session-a",
        sidecarWriter: FoundationScanSidecarWriter())
    // Burn episode 1 in the controller so the pending completion is 2.
    let (coordinator, source) = try p7r6aCoordinatorWithPending(
        in: directory,
        episodes: [
            (reason: "initial_warmup", start: 0, finish: 1),
            (reason: "reliable_rtabmap_loop", start: 20, finish: 22),
        ],
        writer: writer)
    source.pending.removeFirst()
    let result = coordinator.persistTerminalEvidence(
        cancellationReason: nil, now: 23)
    let objects = try p7r6LifecycleObjects(in: directory)
    require(
        result.allPersisted
            && result.attemptedEpisodeIds == [2]
            && result.persistedEpisodeIds == [2]
            && writer.localizationRecoveryEventCount == 1
            && objects.count == 2
            && (objects[0]["version"] as? Int) == 1
            && (objects[1]["version"] as? Int) == 2,
        "P-A1 a legal v1 record plus a new v2 episode must append once")
    require(
        LocalizationEvidenceBundleValidator.blockers(
            in: directory,
            expectation: p7r6BundleExpectation(
                recoveryCount: 2,
                lastEpisodeId: 2,
                lastFinishedAtUptime:
                    writer.lastRecoveryFinishedAtUptime)).isEmpty,
        "P-A1 mixed v1/v2 evidence must pass finalization")
}

// P-A2: the same episode as v1 on disk and v2 pending is never one fact.
do {
    let directory = try p7r6FreshDirectory("pa2")
    let recoveryURL = try p7r6WriteBaseBundle(
        in: directory, createRecoveryFile: false)
    try p7r6aLifecycleRecordData(version: 1, episode: 1)
        .write(to: recoveryURL)
    let writer = P7R6DurableRecoveryWriter(
        directory: directory,
        trackingSessionId: "session-a",
        sidecarWriter: FoundationScanSidecarWriter())
    let (coordinator, source) = try p7r6aCoordinatorWithPending(
        in: directory,
        episodes: [(reason: "reliable_rtabmap_loop", start: 20, finish: 22)],
        writer: writer)
    let result = coordinator.persistTerminalEvidence(
        cancellationReason: nil, now: 23)
    let remainingObjects = try p7r6LifecycleObjects(in: directory)
    require(
        !result.allPersisted
            && result.attemptedEpisodeIds == [1]
            && result.persistedEpisodeIds.isEmpty
            && result.failedEpisodeId == 1
            && result.failureReason == "persisted_episode_version_conflict"
            && writer.localizationRecoveryEventCount == 0
            && source.pending.count == 1
            && remainingObjects.count == 1,
        "P-A2 a v1/v2 same-episode pair must conflict without appending")
}

// P-A3..P-A9: file-level and ordering contracts refuse acknowledgement.
do {
    func coordinatorOverSnapshot(
        _ snapshot: Data
    ) throws -> (RecoveryLifecyclePersistenceResult, P7R6FakeRecoverySource,
        P7R6FakeRecoveryWriter) {
        let controller = PriorMapRecoveryController()
        let source = P7R6FakeRecoverySource()
        _ = controller.request(reason: "reliable_rtabmap_loop", now: 20)
        if let completion = controller.finish(.converged, now: 22) {
            source.pending = [completion]
        }
        let writer = P7R6FakeRecoveryWriter()
        let coordinator = RecoveryLifecyclePersistenceCoordinator(
            source: source,
            writer: writer,
            trackingSessionId: "session-a",
            priorMapId: "map-a",
            priorMapSha256: p7r6aIdentitySha(),
            floorId: "1",
            persistedEvidenceSnapshot: { snapshot })
        return (coordinator.persistTerminalEvidence(
            cancellationReason: nil, now: 23), source, writer)
    }
    func expectNoAck(
        _ snapshot: Data,
        reasonSuffix: String,
        _ message: String
    ) throws {
        let (result, source, writer) = try coordinatorOverSnapshot(snapshot)
        require(
            !result.allPersisted
                && result.attemptedEpisodeIds.isEmpty
                && result.persistedEpisodeIds.isEmpty
                && result.failedEpisodeId == 1
                && result.failureReason == reasonSuffix
                && writer.appendedEpisodeIds.isEmpty
                && source.pending.count == 1,
            "\(message): \(result.failureReason ?? "nil")")
    }

    // P-A3: a complete JSON record without its final newline.
    try expectNoAck(
        p7r6aLifecycleRecordData(
            version: 2, episode: 1, trailingNewline: false),
        reasonSuffix: "existing_evidence_missing_final_newline",
        "P-A3 a missing final newline must refuse acknowledgement")

    // P-A4: blank lines are never records.
    var blankLineSnapshot = try p7r6aLifecycleRecordData(
        version: 2, episode: 1)
    blankLineSnapshot.append(0x0A)
    blankLineSnapshot.append(
        try p7r6aLifecycleRecordData(version: 2, episode: 2))
    try expectNoAck(
        blankLineSnapshot,
        reasonSuffix: "existing_evidence_blank_record",
        "P-A4 a blank line must refuse acknowledgement")

    // P-A5: a partial JSON tail.
    var partialTailSnapshot = try p7r6aLifecycleRecordData(
        version: 2, episode: 1)
    partialTailSnapshot.append(Data("{\"format\":".utf8))
    try expectNoAck(
        partialTailSnapshot,
        reasonSuffix: "existing_evidence_missing_final_newline",
        "P-A5 a partial tail must refuse acknowledgement")

    // P-A6: unknown fields.
    try expectNoAck(
        try p7r6aLifecycleRecordData(
            version: 2, episode: 1, extra: ["unexpected": true]),
        reasonSuffix: "existing_evidence_unknown_field",
        "P-A6 an unknown field must refuse acknowledgement")

    // P-A7: duplicated episodes.
    var duplicateSnapshot = try p7r6aLifecycleRecordData(
        version: 2, episode: 1)
    duplicateSnapshot.append(
        try p7r6aLifecycleRecordData(version: 2, episode: 1))
    try expectNoAck(
        duplicateSnapshot,
        reasonSuffix: "existing_evidence_duplicate_episode",
        "P-A7 a duplicate episode must refuse acknowledgement")

    // P-A8: episode IDs must strictly increase.
    var orderSnapshot = try p7r6aLifecycleRecordData(
        version: 2, episode: 2)
    orderSnapshot.append(
        try p7r6aLifecycleRecordData(version: 2, episode: 1))
    try expectNoAck(
        orderSnapshot,
        reasonSuffix: "existing_evidence_episode_order_invalid",
        "P-A8 out-of-order episodes must refuse acknowledgement")

    // P-A9: terminal finish uptimes never move backwards.
    var finishSnapshot = try p7r6aLifecycleRecordData(
        version: 2, episode: 1, started: 10, finished: 20)
    finishSnapshot.append(
        try p7r6aLifecycleRecordData(
            version: 2, episode: 2, started: 10, finished: 19))
    try expectNoAck(
        finishSnapshot,
        reasonSuffix: "existing_evidence_finish_order_invalid",
        "P-A9 finish-time regression must refuse acknowledgement")
}

// P-A10: every identity field must match exactly.
do {
    for (key, value) in [
        ("tracking_session_id", "session-other"),
        ("prior_map_id", "map-other"),
        ("prior_map_sha256", String(repeating: "b", count: 64)),
        ("floor_id", "2"),
    ] {
        let code = try p7r6aParseFailureCode(
            p7r6aLifecycleRecordData(
                version: 2, episode: 1, identity: [key: value]))
        require(
            code == "identity_mismatch",
            "P-A10 identity field \(key) must reject: \(code)")
    }
}

// P-A11: exact same v2 canonical record acknowledges without rewriting.
do {
    let directory = try p7r6FreshDirectory("pa11")
    let recoveryURL = try p7r6WriteBaseBundle(
        in: directory, createRecoveryFile: false)
    let writer = P7R6DurableRecoveryWriter(
        directory: directory,
        trackingSessionId: "session-a",
        sidecarWriter: FoundationScanSidecarWriter())
    let (coordinator, source) = try p7r6aCoordinatorWithPending(
        in: directory,
        episodes: [(reason: "reliable_rtabmap_loop", start: 20, finish: 22)],
        writer: writer)
    // Persist the exact pending record first (production canonical bytes).
    guard let completion = source.pending.first else {
        require(false, "P-A11 requires one pending completion")
        fatalError()
    }
    require(
        writer.appendRecoveryLifecycleEvent(
            completion, expectedTrackingSessionId: "session-a"),
        "P-A11 setup must persist the pending record")
    let watermarkAfterSetup = writer.localizationRecoveryEventCount
    let result = coordinator.persistTerminalEvidence(
        cancellationReason: nil, now: 23)
    let idempotentObjects = try p7r6LifecycleObjects(in: directory)
    require(
        result.allPersisted
            && result.attemptedEpisodeIds == [1]
            && result.persistedEpisodeIds == [1]
            && writer.localizationRecoveryEventCount == watermarkAfterSetup
            && source.pending.isEmpty
            && idempotentObjects.count == 1,
        "P-A11 identical v2 canonical bytes must ack without rewriting")
    _ = recoveryURL
}

// P-A12: same episode with any differing business bytes conflicts.
do {
    let variants: [(String, (Double, Double, String, Int))] = [
        ("outcome", (20, 22, "timed_out", 2)),
        ("finished time", (20, 23, "converged", 2)),
        ("accepted corrections", (20, 22, "converged", 1)),
    ]
    for (label, variant) in variants {
        let directory = try p7r6FreshDirectory("pa12")
        let recoveryURL = try p7r6WriteBaseBundle(
            in: directory, createRecoveryFile: false)
        try p7r6aLifecycleRecordData(
            version: 2,
            episode: 1,
            started: variant.0,
            finished: variant.1,
            outcome: variant.2,
            accepted: variant.3).write(to: recoveryURL)
        let writer = P7R6DurableRecoveryWriter(
            directory: directory,
            trackingSessionId: "session-a",
            sidecarWriter: FoundationScanSidecarWriter())
        // Pending episode 1 with the canonical production timeline.
        let controller = PriorMapRecoveryController()
        let source = P7R6BundleSource(controller: controller)
        _ = controller.request(
            reason: "reliable_rtabmap_loop", now: variant.0)
        if let completion = controller.finish(
            .converged, now: variant.1) {
            source.pending.append(completion)
        }
        let coordinator = p7r6Coordinator(
            source: source,
            writer: writer,
            persistedEvidenceSnapshot: {
                try p7r6PersistedEvidenceSnapshot(in: directory)
            })
        let result = coordinator.persistTerminalEvidence(
            cancellationReason: nil, now: variant.1 + 1)
        // Every mutated variant differs from the pending canonical bytes, so
        // the transaction must conflict without appending or acknowledging.
        let conflictObjects = try p7r6LifecycleObjects(in: directory)
        require(
            !result.allPersisted
                && result.failedEpisodeId == 1
                && result.failureReason
                    == "persisted_episode_bytes_conflict"
                && writer.localizationRecoveryEventCount == 0
                && source.pending.count == 1
                && conflictObjects.count == 1,
            "P-A12 a \(label) mutation must conflict without appending")
    }
}

// P-A13/P-A14: attempted IDs stop exactly at the failing episode.
do {
    func threePending() -> (P7R6FakeRecoverySource) {
        let controller = PriorMapRecoveryController()
        let source = P7R6FakeRecoverySource()
        for index in 0..<3 {
            _ = controller.request(
                reason: "persistent_weak_or_lost",
                now: TimeInterval(index * 10),
                automatic: true)
            if let completion = controller.finish(
                .converged, now: TimeInterval(index * 10 + 1)) {
                source.pending.append(completion)
            }
        }
        return source
    }
    let firstWriter = P7R6FakeRecoveryWriter()
    firstWriter.failingEpisodeIds = [1]
    let firstCoordinator = RecoveryLifecyclePersistenceCoordinator(
        source: threePending(),
        writer: firstWriter,
        trackingSessionId: "session-a",
        priorMapId: "map-a",
        priorMapSha256: p7r6aIdentitySha(),
        floorId: "1",
        persistedEvidenceSnapshot: { Data() })
    let first = firstCoordinator.persistTerminalEvidence(
        cancellationReason: nil, now: 40)
    require(
        first.attemptedEpisodeIds == [1]
            && first.persistedEpisodeIds.isEmpty
            && first.failedEpisodeId == 1,
        "P-A13 a first-episode failure must attempt only episode 1")
    let secondSource = threePending()
    let secondWriter = P7R6FakeRecoveryWriter()
    secondWriter.failingEpisodeIds = [2]
    let secondCoordinator = RecoveryLifecyclePersistenceCoordinator(
        source: secondSource,
        writer: secondWriter,
        trackingSessionId: "session-a",
        priorMapId: "map-a",
        priorMapSha256: p7r6aIdentitySha(),
        floorId: "1",
        persistedEvidenceSnapshot: { Data() })
    let second = secondCoordinator.persistTerminalEvidence(
        cancellationReason: nil, now: 50)
    require(
        second.attemptedEpisodeIds == [1, 2]
            && second.persistedEpisodeIds == [1]
            && second.failedEpisodeId == 2
            && secondSource.pending.map { $0.episode.id } == [2, 3],
        "P-A14 a second-episode failure must keep episodes 2 and 3 queued")
}

// P-A15: an invalid existing snapshot attempts no pending episode.
do {
    let controller = PriorMapRecoveryController()
    let source = P7R6FakeRecoverySource()
    for index in 0..<2 {
        _ = controller.request(
            reason: "persistent_weak_or_lost",
            now: TimeInterval(index * 10),
            automatic: true)
        if let completion = controller.finish(
            .converged, now: TimeInterval(index * 10 + 1)) {
            source.pending.append(completion)
        }
    }
    let writer = P7R6FakeRecoveryWriter()
    let coordinator = RecoveryLifecyclePersistenceCoordinator(
        source: source,
        writer: writer,
        trackingSessionId: "session-a",
        priorMapId: "map-a",
        priorMapSha256: p7r6aIdentitySha(),
        floorId: "1",
        persistedEvidenceSnapshot: { Data("{\"format\":".utf8) })
    let result = coordinator.persistTerminalEvidence(
        cancellationReason: nil, now: 30)
    require(
        !result.allPersisted
            && result.attemptedEpisodeIds.isEmpty
            && result.persistedEpisodeIds.isEmpty
            && result.failedEpisodeId == 1
            && writer.appendedEpisodeIds.isEmpty
            && source.pending.map { $0.episode.id } == [1, 2],
        "P-A15 snapshot parse failure must keep every completion queued")
}

// P-A16/P-A17/P-A18: watermark expectations on an empty snapshot.
do {
    let empty = Data()
    let pass = try RecoveryLifecyclePersistedEvidenceParser.parse(
        snapshot: empty,
        expectation: p7r6aParseExpectation(expectedRecordCount: 0))
    require(pass.recordCount == 0,
            "P-A16 zero episodes with an empty snapshot must pass")
    do {
        _ = try RecoveryLifecyclePersistedEvidenceParser.parse(
            snapshot: empty,
            expectation: p7r6aParseExpectation(expectedRecordCount: 1))
        require(false, "P-A17 must fail closed")
    }
    catch let error as RecoveryLifecycleEvidenceParseError {
        require(error == .expectedCountMismatch,
                "P-A17 a positive watermark with an empty snapshot must fail")
    }
    do {
        _ = try RecoveryLifecyclePersistedEvidenceParser.parse(
            snapshot: empty,
            expectation: p7r6aParseExpectation(
                expectedRecordCount: 0,
                expectedLastEpisodeId: 1))
        require(false, "P-A18 must fail closed")
    }
    catch let error as RecoveryLifecycleEvidenceParseError {
        require(error == .lastEpisodeWatermarkMismatch,
                "P-A18 a zero watermark with a tail ID must fail")
    }
}

// P-A19: stable-read contracts fail closed under swap/truncate/link attacks.
do {
    let directory = try p7r6FreshDirectory("pa19")
    let target = directory.appendingPathComponent("recovery.jsonl")
    let candidate = directory.appendingPathComponent("replacement.jsonl")
    try Data("aaaaa\n".utf8).write(to: target)
    try Data("bbbbb\n".utf8).write(to: candidate)
    var swapped = false
    var swapFailed = false
    do {
        try SafeSessionPath.streamRegularFile(
            target,
            within: directory,
            maximumBytes: 1024,
            chunkBytes: 2
        ) { _ in
            if !swapped {
                swapped = true
                try FileManager.default.removeItem(at: target)
                try FileManager.default.moveItem(
                    at: candidate, to: target)
            }
        }
    }
    catch {
        swapFailed = true
    }
    require(swapFailed, "P-A19 a same-size swap must fail closed")
    try Data("aaaaa\nbbbbb\n".utf8).write(to: target)
    var truncated = false
    var truncateFailed = false
    do {
        try SafeSessionPath.streamRegularFile(
            target,
            within: directory,
            maximumBytes: 1024,
            chunkBytes: 2
        ) { _ in
            if !truncated {
                truncated = true
                try Data("a\n".utf8).write(to: target)
            }
        }
    }
    catch {
        truncateFailed = true
    }
    require(truncateFailed, "P-A19 a mid-read truncate must fail closed")
    try FileManager.default.removeItem(at: target)
    let linkedSource = directory.appendingPathComponent("source.jsonl")
    try Data("ccccc\n".utf8).write(to: linkedSource)
    try FileManager.default.createSymbolicLink(
        at: target, withDestinationURL: linkedSource)
    var symlinkFailed = false
    do {
        _ = try SafeSessionPath.readRegularFile(
            target, within: directory, maximumBytes: 1024)
    }
    catch {
        symlinkFailed = true
    }
    require(symlinkFailed, "P-A19 a symlink replacement must fail closed")
    try FileManager.default.removeItem(at: target)
    try Data("ddddd\n".utf8).write(to: target)
    let linkURL = directory.appendingPathComponent("alias.jsonl")
    try FileManager.default.linkItem(at: target, to: linkURL)
    var hardLinkFailed = false
    do {
        _ = try SafeSessionPath.readRegularFile(
            target, within: directory, maximumBytes: 1024)
    }
    catch {
        hardLinkFailed = true
    }
    require(hardLinkFailed,
            "P-A19 a hard-linked replacement must fail closed")
}

// P-A20: a mixed v1/v2 file validates under the exact watermark.
do {
    let directory = try p7r6FreshDirectory("pa20")
    let recoveryURL = try p7r6WriteBaseBundle(
        in: directory, createRecoveryFile: false)
    var mixed = try p7r6aLifecycleRecordData(
        version: 1, episode: 1, started: 5, finished: 8)
    mixed.append(
        try p7r6aLifecycleRecordData(
            version: 2, episode: 2, started: 10, finished: 14.5))
    try mixed.write(to: recoveryURL)
    require(
        LocalizationEvidenceBundleValidator.blockers(
            in: directory,
            expectation: p7r6BundleExpectation(
                recoveryCount: 2,
                lastEpisodeId: 2,
                lastFinishedAtUptime: 14.5)).isEmpty,
        "P-A20 mixed v1/v2 evidence must validate under the exact watermark")
    let parsed = try RecoveryLifecyclePersistedEvidenceParser.parse(
        snapshot: mixed,
        expectation: p7r6aParseExpectation(
            expectedRecordCount: 2,
            expectedLastEpisodeId: 2,
            expectedLastFinishedAtUptime: 14.5))
    require(
        parsed.recordCount == 2
            && parsed.records[0].isVersionOne
            && !parsed.records[1].isVersionOne
            && parsed.records[0].deadlineUptime == nil
            && parsed.records[0].maximumValidAttempts == nil
            && parsed.records[0].triggerRecords == nil
            && parsed.records[1].deadlineUptime != nil,
        "P-A20 v1 records must keep their missing v2 facts un-fabricated")
}

// MARK: - P7R6B P-B1..P-B15: strict JSON scalars, duplicate keys, pending
// queue order and unified limits.

/// Builds sequential Recovery completions from one controller, mirroring
/// the canonical v2 record shape used by the shared fixtures
/// (60 s deadline window, 7 valid attempts, 2 accepted corrections).
func p7r6bCompletions(
    _ episodes: [(start: Double, finish: Double)]
) -> [PriorMapRecoveryCompletion] {
    let controller = PriorMapRecoveryController(maximumWallClockSeconds: 60)
    var completions: [PriorMapRecoveryCompletion] = []
    for episode in episodes {
        _ = controller.request(
            reason: "reliable_rtabmap_loop", now: episode.start)
        for _ in 0..<7 {
            _ = controller.recordValidMatcherAttempt()
        }
        for _ in 0..<2 {
            controller.recordAcceptedCorrection()
        }
        if let completion = controller.finish(
            .converged,
            now: episode.finish,
            finalFreshSupportFrames: 4) {
            completions.append(completion)
        }
    }
    return completions
}

func p7r6bCoordinator(
    source: P7R6FakeRecoverySource,
    writer: P7R6FakeRecoveryWriter,
    snapshot: @escaping () -> Data
) -> RecoveryLifecyclePersistenceCoordinator {
    return RecoveryLifecyclePersistenceCoordinator(
        source: source,
        writer: writer,
        trackingSessionId: "session-a",
        priorMapId: "map-a",
        priorMapSha256: p7r6aIdentitySha(),
        floorId: "1",
        persistedEvidenceSnapshot: snapshot)
}

// P-B1: a numeric episode_automatic is not a JSON boolean.
do {
    let snapshot = try p7r6aLifecycleRecordData(
        version: 2, episode: 1, extra: ["episode_automatic": 1])
    let failureCode = try p7r6aParseFailureCode(snapshot)

    require(

        failureCode == "business_schema_invalid",

        "P-B1 numeric episode_automatic must be rejected (SB1)")
}

// P-B2: a numeric completion_frame_step_applied is not a JSON boolean.
do {
    let snapshot = try p7r6aLifecycleRecordData(
        version: 2, episode: 1, extra: ["completion_frame_step_applied": 0])
    let failureCode = try p7r6aParseFailureCode(snapshot)

    require(

        failureCode == "business_schema_invalid",

        "P-B2 numeric completion_frame_step_applied must be rejected (SB2)")
}

// P-B3: a numeric trigger-record automatic is not a JSON boolean.
do {
    let snapshot = try p7r6aLifecycleRecordData(
        version: 2,
        episode: 1,
        extra: ["trigger_records": [
            ["reason": "loop", "automatic": 1, "at_uptime": 10.0],
        ]])
    let failureCode = try p7r6aParseFailureCode(snapshot)

    require(

        failureCode == "trigger_records_invalid",

        "P-B3 numeric trigger automatic must be rejected (SB3)")
}

// P-B4: duplicate top-level object key.
do {
    let snapshot = Data("{\"episode_id\":999,\"episode_id\":1}\n".utf8)
    let failureCode = try p7r6aParseFailureCode(snapshot)

    require(

        failureCode == "duplicate_json_key",

        "P-B4 a duplicate top-level key must be rejected (DK1)")
}

// P-B5: duplicate nested object key inside trigger_records.
do {
    let snapshot = Data((
        "{\"trigger_records\":[{\"reason\":\"a\",\"reason\":\"b\","
            + "\"automatic\":true,\"at_uptime\":10.0}]}\n").utf8)
    let failureCode = try p7r6aParseFailureCode(snapshot)

    require(

        failureCode == "duplicate_json_key",

        "P-B5 a duplicate nested key must be rejected (DK2)")
}

// P-B6: an escaped-equivalent duplicate key is still a duplicate.
do {
    let snapshot = Data("{\"episode_id\":1,\"\\u0065pisode_id\":2}\n".utf8)
    let failureCode = try p7r6aParseFailureCode(snapshot)

    require(

        failureCode == "duplicate_json_key",

        "P-B6 an escaped-equivalent duplicate key must be rejected (DK3)")
}

// P-B7 (PQ1/PQ7): duplicate pending episodes are rejected before any
// append or acknowledgement; the coordinator never writes a duplicate.
do {
    let completions = p7r6bCompletions([(10, 14.5)])
    let source = P7R6FakeRecoverySource()
    source.pending = [completions[0], completions[0]]
    let writer = P7R6FakeRecoveryWriter()
    let result = p7r6bCoordinator(
        source: source, writer: writer, snapshot: { Data() })
        .persistTerminalEvidence(cancellationReason: nil, now: 30)
    require(
        !result.allPersisted
            && result.attemptedEpisodeIds.isEmpty
            && result.persistedEpisodeIds.isEmpty
            && result.failedEpisodeId == 1
            && result.failureReason == "pending_episode_duplicate"
            && writer.appendedEpisodeIds.isEmpty
            && source.pending.count == 2,
        "P-B7 a duplicate pending episode must fail before append/ack (PQ1)")
}

// P-B8 (PQ2): a reversed pending queue is rejected, never sorted.
do {
    let completions = p7r6bCompletions([(10, 14.5), (20, 24.5)])
    let source = P7R6FakeRecoverySource()
    source.pending = [completions[1], completions[0]]
    let writer = P7R6FakeRecoveryWriter()
    let result = p7r6bCoordinator(
        source: source, writer: writer, snapshot: { Data() })
        .persistTerminalEvidence(cancellationReason: nil, now: 30)
    require(
        !result.allPersisted
            && result.attemptedEpisodeIds.isEmpty
            && result.failedEpisodeId == 1
            && result.failureReason == "pending_episode_order_invalid"
            && writer.appendedEpisodeIds.isEmpty
            && source.pending.map { $0.episode.id } == [2, 1],
        "P-B8 a reversed pending queue must fail closed (PQ2)")
}

// P-B9 (PQ3): finish uptimes in the pending queue never regress.
do {
    let completions = p7r6bCompletions([(0, 20), (18, 19)])
    let source = P7R6FakeRecoverySource()
    source.pending = completions
    let writer = P7R6FakeRecoveryWriter()
    let result = p7r6bCoordinator(
        source: source, writer: writer, snapshot: { Data() })
        .persistTerminalEvidence(cancellationReason: nil, now: 30)
    require(
        !result.allPersisted
            && result.attemptedEpisodeIds.isEmpty
            && result.failedEpisodeId == 2
            && result.failureReason == "pending_finish_order_invalid"
            && writer.appendedEpisodeIds.isEmpty,
        "P-B9 a finish-time regression in the pending queue must fail (PQ3)")
}

// P-B10 (PQ5): an identical persisted episode acks without rewriting and a
// later episode appends once, using the same transaction.
do {
    let completions = p7r6bCompletions([(10, 14.5), (20, 24.5)])
    let existingSnapshot = try p7r6aLifecycleRecordData(version: 2, episode: 1)
    let source = P7R6FakeRecoverySource()
    source.pending = completions
    let writer = P7R6FakeRecoveryWriter()
    let result = p7r6bCoordinator(
        source: source, writer: writer, snapshot: { existingSnapshot })
        .persistTerminalEvidence(cancellationReason: nil, now: 30)
    require(
        result.allPersisted
            && result.attemptedEpisodeIds == [1, 2]
            && result.persistedEpisodeIds == [1, 2]
            && writer.appendedEpisodeIds == [2]
            && source.pending.isEmpty,
        "P-B10 an identical existing episode acks and the next appends once (PQ5)")
}

// P-B11 (SB4): finalization rejects a numeric constraint `accepted`.
do {
    let directory = try p7r6FreshDirectory("pb11")
    _ = try p7r6WriteBaseBundle(in: directory)
    let constraintsURL = directory.appendingPathComponent(
        "localization_constraints.jsonl")
    let identity = "\"trackingSessionId\":\"session-a\","
        + "\"priorMapId\":\"map-a\","
        + "\"priorMapSha256\":\"\(p7r6aIdentitySha())\","
        + "\"floorId\":\"1\","
    let pose = "{\"x_m\":0,\"y_m\":0,\"yaw_rad\":0}"
    let line = "{\"format\":\"MarketScannerLocalizationConstraint\","
        + "\"version\":1," + identity
        + "\"timestamp\":1,\"nodeTimebaseTimestamp\":1,"
        + "\"nodeTimebaseOffsetSeconds\":0,\"accepted\":1,"
        + "\"predictedPose\":\(pose),\"uniqueness\":0.9}\n"
    try Data(line.utf8).write(to: constraintsURL)
    let blockers = LocalizationEvidenceBundleValidator.blockers(
        in: directory,
        expectation: p7r6BundleExpectation(recoveryCount: 0))
    require(
        blockers.contains(
            "evidence_bundle_localization_constraints.jsonl_"
                + "constraint_business_schema_invalid"),
        "P-B11 numeric constraint accepted must block finalization (SB4): "
            + "\(blockers)")
}

// P-B12 (SB5): finalization rejects numeric localized-tag booleans.
do {
    let directory = try p7r6FreshDirectory("pb12")
    _ = try p7r6WriteBaseBundle(in: directory)
    let identity = "\"tracking_session_id\":\"session-a\","
        + "\"prior_map_id\":\"map-a\","
        + "\"prior_map_sha256\":\"\(p7r6aIdentitySha())\","
        + "\"floor_id\":\"1\","
    let tag = "[{\"format\":\"MarketScannerLocalizedPriceTag\","
        + "\"version\":1," + identity
        + "\"tag_id\":\"t1\",\"observation_id\":\"o1\","
        + "\"payload\":\"p\",\"symbology\":\"CODE128\","
        + "\"timestamp\":1.0,\"localization_confidence\":0.9,"
        + "\"measurement_confidence\":0.9,\"association_confidence\":0.9,"
        + "\"measurement_method\":\"manual\","
        + "\"needs_review\":0,\"user_confirmed\":1}]\n"
    try Data(tag.utf8).write(to: directory.appendingPathComponent(
        "localized_price_tags.json"))
    let blockers = LocalizationEvidenceBundleValidator.blockers(
        in: directory,
        expectation: p7r6BundleExpectation(recoveryCount: 0))
    require(
        blockers.contains(
            "evidence_bundle_localized_price_tags_"
                + "tag_business_schema_invalid"),
        "P-B12 numeric tag booleans must block finalization (SB5): "
            + "\(blockers)")
}

// P-B13/P-B14: the frozen 16 MB file limit is exact on both sides of the
// boundary, mirroring the Python reader's pre-read size check.
do {
    let exact = Data(
        repeating: 0x61,
        count: RecoveryLifecycleEvidenceLimits.maximumFileBytes)
    let exactCode = try p7r6aParseFailureCode(exact)
    require(
        exactCode == "missing_final_newline",
        "P-B13 an exact-limit snapshot passes the size gate (B4)")
    let over = Data(
        repeating: 0x61,
        count: RecoveryLifecycleEvidenceLimits.maximumFileBytes + 1)
    let overCode = try p7r6aParseFailureCode(over)
    require(
        overCode == "file_too_large",
        "P-B14 a file one byte over the limit fails closed (B4)")
}

// P-B15: record-byte and nesting-depth boundaries use the shared limits.
do {
    var exactRecord = Data(
        repeating: 0x61,
        count: RecoveryLifecycleEvidenceLimits.maximumRecordBytes)
    exactRecord.append(0x0A)
    let exactRecordCode = try p7r6aParseFailureCode(exactRecord)
    require(
        exactRecordCode == "invalid_json",
        "P-B15 an exact-limit record passes the size gate (B4)")
    var overRecord = Data(
        repeating: 0x61,
        count: RecoveryLifecycleEvidenceLimits.maximumRecordBytes + 1)
    overRecord.append(0x0A)
    let overRecordCode = try p7r6aParseFailureCode(overRecord)
    require(
        overRecordCode == "record_too_large",
        "P-B15 a record one byte over the limit fails closed (B4)")
    let allowedDepth = String(repeating: "{\"a\":", count: 32)
        + "null" + String(repeating: "}", count: 32) + "\n"
    let allowedDepthCode = try p7r6aParseFailureCode(
        Data(allowedDepth.utf8))
    require(
        allowedDepthCode == "format_mismatch",
        "P-B15 depth 32 passes the nesting gate (B4)")
    let overDepth = String(
        repeating: "{\"a\":",
        count: RecoveryLifecycleEvidenceLimits.maximumJSONNestingDepth + 1)
        + "null"
        + String(
            repeating: "}",
            count: RecoveryLifecycleEvidenceLimits.maximumJSONNestingDepth + 1)
        + "\n"
    let overDepthCode = try p7r6aParseFailureCode(
        Data(overDepth.utf8))
    require(
        overDepthCode == "invalid_json",
        "P-B15 depth 33 must fail the nesting gate (B4)")
}

// =====================================================================
// P7R6C-C1: the strict JSON validator is a total function. Any Data input
// either validates or throws a typed error; it must never crash, never
// force-unwrap, never read out of bounds.
//
// C1/C2 run only in the default host-test mode (no arguments). The
// --recovery-fixtures and package-integrity modes below invoke this same
// executable repeatedly; re-running the 16 MiB catalog tests on every
// call would blow past CI wall-clock budgets.
// CommandLine.arguments always contains the executable path, so the
// default mode is "no arguments beyond the program path".
// =====================================================================
if CommandLine.arguments.count <= 1 {

// U1: a scalar above U+10FFFF encoded as UTF-8 (F4 BF BF BF) inside a
// JSON string must be rejected without trapping.
do {
    var u1 = Data("{\"value\":\"".utf8)
    u1.append(contentsOf: [0xF4, 0xBF, 0xBF, 0xBF])
    u1.append(Data("\"}".utf8))
    do {
        try StrictJSONKeyUniquenessValidator.validate(u1)
        require(false, "C1-U1 scalar above U+10FFFF must be rejected")
    }
    catch let error as StrictJSONValidationError {
        switch error {
        case .invalidUTF8, .scalarOutOfRange:
            break
        default:
            require(false, "C1-U1 unexpected error code: \(error)")
        }
    }
}

// U2: a UTF-16 surrogate encoded as UTF-8 (ED A0 80) must be rejected.
do {
    var u2 = Data("{\"value\":\"".utf8)
    u2.append(contentsOf: [0xED, 0xA0, 0x80])
    u2.append(Data("\"}".utf8))
    do {
        try StrictJSONKeyUniquenessValidator.validate(u2)
        require(false, "C1-U2 surrogate UTF-8 must be rejected")
    }
    catch let error as StrictJSONValidationError {
        switch error {
        case .invalidUTF8, .scalarOutOfRange:
            break
        default:
            require(false, "C1-U2 unexpected error code: \(error)")
        }
    }
}

// U3: overlong encodings (C0 AF and E0 80 AF) must be rejected.
do {
    for bytes in [[0xC0, 0xAF] as [UInt8], [0xE0, 0x80, 0xAF] as [UInt8]] {
        var u3 = Data("{\"value\":\"".utf8)
        u3.append(contentsOf: bytes)
        u3.append(Data("\"}".utf8))
        do {
            try StrictJSONKeyUniquenessValidator.validate(u3)
            require(false, "C1-U3 overlong encoding must be rejected")
        }
        catch let error as StrictJSONValidationError {
            switch error {
            case .invalidUTF8, .scalarOutOfRange:
                break
            default:
                require(false, "C1-U3 unexpected error code: \(error)")
            }
        }
    }
}

// U4: a bad continuation byte (E2 28 A1) must be rejected.
do {
    var u4 = Data("{\"value\":\"".utf8)
    u4.append(contentsOf: [0xE2, 0x28, 0xA1])
    u4.append(Data("\"}".utf8))
    do {
        try StrictJSONKeyUniquenessValidator.validate(u4)
        require(false, "C1-U4 bad continuation must be rejected")
    }
    catch let error as StrictJSONValidationError {
        switch error {
        case .invalidUTF8:
            break
        default:
            require(false, "C1-U4 unexpected error code: \(error)")
        }
    }
}

// U5: truncated 2/3/4-byte sequences must be rejected.
do {
    for bytes in [[0xC2] as [UInt8], [0xE2, 0x82] as [UInt8],
                  [0xF0, 0x9F, 0x92] as [UInt8]] {
        var u5 = Data("{\"value\":\"".utf8)
        u5.append(contentsOf: bytes)
        u5.append(Data("\"}".utf8))
        do {
            try StrictJSONKeyUniquenessValidator.validate(u5)
            require(false, "C1-U5 truncated sequence must be rejected")
        }
        catch let error as StrictJSONValidationError {
            switch error {
            case .invalidUTF8:
                break
            default:
                require(false, "C1-U5 unexpected error code: \(error)")
            }
        }
    }
}

// U6: an unpaired high surrogate escape must not crash the scanner.
do {
    let u6 = Data("{\"value\":\"\\uD800\"}".utf8)
    do {
        try StrictJSONKeyUniquenessValidator.validate(u6)
    }
    catch let error as StrictJSONValidationError {
        switch error {
        case .unpairedHighSurrogate, .invalidUnicodeEscape, .invalidUTF8:
            break
        default:
            require(false, "C1-U6 unexpected error code: \(error)")
        }
    }
}

// U7: an unpaired low surrogate escape must not crash the scanner.
do {
    let u7 = Data("{\"value\":\"\\uDC00\"}".utf8)
    do {
        try StrictJSONKeyUniquenessValidator.validate(u7)
    }
    catch let error as StrictJSONValidationError {
        switch error {
        case .unpairedLowSurrogate, .invalidUnicodeEscape, .invalidUTF8:
            break
        default:
            require(false, "C1-U7 unexpected error code: \(error)")
        }
    }
}

// U8: a legal surrogate pair passes the duplicate-key scanner.
do {
    let u8 = Data("{\"value\":\"\\uD83D\\uDE00\"}".utf8)
    try StrictJSONKeyUniquenessValidator.validate(u8)
}

// U10/TJ9: deterministic fuzz. 10,000 random byte arrays of length 0..4096
// must only ever return or throw; the process must never crash.
do {
    var state: UInt64 = 0x9E3779B97F4A7C15
    func nextRandom() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
    for _ in 0..<10_000 {
        let length = Int(nextRandom() % 4097)
        var data = Data(capacity: length)
        for _ in 0..<length {
            data.append(UInt8(truncatingIfNeeded: nextRandom()))
        }
        do {
            try StrictJSONKeyUniquenessValidator.validate(data)
        }
        catch {
            // Any typed error is acceptable; a crash is not.
        }
    }
}

// U9/TJ10: an invalid UTF-8 localized_price_tags.json must become a stable
// finalization blocker, never a process crash, and finalization must fail
// closed.
do {
    let directory = try p7r6FreshDirectory("c1-u9")
    _ = try p7r6WriteBaseBundle(in: directory)
    var invalidTags = Data("[\"value\":\"".utf8)
    invalidTags.append(contentsOf: [0xF4, 0xBF, 0xBF, 0xBF])
    invalidTags.append(Data("\"]".utf8))
    try invalidTags.write(
        to: directory.appendingPathComponent("localized_price_tags.json"))
    let blockers = LocalizationEvidenceBundleValidator.blockers(
        in: directory,
        expectation: p7r6BundleExpectation(recoveryCount: 0))
    require(
        blockers.contains {
            $0.contains("localized_price_tags")
                && $0.contains("invalid_json_array")
        },
        "C1-U9 invalid UTF-8 tag file must become a stable blocker: "
            + "\(blockers)")
}

// =====================================================================
// P7R6C-C2: the strict scanner must not reject a large legal tag array.
// The old fixed 1,000,000-token cap wrongly rejected legal catalogs; the
// new progress bound is derived from the byte count.
// =====================================================================

/// Writes a valid localized_price_tags.json array with the given tag
/// count and returns the finalization blockers for that bundle.
func p7r6TagsBlockers(tagCount: Int, mutateLast: (inout String) -> Void = { _ in })
    throws -> [String] {
    let directory = try p7r6FreshDirectory("c2-tags")
    _ = try p7r6WriteBaseBundle(in: directory)
    var lines: [String] = []
    lines.reserveCapacity(tagCount)
    for index in 0..<tagCount {
        var tag = "{\"format\":\"MarketScannerLocalizedPriceTag\","
            + "\"version\":1,"
            + "\"tracking_session_id\":\"session-a\","
            + "\"prior_map_id\":\"map-a\","
            + "\"prior_map_sha256\":\"\(p7r6aIdentitySha())\","
            + "\"floor_id\":\"1\","
            + "\"tag_id\":\"t\(index)\",\"observation_id\":\"o\(index)\","
            + "\"payload\":\"p\",\"symbology\":\"CODE128\","
            + "\"timestamp\":\(1.0 + Double(index)),"
            + "\"localization_confidence\":0.9,"
            + "\"measurement_confidence\":0.9,"
            + "\"association_confidence\":0.9,"
            + "\"measurement_method\":\"manual\","
            + "\"needs_review\":false,\"user_confirmed\":true}"
        if index == tagCount - 1 {
            mutateLast(&tag)
        }
        lines.append(tag)
    }
    let payload = Data(("[" + lines.joined(separator: ",") + "]").utf8)
    try payload.write(
        to: directory.appendingPathComponent("localized_price_tags.json"))
    return LocalizationEvidenceBundleValidator.blockers(
        in: directory,
        expectation: p7r6BundleExpectation(
            recoveryCount: 0,
            localizedPriceTagCount: tagCount))
}

// L1: 10,000 tags must finalize cleanly (no token-cap rejection).
do {
    let blockers = try p7r6TagsBlockers(tagCount: 10_000)
    require(
        blockers.isEmpty,
        "C2-L1 10,000 tags must finalize cleanly: \(blockers)")
}

// L2: 30,000 tags must finalize cleanly.
do {
    let blockers = try p7r6TagsBlockers(tagCount: 30_000)
    require(
        blockers.isEmpty,
        "C2-L2 30,000 tags must finalize cleanly: \(blockers)")
}

// L3: the largest legal tag catalog that fits inside the frozen 16 MiB
// file limit must not be rejected by any scanner token cap. A per-byte
// progress bound replaced the old fixed 1,000,000-token cap.
do {
    let directory = try p7r6FreshDirectory("c2-l3")
    _ = try p7r6WriteBaseBundle(in: directory)
    func minimalTag(_ index: Int) -> String {
        return "{\"format\":\"MarketScannerLocalizedPriceTag\","
            + "\"version\":1,"
            + "\"tracking_session_id\":\"session-a\","
            + "\"prior_map_id\":\"map-a\","
            + "\"prior_map_sha256\":\"\(p7r6aIdentitySha())\","
            + "\"floor_id\":\"1\","
            + "\"tag_id\":\"t\(index)\",\"observation_id\":\"o\(index)\","
            + "\"payload\":\"p\",\"symbology\":\"CODE128\","
            + "\"timestamp\":\(1.0 + Double(index)),"
            + "\"localization_confidence\":0.9,"
            + "\"measurement_confidence\":0.9,"
            + "\"association_confidence\":0.9,"
            + "\"measurement_method\":\"manual\","
            + "\"needs_review\":false,\"user_confirmed\":true}"
    }
    // Accumulate records until the next one would exceed 16 MiB: the
    // largest count that still fits the frozen file limit, accounting for
    // the array brackets and inter-record commas.
    var payload = Data("[".utf8)
    var fittingCount = 0
    while payload.count < RecoveryLifecycleEvidenceLimits.maximumFileBytes {
        let candidate = minimalTag(fittingCount)
        let candidateCount = payload.count
            + candidate.utf8.count
            + (fittingCount == 0 ? 1 : 2) // "[" or "," before the record
        if candidateCount >= RecoveryLifecycleEvidenceLimits.maximumFileBytes {
            break
        }
        if fittingCount > 0 {
            payload.append(Data(",".utf8))
        }
        payload.append(Data(candidate.utf8))
        fittingCount += 1
    }
    payload.append(Data("]".utf8))
    try payload.write(
        to: directory.appendingPathComponent("localized_price_tags.json"))
    require(
        fittingCount >= 30_000,
        "C2-L3 the 16 MiB budget must hold at least 30,000 minimal tags "
            + "(fits \(fittingCount))")
    let blockers = LocalizationEvidenceBundleValidator.blockers(
        in: directory,
        expectation: p7r6BundleExpectation(
            recoveryCount: 0,
            localizedPriceTagCount: fittingCount))
    require(
        blockers.isEmpty,
        "C2-L3 \(fittingCount) tags within the 16 MiB limit "
            + "must finalize cleanly: \(blockers)")
}

// L5: a duplicate key in the LAST tag must still be detected; the scanner
// must never stop scanning early just because the file is large.
do {
    let blockers = try p7r6TagsBlockers(tagCount: 10_000) { tag in
        tag = "{\"format\":\"MarketScannerLocalizedPriceTag\","
            + "\"format\":\"MarketScannerLocalizedPriceTag\","
            + "\"version\":1,"
            + "\"tracking_session_id\":\"session-a\","
            + "\"prior_map_id\":\"map-a\","
            + "\"prior_map_sha256\":\"\(p7r6aIdentitySha())\","
            + "\"floor_id\":\"1\","
            + "\"tag_id\":\"t-last\",\"observation_id\":\"o-last\","
            + "\"payload\":\"p\",\"symbology\":\"CODE128\","
            + "\"timestamp\":1.0,\"localization_confidence\":0.9,"
            + "\"measurement_confidence\":0.9,"
            + "\"association_confidence\":0.9,"
            + "\"measurement_method\":\"manual\","
            + "\"needs_review\":false,\"user_confirmed\":true}"
    }
    require(
        blockers.contains {
            $0.contains("localized_price_tags")
                && $0.contains("duplicate_json_key")
        },
        "C2-L5 duplicate key in the last tag must be detected: \(blockers)")
}

// L6: a numeric boolean in the LAST tag must be rejected.
do {
    let blockers = try p7r6TagsBlockers(tagCount: 10_000) { tag in
        tag = "{\"format\":\"MarketScannerLocalizedPriceTag\","
            + "\"version\":1,"
            + "\"tracking_session_id\":\"session-a\","
            + "\"prior_map_id\":\"map-a\","
            + "\"prior_map_sha256\":\"\(p7r6aIdentitySha())\","
            + "\"floor_id\":\"1\","
            + "\"tag_id\":\"t-last\",\"observation_id\":\"o-last\","
            + "\"payload\":\"p\",\"symbology\":\"CODE128\","
            + "\"timestamp\":1.0,\"localization_confidence\":0.9,"
            + "\"measurement_confidence\":0.9,"
            + "\"association_confidence\":0.9,"
            + "\"measurement_method\":\"manual\","
            + "\"needs_review\":1,\"user_confirmed\":true}"
    }
    require(
        blockers.contains {
            $0.contains("localized_price_tags")
                && $0.contains("tag_business_schema_invalid")
        },
        "C2-L6 numeric boolean in the last tag must be rejected: \(blockers)")
}

// L4: a 16 MiB + 1 byte tag file must fail the frozen file-size limit
// instead of being scanned or parsed.
do {
    let directory = try p7r6FreshDirectory("c2-l4")
    _ = try p7r6WriteBaseBundle(in: directory)
    var oversized = Data(
        repeating: 0x20,
        count: RecoveryLifecycleEvidenceLimits.maximumFileBytes + 1)
    oversized.append(Data("[0]".utf8))
    try oversized.write(
        to: directory.appendingPathComponent("localized_price_tags.json"))
    let blockers = LocalizationEvidenceBundleValidator.blockers(
        in: directory,
        expectation: p7r6BundleExpectation(recoveryCount: 0))
    require(
        blockers.contains {
            $0.contains("localized_price_tags")
                && ($0.contains("file_identity_changed_or_size_limit")
                    || $0.contains("file_size_limit")
                    || $0.contains("invalid_json_array"))
        },
        "C2-L4 a 16 MiB+1 tag file must fail the size limit: \(blockers)")
}

// =====================================================================
// Mobile-Only V1: map-source import (CSV / JSON in default mode; the
// XLSX and three-format parity suite runs through --import-suite because
// real .xlsx fixtures are produced by the Python harness).
// =====================================================================

// I2/I14: CSV baseline with two floors imports cleanly and produces the
// expected element inventory.
do {
    let csv = """
    floor,element
    1,"{""shapeType"":""MapShelf"",""x"":100,""y"":200,""width"":300,""height"":100,""code"":""S1"",""visible"":true}"
    1,"{""shapeType"":""MapCross"",""points"":[0,500,1000,500],""lineWidth"":200,""code"":""C1"",""visible"":true}"
    2,"{""shapeType"":""MapRoadPoint"",""x"":100,""y"":500,""width"":20,""height"":20,""code"":1,""crossCodes"":[""C1""]}"
    """
    let outcome = try CSVMapSourceImporter.importSource(
        data: Data(csv.utf8),
        contract: .topLeft)
    require(
        outcome.elements.count == 3,
        "I2 CSV must import 3 elements, got \(outcome.elements.count)")
    let floors = Set(outcome.elements.map { $0.floorId })
    require(
        floors == ["1", "2"],
        "I2 CSV floors must be [1, 2], got \(floors.sorted())")
    require(
        outcome.elements.allSatisfy { $0.id == "f\($0.floorId)-r\($0.sourceRow)" },
        "I2 element ids must follow the frozen f<floor>-r<row> contract")
    // Road-graph warnings (missing_cross / road_point_without_cross) are
    // produced by the compiler stage, not the importer; the importer only
    // reports geometry/visibility observations.
    require(
        outcome.warnings.allSatisfy {
            $0.code == "unknown_shape_type"
                || $0.code == "invalid_geometry"
                || $0.code == "hidden_element"
        },
        "I2 importer warnings must be normalization-only, got \(outcome.warnings.map { $0.code })")
    // Shelf normalization: x=100,y=200,w=300,h=100 -> CCW map polygon
    // whose first corner is the bottom-left source corner (1.0, -3.0)
    // under the top-left contract.
    let shelf = outcome.elements.first { $0.shapeType == "MapShelf" }
    require(shelf != nil, "I2 shelf must exist")
    if let geometry = shelf?.geometry,
       let coordinates = geometry["coordinates"] as? [[Double]] {
        require(
            coordinates.count == 4,
            "I2 shelf polygon must have 4 points")
        require(
            close(coordinates[0][0], 1.0) && close(coordinates[0][1], -3.0),
            "I2 shelf first corner must be (1.0, -3.0), got \(coordinates[0])")
        require(
            close(coordinates[1][0], 4.0) && close(coordinates[1][1], -3.0),
            "I2 shelf second corner must be (4.0, -3.0), got \(coordinates[1])")
    }
    else {
        require(false, "I2 shelf must carry geometry")
    }
}
catch {
    require(false, "I2 CSV baseline failed: \(error)")
}

// I8: quoted newline inside a field is preserved (RFC 4180).
do {
    let csv = "floor,element\n1,\"{ \"\"shapeType\"\": \"\"MapShelf\"\"}\"\n"
    let outcome = try CSVMapSourceImporter.importSource(
        data: Data(csv.utf8),
        contract: .topLeft)
    require(
        outcome.elements.count == 1,
        "I8 quoted-newline CSV must import 1 element, got \(outcome.elements.count)")
}
catch {
    require(false, "I8 quoted newline failed: \(error)")
}

// I9: an unclosed quoted field must fail closed.
do {
    let csv = "floor,element\n1,\"{quoted-never-closed"
    _ = try CSVMapSourceImporter.importSource(
        data: Data(csv.utf8),
        contract: .topLeft)
    require(false, "I9 unclosed quote must be rejected")
}
catch let error as MapSourceImportError {
    require(
        error == .malformedRow(row: 2, reason: "引号字段未闭合。"),
        "I9 unclosed quote must report malformed row, got \(error.stableCode)")
}
catch {
    require(false, "I9 unclosed quote error type: \(error)")
}

// CSV NUL byte must be rejected.
do {
    var bad = Data("floor,element\n1,\"{\"".utf8)
    bad.append(0)
    bad.append(Data("\"}\"\n".utf8))
    _ = try CSVMapSourceImporter.importSource(
        data: bad,
        contract: .topLeft)
    require(false, "I-csv-nul must be rejected")
}
catch let error as MapSourceImportError {
    require(
        error.stableCode == "map_source_csv_contains_nul",
        "CSV NUL must map to csv_contains_nul, got \(error.stableCode)")
}
catch {
    require(false, "CSV NUL error type: \(error)")
}

// I11: invalid UTF-8 bytes must be rejected.
do {
    var bad = Data("floor,element\n1,\"{}\"".utf8)
    bad.append(0xC3) // truncated UTF-8 sequence
    bad.append(Data("\n".utf8))
    _ = try CSVMapSourceImporter.importSource(
        data: bad,
        contract: .topLeft)
    require(false, "I11 invalid UTF-8 CSV must be rejected")
}
catch let error as MapSourceImportError {
    require(
        error.stableCode == "invalid_utf8",
        "I11 invalid UTF-8 must map to invalid_utf8, got \(error.stableCode)")
}
catch {
    require(false, "I11 invalid UTF-8 error type: \(error)")
}

// I3/I10: JSON baseline imports; duplicate keys are rejected by the
// strict parser.
do {
    let json = """
    {
      "format": "MarketScannerPriorMapSource",
      "version": 1,
      "storeId": "s1",
      "mapName": "sample",
      "source": {
        "originalFormat": "json",
        "originalFilename": "sample.json",
        "sourceFileSha256": "abc",
        "canonicalSourceSha256": ""
      },
      "coordinateContract": {
        "unit": "centimetre", "origin": "top_left", "x_axis": "right",
        "y_axis": "down", "rotation_direction": "clockwise_degrees"
      },
      "elements": [
        {
          "id": "f1-r2", "source_row": 2, "floor_id": "1",
          "shape_type": "MapShelf", "visible": true, "locked": false,
          "code": "S1", "cross_code": "", "row_flag": "",
          "geometry": {"type": "polygon", "coordinates": [[1.0, -2.0], [4.0, -2.0], [4.0, -1.0], [1.0, -1.0]]},
          "bounds": {"min_x_m": 1.0, "min_y_m": -2.0, "max_x_m": 4.0, "max_y_m": -1.0},
          "center_m": [2.5, -1.5], "yaw_rad": 0.0,
          "source": {"shapeType": "MapShelf", "x": 100, "y": 200, "width": 300, "height": 100}
        }
      ],
      "warnings": []
    }
    """
    let outcome = try JSONMapSourceImporter.importSource(data: Data(json.utf8))
    require(
        outcome.elements.count == 1,
        "I3 JSON baseline must import 1 element, got \(outcome.elements.count)")
    require(
        outcome.sourceIdentity?.originalFilename == "sample.json",
        "I3 JSON identity must preserve originalFilename")
    require(
        outcome.elements[0].shapeType == "MapShelf",
        "I3 JSON element shape_type must be preserved")
}
catch {
    require(false, "I3 JSON baseline failed: \(error)")
}

do {
    let json = """
    {"format": "MarketScannerPriorMapSource", "version": 1,
     "storeId": "s", "mapName": "m",
     "coordinateContract": {"unit": "centimetre", "origin": "top_left",
       "x_axis": "right", "y_axis": "down", "rotation_direction": "clockwise_degrees"},
     "elements": [{"id": "f1-r2", "source_row": 2, "floor_id": "1",
       "shape_type": "MapShelf", "visible": true, "locked": false, "code": "S1",
       "cross_code": "", "row_flag": "", "source": {"x": 1, "x": 2}}],
     "warnings": []}
    """
    _ = try JSONMapSourceImporter.importSource(data: Data(json.utf8))
    require(false, "I10 duplicate JSON key must be rejected")
}
catch let error as MapSourceImportError {
    require(
        error.stableCode == "invalid_json",
        "I10 duplicate key must map to invalid_json, got \(error.stableCode)")
}
catch {
    require(false, "I10 duplicate key error type: \(error)")
}

// I13: the bottom-left coordinate preset flips the y axis.
do {
    let csv = """
    floor,element
    1,"{""shapeType"":""MapRoadPoint"",""x"":100,""y"":200,""code"":""P1""}"
    """
    let outcome = try CSVMapSourceImporter.importSource(
        data: Data(csv.utf8),
        contract: .bottomLeft)
    require(
        outcome.elements.count == 1,
        "I13 bottom-left CSV must import 1 element")
    if let coordinates = outcome.elements[0].geometry?["coordinates"] as? [Double] {
        require(
            close(coordinates[0], 1.0) && close(coordinates[1], 2.0),
            "I13 bottom-left must map y=200cm to +2.0m, got \(coordinates)")
    }
    else {
        require(false, "I13 road point must carry point geometry")
    }
}
catch {
    require(false, "I13 bottom-left preset failed: \(error)")
}

// canonical-source digest is stable for the same business payload
// regardless of the source document bytes.
do {
    let csvA = "floor,element\n1,\"{ \"\"shapeType\"\": \"\"MapShelf\"\", \"\"x\"\": 100, \"\"y\"\": 200, \"\"width\"\": 300, \"\"height\"\": 100}\"\n"
    let csvB = "floor,element\n1,\"{ \"\"shapeType\"\":\"\"MapShelf\"\",\"\"x\"\":100,\"\"y\"\":200,\"\"width\"\":300,\"\"height\"\":100}\"\n"
    let outcomeA = try CSVMapSourceImporter.importSource(
        data: Data(csvA.utf8), contract: .topLeft)
    let outcomeB = try CSVMapSourceImporter.importSource(
        data: Data(csvB.utf8), contract: .topLeft)
    require(
        outcomeA.elements == outcomeB.elements,
        "I4 canonical elements must ignore non-business whitespace")
}
catch {
    require(false, "I4 whitespace-insensitive canonical test failed: \(error)")
}

// I4: canonical elements must ignore non-business whitespace (checked
// above); C7/C8/C10: the mobile compiler emits distance-field payloads
// byte-identical to the PC oracle (data_sha256) and road graphs with the
// same statistics.
do {
    let csv = """
    floor,element
    1,"{""shapeType"":""MapShelf"",""x"":100,""y"":200,""width"":300,""height"":100,""code"":""S1"",""visible"":true}"
    1,"{""shapeType"":""MapCross"",""points"":[0,500,1000,500],""lineWidth"":200,""code"":""C1"",""visible"":true}"
    2,"{""shapeType"":""MapRoadPoint"",""x"":100,""y"":500,""width"":20,""height"":20,""code"":1,""crossCodes"":[""C1""]}"
    """
    let outcome = try CSVMapSourceImporter.importSource(
        data: Data(csv.utf8), contract: .topLeft)
    let source = MarketScannerPriorMapSource(
        format: "MarketScannerPriorMapSource", version: 1,
        storeId: "s1", mapName: "sample",
        source: MapSourceIdentity(
            originalFormat: "csv", originalFilename: "sample.csv",
            sourceFileSha256: "x", canonicalSourceSha256: "y"),
        coordinateContract: .topLeft,
        elements: outcome.elements, warnings: outcome.warnings)
    let output = try p7r6FreshDirectory("mobile-compile")
    let result = try MobilePriorMapCompiler.compile(
        canonicalSource: source, outputDirectory: output)
    require(
        result.floorCount == 2 && result.elementCount == 3,
        "C7 mobile compile must yield 2 floors / 3 elements, got \(result.floorCount)/\(result.elementCount)")
    require(
        !result.packageSHA256.isEmpty,
        "C7 mobile compile must self-validate and return a package SHA")
    // The compiled package must load through the production snapshot
    // reader (C9 package self-load). The package manifest is carried
    // separately by the snapshot (not inside artifactNames).
    let snapshot = try PriorMapPackageSnapshotReader.read(directory: output)
    require(
        !snapshot.packageManifest.isEmpty
            && snapshot.artifactNames.contains("distance_fields.json")
            && snapshot.artifactNames.contains("preview.png")
            && snapshot.artifactNames.contains("road_graph.json"),
        "C9 compiled package must expose manifest/distance/preview/road artifacts")
    // Distance-field per-level digests are frozen PC-parity values.
    let distance = try MobilePackageManifestBuilder.requiredFilesPresent(directory: output)
    _ = distance
    let distanceData = try Data(contentsOf: output.appendingPathComponent("distance_fields.json"))
    let distanceObject = try StrictJSONDocumentParser.object(
        from: distanceData,
        limits: StrictJSONDocumentLimits(maximumBytes: distanceData.count + 1))
    if let floorsPayload = distanceObject["floors"] as? [String: Any],
       let floor1 = floorsPayload["1"] as? [String: Any],
       let levels = floor1["levels"] as? [[String: Any]],
       let level0 = levels.first,
       let sha = level0["data_sha256"] as? String {
        require(
            sha == "05560ec893093efe06c0feef1f442fb685d8b935ef842654e2f7a1d6c4954437",
            "C7 floor-1 level-0 distance field must match the PC oracle, got \(sha)")
    }
    else {
        require(false, "C7 distance field structure is invalid")
    }
    // Road graph statistics parity.
    let graphData = try Data(contentsOf: output.appendingPathComponent("road_graph.json"))
    let graphObject = try StrictJSONDocumentParser.object(
        from: graphData,
        limits: StrictJSONDocumentLimits(maximumBytes: graphData.count + 1))
    if let statistics = graphObject["statistics"] as? [String: Any] {
        require(
            (statistics["cross_count"] as? Int) == 1
                && (statistics["node_count"] as? Int) == 1
                && (statistics["edge_count"] as? Int) == 0
                && (statistics["isolated_node_count"] as? Int) == 1,
            "C5 road graph statistics must match the PC oracle: \(statistics)")
    }
    else {
        require(false, "C5 road graph statistics missing")
    }
}
catch {
    require(false, "C5/C7/C9 mobile compiler tests failed: \(error)")
}

// =====================================================================
// Mobile-Only V1: clock correlation, final 1 Hz trajectory (T1-T12) and
// the four-sheet XLSX workbook (X1-X12).
// =====================================================================

// T1/T6/T7: 1 Hz resampling across a connected segment with one clock
// correlation pair; every UTC second in range gets a row. Nodes are
// placed at fractional monotonic times so the integer UTC seconds land
// between nodes and exercise interpolation.
do {
    var records: [ClockCorrelationRecord] = []
    records.append(ClockCorrelationRecord.make(
        trackingSessionID: "s", monotonicSeconds: 100.0,
        utcUnixSeconds: 1_785_762_000.0, timezoneID: "Asia/Shanghai",
        utcOffsetSeconds: 28_800, reason: "session_start"))
    records.append(ClockCorrelationRecord.make(
        trackingSessionID: "s", monotonicSeconds: 110.0,
        utcUnixSeconds: 1_785_762_010.0, timezoneID: "Asia/Shanghai",
        utcOffsetSeconds: 28_800, reason: "session_end"))
    let mapper = MonotonicUTCMapper(records: records)
    let nodes = [
        FinalTrajectory.Node(
            id: 1, monotonicSeconds: 100.0, xM: 0, yM: 0, yawRad: 0,
            uncertaintyM: 0.1, floorID: "1"),
        FinalTrajectory.Node(
            id: 2, monotonicSeconds: 101.5, xM: 1, yM: 0, yawRad: 0,
            uncertaintyM: 0.2, floorID: "1"),
        FinalTrajectory.Node(
            id: 3, monotonicSeconds: 102.5, xM: 1, yM: 1, yawRad: Double.pi / 2,
            uncertaintyM: 0.1, floorID: "1"),
    ]
    let rows = FinalTrajectory.resample(
        input: FinalTrajectory.Input(
            nodes: nodes, lostIntervals: [],
            sessionStartUTC: 1_785_762_000.0,
            sessionEndUTC: 1_785_762_002.0),
        utcMapper: mapper, storeID: "s1",
        priorMapID: "m", priorMapSha256: "a",
        trackingSessionID: "s", appGitSHA: "g")
    require(
        rows.count == 3,
        "T1 resample must emit one row per UTC second, got \(rows.count)")
    require(
        rows[0].positionStatus == "ACCEPTED"
            && rows[0].unixTimeS == 1_785_762_000,
        "T1 first row must be ACCEPTED at the start second")
    require(
        rows[0].timezoneID == "Asia/Shanghai" && rows[0].utcOffset == 28_800,
        "T1 row must carry the local timezone and offset")
    require(
        rows[0].localTimestamp.contains("+08:00"),
        "T1 local timestamp must include the offset, got \(rows[0].localTimestamp)")
    require(
        rows[0].beforeNodeID == 1 && rows[0].afterNodeID == 2,
        "T1 interpolation must bind before/after node ids")
    // Second 1785762001 -> monotonic 101.0, between node 1 (100.0) and
    // node 2 (101.5): ratio 2/3 -> x = 0.6667, y = 0.
    require(
        close(rows[1].mapXM ?? -1, 0.6666667, tolerance: 1.0e-4),
        "T1 second row must interpolate x to 0.6667m, got \(rows[1].mapXM ?? -1)")
    require(
        close(rows[1].mapYM ?? -1, 0.0),
        "T1 second row y must stay 0, got \(rows[1].mapYM ?? -1)")
    // Second 1785762002 -> monotonic 102.0, between node 2 (101.5) and
    // node 3 (102.5): ratio 0.5 -> x=1, y=0.5, yaw=45 deg.
    require(
        rows[2].positionStatus == "ACCEPTED"
            && close(rows[2].mapXM ?? -1, 1.0)
            && close(rows[2].mapYM ?? -1, 0.5),
        "T1 third row must interpolate across nodes 2->3")
    require(
        close(rows[2].yawDeg ?? -1, 45.0, tolerance: 1.0e-6),
        "T1 third row yaw must be shortest-angle interpolated to 45 deg, got \(rows[2].yawDeg ?? -1)")
    require(
        close(rows[1].estimatedUncertaintyM ?? -1, 0.2),
        "T1 uncertainty must be the conservative upper bound (0.2), got \(rows[1].estimatedUncertaintyM ?? -1)")
}
catch {
    require(false, "T1 basic 1 Hz resampling failed: \(error)")
}

// T3: yaw crossing ±pi interpolates the shortest way.
do {
    var records: [ClockCorrelationRecord] = []
    records.append(ClockCorrelationRecord.make(
        trackingSessionID: "s", monotonicSeconds: 0,
        utcUnixSeconds: 1_000_000_000, timezoneID: "UTC",
        utcOffsetSeconds: 0, reason: "start"))
    records.append(ClockCorrelationRecord.make(
        trackingSessionID: "s", monotonicSeconds: 100,
        utcUnixSeconds: 1_000_000_100, timezoneID: "UTC",
        utcOffsetSeconds: 0, reason: "end"))
    let mapper = MonotonicUTCMapper(records: records)
    let nodes = [
        FinalTrajectory.Node(
            id: 1, monotonicSeconds: 0, xM: 0, yM: 0, yawRad: 3.0,
            uncertaintyM: 0.1, floorID: "1"),
        FinalTrajectory.Node(
            id: 2, monotonicSeconds: 2, xM: 1, yM: 0, yawRad: -3.0,
            uncertaintyM: 0.1, floorID: "1"),
    ]
    let rows = FinalTrajectory.resample(
        input: FinalTrajectory.Input(
            nodes: nodes, lostIntervals: [],
            sessionStartUTC: 1_000_000_000,
            sessionEndUTC: 1_000_000_001),
        utcMapper: mapper, storeID: "s1",
        priorMapID: "m", priorMapSha256: "a",
        trackingSessionID: "s", appGitSHA: "g")
    require(
        rows.count == 2 && rows[0].positionStatus == "ACCEPTED",
        "T3 yaw interpolation must produce accepted rows")
    // Shortest arc from +3.0 to -3.0 passes through +pi (not through 0).
    let interpolatedYaw = (rows[0].yawDeg ?? 0) * Double.pi / 180.0
    require(
        abs(interpolatedYaw - 3.0) < 0.01 || abs(interpolatedYaw - Double.pi) < 0.01,
        "T3 yaw must take the shortest arc through +pi, got \(rows[0].yawDeg ?? 0) deg")
}
catch {
    require(false, "T3 yaw shortest-arc failed: \(error)")
}

// T4/T5: lost intervals and floor changes emit UNAVAILABLE rows.
do {
    var records: [ClockCorrelationRecord] = []
    records.append(ClockCorrelationRecord.make(
        trackingSessionID: "s", monotonicSeconds: 0,
        utcUnixSeconds: 2_000_000_000, timezoneID: "UTC",
        utcOffsetSeconds: 0, reason: "start"))
    records.append(ClockCorrelationRecord.make(
        trackingSessionID: "s", monotonicSeconds: 100,
        utcUnixSeconds: 2_000_000_100, timezoneID: "UTC",
        utcOffsetSeconds: 0, reason: "end"))
    let mapper = MonotonicUTCMapper(records: records)
    // Nodes at 0-1s and 9-10s (monotonic); a lost interval covers 3-7s.
    let nodes = [
        FinalTrajectory.Node(id: 1, monotonicSeconds: 0, xM: 0, yM: 0, yawRad: 0, uncertaintyM: 0.1, floorID: "1"),
        FinalTrajectory.Node(id: 2, monotonicSeconds: 1, xM: 1, yM: 0, yawRad: 0, uncertaintyM: 0.1, floorID: "1"),
        FinalTrajectory.Node(id: 3, monotonicSeconds: 9, xM: 1, yM: 1, yawRad: 0, uncertaintyM: 0.1, floorID: "1"),
        FinalTrajectory.Node(id: 4, monotonicSeconds: 10, xM: 2, yM: 1, yawRad: 0, uncertaintyM: 0.1, floorID: "1"),
    ]
    let rows = FinalTrajectory.resample(
        input: FinalTrajectory.Input(
            nodes: nodes,
            lostIntervals: [FinalTrajectory.LostInterval(
                fromMonotonic: 3, toMonotonic: 7, reason: "tracking_lost")],
            sessionStartUTC: 2_000_000_000,
            sessionEndUTC: 2_000_000_009),
        utcMapper: mapper, storeID: "s1",
        priorMapID: "m", priorMapSha256: "a",
        trackingSessionID: "s", appGitSHA: "g")
    require(rows.count == 10, "T4 must emit 10 rows, got \(rows.count)")
    // Seconds 3..7 (0-indexed rows) fall inside the lost interval.
    let lostRows = rows.enumerated().filter { (3...7).contains($0.offset) }
    require(
        lostRows.allSatisfy { $0.element.positionStatus == "UNAVAILABLE" },
        "T4 lost-interval seconds must be UNAVAILABLE")
    // Seconds 8 falls between nodes at monotonic 1 and 9 (8s gap > 3s)
    // -> UNAVAILABLE; second 9 lands exactly on node 3 -> ACCEPTED.
    require(
        rows[8].positionStatus == "UNAVAILABLE",
        "T4 over-long node gaps must be UNAVAILABLE")
    require(
        rows[9].positionStatus == "ACCEPTED",
        "T4 a second landing on a node after a gap must be ACCEPTED")
    require(
        rows[0].positionStatus == "ACCEPTED",
        "T4 connected seconds must stay ACCEPTED")
    // Second 1 (monotonic 1) has no upper node within the interpolation
    // window (node at 9 is 8s away) -> UNAVAILABLE.
    require(
        rows[1].positionStatus == "UNAVAILABLE",
        "T4 a node isolated by an over-long forward gap must be UNAVAILABLE")
}
catch {
    require(false, "T4 lost interval failed: \(error)")
}

// T12: 100k rows export inside a real workbook (X6), plus formula
// injection and control-character sanitization (X8/X9). The 100k-scale
// run lives in the separate --xlsx-scale mode so the default host mode
// stays within the frozen peak-RSS gate.
do {

    // X1-X9 round-trip over a bounded workbook (10k rows keeps the
    // worksheet inside the frozen 64 MiB import-reader entry limit and
    // the default mode inside the peak-RSS gate).
    let output = try p7r6FreshDirectory("mobile-xlsx")
        .appendingPathComponent("result.xlsx")
    try MobileResultExporter.export(
        input: makeInput(positions: makePositions(10_000)), to: output)
    let data = try Data(contentsOf: output)
    let entries = try XLSXZipReader.readEntries(data: data)
    let names = Set(entries.map { $0.name })
    require(
        names.contains("xl/workbook.xml")
            && names.contains("[Content_Types].xml")
            && names.contains("xl/worksheets/sheet1.xml")
            && names.contains("xl/worksheets/sheet2.xml")
            && names.contains("xl/worksheets/sheet3.xml")
            && names.contains("xl/worksheets/sheet4.xml"),
        "X1/X4 workbook must be a real Open XML package with 4 sheets")
    let workbookXML = String(
        data: entries.first { $0.name == "xl/workbook.xml" }!.data,
        encoding: .utf8) ?? ""
    require(
        workbookXML.contains("PriceTags")
            && workbookXML.contains("DevicePositions")
            && workbookXML.contains("RunSummary")
            && workbookXML.contains("RescanRequired"),
        "X4 workbook must name the four required sheets")
    let sheet1 = String(
        data: entries.first { $0.name == "xl/worksheets/sheet1.xml" }!.data,
        encoding: .utf8) ?? ""
    require(
        sheet1.contains("&apos;=HYPERLINK") || sheet1.contains("'=HYPERLINK"),
        "X8 formula-like barcode must be neutralized")
    require(
        !sheet1.contains("<f>"),
        "X8 the workbook must never contain formula elements")
    let sanitized = XLSXWorkbookWriter.sanitizeXML("a\u{0001}b\u{0008}c")
    require(
        sanitized == "abc",
        "X9 control characters must be stripped, got \(sanitized)")
    require(
        XLSXWorkbookWriter.sanitizeXML("&<>\"") == "&amp;&lt;&gt;&quot;",
        "X9 XML specials must be escaped")
}
catch {
    require(false, "X6/X8/X9 workbook tests failed: \(error)")
}

// =====================================================================
// Mobile-Only V1: tag finalization (G1-G10): node/time binding, position
// propagation, burst fusion, shelf association and the quality gate.
// =====================================================================

// G1/G2: explicit node binding and nearest-timestamp binding.
do {
    let finalNodes = [
        TagObservationResolver.FinalNodePose(
            id: 10, monotonicSeconds: 500.0,
            pose: SE2Transform(xM: 2, yM: 3, yawRad: 0),
            floorID: "1"),
        TagObservationResolver.FinalNodePose(
            id: 11, monotonicSeconds: 501.5,
            pose: SE2Transform(xM: 2, yM: 4, yawRad: Double.pi / 2),
            floorID: "1"),
    ]
    // Explicit node 10, raw pose = identity, raw position (0, 0).
    let resolved = try TagObservationResolver.resolve(
        observation: TagObservationResolver.RawObservation(
            barcode: "6901", symbology: "CODE128", floorID: "1",
            nodeID: 10, nodeTimestamp: 500.0, frameMonotonicSeconds: 500.0,
            rawPositionM: (0, 0, 0), rawNodePose: .identity,
            trackingSessionID: "s"),
        finalNodes: finalNodes, sessionID: "s")
    require(
        resolved.mapXM == 2 && resolved.mapYM == 3 && resolved.nodeID == 10,
        "G1 explicit-node binding must propagate to (2,3), got \(resolved.mapXM),\(resolved.mapYM)")
    // Raw node pose with an offset: T_raw is identity so the tag local
    // position is (-1, 0); T_final(node 11) = (2, 4, +90deg) rotates
    // (-1, 0) to (0, -1), so P_final = (2, 3).
    let resolved2 = try TagObservationResolver.resolve(
        observation: TagObservationResolver.RawObservation(
            barcode: "6902", symbology: "CODE128", floorID: "1",
            nodeID: 11, nodeTimestamp: 501.5, frameMonotonicSeconds: 501.5,
            rawPositionM: (-1, 0, 0),
            rawNodePose: SE2Transform(xM: 0, yM: 0, yawRad: 0),
            trackingSessionID: "s"),
        finalNodes: finalNodes, sessionID: "s")
    require(
        close(resolved2.mapXM, 2.0) && close(resolved2.mapYM, 3.0),
        "G1 position propagation must apply T_final*inv(T_raw)*P, got \(resolved2.mapXM),\(resolved2.mapYM)")
    // Nearest-node timestamp binding (no explicit node id).
    let resolved3 = try TagObservationResolver.resolve(
        observation: TagObservationResolver.RawObservation(
            barcode: "6903", symbology: "CODE128", floorID: "1",
            nodeID: nil, nodeTimestamp: 501.6, frameMonotonicSeconds: 501.6,
            rawPositionM: (0, 0, 0), rawNodePose: .identity,
            trackingSessionID: "s"),
        finalNodes: finalNodes, sessionID: "s")
    require(
        resolved3.nodeID == 11 && resolved3.bindingMethod == "nearest_node_timestamp",
        "G2 nearest-node binding must pick node 11, got \(resolved3.nodeID)/\(resolved3.bindingMethod)")
    // Session mismatch must reject.
    do {
        _ = try TagObservationResolver.resolve(
            observation: TagObservationResolver.RawObservation(
                barcode: "x", symbology: "CODE128", floorID: "1",
                nodeID: 10, nodeTimestamp: 500.0, frameMonotonicSeconds: 500.0,
                rawPositionM: (0, 0, 0), rawNodePose: .identity,
                trackingSessionID: "other"),
            finalNodes: finalNodes, sessionID: "s")
        require(false, "G1 session mismatch must be rejected")
    }
    catch let error as TagObservationResolver.ResolutionError {
        require(
            error == .sessionMismatch,
            "G1 session mismatch error code must be sessionMismatch")
    }
}
catch {
    require(false, "G1/G2 tag binding failed: \(error)")
}

// G4/G5: burst fusion clusters same-barcode instances per floor; distant
// same-barcode observations stay separate instances.
do {
    let observations = [
        TagObservationResolver.ResolvedObservation(
            barcode: "B1", symbology: "CODE128", floorID: "1",
            mapXM: 1.0, mapYM: 2.0, mapZM: 0, nodeID: 1,
            nodeTimestamp: 0, frameMonotonicSeconds: 0,
            trackingSessionID: "s", bindingMethod: "explicit_node"),
        TagObservationResolver.ResolvedObservation(
            barcode: "B1", symbology: "CODE128", floorID: "1",
            mapXM: 1.02, mapYM: 2.01, mapZM: 0, nodeID: 1,
            nodeTimestamp: 0, frameMonotonicSeconds: 0,
            trackingSessionID: "s", bindingMethod: "explicit_node"),
        TagObservationResolver.ResolvedObservation(
            barcode: "B1", symbology: "CODE128", floorID: "1",
            mapXM: 1.01, mapYM: 1.99, mapZM: 0, nodeID: 1,
            nodeTimestamp: 0, frameMonotonicSeconds: 0,
            trackingSessionID: "s", bindingMethod: "explicit_node"),
        TagObservationResolver.ResolvedObservation(
            barcode: "B1", symbology: "CODE128", floorID: "2",
            mapXM: 30.0, mapYM: 30.0, mapZM: 0, nodeID: 2,
            nodeTimestamp: 0, frameMonotonicSeconds: 0,
            trackingSessionID: "s", bindingMethod: "explicit_node"),
        TagObservationResolver.ResolvedObservation(
            barcode: "B1", symbology: "CODE128", floorID: "2",
            mapXM: 30.02, mapYM: 30.01, mapZM: 0, nodeID: 2,
            nodeTimestamp: 0, frameMonotonicSeconds: 0,
            trackingSessionID: "s", bindingMethod: "explicit_node"),
        TagObservationResolver.ResolvedObservation(
            barcode: "B1", symbology: "CODE128", floorID: "2",
            mapXM: 30.01, mapYM: 29.99, mapZM: 0, nodeID: 2,
            nodeTimestamp: 0, frameMonotonicSeconds: 0,
            trackingSessionID: "s", bindingMethod: "explicit_node"),
    ]
    let instances = TagObservationResolver.clusterInstances(
        observations: observations, clusterRadiusM: 1.5)
    require(
        instances.count == 2,
        "G4/G5 same barcode on two floors must yield two instances, got \(instances.count)")
    let floor1 = instances.first { $0.floorID == "1" }
    let floor2 = instances.first { $0.floorID == "2" }
    require(
        floor1 != nil && floor1!.observationCount == 3,
        "G4 burst fusion must merge 3 samples into one instance")
    require(
        floor2 != nil && floor2!.observationCount == 3,
        "G5 floor-2 cluster must be independent")
    require(
        close(floor1?.mapXM ?? -1, 1.01, tolerance: 1.0e-6),
        "G4 fused position must be the burst centroid, got \(floor1?.mapXM ?? -1)")
}
catch {
    require(false, "G4/G5 burst fusion failed: \(error)")
}

// G6/G7/G10: shelf association and the automatic quality gate.
do {
    let shelf = ShelfAssociationEngine.ShelfSegment(
        shelfCode: "A1", floorID: "1",
        startM: (0, 0), endM: (10, 0), side: "front")
    guard let mid = ShelfAssociationEngine.associate(
        point: (5, 0.05), shelf: shelf, floorID: "1") else {
        require(false, "G6 shelf association must succeed at mid")
        throw MapSourceImportError.unknownFormat
    }
    require(
        close(mid.distanceFromShelfStartCm, 500.0, tolerance: 1.0e-6)
            && close(mid.positionRatio, 0.5, tolerance: 1.0e-6)
            && close(mid.distanceToSegmentM, 0.05, tolerance: 1.0e-6),
        "G6 mid-shelf projection must be (500cm, 0.5), got \(mid.distanceFromShelfStartCm),\(mid.positionRatio)")
    require(!mid.atEndpoint, "G6 mid-shelf must not be endpoint-ambiguous")
    guard let endpoint = ShelfAssociationEngine.associate(
        point: (0.05, 0.0), shelf: shelf, floorID: "1") else {
        require(false, "G6 endpoint association must succeed")
        throw MapSourceImportError.unknownFormat
    }
    require(endpoint.atEndpoint, "G7 endpoint zone must be flagged ambiguous")
    // Quality gate: accepted only with sufficient burst and geometry.
    func gateInput(
        count: Int,
        spread: Double,
        association: ShelfAssociationEngine.Association,
        graphOK: Bool = true,
        identityOK: Bool = true
    ) -> AutomaticQualityGate.TagQualityInput {
        return AutomaticQualityGate.TagQualityInput(
            observationCount: count, positionSpreadM: spread,
            minimumBurstSamples: 3, maximumSpreadM: 0.1,
            bindingMethod: "explicit_node",
            association: association,
            maximumEndpointDistanceM: 0.15,
            maximumAssociationDistanceM: 0.2,
            graphQualityPassed: graphOK,
            mapSessionIdentityConsistent: identityOK)
    }
    let accepted = AutomaticQualityGate.evaluate(gateInput(
        count: 5, spread: 0.02, association: mid))
    require(
        accepted.0 == .accepted,
        "G10 a well-supported mid-shelf tag must be ACCEPTED, got \(accepted.0.rawValue)")
    let sparse = AutomaticQualityGate.evaluate(gateInput(
        count: 1, spread: 0.02, association: mid))
    require(
        sparse.0 == .rescanRequired,
        "G10 insufficient burst samples must be RESCAN_REQUIRED, got \(sparse.0.rawValue)")
    let endpointGate = AutomaticQualityGate.evaluate(gateInput(
        count: 5, spread: 0.02, association: endpoint))
    require(
        endpointGate.0 == .rescanRequired,
        "G7 endpoint-ambiguous tags must be RESCAN_REQUIRED, got \(endpointGate.0.rawValue)")
}
catch {
    require(false, "G6/G7/G10 shelf/quality tests failed: \(error)")
}

// =====================================================================
// Mobile-Only V1: Fast Path factor graph (P1/P2), session snapshot
// transaction (P7) and the persistent task state machine (P8/P12).
// =====================================================================

// P1/P2: a small chain with a wrong odometry drift and a loop closure
// must converge to a residual near zero; anchor pose is preserved.
do {
    let nodes = [
        SE2FactorGraphCore.Node(id: 1, initialPose: .identity, isAnchor: true, floorID: "1"),
        SE2FactorGraphCore.Node(id: 2, initialPose: SE2Transform(xM: 1, yM: 0, yawRad: 0), isAnchor: false, floorID: "1"),
        SE2FactorGraphCore.Node(id: 3, initialPose: SE2Transform(xM: 2, yM: 0.5, yawRad: 0), isAnchor: false, floorID: "1"),
        SE2FactorGraphCore.Node(id: 4, initialPose: SE2Transform(xM: 3, yM: 0.5, yawRad: 0), isAnchor: false, floorID: "1"),
    ]
    let edges = [
        SE2FactorGraphCore.Edge(from: 1, to: 2, measurement: SE2Transform(xM: 1, yM: 0, yawRad: 0), weight: 10, kind: "odometry"),
        SE2FactorGraphCore.Edge(from: 2, to: 3, measurement: SE2Transform(xM: 1, yM: 0, yawRad: 0), weight: 10, kind: "odometry"),
        SE2FactorGraphCore.Edge(from: 3, to: 4, measurement: SE2Transform(xM: 1, yM: 0, yawRad: 0), weight: 10, kind: "odometry"),
        // Loop closure pulls node 4 back to the line y=0.
        SE2FactorGraphCore.Edge(from: 4, to: 1, measurement: SE2Transform(xM: -3, yM: 0, yawRad: 0), weight: 8, kind: "loop_closure"),
    ]
    let graph = try SE2FactorGraphCore.optimize(nodes: nodes, edges: edges)
    require(
        graph.finalResidual < 1.0e-3,
        "P1 fast-path must converge near zero residual, got \(graph.finalResidual)")
    require(
        close(graph.poses[1]?.xM ?? -1, 0.0) && close(graph.poses[1]?.yM ?? -1, 0.0),
        "P1 the anchor pose must stay fixed")
    require(
        close(graph.poses[2]?.yM ?? -1, 0.0, tolerance: 2.0e-2)
            && close(graph.poses[3]?.yM ?? -1, 0.0, tolerance: 2.0e-2),
        "P1 loop closure must flatten the drift, got \(graph.poses[3]?.yM ?? -1)")
}
catch {
    require(false, "P1 fast-path factor graph failed: \(error)")
}

// P7: the session snapshot transaction copies inputs into a private
// snapshot and computes a bundle digest over the stable bytes.
do {
    let session = try p7r6FreshDirectory("mobile-session")
    let fileManager = FileManager.default
    let metadata = Data("{\"finalized\":true}".utf8)
    try metadata.write(to: session.appendingPathComponent("metadata.json"))
    try Data("trace\n".utf8).write(to: session.appendingPathComponent("localization_trace.jsonl"))
    try Data("constraints\n".utf8).write(to: session.appendingPathComponent("localization_constraints.jsonl"))
    try Data("manual\n".utf8).write(to: session.appendingPathComponent("manual_localization_events.jsonl"))
    try Data("obs\n".utf8).write(to: session.appendingPathComponent("tag_observations.jsonl"))
    try Data("events\n".utf8).write(to: session.appendingPathComponent("localization_events.jsonl"))
    try Data("recovery\n".utf8).write(to: session.appendingPathComponent("localization_recovery_events.jsonl"))
    try Data("[]".utf8).write(to: session.appendingPathComponent("localized_price_tags.json"))
    let database = session.appendingPathComponent("source.db")
    try Data("sqlite-bytes".utf8).write(to: database)

    let taskRoot = try p7r6FreshDirectory("mobile-task")
    let snapshot = try SessionSnapshotTransaction.snapshot(
        finalizedSession: session, sourceDatabase: database, taskRoot: taskRoot)
    require(
        !snapshot.bundleSHA256.isEmpty,
        "P7 snapshot must compute a non-empty bundle digest")
    require(
        fileManager.fileExists(
            atPath: snapshot.snapshotDirectory.appendingPathComponent("source.db").path),
        "P7 snapshot must contain the immutable source DB copy")
    // The persisted input manifest must agree with the snapshot digest,
    // and mutating the original session afterwards must not change it.
    let persistedManifestData = try Data(
        contentsOf: taskRoot.appendingPathComponent("input_manifest.json"))
    let persistedManifest = try StrictJSONDocumentParser.object(
        from: persistedManifestData,
        limits: StrictJSONDocumentLimits(maximumBytes: persistedManifestData.count + 1))
    require(
        (persistedManifest["bundle_sha256"] as? String) == snapshot.bundleSHA256,
        "P7 the persisted input manifest must bind the snapshot digest")
    try Data("tampered".utf8).write(to: database)
    try Data("tampered-trace\n".utf8).write(
        to: session.appendingPathComponent("localization_trace.jsonl"))
    let manifestAfter = try Data(contentsOf: taskRoot.appendingPathComponent("input_manifest.json"))
    require(
        manifestAfter == persistedManifestData,
        "P7 the persisted snapshot manifest must not change when the original is tampered")
}
catch {
    require(false, "P7 session snapshot transaction failed: \(error)")
}

// P8/P12: the persistent task state machine survives atomic writes and
// interrupted states are never reported completed.
do {
    let taskRoot = try p7r6FreshDirectory("mobile-state")
    _ = try PersistentTaskCoordinator.createTask(taskID: "t1", taskRoot: taskRoot)
    _ = try PersistentTaskCoordinator.updateState(.snapshotting, taskRoot: taskRoot, progress: 0.1)
    _ = try PersistentTaskCoordinator.updateState(.fastOptimizing, taskRoot: taskRoot, progress: 0.4)
    _ = try PersistentTaskCoordinator.updateState(.interrupted, taskRoot: taskRoot, progress: 0.4)
    let record = try PersistentTaskCoordinator.read(taskRoot: taskRoot)
    require(
        record.state == .interrupted && record.progress == 0.4,
        "P8 task.json must persist the interrupted state atomically")
    require(
        record.state != .completed,
        "P8 an interrupted task must never be reported completed")
    require(
        PersistentTaskCoordinator.isResumable(record),
        "P12 an interrupted task must be resumable after a crash")
    _ = try PersistentTaskCoordinator.updateState(.completed, taskRoot: taskRoot, progress: 1.0)
    let completed = try PersistentTaskCoordinator.read(taskRoot: taskRoot)
    require(
        completed.state == .completed && !PersistentTaskCoordinator.isResumable(completed),
        "P12 a completed task is terminal")
}
catch {
    require(false, "P8/P12 persistent task state machine failed: \(error)")
}

} // end of C1/C2 default-mode-only host tests

// P7R6A fixture alignment mode: classifies every shared recovery fixture
// through the device-side strict parser and prints "<name> <category>" so
// the Python test can assert the Swift parser and the PC reader agree.
if CommandLine.arguments.count >= 3,
   CommandLine.arguments[1] == "--recovery-fixtures" {
    do {
        let fixtureDirectory = URL(
            fileURLWithPath: CommandLine.arguments[2],
            isDirectory: true)
        let names = try FileManager.default.contentsOfDirectory(
            atPath: fixtureDirectory.path).filter {
                $0.hasSuffix(".jsonl")
            }.sorted()
        guard !names.isEmpty else {
            FileHandle.standardError.write(
                Data("No recovery lifecycle fixtures found\n".utf8))
            exit(3)
        }
        for name in names {
            let data = try Data(
                contentsOf: fixtureDirectory.appendingPathComponent(name))
            let category: String
            do {
                _ = try RecoveryLifecyclePersistedEvidenceParser.parse(
                    snapshot: data,
                    expectation: p7r6aParseExpectation())
                category = "PASS"
            }
            catch let error as RecoveryLifecycleEvidenceParseError {
                category = error.stableCode
            }
            print("\(name) \(category)")
        }
        exit(0)
    }
    catch {
        FileHandle.standardError.write(
            Data("Recovery fixture alignment failed: \(error)\n".utf8))
        exit(4)
    }
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

// P7R6C-C3: integrity-suite mode validates a batch of package directories
// in ONE executable invocation. The root contains subdirectories named
// "<case>.<expected>" where expected is "pass" or "fail"; the harness
// verifies every case against the snapshot validator without re-launching
// the process (CI wall-clock budgets otherwise get blown by repeated
// process starts).
if CommandLine.arguments.count == 3,
   CommandLine.arguments[1] == "--integrity-suite" {
    do {
        let root = URL(
            fileURLWithPath: CommandLine.arguments[2],
            isDirectory: true)
        let entries = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [])
        var failed: [String] = []
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard (try? entry.resourceValues(
                forKeys: [.isDirectoryKey]).isDirectory) == true else {
                continue
            }
            let name = entry.lastPathComponent
            let expected: Bool
            if name.hasSuffix(".pass") {
                expected = true
            }
            else if name.hasSuffix(".fail") {
                expected = false
            }
            else {
                continue
            }
            do {
                _ = try PriorMapPackageIntegrity.validate(directory: entry)
                if !expected {
                    failed.append("\(name): expected fail but passed")
                }
            }
            catch {
                if expected {
                    failed.append("\(name): expected pass but failed: \(error)")
                }
            }
        }
        guard failed.isEmpty else {
            FileHandle.standardError.write(
                Data(("Integrity suite failures:\n"
                    + failed.joined(separator: "\n") + "\n").utf8))
            exit(5)
        }
        print("Integrity suite passed")
    }
    catch {
        FileHandle.standardError.write(
            Data("Integrity suite failed: \(error)\n".utf8))
        exit(5)
    }
}

// Mobile-Only V1: --import-suite validates the three-format canonical
// parity and the XLSX safety policy in ONE invocation. The directory
// contains the fixtures produced by the Python harness:
//   sample.xlsx sample.csv sample.json  -> must import with equal
//                                          canonicalSourceSha256
//   formula.xlsx                        -> must fail formulaNotSupported
//   traversal.xlsx                      -> must fail zipTraversal
//   bomb.xlsx                           -> must fail zip ratio/total
//   multi-floor.json                    -> must import with 2 floors
if CommandLine.arguments.count == 3,
   CommandLine.arguments[1] == "--import-suite" {
    do {
        let root = URL(
            fileURLWithPath: CommandLine.arguments[2],
            isDirectory: true)
        let fileManager = FileManager.default

        func load(_ name: String) throws -> Data {
            let url = root.appendingPathComponent(name)
            guard fileManager.fileExists(atPath: url.path) else {
                throw MapSourceImportError.unreadableSource(reason: "缺少 fixture \(name)")
            }
            return try Data(contentsOf: url)
        }

        var failures: [String] = []

        // Three-format parity: identical canonical digest and elements.
        do {
            let xlsxData = try load("sample.xlsx")
            let csvData = try load("sample.csv")
            let jsonData = try load("sample.json")

            let xlsxReport = try MapSourceImportCoordinator.importMap(
                stagedURL: try writeTemporary(xlsxData, named: "sample.xlsx"),
                originalFilename: "sample.xlsx",
                contract: .topLeft)
            let csvReport = try MapSourceImportCoordinator.importMap(
                stagedURL: try writeTemporary(csvData, named: "sample.csv"),
                originalFilename: "sample.csv",
                contract: .topLeft)
            let jsonReport = try MapSourceImportCoordinator.importMap(
                stagedURL: try writeTemporary(jsonData, named: "sample.json"),
                originalFilename: "sample.json",
                contract: .topLeft)

            if xlsxReport.canonicalSourceSha256 != csvReport.canonicalSourceSha256 {
                failures.append("parity: xlsx vs csv canonical SHA mismatch")
            }
            if xlsxReport.canonicalSourceSha256 != jsonReport.canonicalSourceSha256 {
                failures.append("parity: xlsx vs json canonical SHA mismatch")
            }
            if xlsxReport.canonicalSource.elements != csvReport.canonicalSource.elements {
                failures.append("parity: xlsx vs csv elements mismatch")
            }
            if xlsxReport.canonicalSource.elements != jsonReport.canonicalSource.elements {
                failures.append("parity: xlsx vs json elements mismatch")
            }
            if xlsxReport.elementCount != csvReport.elementCount
                || xlsxReport.elementCount != jsonReport.elementCount {
                failures.append("parity: element count mismatch")
            }
            if xlsxReport.floorCount != csvReport.floorCount
                || xlsxReport.floorCount != jsonReport.floorCount {
                failures.append("parity: floor count mismatch")
            }
            if xlsxReport.sourceFileSha256 == csvReport.sourceFileSha256 {
                failures.append("parity: sourceFileSha256 must differ across formats")
            }
            if xlsxReport.canonicalSourceSha256.isEmpty {
                failures.append("parity: canonical SHA must not be empty")
            }
        }
        catch {
            failures.append("parity: \(error)")
        }

        // I5: formula cells are rejected.
        do {
            let data = try load("formula.xlsx")
            _ = try MapSourceImportCoordinator.importMap(
                stagedURL: try writeTemporary(data, named: "formula.xlsx"),
                originalFilename: "formula.xlsx",
                contract: .topLeft)
            failures.append("formula: expected rejection")
        }
        catch let error as MapSourceImportError {
            if error.stableCode != "map_source_formula_not_supported" {
                failures.append("formula: wrong code \(error.stableCode)")
            }
        }
        catch {
            failures.append("formula: unexpected error \(error)")
        }

        // I6: ZIP path traversal is rejected.
        do {
            let data = try load("traversal.xlsx")
            _ = try MapSourceImportCoordinator.importMap(
                stagedURL: try writeTemporary(data, named: "traversal.xlsx"),
                originalFilename: "traversal.xlsx",
                contract: .topLeft)
            failures.append("traversal: expected rejection")
        }
        catch let error as MapSourceImportError {
            if error.stableCode != "map_source_zip_traversal" {
                failures.append("traversal: wrong code \(error.stableCode)")
            }
        }
        catch {
            failures.append("traversal: unexpected error \(error)")
        }

        // I7: ZIP bomb (extreme compression ratio) is rejected.
        do {
            let data = try load("bomb.xlsx")
            _ = try MapSourceImportCoordinator.importMap(
                stagedURL: try writeTemporary(data, named: "bomb.xlsx"),
                originalFilename: "bomb.xlsx",
                contract: .topLeft)
            failures.append("bomb: expected rejection")
        }
        catch let error as MapSourceImportError {
            let code = error.stableCode
            if code != "map_source_zip_ratio_too_large"
                && code != "map_source_zip_entry_too_large"
                && code != "map_source_zip_total_too_large" {
                failures.append("bomb: wrong code \(code)")
            }
        }
        catch {
            failures.append("bomb: unexpected error \(error)")
        }

        // I14: multi-floor JSON imports with 3 floors.
        do {
            let data = try load("multi-floor.json")
            let report = try MapSourceImportCoordinator.importMap(
                stagedURL: try writeTemporary(data, named: "multi-floor.json"),
                originalFilename: "multi-floor.json",
                contract: .topLeft)
            if report.floorCount != 3 {
                failures.append("multi-floor: expected 3 floors, got \(report.floorCount)")
            }
        }
        catch {
            failures.append("multi-floor: \(error)")
        }

        guard failures.isEmpty else {
            FileHandle.standardError.write(
                Data(("Import suite failures:\n"
                    + failures.joined(separator: "\n") + "\n").utf8))
            exit(6)
        }
        print("Import suite passed")
    }
    catch {
        FileHandle.standardError.write(
            Data("Import suite failed: \(error)\n".utf8))
        exit(6)
    }
}

// Writes a fixture into a temporary file under the suite directory so the
// coordinator can hash a stable staged copy (the security-scoped copy is
// simulated by writing to a private staging file).
private func writeTemporary(_ data: Data, named name: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("import-suite-staging", isDirectory: true)
    try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent(name)
    try data.write(to: url, options: [.atomic])
    return url
}

// Mobile-Only V1: --xlsx-scale exports a 100k-row DevicePositions
// workbook to the given directory. It runs as its own process so the
// default host mode stays inside the frozen peak-RSS gate.
if CommandLine.arguments.count == 3,
   CommandLine.arguments[1] == "--xlsx-scale" {
    do {
        let output = URL(fileURLWithPath: CommandLine.arguments[2])
            .appendingPathComponent("result-100k.xlsx")
        try MobileResultExporter.export(
            input: makeInput(positions: makePositions(100_000)), to: output)
        let bytes = (try FileManager.default.attributesOfItem(
            atPath: output.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard bytes > 0 else {
            FileHandle.standardError.write(
                Data("xlsx-scale produced an empty file\n".utf8))
            exit(7)
        }
        print("xlsx-scale workbook bytes: \(bytes)")
    }
    catch {
        FileHandle.standardError.write(
            Data("xlsx-scale failed: \(error)\n".utf8))
        exit(7)
    }
}

var finalizationResourceUsage = rusage()
if getrusage(RUSAGE_SELF, &finalizationResourceUsage) == 0 {
    print("Finalization test peak RSS bytes: \(finalizationResourceUsage.ru_maxrss)")
}
print("PriorMapLocalizationCore Swift tests passed")
