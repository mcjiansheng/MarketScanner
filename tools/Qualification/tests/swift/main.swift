import CryptoKit
import Darwin
import Foundation
import SQLite3

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
        MobileResultLibrary.processLockAttemptObserver = nil
        MobileResultLibrary.processLockAcquiredObserver = nil
        MobileResultLibrary.processLockValidationObserver = nil
        MobileResultLibrary.rootOverride = nil
        SessionSnapshotTransaction.processLockAttemptObserver = nil
        SessionSnapshotTransaction.processLockAcquiredObserver = nil
        SessionSnapshotTransaction.processLockValidationObserver = nil
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

    // macOS 14 primitive contract: a frozen directory cannot be renamed
    // directly, so the shared helper must thaw only the bound root, perform
    // RENAME_EXCL and refreeze the same inode before returning.
    let primitiveRoot = temporary.appendingPathComponent(
        "immutable-directory-publication", isDirectory: true)
    try FileManager.default.createDirectory(
        at: primitiveRoot, withIntermediateDirectories: true)
    let primitiveSource = primitiveRoot.appendingPathComponent(
        "source", isDirectory: true)
    let primitiveDestination = primitiveRoot.appendingPathComponent(
        "destination", isDirectory: true)
    try FileManager.default.createDirectory(
        at: primitiveSource, withIntermediateDirectories: false)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o555], ofItemAtPath: primitiveSource.path)
    let primitiveIdentity = try ImmutableDirectoryPublication.identity(
        of: primitiveSource, allowedModes: [0o555])
    let publishedIdentity = try ImmutableDirectoryPublication.publish(
        source: primitiveSource,
        destination: primitiveDestination,
        expectedIdentity: primitiveIdentity)
    let primitiveDestinationMode = try permissions(primitiveDestination)
    require(
        publishedIdentity == primitiveIdentity
            && !FileManager.default.fileExists(atPath: primitiveSource.path)
            && primitiveDestinationMode == 0o555,
        "macOS-14 helper must publish and refreeze the same directory inode")
    let collisionSource = primitiveRoot.appendingPathComponent(
        "collision-source", isDirectory: true)
    let collisionDestination = primitiveRoot.appendingPathComponent(
        "collision-destination", isDirectory: true)
    try FileManager.default.createDirectory(
        at: collisionSource, withIntermediateDirectories: false)
    try FileManager.default.createDirectory(
        at: collisionDestination, withIntermediateDirectories: false)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o555], ofItemAtPath: collisionSource.path)
    var primitiveCollisionRejected = false
    do {
        try ImmutableDirectoryPublication.publish(
            source: collisionSource,
            destination: collisionDestination)
    } catch ImmutableDirectoryPublication.PublicationError.destinationExists(_) {
        primitiveCollisionRejected = true
    }
    let collisionSourceMode = try permissions(collisionSource)
    require(
        primitiveCollisionRejected
            && FileManager.default.fileExists(atPath: collisionSource.path)
            && collisionSourceMode == 0o555,
        "RENAME_EXCL collision must preserve the frozen source")

    let replacementSource = primitiveRoot.appendingPathComponent(
        "replacement-source", isDirectory: true)
    let replacementDisplaced = primitiveRoot.appendingPathComponent(
        "replacement-displaced", isDirectory: true)
    let replacementDestination = primitiveRoot.appendingPathComponent(
        "replacement-destination", isDirectory: true)
    try FileManager.default.createDirectory(
        at: replacementSource, withIntermediateDirectories: false)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o555], ofItemAtPath: replacementSource.path)
    let replacementIdentity = try ImmutableDirectoryPublication.identity(
        of: replacementSource, allowedModes: [0o555])
    var replacementRejected = false
    do {
        try ImmutableDirectoryPublication.publish(
            source: replacementSource,
            destination: replacementDestination,
            expectedIdentity: replacementIdentity,
            afterRootThawBeforeRename: {
                guard renameatx_np(
                    AT_FDCWD, replacementSource.path,
                    AT_FDCWD, replacementDisplaced.path,
                    UInt32(RENAME_EXCL)) == 0 else {
                    throw NSError(
                        domain: "ImmutableDirectoryPublicationTest",
                        code: Int(errno))
                }
                try FileManager.default.createDirectory(
                    at: replacementSource,
                    withIntermediateDirectories: false)
            })
    } catch ImmutableDirectoryPublication.PublicationError.identityChanged(_) {
        replacementRejected = true
    }
    let replacementDisplacedMode = try permissions(replacementDisplaced)
    require(
        replacementRejected
            && FileManager.default.fileExists(atPath: replacementSource.path)
            && FileManager.default.fileExists(atPath: replacementDisplaced.path)
            && !FileManager.default.fileExists(
                atPath: replacementDestination.path)
            && replacementDisplacedMode == 0o555,
        "source replacement before rename must preserve and refreeze the bound inode")

    let postFreezeSource = primitiveRoot.appendingPathComponent(
        "post-freeze-source", isDirectory: true)
    let postFreezeDestination = primitiveRoot.appendingPathComponent(
        "post-freeze-destination", isDirectory: true)
    let postFreezeDisplaced = primitiveRoot.appendingPathComponent(
        "post-freeze-displaced", isDirectory: true)
    let postFreezeReplacement = primitiveRoot.appendingPathComponent(
        "post-freeze-replacement", isDirectory: true)
    for directory in [postFreezeSource, postFreezeReplacement] {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false)
        let payload = directory.appendingPathComponent("payload.bin")
        try Data("byte-identical-publication-payload".utf8).write(to: payload)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o444], ofItemAtPath: payload.path)
    }
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o555], ofItemAtPath: postFreezeSource.path)
    let postFreezeSourceIdentity = try ImmutableDirectoryPublication.identity(
        of: postFreezeSource, allowedModes: [0o555])
    let postFreezeReplacementIdentity = try ImmutableDirectoryPublication.identity(
        of: postFreezeReplacement, allowedModes: [0o755])
    require(
        postFreezeSourceIdentity != postFreezeReplacementIdentity,
        "post-freeze replacement fixture must use a new directory inode")
    var postFreezeReplacementRejected = false
    do {
        try ImmutableDirectoryPublication.publish(
            source: postFreezeSource,
            destination: postFreezeDestination,
            expectedIdentity: postFreezeSourceIdentity,
            afterFreezeBeforeParentSync: {
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o755],
                    ofItemAtPath: postFreezeDestination.path)
                guard renameatx_np(
                    AT_FDCWD, postFreezeDestination.path,
                    AT_FDCWD, postFreezeDisplaced.path,
                    UInt32(RENAME_EXCL)) == 0,
                      renameatx_np(
                        AT_FDCWD, postFreezeReplacement.path,
                        AT_FDCWD, postFreezeDestination.path,
                        UInt32(RENAME_EXCL)) == 0 else {
                    throw NSError(
                        domain: "ImmutableDirectoryPublicationTest",
                        code: Int(errno))
                }
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o555],
                    ofItemAtPath: postFreezeDestination.path)
            })
        require(false, "post-freeze destination replacement must fail closed")
    } catch ImmutableDirectoryPublication.PublicationError.identityChanged(_) {
        postFreezeReplacementRejected = true
    }
    let displacedPostFreezeIdentity = try ImmutableDirectoryPublication.identity(
        of: postFreezeDisplaced, allowedModes: [0o755])
    let finalPostFreezeIdentity = try ImmutableDirectoryPublication.identity(
        of: postFreezeDestination, allowedModes: [0o555])
    require(
        postFreezeReplacementRejected
            && displacedPostFreezeIdentity == postFreezeSourceIdentity
            && finalPostFreezeIdentity == postFreezeReplacementIdentity,
        "post-freeze byte-identical replacement must preserve evidence and reject")
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o555], ofItemAtPath: postFreezeDisplaced.path)

    let recreatedSource = primitiveRoot.appendingPathComponent(
        "recreated-source", isDirectory: true)
    let recreatedDestination = primitiveRoot.appendingPathComponent(
        "recreated-destination", isDirectory: true)
    try FileManager.default.createDirectory(
        at: recreatedSource, withIntermediateDirectories: false)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o555], ofItemAtPath: recreatedSource.path)
    let recreatedSourceIdentity = try ImmutableDirectoryPublication.identity(
        of: recreatedSource, allowedModes: [0o555])
    var recreatedSourceRejected = false
    do {
        try ImmutableDirectoryPublication.publish(
            source: recreatedSource,
            destination: recreatedDestination,
            expectedIdentity: recreatedSourceIdentity,
            afterFreezeBeforeParentSync: {
                try FileManager.default.createDirectory(
                    at: recreatedSource, withIntermediateDirectories: false)
            })
        require(false, "recreated source basename must fail closed")
    } catch ImmutableDirectoryPublication.PublicationError.identityChanged(_) {
        recreatedSourceRejected = true
    }
    let recreatedDestinationMode = try permissions(recreatedDestination)
    require(
        recreatedSourceRejected
            && FileManager.default.fileExists(atPath: recreatedSource.path)
            && FileManager.default.fileExists(atPath: recreatedDestination.path)
            && recreatedDestinationMode == 0o555,
        "post-freeze source basename recreation must be detected")

    let interruptedFreeze = primitiveRoot.appendingPathComponent(
        "interrupted-freeze", isDirectory: true)
    let interruptedFreezeDisplaced = primitiveRoot.appendingPathComponent(
        "interrupted-freeze-displaced", isDirectory: true)
    let interruptedFreezeReplacement = primitiveRoot.appendingPathComponent(
        "interrupted-freeze-replacement", isDirectory: true)
    for directory in [interruptedFreeze, interruptedFreezeReplacement] {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false)
        let payload = directory.appendingPathComponent("payload.bin")
        try Data("byte-identical-recovery-payload".utf8).write(to: payload)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o444], ofItemAtPath: payload.path)
    }
    let interruptedFreezeIdentity = try ImmutableDirectoryPublication.identity(
        of: interruptedFreeze, allowedModes: [0o755])
    let interruptedReplacementIdentity = try ImmutableDirectoryPublication.identity(
        of: interruptedFreezeReplacement, allowedModes: [0o755])
    require(
        interruptedFreezeIdentity != interruptedReplacementIdentity,
        "interrupted-freeze replacement fixture must use a new inode")
    var interruptedFreezeReplacementRejected = false
    do {
        try ImmutableDirectoryPublication.freezeInterruptedDestination(
            interruptedFreeze,
            expectedIdentity: interruptedFreezeIdentity,
            afterFreezeBeforeParentSync: {
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o755],
                    ofItemAtPath: interruptedFreeze.path)
                guard renameatx_np(
                    AT_FDCWD, interruptedFreeze.path,
                    AT_FDCWD, interruptedFreezeDisplaced.path,
                    UInt32(RENAME_EXCL)) == 0,
                      renameatx_np(
                        AT_FDCWD, interruptedFreezeReplacement.path,
                        AT_FDCWD, interruptedFreeze.path,
                        UInt32(RENAME_EXCL)) == 0 else {
                    throw NSError(
                        domain: "ImmutableDirectoryPublicationTest",
                        code: Int(errno))
                }
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o555],
                    ofItemAtPath: interruptedFreeze.path)
            })
        require(false, "interrupted destination replacement must fail closed")
    } catch ImmutableDirectoryPublication.PublicationError.identityChanged(_) {
        interruptedFreezeReplacementRejected = true
    }
    let interruptedDisplacedIdentity = try ImmutableDirectoryPublication.identity(
        of: interruptedFreezeDisplaced, allowedModes: [0o755])
    let interruptedFinalIdentity = try ImmutableDirectoryPublication.identity(
        of: interruptedFreeze, allowedModes: [0o555])
    require(
        interruptedFreezeReplacementRejected
            && interruptedDisplacedIdentity == interruptedFreezeIdentity
            && interruptedFinalIdentity == interruptedReplacementIdentity,
        "interrupted freeze must reject a byte-identical new inode")
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o555],
        ofItemAtPath: interruptedFreezeDisplaced.path)
    print("Swift immutable-directory post-freeze replacement contract passed")
    print("Swift macOS-14 immutable-directory publication primitive passed")

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
            stagingMode == 0o755,
            "macOS 14 publication requires staging root 0755 before rename")
        let payloadMode = try permissions(failedPayload)
        require(
            payloadMode == 0o444,
            "staging payload must be frozen 0444 before rename")
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

    let interruptedTaskID = "rename-before-freeze-task"
    let interruptedResultID = "result-rename-before-freeze"
    let interruptedStaging = try MobileResultLibrary.stagingDirectory(
        taskID: interruptedTaskID, resultID: interruptedResultID)
    try Data("{\"phase\":\"rename\"}".utf8).write(
        to: interruptedStaging.appendingPathComponent("payload.json"))
    let interruptedWorkbookName = "result-rename-before-freeze.xlsx"
    try Data("xlsx-rename".utf8).write(
        to: interruptedStaging.appendingPathComponent(
            interruptedWorkbookName))
    let interruptedFinal = try MobileResultLibrary.resultDirectory(
        resultID: interruptedResultID)
    var observedTransientFinal = false
    MobileResultLibrary.commitFaultInjector = { stage in
        guard stage == .afterDirectoryRenameBeforeFreeze else { return }
        require(
            FileManager.default.fileExists(atPath: interruptedFinal.path),
            "rename→freeze fault point must have a final pathname")
        let transientMode = try permissions(interruptedFinal)
        require(
            transientMode == 0o755,
            "rename→freeze fault point must expose only intent-bound 0755")
        observedTransientFinal = true
        throw InjectedResultFreezeFailure.stopBeforeRename
    }
    do {
        _ = try MobileResultLibrary.commit(
            resultID: interruptedResultID,
            taskID: interruptedTaskID,
            stagingDirectory: interruptedStaging,
            packageFiles: ["payload.json"],
            workbookFilename: interruptedWorkbookName)
        require(false, "rename→freeze injected failure must surface")
    } catch InjectedResultFreezeFailure.stopBeforeRename {
        // The durable publish intent must preserve this exact crash state.
    }
    MobileResultLibrary.commitFaultInjector = nil
    require(
        observedTransientFinal,
        "rename→freeze result fault point was not reached")
    let recoveredInterrupted = try MobileResultLibrary.committedResult(
        taskID: interruptedTaskID,
        expectedResultIDs: [interruptedResultID])
    require(
        recoveredInterrupted?.resultID == interruptedResultID,
        "intent-bound writable final must recover as the committed result")
    let recoveredInterruptedMode = try permissions(interruptedFinal)
    require(
        recoveredInterruptedMode == 0o555,
        "recovered result final must be inode-bound frozen to 0555")

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
        "accepted final result root must be immutable 0555")
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

    let lockPathRoot = temporary.appendingPathComponent(
        "Results-LockPath-Replacement", isDirectory: true)
    try FileManager.default.createDirectory(
        at: lockPathRoot, withIntermediateDirectories: false)
    let canonicalLock = lockPathRoot.appendingPathComponent(
        ".result-library.lock")
    let displacedLock = lockPathRoot.appendingPathComponent(
        ".result-library.lock.displaced")
    MobileResultLibrary.rootOverride = lockPathRoot
    var lockPathHookReached = false
    MobileResultLibrary.processLockAttemptObserver = {
        lockPathHookReached = true
        guard renameatx_np(
            AT_FDCWD, canonicalLock.path,
            AT_FDCWD, displacedLock.path,
            UInt32(RENAME_EXCL)) == 0,
              FileManager.default.createFile(
                atPath: canonicalLock.path,
                contents: Data(),
                attributes: [.posixPermissions: 0o600]) else {
            throw NSError(
                domain: "MobileResultLibraryProcessLockTest",
                code: Int(errno))
        }
    }
    var lockPathReplacementRejected = false
    do {
        _ = try MobileResultLibrary.committedResult(taskID: "lock-path-probe")
        require(false, "canonical process-lock replacement must fail closed")
    } catch {
        lockPathReplacementRejected = true
    }
    MobileResultLibrary.processLockAttemptObserver = nil
    var canonicalLockMetadata = stat()
    var displacedLockMetadata = stat()
    require(
        lockPathHookReached
            && lockPathReplacementRejected
            && lstat(canonicalLock.path, &canonicalLockMetadata) == 0
            && lstat(displacedLock.path, &displacedLockMetadata) == 0
            && canonicalLockMetadata.st_dev == displacedLockMetadata.st_dev
            && canonicalLockMetadata.st_ino != displacedLockMetadata.st_ino
            && (canonicalLockMetadata.st_mode & mode_t(0o777)) == 0o600
            && (displacedLockMetadata.st_mode & mode_t(0o777)) == 0o600,
        "process lock must remain bound to its canonical opened inode")

    let rootPathRoot = temporary.appendingPathComponent(
        "Results-RootPath-Replacement", isDirectory: true)
    let displacedRoot = temporary.appendingPathComponent(
        "Results-RootPath-Displaced", isDirectory: true)
    try FileManager.default.createDirectory(
        at: rootPathRoot, withIntermediateDirectories: false)
    MobileResultLibrary.rootOverride = rootPathRoot
    var rootPathHookReached = false
    MobileResultLibrary.processLockAcquiredObserver = {
        rootPathHookReached = true
        guard renameatx_np(
            AT_FDCWD, rootPathRoot.path,
            AT_FDCWD, displacedRoot.path,
            UInt32(RENAME_EXCL)) == 0 else {
            throw NSError(
                domain: "MobileResultLibraryProcessLockTest",
                code: Int(errno))
        }
        try FileManager.default.createDirectory(
            at: rootPathRoot, withIntermediateDirectories: false)
    }
    var rootPathReplacementRejected = false
    do {
        _ = try MobileResultLibrary.committedResult(taskID: "root-path-probe")
        require(false, "result-library root replacement must fail closed")
    } catch {
        rootPathReplacementRejected = true
    }
    MobileResultLibrary.processLockAcquiredObserver = nil
    let openedReplacementRootIdentity = try ImmutableDirectoryPublication.identity(
        of: rootPathRoot, allowedModes: [0o755])
    let displacedRootIdentity = try ImmutableDirectoryPublication.identity(
        of: displacedRoot, allowedModes: [0o755])
    require(
        rootPathHookReached
            && rootPathReplacementRejected
            && openedReplacementRootIdentity != displacedRootIdentity,
        "result-library lock acquisition must bind the root pathname")

    let finalLockPathRoot = temporary.appendingPathComponent(
        "Results-Final-LockPath-Replacement", isDirectory: true)
    try FileManager.default.createDirectory(
        at: finalLockPathRoot, withIntermediateDirectories: false)
    let finalCanonicalLock = finalLockPathRoot.appendingPathComponent(
        ".result-library.lock")
    let finalDisplacedLock = finalLockPathRoot.appendingPathComponent(
        ".result-library.lock.displaced")
    MobileResultLibrary.rootOverride = finalLockPathRoot
    var finalLockPathHookReached = false
    MobileResultLibrary.processLockValidationObserver = {
        finalLockPathHookReached = true
        guard renameatx_np(
            AT_FDCWD, finalCanonicalLock.path,
            AT_FDCWD, finalDisplacedLock.path,
            UInt32(RENAME_EXCL)) == 0,
              FileManager.default.createFile(
                atPath: finalCanonicalLock.path,
                contents: Data(),
                attributes: [.posixPermissions: 0o600]) else {
            throw NSError(
                domain: "MobileResultLibraryFinalProcessLockTest",
                code: Int(errno))
        }
    }
    var finalLockPathReplacementRejected = false
    do {
        _ = try MobileResultLibrary.committedResult(
            taskID: "final-lock-path-probe")
        require(
            false,
            "final canonical process-lock replacement must fail closed")
    } catch MobileResultLibrary.ResultError.cannotCreateRoot(_) {
        finalLockPathReplacementRejected = true
    }
    MobileResultLibrary.processLockValidationObserver = nil
    var finalCanonicalLockMetadata = stat()
    var finalDisplacedLockMetadata = stat()
    require(
        finalLockPathHookReached
            && finalLockPathReplacementRejected
            && lstat(finalCanonicalLock.path, &finalCanonicalLockMetadata) == 0
            && lstat(finalDisplacedLock.path, &finalDisplacedLockMetadata) == 0
            && (finalCanonicalLockMetadata.st_mode & S_IFMT) == S_IFREG
            && (finalDisplacedLockMetadata.st_mode & S_IFMT) == S_IFREG
            && finalCanonicalLockMetadata.st_dev
                == finalDisplacedLockMetadata.st_dev
            && finalCanonicalLockMetadata.st_ino
                != finalDisplacedLockMetadata.st_ino
            && finalCanonicalLockMetadata.st_nlink == 1
            && finalDisplacedLockMetadata.st_nlink == 1
            && finalCanonicalLockMetadata.st_size == 0
            && finalDisplacedLockMetadata.st_size == 0
            && (finalCanonicalLockMetadata.st_mode & mode_t(0o777)) == 0o600
            && (finalDisplacedLockMetadata.st_mode & mode_t(0o777)) == 0o600,
        "final process-lock validation must reject and preserve both lock inodes")

    let finalRootPathRoot = temporary.appendingPathComponent(
        "Results-Final-RootPath-Replacement", isDirectory: true)
    let finalDisplacedRoot = temporary.appendingPathComponent(
        "Results-Final-RootPath-Displaced", isDirectory: true)
    try FileManager.default.createDirectory(
        at: finalRootPathRoot, withIntermediateDirectories: false)
    MobileResultLibrary.rootOverride = finalRootPathRoot
    var finalRootPathHookReached = false
    MobileResultLibrary.processLockValidationObserver = {
        finalRootPathHookReached = true
        guard renameatx_np(
            AT_FDCWD, finalRootPathRoot.path,
            AT_FDCWD, finalDisplacedRoot.path,
            UInt32(RENAME_EXCL)) == 0 else {
            throw NSError(
                domain: "MobileResultLibraryFinalProcessLockTest",
                code: Int(errno))
        }
        try FileManager.default.createDirectory(
            at: finalRootPathRoot, withIntermediateDirectories: false)
    }
    var finalRootPathReplacementRejected = false
    do {
        _ = try MobileResultLibrary.committedResult(
            taskID: "final-root-path-probe")
        require(false, "final result-library root replacement must fail closed")
    } catch MobileResultLibrary.ResultError.commitFailed(_) {
        finalRootPathReplacementRejected = true
    }
    MobileResultLibrary.processLockValidationObserver = nil
    let finalReplacementRootIdentity = try ImmutableDirectoryPublication.identity(
        of: finalRootPathRoot, allowedModes: [0o755])
    let finalDisplacedRootIdentity = try ImmutableDirectoryPublication.identity(
        of: finalDisplacedRoot, allowedModes: [0o755])
    let preservedFinalRootLock = finalDisplacedRoot.appendingPathComponent(
        ".result-library.lock")
    var preservedFinalRootLockMetadata = stat()
    require(
        finalRootPathHookReached
            && finalRootPathReplacementRejected
            && finalReplacementRootIdentity != finalDisplacedRootIdentity
            && lstat(
                preservedFinalRootLock.path,
                &preservedFinalRootLockMetadata) == 0
            && (preservedFinalRootLockMetadata.st_mode & S_IFMT) == S_IFREG
            && preservedFinalRootLockMetadata.st_nlink == 1
            && preservedFinalRootLockMetadata.st_size == 0
            && (preservedFinalRootLockMetadata.st_mode & mode_t(0o777))
                == 0o600,
        "final root validation must reject replacement and preserve old authority")
    print("Swift result final process-lock validation contract passed")
    print("Swift result process-lock pathname binding contract passed")

    func makeSnapshotProcessLockSource() throws -> (session: URL, database: URL) {
        let session = temporary.appendingPathComponent(
            "Snapshot-Process-Lock-Source", isDirectory: true)
        try FileManager.default.createDirectory(
            at: session, withIntermediateDirectories: false)
        let metadata = try CanonicalJSONEncoder.encode([
            "format": "MarketScannerFinalizedSessionMetadata",
            "version": 1,
            "formatVersion": 2,
            "finalized": true,
            "finalizedAtUnix": 1_700_000_100.0,
            "scanMode": "continuous_streaming",
            "workflowMode": "prior_map_localized",
            "trackingSessionId": "SNAPSHOT-PROCESS-LOCK",
            "storeId": "STORE-SNAPSHOT-LOCK",
            "floorId": "FLOOR-SNAPSHOT-LOCK",
            "priorMapId": "MAP-SNAPSHOT-LOCK",
            "priorMapSha256": String(repeating: "a", count: 64),
            "processingEligibility": [
                "status": "eligible",
                "blockers": [],
            ],
            "captureHealth": [
                "localizationRequiredWriteFailureCount": 0,
                "localizationTraceRecordCount": 1,
                "localizationConstraintRecordCount": 1,
                "manualLocalizationEventCount": 0,
                "localizationStateEventCount": 1,
                "localizationEvidenceComplete": true,
                "localizationRecoveryEventCount": 0,
                "localizationRecoveryEvidenceComplete": true,
            ],
            "localizationTrace": "localization_trace.jsonl",
            "manualLocalizationEvents": "manual_localization_events.jsonl",
            "localizationConstraints": "localization_constraints.jsonl",
            "localizationEvents": "localization_events.jsonl",
            "localizationRecoveryEvents": "localization_recovery_events.jsonl",
            "tagObservations": "tag_observations.jsonl",
            "localizedPriceTags": "localized_price_tags.json",
            "clockCorrelationCount": 2,
            "clockNodeBindingCount": 2,
            "clockLastMonotonic": 41.0,
            "clockLastUTC": 1_700_000_041.0,
            "clockEvidenceComplete": true,
            "tagObservationBurstCount": 0,
            "tagObservationBurstComplete": true,
        ])
        try metadata.write(to: session.appendingPathComponent("metadata.json"))
        for (name, contents) in [
            ("localization_trace.jsonl", "trace\n"),
            ("manual_localization_events.jsonl", "manual\n"),
            ("localization_constraints.jsonl", "constraints\n"),
            ("localization_events.jsonl", "events\n"),
            ("localization_recovery_events.jsonl", "recovery\n"),
            ("tag_observations.jsonl", "observations\n"),
            ("localized_price_tags.json", "[]"),
            ("clock_correlations.jsonl", "clock\n"),
            ("tag_observation_bursts.jsonl", ""),
            ("scan_events.jsonl", "scan-event\n"),
        ] {
            try Data(contents.utf8).write(
                to: session.appendingPathComponent(name))
        }
        let database = session.appendingPathComponent("source.db")
        var handle: OpaquePointer?
        guard sqlite3_open_v2(
                database.path,
                &handle,
                SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
                nil) == SQLITE_OK,
              let handle else {
            if let handle { sqlite3_close(handle) }
            throw NSError(
                domain: "SessionSnapshotProcessLockTest", code: 1)
        }
        defer { sqlite3_close(handle) }
        let schema = """
        CREATE TABLE Node (
            id INTEGER PRIMARY KEY, map_id INTEGER, weight INTEGER,
            stamp REAL, pose BLOB
        );
        CREATE TABLE Link (
            from_id INTEGER, to_id INTEGER, type INTEGER,
            transform BLOB, information_matrix BLOB
        );
        """
        guard sqlite3_exec(handle, schema, nil, nil, nil) == SQLITE_OK else {
            throw NSError(
                domain: "SessionSnapshotProcessLockTest", code: 2)
        }
        return (session, database)
    }

    func requireSnapshotLockEvidence(
        canonical: URL,
        displaced: URL,
        _ message: String
    ) {
        var canonicalMetadata = stat()
        var displacedMetadata = stat()
        require(
            lstat(canonical.path, &canonicalMetadata) == 0
                && lstat(displaced.path, &displacedMetadata) == 0
                && (canonicalMetadata.st_mode & S_IFMT) == S_IFREG
                && (displacedMetadata.st_mode & S_IFMT) == S_IFREG
                && (canonicalMetadata.st_dev != displacedMetadata.st_dev
                    || canonicalMetadata.st_ino != displacedMetadata.st_ino)
                && canonicalMetadata.st_nlink == 1
                && displacedMetadata.st_nlink == 1
                && canonicalMetadata.st_size == 0
                && displacedMetadata.st_size == 0
                && (canonicalMetadata.st_mode & mode_t(0o777)) == 0o600
                && (displacedMetadata.st_mode & mode_t(0o777)) == 0o600,
            message)
    }

    let acquisitionLockRoot = temporary.appendingPathComponent(
        "Snapshot-Acquisition-Lock-Replacement", isDirectory: true)
    try FileManager.default.createDirectory(
        at: acquisitionLockRoot, withIntermediateDirectories: false)
    let acquisitionCanonicalLock = acquisitionLockRoot.appendingPathComponent(
        SessionSnapshotTransaction.processLockFileName)
    let acquisitionDisplacedLock = acquisitionLockRoot.appendingPathComponent(
        "input_snapshot.lock.displaced")
    var snapshotAcquisitionLockHookReached = false
    SessionSnapshotTransaction.processLockAttemptObserver = {
        snapshotAcquisitionLockHookReached = true
        guard renameatx_np(
                AT_FDCWD,
                acquisitionCanonicalLock.path,
                AT_FDCWD,
                acquisitionDisplacedLock.path,
                UInt32(RENAME_EXCL)) == 0,
              FileManager.default.createFile(
                atPath: acquisitionCanonicalLock.path,
                contents: Data(),
                attributes: [.posixPermissions: 0o600]) else {
            throw NSError(
                domain: "SessionSnapshotProcessLockTest", code: Int(errno))
        }
    }
    var snapshotAcquisitionLockRejected = false
    do {
        _ = try SessionSnapshotTransaction.snapshot(
            finalizedSession: acquisitionLockRoot,
            sourceDatabase: acquisitionLockRoot.appendingPathComponent("missing.db"),
            taskRoot: acquisitionLockRoot)
        require(false, "snapshot acquisition lock replacement must fail closed")
    } catch SessionSnapshotTransaction.SessionError.copyFailed(_) {
        snapshotAcquisitionLockRejected = true
    }
    SessionSnapshotTransaction.processLockAttemptObserver = nil
    require(
        snapshotAcquisitionLockHookReached && snapshotAcquisitionLockRejected,
        "snapshot acquisition lock replacement hook must run and reject")
    requireSnapshotLockEvidence(
        canonical: acquisitionCanonicalLock,
        displaced: acquisitionDisplacedLock,
        "snapshot acquisition must preserve two valid, distinct lock inodes")

    let acquisitionRoot = temporary.appendingPathComponent(
        "Snapshot-Acquisition-Root-Replacement", isDirectory: true)
    let acquisitionDisplacedRoot = temporary.appendingPathComponent(
        "Snapshot-Acquisition-Root-Displaced", isDirectory: true)
    try FileManager.default.createDirectory(
        at: acquisitionRoot, withIntermediateDirectories: false)
    var snapshotAcquisitionRootHookReached = false
    SessionSnapshotTransaction.processLockAcquiredObserver = {
        snapshotAcquisitionRootHookReached = true
        guard renameatx_np(
                AT_FDCWD,
                acquisitionRoot.path,
                AT_FDCWD,
                acquisitionDisplacedRoot.path,
                UInt32(RENAME_EXCL)) == 0 else {
            throw NSError(
                domain: "SessionSnapshotProcessLockTest", code: Int(errno))
        }
        try FileManager.default.createDirectory(
            at: acquisitionRoot, withIntermediateDirectories: false)
    }
    var snapshotAcquisitionRootRejected = false
    do {
        _ = try SessionSnapshotTransaction.snapshot(
            finalizedSession: acquisitionRoot,
            sourceDatabase: acquisitionRoot.appendingPathComponent("missing.db"),
            taskRoot: acquisitionRoot)
        require(false, "snapshot acquisition root replacement must fail closed")
    } catch SessionSnapshotTransaction.SessionError.copyFailed(_) {
        snapshotAcquisitionRootRejected = true
    }
    SessionSnapshotTransaction.processLockAcquiredObserver = nil
    let acquisitionReplacementRootIdentity = try ImmutableDirectoryPublication.identity(
        of: acquisitionRoot, allowedModes: [0o755])
    let acquisitionDisplacedRootIdentity = try ImmutableDirectoryPublication.identity(
        of: acquisitionDisplacedRoot, allowedModes: [0o755])
    let acquisitionPreservedRootLock = acquisitionDisplacedRoot
        .appendingPathComponent(SessionSnapshotTransaction.processLockFileName)
    var acquisitionPreservedRootLockMetadata = stat()
    require(
        snapshotAcquisitionRootHookReached
            && snapshotAcquisitionRootRejected
            && acquisitionReplacementRootIdentity != acquisitionDisplacedRootIdentity
            && lstat(
                acquisitionPreservedRootLock.path,
                &acquisitionPreservedRootLockMetadata) == 0
            && (acquisitionPreservedRootLockMetadata.st_mode & S_IFMT) == S_IFREG
            && acquisitionPreservedRootLockMetadata.st_nlink == 1
            && acquisitionPreservedRootLockMetadata.st_size == 0
            && (acquisitionPreservedRootLockMetadata.st_mode & mode_t(0o777))
                == 0o600,
        "snapshot acquisition must reject root replacement and preserve authority")
    print("Swift snapshot process-lock pathname binding contract passed")

    let snapshotSource = try makeSnapshotProcessLockSource()
    let finalSnapshotLockRoot = temporary.appendingPathComponent(
        "Snapshot-Final-Lock-Replacement", isDirectory: true)
    try FileManager.default.createDirectory(
        at: finalSnapshotLockRoot, withIntermediateDirectories: false)
    let finalSnapshotCanonicalLock = finalSnapshotLockRoot.appendingPathComponent(
        SessionSnapshotTransaction.processLockFileName)
    let finalSnapshotDisplacedLock = finalSnapshotLockRoot.appendingPathComponent(
        "input_snapshot.lock.displaced")
    var snapshotFinalLockHookReached = false
    SessionSnapshotTransaction.processLockValidationObserver = {
        snapshotFinalLockHookReached = true
        guard renameatx_np(
                AT_FDCWD,
                finalSnapshotCanonicalLock.path,
                AT_FDCWD,
                finalSnapshotDisplacedLock.path,
                UInt32(RENAME_EXCL)) == 0,
              FileManager.default.createFile(
                atPath: finalSnapshotCanonicalLock.path,
                contents: Data(),
                attributes: [.posixPermissions: 0o600]) else {
            throw NSError(
                domain: "SessionSnapshotFinalProcessLockTest", code: Int(errno))
        }
    }
    var snapshotFinalLockRejected = false
    do {
        _ = try SessionSnapshotTransaction.snapshot(
            finalizedSession: snapshotSource.session,
            sourceDatabase: snapshotSource.database,
            taskRoot: finalSnapshotLockRoot)
        require(false, "snapshot final lock replacement must fail closed")
    } catch SessionSnapshotTransaction.SessionError.copyFailed(_) {
        snapshotFinalLockRejected = true
    }
    SessionSnapshotTransaction.processLockValidationObserver = nil
    require(
        snapshotFinalLockHookReached
            && snapshotFinalLockRejected
            && FileManager.default.fileExists(atPath: finalSnapshotLockRoot
                .appendingPathComponent("input_snapshot").path)
            && FileManager.default.fileExists(atPath: finalSnapshotLockRoot
                .appendingPathComponent("input_manifest.json").path),
        "snapshot final lock replacement must preserve committed evidence")
    requireSnapshotLockEvidence(
        canonical: finalSnapshotCanonicalLock,
        displaced: finalSnapshotDisplacedLock,
        "snapshot final validation must preserve two valid, distinct lock inodes")

    let finalSnapshotRoot = temporary.appendingPathComponent(
        "Snapshot-Final-Root-Replacement", isDirectory: true)
    let finalSnapshotDisplacedRoot = temporary.appendingPathComponent(
        "Snapshot-Final-Root-Displaced", isDirectory: true)
    try FileManager.default.createDirectory(
        at: finalSnapshotRoot, withIntermediateDirectories: false)
    var snapshotFinalRootHookReached = false
    SessionSnapshotTransaction.processLockValidationObserver = {
        snapshotFinalRootHookReached = true
        guard renameatx_np(
                AT_FDCWD,
                finalSnapshotRoot.path,
                AT_FDCWD,
                finalSnapshotDisplacedRoot.path,
                UInt32(RENAME_EXCL)) == 0 else {
            throw NSError(
                domain: "SessionSnapshotFinalProcessLockTest", code: Int(errno))
        }
        try FileManager.default.createDirectory(
            at: finalSnapshotRoot, withIntermediateDirectories: false)
    }
    var snapshotFinalRootRejected = false
    do {
        _ = try SessionSnapshotTransaction.snapshot(
            finalizedSession: snapshotSource.session,
            sourceDatabase: snapshotSource.database,
            taskRoot: finalSnapshotRoot)
        require(false, "snapshot final root replacement must fail closed")
    } catch SessionSnapshotTransaction.SessionError.copyFailed(_) {
        snapshotFinalRootRejected = true
    }
    SessionSnapshotTransaction.processLockValidationObserver = nil
    let finalSnapshotReplacementRootIdentity = try ImmutableDirectoryPublication.identity(
        of: finalSnapshotRoot, allowedModes: [0o755])
    let finalSnapshotDisplacedRootIdentity = try ImmutableDirectoryPublication.identity(
        of: finalSnapshotDisplacedRoot, allowedModes: [0o755])
    let finalSnapshotPreservedRootLock = finalSnapshotDisplacedRoot
        .appendingPathComponent(SessionSnapshotTransaction.processLockFileName)
    var finalSnapshotPreservedRootLockMetadata = stat()
    require(
        snapshotFinalRootHookReached
            && snapshotFinalRootRejected
            && finalSnapshotReplacementRootIdentity
                != finalSnapshotDisplacedRootIdentity
            && FileManager.default.fileExists(atPath: finalSnapshotDisplacedRoot
                .appendingPathComponent("input_snapshot").path)
            && FileManager.default.fileExists(atPath: finalSnapshotDisplacedRoot
                .appendingPathComponent("input_manifest.json").path)
            && lstat(
                finalSnapshotPreservedRootLock.path,
                &finalSnapshotPreservedRootLockMetadata) == 0
            && (finalSnapshotPreservedRootLockMetadata.st_mode & S_IFMT) == S_IFREG
            && finalSnapshotPreservedRootLockMetadata.st_nlink == 1
            && finalSnapshotPreservedRootLockMetadata.st_size == 0
            && (finalSnapshotPreservedRootLockMetadata.st_mode & mode_t(0o777))
                == 0o600,
        "snapshot final root replacement must preserve roots, lock, and snapshot")
    print("Swift snapshot final process-lock validation contract passed")
    print("Swift result macOS-14 publication and recovery contract passed")
} catch {
    FileHandle.standardError.write(Data("FAILED: \(error)\n".utf8))
    exit(1)
}
