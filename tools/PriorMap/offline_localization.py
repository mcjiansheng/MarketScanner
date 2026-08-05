"""Stage-3 relative SE(2) trajectory optimization and review/export pipeline.

The source RTAB-Map database is read-only.  This module consumes the already
optimized database copy produced by ``rtabmap-reprocess`` and writes a separate
prior-map coordinate trajectory plus auditable review artifacts.

The publish-capable path invokes the read-only native RTAB-Map/g2o helper and
strictly validates its canonical relative Link factors. The older component-wise
bounded correction field remains available only as a draft fallback.
"""

from __future__ import annotations

import csv
from collections import Counter
from datetime import datetime, timezone
import hashlib
import json
import math
import os
import re
import shutil
import sqlite3
import stat
import tempfile
from dataclasses import dataclass, replace
from pathlib import Path
from typing import Any, Callable, Iterable, Sequence

from .strict_json import (
    DuplicateJSONKeyError,
    json_nesting_depth,
    load_strict_json_bytes,
    reject_duplicate_object_pairs,
    reject_nonfinite_json,
)
from .localized_output_store import LocalizedVersionStore
from .prior_map_schema import load_json, validate_package
from .factor_graph_runner import FactorGraphRunnerError, run_relative_se2_factor_graph


FORMAT_VERSION = 1
TOOL_VERSION = "MarketScanner-RepairV2"
COORDINATE_CONTRACT_VERSION = 1
HUBER_TRANSLATION_M = 0.45
HUBER_YAW_RAD = math.radians(10)
HARD_REJECT_TRANSLATION_M = 2.5
HARD_REJECT_YAW_RAD = math.radians(45)
MANUAL_ANCHOR_MAX_TRANSLATION_M = 5.0
MANUAL_ANCHOR_MAX_YAW_RAD = math.radians(30.0)
SESSION_INPUT_FILE_NAMES_V1 = (
    "metadata.json",
    "localization_trace.jsonl",
    "localization_constraints.jsonl",
    "localization_events.jsonl",
    "manual_localization_events.jsonl",
    "tag_observations.jsonl",
    "localized_price_tags.json",
)
# P7R6: manifest version 2 binds the terminal Recovery lifecycle sidecar into
# the immutable input identity. The file is inserted at a fixed position so
# historical v1 manifests keep their canonical bundle hash untouched.
SESSION_INPUT_FILE_NAMES_V2 = (
    "metadata.json",
    "localization_trace.jsonl",
    "localization_constraints.jsonl",
    "localization_events.jsonl",
    "localization_recovery_events.jsonl",
    "manual_localization_events.jsonl",
    "tag_observations.jsonl",
    "localized_price_tags.json",
)
# Historical alias: v1 stays the legacy contract and never carries Recovery
# evidence binding.
SESSION_INPUT_FILE_NAMES = SESSION_INPUT_FILE_NAMES_V1
RECOVERY_EVIDENCE_UNBOUND_LEGACY = "recovery_lifecycle_evidence_unbound_legacy"
# P7R6B: the PC reader shares the frozen Recovery evidence limits with the
# device parser, the finalization bundle validator and the session
# stable-read snapshot. One file never carries two different size policies.
RECOVERY_MAXIMUM_FILE_BYTES = 16 * 1024 * 1024
RECOVERY_MAXIMUM_RECORD_BYTES = 1_000_000
RECOVERY_MAXIMUM_RECORDS = 100_000
RECOVERY_MAXIMUM_NESTING_DEPTH = 32
EDITABLE_TAG_FIELDS = frozenset(
    {
        "shelf_code",
        "shelf_side",
        "distance_from_shelf_start_cm",
        "height_cm",
        "final_map_position",
    }
)


DEFAULT_REPLAY_PARAMETERS: dict[str, Any] = {
    "resolution": 0.05,
    "preview_resolution": 0.1,
    "trajectory_radius": 1.25,
    "tag_snap_distance": 1.0,
    "occupied_inflate_radius": 0.08,
    "free_ray_max_range": 8.0,
    "horizontal_axes": "xz",
    "auto_align_segments": False,
    "diagnostic_mode": False,
}


def normalize_replay_parameters(
    payload: dict[str, Any] | None = None,
) -> dict[str, Any]:
    values = dict(DEFAULT_REPLAY_PARAMETERS if payload is None else payload)
    if set(values) != set(DEFAULT_REPLAY_PARAMETERS):
        raise OfflineLocalizationError("Replay parameter set is invalid.")
    normalized: dict[str, Any] = {}
    for name in (
        "resolution",
        "preview_resolution",
        "trajectory_radius",
        "tag_snap_distance",
        "occupied_inflate_radius",
        "free_ray_max_range",
    ):
        value = values.get(name)
        if isinstance(value, bool):
            raise OfflineLocalizationError(f"Replay parameter {name} is invalid.")
        try:
            number = float(value)
        except (TypeError, ValueError) as exc:
            raise OfflineLocalizationError(
                f"Replay parameter {name} is invalid."
            ) from exc
        if not math.isfinite(number) or number <= 0:
            raise OfflineLocalizationError(f"Replay parameter {name} is invalid.")
        normalized[name] = number
    axes = values.get("horizontal_axes")
    if axes not in {"xz", "xy", "ios_prior"}:
        raise OfflineLocalizationError("Replay parameter horizontal_axes is invalid.")
    if values.get("auto_align_segments") is not False:
        raise OfflineLocalizationError(
            "Localized replay requires auto_align_segments=false."
        )
    diagnostic_mode = values.get("diagnostic_mode")
    if not isinstance(diagnostic_mode, bool):
        raise OfflineLocalizationError(
            "Replay parameter diagnostic_mode is invalid."
        )
    normalized["horizontal_axes"] = axes
    normalized["auto_align_segments"] = False
    normalized["diagnostic_mode"] = diagnostic_mode
    return normalized


def processing_parameter_sha256(
    replay_parameters: dict[str, Any] | None = None,
) -> str:
    payload = {
        "algorithm_parameters": {
            "coordinate_contract_version": COORDINATE_CONTRACT_VERSION,
            "hard_reject_translation_m": HARD_REJECT_TRANSLATION_M,
            "hard_reject_yaw_rad": HARD_REJECT_YAW_RAD,
            "huber_translation_m": HUBER_TRANSLATION_M,
            "huber_yaw_rad": HUBER_YAW_RAD,
            "solver": "bounded_correction_field_v1",
        },
        "replay_parameters": normalize_replay_parameters(replay_parameters),
    }
    return hashlib.sha256(
        json.dumps(payload, sort_keys=True, separators=(",", ":")).encode("utf-8")
    ).hexdigest()


def _legacy_processing_parameter_sha256_v3() -> str:
    """Return the algorithm-only digest written by manual journal v3."""

    payload = {
        "coordinate_contract_version": COORDINATE_CONTRACT_VERSION,
        "hard_reject_translation_m": HARD_REJECT_TRANSLATION_M,
        "hard_reject_yaw_rad": HARD_REJECT_YAW_RAD,
        "huber_translation_m": HUBER_TRANSLATION_M,
        "huber_yaw_rad": HUBER_YAW_RAD,
        "solver": "bounded_correction_field_v1",
    }
    return hashlib.sha256(
        json.dumps(payload, sort_keys=True, separators=(",", ":")).encode("utf-8")
    ).hexdigest()


def _canonical_json_bytes(payload: dict[str, Any]) -> bytes:
    return json.dumps(
        payload,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
        allow_nan=False,
    ).encode("utf-8")


def _regular_file_identity(path: Path, role: str) -> dict[str, Any]:
    """Hash one regular file through the same descriptor used for its size."""

    try:
        path_before = path.lstat()
        if not stat.S_ISREG(path_before.st_mode):
            raise OfflineLocalizationError(
                f"Session input {role} must be a regular file: {path.name}"
            )
        flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
        descriptor = os.open(path, flags)
        with os.fdopen(descriptor, "rb") as handle:
            before = os.fstat(handle.fileno())
            digest = hashlib.sha256()
            byte_count = 0
            for block in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(block)
                byte_count += len(block)
            after = os.fstat(handle.fileno())
        path_after = path.lstat()
    except OfflineLocalizationError:
        raise
    except FileNotFoundError as exc:
        raise OfflineLocalizationError(
            f"Required sidecar {path.name} is missing."
        ) from exc
    except OSError as exc:
        raise OfflineLocalizationError(
            f"Session input {role} could not be read safely: {path.name}"
        ) from exc
    if (
        not stat.S_ISREG(before.st_mode)
        or not stat.S_ISREG(path_after.st_mode)
        or (path_before.st_dev, path_before.st_ino, path_before.st_size)
        != (before.st_dev, before.st_ino, before.st_size)
        or (before.st_dev, before.st_ino, before.st_size)
        != (after.st_dev, after.st_ino, after.st_size)
        or (after.st_dev, after.st_ino, after.st_size)
        != (path_after.st_dev, path_after.st_ino, path_after.st_size)
        or byte_count != before.st_size
    ):
        raise OfflineLocalizationError(
            f"Session input {role} changed while it was being hashed: {path.name}"
        )
    return {
        "role": role,
        "file": path.name,
        "bytes": byte_count,
        "sha256": digest.hexdigest(),
    }


def _stable_read_bytes(
    path: Path, role: str, *, maximum_bytes: int | None = None
) -> tuple[bytes, dict[str, Any]]:
    """Read one formal input exactly once through a no-follow descriptor.

    P7R6C: the bytes returned here are the bytes that are hashed and the
    bytes that are parsed. The descriptor identity is checked before and
    after the read (regular file, no symlink, single hard link, size
    bound), so a mid-read replacement, truncation or link attack fails
    closed instead of producing hash-A/parse-B evidence.
    """

    try:
        path_before = path.lstat()
        if not stat.S_ISREG(path_before.st_mode):
            raise OfflineLocalizationError(
                f"Session input {role} must be a regular file: {path.name}"
            )
        flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
        descriptor = os.open(path, flags)
        with os.fdopen(descriptor, "rb") as handle:
            before = os.fstat(handle.fileno())
            if maximum_bytes is not None and before.st_size > maximum_bytes:
                raise OfflineLocalizationError(
                    f"Session input {role} exceeds its safety limit: {path.name}"
                )
            data = handle.read()
            digest = hashlib.sha256(data)
            after = os.fstat(handle.fileno())
        path_after = path.lstat()
    except OfflineLocalizationError:
        raise
    except FileNotFoundError as exc:
        raise OfflineLocalizationError(
            f"Required sidecar {path.name} is missing."
        ) from exc
    except OSError as exc:
        raise OfflineLocalizationError(
            f"Session input {role} could not be read safely: {path.name}"
        ) from exc
    if (
        not stat.S_ISREG(before.st_mode)
        or not stat.S_ISREG(path_after.st_mode)
        or before.st_nlink != 1
        or (path_before.st_dev, path_before.st_ino, path_before.st_size)
        != (before.st_dev, before.st_ino, before.st_size)
        or (before.st_dev, before.st_ino, before.st_size)
        != (after.st_dev, after.st_ino, after.st_size)
        or (after.st_dev, after.st_ino, after.st_size)
        != (path_after.st_dev, path_after.st_ino, path_after.st_size)
        or len(data) != before.st_size
    ):
        raise OfflineLocalizationError(
            f"Session input {role} changed while it was being read: {path.name}"
        )
    return data, {
        "role": role,
        "file": path.name,
        "bytes": len(data),
        "sha256": digest.hexdigest(),
    }


def session_input_bundle_sha256(payload: dict[str, Any]) -> str:
    """Validate and return the canonical finalized-session bundle identity."""

    if (
        not isinstance(payload, dict)
        or payload.get("format") != "MarketScannerLocalizedInputManifest"
    ):
        raise OfflineLocalizationError("Session input manifest contract is invalid.")
    version = payload.get("version")
    if version == 1:
        file_names = SESSION_INPUT_FILE_NAMES_V1
    elif version == 2:
        file_names = SESSION_INPUT_FILE_NAMES_V2
    else:
        raise OfflineLocalizationError("Session input manifest contract is invalid.")
    base_keys = {
        "format",
        "version",
        "source_database_sha256",
        "files",
        "bundle_sha256",
    }
    if set(payload) not in (
        base_keys,
        base_keys | {"input_identity_id"},
        base_keys | {"recovery_evidence_binding"},
        base_keys | {"input_identity_id", "recovery_evidence_binding"},
    ):
        raise OfflineLocalizationError("Session input manifest contract is invalid.")
    # v1 historical sessions must never pretend to carry P7R6 recovery
    # evidence; v2 sessions are bound by construction and forbid the marker.
    recovery_binding = payload.get("recovery_evidence_binding")
    if recovery_binding is not None and (
        not isinstance(recovery_binding, str)
        or recovery_binding != RECOVERY_EVIDENCE_UNBOUND_LEGACY
        or version != 1
    ):
        raise OfflineLocalizationError("Session input manifest contract is invalid.")
    files = payload.get("files")
    expected_roles = ("metadata", "source_database", *file_names[1:])
    if not isinstance(files, list) or len(files) != len(expected_roles):
        raise OfflineLocalizationError("Session input manifest file set is invalid.")
    for entry, role in zip(files, expected_roles):
        if (
            not isinstance(entry, dict)
            or set(entry) != {"role", "file", "bytes", "sha256"}
            or entry.get("role") != role
            or not isinstance(entry.get("file"), str)
            or not entry["file"]
            or isinstance(entry.get("bytes"), bool)
            or not isinstance(entry.get("bytes"), int)
            or entry["bytes"] < 0
            or not isinstance(entry.get("sha256"), str)
            or re.fullmatch(r"[0-9a-f]{64}", entry["sha256"]) is None
        ):
            raise OfflineLocalizationError("Session input manifest entry is invalid.")
        expected_file = "metadata.json" if role == "metadata" else role
        if role != "source_database" and entry["file"] != expected_file:
            raise OfflineLocalizationError("Session input manifest filename is invalid.")
    canonical = {
        "format": payload["format"],
        "version": payload["version"],
        "source_database_sha256": payload.get("source_database_sha256"),
        "files": files,
    }
    if canonical["source_database_sha256"] != files[1]["sha256"]:
        raise OfflineLocalizationError(
            "Session input manifest source database hash is inconsistent."
        )
    calculated = hashlib.sha256(_canonical_json_bytes(canonical)).hexdigest()
    if payload.get("bundle_sha256") != calculated:
        raise OfflineLocalizationError("Session input manifest bundle hash is invalid.")
    input_identity_id = payload.get("input_identity_id")
    if input_identity_id is not None and (
        not isinstance(input_identity_id, str)
        or re.fullmatch(r"[0-9a-f]{64}", input_identity_id) is None
    ):
        raise OfflineLocalizationError("Session input manifest input identity is invalid.")
    return calculated


def build_session_input_manifest(
    segment: Path, source_database: Path
) -> dict[str, Any]:
    """Build the deterministic identity of every authoritative finalized input.

    Sessions carrying the P7R6 capture watermark (``captureHealth.
    localizationRecoveryEventCount``) build manifest version 2 and bind the
    Recovery lifecycle sidecar: a missing or tampered file fails the build.
    Older sessions keep manifest version 1 and are explicitly marked as
    ``recovery_lifecycle_evidence_unbound_legacy``.
    """

    try:
        if source_database.resolve().parent != segment.resolve():
            raise OfflineLocalizationError(
                "Source database must belong to the single finalized segment."
            )
    except OSError as exc:
        raise OfflineLocalizationError("Session input paths could not be resolved.") from exc
    # P7R6C: the manifest version decision and the metadata hash come from
    # one descriptor-stable read of the same bytes.
    metadata_bytes, _ = _stable_read_bytes(segment / "metadata.json", "metadata")
    metadata = load_strict_json_bytes(metadata_bytes, name="metadata.json")
    capture_health = (
        metadata.get("captureHealth") if isinstance(metadata, dict) else None
    )
    recovery_bound = (
        isinstance(capture_health, dict)
        and "localizationRecoveryEventCount" in capture_health
    )
    if recovery_bound:
        manifest_version = 2
        file_names = SESSION_INPUT_FILE_NAMES_V2
    else:
        manifest_version = 1
        file_names = SESSION_INPUT_FILE_NAMES_V1
    files = [
        _regular_file_identity(segment / "metadata.json", "metadata"),
        _regular_file_identity(source_database, "source_database"),
        *(
            _regular_file_identity(segment / name, name)
            for name in file_names[1:]
        ),
    ]
    return _session_input_manifest_from_identities(
        files, manifest_version
    )


def _session_input_manifest_from_identities(
    files: list[dict[str, Any]], manifest_version: int
) -> dict[str, Any]:
    manifest: dict[str, Any] = {
        "format": "MarketScannerLocalizedInputManifest",
        "version": manifest_version,
        "source_database_sha256": files[1]["sha256"],
        "files": files,
    }
    if manifest_version == 1:
        manifest["recovery_evidence_binding"] = (
            RECOVERY_EVIDENCE_UNBOUND_LEGACY
        )
    # The bundle hash only binds the canonical identity payload; audit markers
    # stay outside so historical v1 digests remain reproducible.
    canonical_manifest = {
        "format": manifest["format"],
        "version": manifest["version"],
        "source_database_sha256": manifest["source_database_sha256"],
        "files": manifest["files"],
    }
    manifest["bundle_sha256"] = hashlib.sha256(
        _canonical_json_bytes(canonical_manifest)
    ).hexdigest()
    session_input_bundle_sha256(manifest)
    return manifest


@dataclass(frozen=True)
class FinalizedSessionInputSnapshot:
    """P7R6C: parse-and-hash-once view of a finalized session.

    Every artifact is read exactly once through the stable descriptor
    path; the parsed content below comes from the exact bytes that
    produced the manifest identities, so the bundle SHA always describes
    what localization actually consumed.
    """

    metadata: dict[str, Any]
    metadata_bytes: bytes
    source_database_sha256: str
    jsonl_values: dict[str, list[dict[str, Any]]]
    jsonl_diagnostics: dict[str, dict[str, Any]]
    localized_tags_bytes: bytes
    localized_tag_count: int
    manifest: dict[str, Any]


def read_finalized_session_input_snapshot(
    segment: Path, source_database: Path
) -> FinalizedSessionInputSnapshot:
    """Read every authoritative finalized-session input exactly once:
    stable descriptor read, hash and parse of the same bytes, manifest
    built from the same identities."""

    try:
        if source_database.resolve().parent != segment.resolve():
            raise OfflineLocalizationError(
                "Source database must belong to the single finalized segment."
            )
    except OSError as exc:
        raise OfflineLocalizationError("Session input paths could not be resolved.") from exc
    metadata_bytes, metadata_identity = _stable_read_bytes(
        segment / "metadata.json", "metadata"
    )
    metadata = load_strict_json_bytes(metadata_bytes, name="metadata.json")
    if not isinstance(metadata, dict):
        raise OfflineLocalizationError("Session metadata is invalid.")
    capture_health = metadata.get("captureHealth")
    recovery_bound = (
        isinstance(capture_health, dict)
        and "localizationRecoveryEventCount" in capture_health
    )
    manifest_version = 2 if recovery_bound else 1
    file_names = (
        SESSION_INPUT_FILE_NAMES_V2 if recovery_bound else SESSION_INPUT_FILE_NAMES_V1
    )
    session_id = str(metadata.get("trackingSessionId") or "")
    map_hash = str(metadata.get("priorMapSha256") or "")
    floor_id = str(metadata.get("floorId") or "")
    database_identity = _regular_file_identity(source_database, "source_database")
    files = [metadata_identity, database_identity]
    jsonl_values: dict[str, list[dict[str, Any]]] = {}
    jsonl_diagnostics: dict[str, dict[str, Any]] = {}
    contracts = {
        "localization_trace.jsonl": TRACE_CONTRACT,
        "localization_constraints.jsonl": CONSTRAINT_CONTRACT,
        "localization_events.jsonl": STATE_EVENT_CONTRACT,
        "manual_localization_events.jsonl": MANUAL_EVENT_CONTRACT,
    }
    # localized_price_tags.json drives the tag-observation requirement;
    # read its bytes first so the observation contract matches the real
    # finalized content.
    tags_bytes, tags_identity = _stable_read_bytes(
        segment / "localized_price_tags.json",
        "localized_price_tags.json",
        maximum_bytes=128 * 1024 * 1024,
    )
    raw_tags = load_strict_json_bytes(
        tags_bytes, name="localized_price_tags.json"
    )
    if not isinstance(raw_tags, list):
        raise OfflineLocalizationError(
            "localized_price_tags.json must be a bounded array."
        )
    jsonl_names = [name for name in file_names[1:] if name != "localized_price_tags.json"]
    for name in jsonl_names:
        if name == "localization_recovery_events.jsonl":
            contract = (
                RECOVERY_EVENT_CONTRACT
                if recovery_bound
                else replace(RECOVERY_EVENT_CONTRACT, required=False)
            )
        elif name == "tag_observations.jsonl":
            contract = replace(
                TAG_OBSERVATION_CONTRACT,
                required=bool(raw_tags),
                allow_empty=not bool(raw_tags),
            )
        else:
            contract = contracts[name]
        values, diagnostics, identity = _read_jsonl_stable(
            segment / name,
            contract,
            session_id=session_id,
            expected_map_hash=map_hash,
            expected_floor_id=floor_id,
        )
        jsonl_values[name] = values
        jsonl_diagnostics[name] = diagnostics
        if identity:
            # P7R6C: the manifest identity binds the exact bytes that were
            # parsed; the role must be the canonical filename so the bundle
            # SHA matches the manifest contract.
            files.append(
                {
                    "role": name,
                    "file": name,
                    "bytes": identity["bytes"],
                    "sha256": identity["sha256"],
                }
            )
    if not recovery_bound:
        # P7R6: legacy v1 sessions read the Recovery sidecar when it exists
        # but never bind it into the manifest identity. The snapshot still
        # parses it from stable bytes so the render consumes the same view.
        recovery_path = segment / "localization_recovery_events.jsonl"
        legacy_name = "localization_recovery_events.jsonl"
        if recovery_path.is_file():
            legacy_values, legacy_diagnostics, _legacy_identity = (
                _read_jsonl_stable(
                    recovery_path,
                    replace(RECOVERY_EVENT_CONTRACT, required=False),
                    session_id=session_id,
                    expected_map_hash=map_hash,
                    expected_floor_id=floor_id,
                )
            )
        else:
            legacy_values = []
            legacy_diagnostics = {
                "file": str(recovery_path),
                "contract": RECOVERY_EVENT_CONTRACT.name,
                "total_lines": 0,
                "valid_records": 0,
                "invalid_json_lines": 0,
                "invalid_utf8_lines": 0,
                "blank_lines": 0,
                "non_object_lines": 0,
                "oversized_lines": 0,
                "format_mismatches": 0,
                "version_mismatches": 0,
                "session_mismatches": 0,
                "map_hash_mismatches": 0,
                "floor_mismatches": 0,
                "timestamp_errors": 0,
                "duplicate_ids": 0,
            }
        jsonl_values[legacy_name] = legacy_values
        jsonl_diagnostics[legacy_name] = legacy_diagnostics
    files.append(tags_identity)
    manifest = _session_input_manifest_from_identities(files, manifest_version)
    return FinalizedSessionInputSnapshot(
        metadata=metadata,
        metadata_bytes=metadata_bytes,
        source_database_sha256=database_identity["sha256"],
        jsonl_values=jsonl_values,
        jsonl_diagnostics=jsonl_diagnostics,
        localized_tags_bytes=tags_bytes,
        localized_tag_count=len(raw_tags),
        manifest=manifest,
    )


