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
from datetime import datetime, timedelta, timezone
import hashlib
import json
import math
import os
import re
import shutil
import sqlite3
import stat
import struct
import tempfile
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError
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
from .localized_output_store import (
    RECOVERY_EVIDENCE_BOUND_V2,
    RECOVERY_EVIDENCE_UNBOUND_LEGACY,
    LocalizedStoreError,
    LocalizedVersionStore,
    validate_session_input_manifest_contract,
)
from .prior_map_schema import load_json, validate_package
from .factor_graph_runner import FactorGraphRunnerError, run_relative_se2_factor_graph
from .generated_mobile_evidence_contracts import MOBILE_EVIDENCE_CONTRACTS
from .corridor_route_matcher import (
    RouteAnchor,
    match_corridor_route,
    obstacle_polygons,
)


FORMAT_VERSION = 1
TOOL_VERSION = "MarketScanner-RepairV3"
COORDINATE_CONTRACT_VERSION = 1
HUBER_TRANSLATION_M = 0.45
HUBER_YAW_RAD = math.radians(10)
HARD_REJECT_TRANSLATION_M = 2.5
HARD_REJECT_YAW_RAD = math.radians(45)
# A node-bound operator confirmation is an absolute map-frame observation,
# not a claim that the phone physically moved from its current drifted pose.
# The operator can be a few metres imprecise, while accumulated VIO drift over
# a long route can be much larger. Give this evidence explicit uncertainty and
# judge the gradient of the resulting correction field instead of rejecting an
# absolute residual against a fixed distance.
MANUAL_ANCHOR_TRANSLATION_SIGMA_M = 3.0
MANUAL_ANCHOR_YAW_SIGMA_RAD = math.radians(20.0)
MANUAL_ANCHOR_WEIGHT = 1.0 / (
    MANUAL_ANCHOR_TRANSLATION_SIGMA_M * MANUAL_ANCHOR_TRANSLATION_SIGMA_M
)
INITIAL_MAP_POSE_TRANSLATION_SIGMA_M = 1.0
INITIAL_MAP_POSE_YAW_SIGMA_RAD = math.radians(15.0)
UNVERIFIED_MANUAL_ANCHOR_MAX_TRANSLATION_M = 5.0
UNVERIFIED_MANUAL_ANCHOR_MAX_YAW_RAD = math.radians(30.0)
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
# ESL confirmation v2 binds the strict complete-burst sidecar into the same
# immutable parse-and-hash-once snapshot as the localized tag document.
SESSION_INPUT_FILE_NAMES_V3 = (
    "metadata.json",
    "localization_trace.jsonl",
    "localization_constraints.jsonl",
    "localization_events.jsonl",
    "localization_recovery_events.jsonl",
    "manual_localization_events.jsonl",
    "tag_observations.jsonl",
    "tag_observation_bursts.jsonl",
    "localized_price_tags.json",
)
# Clock-bound finalized sessions use one superset contract.  The burst file is
# still present (and may be an empty, watermark-bound file) so v4 has one exact
# role/file inventory for sessions with and without captured ESLs.  This makes
# the local-time tables part of the same immutable input identity as the map,
# database and localization evidence; processing-machine timezone is never an
# implicit input.
SESSION_INPUT_FILE_NAMES_V4 = (
    "metadata.json",
    "clock_correlations.jsonl",
    "localization_trace.jsonl",
    "localization_constraints.jsonl",
    "localization_events.jsonl",
    "localization_recovery_events.jsonl",
    "manual_localization_events.jsonl",
    "tag_observations.jsonl",
    "tag_observation_bursts.jsonl",
    "localized_price_tags.json",
)
# Historical alias: v1 stays the legacy contract and never carries Recovery
# evidence binding.
SESSION_INPUT_FILE_NAMES = SESSION_INPUT_FILE_NAMES_V1
# P7R6B: the PC reader shares the frozen Recovery evidence limits with the
# device parser, the finalization bundle validator and the session
# stable-read snapshot. One file never carries two different size policies.
RECOVERY_MAXIMUM_FILE_BYTES = 16 * 1024 * 1024
RECOVERY_MAXIMUM_RECORD_BYTES = 1_000_000
RECOVERY_MAXIMUM_RECORDS = 100_000
RECOVERY_MAXIMUM_NESTING_DEPTH = 32
CLOCK_LIMITS = MOBILE_EVIDENCE_CONTRACTS["clock_correlations.jsonl"]
CLOCK_DISCONTINUITY_TOLERANCE_SECONDS = 2.0
CLOCK_BINDING_CROSS_CHECK_TOLERANCE_SECONDS = 2.0
CLOCK_BINDING_FRAME_NODE_STAMP_TOLERANCE_SECONDS = 2.0
CLOCK_MAXIMUM_OUTER_EXTRAPOLATION_SECONDS = 3.0
POSITION_INTERPOLATION_MAXIMUM_GAP_SECONDS = 3.0
TAG_EVIDENCE_NUMERIC_TOLERANCE = 1.0e-6
TAG_EVIDENCE_MAXIMUM_NODE_TIME_DELTA_SECONDS = 1.0
EDITABLE_TAG_FIELDS = frozenset(
    {
        "shelf_code",
        "shelf_side",
        "distance_from_shelf_start_cm",
        "height_cm",
        "final_map_position",
    }
)

LOCALIZED_TAG_V1_FIELDS = frozenset(
    {
        "format", "version", "tag_id", "observation_id", "payload", "symbology",
        "floor_id", "timestamp", "tracking_session_id", "prior_map_id",
        "prior_map_sha256", "shelf_code", "row_flag", "cross_code", "shelf_side",
        "distance_from_shelf_start_cm", "height_cm", "raw_map_position",
        "snapped_map_position", "localization_confidence", "measurement_confidence",
        "association_confidence", "measurement_method", "needs_review",
        "user_confirmed",
    }
)
LOCALIZED_TAG_V2_CONFIRMATION_FIELDS = frozenset(
    {
        "shelf_segment_id", "capture_id", "frame_observation_ids",
        "algorithm_shelf_segment_id", "algorithm_shelf_code", "algorithm_side",
        "algorithm_distance_from_shelf_start_cm",
        "algorithm_association_confidence", "confirmation_status",
        "user_confirmed_shelf_segment_id", "user_confirmed_shelf_code",
        "user_confirmed_side", "user_confirmed_distance_from_shelf_start_cm",
        "confirmed_at_utc", "confirmed_at_monotonic", "confirmation_source",
    }
)
LOCALIZED_TAG_V2_FIELDS = (
    LOCALIZED_TAG_V1_FIELDS | LOCALIZED_TAG_V2_CONFIRMATION_FIELDS
)
_CANONICAL_LOWERCASE_UUID = re.compile(
    r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"
)
_LOWERCASE_SHA256 = re.compile(r"^[0-9a-f]{64}$")


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
    "relative_trajectory_authority": "rtabmap_reprocess_optimized_copy",
    "rtabmap_global_graph_incomplete": False,
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
    authority = values.get("relative_trajectory_authority")
    if authority not in {
        "rtabmap_reprocess_optimized_copy",
        "raw_continuous_vio_manual_anchor_recovery",
        "raw_continuous_vio_diagnostic_recovery",
        "partial_rtabmap_graph_continuous_vio_recovery",
    }:
        raise OfflineLocalizationError(
            "Replay parameter relative_trajectory_authority is invalid."
        )
    graph_incomplete = values.get("rtabmap_global_graph_incomplete")
    if not isinstance(graph_incomplete, bool):
        raise OfflineLocalizationError(
            "Replay parameter rtabmap_global_graph_incomplete is invalid."
        )
    raw_vio_recovery = authority in {
        "raw_continuous_vio_manual_anchor_recovery",
        "raw_continuous_vio_diagnostic_recovery",
        "partial_rtabmap_graph_continuous_vio_recovery",
    }
    if raw_vio_recovery != graph_incomplete:
        raise OfflineLocalizationError(
            "Raw VIO recovery requires an explicitly incomplete RTAB-Map graph."
        )
    normalized["relative_trajectory_authority"] = authority
    normalized["rtabmap_global_graph_incomplete"] = graph_incomplete
    return normalized


def _resolve_session_prior_map_identity(
    metadata: dict[str, Any],
    manifest: dict[str, Any],
    package_manifest: dict[str, Any],
) -> dict[str, Any]:
    """Bind a phone session to the selected validated prior-map package.

    ``priorMapSha256`` historically meant the package digest produced by the
    compiler that ran on the device. Swift and Python intentionally share the
    canonical source model, but their rendered package artifacts are not
    byte-identical. Consequently an iPhone package digest cannot equal the PC
    package digest even when both packages came from the same workbook.

    New sessions carry the complete format-independent canonical source SHA.
    Historical sessions are accepted only through a narrow compatibility
    binding: exact map/store/floor identity plus the canonical SHA prefix that
    is embedded in the frozen prior-map ID. The legacy mode is returned to the
    caller so reports never present the weaker compatibility proof as an exact
    package-hash match.
    """

    session_map_id = metadata.get("priorMapId")
    selected_map_id = manifest.get("prior_map_id")
    if not isinstance(session_map_id, str) or session_map_id != selected_map_id:
        raise OfflineLocalizationError(
            "Session prior_map_id does not match the selected map."
        )

    session_hash = metadata.get("priorMapSha256")
    if not isinstance(session_hash, str) or _LOWERCASE_SHA256.fullmatch(
        session_hash
    ) is None:
        raise OfflineLocalizationError("Session prior-map hash is invalid.")

    source_hash = manifest.get("source_sha256")
    package_hash = package_manifest.get("package_sha256")
    canonical_hash = manifest.get("canonical_source_sha256")
    if not isinstance(source_hash, str) or _LOWERCASE_SHA256.fullmatch(
        source_hash
    ) is None:
        raise OfflineLocalizationError("Selected map source hash is invalid.")
    if not isinstance(package_hash, str) or _LOWERCASE_SHA256.fullmatch(
        package_hash
    ) is None:
        raise OfflineLocalizationError("Selected map package hash is invalid.")

    session_store_id = metadata.get("storeId")
    selected_store_id = manifest.get("store_id")
    session_floor_id = metadata.get("floorId")
    floor_ids = {
        str(item.get("id"))
        for item in manifest.get("floors", [])
        if isinstance(item, dict) and isinstance(item.get("id"), str)
    }
    business_identity_matches = (
        isinstance(session_store_id, str)
        and bool(session_store_id)
        and session_store_id == selected_store_id
        and isinstance(session_floor_id, str)
        and bool(session_floor_id)
        and session_floor_id in floor_ids
    )
    canonical_field_present = (
        "priorMapCanonicalSourceSha256" in metadata
        or "prior_map_canonical_source_sha256" in metadata
    )
    session_canonical_hash = metadata.get(
        "priorMapCanonicalSourceSha256",
        metadata.get("prior_map_canonical_source_sha256"),
    )
    if canonical_field_present:
        if (
            not isinstance(session_canonical_hash, str)
            or _LOWERCASE_SHA256.fullmatch(session_canonical_hash) is None
            or not isinstance(canonical_hash, str)
            or session_canonical_hash != canonical_hash
        ):
            raise OfflineLocalizationError(
                "Session canonical prior-map source hash does not match "
                "the selected map."
            )
        if not business_identity_matches:
            raise OfflineLocalizationError(
                "Session store/floor identity does not match the selected map."
            )

    if session_hash == source_hash:
        mode = "source_sha256"
        legacy = False
    elif session_hash == package_hash:
        mode = "package_sha256"
        legacy = False
    elif canonical_field_present:
        mode = "canonical_source_sha256"
        legacy = False
    else:
        if (
            not isinstance(canonical_hash, str)
            or _LOWERCASE_SHA256.fullmatch(canonical_hash) is None
        ):
            raise OfflineLocalizationError(
                "Selected map canonical source hash is invalid."
            )
        map_hash_suffix = session_map_id.rsplit("-", 1)[-1]
        if (
            len(map_hash_suffix) != 12
            or re.fullmatch(r"[0-9a-f]{12}", map_hash_suffix) is None
            or map_hash_suffix != canonical_hash[:12]
        ):
            raise OfflineLocalizationError(
                "Legacy session prior-map ID is not bound to the selected "
                "canonical source."
            )
        if not business_identity_matches:
            raise OfflineLocalizationError(
                "Legacy session store/floor identity does not match the "
                "selected map."
            )
        mode = "legacy_cross_compiler_map_identity"
        legacy = True

    return {
        "mode": mode,
        "legacy_compatibility": legacy,
        "session_prior_map_sha256": session_hash,
        "selected_source_sha256": source_hash,
        "selected_package_sha256": package_hash,
        "canonical_source_sha256": canonical_hash,
        "prior_map_id": session_map_id,
        "store_id": session_store_id,
        "floor_id": session_floor_id,
        "business_identity_exact": business_identity_matches,
    }


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
            "manual_anchor_translation_sigma_m": MANUAL_ANCHOR_TRANSLATION_SIGMA_M,
            "manual_anchor_yaw_sigma_rad": MANUAL_ANCHOR_YAW_SIGMA_RAD,
            "solver": "bounded_correction_field_banded_v3",
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

    if role == "source_database":
        _validate_source_database_storage(path)
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
        or path_before.st_nlink != 1
        or before.st_nlink != 1
        or after.st_nlink != 1
        or path_after.st_nlink != 1
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
    if role == "source_database":
        _validate_source_database_storage(path)
    return {
        "role": role,
        "file": path.name,
        "bytes": byte_count,
        "sha256": digest.hexdigest(),
    }


