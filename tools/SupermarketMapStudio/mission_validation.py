#!/usr/bin/env python3
"""Strict validation for MarketScanner store missions.

Implements the PC input checks of
``docs/map-assisted-localization/PERIODIC_MANUAL_CALIBRATION_AND_AUTO_ROLLOVER_REQUIREMENTS_2026-09-04.md``
section 11.1:

* a mission is only complete when ``mission_manifest.json`` is present;
  ``mission_live_checkpoint.json`` means the mission is still running and may
  only be inspected, never published;
* every unit must keep the existing single-session shape (one
  ``segment_0001``, ``continuous_streaming``, ``finalized=true``, no live
  checkpoint, readable sidecars);
* unit indices must be ``1..N`` without gaps, duplicates or reordering;
* the previous-metadata hash chain must verify against the bytes on disk;
* adjacent units must be linked by exactly one complete two-sided boundary;
* symlinks, hard links, absolute paths and ``..`` escapes are fatal.

The module is dependency-light on purpose: it must stay runnable and testable
without the Map Studio runtime state, and it never mutates phone data.
"""

from __future__ import annotations

import hashlib
import json
import math
import os
import sqlite3
import stat
from contextlib import closing
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

MANIFEST_NAME = "mission_manifest.json"
LIVE_CHECKPOINT_NAME = "mission_live_checkpoint.json"
EVENT_LOG_NAME = "mission_events.jsonl"
UNITS_DIRNAME = "units"
BOUNDARIES_DIRNAME = "boundaries"

FORMAT_MANIFEST = "marketscanner_mission_manifest"
FORMAT_LIVE_CHECKPOINT = "marketscanner_mission_live_checkpoint"
FORMAT_BOUNDARY = "marketscanner_mission_boundary"
FORMAT_VERSION = 1
POLICY_VERSION = 1

POSE_TOLERANCE_M = 1e-6
YAW_TOLERANCE_RAD = 1e-6

STATUS_COMPLETE = "complete"
STATUS_PARTIAL = "partial"
STATUS_DIAGNOSTIC = "diagnostic"
STATUS_INVALID = "invalid"

SEVERITY_FATAL = "fatal"
SEVERITY_WARNING = "warning"
SEVERITY_INFO = "info"

_READ_CHUNK = 1024 * 1024
_MAX_JSON_BYTES = 128 * 1024 * 1024
_REQUIRED_JSON_SIDECARS = {
    "price_tags.json": list,
    "scan_area_cells.json": dict,
    "structure_coverage_cells.json": dict,
    "trajectory_samples.json": (dict, list),
}
_REQUIRED_TEXT_SIDECARS = ("price_tags.csv", "trajectory_samples.csv")


@dataclass
class Finding:
    severity: str
    code: str
    message: str
    unit: Optional[int] = None

    def as_dict(self) -> Dict[str, Any]:
        payload = asdict(self)
        return {key: value for key, value in payload.items() if value is not None}


@dataclass
class UnitReport:
    unit_id: Optional[str]
    unit_index: Optional[int]
    relative_path: Optional[str]
    database: Optional[str] = None
    metadata_path: Optional[str] = None
    finalized: Optional[bool] = None
    scan_mode: Optional[str] = None
    workflow_mode: Optional[str] = None
    segment_count: int = 0
    database_bytes: Optional[int] = None
    database_sha256: Optional[str] = None
    metadata_sha256: Optional[str] = None
    previous_unit_id: Optional[str] = None
    previous_unit_metadata_sha256: Optional[str] = None
    boundary_checkpoint_id: Optional[str] = None
    active_capture_duration_s: Optional[float] = None
    rollover_trigger: Optional[str] = None
    prior_map_id: Optional[str] = None
    prior_map_package_sha256: Optional[str] = None
    store_id: Optional[str] = None
    floor_id: Optional[str] = None
    mission_id: Optional[str] = None
    tracking_session_id: Optional[str] = None
    build_identity: Optional[str] = None
    node_count: Optional[int] = None
    findings: List[Finding] = field(default_factory=list)

    @property
    def verified(self) -> bool:
        return not any(item.severity == SEVERITY_FATAL for item in self.findings)

    def as_dict(self) -> Dict[str, Any]:
        payload = asdict(self)
        payload["findings"] = [item.as_dict() for item in self.findings]
        payload["verified"] = self.verified
        return payload


@dataclass
class BoundaryReport:
    boundary_id: str
    from_unit_id: Optional[str]
    to_unit_id: Optional[str]
    complete: bool
    file: Optional[str] = None
    file_sha256: Optional[str] = None
    findings: List[Finding] = field(default_factory=list)

    def as_dict(self) -> Dict[str, Any]:
        payload = asdict(self)
        payload["findings"] = [item.as_dict() for item in self.findings]
        return payload


@dataclass
class MissionReport:
    root: str
    kind: str
    status: str
    publish_permitted: bool
    mission_id: Optional[str] = None
    identity: Dict[str, Any] = field(default_factory=dict)
    units: List[UnitReport] = field(default_factory=list)
    boundaries: List[BoundaryReport] = field(default_factory=list)
    findings: List[Finding] = field(default_factory=list)
    total_bytes: int = 0
    total_active_capture_s: float = 0.0

    def as_dict(self) -> Dict[str, Any]:
        return {
            "root": self.root,
            "kind": self.kind,
            "status": self.status,
            "publish_permitted": self.publish_permitted,
            "mission_id": self.mission_id,
            "identity": self.identity,
            "units": [unit.as_dict() for unit in self.units],
            "boundaries": [boundary.as_dict() for boundary in self.boundaries],
            "findings": [item.as_dict() for item in self.findings],
            "totals": {
                "bytes": self.total_bytes,
                "active_capture_s": round(self.total_active_capture_s, 3),
                "units": len(self.units),
                "boundaries": len(self.boundaries),
                "verified_units": sum(1 for unit in self.units if unit.verified),
            },
        }


# --------------------------------------------------------------------------
# helpers
# --------------------------------------------------------------------------


def sha256_file(path: Path) -> Optional[str]:
    """Stable SHA-256 of one unlinked regular file."""
    digest = hashlib.sha256()
    try:
        before = os.lstat(path)
        if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
            return None
        descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
        opened = os.fstat(descriptor)
        if (before.st_dev, before.st_ino) != (opened.st_dev, opened.st_ino):
            os.close(descriptor)
            return None
        with os.fdopen(descriptor, "rb") as handle:
            while True:
                chunk = handle.read(_READ_CHUNK)
                if not chunk:
                    break
                digest.update(chunk)
            after_open = os.fstat(handle.fileno())
        after = os.lstat(path)
    except OSError:
        return None
    identity = lambda value: (
        value.st_dev, value.st_ino, value.st_size,
        getattr(value, "st_mtime_ns", int(value.st_mtime * 1_000_000_000)),
        value.st_nlink,
    )
    if identity(before) != identity(after_open) or identity(before) != identity(after):
        return None
    return digest.hexdigest()


def _is_link(path: Path) -> bool:
    """Symlink or hard-link detection (section 9.2 rejects both)."""
    if path.is_symlink():
        return True
    try:
        info = os.lstat(path)
    except OSError:
        return False
    if stat.S_ISDIR(info.st_mode):
        return False
    return int(getattr(info, "st_nlink", 1)) > 1


