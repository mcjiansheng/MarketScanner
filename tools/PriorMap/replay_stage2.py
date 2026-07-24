#!/usr/bin/env python3
"""Deterministic Stage-2 structure-matching replay and performance report."""

from __future__ import annotations

import argparse
import json
import math
import random
import statistics
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from tools.PriorMap.distance_field import decode_level
from tools.PriorMap.prior_map_schema import validate_package


@dataclass(frozen=True)
class Pose:
    x: float
    y: float
    yaw: float


class DistanceLevel:
    def __init__(self, payload: dict[str, Any], truncation_m: float) -> None:
        self.resolution = float(payload["resolution_m"])
        self.origin_x, self.origin_y = map(float, payload["origin_m"])
        self.width = int(payload["width"])
        self.height = int(payload["height"])
        self.values = decode_level(payload)
        self.truncation_m = truncation_m

    def distance(self, x: float, y: float) -> float:
        column = math.floor((x - self.origin_x) / self.resolution)
        row = math.floor((y - self.origin_y) / self.resolution)
        if column < 0 or row < 0 or column >= self.width or row >= self.height:
            return self.truncation_m
        return min(
            self.truncation_m,
            self.values[row * self.width + column] / 100.0,
        )


def _normalize(value: float) -> float:
    return math.atan2(math.sin(value), math.cos(value))


def _compose(first: Pose, second: Pose) -> Pose:
    cosine, sine = math.cos(first.yaw), math.sin(first.yaw)
    return Pose(
        first.x + cosine * second.x - sine * second.y,
        first.y + sine * second.x + cosine * second.y,
        _normalize(first.yaw + second.yaw),
    )


def _inverse(pose: Pose) -> Pose:
    cosine, sine = math.cos(pose.yaw), math.sin(pose.yaw)
    return Pose(
        -cosine * pose.x - sine * pose.y,
        sine * pose.x - cosine * pose.y,
        _normalize(-pose.yaw),
    )


def _relative(first: Pose, second: Pose) -> Pose:
    """Return the local SE(2) correction `first⁻¹ ∘ second`."""
    return _compose(_inverse(first), second)


def _blend(first: Pose, second: Pose, gain: float) -> Pose:
    return Pose(
        first.x + (second.x - first.x) * gain,
        first.y + (second.y - first.y) * gain,
        _normalize(first.yaw + _normalize(second.yaw - first.yaw) * gain),
    )


def _cost(pose: Pose, points: list[tuple[float, float]], level: DistanceLevel) -> float:
    cosine, sine = math.cos(pose.yaw), math.sin(pose.yaw)
    total = 0.0
    for x, y in points:
        distance = level.distance(
            pose.x + cosine * x - sine * y,
            pose.y + sine * x + cosine * y,
        )
        total += min(0.45, distance) ** 2
    return total / max(1, len(points))


def _search(
    center: Pose,
    points: list[tuple[float, float]],
    level: DistanceLevel,
    translation_radius: float,
    translation_step: float,
    yaw_radius_deg: float,
    yaw_step_deg: float,
) -> list[tuple[float, Pose]]:
    translation_steps = math.floor(translation_radius / translation_step)
    yaw_steps = math.floor(yaw_radius_deg / yaw_step_deg)
    candidates: list[tuple[float, Pose]] = []
    for ix in range(-translation_steps, translation_steps + 1):
        for iy in range(-translation_steps, translation_steps + 1):
            for iyaw in range(-yaw_steps, yaw_steps + 1):
                pose = Pose(
                    center.x + ix * translation_step,
                    center.y + iy * translation_step,
                    _normalize(
                        center.yaw + math.radians(iyaw * yaw_step_deg)
                    ),
                )
                candidates.append((_cost(pose, points, level), pose))
    return sorted(candidates, key=lambda value: (value[0], value[1].x, value[1].y, value[1].yaw))


def _independent_candidates(
    candidates: list[tuple[float, Pose]],
    limit: int,
    translation_separation_m: float = 0.25,
    yaw_separation_deg: float = 4.0,
) -> list[tuple[float, Pose]]:
    selected: list[tuple[float, Pose]] = []
    yaw_separation = math.radians(yaw_separation_deg)
    for candidate in candidates:
        if all(
            math.hypot(
                candidate[1].x - other[1].x,
                candidate[1].y - other[1].y,
            )
            >= translation_separation_m
            or abs(_normalize(candidate[1].yaw - other[1].yaw)) >= yaw_separation
            for other in selected
        ):
            selected.append(candidate)
        if len(selected) == limit:
            break
    return selected


