"""Stage-3 derived SE(2) trajectory optimization and review/export pipeline.

The source RTAB-Map database is read-only.  This module consumes the already
optimized database copy produced by ``rtabmap-reprocess`` and writes a separate
prior-map coordinate trajectory plus auditable review artifacts.

The solver is deliberately described as a robust banded SE(2) correction
optimizer, not a general factor-graph implementation.  It preserves the
RTAB-Map relative trajectory with smooth correction terms while applying
accepted map observations and explicit manual anchors through Huber IRLS.
"""

from __future__ import annotations

import csv
import hashlib
import json
import math
import shutil
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, Iterable, Sequence

from .localized_output_store import LocalizedVersionStore
from .prior_map_schema import load_json, validate_package


FORMAT_VERSION = 1
TOOL_VERSION = "MarketScanner-RepairV2"
COORDINATE_CONTRACT_VERSION = 1
HUBER_TRANSLATION_M = 0.45
HUBER_YAW_RAD = math.radians(10)
HARD_REJECT_TRANSLATION_M = 2.5
HARD_REJECT_YAW_RAD = math.radians(45)
EDITABLE_TAG_FIELDS = frozenset(
    {
        "shelf_code",
        "shelf_side",
        "distance_from_shelf_start_cm",
        "height_cm",
        "final_map_position",
    }
)


def processing_parameter_sha256() -> str:
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


@dataclass(frozen=True)
class TagPoseBinding:
    node_index: int
    observation_timestamp: float
    node_timestamp: float
    time_delta_seconds: float
    binding_source: str


def _json_write(path: Path, payload: Any, *, lines: bool = False) -> None:
    if lines:
        text = "".join(
            json.dumps(item, ensure_ascii=False, separators=(",", ":"), sort_keys=True)
            + "\n"
            for item in payload
        )
    else:
        text = json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
    path.write_text(text, encoding="utf-8")


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


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