def _safe_relative_path(root: Path, candidate: Any) -> Tuple[Optional[Path], Optional[str]]:
    """Resolve a mission-relative path, rejecting every escape variant."""
    if not isinstance(candidate, str) or not candidate.strip():
        return None, "path_missing"
    raw = candidate.strip()
    if raw.startswith("/") or raw.startswith("~") or "\\" in raw:
        return None, "path_not_relative"
    if raw.startswith(":") or ":" in raw.split("/")[0]:
        return None, "path_not_relative"
    if any(part == ".." for part in raw.split("/")):
        return None, "path_parent_escape"
    resolved_root = root.resolve()
    parts = [part for part in raw.split("/") if part not in ("", ".")]
    if not parts:
        # "." is the mission root itself and is only legal for the legacy
        # single-session shape, where the session directory holds segment_0001.
        return resolved_root, None
    candidate = resolved_root.joinpath(*parts)
    cursor = resolved_root
    for part in parts:
        cursor = cursor / part
        if not os.path.lexists(cursor):
            continue
        try:
            info = os.lstat(cursor)
        except OSError:
            return None, "path_unreadable"
        if stat.S_ISLNK(info.st_mode):
            return None, "link_detected"
        if stat.S_ISREG(info.st_mode) and info.st_nlink != 1:
            return None, "link_detected"
    target = candidate.resolve()
    try:
        target.relative_to(resolved_root)
    except ValueError:
        return None, "path_outside_root"
    return target, None


def _stat_identity(value: os.stat_result) -> Tuple[int, int, int, int, int]:
    return (
        value.st_dev,
        value.st_ino,
        value.st_size,
        getattr(value, "st_mtime_ns", int(value.st_mtime * 1_000_000_000)),
        value.st_nlink,
    )


def _read_regular_bytes(
    path: Path, maximum_bytes: int = _MAX_JSON_BYTES
) -> Tuple[Optional[bytes], Optional[str]]:
    try:
        before = os.lstat(path)
        if (not stat.S_ISREG(before.st_mode) or before.st_nlink != 1
                or before.st_size > maximum_bytes):
            return None, "not_regular_or_size_limit"
        descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
        with os.fdopen(descriptor, "rb") as handle:
            opened = os.fstat(handle.fileno())
            if _stat_identity(before) != _stat_identity(opened):
                return None, "identity_changed"
            data = handle.read(maximum_bytes + 1)
            after_open = os.fstat(handle.fileno())
        after_path = os.lstat(path)
        if len(data) > maximum_bytes:
            return None, "size_limit"
        if (_stat_identity(before) != _stat_identity(after_open)
                or _stat_identity(before) != _stat_identity(after_path)):
            return None, "identity_changed"
        return data, None
    except OSError as error:
        return None, f"unreadable:{error.__class__.__name__}"


def _read_json(path: Path) -> Tuple[Optional[Any], Optional[str]]:
    try:
        data, error = _read_regular_bytes(path)
        if data is None:
            return None, error
        return json.loads(data.decode("utf-8")), None
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        return None, f"unreadable:{error.__class__.__name__}"


def _finite_number(value: Any) -> Optional[float]:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    result = float(value)
    return result if math.isfinite(result) else None


def _is_sha256(value: Any) -> bool:
    return isinstance(value, str) and len(value) == 64 and all(
        character in "0123456789abcdefABCDEF" for character in value
    )


def _positive_int(value: Any) -> Optional[int]:
    if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
        return None
    return value


def _validate_database(path: Path) -> Tuple[Optional[int], Optional[str]]:
    """Apply the existing PC production DB gate without importing server state."""
    try:
        uri = path.resolve().as_uri() + "?mode=ro&immutable=1"
        with closing(sqlite3.connect(uri, uri=True)) as connection:
            quick = connection.execute("PRAGMA quick_check").fetchone()
            if not quick or quick[0] != "ok":
                return None, f"quick_check:{quick[0] if quick else 'unknown'}"
            tables = {
                str(row[0])
                for row in connection.execute(
                    "SELECT name FROM sqlite_master WHERE type='table'"
                )
            }
            if "Node" not in tables or "Data" not in tables:
                return None, "required_tables_missing"
            node_count = int(
                connection.execute("SELECT count(*) FROM Node WHERE id > 0").fetchone()[0]
            )
            if node_count <= 0:
                return None, "mapping_nodes_missing"
            data_columns = {
                str(row[1]) for row in connection.execute("PRAGMA table_info(Data)")
            }
            if not {"image", "depth", "calibration"}.issubset(data_columns):
                return None, "rgbd_columns_missing"
            rgbd_count = int(connection.execute(
                "SELECT count(*) FROM Data "
                "WHERE length(image)>0 AND length(depth)>0 AND length(calibration)>0"
            ).fetchone()[0])
            if rgbd_count <= 0:
                return None, "rgbd_frames_missing"
            node_columns = {
                str(row[1]) for row in connection.execute("PRAGMA table_info(Node)")
            }
            if "stamp" in node_columns:
                previous: Optional[float] = None
                for (stamp_value,) in connection.execute(
                    "SELECT stamp FROM Node WHERE id > 0 ORDER BY id"
                ):
                    if stamp_value is None:
                        continue
                    stamp_value = float(stamp_value)
                    if previous is not None and stamp_value < previous:
                        return None, "timestamp_regression"
                    previous = stamp_value
            return node_count, None
    except (OSError, sqlite3.Error, TypeError, ValueError) as error:
        return None, f"unreadable:{error.__class__.__name__}"


def _validate_sidecars(segment: Path) -> List[Finding]:
    findings: List[Finding] = []
    for name, expected_type in _REQUIRED_JSON_SIDECARS.items():
        path = segment / name
        payload, error = _read_json(path)
        if error is not None or not isinstance(payload, expected_type):
            findings.append(_finding(
                SEVERITY_FATAL,
                "unit_sidecar_invalid",
                f"{name}: {error or 'unexpected JSON shape'}",
            ))
    for name in _REQUIRED_TEXT_SIDECARS:
        path = segment / name
        try:
            data, read_error = _read_regular_bytes(path)
            if data is None:
                raise OSError(read_error or "missing_or_linked")
            if data and not data.endswith(b"\n"):
                raise ValueError("missing_final_newline")
            data.decode("utf-8")
        except (OSError, UnicodeDecodeError, ValueError) as error:
            findings.append(_finding(
                SEVERITY_FATAL,
                "unit_sidecar_invalid",
                f"{name}: {error}",
            ))
    events = segment / "scan_events.jsonl"
    try:
        raw, read_error = _read_regular_bytes(events)
        if raw is None:
            raise OSError(read_error or "missing_or_linked")
        if not raw or not raw.endswith(b"\n"):
            raise ValueError("missing_final_newline")
        for line in raw.decode("utf-8").splitlines():
            if not line or not isinstance(json.loads(line), dict):
                raise ValueError("invalid_jsonl_record")
    except (OSError, UnicodeDecodeError, ValueError, json.JSONDecodeError) as error:
        findings.append(_finding(
            SEVERITY_FATAL, "unit_sidecar_invalid", f"scan_events.jsonl: {error}"
        ))
    return findings


def _normalized_yaw_delta(lhs: float, rhs: float) -> float:
    delta = math.remainder(lhs - rhs, 2.0 * math.pi)
    return abs(delta)


def _finding(severity: str, code: str, message: str, unit: Optional[int] = None) -> Finding:
    return Finding(severity=severity, code=code, message=message, unit=unit)


# --------------------------------------------------------------------------
# unit validation
# --------------------------------------------------------------------------


