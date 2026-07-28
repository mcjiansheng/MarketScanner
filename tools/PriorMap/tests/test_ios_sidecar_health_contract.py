from __future__ import annotations

import re
import unittest
from pathlib import Path


REPOSITORY = Path(__file__).resolve().parents[3]
SESSION_SOURCE = REPOSITORY / "app/ios/RTABMapApp/SupermarketScanSession.swift"
VIEW_SOURCE = REPOSITORY / "app/ios/RTABMapApp/ViewController.swift"
OVERLAY_SOURCE = REPOSITORY / "app/ios/RTABMapApp/PriorMapLocalization.swift"


def source(path: Path) -> str:
    return path.read_text(encoding="utf-8")


class IOSLocalizationSidecarHealthContractTests(unittest.TestCase):
    def test_trace_constraint_and_state_return_one_structured_result(self) -> None:
        session = source(SESSION_SOURCE)
        self.assertIn("struct LocalizationWriteResult", session)
        for field in (
            "traceWritten",
            "constraintWritten",
            "stateWriteRequired",
            "stateWritten",
            "failureReasons",
        ):
            self.assertIn(f"let {field}", session)
        signature = re.search(
            r"func appendLocalizationTrace\((?P<body>.*?)\n    }\n\n"
            r"    @discardableResult\n    func appendTagObservation",
            session,
            flags=re.DOTALL,
        )
        self.assertIsNotNone(signature)
        body = signature.group("body")
        self.assertIn(") -> LocalizationWriteResult", body)
        self.assertIn("recordLocalizationEvidenceFailures(failures)", body)
        self.assertIn("return result", body)

    def test_state_watermark_advances_only_after_state_write_success(self) -> None:
        session = source(SESSION_SOURCE)
        guarded_assignment = re.compile(
            r"if stateResult\.succeeded \{\s*"
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
        self.assertIn("processingEligibilityError == nil", view)
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
        self.assertIn("try fileManager.removeItem(at: checkpoint)", body)

    def test_append_uses_throwing_filehandle_io(self) -> None:
        session = source(SESSION_SOURCE)
        append_record = re.search(
            r"private func appendLocalizationRecord(?P<body>.*?)\n    }\n\n"
            r"    private func recordLocalizationEvidenceFailures",
            session,
            flags=re.DOTALL,
        )
        self.assertIsNotNone(append_record)
        body = append_record.group("body")
        self.assertIn("try handle.write(contentsOf: data)", body)
        self.assertIn("try handle.synchronize()", body)
        self.assertNotIn("handle.write(data)", body)


if __name__ == "__main__":
    unittest.main()
