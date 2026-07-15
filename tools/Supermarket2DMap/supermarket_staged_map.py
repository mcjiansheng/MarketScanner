#!/usr/bin/env python3
"""
Generate a stage-aware 2D map package from one SupermarketSession directory.

Stages are an offline correction layer above iOS scan segments. They let a
large single-device scan be grouped into route phases, then adjusted and
reviewed without modifying the original RTAB-Map databases.
"""

from __future__ import annotations

import argparse
import dataclasses
import json
import math
import time
from pathlib import Path
from typing import Any, Dict, List, Optional, Sequence, Tuple

import supermarket_2d_map as base


def read_json(path: Optional[Path], default: Any) -> Any:
    if path is None:
        return default
    return base.read_json(path, default)


def parse_transform(raw: Optional[Dict[str, Any]]) -> Dict[str, float]:
    if not isinstance(raw, dict):
        return {"dx": 0.0, "dy": 0.0, "yaw": 0.0}
    return {
        "dx": float(raw.get("dx", 0.0)),
        "dy": float(raw.get("dy", 0.0)),
        "yaw": math.radians(float(raw.get("yaw_deg", 0.0))) if "yaw_deg" in raw else float(raw.get("yaw", 0.0)),
    }


def transform_to_json(transform: Dict[str, float]) -> Dict[str, float]:
    return {
        "dx": transform.get("dx", 0.0),
        "dy": transform.get("dy", 0.0),
        "yaw_deg": math.degrees(transform.get("yaw", 0.0)),
    }


def compose_transform(first: Dict[str, float], second: Dict[str, float]) -> Dict[str, float]:
    """Return a transform equivalent to applying first, then second."""
    dx, dy = base.transform_point(first.get("dx", 0.0), first.get("dy", 0.0), second.get("dx", 0.0), second.get("dy", 0.0), second.get("yaw", 0.0))
    return {
        "dx": dx,
        "dy": dy,
        "yaw": first.get("yaw", 0.0) + second.get("yaw", 0.0),
    }


def apply_transform_to_pose(pose: base.Pose2D, transform: Dict[str, float]) -> None:
    pose.x, pose.y = base.transform_point(pose.x, pose.y, transform["dx"], transform["dy"], transform["yaw"])
    pose.yaw += transform["yaw"]


def apply_transform_to_tag(tag: base.PriceTag, transform: Dict[str, float]) -> None:
    tag.raw_x, tag.raw_y = base.transform_point(tag.raw_x, tag.raw_y, transform["dx"], transform["dy"], transform["yaw"])
    tag.yaw += transform["yaw"]


def apply_transform_to_point(point: base.ProjectedPoint, transform: Dict[str, float]) -> None:
    point.x, point.y = base.transform_point(point.x, point.y, transform["dx"], transform["dy"], transform["yaw"])


def segment_key(raw: Any) -> int:
    return int(raw)


