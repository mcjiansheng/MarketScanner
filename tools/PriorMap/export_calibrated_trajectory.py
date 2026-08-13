#!/usr/bin/env python3
"""Export calibrated phone coordinates and dependency-free route previews.

The immutable localized version is never modified.  This tool verifies the
version manifest entry for the trajectory and localization report, then writes
ordinary review/export artifacts to a separate directory.
"""

from __future__ import annotations

import argparse
import csv
from datetime import datetime, timezone
import hashlib
import json
import math
from pathlib import Path
from typing import Any, Iterable, Sequence

if __package__ in {None, ""}:
    import sys

    sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent))
    from tools.PriorMap.offline_localization import (
        AbsoluteConstraint,
        Pose,
        calibrated_trajectory_rows,
        write_calibrated_trajectory_exports,
    )
    from tools.PriorMap.prior_map_schema import load_json
    from tools.PriorMap.render_prior_map import (
        PILLAR,
        ROAD,
        ROAD_CENTER,
        SHELF_EDGE,
        SHELF_FILL,
        TABLE_EDGE,
        TABLE_FILL,
        Raster,
        _projection,
    )
else:
    from .offline_localization import (
        AbsoluteConstraint,
        Pose,
        calibrated_trajectory_rows,
        write_calibrated_trajectory_exports,
    )
    from .prior_map_schema import load_json
    from .render_prior_map import (
        PILLAR,
        ROAD,
        ROAD_CENTER,
        SHELF_EDGE,
        SHELF_FILL,
        TABLE_EDGE,
        TABLE_FILL,
        Raster,
        _projection,
    )


ROUTE = (220, 28, 174)
ROUTE_LOW = (239, 132, 34)
START = (22, 166, 74)
END = (31, 80, 220)
ANCHOR = (208, 32, 45)
TIME_MARK = (75, 56, 215)


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def _verified_json(version: Path, name: str) -> Any:
    manifest_path = version / "version_manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if (
        not isinstance(manifest, dict)
        or manifest.get("format") != "MarketScannerLocalizedVersionManifest"
        or not isinstance(manifest.get("files"), list)
    ):
        raise ValueError("localized_version_manifest_invalid")
    entries = [
        item
        for item in manifest["files"]
        if isinstance(item, dict) and item.get("file") == name
    ]
    if len(entries) != 1:
        raise ValueError(f"localized_artifact_manifest_entry_invalid:{name}")
    path = version / name
    entry = entries[0]
    if (
        not path.is_file()
        or path.stat().st_size != entry.get("bytes")
        or _sha256(path) != entry.get("sha256")
    ):
        raise ValueError(f"localized_artifact_identity_invalid:{name}")
    return json.loads(path.read_text(encoding="utf-8"))


def _final_poses(trajectory: dict[str, Any]) -> list[Pose]:
    features = trajectory.get("features")
    if not isinstance(features, list):
        raise ValueError("optimized_trajectory_features_invalid")
    matches = [
        feature
        for feature in features
        if isinstance(feature, dict)
        and feature.get("properties", {}).get("layer")
        == "prior_map_offline_optimized"
    ]
    if len(matches) != 1:
        raise ValueError("optimized_trajectory_layer_invalid")
    feature = matches[0]
    properties = feature.get("properties", {})
    coordinates = feature.get("geometry", {}).get("coordinates")
    node_ids = properties.get("node_ids")
    timestamps = properties.get("timestamps")
    yaws_rad = properties.get("yaws_rad")
    if (
        not isinstance(coordinates, list)
        or not isinstance(node_ids, list)
        or not isinstance(timestamps, list)
        or not isinstance(yaws_rad, list)
        or len(coordinates) != len(node_ids)
        or len(coordinates) != len(timestamps)
        or len(coordinates) != len(yaws_rad)
        or not coordinates
    ):
        raise ValueError("optimized_trajectory_inventory_invalid")
    poses: list[Pose] = []
    for node_id, timestamp, coordinate, yaw_rad in zip(
        node_ids, timestamps, coordinates, yaws_rad
    ):
        if not isinstance(coordinate, list) or len(coordinate) < 2:
            raise ValueError("optimized_trajectory_coordinate_invalid")
        values = (
            float(timestamp),
            float(coordinate[0]),
            float(coordinate[1]),
            float(yaw_rad),
        )
        if not all(math.isfinite(value) for value in values):
            raise ValueError("optimized_trajectory_nonfinite")
        poses.append(
            Pose(
                int(node_id),
                values[0],
                values[1],
                values[2],
                values[3],
            )
        )
    return poses


