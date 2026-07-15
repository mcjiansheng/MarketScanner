#!/usr/bin/env python3
"""
Generate a multi-device 2D map package from multiple SupermarketSession dirs.

The pipeline is intentionally offline and correction-file driven:
local segment -> optional stage transform -> device transform -> map_2d.
It is a foundation for PC/server merging, not a replacement for later
structure-point extraction and robust graph optimization.
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
import supermarket_staged_map as staged


def read_json(path: Optional[Path], default: Any) -> Any:
    if path is None:
        return default
    return base.read_json(path, default)


def device_id_from_session(path: Path) -> str:
    parent = path.parent.name
    if parent and not parent.startswith("SupermarketSession-"):
        return parent
    return path.name


def resolve_path_list(raw: Any, base_dir: Path) -> List[Path]:
    if raw is None:
        return []
    values = raw if isinstance(raw, list) else [raw]
    paths: List[Path] = []
    for value in values:
        path = Path(str(value))
        if not path.is_absolute():
            path = (base_dir / path).resolve()
        paths.append(path)
    return paths


def load_inputs(args: argparse.Namespace) -> Tuple[List[Dict[str, Any]], Dict[str, Any], Optional[Path]]:
    config_path = Path(args.config).resolve() if args.config else None
    config = read_json(config_path, {})
    if not isinstance(config, dict):
        config = {}

    devices: List[Dict[str, Any]] = []
    raw_devices = config.get("devices", [])
    config_base = config_path.parent if config_path else Path.cwd()
    if isinstance(raw_devices, list) and raw_devices:
        for raw in raw_devices:
            if not isinstance(raw, dict):
                continue
            session_raw = raw.get("session")
            if not session_raw:
                continue
            session = Path(str(session_raw))
            if not session.is_absolute():
                session = (config_base / session).resolve()
            stage_config = raw.get("stage_config")
            stage_config_path = Path(str(stage_config)) if stage_config else None
            if stage_config_path and not stage_config_path.is_absolute():
                stage_config_path = (config_base / stage_config_path).resolve()
            devices.append(
                {
                    "id": str(raw.get("id") or device_id_from_session(session)),
                    "session": session,
                    "transform": staged.parse_transform(raw.get("transform")),
                    "has_explicit_transform": isinstance(raw.get("transform"), dict),
                    "stage_config": stage_config_path,
                    "points_csv": resolve_path_list(raw.get("points_csv"), config_base),
                    "raw": raw,
                }
            )

    for session_arg in args.sessions:
        session = Path(session_arg).resolve()
        devices.append(
            {
                "id": device_id_from_session(session),
                "session": session,
                "transform": {"dx": 0.0, "dy": 0.0, "yaw": 0.0},
                "has_explicit_transform": False,
                "stage_config": None,
                "points_csv": [],
                "raw": {},
            }
        )

    if not devices:
        raise ValueError("No device sessions were provided. Use positional sessions or --config.")
    seen: Dict[str, int] = {}
    for device in devices:
        base_id = device["id"]
        seen[base_id] = seen.get(base_id, 0) + 1
        if seen[base_id] > 1:
            device["id"] = f"{base_id}_{seen[base_id]}"
    return devices, config, config_path


def first_pose(segments: Sequence[base.Segment]) -> Optional[base.Pose2D]:
    for segment in sorted(segments, key=lambda s: s.index):
        if segment.poses:
            return segment.poses[0]
    return None


def compute_common_start_transforms(device_states: Sequence[Dict[str, Any]], reference_device: Optional[str]) -> None:
    reference_state = None
    if reference_device:
        reference_state = next((state for state in device_states if state["id"] == reference_device), None)
    if reference_state is None:
        reference_state = device_states[0]

    reference_pose = first_pose(reference_state["segments"])
    if reference_pose is None:
        return

    for state in device_states:
        if state["has_explicit_transform"]:
            state["alignment_mode"] = "explicit_transform"
            continue
        pose = first_pose(state["segments"])
        if pose is None:
            state["alignment_mode"] = "identity_no_pose"
            continue
        state["device_transform"] = {
            "dx": reference_pose.x - pose.x,
            "dy": reference_pose.y - pose.y,
            "yaw": reference_pose.yaw - pose.yaw,
        }
        state["alignment_mode"] = "common_start"


def apply_device_transform(
    segments: Sequence[base.Segment],
    points: Sequence[base.ProjectedPoint],
    transform: Dict[str, float],
) -> None:
    for segment in segments:
        for pose in segment.poses:
            staged.apply_transform_to_pose(pose, transform)
        for tag in segment.price_tags:
            staged.apply_transform_to_tag(tag, transform)
    for point in points:
        staged.apply_transform_to_point(point, transform)


def reindex_device_segments(
    device_id: str,
    segments: Sequence[base.Segment],
    points: Sequence[base.ProjectedPoint],
    next_global: int,
) -> Tuple[int, List[Dict[str, Any]]]:
    mapping: Dict[int, int] = {}
    manifest: List[Dict[str, Any]] = []
    for segment in sorted(segments, key=lambda s: s.index):
        local_index = segment.index
        global_index = next_global
        next_global += 1
        mapping[local_index] = global_index
        segment.index = global_index
        for pose in segment.poses:
            pose.segment_index = global_index
        for tag in segment.price_tags:
            tag.segment_index = global_index
        manifest.append(
            {
                "global_segment_id": global_index,
                "device_id": device_id,
                "local_segment_index": local_index,
                "directory": str(segment.directory),
                "database": str(segment.database_path) if segment.database_path else None,
                "node_count": len(segment.poses),
                "price_tag_count": len(segment.price_tags),
            }
        )
    for point in points:
        if point.segment_index in mapping:
            point.segment_index = mapping[point.segment_index]
    return next_global, manifest


def generate(args: argparse.Namespace) -> Path:
    output_dir = Path(args.output).resolve() if args.output else Path.cwd() / f"MultiDeviceMap2D-{time.strftime('%Y%m%d-%H%M%S')}"

    devices, raw_config, config_path = load_inputs(args)
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

    device_states: List[Dict[str, Any]] = []
    for device in devices:
        segments = base.discover_segments(device["session"], config)
        stages, stage_by_segment, stage_transforms, segment_transforms, stage_config = staged.load_stage_config(device.get("stage_config"), segments)
        point_paths = list(device.get("points_csv", []))
        point_paths.extend(sorted(device["session"].glob("segment_*/points.csv")))
        point_paths.extend(sorted(device["session"].glob("points.csv")))
        points = base.load_projected_points(point_paths, config.horizontal_axes)
        applied = staged.apply_stage_transforms(segments, points, stage_by_segment, stage_transforms, segment_transforms)
        stage_report, stage_warnings = staged.stage_quality(stages, segments, stage_by_segment, stage_transforms, segment_transforms, bool(points))
        device_states.append(
            {
                "id": device["id"],
                "session": device["session"],
                "segments": segments,
                "points": points,
                "stage_report": stage_report,
                "stage_warnings": stage_warnings,
                "stage_config": stage_config,
                "stage_applied": applied,
                "device_transform": device["transform"],
                "has_explicit_transform": device["has_explicit_transform"],
                "alignment_mode": "explicit_transform" if device["has_explicit_transform"] else "identity",
                "point_paths": point_paths,
            }
        )

    if args.align_common_start or raw_config.get("align_common_start"):
        compute_common_start_transforms(device_states, raw_config.get("reference_device"))

    for state in device_states:
        apply_device_transform(state["segments"], state["points"], state["device_transform"])

    all_segments: List[base.Segment] = []
    all_points: List[base.ProjectedPoint] = []
    segment_manifest: List[Dict[str, Any]] = []
    next_global = 1
    for state in device_states:
        next_global, entries = reindex_device_segments(state["id"], state["segments"], state["points"], next_global)
        segment_manifest.extend(entries)
        all_segments.extend(state["segments"])
        all_points.extend(state["points"])

    global_point_paths = [Path(p).resolve() for p in args.points_csv]
    global_points = base.load_projected_points(global_point_paths, config.horizontal_axes)
    all_points.extend(global_points)
    base.require_map_evidence(all_segments, all_points)
    output_dir.mkdir(parents=True, exist_ok=True)

    tags = [tag for segment in all_segments for tag in segment.price_tags]
    base.snap_price_tags(tags, all_points, config.tag_snap_distance)
    grid = base.build_grid(all_segments, all_points, config)
    poses = [pose for segment in all_segments for pose in segment.poses]

    base.render_grid(grid, output_dir / "occupancy_grid.png")
    base.render_grid(grid, output_dir / "preview.png", trajectories=poses, tags=tags)
    base.write_yaml(output_dir / "occupancy_grid.yaml", grid, "occupancy_grid.png")
    base.write_geojson(output_dir / "trajectory.geojson", base.trajectory_geojson(all_segments))
    base.write_geojson(output_dir / "price_tags.geojson", base.price_tags_geojson(tags))
    base.write_geojson(output_dir / "vector_map.geojson", base.vector_map_geojson(grid))
    preview_3d_summary = base.write_preview_3d(
        output_dir / "preview_3d.json", all_segments, all_points, tags, config.horizontal_axes
    )
    (output_dir / "semantic_layers.json").write_text(json.dumps(base.semantic_layers(grid), ensure_ascii=False, indent=2), encoding="utf-8")

    report = base.quality_report(output_dir, all_segments, all_points, tags, grid, {})
    report["preview_3d"] = preview_3d_summary
    multi_warnings: List[Dict[str, Any]] = []
    if len(device_states) < 2:
        multi_warnings.append({"type": "multi_device", "message": "Only one device session was provided."})
    if not all_points:
        multi_warnings.append({"type": "map", "message": "No projected structure points were provided; the 2D output is mainly trajectory coverage, not final shelf/wall structure."})
    for state in device_states:
        multi_warnings.extend(state["stage_warnings"])
        if first_pose(state["segments"]) is None:
            multi_warnings.append({"type": "device", "device_id": state["id"], "message": "Device has no valid poses."})

    report["multi_device_summary"] = {
        "device_count": len(device_states),
        "segment_count": len(all_segments),
        "alignment_warnings": multi_warnings,
    }
    (output_dir / "quality_report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")

    manifest = {
        "format": "SupermarketMultiDeviceManifest",
        "version": 1,
        "generated_at": report["generated_at"],
        "alignment_mode": "common_start" if args.align_common_start or raw_config.get("align_common_start") else "configured_or_identity",
        "devices": [
            {
                "id": state["id"],
                "session": str(state["session"]),
                "alignment_mode": state["alignment_mode"],
                "device_transform": staged.transform_to_json(state["device_transform"]),
                "stage_count": len(state["stage_report"]["stages"]),
                "segment_count": len(state["segments"]),
                "node_count": sum(len(segment.poses) for segment in state["segments"]),
                "price_tag_count": sum(len(segment.price_tags) for segment in state["segments"]),
            }
            for state in device_states
        ],
        "segments": segment_manifest,
    }
    (output_dir / "multi_device_manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")
    (output_dir / "alignment_config_used.json").write_text(
        json.dumps(
            {
                "format": "SupermarketMultiDeviceConfigUsed",
                "version": 1,
                "source_config": raw_config,
                "devices": manifest["devices"],
            },
            ensure_ascii=False,
            indent=2,
        ),
        encoding="utf-8",
    )

    source_files = []
    for state in device_states:
        source_files.extend(base.source_manifest(state["session"], state["segments"], state["point_paths"]).get("files", []))
    for path in global_point_paths:
        if path.exists():
            source_files.append({"path": str(path), "sha256": base.sha256_file(path)})
    (output_dir / "source_manifest.json").write_text(
        json.dumps({"format": "SupermarketMultiDeviceSourceManifest", "files": source_files}, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    staged.write_review_items(output_dir / "review_items.json", report, multi_warnings, tags)

    map_json = {
        "format": "SupermarketMultiDeviceMap2D",
        "version": 1,
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
            "multi_device_manifest.json",
            "alignment_config_used.json",
            "review_items.json",
            "source_manifest.json",
        ],
    }
    (output_dir / "map.json").write_text(json.dumps(map_json, ensure_ascii=False, indent=2), encoding="utf-8")
    return output_dir


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Generate a PC-side multi-device 2D map package from SupermarketSession directories.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument("sessions", nargs="*", help="SupermarketSession-* directories. Optional when --config is used.")
    parser.add_argument("--config", help="Optional multi_device_config.json.")
    parser.add_argument("--output", help="Output MultiDeviceMap2D directory.")
    parser.add_argument("--align-common-start", action="store_true", help="Align each device first pose to the reference device first pose unless an explicit transform is configured.")
    parser.add_argument("--points-csv", action="append", default=[], help="Additional projected point CSV already in the global map frame.")
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
        print(f"supermarket_multi_device_map: {exc}", flush=True)
        return 1
    print(output_dir)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