def load_stage_config(config_path: Optional[Path], segments: Sequence[base.Segment]) -> Tuple[List[Dict[str, Any]], Dict[int, str], Dict[str, Dict[str, float]], Dict[int, Dict[str, float]], Dict[str, Any]]:
    config = read_json(config_path, {})
    if not isinstance(config, dict):
        config = {}

    configured_stages = config.get("stages", [])
    stages: List[Dict[str, Any]] = []
    stage_by_segment: Dict[int, str] = {}
    stage_transforms: Dict[str, Dict[str, float]] = {}

    if isinstance(configured_stages, list):
        for index, raw_stage in enumerate(configured_stages, start=1):
            if not isinstance(raw_stage, dict):
                continue
            stage_id = str(raw_stage.get("id") or f"stage_{index:02d}")
            local_segments = [segment_key(s) for s in raw_stage.get("segments", [])]
            stage = {
                "id": stage_id,
                "name": str(raw_stage.get("name") or stage_id),
                "role": str(raw_stage.get("role") or ("anchor" if index == 1 else "normal")),
                "segments": local_segments,
            }
            stages.append(stage)
            stage_transforms[stage_id] = parse_transform(raw_stage.get("transform"))
            for segment_index in local_segments:
                stage_by_segment[segment_index] = stage_id

    covered = set(stage_by_segment)
    for segment in sorted(segments, key=lambda s: s.index):
        if segment.index in covered:
            continue
        stage_id = f"stage_{segment.index:04d}"
        stage = {
            "id": stage_id,
            "name": stage_id,
            "role": "anchor" if not stages else "normal",
            "segments": [segment.index],
        }
        stages.append(stage)
        stage_by_segment[segment.index] = stage_id
        stage_transforms[stage_id] = {"dx": 0.0, "dy": 0.0, "yaw": 0.0}

    raw_segment_transforms = config.get("segment_transforms", {})
    segment_transforms: Dict[int, Dict[str, float]] = {}
    if isinstance(raw_segment_transforms, dict):
        for key, value in raw_segment_transforms.items():
            try:
                segment_index = int(key)
            except ValueError:
                continue
            segment_transforms[segment_index] = parse_transform(value if isinstance(value, dict) else None)

    return stages, stage_by_segment, stage_transforms, segment_transforms, config


def apply_stage_transforms(
    segments: Sequence[base.Segment],
    points: Sequence[base.ProjectedPoint],
    stage_by_segment: Dict[int, str],
    stage_transforms: Dict[str, Dict[str, float]],
    segment_transforms: Dict[int, Dict[str, float]],
) -> Dict[int, Dict[str, Any]]:
    applied: Dict[int, Dict[str, Any]] = {}
    for segment in segments:
        stage_id = stage_by_segment.get(segment.index, f"stage_{segment.index:04d}")
        seg_tr = segment_transforms.get(segment.index, {"dx": 0.0, "dy": 0.0, "yaw": 0.0})
        stage_tr = stage_transforms.get(stage_id, {"dx": 0.0, "dy": 0.0, "yaw": 0.0})
        for pose in segment.poses:
            apply_transform_to_pose(pose, seg_tr)
            apply_transform_to_pose(pose, stage_tr)
        for tag in segment.price_tags:
            apply_transform_to_tag(tag, seg_tr)
            apply_transform_to_tag(tag, stage_tr)
        applied[segment.index] = {
            "stage_id": stage_id,
            "segment_transform": seg_tr,
            "stage_transform": stage_tr,
        }

    for point in points:
        stage_id = stage_by_segment.get(point.segment_index, f"stage_{point.segment_index:04d}")
        seg_tr = segment_transforms.get(point.segment_index, {"dx": 0.0, "dy": 0.0, "yaw": 0.0})
        stage_tr = stage_transforms.get(stage_id, {"dx": 0.0, "dy": 0.0, "yaw": 0.0})
        apply_transform_to_point(point, seg_tr)
        apply_transform_to_point(point, stage_tr)

    return applied


def trajectory_length(poses: Sequence[base.Pose2D]) -> float:
    total = 0.0
    for a, b in zip(poses, poses[1:]):
        total += math.hypot(b.x - a.x, b.y - a.y)
    return total


