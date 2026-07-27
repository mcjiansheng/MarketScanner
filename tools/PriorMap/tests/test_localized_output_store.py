from __future__ import annotations

import ast
import csv
import hashlib
import json
import multiprocessing
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

import tools.PriorMap.localized_file_lock as localized_file_lock
import tools.PriorMap.localized_output_store as localized_store

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
            },
            "processing_manifest.json": {
                "format": "MarketScannerLocalizedProcessing",
                "version": 2,
                "publish_state": state,
                "input_identity_id": self.input_identity_id,
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
                },
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
        published = self.store.publish_current(
            actor="publisher",
            reason="explicit approval",
            field_acceptance={
                "accepted": True,
                "actor": "field-reviewer",
                "accepted_at_utc": "2026-07-27T00:00:00.000Z",
                "evidence_sha256": hashlib.sha256(
                    (review.version_dir / "localized_review.json").read_bytes()
                ).hexdigest(),
            },
        )
        self.assertEqual(published.state, "published")
        self.assertEqual(self.store.published(), published)
        self.assertEqual(self.store.current(), review)
        with self.assertRaisesRegex(LocalizedStoreError, "already exists"):
            self.store.publish_current(
                actor="publisher",
                reason="duplicate publication must fail",
                field_acceptance={
                    "accepted": True,
                    "actor": "field-reviewer",
                    "accepted_at_utc": "2026-07-27T00:00:01.000Z",
                    "evidence_sha256": hashlib.sha256(
                        (review.version_dir / "localized_review.json").read_bytes()
                    ).hexdigest(),
                },
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

    def test_committed_artifact_tampering_fails_closed(self) -> None:
        snapshot = self.commit_valid()
        report = snapshot.version_dir / "localization_report.json"
        report.write_text('{"publish_state":"review"}\n', encoding="utf-8")
        with self.assertRaisesRegex(LocalizedStoreError, "integrity mismatch"):
            self.store.current()

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
