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
    store_id: Optional[str] = None
    floor_id: Optional[str] = None
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
    """SHA-256 of a regular file, or None when the file cannot be read."""
    digest = hashlib.sha256()
    try:
        with open(path, "rb") as handle:
            while True:
                chunk = handle.read(_READ_CHUNK)
                if not chunk:
                    break
                digest.update(chunk)
    except OSError:
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
    if os.path.stat.S_ISDIR(info.st_mode):
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
    if candidate.is_symlink():
        # Reported before resolving so a link that escapes the root is named
        # for what it is instead of looking like a plain missing directory.
        return None, "link_detected"
    target = candidate.resolve()
    try:
        target.relative_to(resolved_root)
    except ValueError:
        return None, "path_outside_root"
    return target, None


def _read_json(path: Path) -> Tuple[Optional[Any], Optional[str]]:
    try:
        if _is_link(path):
            return None, "link_detected"
        with open(path, "r", encoding="utf-8") as handle:
            return json.load(handle), None
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        return None, f"unreadable:{error.__class__.__name__}"


def _finite_number(value: Any) -> Optional[float]:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    result = float(value)
    return result if math.isfinite(result) else None


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
    report.store_id = metadata.get("storeId") if isinstance(metadata.get("storeId"), str) else None
    report.floor_id = metadata.get("floorId") if isinstance(metadata.get("floorId"), str) else None
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

    if require_mission_fields:
        if not report.unit_id:
            report.findings.append(
                _finding(SEVERITY_FATAL, "unit_id_missing", relative_path)
            )
        mission_id = metadata.get("missionId")
        if not isinstance(mission_id, str) or not mission_id:
            report.findings.append(
                _finding(SEVERITY_FATAL, "unit_mission_id_missing", relative_path)
            )
    if report.finalized is not True:
        report.findings.append(
            _finding(SEVERITY_FATAL, "unit_not_finalized", relative_path)
        )
    if report.scan_mode != "continuous_streaming":
        report.findings.append(
            _finding(SEVERITY_FATAL, "unit_scan_mode_invalid", relative_path)
        )
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


def _boundary_end_ok(end: Any, unit_id: Optional[str], pose: Tuple[float, float, float]) -> bool:
    if not isinstance(end, dict):
        return False
    if end.get("unitId") != unit_id:
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
    for required in ("nodeId", "nodeStamp", "nodeTimeSnapshotGeneration", "trackingSessionId"):
        if end.get(required) is None:
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

    outgoing = boundary.get("outgoing")
    incoming = boundary.get("incoming")
    outgoing_ok = _boundary_end_ok(outgoing, report.from_unit_id, pose)
    incoming_ok = _boundary_end_ok(incoming, report.to_unit_id, pose)
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
    has_checkpoint = checkpoint_path.is_file()

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
            "prior_map_id": identity.get("priorMapId"),
            "prior_map_package_sha256": identity.get("priorMapPackageSha256"),
            "store_id": identity.get("storeId"),
            "floor_id": identity.get("floorId"),
        }
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
        if isinstance(entry.get("unitId"), str) and unit.unit_id != entry["unitId"]:
            report.findings.append(
                _finding(
                    SEVERITY_FATAL,
                    "mission_unit_id_mismatch",
                    f"{relative} manifest unitId {entry['unitId']!r} differs from the unit metadata {unit.unit_id!r}.",
                    unit=index,
                )
            )
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
    if isinstance(declared_metadata, str) and unit.metadata_sha256:
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
    if isinstance(declared_database, str) and unit.database_sha256:
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
    if isinstance(declared_finalized, bool) and unit.finalized is not None:
        if declared_finalized != unit.finalized:
            findings.append(
                _finding(
                    SEVERITY_FATAL,
                    "mission_finalized_flag_mismatch",
                    f"{unit.relative_path} finalized flag contradicts the manifest.",
                    unit=unit.unit_index,
                )
            )
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
        if current.previous_unit_id and previous.unit_id and current.previous_unit_id != previous.unit_id:
            report.findings.append(
                _finding(
                    SEVERITY_FATAL,
                    "mission_previous_unit_id_mismatch",
                    f"Unit {current.unit_index} points at an unexpected previous unit.",
                    unit=current.unit_index,
                )
            )


def _validate_boundaries(
    report: MissionReport, root: Path, declared_boundaries: List[Any]
) -> None:
    boundaries_root = root / BOUNDARIES_DIRNAME
    on_disk: Dict[str, Path] = {}
    if boundaries_root.is_dir():
        for candidate in sorted(boundaries_root.glob("boundary_*.json")):
            if _is_link(candidate):
                report.findings.append(
                    _finding(SEVERITY_FATAL, "boundary_link_detected", candidate.name)
                )
                continue
            payload = _read_json(candidate)[0]
            if isinstance(payload, dict) and isinstance(payload.get("boundaryId"), str):
                on_disk[payload["boundaryId"]] = candidate

    for entry in declared_boundaries:
        boundary = validate_boundary(entry, report.mission_id or "", report.units)
        if boundary.boundary_id in on_disk:
            path = on_disk[boundary.boundary_id]
            boundary.file = _relative(root, path)
            digest = sha256_file(path)
            if digest:
                boundary.file_sha256 = digest
                if boundary.file_sha256 and entry.get("fileSha256"):
                    if str(entry["fileSha256"]).lower() != digest.lower():
                        boundary.findings.append(
                            _finding(
                                SEVERITY_FATAL,
                                "boundary_digest_mismatch",
                                boundary.boundary_id,
                            )
                        )
                        boundary.complete = False
            else:
                boundary.findings.append(
                    _finding(SEVERITY_FATAL, "boundary_unreadable", boundary.boundary_id)
                )
                boundary.complete = False
        else:
            boundary.findings.append(
                _finding(
                    SEVERITY_FATAL,
                    "boundary_file_missing",
                    f"Boundary {boundary.boundary_id} has no file under {BOUNDARIES_DIRNAME}/.",
                )
            )
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
        if boundary.boundary_id not in covered and not boundary.complete:
            report.findings.append(
                _finding(
                    SEVERITY_FATAL,
                    "boundary_incomplete",
                    f"Boundary {boundary.boundary_id} is incomplete.",
                )
            )


def _validate_identity_consistency(report: MissionReport) -> None:
    expected = report.identity
    for unit in report.units:
        for key, value in (
            ("prior_map_id", unit.prior_map_id),
            ("store_id", unit.store_id),
            ("floor_id", unit.floor_id),
        ):
            declared = expected.get(key)
            if declared is None:
                continue
            if value is not None and value != declared:
                report.findings.append(
                    _finding(
                        SEVERITY_FATAL,
                        "mission_identity_drift",
                        f"Unit {unit.unit_index} {key}={value!r} differs from the mission identity {declared!r}.",
                        unit=unit.unit_index,
                    )
                )
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
