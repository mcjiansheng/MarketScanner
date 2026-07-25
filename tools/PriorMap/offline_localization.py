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
    strict: bool = False,
    max_error_rate: float = 0.01,  # 最大允许错误率1%
    expected_session_id: str | None = None,
) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    """
    读取JSONL文件，返回(记录列表, 解析统计)
    strict模式下，错误率超过阈值或文件完全损坏时抛出异常
    """
    values: list[dict[str, Any]] = []
    stats = {
        "total_lines": 0,
        "valid_records": 0,
        "invalid_lines": 0,
        "skipped_oversize_lines": 0,
        "empty_lines": 0,
        "error_rate": 0.0,
        "file_exists": path.is_file(),
    }
    if not path.is_file():
        if strict:
            raise OfflineLocalizationError(f"Required JSONL file not found: {path.name}")
        return values, stats
    
    with path.open("r", encoding="utf-8", errors="replace") as handle:
        for line_number, line in enumerate(handle, start=1):
            stats["total_lines"] += 1
            stripped = line.strip()
            if not stripped:
                stats["empty_lines"] += 1
                continue
            if len(line) > maximum_record_bytes:
                stats["skipped_oversize_lines"] += 1
                continue
            try:
                value = json.loads(stripped)
            except json.JSONDecodeError as e:
                stats["invalid_lines"] += 1
                if strict:
                    raise OfflineLocalizationError(
                        f"JSONL file {path.name} corrupted at line {line_number}: {e}"
                    )
                continue
            if isinstance(value, dict):
                # 校验会话ID（如果提供）
                if expected_session_id is not None:
                    record_session = value.get("trackingSessionId") or value.get("tracking_session_id")
                    if record_session is not None and record_session != expected_session_id:
                        stats["invalid_lines"] += 1
                        if strict:
                            raise OfflineLocalizationError(
                                f"JSONL file {path.name} line {line_number} has mismatched session ID: "
                                f"expected {expected_session_id}, got {record_session}"
                            )
                        continue
                values.append(value)
                stats["valid_records"] += 1
                if len(values) > maximum_records:
                    raise OfflineLocalizationError(
                        f"{path.name} exceeds the bounded {maximum_records}-record safety limit."
                    )
    
    # 计算错误率
    non_empty_lines = stats["total_lines"] - stats["empty_lines"]
    if non_empty_lines > 0:
        stats["error_rate"] = stats["invalid_lines"] / non_empty_lines
    else:
        stats["error_rate"] = 1.0 if stats["total_lines"] > 0 else 0.0
    
    # strict模式检查错误率
    if strict and non_empty_lines > 0:
        if stats["valid_records"] == 0:
            raise OfflineLocalizationError(f"JSONL file {path.name} contains no valid records.")
        if stats["error_rate"] > max_error_rate:
            raise OfflineLocalizationError(
                f"JSONL file {path.name} corruption rate {stats['error_rate']:.2%} "
                f"exceeds threshold {max_error_rate:.2%}."
            )
    
    return values, stats


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
    # 转换为统一权重的边
    edge_weights = [(smoothness, smoothness * 1.5)] * (count - 1)
    return _solve_banded_weighted(count, observations, edge_weights, iterations=iterations)