def validate_unit(
    root: Path,
    relative_path: str,
    expected_index: Optional[int] = None,
    require_mission_fields: bool = True,
) -> UnitReport:
    """Validate one unit directory with the existing single-session rules.

    `require_mission_fields=False` only applies to the legacy single-session
    shape, which predates the mission container and therefore carries no
    `missionId` / `unitId`. Every real mission unit must declare both, because
    the boundary hash chain is keyed by unit id: a missing id would make the
    boundary and hash-chain checks pass vacuously.
    """
    target, error = _safe_relative_path(root, relative_path)
    report = UnitReport(
        unit_id=None,
        unit_index=expected_index,
        relative_path=relative_path,
    )
    if error is not None or target is None:
        report.findings.append(
            _finding(SEVERITY_FATAL, f"unit_{error or 'path_invalid'}", relative_path)
        )
        return report
    if _is_link(target):
        report.findings.append(
            _finding(SEVERITY_FATAL, "unit_link_detected", relative_path)
        )
        return report
    if not target.is_dir():
        report.findings.append(
            _finding(SEVERITY_FATAL, "unit_missing", relative_path)
        )
        return report

    segment_dirs = sorted(path for path in target.glob("segment_*") if path.is_dir())
    report.segment_count = len(segment_dirs)
    if len(segment_dirs) != 1 or segment_dirs[0].name != "segment_0001":
        report.findings.append(
            _finding(
                SEVERITY_FATAL,
                "unit_segment_layout_invalid",
                f"{relative_path} must contain exactly one segment_0001 directory.",
            )
        )
        return report

    segment = segment_dirs[0]
    metadata_path = segment / "metadata.json"
    database_path = segment / "rtabmap_segment_0001.db"
    live_checkpoint = segment / "live_checkpoint.json"
    for suffix in ("-wal", "-shm", "-journal"):
        residue = Path(str(database_path) + suffix)
        if os.path.lexists(residue):
            report.findings.append(_finding(
                SEVERITY_FATAL,
                "unit_database_residue_present",
                residue.name,
            ))

    # Link checks before any read: a linked database or metadata file must be
    # named as such, not silently followed.
    for candidate, code in (
        (segment, "unit_segment_link_detected"),
        (database_path, "unit_database_link_detected"),
        (metadata_path, "unit_metadata_link_detected"),
    ):
        if _is_link(candidate):
            report.findings.append(_finding(SEVERITY_FATAL, code, relative_path))
            return report

    if not database_path.is_file():
        report.findings.append(
            _finding(SEVERITY_FATAL, "unit_database_missing", relative_path)
        )
    else:
        report.database = _relative(root, database_path)
        report.database_bytes = database_path.stat().st_size
        report.database_sha256 = sha256_file(database_path)
        if report.database_sha256 is None:
            report.findings.append(
                _finding(SEVERITY_FATAL, "unit_database_unreadable", relative_path)
            )
        node_count, database_error = _validate_database(database_path)
        report.node_count = node_count
        if database_error is not None:
            report.findings.append(_finding(
                SEVERITY_FATAL,
                "unit_database_invalid",
                f"{relative_path}: {database_error}",
            ))

    metadata, metadata_error = _read_json(metadata_path)
    if metadata is None or not isinstance(metadata, dict):
        report.findings.append(
            _finding(
                SEVERITY_FATAL,
                "unit_metadata_unreadable",
                f"{relative_path}: {metadata_error or 'metadata.json is not an object'}",
            )
        )
        return report

    report.metadata_path = _relative(root, metadata_path)
    report.metadata_sha256 = sha256_file(metadata_path)
    report.finalized = metadata.get("finalized") if isinstance(metadata.get("finalized"), bool) else None
    scan_mode = metadata.get("scanMode") or metadata.get("scan_mode")
    if isinstance(scan_mode, str):
        normalized = scan_mode.strip().lower().replace("-", "_")
        if normalized in {"continuous", "streaming", "streaming_single_database", "continuous_streaming"}:
            report.scan_mode = "continuous_streaming"
        elif normalized in {"segment", "legacy_segmented", "segmented"}:
            report.scan_mode = "segmented"
        else:
            report.scan_mode = normalized
    workflow = metadata.get("workflowMode") or metadata.get("workflow_mode")
    report.workflow_mode = workflow if isinstance(workflow, str) else None
    report.unit_id = metadata.get("unitId") if isinstance(metadata.get("unitId"), str) else ""
    if not report.unit_id:
        report.unit_id = None
    report.prior_map_id = metadata.get("priorMapId") if isinstance(metadata.get("priorMapId"), str) else None
    report.prior_map_package_sha256 = (
        metadata.get("priorMapSha256")
        if isinstance(metadata.get("priorMapSha256"), str)
        else None
    )
    report.store_id = metadata.get("storeId") if isinstance(metadata.get("storeId"), str) else None
    report.floor_id = metadata.get("floorId") if isinstance(metadata.get("floorId"), str) else None
    report.mission_id = (
        metadata.get("missionId") if isinstance(metadata.get("missionId"), str) else None
    )
    report.tracking_session_id = (
        metadata.get("trackingSessionId")
        if isinstance(metadata.get("trackingSessionId"), str)
        else None
    )
    build_value = metadata.get("buildIdentity") or metadata.get("appGitSHA")
    report.build_identity = build_value if isinstance(build_value, str) else None
    report.previous_unit_id = (
        metadata.get("previousUnitId") if isinstance(metadata.get("previousUnitId"), str) else None
    )
    report.previous_unit_metadata_sha256 = (
        metadata.get("previousUnitMetadataSha256")
        if isinstance(metadata.get("previousUnitMetadataSha256"), str)
        else None
    )
    report.boundary_checkpoint_id = (
        metadata.get("boundaryCheckpointId")
        if isinstance(metadata.get("boundaryCheckpointId"), str)
        else None
    )
    report.active_capture_duration_s = _finite_number(metadata.get("activeCaptureDurationS"))
    trigger = metadata.get("rolloverTrigger")
    report.rollover_trigger = trigger if isinstance(trigger, str) else None
    index_value = metadata.get("unitIndex")
    if isinstance(index_value, int) and not isinstance(index_value, bool):
        if expected_index is not None and index_value != expected_index:
            report.findings.append(
                _finding(
                    SEVERITY_FATAL,
                    "unit_index_mismatch",
                    f"{relative_path} declares unitIndex={index_value} but is listed as {expected_index}.",
                    unit=index_value,
                )
            )
        report.unit_index = index_value
    elif require_mission_fields:
        report.findings.append(
            _finding(SEVERITY_FATAL, "unit_index_missing", relative_path)
        )

    if require_mission_fields:
        if not report.unit_id:
            report.findings.append(
                _finding(SEVERITY_FATAL, "unit_id_missing", relative_path)
            )
        if not report.mission_id:
            report.findings.append(
                _finding(SEVERITY_FATAL, "unit_mission_id_missing", relative_path)
            )
        for value, code in (
            (report.tracking_session_id, "unit_tracking_session_missing"),
            (report.prior_map_id, "unit_prior_map_id_missing"),
            (report.store_id, "unit_store_id_missing"),
            (report.floor_id, "unit_floor_id_missing"),
            (report.build_identity, "unit_build_identity_missing"),
        ):
            if not value:
                report.findings.append(_finding(SEVERITY_FATAL, code, relative_path))
        if not _is_sha256(report.prior_map_package_sha256):
            report.findings.append(_finding(
                SEVERITY_FATAL, "unit_prior_map_digest_invalid", relative_path
            ))
        if report.workflow_mode != "prior_map_localized":
            report.findings.append(_finding(
                SEVERITY_FATAL, "unit_workflow_mode_invalid", relative_path
            ))
        capture_health = metadata.get("captureHealth")
        eligibility = metadata.get("processingEligibility")
        required_write_failures = (
            capture_health.get("localizationRequiredWriteFailureCount")
            if isinstance(capture_health, dict)
            else None
        )
        if (
            not isinstance(capture_health, dict)
            or isinstance(required_write_failures, bool)
            or required_write_failures != 0
            or capture_health.get("localizationEvidenceComplete") is not True
            or not isinstance(eligibility, dict)
            or eligibility.get("status") != "eligible"
            or eligibility.get("blockers") != []
        ):
            report.findings.append(_finding(
                SEVERITY_FATAL,
                "unit_localization_evidence_incomplete",
                relative_path,
            ))
        if report.active_capture_duration_s is None or report.active_capture_duration_s < 0:
            report.findings.append(_finding(
                SEVERITY_FATAL, "unit_active_duration_invalid", relative_path
            ))
    if report.finalized is not True:
        report.findings.append(
            _finding(SEVERITY_FATAL, "unit_not_finalized", relative_path)
        )
    if report.scan_mode != "continuous_streaming":
        report.findings.append(
            _finding(SEVERITY_FATAL, "unit_scan_mode_invalid", relative_path)
        )
    if require_mission_fields and report.node_count is not None:
        declared_node_count = metadata.get("nodeCount")
        if (not isinstance(declared_node_count, int)
                or isinstance(declared_node_count, bool)
                or declared_node_count != report.node_count):
            report.findings.append(_finding(
                SEVERITY_FATAL,
                "unit_node_count_mismatch",
                f"{relative_path}: metadata nodeCount does not match the database.",
            ))
    if require_mission_fields:
        report.findings.extend(_validate_sidecars(segment))
    # lexists: a dangling symlink at the checkpoint path is still a checkpoint
    # as far as the PC is concerned and must block publication.
    if os.path.lexists(live_checkpoint):
        report.findings.append(
            _finding(SEVERITY_FATAL, "unit_live_checkpoint_present", relative_path)
        )
    return report


