#!/usr/bin/env python3
"""Manual duplicate-region alignment translated into RTAB-Map user closures.

The browser selects two image-space regions from an already generated map.
This module resolves the regions back to optimized poses, estimates node
correspondences after a user-visible planar alignment, and emits kUserClosure
rows suitable for injection into a disposable database copy.
"""

from __future__ import annotations

import hashlib
import json
import math
import sqlite3
import statistics
import struct
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Sequence, Tuple

import supermarket_2d_map as base


class MergeProcessingError(ValueError):
    pass


INFORMATION_LEVELS = {
    "weak": {"linear_variance": 0.08, "angular_variance": 0.08},
    "medium": {"linear_variance": 0.03, "angular_variance": 0.03},
    "strong": {"linear_variance": 0.01, "angular_variance": 0.01},
}
MAX_CONSTRAINTS = 12
MIN_REGION_NODE_COUNT = 2


@dataclass(frozen=True)
class MapGeometry:
    width: int
    height: int
    resolution: float
    origin_x: float
    origin_y: float
    horizontal_axes: str

    def pixel_to_world(self, pixel: Sequence[float]) -> Tuple[float, float]:
        if len(pixel) != 2:
            raise MergeProcessingError("Pixel coordinates must contain x and y.")
        return (
            self.origin_x + float(pixel[0]) * self.resolution,
            self.origin_y + (self.height - 1 - float(pixel[1])) * self.resolution,
        )

    def world_to_pixel(self, point: Sequence[float]) -> Tuple[float, float]:
        return (
            (float(point[0]) - self.origin_x) / self.resolution,
            self.height - 1 - (float(point[1]) - self.origin_y) / self.resolution,
        )


@dataclass(frozen=True)
class PoseRecord:
    node_id: int
    matrix: Tuple[float, ...]
    map_x: float
    map_y: float
    yaw: float


def _load_json(path: Path) -> Dict[str, Any]:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as exc:
        raise MergeProcessingError(f"Required merge artifact is missing: {path.name}") from exc
    except json.JSONDecodeError as exc:
        raise MergeProcessingError(f"Merge artifact is invalid JSON: {path.name}: {exc}") from exc
    if not isinstance(payload, dict):
        raise MergeProcessingError(f"Merge artifact must contain an object: {path.name}")
    return payload


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def result_context(result_dir: Path) -> Dict[str, Any]:
    result_dir = result_dir.resolve()
    map_payload = _load_json(result_dir / "map.json")
    layers_path = result_dir / "preview_layers.json"
    layers = _load_json(layers_path)
    width = int(layers.get("width") or 0)
    height = int(layers.get("height") or 0)
    resolution = float(
        layers.get("resolution_m")
        or map_payload.get("parameters", {}).get("resolution")
        or 0
    )
    origin = layers.get("origin")
    if width <= 0 or height <= 0 or resolution <= 0:
        raise MergeProcessingError(
            "This result does not contain metric preview-layer dimensions. Regenerate the map before manual repair."
        )
    if not isinstance(origin, list) or len(origin) != 2:
        raise MergeProcessingError(
            "This result predates metric preview-layer origins. Regenerate the map before manual repair."
        )
    axes = str(map_payload.get("parameters", {}).get("horizontal_axes") or "xz")
    if axes not in {"xz", "xy"}:
        raise MergeProcessingError(f"Unsupported horizontal axes: {axes}")
    session_raw = map_payload.get("session")
    if not isinstance(session_raw, str) or not session_raw:
        raise MergeProcessingError("The result does not identify its source scan session.")
    session = Path(session_raw).expanduser().resolve()
    if not session.is_dir():
        raise MergeProcessingError(f"The source scan session is unavailable: {session}")

    database = _result_database(result_dir, session)
    geometry = MapGeometry(
        width=width,
        height=height,
        resolution=resolution,
        origin_x=float(origin[0]),
        origin_y=float(origin[1]),
        horizontal_axes=axes,
    )
    return {
        "result_dir": result_dir,
        "session": session,
        "database": database,
        "map": map_payload,
        "layers": layers,
        "layers_sha256": _sha256(layers_path),
        "geometry": geometry,
    }


