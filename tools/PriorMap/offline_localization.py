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

from .prior_map_schema import load_json, validate_package


FORMAT_VERSION = 1
HUBER_TRANSLATION_M = 0.45
HUBER_YAW_RAD = math.radians(10)
HARD_REJECT_TRANSLATION_M = 2.5
HARD_REJECT_YAW_RAD = math.radians(45)


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
    except (TypeError, ValueError):
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
) -> list[dict[str, Any]]:
    values: list[dict[str, Any]] = []
    if not path.is_file():
        return values
    with path.open("r", encoding="utf-8", errors="replace") as handle:
        for line in handle:
            if not line.strip() or len(line) > maximum_record_bytes:
                continue
            try:
                value = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(value, dict):
                values.append(value)
                if len(values) > maximum_records:
                    raise OfflineLocalizationError(
                        f"{path.name} exceeds the bounded {maximum_records}-record safety limit."
                    )
    return values


def _nearest_pose_index(poses: Sequence[Pose], timestamp: float | None) -> int:
    if not poses:
        raise OfflineLocalizationError("The optimized RTAB-Map trajectory is empty.")
    if timestamp is None:
        return 0
    stamped = [
        (abs(float(pose.timestamp) - timestamp), index)
        for index, pose in enumerate(poses)
        if pose.timestamp is not None
    ]
    return min(stamped)[1] if stamped else 0


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
    denom = (x2 - x1) * (y4 - y3) - (y2 - y1) * (x4 - x3)
    if abs(denom) < eps:
        # Parallel or collinear — treat as non-intersecting for occlusion.
        return None
    t = ((x3 - x1) * (y4 - y3) - (y3 - y1) * (x4 - x3)) / denom
    u = ((x3 - x1) * (y2 - y1) - (y3 - y1) * (x2 - x1)) / denom
    # Allow a tiny tolerance so endpoint grazes count as occlusion.
    if t < -eps or t > 1.0 + eps or u < -eps or u > 1.0 + eps:
        return None
    hit_x = x1 + t * (x2 - x1)
    hit_y = y1 + t * (y2 - y1)
    dist = math.hypot(hit_x - x1, hit_y - y1)
    return (max(0.0, min(1.0, t)), max(0.0, min(1.0, u)), dist)


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
        tag["needs_review"] = True
        return tag

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

    can_auto_confirm = (
        has_camera
        and best_distance <= 0.45
        and ray_clear
        and visible_side_consistent
        and not near_endpoint
        and (second is None or margin >= min_margin)
        and loc_conf >= min_auto_confidence
        and meas_conf >= min_auto_confidence
        and not manually_modified
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
        tag["needs_review"] = bool(tag.get("needs_review")) or False
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
        tag["needs_review"] = True
        if "association_confidence" not in tag:
            tag["association_confidence"] = round(
                max(0.0, 1 - best_distance / candidate_radius), 6
            )
    return tag


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
    if loc_conf < 0.6:
        reasons.append(f"localization confidence {loc_conf:.2f} below 0.60")
    if meas_conf < 0.6:
        reasons.append(f"measurement confidence {meas_conf:.2f} below 0.60")
    return "; ".join(reasons) if reasons else "unconfirmed"


def apply_manual_edits(
    constraints: list[dict[str, Any]],
    tags: list[dict[str, Any]],
    edits: dict[str, Any] | None,
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
                    tag["manually_modified"] = True
                    tag["needs_review"] = True
        elif kind == "approve_tag":
            for tag in tags:
                if str(tag.get("tag_id")) == target:
                    tag["approval_status"] = "approved"
                    tag["needs_review"] = False
        elif kind == "batch_approve_tags" and isinstance(new_value, list):
            approved = {str(value) for value in new_value}
            for tag in tags:
                if str(tag.get("tag_id")) in approved:
                    tag["approval_status"] = "approved"
                    tag["needs_review"] = False
        audit.append(
            {
                "sequence": sequence,
                "event_id": event.get("event_id"),
                "type": kind,
                "object_id": target,
                "old_value": event.get("old_value"),
                "new_value": new_value,
            }
        )
    return constraints, tags, audit


def new_manual_edits(map_sha256: str, session_sha256: str) -> dict[str, Any]:
    return {
        "format": "MarketScannerManualEdits",
        "version": 1,
        "prior_map_sha256": map_sha256,
        "source_session_sha256": session_sha256,
        "cursor": 0,
        "events": [],
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
    elif kind == "approve_tag":
        if not target:
            raise OfflineLocalizationError("approve_tag requires object_id.")
    elif kind == "batch_approve_tags":
        if not isinstance(value, list) or not value:
            raise OfflineLocalizationError(
                "batch_approve_tags requires a non-empty tag ID array."
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
        "timestamp": str(event.get("timestamp") or ""),
        "type": str(event.get("type") or ""),
        "object_id": str(event.get("object_id") or ""),
        "old_value": event.get("old_value"),
        "new_value": event.get("new_value"),
    }
    events.append(normalized)
    return {**journal, "events": events, "cursor": len(events)}


def move_manual_edit_cursor(journal: dict[str, Any], delta: int) -> dict[str, Any]:
    events = list(journal.get("events", []))
    cursor = max(0, min(len(events), int(journal.get("cursor", len(events))) + delta))
    return {**journal, "cursor": cursor}


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
    if manual_edits is None:
        manual_edits = new_manual_edits(package_hash, session_hash)
    if (
        manual_edits.get("prior_map_sha256") != package_hash
        or manual_edits.get("source_session_sha256") != session_hash
    ):
        raise OfflineLocalizationError("manual_edits.json does not match this map/session pair.")
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
    if progress:
        progress(84, "先验地图轨迹优化", "正在读取在线约束并建立稳健 SE(2) 修正问题")

    trace = _read_jsonl(segment / "localization_trace.jsonl")
    raw_constraints = _read_jsonl(segment / "localization_constraints.jsonl")
    manual_events = _read_jsonl(segment / "manual_localization_events.jsonl")
    tag_observations = _read_jsonl(segment / "tag_observations.jsonl")
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
        constraints.append(
            AbsoluteConstraint(
                identifier=identifier,
                node_index=_nearest_pose_index(
                    baseline,
                    float(record["timestamp"]) if record.get("timestamp") is not None else None,
                ),
                x=pose[0],
                y=pose[1],
                yaw=pose[2],
                weight=max(1.0, 6.0 * float(record.get("uniqueness", 0.2))),
                kind="online_structure",
                source=record,
            )
        )
    for sequence, record in enumerate(manual_events, start=1):
        pose = _pose_from(record.get("confirmedMapPose"))
        if pose is None:
            pose = _pose_from(record.get("confirmed_map_pose"))
        if pose is None:
            continue
        constraints.append(
            AbsoluteConstraint(
                identifier=f"manual-{sequence:06d}",
                node_index=_nearest_pose_index(
                    baseline,
                    float(record.get("timestampUnix"))
                    if record.get("timestampUnix") is not None
                    else None,
                ),
                x=pose[0],
                y=pose[1],
                yaw=pose[2],
                weight=80.0,
                kind="manual_anchor",
                source=record,
            )
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
    for tag in raw_tags:
        observation = observations_by_id.get(str(tag.get("observation_id")), {})
        obs_timestamp = (
            float(observation["frame_timestamp"])
            if observation.get("frame_timestamp") is not None
            else None
        )
        index = _nearest_pose_index(baseline, obs_timestamp)
        baseline_node = baseline[index]
        optimized_node = optimized[index]
        original = tag.get("snapped_map_position") or tag.get("raw_map_position")
        if isinstance(original, dict):
            tag["online_map_position"] = dict(original)
            try:
                final_x, final_y = apply_pose_delta_to_point(
                    baseline_node,
                    optimized_node,
                    (float(original.get("x_m", 0)), float(original.get("y_m", 0))),
                )
            except OfflineLocalizationError:
                tag["needs_review"] = True
                final_tags.append(
                    _associate_tag(tag, elements, (optimized_node.x, optimized_node.y))
                )
                continue
            tag["final_map_position"] = {
                "x_m": round(final_x, 6),
                "y_m": round(final_y, 6),
                "height_m": original.get("height_m"),
            }
            online_x = float(original.get("x_m", 0))
            online_y = float(original.get("y_m", 0))
            tag["online_offline_distance_cm"] = round(
                math.hypot(final_x - online_x, final_y - online_y) * 100, 3
            )
        tag.setdefault("manually_modified", False)
        tag.setdefault("approval_status", "pending" if tag.get("needs_review") else "auto_approved")
        # Audit: record the binding node and SE(2) delta so reviewers can verify
        # the rigid transform that propagated this tag from online to final.
        node_time_delta: float | None = None
        if obs_timestamp is not None and baseline_node.timestamp is not None:
            node_time_delta = abs(obs_timestamp - baseline_node.timestamp)
        tag.setdefault("transform_audit", {
            "source_observation_id": str(tag.get("observation_id") or ""),
            "bound_node_id": baseline_node.node_id,
            "bound_node_stamp": baseline_node.timestamp,
            "observation_stamp": obs_timestamp,
            "time_delta_seconds": node_time_delta,
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
        })
        if node_time_delta is not None and node_time_delta > max_node_time_delta_seconds:
            tag["needs_review"] = True
        final_tags.append(
            _associate_tag(tag, elements, (optimized_node.x, optimized_node.y))
        )
    # Manual tag decisions are deliberately replayed after all automatic
    # reassociation so a reprocess never silently overwrites a human edit.
    _, final_tags, _ = apply_manual_edits([], final_tags, manual_edits)

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
            "id": f"tag-{tag.get('tag_id', index)}",
            "type": "price_tag",
            "severity": "warning",
            "message": f"价签 {tag.get('payload') or tag.get('tag_id')} 需要人工复核。",
            "object_id": tag.get("tag_id"),
        }
        for index, tag in enumerate(final_tags, start=1)
        if tag.get("needs_review") is True
    )
    max_correction = max(corrections, default=0.0)
    acceptance_rate = accepted_source_count / max(
        1, source_accepted_count + len(manual_events)
    )
    needs_review_count = sum(tag.get("needs_review") is True for tag in final_tags)
    automatic_publish = (
        bool(optimized)
        and acceptance_rate >= 0.55
        and max_correction <= 1.5
        and not rejected
        and needs_review_count == 0
    )
    state_events = _read_jsonl(segment / "localization_events.jsonl")
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
    report = {
        "format": "MarketScannerLocalizationReport",
        "version": FORMAT_VERSION,
        "prior_map_id": manifest.get("prior_map_id"),
        "prior_map_sha256": package_hash,
        "source_session_sha256": session_hash,
        "source_database_sha256": source_hash_before,
        "optimized_database_sha256": _sha256(optimized_database),
        "node_count": len(optimized),
        "node_coverage_ratio": 1.0 if optimized else 0.0,
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
        "map_constraint_acceptance_rate": acceptance_rate,
        "accepted_constraint_count": accepted_count,
        "accepted_source_constraint_count": accepted_source_count,
        "road_soft_constraint_count": sum(
            item["kind"] == "road_soft" for item in accepted
        ),
        "rejected_constraint_count": len(rejected),
        "high_residual_intervals": rejected,
        "aisle_switch_sequence": [
            (_field(record, "road_candidates", "roadCandidates") or [{}])[0].get(
                "edge_id"
            )
            or (_field(record, "road_candidates", "roadCandidates") or [{}])[0].get(
                "edgeId"
            )
            for record in trace
            if _field(record, "road_candidates", "roadCandidates")
        ],
        "manual_aisle_assignments": [
            {
                "event_id": event.get("event_id"),
                "object_id": event.get("object_id"),
                "value": event.get("new_value"),
            }
            for event in active_edit_events
            if isinstance(event, dict)
            and event.get("type") == "assign_interval_to_aisle"
        ],
        "manual_anchor_count": sum(item.kind == "manual_anchor" for item in constraints),
        "manual_aisle_constraint_count": sum(
            item.kind == "manual_aisle_assignment" for item in constraints
        ),
        "tag_total": len(final_tags),
        "tag_confirmed": sum(tag.get("approval_status") in {"approved", "auto_approved"} for tag in final_tags),
        "tag_needs_review": needs_review_count,
        "mean_association_confidence": (
            sum(float(tag.get("association_confidence", 0)) for tag in final_tags)
            / max(1, len(final_tags))
        ),
        "warnings": [
            "自动发布门未通过；结果仅可进入人工复核。"
        ] if not automatic_publish else [],
        "rejection_reasons": sorted({item["reason"] for item in rejected}),
        "automatic_publish_allowed": automatic_publish,
        "solver": {
            "type": "robust_banded_se2_correction_irls",
            "full_factor_graph": False,
            "huber_translation_m": HUBER_TRANSLATION_M,
            "huber_yaw_deg": math.degrees(HUBER_YAW_RAD),
            "relative_trajectory_authority": "rtabmap_reprocess_optimized_copy",
        },
    }
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
            "source_session": str(session),
            "source_database": str(source_database),
            "source_database_sha256_before": source_hash_before,
            "source_database_sha256_after": source_hash_after,
            "source_database_immutable": True,
            "optimized_database": str(optimized_database),
            "prior_map": str(prior_map),
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
            "automatic_publish_allowed": automatic_publish,
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