def _manual_constraints(
    poses: Sequence[Pose], report: dict[str, Any]
) -> list[AbsoluteConstraint]:
    by_id = {pose.node_id: index for index, pose in enumerate(poses)}
    constraints: list[AbsoluteConstraint] = []
    events = report.get("manual_localization_event_audit")
    if not isinstance(events, list):
        return constraints
    for sequence, item in enumerate(events, start=1):
        if (
            not isinstance(item, dict)
            or item.get("status") != "accepted"
            or item.get("trusted_absolute") is not True
        ):
            continue
        try:
            index = by_id[int(item.get("bound_node_id"))]
        except (KeyError, TypeError, ValueError):
            continue
        pose = poses[index]
        constraints.append(
            AbsoluteConstraint(
                identifier=str(item.get("constraint_id") or f"manual-{sequence}"),
                node_index=index,
                x=pose.x,
                y=pose.y,
                yaw=pose.yaw,
                weight=1.0,
                kind="manual_anchor",
                source=item,
                trusted_absolute=True,
            )
        )
    return constraints


def _render(
    prior_map: Path,
    output: Path,
    floor_id: str,
    poses: Sequence[Pose],
    rows: Sequence[dict[str, Any]],
    *,
    timestamped: bool,
) -> None:
    manifest = load_json(prior_map / "manifest.json")
    elements = load_json(prior_map / "elements.json").get("elements", [])
    graph = load_json(prior_map / "road_graph.json")
    floor = next(
        item
        for item in manifest.get("floors", [])
        if str(item.get("id")) == floor_id
    )
    bounds = floor["bounds"]
    width, height, scale = _projection(bounds, 1800, 1400)
    margin = 32

    def point(value: Sequence[float]) -> tuple[float, float]:
        return (
            margin + (float(value[0]) - float(bounds["min_x_m"])) * scale,
            margin + (float(bounds["max_y_m"]) - float(value[1])) * scale,
        )

    raster = Raster(width, height)
    for cross in graph.get("crosses", []):
        if str(cross.get("floor_id")) != floor_id:
            continue
        values = cross.get("points_m")
        if not isinstance(values, list) or len(values) != 2:
            continue
        raster.line(
            point(values[0]),
            point(values[1]),
            ROAD,
            max(2.0, float(cross.get("width_m", 0.5)) * scale),
        )
        raster.line(point(values[0]), point(values[1]), ROAD_CENTER, 1.0)

    for element in elements:
        if (
            not isinstance(element, dict)
            or str(element.get("floor_id")) != floor_id
            or element.get("visible") is not True
        ):
            continue
        geometry = element.get("geometry")
        coordinates = (
            geometry.get("coordinates") if isinstance(geometry, dict) else None
        )
        if not isinstance(coordinates, list) or len(coordinates) < 3:
            continue
        shape = str(element.get("shape_type"))
        if shape == "MapPillar":
            fill = edge = PILLAR
        elif shape in {"MapTable", "MapTableFeature"}:
            fill, edge = TABLE_FILL, TABLE_EDGE
        elif shape == "MapShelf":
            fill, edge = SHELF_FILL, SHELF_EDGE
        else:
            continue
        raster.polygon([point(value) for value in coordinates], fill, edge)

    projected = [point((pose.x, pose.y)) for pose in poses]
    for index, (first, second) in enumerate(zip(projected, projected[1:])):
        low = (
            rows[index].get("route_confidence") == "low"
            or rows[index + 1].get("route_confidence") == "low"
        )
        raster.line(first, second, ROUTE_LOW if low else ROUTE, 3.0)
    raster.disk(*projected[0], 6.0, START)
    raster.disk(*projected[-1], 6.0, END)
    for index, row in enumerate(rows):
        if row.get("manual_anchor_status") == "trusted_manual_anchor":
            raster.disk(*projected[index], 7.0, ANCHOR)

    if timestamped:
        next_timestamp = math.ceil(float(poses[0].timestamp) / 60.0) * 60.0
        cursor = 0
        while next_timestamp <= float(poses[-1].timestamp):
            while (
                cursor + 1 < len(poses)
                and float(poses[cursor + 1].timestamp) < next_timestamp
            ):
                cursor += 1
            index = min(cursor + 1, len(poses) - 1)
            raster.disk(*projected[index], 4.0, TIME_MARK)
            next_timestamp += 60.0
    raster.save_png(output)