def _refine(
    centers: list[tuple[float, Pose]],
    fallback: Pose,
    points: list[tuple[float, float]],
    level: DistanceLevel,
    translation_radius: float,
    translation_step: float,
    yaw_radius_deg: float,
    yaw_step_deg: float,
    hypothesis_limit: int = 8,
) -> list[tuple[float, Pose]]:
    poses = [candidate[1] for candidate in centers] or [fallback]
    expanded = sorted(
        (
            candidate
            for center in poses
            for candidate in _search(
                center,
                points,
                level,
                translation_radius,
                translation_step,
                yaw_radius_deg,
                yaw_step_deg,
            )
        ),
        key=lambda value: (value[0], value[1].x, value[1].y, value[1].yaw),
    )
    return _independent_candidates(expanded, hypothesis_limit)


def match(
    predicted: Pose,
    points: list[tuple[float, float]],
    levels: list[DistanceLevel],
) -> dict[str, Any]:
    started = time.perf_counter()
    sampled = points[:: max(1, len(points) // 600)]
    if len(sampled) < 30:
        return {
            "accepted": False,
            "reason": "insufficient_structure_points",
            "elapsed_ms": (time.perf_counter() - started) * 1000,
            "points": len(sampled),
        }
    coarse = _independent_candidates(
        _search(predicted, sampled, levels[0], 1.2, 0.4, 12, 4),
        8,
        translation_separation_m=0.35,
    )
    medium = _refine(coarse, predicted, sampled, levels[1], 0.4, 0.2, 4, 2)
    fine = _refine(medium, predicted, sampled, levels[-1], 0.2, 0.1, 2, 1)
    top = fine[:3]
    best_cost, best = top[0]
    second_cost = top[1][0] if len(top) > 1 else None
    uniqueness = (
        max(0.0, min(1.0, (second_cost - best_cost) / max(second_cost, 0.01)))
        if second_cost is not None
        else 0.0
    )
    correction_m = math.hypot(best.x - predicted.x, best.y - predicted.y)
    correction_yaw = abs(_normalize(best.yaw - predicted.yaw))
    accepted = (
        len(sampled) >= 45
        and best_cost <= 0.10
        and second_cost is not None
        and uniqueness >= 0.10
        and correction_m <= 0.35
        and correction_yaw <= math.radians(8)
    )
    if best_cost > 0.10:
        reason = "map_mismatch"
    elif second_cost is None or uniqueness < 0.10:
        reason = "ambiguous_structure_match"
    elif correction_m > 0.35 or correction_yaw > math.radians(8):
        reason = "correction_exceeds_safety_gate"
    else:
        reason = "geometry_candidate"
    return {
        "accepted": accepted,
        "reason": reason,
        "pose": best,
        "cost": best_cost,
        "uniqueness": uniqueness,
        "elapsed_ms": (time.perf_counter() - started) * 1000,
        "points": len(sampled),
    }


def _boundary_points(elements: list[dict[str, Any]], floor_id: str) -> list[tuple[float, float]]:
    points: list[tuple[float, float]] = []
    for element in elements:
        if (
            element.get("floor_id") != floor_id
            or element.get("visible") is not True
            or element.get("shape_type")
            not in {"MapShelf", "MapTable", "MapPillar", "MapTableFeature"}
        ):
            continue
        coordinates = element.get("geometry", {}).get("coordinates", [])
        if len(coordinates) < 2:
            continue
        if coordinates[0] != coordinates[-1]:
            coordinates = [*coordinates, coordinates[0]]
        for start, end in zip(coordinates, coordinates[1:]):
            length = math.hypot(end[0] - start[0], end[1] - start[1])
            steps = max(1, math.ceil(length / 0.08))
            points.extend(
                (
                    start[0] + (end[0] - start[0]) * index / steps,
                    start[1] + (end[1] - start[1]) * index / steps,
                )
                for index in range(steps + 1)
            )
    return points


def _observation(
    true_pose: Pose,
    map_points: list[tuple[float, float]],
    rng: random.Random,
    dynamic_fraction: float,
) -> list[tuple[float, float]]:
    cosine, sine = math.cos(-true_pose.yaw), math.sin(-true_pose.yaw)
    observed: list[tuple[float, float]] = []
    for x, y in map_points:
        dx, dy = x - true_pose.x, y - true_pose.y
        if math.hypot(dx, dy) > 6.0:
            continue
        observed.append(
            (
                cosine * dx - sine * dy + rng.gauss(0, 0.015),
                sine * dx + cosine * dy + rng.gauss(0, 0.015),
            )
        )
    dynamic_count = round(len(observed) * max(0, dynamic_fraction))
    observed.extend(
        (rng.uniform(-4, 4), rng.uniform(-1, 6))
        for _ in range(dynamic_count)
    )
    return observed


def _percentile(values: list[float], fraction: float) -> float:
    ordered = sorted(values)
    if not ordered:
        return 0.0
    return ordered[min(len(ordered) - 1, round((len(ordered) - 1) * fraction))]


def replay(
    package: Path,
    output: Path | None = None,
    floor_id: str | None = None,
    seed: int = 24,
    dynamic_fraction: float = 0.2,
    wrong_initial_offset_m: float = 0.0,
    tracking_loss_indices: set[int] | None = None,
) -> dict[str, Any]:
    validation = validate_package(package)
    if not validation["valid"]:
        raise ValueError("Prior-map package is invalid: " + "; ".join(validation["errors"]))
    manifest = json.loads((package / "manifest.json").read_text(encoding="utf-8"))
    floor_id = floor_id or manifest["floors"][0]["id"]
    floor = next(item for item in manifest["floors"] if item["id"] == floor_id)
    elements = json.loads((package / "elements.json").read_text(encoding="utf-8"))["elements"]
    fields = json.loads((package / "distance_fields.json").read_text(encoding="utf-8"))
    truncation = float(fields["truncation_distance_m"])
    levels = [
        DistanceLevel(level, truncation)
        for level in sorted(
            fields["floors"][floor_id]["levels"],
            key=lambda item: item["resolution_m"],
            reverse=True,
        )
    ]
    map_points = _boundary_points(elements, floor_id)
    bounds = floor["bounds"]
    start_x = float(bounds["min_x_m"]) + 1
    end_x = float(bounds["max_x_m"]) - 1
    center_y = (float(bounds["min_y_m"]) + float(bounds["max_y_m"])) / 2
    rng = random.Random(seed)
    samples: list[dict[str, Any]] = []
    consecutive_trusted = 0
    consecutive_rejected = 0
    consecutive_consistent = 0
    last_correction: Pose | None = None
    last_accepted_timestamp: float | None = None
    arkit_origin = Pose(0, 0, 0)
    initial_map_pose = Pose(
        start_x + wrong_initial_offset_m + 0.18,
        center_y,
        0,
    )
    map_from_arkit = _compose(initial_map_pose, _inverse(arkit_origin))
    tracking_loss_indices = tracking_loss_indices or set()
    for index in range(24):
        ratio = index / 23
        true_pose = Pose(start_x + (end_x - start_x) * ratio, center_y, 0)
        # ARKit remains continuous. Slowly varying odometry drift is applied in
        # its own frame; accepted corrections update only map_from_arkit.
        arkit_pose = Pose(
            true_pose.x - start_x + 0.08 * ratio,
            true_pose.y - center_y + 0.10 * math.sin(ratio * math.pi),
            math.radians(0.2 * ratio),
        )
        predicted = _compose(map_from_arkit, arkit_pose)
        observed = _observation(true_pose, map_points, rng, dynamic_fraction)
        tracking_normal = index not in tracking_loss_indices
        result = (
            match(predicted, observed, levels)
            if tracking_normal
            else {
                "accepted": False,
                "reason": "tracking_not_normal",
                "elapsed_ms": 0.0,
                "points": 0,
            }
        )
        geometry_accepted = bool(result["accepted"])
        best = result.get("pose")
        correction = _relative(predicted, best) if best is not None else None
        consistent = False
        if correction is not None and last_correction is not None:
            consistent = (
                math.hypot(
                    correction.x - last_correction.x,
                    correction.y - last_correction.y,
                )
                <= 0.12
                and abs(_normalize(correction.yaw - last_correction.yaw))
                <= math.radians(3)
            )
        if correction is not None:
            consecutive_consistent = consecutive_consistent + 1 if consistent else 1
            last_correction = correction
        else:
            consecutive_consistent = 0
            last_correction = None
        applied = geometry_accepted and consecutive_consistent >= 2 and best is not None
        estimated = _blend(predicted, best, 0.35) if applied else predicted
        if applied:
            map_from_arkit = _compose(estimated, _inverse(arkit_pose))
            consecutive_trusted += 1
            consecutive_rejected = 0
            last_accepted_timestamp = index * 0.5
        else:
            consecutive_rejected += 1
            consecutive_trusted = 0
        timestamp = index * 0.5
        stale = (
            timestamp - last_accepted_timestamp
            if last_accepted_timestamp is not None
            else math.inf
        )
        if not tracking_normal:
            state = "lost"
        elif last_accepted_timestamp is None:
            state = "weak" if consecutive_rejected >= 3 else "initializing"
        elif stale > 10:
            state = "lost"
        elif stale > 4 or consecutive_rejected >= 3:
            state = "weak"
        elif (
            applied
            and consecutive_trusted >= 3
            and result.get("points", 0) >= 80
            and result.get("uniqueness", 0) >= 0.22
        ):
            state = "stable"
        else:
            state = "usable"
        estimated_yaw_error = abs(_normalize(estimated.yaw - true_pose.yaw))
        samples.append(
            {
                "index": index,
                "true_pose": true_pose.__dict__,
                "predicted_pose": predicted.__dict__,
                "estimated_pose": estimated.__dict__,
                "geometry_accepted": geometry_accepted,
                "accepted": applied,
                "reason": (
                    result["reason"]
                    if not geometry_accepted
                    else "trusted_structure_correction"
                    if applied
                    else "awaiting_temporal_consistency"
                ),
                "state": state,
                "correction": correction.__dict__ if correction is not None else None,
                "consecutive_consistent": consecutive_consistent,
                "point_count": result["points"],
                "uniqueness": result.get("uniqueness", 0),
                "residual_cost": result.get("cost"),
                "matcher_elapsed_ms": result["elapsed_ms"],
                "predicted_error_m": math.hypot(
                    predicted.x - true_pose.x, predicted.y - true_pose.y
                ),
                "estimated_error_m": math.hypot(
                    estimated.x - true_pose.x, estimated.y - true_pose.y
                ),
                "estimated_yaw_error_deg": math.degrees(estimated_yaw_error),
            }
        )
    predicted_errors = [sample["predicted_error_m"] for sample in samples]
    estimated_errors = [sample["estimated_error_m"] for sample in samples]
    timings = [sample["matcher_elapsed_ms"] for sample in samples]
    yaw_errors = [sample["estimated_yaw_error_deg"] for sample in samples]
    report = {
        "format": "MarketScannerStage2Replay",
        "version": 1,
        "scenario": {
            "seed": seed,
            "floor_id": floor_id,
            "dynamic_fraction": dynamic_fraction,
            "wrong_initial_offset_m": wrong_initial_offset_m,
            "tracking_loss_indices": sorted(tracking_loss_indices),
            "single_floor": True,
        },
        "summary": {
            "sample_count": len(samples),
            "accepted_count": sum(sample["accepted"] for sample in samples),
            "rejected_count": sum(not sample["accepted"] for sample in samples),
            "single_frame_geometry_candidate_count": sum(
                sample["geometry_accepted"] for sample in samples
            ),
            "median_predicted_error_m": statistics.median(predicted_errors),
            "median_estimated_error_m": statistics.median(estimated_errors),
            "p95_estimated_error_m": _percentile(estimated_errors, 0.95),
            "maximum_estimated_error_m": max(estimated_errors),
            "p95_estimated_yaw_error_deg": _percentile(yaw_errors, 0.95),
            "correct_channel_count": sum(error <= 0.50 for error in estimated_errors),
            "catastrophic_jump_count": sum(error > 2.0 for error in estimated_errors),
            "tracking_recovery_frames": (
                next(
                    (
                        sample["index"] - max(tracking_loss_indices)
                        for sample in samples
                        if sample["index"] > max(tracking_loss_indices)
                        and sample["accepted"]
                    ),
                    None,
                )
                if tracking_loss_indices
                else 0
            ),
            "matcher_p50_ms": statistics.median(timings),
            "matcher_p95_ms": _percentile(timings, 0.95),
            "matcher_max_ms": max(timings),
            "state_counts": {
                state: sum(sample["state"] == state for sample in samples)
                for state in ("initializing", "stable", "usable", "weak", "lost")
            },
        },
        "samples": samples,
    }
    if output is not None:
        output.mkdir(parents=True, exist_ok=True)
        (output / "stage2_replay_report.json").write_text(
            json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
    return report


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("package", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--floor")
    parser.add_argument("--seed", type=int, default=24)
    parser.add_argument("--dynamic-fraction", type=float, default=0.2)
    parser.add_argument("--wrong-initial-offset-m", type=float, default=0.0)
    parser.add_argument("--tracking-loss-start", type=int)
    parser.add_argument("--tracking-loss-frames", type=int, default=0)
    arguments = parser.parse_args()
    report = replay(
        arguments.package,
        arguments.output,
        floor_id=arguments.floor,
        seed=arguments.seed,
        dynamic_fraction=arguments.dynamic_fraction,
        wrong_initial_offset_m=arguments.wrong_initial_offset_m,
        tracking_loss_indices=(
            set(
                range(
                    arguments.tracking_loss_start,
                    arguments.tracking_loss_start + arguments.tracking_loss_frames,
                )
            )
            if arguments.tracking_loss_start is not None
            and arguments.tracking_loss_frames > 0
            else None
        ),
    )
    print(json.dumps(report["summary"], ensure_ascii=False, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
