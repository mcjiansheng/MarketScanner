#!/usr/bin/env python3
"""Cost model + benchmark for the dynamic-structure filter hot loop.

The filter decides, for every depth sample of every frame, whether the sample
is "map supported" (close to a mapped shelf face) and may therefore bypass the
10 s persistence gate that suppresses customers and carts.

Before round 2 the test was::

    polygons.contains { distanceToBoundary(point, $0) <= 0.5 }

which evaluates *every edge of every polygon* for *every point*. After round 2
each polygon carries a pre-computed bounding box and the exact test only runs
for the few polygons whose expanded box contains the point.

This script measures both formulations against real prior-map geometry so the
speedup is a measured number, not an argument.

Usage::

    python3 tools/PriorMap/dynamic_filter_benchmark.py \
        --package /path/to/mapcase03_sam --points 600 --frames 30
"""

from __future__ import annotations

import argparse
import json
import math
import os
import random
import statistics
import time


def load_polygons(package: str) -> list[list[tuple[float, float]]]:
    """Shelf + fixed-structure polygons, mirroring what iOS loads."""
    manifest_path = os.path.join(package, "manifest.json")
    floors: set[str] = set()
    if os.path.exists(manifest_path):
        with open(manifest_path, "r", encoding="utf-8") as handle:
            manifest = json.load(handle)
        for floor in manifest.get("floors") or []:
            floor_id = floor.get("id")
            if floor_id is not None:
                floors.add(str(floor_id))
    polygons: list[list[tuple[float, float]]] = []
    for name in ("shelves.json", "fixed_structures.json", "elements.json"):
        path = os.path.join(package, name)
        if not os.path.exists(path):
            continue
        with open(path, "r", encoding="utf-8") as handle:
            payload = json.load(handle)
        elements = payload.get("elements") if isinstance(payload, dict) else payload
        if not isinstance(elements, list):
            continue
        for element in elements:
            if not isinstance(element, dict):
                continue
            if floors and str(element.get("floor_id")) not in floors:
                continue
            geometry = element.get("geometry")
            if not isinstance(geometry, dict):
                continue
            coords = geometry.get("coordinates")
            if not isinstance(coords, list) or len(coords) < 2:
                continue
            ring = coords[0] if isinstance(coords[0], list) and isinstance(
                coords[0][0], list
            ) else coords
            points: list[tuple[float, float]] = []
            for pair in ring:
                if isinstance(pair, (list, tuple)) and len(pair) >= 2:
                    points.append((float(pair[0]), float(pair[1])))
            if len(points) >= 2:
                polygons.append(points)
    return polygons


def distance_to_boundary(
    x: float, y: float, polygon: list[tuple[float, float]]
) -> float:
    if len(polygon) < 2:
        return math.inf
    best = math.inf
    count = len(polygon)
    for index in range(count):
        sx, sy = polygon[index]
        ex, ey = polygon[(index + 1) % count]
        dx = ex - sx
        dy = ey - sy
        denominator = dx * dx + dy * dy
        if denominator > 0:
            ratio = ((x - sx) * dx + (y - sy) * dy) / denominator
            ratio = max(0.0, min(1.0, ratio))
        else:
            ratio = 0.0
        px = sx + ratio * dx
        py = sy + ratio * dy
        best = min(best, math.hypot(x - px, y - py))
    return best


def bbox(polygon: list[tuple[float, float]]) -> tuple[float, float, float, float]:
    xs = [p[0] for p in polygon]
    ys = [p[1] for p in polygon]
    return (min(xs), min(ys), max(xs), max(ys))


def naive_scan(
    points: list[tuple[float, float]],
    polygons: list[list[tuple[float, float]]],
    tolerance: float,
) -> int:
    supported = 0
    for x, y in points:
        hit = False
        for polygon in polygons:
            if distance_to_boundary(x, y, polygon) <= tolerance:
                hit = True
                break
        if hit:
            supported += 1
    return supported


def bbox_scan(
    points: list[tuple[float, float]],
    polygons: list[list[tuple[float, float]]],
    boxes: list[tuple[float, float, float, float]],
    tolerance: float,
) -> int:
    supported = 0
    for x, y in points:
        hit = False
        for index, polygon in enumerate(polygons):
            min_x, min_y, max_x, max_y = boxes[index]
            # Stage 1: O(1) expanded-box reject.
            if (
                x < min_x - tolerance
                or x > max_x + tolerance
                or y < min_y - tolerance
                or y > max_y + tolerance
            ):
                continue
            # Stage 2: exact geometry, only for nearby shelves.
            if distance_to_boundary(x, y, polygon) <= tolerance:
                hit = True
                break
        if hit:
            supported += 1
    return supported


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--package", required=True, help="PriorMap package dir.")
    parser.add_argument("--points", type=int, default=600, help="Depth samples per frame.")
    parser.add_argument("--frames", type=int, default=30, help="Frames to simulate.")
    parser.add_argument("--seed", type=int, default=20260830)
    args = parser.parse_args()

    polygons = load_polygons(args.package)
    if not polygons:
        print("no polygons loaded", file=sys.stderr)
        return 2
    boxes = [bbox(polygon) for polygon in polygons]

    xs = [b[0] for b in boxes] + [b[2] for b in boxes]
    ys = [b[1] for b in boxes] + [b[3] for b in boxes]
    min_x, max_x = min(xs), max(xs)
    min_y, max_y = min(ys), max(ys)

    rng = random.Random(args.seed)
    frames: list[list[tuple[float, float]]] = []
    for _ in range(args.frames):
        # Operator walks a small region, so samples cluster near shelves --
        # the realistic (and worst) case for the naive scan.
        cx = rng.uniform(min_x, max_x)
        cy = rng.uniform(min_y, max_y)
        frames.append(
            [
                (
                    cx + rng.gauss(0.0, 6.0),
                    cy + rng.gauss(0.0, 6.0),
                )
                for _ in range(args.points)
            ]
        )

    def timeit(fn) -> tuple[float, int]:
        started = time.perf_counter()
        total = 0
        for frame in frames:
            total += fn(frame)
        return time.perf_counter() - started, total

    naive_s, naive_hits = timeit(
        lambda f: naive_scan(f, polygons, 0.5)
    )
    bbox_s, bbox_hits = timeit(
        lambda f: bbox_scan(f, polygons, boxes, 0.5)
    )

    edges = sum(len(p) for p in polygons)
    print(f"地图包: {args.package}")
    print(f"多边形 {len(polygons)}，总边数 {edges}，点/帧 {args.points}，帧数 {args.frames}")
    print()
    print(f"{'方案':<28}{'总耗时 s':>12}{'每帧 ms':>12}{'命中点':>10}")
    print(
        f"{'naive (round-1)':<28}{naive_s:>12.3f}"
        f"{naive_s / args.frames * 1000:>12.2f}{naive_hits:>10}"
    )
    print(
        f"{'bbox prefilter (round-2)':<28}{bbox_s:>12.3f}"
        f"{bbox_s / args.frames * 1000:>12.2f}{bbox_hits:>10}"
    )
    print()
    assert naive_hits == bbox_hits, "optimisation changed the result!"
    speedup = naive_s / bbox_s if bbox_s > 0 else float("inf")
    saved = naive_s - bbox_s
    print(f"结果一致性: OK (命中点 {naive_hits} == {bbox_hits})")
    print(f"加速比: {speedup:.1f}x")
    print(
        f"每帧节省 {saved / args.frames * 1000:.2f} ms；"
        f"按 30 fps 计每秒节省 {saved / args.frames * 30:.3f} s CPU"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