def _solve_banded_weighted(
    count: int,
    observations: Sequence[tuple[int, float, float]],
    edge_weights: Sequence[tuple[float, float]],
    dim: int = 0,
    iterations: int = 120,
) -> list[float]:
    """Solve a 1-D correction field with per-edge weighted smoothness."""
    values = [0.0] * count
    by_index: dict[int, list[tuple[float, float]]] = {}
    for index, target, weight in observations:
        by_index.setdefault(index, []).append((target, weight))
    for _ in range(iterations):
        maximum_change = 0.0
        for index in range(count):
            numerator = 0.0
            denominator = 0.0
            # 左边的边（和index-1的连接）
            if index > 0:
                w = edge_weights[index-1][dim]
                numerator += w * values[index - 1]
                denominator += w
            # 右边的边（和index+1的连接）
            if index + 1 < count:
                w = edge_weights[index][dim]
                numerator += w * values[index + 1]
                denominator += w
            # 绝对观测
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
    max_relative_deformation_m: float = 0.05,  # 相邻节点最大相对形变5cm
    max_relative_deformation_rad: float = math.radians(2.0),  # 相邻节点最大相对旋转2度
) -> tuple[list[Pose], list[dict[str, Any]], list[dict[str, Any]], dict[str, Any]]:
    if not baseline:
        raise OfflineLocalizationError("Cannot optimize an empty trajectory.")
    n = len(baseline)
    active = list(constraints)
    rejected: list[dict[str, Any]] = []
    corrections = [[0.0] * n for _ in range(3)]
    
    # 预计算相邻节点的相对位姿和权重（基于距离加权，距离越近权重越高）
    edge_weights = []
    base_relative = []
    for i in range(n - 1):
        p1 = baseline[i]
        p2 = baseline[i+1]
        dx = p2.x - p1.x
        dy = p2.y - p1.y
        dyaw = _normalize_angle(p2.yaw - p1.yaw)
        dist = math.hypot(dx, dy)
        dt = abs(p2.timestamp - p1.timestamp) if p1.timestamp is not None and p2.timestamp is not None else 0.1
        # 距离小于20cm或者时间间隔小于0.1s的相邻帧，权重更高（连续帧）
        if dist < 0.2 or dt < 0.1:
            weight = 48.0  # 高权重，连续帧不能大幅形变
        elif dist < 1.0:
            weight = 24.0  # 中权重
        else:
            weight = 12.0  # 低权重，间隔远的帧允许更多调整
        edge_weights.append((weight, weight * 1.5))  # (xy权重, yaw权重)
        base_relative.append((dx, dy, dyaw, dist, dt))
    
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
        # 使用加权的相对位姿约束求解
        corrections[0] = _solve_banded_weighted(n, observations[0], edge_weights, dim=0)
        corrections[1] = _solve_banded_weighted(n, observations[1], edge_weights, dim=1)
        corrections[2] = _solve_banded_weighted(n, observations[2], edge_weights, dim=2)
    
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
    
    # 计算相对位姿残差和形变统计
    relative_residuals = []
    high_deformation_intervals = []
    max_deformation_xy = 0.0
    max_deformation_yaw = 0.0
    total_deformation_xy = 0.0
    for i in range(n - 1):
        p1_opt = optimized[i]
        p2_opt = optimized[i+1]
        dx_opt = p2_opt.x - p1_opt.x
        dy_opt = p2_opt.y - p1_opt.y
        dyaw_opt = _normalize_angle(p2_opt.yaw - p1_opt.yaw)
        dx_base, dy_base, dyaw_base, dist_base, dt_base = base_relative[i]
        
        res_xy = math.hypot(dx_opt - dx_base, dy_opt - dy_base)
        res_yaw = abs(_normalize_angle(dyaw_opt - dyaw_base))
        relative_residuals.append({
            "node_from": baseline[i].node_id,
            "node_to": baseline[i+1].node_id,
            "base_distance_m": dist_base,
            "time_delta_s": dt_base,
            "xy_residual_m": res_xy,
            "yaw_residual_deg": math.degrees(res_yaw),
        })
        max_deformation_xy = max(max_deformation_xy, res_xy)
        max_deformation_yaw = max(max_deformation_yaw, res_yaw)
        total_deformation_xy += res_xy
        
        # 检查局部形变是否超过门限
        if res_xy > max_relative_deformation_m or res_yaw > max_relative_deformation_rad:
            high_deformation_intervals.append({
                "constraint_id": f"relative_deformation_{i:06d}",
                "kind": "excessive_relative_deformation",
                "node_from": baseline[i].node_id,
                "node_to": baseline[i+1].node_id,
                "start_timestamp": baseline[i].timestamp,
                "end_timestamp": baseline[i+1].timestamp,
                "translation_residual_m": res_xy,
                "yaw_residual_deg": math.degrees(res_yaw),
                "reason": "local_deformation_exceeds_threshold",
            })
    
    # 将过大的局部形变加入拒绝列表
    rejected.extend(high_deformation_intervals)
    
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
    
    # 优化诊断信息
    diagnostics = {
        "converged": True,
        "iterations": iterations,
        "max_relative_deformation_m": max_deformation_xy,
        "max_relative_deformation_deg": math.degrees(max_deformation_yaw),
        "mean_relative_deformation_m": total_deformation_xy / max(1, n-1),
        "high_deformation_interval_count": len(high_deformation_intervals),
        "accepted_absolute_constraint_count": len(accepted),
        "rejected_constraint_count": len(rejected),
    }
    
    return optimized, accepted, rejected, diagnostics


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


def _point_to_segment_distance(
    point: tuple[float, float],
    start: tuple[float, float],
    end: tuple[float, float],
) -> tuple[float, float, tuple[float, float]]:
    """计算点到线段的距离，返回(距离, 投影比例, 投影点)"""
    dx, dy = end[0] - start[0], end[1] - start[1]
    length2 = dx * dx + dy * dy
    if length2 < 1e-8:
        return math.hypot(point[0] - start[0], point[1] - start[1]), 0.0, start
    ratio = max(
        0.0,
        min(1.0, ((point[0] - start[0]) * dx + (point[1] - start[1]) * dy) / length2),
    )
    projected = (start[0] + ratio * dx, start[1] + ratio * dy)
    distance = math.hypot(point[0] - projected[0], point[1] - projected[1])
    return distance, ratio * math.sqrt(length2), projected


def _segment_intersect(
    a1: tuple[float, float],
    a2: tuple[float, float],
    b1: tuple[float, float],
    b2: tuple[float, float],
) -> bool:
    """判断两条线段是否相交（不包括端点重合）"""
    def ccw(p1, p2, p3):
        return (p3[1] - p1[1]) * (p2[0] - p1[0]) > (p2[1] - p1[1]) * (p3[0] - p1[0])
    
    return (
        ccw(a1, b1, b2) != ccw(a2, b1, b2)
        and ccw(a1, a2, b1) != ccw(a1, a2, b2)
    )