def _verified_source_database_copy(
    source: Path, work_directory: Path, expected_sha256: str
) -> Path:
    """P7R6C 方案 A: copy the source database into a private work input
    while hashing the same descriptor-stable bytes, verify the copy
    matches the snapshot identity, and hand SQLite only the verified
    immutable copy. The original database stays read-only."""

    work_directory.mkdir(parents=True, exist_ok=True)
    destination = work_directory / source.name
    try:
        path_before = source.lstat()
        if not stat.S_ISREG(path_before.st_mode):
            raise OfflineLocalizationError(
                f"Source database must be a regular file: {source.name}"
            )
        flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
        descriptor = os.open(source, flags)
        digest = hashlib.sha256()
        with os.fdopen(descriptor, "rb") as reader:
            before = os.fstat(reader.fileno())
            with destination.open("wb") as writer:
                for chunk in iter(lambda: reader.read(1024 * 1024), b""):
                    writer.write(chunk)
                    digest.update(chunk)
            after = os.fstat(reader.fileno())
        path_after = source.lstat()
    except OfflineLocalizationError:
        raise
    except OSError as exc:
        raise OfflineLocalizationError(
            f"Source database could not be copied safely: {source.name}"
        ) from exc
    if (
        not stat.S_ISREG(before.st_mode)
        or not stat.S_ISREG(path_after.st_mode)
        or (path_before.st_dev, path_before.st_ino, path_before.st_size)
        != (before.st_dev, before.st_ino, before.st_size)
        or (before.st_dev, before.st_ino, before.st_size)
        != (after.st_dev, after.st_ino, after.st_size)
        or (after.st_dev, after.st_ino, after.st_size)
        != (path_after.st_dev, path_after.st_ino, path_after.st_size)
    ):
        raise OfflineLocalizationError(
            f"Source database changed while it was being copied: {source.name}"
        )
    if digest.hexdigest() != expected_sha256:
        raise OfflineLocalizationError(
            "Source database no longer matches the finalized input snapshot."
        )
    return destination


