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
from tools.PriorMap.localized_output_store import REQUIRED_VERSION_FILES

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


def synthetic_trajectory_package(
    index: int,
    *,
    release_sha256: str,
    quality_policy_sha256: str,
) -> tuple[dict[str, object], dict[str, object], str]:
    version_id = f"v{index + 1:06d}"
    input_id = format(index + 301, "064x")
    session_sha = format(index + 1, "064x")
    tracking_id = f"tracking-{index}"
    inventory = {
        "source_count": 20,
        "optimized_count": 20,
        "exported_count": 20,
        "source_missing_from_optimized": [],
        "source_missing_from_export": [],
        "optimized_not_in_source": [],
        "exported_not_in_optimized": [],
        "source_duplicate_ids": [],
        "optimized_duplicate_ids": [],
        "exported_duplicate_ids": [],
        "source_non_monotonic_stamp_node_ids": [],
        "optimized_non_monotonic_stamp_node_ids": [],
    }
    payloads: dict[str, object] = {
        "source_manifest.json": {
            "input_identity_id": input_id,
            "session_input_bundle_sha256": session_sha,
            "source_database_sha256_before": format(index + 101, "064x"),
            "prior_map_id": "prior-test",
            "prior_map_sha256": "d" * 64,
        },
        "processing_manifest.json": {"input_identity_id": input_id},
        "localization_report.json": {
            "input_identity_id": input_id,
            "weak_lost_intervals": [],
            "node_inventory_audit": inventory,
            "localization_state_duration_seconds": {"normal": 99.0, "weak": 1.0},
            "weak_lost_duration_seconds": 1.0,
            "correction_distribution_m": {"p95": 0.5, "maximum": 1.0},
            "node_coverage_ratio": 0.99,
            "aisle_switch_sequence": ["A", "B"],
        },
        "factor_graph_report.json": {
            "input_identity_id": input_id,
            "quality_policy": {
                "policy_sha256": quality_policy_sha256,
                "policy_version": "test-frozen-1",
            },
            "p95_relative_edge_translation_residual_m": 0.1,
            "p95_relative_edge_yaw_residual_deg": 2.864788975654116,
            "converged": True,
            "solver_converged": True,
            "graph_quality_passed": True,
            "graph_connected": True,
        },
        "localized_price_tags.json": [
            {
                "tag_id": str(tag),
                "tracking_session_id": tracking_id,
                "transform_audit": {"status": "applied"},
                "user_confirmed": False,
                "approval_status": "approved",
                "needs_review": False,
                "association_audit": {"status": "confirmed"},
                "shelf_code": "shelf-A",
                "shelf_side": "left",
                "distance_from_shelf_start_cm": tag * 10,
                "timestamp": float(tag),
            }
            for tag in range(20)
        ],
    }
    artifacts = {
        name: json.dumps(value, sort_keys=True).encode("utf-8")
        for name, value in payloads.items()
    }
    files = [
        {"file": name, "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}
        for name, data in artifacts.items()
    ]
    files.append(
        {
            "file": "optimized_map_trajectory.geojson",
            "bytes": 1,
            "sha256": "f" * 64,
        }
    )
    represented = {entry["file"] for entry in files}
    files.extend(
        {
            "file": name,
            "bytes": 0,
            "sha256": hashlib.sha256(b"").hexdigest(),
        }
        for name in REQUIRED_VERSION_FILES
        if name not in represented
    )
    manifest = {
        "format": "MarketScannerLocalizedVersionManifest",
        "version": 3,
        "version_id": version_id,
        "state": "review",
        "revision": 1,
        "input_identity_id": input_id,
        "session_input_bundle_sha256": session_sha,
        "files": files,
    }
    manifest_bytes = json.dumps(manifest, sort_keys=True).encode("utf-8")
    manifest_sha = hashlib.sha256(manifest_bytes).hexdigest()
    identity = qualification._TrajectoryVersionIdentity(
        version_id=version_id,
        manifest_sha256=manifest_sha,
        input_identity_id=input_id,
        session_input_bundle_sha256=session_sha,
    )
    evidence = qualification._derive_trajectory_evidence(
        identity,
        artifacts,
        "f" * 64,
        release={
            "git_sha": "a" * 40,
            "product_version": "test",
            "factor_graph_quality_policy_sha256": quality_policy_sha256,
        },
        release_sha256=release_sha256,
        generated_at_utc="2026-07-30T00:00:00+00:00",
    )
    bundle = qualification._trajectory_bundle_from_verified_bytes(
        manifest_bytes, artifacts
    )
    return evidence, bundle, manifest_sha


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

    def test_stable_read_accepts_windows_path_handle_stat_representation(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "evidence.json"
            path.write_bytes(b'{"result":"PASS"}\n')
            real_fstat = qualification.os.fstat

            def windows_fstat(descriptor: int) -> mock.Mock:
                actual = real_fstat(descriptor)
                represented = mock.Mock()
                represented.st_mode = actual.st_mode
                represented.st_size = actual.st_size
                represented.st_nlink = actual.st_nlink
                represented.st_dev = actual.st_dev + 1
                represented.st_ino = actual.st_ino + 1
                represented.st_ctime_ns = actual.st_ctime_ns + 100
                represented.st_mtime_ns = actual.st_mtime_ns + 100
                return represented

            with mock.patch.object(
                qualification.os, "fstat", side_effect=windows_fstat
            ):
                data, digest, size, _identity = qualification._read_stable_bytes(
                    path,
                    maximum_bytes=1024,
                    label="evidence",
                )

            self.assertEqual(data, path.read_bytes())
            self.assertEqual(digest, hashlib.sha256(data).hexdigest())
            self.assertEqual(size, len(data))

    def test_stable_read_requests_binary_descriptors_when_available(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "evidence.json"
            path.write_bytes(b'{"line":"one\r\ntwo"}\r\n')
            real_open = qualification.os.open
            binary_flag = 1 << 29
            observed_flags: list[int] = []

            def binary_aware_open(target: object, flags: int) -> int:
                observed_flags.append(flags)
                return real_open(target, flags & ~binary_flag)

            with (
                mock.patch.object(
                    qualification.os, "O_BINARY", binary_flag, create=True
                ),
                mock.patch.object(
                    qualification.os, "open", side_effect=binary_aware_open
                ),
            ):
                data, _digest, _size, _identity = qualification._read_stable_bytes(
                    path,
                    maximum_bytes=1024,
                    label="evidence",
                )

            self.assertEqual(data, path.read_bytes())
            self.assertGreaterEqual(len(observed_flags), 3)
            self.assertTrue(all(flags & binary_flag for flags in observed_flags))

    def test_stable_read_rejects_transient_same_size_swap_and_restore(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            path = root / "evidence.json"
            original = b'{"result":"PASS","source":"trusted"}\n'
            replacement = b'{"result":"PASS","source":"forged!"}\n'
            self.assertEqual(len(original), len(replacement))
            path.write_bytes(original)
            forged = root / "forged.json"
            forged.write_bytes(replacement)
            parked = root / "parked.json"
            real_open = qualification.os.open
            real_read = qualification.os.read
            first_open = True
            restored = False

            def swap_before_read_open(target: object, flags: int) -> int:
                nonlocal first_open
                if first_open and Path(target) == path:
                    first_open = False
                    path.replace(parked)
                    forged.replace(path)
                return real_open(target, flags)

            def restore_original(descriptor: int, count: int) -> bytes:
                nonlocal restored
                if not restored:
                    restored = True
                    path.replace(forged)
                    parked.replace(path)
                return real_read(descriptor, count)

            with (
                mock.patch.object(
                    qualification.os, "open", side_effect=swap_before_read_open
                ),
                mock.patch.object(
                    qualification.os, "read", side_effect=restore_original
                ),
            ):
                with self.assertRaisesRegex(
                    QualificationError, "changed_during_read"
                ):
                    qualification._read_stable_bytes(
                        path,
                        maximum_bytes=1024,
                        label="evidence",
                    )

            # Windows denies replacing an open file before the identity checks;
            # restore the adversarial fixture after the main descriptor closes.
            if parked.exists():
                path.replace(forged)
                parked.replace(path)
            self.assertEqual(path.read_bytes(), original)

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
            release_sha = sha256(release)
            trajectory_packages = [
                synthetic_trajectory_package(
                    index,
                    release_sha256=release_sha,
                    quality_policy_sha256=policy_sha,
                )
                for index in range(3)
            ]
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
                    "localizedVersionManifestSha256": trajectory_packages[index][2],
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
            def trajectory_evidence_and_bundle(
                _output: Path,
                version_id: str,
                *,
                expected_version_manifest_sha256: str,
                release: dict,
                release_sha256: str,
            ) -> tuple[dict[str, object], dict[str, object]]:
                index = int(version_id[1:]) - 1
                self.assertEqual(release["git_sha"], "a" * 40)
                self.assertEqual(release_sha256, release_sha)
                self.assertEqual(
                    expected_version_manifest_sha256,
                    trajectory_packages[index][2],
                )
                return trajectory_packages[index][0], trajectory_packages[index][1]

            with mock.patch.object(
                qualification,
                "_trajectory_evidence_and_bundle_from_version",
                side_effect=trajectory_evidence_and_bundle,
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
                "_trajectory_evidence_and_bundle_from_version",
                side_effect=trajectory_evidence_and_bundle,
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
                "_trajectory_evidence_and_bundle_from_version",
                side_effect=trajectory_evidence_and_bundle,
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
                "_trajectory_evidence_and_bundle_from_version",
                side_effect=trajectory_evidence_and_bundle,
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

            for name, forged_value in (
                ("nodeCoverage", -999.0),
                ("factorGraphQualityPassed", False),
            ):
                forged = json.loads(
                    (root / "field-evidence.json").read_text(encoding="utf-8")
                )
                trajectory = forged["runs"][0]["trajectoryEvidence"]
                trajectory[name] = forged_value
                trajectory.pop("evidenceSha256")
                trajectory["evidenceSha256"] = _canonical_sha(trajectory)
                forged.pop("evidenceSha256")
                forged["evidenceSha256"] = _canonical_sha(forged)
                forged_path = root / f"forged-{name}.json"
                write_json(forged_path, forged)
                with self.assertRaisesRegex(
                    QualificationError,
                    "trajectory_evidence_differs_from_source_bundle",
                ):
                    inspect_field_evidence(forged_path)

            forged_tags = json.loads(
                (root / "field-evidence.json").read_text(encoding="utf-8")
            )
            metrics = forged_tags["runs"][0]["independentTagMetrics"]
            for name in (
                "planarP50M",
                "planarP95M",
                "planarMaxM",
                "heightP95M",
                "heightMaxM",
            ):
                metrics[name] = 0.0
            forged_tags.pop("evidenceSha256")
            forged_tags["evidenceSha256"] = _canonical_sha(forged_tags)
            forged_tags_path = root / "forged-tag-metrics.json"
            write_json(forged_tags_path, forged_tags)
            with self.assertRaisesRegex(
                QualificationError,
                "field_run_inputs_differ_from_summaries",
            ):
                inspect_field_evidence(forged_tags_path)

            forged_thresholds = json.loads(
                (root / "field-evidence.json").read_text(encoding="utf-8")
            )
            forged_thresholds["thresholds"]["nodeCoverageMin"] = -999.0
            forged_thresholds.pop("evidenceSha256")
            forged_thresholds["evidenceSha256"] = _canonical_sha(
                forged_thresholds
            )
            forged_thresholds_path = root / "forged-thresholds.json"
            write_json(forged_thresholds_path, forged_thresholds)
            with self.assertRaisesRegex(
                QualificationError,
                "qualification_sources_differ_from_field_evidence",
            ):
                inspect_field_evidence(forged_thresholds_path)


if __name__ == "__main__":
    unittest.main()