def _relative(root: Path, path: Path) -> str:
    try:
        return path.resolve().relative_to(root.resolve()).as_posix()
    except ValueError:
        return path.as_posix()


# --------------------------------------------------------------------------
# boundary validation
# --------------------------------------------------------------------------


def _boundary_end_ok(
    end: Any,
    unit: Optional[UnitReport],
    pose: Tuple[float, float, float],
    *,
    required_hash: str,
) -> bool:
    if not isinstance(end, dict):
        return False
    if unit is None or end.get("unitId") != unit.unit_id:
        return False
    if _positive_int(end.get("unitIndex")) != unit.unit_index:
        return False
    if end.get("trackingSessionId") != unit.tracking_session_id:
        return False
    values = (
        _finite_number(end.get("confirmedX")),
        _finite_number(end.get("confirmedY")),
        _finite_number(end.get("confirmedYaw")),
    )
    if any(value is None for value in values):
        return False
    confirmed_x, confirmed_y, confirmed_yaw = values  # type: ignore[misc]
    if abs(confirmed_x - pose[0]) > POSE_TOLERANCE_M:
        return False
    if abs(confirmed_y - pose[1]) > POSE_TOLERANCE_M:
        return False
    if _normalized_yaw_delta(confirmed_yaw, pose[2]) > YAW_TOLERANCE_RAD:
        return False
    if _positive_int(end.get("nodeId")) is None:
        return False
    node_stamp = _finite_number(end.get("nodeStamp"))
    if node_stamp is None or node_stamp < 0:
        return False
    if _positive_int(end.get("nodeTimeSnapshotGeneration")) is None:
        return False
    if not _is_sha256(end.get(required_hash)):
        return False
    optional_hash = (
        "startReceiptSha256"
        if required_hash == "manualEventSha256"
        else "manualEventSha256"
    )
    if end.get(optional_hash) is not None and not _is_sha256(end.get(optional_hash)):
        return False
    return True


def validate_boundary(
    boundary: Any, mission_id: str, units: List[UnitReport]
) -> BoundaryReport:
    if not isinstance(boundary, dict):
        return BoundaryReport(
            boundary_id="",
            from_unit_id=None,
            to_unit_id=None,
            complete=False,
            findings=[_finding(SEVERITY_FATAL, "boundary_not_object", "Boundary record is not an object.")],
        )

    boundary_id = str(boundary.get("boundaryId") or "")
    report = BoundaryReport(
        boundary_id=boundary_id,
        from_unit_id=boundary.get("fromUnitId") if isinstance(boundary.get("fromUnitId"), str) else None,
        to_unit_id=boundary.get("toUnitId") if isinstance(boundary.get("toUnitId"), str) else None,
        complete=False,
        file_sha256=boundary.get("fileSha256") if isinstance(boundary.get("fileSha256"), str) else None,
    )

    if boundary.get("format") != FORMAT_BOUNDARY:
        report.findings.append(
            _finding(SEVERITY_FATAL, "boundary_format_invalid", boundary_id)
        )
    if boundary.get("version") != FORMAT_VERSION:
        report.findings.append(
            _finding(SEVERITY_FATAL, "boundary_version_unsupported", boundary_id)
        )
    if boundary.get("missionId") != mission_id:
        report.findings.append(
            _finding(SEVERITY_FATAL, "boundary_mission_mismatch", boundary_id)
        )
    if not boundary_id:
        report.findings.append(
            _finding(SEVERITY_FATAL, "boundary_id_missing", "Boundary has no identifier.")
        )
    if not _is_sha256(report.file_sha256):
        report.findings.append(
            _finding(SEVERITY_FATAL, "boundary_digest_missing", boundary_id)
        )
    created = _finite_number(boundary.get("createdAtUnix"))
    committed = _finite_number(boundary.get("committedAtUnix"))
    if created is None or created < 0 or committed is None or committed < created:
        report.findings.append(
            _finding(SEVERITY_FATAL, "boundary_commit_time_invalid", boundary_id)
        )

    pose_values = (
        _finite_number(boundary.get("confirmedX")),
        _finite_number(boundary.get("confirmedY")),
        _finite_number(boundary.get("confirmedYaw")),
    )
    if any(value is None for value in pose_values):
        report.findings.append(
            _finding(SEVERITY_FATAL, "boundary_pose_invalid", boundary_id)
        )
        return report
    pose: Tuple[float, float, float] = (
        pose_values[0],  # type: ignore[index]
        pose_values[1],  # type: ignore[index]
        pose_values[2],  # type: ignore[index]
    )

    by_id = {unit.unit_id: unit for unit in units if unit.unit_id}
    from_unit = by_id.get(report.from_unit_id)
    to_unit = by_id.get(report.to_unit_id)
    outgoing = boundary.get("outgoing")
    incoming = boundary.get("incoming")
    outgoing_ok = _boundary_end_ok(
        outgoing, from_unit, pose, required_hash="manualEventSha256"
    )
    incoming_ok = _boundary_end_ok(
        incoming, to_unit, pose, required_hash="startReceiptSha256"
    )
    if not outgoing_ok:
        report.findings.append(
            _finding(SEVERITY_FATAL, "boundary_outgoing_incomplete", boundary_id)
        )
    if not incoming_ok:
        report.findings.append(
            _finding(SEVERITY_FATAL, "boundary_incoming_incomplete", boundary_id)
        )

    known_ids = {unit.unit_id for unit in units if unit.unit_id}
    # Empty identifiers are rejected explicitly: `None in known_ids` would
    # otherwise make a boundary without unit ids look valid.
    if not report.from_unit_id or not report.to_unit_id:
        report.findings.append(
            _finding(SEVERITY_FATAL, "boundary_unit_id_missing", boundary_id)
        )
    elif report.from_unit_id not in known_ids or report.to_unit_id not in known_ids:
        report.findings.append(
            _finding(SEVERITY_FATAL, "boundary_unit_unknown", boundary_id)
        )
    if from_unit and to_unit and (
        from_unit.unit_index is None
        or to_unit.unit_index != from_unit.unit_index + 1
    ):
        report.findings.append(
            _finding(SEVERITY_FATAL, "boundary_units_nonadjacent", boundary_id)
        )
    expected_identity = {
        "priorMapId": from_unit.prior_map_id if from_unit else None,
        "priorMapPackageSha256": (
            from_unit.prior_map_package_sha256 if from_unit else None
        ),
        "storeId": from_unit.store_id if from_unit else None,
        "floorId": from_unit.floor_id if from_unit else None,
    }
    for key, expected in expected_identity.items():
        if not expected or boundary.get(key) != expected:
            report.findings.append(_finding(
                SEVERITY_FATAL, "boundary_identity_mismatch", f"{boundary_id}:{key}"
            ))

    report.complete = bool(
        outgoing_ok and incoming_ok and not any(
            item.severity == SEVERITY_FATAL for item in report.findings
        )
    )
    return report


