from __future__ import annotations

import csv
import hashlib
import json
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest import mock

import tools.Qualification.qualification as qualification

from tools.Qualification.qualification import (
    DEVICE_SCENARIO_ASSERTIONS,
    REQUIRED_DEVICE_SCENARIOS,
    QualificationError,
    _canonical_sha,
    collect_device,
    evaluate_field,
    inspect_field_evidence,
)


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value), encoding="utf-8")


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


class QualificationTests(unittest.TestCase):
    @staticmethod
    def write_tag_measurements(path: Path, count: int = 20) -> None:
        with path.open("w", newline="", encoding="utf-8") as stream:
            writer = csv.writer(stream)
            writer.writerow([
                "tag_id", "truth_x_m", "truth_y_m", "truth_height_m",
                "estimated_x_m", "estimated_y_m", "estimated_height_m",
            ])
            for tag in range(count):
                writer.writerow([tag, tag, 0, 1, tag + 0.05, 0, 1.02])

    def test_tag_measurements_stable_read_rejects_unsafe_inputs(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            valid = root / "tags.csv"
            self.write_tag_measurements(valid)

            link = root / "tags-link.csv"
            link.symlink_to(valid)
            with self.assertRaisesRegex(QualificationError, "unsafe_or_oversized"):
                qualification._read_tag_measurements_with_identity(link)

            with self.assertRaisesRegex(QualificationError, "unsafe_or_oversized"):
                qualification._read_tag_measurements_with_identity(
                    valid, maximum_bytes=10
                )

            invalid = root / "invalid.csv"
            invalid.write_bytes(b"tag_id,truth_x_m\n\xff")
            with self.assertRaisesRegex(QualificationError, "invalid_utf8"):
                qualification._read_tag_measurements_with_identity(invalid)

    def test_tag_measurements_rejects_partial_and_same_size_replacement(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            path = root / "tags.csv"
            self.write_tag_measurements(path)
            real_read = qualification.os.read
            with mock.patch.object(qualification.os, "read", return_value=b""):
                with self.assertRaisesRegex(QualificationError, "partial_read"):
                    qualification._read_tag_measurements_with_identity(path)

            replacement = root / "replacement.csv"
            replacement.write_bytes(b"x" * path.stat().st_size)
            replaced = False

            def replace_after_open(descriptor: int, count: int) -> bytes:
                nonlocal replaced
                if not replaced:
                    replaced = True
                    replacement.replace(path)
                return real_read(descriptor, count)

            with mock.patch.object(
                qualification.os, "read", side_effect=replace_after_open
            ):
                with self.assertRaisesRegex(QualificationError, "changed_during_read"):
                    qualification._read_tag_measurements_with_identity(path)

    def test_windows_evidence_write_skips_unsupported_directory_fsync(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "evidence.json"
            with (
                mock.patch.object(qualification.os, "name", "nt"),
                mock.patch.object(
                    qualification.os,
                    "open",
                    side_effect=AssertionError("Windows must not open a directory"),
                ),
            ):
                qualification._write_json(output, {"result": "PASS"})
            self.assertEqual(
                json.loads(output.read_text(encoding="utf-8")),
                {"result": "PASS"},
            )

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
            quality_policy = root / "factor-graph-quality-policy.json"
            write_json(quality_policy, {
                "format": "MarketScannerFactorGraphQualityPolicy",
                "version": 1,
                "status": "frozen",
                "policy_version": "test-frozen-1",
                "limits": {},
            })
            policy_sha = sha256(quality_policy)
            release_value = {
                "format": "MarketScannerReleaseManifest",
                "version": 2,
                "git_sha": "a" * 40,
                "product_version": "test",
                "factor_graph_quality_policy_sha256": policy_sha,
            }
            release_value["manifest_body_sha256"] = _canonical_sha(release_value)
            write_json(release, release_value)
            topology = "b" * 64
            shelf = "c" * 64
            runs = []
            for index in range(3):
                device_evidence = root / f"device-evidence-{index}.json"
                device_evidence_value = {
                    "format": "MarketScannerDeviceQualificationEvidence",
                    "version": 2,
                    "run": index,
                    "result": "PASS",
                    "blockers": [],
                    "app": {"gitSha": "a" * 40, "buildId": "test-build"},
                    "runs": [{
                        "rawSessionBundleSha256": format(index + 1, "064x"),
                        "rawDatabaseSha256": format(index + 101, "064x"),
                        "trackingSessionId": f"tracking-{index}",
                        "sessionIdentity": {
                            "priorMapId": "prior-test",
                            "priorMapSha256": "d" * 64,
                        },
                    }],
                }
                device_evidence_value["evidenceSha256"] = _canonical_sha(
                    device_evidence_value
                )
                write_json(device_evidence, device_evidence_value)
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
                    "localizedOutput": str(root / f"localized-{index}"),
                    "localizedVersionId": f"v{index + 1:06d}",
                    "localizedVersionManifestSha256": format(
                        index + 201, "064x"
                    ),
                    "tagMeasurements": str(measurements),
                    "deviceEvidence": str(device_evidence),
                })
            plan = root / "field-plan.json"
            write_json(plan, {
                "format": "MarketScannerFieldQualificationPlan",
                "version": 3,
                "executionStatus": "executed_with_independent_ground_truth",
                "thresholdsFrozenAtUnix": 100,
                "releaseManifest": str(release),
                "releaseManifestSha256": sha256(release),
                "qualityPolicy": str(quality_policy),
                "qualityPolicySha256": policy_sha,
                "priorMapId": "prior-test",
                "priorMapSha256": "d" * 64,
                "siteId": "test-supermarket",
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
            def trajectory_evidence(
                _output: Path,
                version_id: str,
                *,
                expected_version_manifest_sha256: str,
                release: dict,
                release_sha256: str,
            ) -> dict:
                index = int(version_id[1:]) - 1
                value = {
                    "format": "MarketScannerTrajectoryQualificationEvidence",
                    "version": 1,
                    "generated_at_utc": "2026-07-30T00:00:00+00:00",
                    "release_git_sha": release["git_sha"],
                    "release_manifest_sha256": release_sha256,
                    "product_version": release["product_version"],
                    "localized_version_id": version_id,
                    "localized_version_manifest_sha256": expected_version_manifest_sha256,
                    "input_identity_id": format(index + 301, "064x"),
                    "session_input_bundle_sha256": format(index + 1, "064x"),
                    "raw_database_sha256": format(index + 101, "064x"),
                    "tracking_session_id": f"tracking-{index}",
                    "prior_map_id": "prior-test",
                    "prior_map_sha256": "d" * 64,
                    "quality_policy_sha256": policy_sha,
                    "quality_policy_version": "test-frozen-1",
                    "nodeCoverage": 0.99,
                    "correctionP95M": 0.5,
                    "correctionMaxM": 1.0,
                    "relativeTranslationResidualP95M": 0.1,
                    "relativeYawResidualP95Rad": 0.05,
                    "weakLostDurationRatio": 0.01,
                    "inventoriesMatch": True,
                    "factorGraphConverged": True,
                    "factorGraphQualityPassed": True,
                    "singleConnectedComponent": True,
                    "allGroundTruthTagsObserved": True,
                    "userConfirmedTagsPreserved": True,
                    "automaticConfirmDuringWeakLost": 0,
                    "topologyDigest": topology,
                    "shelfAssociationDigest": shelf,
                    "localizedTagIds": [str(tag) for tag in range(20)],
                    "localizedTagIdsSha256": _canonical_sha(
                        sorted(str(tag) for tag in range(20))
                    ),
                }
                value["evidenceSha256"] = _canonical_sha(value)
                return value

            with mock.patch.object(
                qualification,
                "_trajectory_evidence_from_version",
                side_effect=trajectory_evidence,
            ):
                evidence = evaluate_field(plan, root / "field-evidence.json")
            self.assertEqual(evidence["result"], "PASS")
            self.assertEqual(len(evidence["runs"]), 3)
            inspected = inspect_field_evidence(root / "field-evidence.json")
            self.assertEqual(inspected["run_count"], 3)

            duplicate_plan = json.loads(plan.read_text(encoding="utf-8"))
            duplicate_plan["runs"][1]["runId"] = duplicate_plan["runs"][0]["runId"]
            write_json(plan, duplicate_plan)
            with mock.patch.object(
                qualification,
                "_trajectory_evidence_from_version",
                side_effect=trajectory_evidence,
            ):
                duplicate = evaluate_field(plan, root / "duplicate-field-evidence.json")
            self.assertEqual(duplicate["result"], "FAIL")
            self.assertIn("duplicate_run_id", ":".join(duplicate["blockers"]))

            one_old_app_plan = json.loads(plan.read_text(encoding="utf-8"))
            one_old_app_plan["runs"][1]["runId"] = "field-1"
            old_device_path = Path(one_old_app_plan["runs"][1]["deviceEvidence"])
            old_device = json.loads(old_device_path.read_text(encoding="utf-8"))
            old_device["app"]["gitSha"] = "b" * 40
            old_device.pop("evidenceSha256")
            old_device["evidenceSha256"] = _canonical_sha(old_device)
            write_json(old_device_path, old_device)
            write_json(plan, one_old_app_plan)
            with mock.patch.object(
                qualification,
                "_trajectory_evidence_from_version",
                side_effect=trajectory_evidence,
            ):
                old_app = evaluate_field(plan, root / "old-app-field-evidence.json")
            self.assertEqual(old_app["result"], "FAIL")
            self.assertIn(
                "device_app_release_sha_mismatch", ":".join(old_app["blockers"])
            )

            old_device["app"]["gitSha"] = "not-a-git-sha"
            old_device.pop("evidenceSha256")
            old_device["evidenceSha256"] = _canonical_sha(old_device)
            write_json(old_device_path, old_device)
            with mock.patch.object(
                qualification,
                "_trajectory_evidence_from_version",
                side_effect=trajectory_evidence,
            ), self.assertRaisesRegex(QualificationError, "device_app_identity_invalid"):
                evaluate_field(plan, root / "malformed-app-field-evidence.json")

            free_form = json.loads(plan.read_text(encoding="utf-8"))
            free_form["runs"][0]["trajectoryMetrics"] = "operator-metrics.json"
            write_json(plan, free_form)
            with self.assertRaisesRegex(
                QualificationError, "free_form_trajectory_metrics_forbidden"
            ):
                evaluate_field(plan, root / "free-form-field-evidence.json")

            tampered = json.loads((root / "field-evidence.json").read_text(encoding="utf-8"))
            tampered["result"] = "FAIL"
            write_json(root / "tampered-field-evidence.json", tampered)
            with self.assertRaisesRegex(QualificationError, "evidence_contract_invalid"):
                inspect_field_evidence(root / "tampered-field-evidence.json")


if __name__ == "__main__":
    unittest.main()
