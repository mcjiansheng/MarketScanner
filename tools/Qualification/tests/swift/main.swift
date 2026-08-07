import CryptoKit
import Darwin
import Foundation

// The focused host links only the production sources under test. These
// two production dependencies are intentionally reduced to the exact
// interfaces MobileBuildIdentity/MobileResultLibrary consume.
enum RecoveryLifecycleEvidenceLimits {
    static let maximumJSONNestingDepth = 64
}

enum MobileMapLibrary {
    enum SyncError: Error { case openFailed, fsyncFailed }

    static func syncDirectory(_ directory: URL) throws {
        let descriptor = open(directory.path, O_RDONLY)
        guard descriptor >= 0 else { throw SyncError.openFailed }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw SyncError.fsyncFailed }
    }
}

enum MobilePackageManifestBuilder {
    static func packageDigest(_ artifacts: [[String: Any]]) -> String {
        return CanonicalSourceHasher.sha256(
            Data("artifact-count:\(artifacts.count)".utf8))
    }
}

enum InjectedResultFreezeFailure: Error {
    case stopBeforeRename
}

struct InjectedTerminalWriteFailure: Error, CustomStringConvertible {
    let stage: PersistentTaskCoordinator.WriteStage

    var description: String {
        return "injected_terminal_write_failure:\(stage.rawValue)"
    }
}

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        FileHandle.standardError.write(Data("FAILED: \(message)\n".utf8))
        exit(1)
    }
}

func permissions(_ url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
}

func makeTreeRemovable(_ root: URL) {
    let fileManager = FileManager.default
    try? fileManager.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: root.path)
    guard let enumerator = fileManager.enumerator(
        at: root,
        includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
        options: []) else { return }
    for case let url as URL in enumerator {
        let values = try? url.resourceValues(
            forKeys: [.isDirectoryKey, .isRegularFileKey])
        if values?.isDirectory == true {
            try? fileManager.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: url.path)
        } else if values?.isRegularFile == true {
            try? fileManager.setAttributes(
                [.posixPermissions: 0o644], ofItemAtPath: url.path)
        }
    }
}

func placeholderIdentity() -> MobileBuildIdentity {
    return MobileBuildIdentity(
        appGitSHA: String(repeating: "a", count: 40),
        wave: "mobile-only-v1-release-candidate-blocker-closeout",
        branch: "mobile-only-v1-release-candidate-blocker-closeout",
        baseBranch: "mobile-only-v1r5-field-qualification-integrity-scale-closeout",
        baseSHA: String(repeating: "8", count: 40),
        implementationSHA: "<CODE_CONTRACT_TEST_BUILD_SHA>",
        validationSHA: "<EVIDENCE_DOCS_SHA>",
        nativeCoreSHA256: String(repeating: "b", count: 64))
}