def _read_jsonl(
    path: Path,
    maximum_record_bytes: int = 1_000_000,
    maximum_records: int = 500_000,
    *,
    strict: bool = False,
    required: bool = False,
    session_id: str | None = None,
    expected_map_hash: str | None = None,
    expected_floor_id: str | None = None,
) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    """Read a JSONL sidecar with structure-preserving diagnostics.

    Returns ``(records, diagnostics)``.  ``diagnostics`` always contains:
    ``total_lines``, ``valid_records``, ``invalid_json_lines``,
    ``non_object_lines``, ``oversized_lines``, ``version_mismatches``,
    ``session_mismatches``, ``map_hash_mismatches``, ``floor_mismatches``,
    ``truncated``.

    When ``strict=True``, any structural corruption raises immediately.
    When ``required=True``, a missing file also raises.

    Session/map/floor identity checks are best-effort: they only flag
    mismatches and never skip a valid record (non-fatal by default).
    """
    diagnostics: dict[str, Any] = {
        "file": str(path),
        "total_lines": 0,
        "valid_records": 0,
        "invalid_json_lines": 0,
        "non_object_lines": 0,
        "oversized_lines": 0,
        "version_mismatches": 0,
        "session_mismatches": 0,
        "map_hash_mismatches": 0,
        "floor_mismatches": 0,
        "truncated": False,
    }
    values: list[dict[str, Any]] = []
    if not path.is_file():
        if required:
            raise OfflineLocalizationError(
                f"Required sidecar file is missing: {path.name}"
            )
        return values, diagnostics
    malformed_samples: list[str] = []
    max_malformed_samples = 5
    with path.open("r", encoding="utf-8", errors="replace") as handle:
        for line_no, line in enumerate(handle, start=1):
            diagnostics["total_lines"] += 1
            stripped = line.strip()
            if not stripped:
                continue
            if not stripped or len(line) > maximum_record_bytes:
                diagnostics["oversized_lines"] += 1
                if strict:
                    raise OfflineLocalizationError(
                        f"Oversized record at {path.name}:{line_no}"
                    )
                continue
            try:
                value = json.loads(line)
            except json.JSONDecodeError as exc:
                diagnostics["invalid_json_lines"] += 1
                if strict:
                    raise OfflineLocalizationError(
                        f"Invalid JSON at {path.name}:{line_no}: {exc}"
                    ) from exc
                if len(malformed_samples) < max_malformed_samples:
                    malformed_samples.append(
                        f"{path.name}:{line_no}: {str(exc)[:120]}"
                    )
                continue
            if not isinstance(value, dict):
                diagnostics["non_object_lines"] += 1
                if strict:
                    raise OfflineLocalizationError(
                        f"Non-object record at {path.name}:{line_no}"
                    )
                continue
            # Best-effort identity checks (non-fatal).
            if session_id is not None and str(
                value.get("tracking_session_id") or value.get("trackingSessionId") or ""
            ) not in ("", session_id):
                diagnostics["session_mismatches"] += 1
            if expected_map_hash is not None and str(
                value.get("prior_map_sha256") or value.get("priorMapSha256") or ""
            ) not in ("", expected_map_hash):
                diagnostics["map_hash_mismatches"] += 1
            if expected_floor_id is not None and str(
                value.get("floor_id") or value.get("floorId") or ""
            ) not in ("", expected_floor_id):
                diagnostics["floor_mismatches"] += 1
            values.append(value)
            diagnostics["valid_records"] += 1
            if len(values) > maximum_records:
                diagnostics["truncated"] = True
                if strict:
                    raise OfflineLocalizationError(
                        f"{path.name} exceeds the bounded {maximum_records}-record safety limit."
                    )
                break
    if malformed_samples:
        diagnostics["malformed_samples"] = malformed_samples
    return values, diagnostics


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
    timestamp_value = observation.get("frame_timestamp")
    if isinstance(timestamp_value, bool):
        raise OfflineLocalizationError("tag_observation_frame_timestamp_invalid")
    try:
        observation_timestamp = float(timestamp_value)
    except (TypeError, ValueError):
        raise OfflineLocalizationError("tag_observation_frame_timestamp_missing")
    if not math.isfinite(observation_timestamp):
        raise OfflineLocalizationError("tag_observation_frame_timestamp_invalid")

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
    """Validate a v2 manual event and bind it to the RTAB-Map timebase."""
    if event.get("format") != "MarketScannerManualLocalizationEvent":
        raise OfflineLocalizationError("manual_event_format_invalid")
    if event.get("version") != 2:
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
    frame_value = event.get("frame_timestamp")
    if isinstance(frame_value, bool):
        raise OfflineLocalizationError("manual_event_frame_timestamp_invalid")
    try:
        frame_timestamp = float(frame_value)
        alignment_version = int(event.get("alignment_version"))
    except (TypeError, ValueError):
        raise OfflineLocalizationError("manual_event_time_or_alignment_invalid")
    if not math.isfinite(frame_timestamp) or alignment_version <= 0:
        raise OfflineLocalizationError("manual_event_time_or_alignment_invalid")

    node_id_value = event.get("nearest_node_id")
    binding_source = "frame_timestamp"
    if node_id_value is not None:
        if isinstance(node_id_value, bool):
            raise OfflineLocalizationError("manual_event_node_id_invalid")
        try:
            node_id_number = float(node_id_value)
        except (TypeError, ValueError):
            raise OfflineLocalizationError("manual_event_node_id_invalid")
        if not math.isfinite(node_id_number) or not node_id_number.is_integer():
            raise OfflineLocalizationError("manual_event_node_id_invalid")
        matches = [
            index for index, pose in enumerate(poses) if pose.node_id == int(node_id_number)
        ]
        if len(matches) != 1:
            raise OfflineLocalizationError(
                "manual_event_node_id_not_found"
                if not matches
                else "manual_event_node_id_ambiguous"
            )
        index = matches[0]
        binding_source = "nearest_node_id"
        event_node_stamp_value = event.get("nearest_node_stamp")
        event_delta_value = event.get("node_time_delta_seconds")
        try:
            event_node_stamp = float(event_node_stamp_value)
            event_delta = float(event_delta_value)
        except (TypeError, ValueError):
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
        constraints.append(
            AbsoluteConstraint(
                identifier=f"road-{corridor_id}-{pose.node_id}",
                node_index=index,
                x=x,
                y=y,
                yaw=yaw,
                weight=0.35 * proximity,
                kind="road_soft",
                source={
                    "corridor_id": corridor_id,
                    "distance_m": distance,
                    "width_m": width,
                },
            )
        )
    return constraints


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
            if (
                constraint.kind
                not in {"manual_anchor", "manual_aisle_assignment", "road_soft"}
                and (
                    residual_xy > HARD_REJECT_TRANSLATION_M
                    or residual_yaw > HARD_REJECT_YAW_RAD
                )
            ):
                rejected.append(
                    {
                        "constraint_id": constraint.identifier,
                        "kind": constraint.kind,
                        "translation_residual_m": residual_xy,
                        "yaw_residual_deg": math.degrees(residual_yaw),
                        "reason": "robust_hard_gate",
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
            timestamp = float(event.get("timestamp"))
        except (TypeError, ValueError):
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
            "properties": {"layer": "rtabmap_optimized"},
            "geometry": {
                "type": "LineString",
                "coordinates": [[pose.x, pose.y] for pose in baseline],
            },
        },
        {
            "type": "Feature",
            "properties": {"layer": "prior_map_offline_optimized"},
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
                "properties": {"layer": "online_localization"},
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
        features.append(
            {
                **feature,
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
            "candidate_search_complete": False,
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
            if current != suggested:
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
        "candidate_search_complete": False,
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
) -> dict[str, Any]:
    return {
        "format": "MarketScannerManualEdits",
        "version": 3,
        "revision": 1,
        "prior_map_sha256": map_sha256,
        "source_database_sha256": session_sha256,
        "source_session_sha256": session_sha256,
        "optimized_database_sha256": optimized_db_sha256,
        "processing_parameter_sha256": processing_parameter_sha256(),
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
) -> dict[str, Any]:
    """Upgrade the historical v2 journal without weakening identity binding."""

    if journal.get("format") != "MarketScannerManualEdits" or journal.get("version") != 2:
        return journal
    if (
        journal.get("prior_map_sha256") != map_sha256
        or journal.get("source_session_sha256") != source_database_sha256
        or (
            journal.get("optimized_database_sha256")
            and journal.get("optimized_database_sha256")
            != optimized_database_sha256
        )
    ):
        raise OfflineLocalizationError(
            "Historical manual_edits v2 identity does not match the selected inputs."
        )
    upgraded = new_manual_edits(
        map_sha256, source_database_sha256, optimized_database_sha256
    )
    upgraded["revision"] = journal.get("revision", 1)
    upgraded["cursor"] = journal.get("cursor", 0)
    upgraded["events"] = journal.get("events", [])
    upgraded["audit_events"] = [
        {
            "event_id": "migration-v2-to-v3",
            "type": "journal_migrated",
            "actor": "system",
            "reason": "Historical v2 journal upgraded with current immutable identities.",
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
    metadata = load_json(segment / "metadata.json")
    if not isinstance(metadata, dict):
        raise OfflineLocalizationError("Session metadata is invalid.")
    if metadata.get("workflowMode") != "prior_map_localized":
        raise OfflineLocalizationError("This session is not a prior-map localized scan.")
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
    source_hash_before = _sha256(source_database)
    session_hash = source_hash_before
    package_hash = str(package_manifest["package_sha256"])
    optimized_db_hash = _sha256(optimized_database)
    if manual_edits is None:
        manual_edits = new_manual_edits(package_hash, session_hash, optimized_db_hash)
    manual_edits = upgrade_manual_edits_v2(
        manual_edits, package_hash, session_hash, optimized_db_hash
    )
    if (
        manual_edits.get("format") != "MarketScannerManualEdits"
        or manual_edits.get("version") != 3
        or manual_edits.get("prior_map_sha256") != package_hash
        or manual_edits.get("source_database_sha256") != session_hash
        or manual_edits.get("source_session_sha256") != session_hash
        or manual_edits.get("processing_parameter_sha256")
        != processing_parameter_sha256()
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

    trace, trace_diag = _read_jsonl(
        segment / "localization_trace.jsonl", required=True, strict=True
    )
    raw_constraints, constraint_diag = _read_jsonl(
        segment / "localization_constraints.jsonl",
        session_id=str(metadata.get("trackingSessionId") or ""),
    )
    manual_events, manual_diag = _read_jsonl(
        segment / "manual_localization_events.jsonl",
        session_id=str(metadata.get("trackingSessionId") or ""),
    )
    tag_observations, obs_diag = _read_jsonl(
        segment / "tag_observations.jsonl",
        session_id=str(metadata.get("trackingSessionId") or ""),
    )
    jsonl_diagnostics = {
        "localization_trace": trace_diag,
        "localization_constraints": constraint_diag,
        "manual_localization_events": manual_diag,
        "tag_observations": obs_diag,
    }
    has_critical_jsonl_damage = any(
        diag.get("invalid_json_lines", 0) > 0 or diag.get("truncated", False)
        for diag in jsonl_diagnostics.values()
    )
    raw_tags_value = load_json(segment / "localized_price_tags.json") if (
        segment / "localized_price_tags.json"
    ).is_file() else []
    raw_tags = [dict(item) for item in raw_tags_value if isinstance(item, dict)]
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
                float(record["timestamp"])
                if record.get("timestamp") is not None
                else None,
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
    for sequence, record in enumerate(manual_events, start=1):
        identifier = f"manual-{sequence:06d}"
        try:
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
    optimized, accepted, rejected = optimize_trajectory(baseline, constraints)

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
        original = tag.get("raw_map_position") or raw_observation_position
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
    # `automatic_publish_allowed` only ever yields DRAFT; REVIEW requires
    # explicit user submission; PUBLISHED requires an explicit approval event.
    # Any critical JSONL damage or stale node binding prevents even draft.
    state_events, state_diag = _read_jsonl(segment / "localization_events.jsonl")
    jsonl_diagnostics["localization_events"] = state_diag
    has_critical_jsonl_damage = has_critical_jsonl_damage or (
        state_diag.get("invalid_json_lines", 0) > 0
    )
    allow_draft = (
        bool(optimized)
        and not has_critical_jsonl_damage
        and max_correction <= 2.0
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
    # Node coverage: source DB node count vs. optimized vs. exported.
    try:
        source_node_count = int(
            metadata.get("nodeCount") or metadata.get("node_count") or len(baseline)
        )
    except (TypeError, ValueError):
        source_node_count = len(baseline)
    optimized_node_ids = {pose.node_id for pose in optimized}
    baseline_node_ids = {pose.node_id for pose in baseline}
    node_coverage = (
        len(optimized_node_ids & baseline_node_ids) / max(1, source_node_count)
        if source_node_count > 0
        else 0.0
    )
    report = {
        "format": "MarketScannerLocalizationReport",
        "version": FORMAT_VERSION,
        "prior_map_id": manifest.get("prior_map_id"),
        "prior_map_sha256": package_hash,
        "source_session_sha256": session_hash,
        "source_database_sha256": source_hash_before,
        "optimized_database_sha256": optimized_db_hash,
        "node_count": len(optimized),
        "node_coverage_ratio": round(node_coverage, 6),
        "source_node_count": source_node_count,
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
        "aisle_switch_sequence": [
            # Use final trajectory-based road inference, not online raw candidates.
        ],
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
        "allow_auto_publish": False,
        "warnings": [],
        "rejection_reasons": sorted({item["reason"] for item in rejected}),
        "solver": {
            "type": "robust_banded_se2_correction_irls",
            "full_factor_graph": False,
            "huber_translation_m": HUBER_TRANSLATION_M,
            "huber_yaw_deg": math.degrees(HUBER_YAW_RAD),
            "relative_trajectory_authority": "rtabmap_reprocess_optimized_copy",
        },
    }
    if has_critical_jsonl_damage:
        report["warnings"].append(
            "检测到 sidecar 文件损坏，结果可能不完整。不得自动发布。"
        )
    if not allow_draft:
        report["warnings"].append(
            "处理未能生成有效草稿；检查输入文件和优化器状态。"
        )
    source_hash_after = _sha256(source_database)
    if source_hash_after != source_hash_before:
        raise OfflineLocalizationError("Source database changed during localized processing.")

    output.mkdir(parents=True, exist_ok=True)
    shutil.copy2(prior_map / "manifest.json", output / "prior_map_manifest.json")
    _json_write(
        output / "source_manifest.json",
        {
            "format": "MarketScannerLocalizedSourceManifest",
            "version": 1,
            "source_session": str(session.resolve()),
            "source_database": str(source_database.resolve()),
            "source_database_sha256_before": source_hash_before,
            "source_database_sha256_after": source_hash_after,
            "source_database_immutable": True,
            "optimized_database": str(optimized_database.resolve()),
            "prior_map": str(prior_map.resolve()),
            "prior_map_sha256": package_hash,
        },
    )
    _json_write(
        output / "processing_manifest.json",
        {
            "format": "MarketScannerLocalizedProcessing",
            "version": 1,
            "pipeline": [
                "rtabmap_reprocess",
                "relative_trajectory_read",
                "prior_map_se2_correction",
                "tag_reassociation",
                "quality_gate",
                "human_review",
                "export",
            ],
            "source_database_modified": False,
            "publish_state": report["publish_state"],
            "allow_draft": report["allow_draft"],
            "source_database_sha256": source_hash_before,
            "optimized_database_sha256": optimized_db_hash,
            "prior_map_sha256": package_hash,
            "tool_version": TOOL_VERSION,
            "algorithm_version": "bounded_correction_field_v1",
            "coordinate_contract_version": COORDINATE_CONTRACT_VERSION,
            "processing_parameter_sha256": processing_parameter_sha256(),
            "parameters": {
                "huber_translation_m": HUBER_TRANSLATION_M,
                "huber_yaw_rad": HUBER_YAW_RAD,
                "hard_reject_translation_m": HARD_REJECT_TRANSLATION_M,
                "hard_reject_yaw_rad": HARD_REJECT_YAW_RAD,
            },
            "input_sidecars": {
                path.name: {
                    "bytes": path.stat().st_size,
                    "sha256": _sha256(path),
                }
                for path in sorted(segment.iterdir())
                if path.is_file()
                and path.suffix in {".json", ".jsonl", ".csv"}
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
) -> dict[str, Any]:
    """Render and atomically commit an immutable localized result version.

    The rendering function only receives a private staging directory. Readers
    continue resolving the previous ``current.json`` pointer until every
    required artifact has been validated, fsynced and renamed into ``versions``.
    An invalid diagnostic version is retained for audit but never becomes the
    current result.
    """

    store = LocalizedVersionStore(output)
    previous = store.current()
    staging = store.begin()
    try:
        report = _render_localized_version(
            prior_map=prior_map,
            session=session,
            optimized_poses=optimized_poses,
            source_database=source_database,
            optimized_database=optimized_database,
            output=staging,
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