def _result_database(result_dir: Path, session: Path) -> Path:
    report_path = result_dir / "offline_processing_report.json"
    if report_path.is_file():
        report = _load_json(report_path)
        entries = report.get("databases")
        if isinstance(entries, list):
            for entry in reversed(entries):
                if not isinstance(entry, dict):
                    continue
                raw_path = entry.get("output", {}).get("path")
                if isinstance(raw_path, str) and Path(raw_path).expanduser().is_file():
                    return Path(raw_path).expanduser().resolve()
    optimized = sorted(
        (result_dir / "rtabmap_optimized").glob("*.db"),
        key=lambda path: path.stat().st_mtime,
        reverse=True,
    )
    if optimized:
        return optimized[0].resolve()
    databases = sorted(session.glob("segment_*/rtabmap*.db"))
    if len(databases) != 1:
        raise MergeProcessingError(
            "Manual repair currently requires one continuous RTAB-Map database."
        )
    return databases[0].resolve()


def _load_poses(database: Path, axes: str) -> List[PoseRecord]:
    try:
        connection = sqlite3.connect(f"file:{database}?mode=ro", uri=True)
    except sqlite3.Error as exc:
        raise MergeProcessingError(f"Cannot read merge source database: {exc}") from exc
    try:
        tables = set(base.sqlite_tables(connection))
        if "Node" not in tables:
            raise MergeProcessingError("The merge source database has no Node table.")
        optimized = base.extract_optimized_pose_blobs(connection)
        records: List[PoseRecord] = []
        for node_id, raw_pose in connection.execute(
            "SELECT id, pose FROM Node WHERE id > 0 ORDER BY id"
        ):
            blob = optimized.get(int(node_id)) or raw_pose
            matrix = base.parse_transform_matrix(blob)
            parsed = base.parse_rtabmap_transform_3d(blob, axes)
            if matrix is None or parsed is None:
                continue
            map_x, map_y, _height, yaw = parsed
            records.append(
                PoseRecord(
                    node_id=int(node_id),
                    matrix=tuple(float(value) for value in matrix),
                    map_x=float(map_x),
                    map_y=float(map_y),
                    yaw=float(yaw),
                )
            )
    except sqlite3.Error as exc:
        raise MergeProcessingError(f"Cannot read poses for manual repair: {exc}") from exc
    finally:
        connection.close()
    if len(records) < 2:
        raise MergeProcessingError("Manual repair needs at least two valid database poses.")
    return records


def _normalize_region(
    raw: Any,
    label: str,
    geometry: MapGeometry,
) -> Dict[str, Any]:
    if not isinstance(raw, dict):
        raise MergeProcessingError(f"Region {label} must be an object.")
    rectangle = raw.get("rect_pixels")
    if not isinstance(rectangle, list) or len(rectangle) != 4:
        raise MergeProcessingError(f"Region {label} must contain rect_pixels [x0,y0,x1,y1].")
    try:
        values = [float(value) for value in rectangle]
    except (TypeError, ValueError) as exc:
        raise MergeProcessingError(f"Region {label} coordinates must be numeric.") from exc
    if not all(math.isfinite(value) for value in values):
        raise MergeProcessingError(f"Region {label} contains non-finite coordinates.")
    x0, x1 = sorted(
        (
            min(float(geometry.width - 1), max(0.0, values[0])),
            min(float(geometry.width - 1), max(0.0, values[2])),
        )
    )
    y0, y1 = sorted(
        (
            min(float(geometry.height - 1), max(0.0, values[1])),
            min(float(geometry.height - 1), max(0.0, values[3])),
        )
    )
    if x1 - x0 < 4 or y1 - y0 < 4:
        raise MergeProcessingError(f"Region {label} is too small; drag a larger map area.")
    center_pixel = ((x0 + x1) / 2, (y0 + y1) / 2)
    center_world = geometry.pixel_to_world(center_pixel)
    return {
        "label": label,
        "rect_pixels": [
            round(x0, 3),
            round(y0, 3),
            round(x1, 3),
            round(y1, 3),
        ],
        "center_pixel": [round(center_pixel[0], 3), round(center_pixel[1], 3)],
        "center_world": [round(center_world[0], 4), round(center_world[1], 4)],
        "width_m": round((x1 - x0) * geometry.resolution, 4),
        "height_m": round((y1 - y0) * geometry.resolution, 4),
        "area_m2": round(
            (x1 - x0) * (y1 - y0) * geometry.resolution * geometry.resolution,
            4,
        ),
    }


