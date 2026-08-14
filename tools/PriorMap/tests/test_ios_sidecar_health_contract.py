from __future__ import annotations

import json
import re
import unittest
from pathlib import Path


REPOSITORY = Path(__file__).resolve().parents[3]
SESSION_SOURCE = REPOSITORY / "app/ios/RTABMapApp/SupermarketScanSession.swift"
VIEW_SOURCE = REPOSITORY / "app/ios/RTABMapApp/ViewController.swift"
OVERLAY_SOURCE = REPOSITORY / "app/ios/RTABMapApp/PriorMapLocalization.swift"
MATCHER_SOURCE = REPOSITORY / "app/ios/RTABMapApp/PriorMapScanMatcher.swift"
CORE_SOURCE = REPOSITORY / "app/ios/RTABMapApp/PriorMapLocalizationCore.swift"
DEPTH_SOURCE = REPOSITORY / "app/ios/RTABMapApp/PriorMapDepthSampler.swift"
FINALIZATION_CORE_SOURCE = (
    REPOSITORY / "app/ios/RTABMapApp/SupermarketFinalizationCore.swift"
)
PERSISTENCE_COORDINATOR_SOURCE = (
    REPOSITORY / "app/ios/RTABMapApp/RecoveryLifecyclePersistenceCore.swift"
)
RECOVERY_EVIDENCE_PARSER_SOURCE = (
    REPOSITORY / "app/ios/RTABMapApp/RecoveryLifecycleEvidenceParser.swift"
)
MOBILE_INPUT_CONTRACT = (
    REPOSITORY / "contracts/mobile_only_v1r5_input_limits.json"
)
SNAPSHOT_SOURCE = (
    REPOSITORY
    / "app/ios/RTABMapApp/MobilePostProcessing/SessionSnapshotTransaction.swift"
)


def source(path: Path) -> str:
    return path.read_text(encoding="utf-8")


