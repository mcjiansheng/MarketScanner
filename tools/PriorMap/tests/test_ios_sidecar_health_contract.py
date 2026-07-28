from __future__ import annotations

import re
import unittest
from pathlib import Path


REPOSITORY = Path(__file__).resolve().parents[3]
SESSION_SOURCE = REPOSITORY / "app/ios/RTABMapApp/SupermarketScanSession.swift"
VIEW_SOURCE = REPOSITORY / "app/ios/RTABMapApp/ViewController.swift"
OVERLAY_SOURCE = REPOSITORY / "app/ios/RTABMapApp/PriorMapLocalization.swift"
FINALIZATION_CORE_SOURCE = (
    REPOSITORY / "app/ios/RTABMapApp/SupermarketFinalizationCore.swift"
)


def source(path: Path) -> str:
    return path.read_text(encoding="utf-8")


class IOSLocalizationSidecarHealthContractTests(unittest.TestCase):
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
            "localizationStateEventCount",
            "localizationEvidenceComplete",
        ):
            self.assertIn(token, session)
        self.assertIn("status: metadataFinalized ? \"eligible\" : \"invalid\"", view)
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