def export(
    prior_map: Path,
    version: Path,
    output: Path,
) -> dict[str, Any]:
    trajectory = _verified_json(version, "optimized_map_trajectory.geojson")
    report = _verified_json(version, "localization_report.json")
    poses = _final_poses(trajectory)
    route_audit = report.get("corridor_route_match")
    if not isinstance(route_audit, dict):
        route_audit = {"status": "unavailable"}
    constraints = _manual_constraints(poses, report)
    output.mkdir(parents=True, exist_ok=False)
    write_calibrated_trajectory_exports(output, poses, route_audit, constraints)
    rows = calibrated_trajectory_rows(poses, route_audit, constraints)
    floor_id = str(report.get("floor_id") or "")
    if not floor_id:
        prior_manifest = load_json(prior_map / "manifest.json")
        floors = prior_manifest.get("floors", [])
        floor_id = str(floors[0].get("id")) if floors else ""
    _render(
        prior_map,
        output / "calibrated_trajectory_on_prior_map.png",
        floor_id,
        poses,
        rows,
        timestamped=False,
    )
    _render(
        prior_map,
        output / "calibrated_trajectory_timestamped.png",
        floor_id,
        poses,
        rows,
        timestamped=True,
    )
    artifacts = [
        "calibrated_positions_by_node.csv",
        "calibrated_positions_1s.csv",
        "calibrated_trajectory_on_prior_map.png",
        "calibrated_trajectory_timestamped.png",
    ]
    with (output / "calibrated_positions_1s.csv").open(
        "r", encoding="utf-8"
    ) as handle:
        one_second_sample_count = max(0, sum(1 for _ in handle) - 1)
    manifest = {
        "format": "MarketScannerCalibratedTrajectoryExport",
        "version": 1,
        "source_version": version.name,
        "source_version_manifest_sha256": _sha256(
            version / "version_manifest.json"
        ),
        "prior_map_id": report.get("prior_map_id"),
        "floor_id": floor_id,
        "node_count": len(poses),
        "one_second_sample_count": one_second_sample_count,
        "route_confidence": route_audit.get("route_confidence"),
        "corridor_identity_confidence": (
            "low"
            if route_audit.get("ambiguity_intervals")
            else "resolved_within_draft"
        ),
        "distance_scale_confidence": route_audit.get(
            "distance_scale_confidence"
        ),
        "yaw_source": "optimized_phone_pose",
        "result_quality_status": report.get("result_quality_status"),
        "partial_result": report.get("partial_result") is True,
        "review_gate_passed": report.get("review_gate", {}).get("passed") is True,
        "review_blocker_codes": [
            str(item.get("code"))
            for item in report.get("review_gate", {}).get("blockers", [])
            if isinstance(item, dict) and item.get("code") is not None
        ],
        "publish_permitted": report.get("publish_permitted") is True,
        "artifacts": [
            {
                "file": name,
                "bytes": (output / name).stat().st_size,
                "sha256": _sha256(output / name),
            }
            for name in artifacts
        ],
    }
    (output / "export_manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True)
        + "\n",
        encoding="utf-8",
    )
    return manifest


def main(argv: Iterable[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Export calibrated node/second coordinates and route previews."
    )
    parser.add_argument("prior_map", type=Path)
    parser.add_argument("localized_version", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args(argv)
    result = export(args.prior_map, args.localized_version, args.output)
    print(json.dumps(result, ensure_ascii=False, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