def _region_contains(region: Dict[str, Any], pixel: Sequence[float]) -> bool:
    x0, y0, x1, y1 = region["rect_pixels"]
    return x0 <= float(pixel[0]) <= x1 and y0 <= float(pixel[1]) <= y1


def _region_overlap_ratio(
    first: Dict[str, Any],
    second: Dict[str, Any],
) -> float:
    first_rect = first["rect_pixels"]
    second_rect = second["rect_pixels"]
    overlap_width = max(
        0.0,
        min(first_rect[2], second_rect[2]) - max(first_rect[0], second_rect[0]),
    )
    overlap_height = max(
        0.0,
        min(first_rect[3], second_rect[3]) - max(first_rect[1], second_rect[1]),
    )
    overlap_area = overlap_width * overlap_height
    smaller_area = min(
        (first_rect[2] - first_rect[0]) * (first_rect[3] - first_rect[1]),
        (second_rect[2] - second_rect[0]) * (second_rect[3] - second_rect[1]),
    )
    return overlap_area / smaller_area if smaller_area > 0 else 1.0


def _alignment(
    raw: Any,
    source_center: Sequence[float],
    target_center: Sequence[float],
) -> Dict[str, float]:
    if raw is None:
        raw = {}
    if not isinstance(raw, dict):
        raise MergeProcessingError("Alignment must be an object.")
    defaults = {
        "dx_m": float(target_center[0]) - float(source_center[0]),
        "dy_m": float(target_center[1]) - float(source_center[1]),
        "yaw_deg": 0.0,
    }
    values: Dict[str, float] = {}
    for key, default in defaults.items():
        try:
            value = float(raw.get(key, default))
        except (TypeError, ValueError) as exc:
            raise MergeProcessingError(f"Alignment {key} must be numeric.") from exc
        if not math.isfinite(value):
            raise MergeProcessingError(f"Alignment {key} must be finite.")
        values[key] = value
    if math.hypot(values["dx_m"], values["dy_m"]) > 50:
        raise MergeProcessingError("The requested regional correction exceeds the 50 m safety limit.")
    if abs(values["yaw_deg"]) > 45:
        raise MergeProcessingError("Manual regional yaw correction is limited to ±45°.")
    return values


def _apply_alignment(
    point: Sequence[float],
    source_center: Sequence[float],
    alignment: Dict[str, float],
) -> Tuple[float, float]:
    theta = math.radians(alignment["yaw_deg"])
    cosine = math.cos(theta)
    sine = math.sin(theta)
    local_x = float(point[0]) - float(source_center[0])
    local_y = float(point[1]) - float(source_center[1])
    return (
        float(source_center[0]) + alignment["dx_m"] + cosine * local_x - sine * local_y,
        float(source_center[1]) + alignment["dy_m"] + sine * local_x + cosine * local_y,
    )


def _planar_affine(
    source_center: Sequence[float],
    alignment: Dict[str, float],
) -> Tuple[float, float, float]:
    theta = math.radians(alignment["yaw_deg"])
    cosine = math.cos(theta)
    sine = math.sin(theta)
    center_x = float(source_center[0])
    center_y = float(source_center[1])
    translate_x = center_x + alignment["dx_m"] - (cosine * center_x - sine * center_y)
    translate_y = center_y + alignment["dy_m"] - (sine * center_x + cosine * center_y)
    return theta, translate_x, translate_y


def _native_alignment_matrix(
    geometry: MapGeometry,
    source_center: Sequence[float],
    alignment: Dict[str, float],
) -> Tuple[float, ...]:
    theta, translate_x, translate_y = _planar_affine(source_center, alignment)
    native_theta = theta if geometry.horizontal_axes == "xy" else -theta
    cosine = math.cos(native_theta)
    sine = math.sin(native_theta)
    if geometry.horizontal_axes == "xy":
        native_x, native_y = translate_x, translate_y
    else:
        native_x, native_y = -translate_y, -translate_x
    return (
        cosine, -sine, 0.0, native_x,
        sine, cosine, 0.0, native_y,
        0.0, 0.0, 1.0, 0.0,
    )