def stage_quality(
    stages: Sequence[Dict[str, Any]],
    segments: Sequence[base.Segment],
    stage_by_segment: Dict[int, str],
    stage_transforms: Dict[str, Dict[str, float]],
    segment_transforms: Dict[int, Dict[str, float]],
    has_points: bool,
) -> Tuple[Dict[str, Any], List[Dict[str, Any]]]:
    segments_by_stage: Dict[str, List[base.Segment]] = {stage["id"]: [] for stage in stages}
    for segment in segments:
        segments_by_stage.setdefault(stage_by_segment.get(segment.index, ""), []).append(segment)

    warnings: List[Dict[str, Any]] = []
    stage_entries: List[Dict[str, Any]] = []
    previous_end: Optional[Tuple[float, float]] = None

    for stage in stages:
        stage_id = stage["id"]
        stage_segments = sorted(segments_by_stage.get(stage_id, []), key=lambda s: s.index)
        poses = [pose for segment in stage_segments for pose in segment.poses]
        tags = [tag for segment in stage_segments for tag in segment.price_tags]
        start_xy = [poses[0].x, poses[0].y] if poses else None
        end_xy = [poses[-1].x, poses[-1].y] if poses else None
        close_distance = math.hypot(poses[-1].x - poses[0].x, poses[-1].y - poses[0].y) if len(poses) >= 2 else None
        connection_distance = math.hypot(poses[0].x - previous_end[0], poses[0].y - previous_end[1]) if poses and previous_end else None
        if end_xy:
            previous_end = (end_xy[0], end_xy[1])

        stage_transform = stage_transforms.get(stage_id, {"dx": 0.0, "dy": 0.0, "yaw": 0.0})
        stage_shift = math.hypot(stage_transform["dx"], stage_transform["dy"])
        stage_yaw_deg = abs(math.degrees(stage_transform["yaw"]))

        if not poses:
            warnings.append({"type": "stage", "stage": stage_id, "message": "Stage has no valid poses."})
        if stage_yaw_deg > 10:
            warnings.append({"type": "stage", "stage": stage_id, "message": f"Stage yaw correction is large: {stage_yaw_deg:.2f} deg."})
        if stage_shift > 5:
            warnings.append({"type": "stage", "stage": stage_id, "message": f"Stage translation correction is large: {stage_shift:.2f} m."})
        if connection_distance is not None and connection_distance > 5:
            warnings.append({"type": "stage", "stage": stage_id, "message": f"Stage starts {connection_distance:.2f} m from previous stage end."})

        for segment in stage_segments:
            seg_tr = segment_transforms.get(segment.index, {"dx": 0.0, "dy": 0.0, "yaw": 0.0})
            seg_shift = math.hypot(seg_tr["dx"], seg_tr["dy"])
            seg_yaw_deg = abs(math.degrees(seg_tr["yaw"]))
            if seg_yaw_deg > 5:
                warnings.append({"type": "segment", "segment": segment.index, "stage": stage_id, "message": f"Segment yaw correction is large: {seg_yaw_deg:.2f} deg."})
            if seg_shift > 2:
                warnings.append({"type": "segment", "segment": segment.index, "stage": stage_id, "message": f"Segment translation correction is large: {seg_shift:.2f} m."})

        stage_entries.append(
            {
                "id": stage_id,
                "name": stage.get("name", stage_id),
                "role": stage.get("role", "normal"),
                "segments": [segment.index for segment in stage_segments],
                "segment_count": len(stage_segments),
                "node_count": len(poses),
                "price_tag_count": len(tags),
                "trajectory_length_m": round(trajectory_length(poses), 3),
                "start_xy": start_xy,
                "end_xy": end_xy,
                "end_to_start_distance_m": round(close_distance, 3) if close_distance is not None else None,
                "distance_from_previous_stage_end_m": round(connection_distance, 3) if connection_distance is not None else None,
                "stage_transform": transform_to_json(stage_transform),
            }
        )

    if not has_points:
        warnings.append({"type": "map", "message": "No projected structure points were provided; output is mainly trajectory coverage, not final shelf/wall structure."})

    return {"stages": stage_entries, "warnings": warnings}, warnings


