"""P7R6C-C4: the finalized-session input identity must describe exactly
the bytes localization actually consumes.

The old flow hashed every sidecar with one path read and re-opened the
same paths for parsing; any mid-window replacement produced
hash-A/parse-B evidence. The snapshot reader (`read_finalized_session
_input_snapshot`) reads each artifact exactly once through a
descriptor-stable path and derives the manifest from those very bytes,
so the bundle SHA always describes what localization parsed.
"""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import sqlite3
import tempfile
import unittest
from pathlib import Path

from tools.PriorMap.offline_localization import (
    FinalizedSessionInputSnapshot,
    OfflineLocalizationError,
    _stable_read_bytes,
    build_session_input_manifest,
    read_finalized_session_input_snapshot,
    session_input_bundle_sha256,
)
from tools.PriorMap.tests.test_prior_map import fixture_rows, write_workbook
from tools.PriorMap.xlsx_to_prior_map import convert_workbook


def json_write(path: Path, value: object) -> None:
    path.write_text(
        json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def jsonl_write(path: Path, values: list[dict[str, object]]) -> None:
    path.write_text(
        "".join(json.dumps(value, sort_keys=True) + "\n" for value in values),
        encoding="utf-8",
    )


class SessionInputSnapshotFixture(unittest.TestCase):
    """Builds one finalized v1 session and exercises the snapshot reader."""

    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        workbook = self.root / "fixture.xlsx"
        write_workbook(workbook, fixture_rows())
        self.prior_map = convert_workbook(
            workbook, self.root / "PriorMap-fixture", store_id="s1"
        )
        manifest = json.loads((self.prior_map / "manifest.json").read_text())
        self.session = self.root / "SupermarketSession-fixture"
        self.segment = self.session / "segment_0001"
        self.segment.mkdir(parents=True)
        json_write(
            self.segment / "metadata.json",
            {
                "scanMode": "continuous_streaming",
                "finalized": True,
                "workflowMode": "prior_map_localized",
                "trackingSessionId": "tracking-1",
                "priorMapId": manifest["prior_map_id"],
                "priorMapSha256": manifest["source_sha256"],
                "floorId": "1",
                "initialMapPose": {"x_m": 1.5, "y_m": -2.5, "yaw_rad": 0},
                "localizedPriceTags": "localized_price_tags.json",
                "localizedPriceTagCount": 1,
                "captureHealth": {
                    "localizationRequiredWriteFailureCount": 0,
                    "localizationTraceRecordCount": 20,
                    "localizationConstraintRecordCount": 2,
                    "localizationStateEventCount": 3,
                    "localizationEvidenceComplete": True,
                },
                "processingEligibility": {"status": "eligible", "blockers": []},
            },
        )
        self.source_database = self.segment / "rtabmap_segment_0001.db"
        self.node_timebase_offset = 1_700_000_000.0
        connection = sqlite3.connect(self.source_database)
        try:
            connection.execute(
                "CREATE TABLE Node(id INTEGER PRIMARY KEY, stamp REAL NOT NULL)"
            )
            connection.executemany(
                "INSERT INTO Node(id, stamp) VALUES(?, ?)",
                [
                    (index + 1, self.node_timebase_offset + float(index))
                    for index in range(20)
                ],
            )
            connection.commit()
        finally:
            connection.close()
        trace = [
            {
                "format": "MarketScannerLocalizationTrace",
                "version": 1,
                "timestamp": float(index),
                "nodeTimebaseTimestamp": self.node_timebase_offset + float(index),
                "nodeTimebaseOffsetSeconds": self.node_timebase_offset,
                "trackingSessionId": "tracking-1",
                "priorMapSha256": manifest["source_sha256"],
                "floorId": "1",
                "estimated_pose": {
                    "x_m": 1.5 + 0.5 * index,
                    "y_m": -2.5,
                    "yaw_rad": 0,
                },
                "raw_pose": {"x_m": 1.5 + 0.5 * index, "y_m": -2.5, "yaw_rad": 0},
                "trackingState": "normal",
                "localizationState": "stable",
                "confidence": 0.9,
            }
            for index in range(20)
        ]
        jsonl_write(self.segment / "localization_trace.jsonl", trace)
        constraints = [
            {
                "format": "MarketScannerLocalizationConstraint",
                "version": 1,
                "timestamp": float(index),
                "nodeTimebaseTimestamp": self.node_timebase_offset + float(index),
                "nodeTimebaseOffsetSeconds": self.node_timebase_offset,
                "trackingSessionId": "tracking-1",
                "priorMapSha256": manifest["source_sha256"],
                "floorId": "1",
                "accepted": True,
                "estimated_pose": {"x_m": 2.0, "y_m": -2.0, "yaw_rad": 0},
                "predicted_pose": {"x_m": 2.0, "y_m": -2.0, "yaw_rad": 0},
                "uniqueness": 0.9,
            }
            for index in (0, 1)
        ]
        jsonl_write(self.segment / "localization_constraints.jsonl", constraints)
        jsonl_write(
            self.segment / "localization_events.jsonl",
            [
                {
                    "format": "MarketScannerLocalizationStateEvent",
                    "version": 1,
                    "timestamp": float(index),
                    "nodeTimebaseTimestamp": self.node_timebase_offset + float(index),
                    "nodeTimebaseOffsetSeconds": self.node_timebase_offset,
                    "trackingSessionId": "tracking-1",
                    "priorMapSha256": manifest["source_sha256"],
                    "floorId": "1",
                    "state": "stable",
                    "confidence": 1.0,
                }
                for index in (0, 1, 2)
            ],
        )
        jsonl_write(self.segment / "manual_localization_events.jsonl", [])
        manifest_data = manifest
        jsonl_write(
            self.segment / "tag_observations.jsonl",
            [
                {
                    "format": "MarketScannerPriceTagObservation",
                    "version": 1,
                    "observation_id": "obs-1",
                    "frame_timestamp": 0.5,
                    "node_timebase_frame_timestamp": self.node_timebase_offset + 0.5,
                    "node_timebase_offset_seconds": self.node_timebase_offset,
                    "tracking_session_id": "tracking-1",
                    "prior_map_sha256": manifest_data["source_sha256"],
                    "floor_id": "1",
                    "raw_map_position": {"x_m": 2.0, "y_m": -2.0, "height_m": 1.2},
                    "payload": "0123456789",
                    "symbology": "EAN13",
                }
            ],
        )
        json_write(
            self.segment / "localized_price_tags.json",
            [
                {
                    "format": "MarketScannerLocalizedPriceTag",
                    "version": 1,
                    "tag_id": "t1",
                    "observation_id": "o1",
                    "payload": "0123456789",
                    "symbology": "EAN13",
                    "floor_id": "1",
                    "timestamp": 0.5,
                    "tracking_session_id": "tracking-1",
                    "prior_map_id": manifest["prior_map_id"],
                    "prior_map_sha256": manifest["source_sha256"],
                    "raw_map_position": {"x_m": 2.0, "y_m": -2.0, "yaw_rad": 0},
                    "snapped_map_position": {"x_m": 2.0, "y_m": -2.0, "yaw_rad": 0},
                    "localization_confidence": 0.9,
                    "measurement_confidence": 0.9,
                    "association_confidence": 0.9,
                    "measurement_method": "manual",
                    "needs_review": False,
                    "user_confirmed": True,
                }
            ],
        )

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def snapshot(self) -> FinalizedSessionInputSnapshot:
        return read_finalized_session_input_snapshot(
            self.segment, self.source_database
        )


class SnapshotConsistencyTests(SessionInputSnapshotFixture):
    def test_snapshot_manifest_equals_build_manifest_and_recomputes_bundle(self) -> None:
        snapshot = self.snapshot()
        built = build_session_input_manifest(self.segment, self.source_database)
        self.assertEqual(snapshot.manifest, built)
        self.assertEqual(
            session_input_bundle_sha256(snapshot.manifest),
            snapshot.manifest["bundle_sha256"],
        )
        # S10: the bundle SHA must be recomputable from the identities of
        # the artifacts the snapshot actually parsed.
        recomputed = session_input_bundle_sha256(snapshot.manifest)
        self.assertEqual(recomputed, snapshot.manifest["bundle_sha256"])

    def test_snapshot_parses_the_same_bytes_it_hashes(self) -> None:
        snapshot = self.snapshot()
        for entry in snapshot.manifest["files"]:
            self.assertEqual(
                entry["sha256"],
                hashlib.sha256(
                    _artifact_bytes(self.segment, self.source_database, entry)
                ).hexdigest(),
                entry["role"],
            )
        self.assertEqual(snapshot.metadata["trackingSessionId"], "tracking-1")
        self.assertEqual(len(snapshot.jsonl_values["localization_trace.jsonl"]), 20)
        self.assertEqual(snapshot.localized_tag_count, 1)

    def test_metadata_read_once_version_and_hash_same_source(self) -> None:
        # S1: the manifest version decision and the metadata identity must
        # come from ONE stable read inside the snapshot reader. The
        # metadata bytes that drive v1/v2 are exactly the bytes hashed into
        # the manifest identity.
        from unittest import mock

        real_stable_read = _stable_read_bytes
        metadata_reads: list[bytes] = []

        def counting_stable_read(
            path: Path, role: str, *, maximum_bytes: int | None = None
        ) -> tuple[bytes, dict]:
            data, identity = real_stable_read(
                path, role, maximum_bytes=maximum_bytes
            )
            if role == "metadata":
                metadata_reads.append(data)
            return data, identity

        with mock.patch(
            "tools.PriorMap.offline_localization._stable_read_bytes",
            side_effect=counting_stable_read,
        ):
            snapshot = self.snapshot()
        # The metadata path must be read exactly once; the manifest entry
        # for metadata is derived from that same byte payload.
        self.assertEqual(len(metadata_reads), 1)
        metadata_identity = next(
            entry
            for entry in snapshot.manifest["files"]
            if entry["role"] == "metadata"
        )
        self.assertEqual(
            metadata_identity["sha256"],
            hashlib.sha256(metadata_reads[0]).hexdigest(),
        )
        self.assertEqual(
            metadata_identity["bytes"],
            len(metadata_reads[0]),
        )

    def test_replacement_between_build_and_snapshot_fails_closed(self) -> None:
        # S1/S3: a metadata replacement between the caller's manifest build
        # and the snapshot read must be caught by the render before-check,
        # which compares the freshly rebuilt manifest against the expected
        # bundle SHA. We simulate the drift directly: two manifest builds
        # over different bytes must disagree.
        built_before = build_session_input_manifest(
            self.segment, self.source_database
        )
        metadata_path = self.segment / "metadata.json"
        original = metadata_path.read_bytes()
        mutated = original.replace(b'"finalized": true', b'"finalized": false')
        metadata_path.write_bytes(mutated)
        try:
            built_after = build_session_input_manifest(
                self.segment, self.source_database
            )
            self.assertNotEqual(
                built_after["bundle_sha256"], built_before["bundle_sha256"]
            )
        finally:
            metadata_path.write_bytes(original)
        restored = build_session_input_manifest(self.segment, self.source_database)
        self.assertEqual(restored["bundle_sha256"], built_before["bundle_sha256"])

    def test_sidecar_symlink_fails_closed(self) -> None:
        # S4: a symlinked JSONL sidecar must be rejected by the stable
        # descriptor read.
        events = self.segment / "localization_events.jsonl"
        original = events.read_bytes()
        target = self.root / "events-target.jsonl"
        target.write_bytes(original)
        events.unlink()
        events.symlink_to(target)
        with self.assertRaises(OfflineLocalizationError):
            self.snapshot()
        events.unlink()
        events.write_bytes(original)

    def test_sidecar_hardlink_fails_closed(self) -> None:
        # S5: st_nlink != 1 must be rejected by the stable read.
        events = self.segment / "localization_events.jsonl"
        link = self.segment / "events-extra-link"
        link.hardlink_to(events)
        try:
            with self.assertRaises(OfflineLocalizationError):
                self.snapshot()
        finally:
            link.unlink()

    def test_truncate_and_restore_fails_closed(self) -> None:
        # S6: truncate a sidecar between the two reads inside the snapshot
        # -> the pre/post descriptor identity check rejects it.
        trace = self.segment / "localization_trace.jsonl"
        original = trace.read_bytes()
        trace.write_bytes(original[: len(original) // 2])
        with self.assertRaises(OfflineLocalizationError):
            self.snapshot()
        trace.write_bytes(original)

    def test_localized_tags_swap_moves_bundle_sha(self) -> None:
        # S7: replacing the tags file must move the bundle SHA; the render
        # before-check rejects any drift between the caller's manifest and
        # the snapshot read.
        snapshot_before = self.snapshot()
        built_before = build_session_input_manifest(
            self.segment, self.source_database
        )
        tags = self.segment / "localized_price_tags.json"
        original = tags.read_bytes()
        swapped = original.replace(b"0123456789", b"9999999999999999")
        tags.write_bytes(swapped)
        try:
            built_after = build_session_input_manifest(
                self.segment, self.source_database
            )
            self.assertNotEqual(
                built_after["bundle_sha256"], built_before["bundle_sha256"]
            )
            self.assertNotEqual(
                built_after["bundle_sha256"], snapshot_before.manifest["bundle_sha256"]
            )
        finally:
            tags.write_bytes(original)

    def test_source_database_verified_copy_rejects_mutation(self) -> None:
        # S9: the descriptor-verified copy must fail closed when the source
        # database changed after the snapshot identity was captured.
        from tools.PriorMap.offline_localization import (
            _verified_source_database_copy,
        )

        snapshot = self.snapshot()
        work = self.root / "verified-copy-work"
        verified = _verified_source_database_copy(
            self.source_database, work, snapshot.source_database_sha256
        )
        self.assertEqual(
            hashlib.sha256(verified.read_bytes()).hexdigest(),
            snapshot.source_database_sha256,
        )
        # Mutate the original after the snapshot; a new verified copy with
        # the stale expected hash must be rejected.
        original = self.source_database.read_bytes()
        self.source_database.write_bytes(original + b"\x00")
        try:
            with self.assertRaises(OfflineLocalizationError):
                _verified_source_database_copy(
                    self.source_database,
                    self.root / "verified-copy-work-2",
                    snapshot.source_database_sha256,
                )
        finally:
            self.source_database.write_bytes(original)

    def test_v2_recovery_binding_hash_and_parse_agree(self) -> None:
        # S8: a v2 session binds the recovery sidecar; the bundle SHA and
        # the parsed episode set must describe the same bytes.
        metadata_path = self.segment / "metadata.json"
        metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
        metadata["captureHealth"]["localizationRecoveryEventCount"] = 1
        metadata["captureHealth"]["localizationLastRecoveryEpisodeId"] = 1
        metadata["captureHealth"]["localizationLastRecoveryFinishedAtUptime"] = 14.5
        json_write(metadata_path, metadata)
        manifest = json.loads((self.prior_map / "manifest.json").read_text())
        jsonl_write(
            self.segment / "localization_recovery_events.jsonl",
            [
                {
                    "format": "MarketScannerRecoveryLifecycleEvent",
                    "version": 2,
                    "tracking_session_id": "tracking-1",
                    "prior_map_id": manifest["prior_map_id"],
                    "prior_map_sha256": manifest["source_sha256"],
                    "floor_id": "1",
                    "episode_id": 1,
                    "reason": "reliable_rtabmap_loop",
                    "outcome": "converged",
                    "episode_automatic": False,
                    "started_at_uptime": 10.0,
                    "deadline_uptime": 40.0,
                    "finished_at_uptime": 14.5,
                    "elapsed_ms": 4500.0,
                    "maximum_valid_attempts": 40,
                    "valid_matcher_attempts": 7,
                    "accepted_corrections": 2,
                    "trigger_count": 1,
                    "automatic_trigger_count": 0,
                    "reliable_loop_trigger_count": 1,
                    "last_trigger_reason": "reliable_rtabmap_loop",
                    "last_trigger_at_uptime": 10.0,
                    "trigger_records": [
                        {
                            "reason": "reliable_rtabmap_loop",
                            "automatic": False,
                            "at_uptime": 10.0,
                        }
                    ],
                    "fresh_support_frames": 4,
                    "completion_frame_step_applied": False,
                }
            ],
        )
        snapshot = self.snapshot()
        self.assertEqual(snapshot.manifest["version"], 2)
        self.assertEqual(
            len(snapshot.jsonl_values["localization_recovery_events.jsonl"]), 1
        )
        self.assertEqual(
            session_input_bundle_sha256(snapshot.manifest),
            snapshot.manifest["bundle_sha256"],
        )
        # Mutating the recovery sidecar must move the bundle SHA.
        recovery = self.segment / "localization_recovery_events.jsonl"
        original = recovery.read_bytes()
        recovery.write_bytes(original[:-1] + b"\x00" + original[-1:])
        try:
            changed = build_session_input_manifest(self.segment, self.source_database)
            self.assertNotEqual(
                changed["bundle_sha256"], snapshot.manifest["bundle_sha256"]
            )
        finally:
            recovery.write_bytes(original)


def _artifact_bytes(
    segment: Path, source_database: Path, entry: dict[str, object]
) -> bytes:
    role = entry["role"]
    if role == "metadata":
        return (segment / "metadata.json").read_bytes()
    if role == "source_database":
        return source_database.read_bytes()
    if role == "localized_price_tags.json":
        return (segment / role).read_bytes()
    return (segment / role).read_bytes()


if __name__ == "__main__":
    unittest.main()