def _matrix4(matrix: Sequence[float]) -> Tuple[Tuple[float, ...], ...]:
    return (
        (matrix[0], matrix[1], matrix[2], matrix[3]),
        (matrix[4], matrix[5], matrix[6], matrix[7]),
        (matrix[8], matrix[9], matrix[10], matrix[11]),
        (0.0, 0.0, 0.0, 1.0),
    )


def _multiply(a: Sequence[Sequence[float]], b: Sequence[Sequence[float]]) -> Tuple[Tuple[float, ...], ...]:
    return tuple(
        tuple(sum(float(a[row][index]) * float(b[index][column]) for index in range(4)) for column in range(4))
        for row in range(4)
    )


def _inverse_rigid(matrix: Sequence[Sequence[float]]) -> Tuple[Tuple[float, ...], ...]:
    rotation_t = tuple(
        tuple(float(matrix[column][row]) for column in range(3))
        for row in range(3)
    )
    translation = (float(matrix[0][3]), float(matrix[1][3]), float(matrix[2][3]))
    inverse_translation = tuple(
        -sum(rotation_t[row][index] * translation[index] for index in range(3))
        for row in range(3)
    )
    return (
        (*rotation_t[0], inverse_translation[0]),
        (*rotation_t[1], inverse_translation[1]),
        (*rotation_t[2], inverse_translation[2]),
        (0.0, 0.0, 0.0, 1.0),
    )


def _transform12(matrix: Sequence[Sequence[float]]) -> List[float]:
    return [
        float(matrix[row][column])
        for row in range(3)
        for column in range(4)
    ]


def _rotation_error_degrees(matrix: Sequence[Sequence[float]]) -> float:
    trace = float(matrix[0][0]) + float(matrix[1][1]) + float(matrix[2][2])
    cosine = max(-1.0, min(1.0, (trace - 1.0) / 2.0))
    return math.degrees(math.acos(cosine))


def _information(level: str) -> Tuple[List[float], Dict[str, float]]:
    if level not in INFORMATION_LEVELS:
        raise MergeProcessingError("Information level must be weak, medium or strong.")
    parameters = INFORMATION_LEVELS[level]
    planar = 1.0 / parameters["linear_variance"]
    angular = 1.0 / parameters["angular_variance"]
    diagonal = [planar, planar, 4.0, 4.0, 4.0, angular]
    matrix = [0.0] * 36
    for index, value in enumerate(diagonal):
        matrix[index * 6 + index] = value
    return matrix, {**parameters, "vertical_variance": 0.25}


def _existing_pairs(database: Path) -> set[Tuple[int, int]]:
    pairs: set[Tuple[int, int]] = set()
    try:
        connection = sqlite3.connect(f"file:{database}?mode=ro", uri=True)
        if "Link" in set(base.sqlite_tables(connection)):
            for from_id, to_id in connection.execute(
                "SELECT from_id, to_id FROM Link WHERE type BETWEEN 0 AND 4"
            ):
                pairs.add(tuple(sorted((int(from_id), int(to_id)))))
    except sqlite3.Error:
        return pairs
    finally:
        try:
            connection.close()
        except UnboundLocalError:
            pass
    return pairs


