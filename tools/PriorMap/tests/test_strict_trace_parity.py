from __future__ import annotations

import json
import os
from dataclasses import replace
from pathlib import Path
import subprocess
import tempfile
import unittest

from tools.PriorMap.offline_localization import (
    OfflineLocalizationError,
    TRACE_CONTRACT,
    _read_jsonl_bytes,
)


ROOT = Path(__file__).resolve().parents[3]
BASE_FIXTURE = (
    Path(__file__).with_name("fixtures")
    / "localization_trace"
    / "formal_trace_base.json"
)


def canonical_jsonl(value: dict[str, object]) -> bytes:
    return (
        json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n"
    ).encode("utf-8")


def fixture_cases() -> dict[str, tuple[bytes, str]]:
    base = json.loads(BASE_FIXTURE.read_text(encoding="utf-8"))
    cases: dict[str, tuple[bytes, str]] = {
        "valid.jsonl": (canonical_jsonl(base), "OK"),
    }
    active_unavailable = dict(base)
    active_unavailable.update(
        {
            "confidence": 0.0,
            "confidenceAccepted": False,
            "constraintAccepted": False,
            "constraintDisposition": "rejected",
            "correctionStepApplied": False,
            "hypothesisTrusted": False,
            "localizationState": "lost",
            "measurementAccepted": False,
            "recoveryElapsedMs": 100.0,
            "recoveryEpisodeId": 1,
            "recoveryOutcome": "active",
            "recoveryReason": "persistent_weak_or_lost",
            "recoveryRemainingValidAttempts": 40,
            "recoverySearch": True,
            "recoveryTriggerCount": 1,
            "recoveryValidAttemptCount": 0,
            "scanSearchPerformed": False,
            "trackingState": "notAvailable",
        }
    )
    cases["valid_active_recovery_tracking_unavailable.jsonl"] = (
        canonical_jsonl(active_unavailable),
        "OK",
    )
    numeric_bool = dict(base)
    numeric_bool["constraintAccepted"] = 1
    cases["numeric_bool.jsonl"] = (
        canonical_jsonl(numeric_bool),
        "state_field_type_invalid_constraintAccepted",
    )
    disposition = dict(base)
    disposition["constraintAccepted"] = False
    cases["disposition_inconsistent.jsonl"] = (
        canonical_jsonl(disposition),
        "constraint_disposition_inconsistent",
    )
    recovery = dict(base)
    recovery["recoveryEpisodeId"] = 1
    cases["recovery_bundle_incomplete.jsonl"] = (
        canonical_jsonl(recovery),
        "recovery_bundle_incomplete",
    )
    tracking = dict(base)
    tracking["trackingState"] = "notAvailable"
    cases["tracking_state_inconsistent.jsonl"] = (
        canonical_jsonl(tracking),
        "tracking_state_inconsistent",
    )
    unknown = dict(base)
    unknown["unexpected"] = True
    cases["unknown_field.jsonl"] = (
        canonical_jsonl(unknown),
        "unknown_field_unexpected",
    )
    valid_text = canonical_jsonl(base).decode("utf-8").rstrip("\n")
    duplicate = valid_text[:-1] + ',"confidence":0.2}\n'
    cases["duplicate_key.jsonl"] = (duplicate.encode("utf-8"), "invalid_json")
    return cases


class StrictTraceParityTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.temporary = tempfile.TemporaryDirectory()
        cls.root = Path(cls.temporary.name)
        cls.fixture_directory = cls.root / "fixtures"
        cls.fixture_directory.mkdir()
        cls.expected = {}
        for name, (payload, reason) in fixture_cases().items():
            (cls.fixture_directory / name).write_bytes(payload)
            cls.expected[name] = reason
        cls.runner = cls.root / "strict-trace-runner"
        sources = [
            ROOT / "app/ios/RTABMapApp/GeneratedMobileEvidenceContracts.swift",
            ROOT / "app/ios/RTABMapApp/StrictJSONScalar.swift",
            ROOT / "app/ios/RTABMapApp/StrictJSONKeyUniquenessValidator.swift",
            ROOT / "app/ios/RTABMapApp/StrictJSONDocumentParser.swift",
            ROOT / "app/ios/RTABMapApp/MobilePostProcessing/StrictJSONLStreamReader.swift",
            ROOT / "app/ios/RTABMapApp/MobilePostProcessing/StrictLocalizationTraceParser.swift",
            ROOT / "tools/PriorMap/tests/strict_trace_fixture_runner/main.swift",
        ]
        environment = dict(os.environ)
        environment["CLANG_MODULE_CACHE_PATH"] = str(cls.root / "clang-cache")
        environment["SWIFT_MODULECACHE_PATH"] = str(cls.root / "swift-cache")
        subprocess.run(
            ["xcrun", "swiftc", *map(str, sources), "-o", str(cls.runner)],
            check=True,
            cwd=ROOT,
            env=environment,
            capture_output=True,
            text=True,
        )

    @classmethod
    def tearDownClass(cls) -> None:
        cls.temporary.cleanup()

    def test_device_and_pc_return_the_same_stable_reason(self) -> None:
        completed = subprocess.run(
            [str(self.runner), str(self.fixture_directory)],
            check=True,
            cwd=ROOT,
            capture_output=True,
            text=True,
        )
        device = dict(
            line.split("=", 1)
            for line in completed.stdout.splitlines()
            if line.strip()
        )
        pc: dict[str, str] = {}
        for path in sorted(self.fixture_directory.glob("*.jsonl")):
            try:
                _read_jsonl_bytes(
                    path.read_bytes(),
                    TRACE_CONTRACT,
                    path_label=path.name,
                    session_id="session-a",
                    expected_map_hash="a" * 64,
                    expected_floor_id="1",
                )
                pc[path.name] = "OK"
            except OfflineLocalizationError as error:
                pc[path.name] = error.reason or "unstable_reason"
        self.assertEqual(device, self.expected)
        self.assertEqual(pc, self.expected)

    def test_qualification_ceiling_is_distinct_from_the_hard_cap(self) -> None:
        device = subprocess.run(
            [str(self.runner), "--qualification-preflight"],
            check=True,
            cwd=ROOT,
            capture_output=True,
            text=True,
        )
        self.assertEqual(device.stdout.strip(), "qualification_limit_exceeded")

        base = json.loads(BASE_FIXTURE.read_text(encoding="utf-8"))
        second = dict(base)
        second["timestamp"] = 2.0
        second["nodeTimebaseTimestamp"] = 1002.0
        payload = canonical_jsonl(base) + canonical_jsonl(second)
        one_record_qualification = replace(
            TRACE_CONTRACT,
            qualification_maximum_records=1,
        )
        with self.assertRaises(OfflineLocalizationError) as caught:
            _read_jsonl_bytes(
                payload,
                one_record_qualification,
                path_label="qualification.jsonl",
                session_id="session-a",
                expected_map_hash="a" * 64,
                expected_floor_id="1",
            )
        self.assertEqual(caught.exception.reason, "qualification_limit_exceeded")

    def test_compaction_axis_rejects_finite_values_that_cannot_form_int64_seconds(
        self,
    ) -> None:
        base = json.loads(BASE_FIXTURE.read_text(encoding="utf-8"))

        def device_reason(
            *,
            timestamp: float,
            node_timestamp: float,
            origin: float,
        ) -> str:
            case_directory = self.root / f"axis-{len(list(self.root.glob('axis-*')))}"
            case_directory.mkdir()
            value = dict(base)
            value["timestamp"] = timestamp
            value["nodeTimebaseTimestamp"] = node_timestamp
            value["nodeTimebaseOffsetSeconds"] = node_timestamp - timestamp
            (case_directory / "case.jsonl").write_bytes(canonical_jsonl(value))
            completed = subprocess.run(
                [
                    str(self.runner),
                    "--compaction-origin",
                    repr(origin),
                    str(case_directory),
                ],
                check=True,
                cwd=ROOT,
                capture_output=True,
                text=True,
            )
            return completed.stdout.strip().split("=", 1)[1]

        self.assertEqual(
            device_reason(timestamp=1e308, node_timestamp=1e308, origin=-1e308),
            "compaction_axis_out_of_range",
        )
        self.assertEqual(
            device_reason(timestamp=2e19, node_timestamp=2e19, origin=0.0),
            "compaction_axis_out_of_range",
        )
        self.assertEqual(
            device_reason(timestamp=-2e19, node_timestamp=-2e19, origin=0.0),
            "compaction_axis_out_of_range",
        )
        self.assertEqual(
            device_reason(timestamp=1e308, node_timestamp=1e308, origin=1e308),
            "OK",
        )
        self.assertEqual(
            device_reason(timestamp=0.0, node_timestamp=0.0, origin=1.0),
            "OK",
        )


if __name__ == "__main__":
    unittest.main()