# --------------------------------------------------------------------------
# mission validation
# --------------------------------------------------------------------------


def _looks_like_legacy_session(root: Path) -> bool:
    return (root / "segment_0001").is_dir() and not (root / UNITS_DIRNAME).is_dir()


def validate_legacy_session(root: Path) -> MissionReport:
    """A single ``SupermarketSession-*`` is a legacy one-unit mission."""
    report = MissionReport(
        root=str(root),
        kind="legacy_session",
        status=STATUS_INVALID,
        publish_permitted=False,
    )
    unit = validate_unit(root, ".", expected_index=1, require_mission_fields=False)
    # Validate the session root itself: it holds segment_0001 directly.
    unit.relative_path = "."
    report.units = [unit]
    report.findings.extend(unit.findings)
    metadata = _read_json(root / "segment_0001" / "metadata.json")[0]
    if isinstance(metadata, dict):
        report.identity = {
            "prior_map_id": metadata.get("priorMapId"),
            "prior_map_package_sha256": metadata.get("priorMapSha256"),
            "store_id": metadata.get("storeId"),
            "floor_id": metadata.get("floorId"),
        }
        report.mission_id = metadata.get("missionId") if isinstance(metadata.get("missionId"), str) else None
    report.total_bytes = unit.database_bytes or 0
    report.total_active_capture_s = unit.active_capture_duration_s or 0.0
    if unit.verified:
        report.status = STATUS_COMPLETE
        report.publish_permitted = True
        report.findings.append(
            _finding(
                SEVERITY_INFO,
                "legacy_single_session",
                "Legacy single session: processed as one mission unit.",
                unit=1,
            )
        )
    else:
        report.status = STATUS_INVALID
    return report


def inspect_mission(root: Path) -> Dict[str, Any]:
    """Validate a mission directory and return a JSON-serialisable report."""
    return validate_mission(root).as_dict()


def validate_mission(root: Path) -> MissionReport:
    path = Path(root)
    report = MissionReport(
        root=str(path),
        kind="mission",
        status=STATUS_INVALID,
        publish_permitted=False,
    )

    if not path.exists() or not path.is_dir():
        report.findings.append(
            _finding(SEVERITY_FATAL, "mission_root_missing", str(path))
        )
        return report
    if _is_link(path):
        report.findings.append(
            _finding(SEVERITY_FATAL, "mission_root_link_detected", str(path))
        )
        return report

    if _looks_like_legacy_session(path):
        return validate_legacy_session(path)

    manifest_path = path / MANIFEST_NAME
    checkpoint_path = path / LIVE_CHECKPOINT_NAME
    has_manifest = manifest_path.is_file()
    has_checkpoint = os.path.lexists(checkpoint_path)

    if not has_manifest and not has_checkpoint:
        report.findings.append(
            _finding(
                SEVERITY_FATAL,
                "mission_container_unrecognized",
                "Neither mission_manifest.json nor mission_live_checkpoint.json exists.",
            )
        )
        return report

    if not has_manifest:
        running_state, checkpoint = _read_running_checkpoint(report, checkpoint_path)
        report.status = STATUS_DIAGNOSTIC
        report.publish_permitted = False
        report.findings.append(
            _finding(
                SEVERITY_WARNING,
                "mission_not_completed",
                "The mission is still running; only diagnostic inspection is allowed.",
            )
        )
        report.identity = running_state
        _collect_running_units(report, path, checkpoint)
        return report

    if has_checkpoint:
        report.findings.append(_finding(
            SEVERITY_FATAL,
            "mission_live_checkpoint_present",
            "A completion manifest and live checkpoint cannot coexist.",
        ))


    manifest, error = _read_json(manifest_path)
    if manifest is None or not isinstance(manifest, dict):
        report.findings.append(
            _finding(
                SEVERITY_FATAL,
                "mission_manifest_unreadable",
                error or "mission_manifest.json is not an object",
            )
        )
        return report
    if manifest.get("format") != FORMAT_MANIFEST:
        report.findings.append(
            _finding(SEVERITY_FATAL, "mission_manifest_format_invalid", MANIFEST_NAME)
        )
        return report
    if manifest.get("version") != FORMAT_VERSION:
        report.findings.append(
            _finding(SEVERITY_FATAL, "mission_manifest_version_unsupported", MANIFEST_NAME)
        )
        return report

    report.mission_id = manifest.get("missionId") if isinstance(manifest.get("missionId"), str) else None
    if not report.mission_id:
        report.findings.append(
            _finding(SEVERITY_FATAL, "mission_id_missing", MANIFEST_NAME)
        )
    identity = manifest.get("identity")
    if isinstance(identity, dict):
        report.identity = {
            "mission_id": identity.get("missionId"),
            "prior_map_id": identity.get("priorMapId"),
            "prior_map_package_sha256": identity.get("priorMapPackageSha256"),
            "store_id": identity.get("storeId"),
            "floor_id": identity.get("floorId"),
            "build_identity": identity.get("buildIdentity"),
        }
        for key in (
            "mission_id", "prior_map_id", "store_id", "floor_id", "build_identity"
        ):
            if not isinstance(report.identity.get(key), str) or not report.identity[key]:
                report.findings.append(_finding(
                    SEVERITY_FATAL, "mission_identity_incomplete", key
                ))
        if report.identity.get("mission_id") != report.mission_id:
            report.findings.append(_finding(
                SEVERITY_FATAL, "mission_identity_id_mismatch", MANIFEST_NAME
            ))
        if not _is_sha256(report.identity.get("prior_map_package_sha256")):
            report.findings.append(_finding(
                SEVERITY_FATAL, "mission_identity_digest_invalid", MANIFEST_NAME
            ))
    else:
        report.findings.append(
            _finding(SEVERITY_FATAL, "mission_identity_missing", MANIFEST_NAME)
        )
    if manifest.get("policyVersion") is not None and manifest.get("policyVersion") != POLICY_VERSION:
        report.findings.append(
            _finding(
                SEVERITY_FATAL,
                "mission_policy_version_unsupported",
                f"Unsupported maintenance policy version {manifest.get('policyVersion')}.",
            )
        )
    completed_at = _finite_number(manifest.get("completedAtUnix"))
    if completed_at is None or completed_at < 0:
        report.findings.append(_finding(
            SEVERITY_FATAL, "mission_completed_time_invalid", MANIFEST_NAME
        ))
    if manifest.get("integrity") != "verified":
        report.findings.append(_finding(
            SEVERITY_FATAL,
            "mission_manifest_integrity_unverified",
            "The phone did not commit integrity=verified.",
        ))
    if manifest.get("publishPermitted") is not True:
        report.findings.append(_finding(
            SEVERITY_FATAL,
            "mission_manifest_publish_denied",
            "The phone completion manifest did not permit publication.",
        ))

    declared_units = manifest.get("units")
    if not isinstance(declared_units, list) or not declared_units:
        report.findings.append(
            _finding(SEVERITY_FATAL, "mission_units_missing", MANIFEST_NAME)
        )
        return report

    declared_boundaries = manifest.get("boundaries")
    if not isinstance(declared_boundaries, list):
        report.findings.append(
            _finding(SEVERITY_FATAL, "mission_boundaries_missing", MANIFEST_NAME)
        )
        declared_boundaries = []

    _validate_units(report, path, declared_units)
    _validate_hash_chain(report)
    _validate_boundaries(report, path, declared_boundaries)
    _validate_identity_consistency(report)

    fatal = [item for item in report.findings if item.severity == SEVERITY_FATAL]
    if fatal:
        report.status = STATUS_PARTIAL
        report.publish_permitted = False
    else:
        report.status = STATUS_COMPLETE
        report.publish_permitted = True

    # The manifest declares its own conclusion; the validator has the last word.
    if manifest.get("publishPermitted") is True and not report.publish_permitted:
        report.findings.append(
            _finding(
                SEVERITY_FATAL,
                "mission_manifest_overclaims",
                "The manifest claims publish_permitted=true but validation found fatal findings.",
            )
        )
    return report


