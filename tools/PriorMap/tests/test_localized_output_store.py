from __future__ import annotations

import ast
import csv
import hashlib
import json
import multiprocessing
import os
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

import tools.PriorMap.localized_file_lock as localized_file_lock
import tools.PriorMap.localized_output_store as localized_store
import tools.Qualification.qualification as qualification

from tools.PriorMap.localized_file_lock import (
    FileLockError,
    PosixFileLock,
    WindowsFileLock,
    select_file_lock_backend,
)
from tools.PriorMap.localized_output_store import (
    LocalizedStoreError,
    LocalizedVersionStore,
    REQUIRED_VERSION_FILES,
    local_input_identity_id,
)
from tools.Qualification.qualification import (
    QualificationError,
    build_trajectory_qualification_evidence,
)


def _canonical_sha(value: object) -> str:
    return hashlib.sha256(
        json.dumps(value, sort_keys=True, separators=(",", ":")).encode("utf-8")
    ).hexdigest()


def _synthetic_trajectory_package(
    index: int,
    *,
    release_manifest_sha256: str,
    release_git_sha: str,
    product_version: str,
    prior_map_sha256: str,
    quality_policy_sha256: str,
) -> tuple[dict[str, object], dict[str, object]]:
    version_id = f"v{index + 1:06d}"
    input_id = format(index + 20, "064x")
    session_sha = format(index + 30, "064x")
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
            "source_database_sha256_before": format(index + 40, "064x"),
            "prior_map_id": "prior-test",
            "prior_map_sha256": prior_map_sha256,
        },
        "processing_manifest.json": {"input_identity_id": input_id},
        "localization_report.json": {
            "input_identity_id": input_id,
            "weak_lost_intervals": [],
            "node_inventory_audit": inventory,
            "localization_state_duration_seconds": {"normal": 100.0},
            "weak_lost_duration_seconds": 0.0,
            "correction_distribution_m": {"p95": 0.1, "maximum": 0.2},
            "node_coverage_ratio": 1.0,
            "aisle_switch_sequence": ["A", "B"],
        },
        "factor_graph_report.json": {
            "input_identity_id": input_id,
            "quality_policy": {
                "policy_sha256": quality_policy_sha256,
                "policy_version": "test-frozen-1",
            },
            "p95_relative_edge_translation_residual_m": 0.01,
            "p95_relative_edge_yaw_residual_deg": 0.5729577951308232,
            "converged": True,
            "solver_converged": True,
            "graph_quality_passed": True,
            "graph_connected": True,
        },
        "localized_price_tags.json": [
            {
                "tag_id": f"tag-{tag}",
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
    trajectory = qualification._derive_trajectory_evidence(
        identity,
        artifacts,
        "f" * 64,
        release={
            "git_sha": release_git_sha,
            "product_version": product_version,
            "factor_graph_quality_policy_sha256": quality_policy_sha256,
        },
        release_sha256=release_manifest_sha256,
        generated_at_utc="2026-07-30T00:00:00+00:00",
    )
    bundle = qualification._trajectory_bundle_from_verified_bytes(
        manifest_bytes, artifacts
    )
    return trajectory, bundle


def write_valid_field_evidence(
    path: Path,
    *,
    release_manifest_sha256: str,
    release_git_sha: str,
    product_version: str,
    prior_map_sha256: str,
    quality_policy_sha256: str,
) -> tuple[str, dict[str, object]]:
    runs: list[dict[str, object]] = []
    for index in range(3):
        trajectory, trajectory_source_bundle = _synthetic_trajectory_package(
            index,
            release_manifest_sha256=release_manifest_sha256,
            release_git_sha=release_git_sha,
            product_version=product_version,
            prior_map_sha256=prior_map_sha256,
            quality_policy_sha256=quality_policy_sha256,
        )
        runs.append(
            {
                "runId": f"run-{index}",
                "executedAtUnix": 200 + index,
                "sourceSessionIdentity": {
                    "rawSessionBundleSha256": trajectory[
                        "session_input_bundle_sha256"
                    ],
                    "rawDatabaseSha256": trajectory["raw_database_sha256"],
                    "trackingSessionId": trajectory["tracking_session_id"],
                },
                "trajectoryEvidence": trajectory,
                "trajectorySourceBundle": trajectory_source_bundle,
                "independentTagMetrics": {
                    "count": 20,
                    "planarP50M": 0.01,
                    "planarP95M": 0.02,
                    "planarMaxM": 0.03,
                    "heightP95M": 0.02,
                    "heightMaxM": 0.03,
                },
                "releaseGitSha": release_git_sha,
                "deviceAppGitSha": release_git_sha,
                "deviceAppBuildId": "test-build",
                "deviceEvidenceIdentity": {
                    "format": "MarketScannerDeviceQualificationEvidence",
                    "version": 2,
                    "result": "PASS",
                    "appGitSha": release_git_sha,
                    "appBuildId": "test-build",
                    "evidenceBodySha256": "c" * 64,
                    "fileSha256": "d" * 64,
                },
                "inputFiles": [],
                "blockers": [],
                "result": "PASS",
            }
        )
    evidence: dict[str, object] = {
        "format": "MarketScannerFieldQualificationEvidence",
        "version": 3,
        "sourcePlanSha256": "9" * 64,
        "releaseManifest": {
            "name": "release-manifest.json",
            "bytes": 1,
            "sha256": release_manifest_sha256,
            "gitSha": release_git_sha,
            "productVersion": product_version,
            "manifestBodySha256": "8" * 64,
        },
        "qualityPolicy": {
            "name": "quality-policy.json",
            "bytes": 1,
            "sha256": quality_policy_sha256,
            "policyVersion": "test-frozen-1",
            "status": "frozen",
        },
        "priorMapIdentity": {
            "priorMapId": "prior-test",
            "priorMapSha256": prior_map_sha256,
        },
        "thresholdsFrozenAtUnix": 100,
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
        "siteId": "store-test",
        "siteType": "supermarket",
        "groundTruthMethod": "independent controls",
        "independentSurveyor": "test surveyor",
        "runs": runs,
        "blockers": [],
        "result": "PASS",
    }
    evidence["evidenceSha256"] = _canonical_sha(evidence)
    data = json.dumps(evidence, indent=2, sort_keys=True).encode("utf-8") + b"\n"
    path.write_bytes(data)
    return hashlib.sha256(data).hexdigest(), evidence


def _hold_store_lock(
    output_path: str,
    ready_connection: object,
    release_event: object,
) -> None:
    """Spawn-safe worker that holds the store's native lock until released."""

    store = LocalizedVersionStore(
        Path(output_path), lock_timeout_seconds=5.0
    )
    store._acquire_lock()
    ready_connection.send(".write.lock")  # type: ignore[attr-defined]
    ready_connection.close()  # type: ignore[attr-defined]
    release_event.wait(10.0)  # type: ignore[attr-defined]
    store._release_lock()


class LocalizedFileLockTests(unittest.TestCase):
    def test_backend_selection_is_explicit_and_rejects_thread_fallback(self) -> None:
        self.assertIs(select_file_lock_backend("posix"), PosixFileLock)
        self.assertIs(select_file_lock_backend("nt"), WindowsFileLock)
        with self.assertRaisesRegex(FileLockError, "Unsupported"):
            select_file_lock_backend("java")

    def test_platform_only_lock_modules_are_lazily_imported(self) -> None:
        source = Path(localized_file_lock.__file__).read_text(encoding="utf-8")
        tree = ast.parse(source)
        top_level_imports = {
            alias.name
            for node in tree.body
            if isinstance(node, ast.Import)
            for alias in node.names
        }
        top_level_imports.update(
            node.module
            for node in tree.body
            if isinstance(node, ast.ImportFrom) and node.module is not None
        )
        self.assertNotIn("fcntl", top_level_imports)
        self.assertNotIn("msvcrt", top_level_imports)

    def test_same_output_root_is_excluded_across_processes_with_timeout(self) -> None:
        context = multiprocessing.get_context("spawn")
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "output"
            parent_connection, child_connection = context.Pipe(duplex=False)
            release_event = context.Event()
            holder = context.Process(
                target=_hold_store_lock,
                args=(str(output), child_connection, release_event),
            )
            holder.start()
            child_connection.close()
            try:
                self.assertTrue(parent_connection.poll(10.0))
                self.assertEqual(parent_connection.recv(), ".write.lock")
                contender = LocalizedVersionStore(
                    output,
                    lock_timeout_seconds=0.25,
                    lock_poll_interval_seconds=0.01,
                )
                started = time.monotonic()
                with self.assertRaisesRegex(
                    LocalizedStoreError,
                    r"Timed out.*exclusive .* lock.*requesting_pid=",
                ):
                    contender.prepare()
                elapsed = time.monotonic() - started
                self.assertGreaterEqual(elapsed, 0.20)
                self.assertLess(elapsed, 2.0)
            finally:
                release_event.set()
                holder.join(10.0)
                if holder.is_alive():
                    holder.terminate()
                    holder.join(5.0)
                parent_connection.close()
            self.assertEqual(holder.exitcode, 0)

    def test_process_termination_releases_os_lock(self) -> None:
        context = multiprocessing.get_context("spawn")
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "output"
            parent_connection, child_connection = context.Pipe(duplex=False)
            release_event = context.Event()
            holder = context.Process(
                target=_hold_store_lock,
                args=(str(output), child_connection, release_event),
            )
            holder.start()
            child_connection.close()
            try:
                self.assertTrue(parent_connection.poll(10.0))
                self.assertEqual(parent_connection.recv(), ".write.lock")
            finally:
                parent_connection.close()
            holder.terminate()
            holder.join(10.0)
            self.assertFalse(holder.is_alive())
            self.assertNotEqual(holder.exitcode, 0)

            store = LocalizedVersionStore(output, lock_timeout_seconds=2.0)
            store._acquire_lock()
            try:
                self.assertIsNotNone(store._lock_handle)
            finally:
                store._release_lock()


class LocalizedPlatformPersistenceTests(unittest.TestCase):
    def test_windows_file_flush_uses_a_writable_descriptor(self) -> None:
        artifact = Path("artifact.json")
        handle = mock.MagicMock()
        handle.__enter__.return_value.fileno.return_value = 73
        with (
            mock.patch.object(localized_store.os, "name", "nt"),
            mock.patch.object(Path, "open", return_value=handle) as open_file,
            mock.patch.object(localized_store.os, "fsync") as fsync,
        ):
            localized_store._fsync_file(artifact)
        open_file.assert_called_once_with("r+b")
        fsync.assert_called_once_with(73)

    def test_windows_replacement_uses_write_through_backend(self) -> None:
        source = Path("source.tmp")
        destination = Path("destination.json")
        with (
            mock.patch.object(localized_store.os, "name", "nt"),
            mock.patch.object(localized_store, "_atomic_replace_windows") as replace,
        ):
            localized_store._atomic_replace(source, destination)
        replace.assert_called_once_with(source, destination)

    def test_windows_does_not_attempt_unsupported_directory_flush(self) -> None:
        with (
            mock.patch.object(localized_store.os, "name", "nt"),
            mock.patch.object(localized_store.os, "open") as open_directory,
        ):
            localized_store._fsync_directory(Path("localized"))
        open_directory.assert_not_called()


class LocalizedVersionStoreTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.output = Path(self.temporary.name) / "output"
        self.store = LocalizedVersionStore(self.output)
        self.session_input_files = [
            {
                "role": role,
                "file": file_name,
                "bytes": 0,
                "sha256": "b" * 64 if role == "source_database" else "f" * 64,
            }
            for role, file_name in (
                ("metadata", "metadata.json"),
                ("source_database", "source.db"),
                ("localization_trace.jsonl", "localization_trace.jsonl"),
                ("localization_constraints.jsonl", "localization_constraints.jsonl"),
                ("localization_events.jsonl", "localization_events.jsonl"),
                ("manual_localization_events.jsonl", "manual_localization_events.jsonl"),
                ("tag_observations.jsonl", "tag_observations.jsonl"),
                ("localized_price_tags.json", "localized_price_tags.json"),
            )
        ]
        session_bundle = hashlib.sha256(
            json.dumps(
                {
                    "format": "MarketScannerLocalizedInputManifest",
                    "version": 1,
                    "source_database_sha256": "b" * 64,
                    "files": self.session_input_files,
                },
                sort_keys=True,
                separators=(",", ":"),
            ).encode("utf-8")
        ).hexdigest()
        self.identity_hashes = {
            "session_input_bundle_sha256": session_bundle,
            "source_database_sha256": "b" * 64,
            "optimized_database_sha256": "c" * 64,
            "prior_map_sha256": "d" * 64,
            "processing_parameter_sha256": "e" * 64,
        }
        self.local_input_record = {
            "format": "MarketScannerLocalizedLocalInputs",
            "version": 1,
            "paths": {
                "source_session": "/test/session",
                "source_database": "/test/source.db",
                "optimized_database": "/test/optimized.db",
                "prior_map": "/test/prior-map",
            },
            "identities": self.identity_hashes,
        }
        self.input_identity_id = local_input_identity_id(self.local_input_record)
        self.local_input_record["input_identity_id"] = self.input_identity_id

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def write_valid_staging(
        self, *, revision: int = 1, state: str = "draft"
    ) -> Path:
        staging = self.store.begin()
        json_payloads: dict[str, object] = {
            "prior_map_manifest.json": {"format": "MarketScannerPriorMap", "version": 1},
            "source_manifest.json": {
                "format": "MarketScannerLocalizedSourceManifest",
                "version": 2,
                "input_identity_id": self.input_identity_id,
                "session_input_bundle_sha256": self.identity_hashes[
                    "session_input_bundle_sha256"
                ],
                "source_database_sha256_before": self.identity_hashes[
                    "source_database_sha256"
                ],
                "optimized_database_sha256": self.identity_hashes[
                    "optimized_database_sha256"
                ],
                "prior_map_sha256": self.identity_hashes["prior_map_sha256"],
                "prior_map_id": "prior-test",
            },
            "processing_manifest.json": {
                "format": "MarketScannerLocalizedProcessing",
                "version": 2,
                "publish_state": state,
                "input_identity_id": self.input_identity_id,
                "factor_graph_quality_policy_sha256": "e" * 64,
                "factor_graph_quality_policy_version": "test-frozen-1",
                **self.identity_hashes,
            },
            "session_input_manifest.json": {
                "format": "MarketScannerLocalizedInputManifest",
                "version": 1,
                "source_database_sha256": self.identity_hashes[
                    "source_database_sha256"
                ],
                "bundle_sha256": self.identity_hashes[
                    "session_input_bundle_sha256"
                ],
                "input_identity_id": self.input_identity_id,
                "files": self.session_input_files,
            },
            "online_localization_trace.json": [],
            "optimized_map_trajectory.geojson": {
                "type": "FeatureCollection",
                "features": [],
            },
            "localization_constraints.json": {
                "format": "MarketScannerOfflineLocalizationConstraints",
                "version": 1,
            },
            "localization_report.json": {
                "format": "MarketScannerLocalizationReport",
                "version": 1,
                "publish_state": state,
                "publish_gate": {"passed": True, "blockers": []},
                "solver": {
                    "type": "relative_se2_factor_graph",
                    "full_factor_graph": True,
                    "published_capable": True,
                    "graph_quality_passed": True,
                    "factor_set_sha256": "d" * 64,
                },
            },
            "factor_graph_report.json": {
                "format": "MarketScannerRelativeSE2FactorGraphReport",
                "version": 2,
                "solver": "rtabmap_g2o_slam2d",
                "full_factor_graph": True,
                "published_capable": True,
                "converged": True,
                "solver_converged": True,
                "graph_integrity_passed": True,
                "graph_quality_passed": True,
                "quality_policy": {
                    "policy_sha256": "e" * 64,
                    "policy_version": "test-frozen-1",
                    "policy_status": "frozen",
                    "passed": True,
                    "blockers": [],
                },
                "factor_set_sha256": "d" * 64,
                "input_identity_id": self.input_identity_id,
                "optimized_database_sha256": self.identity_hashes[
                    "optimized_database_sha256"
                ],
            },
            "review_items.json": {
                "format": "MarketScannerLocalizationReviewItems", "version": 1, "items": []
            },
            "localized_review.json": {
                "format": "MarketScannerLocalizedReview", "version": 1
            },
            "manual_edits.json": {
                "format": "MarketScannerManualEdits", "version": 4,
                "revision": revision, "events": [], "cursor": 0,
                "input_identity_id": self.input_identity_id,
                **self.identity_hashes,
            },
            "localized_price_tags.json": [],
            "localized_price_tags.geojson": {
                "type": "FeatureCollection",
                "features": [],
            },
            "shelf_tag_index.json": {
                "format": "MarketScannerShelfTagIndex", "version": 1, "shelves": {}
            },
        }
        for name, payload in json_payloads.items():
            (staging / name).write_text(
                json.dumps(payload, sort_keys=True) + "\n", encoding="utf-8"
            )
        with (staging / "localized_price_tags.csv").open(
            "w", encoding="utf-8", newline=""
        ) as handle:
            writer = csv.DictWriter(handle, fieldnames=["tag_id", "approval_status"])
            writer.writeheader()
        (staging / "audit_log.jsonl").write_text(
            '{"event":"test"}\n', encoding="utf-8"
        )
        self.assertEqual(
            set(REQUIRED_VERSION_FILES),
            {path.name for path in staging.iterdir()},
        )
        return staging

    def commit_valid(
        self, *, revision: int = 1, state: str = "draft", update_current: bool = True
    ):
        staging = self.write_valid_staging(revision=revision, state=state)
        manifest = self.store.validate_staging(staging, parent_version=None)
        return self.store.commit(
            staging,
            manifest,
            update_current=update_current,
            local_input_record=self.local_input_record,
        )

    def commit_qualification_version(self, *, quality_sha: str = "e" * 64):
        staging = self.write_valid_staging(state="review")
        report_path = staging / "localization_report.json"
        report = json.loads(report_path.read_text(encoding="utf-8"))
        report.update(
            {
                "input_identity_id": self.input_identity_id,
                "node_coverage_ratio": 1.0,
                "node_inventory_audit": {
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
                },
                "correction_distribution_m": {
                    "p95": 0.1,
                    "maximum": 0.2,
                },
                "localization_state_duration_seconds": {
                    "normal": 100.0,
                    "weak": 0.0,
                    "lost": 0.0,
                },
                "weak_lost_duration_seconds": 0.0,
                "weak_lost_intervals": [],
                "aisle_switch_sequence": [],
            }
        )
        report_path.write_text(json.dumps(report) + "\n", encoding="utf-8")
        factor_path = staging / "factor_graph_report.json"
        factor = json.loads(factor_path.read_text(encoding="utf-8"))
        factor.update(
            {
                "graph_connected": True,
                "p95_relative_edge_translation_residual_m": 0.01,
                "p95_relative_edge_yaw_residual_deg": 0.5,
            }
        )
        factor["quality_policy"]["policy_sha256"] = quality_sha
        factor_path.write_text(json.dumps(factor) + "\n", encoding="utf-8")
        processing_path = staging / "processing_manifest.json"
        processing = json.loads(processing_path.read_text(encoding="utf-8"))
        processing["factor_graph_quality_policy_sha256"] = quality_sha
        processing_path.write_text(json.dumps(processing) + "\n", encoding="utf-8")
        tags = []
        features = []
        for index in range(20):
            tag_id = f"tag-{index}"
            tags.append(
                {
                    "tag_id": tag_id,
                    "tracking_session_id": "tracking-test",
                    "timestamp": float(index),
                    "user_confirmed": True,
                    "approval_status": "approved",
                    "needs_review": False,
                    "shelf_code": "shelf-a",
                    "shelf_side": "edge-a",
                    "distance_from_shelf_start_cm": float(index),
                    "final_map_position": {"x_m": float(index), "y_m": 0.0},
                    "transform_audit": {"status": "applied"},
                    "association_audit": {"status": "human_confirmed"},
                }
            )
            features.append(
                {
                    "type": "Feature",
                    "geometry": {
                        "type": "Point",
                        "coordinates": [float(index), 0.0],
                    },
                    "properties": {"tag_id": tag_id},
                }
            )
        (staging / "localized_price_tags.json").write_text(
            json.dumps(tags) + "\n", encoding="utf-8"
        )
        (staging / "localized_price_tags.geojson").write_text(
            json.dumps({"type": "FeatureCollection", "features": features}) + "\n",
            encoding="utf-8",
        )
        with (staging / "localized_price_tags.csv").open(
            "w", encoding="utf-8", newline=""
        ) as handle:
            writer = csv.DictWriter(handle, fieldnames=["tag_id", "approval_status"])
            writer.writeheader()
            for tag in tags:
                writer.writerow(
                    {"tag_id": tag["tag_id"], "approval_status": "approved"}
                )
        manifest = self.store.validate_staging(staging, parent_version=None)
        return self.store.commit(
            staging,
            manifest,
            update_current=True,
            local_input_record=self.local_input_record,
        )

    def test_failed_validation_leaves_current_unchanged(self) -> None:
        first = self.commit_valid()
        staging = self.write_valid_staging(revision=2)
        (staging / "localized_review.json").unlink()
        with self.assertRaises(LocalizedStoreError):
            self.store.validate_staging(staging, parent_version=first.version_id)
        self.store.abort(staging)
        current = self.store.current()
        self.assertIsNotNone(current)
        assert current is not None
        self.assertEqual(current.version_id, first.version_id)
        self.assertTrue(first.version_dir.is_dir())

    def test_trajectory_evidence_is_derived_from_verified_version(self) -> None:
        snapshot = self.commit_qualification_version()
        release_path = self.output / "release-manifest.json"
        release: dict[str, object] = {
            "format": "MarketScannerReleaseManifest",
            "version": 2,
            "git_sha": "a" * 40,
            "product_version": "test",
            "factor_graph_quality_policy_sha256": "e" * 64,
        }
        release["manifest_body_sha256"] = _canonical_sha(release)
        release_path.write_text(json.dumps(release), encoding="utf-8")
        output = self.output / "trajectory-evidence.json"
        evidence = build_trajectory_qualification_evidence(
            self.output,
            snapshot.version_id,
            snapshot.manifest_sha256,
            release_path,
            output,
        )
        self.assertEqual(
            evidence["format"],
            "MarketScannerTrajectoryQualificationEvidence",
        )
        self.assertEqual(evidence["localized_version_id"], snapshot.version_id)
        self.assertEqual(
            evidence["localized_version_manifest_sha256"],
            snapshot.manifest_sha256,
        )
        self.assertTrue(evidence["factorGraphQualityPassed"])
        self.assertEqual(evidence["automaticConfirmDuringWeakLost"], 0)

        manifest_path = snapshot.version_dir / "version_manifest.json"
        manifest_path.write_bytes(manifest_path.read_bytes() + b" ")
        with self.assertRaisesRegex(
            QualificationError, "localized_version_manifest_sha_mismatch"
        ):
            build_trajectory_qualification_evidence(
                self.output,
                snapshot.version_id,
                snapshot.manifest_sha256,
                release_path,
                self.output / "tampered-trajectory-evidence.json",
            )

    def test_trajectory_evidence_rejects_release_quality_identity_mismatch(self) -> None:
        snapshot = self.commit_qualification_version(quality_sha="f" * 64)
        release_path = self.output / "release-manifest.json"
        release: dict[str, object] = {
            "format": "MarketScannerReleaseManifest",
            "version": 2,
            "git_sha": "a" * 40,
            "product_version": "test",
            "factor_graph_quality_policy_sha256": "e" * 64,
        }
        release["manifest_body_sha256"] = _canonical_sha(release)
        release_path.write_text(json.dumps(release), encoding="utf-8")
        with self.assertRaisesRegex(
            QualificationError, "trajectory_evidence_identity_mismatch"
        ):
            build_trajectory_qualification_evidence(
                self.output,
                snapshot.version_id,
                snapshot.manifest_sha256,
                release_path,
                self.output / "trajectory-evidence.json",
            )

    def test_new_version_is_immutable_and_pointer_switch_is_atomic(self) -> None:
        first = self.commit_valid()
        first_report = (first.version_dir / "localization_report.json").read_bytes()
        staging = self.write_valid_staging(revision=2, state="review")
        manifest = self.store.validate_staging(
            staging, parent_version=first.version_id
        )
        second = self.store.commit(staging, manifest, update_current=True)
        current = self.store.current()
        self.assertIsNotNone(current)
        assert current is not None
        self.assertEqual(current.version_id, second.version_id)
        self.assertEqual(current.revision, 2)
        self.assertEqual(
            (first.version_dir / "localization_report.json").read_bytes(),
            first_report,
        )

    def test_invalid_diagnostic_version_never_becomes_current(self) -> None:
        diagnostic = self.commit_valid(state="invalid", update_current=False)
        self.assertEqual(diagnostic.state, "invalid")
        self.assertIsNone(self.store.current())
        self.assertTrue(diagnostic.version_dir.is_dir())

    def test_stale_staging_is_recovered_and_corrupt_pointer_fails_closed(self) -> None:
        self.store.root.mkdir(parents=True)
        stale = self.store.root / ".staging-abandoned"
        stale.mkdir()
        (stale / "partial.json").write_text("{}", encoding="utf-8")
        self.store.prepare()
        self.assertFalse(stale.exists())
        snapshot = self.commit_valid()
        pointer = self.store.root / "current.json"
        payload = json.loads(pointer.read_text(encoding="utf-8"))
        payload["revision"] = snapshot.revision + 1
        pointer.write_text(json.dumps(payload), encoding="utf-8")
        with self.assertRaises(LocalizedStoreError):
            self.store.current()

    def test_state_transitions_create_new_versions_and_publication_audit(self) -> None:
        draft = self.commit_valid()
        review = self.store.transition_current(
            "review", actor="reviewer", reason="quality checks complete"
        )
        self.assertNotEqual(review.version_id, draft.version_id)
        self.assertEqual(review.state, "review")
        self.assertEqual(
            json.loads(
                (review.version_dir / "localization_report.json").read_text()
            )["publish_state"],
            "review",
        )
        evidence_path = self.output / "field-evidence.json"
        evidence_sha, _evidence = write_valid_field_evidence(
            evidence_path,
            release_manifest_sha256="2" * 64,
            release_git_sha="3" * 40,
            product_version="test",
            prior_map_sha256=self.identity_hashes["prior_map_sha256"],
            quality_policy_sha256="e" * 64,
        )
        release_identity = {
            "release_manifest_sha256": "2" * 64,
            "git_sha": "3" * 40,
            "product_version": "test",
            "quality_policy_sha256": "e" * 64,
        }
        published = self.store.publish_current(
            actor="publisher",
            reason="explicit approval",
            qualification_evidence_path=evidence_path,
            expected_field_evidence_sha256=evidence_sha,
            expected_release_identity=release_identity,
        )
        self.assertEqual(published.state, "published")
        self.assertEqual(self.store.published(), published)
        self.assertEqual(self.store.current(), review)
        embedded = published.version_dir / "field_evidence.json"
        self.assertEqual(embedded.read_bytes(), evidence_path.read_bytes())
        self.assertTrue(
            (published.version_dir / "qualification_manifest.json").is_file()
        )
        evidence_path.unlink()
        self.assertEqual(self.store.published(), published)
        evidence_path.write_text('{"external":"changed"}\n', encoding="utf-8")
        self.assertEqual(self.store.published(), published)
        with self.assertRaisesRegex(LocalizedStoreError, "already exists"):
            self.store.publish_current(
                actor="publisher",
                reason="duplicate publication must fail",
                qualification_evidence_path=evidence_path,
                expected_field_evidence_sha256=evidence_sha,
                expected_release_identity=release_identity,
            )
        revoked = self.store.revoke_published(
            actor="publisher", reason="field issue"
        )
        self.assertEqual(revoked.state, "revoked")
        self.assertEqual(self.store.published(), revoked)
        self.assertIn(
            "localized_state_transition",
            (revoked.version_dir / "audit_log.jsonl").read_text(),
        )

    def test_publication_rejects_rehashed_forged_trajectory_metrics(self) -> None:
        self.commit_valid()
        review = self.store.transition_current(
            "review", actor="reviewer", reason="quality checks complete"
        )
        evidence_path = self.output / "forged-field-evidence.json"
        _evidence_sha, evidence = write_valid_field_evidence(
            evidence_path,
            release_manifest_sha256="2" * 64,
            release_git_sha="3" * 40,
            product_version="test",
            prior_map_sha256=self.identity_hashes["prior_map_sha256"],
            quality_policy_sha256="e" * 64,
        )
        trajectory = evidence["runs"][0]["trajectoryEvidence"]
        assert isinstance(trajectory, dict)
        trajectory["correctionMaxM"] = 999999.0
        trajectory.pop("evidenceSha256")
        trajectory["evidenceSha256"] = _canonical_sha(trajectory)
        evidence.pop("evidenceSha256")
        evidence["evidenceSha256"] = _canonical_sha(evidence)
        data = json.dumps(evidence, indent=2, sort_keys=True).encode("utf-8") + b"\n"
        evidence_path.write_bytes(data)
        with self.assertRaisesRegex(
            LocalizedStoreError, "Field qualification evidence is invalid"
        ):
            self.store.publish_current(
                actor="publisher",
                reason="forged metrics",
                qualification_evidence_path=evidence_path,
                expected_field_evidence_sha256=hashlib.sha256(data).hexdigest(),
                expected_release_identity={
                    "release_manifest_sha256": "2" * 64,
                    "git_sha": "3" * 40,
                    "product_version": "test",
                    "quality_policy_sha256": "e" * 64,
                },
                expected_version=review.version_id,
            )
        self.assertEqual(self.store.current(), review)
        self.assertIsNone(self.store.published())

    def test_committed_artifact_tampering_fails_closed(self) -> None:
        snapshot = self.commit_valid()
        report = snapshot.version_dir / "localization_report.json"
        report.write_text('{"publish_state":"review"}\n', encoding="utf-8")
        with self.assertRaisesRegex(LocalizedStoreError, "integrity mismatch"):
            self.store.current()

    def test_verified_json_rejects_change_after_snapshot_resolution(self) -> None:
        snapshot = self.commit_valid()
        report = snapshot.version_dir / "localization_report.json"
        report.write_text('{"publish_state":"review"}\n', encoding="utf-8")
        with mock.patch.object(
            self.store, "resolve_version", return_value=snapshot
        ):
            with self.assertRaisesRegex(
                LocalizedStoreError, "changed during verified read"
            ):
                self.store.read_verified_json(snapshot, "localization_report.json")

    def test_verified_read_parses_bytes_from_the_open_descriptor(self) -> None:
        snapshot = self.commit_valid()
        report = snapshot.version_dir / "localization_report.json"
        replacement = snapshot.version_dir / ".replacement-report.json"
        replacement.write_text('{"publish_state":"review"}\n', encoding="utf-8")
        real_fdopen = localized_store.os.fdopen
        opened = 0
        replacement_blocked_by_platform = False

        def replace_path_after_open(descriptor: int, *args: object, **kwargs: object):
            nonlocal opened, replacement_blocked_by_platform
            opened += 1
            if opened == 2:
                try:
                    localized_store.os.replace(replacement, report)
                except PermissionError:
                    if os.name != "nt":
                        raise
                    # Windows denies replacing an open file unless the opener
                    # explicitly granted delete sharing. That OS-level block
                    # closes this TOCTOU attempt before verified parsing.
                    replacement_blocked_by_platform = True
            return real_fdopen(descriptor, *args, **kwargs)

        with (
            mock.patch.object(self.store, "resolve_version", return_value=snapshot),
            mock.patch.object(
                localized_store.os, "fdopen", side_effect=replace_path_after_open
            ),
        ):
            payload = self.store.read_verified_json(
                snapshot, "localization_report.json"
            )
        self.assertEqual(payload["format"], "MarketScannerLocalizationReport")
        if os.name == "nt":
            self.assertTrue(replacement_blocked_by_platform)
            self.assertTrue(replacement.is_file())
            self.assertEqual(
                json.loads(report.read_text())["format"],
                "MarketScannerLocalizationReport",
            )
        else:
            self.assertFalse(replacement_blocked_by_platform)
            self.assertEqual(json.loads(report.read_text())["publish_state"], "review")

    def test_local_input_tampering_fails_closed_without_changing_current(self) -> None:
        snapshot = self.commit_valid()
        record_path = (
            self.store.local_inputs / f"{snapshot.input_identity_id}.json"
        )
        payload = json.loads(record_path.read_text(encoding="utf-8"))
        payload["paths"]["source_database"] = "/tampered/source.db"
        record_path.write_text(json.dumps(payload), encoding="utf-8")
        self.assertEqual(self.store.current(), snapshot)
        with self.assertRaisesRegex(LocalizedStoreError, "identity is invalid"):
            self.store.local_inputs_for(snapshot)

    def test_local_input_fsync_failure_leaves_pointer_unset(self) -> None:
        staging = self.write_valid_staging()
        manifest = self.store.validate_staging(staging, parent_version=None)
        real_fsync_directory = localized_store._fsync_directory

        def fail_local_inputs(path: Path) -> None:
            if path == self.store.local_inputs:
                raise OSError("injected local-input fsync failure")
            real_fsync_directory(path)

        with mock.patch.object(
            localized_store, "_fsync_directory", side_effect=fail_local_inputs
        ):
            with self.assertRaisesRegex(OSError, "local-input"):
                self.store.commit(
                    staging,
                    manifest,
                    update_current=True,
                    local_input_record=self.local_input_record,
                )
        self.assertIsNone(self.store.current())
        self.assertTrue((self.store.versions / "v000001").is_dir())

    def test_version_directory_fsync_failure_leaves_pointer_unchanged(self) -> None:
        first = self.commit_valid()
        staging = self.write_valid_staging(revision=2)
        manifest = self.store.validate_staging(
            staging, parent_version=first.version_id
        )
        real_fsync_directory = localized_store._fsync_directory

        def fail_versions(path: Path) -> None:
            if path == self.store.versions:
                raise OSError("injected versions fsync failure")
            real_fsync_directory(path)

        with mock.patch.object(
            localized_store, "_fsync_directory", side_effect=fail_versions
        ):
            with self.assertRaisesRegex(OSError, "injected"):
                self.store.commit(staging, manifest, update_current=True)
        self.assertEqual(self.store.current(), first)
        self.assertTrue((self.store.versions / "v000002").is_dir())

    def test_pointer_fsync_failure_is_reported_as_indeterminate(self) -> None:
        first = self.commit_valid()
        staging = self.write_valid_staging(revision=2)
        manifest = self.store.validate_staging(
            staging, parent_version=first.version_id
        )
        real_fsync_directory = localized_store._fsync_directory

        def fail_pointer_directory(path: Path) -> None:
            if path == self.store.root:
                raise OSError("injected pointer fsync failure")
            real_fsync_directory(path)

        with mock.patch.object(
            localized_store, "_fsync_directory", side_effect=fail_pointer_directory
        ):
            with self.assertRaises(localized_store.LocalizedCommitIndeterminate):
                self.store.commit(staging, manifest, update_current=True)
        current = self.store.current()
        self.assertIsNotNone(current)
        assert current is not None
        self.assertEqual(current.version_id, "v000002")
        self.assertTrue(
            (
                self.store.local_inputs
                / f"{current.input_identity_id}.json"
            ).is_file()
        )


if __name__ == "__main__":
    unittest.main()