do {
    let placeholder = placeholderIdentity()
    require(
        !placeholder.isUsable,
        "unbound governance placeholders must block runtime eligibility")
    require(
        placeholder.implementationSHA == "<CODE_CONTRACT_TEST_BUILD_SHA>"
            && placeholder.validationSHA == "<EVIDENCE_DOCS_SHA>",
        "exact pre-governance placeholders must remain loadable for audit")
    var bound = placeholder
    bound.implementationSHA = String(repeating: "c", count: 40)
    bound.validationSHA = String(repeating: "d", count: 40)
    require(
        bound.isUsable,
        "current RC wave with fully bound governance SHAs must be usable "
            + "without the obsolete V1R4 prefix")

    let invalidMutations: [(String, (inout MobileBuildIdentity) -> Void)] = [
        ("wave", { $0.wave = "unsafe/wave" }),
        ("branch", { $0.branch = "" }),
        ("base branch", { $0.baseBranch = "../base" }),
        ("base SHA", { $0.baseSHA = String(repeating: "F", count: 40) }),
        ("implementation SHA", { $0.implementationSHA = "<WRONG_SHA>" }),
        ("validation SHA", { $0.validationSHA = String(repeating: "e", count: 39) }),
        ("app SHA", { $0.appGitSHA = String(repeating: "a", count: 39) }),
        ("native digest", { $0.nativeCoreSHA256 = String(repeating: "B", count: 64) }),
    ]
    for (field, mutate) in invalidMutations {
        var malformed = bound
        mutate(&malformed)
        require(!malformed.isUsable, "invalid \(field) must fail closed")
    }
    print("Swift build identity governance contract passed")

    let temporary = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "marketscanner-result-freeze-\(UUID().uuidString)",
            isDirectory: true)
    try FileManager.default.createDirectory(
        at: temporary, withIntermediateDirectories: false)
    defer {
        makeTreeRemovable(temporary)
        try? FileManager.default.removeItem(at: temporary)
        MobileResultLibrary.commitFaultInjector = nil
        MobileResultLibrary.rootOverride = nil
        PersistentTaskCoordinator.writeFaultInjector = nil
    }

    let terminalTasksRoot = temporary.appendingPathComponent(
        "TerminalTasks", isDirectory: true)
    try FileManager.default.createDirectory(
        at: terminalTasksRoot, withIntermediateDirectories: false)
    let terminalRoutes: [(
        name: String,
        error: MobileOnlyWorkflowError,
        outcome: MobileTerminalStatePersistence.BusinessOutcome,
        state: PersistentTaskCoordinator.TaskState,
        persistedReason: String
    )] = [
        (
            "cancelled", .cancelled, .cancelled, .cancelled,
            "user_cancelled"),
        (
            "interrupted", .interrupted, .interrupted, .interrupted,
            "system_interrupted"),
        (
            "resource-required", .resourceRequired("memory pressure"),
            .resourceRequired, .interrupted, "resource_pause"),
        (
            "workflow-failed", .invalidState("forced workflow failure"),
            .workflowFailed, .failed,
            MobileOnlyWorkflowError.invalidState(
                "forced workflow failure").localizedDescription),
    ]
    let terminalWriteStages: [PersistentTaskCoordinator.WriteStage] = [
        .beforeTemporaryWrite,
        .afterTemporaryFsync,
        .afterRename,
        .afterParentFsync,
    ]

    // Successful terminal persistence must write the intended task state,
    // remove its intent marker, and rethrow the ORIGINAL business error.
    for route in terminalRoutes {
        let taskID = "terminal-success-\(route.name)"
        let taskRoot = terminalTasksRoot.appendingPathComponent(
            taskID, isDirectory: true)
        _ = try PersistentTaskCoordinator.createTask(
            taskID: taskID, taskRoot: taskRoot)
        _ = try PersistentTaskCoordinator.updateState(
            .snapshotting, taskRoot: taskRoot, progress: 0.1)
        do {
            try MobileTerminalStatePersistence.persistThenRethrow(
                route.error, taskRoot: taskRoot)
        } catch let returned as MobileOnlyWorkflowError {
            require(
                returned == route.error,
                "successful terminal transaction must rethrow original "
                    + "\(route.name) error")
        }
        let record = try PersistentTaskCoordinator.read(taskRoot: taskRoot)
        require(
            record.state == route.state
                && record.error == route.persistedReason,
            "successful \(route.name) terminal state/reason mismatch")
        let clearedSuccessIntent = try MobileTerminalStatePersistence
            .readIntentIfPresent(taskRoot: taskRoot)
        require(
            clearedSuccessIntent == nil,
            "successful \(route.name) transaction must clear its intent")
    }

    // P1-11 matrix: every business outcome at every task writer boundary
    // must surface a typed business+durability error. The durable intent
    // must remain, restart reconciliation must finish/confirm the target
    // state, and no temporary task file may leak.
    for route in terminalRoutes {
        for stage in terminalWriteStages {
            let taskID = "terminal-\(route.name)-\(stage.rawValue)"
            let taskRoot = terminalTasksRoot.appendingPathComponent(
                taskID, isDirectory: true)
            _ = try PersistentTaskCoordinator.createTask(
                taskID: taskID, taskRoot: taskRoot)
            _ = try PersistentTaskCoordinator.updateState(
                .snapshotting, taskRoot: taskRoot, progress: 0.1)
            PersistentTaskCoordinator.writeFaultInjector = { observed in
                if observed == stage {
                    throw InjectedTerminalWriteFailure(stage: stage)
                }
            }
            do {
                try MobileTerminalStatePersistence.persistThenRethrow(
                    route.error, taskRoot: taskRoot)
                require(
                    false,
                    "\(route.name)/\(stage.rawValue) must not report "
                        + "business terminal success")
            } catch let failure as MobileTerminalStatePersistence
                    .DurabilityFailure {
                require(
                    failure.outcome == route.outcome,
                    "typed durability failure lost \(route.name) outcome")
                require(
                    failure.phase == .persistTaskState,
                    "task writer fault must report persist_task_state phase")
                require(
                    failure.businessCode == route.error.code
                        && failure.businessDetail
                            == route.error.localizedDescription,
                    "typed durability failure lost business code/detail")
                require(
                    failure.persistenceDetail.contains(stage.rawValue),
                    "typed durability failure lost injected stage")
                let expectedObserved: PersistentTaskCoordinator.TaskState =
                    stage == .beforeTemporaryWrite
                        || stage == .afterTemporaryFsync
                        ? .snapshotting : route.state
                require(
                    failure.observedTaskState == expectedObserved,
                    "\(route.name)/\(stage.rawValue) observed state drift")
            }
            PersistentTaskCoordinator.writeFaultInjector = nil
            let retainedIntent = try MobileTerminalStatePersistence
                .readIntentIfPresent(taskRoot: taskRoot)
            require(
                retainedIntent?.outcome == route.outcome,
                "failed \(route.name) transaction must retain durable intent")
            let taskNames = try FileManager.default.contentsOfDirectory(
                atPath: taskRoot.path)
            require(
                !taskNames.contains(where: { $0.hasPrefix(".task.json.tmp-") }),
                "task writer fault must not leak a temporary task file")

            try MobileTerminalStatePersistence.reconcilePendingIntent(
                taskRoot: taskRoot)
            let clearedReconciledIntent = try MobileTerminalStatePersistence
                .readIntentIfPresent(taskRoot: taskRoot)
            require(
                clearedReconciledIntent == nil,
                "restart reconciliation must clear terminal intent")
            let reconciled = try PersistentTaskCoordinator.read(
                taskRoot: taskRoot)
            require(
                reconciled.state == route.state
                    && reconciled.error == route.persistedReason,
                "restart reconciliation did not restore \(route.name)")
            require(
                PersistentTaskCoordinator.isResumable(reconciled)
                    == (route.state == .interrupted),
                "reconciled terminal resumability mismatch for \(route.name)")
        }
    }

    // Honest lower-boundary test: if the intent itself cannot be created,
    // the helper returns an establish_intent durability failure and cannot
    // claim that a restart marker exists on the failed storage.
    let blockedIntentTaskID = "terminal-intent-storage-blocked"
    let blockedIntentRoot = terminalTasksRoot.appendingPathComponent(
        blockedIntentTaskID, isDirectory: true)
    _ = try PersistentTaskCoordinator.createTask(
        taskID: blockedIntentTaskID, taskRoot: blockedIntentRoot)
    _ = try PersistentTaskCoordinator.updateState(
        .snapshotting, taskRoot: blockedIntentRoot, progress: 0.1)
    require(
        chmod(blockedIntentRoot.path, 0o555) == 0,
        "cannot make intent-boundary task root read-only")
    do {
        try MobileTerminalStatePersistence.persistThenRethrow(
            MobileOnlyWorkflowError.cancelled,
            taskRoot: blockedIntentRoot)
        require(false, "blocked intent storage must not report cancellation")
    } catch let failure as MobileTerminalStatePersistence.DurabilityFailure {
        require(
            failure.outcome == .cancelled
                && failure.phase == .establishIntent,
            "intent creation failure must preserve outcome and phase")
    }
    require(
        chmod(blockedIntentRoot.path, 0o755) == 0,
        "cannot restore intent-boundary task root permissions")
    let absentBlockedIntent = try MobileTerminalStatePersistence
        .readIntentIfPresent(taskRoot: blockedIntentRoot)
    require(
        absentBlockedIntent == nil,
        "failed intent establishment must not invent a durable marker")
    let blockedIntentRecord = try PersistentTaskCoordinator.read(
        taskRoot: blockedIntentRoot)
    require(
        blockedIntentRecord.state == .snapshotting,
        "failed intent establishment must not mutate task state")
    print(
        "Swift terminal-state durability matrix passed: "
            + "outcomes=4 write-stages=4 intent-boundary=1")

    // A retained intent is recovery evidence, not authority to overwrite a
    // newer terminal decision. Exercise the conflict rules with real files
    // produced by the production two-phase persistence helper.
    let completedConflictTaskID = "terminal-conflict-completed-failed"
    let completedConflictRoot = terminalTasksRoot.appendingPathComponent(
        completedConflictTaskID, isDirectory: true)
    _ = try PersistentTaskCoordinator.createTask(
        taskID: completedConflictTaskID, taskRoot: completedConflictRoot)
    let statesToCommittingResult: [PersistentTaskCoordinator.TaskState] = [
        .snapshotting,
        .fastOptimizing,
        .fastQualityCheck,
        .buildingTrajectory,
        .resolvingTags,
        .buildingWorkbook,
        .validatingResult,
        .committingResult,
    ]
    for state in statesToCommittingResult {
        _ = try PersistentTaskCoordinator.updateState(
            state, taskRoot: completedConflictRoot)
    }
    let completedConflictError = MobileOnlyWorkflowError.invalidState(
        "stale failed intent must not overwrite completed")
    PersistentTaskCoordinator.writeFaultInjector = { stage in
        if stage == .beforeTemporaryWrite {
            throw InjectedTerminalWriteFailure(stage: stage)
        }
    }
    do {
        try MobileTerminalStatePersistence.persistThenRethrow(
            completedConflictError, taskRoot: completedConflictRoot)
        require(false, "failed intent fixture must retain its marker")
    } catch let failure as MobileTerminalStatePersistence.DurabilityFailure {
        require(
            failure.phase == .persistTaskState,
            "completed conflict fixture must fail at task persistence")
    }
    PersistentTaskCoordinator.writeFaultInjector = nil
    _ = try PersistentTaskCoordinator.updateState(
        .completed, taskRoot: completedConflictRoot, progress: 1)
    do {
        try MobileTerminalStatePersistence.reconcilePendingIntent(
            taskRoot: completedConflictRoot)
        require(false, "completed task must reject stale failed intent")
    } catch let error as MobileTerminalStatePersistence.IntentError {
        if case .conflictingIntent = error {
            // Expected fail-closed conflict.
        } else {
            require(false, "completed task returned wrong intent error")
        }
    }
    let completedConflictRecord = try PersistentTaskCoordinator.read(
        taskRoot: completedConflictRoot)
    require(
        completedConflictRecord.state == .completed,
        "stale failed intent must not overwrite completed task")
    require(
        FileManager.default.fileExists(
            atPath: MobileTerminalStatePersistence.intentFileURL(
                taskRoot: completedConflictRoot).path),
        "completed conflict must retain its intent for audit")

    let cancelledConflictTaskID = "terminal-conflict-cancelled-failed"
    let cancelledConflictRoot = terminalTasksRoot.appendingPathComponent(
        cancelledConflictTaskID, isDirectory: true)
    _ = try PersistentTaskCoordinator.createTask(
        taskID: cancelledConflictTaskID, taskRoot: cancelledConflictRoot)
    _ = try PersistentTaskCoordinator.updateState(
        .snapshotting, taskRoot: cancelledConflictRoot)
    PersistentTaskCoordinator.writeFaultInjector = { stage in
        if stage == .beforeTemporaryWrite {
            throw InjectedTerminalWriteFailure(stage: stage)
        }
    }
    do {
        try MobileTerminalStatePersistence.persistThenRethrow(
            MobileOnlyWorkflowError.invalidState(
                "stale failed intent must not overwrite cancelled"),
            taskRoot: cancelledConflictRoot)
        require(false, "cancelled conflict fixture must retain its intent")
    } catch let failure as MobileTerminalStatePersistence.DurabilityFailure {
        require(
            failure.phase == .persistTaskState,
            "cancelled conflict fixture must fail at task persistence")
    }
    PersistentTaskCoordinator.writeFaultInjector = nil
    _ = try PersistentTaskCoordinator.updateState(
        .cancelled,
        taskRoot: cancelledConflictRoot,
        error: "user_cancelled")
    do {
        try MobileTerminalStatePersistence.reconcilePendingIntent(
            taskRoot: cancelledConflictRoot)
        require(false, "cancelled task must reject stale failed intent")
    } catch let error as MobileTerminalStatePersistence.IntentError {
        if case .conflictingIntent = error {
            // Expected fail-closed conflict.
        } else {
            require(false, "cancelled task returned wrong intent error")
        }
    }
    let cancelledConflictRecord = try PersistentTaskCoordinator.read(
        taskRoot: cancelledConflictRoot)
    require(
        cancelledConflictRecord.state == .cancelled
            && cancelledConflictRecord.error == "user_cancelled",
        "stale failed intent must not overwrite cancelled task")
    require(
        FileManager.default.fileExists(
            atPath: MobileTerminalStatePersistence.intentFileURL(
                taskRoot: cancelledConflictRoot).path),
        "cancelled conflict must retain its intent for audit")

    let reasonConflictTaskID = "terminal-conflict-interrupted-reason"
    let reasonConflictRoot = terminalTasksRoot.appendingPathComponent(
        reasonConflictTaskID, isDirectory: true)
    _ = try PersistentTaskCoordinator.createTask(
        taskID: reasonConflictTaskID, taskRoot: reasonConflictRoot)
    _ = try PersistentTaskCoordinator.updateState(
        .snapshotting, taskRoot: reasonConflictRoot)
    PersistentTaskCoordinator.writeFaultInjector = { stage in
        if stage == .beforeTemporaryWrite {
            throw InjectedTerminalWriteFailure(stage: stage)
        }
    }
    do {
        try MobileTerminalStatePersistence.persistThenRethrow(
            MobileOnlyWorkflowError.interrupted,
            taskRoot: reasonConflictRoot)
        require(false, "reason conflict fixture must retain its intent")
    } catch let failure as MobileTerminalStatePersistence.DurabilityFailure {
        require(
            failure.phase == .persistTaskState,
            "reason conflict fixture must fail at task persistence")
    }
    PersistentTaskCoordinator.writeFaultInjector = nil
    _ = try PersistentTaskCoordinator.updateState(
        .interrupted,
        taskRoot: reasonConflictRoot,
        error: "resource_pause")
    do {
        try MobileTerminalStatePersistence.reconcilePendingIntent(
            taskRoot: reasonConflictRoot)
        require(false, "same state with different reason must conflict")
    } catch let error as MobileTerminalStatePersistence.IntentError {
        if case .conflictingIntent = error {
            // Expected fail-closed conflict.
        } else {
            require(false, "reason mismatch returned wrong intent error")
        }
    }
    let reasonConflictRecord = try PersistentTaskCoordinator.read(
        taskRoot: reasonConflictRoot)
    require(
        reasonConflictRecord.state == .interrupted
            && reasonConflictRecord.error == "resource_pause",
        "intent must not replace an existing terminal reason")
    require(
        FileManager.default.fileExists(
            atPath: MobileTerminalStatePersistence.intentFileURL(
                taskRoot: reasonConflictRoot).path),
        "reason conflict must retain its intent for audit")

    let sourceIdentityTaskID = "terminal-conflict-identity-source"
    let sourceIdentityRoot = terminalTasksRoot.appendingPathComponent(
        sourceIdentityTaskID, isDirectory: true)
    _ = try PersistentTaskCoordinator.createTask(
        taskID: sourceIdentityTaskID, taskRoot: sourceIdentityRoot)
    _ = try PersistentTaskCoordinator.updateState(
        .snapshotting, taskRoot: sourceIdentityRoot)
    PersistentTaskCoordinator.writeFaultInjector = { stage in
        if stage == .beforeTemporaryWrite {
            throw InjectedTerminalWriteFailure(stage: stage)
        }
    }
    do {
        try MobileTerminalStatePersistence.persistThenRethrow(
            MobileOnlyWorkflowError.invalidState(
                "foreign task intent must be rejected"),
            taskRoot: sourceIdentityRoot)
        require(false, "identity source fixture must retain its intent")
    } catch let failure as MobileTerminalStatePersistence.DurabilityFailure {
        require(
            failure.phase == .persistTaskState,
            "identity source fixture must fail at task persistence")
    }
    PersistentTaskCoordinator.writeFaultInjector = nil
    let targetIdentityTaskID = "terminal-conflict-identity-target"
    let targetIdentityRoot = terminalTasksRoot.appendingPathComponent(
        targetIdentityTaskID, isDirectory: true)
    _ = try PersistentTaskCoordinator.createTask(
        taskID: targetIdentityTaskID, taskRoot: targetIdentityRoot)
    let sourceIdentityIntent = MobileTerminalStatePersistence.intentFileURL(
        taskRoot: sourceIdentityRoot)
    let targetIdentityIntent = MobileTerminalStatePersistence.intentFileURL(
        taskRoot: targetIdentityRoot)
    try FileManager.default.copyItem(
        at: sourceIdentityIntent, to: targetIdentityIntent)
    var sourceIntentStat = stat()
    var targetIntentStat = stat()
    require(
        lstat(sourceIdentityIntent.path, &sourceIntentStat) == 0
            && lstat(targetIdentityIntent.path, &targetIntentStat) == 0
            && sourceIntentStat.st_nlink == 1
            && targetIntentStat.st_nlink == 1
            && (sourceIntentStat.st_dev != targetIntentStat.st_dev
                || sourceIntentStat.st_ino != targetIntentStat.st_ino),
        "task-ID conflict fixture must use a separate regular file")
    do {
        try MobileTerminalStatePersistence.reconcilePendingIntent(
            taskRoot: targetIdentityRoot)
        require(false, "foreign task intent must fail closed")
    } catch let error as MobileTerminalStatePersistence.IntentError {
        if case .invalidIntent = error {
            // Expected: marker task_id does not match the target directory.
        } else {
            require(false, "foreign task intent returned wrong error")
        }
    }
    let targetIdentityRecord = try PersistentTaskCoordinator.read(
        taskRoot: targetIdentityRoot)
    require(
        targetIdentityRecord.state == .created,
        "foreign task intent must not mutate target task state")
    require(
        FileManager.default.fileExists(atPath: targetIdentityIntent.path),
        "foreign task intent must not be silently deleted")
    print("Swift terminal-intent conflict matrix passed")

    MobileResultLibrary.rootOverride = temporary.appendingPathComponent(
        "Results", isDirectory: true)

    let failedTaskID = "freeze-before-publish-task"
    let failedResultID = "result-freeze-before-publish"
    let failedStaging = try MobileResultLibrary.stagingDirectory(
        taskID: failedTaskID, resultID: failedResultID)
    let failedPayload = failedStaging.appendingPathComponent("payload.json")
    let failedWorkbookName = "result-freeze-before-publish.xlsx"
    let failedWorkbook = failedStaging.appendingPathComponent(failedWorkbookName)
    try Data("{}".utf8).write(to: failedPayload)
    try Data("xlsx".utf8).write(to: failedWorkbook)
    let failedFinal = try MobileResultLibrary.resultDirectory(
        resultID: failedResultID)
    let resolvedFailedStaging = try MobileResultLibrary.stagingDirectoryURL(
        taskID: failedTaskID, resultID: failedResultID)
    require(
        resolvedFailedStaging == failedStaging,
        "checkpoint and commit must resolve the same hidden staging path")
    require(
        failedStaging.deletingLastPathComponent()
            == failedFinal.deletingLastPathComponent(),
        "frozen staging and final result must be same-parent siblings")
    var observedPreRenameFreeze = false
    MobileResultLibrary.commitFaultInjector = { stage in
        guard stage == .afterFreeze else { return }
        let stagingMode = try permissions(failedStaging)
        require(
            stagingMode == 0o555,
            "staging root must be 0555 before rename")
        let payloadMode = try permissions(failedPayload)
        require(
            payloadMode == 0o444,
            "staging payload must be 0444 before rename")
        require(
            !FileManager.default.fileExists(atPath: failedFinal.path),
            "final path must remain absent until immutable rename")
        observedPreRenameFreeze = true
        throw InjectedResultFreezeFailure.stopBeforeRename
    }
    do {
        _ = try MobileResultLibrary.commit(
            resultID: failedResultID,
            taskID: failedTaskID,
            stagingDirectory: failedStaging,
            packageFiles: ["payload.json"],
            workbookFilename: failedWorkbookName)
        require(false, "injected pre-rename failure must abort commit")
    } catch InjectedResultFreezeFailure.stopBeforeRename {
        // Expected.
    }
    MobileResultLibrary.commitFaultInjector = nil
    require(observedPreRenameFreeze, "pre-rename freeze hook was not reached")
    require(
        !FileManager.default.fileExists(atPath: failedFinal.path),
        "failed pre-rename commit must not expose a final path")
    let recoveredStagingMode = try permissions(failedStaging)
    require(
        recoveredStagingMode == 0o755,
        "failed staging root must be restored to recoverable 0755")
    let recoveredPayloadMode = try permissions(failedPayload)
    require(
        recoveredPayloadMode == 0o644,
        "failed staging payload must be restored to recoverable 0644")
    MobileResultLibrary.cleanupStaging(taskID: failedTaskID)
    require(
        !FileManager.default.fileExists(atPath: failedStaging.path),
        "recovered failed staging package must be cleanable")

    let successTaskID = "immutable-publish-task"
    let successResultID = "result-immutable-publish"
    let successStaging = try MobileResultLibrary.stagingDirectory(
        taskID: successTaskID, resultID: successResultID)
    let successPayload = successStaging.appendingPathComponent("payload.json")
    let successWorkbookName = "result-immutable-publish.xlsx"
    try Data("{\"ok\":true}".utf8).write(to: successPayload)
    try Data("xlsx-ok".utf8).write(
        to: successStaging.appendingPathComponent(successWorkbookName))
    let entry = try MobileResultLibrary.commit(
        resultID: successResultID,
        taskID: successTaskID,
        stagingDirectory: successStaging,
        packageFiles: ["payload.json"],
        workbookFilename: successWorkbookName)
    let finalDirectoryMode = try permissions(entry.directory)
    require(
        finalDirectoryMode == 0o555,
        "visible final result root must already be immutable 0555")
    for name in [
        "payload.json", successWorkbookName,
        MobileResultLibrary.manifestFileName,
        MobileResultLibrary.commitReceiptFileName,
    ] {
        let finalFileMode = try permissions(
            entry.directory.appendingPathComponent(name))
        require(
            finalFileMode == 0o444,
            "visible final file \(name) must already be immutable 0444")
    }
    let reopened = try MobileResultLibrary.readResult(resultID: successResultID)
    require(
        reopened.workbookSHA256 == entry.workbookSHA256,
        "post-rename receipt/hash verification must reopen the same result")
    print("Swift result pre-rename freeze and recovery contract passed")
} catch {
    FileHandle.standardError.write(Data("FAILED: \(error)\n".utf8))
    exit(1)
}