def _pair_nodes(
    source_nodes: Sequence[PoseRecord],
    target_nodes: Sequence[PoseRecord],
    source_center: Sequence[float],
    alignment: Dict[str, float],
    existing_pairs: set[Tuple[int, int]],
) -> Tuple[List[Tuple[PoseRecord, PoseRecord, float]], List[str]]:
    warnings: List[str] = []
    ordered_source = sorted(source_nodes, key=lambda pose: pose.node_id)
    stride = max(1, math.ceil(len(ordered_source) / MAX_CONSTRAINTS))
    candidates = ordered_source[::stride]
    if ordered_source[-1] not in candidates:
        candidates.append(ordered_source[-1])
    paired: List[Tuple[PoseRecord, PoseRecord, float]] = []
    used_target_ids: set[int] = set()
    for source in candidates:
        transformed = _apply_alignment(
            (source.map_x, source.map_y),
            source_center,
            alignment,
        )
        target = min(
            target_nodes,
            key=lambda item: math.hypot(item.map_x - transformed[0], item.map_y - transformed[1]),
        )
        distance = math.hypot(target.map_x - transformed[0], target.map_y - transformed[1])
        pair_key = tuple(sorted((source.node_id, target.node_id)))
        if source.node_id == target.node_id or target.node_id in used_target_ids or pair_key in existing_pairs:
            continue
        if distance > 2.0:
            continue
        used_target_ids.add(target.node_id)
        paired.append((source, target, distance))
    if len(paired) > MAX_CONSTRAINTS:
        paired = paired[:MAX_CONSTRAINTS]
    if paired and max(abs(source.node_id - target.node_id) for source, target, _distance in paired) < 30:
        warnings.append(
            "The selected regions only connect nearby graph nodes; this repair may not constrain accumulated drift."
        )
    return paired, warnings


def preview_merge(result_dir: Path, request: Dict[str, Any]) -> Dict[str, Any]:
    context = result_context(result_dir)
    geometry: MapGeometry = context["geometry"]
    raw_regions = request.get("regions")
    if not isinstance(raw_regions, list) or len(raw_regions) != 2:
        raise MergeProcessingError("Select exactly two duplicate regions: target A and source B.")
    target_region = _normalize_region(raw_regions[0], "A", geometry)
    source_region = _normalize_region(raw_regions[1], "B", geometry)
    overlap_ratio = _region_overlap_ratio(target_region, source_region)
    if overlap_ratio > 0.80:
        raise MergeProcessingError(
            "The two image regions overlap almost completely, so their trajectory memberships "
            "cannot be separated safely. Select the two visible duplicate copies independently."
        )
    alignment = _alignment(
        request.get("alignment"),
        source_region["center_world"],
        target_region["center_world"],
    )
    level = str(request.get("information_level") or "medium")
    information_matrix, variance = _information(level)
    poses = _load_poses(context["database"], geometry.horizontal_axes)
    target_nodes = [
        pose
        for pose in poses
        if _region_contains(target_region, geometry.world_to_pixel((pose.map_x, pose.map_y)))
    ]
    source_nodes = [
        pose
        for pose in poses
        if _region_contains(source_region, geometry.world_to_pixel((pose.map_x, pose.map_y)))
    ]
    if len(target_nodes) < MIN_REGION_NODE_COUNT:
        raise MergeProcessingError(
            f"Region A contains only {len(target_nodes)} trajectory nodes; enlarge it around the duplicated aisle."
        )
    if len(source_nodes) < MIN_REGION_NODE_COUNT:
        raise MergeProcessingError(
            f"Region B contains only {len(source_nodes)} trajectory nodes; enlarge it around the duplicated aisle."
        )

    paired, warnings = _pair_nodes(
        source_nodes,
        target_nodes,
        source_region["center_world"],
        alignment,
        _existing_pairs(context["database"]),
    )
    if len(paired) < 2:
        raise MergeProcessingError(
            "Fewer than two independent pose correspondences remain after safety filtering. Adjust or enlarge the regions."
        )
    native_alignment = _matrix4(
        _native_alignment_matrix(
            geometry,
            source_region["center_world"],
            alignment,
        )
    )
    constraints: List[Dict[str, Any]] = []
    for source, target, distance in paired:
        desired_source = _multiply(native_alignment, _matrix4(source.matrix))
        source_to_target = _multiply(_inverse_rigid(desired_source), _matrix4(target.matrix))
        from_id = source.node_id
        to_id = target.node_id
        transform = source_to_target
        if from_id < to_id:
            from_id, to_id = to_id, from_id
            transform = _inverse_rigid(transform)
        constraints.append(
            {
                "from_id": from_id,
                "to_id": to_id,
                "type": 4,
                "transform": [round(value, 8) for value in _transform12(transform)],
                "information_matrix": [round(value, 8) for value in information_matrix],
                "source_node_id": source.node_id,
                "target_node_id": target.node_id,
                "preview_residual_m": round(distance, 4),
            }
        )

    median_residual = statistics.median(item[2] for item in paired)
    node_separations = [
        abs(source.node_id - target.node_id)
        for source, target, _distance in paired
    ]
    long_range_pair_count = sum(
        1 for separation in node_separations if separation >= 30
    )
    area_ratio = min(target_region["area_m2"], source_region["area_m2"]) / max(
        target_region["area_m2"], source_region["area_m2"]
    )
    coverage_score = min(1.0, len(paired) / 6.0)
    residual_score = max(0.0, 1.0 - median_residual / 2.0)
    score = int(round(100 * (0.25 * area_ratio + 0.40 * coverage_score + 0.35 * residual_score)))
    translation = math.hypot(alignment["dx_m"], alignment["dy_m"])
    if translation > 8:
        warnings.append("The requested correction is larger than 8 m; verify the selected regions carefully.")
        score = min(score, 55)
    if area_ratio < 0.25:
        warnings.append("The selected regions have very different areas.")
        score = min(score, 55)
    if median_residual > 0.75:
        warnings.append("Pose correspondence residual is high; refine dx/dy/yaw before applying.")
    if long_range_pair_count == 0:
        warnings.append(
            "The selected regions do not connect graph nodes at least 30 keyframes apart; "
            "they cannot serve as a long-range drift correction."
        )
        score = min(score, 35)
    if score < 40:
        warnings.append("Alignment confidence is below the publishing threshold.")

    return {
        "format": "SupermarketManualRegionMergePreview",
        "version": 1,
        "base_result": context["result_dir"].name,
        "source_session": str(context["session"]),
        "source_database": str(context["database"]),
        "evidence_ref": f"preview_layers.json@{context['layers_sha256']}",
        "geometry": {
            "width": geometry.width,
            "height": geometry.height,
            "resolution_m": geometry.resolution,
            "origin": [geometry.origin_x, geometry.origin_y],
            "horizontal_axes": geometry.horizontal_axes,
        },
        "regions": [target_region, source_region],
        "alignment": {
            **{key: round(value, 6) for key, value in alignment.items()},
            "score": score,
            "method": "manual_regions_with_nearest_pose_correspondence",
        },
        "information_level": level,
        "information_variance": variance,
        "constraints": constraints,
        "summary": {
            "target_node_count": len(target_nodes),
            "source_node_count": len(source_nodes),
            "constraint_count": len(constraints),
            "long_range_constraint_count": long_range_pair_count,
            "region_overlap_ratio": round(overlap_ratio, 4),
            "node_ranges": {
                "target": [min(item.node_id for item in target_nodes), max(item.node_id for item in target_nodes)],
                "source": [min(item.node_id for item in source_nodes), max(item.node_id for item in source_nodes)],
            },
            "median_preview_residual_m": round(median_residual, 4),
            "estimated_max_displacement_m": round(translation, 4),
        },
        "warnings": warnings,
        "can_apply": (
            score >= 40
            and len(constraints) >= 2
            and long_range_pair_count >= 1
        ),
    }


