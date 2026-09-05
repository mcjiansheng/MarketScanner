#!/usr/bin/env python3
"""Strict validation tests for store missions (requirement §11.1 / §14.1)."""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import sqlite3
import tempfile
import unittest
from contextlib import closing
from pathlib import Path

import mission_validation as mv


PACKAGE_SHA = "a" * 64
BUILD_IDENTITY = "build-20260905"
EVIDENCE_SHA = "b" * 64


def _sha256_bytes(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def _sha256_file(path: Path) -> str:
    return _sha256_bytes(path.read_bytes())


def _metadata(
    *,
    unit_id: str,
    unit_index: int,
    previous_unit_id: str | None = None,
    previous_hash: str | None = None,
    finalized: bool = True,
    scan_mode: str = "continuous_streaming",
    prior_map_id: str = "map-01",
    store_id: str = "store-01",
    floor_id: str = "F1",
    boundary_id: str | None = None,
    active_capture: float = 1800.0,
    trigger: str = "time_limit",
) -> dict:
    return {
        "format": "SupermarketScanSession",
        "version": 1,
        "segmentIndex": 1,
        "scanMode": scan_mode,
        "finalized": finalized,
        "workflowMode": "prior_map_localized",
        "exportedAt": "2026-09-04 10:00:00",
        "knownAreaM2": 120.0,
        "nodeCount": 1,
        "trackingSessionId": f"tracking-{unit_id}",
        "captureHealth": {
            "localizationRequiredWriteFailureCount": 0,
            "localizationEvidenceComplete": True,
        },
        "processingEligibility": {"status": "eligible", "blockers": []},
        "priorMapId": prior_map_id,
        "priorMapSha256": PACKAGE_SHA,
        "storeId": store_id,
        "floorId": floor_id,
        "buildIdentity": BUILD_IDENTITY,
        "missionId": "mission-0001",
        "missionFormatVersion": 1,
        "unitId": unit_id,
        "unitIndex": unit_index,
        "previousUnitId": previous_unit_id,
        "previousUnitMetadataSha256": previous_hash,
        "rolloverTrigger": trigger,
        "activeCaptureDurationS": active_capture,
        "maintenancePolicyVersion": 1,
        "calibrationIntervalS": 1800,
        "boundaryCheckpointId": boundary_id,
        "nextMaintenanceAtActiveS": 1800,
        "maintenanceState": "scanning",
    }


def _write_unit(
    root: Path,
    name: str,
    metadata: dict,
    *,
    database_bytes: bytes | None = None,
    live_checkpoint: bool = False,
    segment_name: str = "segment_0001",
) -> Path:
    unit_dir = root / "units" / name
    segment_dir = unit_dir / segment_name
    segment_dir.mkdir(parents=True, exist_ok=True)
    database_path = segment_dir / "rtabmap_segment_0001.db"
    if database_bytes is None:
        _create_database(database_path)
    else:
        database_path.write_bytes(database_bytes)
    (segment_dir / "metadata.json").write_text(
        json.dumps(metadata, sort_keys=True), encoding="utf-8"
    )
    if live_checkpoint:
        (segment_dir / "live_checkpoint.json").write_text("{}", encoding="utf-8")
    _write_required_sidecars(segment_dir)
    return unit_dir


def _write_required_sidecars(segment_dir: Path) -> None:
    (segment_dir / "price_tags.json").write_text("[]", encoding="utf-8")
    (segment_dir / "price_tags.csv").write_text("barcode\n", encoding="utf-8")
    (segment_dir / "scan_area_cells.json").write_text("{}", encoding="utf-8")
    (segment_dir / "structure_coverage_cells.json").write_text("{}", encoding="utf-8")
    (segment_dir / "trajectory_samples.json").write_text("[]", encoding="utf-8")
    (segment_dir / "trajectory_samples.csv").write_text("timestamp\n", encoding="utf-8")
    (segment_dir / "scan_events.jsonl").write_text(
        '{"event":"scan_finalized"}\n', encoding="utf-8"
    )


def _create_database(path: Path) -> None:
    with closing(sqlite3.connect(path)) as connection, connection:
        connection.execute("CREATE TABLE Node (id INTEGER PRIMARY KEY, stamp REAL)")
        connection.execute("CREATE TABLE Data (image BLOB, depth BLOB, calibration BLOB)")
        connection.execute("INSERT INTO Node VALUES (1, 1.0)")
        connection.execute("INSERT INTO Data VALUES (?, ?, ?)", (b"i", b"d", b"c"))


def _boundary(
    mission_id: str,
    boundary_id: str,
    from_unit: str,
    to_unit: str,
    *,
    outgoing: bool = True,
    incoming: bool = True,
    pose=(10.0, 20.0, 0.5),
) -> dict:
    def end(unit_id: str, index: int, *, outgoing_end: bool) -> dict:
        value = {
            "unitId": unit_id,
            "unitIndex": index,
            "trackingSessionId": f"tracking-{unit_id}",
            "nodeId": 100 + index,
            "nodeStamp": 1000.0 + index,
            "nodeTimeSnapshotGeneration": 7,
            "confirmedX": pose[0],
            "confirmedY": pose[1],
            "confirmedYaw": pose[2],
        }
        if outgoing_end:
            value["manualEventSha256"] = EVIDENCE_SHA
        else:
            value["startReceiptSha256"] = "c" * 64
        return value

    return {
        "format": mv.FORMAT_BOUNDARY,
        "version": 1,
        "missionId": mission_id,
        "boundaryId": boundary_id,
        "priorMapId": "map-01",
        "priorMapPackageSha256": PACKAGE_SHA,
        "storeId": "store-01",
        "floorId": "F1",
        "fromUnitId": from_unit,
        "toUnitId": to_unit,
        "confirmedX": pose[0],
        "confirmedY": pose[1],
        "confirmedYaw": pose[2],
        "outgoing": end(
            from_unit, int(from_unit.rsplit("-", 1)[-1]), outgoing_end=True
        ) if outgoing else None,
        "incoming": end(
            to_unit, int(to_unit.rsplit("-", 1)[-1]), outgoing_end=False
        ) if incoming else None,
        "createdAtUnix": 1.0,
        "committedAtUnix": 2.0,
    }


def _unit_entry(root: Path, unit_dir: Path, unit_id: str, index: int, previous: dict | None) -> dict:
    metadata_path = unit_dir / "segment_0001" / "metadata.json"
    database_path = unit_dir / "segment_0001" / "rtabmap_segment_0001.db"
    return {
        "unitId": unit_id,
        "unitIndex": index,
        "relativePath": unit_dir.relative_to(root).as_posix(),
        "trackingSessionId": f"tracking-{unit_id}",
        "databaseRelativePath": database_path.relative_to(root).as_posix(),
        "metadataRelativePath": metadata_path.relative_to(root).as_posix(),
        "databaseSha256": _sha256_file(database_path),
        "metadataSha256": _sha256_file(metadata_path),
        "previousUnitId": previous.get("unitId") if previous else None,
        "previousUnitMetadataSha256": previous.get("metadataSha256") if previous else None,
        "rolloverTrigger": "time_limit",
        "activeCaptureDurationS": 1800.0,
        "unitStorageBytes": sum(
            path.stat().st_size for path in unit_dir.rglob("*") if path.is_file()
        ),
        "finalizedAtUnix": 2.0 + index,
        "finalized": True,
    }


class MissionValidationTestCase(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="mission-validation-"))
        self.addCleanup(shutil.rmtree, self.tmp, True)

    # -- builders ---------------------------------------------------------

    def _make_mission(self, unit_count: int = 4, **kwargs) -> Path:
        root = self.tmp / "SupermarketMission-20260904-100000"
        (root / "units").mkdir(parents=True)
        (root / "boundaries").mkdir()
        entries: list[dict] = []
        boundaries: list[dict] = []
        previous: dict | None = None
        for index in range(1, unit_count + 1):
            unit_id = f"unit-{index:04d}"
            metadata = _metadata(
                unit_id=unit_id,
                unit_index=index,
                previous_unit_id=previous.get("unitId") if previous else None,
                previous_hash=previous.get("metadataSha256") if previous else None,
                boundary_id=f"boundary-{index:04d}" if index > 1 else None,
                **kwargs,
            )
            unit_dir = _write_unit(
                root,
                f"SupermarketSession-20260904-100000-U{index:04d}",
                metadata,
            )
            entry = _unit_entry(root, unit_dir, unit_id, index, previous)
            entries.append(entry)
            previous = entry
        for index in range(2, unit_count + 1):
            boundary = _boundary(
                "mission-0001",
                f"boundary-{index:04d}",
                f"unit-{index - 1:04d}",
                f"unit-{index:04d}",
            )
            boundary_dir = root / "boundaries"
            payload = json.dumps(boundary, sort_keys=True).encode("utf-8")
            (boundary_dir / f"boundary_{index - 1:04d}.json").write_bytes(payload)
            boundary["fileSha256"] = _sha256_bytes(payload)
            boundaries.append(boundary)
        manifest = {
            "format": mv.FORMAT_MANIFEST,
            "version": 1,
            "missionId": "mission-0001",
            "policyVersion": 1,
            "identity": {
                "missionId": "mission-0001",
                "priorMapId": "map-01",
                "priorMapPackageSha256": PACKAGE_SHA,
                "storeId": "store-01",
                "floorId": "F1",
                "buildIdentity": BUILD_IDENTITY,
            },
            "units": entries,
            "boundaries": boundaries,
            "completedAtUnix": 10.0,
            "integrity": "verified",
            "publishPermitted": True,
        }
        (root / "mission_manifest.json").write_text(
            json.dumps(manifest, sort_keys=True), encoding="utf-8"
        )
        return root

    # -- tests ------------------------------------------------------------

    def test_complete_four_unit_mission_publishes(self) -> None:
        root = self._make_mission(4)
        report = mv.validate_mission(root)
        self.assertEqual(report.status, mv.STATUS_COMPLETE)
        self.assertTrue(report.publish_permitted)
        self.assertEqual([item.unit_index for item in report.units], [1, 2, 3, 4])
        self.assertEqual(len(report.boundaries), 3)
        self.assertTrue(all(boundary.complete for boundary in report.boundaries))
        self.assertEqual(
            [item.severity for item in report.findings if item.severity == mv.SEVERITY_FATAL], []
        )

    def test_single_unit_mission_without_boundary_publishes(self) -> None:
        root = self._make_mission(1)
        report = mv.validate_mission(root)
        self.assertTrue(report.publish_permitted, report.findings)

    def test_declared_storage_bytes_cover_the_entire_unit(self) -> None:
        root = self._make_mission(1)
        manifest_path = root / "mission_manifest.json"
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        manifest["units"][0]["unitStorageBytes"] -= 1
        manifest_path.write_text(json.dumps(manifest, sort_keys=True), encoding="utf-8")
        report = mv.validate_mission(root)
        self.assertFalse(report.publish_permitted)
        self.assertIn(
            "mission_unit_storage_bytes_mismatch",
            {item.code for item in report.findings},
        )

    def test_missing_policy_version_is_fatal(self) -> None:
        root = self._make_mission(1)
        manifest_path = root / "mission_manifest.json"
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        manifest.pop("policyVersion")
        manifest_path.write_text(json.dumps(manifest, sort_keys=True), encoding="utf-8")
        report = mv.validate_mission(root)
        self.assertFalse(report.publish_permitted)
        self.assertIn(
            "mission_policy_version_unsupported",
            {item.code for item in report.findings},
        )

    def test_undeclared_unit_directory_is_fatal(self) -> None:
        root = self._make_mission(1)
        extra = root / "units" / "SupermarketSession-20260904-100000-U0002"
        _write_unit(
            root,
            extra.name,
            _metadata(unit_id="unit-0002", unit_index=2),
        )
        report = mv.validate_mission(root)
        self.assertFalse(report.publish_permitted)
        self.assertIn(
            "mission_undeclared_unit",
            {item.code for item in report.findings},
        )

    def test_noncanonical_declared_path_is_fatal(self) -> None:
        root = self._make_mission(1)
        manifest_path = root / "mission_manifest.json"
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        manifest["units"][0]["relativePath"] = (
            "units//SupermarketSession-20260904-100000-U0001"
        )
        manifest_path.write_text(json.dumps(manifest, sort_keys=True), encoding="utf-8")
        report = mv.validate_mission(root)
        self.assertFalse(report.publish_permitted)
        self.assertIn(
            "unit_path_not_canonical",
            {item.code for item in report.findings},
        )

    def test_missing_unit_directory_is_fatal(self) -> None:
        root = self._make_mission(3)
        shutil.rmtree(root / "units" / "SupermarketSession-20260904-100000-U0002")
        report = mv.validate_mission(root)
        self.assertFalse(report.publish_permitted)
        codes = {item.code for item in report.findings}
        self.assertIn("unit_missing", codes)
        # The chain cannot be verified once the middle metadata is gone; both
        # "missing" and "broken" are fail-closed outcomes.
        self.assertTrue(codes & {"mission_hash_chain_broken", "mission_hash_chain_missing"})

    def test_reordered_units_are_rejected(self) -> None:
        root = self._make_mission(3)
        manifest_path = root / "mission_manifest.json"
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        manifest["units"] = list(reversed(manifest["units"]))
        manifest_path.write_text(json.dumps(manifest, sort_keys=True), encoding="utf-8")
        report = mv.validate_mission(root)
        self.assertFalse(report.publish_permitted)
        codes = {item.code for item in report.findings}
        # The manifest itself must list units in ascending order; a reordered
        # declaration is fatal even though the files on disk are intact.
        self.assertIn("mission_unit_declaration_out_of_order", codes)

    def test_duplicate_unit_index_is_fatal(self) -> None:
        root = self._make_mission(3)
        manifest_path = root / "mission_manifest.json"
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        manifest["units"][2]["unitIndex"] = 1
        manifest_path.write_text(json.dumps(manifest, sort_keys=True), encoding="utf-8")
        report = mv.validate_mission(root)
        self.assertFalse(report.publish_permitted)
        self.assertIn(
            "mission_duplicate_unit_index",
            {item.code for item in report.findings},
        )

    def test_broken_hash_chain_is_fatal(self) -> None:
        root = self._make_mission(3)
        metadata_path = (
            root
            / "units"
            / "SupermarketSession-20260904-100000-U0003"
            / "segment_0001"
            / "metadata.json"
        )
        metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
        metadata["previousUnitMetadataSha256"] = "0" * 64
        metadata_path.write_text(json.dumps(metadata, sort_keys=True), encoding="utf-8")
        report = mv.validate_mission(root)
        self.assertFalse(report.publish_permitted)
        self.assertIn(
            "mission_hash_chain_broken", {item.code for item in report.findings}
        )

    def test_one_sided_boundary_blocks_publication(self) -> None:
        root = self._make_mission(2)
        boundary_path = root / "boundaries" / "boundary_0001.json"
        boundary = json.loads(boundary_path.read_text(encoding="utf-8"))
        boundary["incoming"] = None
        payload = json.dumps(boundary, sort_keys=True).encode("utf-8")
        boundary_path.write_bytes(payload)
        manifest_path = root / "mission_manifest.json"
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        manifest["boundaries"][0]["incoming"] = None
        manifest["boundaries"][0]["fileSha256"] = _sha256_bytes(payload)
        manifest_path.write_text(json.dumps(manifest, sort_keys=True), encoding="utf-8")
        report = mv.validate_mission(root)
        self.assertFalse(report.publish_permitted)
        codes = {item.code for item in report.findings}
        self.assertIn("boundary_incoming_incomplete", codes)
        self.assertIn("boundary_incomplete", codes)

    def test_missing_boundary_file_is_fatal(self) -> None:
        root = self._make_mission(2)
        (root / "boundaries" / "boundary_0001.json").unlink()
        report = mv.validate_mission(root)
        self.assertFalse(report.publish_permitted)
        self.assertIn(
            "boundary_file_missing", {item.code for item in report.findings}
        )

    def test_symlinked_unit_is_rejected(self) -> None:
        root = self._make_mission(2)
        outside = self.tmp / "outside-unit"
        outside.mkdir()
        (outside / "segment_0001").mkdir()
        real_unit = root / "units" / "SupermarketSession-20260904-100000-U0002"
        shutil.rmtree(real_unit)
        os.symlink(outside, real_unit)
        report = mv.validate_mission(root)
        self.assertFalse(report.publish_permitted)
        self.assertIn(
            "unit_link_detected", {item.code for item in report.findings}
        )

    def test_path_escape_is_rejected(self) -> None:
        root = self._make_mission(2)
        manifest_path = root / "mission_manifest.json"
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        manifest["units"][1]["relativePath"] = "../../etc"
        manifest_path.write_text(json.dumps(manifest, sort_keys=True), encoding="utf-8")
        report = mv.validate_mission(root)
        self.assertFalse(report.publish_permitted)
        self.assertIn(
            "unit_path_parent_escape", {item.code for item in report.findings}
        )

    def test_running_mission_is_diagnostic_only(self) -> None:
        root = self._make_mission(2)
        (root / "mission_manifest.json").unlink()
        checkpoint = {
            "format": mv.FORMAT_LIVE_CHECKPOINT,
            "version": 1,
            "missionId": "mission-0001",
            "policyVersion": 1,
            "identity": {
                "missionId": "mission-0001",
                "priorMapId": "map-01",
                "priorMapPackageSha256": "package-sha",
                "storeId": "store-01",
                "floorId": "F1",
            },
            "currentUnit": {
                "unitId": "unit-0002",
                "unitIndex": 2,
                "relativePath": "units/SupermarketSession-20260904-100000-U0002",
                "trackingSessionId": "tracking-unit-0002",
                "databaseRelativePath": "units/SupermarketSession-20260904-100000-U0002/segment_0001/rtabmap_segment_0001.db",
                "metadataRelativePath": "units/SupermarketSession-20260904-100000-U0002/segment_0001/metadata.json",
                "finalized": False,
            },
            "finalizedUnits": [],
            "activeCaptureElapsedS": 900,
            "nextMaintenanceAtActiveS": 1800,
            "maintenanceState": "scanning",
        }
        (root / "mission_live_checkpoint.json").write_text(
            json.dumps(checkpoint, sort_keys=True), encoding="utf-8"
        )
        report = mv.validate_mission(root)
        self.assertEqual(report.status, mv.STATUS_DIAGNOSTIC)
        self.assertFalse(report.publish_permitted)
        self.assertIn(
            "mission_not_completed", {item.code for item in report.findings}
        )

    def test_unrecognized_container_is_invalid(self) -> None:
        root = self.tmp / "SupermarketMission-empty"
        (root / "units").mkdir(parents=True)
        report = mv.validate_mission(root)
        self.assertEqual(report.status, mv.STATUS_INVALID)
        self.assertIn(
            "mission_container_unrecognized", {item.code for item in report.findings}
        )

    def test_identity_drift_is_fatal(self) -> None:
        root = self._make_mission(2)
        metadata_path = (
            root
            / "units"
            / "SupermarketSession-20260904-100000-U0002"
            / "segment_0001"
            / "metadata.json"
        )
        metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
        metadata["floorId"] = "F2"
        metadata_path.write_text(json.dumps(metadata, sort_keys=True), encoding="utf-8")
        report = mv.validate_mission(root)
        self.assertFalse(report.publish_permitted)
        self.assertIn(
            "mission_identity_drift", {item.code for item in report.findings}
        )

    def test_not_finalized_unit_blocks_publication(self) -> None:
        root = self._make_mission(2)
        metadata_path = (
            root
            / "units"
            / "SupermarketSession-20260904-100000-U0002"
            / "segment_0001"
            / "metadata.json"
        )
        metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
        metadata["finalized"] = False
        metadata_path.write_text(json.dumps(metadata, sort_keys=True), encoding="utf-8")
        report = mv.validate_mission(root)
        self.assertFalse(report.publish_permitted)
        codes = {item.code for item in report.findings}
        self.assertTrue({"unit_not_finalized", "mission_finalized_flag_mismatch"} & codes)

    def test_live_checkpoint_inside_unit_is_fatal(self) -> None:
        root = self._make_mission(2)
        (
            root
            / "units"
            / "SupermarketSession-20260904-100000-U0001"
            / "segment_0001"
            / "live_checkpoint.json"
        ).write_text("{}", encoding="utf-8")
        report = mv.validate_mission(root)
        self.assertFalse(report.publish_permitted)
        self.assertIn(
            "unit_live_checkpoint_present", {item.code for item in report.findings}
        )

    def test_legacy_single_session_is_one_unit_mission(self) -> None:
        session = self.tmp / "SupermarketSession-20260904-090000"
        (session / "segment_0001").mkdir(parents=True)
        _create_database(session / "segment_0001" / "rtabmap_segment_0001.db")
        _write_required_sidecars(session / "segment_0001")
        (session / "segment_0001" / "metadata.json").write_text(
            json.dumps(_metadata(unit_id="legacy", unit_index=1), sort_keys=True),
            encoding="utf-8",
        )
        report = mv.validate_mission(session)
        self.assertEqual(report.kind, "legacy_session")
        self.assertTrue(report.publish_permitted)
        self.assertEqual(len(report.units), 1)

    def test_legacy_session_with_live_checkpoint_is_rejected(self) -> None:
        session = self.tmp / "SupermarketSession-20260904-090001"
        (session / "segment_0001").mkdir(parents=True)
        _create_database(session / "segment_0001" / "rtabmap_segment_0001.db")
        _write_required_sidecars(session / "segment_0001")
        metadata = _metadata(unit_id="legacy", unit_index=1)
        metadata["finalized"] = False
        (session / "segment_0001" / "metadata.json").write_text(
            json.dumps(metadata, sort_keys=True), encoding="utf-8"
        )
        (session / "segment_0001" / "live_checkpoint.json").write_text("{}", encoding="utf-8")
        report = mv.validate_mission(session)
        self.assertFalse(report.publish_permitted)
        codes = {item.code for item in report.findings}
        self.assertTrue({"unit_not_finalized", "unit_live_checkpoint_present"} & codes)

    def test_manifest_overclaim_is_reported(self) -> None:
        root = self._make_mission(2)
        (
            root
            / "units"
            / "SupermarketSession-20260904-100000-U0001"
            / "segment_0001"
            / "live_checkpoint.json"
        ).write_text("{}", encoding="utf-8")
        report = mv.validate_mission(root)
        self.assertFalse(report.publish_permitted)
        self.assertIn(
            "mission_manifest_overclaims", {item.code for item in report.findings}
        )

    def test_database_digest_mismatch_is_fatal(self) -> None:
        root = self._make_mission(2)
        (
            root
            / "units"
            / "SupermarketSession-20260904-100000-U0002"
            / "segment_0001"
            / "rtabmap_segment_0001.db"
        ).write_bytes(b"tampered")
        report = mv.validate_mission(root)
        self.assertFalse(report.publish_permitted)
        self.assertIn(
            "mission_database_digest_mismatch", {item.code for item in report.findings}
        )

    def test_unit_without_mission_identity_is_fatal(self) -> None:
        """A missing unit/mission id must not make the chain pass vacuously."""
        root = self._make_mission(2)
        metadata_path = (
            root
            / "units"
            / "SupermarketSession-20260904-100000-U0002"
            / "segment_0001"
            / "metadata.json"
        )
        metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
        metadata.pop("unitId")
        metadata.pop("missionId")
        metadata_path.write_text(json.dumps(metadata, sort_keys=True), encoding="utf-8")
        report = mv.validate_mission(root)
        codes = {item.code for item in report.findings}
        self.assertFalse(report.publish_permitted)
        self.assertTrue({"unit_id_missing", "unit_mission_id_missing"} & codes)
        # Without a unit id the boundary cannot be matched against a real unit.
        self.assertIn("boundary_unit_unknown", codes)

    def test_legacy_session_without_mission_fields_publishes(self) -> None:
        session = self.tmp / "SupermarketSession-20260801-080000"
        (session / "segment_0001").mkdir(parents=True)
        _create_database(session / "segment_0001" / "rtabmap_segment_0001.db")
        _write_required_sidecars(session / "segment_0001")
        metadata = _metadata(unit_id="legacy", unit_index=1)
        metadata.pop("missionId")
        metadata.pop("unitId")
        metadata.pop("unitIndex")
        (session / "segment_0001" / "metadata.json").write_text(
            json.dumps(metadata, sort_keys=True), encoding="utf-8"
        )
        report = mv.validate_mission(session)
        self.assertTrue(report.publish_permitted, report.findings)

    def test_boundary_without_unit_ids_is_fatal(self) -> None:
        root = self._make_mission(2)
        manifest_path = root / "mission_manifest.json"
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        manifest["boundaries"][0]["fromUnitId"] = None
        manifest["boundaries"][0]["toUnitId"] = None
        manifest_path.write_text(json.dumps(manifest, sort_keys=True), encoding="utf-8")
        report = mv.validate_mission(root)
        self.assertFalse(report.publish_permitted)
        codes = {item.code for item in report.findings}
        self.assertIn("boundary_unit_id_missing", codes)
        self.assertIn("boundary_manifest_file_mismatch", codes)

    def test_duplicate_boundary_id_is_fatal(self) -> None:
        root = self._make_mission(3)
        manifest_path = root / "mission_manifest.json"
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        manifest["boundaries"][1]["boundaryId"] = manifest["boundaries"][0]["boundaryId"]
        manifest_path.write_text(json.dumps(manifest, sort_keys=True), encoding="utf-8")
        report = mv.validate_mission(root)
        self.assertFalse(report.publish_permitted)
        self.assertIn(
            "boundary_duplicate_id", {item.code for item in report.findings}
        )

    def test_linked_database_is_rejected(self) -> None:
        root = self._make_mission(2)
        database = (
            root
            / "units"
            / "SupermarketSession-20260904-100000-U0002"
            / "segment_0001"
            / "rtabmap_segment_0001.db"
        )
        outside = self.tmp / "planted.db"
        outside.write_bytes(b"planted")
        database.unlink()
        os.symlink(outside, database)
        report = mv.validate_mission(root)
        self.assertFalse(report.publish_permitted)
        self.assertIn(
            "unit_database_link_detected", {item.code for item in report.findings}
        )

    def test_dangling_live_checkpoint_blocks_publication(self) -> None:
        root = self._make_mission(2)
        dangling = (
            root
            / "units"
            / "SupermarketSession-20260904-100000-U0002"
            / "segment_0001"
            / "live_checkpoint.json"
        )
        os.symlink(self.tmp / "missing-checkpoint.json", dangling)
        report = mv.validate_mission(root)
        self.assertFalse(report.publish_permitted)
        self.assertIn(
            "unit_live_checkpoint_present", {item.code for item in report.findings}
        )

    def test_fake_database_and_missing_sidecar_are_fatal(self) -> None:
        root = self._make_mission(1)
        segment = root / "units" / "SupermarketSession-20260904-100000-U0001" / "segment_0001"
        database = segment / "rtabmap_segment_0001.db"
        database.write_bytes(b"sqlite-payload")
        (segment / "trajectory_samples.json").unlink()
        manifest_path = root / "mission_manifest.json"
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        manifest["units"][0]["databaseSha256"] = _sha256_file(database)
        manifest_path.write_text(json.dumps(manifest, sort_keys=True), encoding="utf-8")
        codes = {item.code for item in mv.validate_mission(root).findings}
        self.assertIn("unit_database_invalid", codes)
        self.assertIn("unit_sidecar_invalid", codes)

    def test_foreign_unit_mission_identity_is_fatal(self) -> None:
        root = self._make_mission(1)
        metadata_path = root / "units" / "SupermarketSession-20260904-100000-U0001" / "segment_0001" / "metadata.json"
        metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
        metadata["missionId"] = "mission-foreign"
        metadata_path.write_text(json.dumps(metadata, sort_keys=True), encoding="utf-8")
        manifest_path = root / "mission_manifest.json"
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        manifest["units"][0]["metadataSha256"] = _sha256_file(metadata_path)
        manifest_path.write_text(json.dumps(manifest, sort_keys=True), encoding="utf-8")
        report = mv.validate_mission(root)
        self.assertFalse(report.publish_permitted)
        self.assertIn("mission_identity_drift", {item.code for item in report.findings})

    def test_free_mapping_unit_is_not_a_prior_map_mission(self) -> None:
        root = self._make_mission(1)
        metadata_path = root / "units" / "SupermarketSession-20260904-100000-U0001" / "segment_0001" / "metadata.json"
        metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
        metadata["workflowMode"] = "free_mapping"
        metadata_path.write_text(json.dumps(metadata, sort_keys=True), encoding="utf-8")
        manifest_path = root / "mission_manifest.json"
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        manifest["units"][0]["metadataSha256"] = _sha256_file(metadata_path)
        manifest_path.write_text(json.dumps(manifest, sort_keys=True), encoding="utf-8")
        report = mv.validate_mission(root)
        self.assertFalse(report.publish_permitted)
        self.assertIn("unit_workflow_mode_invalid", {item.code for item in report.findings})

        metadata["workflowMode"] = "prior_map_localized"
        metadata["captureHealth"]["localizationRequiredWriteFailureCount"] = False
        metadata_path.write_text(json.dumps(metadata, sort_keys=True), encoding="utf-8")
        manifest["units"][0]["metadataSha256"] = _sha256_file(metadata_path)
        manifest_path.write_text(json.dumps(manifest, sort_keys=True), encoding="utf-8")
        strict_report = mv.validate_mission(root)
        self.assertFalse(strict_report.publish_permitted)
        self.assertIn(
            "unit_localization_evidence_incomplete",
            {item.code for item in strict_report.findings},
        )

    def test_declared_paths_and_digests_are_mandatory(self) -> None:
        root = self._make_mission(1)
        manifest_path = root / "mission_manifest.json"
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        unit = manifest["units"][0]
        unit.pop("databaseSha256")
        unit.pop("metadataSha256")
        unit["databaseRelativePath"] = "../../foreign.db"
        unit["metadataRelativePath"] = "units/other/metadata.json"
        manifest_path.write_text(json.dumps(manifest, sort_keys=True), encoding="utf-8")
        codes = {item.code for item in mv.validate_mission(root).findings}
        self.assertIn("mission_database_digest_missing", codes)
        self.assertIn("mission_metadata_digest_missing", codes)
        self.assertIn("mission_database_path_mismatch", codes)
        self.assertIn("mission_metadata_path_mismatch", codes)

    def test_unverified_manifest_and_live_checkpoint_never_publish(self) -> None:
        root = self._make_mission(1)
        manifest_path = root / "mission_manifest.json"
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        manifest["integrity"] = "unverified"
        manifest["publishPermitted"] = False
        manifest_path.write_text(json.dumps(manifest, sort_keys=True), encoding="utf-8")
        (root / "mission_live_checkpoint.json").write_text("{}", encoding="utf-8")
        report = mv.validate_mission(root)
        codes = {item.code for item in report.findings}
        self.assertFalse(report.publish_permitted)
        self.assertIn("mission_live_checkpoint_present", codes)
        self.assertIn("mission_manifest_integrity_unverified", codes)
        self.assertIn("mission_manifest_publish_denied", codes)

    def test_boundary_end_types_tracking_and_hashes_are_strict(self) -> None:
        root = self._make_mission(2)
        boundary_path = root / "boundaries" / "boundary_0001.json"
        boundary = json.loads(boundary_path.read_text(encoding="utf-8"))
        boundary["outgoing"]["nodeId"] = "101"
        boundary["outgoing"]["nodeTimeSnapshotGeneration"] = -1
        boundary["outgoing"]["trackingSessionId"] = "foreign-tracking"
        boundary["outgoing"]["manualEventSha256"] = "missing"
        boundary_path.write_text(json.dumps(boundary, sort_keys=True), encoding="utf-8")
        manifest_path = root / "mission_manifest.json"
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        declared = dict(boundary)
        declared["fileSha256"] = _sha256_file(boundary_path)
        manifest["boundaries"] = [declared]
        manifest_path.write_text(json.dumps(manifest, sort_keys=True), encoding="utf-8")
        report = mv.validate_mission(root)
        self.assertFalse(report.publish_permitted)
        self.assertIn("boundary_outgoing_incomplete", {item.code for item in report.findings})

    def test_extra_complete_nonadjacent_boundary_is_fatal(self) -> None:
        root = self._make_mission(3)
        extra = _boundary(
            "mission-0001", "boundary-extra", "unit-0001", "unit-0003"
        )
        path = root / "boundaries" / "boundary_9999.json"
        path.write_text(json.dumps(extra, sort_keys=True), encoding="utf-8")
        declared = dict(extra)
        declared["fileSha256"] = _sha256_file(path)
        manifest_path = root / "mission_manifest.json"
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        manifest["boundaries"].append(declared)
        manifest_path.write_text(json.dumps(manifest, sort_keys=True), encoding="utf-8")
        report = mv.validate_mission(root)
        codes = {item.code for item in report.findings}
        self.assertFalse(report.publish_permitted)
        self.assertTrue({"boundary_units_nonadjacent", "boundary_nonadjacent"} & codes)

    def test_unexpected_boundary_file_is_fatal(self) -> None:
        root = self._make_mission(1)
        (root / "boundaries" / "notes.txt").write_text("unexpected", encoding="utf-8")
        report = mv.validate_mission(root)
        self.assertFalse(report.publish_permitted)
        self.assertIn(
            "boundary_file_unexpected",
            {item.code for item in report.findings},
        )

    def test_report_is_json_serialisable(self) -> None:
        root = self._make_mission(2)
        payload = mv.inspect_mission(root)
        json.dumps(payload)
        self.assertEqual(payload["status"], mv.STATUS_COMPLETE)
        self.assertEqual(payload["totals"]["units"], 2)
        self.assertEqual(payload["totals"]["verified_units"], 2)


if __name__ == "__main__":
    unittest.main(verbosity=2)
