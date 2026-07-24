#!/usr/bin/env python3
"""Synthetic/recorded stage-one localization replay without supermarket data."""

from __future__ import annotations

import argparse
import csv
import json
import math
import random
import sys
from pathlib import Path
from typing import Any, Iterable

if __package__ in {None, ""}:
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
    from PriorMap.coordinate_system import normalize_angle, rounded
    from PriorMap.prior_map_schema import load_json
    from PriorMap.stage1_localizer import Pose2D, StageOneLocalizer
else:
    from .coordinate_system import normalize_angle, rounded
    from .prior_map_schema import load_json
    from .stage1_localizer import Pose2D, StageOneLocalizer


def synthetic_path(road_graph: dict[str, Any], floor_id: str, maximum_samples: int = 500) -> list[Pose2D]:
    nodes = {
        str(node["id"]): node
        for node in road_graph.get("nodes", [])
        if str(node.get("floor_id")) == str(floor_id)
    }
    adjacency: dict[str, list[str]] = {identifier: [] for identifier in nodes}
    for edge in road_graph.get("edges", []):
        if str(edge.get("floor_id")) != str(floor_id):
            continue
        first, second = str(edge["from"]), str(edge["to"])
        if first in adjacency and second in adjacency:
            adjacency[first].append(second)
            adjacency[second].append(first)
    if not nodes:
        raise ValueError(f"Floor {floor_id} has no road nodes.")
    for values in adjacency.values():
        values.sort()
    start = min(nodes, key=lambda identifier: (len(adjacency[identifier]) == 0, identifier))
    walk = [start]
    visited_edges: set[tuple[str, str]] = set()
    current = start
    while len(walk) < min(maximum_samples // 5, max(2, len(nodes) * 2)):
        options = [
            value
            for value in adjacency[current]
            if tuple(sorted((current, value))) not in visited_edges
        ]
        if not options:
            options = adjacency[current]
        if not options:
            break
        following = options[0]
        visited_edges.add(tuple(sorted((current, following))))
        walk.append(following)
        current = following
        if len(visited_edges) >= sum(len(value) for value in adjacency.values()) // 2:
            break
    poses: list[Pose2D] = []
    for first_id, second_id in zip(walk, walk[1:]):
        first = nodes[first_id]["position_m"]
        second = nodes[second_id]["position_m"]
        dx = float(second[0]) - float(first[0])
        dy = float(second[1]) - float(first[1])
        distance = math.hypot(dx, dy)
        steps = max(1, int(math.ceil(distance / 0.5)))
        yaw = math.atan2(dy, dx)
        for index in range(steps):
            ratio = index / steps
            poses.append(
                Pose2D(
                    float(first[0]) + dx * ratio,
                    float(first[1]) + dy * ratio,
                    yaw,
                )
            )
            if len(poses) >= maximum_samples:
                return poses
    if walk:
        final = nodes[walk[-1]]["position_m"]
        poses.append(Pose2D(float(final[0]), float(final[1]), poses[-1].yaw_rad if poses else 0.0))
    return poses


def recorded_path(path: Path) -> list[Pose2D]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(payload, list):
        raise ValueError("trajectory_samples input must be a JSON array.")
    return [
        Pose2D(float(item["x"]), float(item.get("z", item.get("y", 0.0))), float(item.get("yaw", 0.0)))
        for item in payload
    ]


def replay(
    package: Path | str,
    output: Path | str,
    floor_id: str | None = None,
    trajectory: Path | str | None = None,
    translation_drift_per_m: float = 0.0,
    rotation_drift_deg_per_m: float = 0.0,
    noise_std_m: float = 0.0,
    tracking_loss_start: int = -1,
    tracking_loss_length: int = 0,
    seed: int = 7,
) -> dict[str, Any]:
    root = Path(package)
    output_path = Path(output)
    output_path.mkdir(parents=True, exist_ok=True)
    manifest = load_json(root / "manifest.json")
    graph = load_json(root / "road_graph.json")
    floor = str(floor_id or manifest["floors"][0]["id"])
    truth = recorded_path(Path(trajectory)) if trajectory is not None else synthetic_path(graph, floor)
    if not truth:
        raise ValueError("Replay trajectory is empty.")
    rng = random.Random(seed)
    localizer = StageOneLocalizer(graph, floor, truth[0])
    travelled = 0.0
    samples: list[dict[str, Any]] = []
    errors: list[float] = []
    previous = truth[0]
    for index, target in enumerate(truth):
        travelled += math.hypot(target.x_m - previous.x_m, target.y_m - previous.y_m)
        drift_x = travelled * float(translation_drift_per_m)
        drift_yaw = math.radians(float(rotation_drift_deg_per_m)) * travelled
        map_dx = target.x_m - truth[0].x_m
        map_dy = target.y_m - truth[0].y_m
        origin_cosine = math.cos(truth[0].yaw_rad)
        origin_sine = math.sin(truth[0].yaw_rad)
        local_x = origin_cosine * map_dx + origin_sine * map_dy
        local_y = -origin_sine * map_dx + origin_cosine * map_dy
        noisy_x = local_x + drift_x + rng.gauss(0.0, noise_std_m)
        noisy_y = local_y + rng.gauss(0.0, noise_std_m)
        arkit = Pose2D(noisy_x, noisy_y, normalize_angle(target.yaw_rad - truth[0].yaw_rad + drift_yaw))
        tracking = (
            "notAvailable"
            if tracking_loss_start <= index < tracking_loss_start + tracking_loss_length
            else "normal"
        )
        update = localizer.update(arkit, tracking)
        estimated = update["estimated_pose"]
        error = math.hypot(float(estimated["x_m"]) - target.x_m, float(estimated["y_m"]) - target.y_m)
        errors.append(error)
        samples.append(
            {
                "index": index,
                "ground_truth": target.as_dict(),
                "arkit_pose": arkit.as_dict(),
                "estimated_pose": estimated,
                "error_m": rounded(error),
                "road_assignment": (
                    update["road_constraint"]["candidates"][0]["edge_id"]
                    if update["road_constraint"]["candidates"]
                    else None
                ),
                "localization_state": update["localization_state"],
                "tracking_state": tracking,
                "constraint_accepted": update["road_constraint"]["accepted"],
                "constraint_reason": update["road_constraint"]["reason"],
            }
        )
        previous = target

    sorted_errors = sorted(errors)
    percentile_index = min(len(sorted_errors) - 1, int(math.floor(len(sorted_errors) * 0.95)))
    report = {
        "format": "MarketScannerLocalizationReplay",
        "version": 1,
        "prior_map_id": manifest["prior_map_id"],
        "source_sha256": manifest["source_sha256"],
        "floor_id": floor,
        "parameters": {
            "translation_drift_per_m": translation_drift_per_m,
            "rotation_drift_deg_per_m": rotation_drift_deg_per_m,
            "noise_std_m": noise_std_m,
            "tracking_loss_start": tracking_loss_start,
            "tracking_loss_length": tracking_loss_length,
            "seed": seed,
        },
        "summary": {
            "sample_count": len(samples),
            "path_length_m": rounded(travelled),
            "mean_error_m": rounded(sum(errors) / len(errors)),
            "maximum_error_m": rounded(max(errors)),
            "p95_error_m": rounded(sorted_errors[percentile_index]),
            "accepted_soft_constraint_count": sum(item["constraint_accepted"] for item in samples),
            "state_counts": {
                state: sum(item["localization_state"] == state for item in samples)
                for state in ("stable", "usable", "weak", "lost")
            },
        },
        "samples": samples,
    }
    (output_path / "replay_report.json").write_text(
        json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    with (output_path / "localization_trace.csv").open("w", encoding="utf-8", newline="") as handle:
        writer = csv.writer(handle)
        writer.writerow(
            [
                "index",
                "ground_truth_x_m",
                "ground_truth_y_m",
                "estimated_x_m",
                "estimated_y_m",
                "error_m",
                "road_assignment",
                "localization_state",
                "tracking_state",
            ]
        )
        for item in samples:
            writer.writerow(
                [
                    item["index"],
                    item["ground_truth"]["x_m"],
                    item["ground_truth"]["y_m"],
                    item["estimated_pose"]["x_m"],
                    item["estimated_pose"]["y_m"],
                    item["error_m"],
                    item["road_assignment"] or "",
                    item["localization_state"],
                    item["tracking_state"],
                ]
            )
    return report


def main(argv: Iterable[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Replay stage-one prior-map localization.")
    parser.add_argument("package", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--floor")
    parser.add_argument("--trajectory", type=Path)
    parser.add_argument("--translation-drift-per-m", type=float, default=0.0)
    parser.add_argument("--rotation-drift-deg-per-m", type=float, default=0.0)
    parser.add_argument("--noise-std-m", type=float, default=0.0)
    parser.add_argument("--tracking-loss-start", type=int, default=-1)
    parser.add_argument("--tracking-loss-length", type=int, default=0)
    parser.add_argument("--seed", type=int, default=7)
    args = parser.parse_args(argv)
    report = replay(
        args.package,
        args.output,
        args.floor,
        args.trajectory,
        args.translation_drift_per_m,
        args.rotation_drift_deg_per_m,
        args.noise_std_m,
        args.tracking_loss_start,
        args.tracking_loss_length,
        args.seed,
    )
    print(json.dumps(report["summary"], ensure_ascii=False, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