def write_review_items(path: Path, base_report: Dict[str, Any], stage_warnings: Sequence[Dict[str, Any]], tags: Sequence[base.PriceTag]) -> None:
    items: List[Dict[str, Any]] = []
    for warning in base_report.get("warnings", []):
        items.append({"type": "warning", "message": warning})
    for warning in stage_warnings:
        items.append({"type": warning.get("type", "stage_warning"), "message": warning.get("message", ""), **{k: v for k, v in warning.items() if k not in {"type", "message"}}})
    for tag in tags:
        if tag.needs_review:
            items.append(
                {
                    "type": "price_tag",
                    "message": f"Price tag {tag.tag_id} needs position review",
                    "segment": tag.segment_index,
                    "raw_xy": [tag.raw_x, tag.raw_y],
                    "snapped_xy": [tag.snapped_x, tag.snapped_y],
                    "confidence": tag.confidence,
                }
            )
    path.write_text(json.dumps({"items": items}, ensure_ascii=False, indent=2), encoding="utf-8")


def generate(args: argparse.Namespace) -> Path:
    session_dir = Path(args.session).resolve()
    output_dir = Path(args.output).resolve() if args.output else session_dir / f"StageMap2D-{time.strftime('%Y%m%d-%H%M%S')}"

    config = base.MapConfig(
        resolution=args.resolution,
        preview_resolution=args.preview_resolution,
        trajectory_radius=args.trajectory_radius,
        tag_snap_distance=args.tag_snap_distance,
        occupied_inflate_radius=args.occupied_inflate_radius,
        free_ray_max_range=args.free_ray_max_range,
        horizontal_axes=args.horizontal_axes,
        auto_align_segments=False,
    )

    segments = base.discover_segments(session_dir, config)
    stages, stage_by_segment, stage_transforms, segment_transforms, raw_config = load_stage_config(Path(args.stage_config).resolve() if args.stage_config else None, segments)

    point_paths = [Path(p).resolve() for p in args.points_csv]
    point_paths.extend(sorted(session_dir.glob("segment_*/points.csv")))
    point_paths.extend(sorted(session_dir.glob("points.csv")))
    points = base.load_projected_points(point_paths, config.horizontal_axes)
    base.require_map_evidence(segments, points)
    output_dir.mkdir(parents=True, exist_ok=True)

    applied = apply_stage_transforms(segments, points, stage_by_segment, stage_transforms, segment_transforms)

    tags = [tag for segment in segments for tag in segment.price_tags]
    base.snap_price_tags(tags, points, config.tag_snap_distance)
    grid = base.build_grid(segments, points, config)
    poses = [pose for segment in segments for pose in segment.poses]

    base.render_grid(grid, output_dir / "occupancy_grid.png")
    base.render_grid(grid, output_dir / "preview.png", trajectories=poses, tags=tags)
    base.write_yaml(output_dir / "occupancy_grid.yaml", grid, "occupancy_grid.png")
    base.write_geojson(output_dir / "trajectory.geojson", base.trajectory_geojson(segments))
    base.write_geojson(output_dir / "price_tags.geojson", base.price_tags_geojson(tags))
    base.write_geojson(output_dir / "vector_map.geojson", base.vector_map_geojson(grid))
    base.write_preview_3d(output_dir / "preview_3d.json", segments, points, tags, config.horizontal_axes)
    (output_dir / "semantic_layers.json").write_text(json.dumps(base.semantic_layers(grid), ensure_ascii=False, indent=2), encoding="utf-8")

    transforms_for_report = {
        segment.index: compose_transform(applied[segment.index]["segment_transform"], applied[segment.index]["stage_transform"])
        for segment in segments
    }
    report = base.quality_report(session_dir, segments, points, tags, grid, transforms_for_report)
    stage_report, stage_warnings = stage_quality(stages, segments, stage_by_segment, stage_transforms, segment_transforms, bool(points))
    report["stage_summary"] = {
        "stage_count": len(stages),
        "warnings": stage_warnings,
    }
    (output_dir / "quality_report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    (output_dir / "stage_quality_report.json").write_text(json.dumps(stage_report, ensure_ascii=False, indent=2), encoding="utf-8")

    stage_manifest = {
        "format": "SupermarketStageManifest",
        "version": 1,
        "session": str(session_dir),
        "generated_at": report["generated_at"],
        "stages": stage_report["stages"],
        "segments": [
            {
                "segment_index": segment.index,
                "stage_id": stage_by_segment.get(segment.index),
                "directory": str(segment.directory),
                "database": str(segment.database_path) if segment.database_path else None,
                "node_count": len(segment.poses),
                "price_tag_count": len(segment.price_tags),
                "applied": {
                    "stage_transform": transform_to_json(applied[segment.index]["stage_transform"]),
                    "segment_transform": transform_to_json(applied[segment.index]["segment_transform"]),
                },
            }
            for segment in segments
        ],
    }
    (output_dir / "stage_manifest.json").write_text(json.dumps(stage_manifest, ensure_ascii=False, indent=2), encoding="utf-8")

    config_used = {
        "format": "SupermarketStageConfigUsed",
        "version": 1,
        "source_config": raw_config,
        "stage_transforms": {stage_id: transform_to_json(transform) for stage_id, transform in stage_transforms.items()},
        "segment_transforms": {str(segment): transform_to_json(transform) for segment, transform in segment_transforms.items()},
    }
    (output_dir / "alignment_config_used.json").write_text(json.dumps(config_used, ensure_ascii=False, indent=2), encoding="utf-8")
    (output_dir / "source_manifest.json").write_text(
        json.dumps(base.source_manifest(session_dir, segments, point_paths), ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    write_review_items(output_dir / "review_items.json", report, stage_warnings, tags)

    map_json = {
        "format": "SupermarketStageMap2D",
        "version": 1,
        "session": str(session_dir),
        "generated_at": report["generated_at"],
        "coordinate_frame": {
            "name": "map_2d",
            "horizontal_axes": config.horizontal_axes,
            "origin": [grid.origin_x, grid.origin_y],
            "resolution_m": grid.resolution,
        },
        "parameters": dataclasses.asdict(config),
        "outputs": [
            "occupancy_grid.png",
            "occupancy_grid.yaml",
            "preview.png",
            "preview_3d.json",
            "trajectory.geojson",
            "price_tags.geojson",
            "vector_map.geojson",
            "semantic_layers.json",
            "quality_report.json",
            "stage_quality_report.json",
            "stage_manifest.json",
            "alignment_config_used.json",
            "review_items.json",
            "source_manifest.json",
        ],
    }
    (output_dir / "map.json").write_text(json.dumps(map_json, ensure_ascii=False, indent=2), encoding="utf-8")
    return output_dir


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Generate a stage-aware 2D map package from one SupermarketSession directory.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument("session", help="Path to one SupermarketSession-* directory.")
    parser.add_argument("--stage-config", help="Optional stage_config.json with stages and corrections.")
    parser.add_argument("--output", help="Output StageMap2D directory.")
    parser.add_argument("--points-csv", action="append", default=[], help="Projected point CSV with x,y,z,kind,segmentIndex,nodeId columns.")
    parser.add_argument("--resolution", type=float, default=0.05, help="Occupancy grid resolution in meters.")
    parser.add_argument("--preview-resolution", type=float, default=0.10, help="Reserved for future preview downsampling.")
    parser.add_argument("--trajectory-radius", type=float, default=1.25, help="Free-space radius around scan trajectory.")
    parser.add_argument("--tag-snap-distance", type=float, default=1.0, help="Maximum distance for snapping price tags to occupied points.")
    parser.add_argument("--occupied-inflate-radius", type=float, default=0.08, help="Inflation radius for projected occupied points.")
    parser.add_argument("--free-ray-max-range", type=float, default=8.0, help="Maximum ray clearing range from pose to occupied point.")
    parser.add_argument("--horizontal-axes", choices=["xz", "xy"], default="xz", help="RTAB-Map transform axes used for the 2D floor plane.")
    return parser


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = build_arg_parser()
    args = parser.parse_args(argv)
    try:
        output_dir = generate(args)
    except Exception as exc:
        print(f"supermarket_staged_map: {exc}", flush=True)
        return 1
    print(output_dir)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