def _read_running_checkpoint(
    report: MissionReport, checkpoint_path: Path
) -> Tuple[Dict[str, Any], Optional[Dict[str, Any]]]:
    """Returns the identity summary and the parsed checkpoint (or None)."""
    checkpoint, error = _read_json(checkpoint_path)
    if checkpoint is None or not isinstance(checkpoint, dict):
        report.findings.append(
            _finding(
                SEVERITY_FATAL,
                "mission_checkpoint_unreadable",
                error or "mission_live_checkpoint.json is not an object",
            )
        )
        return {}, None
    if checkpoint.get("format") != FORMAT_LIVE_CHECKPOINT:
        report.findings.append(
            _finding(SEVERITY_FATAL, "mission_checkpoint_format_invalid", LIVE_CHECKPOINT_NAME)
        )
        return {}, None
    report.mission_id = checkpoint.get("missionId") if isinstance(checkpoint.get("missionId"), str) else None
    identity = checkpoint.get("identity")
    result: Dict[str, Any] = {}
    if isinstance(identity, dict):
        result = {
            "prior_map_id": identity.get("priorMapId"),
            "prior_map_package_sha256": identity.get("priorMapPackageSha256"),
            "store_id": identity.get("storeId"),
            "floor_id": identity.get("floorId"),
        }
    result["maintenance_state"] = checkpoint.get("maintenanceState")
    result["active_capture_elapsed_s"] = _finite_number(checkpoint.get("activeCaptureElapsedS"))
    return result, checkpoint


def _collect_running_units(
    report: MissionReport, root: Path, checkpoint: Optional[Dict[str, Any]]
) -> None:
    """List units of a running mission for diagnostics only."""
    declared: List[Any] = []
    if isinstance(checkpoint, dict):
        if isinstance(checkpoint.get("currentUnit"), dict):
            declared.append(checkpoint["currentUnit"])
        finalized = checkpoint.get("finalizedUnits")
        if isinstance(finalized, list):
            declared.extend(item for item in finalized if isinstance(item, dict))
    for entry in declared:
        relative = entry.get("relativePath") if isinstance(entry, dict) else None
        if not isinstance(relative, str):
            continue
        unit = validate_unit(root, relative, expected_index=entry.get("unitIndex"))
        report.units.append(unit)
        report.total_bytes += unit.database_bytes or 0
        report.total_active_capture_s += unit.active_capture_duration_s or 0.0
    report.units.sort(key=lambda item: (item.unit_index or 0))


def _validate_units(report: MissionReport, root: Path, declared_units: List[Any]) -> None:
    seen_indices: Dict[int, str] = {}
    seen_ids: Dict[str, int] = {}
    previous_index: Optional[int] = None
    for position, entry in enumerate(declared_units, start=1):
        if not isinstance(entry, dict):
            report.findings.append(
                _finding(SEVERITY_FATAL, "mission_unit_entry_invalid", f"units[{position}]")
            )
            continue
        relative = entry.get("relativePath")
        if not isinstance(relative, str):
            report.findings.append(
                _finding(SEVERITY_FATAL, "mission_unit_path_missing", f"units[{position}]")
            )
            continue
        index = entry.get("unitIndex")
        if not isinstance(index, int) or isinstance(index, bool):
            report.findings.append(
                _finding(SEVERITY_FATAL, "mission_unit_index_invalid", relative)
            )
            index = None
        unit = validate_unit(root, relative, expected_index=index)
        # The unit identity comes from the unit's own metadata, never from the
        # manifest: a manifest claim must not be able to name a unit whose
        # metadata declares no id.
        if not isinstance(entry.get("unitId"), str) or not entry["unitId"]:
            report.findings.append(_finding(
                SEVERITY_FATAL, "mission_unit_id_missing", relative, unit=index
            ))
        elif unit.unit_id != entry["unitId"]:
            report.findings.append(
                _finding(
                    SEVERITY_FATAL,
                    "mission_unit_id_mismatch",
                    f"{relative} manifest unitId {entry['unitId']!r} differs from the unit metadata {unit.unit_id!r}.",
                    unit=index,
                )
            )
        if entry.get("trackingSessionId") != unit.tracking_session_id:
            report.findings.append(_finding(
                SEVERITY_FATAL,
                "mission_tracking_session_mismatch",
                relative,
                unit=index,
            ))
        for field_name, actual, suffix in (
            ("databaseRelativePath", unit.database, "database"),
            ("metadataRelativePath", unit.metadata_path, "metadata"),
        ):
            declared_path = entry.get(field_name)
            _, path_error = _safe_relative_path(root, declared_path)
            if path_error is not None or declared_path != actual:
                report.findings.append(_finding(
                    SEVERITY_FATAL,
                    f"mission_{suffix}_path_mismatch",
                    f"{relative}: declared {field_name} does not identify the validated file.",
                    unit=index,
                ))
        if unit.unit_id in seen_ids:
            report.findings.append(
                _finding(SEVERITY_FATAL, "mission_duplicate_unit_id", str(unit.unit_id))
            )
        elif unit.unit_id is not None:
            seen_ids[unit.unit_id] = unit.unit_index or 0
        if index is not None:
            if previous_index is not None and index <= previous_index:
                report.findings.append(
                    _finding(
                        SEVERITY_FATAL,
                        "mission_unit_declaration_out_of_order",
                        f"{relative} declares unit index {index} after {previous_index}; the manifest must list units in ascending order.",
                        unit=index,
                    )
                )
            previous_index = index
            if index in seen_indices:
                report.findings.append(
                    _finding(
                        SEVERITY_FATAL,
                        "mission_duplicate_unit_index",
                        f"{relative} duplicates unit index {index} claimed by {seen_indices[index]}.",
                        unit=index,
                    )
                )
            else:
                seen_indices[index] = relative
        unit.findings.extend(_validate_declared_digests(entry, unit))
        report.units.append(unit)
        # Unit findings are mission findings: a single unverifiable unit must
        # block publication of the whole mission (section 11.1).
        report.findings.extend(unit.findings)
        report.total_bytes += unit.database_bytes or 0
        report.total_active_capture_s += unit.active_capture_duration_s or 0.0

    report.units.sort(key=lambda item: (item.unit_index or 0, item.relative_path or ""))
    indices = [unit.unit_index for unit in report.units if unit.unit_index is not None]
    if indices and sorted(indices) != list(range(1, len(report.units) + 1)):
        report.findings.append(
            _finding(
                SEVERITY_FATAL,
                "mission_unit_index_discontinuous",
                f"Unit indices {indices} are not 1..N without gaps or duplicates.",
            )
        )