class IOSLocalizationSidecarHealthContractTests(unittest.TestCase):
    def test_finalized_metadata_uses_one_stable_read_for_parse_and_digest(self) -> None:
        snapshot = source(SNAPSHOT_SOURCE)
        reader = snapshot.split("private static func readMetadata(", 1)[1].split(
            "private static func checkEligibility(", 1
        )[0]
        self.assertIn("O_RDONLY | O_NOFOLLOW", reader)
        self.assertIn("before.st_nlink == 1", reader)
        self.assertIn("Int64(before.st_size) <= maximumMetadataBytes", reader)
        self.assertIn("sameFileIdentity(before, after)", reader)
        self.assertIn("sameFileIdentity(before, pathAfter)", reader)
        self.assertNotIn("mappedIfSafe", reader)
        self.assertIn("return (value, sha256(data))", reader)
        self.assertIn(
            "metadataSnapshot.sha256 == stagedMetadataSnapshot.sha256",
            snapshot,
        )

    def test_generated_metadata_and_native_limits_match_shipping_gates(self) -> None:
        contract = json.loads(MOBILE_INPUT_CONTRACT.read_text(encoding="utf-8"))
        metadata = contract["evidence_files"]["metadata.json"]
        self.assertEqual(metadata["max_file_bytes"], 1024 * 1024)
        self.assertEqual(metadata["max_record_bytes"], 1024 * 1024)
        self.assertIn(
            "captureHealth.localizationTraceRecordCount",
            metadata["watermark_fields"],
        )
        self.assertNotIn(
            "localizationTraceRecordCount",
            metadata["watermark_fields"],
        )
        for watermark in (
            "performanceSampleCount",
            "performanceLastSequence",
            "performanceLastTimestampUnix",
            "performanceEvidenceComplete",
        ):
            self.assertIn(watermark, metadata["watermark_fields"])
        performance = contract["evidence_files"]["performance_samples.jsonl"]
        self.assertEqual(performance["max_file_bytes"], 256 * 1024 * 1024)
        self.assertEqual(performance["max_record_bytes"], 64 * 1024)
        self.assertEqual(performance["max_records"], 250_000)
        self.assertEqual(performance["qualification_max_records"], 34_560)
        self.assertEqual(performance["identity_fields"], ["tracking_session_id"])

        native = contract["evidence_files"]["native_graph"]
        self.assertEqual(native["max_raw_nodes"], 200_000)
        self.assertEqual(native["max_skeleton_nodes"], 4_096)
        self.assertEqual(native["max_factors"], 4_096)
        self.assertEqual(native["max_priors"], 4_096)
        self.assertEqual(native["max_trajectory_rows"], 200_000)

    def test_bounded_performance_evidence_is_preserved_without_becoming_pose_authority(self) -> None:
        session = source(SESSION_SOURCE)
        view = source(VIEW_SOURCE)
        snapshot = source(SNAPSHOT_SOURCE)
        for token in (
            "MarketScannerPerformanceSample",
            "performance_samples.jsonl",
            "File_performance_samples_jsonl",
            ".max_records",
            ".max_file_bytes",
            ".max_record_bytes",
            "performanceEvidenceWatermark",
            "performanceEvidenceSealed",
            'gpuMetricStatus: "not_available_public_ios_api"',
        ):
            self.assertIn(token, session)
        for token in (
            "recordStreamingPerformanceSample",
            "processCPUTimeSeconds",
            "ProcessingResourceGovernor.currentMemoryFootprintMB()",
            "ProcessingResourceGovernor.batteryPercent()",
            'scanState: "finalizing"',
            "sealAfterAppend: force && scanState == \"finalizing\"",
        ):
            self.assertIn(token, view)
        self.assertIn("observabilitySidecarPairs", snapshot)
        self.assertIn(
            '("performanceSamples", "performance_samples.jsonl")', snapshot
        )
        required_pairs = snapshot.split(
            "static let declaredSidecarPairs", 1
        )[1].split("static let observabilitySidecarPairs", 1)[0]
        self.assertNotIn("performanceSamples", required_pairs)

    def test_sam_recovery_and_dynamic_filtering_contracts_are_wired(self) -> None:
        view = source(VIEW_SOURCE)
        overlay = source(OVERLAY_SOURCE)
        matcher = source(MATCHER_SOURCE)
        core = source(CORE_SOURCE)
        depth = source(DEPTH_SOURCE)
        session = source(SESSION_SOURCE)
        finalization = source(FINALIZATION_CORE_SOURCE)
        coordinator = source(PERSISTENCE_COORDINATOR_SOURCE)
        parser = source(RECOVERY_EVIDENCE_PARSER_SOURCE)
        for token in (
            "PriorMapHypothesisTracker",
            "activeTracks",
            "recoverySearch ? 5.0 : 1.2",
            "recoverySearch ? 30 : 12",
        ):
            self.assertIn(token, matcher)
        for token in (
            'requestRecovery(reason: "reliable_rtabmap_loop")',
            "persistTerminalRecoveryEvidence(",
            "localizerToCancel.cancelRecovery(",
            "reason: .scanStopped",
            "mPendingAdaptiveDetectionRateSince",
            "dwellSeconds",
            "priorMapLastNodeBinding",
        ):
            self.assertIn(token, view)
        self.assertIn("PriorMapRecoveryController", core + overlay)
        # P7R6: peek/ack replaced drain-before-ack; completions stay queued
        # until the durable append is confirmed.
        for token in (
            "pendingTerminalRecoveryCompletions",
            "acknowledgeTerminalRecoveryCompletion",
            "discardTerminalRecoveryCompletionsForInvalidatedSession",
        ):
            self.assertIn(token, overlay)
        self.assertNotIn("drainTerminalRecoveryCompletions", overlay + view)
        self.assertIn("cancelRecovery(", overlay)
        for token in (
            "RecoveryLifecyclePersistenceCoordinator(",
            "runRecoveryLifecyclePersistence(",
            "dispatchPrecondition",
        ):
            self.assertIn(token, view)
        for token in (
            "RecoveryCompletionDraining",
            "RecoveryLifecycleWriting",
            "RecoveryLifecyclePersistenceResult",
            "persisted_episode_bytes_conflict",
            "persisted_episode_version_conflict",
            "durable_append_failed",
            # P7R6A: the coordinator must validate the complete snapshot
            # through the shared strict parser before any acknowledgement.
            "RecoveryLifecyclePersistedEvidenceParser.parse(",
            "canonicalPendingRecordBytes(",
        ):
            self.assertIn(token, coordinator)
        # P7R6A: the coordinator must not auto-decode persisted records
        # with a plain JSONDecoder; only the strict parser decides.
        self.assertNotIn("JSONDecoder", coordinator)
        self.assertIn("persistedRecoveryLifecycleSnapshot", session)
        self.assertNotIn("persistedRecoveryLifecycleLines", session)
        for token in (
            "RecoveryLifecycleEvidenceExpectation",
            "PersistedRecoveryLifecycleRecord",
            "ParsedRecoveryLifecycleEvidence",
            "RecoveryLifecycleEvidenceParseError",
            "missingFinalNewline",
            "canonicalRecordBytes",
        ):
            self.assertIn(token, parser)
        self.assertIn("recordRecoveryPersistenceFailure", session + view)
        self.assertIn("appendRecoveryLifecycleEvent", session)
        self.assertIn("MarketScannerRecoveryLifecycleEvent", core)
        self.assertIn("localization_recovery_events.jsonl", finalization)
        self.assertIn("beginRecoveryEpisode(id: episode.id)", overlay)
        self.assertIn("match.searchPerformed", overlay)
        self.assertIn("minimumSearchPointCount = 30", matcher)
        self.assertIn("PriorMapRecoveryUpdateReducer.reduce", overlay)
        self.assertIn("recoveryController.recordFrameDisposition", core)
        self.assertIn("PriorMapRecoveryFrameDisposition", core)
        self.assertIn("PriorMapLocalizationAnchor", core + overlay)
        self.assertIn("PriorMapHypothesisTraceBinder.bind", overlay)
        self.assertNotIn("recoveryFramesRemaining", overlay)
        self.assertIn("PriorMapRecoveryDecisionEngine.evaluate", core)
        self.assertIn("convergenceTranslationM = 0.5", core)
        self.assertIn("guard hits >= 4, frameIndex - firstFrame >= 3", depth)
        for token in (
            "PriorMapAlignmentTransform",
            "PriorMapAlignmentMath.mapFromArkit",
            "PriorMapAlignmentMath.apply",
            "PriorMapCorrectionSafety.isWithinGate",
            "PriorMapCorrectionSafety.boundedStep",
        ):
            self.assertIn(token, core + matcher + overlay)
        self.assertNotIn("PriorMapCorrectionMath", matcher)
        self.assertNotIn("PriorMapTemporalCorrectionGate", matcher)

    def test_loop_recovery_and_corrected_hud_are_fail_closed(self) -> None:
        overlay = source(OVERLAY_SOURCE)
        recovery = overlay.split("func requestRecovery(reason: String)", 1)[1].split(
            "func update(", 1
        )[0]
        self.assertIn("beginRecovery(", recovery)
        self.assertNotIn("arkitOrigin =", recovery)
        self.assertNotIn("initialMapPose =", recovery)
        self.assertNotIn("latestEstimatedPose =", recovery)
        self.assertIn("recentTrajectory.append(value.estimatedPose)", overlay)
        self.assertIn("xM: value.estimatedPose.xM", overlay)
        self.assertIn("yM: value.estimatedPose.yM", overlay)
        self.assertIn("value.estimatedPose.yawRad", overlay)

    def test_recovery_episode_budget_and_cleanup_are_explicit(self) -> None:
        overlay = source(OVERLAY_SOURCE)
        matcher = source(MATCHER_SOURCE)
        core = source(CORE_SOURCE)
        for token in (
            "struct PriorMapRecoveryEpisode",
            "maximumValidAttempts: Int = 40",
            "maximumWallClockSeconds: TimeInterval = 30",
            "episode.remainingValidAttempts == 0",
            "triggerCount + 1",
            "maximumRetainedTriggerRecords = 8",
        ):
            self.assertIn(token, core)
        for token in (
            "func beginRecoveryEpisode(id: Int)",
            "func endRecoveryEpisode(id: Int, outcome _:",
            "Limits.supportFrameCap",
        ):
            self.assertIn(token, matcher)
        for token in (
            "outcome: .timedOut",
            "outcome: .converged",
            "outcome: .manualReset",
            "recoveryValidAttemptCount",
            "recoveryFreshSupportFrames",
            "recoveryFinishedAtUptime",
            "recoverySelectedHypothesisId",
        ):
            self.assertIn(token, overlay)

    def test_trace_constraint_and_state_return_one_structured_result(self) -> None:
        session = source(SESSION_SOURCE)
        finalization = source(FINALIZATION_CORE_SOURCE)
        self.assertIn("struct LocalizationWriteResult", finalization)
        for field in (
            "traceWritten",
            "constraintWritten",
            "stateWriteRequired",
            "stateWritten",
            "failureReasons",
        ):
            self.assertIn(f"let {field}", finalization)
        signature = re.search(
            r"func appendLocalizationTrace\((?P<body>.*?)\n    }\n\n"
            r"    @discardableResult\n    func appendTagObservation",
            session,
            flags=re.DOTALL,
        )
        self.assertIsNotNone(signature)
        body = signature.group("body")
        self.assertIn(") -> LocalizationWriteResult", body)
        self.assertIn("recordLocalizationEvidenceFailures(result.failureReasons)", body)
        self.assertIn("return result", body)

    def test_localization_waits_for_native_node_timebase_before_writer(self) -> None:
        view = source(VIEW_SOURCE)
        update = view.split(
            "private func updatePriorMapLocalization(", 1
        )[1].split("@objc private func scanPriorMapPriceTag", 1)[0]
        admission = update.index("PriorMapNodeTimebaseAdmission.accepts")
        writer = update.index("scanSession.appendLocalizationTrace")
        self.assertLess(admission, writer)
        self.assertIn(
            'event: "prior_map_update_waiting_for_node_timebase"',
            update,
        )
        self.assertIn("return\n        }", update[admission:writer])
        self.assertNotIn(".nan", update)
        self.assertIn(
            "nodeTimebaseOffsetSeconds: nodeTimebase.offsetSeconds",
            update,
        )

    def test_state_watermark_advances_only_after_state_write_success(self) -> None:
        session = source(SESSION_SOURCE)
        guarded_assignment = re.compile(
            r"if stateWriteRequired && result\.stateWritten \{\s*"
            r"//.*?\s*lastLocalizationState = update\.localizationState\s*\}",
            flags=re.DOTALL,
        )
        self.assertIsNotNone(guarded_assignment.search(session))
        self.assertEqual(
            session.count("lastLocalizationState = update.localizationState"),
            1,
        )

    def test_capture_health_and_finalization_gate_are_persistent(self) -> None:
        session = source(SESSION_SOURCE)
        view = source(VIEW_SOURCE)
        overlay = source(OVERLAY_SOURCE)
        for token in (
            "localizationRequiredWriteFailureCount",
            "firstLocalizationRequiredWriteError",
            "localizationTraceRecordCount",
            "localizationConstraintRecordCount",
            "manualLocalizationEventCount",
            "localizationStateEventCount",
            "localizationEvidenceComplete",
        ):
            self.assertIn(token, session)
        self.assertRegex(
            session,
            r"(?s)if !result\.succeeded \{.*?\} else \{.*?"
            r"manualLocalizationEventCount \+= 1",
        )
        self.assertIn(
            "manualLocalizationEventCount:",
            session,
        )
        # V1R4 §7.2/§13.1: the finalization gate is driven by the
        # processing blockers (clock sidecar, prior-map evidence,
        # tag burst flush) and maps to eligible/invalid eligibility.
        self.assertIn("let metadataFinalized = processingBlockers.isEmpty", view)
        self.assertIn("status: \"eligible\", blockers: []", view)
        self.assertIn("status: \"invalid\", blockers: processingBlockers", view)
        self.assertIn("formatVersion: 2", view)
        self.assertIn("eligibilityError: processingEligibilityError", view)
        self.assertIn("showEvidenceWriteFailure", overlay)
        self.assertIn("presentLocalizationEvidenceWriteFailure", view)

    def test_metadata_is_the_last_sidecar_commit_marker(self) -> None:
        session = source(SESSION_SOURCE)
        write_function = re.search(
            r"func writeSidecarFiles\((?P<body>.*?)\n    }\n\n"
            r"    func appendScanEvent",
            session,
            flags=re.DOTALL,
        )
        self.assertIsNotNone(write_function)
        body = write_function.group("body")
        metadata_write = body.index('appendingPathComponent("metadata.json")')
        self.assertGreater(
            metadata_write,
            body.index('appendingPathComponent("trajectory_samples.json")'),
        )
        self.assertGreater(
            body.index('"live_checkpoint.json"'),
            metadata_write,
        )
        self.assertIn("SidecarFinalizationCoordinator.commitMetadata", body)

    def test_metadata_commit_and_checkpoint_cleanup_are_separate_states(self) -> None:
        session = source(SESSION_SOURCE)
        finalization = source(FINALIZATION_CORE_SOURCE)
        view = source(VIEW_SOURCE)
        self.assertIn("struct SidecarCommitResult", finalization)
        self.assertIn("case finalizedNeedsCleanup", finalization)
        self.assertIn("return try SidecarFinalizationCoordinator.commitMetadata", session)
        self.assertIn("terminalFinalizedNeedsCleanup", view)
        self.assertIn("if !effects.allowsExternalCopy", view)
        self.assertNotIn("try fileManager.removeItem(at: checkpoint)", session)

    def test_append_uses_throwing_filehandle_io(self) -> None:
        session = source(SESSION_SOURCE)
        finalization = source(FINALIZATION_CORE_SOURCE)
        self.assertIn("try sidecarWriter.append(encoded.data, to: encoded.url)", session)
        self.assertIn("try handle.write(contentsOf: data)", finalization)
        self.assertIn("try handle.synchronize()", finalization)
        self.assertNotIn("handle.write(data)", finalization)

    def test_finalized_metadata_is_bound_to_persisted_evidence_bytes(self) -> None:
        session = source(SESSION_SOURCE)
        finalization = source(FINALIZATION_CORE_SOURCE)
        self.assertIn("enum LocalizationEvidenceBundleValidator", finalization)
        for token in (
            "requiredNonEmpty",
            "invalid_utf8_or_partial_line",
            "count_mismatch",
            "identity_mismatch",
            "watermark_mismatch",
            "isSymbolicLinkKey",
        ):
            self.assertIn(token, finalization)
        self.assertIn("LocalizationEvidenceBundleValidator.blockers", session)
        self.assertIn("committedMetadata.finalized = false", session)

    def test_finalization_validator_is_streaming_bounded_and_schema_strict(self) -> None:
        finalization = source(FINALIZATION_CORE_SOURCE)
        validator = finalization.split(
            "enum LocalizationEvidenceBundleValidator", 1
        )[1].split("struct SafeRegularFileSnapshot", 1)[0]
        jsonl_validator = validator.split(
            "private static func validateLocalizedTags", 1
        )[0]
        for token in (
            "streamRegularFile",
            "maximumRecordBytes = 1_000_000",
            "maximumRecords = 500_000",
            "maximumLocalizedTagRecords = 50_000",
            "maximumLocalizedTagsBytes = 16 * 1024 * 1024",
            "autoreleasepool",
            "node_timebase_contract_invalid",
            "trace_business_schema_invalid",
            "constraint_business_schema_invalid",
            "state_business_schema_invalid",
            "tag_business_schema_invalid",
        ):
            self.assertIn(token, validator)
        self.assertNotIn("Data(contentsOf:", jsonl_validator)
        self.assertNotIn("readToEnd", jsonl_validator)
        self.assertNotIn("[[String: Any]]", jsonl_validator)
        safe_path = finalization.split("enum SafeSessionPath", 1)[1]
        self.assertIn("finalPathInfo.st_ino == openedInfo.st_ino", safe_path)
        self.assertIn("file_identity_changed_during_read", safe_path)

    def test_checkpoint_cleanup_uses_no_follow_file_identity(self) -> None:
        session = source(SESSION_SOURCE)
        finalization = source(FINALIZATION_CORE_SOURCE)
        for token in (
            "enum SafeSessionPath",
            "O_NOFOLLOW",
            "openat",
            "fstat",
            "unlinkat",
            "file_changed_before_delete",
            "directory_identity_changed_during_open",
            "isStrictlyContained",
        ):
            self.assertIn(token, finalization)
        self.assertIn("SafeSessionPath.readRegularFile", session)
        self.assertIn("SafeSessionPath.removeRegularFile", session)
        self.assertIn("finalization_checkpoint_cleanup_failed", session)

    def test_atomic_visibility_and_copy_retention_contracts_are_explicit(self) -> None:
        session = source(SESSION_SOURCE)
        finalization = source(FINALIZATION_CORE_SOURCE)
        view = source(VIEW_SOURCE)
        for token in (
            "enum AtomicWriteStage",
            "O_EXCL",
            "handle.synchronize()",
            "Darwin.rename",
            "ExternalCopyVerificationReceipt",
            "no_power_loss_guarantee",
        ):
            self.assertIn(token, finalization + session)
        self.assertIn("localCopyRetained: true", session)
        copy_function = re.search(
            r"private func copyCaptureInBackground\((?P<body>.*?)\n    }\n\n"
            r"    func save\(",
            view,
            flags=re.DOTALL,
        )
        self.assertIsNotNone(copy_function)
        self.assertNotIn("removeLocalCaptureDirectory", copy_function.group("body"))

    def test_copy_receipt_is_path_private_and_has_qualification_hook(self) -> None:
        session = source(SESSION_SOURCE)
        finalization = source(FINALIZATION_CORE_SOURCE)
        self.assertNotIn("sourceDirectory", finalization)
        self.assertNotIn("destinationDirectory", finalization)
        for token in (
            "packageContentSha256",
            "providerDisplayName",
            "sourceRelativePath",
            "destinationRelativePath",
            "ExternalCopyPackageManifest",
            "ExternalCopyDurabilityQualificationEvidence",
        ):
            self.assertIn(token, finalization)
        self.assertIn("recordExternalCopyDurabilityQualification", session)
        self.assertIn("durabilityQualificationStatus: \"not_executed\"", session)
        self.assertIn("localCopyRetained: true", session)

    def test_finalization_effects_connect_explicit_dispositions_to_ui(self) -> None:
        finalization = source(FINALIZATION_CORE_SOURCE)
        view = source(VIEW_SOURCE)
        self.assertIn("struct ScanFinalizationEffects", finalization)
        self.assertIn("enum ScanFinalizationEffectPlanner", finalization)
        for token in (
            "resumesCameraAndMapping",
            "closesSession",
            "allowsExternalCopy",
            "preservesCheckpoint",
            "processingEligible",
        ):
            self.assertIn(token, finalization)
        self.assertIn(
            "completion: ((ScanFinalizationDisposition) -> Void)?", view
        )
        self.assertNotIn("completion: ((Bool) -> Void)?", view)
        self.assertIn("ScanFinalizationEffectPlanner.effects", view)
        self.assertIn("if !effects.allowsExternalCopy", view)


if __name__ == "__main__":
    unittest.main()