def _validate_source_database_storage(source_database: Path) -> None:
    """Reject mutable SQLite companion state and linked source identities.

    An absent or descriptor-stable zero-byte WAL is equivalent to no pending
    WAL content.  A non-empty WAL, a non-empty rollback journal, any linked
    source DB, or any non-regular/linked companion fails closed.
    """

    try:
        database_stat = source_database.lstat()
    except OSError as exc:
        raise OfflineLocalizationError(
            f"Source database could not be inspected safely: {source_database.name}"
        ) from exc
    if not stat.S_ISREG(database_stat.st_mode) or database_stat.st_nlink != 1:
        raise OfflineLocalizationError(
            f"Source database must be an unlinked regular file: {source_database.name}"
        )
    for suffix, active_description in (
        ("-wal", "non-empty WAL"),
        ("-journal", "active rollback journal"),
    ):
        companion = source_database.with_name(source_database.name + suffix)
        try:
            path_before = companion.lstat()
        except FileNotFoundError:
            continue
        except OSError as exc:
            raise OfflineLocalizationError(
                f"Source database companion could not be inspected safely: {companion.name}"
            ) from exc
        if not stat.S_ISREG(path_before.st_mode) or path_before.st_nlink != 1:
            raise OfflineLocalizationError(
                f"Source database companion is unsafe: {companion.name}"
            )
        try:
            flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
            descriptor = os.open(companion, flags)
            with os.fdopen(descriptor, "rb") as handle:
                before = os.fstat(handle.fileno())
                first_byte = handle.read(1)
                after = os.fstat(handle.fileno())
            path_after = companion.lstat()
        except OSError as exc:
            raise OfflineLocalizationError(
                f"Source database companion could not be read safely: {companion.name}"
            ) from exc
        stable_identity = (
            path_before.st_dev,
            path_before.st_ino,
            path_before.st_size,
        )
        if (
            not stat.S_ISREG(before.st_mode)
            or not stat.S_ISREG(path_after.st_mode)
            or before.st_nlink != 1
            or after.st_nlink != 1
            or path_after.st_nlink != 1
            or stable_identity
            != (before.st_dev, before.st_ino, before.st_size)
            or stable_identity != (after.st_dev, after.st_ino, after.st_size)
            or stable_identity
            != (path_after.st_dev, path_after.st_ino, path_after.st_size)
        ):
            raise OfflineLocalizationError(
                f"Source database companion changed while inspected: {companion.name}"
            )
        if before.st_size != 0 or first_byte:
            raise OfflineLocalizationError(
                f"Source database has a {active_description}: {companion.name}"
            )


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
    try:
        validated = validate_session_input_manifest_contract(payload)
    except LocalizedStoreError as exc:
        raise OfflineLocalizationError(str(exc)) from exc
    return str(validated["bundle_sha256"])


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
    if not isinstance(metadata, dict):
        raise OfflineLocalizationError("Session metadata is invalid.")
    capture_health = (
        metadata.get("captureHealth")
    )
    recovery_bound = (
        isinstance(capture_health, dict)
        and "localizationRecoveryEventCount" in capture_health
    )
    tags_bytes, _ = _stable_read_bytes(
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
    has_v2_tags = any(
        isinstance(item, dict) and item.get("version") == 2
        for item in raw_tags
    )
    burst_count = metadata.get("tagObservationBurstCount")
    if isinstance(burst_count, bool) or not isinstance(burst_count, int):
        burst_count = None
    burst_bound = has_v2_tags or (burst_count is not None and burst_count > 0)
    clock_correlation_count = _strict_integer(
        metadata.get("clockCorrelationCount")
    )
    clock_binding_count = _strict_integer(metadata.get("clockNodeBindingCount"))
    clock_bound = (
        metadata.get("clockEvidenceComplete") is True
        or clock_correlation_count is not None
        or clock_binding_count is not None
    )
    if clock_bound:
        if (
            not recovery_bound
            or metadata.get("clockEvidenceComplete") is not True
            or clock_correlation_count is None
            or clock_correlation_count < 2
            or clock_binding_count is None
            or clock_binding_count < 2
        ):
            raise OfflineLocalizationError(
                "Clock-bound localization requires complete v2 clock evidence."
            )
        manifest_version = 4
        file_names = SESSION_INPUT_FILE_NAMES_V4
    elif burst_bound:
        if (
            not recovery_bound
            or burst_count is None
            or burst_count <= 0
            or metadata.get("tagObservationBurstComplete") is not True
        ):
            raise OfflineLocalizationError(
                "ESL confirmation requires recovery-bound metadata and a "
                "complete tag-burst watermark."
            )
        manifest_version = 3
        file_names = SESSION_INPUT_FILE_NAMES_V3
    elif recovery_bound:
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
    verified_burst_observation_ids: dict[str, set[str]]
    verified_burst_frame_authorities: dict[
        str, "VerifiedTagBurstFrameAuthority"
    ]
    durable_tag_bursts: tuple["DurableTagBurstIdentity", ...]
    tag_evidence_degradations: list[dict[str, Any]]
    clock_evidence: "ClockEvidence"
    manifest: dict[str, Any]


@dataclass(frozen=True)
class ClockBinding:
    node_id: int
    node_stamp: float
    system_uptime: float
    utc_unix_seconds: float
    timezone_id: str
    utc_offset_seconds: int


@dataclass(frozen=True)
class ClockEvidence:
    correlations: tuple[dict[str, Any], ...]
    bindings: tuple[ClockBinding, ...]
    discontinuity_binding_edges: frozenset[int]
    bound_node_ids: frozenset[int]
    degradation_codes: tuple[str, ...]

    @property
    def primary_timezone_id(self) -> str:
        if self.bindings:
            return self.bindings[0].timezone_id
        value = self.correlations[0].get("timezone_id") if self.correlations else None
        return value if isinstance(value, str) else ""

    @property
    def primary_utc_offset_seconds(self) -> int:
        if self.bindings:
            return self.bindings[0].utc_offset_seconds
        value = (
            self.correlations[0].get("utc_offset_seconds")
            if self.correlations
            else None
        )
        return value if isinstance(value, int) and not isinstance(value, bool) else 0


def _timezone_offset_seconds(
    timezone_id: str, utc_unix_seconds: float
) -> int | None:
    try:
        zone = ZoneInfo(timezone_id)
        offset = datetime.fromtimestamp(
            utc_unix_seconds, timezone.utc
        ).astimezone(zone).utcoffset()
    except (OSError, OverflowError, ValueError, ZoneInfoNotFoundError):
        return None
    return int(offset.total_seconds()) if offset is not None else None


def _clock_discontinuity_edges(
    correlations: Sequence[dict[str, Any]],
) -> set[int]:
    ratios = [
        (float(after["utc_unix_seconds"]) - float(before["utc_unix_seconds"]))
        / (float(after["monotonic_seconds"]) - float(before["monotonic_seconds"]))
        for before, after in zip(correlations, correlations[1:])
        if abs(
            float(after["monotonic_seconds"])
            - float(before["monotonic_seconds"])
        )
        > 1.0e-9
    ]
    if not ratios:
        return set()
    ordered = sorted(ratios)
    robust_scale = ordered[(len(ordered) - 1) // 2]
    edges: set[int] = set()
    for index, (before, after) in enumerate(
        zip(correlations, correlations[1:])
    ):
        uptime_delta = float(after["monotonic_seconds"]) - float(
            before["monotonic_seconds"]
        )
        utc_delta = float(after["utc_unix_seconds"]) - float(
            before["utc_unix_seconds"]
        )
        explicit = after["reason"] in {"system_clock_change", "timezone_change"}
        timezone_changed = (
            before["timezone_id"] != after["timezone_id"]
            or before["utc_offset_seconds"] != after["utc_offset_seconds"]
        )
        residual = abs(utc_delta - robust_scale * uptime_delta)
        if (
            explicit
            or timezone_changed
            or residual > CLOCK_DISCONTINUITY_TOLERANCE_SECONDS
        ):
            edges.add(index)
    return edges


def _mapped_clock_utc(
    uptime: float,
    correlations: Sequence[dict[str, Any]],
    discontinuity_edges: set[int],
) -> float | None:
    for record in correlations:
        if abs(float(record["monotonic_seconds"]) - uptime) <= 1.0e-9:
            return float(record["utc_unix_seconds"])
    if len(correlations) < 2:
        return None
    for index, (before, after) in enumerate(
        zip(correlations, correlations[1:])
    ):
        first = float(before["monotonic_seconds"])
        second = float(after["monotonic_seconds"])
        if first <= uptime <= second:
            if index in discontinuity_edges:
                return None
            ratio = (uptime - first) / (second - first)
            return float(before["utc_unix_seconds"]) + ratio * (
                float(after["utc_unix_seconds"])
                - float(before["utc_unix_seconds"])
            )
    if uptime < float(correlations[0]["monotonic_seconds"]):
        edge = 0
        distance = float(correlations[0]["monotonic_seconds"]) - uptime
        before, after = correlations[0], correlations[1]
    else:
        edge = len(correlations) - 2
        distance = uptime - float(correlations[-1]["monotonic_seconds"])
        before, after = correlations[-2], correlations[-1]
    if (
        edge in discontinuity_edges
        or distance > CLOCK_MAXIMUM_OUTER_EXTRAPOLATION_SECONDS
    ):
        return None
    first = float(before["monotonic_seconds"])
    second = float(after["monotonic_seconds"])
    ratio = (uptime - first) / (second - first)
    return float(before["utc_unix_seconds"]) + ratio * (
        float(after["utc_unix_seconds"])
        - float(before["utc_unix_seconds"])
    )


def _clock_context_for_uptime(
    uptime: float,
    correlations: Sequence[dict[str, Any]],
) -> tuple[str, int] | None:
    """Return the scan-time timezone context active at one device uptime.

    This mirrors ``StrictClockEvidenceParser.correlationContext`` on iOS:
    an exact sample uses that sample, an interior value uses the immediately
    preceding correlation, and bounded outer values use the nearest endpoint.
    The processing computer's timezone is never consulted.
    """

    if not correlations:
        return None
    selected = correlations[0]
    for record in correlations:
        if float(record["monotonic_seconds"]) > uptime:
            break
        selected = record
    return (
        str(selected["timezone_id"]),
        int(selected["utc_offset_seconds"]),
    )


def _read_clock_evidence_bytes(
    data: bytes,
    *,
    metadata: dict[str, Any],
    node_stamps_by_id: dict[int, float],
) -> tuple[ClockEvidence, dict[str, Any]]:
    """Strictly bind clock framing/identity while retaining sparse coverage.

    A missing per-node binding is an algorithm/evidence coverage degradation,
    not a corrupt session.  Durable duplicate IDs, watermark disagreement,
    malformed framing and node-stamp identity conflicts remain fatal.
    """

    if len(data) > CLOCK_CORRELATION_CONTRACT.maximum_file_bytes:
        raise OfflineLocalizationError("clock_correlations.jsonl exceeds its safety limit.")
    parts = data.split(b"\n")
    if not parts or parts[-1] != b"":
        raise OfflineLocalizationError(
            "Missing final newline at clock_correlations.jsonl."
        )
    parts.pop()
    if not parts:
        raise OfflineLocalizationError("clock_correlations.jsonl is empty.")
    if len(parts) > CLOCK_CORRELATION_CONTRACT.maximum_records:
        raise OfflineLocalizationError("clock_correlations.jsonl has too many records.")

    expected_session = str(metadata.get("trackingSessionId") or "")
    if not expected_session:
        raise OfflineLocalizationError("Clock evidence has no tracking-session authority.")
    correlation_keys = {
        "format", "version", "record_kind", "tracking_session_id",
        "monotonic_seconds", "utc_unix_seconds", "timezone_id",
        "utc_offset_seconds", "reason",
    }
    binding_keys = {
        "format", "version", "record_kind", "tracking_session_id",
        "node_id", "node_stamp", "sampled_frame_timestamp",
        "system_uptime", "utc_unix_seconds", "timezone_id",
        "utc_offset_seconds", "reason",
    }
    correlation_reasons = {
        "session_start", "periodic", "will_resign_active",
        "did_become_active", "system_clock_change", "timezone_change",
        "session_end",
    }
    correlations: list[dict[str, Any]] = []
    pending_bindings: list[ClockBinding] = []
    seen_node_ids: set[int] = set()
    previous_monotonic: float | None = None
    previous_correlation_utc: float | None = None
    previous_binding_stamp: float | None = None
    previous_binding_utc: float | None = None
    for line_number, raw in enumerate(parts, start=1):
        if not raw:
            raise OfflineLocalizationError(
                f"Blank JSONL record at clock_correlations.jsonl:{line_number}"
            )
        if len(raw) + 1 > CLOCK_CORRELATION_CONTRACT.maximum_record_bytes:
            raise OfflineLocalizationError(
                f"Oversized record at clock_correlations.jsonl:{line_number}"
            )
        try:
            value = json.loads(
                raw.decode("utf-8", errors="strict"),
                parse_constant=reject_nonfinite_json,
                object_pairs_hook=reject_duplicate_object_pairs,
            )
        except (UnicodeDecodeError, json.JSONDecodeError, ValueError) as exc:
            raise OfflineLocalizationError(
                f"Invalid clock JSON at clock_correlations.jsonl:{line_number}"
            ) from exc
        if (
            not isinstance(value, dict)
            or json_nesting_depth(value) > CLOCK_CORRELATION_CONTRACT.maximum_nesting_depth
            or value.get("format") != "MarketScannerClockCorrelation"
            or type(value.get("version")) is not int
            or value.get("version") != 2
            or value.get("tracking_session_id") != expected_session
        ):
            raise OfflineLocalizationError(
                f"Invalid clock identity at clock_correlations.jsonl:{line_number}"
            )
        kind = value.get("record_kind")
        allowed_keys = correlation_keys if kind == "correlation" else binding_keys
        if kind not in {"correlation", "node_binding"} or set(value) != allowed_keys:
            raise OfflineLocalizationError(
                f"Invalid clock schema at clock_correlations.jsonl:{line_number}"
            )
        numeric_fields = (
            ("monotonic_seconds", "utc_unix_seconds")
            if kind == "correlation"
            else (
                "node_stamp", "sampled_frame_timestamp", "system_uptime",
                "utc_unix_seconds",
            )
        )
        numeric_values = [_strict_number(value.get(name)) for name in numeric_fields]
        offset = _strict_integer(value.get("utc_offset_seconds"))
        timezone_id = value.get("timezone_id")
        if (
            any(number is None for number in numeric_values)
            or offset is None
            or not isinstance(timezone_id, str)
            or not timezone_id
        ):
            raise OfflineLocalizationError(
                f"Invalid clock scalar at clock_correlations.jsonl:{line_number}"
            )
        utc_value = float(value["utc_unix_seconds"])
        if _timezone_offset_seconds(timezone_id, utc_value) != offset:
            raise OfflineLocalizationError(
                f"Clock timezone offset mismatch at clock_correlations.jsonl:{line_number}"
            )
        if kind == "correlation":
            monotonic = float(value["monotonic_seconds"])
            if (
                value.get("reason") not in correlation_reasons
                or (previous_monotonic is not None and monotonic <= previous_monotonic)
                or (
                    previous_correlation_utc is not None
                    and utc_value <= previous_correlation_utc
                )
            ):
                raise OfflineLocalizationError(
                    f"Invalid clock correlation order at clock_correlations.jsonl:{line_number}"
                )
            previous_monotonic = monotonic
            previous_correlation_utc = utc_value
            correlations.append(value)
            continue

        node_id = _strict_integer(value.get("node_id"))
        node_stamp = float(value["node_stamp"])
        binding_utc = float(value["utc_unix_seconds"])
        if (
            value.get("reason") != "node_bound"
            or node_id is None
            or node_id <= 0
            or node_id in seen_node_ids
            or node_id not in node_stamps_by_id
            or abs(node_stamps_by_id[node_id] - node_stamp) > 1.0e-6
            or abs(float(value["sampled_frame_timestamp"]) - node_stamp)
            > CLOCK_BINDING_FRAME_NODE_STAMP_TOLERANCE_SECONDS
            or (previous_binding_stamp is not None and node_stamp <= previous_binding_stamp)
            or (previous_binding_utc is not None and binding_utc <= previous_binding_utc)
        ):
            raise OfflineLocalizationError(
                f"Invalid or duplicate clock node binding at clock_correlations.jsonl:{line_number}"
            )
        seen_node_ids.add(node_id)
        previous_binding_stamp = node_stamp
        previous_binding_utc = binding_utc
        pending_bindings.append(
            ClockBinding(
                node_id=node_id,
                node_stamp=node_stamp,
                system_uptime=float(value["system_uptime"]),
                utc_unix_seconds=binding_utc,
                timezone_id=timezone_id,
                utc_offset_seconds=offset,
            )
        )

    expected_correlation_count = _strict_integer(metadata.get("clockCorrelationCount"))
    expected_binding_count = _strict_integer(metadata.get("clockNodeBindingCount"))
    if (
        expected_correlation_count != len(correlations)
        or expected_binding_count != len(pending_bindings)
        or metadata.get("clockEvidenceComplete") is not True
        or len(correlations) < 2
        or len(pending_bindings) < 2
    ):
        raise OfflineLocalizationError(
            "Clock evidence count/watermark contract is incomplete."
        )

    correlation_edges = _clock_discontinuity_edges(correlations)
    retained_bindings: list[ClockBinding] = []
    degradation_codes: set[str] = set()
    for binding in pending_bindings:
        mapped = _mapped_clock_utc(
            binding.system_uptime, correlations, correlation_edges
        )
        context = _clock_context_for_uptime(
            binding.system_uptime, correlations
        )
        if (
            mapped is None
            or abs(mapped - binding.utc_unix_seconds)
            > CLOCK_BINDING_CROSS_CHECK_TOLERANCE_SECONDS
            or context
            != (binding.timezone_id, binding.utc_offset_seconds)
        ):
            degradation_codes.add("clock_binding_correlation_mismatch_retained_as_gap")
            continue
        retained_bindings.append(binding)
    if len(retained_bindings) < 2:
        # Framing, watermark, identity and snapshot-node binding were all
        # validated above.  Fewer than two correlation-consistent bindings is
        # therefore an evidence-coverage degradation, not a corrupt session.
        # Keep the trajectory/tag result and emit the wall-clock seconds with
        # unavailable positions instead of terminating the whole job.
        degradation_codes.add(
            "clock_mapping_insufficient_after_cross_check"
        )

    binding_edges: set[int] = set()
    if correlation_edges:
        spans = [
            (
                float(correlations[index]["monotonic_seconds"]),
                float(correlations[index + 1]["monotonic_seconds"]),
            )
            for index in correlation_edges
        ]
        for index, (before, after) in enumerate(
            zip(retained_bindings, retained_bindings[1:])
        ):
            if (
                before.timezone_id != after.timezone_id
                or before.utc_offset_seconds != after.utc_offset_seconds
                or any(
                    min(before.system_uptime, after.system_uptime) < end
                    and max(before.system_uptime, after.system_uptime) > start
                    for start, end in spans
                )
            ):
                binding_edges.add(index)
    missing = set(node_stamps_by_id) - {item.node_id for item in retained_bindings}
    if missing:
        degradation_codes.add("clock_node_binding_coverage_incomplete")
    if (
        not retained_bindings
        or retained_bindings[0].node_id != min(node_stamps_by_id)
    ):
        degradation_codes.add("clock_start_node_unbound")
    if (
        not retained_bindings
        or retained_bindings[-1].node_id != max(node_stamps_by_id)
    ):
        degradation_codes.add("clock_end_node_unbound")
    diagnostics = {
        "file": "clock_correlations.jsonl",
        "contract": "clock_correlations_v2",
        "correlation_count": len(correlations),
        "declared_binding_count": len(pending_bindings),
        "usable_binding_count": len(retained_bindings),
        "database_node_count": len(node_stamps_by_id),
        "unbound_database_node_count": len(missing),
        "discontinuity_count": len(binding_edges),
        "degradation_codes": sorted(degradation_codes),
    }
    return (
        ClockEvidence(
            correlations=tuple(correlations),
            bindings=tuple(retained_bindings),
            discontinuity_binding_edges=frozenset(binding_edges),
            bound_node_ids=frozenset(item.node_id for item in retained_bindings),
            degradation_codes=tuple(sorted(degradation_codes)),
        ),
        diagnostics,
    )


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
    has_v2_tags = any(
        isinstance(item, dict) and item.get("version") == 2
        for item in raw_tags
    )
    burst_count = metadata.get("tagObservationBurstCount")
    if isinstance(burst_count, bool) or not isinstance(burst_count, int):
        burst_count = None
    burst_bound = has_v2_tags or (burst_count is not None and burst_count > 0)
    clock_correlation_count = _strict_integer(
        metadata.get("clockCorrelationCount")
    )
    clock_binding_count = _strict_integer(metadata.get("clockNodeBindingCount"))
    clock_bound = (
        metadata.get("clockEvidenceComplete") is True
        or clock_correlation_count is not None
        or clock_binding_count is not None
    )
    if clock_bound:
        if (
            not recovery_bound
            or metadata.get("clockEvidenceComplete") is not True
            or clock_correlation_count is None
            or clock_correlation_count < 2
            or clock_binding_count is None
            or clock_binding_count < 2
        ):
            raise OfflineLocalizationError(
                "Clock-bound localization requires complete v2 clock evidence."
            )
        manifest_version = 4
        file_names = SESSION_INPUT_FILE_NAMES_V4
    elif burst_bound:
        if (
            not recovery_bound
            or burst_count is None
            or burst_count <= 0
            or metadata.get("tagObservationBurstComplete") is not True
        ):
            raise OfflineLocalizationError(
                "ESL confirmation requires recovery-bound metadata and a "
                "complete tag-burst watermark."
            )
        manifest_version = 3
        file_names = SESSION_INPUT_FILE_NAMES_V3
    else:
        manifest_version = 2 if recovery_bound else 1
        file_names = (
            SESSION_INPUT_FILE_NAMES_V2
            if recovery_bound
            else SESSION_INPUT_FILE_NAMES_V1
        )
    node_inventory = _database_node_inventory(source_database)
    node_stamps_by_id = dict(
        zip(node_inventory["ids"], node_inventory["stamps"], strict=True)
    )
    clock_evidence: ClockEvidence | None = None
    jsonl_names = [name for name in file_names[1:] if name != "localized_price_tags.json"]
    for name in jsonl_names:
        if name == "clock_correlations.jsonl":
            clock_bytes, identity = _stable_read_bytes(
                segment / name,
                name,
                maximum_bytes=CLOCK_CORRELATION_CONTRACT.maximum_file_bytes,
            )
            clock_evidence, diagnostics = _read_clock_evidence_bytes(
                clock_bytes,
                metadata=metadata,
                node_stamps_by_id=node_stamps_by_id,
            )
            values = []
        elif name == "localization_recovery_events.jsonl":
            contract = (
                RECOVERY_EVENT_CONTRACT
                if recovery_bound
                else replace(RECOVERY_EVENT_CONTRACT, required=False)
            )
        elif name == "tag_observations.jsonl":
            contract = replace(
                TAG_OBSERVATION_CONTRACT,
                required=bool(raw_tags),
                # A finalized empty sidecar is still bounded immutable
                # evidence. Preserve every tag barcode as LOW_CONFIDENCE
                # instead of aborting the trajectory/map result.
                allow_empty=True,
            )
        elif name == "tag_observation_bursts.jsonl":
            contract = replace(
                TAG_OBSERVATION_BURST_CONTRACT,
                required=True,
                allow_empty=not burst_bound,
            )
        else:
            contract = contracts[name]
        if name != "clock_correlations.jsonl":
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
    if clock_bound and clock_evidence is None:
        raise OfflineLocalizationError("Clock evidence was not parsed.")
    if clock_evidence is None:
        # Historical v1-v3 sessions remain readable. Their timestamps are not
        # allowed to enter the new immutable calibrated-deliverables contract.
        clock_evidence = ClockEvidence((), (), frozenset(), frozenset(), (
            "clock_evidence_unbound_legacy",
        ))
    verified_burst_observation_ids: dict[str, set[str]] = {}
    verified_burst_frame_authorities: dict[
        str, VerifiedTagBurstFrameAuthority
    ] = {}
    durable_tag_bursts: tuple[DurableTagBurstIdentity, ...] = ()
    tag_evidence_degradations: list[dict[str, Any]] = []
    for sidecar_name in (
        "tag_observations.jsonl",
        "tag_observation_bursts.jsonl",
    ):
        diagnostics = jsonl_diagnostics.get(sidecar_name, {})
        sidecar_degradations = diagnostics.get("degradations")
        if isinstance(sidecar_degradations, list):
            tag_evidence_degradations.extend(
                item for item in sidecar_degradations if isinstance(item, dict)
            )
    if burst_bound:
        bursts = jsonl_values.get("tag_observation_bursts.jsonl", [])
        if len(bursts) != burst_count:
            raise OfflineLocalizationError(
                "Tag burst count does not match the finalized watermark."
            )
        expected_last_burst = metadata.get("tagObservationBurstLastID")
        observed_last_burst = bursts[-1].get("burst_id") if bursts else None
        if observed_last_burst != expected_last_burst:
            raise OfflineLocalizationError(
                "Tag burst last ID does not match the finalized watermark."
            )
        durable_tag_bursts = _durable_tag_burst_inventory(bursts)
        (
            verified_burst_observation_ids,
            verified_burst_frame_authorities,
        ) = _verified_tag_burst_evidence(
            bursts,
            jsonl_values.get("tag_observations.jsonl", []),
            degradations=tag_evidence_degradations,
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
        verified_burst_observation_ids=verified_burst_observation_ids,
        verified_burst_frame_authorities=verified_burst_frame_authorities,
        durable_tag_bursts=durable_tag_bursts,
        tag_evidence_degradations=tag_evidence_degradations,
        clock_evidence=clock_evidence,
        manifest=manifest,
    )


def _verified_source_database_copy(
    source: Path, work_directory: Path, expected_sha256: str
) -> Path:
    """P7R6C 方案 A: copy the source database into a private work input
    while hashing the same descriptor-stable bytes, verify the copy
    matches the snapshot identity, and hand SQLite only the verified
    immutable copy. The original database stays read-only."""

    _validate_source_database_storage(source)
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
        or path_before.st_nlink != 1
        or before.st_nlink != 1
        or after.st_nlink != 1
        or path_after.st_nlink != 1
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
    _validate_source_database_storage(source)
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
    def __init__(self, message: str, *, reason: str | None = None) -> None:
        super().__init__(message)
        self.reason = reason


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
    trusted_absolute: bool = False


@dataclass(frozen=True)
class TagPoseBinding:
    node_index: int
    observation_timestamp: float
    node_timestamp: float
    time_delta_seconds: float
    binding_source: str


@dataclass(frozen=True)
class VerifiedTagBurstFrameAuthority:
    """Manifest-v3 node authority for one durable tag observation.

    The phone persists the exact RTAB-Map node in the complete burst frame.
    Stage-3 must not let optional/legacy observation fields replace that node.
    """

    burst_id: str
    frame_id: str
    observation_id: str
    bound_node_id: int
    frame_timestamp: float
    node_timestamp: float
    payload: str
    symbology: str


@dataclass(frozen=True)
class DurableTagBurstIdentity:
    """Business identity retained for every safely delimited burst record.

    Frame/summary geometry may later degrade, but a uniquely identified
    barcode capture still represents one business row that must reach the
    final result.  Only missing or conflicting durable identity is fatal.
    """

    record_index: int
    burst_id: str
    barcode: str
    symbology: str
    prior_map_id: str
    prior_map_sha256: str
    floor_id: str
    tracking_session_id: str
    last_frame_timestamp: float | None


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
    qualification_maximum_records: int | None = None
    strictly_increasing_timestamps: bool = False


TRACE_LIMITS = MOBILE_EVIDENCE_CONTRACTS["localization_trace.jsonl"]
TRACE_CONTRACT = JsonlContract(
    "localization_trace",
    "MarketScannerLocalizationTrace",
    frozenset({1}),
    True,
    False,
    ("node_timebase_timestamp", "nodeTimebaseTimestamp"),
    maximum_record_bytes=TRACE_LIMITS["max_record_bytes"],
    maximum_records=TRACE_LIMITS["max_records"],
    maximum_file_bytes=TRACE_LIMITS["max_file_bytes"],
    maximum_nesting_depth=TRACE_LIMITS["max_nesting_depth"],
    qualification_maximum_records=TRACE_LIMITS["qualification_max_records"],
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
TAG_BURST_LIMITS = MOBILE_EVIDENCE_CONTRACTS["tag_observation_bursts.jsonl"]
TAG_OBSERVATION_BURST_CONTRACT = JsonlContract(
    "tag_observation_bursts",
    "MarketScannerPriceTagBurst",
    frozenset({2}),
    False,
    True,
    ("last_frame_timestamp",),
    record_id_field="burst_id",
    maximum_record_bytes=TAG_BURST_LIMITS["max_record_bytes"],
    maximum_records=TAG_BURST_LIMITS["max_records"],
    maximum_file_bytes=TAG_BURST_LIMITS["max_file_bytes"],
    maximum_nesting_depth=TAG_BURST_LIMITS["max_nesting_depth"],
    qualification_maximum_records=TAG_BURST_LIMITS.get("qualification_max_records"),
)
CLOCK_CORRELATION_CONTRACT = JsonlContract(
    "clock_correlations",
    "MarketScannerClockCorrelation",
    frozenset({2}),
    True,
    False,
    (),
    identity_required=False,
    maximum_record_bytes=CLOCK_LIMITS["max_record_bytes"],
    maximum_records=CLOCK_LIMITS["max_records"],
    maximum_file_bytes=CLOCK_LIMITS["max_file_bytes"],
    maximum_nesting_depth=CLOCK_LIMITS["max_nesting_depth"],
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
        "stamps": stamps,
        "id_set": set(ids),
        "duplicate_ids": [int(row[0]) for row in duplicate_rows],
        "non_monotonic_stamp_node_ids": non_monotonic,
        "first_stamp": stamps[0],
        "last_stamp": stamps[-1],
    }


def load_raw_continuous_vio_poses(path: Path, horizontal_axes: str) -> list[Pose]:
    """Load every finite immutable Node.pose in the requested map plane."""
    if horizontal_axes not in {"xy", "xz", "ios_prior"}:
        raise OfflineLocalizationError("Raw VIO horizontal axes are invalid.")
    try:
        connection = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
        try:
            rows = connection.execute(
                "SELECT id, stamp, pose FROM Node WHERE id>0 ORDER BY id"
            ).fetchall()
        finally:
            connection.close()
    except sqlite3.Error as exc:
        raise OfflineLocalizationError(
            f"Cannot read raw continuous VIO poses from {path.name}: {exc}"
        ) from exc
    poses: list[Pose] = []
    previous_stamp: float | None = None
    for node_id, stamp_value, blob in rows:
        stamp = _strict_number(stamp_value)
        if (
            isinstance(node_id, bool)
            or not isinstance(node_id, int)
            or node_id <= 0
            or stamp is None
            or not isinstance(blob, bytes)
            or len(blob) != 48
        ):
            raise OfflineLocalizationError("Raw continuous VIO pose inventory is invalid.")
        if previous_stamp is not None and stamp <= previous_stamp:
            raise OfflineLocalizationError(
                "Raw continuous VIO timestamps are not strictly increasing."
            )
        values = struct.unpack("<12f", blob)
        if not all(math.isfinite(value) for value in values):
            raise OfflineLocalizationError("Raw continuous VIO pose is non-finite.")
        tx, ty, tz = values[3], values[7], values[11]
        yaw_xy = math.atan2(values[4], values[0])
        if horizontal_axes == "xy":
            x, y, yaw = tx, ty, yaw_xy
        elif horizontal_axes == "xz":
            x, y, yaw = -ty, -tx, math.atan2(-values[9], values[5])
        else:
            x, y, yaw = -ty, tx, yaw_xy
        poses.append(Pose(node_id, stamp, x, y, _normalize_angle(yaw)))
        previous_stamp = stamp
    if not poses:
        raise OfflineLocalizationError("Raw continuous VIO trajectory is empty.")
    return poses


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


def _strict_numbers_match(left: Any, right: Any) -> bool:
    left_number = _strict_number(left)
    right_number = _strict_number(right)
    return (
        left_number is not None
        and right_number is not None
        and abs(left_number - right_number) <= TAG_EVIDENCE_NUMERIC_TOLERANCE
    )


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


_FORMAL_TRACE_FIELDS = frozenset(
    {
        "format", "version", "timestamp", "trackingState",
        "localizationState", "confidence", "rawPose", "estimatedPose",
        "roadCandidates", "structureSource", "structurePointCount",
        "structureCoverageAngleRad", "matchCandidates", "matchUniqueness",
        "matchResidualCost", "matcherElapsedMs", "constraintAccepted",
        "constraintReason", "measurementAccepted", "hypothesisTrusted",
        "correctionStepApplied", "recoveryConvergedThisUpdate",
        "confidenceAccepted", "constraintDisposition",
        "postRecoveryTrustedLocalFrames", "scanSearchPerformed",
        "hypothesisSupportFrames", "hypothesisScoreMargin", "recoverySearch",
        "correctionTranslationM", "correctionYawDeg", "mapFromArkitX",
        "mapFromArkitY", "mapFromArkitYawDeg", "selectedHypothesisId",
        "activeHypothesisTrackCount", "hypothesisBestCost",
        "hypothesisSecondCost", "hypothesisReason",
        "hypothesisTrackerElapsedMs", "recoveryEpisodeId", "recoveryReason",
        "recoveryOutcome", "recoveryValidAttemptCount",
        "recoveryRemainingValidAttempts", "recoveryElapsedMs",
        "recoveryFreshSupportFrames", "recoveryTriggerCount",
        "recoveryFinishedAtUptime", "recoverySelectedHypothesisId",
        "recoveryFinalResidualTranslationM", "recoveryFinalResidualYawDeg",
        "recoveryCorrectionStepAppliedOnCompletionFrame",
        "recoveryCooldownRemainingMs", "recoveryAutomaticTriggerSuppressed",
        "recoveryAutomaticTriggerReason", "trackingSessionId", "priorMapId",
        "priorMapSha256", "floorId", "nodeTimebaseTimestamp",
        "nodeTimebaseOffsetSeconds",
    }
)
_FORMAL_TRACE_LOCALIZATION_STATES = frozenset(
    {
        "uninitialized", "initializing", "stable", "usable", "recovering",
        "weak", "lost", "manualCorrection",
    }
)
_FORMAL_TRACE_TRACKING_STATES = frozenset(
    {
        "normal", "notAvailable", "limited.excessiveMotion",
        "limited.insufficientFeatures", "limited.initializing",
        "limited.relocalizing", "unknown",
    }
)
_FORMAL_TRACE_DISPOSITIONS = frozenset(
    {
        "rejected", "provisional_recovery_step", "accepted_local",
        "accepted_recovery_convergence",
    }
)
_FORMAL_TRACE_RECOVERY_OUTCOMES = frozenset(
    {"active", "converged", "timed_out", "cancelled", "manual_reset"}
)


def _trace_failure(reason: str, line_label: str) -> None:
    raise OfflineLocalizationError(
        f"{reason} at {line_label}", reason=reason
    )


def _validate_formal_trace_state(value: dict[str, Any], line_label: str) -> None:
    """PC parity validator for the device's current camelCase trace schema.

    Historical PC fixtures omit ``constraintDisposition`` and retain their
    legacy compatibility path. Every current device record contains it and is
    therefore checked against the exact same stable reason categories as the
    Swift parser.
    """
    if "constraintDisposition" not in value:
        return
    unknown = sorted(set(value) - _FORMAL_TRACE_FIELDS)
    if unknown:
        _trace_failure(f"unknown_field_{','.join(unknown)}", line_label)
    boolean_fields = {
        "constraintAccepted", "measurementAccepted", "hypothesisTrusted",
        "correctionStepApplied", "recoveryConvergedThisUpdate",
        "confidenceAccepted", "scanSearchPerformed", "recoverySearch",
        "recoveryAutomaticTriggerSuppressed",
    }
    for field in boolean_fields:
        if type(value.get(field)) is not bool:
            _trace_failure(f"state_field_type_invalid_{field}", line_label)
    nonnegative_integer_fields = {
        "structurePointCount", "postRecoveryTrustedLocalFrames",
        "hypothesisSupportFrames", "activeHypothesisTrackCount",
    }
    for field in nonnegative_integer_fields:
        item = value.get(field)
        if type(item) is not int or item < 0:
            _trace_failure(f"state_field_type_invalid_{field}", line_label)
    required_numbers = {
        "structureCoverageAngleRad", "matchUniqueness", "matcherElapsedMs",
        "hypothesisScoreMargin", "correctionTranslationM", "correctionYawDeg",
        "hypothesisTrackerElapsedMs", "recoveryCooldownRemainingMs",
    }
    numbers: dict[str, float] = {}
    for field in required_numbers:
        item = _strict_number(value.get(field))
        if item is None:
            _trace_failure(f"state_field_type_invalid_{field}", line_label)
        numbers[field] = item
    for field in {
        "matcherElapsedMs", "correctionTranslationM",
        "hypothesisTrackerElapsedMs", "recoveryCooldownRemainingMs",
    }:
        if numbers[field] < 0:
            _trace_failure(f"state_field_range_invalid_{field}", line_label)
    if not 0 <= numbers["matchUniqueness"] <= 1:
        _trace_failure("state_field_range_invalid_matchUniqueness", line_label)
    optional_numbers = {
        "matchResidualCost", "mapFromArkitX", "mapFromArkitY",
        "mapFromArkitYawDeg", "hypothesisBestCost", "hypothesisSecondCost",
        "recoveryElapsedMs", "recoveryFinishedAtUptime",
        "recoveryFinalResidualTranslationM", "recoveryFinalResidualYawDeg",
    }
    for field in optional_numbers:
        if field in value and _strict_number(value[field]) is None:
            _trace_failure(f"state_field_type_invalid_{field}", line_label)
    optional_integers = {
        "selectedHypothesisId", "recoveryEpisodeId",
        "recoveryValidAttemptCount", "recoveryRemainingValidAttempts",
        "recoveryFreshSupportFrames", "recoveryTriggerCount",
        "recoverySelectedHypothesisId",
    }
    for field in optional_integers:
        if field in value and (
            type(value[field]) is not int or value[field] < 0
        ):
            _trace_failure(f"state_field_type_invalid_{field}", line_label)
    completion_step = value.get(
        "recoveryCorrectionStepAppliedOnCompletionFrame"
    )
    if completion_step is not None and type(completion_step) is not bool:
        _trace_failure(
            "state_field_type_invalid_"
            "recoveryCorrectionStepAppliedOnCompletionFrame",
            line_label,
        )
    automatic_reason = value.get("recoveryAutomaticTriggerReason")
    if automatic_reason is not None and (
        not isinstance(automatic_reason, str) or not automatic_reason
    ):
        _trace_failure(
            "state_field_type_invalid_recoveryAutomaticTriggerReason",
            line_label,
        )
    disposition = value.get("constraintDisposition")
    if (
        not isinstance(value.get("structureSource"), str)
        or not value["structureSource"]
        or not isinstance(value.get("constraintReason"), str)
        or not value["constraintReason"]
        or not isinstance(value.get("hypothesisReason"), str)
        or not value["hypothesisReason"]
        or not isinstance(value.get("roadCandidates"), list)
        or not isinstance(value.get("matchCandidates"), list)
        or disposition not in _FORMAL_TRACE_DISPOSITIONS
    ):
        _trace_failure("formal_state_schema_invalid", line_label)
    localization_state = value.get("localizationState")
    tracking_state = value.get("trackingState")
    if localization_state not in _FORMAL_TRACE_LOCALIZATION_STATES:
        _trace_failure("schema_or_state_invalid", line_label)
    if tracking_state not in _FORMAL_TRACE_TRACKING_STATES:
        _trace_failure("schema_or_state_invalid", line_label)

    accepted_disposition = disposition in {
        "accepted_local", "accepted_recovery_convergence"
    }
    measurement_disposition = accepted_disposition or disposition == (
        "provisional_recovery_step"
    )
    recovery_converged = value["recoveryConvergedThisUpdate"]
    if not (
        value["constraintAccepted"] == accepted_disposition
        and value["measurementAccepted"] == measurement_disposition
        and value["correctionStepApplied"] == measurement_disposition
        and value["confidenceAccepted"] == accepted_disposition
        and recovery_converged
        == (disposition == "accepted_recovery_convergence")
    ):
        _trace_failure("constraint_disposition_inconsistent", line_label)
    if value["measurementAccepted"] and (
        not value["hypothesisTrusted"] or not value["scanSearchPerformed"]
    ):
        _trace_failure("measurement_state_inconsistent", line_label)
    recovery_search = value["recoverySearch"]
    if disposition == "accepted_local" and recovery_search:
        _trace_failure("local_acceptance_during_recovery", line_label)
    if disposition == "provisional_recovery_step" and not recovery_search:
        _trace_failure("provisional_step_without_recovery", line_label)
    if tracking_state != "normal" and any(
        value[field]
        for field in {
            "constraintAccepted", "measurementAccepted",
            "correctionStepApplied", "confidenceAccepted",
        }
    ):
        _trace_failure("tracking_state_inconsistent", line_label)
    confidence = _strict_number(value.get("confidence"))
    if tracking_state == "notAvailable" and (
        localization_state != "lost" or confidence != 0
    ):
        _trace_failure("tracking_state_inconsistent", line_label)

    recovery_core = {
        "recoveryEpisodeId", "recoveryReason", "recoveryOutcome",
        "recoveryValidAttemptCount", "recoveryRemainingValidAttempts",
        "recoveryElapsedMs", "recoveryTriggerCount",
    }
    present_count = sum(field in value for field in recovery_core)
    if present_count not in {0, len(recovery_core)}:
        _trace_failure("recovery_bundle_incomplete", line_label)
    recovery_outcome = value.get("recoveryOutcome")
    if present_count:
        if (
            type(value["recoveryEpisodeId"]) is not int
            or value["recoveryEpisodeId"] <= 0
            or not isinstance(value["recoveryReason"], str)
            or not value["recoveryReason"]
            or recovery_outcome not in _FORMAL_TRACE_RECOVERY_OUTCOMES
        ):
            _trace_failure("recovery_bundle_invalid", line_label)
        if recovery_outcome == "active":
            if (
                not recovery_search
                or "recoveryFinishedAtUptime" in value
                or "recoveryCorrectionStepAppliedOnCompletionFrame" in value
            ):
                _trace_failure("recovery_active_state_inconsistent", line_label)
        elif not {
            "recoveryFinishedAtUptime", "recoveryFreshSupportFrames",
            "recoveryCorrectionStepAppliedOnCompletionFrame",
        }.issubset(value):
            _trace_failure("recovery_completion_incomplete", line_label)
    else:
        stray = {
            "recoveryFreshSupportFrames", "recoveryFinishedAtUptime",
            "recoverySelectedHypothesisId",
            "recoveryFinalResidualTranslationM",
            "recoveryFinalResidualYawDeg",
            "recoveryCorrectionStepAppliedOnCompletionFrame",
        }
        if any(field in value for field in stray):
            _trace_failure("recovery_bundle_incomplete", line_label)
    if localization_state == "recovering" and not (
        recovery_search and recovery_outcome == "active" and not recovery_converged
    ):
        _trace_failure("localization_recovery_state_inconsistent", line_label)
    if recovery_outcome == "active" and localization_state != "recovering":
        if not (
            tracking_state == "notAvailable" and localization_state == "lost"
        ):
            _trace_failure("localization_recovery_state_inconsistent", line_label)
    if recovery_converged and recovery_outcome != "converged":
        _trace_failure("recovery_convergence_inconsistent", line_label)
    if value["recoveryAutomaticTriggerSuppressed"] != (
        "recoveryAutomaticTriggerReason" in value
    ):
        _trace_failure("automatic_trigger_state_inconsistent", line_label)


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
        _validate_formal_trace_state(value, line_label)
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
    elif contract.name == "tag_observation_bursts":
        allowed_fields = {
            "format", "version", "burst_id", "sequence", "barcode",
            "symbology", "prior_map_id", "prior_map_sha256", "floor_id",
            "frame_count", "first_frame_timestamp", "last_frame_timestamp",
            "bound_node_id_min", "bound_node_id_max", "depth_quality",
            "view_angle", "tracking_quality", "localization_confidence_mean",
            "tracking_session_id", "complete", "frames",
        }
        allowed_frame_fields = {
            "frame_id", "observation_id", "bound_node_id", "frame_timestamp",
            "node_timestamp", "depth", "view", "tracking", "confidence",
        }
        frames = value.get("frames")
        frame_count = _strict_integer(value.get("frame_count"))
        sequence = _strict_integer(value.get("sequence"))
        first_timestamp = _strict_number(value.get("first_frame_timestamp"))
        last_timestamp = _strict_number(value.get("last_frame_timestamp"))
        if (
            not set(value).issubset(allowed_fields)
            or not isinstance(value.get("burst_id"), str)
            or not value.get("burst_id")
            or not isinstance(value.get("barcode"), str)
            or not value.get("barcode")
            or not isinstance(value.get("symbology"), str)
            or not value.get("symbology")
            or sequence is None
            or sequence <= 0
            or frame_count is None
            or frame_count <= 0
            or not isinstance(frames, list)
            or len(frames) != frame_count
            or value.get("complete") is not True
            or first_timestamp is None
            or last_timestamp is None
            or last_timestamp < first_timestamp
            or (_strict_number(value.get("depth_quality")) is None)
            or not 0 <= float(value.get("depth_quality")) <= 1
            or (_strict_number(value.get("localization_confidence_mean")) is None)
            or not 0 <= float(value.get("localization_confidence_mean")) <= 1
        ):
            raise OfflineLocalizationError(
                f"Invalid tag burst contract at {line_label}"
            )
        frame_ids: set[str] = set()
        observation_ids: set[str] = set()
        frame_timestamps: list[float] = []
        node_ids: list[int] = []
        for frame in frames:
            if not isinstance(frame, dict) or not set(frame).issubset(
                allowed_frame_fields
            ):
                raise OfflineLocalizationError(
                    f"Invalid tag burst frame contract at {line_label}"
                )
            frame_id = frame.get("frame_id")
            observation_id = frame.get("observation_id")
            node_id = _strict_integer(frame.get("bound_node_id"))
            frame_timestamp = _strict_number(frame.get("frame_timestamp"))
            if (
                not isinstance(frame_id, str)
                or not frame_id
                or frame_id in frame_ids
                or not isinstance(observation_id, str)
                or not observation_id
                or observation_id in observation_ids
                or node_id is None
                or node_id <= 0
                or frame_timestamp is None
                or _strict_number(frame.get("node_timestamp")) is None
                or _strict_number(frame.get("depth")) is None
                or not 0 <= float(frame.get("depth")) <= 1
                or not isinstance(frame.get("view"), str)
                or not frame.get("view")
                or not isinstance(frame.get("tracking"), str)
                or not frame.get("tracking")
                or _strict_number(frame.get("confidence")) is None
                or not 0 <= float(frame.get("confidence")) <= 1
            ):
                raise OfflineLocalizationError(
                    f"Invalid tag burst frame at {line_label}"
                )
            frame_ids.add(frame_id)
            observation_ids.add(observation_id)
            frame_timestamps.append(frame_timestamp)
            node_ids.append(node_id)
        if (
            min(frame_timestamps) != first_timestamp
            or max(frame_timestamps) != last_timestamp
            or min(node_ids) != _strict_integer(value.get("bound_node_id_min"))
            or max(node_ids) != _strict_integer(value.get("bound_node_id_max"))
        ):
            raise OfflineLocalizationError(
                f"Tag burst summary mismatch at {line_label}"
            )


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
                f"Invalid JSON at {path_label}:{line_no}: {exc}",
                reason="invalid_json" if contract.name == "localization_trace" else None,
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
        if (
            contract.qualification_maximum_records is not None
            and len(values) > contract.qualification_maximum_records
        ):
            raise OfflineLocalizationError(
                "qualification_limit_exceeded at "
                f"{path_label}:{line_no}: {len(values)} > "
                f"{contract.qualification_maximum_records}",
                reason="qualification_limit_exceeded",
            )
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


def _read_tag_jsonl_bytes_degraded(
    data: bytes,
    contract: JsonlContract,
    *,
    path_label: str,
    session_id: str,
    expected_map_hash: str,
    expected_floor_id: str,
) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    """Parse immutable tag JSONL while isolating record-local evidence gaps.

    Framing, UTF-8, JSON, duplicate durable IDs, identity mismatches and safety
    limits remain fatal. Once a record is safely delimited and belongs to this
    map/session/floor, its optional position/burst business contract may be
    rejected independently and audited as LOW_CONFIDENCE.
    """

    diagnostics: dict[str, Any] = {
        "file": path_label,
        "contract": contract.name,
        "total_lines": 0,
        "valid_records": 0,
        "degraded_records": 0,
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
        "degradations": [],
    }
    if contract.maximum_file_bytes is not None and len(data) > contract.maximum_file_bytes:
        raise OfflineLocalizationError(
            f"{path_label} exceeds the bounded file-size safety limit."
        )
    parts = data.split(b"\n")
    if parts[-1] != b"":
        raise OfflineLocalizationError(
            f"Missing final newline at {path_label}:{len(parts)}"
        )
    parts.pop()
    values: list[dict[str, Any]] = []
    seen_ids: set[str] = set()
    for line_no, part in enumerate(parts, start=1):
        raw_line = part + b"\n"
        diagnostics["total_lines"] += 1
        if (
            contract.qualification_maximum_records is not None
            and diagnostics["total_lines"]
            > contract.qualification_maximum_records
        ):
            raise OfflineLocalizationError(
                "qualification_limit_exceeded at "
                f"{path_label}:{line_no}: {diagnostics['total_lines']} > "
                f"{contract.qualification_maximum_records}",
                reason="qualification_limit_exceeded",
            )
        if diagnostics["total_lines"] > contract.maximum_records:
            raise OfflineLocalizationError(
                f"{path_label} exceeds the bounded "
                f"{contract.maximum_records}-record safety limit."
            )
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
                f"{path_label}:{line_no} exceeds the bounded nesting-depth safety limit."
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
        if _identity_field(
            value, "tracking_session_id", "trackingSessionId"
        ) != session_id:
            diagnostics["session_mismatches"] += 1
            raise OfflineLocalizationError(
                f"Tracking-session mismatch at {path_label}:{line_no}"
            )
        if _identity_field(
            value, "prior_map_sha256", "priorMapSha256"
        ) != expected_map_hash:
            diagnostics["map_hash_mismatches"] += 1
            raise OfflineLocalizationError(
                f"Prior-map hash mismatch at {path_label}:{line_no}"
            )
        if _identity_field(value, "floor_id", "floorId") != expected_floor_id:
            diagnostics["floor_mismatches"] += 1
            raise OfflineLocalizationError(
                f"Floor mismatch at {path_label}:{line_no}"
            )
        record_id = str(value.get(contract.record_id_field or "") or "")
        if not record_id or record_id in seen_ids:
            diagnostics["duplicate_ids"] += 1
            raise OfflineLocalizationError(
                f"Missing or duplicate {contract.record_id_field} at {path_label}:{line_no}"
            )
        seen_ids.add(record_id)
        timestamp = next(
            (value.get(field) for field in contract.timestamp_fields if field in value),
            None,
        )
        timestamp_number = _strict_number(timestamp)
        try:
            _validate_jsonl_business_record(
                contract, value, f"{path_label}:{line_no}"
            )
        except OfflineLocalizationError as exc:
            diagnostics["degraded_records"] += 1
            diagnostics["degradations"].append(
                {
                    "code": f"{contract.name}_record_degraded",
                    "severity": "warning",
                    "disposition": "LOW_CONFIDENCE",
                    "record_id": record_id,
                    "record_index": line_no - 1,
                    "barcode": value.get("payload") or value.get("barcode"),
                    "detail": str(exc),
                }
            )
            values.append(value)
            continue
        if timestamp_number is None:
            diagnostics["timestamp_errors"] += 1
            diagnostics["degraded_records"] += 1
            diagnostics["degradations"].append(
                {
                    "code": f"{contract.name}_timestamp_degraded",
                    "severity": "warning",
                    "disposition": "LOW_CONFIDENCE",
                    "record_id": record_id,
                    "record_index": line_no - 1,
                    "barcode": value.get("payload") or value.get("barcode"),
                    "detail": f"Invalid timestamp at {path_label}:{line_no}",
                }
            )
            values.append(value)
            continue
        values.append(value)
        diagnostics["valid_records"] += 1
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
    if contract.name in {"tag_observations", "tag_observation_bursts"}:
        values, diagnostics = _read_tag_jsonl_bytes_degraded(
            data,
            contract,
            path_label=path.name,
            session_id=session_id,
            expected_map_hash=expected_map_hash,
            expected_floor_id=expected_floor_id,
        )
    else:
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


def _durable_tag_burst_inventory(
    bursts: Sequence[dict[str, Any]],
) -> tuple[DurableTagBurstIdentity, ...]:
    """Build the one-row-per-capture source inventory before localization.

    The degraded JSONL reader has already established framing, format,
    version, map/session/floor identity and globally unique ``burst_id``.
    Barcode and symbology are the remaining business identity fields: if
    either is absent there is no truthful tag row that can be synthesized.
    """

    inventory: list[DurableTagBurstIdentity] = []
    for record_index, burst in enumerate(bursts):
        burst_id = burst.get("burst_id")
        barcode = burst.get("barcode")
        symbology = burst.get("symbology")
        prior_map_id = burst.get("prior_map_id")
        prior_map_sha256 = burst.get("prior_map_sha256")
        floor_id = burst.get("floor_id")
        tracking_session_id = burst.get("tracking_session_id")
        if any(
            not isinstance(value, str) or not value
            for value in (
                burst_id,
                barcode,
                symbology,
                prior_map_id,
                prior_map_sha256,
                floor_id,
                tracking_session_id,
            )
        ):
            raise OfflineLocalizationError(
                "Tag burst has no safely recoverable durable business identity."
            )
        inventory.append(
            DurableTagBurstIdentity(
                record_index=record_index,
                burst_id=burst_id,
                barcode=barcode,
                symbology=symbology,
                prior_map_id=prior_map_id,
                prior_map_sha256=prior_map_sha256,
                floor_id=floor_id,
                tracking_session_id=tracking_session_id,
                last_frame_timestamp=_strict_number(
                    burst.get("last_frame_timestamp")
                ),
            )
        )
    return tuple(inventory)


def _verified_tag_burst_evidence(
    bursts: Sequence[dict[str, Any]],
    observations: Sequence[dict[str, Any]],
    *,
    degradations: list[dict[str, Any]] | None = None,
) -> tuple[
    dict[str, set[str]],
    dict[str, VerifiedTagBurstFrameAuthority],
]:
    """Return exact complete-burst membership and per-frame node authority.

    A v2 confirmation may only reference one verified observation set. For a
    manifest-v3 session, the burst frame's ``bound_node_id`` is also the only
    node authority consumed by Stage-3; optional legacy node fields in the
    observation may agree with it, but can never replace it.
    """

    tolerant = degradations is not None

    def reject(
        code: str,
        detail: str,
        *,
        burst_id: str | None = None,
        observation_id: str | None = None,
        frame_id: str | None = None,
    ) -> None:
        if not tolerant:
            raise OfflineLocalizationError(detail)
        assert degradations is not None
        degradations.append(
            {
                "code": code,
                "severity": "warning",
                "disposition": "LOW_CONFIDENCE",
                "burst_id": burst_id,
                "observation_id": observation_id,
                "frame_id": frame_id,
                "detail": detail,
            }
        )

    observations_by_id: dict[str, dict[str, Any]] = {}
    for observation in observations:
        observation_id = observation.get("observation_id")
        if not isinstance(observation_id, str) or not observation_id:
            reject(
                "tag_observation_id_missing",
                "Tag observation is missing its durable observation ID.",
            )
            continue
        if observation_id in observations_by_id:
            raise OfflineLocalizationError(
                "Tag observation IDs must be globally unique."
            )
        observations_by_id[observation_id] = observation

    # Durable IDs are global inventory, not a property of a burst that later
    # happens to pass its summary/geometry checks. Reserve them before semantic
    # verification so a degraded first burst cannot hand its IDs to a later
    # record and silently change capture identity.
    seen_burst_ids: set[str] = set()
    seen_frame_ids: set[str] = set()
    seen_burst_observation_ids: set[str] = set()
    for burst in bursts:
        burst_id = burst.get("burst_id")
        if isinstance(burst_id, str) and burst_id:
            if burst_id in seen_burst_ids:
                raise OfflineLocalizationError(
                    "Tag burst IDs must be globally unique."
                )
            seen_burst_ids.add(burst_id)
        frames = burst.get("frames")
        if not isinstance(frames, list):
            continue
        for frame in frames:
            if not isinstance(frame, dict):
                continue
            frame_id = frame.get("frame_id")
            observation_id = frame.get("observation_id")
            if isinstance(frame_id, str) and frame_id:
                if frame_id in seen_frame_ids:
                    raise OfflineLocalizationError(
                        "Tag burst frame IDs must be globally unique."
                    )
                seen_frame_ids.add(frame_id)
            if isinstance(observation_id, str) and observation_id:
                if observation_id in seen_burst_observation_ids:
                    raise OfflineLocalizationError(
                        "Tag burst observation IDs must be globally unique."
                    )
                seen_burst_observation_ids.add(observation_id)

    predegraded_burst_ids = {
        str(item.get("record_id"))
        for item in degradations or []
        if isinstance(item, dict)
        and str(item.get("code") or "").startswith(
            "tag_observation_bursts_"
        )
        and item.get("record_id")
    }

    verified: dict[str, set[str]] = {}
    frame_authorities: dict[str, VerifiedTagBurstFrameAuthority] = {}
    globally_bound_observations: set[str] = set()
    previous_sequence: int | None = None
    for burst in bursts:
        burst_id = burst.get("burst_id")
        sequence = _strict_integer(burst.get("sequence"))
        frames = burst.get("frames")
        if (
            not isinstance(burst_id, str)
            or not burst_id
            or sequence is None
            or (previous_sequence is not None and sequence <= previous_sequence)
            or burst.get("complete") is not True
            or not isinstance(frames, list)
        ):
            reject(
                "tag_burst_identity_order_or_completion_invalid",
                "Tag burst identity, order or completion state is invalid.",
                burst_id=burst_id if isinstance(burst_id, str) else None,
            )
            continue
        if burst_id in predegraded_burst_ids:
            # Its unique barcode capture remains in the durable inventory and
            # will become one LOW_CONFIDENCE result, but degraded summary or
            # frame semantics cannot contribute a pose/shelf factor.
            continue
        previous_sequence = sequence
        member_ids: set[str] = set()
        candidate_authorities: dict[
            str, VerifiedTagBurstFrameAuthority
        ] = {}
        burst_valid = True
        for frame in frames:
            if not isinstance(frame, dict):
                reject(
                    "tag_burst_frame_invalid",
                    "Tag burst frame is invalid.",
                    burst_id=burst_id,
                )
                burst_valid = False
                continue
            observation_id = frame.get("observation_id")
            frame_id = frame.get("frame_id")
            bound_node_id = _strict_integer(frame.get("bound_node_id"))
            frame_timestamp = _strict_number(frame.get("frame_timestamp"))
            node_timestamp = _strict_number(frame.get("node_timestamp"))
            observation = observations_by_id.get(str(observation_id or ""))
            if (
                not isinstance(observation_id, str)
                or not observation_id
                or observation_id in member_ids
                or not isinstance(frame_id, str)
                or not frame_id
                or bound_node_id is None
                or bound_node_id <= 0
                or frame_timestamp is None
                or node_timestamp is None
                or observation is None
                or observation.get("burst_id") != burst_id
                or observation.get("frame_id") != frame_id
                or observation.get("payload") != burst.get("barcode")
                or observation.get("symbology") != burst.get("symbology")
                or not _strict_numbers_match(
                    observation.get("frame_timestamp"), frame_timestamp
                )
                or not _strict_numbers_match(
                    observation.get("node_timebase_frame_timestamp"),
                    node_timestamp,
                )
            ):
                reject(
                    "tag_burst_frame_observation_mismatch",
                    "Tag burst frame does not match its durable observation.",
                    burst_id=burst_id,
                    observation_id=(
                        observation_id
                        if isinstance(observation_id, str)
                        else None
                    ),
                    frame_id=frame_id if isinstance(frame_id, str) else None,
                )
                burst_valid = False
                continue
            node_conflict = False
            for explicit_field in ("nearest_node_id", "node_id"):
                if explicit_field not in observation:
                    continue
                if _strict_integer(observation.get(explicit_field)) != bound_node_id:
                    reject(
                        "tag_observation_node_conflicts_with_burst",
                        "Tag observation node field conflicts with its verified "
                        "burst bound node.",
                        burst_id=burst_id,
                        observation_id=observation_id,
                        frame_id=frame_id,
                    )
                    node_conflict = True
                    burst_valid = False
                    break
            if node_conflict:
                continue
            member_ids.add(observation_id)
            candidate_authorities[observation_id] = VerifiedTagBurstFrameAuthority(
                burst_id=burst_id,
                frame_id=frame_id,
                observation_id=observation_id,
                bound_node_id=bound_node_id,
                frame_timestamp=frame_timestamp,
                node_timestamp=node_timestamp,
                payload=str(burst.get("barcode")),
                symbology=str(burst.get("symbology")),
            )
        if not burst_valid or len(member_ids) != len(frames):
            reject(
                "tag_burst_incomplete_after_verification",
                "Tag burst has incomplete or conflicting frame evidence and "
                "was retained only as low-confidence tag identity.",
                burst_id=burst_id,
            )
            continue
        verified[burst_id] = member_ids
        globally_bound_observations.update(member_ids)
        frame_authorities.update(candidate_authorities)
    for observation_id, observation in observations_by_id.items():
        burst_id = observation.get("burst_id")
        frame_id = observation.get("frame_id")
        if (burst_id is not None or frame_id is not None) and (
            not isinstance(burst_id, str)
            or not burst_id
            or not isinstance(frame_id, str)
            or not frame_id
            or observation_id not in globally_bound_observations
        ):
            reject(
                "tag_observation_missing_verified_complete_burst",
                "A durable burst-bound observation is missing from the "
                "verified complete burst set.",
                burst_id=burst_id if isinstance(burst_id, str) else None,
                observation_id=observation_id,
                frame_id=frame_id if isinstance(frame_id, str) else None,
            )
    return verified, frame_authorities


def _verified_tag_burst_observation_ids(
    bursts: Sequence[dict[str, Any]],
    observations: Sequence[dict[str, Any]],
) -> dict[str, set[str]]:
    """Compatibility wrapper returning only verified burst membership."""

    verified, _frame_authorities = _verified_tag_burst_evidence(
        bursts, observations
    )
    return verified


def _degraded_localized_tag(
    item: dict[str, Any],
    index: int,
    reason: str,
) -> dict[str, Any] | None:
    """Preserve a readable barcode identity when optional tag evidence is bad.

    Identity mismatches are rejected by the caller before this helper.  This
    path deliberately removes malformed positions instead of fabricating a
    map origin, retains the additive operator/algorithm fields for audit, and
    prevents incomplete confirmation evidence from becoming authoritative.
    """

    version = item.get("version")
    allowed_fields = (
        LOCALIZED_TAG_V2_FIELDS
        if version == 2
        else LOCALIZED_TAG_V1_FIELDS
    )
    tag = {key: item[key] for key in allowed_fields if key in item}
    payload = item.get("payload")
    tag_id = item.get("tag_id")
    if not isinstance(payload, str) or not payload:
        payload = ""
    if not isinstance(tag_id, str) or not tag_id:
        if not payload:
            return None
        tag_id = "degraded-" + hashlib.sha256(
            f"{index}:{payload}".encode("utf-8")
        ).hexdigest()[:24]
    tag["format"] = "MarketScannerLocalizedPriceTag"
    tag["version"] = 2 if version == 2 else 1
    tag["tag_id"] = tag_id
    tag["payload"] = payload
    tag["symbology"] = (
        item.get("symbology")
        if isinstance(item.get("symbology"), str)
        else "unknown"
    )
    for position_field in ("raw_map_position", "snapped_map_position"):
        if not _strict_pose_2d_or_3d(tag.get(position_field)):
            tag.pop(position_field, None)
    for confidence_field in (
        "localization_confidence",
        "measurement_confidence",
        "association_confidence",
    ):
        value = _strict_number(tag.get(confidence_field))
        tag[confidence_field] = (
            max(0.0, min(1.0, value)) if value is not None else 0.0
        )
    timestamp = _strict_number(tag.get("timestamp"))
    if timestamp is None:
        tag.pop("timestamp", None)
    tag["needs_review"] = True
    tag["user_confirmed"] = False
    tag["quality_status"] = "LOW_CONFIDENCE"
    tag["input_evidence_status"] = "DEGRADED"
    tag["review_reasons"] = [reason]
    tag["approval_status"] = "pending"
    return tag


def _append_missing_durable_burst_tags(
    tags: list[dict[str, Any]],
    durable_bursts: Sequence[DurableTagBurstIdentity],
    *,
    expected_map_id: str,
    expected_map_hash: str,
    expected_floor_id: str,
    expected_tracking_session_id: str,
    degradations: list[dict[str, Any]],
) -> int:
    """Reconcile the finalized tag array with the durable burst inventory.

    A writer/finalizer defect must not erase a safely identified barcode
    capture. Every burst not represented by a non-empty ``capture_id`` gains
    one explicit LOW_CONFIDENCE row with unavailable position/shelf fields.
    Existing localized rows are retained independently; they are never merged
    merely because their barcode text matches another capture.
    """

    represented_capture_ids = {
        str(tag.get("capture_id"))
        for tag in tags
        if isinstance(tag.get("capture_id"), str) and tag.get("capture_id")
    }
    tag_ids = {
        str(tag.get("tag_id"))
        for tag in tags
        if isinstance(tag.get("tag_id"), str) and tag.get("tag_id")
    }
    observation_ids = {
        str(tag.get("observation_id"))
        for tag in tags
        if isinstance(tag.get("observation_id"), str)
        and tag.get("observation_id")
    }
    appended = 0
    for burst in durable_bursts:
        if (
            burst.prior_map_id != expected_map_id
            or burst.prior_map_sha256 != expected_map_hash
            or burst.floor_id != expected_floor_id
            or burst.tracking_session_id != expected_tracking_session_id
        ):
            raise OfflineLocalizationError(
                "Durable tag burst identity does not match the active map/session."
            )
        if burst.burst_id in represented_capture_ids:
            continue
        digest = hashlib.sha256(
            (
                f"{burst.tracking_session_id}\0{burst.prior_map_sha256}\0"
                f"{burst.floor_id}\0{burst.burst_id}"
            ).encode("utf-8")
        ).hexdigest()
        tag_id = f"durable-burst-{digest}"
        observation_id = f"missing-final-tag-{digest}"
        if tag_id in tag_ids or observation_id in observation_ids:
            raise OfflineLocalizationError(
                "Synthesized durable tag identity collides with finalized tag data."
            )
        tags.append(
            {
                "format": "MarketScannerLocalizedPriceTag",
                "version": 1,
                "tag_id": tag_id,
                "observation_id": observation_id,
                "capture_id": burst.burst_id,
                "payload": burst.barcode,
                "symbology": burst.symbology,
                "floor_id": burst.floor_id,
                "timestamp": burst.last_frame_timestamp or 0.0,
                "tracking_session_id": burst.tracking_session_id,
                "prior_map_id": burst.prior_map_id,
                "prior_map_sha256": burst.prior_map_sha256,
                "shelf_code": None,
                "row_flag": None,
                "cross_code": None,
                "shelf_side": None,
                "distance_from_shelf_start_cm": None,
                "height_cm": None,
                "raw_map_position": None,
                "snapped_map_position": None,
                "localization_confidence": 0.0,
                "measurement_confidence": 0.0,
                "association_confidence": 0.0,
                "measurement_method": "durable_burst_inventory_recovery",
                "needs_review": True,
                "user_confirmed": False,
                "quality_status": "LOW_CONFIDENCE",
                "input_evidence_status": "DEGRADED",
                "review_reasons": ["durable_burst_missing_final_tag"],
                "approval_status": "pending",
            }
        )
        tag_ids.add(tag_id)
        observation_ids.add(observation_id)
        represented_capture_ids.add(burst.burst_id)
        appended += 1
        degradations.append(
            {
                "code": "durable_burst_missing_final_tag",
                "severity": "warning",
                "disposition": "LOW_CONFIDENCE",
                "record_index": burst.record_index,
                "burst_id": burst.burst_id,
                "barcode": burst.barcode,
                "detail": (
                    "Durable burst had no finalized localized tag row; one "
                    "unpositioned business row was retained."
                ),
            }
        )
    return appended


def _read_localized_price_tags_bytes(
    data: bytes,
    *,
    session_id: str,
    expected_map_id: str,
    expected_map_hash: str,
    expected_floor_id: str,
    expected_count: int,
    verified_burst_observation_ids: dict[str, set[str]] | None = None,
    verified_burst_identities: dict[str, tuple[str, str]] | None = None,
    degradations: list[dict[str, Any]] | None = None,
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
    if degradations is not None:
        tags: list[dict[str, Any]] = []
        tag_ids: set[str] = set()
        observation_ids: set[str] = set()
        capture_ids: set[str] = set()
        for index, item in enumerate(payload):
            if not isinstance(item, dict):
                degradations.append(
                    {
                        "code": "localized_tag_record_not_object",
                        "severity": "warning",
                        "disposition": "LOW_CONFIDENCE",
                        "record_index": index,
                        "detail": "Localized tag record is not an object and has no recoverable barcode identity.",
                    }
                )
                continue
            if (
                _identity_field(item, "tracking_session_id", "trackingSessionId")
                != session_id
                or _identity_field(item, "prior_map_sha256", "priorMapSha256")
                != expected_map_hash
                or _identity_field(item, "floor_id", "floorId")
                != expected_floor_id
            ):
                raise OfflineLocalizationError(
                    f"localized_price_tags.json item {index} has mismatched identity."
                )
            if item.get("prior_map_id") != expected_map_id:
                raise OfflineLocalizationError(
                    f"localized_price_tags.json item {index} has an invalid prior_map_id."
                )
            raw_tag_id = item.get("tag_id")
            raw_observation_id = item.get("observation_id")
            raw_capture_id = item.get("capture_id")
            if isinstance(raw_tag_id, str) and raw_tag_id:
                if raw_tag_id in tag_ids:
                    raise OfflineLocalizationError(
                        f"localized_price_tags.json item {index} has missing/duplicate IDs."
                    )
                tag_ids.add(raw_tag_id)
            if isinstance(raw_observation_id, str) and raw_observation_id:
                if raw_observation_id in observation_ids:
                    raise OfflineLocalizationError(
                        f"localized_price_tags.json item {index} has missing/duplicate IDs."
                    )
                observation_ids.add(raw_observation_id)
            if isinstance(raw_capture_id, str) and raw_capture_id:
                if raw_capture_id in capture_ids:
                    raise OfflineLocalizationError(
                        f"localized_price_tags.json item {index} has a duplicate capture_id."
                    )
                capture_ids.add(raw_capture_id)
            try:
                parsed = _read_localized_price_tags_bytes(
                    _canonical_json_bytes([item]),
                    session_id=session_id,
                    expected_map_id=expected_map_id,
                    expected_map_hash=expected_map_hash,
                    expected_floor_id=expected_floor_id,
                    expected_count=1,
                    verified_burst_observation_ids=verified_burst_observation_ids,
                    verified_burst_identities=verified_burst_identities,
                    maximum_bytes=maximum_bytes,
                    maximum_records=maximum_records,
                )[0]
            except OfflineLocalizationError as exc:
                reason = str(exc)
                degraded = _degraded_localized_tag(item, index, reason)
                degradations.append(
                    {
                        "code": "localized_tag_evidence_degraded",
                        "severity": "warning",
                        "disposition": "LOW_CONFIDENCE",
                        "record_index": index,
                        "tag_id": raw_tag_id,
                        "observation_id": raw_observation_id,
                        "detail": reason,
                        "barcode_retained": degraded is not None,
                    }
                )
                if degraded is not None:
                    tags.append(degraded)
            else:
                tags.append(parsed)
        return tags
    tags: list[dict[str, Any]] = []
    tag_ids: set[str] = set()
    observation_ids: set[str] = set()
    capture_ids: set[str] = set()
    confirmed_frame_observation_ids: set[str] = set()
    for index, item in enumerate(payload):
        if not isinstance(item, dict):
            raise OfflineLocalizationError(
                f"localized_price_tags.json item {index} is not an object."
            )
        version = item.get("version")
        if (
            item.get("format") != "MarketScannerLocalizedPriceTag"
            or isinstance(version, bool)
            or not isinstance(version, int)
            or version not in {1, 2}
        ):
            raise OfflineLocalizationError(
                f"localized_price_tags.json item {index} has an invalid contract."
            )
        allowed_fields = (
            LOCALIZED_TAG_V1_FIELDS
            if version == 1
            else LOCALIZED_TAG_V2_FIELDS
        )
        unexpected_fields = sorted(set(item) - allowed_fields)
        if unexpected_fields:
            raise OfflineLocalizationError(
                "localized_price_tags.json item "
                f"{index} contains forbidden fields: {unexpected_fields}."
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
        if version == 2:
            capture_id = item.get("capture_id")
            frame_ids = item.get("frame_observation_ids")
            algorithm_segment_id = item.get("algorithm_shelf_segment_id")
            algorithm_side = item.get("algorithm_side")
            algorithm_confidence = _strict_number(
                item.get("algorithm_association_confidence")
            )
            confirmation_status = item.get("confirmation_status")
            user_segment_id = item.get("user_confirmed_shelf_segment_id")
            user_side = item.get("user_confirmed_side")
            confirmed_at_utc = _strict_number(item.get("confirmed_at_utc"))
            confirmed_at_monotonic = _strict_number(
                item.get("confirmed_at_monotonic")
            )
            if (
                not isinstance(capture_id, str)
                or _CANONICAL_LOWERCASE_UUID.fullmatch(capture_id) is None
                or capture_id in capture_ids
                or not isinstance(frame_ids, list)
                or not 3 <= len(frame_ids) <= 64
                or any(
                    not isinstance(value, str)
                    or not value
                    or len(value) > 128
                    for value in frame_ids
                )
                or len(set(frame_ids)) != len(frame_ids)
                or observation_id not in frame_ids
                or any(value in confirmed_frame_observation_ids for value in frame_ids)
                or not isinstance(algorithm_segment_id, str)
                or not algorithm_segment_id
                or len(algorithm_segment_id) > 128
                or item.get("shelf_segment_id") != algorithm_segment_id
                or not isinstance(algorithm_side, str)
                or not algorithm_side
                or len(algorithm_side) > 128
                or item.get("shelf_side") != algorithm_side
                or algorithm_confidence is None
                or not 0 <= algorithm_confidence <= 1
                or confirmation_status
                not in {"USER_CONFIRMED", "USER_OVERRIDDEN"}
                or item.get("user_confirmed") is not True
                or item.get("needs_review") is not False
                or not isinstance(user_segment_id, str)
                or not user_segment_id
                or len(user_segment_id) > 128
                or not isinstance(user_side, str)
                or not user_side
                or len(user_side) > 128
                or confirmed_at_utc is None
                or confirmed_at_utc <= 0
                or confirmed_at_monotonic is None
                or confirmed_at_monotonic < 0
                or item.get("confirmation_source") != "on_device_operator"
            ):
                raise OfflineLocalizationError(
                    f"localized_price_tags.json item {index} has invalid confirmation evidence."
                )
            verified_frames = (
                verified_burst_observation_ids or {}
            ).get(capture_id)
            if verified_frames != set(frame_ids):
                raise OfflineLocalizationError(
                    f"localized_price_tags.json item {index} is not bound to one verified complete burst."
                )
            verified_identity = (verified_burst_identities or {}).get(capture_id)
            if verified_identity != (item.get("payload"), item.get("symbology")):
                raise OfflineLocalizationError(
                    f"localized_price_tags.json item {index} payload does not match its verified burst."
                )
            same_candidate = (
                algorithm_segment_id == user_segment_id
                and algorithm_side == user_side
            )
            if (
                confirmation_status == "USER_CONFIRMED" and not same_candidate
            ) or (
                confirmation_status == "USER_OVERRIDDEN" and same_candidate
            ):
                raise OfflineLocalizationError(
                    f"localized_price_tags.json item {index} has inconsistent confirmation status."
                )
            for field in (
                "algorithm_distance_from_shelf_start_cm",
                "user_confirmed_distance_from_shelf_start_cm",
            ):
                value = _strict_number(item.get(field))
                if value is None or not 0 <= value <= 100_000:
                    raise OfflineLocalizationError(
                        f"localized_price_tags.json item {index} has invalid {field}."
                    )
            for field in ("algorithm_shelf_code", "user_confirmed_shelf_code"):
                value = item.get(field)
                if value is not None and (
                    not isinstance(value, str) or not value or len(value) > 128
                ):
                    raise OfflineLocalizationError(
                        f"localized_price_tags.json item {index} has invalid {field}."
                    )
            legacy_distance = _strict_number(
                item.get("distance_from_shelf_start_cm")
            )
            algorithm_distance = _strict_number(
                item.get("algorithm_distance_from_shelf_start_cm")
            )
            legacy_confidence = _strict_number(
                item.get("association_confidence")
            )
            if (
                item.get("shelf_code") != item.get("algorithm_shelf_code")
                or legacy_distance is None
                or algorithm_distance is None
                or abs(legacy_distance - algorithm_distance) > 1.0e-9
                or legacy_confidence is None
                or abs(legacy_confidence - algorithm_confidence) > 1.0e-9
            ):
                raise OfflineLocalizationError(
                    f"localized_price_tags.json item {index} overwrites algorithm evidence."
                )
            capture_ids.add(capture_id)
            confirmed_frame_observation_ids.update(frame_ids)
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
    verified_burst_frame: VerifiedTagBurstFrameAuthority | None = None,
) -> TagPoseBinding:
    """Bind one tag observation to a real RTAB-Map node, or fail closed.

    Manifest-v3 observations use the verified complete burst frame's exact
    node ID. Optional observation node fields may agree but can never override
    it. Legacy v1/v2 inputs retain the historical explicit-ID / timestamp
    behavior. Wall-clock timestamps are deliberately ignored.
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

    if verified_burst_frame is not None:
        observation_id = observation.get("observation_id")
        if (
            observation_id != verified_burst_frame.observation_id
            or observation.get("burst_id") != verified_burst_frame.burst_id
            or observation.get("frame_id") != verified_burst_frame.frame_id
            or observation.get("payload") != verified_burst_frame.payload
            or observation.get("symbology") != verified_burst_frame.symbology
            or not _strict_numbers_match(
                observation.get("frame_timestamp"),
                verified_burst_frame.frame_timestamp,
            )
            or not _strict_numbers_match(
                observation_timestamp,
                verified_burst_frame.node_timestamp,
            )
        ):
            raise OfflineLocalizationError(
                "tag_observation_verified_burst_frame_mismatch"
            )
        for explicit_field in ("nearest_node_id", "node_id"):
            if explicit_field not in observation:
                continue
            if (
                _strict_integer(observation.get(explicit_field))
                != verified_burst_frame.bound_node_id
            ):
                raise OfflineLocalizationError(
                    "tag_observation_verified_burst_node_override"
                )
        matches = [
            index
            for index, pose in enumerate(poses)
            if pose.node_id == verified_burst_frame.bound_node_id
        ]
        if not matches:
            raise OfflineLocalizationError(
                "tag_observation_verified_burst_node_id_not_found"
            )
        if len(matches) != 1:
            raise OfflineLocalizationError(
                "tag_observation_verified_burst_node_id_ambiguous"
            )
        index = matches[0]
        binding_source = "verified_burst_bound_node_id"
    else:
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
    if verified_burst_frame is not None and (
        abs(node_timestamp - verified_burst_frame.node_timestamp)
        > TAG_EVIDENCE_MAXIMUM_NODE_TIME_DELTA_SECONDS
    ):
        raise OfflineLocalizationError(
            "tag_observation_verified_burst_node_stamp_mismatch"
        )
    time_delta = abs(observation_timestamp - node_timestamp)
    effective_maximum_delta = (
        min(
            maximum_time_delta_seconds,
            TAG_EVIDENCE_MAXIMUM_NODE_TIME_DELTA_SECONDS,
        )
        if verified_burst_frame is not None
        else maximum_time_delta_seconds
    )
    if time_delta > effective_maximum_delta:
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
    match_audit: list[dict[str, Any]] | None = None,
) -> list[AbsoluteConstraint]:
    """Build ambiguity-gated priors from one continuous corridor sequence.

    The former implementation selected the nearest corridor independently at
    every sample. A gradually rotated trajectory would therefore cross the
    midpoint between two parallel aisles and start constraining itself to the
    wrong aisle. This Viterbi-style matcher preserves a continuous correction
    field, respects map corridor connectivity and leaves genuinely ambiguous
    samples unconstrained.

    Device yaw is not assumed to equal walking direction. The yaw prior applies
    only the rotation needed to align the local trajectory tangent with the
    selected corridor, preserving how the operator held the phone.
    """
    corridors: list[tuple[str, float, tuple[float, float], tuple[float, float]]] = []
    for cross in road_graph.get("crosses", []):
        if not isinstance(cross, dict) or str(cross.get("floor_id")) != floor_id:
            continue
        points = cross.get("points_m")
        if not isinstance(points, list):
            continue
        width = max(0.2, float(cross.get("width_m", 1.0) or 1.0))
        for first, second in zip(points, points[1:]):
            if (
                not isinstance(first, list)
                or not isinstance(second, list)
                or len(first) < 2
                or len(second) < 2
            ):
                continue
            corridors.append(
                (
                    str(cross.get("id", "cross")),
                    width,
                    (float(first[0]), float(first[1])),
                    (float(second[0]), float(second[1])),
                )
            )
    if not baseline or not corridors:
        return []

    # The continuous sequence model needs enough travel history to establish
    # a route-level hypothesis. Preserve the former bounded local prior for
    # short sessions; this also prevents a tiny synthetic/inspection scan from
    # acquiring a confident periodic-aisle sequence that it cannot support.
    if len(baseline) < 64:
        constraints: list[AbsoluteConstraint] = []
        sample_stride = max(1, stride)
        sampled_indices = list(range(0, len(baseline), sample_stride))
        if sampled_indices[-1] != len(baseline) - 1:
            sampled_indices.append(len(baseline) - 1)
        for index in sampled_indices:
            pose = baseline[index]
            candidates: list[
                tuple[float, str, float, float, float, float]
            ] = []
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
            proximity = max(0.1, 1.0 - distance / (width / 2 + 0.75))
            weight = 0.35 * proximity
            legacy_sigma = 1.0 / math.sqrt(weight)
            constraints.append(
                AbsoluteConstraint(
                    identifier=f"road-local-{corridor_id}-{pose.node_id}",
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
                        "matcher": "bounded_local_corridor_v1",
                    },
                    translation_sigma_m=legacy_sigma,
                    yaw_sigma_rad=min(math.pi, legacy_sigma),
                )
            )
        return constraints

    adjacency: dict[str, set[str]] = {}
    for cross in road_graph.get("crosses", []):
        if isinstance(cross, dict) and str(cross.get("floor_id")) == floor_id:
            identifier = str(cross.get("id") or "")
            if identifier:
                adjacency.setdefault(identifier, set()).add(identifier)
    for node in road_graph.get("nodes", []):
        if not isinstance(node, dict) or str(node.get("floor_id")) != floor_id:
            continue
        identifiers = sorted(
            {
                str(value)
                for value in node.get("cross_ids", [])
                if str(value) in adjacency
            }
        )
        for first in identifiers:
            adjacency[first].update(identifiers)

    constraints: list[AbsoluteConstraint] = []
    sample_stride = max(1, stride)
    sampled_indices = list(range(0, len(baseline), sample_stride))
    if baseline and sampled_indices[-1:] != [len(baseline) - 1]:
        sampled_indices.append(len(baseline) - 1)

    def motion_yaw(index: int) -> tuple[float | None, float]:
        left = index
        right = index
        maximum_radius = min(32, max(4, sample_stride * 2))
        for radius in range(2, maximum_radius + 1, 2):
            left = max(0, index - radius)
            right = min(len(baseline) - 1, index + radius)
            dx = baseline[right].x - baseline[left].x
            dy = baseline[right].y - baseline[left].y
            distance = math.hypot(dx, dy)
            if distance >= 0.75:
                return math.atan2(-dx, dy), distance
        return None, math.hypot(
            baseline[right].x - baseline[left].x,
            baseline[right].y - baseline[left].y,
        )

    candidate_sets: list[list[dict[str, Any]]] = []
    for index in sampled_indices:
        pose = baseline[index]
        travel_yaw, tangent_distance = motion_yaw(index)
        by_corridor: dict[str, dict[str, Any]] = {}
        for corridor_id, width, start, end in corridors:
            projected = _project_to_segment(pose.x, pose.y, start, end)
            if projected is None or projected[2] > width / 2 + 5.0:
                continue
            road_yaw = projected[3]
            yaw_delta = 0.0
            yaw_residual = 0.0
            if travel_yaw is not None:
                selected_road_yaw = min(
                    (road_yaw, _normalize_angle(road_yaw + math.pi)),
                    key=lambda value: abs(_normalize_angle(value - travel_yaw)),
                )
                yaw_delta = _normalize_angle(selected_road_yaw - travel_yaw)
                yaw_residual = abs(yaw_delta)
                if yaw_residual > math.radians(50.0):
                    continue
            outside = max(0.0, projected[2] - width / 2.0)
            emission = (outside / 1.35) ** 2 + 0.12 * (
                projected[2] / (width / 2.0 + 1.0)
            ) ** 2
            if travel_yaw is not None:
                emission += 0.35 * (yaw_residual / math.radians(15.0)) ** 2
            candidate = {
                "corridor_id": corridor_id,
                "node_index": index,
                "x": projected[0],
                "y": projected[1],
                "distance_m": projected[2],
                "width_m": width,
                "yaw_delta": yaw_delta,
                "yaw_residual_deg": math.degrees(yaw_residual),
                "travel_yaw_available": travel_yaw is not None,
                "tangent_distance_m": tangent_distance,
                "emission": emission,
            }
            previous = by_corridor.get(corridor_id)
            if previous is None or (emission, projected[2]) < (
                previous["emission"], previous["distance_m"]
            ):
                by_corridor[corridor_id] = candidate
        candidates = sorted(
            by_corridor.values(),
            key=lambda value: (
                value["emission"], value["distance_m"], value["corridor_id"]
            ),
        )[:12]
        candidates.append(
            {
                "corridor_id": None,
                "node_index": index,
                "x": pose.x,
                "y": pose.y,
                "distance_m": None,
                "width_m": None,
                "yaw_delta": 0.0,
                "yaw_residual_deg": None,
                "travel_yaw_available": travel_yaw is not None,
                "tangent_distance_m": tangent_distance,
                "emission": 4.5,
            }
        )
        candidate_sets.append(candidates)

    def transition(previous: dict[str, Any], current: dict[str, Any]) -> float:
        previous_id = previous["corridor_id"]
        current_id = current["corridor_id"]
        if previous_id is None or current_id is None:
            return 0.35 if previous_id == current_id else 0.9
        cost = 0.0 if previous_id == current_id else (
            0.35 if current_id in adjacency.get(previous_id, set()) else 8.0
        )
        previous_pose = baseline[previous["node_index"]]
        current_pose = baseline[current["node_index"]]
        previous_correction = (
            previous["x"] - previous_pose.x,
            previous["y"] - previous_pose.y,
        )
        current_correction = (
            current["x"] - current_pose.x,
            current["y"] - current_pose.y,
        )
        correction_delta = math.hypot(
            current_correction[0] - previous_correction[0],
            current_correction[1] - previous_correction[1],
        )
        yaw_delta = abs(
            _normalize_angle(current["yaw_delta"] - previous["yaw_delta"])
        )
        raw_travel = math.hypot(
            current_pose.x - previous_pose.x, current_pose.y - previous_pose.y
        )
        projected_travel = math.hypot(
            current["x"] - previous["x"], current["y"] - previous["y"]
        )
        return (
            cost
            + 0.30 * (correction_delta / 1.25) ** 2
            + 0.30 * (yaw_delta / math.radians(12.0)) ** 2
            + 0.08 * (abs(projected_travel - raw_travel) / 1.5) ** 2
        )

    forward: list[list[float]] = []
    parents: list[list[int]] = []
    for sample_index, candidates in enumerate(candidate_sets):
        if sample_index == 0:
            forward.append([float(value["emission"]) for value in candidates])
            parents.append([-1] * len(candidates))
            continue
        costs: list[float] = []
        links: list[int] = []
        for candidate in candidates:
            options = [
                (
                    forward[sample_index - 1][prior_index]
                    + transition(prior, candidate),
                    prior_index,
                )
                for prior_index, prior in enumerate(candidate_sets[sample_index - 1])
            ]
            best_cost, best_parent = min(options)
            costs.append(best_cost + float(candidate["emission"]))
            links.append(best_parent)
        forward.append(costs)
        parents.append(links)
    selected_indices = [0] * len(candidate_sets)
    selected_indices[-1] = min(
        range(len(candidate_sets[-1])), key=forward[-1].__getitem__
    )
    for sample_index in range(len(candidate_sets) - 1, 0, -1):
        selected_indices[sample_index - 1] = parents[sample_index][
            selected_indices[sample_index]
        ]

    backward = [[0.0] * len(values) for values in candidate_sets]
    for sample_index in range(len(candidate_sets) - 2, -1, -1):
        for prior_index, prior in enumerate(candidate_sets[sample_index]):
            backward[sample_index][prior_index] = min(
                transition(prior, candidate)
                + float(candidate["emission"])
                + backward[sample_index + 1][candidate_index]
                for candidate_index, candidate in enumerate(
                    candidate_sets[sample_index + 1]
                )
            )

    selected: list[dict[str, Any]] = []
    for sample_index, candidate_index in enumerate(selected_indices):
        candidate = dict(candidate_sets[sample_index][candidate_index])
        totals = sorted(
            forward[sample_index][index]
            + backward[sample_index][index]
            for index in range(len(candidate_sets[sample_index]))
        )
        candidate["path_margin"] = (
            math.inf if len(totals) < 2 else max(0.0, totals[1] - totals[0])
        )
        selected.append(candidate)

    run_start = 0
    for run_end in range(1, len(selected) + 1):
        if run_end < len(selected) and selected[run_end]["corridor_id"] == selected[
            run_start
        ]["corridor_id"]:
            continue
        run_length = run_end - run_start
        corridor_id = selected[run_start]["corridor_id"]
        if corridor_id is not None and run_length >= 2:
            for candidate in selected[run_start:run_end]:
                margin = float(candidate["path_margin"])
                if margin < 0.35:
                    continue
                pose = baseline[candidate["node_index"]]
                high_confidence = (
                    margin >= 1.5
                    and float(candidate["distance_m"])
                    <= float(candidate["width_m"]) / 2.0 + 2.5
                )
                translation_sigma = 0.65 if high_confidence else 0.95
                yaw_sigma = (
                    math.radians(8.0 if high_confidence else 12.0)
                    if candidate["travel_yaw_available"]
                    else math.pi
                )
                target_yaw = _normalize_angle(pose.yaw + candidate["yaw_delta"])
                constraints.append(
                    AbsoluteConstraint(
                        identifier=(
                            f"road-sequence-{corridor_id}-{pose.node_id}"
                        ),
                        node_index=candidate["node_index"],
                        x=float(candidate["x"]),
                        y=float(candidate["y"]),
                        yaw=target_yaw,
                        weight=1.0 / (translation_sigma * translation_sigma),
                        kind="road_soft",
                        source={
                            "corridor_id": corridor_id,
                            "distance_m": candidate["distance_m"],
                            "width_m": candidate["width_m"],
                            "path_margin": margin,
                            "confidence": (
                                "high" if high_confidence else "medium"
                            ),
                            "yaw_correction_deg": math.degrees(
                                candidate["yaw_delta"]
                            ),
                            "matcher": "continuous_corridor_sequence_v2",
                        },
                        translation_sigma_m=translation_sigma,
                        yaw_sigma_rad=yaw_sigma,
                    )
                )
        run_start = run_end

    if match_audit is not None:
        for candidate in selected:
            pose = baseline[candidate["node_index"]]
            match_audit.append(
                {
                    "node_id": pose.node_id,
                    "timestamp": pose.timestamp,
                    "corridor_id": candidate["corridor_id"],
                    "distance_m": candidate["distance_m"],
                    "yaw_residual_deg": candidate["yaw_residual_deg"],
                    "path_margin": (
                        None
                        if math.isinf(float(candidate["path_margin"]))
                        else round(float(candidate["path_margin"]), 6)
                    ),
                    "status": (
                        "unmatched"
                        if candidate["corridor_id"] is None
                        else (
                            "ambiguous_low_confidence"
                            if float(candidate["path_margin"]) < 0.35
                            else "matched"
                        )
                    ),
                }
            )
    return constraints


def build_corridor_heading_constraints(
    baseline: Sequence[Pose],
    road_graph: dict[str, Any],
    floor_id: str,
    stride: int = 8,
) -> list[AbsoluteConstraint]:
    """Align long straight motion to the prior-map corridor orientation field.

    Parallel supermarket aisles make the exact aisle identity ambiguous while
    their dominant orientation is still unambiguous. Point-to-corridor priors
    must therefore not be the only source of yaw correction: a gradually
    rotated route can be several metres from the right aisle before a unique
    lateral association exists. This pass rotates each stable straight-motion
    run around its own center, correcting both position and device yaw without
    selecting a particular parallel aisle. The sequence matcher remains the
    authority for the later lateral association.
    """

    # This is a low-frequency drift correction, not a local shape snap. Short
    # sessions do not contain enough repeated aisle travel to distinguish a
    # persistent map-axis bias from an ordinary turn, and applying it there
    # would compete with exact anchors/tag fixtures. The real production case
    # is a many-minute route with hundreds of nodes.
    if len(baseline) < 64:
        return []
    axes: list[float] = []
    for cross in road_graph.get("crosses", []):
        if not isinstance(cross, dict) or str(cross.get("floor_id")) != floor_id:
            continue
        points = cross.get("points_m")
        if not isinstance(points, list):
            continue
        for first, second in zip(points, points[1:]):
            if (
                not isinstance(first, list)
                or not isinstance(second, list)
                or len(first) < 2
                or len(second) < 2
            ):
                continue
            dx = float(second[0]) - float(first[0])
            dy = float(second[1]) - float(first[1])
            if math.hypot(dx, dy) < 2.0:
                continue
            axis = math.atan2(-dx, dy)
            # An undirected corridor axis is canonical modulo pi.
            axis = axis % math.pi
            if all(
                min(
                    abs(_normalize_angle(axis - existing)),
                    abs(_normalize_angle(axis - existing + math.pi)),
                    abs(_normalize_angle(axis - existing - math.pi)),
                )
                > math.radians(10.0)
                for existing in axes
            ):
                axes.append(axis)
    if not axes:
        return []

    sample_stride = max(1, stride)
    sampled_indices = list(range(0, len(baseline), sample_stride))
    if sampled_indices[-1] != len(baseline) - 1:
        sampled_indices.append(len(baseline) - 1)
    cumulative_distance = [0.0]
    for previous, current in zip(baseline, baseline[1:]):
        cumulative_distance.append(
            cumulative_distance[-1]
            + math.hypot(current.x - previous.x, current.y - previous.y)
        )

    samples: list[dict[str, Any]] = []
    for index in sampled_indices:
        left = index
        right = index
        travel_yaw: float | None = None
        for radius in range(4, min(32, max(8, sample_stride * 2)) + 1, 2):
            left = max(0, index - radius)
            right = min(len(baseline) - 1, index + radius)
            dx = baseline[right].x - baseline[left].x
            dy = baseline[right].y - baseline[left].y
            if math.hypot(dx, dy) >= 1.5:
                travel_yaw = math.atan2(-dx, dy)
                break
        if travel_yaw is None:
            samples.append({"node_index": index, "axis": None, "yaw_delta": 0.0})
            continue
        choices: list[tuple[float, float]] = []
        for axis in axes:
            directed = min(
                (axis, _normalize_angle(axis + math.pi)),
                key=lambda value: abs(_normalize_angle(value - travel_yaw)),
            )
            choices.append((abs(_normalize_angle(directed - travel_yaw)), directed))
        residual, directed_axis = min(choices)
        if residual > math.radians(28.0):
            samples.append({"node_index": index, "axis": None, "yaw_delta": 0.0})
            continue
        samples.append(
            {
                "node_index": index,
                "axis": round(directed_axis % math.pi, 6),
                "yaw_delta": _normalize_angle(directed_axis - travel_yaw),
                "residual_deg": math.degrees(residual),
            }
        )

    constraints: list[AbsoluteConstraint] = []
    run_start = 0
    for run_end in range(1, len(samples) + 1):
        if run_end < len(samples) and samples[run_end]["axis"] == samples[run_start]["axis"]:
            continue
        run = samples[run_start:run_end]
        if run and run[0]["axis"] is not None:
            first_index = int(run[0]["node_index"])
            last_index = int(run[-1]["node_index"])
            run_distance = cumulative_distance[last_index] - cumulative_distance[first_index]
            if len(run) >= 3 and run_distance >= 6.0:
                deltas = [float(item["yaw_delta"]) for item in run]
                median_delta = min(
                    deltas,
                    key=lambda candidate: sum(
                        abs(_normalize_angle(value - candidate))
                        for value in deltas
                    ),
                )
                deviations = [
                    abs(_normalize_angle(float(item["yaw_delta"]) - median_delta))
                    for item in run
                ]
                inliers = [
                    item
                    for item, deviation in zip(run, deviations)
                    if deviation <= math.radians(12.0)
                ]
                if len(inliers) >= 3:
                    run_identifier = (
                        f"{baseline[first_index].node_id}-"
                        f"{baseline[last_index].node_id}-"
                        f"{run[0]['axis']}"
                    )
                    center_x = sum(
                        baseline[int(item["node_index"])].x for item in inliers
                    ) / len(inliers)
                    center_y = sum(
                        baseline[int(item["node_index"])].y for item in inliers
                    ) / len(inliers)
                    cosine = math.cos(median_delta)
                    sine = math.sin(median_delta)
                    for item in inliers:
                        index = int(item["node_index"])
                        pose = baseline[index]
                        relative_x = pose.x - center_x
                        relative_y = pose.y - center_y
                        target_x = center_x + cosine * relative_x - sine * relative_y
                        target_y = center_y + sine * relative_x + cosine * relative_y
                        constraints.append(
                            AbsoluteConstraint(
                                identifier=f"road-heading-{pose.node_id}",
                                node_index=index,
                                x=target_x,
                                y=target_y,
                                yaw=_normalize_angle(pose.yaw + median_delta),
                                weight=1.0,
                                kind="road_heading_soft",
                                source={
                                    "matcher": "corridor_orientation_field_v2",
                                    "correction_field_contract": (
                                        "continuous_rigid_run_se2_v1"
                                    ),
                                    "run_id": run_identifier,
                                    "run_start_node_index": first_index,
                                    "run_end_node_index": last_index,
                                    "run_start_node_id": baseline[first_index].node_id,
                                    "run_end_node_id": baseline[last_index].node_id,
                                    "field_sample_stride": sample_stride,
                                    "run_distance_m": run_distance,
                                    "run_sample_count": len(run),
                                    "yaw_correction_deg": math.degrees(median_delta),
                                    "position_rotation_center": {
                                        "x_m": center_x,
                                        "y_m": center_y,
                                    },
                                    "position_rotation_only": True,
                                },
                                translation_sigma_m=0.55,
                                yaw_sigma_rad=math.radians(4.0),
                            )
                        )
        run_start = run_end
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


def reconstruct_gauge_neutral_trace(
    trace: Sequence[dict[str, Any]],
    manual_events: Sequence[dict[str, Any]] = (),
) -> tuple[list[Pose], dict[str, Any]]:
    """Recover continuous physical motion from a mutable map-gauge trace.

    ``rawPose`` is projected through the phone's current map/ARKit alignment.
    Accepted structure corrections and manual relocalizations replace that
    alignment, so the next raw pose can jump even while the operator is
    stationary.  A correction frame publishes the pre-reset ``rawPose`` and
    post-reset ``estimatedPose``.  The following physical increment must
    therefore start at the previous estimated pose.  Exact manual anchors are
    similar gauge resets, but have no correction-frame flag; their confirmed
    map pose identifies the first post-reset raw sample.

    The returned trajectory preserves only relative physical increments.  Its
    first pose is kept in the current map frame so downstream route matching
    can use the selected scan start as an initial hint.
    """

    records: list[tuple[float, tuple[float, float, float], tuple[float, float, float], bool]] = []
    for record in trace:
        if not isinstance(record, dict):
            continue
        timestamp = _strict_number(
            _field(record, "node_timebase_timestamp", "nodeTimebaseTimestamp")
        )
        raw = _pose_from(_field(record, "raw_pose", "rawPose"))
        estimated = _pose_from(_field(record, "estimated_pose", "estimatedPose"))
        if timestamp is None or raw is None or estimated is None:
            continue
        records.append(
            (
                timestamp,
                raw,
                estimated,
                record.get("correctionStepApplied") is True
                or record.get("correction_step_applied") is True,
            )
        )
    if not records:
        return [], {
            "format": "MarketScannerGaugeNeutralTraceAudit",
            "version": 1,
            "status": "unavailable",
            "reason": "no_complete_trace_records",
        }

    manual_resets: dict[int, dict[str, Any]] = {}
    timestamps = [record[0] for record in records]
    for sequence, event in enumerate(manual_events, start=1):
        if not isinstance(event, dict):
            continue
        event_timestamp = _strict_number(
            event.get("node_timebase_frame_timestamp")
            if event.get("node_timebase_frame_timestamp") is not None
            else event.get("nodeTimebaseFrameTimestamp")
        )
        confirmed = _pose_from(event.get("confirmed_map_pose"))
        if event_timestamp is None or confirmed is None:
            continue
        insertion = min(
            range(len(timestamps)),
            key=lambda index: abs(timestamps[index] - event_timestamp),
        )
        # The anchor reset may appear in the closest sample or the immediately
        # following sample.  Select the raw pose nearest to the confirmed map
        # pose; this uses the anchor only to identify a gauge boundary, never
        # as a physical displacement measurement.
        candidates = [
            index
            for index in range(max(1, insertion - 1), min(len(records), insertion + 3))
        ]
        if not candidates:
            continue
        reset_index = min(
            candidates,
            key=lambda index: math.hypot(
                records[index][1][0] - confirmed[0],
                records[index][1][1] - confirmed[1],
            ),
        )
        manual_resets[reset_index] = {
            "event_id": str(event.get("event_id") or f"manual-{sequence:06d}"),
            "event_timestamp": event_timestamp,
            "trace_timestamp": records[reset_index][0],
            "confirmed_map_pose": confirmed,
        }

    first_raw = records[0][1]
    recovered = [Pose(1, records[0][0], first_raw[0], first_raw[1], first_raw[2])]
    automatic_reset_count = 0
    manual_reset_count = 0
    maximum_input_step = 0.0
    maximum_output_step = 0.0
    for index in range(1, len(records)):
        previous_raw = records[index - 1][1]
        previous_estimated = records[index - 1][2]
        current_raw = records[index][1]
        maximum_input_step = max(
            maximum_input_step,
            math.hypot(
                current_raw[0] - previous_raw[0],
                current_raw[1] - previous_raw[1],
            ),
        )
        if index in manual_resets:
            dx = 0.0
            dy = 0.0
            dyaw = 0.0
            manual_reset_count += 1
        else:
            origin = previous_estimated if records[index - 1][3] else previous_raw
            dx_map = current_raw[0] - origin[0]
            dy_map = current_raw[1] - origin[1]
            cosine = math.cos(-origin[2])
            sine = math.sin(-origin[2])
            dx = cosine * dx_map - sine * dy_map
            dy = sine * dx_map + cosine * dy_map
            dyaw = _normalize_angle(current_raw[2] - origin[2])
            if records[index - 1][3]:
                automatic_reset_count += 1
        previous = recovered[-1]
        cosine = math.cos(previous.yaw)
        sine = math.sin(previous.yaw)
        next_x = previous.x + cosine * dx - sine * dy
        next_y = previous.y + sine * dx + cosine * dy
        maximum_output_step = max(
            maximum_output_step,
            math.hypot(next_x - previous.x, next_y - previous.y),
        )
        recovered.append(
            Pose(
                node_id=index + 1,
                timestamp=records[index][0],
                x=next_x,
                y=next_y,
                yaw=_normalize_angle(previous.yaw + dyaw),
            )
        )
    return recovered, {
        "format": "MarketScannerGaugeNeutralTraceAudit",
        "version": 1,
        "status": "recovered",
        "trace_sample_count": len(recovered),
        "automatic_alignment_reset_count": automatic_reset_count,
        "manual_alignment_reset_count": manual_reset_count,
        "maximum_input_map_gauge_step_m": round(maximum_input_step, 9),
        "maximum_recovered_physical_step_m": round(maximum_output_step, 9),
        "input_trajectory_length_m": _trajectory_length(
            [
                Pose(index + 1, record[0], record[1][0], record[1][1], record[1][2])
                for index, record in enumerate(records)
            ]
        ),
        "physical_trajectory_length_m": _trajectory_length(recovered),
        "manual_resets": [
            {
                **value,
                "confirmed_map_pose": {
                    "x_m": value["confirmed_map_pose"][0],
                    "y_m": value["confirmed_map_pose"][1],
                    "yaw_rad": value["confirmed_map_pose"][2],
                },
            }
            for _, value in sorted(manual_resets.items())
        ],
    }


def resample_pose_sequence(
    source: Sequence[Pose], targets: Sequence[Pose]
) -> list[Pose]:
    """Interpolate one timestamped pose sequence at another pose inventory."""

    if not source:
        return []
    valid_source = [
        pose
        for pose in source
        if pose.timestamp is not None and math.isfinite(float(pose.timestamp))
    ]
    if not valid_source:
        return []
    timestamps = [float(pose.timestamp) for pose in valid_source]
    result: list[Pose] = []
    cursor = 0
    for target in targets:
        if target.timestamp is None or not math.isfinite(float(target.timestamp)):
            return []
        timestamp = float(target.timestamp)
        while cursor + 1 < len(timestamps) and timestamps[cursor + 1] < timestamp:
            cursor += 1
        if timestamp <= timestamps[0]:
            value = valid_source[0]
        elif timestamp >= timestamps[-1]:
            value = valid_source[-1]
        else:
            first = valid_source[cursor]
            second = valid_source[cursor + 1]
            denominator = float(second.timestamp) - float(first.timestamp)
            fraction = max(
                0.0,
                min(1.0, (timestamp - float(first.timestamp)) / denominator),
            )
            delta_yaw = _normalize_angle(second.yaw - first.yaw)
            value = Pose(
                node_id=target.node_id,
                timestamp=target.timestamp,
                x=first.x + fraction * (second.x - first.x),
                y=first.y + fraction * (second.y - first.y),
                yaw=_normalize_angle(first.yaw + fraction * delta_yaw),
            )
        result.append(
            Pose(
                node_id=target.node_id,
                timestamp=target.timestamp,
                x=value.x,
                y=value.y,
                yaw=value.yaw,
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
    curvature_smoothness: float = 0.0,
    iterations: int = 120,
) -> list[float]:
    """Solve a banded smooth correction field exactly in O(N).

    Fixed-iteration relaxation converged too slowly for thousand-node routes.
    A remote manual anchor could therefore form a narrow correction spike and
    look like a physical pose jump. First-difference regularization preserves
    continuity, while the optional second-difference term permits an affine
    correction over a long straight run. That distinction matters for heading
    drift: a rigid rotation is a linear x/y correction along the aisle and
    should not be suppressed as if it were a discontinuity.

    The resulting symmetric positive-definite matrix has bandwidth two. A
    deterministic banded Cholesky factorization replaces the former Thomas
    solve without changing the O(N) memory or time bound.
    """
    del iterations  # Kept in the signature for source compatibility.
    if count <= 0:
        return []
    if (
        not math.isfinite(smoothness)
        or not math.isfinite(curvature_smoothness)
        or smoothness < 0.0
        or curvature_smoothness < 0.0
    ):
        raise OfflineLocalizationError(
            "Correction-field smoothness is invalid."
        )
    diagonal = [0.0] * count
    first_off_diagonal = [0.0] * max(0, count - 1)
    second_off_diagonal = [0.0] * max(0, count - 2)
    right_hand_side = [0.0] * count
    for index in range(count):
        if index > 0:
            diagonal[index] += smoothness
        if index + 1 < count:
            diagonal[index] += smoothness
            first_off_diagonal[index] -= smoothness
    for center in range(1, count - 1):
        # curvature_smoothness * (c[i-1] - 2*c[i] + c[i+1])^2
        diagonal[center - 1] += curvature_smoothness
        diagonal[center] += 4.0 * curvature_smoothness
        diagonal[center + 1] += curvature_smoothness
        first_off_diagonal[center - 1] -= 2.0 * curvature_smoothness
        first_off_diagonal[center] -= 2.0 * curvature_smoothness
        second_off_diagonal[center - 1] += curvature_smoothness
    for index, target, weight in observations:
        if not 0 <= index < count or not all(
            math.isfinite(value) for value in (target, weight)
        ) or weight <= 0.0:
            raise OfflineLocalizationError("Correction-field observation is invalid.")
        diagonal[index] += weight
        right_hand_side[index] += weight * target
    # Keep the selected scan start as a soft gauge. It must not freeze the
    # route when later absolute evidence proves accumulated drift.
    diagonal[0] += 2.0
    if any(value <= 0.0 or not math.isfinite(value) for value in diagonal):
        raise OfflineLocalizationError("Correction-field system is singular.")

    cholesky_diagonal = [0.0] * count
    cholesky_first = [0.0] * count
    cholesky_second = [0.0] * count
    for index in range(count):
        if index >= 2:
            cholesky_second[index] = (
                second_off_diagonal[index - 2]
                / cholesky_diagonal[index - 2]
            )
        if index >= 1:
            overlap = (
                cholesky_second[index] * cholesky_first[index - 1]
                if index >= 2
                else 0.0
            )
            cholesky_first[index] = (
                first_off_diagonal[index - 1] - overlap
            ) / cholesky_diagonal[index - 1]
        pivot = (
            diagonal[index]
            - cholesky_first[index] * cholesky_first[index]
            - cholesky_second[index] * cholesky_second[index]
        )
        if pivot <= 0.0 or not math.isfinite(pivot):
            raise OfflineLocalizationError("Correction-field system is singular.")
        cholesky_diagonal[index] = math.sqrt(pivot)

    forward = [0.0] * count
    for index in range(count):
        value = right_hand_side[index]
        if index >= 1:
            value -= cholesky_first[index] * forward[index - 1]
        if index >= 2:
            value -= cholesky_second[index] * forward[index - 2]
        forward[index] = value / cholesky_diagonal[index]
    values = [0.0] * count
    for index in range(count - 1, -1, -1):
        value = forward[index]
        if index + 1 < count:
            value -= cholesky_first[index + 1] * values[index + 1]
        if index + 2 < count:
            value -= cholesky_second[index + 2] * values[index + 2]
        values[index] = value / cholesky_diagonal[index]
    if any(not math.isfinite(value) for value in values):
        raise OfflineLocalizationError("Correction-field solution is non-finite.")
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
            trusted_manual_anchor = is_manual_anchor and constraint.trusted_absolute
            if is_manual_anchor and not trusted_manual_anchor:
                exceeds_gate = (
                    residual_xy > UNVERIFIED_MANUAL_ANCHOR_MAX_TRANSLATION_M
                    or residual_yaw > UNVERIFIED_MANUAL_ANCHOR_MAX_YAW_RAD
                )
            else:
                exceeds_gate = not trusted_manual_anchor and constraint.kind not in {
                    "manual_aisle_assignment",
                    "road_heading_soft",
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
                            "unverified_manual_anchor_safety_gate"
                            if is_manual_anchor
                            else "robust_hard_gate"
                        ),
                    }
                )
                continue
            retained.append(constraint)
            # A verified manual anchor is already uncertainty-bounded evidence.
            # Huber-downweighting it by a large drift residual would make it
            # weaker exactly when it is most useful. Automatic constraints
            # remain robustly downweighted and hard-gated as before.
            translation_weight = (
                1.0 / (constraint.translation_sigma_m ** 2)
                if constraint.translation_sigma_m is not None
                else constraint.weight
            )
            yaw_base_weight = (
                1.0 / (constraint.yaw_sigma_rad ** 2)
                if constraint.yaw_sigma_rad is not None
                else constraint.weight
            )
            xy_weight = translation_weight * (
                1.0
                if trusted_manual_anchor
                or constraint.kind in {"road_heading_soft", "road_soft"}
                else _huber_weight(residual_xy, HUBER_TRANSLATION_M)
            )
            yaw_weight = yaw_base_weight * (
                1.0
                if trusted_manual_anchor
                or constraint.kind in {"road_heading_soft", "road_soft"}
                else _huber_weight(residual_yaw, HUBER_YAW_RAD)
            )
            if (
                constraint.kind == "road_heading_soft"
                and constraint.source.get("correction_field_contract")
                == "continuous_rigid_run_se2_v1"
            ):
                # The complete run is added below as one continuous low-rate
                # field. Keeping only these sparse point observations would
                # penalize a genuine rigid rotation through the first-order
                # smoother and leave the long aisle visibly skewed.
                continue
            observations[0].append((index, constraint.x - baseline[index].x, xy_weight))
            observations[1].append((index, constraint.y - baseline[index].y, xy_weight))
            observations[2].append(
                (
                    index,
                    _normalize_angle(constraint.yaw - baseline[index].yaw),
                    yaw_weight,
                )
            )
        heading_runs: dict[str, AbsoluteConstraint] = {}
        for constraint in retained:
            if (
                constraint.kind == "road_heading_soft"
                and constraint.source.get("correction_field_contract")
                == "continuous_rigid_run_se2_v1"
            ):
                run_id = str(constraint.source.get("run_id") or "")
                if run_id:
                    heading_runs.setdefault(run_id, constraint)
        for constraint in heading_runs.values():
            source = constraint.source
            start = source.get("run_start_node_index")
            end = source.get("run_end_node_index")
            center = source.get("position_rotation_center")
            correction_deg = source.get("yaw_correction_deg")
            stride = source.get("field_sample_stride")
            if (
                isinstance(start, bool)
                or not isinstance(start, int)
                or isinstance(end, bool)
                or not isinstance(end, int)
                or not 0 <= start <= end < len(baseline)
                or not isinstance(center, dict)
                or isinstance(stride, bool)
                or not isinstance(stride, int)
                or stride <= 0
            ):
                raise OfflineLocalizationError(
                    "Corridor heading correction field is invalid."
                )
            try:
                center_x = float(center["x_m"])
                center_y = float(center["y_m"])
                correction = math.radians(float(correction_deg))
            except (KeyError, TypeError, ValueError) as exc:
                raise OfflineLocalizationError(
                    "Corridor heading correction field is invalid."
                ) from exc
            if not all(
                math.isfinite(value)
                for value in (center_x, center_y, correction)
            ):
                raise OfflineLocalizationError(
                    "Corridor heading correction field is invalid."
                )
            cosine = math.cos(correction)
            sine = math.sin(correction)
            # Preserve the total evidence scale of the sparse matcher while
            # distributing it over every node. The bounded translation boost
            # lets a long rigid run overcome first-order damping without
            # turning an ambiguous corridor into a hard lateral assignment.
            translation_sigma = constraint.translation_sigma_m or 0.55
            yaw_sigma = constraint.yaw_sigma_rad or math.radians(4.0)
            translation_weight = 4.0 / (
                translation_sigma * translation_sigma * stride
            )
            yaw_weight = 1.0 / (yaw_sigma * yaw_sigma * stride)
            for index in range(start, end + 1):
                pose = baseline[index]
                relative_x = pose.x - center_x
                relative_y = pose.y - center_y
                target_x = center_x + cosine * relative_x - sine * relative_y
                target_y = center_y + sine * relative_x + cosine * relative_y
                observations[0].append(
                    (index, target_x - pose.x, translation_weight)
                )
                observations[1].append(
                    (index, target_y - pose.y, translation_weight)
                )
                observations[2].append((index, correction, yaw_weight))
        active = retained
        use_rigid_heading_field = bool(heading_runs)
        corrections[0] = _solve_banded(
            len(baseline),
            observations[0],
            smoothness=1.5 if use_rigid_heading_field else 24.0,
            curvature_smoothness=96.0 if use_rigid_heading_field else 0.0,
        )
        corrections[1] = _solve_banded(
            len(baseline),
            observations[1],
            smoothness=1.5 if use_rigid_heading_field else 24.0,
            curvature_smoothness=96.0 if use_rigid_heading_field else 0.0,
        )
        corrections[2] = _solve_banded(
            len(baseline),
            observations[2],
            smoothness=12.0 if use_rigid_heading_field else 36.0,
            curvature_smoothness=72.0 if use_rigid_heading_field else 0.0,
        )
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
            "translation_sigma_m": item.translation_sigma_m,
            "yaw_sigma_rad": item.yaw_sigma_rad,
            "uncertainty_source": (
                "explicit_v2"
                if item.translation_sigma_m is not None
                else "legacy_scalar_weight_migration"
            ),
            "trusted_absolute": item.trusted_absolute,
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
    correction_translation_steps: list[float] = []
    correction_yaw_steps: list[float] = []
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
        first_correction = (
            opt_first.x - base_first.x,
            opt_first.y - base_first.y,
            _normalize_angle(opt_first.yaw - base_first.yaw),
        )
        second_correction = (
            opt_second.x - base_second.x,
            opt_second.y - base_second.y,
            _normalize_angle(opt_second.yaw - base_second.yaw),
        )
        correction_translation_steps.append(
            math.hypot(
                second_correction[0] - first_correction[0],
                second_correction[1] - first_correction[1],
            )
        )
        correction_yaw_steps.append(
            abs(_normalize_angle(second_correction[2] - first_correction[2]))
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
        "maximum_neighbor_correction_translation_change_m": round(
            max(correction_translation_steps, default=0.0), 9
        ),
        "maximum_neighbor_correction_yaw_change_deg": round(
            math.degrees(max(correction_yaw_steps, default=0.0)), 9
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
                "yaws_rad": [pose.yaw for pose in baseline],
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
                # The route matcher changes the map gauge while preserving
                # the phone's physical orientation relative to that gauge.
                # Export the solved phone yaw explicitly: a route tangent is
                # movement direction, not necessarily the way the phone was
                # facing while the operator scanned a shelf.
                "yaws_rad": [pose.yaw for pose in optimized],
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
                    "yaws_rad": [pose[2] for pose in online_points],
                },
                "geometry": {
                    "type": "LineString",
                    "coordinates": [[pose[0], pose[1]] for pose in online_points],
                },
            },
        )
    return {"type": "FeatureCollection", "features": features}


def manual_anchor_statuses(
    poses: Sequence[Pose], constraints: Sequence[AbsoluteConstraint]
) -> list[str | None]:
    """Mark exact-node operator anchors without treating them as movement."""

    statuses: list[str | None] = [None] * len(poses)
    for constraint in constraints:
        if (
            constraint.kind == "manual_anchor"
            and constraint.trusted_absolute
            and 0 <= constraint.node_index < len(statuses)
        ):
            statuses[constraint.node_index] = "trusted_manual_anchor"
    return statuses


def _clock_value_for_node_stamp(
    clock_evidence: ClockEvidence,
    node_stamp: float,
) -> dict[str, Any]:
    bindings = clock_evidence.bindings
    unavailable = {
        "utc_unix_s": None,
        "local_time_iso8601": None,
        "timezone_id": None,
        "utc_offset_seconds": None,
        "clock_segment_index": None,
        "clock_status": "UNAVAILABLE",
        "clock_degradation_code": "clock_time_mapping_unavailable",
    }
    for binding_index, binding in enumerate(bindings):
        if abs(binding.node_stamp - node_stamp) <= 1.0e-9:
            utc_value = binding.utc_unix_seconds
            return {
                "utc_unix_s": utc_value,
                "local_time_iso8601": _format_local_time(
                    utc_value, binding.utc_offset_seconds, milliseconds=True
                ),
                "timezone_id": binding.timezone_id,
                "utc_offset_seconds": binding.utc_offset_seconds,
                "clock_segment_index": sum(
                    edge < binding_index
                    for edge in clock_evidence.discontinuity_binding_edges
                ),
                "clock_status": "EXACT_NODE_BINDING",
                "clock_degradation_code": None,
            }
    if len(bindings) < 2:
        return {
            **unavailable,
            "clock_degradation_code": (
                "clock_mapping_insufficient_after_cross_check"
                if bindings
                else "clock_evidence_unbound_legacy"
            ),
        }
    for index, (before, after) in enumerate(zip(bindings, bindings[1:])):
        if before.node_stamp <= node_stamp <= after.node_stamp:
            if index in clock_evidence.discontinuity_binding_edges:
                return {
                    **unavailable,
                    "clock_degradation_code": "clock_discontinuity",
                }
            span = after.node_stamp - before.node_stamp
            if span <= 1.0e-9:
                return unavailable
            fraction = (node_stamp - before.node_stamp) / span
            utc_value = before.utc_unix_seconds + fraction * (
                after.utc_unix_seconds - before.utc_unix_seconds
            )
            # A timezone transition always creates a discontinuity edge. Both
            # endpoints therefore share one exact context here.
            return {
                "utc_unix_s": utc_value,
                "local_time_iso8601": _format_local_time(
                    utc_value, before.utc_offset_seconds, milliseconds=True
                ),
                "timezone_id": before.timezone_id,
                "utc_offset_seconds": before.utc_offset_seconds,
                "clock_segment_index": sum(
                    edge < index
                    for edge in clock_evidence.discontinuity_binding_edges
                ),
                "clock_status": "INTERPOLATED_BETWEEN_BINDINGS",
                "clock_degradation_code": (
                    "clock_node_binding_interpolated"
                    if node_stamp not in {before.node_stamp, after.node_stamp}
                    else None
                ),
            }
    if node_stamp < bindings[0].node_stamp:
        edge = 0
        distance = bindings[0].node_stamp - node_stamp
        before, after = bindings[0], bindings[1]
    else:
        edge = len(bindings) - 2
        distance = node_stamp - bindings[-1].node_stamp
        before, after = bindings[-2], bindings[-1]
    if (
        edge in clock_evidence.discontinuity_binding_edges
        or distance > CLOCK_MAXIMUM_OUTER_EXTRAPOLATION_SECONDS
    ):
        return unavailable
    span = after.node_stamp - before.node_stamp
    if span <= 1.0e-9:
        return unavailable
    fraction = (node_stamp - before.node_stamp) / span
    utc_value = before.utc_unix_seconds + fraction * (
        after.utc_unix_seconds - before.utc_unix_seconds
    )
    context = before if node_stamp < bindings[0].node_stamp else after
    context_binding_index = 0 if node_stamp < bindings[0].node_stamp else len(bindings) - 1
    return {
        "utc_unix_s": utc_value,
        "local_time_iso8601": _format_local_time(
            utc_value, context.utc_offset_seconds, milliseconds=True
        ),
        "timezone_id": context.timezone_id,
        "utc_offset_seconds": context.utc_offset_seconds,
        "clock_segment_index": sum(
            discontinuity_edge < context_binding_index
            for discontinuity_edge in clock_evidence.discontinuity_binding_edges
        ),
        "clock_status": "BOUNDED_EDGE_EXTRAPOLATION",
        "clock_degradation_code": "clock_edge_extrapolated",
    }


def _format_local_time(
    utc_unix_seconds: float,
    utc_offset_seconds: int,
    *,
    milliseconds: bool,
) -> str:
    zone = timezone(timedelta(seconds=utc_offset_seconds))
    return datetime.fromtimestamp(utc_unix_seconds, timezone.utc).astimezone(
        zone
    ).isoformat(timespec="milliseconds" if milliseconds else "seconds")


def _algorithm_degradation_codes(report: dict[str, Any]) -> list[str]:
    codes = {
        str(item.get("code"))
        for gate_name in ("review_gate", "publish_gate")
        for item in report.get(gate_name, {}).get("blockers", [])
        if isinstance(item, dict) and item.get("code")
    }
    clock_codes = report.get("clock_evidence", {}).get("degradation_codes", [])
    if isinstance(clock_codes, list):
        codes.update(str(code) for code in clock_codes if code)
    return sorted(codes)


def calibrated_trajectory_rows(
    poses: Sequence[Pose],
    route_audit: dict[str, Any],
    constraints: Sequence[AbsoluteConstraint],
    *,
    clock_evidence: ClockEvidence | None = None,
    delivery_context: dict[str, Any] | None = None,
) -> list[dict[str, Any]]:
    delivery_context = delivery_context or {}
    clock_evidence = clock_evidence or ClockEvidence(
        (), (), frozenset(), frozenset(), ("clock_evidence_unbound_legacy",)
    )
    edge_ids = route_audit.get("edge_ids")
    corridor_ids = route_audit.get("corridor_ids")
    ambiguity_intervals = route_audit.get("ambiguity_intervals")
    ambiguous = [False] * len(poses)
    if isinstance(ambiguity_intervals, list):
        for interval in ambiguity_intervals:
            if not isinstance(interval, dict):
                continue
            try:
                start = max(0, int(interval.get("start_index")))
                end = min(len(poses) - 1, int(interval.get("end_index")))
            except (TypeError, ValueError):
                continue
            for index in range(start, end + 1):
                ambiguous[index] = True
    anchor_statuses = manual_anchor_statuses(poses, constraints)
    route_status = str(route_audit.get("status") or "unavailable")
    distance_scale_confidence = str(
        route_audit.get("distance_scale_confidence") or "high"
    )
    scale_segments = route_audit.get("reparameterization", {}).get("segments")
    rows: list[dict[str, Any]] = []
    for index, pose in enumerate(poses):
        distance_scale = None
        if isinstance(scale_segments, list):
            for segment in scale_segments:
                if not isinstance(segment, dict):
                    continue
                try:
                    if int(segment.get("start_index")) <= index <= int(
                        segment.get("end_index")
                    ):
                        distance_scale = segment.get("distance_scale")
                        break
                except (TypeError, ValueError):
                    continue
        corridor_identity_confidence = (
            "low" if ambiguous[index] else "resolved_within_draft"
        )
        rows.append(
            {
                "node_id": pose.node_id,
                "node_timebase_timestamp": pose.timestamp,
                **_clock_value_for_node_stamp(
                    clock_evidence, float(pose.timestamp)
                ),
                "x_m": pose.x,
                "y_m": pose.y,
                "yaw_rad": pose.yaw,
                "yaw_deg": math.degrees(pose.yaw),
                "yaw_source": "optimized_phone_pose",
                "position_source": delivery_context.get(
                    "position_source", "prior_map_offline_optimized"
                ),
                "route_edge_id": (
                    edge_ids[index]
                    if isinstance(edge_ids, list) and index < len(edge_ids)
                    else None
                ),
                "corridor_id": (
                    corridor_ids[index]
                    if isinstance(corridor_ids, list)
                    and index < len(corridor_ids)
                    else None
                ),
                "route_status": route_status,
                "route_confidence": (
                    "low"
                    if ambiguous[index] or distance_scale_confidence == "low"
                    else "resolved_within_draft"
                ),
                "corridor_identity_confidence": corridor_identity_confidence,
                "distance_scale": distance_scale,
                "distance_scale_confidence": distance_scale_confidence,
                "manual_anchor_status": anchor_statuses[index],
                "store_id": delivery_context.get("store_id"),
                "floor_id": delivery_context.get("floor_id"),
                "prior_map_id": delivery_context.get("prior_map_id"),
                "prior_map_package_sha256": delivery_context.get(
                    "prior_map_package_sha256"
                ),
                "canonical_source_sha256": delivery_context.get(
                    "canonical_source_sha256"
                ),
                "coordinate_contract_version": delivery_context.get(
                    "coordinate_contract_version"
                ),
                "input_identity_id": delivery_context.get("input_identity_id"),
                "position_confidence": (
                    "LOW"
                    if ambiguous[index]
                    or distance_scale_confidence == "low"
                    or delivery_context.get("result_quality_status")
                    != "COMPLETE"
                    else "REVIEWED_ALGORITHM_OUTPUT"
                ),
                "estimated_uncertainty_m": None,
                "uncertainty_source": "unavailable_not_fabricated",
                "quality_status": delivery_context.get(
                    "result_quality_status", "PARTIAL_REVIEW_REQUIRED"
                ),
                "publish_permitted": delivery_context.get(
                    "publish_permitted", False
                ),
                "algorithm_degradation_codes": json.dumps(
                    delivery_context.get("algorithm_degradation_codes", []),
                    ensure_ascii=False,
                    separators=(",", ":"),
                ),
            }
        )
    return rows


def write_calibrated_trajectory_exports(
    output: Path,
    poses: Sequence[Pose],
    route_audit: dict[str, Any],
    constraints: Sequence[AbsoluteConstraint],
    *,
    clock_evidence: ClockEvidence | None = None,
    delivery_context: dict[str, Any] | None = None,
    unavailable_intervals: Sequence[dict[str, Any]] = (),
) -> dict[str, Any]:
    """Write node-level and one-second calibrated phone coordinates.

    These tables are core immutable business results. A LOW_CONFIDENCE route
    remains exportable for diagnosis and human review; the publish gate still
    prohibits production publication, but no finite source node is discarded.
    """

    rows = calibrated_trajectory_rows(
        poses,
        route_audit,
        constraints,
        clock_evidence=clock_evidence,
        delivery_context=delivery_context,
    )
    fieldnames = [
        "node_id",
        "node_timebase_timestamp",
        "utc_unix_s",
        "local_time_iso8601",
        "timezone_id",
        "utc_offset_seconds",
        "clock_segment_index",
        "clock_status",
        "clock_degradation_code",
        "x_m",
        "y_m",
        "yaw_rad",
        "yaw_deg",
        "yaw_source",
        "position_source",
        "route_edge_id",
        "corridor_id",
        "route_status",
        "route_confidence",
        "corridor_identity_confidence",
        "distance_scale",
        "distance_scale_confidence",
        "manual_anchor_status",
        "store_id",
        "floor_id",
        "prior_map_id",
        "prior_map_package_sha256",
        "canonical_source_sha256",
        "coordinate_contract_version",
        "input_identity_id",
        "position_confidence",
        "estimated_uncertainty_m",
        "uncertainty_source",
        "quality_status",
        "publish_permitted",
        "algorithm_degradation_codes",
    ]
    with (output / "calibrated_positions_by_node.csv").open(
        "w", encoding="utf-8", newline=""
    ) as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)

    one_second: list[dict[str, Any]] = []
    mapped_rows = [row for row in rows if row["utc_unix_s"] is not None]
    mapped_utc_values = [float(row["utc_unix_s"]) for row in mapped_rows]
    if clock_evidence and len(clock_evidence.correlations) >= 2:
        first_second = math.ceil(
            float(clock_evidence.correlations[0]["utc_unix_seconds"])
        )
        last_second = math.floor(
            float(clock_evidence.correlations[-1]["utc_unix_seconds"])
        )
        cursor = 0
        correlation_context_index = 0
        for timestamp in range(first_second, last_second + 1):
            while (
                correlation_context_index + 1
                < len(clock_evidence.correlations)
                and float(
                    clock_evidence.correlations[
                        correlation_context_index + 1
                    ]["utc_unix_seconds"]
                )
                <= timestamp
            ):
                correlation_context_index += 1
            correlation_context = clock_evidence.correlations[
                correlation_context_index
            ]
            if not mapped_rows:
                offset = int(correlation_context["utc_offset_seconds"])
                one_second.append(
                    {
                        "timestamp_unix_s": timestamp,
                        "local_time_iso8601": _format_local_time(
                            float(timestamp), offset, milliseconds=False
                        ),
                        "timezone_id": correlation_context["timezone_id"],
                        "utc_offset_seconds": offset,
                        "clock_segment_index": None,
                        "x_m": None,
                        "y_m": None,
                        "yaw_rad": None,
                        "yaw_deg": None,
                        "yaw_source": None,
                        "position_source": (delivery_context or {}).get(
                            "position_source",
                            "prior_map_offline_optimized",
                        ),
                        "position_status": "UNAVAILABLE",
                        "position_degradation_code": (
                            "clock_mapping_insufficient_after_cross_check"
                        ),
                        "nearest_node_id": None,
                        "before_node_id": None,
                        "after_node_id": None,
                        "interpolation_ratio": None,
                        "route_edge_id": None,
                        "corridor_id": None,
                        "route_status": "unavailable",
                        "route_confidence": "low",
                        "corridor_identity_confidence": "low",
                        "distance_scale": None,
                        "distance_scale_confidence": "low",
                        "manual_anchor_status": "none",
                        **{
                            key: (
                                json.dumps(
                                    (delivery_context or {}).get(key, []),
                                    ensure_ascii=False,
                                    separators=(",", ":"),
                                )
                                if key == "algorithm_degradation_codes"
                                else (delivery_context or {}).get(key)
                            )
                            for key in (
                                "store_id", "floor_id", "prior_map_id",
                                "prior_map_package_sha256",
                                "canonical_source_sha256",
                                "coordinate_contract_version",
                                "input_identity_id", "position_confidence",
                                "estimated_uncertainty_m",
                                "uncertainty_source", "quality_status",
                                "publish_permitted",
                                "algorithm_degradation_codes",
                            )
                        },
                    }
                )
                continue
            # A session second can sit before the first or after the last
            # mapped node binding. Keep the row, but never use a negative or
            # >1 interpolation ratio to invent a position.
            if timestamp < mapped_utc_values[0]:
                before = after = mapped_rows[0]
            elif timestamp > mapped_utc_values[-1]:
                before = after = mapped_rows[-1]
            else:
                while (
                    cursor + 1 < len(mapped_rows)
                    and mapped_utc_values[cursor + 1] < timestamp
                ):
                    cursor += 1
                before = mapped_rows[cursor]
                after = mapped_rows[min(cursor + 1, len(mapped_rows) - 1)]
                # An exact node timestamp is authoritative even when the next
                # node is farther than the bounded interpolation window. Only
                # the unsupported interior seconds become UNAVAILABLE.
                if abs(float(before["utc_unix_s"]) - timestamp) <= 1.0e-9:
                    after = before
                elif abs(float(after["utc_unix_s"]) - timestamp) <= 1.0e-9:
                    before = after
            span = float(after["utc_unix_s"]) - float(before["utc_unix_s"])
            same_clock_segment = (
                before["clock_segment_index"] is not None
                and before["clock_segment_index"]
                == after["clock_segment_index"]
            )
            safe_span = (
                span >= 0
                and span <= POSITION_INTERPOLATION_MAXIMUM_GAP_SECONDS
                and float(before["utc_unix_s"]) <= timestamp
                and timestamp <= float(after["utc_unix_s"])
                and before["floor_id"] == after["floor_id"]
                and before["clock_status"] != "UNAVAILABLE"
                and after["clock_status"] != "UNAVAILABLE"
                and same_clock_segment
            )
            fraction = (
                0.0
                if span <= 1.0e-9
                else (timestamp - float(before["utc_unix_s"])) / span
            )
            target_node_stamp = float(before["node_timebase_timestamp"])
            if span > 1.0e-9:
                target_node_stamp += fraction * (
                    float(after["node_timebase_timestamp"])
                    - float(before["node_timebase_timestamp"])
                )
            interval_reason = next(
                (
                    str(interval.get("state") or "tracking_unavailable")
                    for interval in unavailable_intervals
                    if isinstance(interval, dict)
                    and _strict_number(interval.get("start_timestamp")) is not None
                    and _strict_number(interval.get("end_timestamp")) is not None
                    and float(interval["start_timestamp"])
                    <= target_node_stamp
                    <= float(interval["end_timestamp"])
                ),
                None,
            )
            if interval_reason is not None:
                safe_span = False
            nearest = before if fraction < 0.5 else after
            local_time = _format_local_time(
                float(timestamp),
                int(nearest["utc_offset_seconds"]),
                milliseconds=False,
            )
            base = {
                "timestamp_unix_s": timestamp,
                "local_time_iso8601": local_time,
                "timezone_id": nearest["timezone_id"],
                "utc_offset_seconds": nearest["utc_offset_seconds"],
                "clock_segment_index": nearest["clock_segment_index"],
                "nearest_node_id": nearest["node_id"],
                "before_node_id": before["node_id"],
                "after_node_id": after["node_id"],
                "interpolation_ratio": fraction if safe_span else None,
                "route_edge_id": nearest["route_edge_id"],
                "corridor_id": nearest["corridor_id"],
                "route_status": nearest["route_status"],
                "route_confidence": nearest["route_confidence"],
                "corridor_identity_confidence": nearest[
                    "corridor_identity_confidence"
                ],
                "distance_scale": nearest["distance_scale"],
                "distance_scale_confidence": nearest[
                    "distance_scale_confidence"
                ],
                "manual_anchor_status": nearest["manual_anchor_status"],
                "position_source": nearest["position_source"],
                **{
                    key: nearest[key]
                    for key in (
                        "store_id", "floor_id", "prior_map_id",
                        "prior_map_package_sha256", "canonical_source_sha256",
                        "coordinate_contract_version", "input_identity_id",
                        "position_confidence", "estimated_uncertainty_m",
                        "uncertainty_source", "quality_status",
                        "publish_permitted", "algorithm_degradation_codes",
                    )
                },
            }
            if not safe_span or not 0.0 <= fraction <= 1.0:
                one_second.append(
                    {
                        **base,
                        "x_m": None,
                        "y_m": None,
                        "yaw_rad": None,
                        "yaw_deg": None,
                        "yaw_source": None,
                        "position_status": "UNAVAILABLE",
                        "position_degradation_code": (
                            f"localization_state_{interval_reason}"
                            if interval_reason is not None
                            else
                            "clock_discontinuity"
                            if not same_clock_segment
                            else
                            "position_outside_mapped_node_span"
                            if timestamp < mapped_utc_values[0]
                            or timestamp > mapped_utc_values[-1]
                            else "position_interpolation_gap_above_3s"
                        ),
                    }
                )
                continue
            yaw = _normalize_angle(
                float(before["yaw_rad"])
                + fraction
                * _normalize_angle(
                    float(after["yaw_rad"]) - float(before["yaw_rad"])
                )
            )
            one_second.append(
                {
                    **base,
                    "x_m": float(before["x_m"])
                    + fraction * (float(after["x_m"]) - float(before["x_m"])),
                    "y_m": float(before["y_m"])
                    + fraction * (float(after["y_m"]) - float(before["y_m"])),
                    "yaw_rad": yaw,
                    "yaw_deg": math.degrees(yaw),
                    "yaw_source": "optimized_phone_pose",
                    "position_status": (
                        "LOW_CONFIDENCE"
                        if nearest["position_confidence"] == "LOW"
                        else "AVAILABLE"
                    ),
                    "position_degradation_code": None,
                }
            )
    one_second_fields = [
        "timestamp_unix_s",
        "local_time_iso8601",
        "timezone_id",
        "utc_offset_seconds",
        "clock_segment_index",
        "x_m",
        "y_m",
        "yaw_rad",
        "yaw_deg",
        "yaw_source",
        "position_source",
        "position_status",
        "position_degradation_code",
        "nearest_node_id",
        "before_node_id",
        "after_node_id",
        "interpolation_ratio",
        "route_edge_id",
        "corridor_id",
        "route_status",
        "route_confidence",
        "corridor_identity_confidence",
        "distance_scale",
        "distance_scale_confidence",
        "manual_anchor_status",
        "store_id",
        "floor_id",
        "prior_map_id",
        "prior_map_package_sha256",
        "canonical_source_sha256",
        "coordinate_contract_version",
        "input_identity_id",
        "position_confidence",
        "estimated_uncertainty_m",
        "uncertainty_source",
        "quality_status",
        "publish_permitted",
        "algorithm_degradation_codes",
    ]
    with (output / "calibrated_positions_1s.csv").open(
        "w", encoding="utf-8", newline=""
    ) as handle:
        writer = csv.DictWriter(handle, fieldnames=one_second_fields)
        writer.writeheader()
        writer.writerows(one_second)
    return {
        "node_count": len(rows),
        "one_second_row_count": len(one_second),
        "one_second_unavailable_count": sum(
            row["position_status"] == "UNAVAILABLE" for row in one_second
        ),
        "clock_unavailable_node_count": sum(
            row["clock_status"] == "UNAVAILABLE" for row in rows
        ),
    }


def write_calibrated_deliverables_manifest(
    output: Path,
    *,
    report: dict[str, Any],
    source_database_sha256: str,
    optimized_database_sha256: str,
    prior_map_package_sha256: str,
    canonical_source_sha256: str,
    trajectory_counts: dict[str, Any],
) -> dict[str, Any]:
    core_files = (
        "calibrated_positions_by_node.csv",
        "calibrated_positions_1s.csv",
        "localized_price_tags.json",
        "localized_price_tags.csv",
    )

    def csv_count(name: str) -> int:
        with (output / name).open("r", encoding="utf-8", newline="") as handle:
            return sum(1 for _ in csv.DictReader(handle))

    tag_source_count = int(report.get("tag_source_record_count", -1))
    tag_retained_count = int(report.get("tag_retained_count", -2))
    source_node_count = int(report.get("source_node_count", -1))
    exported_node_count = int(trajectory_counts.get("node_count", -2))
    if tag_source_count != tag_retained_count:
        raise OfflineLocalizationError(
            "Core deliverables lost one or more safely parsed tag records."
        )
    if source_node_count != exported_node_count:
        raise OfflineLocalizationError(
            "Core deliverables do not contain every source trajectory node."
        )
    if csv_count("calibrated_positions_by_node.csv") != exported_node_count:
        raise OfflineLocalizationError(
            "Node coordinate CSV row count differs from its source inventory."
        )
    if csv_count("localized_price_tags.csv") != tag_retained_count:
        raise OfflineLocalizationError(
            "Tag CSV row count differs from retained tag JSON."
        )
    manifest = {
        "format": "MarketScannerCalibratedDeliverablesManifest",
        "version": 1,
        "input_identity_id": report.get("input_identity_id"),
        "session_input_bundle_sha256": report.get(
            "session_input_bundle_sha256"
        ),
        "source_database_sha256": source_database_sha256,
        "optimized_database_sha256": optimized_database_sha256,
        "prior_map_id": report.get("prior_map_id"),
        "prior_map_package_sha256": prior_map_package_sha256,
        "canonical_source_sha256": canonical_source_sha256,
        "coordinate_contract_version": COORDINATE_CONTRACT_VERSION,
        "source_node_count": source_node_count,
        "exported_node_count": exported_node_count,
        "one_second_row_count": int(
            trajectory_counts.get("one_second_row_count", 0)
        ),
        "one_second_unavailable_count": int(
            trajectory_counts.get("one_second_unavailable_count", 0)
        ),
        "clock_unavailable_node_count": int(
            trajectory_counts.get("clock_unavailable_node_count", 0)
        ),
        "source_tag_count": tag_source_count,
        "retained_tag_count": tag_retained_count,
        "positioned_tag_count": int(report.get("tag_positioned_count", 0)),
        "unpositioned_tag_count": int(report.get("tag_unpositioned_count", 0)),
        "shelf_associated_tag_count": int(
            report.get("tag_shelf_associated_count", 0)
        ),
        "unassociated_tag_count": int(
            report.get("tag_unassociated_count", 0)
        ),
        "low_confidence_tag_count": int(
            report.get("tag_low_confidence_count", 0)
        ),
        "result_quality_status": report.get("result_quality_status"),
        "publish_permitted": report.get("publish_permitted") is True,
        "algorithm_degradation_codes": report.get(
            "algorithm_degradation_codes", []
        ),
        "files": [
            {
                "file": name,
                "bytes": (output / name).stat().st_size,
                "sha256": _sha256(output / name),
                "row_count": (
                    csv_count(name)
                    if name.endswith(".csv")
                    else tag_retained_count
                ),
            }
            for name in core_files
        ],
    }
    _json_write(output / "calibrated_deliverables_manifest.json", manifest)
    return manifest


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
        for key in ("timestamps", "node_ids", "yaws_rad"):
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
    tag["quality_status"] = "LOW_CONFIDENCE"
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
        tag["quality_status"] = "LOW_CONFIDENCE"
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
    if tag.get("needs_review") is not True:
        tag["quality_status"] = "ACCEPTED"
    return tag


def _apply_on_device_confirmation_authority(
    tag: dict[str, Any],
) -> dict[str, Any]:
    """Map additive v2 operator evidence to the derived business fields.

    The immutable ``algorithm_*`` fields remain untouched. Only the derived
    PC output's legacy business columns follow the explicit on-device choice.
    """

    if tag.get("version") != 2 or tag.get("user_confirmed") is not True:
        return tag
    tag["final_shelf_segment_id"] = tag.get(
        "user_confirmed_shelf_segment_id"
    )
    tag["shelf_code"] = tag.get("user_confirmed_shelf_code")
    tag["shelf_side"] = tag.get("user_confirmed_side")
    tag["distance_from_shelf_start_cm"] = tag.get(
        "user_confirmed_distance_from_shelf_start_cm"
    )
    tag["final_business_association_source"] = "on_device_operator"
    return tag


def _enforce_on_device_confirmation_conflict(
    tag: dict[str, Any],
) -> dict[str, Any]:
    """Never silently replace an operator shelf with offline reassociation."""

    if tag.get("version") != 2:
        return tag
    audit = tag.get("association_audit")
    candidates = audit.get("candidates") if isinstance(audit, dict) else None
    best = candidates[0] if isinstance(candidates, list) and candidates else None
    user_segment = tag.get("user_confirmed_shelf_segment_id")
    user_side = tag.get("user_confirmed_side")
    if (
        not isinstance(best, dict)
        or audit.get("offline_evidence_reliable") is not True
    ):
        _mark_tag_for_review(tag, "price_tag_offline_association_unavailable")
        tag["confirmation_conflict"] = {
            "code": "OFFLINE_ASSOCIATION_UNAVAILABLE",
            "disposition": "REVIEW_REQUIRED",
            "rescan_required": True,
            "user_shelf_segment_id": user_segment,
            "user_side": user_side,
        }
        return enforce_tag_state_invariants(tag)
    optimized_segment = best.get("element_id")
    optimized_side = best.get("edge_id")
    if optimized_segment == user_segment and optimized_side == user_side:
        audit["offline_association_status"] = audit.get("status")
        audit["status"] = "user_confirmation_consistent"
        tag["confirmation_conflict"] = {
            "code": "NO_CONFLICT",
            "disposition": "CONFIRMED",
            "rescan_required": False,
            "user_shelf_segment_id": user_segment,
            "user_side": user_side,
            "optimized_shelf_segment_id": optimized_segment,
            "optimized_side": optimized_side,
        }
        return enforce_tag_state_invariants(tag)
    _mark_tag_for_review(tag, "price_tag_confirmation_conflict")
    audit["offline_association_status"] = audit.get("status")
    audit["status"] = "price_tag_confirmation_conflict"
    tag["confirmation_conflict"] = {
        "code": "USER_CONFIRMATION_CONFLICT",
        "disposition": "REVIEW_REQUIRED",
        "rescan_required": True,
        "user_shelf_segment_id": user_segment,
        "user_side": user_side,
        "optimized_shelf_segment_id": optimized_segment,
        "optimized_side": optimized_side,
    }
    return enforce_tag_state_invariants(tag)


def _finalize_tag_with_unavailable_offline_association(
    tag: dict[str, Any],
    reason: str,
) -> dict[str, Any]:
    """Emit one stable fail-closed audit when reassociation cannot run.

    Defensive transform/binding failures must not bypass the additive v2
    confirmation adjudicator.  Keeping the audit shape identical for every
    early exit makes the operator decision immutable while giving downstream
    review and rescan tooling one machine-readable unavailable outcome.
    """

    tag["association_audit"] = {
        "status": "not_attempted",
        "reason": reason,
        "offline_evidence_reliable": False,
        "candidate_search_complete": False,
        "candidate_count": 0,
        "candidates": [],
    }
    return enforce_tag_state_invariants(
        _enforce_on_device_confirmation_conflict(tag)
    )


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

    offline_evidence_reliable = (
        has_camera
        and best_distance <= 0.45
        and ray_clear
        and visible_side_consistent
        and not near_endpoint
        and second is not None
        and margin >= min_margin
        and loc_conf >= min_auto_confidence
        and meas_conf >= min_auto_confidence
    )
    can_auto_confirm = (
        offline_evidence_reliable
        and not human_authoritative
        and tag.get("needs_review") is not True
    )

    if can_auto_confirm:
        tag.update(
            {
                "final_shelf_segment_id": best_element.get("id") or None,
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
            "shelf_segment_id": best_element.get("id") or None,
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
            if tag.get("version") != 2:
                current = (
                    tag.get("shelf_code"),
                    tag.get("shelf_side"),
                    tag.get("distance_from_shelf_start_cm"),
                )
                suggested = (
                    tag["suggested_association"].get("shelf_code"),
                    tag["suggested_association"].get("shelf_side"),
                    tag["suggested_association"].get(
                        "distance_from_shelf_start_cm"
                    ),
                )
                same_business_edge = current[:2] == suggested[:2]
                try:
                    offset_difference_cm = abs(
                        float(current[2]) - float(suggested[2])
                    )
                except (TypeError, ValueError):
                    offset_difference_cm = math.inf
                if not same_business_edge or offset_difference_cm > 1.0:
                    _mark_tag_for_review(
                        tag,
                        "human_association_conflicts_with_offline_evidence",
                    )
            # Additive v2 on-device confirmation is adjudicated exactly once
            # by `_enforce_on_device_confirmation_conflict` after this audit
            # is complete. Do not pre-mark a consistent confirmation merely
            # because it is intentionally ineligible for auto-confirmation.
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
        "offline_evidence_reliable": offline_evidence_reliable,
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
        yaw_value = _strict_number(value.get("yaw_rad"))
        if (
            yaw_value is None
            or yaw_value <= -math.pi
            or yaw_value > math.pi
        ):
            raise OfflineLocalizationError(
                "set_anchor yaw_rad must use canonical (-pi, pi] range."
            )
        allowed_anchor_fields = {
            "timestamp",
            "node_id",
            "floor_id",
            "coordinate_contract_version",
            "x_m",
            "y_m",
            "yaw_rad",
        }
        if set(value) - allowed_anchor_fields:
            raise OfflineLocalizationError("set_anchor contains unknown fields.")
        node_id = value.get("node_id")
        coordinate_version = value.get("coordinate_contract_version")
        floor_id = value.get("floor_id")
        exact_fields_present = any(
            field in value
            for field in ("node_id", "floor_id", "coordinate_contract_version")
        )
        if exact_fields_present and (
            isinstance(node_id, bool)
            or not isinstance(node_id, int)
            or node_id <= 0
            or not isinstance(floor_id, str)
            or not floor_id
            or isinstance(coordinate_version, bool)
            or coordinate_version != COORDINATE_CONTRACT_VERSION
        ):
            raise OfflineLocalizationError(
                "set_anchor exact node/floor/coordinate contract is invalid."
            )
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
    upstream_processing_report: dict[str, Any] | None = None,
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
    expected_hash = metadata.get("priorMapSha256")
    map_identity_binding = _resolve_session_prior_map_identity(
        metadata, manifest, package_manifest
    )
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
    verified_burst_observation_ids = (
        input_snapshot.verified_burst_observation_ids
    )
    verified_burst_frame_authorities = (
        input_snapshot.verified_burst_frame_authorities
    )
    tag_evidence_degradations = list(
        input_snapshot.tag_evidence_degradations
    )
    verified_burst_identities = {
        str(burst.get("burst_id") or ""): (
            str(burst.get("barcode") or ""),
            str(burst.get("symbology") or ""),
        )
        for burst in input_snapshot.jsonl_values.get(
            "tag_observation_bursts.jsonl", []
        )
    }
    raw_tags = _read_localized_price_tags_bytes(
        input_snapshot.localized_tags_bytes,
        session_id=sidecar_session_id,
        expected_map_id=str(manifest.get("prior_map_id") or ""),
        expected_map_hash=sidecar_map_hash,
        expected_floor_id=sidecar_floor_id,
        expected_count=localized_tag_count,
        verified_burst_observation_ids=verified_burst_observation_ids,
        verified_burst_identities=verified_burst_identities,
        degradations=tag_evidence_degradations,
    )
    if len(raw_tags) != localized_tag_count:
        raise OfflineLocalizationError(
            "One or more finalized tag records has no recoverable durable business identity."
        )
    recovered_missing_burst_tag_count = _append_missing_durable_burst_tags(
        raw_tags,
        input_snapshot.durable_tag_bursts,
        expected_map_id=str(manifest.get("prior_map_id") or ""),
        expected_map_hash=sidecar_map_hash,
        expected_floor_id=sidecar_floor_id,
        expected_tracking_session_id=sidecar_session_id,
        degradations=tag_evidence_degradations,
    )
    source_tag_count = (
        localized_tag_count + recovered_missing_burst_tag_count
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
    if input_manifest_version in {2, 3, 4}:
        if (
            isinstance(recovery_watermark, bool)
            or not isinstance(recovery_watermark, int)
            or recovery_watermark < 0
        ):
            raise OfflineLocalizationError(
                "Recovery-bound input manifests require the recovery lifecycle watermark."
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
        recovery_evidence_binding = RECOVERY_EVIDENCE_BOUND_V2
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
        "clock_correlations": input_snapshot.jsonl_diagnostics.get(
            "clock_correlations.jsonl", {}
        ),
        "localization_trace": trace_diag,
        "localization_constraints": constraint_diag,
        "manual_localization_events": manual_diag,
        "tag_observations": obs_diag,
        "tag_observation_bursts": input_snapshot.jsonl_diagnostics.get(
            "tag_observation_bursts.jsonl",
            {},
        ),
        "localization_events": state_diag,
        "localization_recovery_events": recovery_diag,
        "tag_evidence_degradations": tag_evidence_degradations,
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
    relative_trajectory_authority = str(
        replay_parameters["relative_trajectory_authority"]
    )
    raw_manual_anchor_recovery = (
        relative_trajectory_authority
        == "raw_continuous_vio_manual_anchor_recovery"
    )
    raw_diagnostic_recovery = (
        relative_trajectory_authority
        == "raw_continuous_vio_diagnostic_recovery"
    )
    partial_graph_recovery = (
        relative_trajectory_authority
        == "partial_rtabmap_graph_continuous_vio_recovery"
    )
    raw_vio_recovery = (
        raw_manual_anchor_recovery
        or raw_diagnostic_recovery
        or partial_graph_recovery
    )

    constraints: list[AbsoluteConstraint] = []
    constraint_records: list[dict[str, Any]] = []
    # The selected start and heading are the only map-frame information that
    # exists even when online structure matching produced no accepted frame.
    # Keep it as an explicit, moderately uncertain factor instead of merely
    # pre-aligning the first pose.  This lets long routes distribute drift
    # correction through the full relative graph while exposing the operator
    # uncertainty in the report.
    metadata_initial = _pose_from(metadata.get("initialMapPose"))
    if metadata_initial is not None and baseline:
        constraints.append(
            AbsoluteConstraint(
                identifier="initial-map-pose-000001",
                node_index=0,
                x=metadata_initial[0],
                y=metadata_initial[1],
                yaw=metadata_initial[2],
                weight=1.0 / (INITIAL_MAP_POSE_TRANSLATION_SIGMA_M ** 2),
                kind="initial_map_pose",
                source={
                    "uncertainty_source": "operator_selected_initial_pose_policy_v1",
                    "metadata_key": "initialMapPose",
                },
                translation_sigma_m=INITIAL_MAP_POSE_TRANSLATION_SIGMA_M,
                yaw_sigma_rad=INITIAL_MAP_POSE_YAW_SIGMA_RAD,
                trusted_absolute=True,
            )
        )
        constraint_records.append(
            {
                "constraint_id": "initial-map-pose-000001",
                "kind": "initial_map_pose",
                "status": "accepted",
                "node_index": 0,
                "uncertainty_source": "operator_selected_initial_pose_policy_v1",
                "translation_sigma_m": INITIAL_MAP_POSE_TRANSLATION_SIGMA_M,
                "yaw_sigma_deg": math.degrees(INITIAL_MAP_POSE_YAW_SIGMA_RAD),
            }
        )
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
        trusted_absolute = (
            record.get("version") == 3
            and binding.binding_source == "nearest_node_id"
            and record.get("node_binding_status") == "matched"
        )
        constraints.append(
            AbsoluteConstraint(
                identifier=identifier,
                node_index=binding.node_index,
                x=pose[0],
                y=pose[1],
                yaw=pose[2],
                weight=(MANUAL_ANCHOR_WEIGHT if trusted_absolute else 80.0),
                kind="manual_anchor",
                source=record,
                translation_sigma_m=(
                    MANUAL_ANCHOR_TRANSLATION_SIGMA_M
                    if trusted_absolute
                    else None
                ),
                yaw_sigma_rad=(
                    MANUAL_ANCHOR_YAW_SIGMA_RAD
                    if trusted_absolute
                    else None
                ),
                trusted_absolute=trusted_absolute,
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
                "trusted_absolute": trusted_absolute,
                "trust_class": (
                    "verified_v3_exact_node_absolute_anchor"
                    if trusted_absolute
                    else "legacy_or_timestamp_bound_manual_evidence"
                ),
                "translation_sigma_m": (
                    MANUAL_ANCHOR_TRANSLATION_SIGMA_M
                    if trusted_absolute
                    else None
                ),
                "yaw_sigma_deg": (
                    math.degrees(MANUAL_ANCHOR_YAW_SIGMA_RAD)
                    if trusted_absolute
                    else None
                ),
                "absolute_residual_is_physical_jump": (
                    False if trusted_absolute else None
                ),
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
        exact_node_bound = (
            isinstance(value.get("node_id"), int)
            and not isinstance(value.get("node_id"), bool)
            and value.get("coordinate_contract_version")
            == COORDINATE_CONTRACT_VERSION
            and str(value.get("floor_id") or "")
            == str(metadata.get("floorId") or metadata.get("floor_id") or "")
        )
        node_index = _nearest_pose_index(
            baseline,
            float(timestamp) if timestamp is not None else None,
        )
        if exact_node_bound and baseline[node_index].node_id != value["node_id"]:
            raise OfflineLocalizationError(
                "PC manual anchor exact node changed during replay."
            )
        constraints.append(
            AbsoluteConstraint(
                identifier=str(event.get("event_id") or "manual-edit-anchor"),
                node_index=node_index,
                x=pose[0],
                y=pose[1],
                yaw=pose[2],
                weight=(MANUAL_ANCHOR_WEIGHT if exact_node_bound else 100.0),
                kind="manual_anchor",
                source=event,
                translation_sigma_m=(
                    MANUAL_ANCHOR_TRANSLATION_SIGMA_M
                    if exact_node_bound else None
                ),
                yaw_sigma_rad=(
                    MANUAL_ANCHOR_YAW_SIGMA_RAD
                    if exact_node_bound else None
                ),
                trusted_absolute=exact_node_bound,
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
    corridor_match_audit: list[dict[str, Any]] = []
    # A long scan needs one route-level hypothesis.  Feeding the legacy
    # corridor orientation field and point-to-corridor soft priors into the
    # preliminary factor graph first can rotate or translate the map hints
    # across shelves before the hard free-space matcher runs.  Keep those
    # bounded priors only for short compatibility sessions; long sessions are
    # solved below from gauge-neutral physical motion, exact manual anchors,
    # road connectivity and occupied-structure collision checks.
    if len(baseline) < 64:
        constraints.extend(
            build_road_soft_constraints(
                baseline,
                road_graph_payload,
                str(metadata.get("floorId") or metadata.get("floor_id") or ""),
                match_audit=corridor_match_audit,
            )
        )
    # Exact node-bound operator evidence is the highest-trust map-frame input.
    # Corridor identity is periodic and remains a soft automatic hypothesis;
    # it must not dilute a verified manual anchor or move a confirmed tag
    # fixture merely because a nearby parallel aisle is geometrically valid.
    if (trusted_manual_anchor_count := sum(
        item.kind == "manual_anchor" and item.trusted_absolute
        for item in constraints
    )) and len(baseline) < 64:
        constraints = [
            item
            for item in constraints
            if item.kind not in {"road_heading_soft", "road_soft"}
        ]
        corridor_match_audit = []
    if raw_manual_anchor_recovery and trusted_manual_anchor_count == 0:
        raise OfflineLocalizationError(
            "Raw continuous VIO recovery requires at least one verified manual anchor."
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
    continuity_fallback_reason: str | None = None
    if raw_vio_recovery and full_factor_graph and (
        solver_metrics["maximum_neighbor_correction_translation_change_m"] > 1.0
        or solver_metrics["maximum_neighbor_correction_yaw_change_deg"] > 30.0
    ):
        # Preserve the complete native report, but do not export a graph that
        # violated the physically continuous recovered baseline. Automatic map
        # priors are weaker than continuity. The bounded field is finite,
        # continuous and remains explicitly draft/review only.
        native_factor_graph_report = dict(factor_graph_report)
        optimized, accepted, rejected = optimize_trajectory(
            baseline, constraints
        )
        solver_metrics = bounded_correction_metrics(
            baseline, optimized, constraints
        )
        full_factor_graph = False
        continuity_fallback_reason = (
            "native_graph_violated_recovered_physical_continuity"
        )
        factor_graph_report = {
            **native_factor_graph_report,
            "full_factor_graph": False,
            "published_capable": False,
            "continuity_fallback_applied": True,
            "continuity_fallback_reason": continuity_fallback_reason,
            "native_graph_preserved_for_audit": True,
            "review_trajectory_solver": "bounded_correction_field_banded_v3",
        }
    graph_quality_passed = factor_graph_report.get("graph_quality_passed") is True
    factor_graph_published_capable = (
        full_factor_graph
        and graph_quality_passed
        and factor_graph_report.get("published_capable") is True
    )

    gauge_neutral_trace, gauge_neutral_trace_audit = (
        reconstruct_gauge_neutral_trace(trace, manual_events)
    )
    gauge_neutral_nodes = resample_pose_sequence(
        gauge_neutral_trace, baseline
    )
    corridor_route_audit: dict[str, Any] = {
        "format": "MarketScannerCorridorRouteMatchAudit",
        "version": 1,
        "matcher": "not_run",
        "status": "unavailable",
        "reason": "gauge_neutral_trace_unavailable",
    }
    # Very short sessions do not establish a route-level hypothesis.  Keeping
    # their original SE(2) result also preserves exact synthetic/inspection
    # semantics and prevents periodic aisles from creating false confidence.
    if (
        len(baseline) >= 64
        and gauge_neutral_nodes
        and len(gauge_neutral_nodes) == len(baseline)
    ):
        shelves_payload = load_json(prior_map / "shelves.json")
        structures_payload = load_json(prior_map / "fixed_structures.json")
        floor_id = str(metadata.get("floorId") or metadata.get("floor_id") or "")
        route_anchors = [
            RouteAnchor(
                index=item.node_index,
                x=item.x,
                y=item.y,
                translation_sigma_m=(
                    item.translation_sigma_m
                    if item.translation_sigma_m is not None
                    else MANUAL_ANCHOR_TRANSLATION_SIGMA_M
                ),
                identifier=item.identifier,
            )
            for item in constraints
            if item.kind == "manual_anchor" and item.trusted_absolute
        ]
        route_match = match_corridor_route(
            gauge_neutral_nodes,
            optimized,
            road_graph_payload,
            floor_id,
            obstacle_polygons(
                shelves_payload, structures_payload, floor_id
            ),
            route_anchors,
        )
        if route_match is not None:
            optimized = [
                Pose(
                    node_id=baseline[index].node_id,
                    timestamp=baseline[index].timestamp,
                    x=route_pose.x,
                    y=route_pose.y,
                    yaw=route_pose.yaw,
                )
                for index, route_pose in enumerate(route_match.poses)
            ]
            corridor_route_audit = {
                **route_match.audit,
                "status": "matched_low_confidence"
                if route_match.audit.get("route_confidence") == "low"
                else "matched",
            }
            solver_metrics = bounded_correction_metrics(
                baseline, optimized, constraints
            )
            solver_metrics["continuity_gate_authority"] = (
                "gauge_neutral_free_space_road_route"
            )
            solver_metrics["legacy_correction_gradient_is_diagnostic_only"] = True
            full_factor_graph = False
            factor_graph_published_capable = False
            continuity_fallback_reason = (
                "free_space_corridor_route_review_draft"
            )
            factor_graph_report = {
                **factor_graph_report,
                "full_factor_graph": False,
                "published_capable": False,
                "corridor_route_review_applied": True,
                "corridor_route_matcher": corridor_route_audit.get("matcher"),
                "review_trajectory_solver": (
                    "gauge_neutral_physical_motion_plus_free_space_road_route_v1"
                ),
            }
        else:
            corridor_route_audit = {
                **corridor_route_audit,
                "reason": "no_connected_collision_free_route_hypothesis",
            }

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
        tag = _apply_on_device_confirmation_authority(dict(tag))
        observation = observations_by_id.get(str(tag.get("observation_id")))
        try:
            verified_burst_frame = None
            # Manifest v3 means the session contains verified burst evidence;
            # it does not retroactively convert every historical v1 tag in the
            # same finalized file into a burst-bound v2 confirmation. Only v2
            # tags use the complete burst frame as their exact node authority.
            if input_manifest_version in {3, 4} and tag.get("version") == 2:
                verified_burst_frame = verified_burst_frame_authorities.get(
                    str(tag.get("observation_id") or "")
                )
                if verified_burst_frame is None:
                    raise OfflineLocalizationError(
                        "tag_observation_verified_burst_frame_missing"
                    )
            binding = bind_tag_observation_to_pose(
                baseline,
                observation,
                tag=tag,
                expected_tracking_session_id=expected_tracking_session_id,
                expected_map_hashes=expected_map_hashes,
                expected_floor_id=expected_floor_id,
                maximum_time_delta_seconds=max_node_time_delta_seconds,
                verified_burst_frame=verified_burst_frame,
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
            final_tags.append(
                _finalize_tag_with_unavailable_offline_association(
                    tag,
                    "tag_pose_binding_failed",
                )
            )
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
            final_tags.append(
                _finalize_tag_with_unavailable_offline_association(
                    tag,
                    "tag_raw_map_position_missing",
                )
            )
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
            final_tags.append(
                _finalize_tag_with_unavailable_offline_association(
                    tag,
                    "tag_raw_map_position_invalid",
                )
            )
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
        associated = _associate_tag(
            tag,
            elements,
            (optimized_node.x, optimized_node.y),
        )
        final_tags.append(
            _enforce_on_device_confirmation_conflict(associated)
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
    accepted_trusted_manual_anchor_count = sum(
        item["kind"] == "manual_anchor"
        and item.get("trusted_absolute") is True
        for item in accepted
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
    review_items.extend(
        {
            "id": f"tag-evidence-{index:06d}",
            "type": "tag_evidence_degradation",
            "severity": "warning",
            "message": "局部价签证据不完整；条码已保留为低置信度结果。",
            "object_id": item.get("tag_id"),
            "details": item,
        }
        for index, item in enumerate(tag_evidence_degradations, start=1)
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
    # Any successfully produced finite trajectory is a reviewable draft. Large
    # corrections, partial graph quality and tag degradations remain explicit
    # review/publication blockers, but must not turn a safely committed result
    # back into a generic processing failure. Framing/identity/database damage
    # and an empty/non-finite trajectory fail earlier and never reach commit.
    # Explicit diagnostic mode still marks the result diagnostic-only; it does
    # not weaken any review or publication gate.
    diagnostic_mode = bool(replay_parameters["diagnostic_mode"])
    diagnostic_only = diagnostic_mode or raw_vio_recovery
    allow_draft = bool(optimized) and not has_critical_jsonl_damage
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
        "floor_id": str(metadata.get("floorId") or metadata.get("floor_id") or ""),
        "prior_map_sha256": package_hash,
        "prior_map_identity_binding": map_identity_binding,
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
        "accepted_trusted_manual_anchor_count": (
            accepted_trusted_manual_anchor_count
        ),
        "road_soft_constraint_count": sum(
            item["kind"] == "road_soft" for item in accepted
        ),
        "road_heading_soft_constraint_count": sum(
            item["kind"] == "road_heading_soft" for item in accepted
        ),
        "corridor_sequence_match": {
            "format": "MarketScannerCorridorSequenceMatchAudit",
            "version": 2,
            "matcher": "continuous_corridor_sequence_v2",
            "sample_count": len(corridor_match_audit),
            "matched_sample_count": sum(
                item["status"] == "matched" for item in corridor_match_audit
            ),
            "ambiguous_sample_count": sum(
                item["status"] == "ambiguous_low_confidence"
                for item in corridor_match_audit
            ),
            "unmatched_sample_count": sum(
                item["status"] == "unmatched" for item in corridor_match_audit
            ),
            "samples": corridor_match_audit,
        },
        "gauge_neutral_physical_trace": gauge_neutral_trace_audit,
        "corridor_route_match": corridor_route_audit,
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
        "trusted_manual_anchor_count": trusted_manual_anchor_count,
        "absolute_correction_interpretation": (
            "verified_manual_anchor_map_gauge_correction"
            if accepted_trusted_manual_anchor_count > 0
            else "ordinary_local_trajectory_update"
        ),
        "manual_localization_event_audit": manual_event_audit,
        "tag_total": len(final_tags),
        "tag_source_record_count": source_tag_count,
        "localized_tag_source_record_count": localized_tag_count,
        "durable_burst_missing_final_tag_count": (
            recovered_missing_burst_tag_count
        ),
        "tag_retained_count": len(final_tags),
        "tag_positioned_count": sum(
            isinstance(tag.get("final_map_position"), dict)
            for tag in final_tags
        ),
        "tag_unpositioned_count": sum(
            not isinstance(tag.get("final_map_position"), dict)
            for tag in final_tags
        ),
        "tag_shelf_associated_count": sum(
            bool(tag.get("shelf_code"))
            and bool(
                tag.get("final_shelf_segment_id")
                or tag.get("shelf_segment_id")
                or tag.get("algorithm_shelf_segment_id")
                or tag.get("user_confirmed_shelf_segment_id")
            )
            for tag in final_tags
        ),
        "tag_unassociated_count": sum(
            not bool(tag.get("shelf_code"))
            or not bool(
                tag.get("final_shelf_segment_id")
                or tag.get("shelf_segment_id")
                or tag.get("algorithm_shelf_segment_id")
                or tag.get("user_confirmed_shelf_segment_id")
            )
            for tag in final_tags
        ),
        "tag_low_confidence_count": sum(
            tag.get("quality_status") == "LOW_CONFIDENCE"
            for tag in final_tags
        ),
        "tag_evidence_degradation_count": len(tag_evidence_degradations),
        "tag_evidence_degradations": tag_evidence_degradations,
        "tag_confirmed": sum(tag.get("approval_status") in {"approved", "auto_approved"} for tag in final_tags),
        "tag_needs_review": needs_review_count,
        "mean_association_confidence": (
            sum(float(tag.get("association_confidence", 0)) for tag in final_tags)
            / max(1, len(final_tags))
        ),
        "publish_state": "draft" if allow_draft else "invalid",
        "result_quality_status": (
            "PARTIAL_REVIEW_REQUIRED"
            if tag_evidence_degradations or needs_review_count
            else "COMPLETE"
        ),
        "partial_result": bool(tag_evidence_degradations or needs_review_count),
        "allow_draft": allow_draft,
        "diagnostic_mode": diagnostic_mode,
        "diagnostic_only": diagnostic_only,
        "relative_trajectory_authority": relative_trajectory_authority,
        "rtabmap_global_graph_incomplete": bool(
            replay_parameters["rtabmap_global_graph_incomplete"]
        ),
        "manual_anchor_recovery": raw_manual_anchor_recovery,
        "raw_vio_diagnostic_recovery": raw_diagnostic_recovery,
        "partial_rtabmap_graph_continuous_vio_recovery": partial_graph_recovery,
        "initial_map_pose_constraint_count": factor_graph_report.get(
            "initial_map_pose_constraint_count", 0
        ),
        "upstream_processing": upstream_processing_report,
        "ignored_conflicting_source_constraint_count": sum(
            item.get("kind") == "online_structure" for item in rejected
        ),
        "warnings": [],
        "rejection_reasons": sorted({item["reason"] for item in rejected}),
        "solver": {
            "type": (
                "relative_se2_factor_graph"
                if full_factor_graph
                else (
                    "gauge_neutral_free_space_road_route"
                    if corridor_route_audit.get("status")
                    in {"matched", "matched_low_confidence"}
                    else "bounded_correction_field"
                )
            ),
            "full_factor_graph": full_factor_graph,
            "graph_integrity_passed": factor_graph_report.get("graph_integrity_passed") is True,
            "graph_quality_passed": graph_quality_passed,
            "quality_policy": factor_graph_report.get("quality_policy"),
            "published_capable": factor_graph_published_capable,
            "limitation": (
                None
                if full_factor_graph
                else (
                    "The final review trajectory is reconstructed from gauge-neutral physical motion, strict manual map anchors, connected road topology, and shelf/fixed-structure free-space constraints. The native factor graph remains available for audit; this route is a non-publishable review draft."
                    if corridor_route_audit.get("status")
                    in {"matched", "matched_low_confidence"}
                    else (
                        "The native relative SE(2) graph violated recovered physical continuity; its report was preserved, and a continuous bounded correction field is used for draft/review only."
                        if continuity_fallback_reason
                        == "native_graph_violated_recovered_physical_continuity"
                        else "The native relative SE(2) graph was unavailable or failed; bounded correction is draft/review only."
                    )
                )
            ),
            "continuity_fallback_reason": continuity_fallback_reason,
            "native_solver": factor_graph_report.get("solver"),
            "factor_set_sha256": factor_graph_report.get("factor_set_sha256"),
            "huber_translation_m": HUBER_TRANSLATION_M,
            "huber_yaw_deg": math.degrees(HUBER_YAW_RAD),
            "relative_trajectory_authority": relative_trajectory_authority,
            "rtabmap_global_graph_incomplete": bool(
                replay_parameters["rtabmap_global_graph_incomplete"]
            ),
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
        (
            accepted_trusted_manual_anchor_count > 0
            or raw_vio_recovery
            or max_correction <= 2.0,
            "maximum_correction_above_2m",
            max_correction,
        ),
        (
            accepted_trusted_manual_anchor_count > 0
            or raw_vio_recovery
            or correction_p95 <= 1.0,
            "p95_correction_above_1m",
            correction_p95,
        ),
        (
            corridor_route_audit.get("status")
            in {"matched", "matched_low_confidence"}
            or solver_metrics[
                "maximum_neighbor_correction_translation_change_m"
            ] <= 0.5,
            "neighbor_correction_gradient_above_0_5m",
            solver_metrics[
                "maximum_neighbor_correction_translation_change_m"
            ],
        ),
        (
            corridor_route_audit.get("status")
            in {"matched", "matched_low_confidence"}
            or solver_metrics[
                "maximum_neighbor_correction_yaw_change_deg"
            ] <= 15.0,
            "neighbor_correction_yaw_gradient_above_15deg",
            solver_metrics[
                "maximum_neighbor_correction_yaw_change_deg"
            ],
        ),
        (
            corridor_route_audit.get("status")
            in {"matched", "matched_low_confidence"},
            "corridor_route_match_unavailable",
            corridor_route_audit.get("reason"),
        ),
        (
            corridor_route_audit.get("point_obstacle_penetration_count") == 0,
            "corridor_route_obstacle_penetration_present",
            corridor_route_audit.get("point_obstacle_penetration_count"),
        ),
        (
            corridor_route_audit.get("obstacle_crossing_segment_count") == 0,
            "corridor_route_obstacle_crossing_present",
            corridor_route_audit.get("obstacle_crossing_segment_count"),
        ),
        (
            corridor_route_audit.get("topological_discontinuity_count") == 0,
            "corridor_route_topological_discontinuity_present",
            corridor_route_audit.get("topological_discontinuity_count"),
        ),
        (
            float(corridor_route_audit.get("maximum_step_m") or math.inf)
            <= float(corridor_route_audit.get("maximum_physical_step_m") or 0.0)
            + 0.25,
            "corridor_route_nonphysical_step_present",
            {
                "route_maximum_step_m": corridor_route_audit.get(
                    "maximum_step_m"
                ),
                "physical_maximum_step_m": corridor_route_audit.get(
                    "maximum_physical_step_m"
                ),
            },
        ),
        (
            float(
                corridor_route_audit.get("maximum_distance_scale_deviation")
                or 0.0
            )
            <= 0.05,
            "corridor_route_distance_scale_above_5pct",
            {
                "maximum_distance_scale_deviation": corridor_route_audit.get(
                    "maximum_distance_scale_deviation"
                ),
                "reparameterization": corridor_route_audit.get(
                    "reparameterization"
                ),
            },
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
    if diagnostic_only:
        publish_blockers.insert(
            0,
            {
                "code": (
                    "raw_continuous_vio_manual_anchor_recovery"
                    if raw_manual_anchor_recovery
                    else (
                        "raw_continuous_vio_diagnostic_recovery"
                        if raw_diagnostic_recovery
                        else (
                            "partial_rtabmap_graph_continuous_vio_recovery"
                            if partial_graph_recovery
                            else "diagnostic_mode_enabled"
                        )
                    )
                ),
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
    report["publish_permitted"] = report["publish_gate"]["passed"]
    report["clock_evidence"] = {
        **input_snapshot.jsonl_diagnostics.get("clock_correlations.jsonl", {}),
        "degradation_codes": list(input_snapshot.clock_evidence.degradation_codes),
    }
    report["algorithm_degradation_codes"] = _algorithm_degradation_codes(
        report
    )
    if publish_blockers:
        report["result_quality_status"] = "PARTIAL_REVIEW_REQUIRED"
        report["partial_result"] = True
    if tag_evidence_degradations:
        report["warnings"].append(
            "部分价签 burst、节点绑定或确认材料不完整；轨迹和可恢复价签已保留，"
            "相关条目标记为 LOW_CONFIDENCE，结果禁止自动发布。"
        )
    if corridor_route_audit.get("route_confidence") == "low":
        report["warnings"].append(
            "轨迹已按连续物理移动、道路图连通性和货架/固定结构自由空间重建；"
            "平行通道身份仍存在多解，结果保留为 LOW_CONFIDENCE 复核草稿，"
            "但不会再用穿货架或非物理横移伪造确定路线。"
        )
    if float(
        corridor_route_audit.get("maximum_distance_scale_deviation") or 0.0
    ) > 0.05:
        report["warnings"].append(
            "候选道路路线与 gauge-neutral 物理累计距离存在超过 5% 的分段尺度差；"
            "有限路线和坐标表仍保留，但距离尺度标记为 LOW_CONFIDENCE，必须人工复核。"
        )
    if has_critical_jsonl_damage:
        report["warnings"].append(
            "检测到 sidecar 文件损坏，结果可能不完整。不得自动发布。"
        )
    if map_identity_binding["legacy_compatibility"]:
        report["warnings"].append(
            "该历史手机会话未记录完整 canonical source SHA；本次通过地图 ID、"
            "门店、楼层和 canonical SHA 前缀执行跨编译器兼容绑定。结果报告已"
            "保留手机包哈希与电脑包哈希，后续新会话应使用完整 canonical 绑定。"
        )
    if diagnostic_mode:
        ignored_count = report["ignored_conflicting_source_constraint_count"]
        report["warnings"].append(
            "测试诊断模式已启用：冲突手机定位约束不会阻止生成可视化草稿，"
            f"本次忽略 {ignored_count} 条；全部门禁和误差指标仍保留，且结果禁止发布。"
        )
    if raw_manual_anchor_recovery:
        report["warnings"].append(
            "RTAB-Map 全局优化图不完整；本草稿使用完整原始连续 VIO、严格绑定的人工绝对锚点和地图结构约束重建。大绝对修正按地图坐标校准解释，相邻连续形变仍受门禁约束；结果仅供诊断与人工复核，禁止发布。"
        )
    elif raw_diagnostic_recovery:
        report["warnings"].append(
            "RTAB-Map 全局优化图不完整；本草稿使用完整原始 VIO 与扫描起点地图位姿保留有限轨迹。若检测到采集坐标系重置，仅在多条独立短 Link 对同一刚体变换达成一致后缝合；结果仅供诊断与人工复核，禁止发布。"
        )
    elif partial_graph_recovery:
        report["warnings"].append(
            "RTAB-Map 只保存了部分节点的全局优化位姿；本草稿以完整、连续的原始 VIO 为相对运动骨架，并在已优化节点之间连续插值 SE(2) 校正。全部源节点和人工/地图修正证据均保留，但该结果不冒充完整全局图，禁止自动发布。"
        )
    if publish_blockers:
        report["warnings"].append(
            "质量或发布门禁未全部通过；有限轨迹和可恢复业务结果已作为"
            "不可发布草稿保留，请按 blocker 和 review item 人工复核。"
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
                "gauge_neutral_physical_motion_reconstruction",
                "free_space_road_route_matching",
                "tag_reassociation",
                "quality_gate",
                "human_review",
                "export",
            ],
            "source_database_modified": False,
            "publish_state": report["publish_state"],
            "allow_draft": report["allow_draft"],
            "diagnostic_mode": report["diagnostic_mode"],
            "diagnostic_only": report["diagnostic_only"],
            "relative_trajectory_authority": relative_trajectory_authority,
            "rtabmap_global_graph_incomplete": report[
                "rtabmap_global_graph_incomplete"
            ],
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
                else (
                    "gauge_neutral_free_space_road_route_v1"
                    if corridor_route_audit.get("status")
                    in {"matched", "matched_low_confidence"}
                    else "bounded_correction_field_banded_v3"
                )
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
                "manual_anchor_translation_sigma_m": MANUAL_ANCHOR_TRANSLATION_SIGMA_M,
                "manual_anchor_yaw_sigma_rad": MANUAL_ANCHOR_YAW_SIGMA_RAD,
                "corridor_route_obstacle_clearance_m": corridor_route_audit.get(
                    "obstacle_clearance_m"
                ),
                "corridor_route_maximum_candidates": corridor_route_audit.get(
                    "maximum_candidates"
                ),
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
            "floor_id": str(
                metadata.get("floorId") or metadata.get("floor_id") or ""
            ),
            "coordinate_contract_version": COORDINATE_CONTRACT_VERSION,
            "coordinate_contract": {
                "x_axis": "+X east / screen right",
                "y_axis": "+Y north / screen up",
                "yaw_zero_axis": "+X",
                "yaw_positive": "counterclockwise",
                "view_y_conversion_count": 1,
            },
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
            "tag_id", "capture_id", "observation_id", "payload", "symbology",
            "map_x_cm", "map_y_cm", "height_cm",
            "final_shelf_segment_id", "shelf_code", "row_flag", "cross_code", "shelf_side",
            "distance_from_shelf_start_cm", "online_offline_distance_cm",
            "localization_confidence", "measurement_confidence",
            "association_confidence", "manually_modified", "needs_review",
            "approval_status",
            "quality_status", "input_evidence_status", "review_reasons",
            "store_id", "floor_id", "prior_map_id",
            "prior_map_package_sha256", "canonical_source_sha256",
            "coordinate_contract_version", "position_status",
            "shelf_association_status", "algorithm_degradation_codes",
        ]
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        for tag in final_tags:
            position = tag.get("final_map_position") or {}
            x_m = _strict_number(position.get("x_m"))
            y_m = _strict_number(position.get("y_m"))
            writer.writerow(
                {
                    **{key: tag.get(key) for key in fieldnames},
                    "map_x_cm": x_m * 100 if x_m is not None else None,
                    "map_y_cm": y_m * 100 if y_m is not None else None,
                    "height_cm": (
                        float(position["height_m"]) * 100
                        if position.get("height_m") is not None else None
                    ),
                    "final_shelf_segment_id": (
                        tag.get("final_shelf_segment_id")
                        or tag.get("shelf_segment_id")
                        or tag.get("algorithm_shelf_segment_id")
                        or tag.get("user_confirmed_shelf_segment_id")
                    ),
                    "store_id": metadata.get("storeId"),
                    "floor_id": sidecar_floor_id,
                    "prior_map_id": manifest.get("prior_map_id"),
                    "prior_map_package_sha256": package_hash,
                    "canonical_source_sha256": map_identity_binding.get(
                        "canonical_source_sha256"
                    ),
                    "coordinate_contract_version": COORDINATE_CONTRACT_VERSION,
                    "position_status": (
                        "AVAILABLE"
                        if isinstance(tag.get("final_map_position"), dict)
                        else "UNAVAILABLE"
                    ),
                    "shelf_association_status": (
                        "ASSOCIATED"
                        if tag.get("shelf_code")
                        and (
                            tag.get("final_shelf_segment_id")
                            or tag.get("shelf_segment_id")
                            or tag.get("algorithm_shelf_segment_id")
                            or tag.get("user_confirmed_shelf_segment_id")
                        )
                        else "UNASSOCIATED"
                    ),
                    "algorithm_degradation_codes": json.dumps(
                        tag.get("review_reasons", []),
                        ensure_ascii=False,
                        separators=(",", ":"),
                    ),
                    "review_reasons": json.dumps(
                        tag.get("review_reasons", []),
                        ensure_ascii=False,
                        separators=(",", ":"),
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
    delivery_context = {
        "store_id": metadata.get("storeId"),
        "floor_id": sidecar_floor_id,
        "prior_map_id": manifest.get("prior_map_id"),
        "prior_map_package_sha256": package_hash,
        "canonical_source_sha256": map_identity_binding.get(
            "canonical_source_sha256"
        ),
        "coordinate_contract_version": COORDINATE_CONTRACT_VERSION,
        "input_identity_id": input_identity_id,
        "result_quality_status": report.get("result_quality_status"),
        "publish_permitted": report.get("publish_permitted") is True,
        "algorithm_degradation_codes": report.get(
            "algorithm_degradation_codes", []
        ),
        "position_source": (
            "partial_rtabmap_graph_continuous_vio_map_corrected"
            if partial_graph_recovery
            else (
                "raw_continuous_vio_map_corrected"
                if raw_vio_recovery
                else "rtabmap_reprocess_plus_prior_map_correction"
            )
        ),
    }
    trajectory_counts = write_calibrated_trajectory_exports(
        output,
        optimized,
        corridor_route_audit,
        constraints,
        clock_evidence=input_snapshot.clock_evidence,
        delivery_context=delivery_context,
        unavailable_intervals=weak_lost_intervals,
    )
    deliverables_manifest = write_calibrated_deliverables_manifest(
        output,
        report=report,
        source_database_sha256=source_hash_before,
        optimized_database_sha256=optimized_db_hash,
        prior_map_package_sha256=package_hash,
        canonical_source_sha256=str(
            map_identity_binding.get("canonical_source_sha256") or ""
        ),
        trajectory_counts=trajectory_counts,
    )
    report["calibrated_deliverables"] = {
        key: deliverables_manifest[key]
        for key in (
            "source_node_count",
            "exported_node_count",
            "one_second_row_count",
            "one_second_unavailable_count",
            "source_tag_count",
            "retained_tag_count",
            "positioned_tag_count",
            "unpositioned_tag_count",
            "shelf_associated_tag_count",
            "unassociated_tag_count",
        )
    }
    # The report is itself an immutable artifact; rewrite it after the core
    # deliverables pass their cross-file count/hash contract.
    _json_write(output / "localization_report.json", report)
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
    upstream_processing_report: dict[str, Any] | None = None,
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
            upstream_processing_report=upstream_processing_report,
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