def _validate_declared_digests(entry: Dict[str, Any], unit: UnitReport) -> List[Finding]:
    findings: List[Finding] = []
    declared_metadata = entry.get("metadataSha256")
    if not _is_sha256(declared_metadata):
        findings.append(_finding(
            SEVERITY_FATAL,
            "mission_metadata_digest_missing",
            str(unit.relative_path),
            unit=unit.unit_index,
        ))
    elif unit.metadata_sha256:
        if declared_metadata.lower() != unit.metadata_sha256.lower():
            findings.append(
                _finding(
                    SEVERITY_FATAL,
                    "mission_metadata_digest_mismatch",
                    f"{unit.relative_path} metadata digest does not match the manifest.",
                    unit=unit.unit_index,
                )
            )
    declared_database = entry.get("databaseSha256")
    if not _is_sha256(declared_database):
        findings.append(_finding(
            SEVERITY_FATAL,
            "mission_database_digest_missing",
            str(unit.relative_path),
            unit=unit.unit_index,
        ))
    elif unit.database_sha256:
        if declared_database.lower() != unit.database_sha256.lower():
            findings.append(
                _finding(
                    SEVERITY_FATAL,
                    "mission_database_digest_mismatch",
                    f"{unit.relative_path} database digest does not match the manifest.",
                    unit=unit.unit_index,
                )
            )
    declared_finalized = entry.get("finalized")
    if declared_finalized is not True:
        findings.append(_finding(
            SEVERITY_FATAL,
            "mission_finalized_flag_missing",
            str(unit.relative_path),
            unit=unit.unit_index,
        ))
    elif unit.finalized is not None:
        if unit.finalized is not True:
            findings.append(
                _finding(
                    SEVERITY_FATAL,
                    "mission_finalized_flag_mismatch",
                    f"{unit.relative_path} finalized flag contradicts the manifest.",
                    unit=unit.unit_index,
                )
            )
    finalized_at = _finite_number(entry.get("finalizedAtUnix"))
    if finalized_at is None or finalized_at < 0:
        findings.append(_finding(
            SEVERITY_FATAL,
            "mission_finalized_time_invalid",
            str(unit.relative_path),
            unit=unit.unit_index,
        ))
    duration = _finite_number(entry.get("activeCaptureDurationS"))
    if duration is None or duration < 0 or duration != unit.active_capture_duration_s:
        findings.append(_finding(
            SEVERITY_FATAL,
            "mission_active_duration_mismatch",
            str(unit.relative_path),
            unit=unit.unit_index,
        ))
    if entry.get("rolloverTrigger") not in {
        "time_limit", "size_limit", "operator_stop", "safety_stop"
    } or entry.get("rolloverTrigger") != unit.rollover_trigger:
        findings.append(_finding(
            SEVERITY_FATAL,
            "mission_rollover_trigger_mismatch",
            str(unit.relative_path),
            unit=unit.unit_index,
        ))
    storage_bytes = entry.get("unitStorageBytes")
    if (not isinstance(storage_bytes, int) or isinstance(storage_bytes, bool)
            or storage_bytes <= 0):
        findings.append(_finding(
            SEVERITY_FATAL,
            "mission_unit_storage_bytes_invalid",
            str(unit.relative_path),
            unit=unit.unit_index,
        ))
    if entry.get("previousUnitId") != unit.previous_unit_id:
        findings.append(_finding(
            SEVERITY_FATAL,
            "mission_declared_previous_unit_mismatch",
            str(unit.relative_path),
            unit=unit.unit_index,
        ))
    if entry.get("previousUnitMetadataSha256") != unit.previous_unit_metadata_sha256:
        findings.append(_finding(
            SEVERITY_FATAL,
            "mission_declared_previous_digest_mismatch",
            str(unit.relative_path),
            unit=unit.unit_index,
        ))
    return findings


def _validate_hash_chain(report: MissionReport) -> None:
    ordered = [unit for unit in report.units if unit.unit_index is not None]
    ordered.sort(key=lambda item: item.unit_index or 0)
    for position in range(1, len(ordered)):
        previous = ordered[position - 1]
        current = ordered[position]
        if current.previous_unit_metadata_sha256 is None:
            report.findings.append(
                _finding(
                    SEVERITY_FATAL,
                    "mission_hash_chain_missing",
                    f"Unit {current.unit_index} does not carry the previous metadata digest.",
                    unit=current.unit_index,
                )
            )
            continue
        if previous.metadata_sha256 is None:
            continue
        if current.previous_unit_metadata_sha256.lower() != previous.metadata_sha256.lower():
            report.findings.append(
                _finding(
                    SEVERITY_FATAL,
                    "mission_hash_chain_broken",
                    f"Unit {current.unit_index} previous digest does not match unit {previous.unit_index}.",
                    unit=current.unit_index,
                )
            )
        if current.previous_unit_id != previous.unit_id:
            report.findings.append(
                _finding(
                    SEVERITY_FATAL,
                    "mission_previous_unit_id_mismatch",
                    f"Unit {current.unit_index} points at an unexpected previous unit.",
                    unit=current.unit_index,
                )
            )
    if ordered and (
        ordered[0].previous_unit_id is not None
        or ordered[0].previous_unit_metadata_sha256 is not None
    ):
        report.findings.append(_finding(
            SEVERITY_FATAL,
            "mission_first_unit_has_predecessor",
            "Unit 1 must not declare a predecessor.",
            unit=ordered[0].unit_index,
        ))


