from __future__ import annotations

import csv
import hashlib
import json
from pathlib import Path
import shutil
import tempfile
import unittest

from tools.Qualification.qualification import (
    DEVICE_SCENARIO_ASSERTIONS,
    REQUIRED_DEVICE_SCENARIOS,
    QualificationError,
    _canonical_sha,
    collect_device,
    evaluate_field,
)


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value), encoding="utf-8")


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


class QualificationTests(unittest.TestCase):
    def make_device_fixture(self, root: Path) -> Path:
        prior = root / "prior-map.zip"
        prior.write_bytes(b"prior-map")
        library = root / "libRTABMap.a"
        library.write_bytes(b"native-library")
        log = root / "operator.log"
        log.write_text("real-device log fixture", encoding="utf-8")
        segment = root / "SupermarketSession-test" / "segment_0001"
        segment.mkdir(parents=True)
        for name in (
            "localization_trace.jsonl",
            "localization_constraints.jsonl",
            "localization_events.jsonl",
            "localized_price_tags.json",
        ):
            (segment / name).write_text("[]\n", encoding="utf-8")
        (segment / "rtabmap_segment_0001.db").write_bytes(b"SQLite fixture")
        session_id = "session-real-device"
        prior_sha = sha256(prior)
        write_json(segment / "metadata.json", {
            "scanMode": "continuous_streaming",
            "finalized": True,
            "trackingSessionId": session_id,
            "priorMapId": "prior-1",
            "priorMapSha256": prior_sha,
            "captureHealth": {
                "localizationEvidenceComplete": True,
                "localizationRequiredWriteFailureCount": 0,
            },
            "processingEligibility": {"status": "eligible", "blockers": []},
        })
        copy_root = root / "external-copy"
        copy_root.mkdir()
        copied_segment = copy_root / "segment_0001"
        shutil.copytree(segment, copied_segment)
        receipt_files = [
            {
                "relativePath": path.relative_to(copied_segment).as_posix(),
                "byteCount": path.stat().st_size,
                "sha256": sha256(path),
            }
            for path in sorted(copied_segment.rglob("*"))
            if path.is_file()
        ]
        write_json(copy_root / "copy_verification.json", {
            "format": "MarketScannerExternalCopyVerification",
            "version": 2,
            "packageId": "package-1",
            "sessionId": session_id,
            "localCopyRetained": True,
            "files": receipt_files,
            "packageContentSha256": _canonical_sha(receipt_files),
        })
        files = [
            {
                "relativePath": path.relative_to(copy_root).as_posix(),
                "byteCount": path.stat().st_size,
                "sha256": sha256(path),
            }
            for path in sorted(copy_root.rglob("*"))
            if path.is_file()
        ]
        write_json(copy_root / "copy_package_manifest.json", {
            "format": "MarketScannerExternalCopyPackageManifest",
            "version": 1,
            "packageId": "package-1",
            "sessionId": session_id,
            "localCopyRetained": True,
            "files": files,
            "packageContentSha256": _canonical_sha(files),
            "durabilityQualificationStatus": "not_executed",
        })
        plan = root / "device-plan.json"
        write_json(plan, {
            "format": "MarketScannerDeviceQualificationPlan",
            "version": 1,
            "executionStatus": "executed_on_real_device",
            "operator": "test operator",
            "device": {"model": "iPhone Pro", "iosBuild": "test", "lidarAvailable": True},
            "app": {
                "gitSha": "a" * 40,
                "buildId": "test-build",
                "nativeStaticLibraries": [str(library)],
            },
            "runs": [{
                "runId": "device-run-1",
                "executedAtUnix": 2_000_000_000,
                "covers": sorted(REQUIRED_DEVICE_SCENARIOS),
                "operatorAssertions": {
                    assertion: True
                    for assertion in set().union(*DEVICE_SCENARIO_ASSERTIONS.values())
                },
                "segmentDirectory": str(segment),
                "expectedSessionOutcome": "finalized_eligible",
                "priorMapId": "prior-1",
                "priorMapSha256": prior_sha,
                "priorMapPackage": str(prior),
                "externalCopyRoot": str(copy_root),
                "evidenceFiles": [str(log)],
                "environment": {
                    "testAreaDimensions": "20m x 10m",
                    "filesProvider": "On My iPhone",
                    "initialAvailableStorageBytes": 10_000_000,
                    "initialBatteryPercent": 90,
                    "initialThermalState": "nominal",
                },
            }],
        })
        return plan

    def test_device_evidence_passes_only_complete_matrix(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            plan = self.make_device_fixture(root)
            evidence = collect_device(plan, root / "evidence.json")
            self.assertEqual(evidence["result"], "PASS")
            self.assertNotIn(str(root), json.dumps(evidence))
            self.assertEqual(len(evidence["app"]["nativeStaticLibraries"]), 1)

    def test_device_evidence_fails_missing_scenario_and_is_immutable(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            plan = self.make_device_fixture(root)
            value = json.loads(plan.read_text(encoding="utf-8"))
            value["runs"][0]["covers"].remove("low_disk")
            write_json(plan, value)
            output = root / "evidence.json"
            evidence = collect_device(plan, output)
            self.assertEqual(evidence["result"], "FAIL")
            self.assertTrue(any("missing_scenarios:low_disk" in item for item in evidence["blockers"]))
            with self.assertRaises(QualificationError):
                collect_device(plan, output)

    def test_device_evidence_detects_same_size_copy_mutation(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            plan = self.make_device_fixture(root)
            value = json.loads(plan.read_text(encoding="utf-8"))
            copied_database = (
                Path(value["runs"][0]["externalCopyRoot"])
                / "segment_0001"
                / "rtabmap_segment_0001.db"
            )
            original = copied_database.read_bytes()
            copied_database.write_bytes(bytes([original[0] ^ 0xFF]) + original[1:])
            evidence = collect_device(plan, root / "evidence.json")
            self.assertEqual(evidence["result"], "FAIL")
            self.assertIn(
                "device-run-1:copy_package_files_changed",
                evidence["blockers"],
            )
            self.assertIn(
                "device-run-1:copy_receipt_files_changed",
                evidence["blockers"],
            )

    def test_device_evidence_requires_scenario_specific_assertions(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            plan = self.make_device_fixture(root)
            value = json.loads(plan.read_text(encoding="utf-8"))
            del value["runs"][0]["operatorAssertions"]["no_hard_snap_during_weak_lost"]
            write_json(plan, value)
            evidence = collect_device(plan, root / "evidence.json")
            self.assertEqual(evidence["result"], "FAIL")
            self.assertTrue(any(
                "no_hard_snap_during_weak_lost" in blocker
                for blocker in evidence["blockers"]
            ))

    def test_field_evidence_requires_three_repeatable_runs(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            release = root / "release-manifest.json"
            release.write_text("{}", encoding="utf-8")
            topology = "b" * 64
            shelf = "c" * 64
            runs = []
            for index in range(3):
                device_evidence = root / f"device-evidence-{index}.json"
                device_evidence_value = {
                    "format": "MarketScannerDeviceQualificationEvidence",
                    "version": 1,
                    "run": index,
                    "result": "PASS",
                }
                device_evidence_value["evidenceSha256"] = _canonical_sha(
                    device_evidence_value
                )
                write_json(device_evidence, device_evidence_value)
                device_evidence_sha = sha256(device_evidence)
                metrics = root / f"metrics-{index}.json"
                write_json(metrics, {
                    "nodeCoverage": 0.99,
                    "correctionP95M": 0.5,
                    "correctionMaxM": 1.0,
                    "relativeTranslationResidualP95M": 0.1,
                    "relativeYawResidualP95Rad": 0.05,
                    "weakLostDurationRatio": 0.01,
                    "inventoriesMatch": True,
                    "factorGraphConverged": True,
                    "singleConnectedComponent": True,
                    "allGroundTruthTagsObserved": True,
                    "userConfirmedTagsPreserved": True,
                    "automaticConfirmDuringWeakLost": 0,
                    "topologyDigest": topology,
                    "shelfAssociationDigest": shelf,
                    "sourceSessionSha256": device_evidence_sha,
                })
                measurements = root / f"tags-{index}.csv"
                with measurements.open("w", newline="", encoding="utf-8") as stream:
                    writer = csv.writer(stream)
                    writer.writerow([
                        "tag_id", "truth_x_m", "truth_y_m", "truth_height_m",
                        "estimated_x_m", "estimated_y_m", "estimated_height_m",
                    ])
                    for tag in range(20):
                        writer.writerow([tag, tag, 0, 1, tag + 0.05, 0, 1.02])
                runs.append({
                    "runId": f"field-{index}",
                    "executedAtUnix": 200,
                    "trajectoryMetrics": str(metrics),
                    "tagMeasurements": str(measurements),
                    "deviceEvidence": str(device_evidence),
                })
            plan = root / "field-plan.json"
            write_json(plan, {
                "format": "MarketScannerFieldQualificationPlan",
                "version": 1,
                "executionStatus": "executed_with_independent_ground_truth",
                "thresholdsFrozenAtUnix": 100,
                "releaseManifest": str(release),
                "releaseManifestSha256": sha256(release),
                "siteType": "supermarket",
                "groundTruthMethod": "independent total station controls",
                "independentSurveyor": "test surveyor",
                "thresholds": {
                    "nodeCoverageMin": 0.98,
                    "correctionP95MaxM": 1.0,
                    "correctionMaxM": 2.0,
                    "relativeTranslationResidualP95MaxM": 0.2,
                    "relativeYawResidualP95MaxRad": 0.1,
                    "weakLostDurationRatioMax": 0.1,
                    "tagPlanarP95MaxM": 0.2,
                    "tagPlanarMaxM": 0.3,
                    "tagHeightP95MaxM": 0.1,
                },
                "runs": runs,
            })
            evidence = evaluate_field(plan, root / "field-evidence.json")
            self.assertEqual(evidence["result"], "PASS")
            self.assertEqual(len(evidence["runs"]), 3)


if __name__ == "__main__":
    unittest.main()