def _associate_tag(
    tag: dict[str, Any],
    elements: Sequence[dict[str, Any]],
    camera_position: tuple[float, float] | None = None,
) -> dict[str, Any]:
    """
    安全的价签-货架关联，复用在线关联的安全门：
    1. 收集所有结构边（货架/柜台作为候选，柱体作为遮挡）
    2. 射线遮挡检查：相机到标签的视线不能被其他结构遮挡
    3. 候选唯一性检查：最优/次优margin必须足够大
    4. 端点检查：标签不能太靠近货架端点
    5. 远侧面检查：标签不能在货架的远侧面（相机看不到的一侧）
    6. 任何不确定情况都标记needs_review，不自动确认
    """
    position = tag.get("final_map_position") or tag.get("snapped_map_position")
    if not isinstance(position, dict):
        tag["needs_review"] = True
        tag["association_failure_reason"] = "invalid_position"
        return tag
    
    point = (float(position.get("x_m", 0)), float(position.get("y_m", 0)))
    MAX_ASSOCIATION_DISTANCE = 1.2  # 最大关联距离1.2m
    MIN_CANDIDATE_MARGIN = 0.2  # 最优次优最小margin 20cm
    ENDPOINT_PROXIMITY_THRESHOLD = 0.15  # 距离端点小于15cm标记review
    OCCLUSION_EPSILON = 0.05  # 遮挡判断容差5cm
    
    # 收集所有边：候选边（货架/柜台）和遮挡边（柱体）
    candidate_edges: list[tuple[dict[str, Any], str, tuple[float, float], tuple[float, float]]] = []
    occluder_edges: list[tuple[tuple[float, float], tuple[float, float]]] = []
    
    for element in elements:
        shape_type = element.get("shape_type")
        if shape_type in {"MapShelf", "MapTable", "MapTableFeature"}:
            for edge_id, start, end in _stable_edges(element):
                candidate_edges.append((element, edge_id, start, end))
        elif shape_type == "MapPillar":
            # 柱体作为遮挡物，添加其边
            for _, start, end in _stable_edges(element):
                occluder_edges.append((start, end))
    
    # 计算所有候选边的距离和信息
    candidates: list[tuple[float, dict[str, Any], str, float, tuple[float, float], tuple[float, float], tuple[float, float]]] = []
    for element, edge_id, start, end in candidate_edges:
        distance, offset, snapped = _point_to_segment_distance(point, start, end)
        if distance <= MAX_ASSOCIATION_DISTANCE:
            # 计算边的法向量，判断点在边的哪一侧
            dx, dy = end[0] - start[0], end[1] - start[1]
            length = math.hypot(dx, dy)
            if length < 1e-8:
                continue
            # 法向量（指向边的右侧）
            normal = (-dy / length, dx / length)
            # 点到边的向量
            vec_to_point = (point[0] - snapped[0], point[1] - snapped[1])
            side_dot = vec_to_point[0] * normal[0] + vec_to_point[1] * normal[1]
            is_far_side = False
            # 如果有相机位置，检查是否在远侧面（相机在另一侧）
            if camera_position is not None:
                vec_to_camera = (camera_position[0] - snapped[0], camera_position[1] - snapped[1])
                camera_dot = vec_to_camera[0] * normal[0] + vec_to_camera[1] * normal[1]
                # 点和相机在边的两侧，说明点在远侧面，被货架本身遮挡
                if side_dot * camera_dot < -OCCLUSION_EPSILON:
                    is_far_side = True
            # 检查是否靠近端点
            dist_to_start = math.hypot(point[0] - start[0], point[1] - start[1])
            dist_to_end = math.hypot(point[0] - end[0], point[1] - end[1])
            near_endpoint = min(dist_to_start, dist_to_end) < ENDPOINT_PROXIMITY_THRESHOLD
            candidates.append((distance, element, edge_id, offset, snapped, start, end, is_far_side, near_endpoint))
    
    if not candidates:
        tag["needs_review"] = True
        tag["association_failure_reason"] = "no_candidate_within_range"
        tag["association_confidence"] = 0.0
        return tag
    
    # 按距离排序
    candidates.sort(key=lambda x: (x[0], str(x[1].get("id")), x[2]))
    best = candidates[0]
    best_distance, best_element, best_edge_id, best_offset, best_snapped, best_start, best_end, best_far_side, best_near_endpoint = best
    
    # 检查候选唯一性
    candidate_margin = float("inf")
    if len(candidates) >= 2:
        candidate_margin = candidates[1][0] - best_distance
    
    # 遮挡检查：相机到标签点的线段是否与任何遮挡边或其他候选边相交
    has_occlusion = False
    occlusion_reason = None
    if camera_position is not None:
        # 检查柱体遮挡
        for occ_start, occ_end in occluder_edges:
            if _segment_intersect(camera_position, point, occ_start, occ_end):
                has_occlusion = True
                occlusion_reason = "occluded_by_pillar"
                break
        # 检查其他货架边遮挡（不是最佳边本身）
        if not has_occlusion:
            for _, _, _, _, _, edge_start, edge_end, _, _ in candidates[1:]:
                # 跳过和最佳边共线或距离太近的边
                if _segment_intersect(camera_position, point, edge_start, edge_end):
                    # 检查交点是否在相机和点之间
                    dist_intersect_to_cam = math.hypot(
                        (edge_start[0] + edge_end[0])/2 - camera_position[0],
                        (edge_start[1] + edge_end[1])/2 - camera_position[1]
                    )
                    dist_point_to_cam = math.hypot(
                        point[0] - camera_position[0],
                        point[1] - camera_position[1]
                    )
                    if dist_intersect_to_cam < dist_point_to_cam - OCCLUSION_EPSILON:
                        has_occlusion = True
                        occlusion_reason = "occluded_by_other_structure"
                        break
    
    # 综合判断是否需要review
    needs_review = (
        best_distance > 0.45
        or best_far_side
        or best_near_endpoint
        or has_occlusion
        or candidate_margin < MIN_CANDIDATE_MARGIN
        or float(tag.get("association_confidence", 1.0)) < 0.65
    )
    
    # 如果在线已经有人工确认的关联，保留人工确认，不自动覆盖
    if tag.get("manually_associated") is True and tag.get("shelf_code") is not None:
        tag["association_note"] = "保留在线人工确认关联，离线仅做位置变换"
        tag["needs_review"] = tag.get("needs_review", False) or needs_review
        return tag
    
    # 只有在所有安全检查通过时才自动关联，否则标记review
    if not needs_review:
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
                "association_confidence": round(max(0.0, min(1.0, 1 - best_distance / MAX_ASSOCIATION_DISTANCE)), 6),
                "association_audit": {
                    "best_distance_m": best_distance,
                    "second_best_distance_m": candidates[1][0] if len(candidates) >= 2 else None,
                    "candidate_margin_m": candidate_margin,
                    "is_far_side": best_far_side,
                    "near_endpoint": best_near_endpoint,
                    "has_occlusion": has_occlusion,
                    "occlusion_reason": occlusion_reason,
                    "candidate_count": len(candidates),
                }
            }
        )
        tag["needs_review"] = False
        tag["association_failure_reason"] = None
    else:
        # 不确定的情况，保留原始位置，标记需要人工复核
        reasons = []
        if best_distance > 0.45:
            reasons.append(f"distance_too_large_{best_distance:.2f}m")
        if best_far_side:
            reasons.append("far_side_of_shelf")
        if best_near_endpoint:
            reasons.append("near_shelf_endpoint")
        if has_occlusion:
            reasons.append(occlusion_reason or "occluded")
        if candidate_margin < MIN_CANDIDATE_MARGIN:
            reasons.append(f"ambiguous_candidates_margin_{candidate_margin:.2f}m")
        tag["needs_review"] = True
        tag["association_failure_reason"] = ",".join(reasons)
        tag["association_confidence"] = round(max(0.0, min(1.0, 1 - best_distance / MAX_ASSOCIATION_DISTANCE)), 6)
        # 给出最佳候选作为建议，但不自动确认
        tag["suggested_association"] = {
            "shelf_code": best_element.get("code") or None,
            "shelf_side": best_edge_id,
            "distance_from_shelf_start_cm": round(best_offset * 100, 3),
            "snapped_position": {
                "x_m": round(best_snapped[0], 6),
                "y_m": round(best_snapped[1], 6),
            }
        }
    
    return tag


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