def build_local_input_record(
    *,
    session: Path,
    source_database: Path,
    optimized_database: Path,
    prior_map: Path,
    session_input_manifest: dict[str, Any],
    prior_map_sha256: str,
    replay_parameters: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """Build the private, path-bearing record referenced by one version."""

    bundle_sha256 = session_input_bundle_sha256(session_input_manifest)
    source_entry = next(
        entry
        for entry in session_input_manifest["files"]
        if entry["role"] == "source_database"
    )
    body = {
        "format": "MarketScannerLocalizedLocalInputs",
        "version": 1,
        "paths": {
            "source_session": str(session.resolve()),
            "source_database": str(source_database.resolve()),
            "optimized_database": str(optimized_database.resolve()),
            "prior_map": str(prior_map.resolve()),
        },
        "identities": {
            "session_input_bundle_sha256": bundle_sha256,
            "source_database_sha256": source_entry["sha256"],
            "optimized_database_sha256": _sha256(optimized_database),
            "prior_map_sha256": prior_map_sha256,
            "processing_parameter_sha256": processing_parameter_sha256(
                replay_parameters
            ),
        },
    }
    return {
        **body,
        "input_identity_id": hashlib.sha256(_canonical_json_bytes(body)).hexdigest(),
    }


class OfflineLocalizationError(ValueError):
    pass


@dataclass(frozen=True)
class Pose:
    node_id: int
    timestamp: float | None
    x: float
    y: float
    yaw: float


@dataclass(frozen=True)
class AbsoluteConstraint:
    identifier: str
    node_index: int
    x: float
    y: float
    yaw: float
    weight: float
    kind: str
    source: dict[str, Any]
    translation_sigma_m: float | None = None
    yaw_sigma_rad: float | None = None


@dataclass(frozen=True)
class TagPoseBinding:
    node_index: int
    observation_timestamp: float
    node_timestamp: float
    time_delta_seconds: float
    binding_source: str


@dataclass(frozen=True)
class JsonlContract:
    name: str
    record_format: str
    versions: frozenset[int]
    required: bool
    allow_empty: bool
    timestamp_fields: tuple[str, ...]
    identity_required: bool = True
    record_id_field: str | None = None
    maximum_record_bytes: int = 1_000_000
    maximum_records: int = 500_000
    maximum_file_bytes: int | None = None
    maximum_nesting_depth: int | None = None
    strictly_increasing_timestamps: bool = False


TRACE_CONTRACT = JsonlContract(
    "localization_trace",
    "MarketScannerLocalizationTrace",
    frozenset({1}),
    True,
    False,
    ("node_timebase_timestamp", "nodeTimebaseTimestamp"),
    strictly_increasing_timestamps=True,
)
CONSTRAINT_CONTRACT = JsonlContract(
    "localization_constraints",
    "MarketScannerLocalizationConstraint",
    frozenset({1}),
    True,
    True,
    ("node_timebase_timestamp", "nodeTimebaseTimestamp"),
)
STATE_EVENT_CONTRACT = JsonlContract(
    "localization_events",
    "MarketScannerLocalizationStateEvent",
    frozenset({1}),
    True,
    False,
    ("node_timebase_timestamp", "nodeTimebaseTimestamp"),
    strictly_increasing_timestamps=True,
)
TAG_OBSERVATION_CONTRACT = JsonlContract(
    "tag_observations",
    "MarketScannerPriceTagObservation",
    frozenset({1}),
    False,
    True,
    ("node_timebase_frame_timestamp", "nodeTimebaseFrameTimestamp"),
    record_id_field="observation_id",
)
MANUAL_EVENT_CONTRACT = JsonlContract(
    "manual_localization_events",
    "MarketScannerManualLocalizationEvent",
    frozenset({1, 2, 3}),
    False,
    True,
    (
        "node_timebase_frame_timestamp",
        "nodeTimebaseFrameTimestamp",
        "timestampUnix",
    ),
)
# P7R6: terminal Recovery lifecycle evidence. Timestamps are monotonic
# uptimes, not node-timebase stamps; ``allow_empty`` only means a session
# without any Recovery episode may carry an empty file, and the record count
# must still match the finalized capture watermark exactly.
RECOVERY_EVENT_CONTRACT = JsonlContract(
    "localization_recovery_events",
    "MarketScannerRecoveryLifecycleEvent",
    frozenset({1, 2}),
    True,
    True,
    ("finished_at_uptime",),
    record_id_field="episode_id",
    maximum_record_bytes=RECOVERY_MAXIMUM_RECORD_BYTES,
    maximum_records=RECOVERY_MAXIMUM_RECORDS,
    maximum_file_bytes=RECOVERY_MAXIMUM_FILE_BYTES,
    maximum_nesting_depth=RECOVERY_MAXIMUM_NESTING_DEPTH,
)


def _json_write(path: Path, payload: Any, *, lines: bool = False) -> None:
    if lines:
        text = "".join(
            json.dumps(
                item,
                ensure_ascii=False,
                separators=(",", ":"),
                sort_keys=True,
                allow_nan=False,
            )
            + "\n"
            for item in payload
        )
    else:
        text = json.dumps(
            payload,
            ensure_ascii=False,
            indent=2,
            sort_keys=True,
            allow_nan=False,
        ) + "\n"
    path.write_text(text, encoding="utf-8")


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _database_node_inventory(path: Path) -> dict[str, Any]:
    try:
        connection = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
        try:
            rows = connection.execute(
                "SELECT id, stamp FROM Node ORDER BY id"
            ).fetchall()
            duplicate_rows = connection.execute(
                "SELECT id, COUNT(*) FROM Node GROUP BY id HAVING COUNT(*) > 1"
            ).fetchall()
        finally:
            connection.close()
    except sqlite3.Error as exc:
        raise OfflineLocalizationError(
            f"Cannot audit RTAB-Map Node inventory in {path.name}: {exc}"
        ) from exc
    if not rows:
        raise OfflineLocalizationError(f"RTAB-Map Node inventory is empty: {path.name}")
    ids: list[int] = []
    stamps: list[float] = []
    for node_id, stamp in rows:
        if isinstance(node_id, bool) or not isinstance(node_id, int):
            raise OfflineLocalizationError(f"Invalid Node.id in {path.name}")
        stamp_number = _strict_number(stamp)
        if stamp_number is None:
            raise OfflineLocalizationError(f"Invalid Node.stamp in {path.name}")
        ids.append(node_id)
        stamps.append(stamp_number)
    non_monotonic = [
        ids[index]
        for index in range(1, len(stamps))
        if stamps[index] <= stamps[index - 1]
    ]
    return {
        "ids": ids,
        "id_set": set(ids),
        "duplicate_ids": [int(row[0]) for row in duplicate_rows],
        "non_monotonic_stamp_node_ids": non_monotonic,
        "first_stamp": stamps[0],
        "last_stamp": stamps[-1],
    }


def _normalize_angle(value: float) -> float:
    while value > math.pi:
        value -= 2 * math.pi
    while value <= -math.pi:
        value += 2 * math.pi
    return value


def _pose_from(value: Any) -> tuple[float, float, float] | None:
    if not isinstance(value, dict):
        return None
    try:
        x = float(value.get("x_m"))
        y = float(value.get("y_m"))
        yaw = float(value.get("yaw_rad", 0))
    except (KeyError, TypeError, ValueError):
        return None
    if not all(math.isfinite(item) for item in (x, y, yaw)):
        return None
    return x, y, _normalize_angle(yaw)


def _field(record: dict[str, Any], snake: str, camel: str) -> Any:
    return record.get(snake) if record.get(snake) is not None else record.get(camel)


def _identity_field(value: dict[str, Any], snake: str, camel: str) -> str:
    return str(value.get(snake) or value.get(camel) or "")


def _strict_number(value: Any) -> float | None:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    number = float(value)
    return number if math.isfinite(number) else None


def _strict_integer(value: Any) -> int | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        return value
    if isinstance(value, float) and math.isfinite(value) and value.is_integer():
        return int(value)
    return None


RECOVERY_OUTCOMES = frozenset(
    {"converged", "timed_out", "cancelled", "manual_reset"}
)
RECOVERY_CANCELLATION_REASONS = frozenset(
    {
        "scan_stopped",
        "map_unloaded",
        "app_interrupted",
        "session_generation_changed",
        "operator_cancelled",
    }
)
RECOVERY_EVENT_BASE_FIELDS = frozenset(
    {
        "format", "version", "tracking_session_id", "prior_map_id",
        "prior_map_sha256", "floor_id", "episode_id", "reason",
        "outcome", "cancellation_reason", "episode_automatic",
        "started_at_uptime", "finished_at_uptime", "elapsed_ms",
        "valid_matcher_attempts", "accepted_corrections",
        "trigger_count", "automatic_trigger_count",
        "reliable_loop_trigger_count", "last_trigger_reason",
        "last_trigger_at_uptime", "selected_hypothesis_id",
        "fresh_support_frames", "final_residual_translation_m",
        "final_residual_yaw_rad", "completion_frame_step_applied",
    }
)
# v2 additionally persists the deadline, the attempts budget and the bounded
# trigger source sequence.
RECOVERY_EVENT_V2_FIELDS = RECOVERY_EVENT_BASE_FIELDS | frozenset(
    {"deadline_uptime", "maximum_valid_attempts", "trigger_records"}
)


def _validate_recovery_trigger_records(
    value: dict[str, Any],
    started_at_uptime: float,
    finished_at_uptime: float,
    last_trigger_at_uptime: float,
    line_label: str,
) -> None:
    records = value.get("trigger_records")
    if not isinstance(records, list) or not records or len(records) > 8:
        raise OfflineLocalizationError(
            f"recovery_trigger_records_invalid at {line_label}"
        )
    previous_uptime: float | None = None
    for record in records:
        uptime = _strict_number(record.get("at_uptime") if isinstance(record, dict) else None)
        if (
            not isinstance(record, dict)
            or set(record) - {"reason", "automatic", "at_uptime"}
            or not isinstance(record.get("reason"), str)
            or not record.get("reason")
            or not isinstance(record.get("automatic"), bool)
            or uptime is None
            or uptime < started_at_uptime
            or uptime > finished_at_uptime
        ):
            raise OfflineLocalizationError(
                f"recovery_trigger_records_invalid at {line_label}"
            )
        if previous_uptime is not None and uptime < previous_uptime:
            raise OfflineLocalizationError(
                f"recovery_trigger_records_invalid at {line_label}"
            )
        previous_uptime = uptime
    # Bounded eviction may drop early records, but the newest retained record
    # must always agree with the persisted trigger summary.
    newest = records[-1]
    newest_uptime = _strict_number(newest.get("at_uptime"))
    if (
        newest.get("reason") != value.get("last_trigger_reason")
        or newest_uptime is None
        or abs(newest_uptime - last_trigger_at_uptime) > 1.0e-9
    ):
        raise OfflineLocalizationError(
            f"recovery_trigger_records_invalid at {line_label}"
        )


def _validate_recovery_event_record(value: dict[str, Any], line_label: str) -> None:
    """Mirror the on-device R6-03 strict lifecycle schema, fail closed."""

    version = value.get("version")
    allowed_fields = (
        RECOVERY_EVENT_V2_FIELDS if version == 2 else RECOVERY_EVENT_BASE_FIELDS
    )
    if set(value) - allowed_fields:
        raise OfflineLocalizationError(f"recovery_unknown_field at {line_label}")
    outcome = value.get("outcome")
    if outcome not in RECOVERY_OUTCOMES:
        raise OfflineLocalizationError(f"recovery_outcome_invalid at {line_label}")
    cancellation = value.get("cancellation_reason")
    if outcome == "cancelled":
        if cancellation not in RECOVERY_CANCELLATION_REASONS:
            raise OfflineLocalizationError(
                f"recovery_cancellation_reason_invalid at {line_label}"
            )
    elif cancellation is not None:
        raise OfflineLocalizationError(
            f"recovery_cancellation_reason_invalid at {line_label}"
        )
    started = _strict_number(value.get("started_at_uptime"))
    finished = _strict_number(value.get("finished_at_uptime"))
    elapsed_ms = _strict_number(value.get("elapsed_ms"))
    episode_id = _strict_integer(value.get("episode_id"))
    valid_attempts = _strict_integer(value.get("valid_matcher_attempts"))
    accepted_corrections = _strict_integer(value.get("accepted_corrections"))
    trigger_count = _strict_integer(value.get("trigger_count"))
    automatic_count = _strict_integer(value.get("automatic_trigger_count"))
    reliable_count = _strict_integer(value.get("reliable_loop_trigger_count"))
    last_trigger_reason = value.get("last_trigger_reason")
    last_trigger_at = _strict_number(value.get("last_trigger_at_uptime"))
    fresh_frames = _strict_integer(value.get("fresh_support_frames"))
    if (
        started is None
        or started < 0
        or finished is None
        or finished < started
        or elapsed_ms is None
        or elapsed_ms < 0
        or abs(elapsed_ms - (finished - started) * 1000.0) > 1.0
        or episode_id is None
        or episode_id <= 0
        or valid_attempts is None
        or valid_attempts < 0
        or accepted_corrections is None
        or not 0 <= accepted_corrections <= valid_attempts
        or trigger_count is None
        or trigger_count < 1
        or automatic_count is None
        or automatic_count < 0
        or reliable_count is None
        or reliable_count < 0
        or automatic_count + reliable_count != trigger_count
        or not isinstance(last_trigger_reason, str)
        or not last_trigger_reason
        or last_trigger_at is None
        or last_trigger_at < started
        or last_trigger_at > finished
        or fresh_frames is None
        or fresh_frames < 0
        or not isinstance(value.get("episode_automatic"), bool)
        or not isinstance(value.get("completion_frame_step_applied"), bool)
        or not isinstance(value.get("reason"), str)
        or not value.get("reason")
    ):
        raise OfflineLocalizationError(
            f"recovery_business_schema_invalid at {line_label}"
        )
    if version == 2:
        deadline = _strict_number(value.get("deadline_uptime"))
        maximum_attempts = _strict_integer(value.get("maximum_valid_attempts"))
        if (
            deadline is None
            or deadline < started
            or maximum_attempts is None
            or maximum_attempts < 1
            or valid_attempts > maximum_attempts
        ):
            raise OfflineLocalizationError(
                f"recovery_business_schema_invalid at {line_label}"
            )
        _validate_recovery_trigger_records(
            value,
            started,
            finished,
            last_trigger_at,
            line_label,
        )
    hypothesis = value.get("selected_hypothesis_id")
    if hypothesis is not None:
        hypothesis_id = _strict_integer(hypothesis)
        if hypothesis_id is None or hypothesis_id <= 0:
            raise OfflineLocalizationError(
                f"recovery_business_schema_invalid at {line_label}"
            )
    for field_name in ("final_residual_translation_m", "final_residual_yaw_rad"):
        residual = value.get(field_name)
        if residual is not None:
            residual_number = _strict_number(residual)
            if residual_number is None or residual_number < 0:
                raise OfflineLocalizationError(
                    f"recovery_business_schema_invalid at {line_label}"
                )


def _validate_recovery_event_sequence(values: Sequence[dict[str, Any]]) -> None:
    """Episode set contract: IDs strictly increase and terminal finish uptimes
    never move backwards."""

    previous_episode_id: int | None = None
    previous_finished: float | None = None
    for value in values:
        episode_id = _strict_integer(value.get("episode_id"))
        finished = _strict_number(value.get("finished_at_uptime"))
        if episode_id is None or finished is None:
            raise OfflineLocalizationError(
                "recovery_business_schema_invalid at episode sequence"
            )
        if previous_episode_id is not None and episode_id <= previous_episode_id:
            raise OfflineLocalizationError("recovery_episode_order_invalid")
        if previous_finished is not None and finished < previous_finished:
            raise OfflineLocalizationError("recovery_finish_order_invalid")
        previous_episode_id = episode_id
        previous_finished = finished


def _strict_pose(value: Any) -> bool:
    return isinstance(value, dict) and all(
        _strict_number(value.get(field)) is not None
        for field in ("x_m", "y_m", "yaw_rad")
    )


def _strict_pose_2d_or_3d(value: Any) -> bool:
    if not isinstance(value, dict):
        return False
    required = (_strict_number(value.get("x_m")), _strict_number(value.get("y_m")))
    height = value.get("height_m")
    return all(item is not None for item in required) and (
        height is None or _strict_number(height) is not None
    )


def _node_timebase_timestamp(
    value: dict[str, Any], *, frame: bool = False
) -> float:
    raw = _field(
        value,
        "frame_timestamp" if frame else "timestamp",
        "frameTimestamp" if frame else "timestamp",
    )
    converted = _field(
        value,
        "node_timebase_frame_timestamp" if frame else "node_timebase_timestamp",
        "nodeTimebaseFrameTimestamp" if frame else "nodeTimebaseTimestamp",
    )
    offset = _field(
        value, "node_timebase_offset_seconds", "nodeTimebaseOffsetSeconds"
    )
    raw_number = _strict_number(raw)
    converted_number = _strict_number(converted)
    offset_number = _strict_number(offset)
    if (
        raw_number is None
        or converted_number is None
        or offset_number is None
        or abs(raw_number + offset_number - converted_number) > 1.0e-6
    ):
        raise OfflineLocalizationError("node_timebase_contract_invalid")
    return converted_number


def _validate_jsonl_business_record(
    contract: JsonlContract, value: dict[str, Any], line_label: str
) -> None:
    if contract.name in {
        "localization_trace",
        "localization_constraints",
        "localization_events",
    }:
        _node_timebase_timestamp(value)
    elif contract.name in {"tag_observations", "manual_localization_events"} and value.get(
        "version"
    ) != 1:
        _node_timebase_timestamp(value, frame=True)
    elif contract.name == "tag_observations":
        _node_timebase_timestamp(value, frame=True)
    if contract.name == "localization_trace":
        if not _strict_pose(_field(value, "raw_pose", "rawPose")) or not _strict_pose(
            _field(value, "estimated_pose", "estimatedPose")
        ):
            raise OfflineLocalizationError(f"Invalid trace pose at {line_label}")
        for field in ("trackingState", "localizationState"):
            snake = re.sub(r"(?<!^)(?=[A-Z])", "_", field).lower()
            if not isinstance(_field(value, snake, field), str) or not _field(
                value, snake, field
            ):
                raise OfflineLocalizationError(f"Missing trace {snake} at {line_label}")
        confidence = _strict_number(value.get("confidence"))
        if confidence is None or not 0 <= confidence <= 1:
            raise OfflineLocalizationError(f"Invalid trace confidence at {line_label}")
        disposition = _field(value, "constraint_disposition", "constraintDisposition")
        accepted = _field(value, "constraint_accepted", "constraintAccepted")
        if disposition is not None:
            allowed = {
                "rejected",
                "provisional_recovery_step",
                "accepted_local",
                "accepted_recovery_convergence",
            }
            if disposition not in allowed:
                raise OfflineLocalizationError(
                    f"Invalid constraint disposition at {line_label}"
                )
            if disposition == "provisional_recovery_step" and accepted is not False:
                raise OfflineLocalizationError(
                    f"Provisional recovery step marked accepted at {line_label}"
                )
    elif contract.name == "localization_constraints":
        if not isinstance(value.get("accepted"), bool):
            raise OfflineLocalizationError(f"Invalid constraint accepted flag at {line_label}")
        if not _strict_pose(_field(value, "predicted_pose", "predictedPose")):
            raise OfflineLocalizationError(f"Invalid predicted constraint pose at {line_label}")
        if value.get("accepted") is True and not _strict_pose(
            _field(value, "estimated_pose", "estimatedPose")
        ):
            raise OfflineLocalizationError(f"Accepted constraint has no pose at {line_label}")
        uniqueness = _strict_number(value.get("uniqueness"))
        if uniqueness is None or not 0 <= uniqueness <= 1:
            raise OfflineLocalizationError(f"Invalid constraint uniqueness at {line_label}")
        disposition = value.get("disposition")
        if disposition is not None:
            allowed = {
                "rejected",
                "provisional_recovery_step",
                "accepted_local",
                "accepted_recovery_convergence",
            }
            if disposition not in allowed:
                raise OfflineLocalizationError(
                    f"Invalid constraint disposition at {line_label}"
                )
            if disposition == "provisional_recovery_step" and value.get("accepted"):
                raise OfflineLocalizationError(
                    f"Provisional recovery step marked accepted at {line_label}"
                )
    elif contract.name == "localization_events":
        state = value.get("state")
        confidence = _strict_number(value.get("confidence"))
        if not isinstance(state, str) or not state:
            raise OfflineLocalizationError(f"Missing localization state at {line_label}")
        if confidence is None or not 0 <= confidence <= 1:
            raise OfflineLocalizationError(f"Invalid localization confidence at {line_label}")
    elif contract.name == "localization_recovery_events":
        _validate_recovery_event_record(value, line_label)
    elif contract.name == "tag_observations":
        for field in ("observation_id", "payload", "symbology"):
            if not isinstance(value.get(field), str) or not value.get(field):
                raise OfflineLocalizationError(f"Missing tag observation {field} at {line_label}")
        if not _strict_pose_2d_or_3d(value.get("raw_map_position")):
            raise OfflineLocalizationError(f"Invalid tag observation raw position at {line_label}")


def _read_jsonl_bytes(
    data: bytes,
    contract: JsonlContract,
    *,
    path_label: str,
    session_id: str,
    expected_map_hash: str,
    expected_floor_id: str,
) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    """Validate one formal JSONL contract from already-stable bytes.

    P7R6C: callers hand in the exact bytes that were hashed, so the
    parsed records and the manifest identity can never describe
    different content. The validation contract is unchanged.
    """
    diagnostics: dict[str, Any] = {
        "file": path_label,
        "contract": contract.name,
        "total_lines": 0,
        "valid_records": 0,
        "invalid_json_lines": 0,
        "invalid_utf8_lines": 0,
        "blank_lines": 0,
        "non_object_lines": 0,
        "oversized_lines": 0,
        "format_mismatches": 0,
        "version_mismatches": 0,
        "session_mismatches": 0,
        "map_hash_mismatches": 0,
        "floor_mismatches": 0,
        "timestamp_errors": 0,
        "duplicate_ids": 0,
    }
    values: list[dict[str, Any]] = []
    if contract.maximum_file_bytes is not None and len(data) > contract.maximum_file_bytes:
        raise OfflineLocalizationError(
            f"{path_label} exceeds the bounded file-size safety limit."
        )
    parts = data.split(b"\n")
    if parts[-1] != b"":
        # P7R6A: the formal JSONL contract always ends every record with
        # a newline. A complete JSON object without its final newline is
        # partial evidence and fails closed.
        raise OfflineLocalizationError(
            f"Missing final newline at {path_label}:{len(parts)}"
        )
    parts.pop()
    seen_ids: set[str] = set()
    previous_timestamp: float | None = None
    for line_no, part in enumerate(parts, start=1):
        raw_line = part + b"\n"
        diagnostics["total_lines"] += 1
        if len(raw_line) > contract.maximum_record_bytes:
            diagnostics["oversized_lines"] += 1
            raise OfflineLocalizationError(
                f"Oversized record at {path_label}:{line_no}"
            )
        try:
            line = raw_line.decode("utf-8", errors="strict")
        except UnicodeDecodeError as exc:
            diagnostics["invalid_utf8_lines"] += 1
            raise OfflineLocalizationError(
                f"Invalid UTF-8 at {path_label}:{line_no}"
            ) from exc
        if not line.strip():
            diagnostics["blank_lines"] += 1
            raise OfflineLocalizationError(
                f"Blank JSONL record at {path_label}:{line_no}"
            )
        try:
            value = json.loads(
                line,
                parse_constant=reject_nonfinite_json,
                object_pairs_hook=reject_duplicate_object_pairs,
            )
        except (json.JSONDecodeError, ValueError, RecursionError) as exc:
            diagnostics["invalid_json_lines"] += 1
            raise OfflineLocalizationError(
                f"Invalid JSON at {path_label}:{line_no}: {exc}"
            ) from exc
        if not isinstance(value, dict):
            diagnostics["non_object_lines"] += 1
            raise OfflineLocalizationError(
                f"Non-object record at {path_label}:{line_no}"
            )
        if (
            contract.maximum_nesting_depth is not None
            and json_nesting_depth(value) > contract.maximum_nesting_depth
        ):
            diagnostics["invalid_json_lines"] += 1
            raise OfflineLocalizationError(
                f"{path_label}:{line_no} exceeds the bounded "
                f"nesting-depth safety limit."
            )
        if value.get("format") != contract.record_format:
            diagnostics["format_mismatches"] += 1
            raise OfflineLocalizationError(
                f"Format mismatch at {path_label}:{line_no}"
            )
        version = value.get("version")
        if (
            isinstance(version, bool)
            or not isinstance(version, int)
            or version not in contract.versions
        ):
            diagnostics["version_mismatches"] += 1
            raise OfflineLocalizationError(
                f"Version mismatch at {path_label}:{line_no}"
            )
        legacy_manual = contract.name == "manual_localization_events" and version == 1
        if contract.identity_required and not legacy_manual and _identity_field(
            value, "tracking_session_id", "trackingSessionId"
        ) != session_id:
            diagnostics["session_mismatches"] += 1
            raise OfflineLocalizationError(
                f"Tracking-session mismatch at {path_label}:{line_no}"
            )
        if contract.identity_required and not legacy_manual and _identity_field(
            value, "prior_map_sha256", "priorMapSha256"
        ) != expected_map_hash:
            diagnostics["map_hash_mismatches"] += 1
            raise OfflineLocalizationError(
                f"Prior-map hash mismatch at {path_label}:{line_no}"
            )
        if contract.identity_required and not legacy_manual and _identity_field(
            value, "floor_id", "floorId"
        ) != expected_floor_id:
            diagnostics["floor_mismatches"] += 1
            raise OfflineLocalizationError(
                f"Floor mismatch at {path_label}:{line_no}"
            )
        timestamp = next(
            (value.get(field) for field in contract.timestamp_fields if field in value),
            None,
        )
        try:
            timestamp_valid = (
                timestamp is not None
                and not isinstance(timestamp, bool)
                and math.isfinite(float(timestamp))
            )
        except (TypeError, ValueError):
            timestamp_valid = False
        if not timestamp_valid:
            diagnostics["timestamp_errors"] += 1
            raise OfflineLocalizationError(
                f"Invalid timestamp at {path_label}:{line_no}"
            )
        timestamp_number = float(timestamp)
        if (
            contract.strictly_increasing_timestamps
            and previous_timestamp is not None
            and timestamp_number <= previous_timestamp
        ):
            diagnostics["timestamp_errors"] += 1
            raise OfflineLocalizationError(
                f"Duplicate or non-monotonic timestamp at {path_label}:{line_no}"
            )
        previous_timestamp = timestamp_number
        _validate_jsonl_business_record(
            contract, value, f"{path_label}:{line_no}"
        )
        if contract.record_id_field is not None:
            record_id = str(value.get(contract.record_id_field) or "")
            if not record_id or record_id in seen_ids:
                diagnostics["duplicate_ids"] += 1
                raise OfflineLocalizationError(
                    f"Missing or duplicate {contract.record_id_field} at "
                    f"{path_label}:{line_no}"
                )
            seen_ids.add(record_id)
        values.append(value)
        diagnostics["valid_records"] += 1
        if len(values) > contract.maximum_records:
            raise OfflineLocalizationError(
                f"{path_label} exceeds the bounded "
                f"{contract.maximum_records}-record safety limit."
            )
    if not contract.allow_empty and not values:
        raise OfflineLocalizationError(
            f"Required sidecar file is empty: {path_label}"
        )
    return values, diagnostics


def _read_jsonl_stable(
    path: Path,
    contract: JsonlContract,
    *,
    session_id: str,
    expected_map_hash: str,
    expected_floor_id: str,
) -> tuple[list[dict[str, Any]], dict[str, Any], dict[str, Any]]:
    """P7R6C: one descriptor-stable read that is hashed and parsed from
    the same bytes. Returns the validated records, diagnostics and the
    manifest identity of those exact bytes."""
    values: list[dict[str, Any]] = []
    empty_diagnostics: dict[str, Any] = {
        "file": str(path),
        "contract": contract.name,
        "total_lines": 0,
        "valid_records": 0,
        "invalid_json_lines": 0,
        "invalid_utf8_lines": 0,
        "blank_lines": 0,
        "non_object_lines": 0,
        "oversized_lines": 0,
        "format_mismatches": 0,
        "version_mismatches": 0,
        "session_mismatches": 0,
        "map_hash_mismatches": 0,
        "floor_mismatches": 0,
        "timestamp_errors": 0,
        "duplicate_ids": 0,
    }
    if not path.is_file():
        if contract.required:
            raise OfflineLocalizationError(
                f"Required sidecar file is missing: {path.name}"
            )
        return values, empty_diagnostics, {}
    data, identity = _stable_read_bytes(path, contract.name)
    values, diagnostics = _read_jsonl_bytes(
        data,
        contract,
        path_label=path.name,
        session_id=session_id,
        expected_map_hash=expected_map_hash,
        expected_floor_id=expected_floor_id,
    )
    diagnostics["file"] = str(path)
    return values, diagnostics, identity


def _read_jsonl(
    path: Path,
    contract: JsonlContract,
    *,
    session_id: str,
    expected_map_hash: str,
    expected_floor_id: str,
) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    """Read one formally declared JSONL contract and fail closed on
    damage. The file is read exactly once through the stable descriptor
    path and validated from those same bytes."""
    values, diagnostics, _ = _read_jsonl_stable(
        path,
        contract,
        session_id=session_id,
        expected_map_hash=expected_map_hash,
        expected_floor_id=expected_floor_id,
    )
    return values, diagnostics


def _read_localized_price_tags_bytes(
    data: bytes,
    *,
    session_id: str,
    expected_map_id: str,
    expected_map_hash: str,
    expected_floor_id: str,
    expected_count: int,
    maximum_bytes: int = 128 * 1024 * 1024,
    maximum_records: int = 500_000,
) -> list[dict[str, Any]]:
    """Validate localized_price_tags.json from already-stable bytes
    (P7R6C): the bytes that were hashed are the bytes that are parsed."""
    if len(data) > maximum_bytes:
        raise OfflineLocalizationError("localized_price_tags.json exceeds its safety limit.")
    try:
        payload = load_strict_json_bytes(data, name="localized_price_tags.json")
    except ValueError as exc:
        raise OfflineLocalizationError(
            f"localized_price_tags.json is invalid: {exc}"
        ) from exc
    if not isinstance(payload, list) or len(payload) > maximum_records:
        raise OfflineLocalizationError(
            "localized_price_tags.json must be a bounded array."
        )
    if len(payload) != expected_count:
        raise OfflineLocalizationError(
            "localized_price_tags.json count does not match finalized metadata."
        )
    allowed_fields = {
        "format", "version", "tag_id", "observation_id", "payload", "symbology",
        "floor_id", "timestamp", "tracking_session_id", "prior_map_id",
        "prior_map_sha256", "shelf_code", "row_flag", "cross_code", "shelf_side",
        "distance_from_shelf_start_cm", "height_cm", "raw_map_position",
        "snapped_map_position", "localization_confidence", "measurement_confidence",
        "association_confidence", "measurement_method", "needs_review", "user_confirmed",
    }
    tags: list[dict[str, Any]] = []
    tag_ids: set[str] = set()
    observation_ids: set[str] = set()
    for index, item in enumerate(payload):
        if not isinstance(item, dict):
            raise OfflineLocalizationError(
                f"localized_price_tags.json item {index} is not an object."
            )
        unexpected_fields = sorted(set(item) - allowed_fields)
        if unexpected_fields:
            raise OfflineLocalizationError(
                "localized_price_tags.json item "
                f"{index} contains forbidden derived fields: {unexpected_fields}."
            )
        version = item.get("version")
        if (
            item.get("format") != "MarketScannerLocalizedPriceTag"
            or isinstance(version, bool)
            or not isinstance(version, int)
            or version != 1
        ):
            raise OfflineLocalizationError(
                f"localized_price_tags.json item {index} has an invalid contract."
            )
        if (
            _identity_field(item, "tracking_session_id", "trackingSessionId")
            != session_id
            or _identity_field(item, "prior_map_sha256", "priorMapSha256")
            != expected_map_hash
            or _identity_field(item, "floor_id", "floorId") != expected_floor_id
        ):
            raise OfflineLocalizationError(
                f"localized_price_tags.json item {index} has mismatched identity."
            )
        prior_map_id = item.get("prior_map_id")
        if prior_map_id != expected_map_id:
            raise OfflineLocalizationError(
                f"localized_price_tags.json item {index} has an invalid prior_map_id."
            )
        for field in ("shelf_code", "row_flag", "cross_code", "shelf_side"):
            value = item.get(field)
            if value is not None and (not isinstance(value, str) or len(value) > 128):
                raise OfflineLocalizationError(
                    f"localized_price_tags.json item {index} has an invalid {field}."
                )
        for field, lower, upper in (
            ("distance_from_shelf_start_cm", 0.0, 100_000.0),
            ("height_cm", 0.0, 500.0),
        ):
            value = item.get(field)
            if value is not None and (
                _strict_number(value) is None or not lower <= float(value) <= upper
            ):
                raise OfflineLocalizationError(
                    f"localized_price_tags.json item {index} has an invalid {field}."
                )
        tag_id = item.get("tag_id")
        observation_id = item.get("observation_id")
        if (
            not isinstance(tag_id, str)
            or not tag_id
            or not isinstance(observation_id, str)
            or not observation_id
            or tag_id in tag_ids
            or observation_id in observation_ids
        ):
            raise OfflineLocalizationError(
                f"localized_price_tags.json item {index} has missing/duplicate IDs."
            )
        for field in ("payload", "symbology", "measurement_method"):
            if not isinstance(item.get(field), str) or not item.get(field):
                raise OfflineLocalizationError(
                    f"localized_price_tags.json item {index} has invalid {field}."
                )
        if not isinstance(item.get("needs_review"), bool) or not isinstance(
            item.get("user_confirmed"), bool
        ):
            raise OfflineLocalizationError(
                f"localized_price_tags.json item {index} has invalid boolean fields."
            )
        timestamp = _strict_number(item.get("timestamp"))
        confidences = [
            _strict_number(item.get(field))
            for field in (
                "localization_confidence",
                "measurement_confidence",
                "association_confidence",
            )
        ]
        if (
            timestamp is None
            or any(value is None or not 0 <= value <= 1 for value in confidences)
        ):
            raise OfflineLocalizationError(
                f"localized_price_tags.json item {index} has out-of-range numeric fields."
            )
        for position_field in ("raw_map_position", "snapped_map_position"):
            position = item.get(position_field)
            if position is None:
                continue
            if not isinstance(position, dict):
                raise OfflineLocalizationError(
                    f"localized_price_tags.json item {index} has invalid {position_field}."
                )
            if not _strict_pose_2d_or_3d(position):
                raise OfflineLocalizationError(
                    f"localized_price_tags.json item {index} has invalid {position_field}."
                )
        tag_ids.add(tag_id)
        observation_ids.add(observation_id)
        tags.append({key: item[key] for key in allowed_fields if key in item})
    return tags


def _read_localized_price_tags_stable(
    path: Path,
    *,
    session_id: str,
    expected_map_id: str,
    expected_map_hash: str,
    expected_floor_id: str,
    expected_count: int,
) -> tuple[list[dict[str, Any]], dict[str, Any], bytes]:
    """P7R6C: one descriptor-stable read; returns validated tags, the
    manifest identity of the exact bytes, and the bytes themselves."""
    data, identity = _stable_read_bytes(path, "localized_price_tags.json")
    tags = _read_localized_price_tags_bytes(
        data,
        session_id=session_id,
        expected_map_id=expected_map_id,
        expected_map_hash=expected_map_hash,
        expected_floor_id=expected_floor_id,
        expected_count=expected_count,
    )
    return tags, identity, data


def _read_localized_price_tags(
    path: Path,
    *,
    session_id: str,
    expected_map_id: str,
    expected_map_hash: str,
    expected_floor_id: str,
    expected_count: int,
    maximum_bytes: int = 128 * 1024 * 1024,
    maximum_records: int = 500_000,
) -> list[dict[str, Any]]:
    """Read localized_price_tags.json exactly once through the stable
    descriptor path and validate from those same bytes."""
    if not path.is_file():
        raise OfflineLocalizationError("Required localized_price_tags.json is missing.")
    data, _identity = _stable_read_bytes(
        path, "localized_price_tags.json", maximum_bytes=maximum_bytes
    )
    return _read_localized_price_tags_bytes(
        data,
        session_id=session_id,
        expected_map_id=expected_map_id,
        expected_map_hash=expected_map_hash,
        expected_floor_id=expected_floor_id,
        expected_count=expected_count,
        maximum_bytes=maximum_bytes,
        maximum_records=maximum_records,
    )


def _nearest_pose_index(poses: Sequence[Pose], timestamp: float | None) -> int:
    if not poses:
        raise OfflineLocalizationError("The optimized RTAB-Map trajectory is empty.")
    if timestamp is None or not math.isfinite(float(timestamp)):
        raise OfflineLocalizationError("A finite frame/node timestamp is required.")
    stamped = [
        (abs(float(pose.timestamp) - timestamp), index)
        for index, pose in enumerate(poses)
        if pose.timestamp is not None and math.isfinite(float(pose.timestamp))
    ]
    if not stamped:
        raise OfflineLocalizationError(
            "The optimized RTAB-Map trajectory has no finite node timestamps."
        )
    return min(stamped)[1]


def bind_tag_observation_to_pose(
    poses: Sequence[Pose],
    observation: dict[str, Any] | None,
    *,
    tag: dict[str, Any] | None = None,
    expected_tracking_session_id: str,
    expected_map_hashes: set[str],
    expected_floor_id: str,
    maximum_time_delta_seconds: float = 1.5,
) -> TagPoseBinding:
    """Bind one tag observation to a real RTAB-Map node, or fail closed.

    An explicit node ID is authoritative when present. Otherwise the
    observation's ARFrame timestamp is matched against ``Node.stamp``.  Wall
    clock timestamps are deliberately ignored. Identity fields are required
    whenever the session declares the corresponding identity.
    """
    if not isinstance(observation, dict):
        raise OfflineLocalizationError("tag_observation_missing")
    try:
        observation_timestamp = _node_timebase_timestamp(observation, frame=True)
    except OfflineLocalizationError as exc:
        raise OfflineLocalizationError("tag_observation_node_timebase_invalid") from exc

    identity_checks = (
        (
            "tracking_session_id",
            expected_tracking_session_id,
            str(
                observation.get("tracking_session_id")
                or observation.get("trackingSessionId")
                or ""
            ),
        ),
        (
            "floor_id",
            expected_floor_id,
            str(observation.get("floor_id") or observation.get("floorId") or ""),
        ),
    )
    for name, expected, actual in identity_checks:
        if expected and actual != expected:
            raise OfflineLocalizationError(f"tag_observation_{name}_mismatch")
    actual_map_hash = str(
        observation.get("prior_map_sha256")
        or observation.get("priorMapSha256")
        or ""
    )
    if expected_map_hashes and actual_map_hash not in expected_map_hashes:
        raise OfflineLocalizationError("tag_observation_prior_map_sha256_mismatch")
    if isinstance(tag, dict):
        expected_tag_identities = (
            (
                "tracking_session_id",
                expected_tracking_session_id,
                str(tag.get("tracking_session_id") or tag.get("trackingSessionId") or ""),
            ),
            (
                "floor_id",
                expected_floor_id,
                str(tag.get("floor_id") or tag.get("floorId") or ""),
            ),
        )
        for name, expected, actual in expected_tag_identities:
            if expected and actual != expected:
                raise OfflineLocalizationError(f"tag_{name}_mismatch")
        tag_map_hash = str(
            tag.get("prior_map_sha256") or tag.get("priorMapSha256") or ""
        )
        if expected_map_hashes and tag_map_hash not in expected_map_hashes:
            raise OfflineLocalizationError("tag_prior_map_sha256_mismatch")
        paired_identities = (
            (
                "tracking_session_id",
                str(tag.get("tracking_session_id") or tag.get("trackingSessionId") or ""),
                str(
                    observation.get("tracking_session_id")
                    or observation.get("trackingSessionId")
                    or ""
                ),
            ),
            (
                "prior_map_sha256",
                str(tag.get("prior_map_sha256") or tag.get("priorMapSha256") or ""),
                actual_map_hash,
            ),
            (
                "floor_id",
                str(tag.get("floor_id") or tag.get("floorId") or ""),
                str(observation.get("floor_id") or observation.get("floorId") or ""),
            ),
        )
        for name, tag_value, observation_value in paired_identities:
            if tag_value and observation_value != tag_value:
                raise OfflineLocalizationError(
                    f"tag_and_observation_{name}_mismatch"
                )
        for field in ("payload", "symbology"):
            if tag.get(field) != observation.get(field):
                raise OfflineLocalizationError(
                    f"tag_and_observation_{field}_mismatch"
                )
        tag_position = tag.get("raw_map_position")
        observation_position = observation.get("raw_map_position")
        if not _strict_pose_2d_or_3d(tag_position) or not _strict_pose_2d_or_3d(
            observation_position
        ):
            raise OfflineLocalizationError("tag_and_observation_raw_position_missing")
        compared_fields = ["x_m", "y_m"]
        if tag_position.get("height_m") is not None or observation_position.get(
            "height_m"
        ) is not None:
            compared_fields.append("height_m")
        if any(
            tag_position.get(field) is None
            or observation_position.get(field) is None
            or abs(float(tag_position[field]) - float(observation_position[field])) > 0.01
            for field in compared_fields
        ):
            raise OfflineLocalizationError("tag_and_observation_raw_position_mismatch")

    explicit_node_id = observation.get("nearest_node_id")
    if explicit_node_id is None:
        explicit_node_id = observation.get("node_id")
    binding_source = "frame_timestamp"
    if explicit_node_id is not None:
        if isinstance(explicit_node_id, bool):
            raise OfflineLocalizationError("tag_observation_node_id_invalid")
        try:
            node_id_number = float(explicit_node_id)
        except (TypeError, ValueError):
            raise OfflineLocalizationError("tag_observation_node_id_invalid")
        if not math.isfinite(node_id_number) or not node_id_number.is_integer():
            raise OfflineLocalizationError("tag_observation_node_id_invalid")
        node_id = int(node_id_number)
        matches = [index for index, pose in enumerate(poses) if pose.node_id == node_id]
        if not matches:
            raise OfflineLocalizationError("tag_observation_node_id_not_found")
        if len(matches) != 1:
            raise OfflineLocalizationError("tag_observation_node_id_ambiguous")
        index = matches[0]
        binding_source = "nearest_node_id"
    else:
        index = _nearest_pose_index(poses, observation_timestamp)

    node_timestamp_value = poses[index].timestamp
    if node_timestamp_value is None or not math.isfinite(float(node_timestamp_value)):
        raise OfflineLocalizationError("tag_observation_bound_node_stamp_invalid")
    node_timestamp = float(node_timestamp_value)
    time_delta = abs(observation_timestamp - node_timestamp)
    if time_delta > maximum_time_delta_seconds:
        raise OfflineLocalizationError("tag_observation_node_time_delta_exceeded")
    return TagPoseBinding(
        node_index=index,
        observation_timestamp=observation_timestamp,
        node_timestamp=node_timestamp,
        time_delta_seconds=time_delta,
        binding_source=binding_source,
    )


def bind_manual_localization_event_to_pose(
    poses: Sequence[Pose],
    event: dict[str, Any],
    *,
    expected_tracking_session_id: str,
    expected_map_hash: str,
    expected_floor_id: str,
    maximum_time_delta_seconds: float = 1.0,
) -> TagPoseBinding:
    """Validate a current manual event and bind it to the RTAB-Map timebase."""
    if event.get("format") != "MarketScannerManualLocalizationEvent":
        raise OfflineLocalizationError("manual_event_format_invalid")
    version = event.get("version")
    if version not in {2, 3}:
        raise OfflineLocalizationError("manual_event_legacy_or_unknown_version")
    identities = (
        (
            "tracking_session_id",
            expected_tracking_session_id,
            str(event.get("tracking_session_id") or ""),
        ),
        (
            "prior_map_sha256",
            expected_map_hash,
            str(event.get("prior_map_sha256") or ""),
        ),
        (
            "floor_id",
            expected_floor_id,
            str(event.get("floor_id") or ""),
        ),
    )
    for name, expected, actual in identities:
        if expected and actual != expected:
            raise OfflineLocalizationError(f"manual_event_{name}_mismatch")
    wall_unix = _strict_number(event.get("wall_clock_timestamp_unix"))
    wall_iso = event.get("wall_clock_timestamp")
    if wall_unix is None or not isinstance(wall_iso, str) or not wall_iso.strip():
        raise OfflineLocalizationError("manual_event_wall_clock_missing")
    try:
        parsed_wall = datetime.fromisoformat(wall_iso.replace("Z", "+00:00"))
    except ValueError as exc:
        raise OfflineLocalizationError("manual_event_wall_clock_invalid") from exc
    if (
        parsed_wall.tzinfo is None
        or abs(parsed_wall.astimezone(timezone.utc).timestamp() - wall_unix) > 0.01
    ):
        raise OfflineLocalizationError("manual_event_wall_clock_mismatch")
    try:
        frame_timestamp = _node_timebase_timestamp(event, frame=True)
    except OfflineLocalizationError as exc:
        raise OfflineLocalizationError("manual_event_node_timebase_invalid") from exc
    alignment_value = event.get("alignment_version")
    if isinstance(alignment_value, bool) or not isinstance(alignment_value, int):
        raise OfflineLocalizationError("manual_event_time_or_alignment_invalid")
    alignment_version = alignment_value
    if not math.isfinite(frame_timestamp) or alignment_version <= 0:
        raise OfflineLocalizationError("manual_event_time_or_alignment_invalid")
    if not _strict_pose(event.get("confirmed_map_pose")) or not _strict_pose(
        event.get("arkit_pose")
    ):
        raise OfflineLocalizationError("manual_event_pose_invalid")

    if version == 3:
        snapshot_generation = event.get("node_time_snapshot_generation")
        if (
            isinstance(snapshot_generation, bool)
            or not isinstance(snapshot_generation, int)
            or snapshot_generation <= 0
        ):
            raise OfflineLocalizationError(
                "manual_event_node_time_snapshot_generation_invalid"
            )
        if event.get("node_binding_status") != "matched":
            raise OfflineLocalizationError("manual_event_node_binding_status_invalid")
        if event.get("nearest_node_id") is None:
            raise OfflineLocalizationError("manual_event_node_evidence_missing")

    node_id_value = event.get("nearest_node_id")
    binding_source = "frame_timestamp"
    if node_id_value is not None:
        if isinstance(node_id_value, bool) or not isinstance(node_id_value, int):
            raise OfflineLocalizationError("manual_event_node_id_invalid")
        if event.get("node_binding_status") != "matched":
            raise OfflineLocalizationError("manual_event_node_binding_status_invalid")
        matches = [
            index for index, pose in enumerate(poses) if pose.node_id == node_id_value
        ]
        if len(matches) != 1:
            raise OfflineLocalizationError(
                "manual_event_node_id_not_found"
                if not matches
                else "manual_event_node_id_ambiguous"
            )
        index = matches[0]
        binding_source = "nearest_node_id"
        event_node_stamp = _strict_number(event.get("nearest_node_stamp"))
        event_delta = _strict_number(event.get("node_time_delta_seconds"))
        if event_node_stamp is None or event_delta is None:
            raise OfflineLocalizationError("manual_event_node_evidence_missing")
        actual_stamp = poses[index].timestamp
        if actual_stamp is None or not all(
            math.isfinite(value)
            for value in (event_node_stamp, event_delta, float(actual_stamp))
        ):
            raise OfflineLocalizationError("manual_event_node_evidence_invalid")
        if abs(event_node_stamp - float(actual_stamp)) > 1.0e-6:
            raise OfflineLocalizationError("manual_event_node_stamp_mismatch")
        recomputed_delta = abs(frame_timestamp - float(actual_stamp))
        if abs(event_delta - recomputed_delta) > 1.0e-6:
            raise OfflineLocalizationError("manual_event_node_delta_mismatch")
    else:
        if event.get("node_binding_status") != "frame_timestamp_only":
            raise OfflineLocalizationError("manual_event_node_binding_status_invalid")
        if event.get("nearest_node_stamp") is not None or event.get(
            "node_time_delta_seconds"
        ) is not None:
            raise OfflineLocalizationError("manual_event_node_evidence_contradictory")
        finite_candidates = [
            (abs(float(pose.timestamp) - frame_timestamp), index)
            for index, pose in enumerate(poses)
            if pose.timestamp is not None and math.isfinite(float(pose.timestamp))
        ]
        if not finite_candidates:
            raise OfflineLocalizationError("manual_event_no_node_timestamps")
        finite_candidates.sort()
        if (
            len(finite_candidates) > 1
            and abs(finite_candidates[0][0] - finite_candidates[1][0]) <= 1.0e-6
        ):
            raise OfflineLocalizationError("manual_event_timestamp_binding_ambiguous")
        index = finite_candidates[0][1]

    node_stamp_value = poses[index].timestamp
    if node_stamp_value is None or not math.isfinite(float(node_stamp_value)):
        raise OfflineLocalizationError("manual_event_bound_node_stamp_invalid")
    node_stamp = float(node_stamp_value)
    time_delta = abs(frame_timestamp - node_stamp)
    if time_delta > maximum_time_delta_seconds:
        raise OfflineLocalizationError("manual_event_node_time_delta_exceeded")
    return TagPoseBinding(
        node_index=index,
        observation_timestamp=frame_timestamp,
        node_timestamp=node_stamp,
        time_delta_seconds=time_delta,
        binding_source=binding_source,
    )


def _project_to_segment(
    x: float,
    y: float,
    start: tuple[float, float],
    end: tuple[float, float],
) -> tuple[float, float, float, float] | None:
    dx, dy = end[0] - start[0], end[1] - start[1]
    length_squared = dx * dx + dy * dy
    if length_squared <= 1.0e-12:
        return None
    fraction = max(
        0.0,
        min(1.0, ((x - start[0]) * dx + (y - start[1]) * dy) / length_squared),
    )
    projected_x = start[0] + fraction * dx
    projected_y = start[1] + fraction * dy
    return (
        projected_x,
        projected_y,
        math.hypot(x - projected_x, y - projected_y),
        math.atan2(-dx, dy),
    )


def build_road_soft_constraints(
    baseline: Sequence[Pose],
    road_graph: dict[str, Any],
    floor_id: str,
    stride: int = 8,
) -> list[AbsoluteConstraint]:
    """Build bounded, low-weight road-area/direction priors.

    These priors only attach when a sampled pose is already inside or close to
    a declared road/cross corridor. They cannot introduce a remote basin.
    """
    corridors: list[tuple[str, float, tuple[float, float], tuple[float, float]]] = []
    for cross in road_graph.get("crosses", []):
        if not isinstance(cross, dict) or str(cross.get("floor_id")) != floor_id:
            continue
        points = cross.get("points_m")
        if not isinstance(points, list):
            continue
        width = max(0.2, float(cross.get("width_m", 1.0) or 1.0))
        for segment_index, (first, second) in enumerate(zip(points, points[1:])):
            if (
                not isinstance(first, list)
                or not isinstance(second, list)
                or len(first) < 2
                or len(second) < 2
            ):
                continue
            corridors.append(
                (
                    f"{cross.get('id', 'cross')}:{segment_index}",
                    width,
                    (float(first[0]), float(first[1])),
                    (float(second[0]), float(second[1])),
                )
            )
    constraints: list[AbsoluteConstraint] = []
    sample_stride = max(1, stride)
    sampled_indices = list(range(0, len(baseline), sample_stride))
    if baseline and sampled_indices[-1:] != [len(baseline) - 1]:
        sampled_indices.append(len(baseline) - 1)
    for index in sampled_indices:
        pose = baseline[index]
        candidates: list[tuple[float, str, float, float, float, float]] = []
        for corridor_id, width, start, end in corridors:
            projected = _project_to_segment(pose.x, pose.y, start, end)
            if projected is None or projected[2] > width / 2 + 0.75:
                continue
            candidates.append(
                (
                    projected[2],
                    corridor_id,
                    projected[0],
                    projected[1],
                    projected[3],
                    width,
                )
            )
        if not candidates:
            continue
        distance, corridor_id, x, y, road_yaw, width = min(candidates)
        reverse_yaw = _normalize_angle(road_yaw + math.pi)
        yaw = min(
            (road_yaw, reverse_yaw),
            key=lambda value: abs(_normalize_angle(value - pose.yaw)),
        )
        # Weak enough to preserve the RTAB-Map trajectory, but useful across a
        # long aisle. Confidence tapers to zero outside the declared corridor.
        proximity = max(0.1, 1.0 - distance / (width / 2 + 0.75))
        weight = 0.35 * proximity
        legacy_sigma = 1.0 / math.sqrt(weight)
        constraints.append(
            AbsoluteConstraint(
                identifier=f"road-{corridor_id}-{pose.node_id}",
                node_index=index,
                x=x,
                y=y,
                yaw=yaw,
                weight=weight,
                kind="road_soft",
                source={
                    "corridor_id": corridor_id,
                    "distance_m": distance,
                    "width_m": width,
                },
                # The old scalar-weight migration used the same sigma for
                # metres and radians. Very weak road priors could therefore
                # derive yaw sigma > pi and abort the complete factor graph.
                # Preserve the translation strength while making the yaw
                # prior explicitly bounded and effectively non-directional.
                translation_sigma_m=legacy_sigma,
                yaw_sigma_rad=min(math.pi, legacy_sigma),
            )
        )
    return constraints


def infer_aisle_switch_sequence(
    trajectory: Sequence[Pose],
    road_graph: dict[str, Any],
    floor_id: str,
    stride: int = 4,
    weak_lost_intervals: Sequence[dict[str, Any]] = (),
    manual_events: Sequence[dict[str, Any]] = (),
) -> list[dict[str, Any]]:
    """Infer an auditable, ambiguity-gated corridor sequence from final poses."""

    corridors: list[
        tuple[str, float, tuple[float, float], tuple[float, float]]
    ] = []
    for cross in road_graph.get("crosses", []):
        if not isinstance(cross, dict) or str(cross.get("floor_id")) != floor_id:
            continue
        corridor_id = str(cross.get("id") or "")
        points = cross.get("points_m")
        if not corridor_id or not isinstance(points, list):
            continue
        width = max(0.2, float(cross.get("width_m", 1.0) or 1.0))
        for first, second in zip(points, points[1:]):
            if (
                isinstance(first, list)
                and isinstance(second, list)
                and len(first) >= 2
                and len(second) >= 2
            ):
                corridors.append(
                    (
                        corridor_id,
                        width,
                        (float(first[0]), float(first[1])),
                        (float(second[0]), float(second[1])),
                    )
                )
    samples: list[tuple[Pose, str | None, float | None, float | None]] = []
    for pose in trajectory[:: max(1, stride)]:
        by_corridor: dict[str, tuple[float, float]] = {}
        for corridor_id, width, start, end in corridors:
            projected = _project_to_segment(pose.x, pose.y, start, end)
            if projected is None or projected[2] > width / 2 + 0.75:
                continue
            previous = by_corridor.get(corridor_id)
            if previous is None or projected[2] < previous[0]:
                by_corridor[corridor_id] = (projected[2], width)
        ordered = sorted(
            (distance, corridor_id, width)
            for corridor_id, (distance, width) in by_corridor.items()
        )
        if not ordered:
            samples.append((pose, None, None, None))
            continue
        best_distance, best_id, _width = ordered[0]
        margin = (
            ordered[1][0] - best_distance if len(ordered) > 1 else math.inf
        )
        if len(ordered) > 1 and margin < 0.35:
            samples.append((pose, None, best_distance, margin))
        else:
            samples.append((pose, best_id, best_distance, margin))
    intervals: list[dict[str, Any]] = []
    active: dict[str, Any] | None = None
    for pose, corridor_id, distance, margin in samples:
        if corridor_id is None:
            if active is not None:
                intervals.append(active)
                active = None
            continue
        if active is None or active["corridor_id"] != corridor_id:
            if active is not None:
                intervals.append(active)
            active = {
                "corridor_id": corridor_id,
                "start_node_id": pose.node_id,
                "end_node_id": pose.node_id,
                "start_timestamp": pose.timestamp,
                "end_timestamp": pose.timestamp,
                "sample_count": 1,
                "maximum_distance_m": round(float(distance), 6),
                "minimum_uniqueness_margin_m": (
                    None if margin == math.inf else round(float(margin), 6)
                ),
                "source": "final_trajectory_geometry",
            }
        else:
            active["end_node_id"] = pose.node_id
            active["end_timestamp"] = pose.timestamp
            active["sample_count"] += 1
            active["maximum_distance_m"] = round(
                max(active["maximum_distance_m"], float(distance)), 6
            )
            if margin != math.inf:
                current_margin = active["minimum_uniqueness_margin_m"]
                active["minimum_uniqueness_margin_m"] = round(
                    float(margin)
                    if current_margin is None
                    else min(float(current_margin), float(margin)),
                    6,
                )
    if active is not None:
        intervals.append(active)
    pose_by_node = {pose.node_id: pose for pose in trajectory}
    segments_by_corridor: dict[
        str, list[tuple[tuple[float, float], tuple[float, float]]]
    ] = {}
    for corridor_id, _width, start, end in corridors:
        segments_by_corridor.setdefault(corridor_id, []).append((start, end))
    previous: dict[str, Any] | None = None
    for interval in intervals:
        start_pose = pose_by_node.get(interval["start_node_id"])
        end_pose = pose_by_node.get(interval["end_node_id"])
        direction = "stationary"
        if start_pose is not None and end_pose is not None:
            movement = (end_pose.x - start_pose.x, end_pose.y - start_pose.y)
            movement_length = math.hypot(*movement)
            candidates = segments_by_corridor.get(interval["corridor_id"], [])
            if movement_length > 1.0e-6 and candidates:
                midpoint = (
                    (start_pose.x + end_pose.x) / 2,
                    (start_pose.y + end_pose.y) / 2,
                )
                segment = min(
                    candidates,
                    key=lambda item: (
                        _project_to_segment(midpoint[0], midpoint[1], item[0], item[1])
                        or (0.0, 0.0, math.inf)
                    )[2],
                )
                tangent = (
                    segment[1][0] - segment[0][0],
                    segment[1][1] - segment[0][1],
                )
                direction = (
                    "forward"
                    if movement[0] * tangent[0] + movement[1] * tangent[1] >= 0
                    else "reverse"
                )
        interval["direction"] = direction
        interval["weak_lost_overlap"] = any(
            float(item.get("end_timestamp", -math.inf))
            >= float(interval["start_timestamp"])
            and float(item.get("start_timestamp", math.inf))
            <= float(interval["end_timestamp"])
            for item in weak_lost_intervals
        )
        interval["manual_assignment"] = any(
            event.get("type") == "assign_interval_to_aisle"
            and isinstance(event.get("new_value"), dict)
            and str(
                event["new_value"].get("aisle_id")
                or event["new_value"].get("road_id")
                or event.get("object_id")
            )
            == interval["corridor_id"]
            and float(event["new_value"].get("end_timestamp", math.inf))
            >= float(interval["start_timestamp"])
            and float(event["new_value"].get("start_timestamp", -math.inf))
            <= float(interval["end_timestamp"])
            for event in manual_events
        )
        interval["transition_from_corridor_id"] = (
            previous["corridor_id"] if previous is not None else None
        )
        interval["possible_silent_switch"] = bool(
            previous is not None
            and previous["corridor_id"] != interval["corridor_id"]
            and not previous["weak_lost_overlap"]
            and not interval["weak_lost_overlap"]
            and not interval["manual_assignment"]
        )
        previous = interval
    return intervals


def build_manual_aisle_constraints(
    baseline: Sequence[Pose],
    road_graph: dict[str, Any],
    floor_id: str,
    event: dict[str, Any],
    stride: int = 4,
) -> list[AbsoluteConstraint]:
    value = event.get("new_value")
    if not isinstance(value, dict):
        return []
    aisle_id = str(
        value.get("aisle_id") or value.get("road_id") or event.get("object_id") or ""
    )
    if not aisle_id:
        return []
    try:
        start_timestamp = float(value.get("start_timestamp", -math.inf))
        end_timestamp = float(value.get("end_timestamp", math.inf))
    except (TypeError, ValueError):
        return []
    if start_timestamp > end_timestamp:
        start_timestamp, end_timestamp = end_timestamp, start_timestamp
    segments: list[tuple[tuple[float, float], tuple[float, float]]] = []
    for cross in road_graph.get("crosses", []):
        if (
            isinstance(cross, dict)
            and str(cross.get("floor_id")) == floor_id
            and str(cross.get("id")) == aisle_id
        ):
            points = cross.get("points_m")
            if isinstance(points, list):
                for first, second in zip(points, points[1:]):
                    if (
                        isinstance(first, list)
                        and isinstance(second, list)
                        and len(first) >= 2
                        and len(second) >= 2
                    ):
                        segments.append(
                            (
                                (float(first[0]), float(first[1])),
                                (float(second[0]), float(second[1])),
                            )
                        )
    nodes = {
        str(node.get("id")): node.get("position_m")
        for node in road_graph.get("nodes", [])
        if isinstance(node, dict) and str(node.get("floor_id")) == floor_id
    }
    for edge in road_graph.get("edges", []):
        if (
            not isinstance(edge, dict)
            or str(edge.get("floor_id")) != floor_id
            or str(edge.get("id")) != aisle_id
        ):
            continue
        first, second = nodes.get(str(edge.get("from"))), nodes.get(str(edge.get("to")))
        if (
            isinstance(first, list)
            and isinstance(second, list)
            and len(first) >= 2
            and len(second) >= 2
        ):
            segments.append(
                (
                    (float(first[0]), float(first[1])),
                    (float(second[0]), float(second[1])),
                )
            )
    if not segments:
        return []
    constraints: list[AbsoluteConstraint] = []
    selected = [
        index
        for index, pose in enumerate(baseline)
        if pose.timestamp is not None
        and start_timestamp <= float(pose.timestamp) <= end_timestamp
    ]
    selected = selected[:: max(1, stride)]
    for index in selected:
        pose = baseline[index]
        candidates = [
            projection
            for start, end in segments
            if (projection := _project_to_segment(pose.x, pose.y, start, end))
            is not None
        ]
        if not candidates:
            continue
        x, y, distance, road_yaw = min(candidates, key=lambda item: item[2])
        reverse_yaw = _normalize_angle(road_yaw + math.pi)
        yaw = min(
            (road_yaw, reverse_yaw),
            key=lambda candidate: abs(_normalize_angle(candidate - pose.yaw)),
        )
        constraints.append(
            AbsoluteConstraint(
                identifier=(
                    f"manual-aisle-{event.get('event_id', aisle_id)}-{pose.node_id}"
                ),
                node_index=index,
                x=x,
                y=y,
                yaw=yaw,
                weight=4.0,
                kind="manual_aisle_assignment",
                source={**event, "projection_distance_m": distance},
            )
        )
    return constraints


def align_relative_trajectory(
    poses: Sequence[Pose],
    initial_map_pose: tuple[float, float, float],
) -> list[Pose]:
    if not poses:
        return []
    first = poses[0]
    target_x, target_y, target_yaw = initial_map_pose
    rotation = _normalize_angle(target_yaw - first.yaw)
    cosine, sine = math.cos(rotation), math.sin(rotation)
    result: list[Pose] = []
    for pose in poses:
        dx, dy = pose.x - first.x, pose.y - first.y
        result.append(
            Pose(
                node_id=pose.node_id,
                timestamp=pose.timestamp,
                x=target_x + cosine * dx - sine * dy,
                y=target_y + sine * dx + cosine * dy,
                yaw=_normalize_angle(pose.yaw + rotation),
            )
        )
    return result


def apply_pose_delta_to_point(
    baseline_pose: Pose,
    optimized_pose: Pose,
    point_xy: tuple[float, float],
) -> tuple[float, float]:
    """Apply the full SE(2) rigid delta between two poses to a planar point.

    Computes ``DeltaT = T_offline * inverse(T_baseline)`` and returns
    ``DeltaT * P_online``.  The yaw of the baseline/optimized node rotates the
    point around the baseline node translation; a pure ``dx/dy`` addition is
    only correct when the yaw correction is zero.  Height is handled separately
    by the caller because the 2-D yaw must not act on the vertical axis.

    Raises :class:`OfflineLocalizationError` for non-finite inputs so callers
    can route the tag to review instead of emitting invalid coordinates.
    """
    bx, by, byaw = baseline_pose.x, baseline_pose.y, baseline_pose.yaw
    ox, oy, oyaw = optimized_pose.x, optimized_pose.y, optimized_pose.yaw
    px, py = point_xy
    if not all(
        math.isfinite(value)
        for value in (bx, by, byaw, ox, oy, oyaw, px, py)
    ):
        raise OfflineLocalizationError(
            "Cannot apply SE(2) delta to a tag with non-finite coordinates."
        )
    delta_yaw = _normalize_angle(oyaw - byaw)
    cos_d = math.cos(delta_yaw)
    sin_d = math.sin(delta_yaw)
    # DeltaT translation: t_off - R_delta * t_base
    delta_x = ox - (cos_d * bx - sin_d * by)
    delta_y = oy - (sin_d * bx + cos_d * by)
    # P_final = R_delta * P_online + delta_t
    return (cos_d * px - sin_d * py + delta_x, sin_d * px + cos_d * py + delta_y)


def _huber_weight(residual: float, threshold: float) -> float:
    magnitude = abs(residual)
    return 1.0 if magnitude <= threshold else threshold / max(magnitude, 1.0e-12)


def _solve_banded(
    count: int,
    observations: Sequence[tuple[int, float, float]],
    smoothness: float,
    iterations: int = 120,
) -> list[float]:
    """Solve a 1-D correction field with a Jacobi-stabilized Gauss-Seidel pass."""
    values = [0.0] * count
    by_index: dict[int, list[tuple[float, float]]] = {}
    for index, target, weight in observations:
        by_index.setdefault(index, []).append((target, weight))
    for _ in range(iterations):
        maximum_change = 0.0
        for index in range(count):
            numerator = 0.0
            denominator = 0.0
            if index > 0:
                numerator += smoothness * values[index - 1]
                denominator += smoothness
            if index + 1 < count:
                numerator += smoothness * values[index + 1]
                denominator += smoothness
            for target, weight in by_index.get(index, ()):
                numerator += weight * target
                denominator += weight
            if index == 0:
                # Gauge/safety anchor: the initial map pose remains fixed
                # unless an explicit manual anchor at node zero dominates it.
                numerator += 2.0 * values[0]
                denominator += 2.0
            if denominator <= 0:
                continue
            updated = numerator / denominator
            maximum_change = max(maximum_change, abs(updated - values[index]))
            values[index] = updated
        if maximum_change < 1.0e-7:
            break
    return values


def optimize_trajectory(
    baseline: Sequence[Pose],
    constraints: Sequence[AbsoluteConstraint],
    iterations: int = 8,
) -> tuple[list[Pose], list[dict[str, Any]], list[dict[str, Any]]]:
    if not baseline:
        raise OfflineLocalizationError("Cannot optimize an empty trajectory.")
    active = list(constraints)
    rejected: list[dict[str, Any]] = []
    corrections = [[0.0] * len(baseline) for _ in range(3)]
    for _ in range(iterations):
        observations = [[], [], []]
        retained: list[AbsoluteConstraint] = []
        for constraint in active:
            index = constraint.node_index
            current = (
                baseline[index].x + corrections[0][index],
                baseline[index].y + corrections[1][index],
                _normalize_angle(baseline[index].yaw + corrections[2][index]),
            )
            residual_xy = math.hypot(constraint.x - current[0], constraint.y - current[1])
            residual_yaw = abs(_normalize_angle(constraint.yaw - current[2]))
            is_manual_anchor = constraint.kind == "manual_anchor"
            if is_manual_anchor:
                exceeds_gate = (
                    residual_xy > MANUAL_ANCHOR_MAX_TRANSLATION_M
                    or residual_yaw > MANUAL_ANCHOR_MAX_YAW_RAD
                )
            else:
                exceeds_gate = constraint.kind not in {
                    "manual_aisle_assignment",
                    "road_soft",
                } and (
                    residual_xy > HARD_REJECT_TRANSLATION_M
                    or residual_yaw > HARD_REJECT_YAW_RAD
                )
            if exceeds_gate:
                rejected.append(
                    {
                        "constraint_id": constraint.identifier,
                        "kind": constraint.kind,
                        "translation_residual_m": residual_xy,
                        "yaw_residual_deg": math.degrees(residual_yaw),
                        "reason": (
                            "manual_anchor_safety_gate"
                            if is_manual_anchor
                            else "robust_hard_gate"
                        ),
                    }
                )
                continue
            retained.append(constraint)
            xy_weight = constraint.weight * _huber_weight(
                residual_xy, HUBER_TRANSLATION_M
            )
            yaw_weight = constraint.weight * _huber_weight(
                residual_yaw, HUBER_YAW_RAD
            )
            observations[0].append((index, constraint.x - baseline[index].x, xy_weight))
            observations[1].append((index, constraint.y - baseline[index].y, xy_weight))
            observations[2].append(
                (
                    index,
                    _normalize_angle(constraint.yaw - baseline[index].yaw),
                    yaw_weight,
                )
            )
        active = retained
        corrections[0] = _solve_banded(len(baseline), observations[0], smoothness=24.0)
        corrections[1] = _solve_banded(len(baseline), observations[1], smoothness=24.0)
        corrections[2] = _solve_banded(len(baseline), observations[2], smoothness=36.0)
    optimized = [
        Pose(
            node_id=pose.node_id,
            timestamp=pose.timestamp,
            x=pose.x + corrections[0][index],
            y=pose.y + corrections[1][index],
            yaw=_normalize_angle(pose.yaw + corrections[2][index]),
        )
        for index, pose in enumerate(baseline)
    ]
    accepted = [
        {
            "constraint_id": item.identifier,
            "kind": item.kind,
            "node_id": baseline[item.node_index].node_id,
            "weight": item.weight,
            "translation_residual_m": math.hypot(
                item.x - optimized[item.node_index].x,
                item.y - optimized[item.node_index].y,
            ),
            "yaw_residual_deg": math.degrees(
                abs(_normalize_angle(item.yaw - optimized[item.node_index].yaw))
            ),
        }
        for item in active
    ]
    return optimized, accepted, rejected


def bounded_correction_metrics(
    baseline: Sequence[Pose],
    optimized: Sequence[Pose],
    constraints: Sequence[AbsoluteConstraint],
) -> dict[str, Any]:
    def objective(poses: Sequence[Pose]) -> float:
        total = 0.0
        for constraint in constraints:
            pose = poses[constraint.node_index]
            translation = math.hypot(constraint.x - pose.x, constraint.y - pose.y)
            yaw = abs(_normalize_angle(constraint.yaw - pose.yaw))
            translation_loss = (
                0.5 * translation * translation
                if translation <= HUBER_TRANSLATION_M
                else HUBER_TRANSLATION_M
                * (translation - 0.5 * HUBER_TRANSLATION_M)
            )
            yaw_loss = (
                0.5 * yaw * yaw
                if yaw <= HUBER_YAW_RAD
                else HUBER_YAW_RAD * (yaw - 0.5 * HUBER_YAW_RAD)
            )
            total += constraint.weight * (translation_loss + yaw_loss)
        return total

    relative_translation_errors: list[float] = []
    relative_yaw_errors: list[float] = []
    for base_first, base_second, opt_first, opt_second in zip(
        baseline, baseline[1:], optimized, optimized[1:]
    ):
        def relative(first: Pose, second: Pose) -> tuple[float, float, float]:
            dx = second.x - first.x
            dy = second.y - first.y
            cosine = math.cos(first.yaw)
            sine = math.sin(first.yaw)
            return (
                cosine * dx + sine * dy,
                -sine * dx + cosine * dy,
                _normalize_angle(second.yaw - first.yaw),
            )

        base_relative = relative(base_first, base_second)
        opt_relative = relative(opt_first, opt_second)
        relative_translation_errors.append(
            math.hypot(
                opt_relative[0] - base_relative[0],
                opt_relative[1] - base_relative[1],
            )
        )
        relative_yaw_errors.append(
            abs(_normalize_angle(opt_relative[2] - base_relative[2]))
        )
    return {
        "absolute_constraint_residual_diagnostic_before": round(
            objective(baseline), 9
        ),
        "absolute_constraint_residual_diagnostic_after": round(
            objective(optimized), 9
        ),
        "residual_diagnostic_scope": (
            "absolute_constraints_only; excludes the solver smoothing term and "
            "is not a convergence objective"
        ),
        "convergence_status": "fixed_iterations_no_convergence_proof",
        "maximum_local_relative_translation_change_m": round(
            max(relative_translation_errors, default=0.0), 9
        ),
        "maximum_local_relative_yaw_change_deg": round(
            math.degrees(max(relative_yaw_errors, default=0.0)), 9
        ),
    }


def _trajectory_length(poses: Sequence[Pose]) -> float:
    return sum(
        math.hypot(second.x - first.x, second.y - first.y)
        for first, second in zip(poses, poses[1:])
    )


def _state_durations(
    events: Sequence[dict[str, Any]],
    final_timestamp: float | None,
) -> tuple[dict[str, float], list[dict[str, Any]]]:
    normalized: list[tuple[float, str, dict[str, Any]]] = []
    for event in events:
        try:
            timestamp = _node_timebase_timestamp(event)
        except OfflineLocalizationError:
            continue
        if not math.isfinite(timestamp):
            continue
        normalized.append((timestamp, str(event.get("state") or "unknown"), event))
    normalized.sort(key=lambda value: value[0])
    durations: dict[str, float] = {}
    intervals: list[dict[str, Any]] = []
    for index, (start, state, event) in enumerate(normalized):
        if index + 1 < len(normalized):
            end = normalized[index + 1][0]
        elif final_timestamp is not None and math.isfinite(final_timestamp):
            end = max(start, final_timestamp)
        else:
            end = start
        duration = max(0.0, end - start)
        durations[state] = durations.get(state, 0.0) + duration
        if state in {"weak", "lost"}:
            intervals.append(
                {
                    "state": state,
                    "start_timestamp": start,
                    "end_timestamp": end,
                    "duration_seconds": duration,
                    "reason": event.get("reason"),
                }
            )
    return durations, intervals


def _trajectory_geojson(
    baseline: Sequence[Pose],
    optimized: Sequence[Pose],
    online: Sequence[dict[str, Any]],
) -> dict[str, Any]:
    online_points = [
        pose
        for record in online
        if (pose := _pose_from(_field(record, "estimated_pose", "estimatedPose"))) is not None
    ]
    features = [
        {
            "type": "Feature",
            "properties": {
                "layer": "rtabmap_optimized",
                "timestamps": [pose.timestamp for pose in baseline],
                "node_ids": [pose.node_id for pose in baseline],
            },
            "geometry": {
                "type": "LineString",
                "coordinates": [[pose.x, pose.y] for pose in baseline],
            },
        },
        {
            "type": "Feature",
            "properties": {
                "layer": "prior_map_offline_optimized",
                "timestamps": [pose.timestamp for pose in optimized],
                "node_ids": [pose.node_id for pose in optimized],
            },
            "geometry": {
                "type": "LineString",
                "coordinates": [[pose.x, pose.y] for pose in optimized],
            },
        },
    ]
    if online_points:
        features.insert(
            0,
            {
                "type": "Feature",
                "properties": {
                    "layer": "online_localization",
                    "timestamps": [
                        _field(record, "timestamp", "timestamp")
                        for record in online
                        if _pose_from(_field(record, "estimated_pose", "estimatedPose"))
                        is not None
                    ],
                },
                "geometry": {
                    "type": "LineString",
                    "coordinates": [[pose[0], pose[1]] for pose in online_points],
                },
            },
        )
    return {"type": "FeatureCollection", "features": features}


def _bounded_review_trajectory(
    trajectory: dict[str, Any], maximum_points_per_layer: int = 20_000
) -> dict[str, Any]:
    features: list[dict[str, Any]] = []
    for feature in trajectory.get("features", []):
        coordinates = feature.get("geometry", {}).get("coordinates", [])
        stride = max(1, math.ceil(len(coordinates) / maximum_points_per_layer))
        sampled = coordinates[::stride]
        if coordinates and sampled[-1:] != coordinates[-1:]:
            sampled.append(coordinates[-1])
        properties = dict(feature.get("properties", {}))
        for key in ("timestamps", "node_ids"):
            values = properties.get(key)
            if isinstance(values, list) and len(values) == len(coordinates):
                sampled_values = values[::stride]
                if values and len(sampled_values) < len(sampled):
                    sampled_values.append(values[-1])
                properties[key] = sampled_values
        features.append(
            {
                **feature,
                "properties": properties,
                "geometry": {**feature.get("geometry", {}), "coordinates": sampled},
            }
        )
    return {"type": "FeatureCollection", "features": features}


def _stable_edges(element: dict[str, Any]) -> list[tuple[str, tuple[float, float], tuple[float, float]]]:
    geometry = element.get("geometry")
    points = geometry.get("coordinates") if isinstance(geometry, dict) else None
    if not isinstance(points, list) or len(points) < 3:
        return []
    values = [(float(point[0]), float(point[1])) for point in points if len(point) >= 2]
    edges: list[tuple[tuple[float, float], tuple[float, float]]] = []
    for start, end in zip(values, values[1:] + values[:1]):
        if math.hypot(end[0] - start[0], end[1] - start[1]) <= 1.0e-9:
            continue
        if start > end:
            start, end = end, start
        edges.append((start, end))
    if element.get("shape_type") == "MapShelf":
        center = (
            sum(point[0] for point in values) / len(values),
            sum(point[1] for point in values) / len(values),
        )
        yaw = element.get("yaw_rad")
        source = element.get("source") if isinstance(element.get("source"), dict) else {}
        if isinstance(yaw, (int, float)):
            angle = float(yaw)
            if float(source.get("width", 0) or 0) < float(source.get("height", 0) or 0):
                angle += math.pi / 2
        else:
            xx = sum((point[0] - center[0]) ** 2 for point in values)
            yy = sum((point[1] - center[1]) ** 2 for point in values)
            xy = sum(
                (point[0] - center[0]) * (point[1] - center[1])
                for point in values
            )
            angle = 0.0 if math.hypot(xx - yy, 2 * xy) <= max(
                1.0e-9, (xx + yy) * 1.0e-6
            ) else 0.5 * math.atan2(2 * xy, xx - yy)
        axis = (math.cos(angle), math.sin(angle))
        if axis[0] < 0 or (abs(axis[0]) <= 1.0e-9 and axis[1] < 0):
            axis = (-axis[0], -axis[1])
        selected = sorted(
            edges,
            key=lambda edge: -abs(
                ((edge[1][0] - edge[0][0]) * axis[0]
                 + (edge[1][1] - edge[0][1]) * axis[1])
                / math.hypot(edge[1][0] - edge[0][0], edge[1][1] - edge[0][1])
            ),
        )[:2]
        result = []
        positive_normal = (-axis[1], axis[0])
        for start, end in selected:
            if (end[0] - start[0]) * axis[0] + (end[1] - start[1]) * axis[1] < 0:
                start, end = end, start
            midpoint = ((start[0] + end[0]) / 2, (start[1] + end[1]) / 2)
            side = "A" if (
                (midpoint[0] - center[0]) * positive_normal[0]
                + (midpoint[1] - center[1]) * positive_normal[1]
            ) >= 0 else "B"
            result.append((side, start, end))
        return sorted(result)
    ordered = sorted(
        edges,
        key=lambda edge: (
            (edge[0][0] + edge[1][0]) / 2,
            (edge[0][1] + edge[1][1]) / 2,
            edge,
        ),
    )
    return [(f"E{index:02d}", start, end) for index, (start, end) in enumerate(ordered, 1)]


def _segment_intersection(
    p1: tuple[float, float],
    p2: tuple[float, float],
    p3: tuple[float, float],
    p4: tuple[float, float],
) -> tuple[float, float, float] | None:
    """Parametric segment intersection.

    Returns ``(t, u, x, y)`` is not the contract here; instead returns
    ``(t, u, dist)`` where ``t`` is the parameter along segment ``p1->p2``
    (the ray from camera to tag) and ``u`` along ``p3->p4`` (the occluding
    edge), and ``dist`` is the Euclidean distance from ``p1`` to the hit point.
    Returns ``None`` if the segments do not properly intersect.

    Handles collinear and endpoint cases with a small tolerance so that a ray
    grazing a shelf endpoint is treated as an occlusion, not a miss.
    """
    eps = 1.0e-9
    x1, y1 = p1
    x2, y2 = p2
    x3, y3 = p3
    x4, y4 = p4
    rx, ry = x2 - x1, y2 - y1
    sx, sy = x4 - x3, y4 - y3
    qpx, qpy = x3 - x1, y3 - y1
    denom = rx * sy - ry * sx
    if abs(denom) < eps:
        # Parallel segments intersect only when they are collinear and their
        # finite intervals overlap. The nearest overlap point is the occluder.
        if abs(qpx * ry - qpy * rx) >= eps:
            return None
        ray_length_squared = rx * rx + ry * ry
        if ray_length_squared <= eps:
            return None
        t0 = (qpx * rx + qpy * ry) / ray_length_squared
        t1 = t0 + (sx * rx + sy * ry) / ray_length_squared
        overlap_start = max(0.0, min(t0, t1))
        overlap_end = min(1.0, max(t0, t1))
        if overlap_start > overlap_end + eps:
            return None
        t = max(0.0, min(1.0, overlap_start))
        hit_x = x1 + t * rx
        hit_y = y1 + t * ry
        edge_length_squared = sx * sx + sy * sy
        u = (
            ((hit_x - x3) * sx + (hit_y - y3) * sy) / edge_length_squared
            if edge_length_squared > eps
            else 0.0
        )
        return (
            t,
            max(0.0, min(1.0, u)),
            math.hypot(hit_x - x1, hit_y - y1),
        )
    t = (qpx * sy - qpy * sx) / denom
    u = (qpx * ry - qpy * rx) / denom
    # Allow a tiny tolerance so endpoint grazes count as occlusion.
    if t < -eps or t > 1.0 + eps or u < -eps or u > 1.0 + eps:
        return None
    hit_x = x1 + t * (x2 - x1)
    hit_y = y1 + t * (y2 - y1)
    dist = math.hypot(hit_x - x1, hit_y - y1)
    return (max(0.0, min(1.0, t)), max(0.0, min(1.0, u)), dist)


def _mark_tag_for_review(tag: dict[str, Any], reason: str) -> None:
    reasons = tag.setdefault("review_reasons", [])
    if isinstance(reasons, list) and reason not in reasons:
        reasons.append(reason)
    tag["needs_review"] = True
    if tag.get("approval_status") in {None, "approved", "auto_approved"}:
        tag["approval_status"] = "pending"


def _tag_has_publishable_fields(tag: dict[str, Any]) -> bool:
    position = tag.get("final_map_position")
    if not isinstance(position, dict):
        return False
    try:
        x = float(position.get("x_m"))
        y = float(position.get("y_m"))
        offset = float(tag.get("distance_from_shelf_start_cm"))
    except (TypeError, ValueError):
        return False
    return (
        math.isfinite(x)
        and math.isfinite(y)
        and math.isfinite(offset)
        and offset >= 0
        and bool(tag.get("shelf_code"))
        and bool(tag.get("shelf_side"))
    )


def enforce_tag_state_invariants(tag: dict[str, Any]) -> dict[str, Any]:
    """Keep review and approval fields logically consistent."""
    if tag.get("needs_review") is True:
        if tag.get("approval_status") not in {"pending", "rejected"}:
            tag["approval_status"] = "pending"
        return tag
    if not _tag_has_publishable_fields(tag):
        _mark_tag_for_review(tag, "tag_missing_publishable_position_or_association")
        return tag
    if tag.get("user_confirmed") is True:
        tag["approval_status"] = "approved"
    elif tag.get("approval_status") == "approved":
        return tag
    elif (
        isinstance(tag.get("association_audit"), dict)
        and tag["association_audit"].get("status") == "auto_confirmed"
    ):
        tag["approval_status"] = "auto_approved"
    else:
        _mark_tag_for_review(tag, "automatic_approval_has_no_safe_association_evidence")
    return tag


def _associate_tag(
    tag: dict[str, Any],
    elements: Sequence[dict[str, Any]],
    camera_xy: tuple[float, float] | None = None,
) -> dict[str, Any]:
    """Safe offline shelf re-association.

    Candidate edges and occlusion edges are separate sets: every fixed
    structure edge participates in occlusion regardless of its distance to the
    tag, while only shelf/table/table-feature edges within ``candidate_radius``
    compete for the association.

    Auto-confirm requires: distance within threshold, camera and tag on the
    visible side, ray not occluded by a nearer structure, not in an endpoint
    ambiguity zone, sufficient independent-second-candidate margin, legal side
    ID, and adequate localization/measurement confidence.  Any failure
    produces ``needs_review=True`` with only a ``suggested_association``.
    """
    position = tag.get("final_map_position") or tag.get("snapped_map_position")
    if not isinstance(position, dict):
        return tag
    point = (float(position.get("x_m", 0)), float(position.get("y_m", 0)))

    candidate_radius = 1.2
    endpoint_ambiguity_m = 0.25
    min_margin = 0.15
    min_auto_confidence = 0.6

    # Build candidate edges and the full occlusion edge set.
    candidates: list[
        tuple[float, dict[str, Any], str, float, tuple[float, float], tuple[float, float]]
    ] = []
    occlusion_edges: list[tuple[tuple[float, float], tuple[float, float]]] = []
    for element in elements:
        shape = element.get("shape_type")
        edges = _stable_edges(element)
        if shape in {"MapShelf", "MapTable", "MapTableFeature"}:
            for edge_id, start, end in edges:
                dx, dy = end[0] - start[0], end[1] - start[1]
                length2 = dx * dx + dy * dy
                if length2 <= 1.0e-12:
                    continue
                ratio = max(
                    0.0,
                    min(1.0, ((point[0] - start[0]) * dx + (point[1] - start[1]) * dy) / length2),
                )
                snapped = (start[0] + ratio * dx, start[1] + ratio * dy)
                distance = math.hypot(point[0] - snapped[0], point[1] - snapped[1])
                if distance <= candidate_radius:
                    candidates.append(
                        (distance, element, edge_id, ratio * math.sqrt(length2), snapped, (start, end))
                    )
        # All fixed structures participate in occlusion, including pillars.
        if shape in {"MapShelf", "MapTable", "MapTableFeature", "MapPillar"}:
            for _edge_id, start, end in edges:
                occlusion_edges.append((start, end))

    if not candidates:
        _mark_tag_for_review(tag, "no_shelf_association_candidate")
        tag["association_audit"] = {
            "status": "not_associated",
            "candidate_search_radius_m": candidate_radius,
            "candidate_search_complete": True,
            "candidate_search_scope": "all_stable_edges_within_radius",
            "candidate_count": 0,
            "candidates": [],
        }
        return enforce_tag_state_invariants(tag)

    candidates.sort(key=lambda value: (value[0], str(value[1].get("id")), value[2]))
    best = candidates[0]
    best_distance, best_element, best_edge_id, best_offset, best_snapped, best_edge = best

    # Compute the independent second-best candidate: must come from a different
    # physical element so that two edges of the same shelf do not masquerade
    # as a confirmatory second candidate.
    second: tuple[float, dict[str, Any], str, float, tuple[float, float], tuple[float, float]] | None = None
    for candidate in candidates[1:]:
        if candidate[1].get("id") != best_element.get("id"):
            second = candidate
            break
    margin = best_distance if second is None else (second[0] - best_distance)

    # If a camera position is available, perform ray-based occlusion and
    # visible-side checks.  Without a camera position we cannot auto-confirm.
    ray_clear = True
    visible_side_consistent = True
    has_camera = camera_xy is not None and all(math.isfinite(v) for v in camera_xy)
    if has_camera:
        cam = camera_xy  # type: ignore[assignment]
        ray_length = math.hypot(point[0] - cam[0], point[1] - cam[1])
        if ray_length <= 1.0e-6:
            has_camera = False
        else:
            # Check if any occlusion edge intersects the camera→tag ray
            # closer than the tag itself.
            tag_dist = ray_length
            for occ_start, occ_end in occlusion_edges:
                hit = _segment_intersection(cam, point, occ_start, occ_end)
                if hit is not None and hit[2] < tag_dist - 0.05:
                    ray_clear = False
                    break
            # Visible-side check: the tag should be on the same side of the
            # shelf as the camera (i.e. the candidate edge faces the camera).
            dx_edge = best_edge[1][0] - best_edge[0][0]
            dy_edge = best_edge[1][1] - best_edge[0][1]
            edge_len = math.hypot(dx_edge, dy_edge)
            if edge_len > 1.0e-9:
                # Outward normal of the best edge (pointing away from shelf center).
                normal = (-dy_edge / edge_len, dx_edge / edge_len)
                # Ensure normal points outward (away from element center).
                center = best_element.get("center_m") or best_element.get("center")
                if isinstance(center, list) and len(center) >= 2:
                    cx, cy = float(center[0]), float(center[1])
                    mid = ((best_edge[0][0] + best_edge[1][0]) / 2,
                           (best_edge[0][1] + best_edge[1][1]) / 2)
                    if ((mid[0] - cx) * normal[0] + (mid[1] - cy) * normal[1]) < 0:
                        normal = (-normal[0], -normal[1])
                # Camera and tag should both be on the outward side.
                cam_side = (cam[0] - best_snapped[0]) * normal[0] + (cam[1] - best_snapped[1]) * normal[1]
                tag_side = (point[0] - best_snapped[0]) * normal[0] + (point[1] - best_snapped[1]) * normal[1]
                if cam_side < -0.05 or tag_side < -0.05:
                    visible_side_consistent = False

    # Endpoint ambiguity: tag very close to a shelf end may match either side.
    edge_length = math.hypot(
        best_edge[1][0] - best_edge[0][0], best_edge[1][1] - best_edge[0][1]
    )
    near_endpoint = best_offset < endpoint_ambiguity_m or best_offset > edge_length - endpoint_ambiguity_m

    loc_conf = float(tag.get("localization_confidence", 0) or 0)
    meas_conf = float(tag.get("measurement_confidence", 0) or 0)
    manually_modified = bool(tag.get("manually_modified"))
    user_confirmed = bool(tag.get("user_confirmed"))
    human_authoritative = (
        manually_modified
        or user_confirmed
        or tag.get("approval_status") == "approved"
    )

    can_auto_confirm = (
        has_camera
        and best_distance <= 0.45
        and ray_clear
        and visible_side_consistent
        and not near_endpoint
        and second is not None
        and margin >= min_margin
        and loc_conf >= min_auto_confidence
        and meas_conf >= min_auto_confidence
        and not human_authoritative
        and tag.get("needs_review") is not True
    )

    if can_auto_confirm:
        tag.update(
            {
                "shelf_code": best_element.get("code") or None,
                "row_flag": best_element.get("row_flag") or None,
                "cross_code": best_element.get("cross_code") or None,
                "shelf_side": best_edge_id,
                "distance_from_shelf_start_cm": round(best_offset * 100, 3),
                "final_map_position": {
                    "x_m": round(best_snapped[0], 6),
                    "y_m": round(best_snapped[1], 6),
                    "height_m": position.get("height_m"),
                },
                "association_confidence": round(max(0.0, 1 - best_distance / candidate_radius), 6),
            }
        )
        tag["needs_review"] = bool(tag.get("needs_review"))
    else:
        # Fail-closed: keep original position, provide suggestion only.
        tag["suggested_association"] = {
            "shelf_code": best_element.get("code") or None,
            "row_flag": best_element.get("row_flag") or None,
            "cross_code": best_element.get("cross_code") or None,
            "shelf_side": best_edge_id,
            "distance_from_shelf_start_cm": round(best_offset * 100, 3),
            "distance_m": round(best_distance, 6),
            "reason": _association_reject_reason(
                best_distance, ray_clear, visible_side_consistent, near_endpoint,
                margin, second is not None, loc_conf, meas_conf, has_camera
            ),
        }
        rejection_reason = tag["suggested_association"]["reason"]
        if human_authoritative:
            current = (
                tag.get("shelf_code"),
                tag.get("shelf_side"),
                tag.get("distance_from_shelf_start_cm"),
            )
            suggested = (
                tag["suggested_association"].get("shelf_code"),
                tag["suggested_association"].get("shelf_side"),
                tag["suggested_association"].get("distance_from_shelf_start_cm"),
            )
            same_business_edge = current[:2] == suggested[:2]
            try:
                offset_difference_cm = abs(float(current[2]) - float(suggested[2]))
            except (TypeError, ValueError):
                offset_difference_cm = math.inf
            if not same_business_edge or offset_difference_cm > 1.0:
                _mark_tag_for_review(tag, "human_association_conflicts_with_offline_evidence")
        else:
            _mark_tag_for_review(tag, rejection_reason)
        if "association_confidence" not in tag:
            tag["association_confidence"] = round(
                max(0.0, 1 - best_distance / candidate_radius), 6
            )
    tag["association_audit"] = {
        "status": "auto_confirmed" if can_auto_confirm else "suggested_only",
        "candidate_search_radius_m": candidate_radius,
        "candidate_search_complete": True,
        "candidate_search_scope": "all_stable_edges_within_radius",
        "candidate_count": len(candidates),
        "independent_second_candidate_present": second is not None,
        "best_distance_m": round(best_distance, 6),
        "second_distance_m": round(second[0], 6) if second is not None else None,
        "margin_m": round(margin, 6),
        "ray_clear": ray_clear,
        "visible_side_consistent": visible_side_consistent,
        "near_endpoint": near_endpoint,
        "human_authoritative": human_authoritative,
        "candidates_truncated": len(candidates) > 100,
        "candidate_set_sha256": hashlib.sha256(
            json.dumps(
                [
                    {
                        "element_id": item[1].get("id"),
                        "edge_id": item[2],
                        "distance_m": round(item[0], 9),
                    }
                    for item in candidates
                ],
                sort_keys=True,
                separators=(",", ":"),
                allow_nan=False,
            ).encode("utf-8")
        ).hexdigest(),
        "candidates": [
            {
                "element_id": item[1].get("id"),
                "shelf_code": item[1].get("code"),
                "edge_id": item[2],
                "distance_m": round(item[0], 6),
            }
            for item in candidates[:100]
        ],
    }
    return enforce_tag_state_invariants(tag)


def _association_reject_reason(
    distance: float,
    ray_clear: bool,
    visible_side: bool,
    near_endpoint: bool,
    margin: float,
    has_second: bool,
    loc_conf: float,
    meas_conf: float,
    has_camera: bool,
) -> str:
    reasons: list[str] = []
    if distance > 0.45:
        reasons.append(f"distance {distance:.2f}m exceeds 0.45m auto-confirm threshold")
    if not has_camera:
        reasons.append("no camera origin available for occlusion/visible-side check")
    if not ray_clear:
        reasons.append("camera-to-tag ray occluded by a nearer structure")
    if not visible_side:
        reasons.append("tag not on the camera-visible side of the shelf")
    if near_endpoint:
        reasons.append("tag near shelf endpoint, side ambiguous")
    if has_second and margin < 0.15:
        reasons.append(f"independent second candidate margin {margin:.2f}m below 0.15m")
    if not has_second:
        reasons.append("independent second candidate is required for auto-confirmation")
    if loc_conf < 0.6:
        reasons.append(f"localization confidence {loc_conf:.2f} below 0.60")
    if meas_conf < 0.6:
        reasons.append(f"measurement confidence {meas_conf:.2f} below 0.60")
    return "; ".join(reasons) if reasons else "unconfirmed"


def apply_manual_edits(
    constraints: list[dict[str, Any]],
    tags: list[dict[str, Any]],
    edits: dict[str, Any] | None,
    elements: Sequence[dict[str, Any]] | None = None,
) -> tuple[list[dict[str, Any]], list[dict[str, Any]], list[dict[str, Any]]]:
    events = edits.get("events", []) if isinstance(edits, dict) else []
    cursor = int(edits.get("cursor", len(events))) if isinstance(edits, dict) else 0
    audit: list[dict[str, Any]] = []
    for sequence, event in enumerate(events[: max(0, min(cursor, len(events)))], start=1):
        if not isinstance(event, dict):
            continue
        kind = event.get("type")
        target = str(event.get("object_id") or "")
        new_value = event.get("new_value")
        if kind == "disable_constraint":
            for constraint in constraints:
                if constraint.get("constraint_id") == target:
                    constraint["disabled_by_manual_edit"] = True
        elif kind == "edit_tag" and isinstance(new_value, dict):
            for tag in tags:
                if str(tag.get("tag_id")) == target:
                    tag.update(new_value)
                    if "height_cm" in new_value:
                        position = dict(tag.get("final_map_position") or {})
                        position["height_m"] = float(new_value["height_cm"]) / 100
                        tag["final_map_position"] = position
                    tag["manually_modified"] = True
                    tag["needs_review"] = True
        elif kind == "approve_tag":
            for tag in tags:
                if str(tag.get("tag_id")) == target:
                    if elements is not None and _tag_has_valid_map_association(tag, elements):
                        tag["user_confirmed"] = True
                        tag["approval_status"] = "approved"
                        tag["needs_review"] = False
                    else:
                        _mark_tag_for_review(
                            tag, "manual_approval_failed_map_association_validation"
                        )
        elif kind == "batch_approve_tags" and isinstance(new_value, list):
            approved = {str(value) for value in new_value}
            for tag in tags:
                if str(tag.get("tag_id")) in approved:
                    if elements is not None and _tag_has_valid_map_association(tag, elements):
                        tag["user_confirmed"] = True
                        tag["approval_status"] = "approved"
                        tag["needs_review"] = False
                    else:
                        _mark_tag_for_review(
                            tag, "manual_approval_failed_map_association_validation"
                        )
        audit.append(
            {
                "sequence": sequence,
                "event_id": event.get("event_id"),
                "type": kind,
                "object_id": target,
                "old_value": event.get("old_value"),
                "new_value": new_value,
                "created_at_utc": event.get("created_at_utc"),
                "base_revision": event.get("base_revision"),
                "actor": event.get("actor"),
                "reason": event.get("reason"),
            }
        )
    return constraints, tags, audit


def _tag_has_valid_map_association(
    tag: dict[str, Any], elements: Sequence[dict[str, Any]]
) -> bool:
    if not _tag_has_publishable_fields(tag):
        return False
    shelves = [
        element
        for element in elements
        if element.get("shape_type") in {"MapShelf", "MapTable", "MapTableFeature"}
        and str(element.get("code") or "") == str(tag.get("shelf_code") or "")
    ]
    if len(shelves) != 1:
        return False
    edge = next(
        (
            (start, end)
            for edge_id, start, end in _stable_edges(shelves[0])
            if edge_id == tag.get("shelf_side")
        ),
        None,
    )
    if edge is None:
        return False
    try:
        offset_m = float(tag.get("distance_from_shelf_start_cm")) / 100
        position = tag["final_map_position"]
        x = float(position["x_m"])
        y = float(position["y_m"])
    except (KeyError, TypeError, ValueError):
        return False
    length_m = math.hypot(edge[1][0] - edge[0][0], edge[1][1] - edge[0][1])
    if (
        not all(math.isfinite(value) for value in (offset_m, x, y))
        or not 0 <= offset_m <= length_m + 1.0e-9
        or length_m <= 1.0e-9
    ):
        return False
    ratio = offset_m / length_m
    shelf_x = edge[0][0] + ratio * (edge[1][0] - edge[0][0])
    shelf_y = edge[0][1] + ratio * (edge[1][1] - edge[0][1])
    return math.hypot(x - shelf_x, y - shelf_y) <= 0.45 + 1.0e-9


def new_manual_edits(
    map_sha256: str,
    session_sha256: str,
    optimized_db_sha256: str = "",
    session_input_bundle_sha256: str = "",
    input_identity_id: str = "",
    replay_parameters: dict[str, Any] | None = None,
) -> dict[str, Any]:
    return {
        "format": "MarketScannerManualEdits",
        "version": 4,
        "revision": 1,
        "prior_map_sha256": map_sha256,
        "source_database_sha256": session_sha256,
        "session_input_bundle_sha256": session_input_bundle_sha256,
        "input_identity_id": input_identity_id,
        "optimized_database_sha256": optimized_db_sha256,
        "processing_parameter_sha256": processing_parameter_sha256(
            replay_parameters
        ),
        "tool_version": TOOL_VERSION,
        "coordinate_contract_version": COORDINATE_CONTRACT_VERSION,
        "cursor": 0,
        "events": [],
        "audit_events": [],
    }


def validate_manual_edit_event(event: dict[str, Any]) -> None:
    if not isinstance(event, dict):
        raise OfflineLocalizationError("Manual edit event must be an object.")
    kind = event.get("type")
    target = str(event.get("object_id") or "")
    value = event.get("new_value")
    if kind == "set_anchor":
        if _pose_from(value) is None or not isinstance(value, dict):
            raise OfflineLocalizationError(
                "set_anchor requires new_value x_m/y_m/yaw_rad."
            )
        timestamp = value.get("timestamp")
        try:
            valid_timestamp = timestamp is not None and math.isfinite(float(timestamp))
        except (TypeError, ValueError):
            valid_timestamp = False
        if not valid_timestamp:
            raise OfflineLocalizationError("set_anchor requires a finite timestamp.")
    elif kind == "disable_constraint":
        if not target:
            raise OfflineLocalizationError("disable_constraint requires object_id.")
    elif kind == "assign_interval_to_aisle":
        if not isinstance(value, dict) or not (
            value.get("aisle_id") or value.get("road_id")
        ):
            raise OfflineLocalizationError(
                "assign_interval_to_aisle requires new_value.aisle_id."
            )
        try:
            start = float(value.get("start_timestamp"))
            end = float(value.get("end_timestamp"))
        except (TypeError, ValueError):
            raise OfflineLocalizationError(
                "assign_interval_to_aisle requires finite start/end timestamps."
            )
        if not math.isfinite(start) or not math.isfinite(end):
            raise OfflineLocalizationError(
                "assign_interval_to_aisle requires finite start/end timestamps."
            )
    elif kind == "edit_tag":
        if not target or not isinstance(value, dict) or not value:
            raise OfflineLocalizationError(
                "edit_tag requires object_id and a non-empty new_value object."
            )
        unexpected = sorted(set(value) - EDITABLE_TAG_FIELDS)
        if unexpected:
            raise OfflineLocalizationError(
                f"edit_tag contains fields that are not editable: {unexpected}."
            )
        if "shelf_code" in value and (
            not isinstance(value["shelf_code"], str)
            or not value["shelf_code"].strip()
            or len(value["shelf_code"]) > 128
        ):
            raise OfflineLocalizationError("edit_tag shelf_code is invalid.")
        if "shelf_side" in value:
            side = value["shelf_side"]
            valid_side = side in {"A", "B"} or (
                isinstance(side, str)
                and len(side) == 3
                and side.startswith("E")
                and side[1:].isdigit()
            )
            if not valid_side:
                raise OfflineLocalizationError(
                    "edit_tag shelf_side must be A, B or a stable E## edge ID."
                )
        for field, lower, upper in (
            ("distance_from_shelf_start_cm", 0.0, 100_000.0),
            ("height_cm", 0.0, 500.0),
        ):
            if field in value:
                try:
                    number = float(value[field])
                except (TypeError, ValueError) as exc:
                    raise OfflineLocalizationError(
                        f"edit_tag {field} must be finite."
                    ) from exc
                if isinstance(value[field], bool) or not math.isfinite(number) or not lower <= number <= upper:
                    raise OfflineLocalizationError(
                        f"edit_tag {field} is outside the supported range."
                    )
        if "final_map_position" in value:
            position = value["final_map_position"]
            if not isinstance(position, dict) or set(position) - {"x_m", "y_m", "height_m"}:
                raise OfflineLocalizationError("edit_tag final_map_position is invalid.")
            try:
                x = float(position["x_m"])
                y = float(position["y_m"])
                height = float(position.get("height_m", 0.0))
            except (KeyError, TypeError, ValueError) as exc:
                raise OfflineLocalizationError(
                    "edit_tag final_map_position requires finite x_m/y_m."
                ) from exc
            if not all(math.isfinite(item) for item in (x, y, height)) or not 0 <= height <= 5:
                raise OfflineLocalizationError("edit_tag final_map_position is invalid.")
    elif kind == "approve_tag":
        if not target:
            raise OfflineLocalizationError("approve_tag requires object_id.")
    elif kind == "batch_approve_tags":
        if not isinstance(value, list) or not value:
            raise OfflineLocalizationError(
                "batch_approve_tags requires a non-empty tag ID array."
            )
        identifiers = [str(item) for item in value]
        if len(identifiers) > 1_000 or any(not item for item in identifiers) or len(set(identifiers)) != len(identifiers):
            raise OfflineLocalizationError(
                "batch_approve_tags requires unique non-empty tag IDs (maximum 1000)."
            )
    else:
        raise OfflineLocalizationError(f"Unsupported manual edit type: {kind!r}.")


def append_manual_edit(
    journal: dict[str, Any],
    event: dict[str, Any],
) -> dict[str, Any]:
    validate_manual_edit_event(event)
    events = list(journal.get("events", []))
    cursor = max(0, min(int(journal.get("cursor", len(events))), len(events)))
    events = events[:cursor]
    normalized = {
        "event_id": str(event.get("event_id") or f"edit-{len(events) + 1:06d}"),
        "created_at_utc": str(
            event.get("created_at_utc") or event.get("timestamp") or ""
        ),
        "base_revision": int(event.get("base_revision", journal.get("revision", 1))),
        "type": str(event.get("type") or ""),
        "object_id": str(event.get("object_id") or ""),
        "old_value": event.get("old_value"),
        "new_value": event.get("new_value"),
        "actor": str(event.get("actor") or "local-user"),
        "reason": str(event.get("reason") or ""),
    }
    events.append(normalized)
    return {**journal, "events": events, "cursor": len(events)}


def move_manual_edit_cursor(journal: dict[str, Any], delta: int) -> dict[str, Any]:
    events = list(journal.get("events", []))
    cursor = max(0, min(len(events), int(journal.get("cursor", len(events))) + delta))
    return {**journal, "cursor": cursor}


def upgrade_manual_edits_v2(
    journal: dict[str, Any],
    map_sha256: str,
    source_database_sha256: str,
    optimized_database_sha256: str,
    session_input_bundle_sha256: str,
    input_identity_id: str,
    replay_parameters: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """Upgrade a historical v2/v3 journal using a verified current bundle."""

    if journal.get("format") != "MarketScannerManualEdits" or journal.get("version") not in {2, 3}:
        return journal
    if (
        re.fullmatch(r"[0-9a-f]{64}", session_input_bundle_sha256) is None
        or re.fullmatch(r"[0-9a-f]{64}", input_identity_id) is None
    ):
        raise OfflineLocalizationError(
            "Historical manual_edits migration requires a verified input bundle."
        )
    historical_version = int(journal["version"])
    if (
        journal.get("prior_map_sha256") != map_sha256
        or (
            journal.get("source_database_sha256")
            or journal.get("source_session_sha256")
        )
        != source_database_sha256
        or (
            journal.get("optimized_database_sha256")
            and journal.get("optimized_database_sha256")
            != optimized_database_sha256
        )
        or (
            historical_version == 3
            and journal.get("processing_parameter_sha256")
            != _legacy_processing_parameter_sha256_v3()
        )
    ):
        raise OfflineLocalizationError(
            "Historical manual_edits identity does not match the selected inputs."
        )
    upgraded = new_manual_edits(
        map_sha256,
        source_database_sha256,
        optimized_database_sha256,
        session_input_bundle_sha256,
        input_identity_id,
        replay_parameters,
    )
    upgraded["revision"] = journal.get("revision", 1)
    upgraded["cursor"] = journal.get("cursor", 0)
    upgraded["events"] = journal.get("events", [])
    historical_audit = journal.get("audit_events", [])
    if not isinstance(historical_audit, list) or any(
        not isinstance(item, dict) for item in historical_audit
    ):
        raise OfflineLocalizationError("Historical manual_edits audit is invalid.")
    upgraded["audit_events"] = [
        *historical_audit,
        {
            "event_id": f"migration-v{historical_version}-to-v4",
            "type": "journal_migrated",
            "actor": "system",
            "reason": (
                f"Historical v{historical_version} journal upgraded with the "
                "verified finalized-session bundle."
            ),
        }
    ]
    return upgraded


def _render_localized_version(
    prior_map: Path,
    session: Path,
    optimized_poses: Sequence[Pose],
    source_database: Path,
    optimized_database: Path,
    output: Path,
    session_input_manifest: dict[str, Any],
    input_identity_id: str,
    local_input_record: dict[str, Any],
    replay_parameters: dict[str, Any],
    input_snapshot: FinalizedSessionInputSnapshot,
    factor_graph_binary: Path | None = None,
    manual_edits: dict[str, Any] | None = None,
    progress: Callable[[int, str, str], None] | None = None,
) -> dict[str, Any]:
    validation = validate_package(prior_map)
    if not validation["valid"]:
        raise OfflineLocalizationError(
            "Prior-map validation failed: "
            + "; ".join(item["message"] for item in validation["errors"])
        )
    segment_dirs = sorted(path for path in session.glob("segment_*") if path.is_dir())
    if len(segment_dirs) != 1:
        raise OfflineLocalizationError("Localized processing requires one continuous segment.")
    segment = segment_dirs[0]
    expected_bundle_sha256 = session_input_bundle_sha256(session_input_manifest)
    if session_input_manifest.get("input_identity_id") != input_identity_id:
        raise OfflineLocalizationError("Session input manifest identity is inconsistent.")
    session_inputs_before = build_session_input_manifest(segment, source_database)
    if (
        session_inputs_before["bundle_sha256"] != expected_bundle_sha256
        or session_inputs_before["files"] != session_input_manifest["files"]
    ):
        raise OfflineLocalizationError(
            "Finalized session inputs changed before localized processing."
        )
    # P7R6C: the parse-and-hash-once snapshot must describe exactly the
    # bytes the manifest binds; otherwise a concurrent replacement slipped
    # between the manifest build and the snapshot read.
    if (
        input_snapshot.manifest.get("bundle_sha256") != expected_bundle_sha256
        or input_snapshot.manifest.get("files") != session_input_manifest["files"]
        or input_snapshot.source_database_sha256
        != session_input_manifest["source_database_sha256"]
    ):
        raise OfflineLocalizationError(
            "Finalized session inputs changed before localized processing."
        )
    metadata = input_snapshot.metadata
    if not isinstance(metadata, dict):
        raise OfflineLocalizationError("Session metadata is invalid.")
    if metadata.get("workflowMode") != "prior_map_localized":
        raise OfflineLocalizationError("This session is not a prior-map localized scan.")
    if metadata.get("finalized") is not True:
        raise OfflineLocalizationError("Localized processing requires a finalized session.")
    capture_health = metadata.get("captureHealth")
    processing_eligibility = metadata.get("processingEligibility")
    failure_count = (
        capture_health.get("localizationRequiredWriteFailureCount")
        if isinstance(capture_health, dict)
        else None
    )
    evidence_complete = (
        capture_health.get("localizationEvidenceComplete")
        if isinstance(capture_health, dict)
        else None
    )
    blockers = (
        processing_eligibility.get("blockers")
        if isinstance(processing_eligibility, dict)
        else None
    )
    if (
        not isinstance(capture_health, dict)
        or isinstance(failure_count, bool)
        or failure_count != 0
        or evidence_complete is not True
        or not isinstance(processing_eligibility, dict)
        or processing_eligibility.get("status") != "eligible"
        or blockers != []
    ):
        raise OfflineLocalizationError(
            "Localized processing requires complete prior-map sidecar write evidence."
        )
    manifest = load_json(prior_map / "manifest.json")
    package_manifest = load_json(prior_map / "package_manifest.json")
    expected_map_id = metadata.get("priorMapId")
    expected_hash = metadata.get("priorMapSha256")
    if expected_map_id != manifest.get("prior_map_id"):
        raise OfflineLocalizationError("Session prior_map_id does not match the selected map.")
    if expected_hash not in {
        manifest.get("source_sha256"),
        package_manifest.get("package_sha256"),
    }:
        raise OfflineLocalizationError("Session prior-map hash does not match the selected map.")
    # P7R6C: the snapshot identity is the byte-exact source database hash;
    # every downstream binding (local inputs, manual edits, manifests) uses
    # it instead of a second path-based hash pass.
    source_hash_before = input_snapshot.source_database_sha256
    session_hash = source_hash_before
    package_hash = str(package_manifest["package_sha256"])
    optimized_db_hash = _sha256(optimized_database)
    local_identities = local_input_record.get("identities")
    if (
        local_input_record.get("input_identity_id") != input_identity_id
        or not isinstance(local_identities, dict)
        or local_identities.get("session_input_bundle_sha256")
        != expected_bundle_sha256
        or local_identities.get("source_database_sha256") != source_hash_before
        or local_identities.get("optimized_database_sha256") != optimized_db_hash
        or local_identities.get("prior_map_sha256") != package_hash
        or local_identities.get("processing_parameter_sha256")
        != processing_parameter_sha256(replay_parameters)
    ):
        raise OfflineLocalizationError("Localized local-input identity is inconsistent.")
    if manual_edits is None:
        manual_edits = new_manual_edits(
            package_hash,
            session_hash,
            optimized_db_hash,
            expected_bundle_sha256,
            input_identity_id,
            replay_parameters,
        )
    manual_edits = upgrade_manual_edits_v2(
        manual_edits,
        package_hash,
        session_hash,
        optimized_db_hash,
        expected_bundle_sha256,
        input_identity_id,
        replay_parameters,
    )
    if (
        manual_edits.get("format") != "MarketScannerManualEdits"
        or manual_edits.get("version") != 4
        or manual_edits.get("prior_map_sha256") != package_hash
        or manual_edits.get("source_database_sha256") != session_hash
        or manual_edits.get("session_input_bundle_sha256")
        != expected_bundle_sha256
        or manual_edits.get("input_identity_id") != input_identity_id
        or manual_edits.get("processing_parameter_sha256")
        != processing_parameter_sha256(replay_parameters)
        or manual_edits.get("tool_version") != TOOL_VERSION
        or manual_edits.get("coordinate_contract_version")
        != COORDINATE_CONTRACT_VERSION
    ):
        raise OfflineLocalizationError("manual_edits.json does not match this map/session pair.")
    stored_optimized = manual_edits.get("optimized_database_sha256")
    if stored_optimized and stored_optimized != optimized_db_hash:
        raise OfflineLocalizationError(
            "manual_edits.json was created with a different optimized database; "
            "edits cannot be safely replayed."
        )
    try:
        edit_revision = int(manual_edits.get("revision"))
    except (TypeError, ValueError) as exc:
        raise OfflineLocalizationError(
            "manual_edits.json revision must be an integer."
        ) from exc
    if isinstance(manual_edits.get("revision"), bool) or edit_revision < 1:
        raise OfflineLocalizationError(
            "manual_edits.json revision must be a positive integer."
        )
    edit_events = manual_edits.get("events")
    if not isinstance(edit_events, list):
        raise OfflineLocalizationError("manual_edits.json events must be an array.")
    try:
        edit_cursor = int(manual_edits.get("cursor"))
    except (TypeError, ValueError):
        raise OfflineLocalizationError("manual_edits.json cursor must be an integer.")
    if edit_cursor < 0 or edit_cursor > len(edit_events):
        raise OfflineLocalizationError("manual_edits.json cursor is out of range.")
    for event in edit_events:
        validate_manual_edit_event(event)
    audit_events = manual_edits.get("audit_events")
    if not isinstance(audit_events, list) or any(
        not isinstance(item, dict) for item in audit_events
    ):
        raise OfflineLocalizationError(
            "manual_edits.json audit_events must be an object array."
        )
    if progress:
        progress(84, "先验地图轨迹优化", "正在读取在线约束并建立稳健 SE(2) 修正问题")

    sidecar_session_id = str(metadata.get("trackingSessionId") or "")
    sidecar_map_hash = str(metadata.get("priorMapSha256") or "")
    sidecar_floor_id = str(metadata.get("floorId") or "")
    if not sidecar_session_id or not sidecar_map_hash or not sidecar_floor_id:
        raise OfflineLocalizationError(
            "Localized metadata requires tracking session, prior-map hash and floor identities."
        )
    localized_tag_count = metadata.get("localizedPriceTagCount")
    if (
        isinstance(localized_tag_count, bool)
        or not isinstance(localized_tag_count, int)
        or localized_tag_count < 0
        or metadata.get("localizedPriceTags") != "localized_price_tags.json"
    ):
        raise OfflineLocalizationError(
            "Finalized localized metadata requires an exact tag file and count contract."
        )
    # P7R6C: every formal input is consumed from the parse-and-hash-once
    # snapshot. The tag bytes and the JSONL records below are the exact
    # bytes that produced the manifest identities, so the bundle SHA always
    # describes what localization actually parsed.
    raw_tags = _read_localized_price_tags_bytes(
        input_snapshot.localized_tags_bytes,
        session_id=sidecar_session_id,
        expected_map_id=str(manifest.get("prior_map_id") or ""),
        expected_map_hash=sidecar_map_hash,
        expected_floor_id=sidecar_floor_id,
        expected_count=localized_tag_count,
    )
    trace = input_snapshot.jsonl_values["localization_trace.jsonl"]
    trace_diag = input_snapshot.jsonl_diagnostics["localization_trace.jsonl"]
    raw_constraints = input_snapshot.jsonl_values[
        "localization_constraints.jsonl"
    ]
    constraint_diag = input_snapshot.jsonl_diagnostics[
        "localization_constraints.jsonl"
    ]
    manual_events = input_snapshot.jsonl_values[
        "manual_localization_events.jsonl"
    ]
    manual_diag = input_snapshot.jsonl_diagnostics[
        "manual_localization_events.jsonl"
    ]
    tag_observations = input_snapshot.jsonl_values["tag_observations.jsonl"]
    obs_diag = input_snapshot.jsonl_diagnostics["tag_observations.jsonl"]
    state_events = input_snapshot.jsonl_values["localization_events.jsonl"]
    state_diag = input_snapshot.jsonl_diagnostics["localization_events.jsonl"]
    # P7R6: terminal Recovery lifecycle evidence. Manifest v2 binds the
    # sidecar into the immutable input identity and reconciles the record
    # set against the finalized capture watermark; v1 legacy sessions are
    # read when the file exists but stay explicitly unbound.
    input_manifest_version = session_input_manifest.get("version")
    recovery_watermark = (
        capture_health.get("localizationRecoveryEventCount")
        if isinstance(capture_health, dict)
        else None
    )
    if input_manifest_version == 2:
        if (
            isinstance(recovery_watermark, bool)
            or not isinstance(recovery_watermark, int)
            or recovery_watermark < 0
        ):
            raise OfflineLocalizationError(
                "Input manifest v2 requires the recovery lifecycle watermark."
            )
        recovery_events = input_snapshot.jsonl_values[
            "localization_recovery_events.jsonl"
        ]
        recovery_diag = input_snapshot.jsonl_diagnostics[
            "localization_recovery_events.jsonl"
        ]
        _validate_recovery_event_sequence(recovery_events)
        if len(recovery_events) != recovery_watermark:
            raise OfflineLocalizationError(
                "Recovery lifecycle evidence count does not match the "
                "finalized capture watermark."
            )
        if recovery_watermark > 0:
            expected_last_episode = capture_health.get(
                "localizationLastRecoveryEpisodeId"
            )
            expected_last_finished = _strict_number(
                capture_health.get("localizationLastRecoveryFinishedAtUptime")
            )
            last_event = recovery_events[-1]
            observed_finished = _strict_number(
                last_event.get("finished_at_uptime")
            )
            if (
                last_event.get("episode_id") != expected_last_episode
                or expected_last_finished is None
                or observed_finished is None
                or abs(observed_finished - expected_last_finished) > 1.0e-9
            ):
                raise OfflineLocalizationError(
                    "Recovery lifecycle watermark does not reconcile with "
                    "the last persisted episode."
                )
        recovery_evidence_binding = "recovery_lifecycle_evidence_bound_v2"
    else:
        recovery_events = input_snapshot.jsonl_values[
            "localization_recovery_events.jsonl"
        ]
        recovery_diag = input_snapshot.jsonl_diagnostics[
            "localization_recovery_events.jsonl"
        ]
        _validate_recovery_event_sequence(recovery_events)
        recovery_evidence_binding = RECOVERY_EVIDENCE_UNBOUND_LEGACY
    jsonl_diagnostics = {
        "localization_trace": trace_diag,
        "localization_constraints": constraint_diag,
        "manual_localization_events": manual_diag,
        "tag_observations": obs_diag,
        "localization_events": state_diag,
        "localization_recovery_events": recovery_diag,
    }
    has_critical_jsonl_damage = False
    initial = _pose_from(metadata.get("initialMapPose"))
    if initial is None:
        first_trace = next(
            (
                _pose_from(_field(record, "estimated_pose", "estimatedPose"))
                for record in trace
                if _pose_from(_field(record, "estimated_pose", "estimatedPose")) is not None
            ),
            None,
        )
        initial = first_trace or (0.0, 0.0, 0.0)
    baseline = align_relative_trajectory(optimized_poses, initial)

    constraints: list[AbsoluteConstraint] = []
    constraint_records: list[dict[str, Any]] = []
    for sequence, record in enumerate(raw_constraints, start=1):
        pose = _pose_from(_field(record, "estimated_pose", "estimatedPose"))
        if pose is None:
            candidates = record.get("candidates")
            if isinstance(candidates, list) and candidates:
                pose = _pose_from(candidates[0].get("pose"))
        identifier = str(record.get("constraint_id") or f"online-{sequence:06d}")
        normalized = {
            **record,
            "constraint_id": identifier,
            "source_accepted": record.get("accepted") is True,
        }
        constraint_records.append(normalized)
        if record.get("accepted") is not True or pose is None:
            continue
        try:
            node_index = _nearest_pose_index(
                baseline,
                _node_timebase_timestamp(record),
            )
        except (OfflineLocalizationError, TypeError, ValueError):
            normalized["offline_rejected_reason"] = "constraint_timestamp_invalid"
            continue
        constraints.append(
            AbsoluteConstraint(
                identifier=identifier,
                node_index=node_index,
                x=pose[0],
                y=pose[1],
                yaw=pose[2],
                weight=max(1.0, 6.0 * float(record.get("uniqueness", 0.2))),
                kind="online_structure",
                source=record,
            )
        )
    manual_event_audit: list[dict[str, Any]] = []
    last_alignment_version = 0
    for sequence, record in enumerate(manual_events, start=1):
        identifier = f"manual-{sequence:06d}"
        try:
            if record.get("version") in {2, 3}:
                alignment_version = record.get("alignment_version")
                if (
                    isinstance(alignment_version, bool)
                    or not isinstance(alignment_version, int)
                    or alignment_version <= last_alignment_version
                ):
                    raise OfflineLocalizationError(
                        "manual_event_alignment_version_stale_or_duplicate"
                    )
                # Advance the observed watermark before node binding.  A newer
                # confirmation that later fails evidence checks still proves
                # every following lower version is stale.
                last_alignment_version = alignment_version
            binding = bind_manual_localization_event_to_pose(
                baseline,
                record,
                expected_tracking_session_id=str(
                    metadata.get("trackingSessionId")
                    or metadata.get("tracking_session_id")
                    or ""
                ),
                expected_map_hash=str(expected_hash or ""),
                expected_floor_id=str(
                    metadata.get("floorId") or metadata.get("floor_id") or ""
                ),
            )
        except OfflineLocalizationError as exc:
            manual_event_audit.append(
                {
                    "constraint_id": identifier,
                    "status": "rejected",
                    "reason": str(exc),
                    "source_version": record.get("version"),
                }
            )
            continue
        pose = _pose_from(record.get("confirmed_map_pose"))
        if pose is None:
            manual_event_audit.append(
                {
                    "constraint_id": identifier,
                    "status": "rejected",
                    "reason": "manual_event_confirmed_map_pose_invalid",
                    "source_version": record.get("version"),
                }
            )
            continue
        constraints.append(
            AbsoluteConstraint(
                identifier=identifier,
                node_index=binding.node_index,
                x=pose[0],
                y=pose[1],
                yaw=pose[2],
                weight=80.0,
                kind="manual_anchor",
                source=record,
            )
        )
        manual_event_audit.append(
            {
                "constraint_id": identifier,
                "status": "accepted",
                "bound_node_id": baseline[binding.node_index].node_id,
                "bound_node_stamp": binding.node_timestamp,
                "frame_timestamp": binding.observation_timestamp,
                "time_delta_seconds": binding.time_delta_seconds,
                "binding_source": binding.binding_source,
                "alignment_version": record.get("alignment_version"),
            }
        )
    constraint_records, _, edit_audit = apply_manual_edits(
        constraint_records, [], manual_edits
    )
    disabled_ids = {
        str(item["constraint_id"])
        for item in constraint_records
        if item.get("disabled_by_manual_edit") is True
    }
    constraints = [item for item in constraints if item.identifier not in disabled_ids]
    active_edit_events = list(manual_edits.get("events", []))[
        : max(0, min(int(manual_edits.get("cursor", 0)), len(manual_edits.get("events", []))))
    ]
    for event in active_edit_events:
        if not isinstance(event, dict) or event.get("type") != "set_anchor":
            continue
        value = event.get("new_value")
        pose = _pose_from(value)
        if pose is None or not isinstance(value, dict):
            continue
        timestamp = value.get("timestamp")
        constraints.append(
            AbsoluteConstraint(
                identifier=str(event.get("event_id") or "manual-edit-anchor"),
                node_index=_nearest_pose_index(
                    baseline,
                    float(timestamp) if timestamp is not None else None,
                ),
                x=pose[0],
                y=pose[1],
                yaw=pose[2],
                weight=100.0,
                kind="manual_anchor",
                source=event,
            )
        )
    road_graph = load_json(prior_map / "road_graph.json")
    road_graph_payload = road_graph if isinstance(road_graph, dict) else {}
    for event in active_edit_events:
        if (
            isinstance(event, dict)
            and event.get("type") == "assign_interval_to_aisle"
        ):
            constraints.extend(
                build_manual_aisle_constraints(
                    baseline,
                    road_graph_payload,
                    str(metadata.get("floorId") or metadata.get("floor_id") or ""),
                    event,
                )
            )
    constraints.extend(
        build_road_soft_constraints(
            baseline,
            road_graph_payload,
            str(metadata.get("floorId") or metadata.get("floor_id") or ""),
        )
    )
    factor_graph_report: dict[str, Any] = {
        "format": "MarketScannerRelativeSE2FactorGraphReport",
        "version": 2,
        "solver": "unavailable",
        "full_factor_graph": False,
        "published_capable": False,
        "converged": False,
        "blockers": [{"code": "native_factor_graph_helper_unavailable"}],
        "input_identity_id": input_identity_id,
        "optimized_database_sha256": optimized_db_hash,
    }
    full_factor_graph = False
    if factor_graph_binary is not None:
        try:
            optimized, accepted, rejected, factor_graph_report = (
                run_relative_se2_factor_graph(
                    binary=factor_graph_binary,
                    optimized_database=optimized_database,
                    baseline=baseline,
                    constraints=constraints,
                    input_identity_id=input_identity_id,
                    horizontal_axes=str(replay_parameters["horizontal_axes"]),
                    pose_type=Pose,
                    hard_reject_translation_m=HARD_REJECT_TRANSLATION_M,
                    hard_reject_yaw_rad=HARD_REJECT_YAW_RAD,
                )
            )
            full_factor_graph = factor_graph_report.get("full_factor_graph") is True
        except FactorGraphRunnerError as exc:
            factor_graph_report = {
                **factor_graph_report,
                "solver": "rtabmap_g2o_slam2d",
                "blockers": [
                    {
                        "code": "native_factor_graph_failed",
                        "message": str(exc),
                    }
                ],
            }
            optimized, accepted, rejected = optimize_trajectory(
                baseline, constraints
            )
    else:
        optimized, accepted, rejected = optimize_trajectory(baseline, constraints)
    solver_metrics = bounded_correction_metrics(
        baseline, optimized, constraints
    )
    graph_quality_passed = factor_graph_report.get("graph_quality_passed") is True
    factor_graph_published_capable = (
        full_factor_graph
        and graph_quality_passed
        and factor_graph_report.get("published_capable") is True
    )

    elements_payload = load_json(prior_map / "elements.json")
    elements = elements_payload.get("elements", []) if isinstance(elements_payload, dict) else []
    final_tags: list[dict[str, Any]] = []
    observations_by_id = {
        str(item.get("observation_id")): item for item in tag_observations
    }
    max_node_time_delta_seconds = 1.5
    expected_tracking_session_id = str(
        metadata.get("trackingSessionId") or metadata.get("tracking_session_id") or ""
    )
    expected_floor_id = str(metadata.get("floorId") or metadata.get("floor_id") or "")
    expected_map_hashes = {str(expected_hash)} if expected_hash else set()
    for tag in raw_tags:
        observation = observations_by_id.get(str(tag.get("observation_id")))
        try:
            binding = bind_tag_observation_to_pose(
                baseline,
                observation,
                tag=tag,
                expected_tracking_session_id=expected_tracking_session_id,
                expected_map_hashes=expected_map_hashes,
                expected_floor_id=expected_floor_id,
                maximum_time_delta_seconds=max_node_time_delta_seconds,
            )
        except OfflineLocalizationError as exc:
            reason = str(exc)
            tag.pop("final_map_position", None)
            _mark_tag_for_review(tag, reason)
            tag["transform_audit"] = {
                "status": "not_applied",
                "source_observation_id": str(tag.get("observation_id") or ""),
                "reason": reason,
            }
            tag["association_audit"] = {
                "status": "not_attempted",
                "reason": "tag_pose_binding_failed",
            }
            final_tags.append(enforce_tag_state_invariants(tag))
            continue
        index = binding.node_index
        baseline_node = baseline[index]
        optimized_node = optimized[index]
        raw_observation_position = (
            observation.get("raw_map_position")
            if isinstance(observation, dict)
            else None
        )
        # The observation is the measurement authority.  The duplicate tag
        # position was already checked above and must never override it.
        original = raw_observation_position
        if not isinstance(original, dict):
            tag.pop("final_map_position", None)
            _mark_tag_for_review(tag, "tag_raw_map_position_missing")
            tag["transform_audit"] = {
                "status": "not_applied",
                "source_observation_id": str(tag.get("observation_id") or ""),
                "bound_node_id": baseline_node.node_id,
                "reason": "tag_raw_map_position_missing",
            }
            tag["association_audit"] = {
                "status": "not_attempted",
                "reason": "tag_raw_map_position_missing",
            }
            final_tags.append(enforce_tag_state_invariants(tag))
            continue
        tag["online_map_position"] = dict(original)
        try:
            final_x, final_y = apply_pose_delta_to_point(
                baseline_node,
                optimized_node,
                (float(original.get("x_m")), float(original.get("y_m"))),
            )
        except (OfflineLocalizationError, TypeError, ValueError):
            tag.pop("final_map_position", None)
            _mark_tag_for_review(tag, "tag_raw_map_position_invalid")
            tag["transform_audit"] = {
                "status": "not_applied",
                "source_observation_id": str(tag.get("observation_id") or ""),
                "bound_node_id": baseline_node.node_id,
                "reason": "tag_raw_map_position_invalid",
            }
            tag["association_audit"] = {
                "status": "not_attempted",
                "reason": "tag_raw_map_position_invalid",
            }
            final_tags.append(enforce_tag_state_invariants(tag))
            continue
        tag["final_map_position"] = {
            "x_m": round(final_x, 6),
            "y_m": round(final_y, 6),
            "height_m": original.get("height_m"),
        }
        online_x = float(original.get("x_m"))
        online_y = float(original.get("y_m"))
        tag["online_offline_distance_cm"] = round(
            math.hypot(final_x - online_x, final_y - online_y) * 100, 3
        )
        tag.setdefault("manually_modified", False)
        tag.setdefault("approval_status", "pending" if tag.get("needs_review") else "auto_approved")
        # Audit: record the binding node and SE(2) delta so reviewers can verify
        # the rigid transform that propagated this tag from online to final.
        tag["transform_audit"] = {
            "status": "applied",
            "source_position_field": (
                "tag.raw_map_position"
                if isinstance(tag.get("raw_map_position"), dict)
                else "observation.raw_map_position"
            ),
            "source_observation_id": str(tag.get("observation_id") or ""),
            "bound_node_id": baseline_node.node_id,
            "bound_node_stamp": baseline_node.timestamp,
            "observation_stamp": binding.observation_timestamp,
            "time_delta_seconds": binding.time_delta_seconds,
            "binding_source": binding.binding_source,
            "baseline_pose": {
                "x_m": round(baseline_node.x, 6),
                "y_m": round(baseline_node.y, 6),
                "yaw_rad": round(baseline_node.yaw, 6),
            },
            "optimized_pose": {
                "x_m": round(optimized_node.x, 6),
                "y_m": round(optimized_node.y, 6),
                "yaw_rad": round(optimized_node.yaw, 6),
            },
            "delta_yaw_rad": round(
                _normalize_angle(optimized_node.yaw - baseline_node.yaw), 6
            ),
        }
        final_tags.append(
            _associate_tag(tag, elements, (optimized_node.x, optimized_node.y))
        )
    # Manual tag decisions are deliberately replayed after all automatic
    # reassociation so a reprocess never silently overwrites a human edit.
    _, final_tags, _ = apply_manual_edits(
        [], final_tags, manual_edits, elements=elements
    )
    final_tags = [enforce_tag_state_invariants(tag) for tag in final_tags]

    corrections = [
        math.hypot(after.x - before.x, after.y - before.y)
        for before, after in zip(baseline, optimized)
    ]
    accepted_count = len(accepted)
    accepted_source_count = sum(
        item["kind"] == "online_structure" for item in accepted
    )
    source_accepted_count = sum(item.get("accepted") is True for item in raw_constraints)
    review_items: list[dict[str, Any]] = [
        {
            "id": f"rejected-{index:06d}",
            "type": "rejected_constraint",
            "severity": "warning",
            "message": f"地图约束 {item['constraint_id']} 被稳健门限拒绝。",
            "details": item,
        }
        for index, item in enumerate(rejected, start=1)
    ]
    review_items.extend(
        {
            "id": f"manual-event-{index:06d}",
            "type": "manual_localization_event",
            "severity": "warning",
            "message": "人工定位事件未通过同源时间和节点绑定校验。",
            "details": item,
        }
        for index, item in enumerate(manual_event_audit, start=1)
        if item.get("status") == "rejected"
    )
    review_items.extend(
        {
            "id": f"tag-{tag.get('tag_id', index)}",
            "type": "price_tag",
            "severity": "warning",
            "message": f"价签 {tag.get('payload') or tag.get('tag_id')} 需要人工复核。",
            "object_id": tag.get("tag_id"),
            "details": {
                "review_reasons": tag.get("review_reasons", []),
                "transform_audit": tag.get("transform_audit"),
                "association_audit": tag.get("association_audit"),
            },
        }
        for index, tag in enumerate(final_tags, start=1)
        if tag.get("needs_review") is True
    )
    max_correction = max(corrections, default=0.0)
    # Online constraint acceptance rate: only ÷ online source count,
    # never mix manual events into the denominator.
    acceptance_rate = (
        accepted_source_count / max(1, source_accepted_count)
        if source_accepted_count > 0
        else 0.0
    )
    needs_review_count = sum(tag.get("needs_review") is True for tag in final_tags)
    # Publish gate: three explicit levels — draft, review, published.
    # REVIEW requires explicit user submission; PUBLISHED additionally requires
    # the full solver gate and evidence-bound field acceptance.
    # Any critical JSONL damage or stale node binding prevents even draft.
    # Explicit diagnostic mode is development/test-only product semantics: it
    # keeps an unsafe working draft inspectable without relaxing review or
    # publication gates. Conflicting phone constraints remain in the audit and
    # are excluded by the robust hard gate above.
    diagnostic_mode = bool(replay_parameters["diagnostic_mode"])
    allow_draft = (
        bool(optimized)
        and not has_critical_jsonl_damage
        and (max_correction <= 2.0 or diagnostic_mode)
    )
    state_counts: dict[str, int] = {}
    for event in state_events:
        state = str(event.get("state") or "unknown")
        state_counts[state] = state_counts.get(state, 0) + 1
    final_state_timestamp = next(
        (
            float(pose.timestamp)
            for pose in reversed(optimized)
            if pose.timestamp is not None
        ),
        None,
    )
    state_durations, weak_lost_intervals = _state_durations(
        state_events, final_state_timestamp
    )
    # P7R6: Recovery lifecycle evidence must be used, not only hashed. The
    # summary reports terminal outcomes; provisional recovery steps stay
    # auditable but can never count as accepted constraints (already
    # enforced by the disposition contract). Count and schema violations
    # fail closed earlier; the remaining session-level rules become gate
    # blockers below.
    recovery_outcome_counts: dict[str, int] = {}
    for event in recovery_events:
        outcome_name = str(event.get("outcome") or "")
        recovery_outcome_counts[outcome_name] = (
            recovery_outcome_counts.get(outcome_name, 0) + 1
        )
    last_recovery_outcome = (
        str(recovery_events[-1].get("outcome")) if recovery_events else None
    )
    provisional_completion_step_count = sum(
        record.get("disposition") == "provisional_recovery_step"
        for record in raw_constraints
    )
    recovery_summary = {
        "episode_count": len(recovery_events),
        "converged_count": recovery_outcome_counts.get("converged", 0),
        "timed_out_count": recovery_outcome_counts.get("timed_out", 0),
        "cancelled_count": recovery_outcome_counts.get("cancelled", 0),
        "manual_reset_count": recovery_outcome_counts.get("manual_reset", 0),
        "last_outcome": last_recovery_outcome,
        "provisional_completion_step_count": provisional_completion_step_count,
    }
    recovery_gate_blockers: list[dict[str, Any]] = []
    recovery_state_seen = any(
        str(event.get("state")) == "recovering" for event in state_events
    )
    last_state_event = (
        str(state_events[-1].get("state")) if state_events else None
    )
    if recovery_state_seen and not recovery_events:
        recovery_gate_blockers.append(
            {"code": "recovery_terminal_missing", "value": None}
        )
    if (
        last_state_event == "recovering"
        and last_recovery_outcome != "cancelled"
    ):
        recovery_gate_blockers.append(
            {
                "code": "recovery_active_without_cancelled_terminal",
                "value": last_recovery_outcome,
            }
        )
    review_items.extend(
        {
            "id": f"state-{index:06d}",
            "type": "localization_interval",
            "severity": "warning",
            "message": (
                f"定位状态 {item['state']} 持续 "
                f"{item['duration_seconds']:.1f} 秒，需要轨迹复核。"
            ),
            "details": item,
        }
        for index, item in enumerate(weak_lost_intervals, start=1)
    )
    # Coverage is audited from both immutable SQLite inputs plus the exported
    # trajectory.  Metadata is only a cross-check and never the denominator.
    # P7R6C 方案 A: SQLite only ever opens a descriptor-verified immutable
    # copy of the source database; the original stays read-only. The copy
    # must match the snapshot identity or processing fails closed.
    with tempfile.TemporaryDirectory(
        prefix="marketscanner-localized-source-"
    ) as source_work_root:
        verified_source_database = _verified_source_database_copy(
            source_database, Path(source_work_root), source_hash_before
        )
        source_inventory = _database_node_inventory(verified_source_database)
    optimized_inventory = _database_node_inventory(optimized_database)
    exported_node_ids = [pose.node_id for pose in optimized]
    exported_node_counts = Counter(exported_node_ids)
    exported_node_set = set(exported_node_ids)
    source_node_ids = source_inventory["id_set"]
    optimized_node_ids = optimized_inventory["id_set"]
    common_node_ids = source_node_ids & optimized_node_ids & exported_node_set
    source_node_count = len(source_node_ids)
    node_coverage = len(common_node_ids) / source_node_count
    node_inventory_audit = {
        "source_count": source_node_count,
        "optimized_count": len(optimized_node_ids),
        "exported_count": len(exported_node_ids),
        "source_missing_from_optimized": sorted(source_node_ids - optimized_node_ids),
        "source_missing_from_export": sorted(source_node_ids - exported_node_set),
        "optimized_not_in_source": sorted(optimized_node_ids - source_node_ids),
        "exported_not_in_optimized": sorted(exported_node_set - optimized_node_ids),
        "source_duplicate_ids": source_inventory["duplicate_ids"],
        "optimized_duplicate_ids": optimized_inventory["duplicate_ids"],
        "exported_duplicate_ids": sorted(
            node_id for node_id, count in exported_node_counts.items() if count > 1
        ),
        "source_non_monotonic_stamp_node_ids": source_inventory[
            "non_monotonic_stamp_node_ids"
        ],
        "optimized_non_monotonic_stamp_node_ids": optimized_inventory[
            "non_monotonic_stamp_node_ids"
        ],
        "source_first_stamp": source_inventory["first_stamp"],
        "source_last_stamp": source_inventory["last_stamp"],
        "optimized_first_stamp": optimized_inventory["first_stamp"],
        "optimized_last_stamp": optimized_inventory["last_stamp"],
    }
    report = {
        "format": "MarketScannerLocalizationReport",
        "version": FORMAT_VERSION,
        "prior_map_id": manifest.get("prior_map_id"),
        "prior_map_sha256": package_hash,
        "session_input_bundle_sha256": expected_bundle_sha256,
        "session_input_manifest_version": input_manifest_version,
        "recovery_evidence_binding": recovery_evidence_binding,
        "input_identity_id": input_identity_id,
        "source_database_sha256": source_hash_before,
        "optimized_database_sha256": optimized_db_hash,
        "node_count": len(optimized),
        "node_coverage_ratio": round(node_coverage, 6),
        "source_node_count": source_node_count,
        "node_inventory_audit": node_inventory_audit,
        "online_trajectory_length_m": _trajectory_length(
            [
                Pose(index, None, pose[0], pose[1], pose[2])
                for index, record in enumerate(trace)
                if (pose := _pose_from(_field(record, "estimated_pose", "estimatedPose"))) is not None
            ]
        ),
        "rtabmap_trajectory_length_m": _trajectory_length(baseline),
        "offline_trajectory_length_m": _trajectory_length(optimized),
        "correction_distribution_m": {
            "median": sorted(corrections)[len(corrections) // 2] if corrections else 0,
            "p95": sorted(corrections)[min(len(corrections) - 1, int(len(corrections) * 0.95))]
            if corrections else 0,
            "maximum": max_correction,
        },
        "maximum_correction_m": max_correction,
        "weak_lost_state_counts": {
            key: state_counts.get(key, 0) for key in ("weak", "lost")
        },
        "localization_state_duration_seconds": {
            key: round(value, 6) for key, value in sorted(state_durations.items())
        },
        "weak_lost_duration_seconds": round(
            state_durations.get("weak", 0.0)
            + state_durations.get("lost", 0.0),
            6,
        ),
        "weak_lost_intervals": weak_lost_intervals,
        "recovery_summary": recovery_summary,
        "recovery_gate": {
            "passed": not recovery_gate_blockers,
            "blockers": recovery_gate_blockers,
        },
        "map_constraint_acceptance_rate": round(acceptance_rate, 6),
        "accepted_constraint_count": accepted_count,
        "accepted_source_constraint_count": accepted_source_count,
        "accepted_manual_anchor_count": sum(
            item["kind"] == "manual_anchor" for item in accepted
        ),
        "road_soft_constraint_count": sum(
            item["kind"] == "road_soft" for item in accepted
        ),
        "manual_aisle_constraint_count": sum(
            item.kind == "manual_aisle_assignment" for item in constraints
        ),
        "rejected_constraint_count": len(rejected),
        "high_residual_intervals": rejected,
        "jsonl_diagnostics": jsonl_diagnostics,
        "aisle_switch_sequence": infer_aisle_switch_sequence(
            optimized,
            road_graph_payload,
            str(metadata.get("floorId") or metadata.get("floor_id") or ""),
            weak_lost_intervals=weak_lost_intervals,
            manual_events=active_edit_events,
        ),
        "manual_anchor_count": sum(item.kind == "manual_anchor" for item in constraints),
        "manual_localization_event_audit": manual_event_audit,
        "tag_total": len(final_tags),
        "tag_confirmed": sum(tag.get("approval_status") in {"approved", "auto_approved"} for tag in final_tags),
        "tag_needs_review": needs_review_count,
        "mean_association_confidence": (
            sum(float(tag.get("association_confidence", 0)) for tag in final_tags)
            / max(1, len(final_tags))
        ),
        "publish_state": "draft" if allow_draft else "invalid",
        "allow_draft": allow_draft,
        "diagnostic_mode": diagnostic_mode,
        "diagnostic_only": diagnostic_mode,
        "ignored_conflicting_source_constraint_count": sum(
            item.get("kind") == "online_structure" for item in rejected
        ),
        "warnings": [],
        "rejection_reasons": sorted({item["reason"] for item in rejected}),
        "solver": {
            "type": (
                "relative_se2_factor_graph"
                if full_factor_graph
                else "bounded_correction_field"
            ),
            "full_factor_graph": full_factor_graph,
            "graph_integrity_passed": factor_graph_report.get("graph_integrity_passed") is True,
            "graph_quality_passed": graph_quality_passed,
            "quality_policy": factor_graph_report.get("quality_policy"),
            "published_capable": factor_graph_published_capable,
            "limitation": (
                None
                if full_factor_graph
                else "The native relative SE(2) graph was unavailable or failed; bounded correction is draft/review only."
            ),
            "native_solver": factor_graph_report.get("solver"),
            "factor_set_sha256": factor_graph_report.get("factor_set_sha256"),
            "huber_translation_m": HUBER_TRANSLATION_M,
            "huber_yaw_deg": math.degrees(HUBER_YAW_RAD),
            "relative_trajectory_authority": "rtabmap_reprocess_optimized_copy",
            **solver_metrics,
        },
    }
    correction_p95 = report["correction_distribution_m"]["p95"]
    tag_observation_coverage = (
        sum(
            isinstance(tag.get("transform_audit"), dict)
            and tag["transform_audit"].get("status") == "applied"
            for tag in final_tags
        )
        / max(1, len(final_tags))
        if final_tags
        else 1.0
    )
    review_blockers: list[dict[str, Any]] = []
    review_checks = (
        (node_coverage >= 0.98, "node_coverage_below_0_98", node_coverage),
        (
            not any(
                node_inventory_audit[key]
                for key in (
                    "source_missing_from_optimized",
                    "source_missing_from_export",
                    "optimized_not_in_source",
                    "exported_not_in_optimized",
                    "source_duplicate_ids",
                    "optimized_duplicate_ids",
                    "exported_duplicate_ids",
                    "source_non_monotonic_stamp_node_ids",
                    "optimized_non_monotonic_stamp_node_ids",
                )
            ),
            "node_inventory_integrity_failed",
            node_inventory_audit,
        ),
        (max_correction <= 2.0, "maximum_correction_above_2m", max_correction),
        (correction_p95 <= 1.0, "p95_correction_above_1m", correction_p95),
        (
            solver_metrics["maximum_local_relative_translation_change_m"] <= 0.5,
            "local_deformation_above_0_5m",
            solver_metrics["maximum_local_relative_translation_change_m"],
        ),
        (
            solver_metrics["maximum_local_relative_yaw_change_deg"] <= 15.0,
            "local_yaw_deformation_above_15deg",
            solver_metrics["maximum_local_relative_yaw_change_deg"],
        ),
        (
            report["weak_lost_duration_seconds"] <= 30.0,
            "weak_lost_duration_above_30s",
            report["weak_lost_duration_seconds"],
        ),
        (
            tag_observation_coverage == 1.0,
            "tag_observation_coverage_incomplete",
            tag_observation_coverage,
        ),
        (needs_review_count == 0, "pending_tag_review", needs_review_count),
        (len(rejected) == 0, "rejected_constraints_present", len(rejected)),
        (
            sum(item.get("status") == "rejected" for item in manual_event_audit) == 0,
            "rejected_manual_localization_events_present",
            sum(item.get("status") == "rejected" for item in manual_event_audit),
        ),
    )
    for passed, code, value in review_checks:
        if not passed:
            review_blockers.append({"code": code, "value": value})
    # Recovery lifecycle gates bind both review and publication: a session
    # that stopped inside an uncancelled Recovery episode must never be
    # declared trustworthy by convergence counters alone.
    review_blockers.extend(recovery_gate_blockers)
    report["tag_observation_coverage_ratio"] = round(
        tag_observation_coverage, 6
    )
    report["review_gate"] = {
        "passed": not review_blockers,
        "blockers": review_blockers,
    }
    publish_blockers = list(review_blockers)
    if diagnostic_mode:
        publish_blockers.insert(
            0,
            {
                "code": "diagnostic_mode_enabled",
                "value": True,
            },
        )
    if not full_factor_graph:
        publish_blockers.insert(
            0,
            {
                "code": "solver_not_full_relative_se2_factor_graph",
                "value": report["solver"]["type"],
            },
        )
    elif not graph_quality_passed:
        quality = factor_graph_report.get("quality_policy")
        quality_blockers = quality.get("blockers") if isinstance(quality, dict) else None
        publish_blockers.insert(
            0,
            {
                "code": "factor_graph_quality_not_passed",
                "value": quality_blockers if isinstance(quality_blockers, list) else [],
            },
        )
    report["publish_gate"] = {
        "passed": factor_graph_published_capable and not publish_blockers,
        "blockers": publish_blockers,
    }
    if has_critical_jsonl_damage:
        report["warnings"].append(
            "检测到 sidecar 文件损坏，结果可能不完整。不得自动发布。"
        )
    if diagnostic_mode:
        ignored_count = report["ignored_conflicting_source_constraint_count"]
        report["warnings"].append(
            "测试诊断模式已启用：冲突手机定位约束不会阻止生成可视化草稿，"
            f"本次忽略 {ignored_count} 条；全部门禁和误差指标仍保留，且结果禁止发布。"
        )
    if not allow_draft:
        report["warnings"].append(
            "处理未能生成有效草稿；检查输入文件和优化器状态。"
        )
    source_hash_after = _regular_file_identity(source_database, "source_database")[
        "sha256"
    ]
    if source_hash_after != source_hash_before:
        raise OfflineLocalizationError("Source database changed during localized processing.")
    session_inputs_after = build_session_input_manifest(segment, source_database)
    if (
        session_inputs_after["bundle_sha256"] != expected_bundle_sha256
        or session_inputs_after["files"] != session_input_manifest["files"]
    ):
        raise OfflineLocalizationError(
            "Finalized session inputs changed during localized processing."
        )

    output.mkdir(parents=True, exist_ok=True)
    shutil.copy2(prior_map / "manifest.json", output / "prior_map_manifest.json")
    _json_write(output / "session_input_manifest.json", session_input_manifest)
    _json_write(
        output / "source_manifest.json",
        {
            "format": "MarketScannerLocalizedSourceManifest",
            "version": 2,
            "input_identity_id": input_identity_id,
            "session_input_bundle_sha256": expected_bundle_sha256,
            "source_session_id": session.name,
            "source_database_name": source_database.name,
            "source_database_sha256_before": source_hash_before,
            "source_database_sha256_after": source_hash_after,
            "source_database_immutable": True,
            "optimized_database_name": optimized_database.name,
            "optimized_database_sha256": optimized_db_hash,
            "prior_map_id": manifest.get("prior_map_id"),
            "prior_map_sha256": package_hash,
        },
    )
    _json_write(
        output / "processing_manifest.json",
        {
            "format": "MarketScannerLocalizedProcessing",
            "version": 2,
            "input_identity_id": input_identity_id,
            "session_input_bundle_sha256": expected_bundle_sha256,
            "session_input_manifest_version": input_manifest_version,
            "recovery_evidence_binding": recovery_evidence_binding,
            "pipeline": [
                "rtabmap_reprocess",
                "relative_trajectory_read",
                (
                    "relative_se2_factor_graph"
                    if full_factor_graph
                    else "bounded_draft_fallback"
                ),
                "tag_reassociation",
                "quality_gate",
                "human_review",
                "export",
            ],
            "source_database_modified": False,
            "publish_state": report["publish_state"],
            "allow_draft": report["allow_draft"],
            "diagnostic_mode": report["diagnostic_mode"],
            "source_database_sha256": source_hash_before,
            "optimized_database_sha256": optimized_db_hash,
            "prior_map_sha256": package_hash,
            "factor_graph_quality_policy_sha256": (
                factor_graph_report.get("quality_policy") or {}
            ).get("policy_sha256"),
            "factor_graph_quality_policy_version": (
                factor_graph_report.get("quality_policy") or {}
            ).get("policy_version"),
            "tool_version": TOOL_VERSION,
            "algorithm_version": (
                "relative_se2_factor_graph_v2"
                if full_factor_graph
                else "bounded_correction_field_v1"
            ),
            "coordinate_contract_version": COORDINATE_CONTRACT_VERSION,
            "processing_parameter_sha256": processing_parameter_sha256(
                replay_parameters
            ),
            "replay_parameters": replay_parameters,
            "parameters": {
                "huber_translation_m": HUBER_TRANSLATION_M,
                "huber_yaw_rad": HUBER_YAW_RAD,
                "hard_reject_translation_m": HARD_REJECT_TRANSLATION_M,
                "hard_reject_yaw_rad": HARD_REJECT_YAW_RAD,
            },
        },
    )
    _json_write(output / "online_localization_trace.json", trace)
    trajectory_payload = _trajectory_geojson(baseline, optimized, trace)
    _json_write(output / "optimized_map_trajectory.geojson", trajectory_payload)
    _json_write(
        output / "localization_constraints.json",
        {
            "format": "MarketScannerOfflineLocalizationConstraints",
            "version": 1,
            "raw": constraint_records,
            "accepted": accepted,
            "rejected": rejected,
        },
    )
    _json_write(output / "localization_report.json", report)
    _json_write(output / "factor_graph_report.json", factor_graph_report)
    _json_write(
        output / "review_items.json",
        {
            "format": "MarketScannerLocalizationReviewItems",
            "version": 1,
            "items": review_items,
        },
    )
    _json_write(
        output / "localized_review.json",
        {
            "format": "MarketScannerLocalizedReview",
            "version": 1,
            "bounds": manifest.get("bounds"),
            "elements": [
                {
                    key: element.get(key)
                    for key in ("id", "code", "shape_type", "floor_id", "geometry")
                }
                for element in elements[:50_000]
                if element.get("geometry") is not None
            ],
            "trajectory": _bounded_review_trajectory(trajectory_payload),
            "tags": final_tags[:50_000],
            "review_items": review_items[:5_000],
            "view_limits": {
                "maximum_elements": 50_000,
                "maximum_trajectory_points_per_layer": 20_000,
                "maximum_tags": 50_000,
                "maximum_review_items": 5_000,
                "elements_truncated": len(elements) > 50_000,
                "tags_truncated": len(final_tags) > 50_000,
                "review_items_truncated": len(review_items) > 5_000,
            },
        },
    )
    _json_write(output / "manual_edits.json", manual_edits)
    _json_write(output / "localized_price_tags.json", final_tags)
    with (output / "localized_price_tags.csv").open(
        "w", encoding="utf-8", newline=""
    ) as handle:
        fieldnames = [
            "tag_id", "payload", "map_x_cm", "map_y_cm", "height_cm",
            "shelf_code", "row_flag", "cross_code", "shelf_side",
            "distance_from_shelf_start_cm", "online_offline_distance_cm",
            "localization_confidence", "measurement_confidence",
            "association_confidence", "manually_modified", "needs_review",
            "approval_status", "observation_id",
        ]
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        for tag in final_tags:
            position = tag.get("final_map_position") or {}
            writer.writerow(
                {
                    **{key: tag.get(key) for key in fieldnames},
                    "map_x_cm": float(position.get("x_m", 0)) * 100,
                    "map_y_cm": float(position.get("y_m", 0)) * 100,
                    "height_cm": (
                        float(position["height_m"]) * 100
                        if position.get("height_m") is not None else None
                    ),
                }
            )
    _json_write(
        output / "localized_price_tags.geojson",
        {
            "type": "FeatureCollection",
            "features": [
                {
                    "type": "Feature",
                    "properties": {
                        key: value
                        for key, value in tag.items()
                        if key not in {"final_map_position", "raw_map_position", "snapped_map_position"}
                    },
                    "geometry": {
                        "type": "Point",
                        "coordinates": [
                            float(tag["final_map_position"]["x_m"]),
                            float(tag["final_map_position"]["y_m"]),
                        ],
                    },
                }
                for tag in final_tags
                if isinstance(tag.get("final_map_position"), dict)
            ],
        },
    )
    shelf_index: dict[str, list[str]] = {}
    for tag in final_tags:
        shelf = str(tag.get("shelf_code") or "")
        if shelf:
            shelf_index.setdefault(shelf, []).append(str(tag.get("tag_id")))
    _json_write(
        output / "shelf_tag_index.json",
        {
            "format": "MarketScannerShelfTagIndex",
            "version": 1,
            "shelves": {key: sorted(value) for key, value in sorted(shelf_index.items())},
        },
    )
    _json_write(
        output / "audit_log.jsonl",
        [
            {
                "sequence": 1,
                "event": "source_database_verified_immutable",
                "sha256": source_hash_before,
            },
            {
                "sequence": 2,
                "event": "offline_prior_map_optimization_completed",
                "accepted_constraints": accepted_count,
                "rejected_constraints": len(rejected),
            },
            *[
                {"sequence": index + 3, "event": "manual_edit_applied", **item}
                for index, item in enumerate(edit_audit)
            ],
            *[
                {
                    "sequence": index + 3 + len(edit_audit),
                    "event": "manual_operation_audited",
                    **item,
                }
                for index, item in enumerate(
                    manual_edits.get("audit_events", []), start=1
                )
            ],
        ],
        lines=True,
    )
    if progress:
        progress(
            97,
            "质量门禁与导出",
            "离线轨迹、价签结果、复核项和审计记录已生成",
        )
    return report


def process_localized_session(
    prior_map: Path,
    session: Path,
    optimized_poses: Sequence[Pose],
    source_database: Path,
    optimized_database: Path,
    output: Path,
    manual_edits: dict[str, Any] | None = None,
    progress: Callable[[int, str, str], None] | None = None,
    expected_parent_version: str | None = None,
    replay_parameters: dict[str, Any] | None = None,
    factor_graph_binary: Path | None = None,
) -> dict[str, Any]:
    """Render and atomically commit an immutable localized result version.

    The rendering function only receives a private staging directory. Readers
    continue resolving the previous ``current.json`` pointer until every
    required artifact has been validated, fsynced and renamed into ``versions``.
    An invalid diagnostic version is retained for audit but never becomes the
    current result.
    """

    normalized_replay_parameters = normalize_replay_parameters(replay_parameters)
    validation = validate_package(prior_map)
    if not validation["valid"]:
        raise OfflineLocalizationError(
            "Prior-map validation failed: "
            + "; ".join(item["message"] for item in validation["errors"])
        )
    segment_dirs = sorted(path for path in session.glob("segment_*") if path.is_dir())
    if len(segment_dirs) != 1:
        raise OfflineLocalizationError("Localized processing requires one continuous segment.")
    package_manifest = load_json(prior_map / "package_manifest.json")
    if not isinstance(package_manifest, dict) or not isinstance(
        package_manifest.get("package_sha256"), str
    ):
        raise OfflineLocalizationError("Prior-map package manifest is invalid.")
    # P7R6C: parse-and-hash-once snapshot. The manifest builder call stays
    # so external callers and the render re-verification keep one code path,
    # but the snapshot is the authoritative view: every byte below is read
    # exactly once through a stable descriptor and the manifest identities
    # describe those very bytes. Any drift between the two reads fails
    # closed before any processing work starts.
    session_input_manifest = build_session_input_manifest(
        segment_dirs[0], source_database
    )
    input_snapshot = read_finalized_session_input_snapshot(
        segment_dirs[0], source_database
    )
    if (
        input_snapshot.manifest.get("bundle_sha256")
        != session_input_manifest.get("bundle_sha256")
        or input_snapshot.manifest.get("files")
        != session_input_manifest.get("files")
    ):
        raise OfflineLocalizationError(
            "Finalized session inputs changed before localized processing."
        )
    session_input_manifest = input_snapshot.manifest
    local_input_record = build_local_input_record(
        session=session,
        source_database=source_database,
        optimized_database=optimized_database,
        prior_map=prior_map,
        session_input_manifest=session_input_manifest,
        prior_map_sha256=package_manifest["package_sha256"],
        replay_parameters=normalized_replay_parameters,
    )
    input_identity_id = local_input_record["input_identity_id"]
    session_input_manifest = {
        **session_input_manifest,
        "input_identity_id": input_identity_id,
    }

    store = LocalizedVersionStore(output)
    staging = store.begin()
    try:
        previous = store.current()
        if expected_parent_version is not None and (
            previous is None or previous.version_id != expected_parent_version
        ):
            actual = previous.version_id if previous else "missing"
            raise OfflineLocalizationError(
                "Localized current version changed during replay: "
                f"expected {expected_parent_version}, found {actual}."
            )
        if previous is not None:
            if previous.input_identity_id is None:
                raise OfflineLocalizationError(
                    "Legacy localized output requires explicit migration or a new output directory."
                )
            if previous.input_identity_id != input_identity_id:
                raise OfflineLocalizationError(
                    "Localized output is already bound to a different session input identity."
                )
            # Fail closed if the version-bound private path record has been
            # removed or altered before any replay work starts.
            store.local_inputs_for(previous)
        report = _render_localized_version(
            prior_map=prior_map,
            session=session,
            optimized_poses=optimized_poses,
            source_database=source_database,
            optimized_database=optimized_database,
            output=staging,
            session_input_manifest=session_input_manifest,
            input_identity_id=input_identity_id,
            local_input_record=local_input_record,
            replay_parameters=normalized_replay_parameters,
            input_snapshot=input_snapshot,
            factor_graph_binary=factor_graph_binary,
            manual_edits=manual_edits,
            progress=progress,
        )
        manifest = store.validate_staging(
            staging,
            parent_version=previous.version_id if previous else None,
        )
        update_current = bool(report.get("allow_draft")) and (
            report.get("publish_state") == "draft"
        )
        snapshot = store.commit(
            staging,
            manifest,
            update_current=update_current,
            local_input_record=local_input_record,
        )
    except Exception:
        if staging.exists():
            store.abort(staging)
        raise
    return {
        **report,
        "version_id": snapshot.version_id,
        "revision": snapshot.revision,
        "current_updated": update_current,
    }