def _translation(matrix: Sequence[Sequence[float]]) -> Tuple[float, float, float]:
    return float(matrix[0][3]), float(matrix[1][3]), float(matrix[2][3])


def validate_optimized_merge(
    before_database: Path,
    after_database: Path,
    constraints: Sequence[Dict[str, Any]],
    axes: str,
) -> Dict[str, Any]:
    before = {pose.node_id: pose for pose in _load_poses(before_database, axes)}
    after = {pose.node_id: pose for pose in _load_poses(after_database, axes)}
    common_ids = sorted(set(before) & set(after))
    displacements = [
        math.sqrt(
            sum(
                (
                    _translation(_matrix4(before[node_id].matrix))[axis]
                    - _translation(_matrix4(after[node_id].matrix))[axis]
                )
                ** 2
                for axis in range(3)
            )
        )
        for node_id in common_ids
    ]
    residuals: List[Dict[str, Any]] = []
    for constraint in constraints:
        from_id = int(constraint["from_id"])
        to_id = int(constraint["to_id"])
        if from_id not in after or to_id not in after:
            continue
        predicted = _multiply(
            _inverse_rigid(_matrix4(after[from_id].matrix)),
            _matrix4(after[to_id].matrix),
        )
        expected = _matrix4([float(value) for value in constraint["transform"]])
        error = _multiply(_inverse_rigid(expected), predicted)
        translation_error = math.sqrt(sum(value * value for value in _translation(error)))
        residuals.append(
            {
                "from_id": from_id,
                "to_id": to_id,
                "translation_m": round(translation_error, 6),
                "rotation_deg": round(_rotation_error_degrees(error), 6),
            }
        )
    translation_residuals = [item["translation_m"] for item in residuals]
    median_residual = statistics.median(translation_residuals) if translation_residuals else float("inf")
    conflicting_ratio = (
        sum(1 for value in translation_residuals if value > 0.30) / len(translation_residuals)
        if translation_residuals
        else 1.0
    )
    sorted_displacements = sorted(displacements)
    p95_index = max(0, math.ceil(len(sorted_displacements) * 0.95) - 1)
    displacement_p95 = sorted_displacements[p95_index] if sorted_displacements else 0.0
    displacement_max = max(sorted_displacements, default=0.0)
    rejection_reasons: List[str] = []
    if not residuals:
        rejection_reasons.append("No injected user constraints could be evaluated after optimization.")
    if median_residual > 0.30 and conflicting_ratio > 0.50:
        rejection_reasons.append(
            "More than half of the manual constraints conflict with the optimized graph "
            f"(median residual {median_residual:.2f} m)."
        )
    if displacement_max > 12.0:
        rejection_reasons.append(
            f"Manual repair displaced at least one graph node by {displacement_max:.2f} m, exceeding the 12 m safety limit."
        )
    return {
        "format": "SupermarketManualRegionMergeValidation",
        "version": 1,
        "status": "rejected" if rejection_reasons else "pass",
        "evaluated_pose_count": len(common_ids),
        "evaluated_constraint_count": len(residuals),
        "constraint_residuals": residuals,
        "median_constraint_residual_m": round(median_residual, 6) if math.isfinite(median_residual) else None,
        "conflicting_constraint_ratio": round(conflicting_ratio, 6),
        "displacement": {
            "p95_m": round(displacement_p95, 6),
            "max_m": round(displacement_max, 6),
        },
        "rejection_reasons": rejection_reasons,
    }