def new_manual_edits(
    map_sha256: str,
    session_sha256: str,
    source_database_sha256: str | None = None,
    optimized_database_sha256: str | None = None,
    processing_parameters: dict[str, Any] | None = None,
    tool_version: str = "1.1.0",
) -> dict[str, Any]:
    return {
        "format": "MarketScannerManualEdits",
        "version": 2,
        "revision": 1,  # 乐观锁版本号，每次修改+1
        "prior_map_sha256": map_sha256,
        "source_session_sha256": session_sha256,
        "source_database_sha256": source_database_sha256,
        "optimized_database_sha256": optimized_database_sha256,
        "processing_parameters": processing_parameters or {},
        "tool_version": tool_version,
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
        # 允许人工修改的字段白名单
        allowed_fields = {
            "shelf_code": str,
            "shelf_side": str,
            "row_flag": int,
            "cross_code": str,
            "distance_from_shelf_start_cm": (int, float),
            "height_cm": (int, float),
            "needs_review": bool,
            "approval_status": str,
            "manual_position": dict,
            "notes": str,
        }
        # 验证字段和类型
        for field, field_value in value.items():
            if field not in allowed_fields:
                raise OfflineLocalizationError(
                    f"edit_tag does not allow modifying field: {field}. "
                    f"Allowed fields: {', '.join(allowed_fields.keys())}"
                )
            expected_type = allowed_fields[field]
            if not isinstance(field_value, expected_type):
                raise OfflineLocalizationError(
                    f"edit_tag field {field} must be of type {expected_type}, got {type(field_value)}"
                )
            # 范围验证
            if field == "shelf_side" and field_value not in {"left", "right", "unknown"}:
                raise OfflineLocalizationError("shelf_side must be 'left', 'right' or 'unknown'")
            if field == "row_flag" and not (1 <= field_value <= 8):
                raise OfflineLocalizationError("row_flag must be between 1 and 8")
            if field == "distance_from_shelf_start_cm" and not (0 <= field_value <= 10000):
                raise OfflineLocalizationError("distance_from_shelf_start_cm must be between 0 and 10000")
            if field == "height_cm" and not (0 <= field_value <= 300):
                raise OfflineLocalizationError("height_cm must be between 0 and 300")
            if field == "approval_status" and field_value not in {"pending", "approved", "rejected"}:
                raise OfflineLocalizationError("approval_status must be 'pending', 'approved' or 'rejected'")
            if field == "manual_position":
                if "x_m" not in field_value or "y_m" not in field_value:
                    raise OfflineLocalizationError("manual_position must contain x_m and y_m")
                try:
                    x = float(field_value["x_m"])
                    y = float(field_value["y_m"])
                except (TypeError, ValueError):
                    raise OfflineLocalizationError("manual_position x_m/y_m must be numbers")
                if not (-1000 <= x <= 1000 and -1000 <= y <= 1000):
                    raise OfflineLocalizationError("manual_position coordinates out of valid range")
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
    expected_revision: int | None = None,
) -> dict[str, Any]:
    validate_manual_edit_event(event)
    current_revision = int(journal.get("revision", 1))
    # 乐观锁检查
    if expected_revision is not None and current_revision != expected_revision:
        raise OfflineLocalizationError(
            f"Revision conflict: expected {expected_revision}, current {current_revision}. "
            "Please refresh and try again."
        )
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
    return {
        **journal,
        "events": events,
        "cursor": len(events),
        "revision": current_revision + 1,  # 每次修改版本号+1
    }