def _validate_boundaries(
    report: MissionReport, root: Path, declared_boundaries: List[Any]
) -> None:
    boundaries_root = root / BOUNDARIES_DIRNAME
    on_disk: Dict[str, List[Tuple[Path, Dict[str, Any], str]]] = {}
    if boundaries_root.is_dir():
        for candidate in sorted(boundaries_root.glob("boundary_*.json")):
            if _is_link(candidate):
                report.findings.append(
                    _finding(SEVERITY_FATAL, "boundary_link_detected", candidate.name)
                )
                continue
            payload, error = _read_json(candidate)
            digest = sha256_file(candidate)
            if (not isinstance(payload, dict)
                    or not isinstance(payload.get("boundaryId"), str)
                    or not digest):
                report.findings.append(_finding(
                    SEVERITY_FATAL,
                    "boundary_file_unreadable",
                    f"{candidate.name}: {error or 'invalid payload or unstable file'}",
                ))
                continue
            on_disk.setdefault(payload["boundaryId"], []).append(
                (candidate, payload, digest)
            )
    elif declared_boundaries:
        report.findings.append(_finding(
            SEVERITY_FATAL, "boundary_directory_missing", BOUNDARIES_DIRNAME
        ))

    for entry in declared_boundaries:
        manifest_boundary = validate_boundary(
            entry, report.mission_id or "", report.units
        )
        matches = on_disk.get(manifest_boundary.boundary_id, [])
        if len(matches) != 1:
            code = "boundary_file_missing" if not matches else "boundary_file_duplicate"
            manifest_boundary.findings.append(
                _finding(SEVERITY_FATAL, code, manifest_boundary.boundary_id)
            )
            manifest_boundary.complete = False
            report.boundaries.append(manifest_boundary)
            report.findings.extend(manifest_boundary.findings)
            continue
        path, disk_payload, digest = matches[0]
        authoritative_payload = dict(disk_payload)
        authoritative_payload["fileSha256"] = digest
        boundary = validate_boundary(
            authoritative_payload, report.mission_id or "", report.units
        )
        if manifest_boundary.findings:
            boundary.findings.extend(manifest_boundary.findings)
            boundary.complete = False
        boundary.file = _relative(root, path)
        boundary.file_sha256 = digest
        if not isinstance(entry, dict) or not _is_sha256(entry.get("fileSha256")):
            boundary.findings.append(
                _finding(
                    SEVERITY_FATAL,
                    "boundary_digest_missing",
                    boundary.boundary_id,
                )
            )
            boundary.complete = False
        elif str(entry["fileSha256"]).lower() != digest.lower():
            boundary.findings.append(_finding(
                SEVERITY_FATAL, "boundary_digest_mismatch", boundary.boundary_id
            ))
            boundary.complete = False
        manifest_payload = dict(entry) if isinstance(entry, dict) else {}
        manifest_payload.pop("fileSha256", None)
        disk_comparable = dict(disk_payload)
        disk_comparable.pop("fileSha256", None)
        if manifest_payload != disk_comparable:
            boundary.findings.append(_finding(
                SEVERITY_FATAL,
                "boundary_manifest_file_mismatch",
                boundary.boundary_id,
            ))
            boundary.complete = False
        from_unit = next(
            (unit for unit in report.units if unit.unit_id == boundary.from_unit_id),
            None,
        )
        if (from_unit is None or from_unit.unit_index is None
                or path.name != f"boundary_{from_unit.unit_index:04d}.json"):
            boundary.findings.append(_finding(
                SEVERITY_FATAL, "boundary_filename_mismatch", path.name
            ))
            boundary.complete = False
        report.boundaries.append(boundary)
        report.findings.extend(boundary.findings)

    seen_boundary_ids: set = set()
    for boundary in report.boundaries:
        if boundary.boundary_id in seen_boundary_ids:
            report.findings.append(
                _finding(
                    SEVERITY_FATAL,
                    "boundary_duplicate_id",
                    f"Boundary id {boundary.boundary_id} is declared more than once.",
                )
            )
        seen_boundary_ids.add(boundary.boundary_id)

    unexpected = set(on_disk) - {item.boundary_id for item in report.boundaries}
    for boundary_id in sorted(unexpected):
        report.findings.append(
            _finding(
                SEVERITY_FATAL,
                "boundary_undeclared",
                f"Boundary {boundary_id} exists on disk but is not declared by the manifest.",
            )
        )

    by_pair: Dict[Tuple[Optional[str], Optional[str]], List[BoundaryReport]] = {}
    for boundary in report.boundaries:
        by_pair.setdefault((boundary.from_unit_id, boundary.to_unit_id), []).append(boundary)
    for (from_id, to_id), items in by_pair.items():
        if len(items) > 1:
            report.findings.append(
                _finding(
                    SEVERITY_FATAL,
                    "boundary_duplicate_pair",
                    f"{len(items)} boundaries link {from_id} -> {to_id}.",
                )
            )

    ordered = [unit for unit in report.units if unit.unit_index is not None]
    ordered.sort(key=lambda item: item.unit_index or 0)
    if len(report.boundaries) != max(0, len(ordered) - 1):
        report.findings.append(_finding(
            SEVERITY_FATAL,
            "boundary_count_invalid",
            "The mission must declare exactly one boundary per adjacent unit pair.",
        ))
    covered: set = set()
    for position in range(1, len(ordered)):
        previous = ordered[position - 1]
        current = ordered[position]
        matches = (
            [
                boundary
                for boundary in report.boundaries
                if boundary.from_unit_id == previous.unit_id
                and boundary.to_unit_id == current.unit_id
            ]
            if previous.unit_id and current.unit_id
            else []
        )
        for match in matches:
            covered.add(match.boundary_id)
        if not matches:
            report.findings.append(
                _finding(
                    SEVERITY_FATAL,
                    "boundary_missing",
                    f"No boundary links unit {previous.unit_index} and {current.unit_index}.",
                    unit=current.unit_index,
                )
            )
            continue
        if len(matches) > 1 or not matches[0].complete:
            report.findings.append(
                _finding(
                    SEVERITY_FATAL,
                    "boundary_incomplete",
                    f"The boundary between unit {previous.unit_index} and {current.unit_index} is not two-sided.",
                    unit=current.unit_index,
                )
            )
    for boundary in report.boundaries:
        if boundary.boundary_id not in covered:
            report.findings.append(
                _finding(
                    SEVERITY_FATAL,
                    "boundary_nonadjacent",
                    f"Boundary {boundary.boundary_id} does not link adjacent units.",
                )
            )


def _validate_identity_consistency(report: MissionReport) -> None:
    expected = report.identity
    for unit in report.units:
        for key, value in (
            ("mission_id", unit.mission_id),
            ("prior_map_id", unit.prior_map_id),
            ("prior_map_package_sha256", unit.prior_map_package_sha256),
            ("store_id", unit.store_id),
            ("floor_id", unit.floor_id),
            ("build_identity", unit.build_identity),
        ):
            declared = expected.get(key)
            if not declared or not value or value != declared:
                report.findings.append(
                    _finding(
                        SEVERITY_FATAL,
                        "mission_identity_drift",
                        f"Unit {unit.unit_index} {key}={value!r} differs from the mission identity {declared!r}.",
                        unit=unit.unit_index,
                    )
                )
        if not unit.tracking_session_id:
            report.findings.append(_finding(
                SEVERITY_FATAL,
                "mission_tracking_session_missing",
                f"Unit {unit.unit_index} has no tracking session identity.",
                unit=unit.unit_index,
            ))
    # Boundary completeness is reported by _validate_boundaries, which knows
    # which boundary belongs to which adjacent pair.


__all__ = [
    "MissionReport",
    "UnitReport",
    "BoundaryReport",
    "Finding",
    "inspect_mission",
    "validate_mission",
    "validate_unit",
    "validate_boundary",
    "sha256_file",
    "STATUS_COMPLETE",
    "STATUS_PARTIAL",
    "STATUS_DIAGNOSTIC",
    "STATUS_INVALID",
]