def write_merge_artifacts(
    output: Path,
    preview: Dict[str, Any],
    validation: Dict[str, Any],
    source_result: Path,
) -> None:
    generated_at = time.strftime("%Y-%m-%d %H:%M:%S")
    edit = {
        "id": "merge-0001",
        "created_at": generated_at,
        "regions": preview["regions"],
        "alignment": preview["alignment"],
        "information_level": preview["information_level"],
        "constraints": preview["constraints"],
        "evidence_ref": preview["evidence_ref"],
        "source_version": source_result.name,
        "result_version": output.name,
        "validation": validation,
    }
    edits_payload = {
        "format": "SupermarketMergeEdits",
        "version": 1,
        "base_result": source_result.name,
        "edits": [edit],
    }
    manifest = {
        "format": "SupermarketManualRegionMergeManifest",
        "version": 1,
        "generated_at": generated_at,
        "base_result": str(source_result),
        "result_version": str(output),
        "source_session": preview["source_session"],
        "source_database": preview["source_database"],
        "user_constraints_used": True,
        "constraint_count": len(preview["constraints"]),
        "alignment": preview["alignment"],
        "validation_status": validation["status"],
    }
    report = {
        "format": "SupermarketManualRegionMergeReport",
        "version": 1,
        "generated_at": generated_at,
        "preview": preview,
        "validation": validation,
    }
    for name, payload in (
        ("merge_edits.json", edits_payload),
        ("merge_manifest.json", manifest),
        ("merge_report.json", report),
    ):
        (output / name).write_text(
            json.dumps(payload, ensure_ascii=False, indent=2),
            encoding="utf-8",
        )

    for name in ("map.json", "quality_report.json", "source_manifest.json"):
        path = output / name
        if not path.is_file():
            continue
        payload = _load_json(path)
        payload["manual_region_merge"] = {
            "enabled": True,
            "base_result": source_result.name,
            "constraint_count": len(preview["constraints"]),
            "alignment_score": preview["alignment"]["score"],
            "validation_status": validation["status"],
            "manifest": "merge_manifest.json",
        }
        path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