def move_manual_edit_cursor(
    journal: dict[str, Any],
    delta: int,
    expected_revision: int | None = None,
) -> dict[str, Any]:
    current_revision = int(journal.get("revision", 1))
    # 乐观锁检查
    if expected_revision is not None and current_revision != expected_revision:
        raise OfflineLocalizationError(
            f"Revision conflict: expected {expected_revision}, current {current_revision}. "
            "Please refresh and try again."
        )
    events = list(journal.get("events", []))
    cursor = max(0, min(len(events), int(journal.get("cursor", len(events))) + delta))
    return {
        **journal,
        "cursor": cursor,
        "revision": current_revision + 1,  # undo/redo也算修改，版本号+1
    }


def process_localized_session(
    prior_map: Path,
    session: Path,
    optimized_poses: Sequence[Pose],
    source_database: Path,
    optimized_database: Path,
    output: Path,
    manual_edits: dict[str, Any] | None = None,
    progress: Callable[[int, str, str], None] | None = None,
    publish_state: str = "draft",  # draft/review/published
    allow_automatic_publish: bool = False,  # 默认禁止自动发布，必须人工确认
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
        # 计算优化数据库hash
        optimized_hash = _sha256(optimized_database)
        manual_edits = new_manual_edits(
            map_sha256=package_hash,
            session_sha256=session_hash,
            source_database_sha256=source_hash_before,
            optimized_database_sha256=optimized_hash,
            processing_parameters={
                "resolution": 0.05,
                "tag_snap_distance": 1.0,
                "max_correction_threshold": 1.5,
                "acceptance_rate_threshold": 0.55,
            }
        )
    # 计算当前数据库hash用于验证
    current_source_hash = source_hash_before
    current_optimized_hash = _sha256(optimized_database)
    
    # 验证journal身份绑定
    journal_source_hash = manual_edits.get("source_database_sha256")
    journal_optimized_hash = manual_edits.get("optimized_database_sha256")
    if (
        manual_edits.get("prior_map_sha256") != package_hash
        or manual_edits.get("source_session_sha256") != session_hash
        or (journal_source_hash is not None and journal_source_hash != current_source_hash)
        or (journal_optimized_hash is not None and journal_optimized_hash != current_optimized_hash)
    ):
        raise OfflineLocalizationError(
            "manual_edits.json does not match this map/session/database version. "
            "Please re-export or create a new edit journal."
        )
    # 兼容旧版本journal，补充缺失的身份字段
    if manual_edits.get("version", 1) < 2:
        manual_edits["version"] = 2
        manual_edits["revision"] = 1
        manual_edits["source_database_sha256"] = current_source_hash
        manual_edits["optimized_database_sha256"] = current_optimized_hash
        manual_edits["processing_parameters"] = {
            "resolution": 0.05,
            "tag_snap_distance": 1.0,
            "max_correction_threshold": 1.5,
            "acceptance_rate_threshold": 0.55,
        }
        manual_edits["tool_version"] = "1.1.0"
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

    # 读取关键JSONL文件，使用严格模式，损坏直接失败
    trace, trace_stats = _read_jsonl(segment / "localization_trace.jsonl", strict=True)
    raw_constraints, constraints_stats = _read_jsonl(segment / "localization_constraints.jsonl", strict=True)
    manual_events, manual_events_stats = _read_jsonl(segment / "manual_localization_events.jsonl", strict=False)
    tag_observations, tag_obs_stats = _read_jsonl(segment / "tag_observations.jsonl", strict=True)
    state_events, state_events_stats = _read_jsonl(segment / "localization_events.jsonl", strict=True)
    raw_tags_value = load_json(segment / "localized_price_tags.json") if (
        segment / "localized_price_tags.json"
    ).is_file() else []
    raw_tags = [dict(item) for item in raw_tags_value if isinstance(item, dict)]
    review_items: list[dict[str, Any]] = []  # 提前初始化复核项列表
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
    MAX_MANUAL_EVENT_TIME_DIFF_S = 1.0  # 人工事件与节点时间差最大1秒
    manual_anchor_warnings = []
    for sequence, record in enumerate(manual_events, start=1):
        pose = _pose_from(record.get("confirmedMapPose"))
        if pose is None:
            pose = _pose_from(record.get("confirmed_map_pose"))
        if pose is None:
            continue
        
        event_version = int(record.get("version", 1))
        # 优先使用同源时间戳：frameTimestamp > timestampUnix
        use_timestamp = None
        time_source = None
        if event_version >= 2 and record.get("frameTimestamp") is not None:
            try:
                use_timestamp = float(record.get("frameTimestamp"))
                time_source = "frameTimestamp"
            except (TypeError, ValueError):
                pass
        
        if use_timestamp is None and record.get("timestampUnix") is not None:
            try:
                use_timestamp = float(record.get("timestampUnix"))
                time_source = "timestampUnix"
                # 旧版本事件（无frameTimestamp）添加警告
                if event_version < 2:
                    manual_anchor_warnings.append({
                        "type": "legacy_manual_event",
                        "event_id": f"manual-{sequence:06d}",
                        "message": "旧版本人工锚点事件无同源frameTimestamp，使用Unix时间匹配，可能存在时间基准偏差",
                        "severity": "warning"
                    })
            except (TypeError, ValueError):
                pass
        
        # 查找节点
        node_index = None
        time_diff = None
        if record.get("nearestNodeId") is not None:
            # 如果有明确的节点ID，优先使用
            try:
                target_id = int(record.get("nearestNodeId"))
                for idx, p in enumerate(baseline):
                    if p.index == target_id:
                        node_index = idx
                        break
            except (TypeError, ValueError):
                pass
        
        if node_index is None and use_timestamp is not None:
            node_index = _nearest_pose_index(baseline, use_timestamp)
            # 计算时间差
            if node_index is not None and baseline[node_index].timestamp is not None:
                time_diff = abs(baseline[node_index].timestamp - use_timestamp)
                if time_diff > MAX_MANUAL_EVENT_TIME_DIFF_S:
                    manual_anchor_warnings.append({
                        "type": "manual_event_time_mismatch",
                        "event_id": f"manual-{sequence:06d}",
                        "message": f"人工锚点与最近节点时间差{time_diff:.2f}s超过阈值{MAX_MANUAL_EVENT_TIME_DIFF_S}s，需要人工选择节点",
                        "severity": "error",
                        "time_diff_seconds": time_diff,
                        "time_source": time_source
                    })
                    continue  # 时间差太大，不自动应用
        
        if node_index is None:
            manual_anchor_warnings.append({
                "type": "manual_event_no_matching_node",
                "event_id": f"manual-{sequence:06d}",
                "message": "人工锚点找不到匹配的轨迹节点，需要人工选择",
                "severity": "error"
            })
            continue
        
        constraints.append(
            AbsoluteConstraint(
                identifier=f"manual-{sequence:06d}",
                node_index=node_index,
                x=pose[0],
                y=pose[1],
                yaw=pose[2],
                weight=80.0,
                kind="manual_anchor",
                source={
                    **record,
                    "_time_source": time_source,
                    "_time_diff_seconds": time_diff,
                    "_event_version": event_version
                },
            )
        )
    # 将人工锚点警告加入复核项
    review_items.extend(manual_anchor_warnings)
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
    optimized, accepted, rejected, optimization_diagnostics = optimize_trajectory(baseline, constraints)

    elements_payload = load_json(prior_map / "elements.json")
    elements = elements_payload.get("elements", []) if isinstance(elements_payload, dict) else []
    final_tags: list[dict[str, Any]] = []
    observations_by_id = {
        str(item.get("observation_id")): item for item in tag_observations
    }
    for tag in raw_tags:
        observation = observations_by_id.get(str(tag.get("observation_id")), {})
        index = _nearest_pose_index(
            baseline,
            float(observation["frame_timestamp"])
            if observation.get("frame_timestamp") is not None
            else None,
        )
        # 获取基线和优化后的位姿
        base_pose = baseline[index]
        opt_pose = optimized[index]
        x_base, y_base, yaw_base = base_pose.x, base_pose.y, base_pose.yaw
        x_opt, y_opt, yaw_opt = opt_pose.x, opt_pose.y, opt_pose.yaw
        
        original = tag.get("snapped_map_position") or tag.get("raw_map_position")
        if isinstance(original):
            x_online = float(original.get("x_m", 0))
            y_online = float(original.get("y_m", 0))
            tag["online_map_position"] = dict(original)
            
            # 完整SE(2)刚体变换：DeltaT = T_opt * inverse(T_base) * P_online
            # 1. 转换到基线节点局部坐标系
            dx_global = x_online - x_base
            dy_global = y_online - y_base
            cos_base = math.cos(yaw_base)
            sin_base = math.sin(yaw_base)
            local_x = dx_global * cos_base + dy_global * sin_base
            local_y = -dx_global * sin_base + dy_global * cos_base
            
            # 2. 转换到优化后节点的全局坐标系
            cos_opt = math.cos(yaw_opt)
            sin_opt = math.sin(yaw_opt)
            x_final = local_x * cos_opt - local_y * sin_opt + x_opt
            y_final = local_x * sin_opt + local_y * cos_opt + y_opt
            
            # 计算平移和旋转贡献（审计用）
            dx_trans = x_opt - x_base
            dy_trans = y_opt - y_base
            dyaw = yaw_opt - yaw_base
            # 归一化角度到[-pi, pi]
            dyaw = (dyaw + math.pi) % (2 * math.pi) - math.pi
            
            tag["final_map_position"] = {
                "x_m": x_final,
                "y_m": y_final,
                "height_m": original.get("height_m"),
            }
            tag["transform_audit"] = {
                "node_id": base_pose.index,
                "node_timestamp": base_pose.timestamp,
                "time_delta_seconds": observation.get("time_delta_seconds", 0.0),
                "base_pose": {"x_m": x_base, "y_m": y_base, "yaw_rad": yaw_base},
                "optimized_pose": {"x_m": x_opt, "y_m": y_opt, "yaw_rad": yaw_opt},
                "delta_translation_m": {"dx": dx_trans, "dy": dy_trans},
                "delta_rotation_rad": dyaw,
                "rotation_contribution_m": {
                    "dx": x_final - (x_online + dx_trans),
                    "dy": y_final - (y_online + dy_trans),
                }
            }
            tag["online_offline_distance_cm"] = round(math.hypot(x_final - x_online, y_final - y_online) * 100, 3)
        tag.setdefault("manually_modified", False)
        tag.setdefault("approval_status", "pending" if tag.get("needs_review") else "auto_approved")
        # 传入相机位置（优化后的节点位置）用于遮挡检查
        camera_pos = (x_opt, y_opt)
        final_tags.append(_associate_tag(tag, elements, camera_position=camera_pos))
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
    review_items.extend(
        {
            "id": f"rejected-{index:06d}",
            "type": "rejected_constraint",
            "severity": "warning",
            "message": f"地图约束 {item['constraint_id']} 被稳健门限拒绝。",
            "details": item,
        }
        for index, item in enumerate(rejected, start=1)
    )
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
    total_tags = len(final_tags)
    tags_with_position = sum(1 for tag in final_tags if tag.get("final_map_position") is not None)
    tags_with_shelf = sum(1 for tag in final_tags if tag.get("shelf_code"))
    tag_coverage_ratio = tags_with_position / max(1, total_tags)
    shelf_association_rate = tags_with_shelf / max(1, total_tags)
    node_coverage_ratio = len(optimized) / max(1, len(baseline)) if baseline else 0.0
    
    # 严格发布硬指标
    strict_publish_criteria_met = (
        bool(optimized)
        and node_coverage_ratio >= 1.0
        and tag_coverage_ratio >= 0.95
        and shelf_association_rate >= 0.95
        and acceptance_rate >= 0.70
        and max_correction <= 1.0
        and not rejected
        and needs_review_count == 0
        and report["input_file_validation"]["all_critical_files_valid"]
        and optimization_diagnostics["high_deformation_interval_count"] == 0
        and len(weak_lost_intervals) == 0
    )
    
    # 三级发布状态：
    # - draft: 自动生成，未经过人工检查，不可作为权威结果
    # - review: 满足基本质量，需要人工复核
    # - published: 人工确认通过，满足所有硬指标，可作为权威结果
    if publish_state == "published" and allow_automatic_publish and strict_publish_criteria_met:
        final_publish_state = "published"
    elif strict_publish_criteria_met:
        final_publish_state = "review"  # 满足指标但需要人工确认才能发布
    else:
        final_publish_state = "draft"
    
    automatic_publish = (final_publish_state == "published")
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
        "optimization_diagnostics": optimization_diagnostics,
        "input_file_validation": {
            "localization_trace": trace_stats,
            "localization_constraints": constraints_stats,
            "manual_localization_events": manual_events_stats,
            "tag_observations": tag_obs_stats,
            "localization_state_events": state_events_stats,
            "all_critical_files_valid": (
                trace_stats["error_rate"] == 0.0
                and constraints_stats["error_rate"] == 0.0
                and tag_obs_stats["error_rate"] == 0.0
                and state_events_stats["error_rate"] == 0.0
            )
        },
        "node_count": len(optimized),
        "node_coverage_ratio": node_coverage_ratio,
        "total_tag_count": total_tags,
        "tag_coverage_ratio": tag_coverage_ratio,
        "shelf_association_rate": shelf_association_rate,
        "needs_review_tag_count": needs_review_count,
        "accepted_constraint_count": len(accepted),
        "rejected_constraint_count": len(rejected),
        "constraint_acceptance_rate": acceptance_rate,
        "max_correction_m": max_correction,
        "publish_state": final_publish_state,
        "strict_publish_criteria_met": strict_publish_criteria_met,
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

    # ========== 原子事务写入：先写临时目录，校验后原子发布 ==========
    import tempfile
    import shutil
    import time
    
    # 创建临时目录（和output同分区，保证rename原子性）
    temp_dir = output.parent / f".{output.name}.tmp.{int(time.time() * 1000)}"
    temp_dir.mkdir(parents=True, exist_ok=False)
    
    try:
        # 复制先验地图manifest
        shutil.copy2(prior_map / "manifest.json", temp_dir / "prior_map_manifest.json")
        # 写入source manifest，不包含本机绝对路径，只保留ID和hash
        _json_write(
            temp_dir / "source_manifest.json",
            {
                "format": "MarketScannerLocalizedSourceManifest",
                "version": 2,
                "source_session_id": session.name,
                "source_database_filename": source_database.name,
                "source_database_sha256": source_hash_before,
                "source_database_immutable": True,
                "optimized_database_filename": optimized_database.name,
                "optimized_database_sha256": _sha256(optimized_database),
                "prior_map_id": manifest.get("prior_map_id"),
                "prior_map_sha256": package_hash,
            },
        )
        # 所有输出先写入临时目录
        _json_write(
            temp_dir / "processing_manifest.json",
            {
                "format": "MarketScannerLocalizedProcessing",
                "version": 2,
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
                "automatic_publish_allowed": allow_automatic_publish,
                "publish_state": final_publish_state,
                "publish_timestamp": time.time(),
                "tool_version": "1.1.0",
            },
        )
        _json_write(temp_dir / "online_localization_trace.json", trace)
        trajectory_payload = _trajectory_geojson(baseline, optimized, trace)
        _json_write(temp_dir / "optimized_map_trajectory.geojson", trajectory_payload)
        _json_write(
            temp_dir / "localization_constraints.json",
            {
                "format": "MarketScannerOfflineLocalizationConstraints",
                "version": 1,
                "raw": constraint_records,
                "accepted": accepted,
                "rejected": rejected,
            },
        )
        _json_write(temp_dir / "localization_report.json", report)
        _json_write(
            temp_dir / "review_items.json",
            {
                "format": "MarketScannerLocalizationReviewItems",
                "version": 1,
                "items": review_items,
            },
        )
        _json_write(
            temp_dir / "localized_review.json",
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
        _json_write(temp_dir / "manual_edits.json", manual_edits)
        _json_write(temp_dir / "localized_price_tags.json", final_tags)
        with (temp_dir / "localized_price_tags.csv").open(
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
                            if position.get("height_m") is not None
                            else None
                        ),
                    }
                )
        
        # 写入GeoJSON价签图层
        _json_write(
            temp_dir / "localized_price_tags.geojson",
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
        # 写入货架-价签索引
        shelf_index: dict[str, list[str]] = {}
        for tag in final_tags:
            shelf = str(tag.get("shelf_code") or "")
            if shelf:
                shelf_index.setdefault(shelf, []).append(str(tag.get("tag_id")))
        _json_write(
            temp_dir / "shelf_tag_index.json",
            {
                "format": "MarketScannerShelfTagIndex",
                "version": 1,
                "shelves": {key: sorted(value) for key, value in sorted(shelf_index.items())},
            },
        )
        # 写入审计日志
        _json_write(
            temp_dir / "audit_log.jsonl",
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
        
        # ========== 完整性校验 ==========
        required_files = [
            "processing_manifest.json",
            "localization_report.json",
            "review_items.json",
            "localized_review.json",
            "localized_price_tags.json",
            "localized_price_tags.csv",
            "localized_price_tags.geojson",
            "optimized_map_trajectory.geojson",
            "localization_constraints.json",
            "manual_edits.json",
            "shelf_tag_index.json",
            "audit_log.jsonl",
        ]
        for filename in required_files:
            file_path = temp_dir / filename
            if not file_path.is_file():
                raise OfflineLocalizationError(f"Required output file missing: {filename}")
            # 校验JSON文件是有效的
            if filename.endswith(".json") or filename.endswith(".geojson"):
                try:
                    with open(file_path, "r", encoding="utf-8") as f:
                        json.load(f)
                except json.JSONDecodeError as e:
                    raise OfflineLocalizationError(f"Output file {filename} is invalid JSON: {e}")
        
        # ========== 原子发布 ==========
        # 备份旧版本
        backup_dir = None
        if output.exists():
            backup_dir = output.parent / f"{output.name}.bak.{int(time.time() * 1000)}"
            output.rename(backup_dir)
        
        # 原子替换：临时目录重命名为正式目录
        temp_dir.rename(output)
        
        # 清理旧备份（保留最近2个备份）
        all_backups = sorted(
            output.parent.glob(f"{output.name}.bak.*"),
            key=lambda p: p.stat().st_mtime,
            reverse=True
        )
        for old_backup in all_backups[2:]:
            shutil.rmtree(old_backup, ignore_errors=True)
            
    except Exception as e:
        # 任何错误，清理临时目录，不影响原有结果
        shutil.rmtree(temp_dir, ignore_errors=True)
        raise e
    
    if progress:
        progress(
            97,
            "质量门禁与导出",
            "离线轨迹、价签结果、复核项和审计记录已生成",
        )
    return report
        ]
        for filename in required_files:
            file_path = temp_dir / filename
            if not file_path.is_file():
                raise OfflineLocalizationError(f"Required output file missing: {filename}")
            # 校验JSON文件是有效的
            if filename.endswith(".json") or filename.endswith(".geojson"):
                try:
                    with open(file_path, "r", encoding="utf-8") as f:
                        json.load(f)
                except json.JSONDecodeError as e:
                    raise OfflineLocalizationError(f"Output file {filename} is invalid JSON: {e}")
        
        # ========== 原子发布 ==========
        # 备份旧版本
        backup_dir = None
        if output.exists():
            backup_dir = output.parent / f"{output.name}.bak.{int(time.time() * 1000)}"
            output.rename(backup_dir)
        
        # 原子替换：临时目录重命名为正式目录
        temp_dir.rename(output)
        
        # 清理旧备份（保留最近3个备份）
        all_backups = sorted(
            output.parent.glob(f"{output.name}.bak.*"),
            key=lambda p: p.stat().st_mtime,
            reverse=True
        )
        for old_backup in all_backups[2:]:  # 保留最近2个备份
            shutil.rmtree(old_backup, ignore_errors=True)
            
    except Exception as e:
        # 任何错误，清理临时目录，不影响原有结果
        shutil.rmtree(temp_dir, ignore_errors=True)
        raise e
