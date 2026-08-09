"""Deterministic multi-resolution distance fields for mobile scan matching."""

from __future__ import annotations

import hashlib
import heapq
import json
import math
from collections import defaultdict
from typing import Any, Iterable

from .element_roles import STRUCTURE_TYPES


DISTANCE_FIELD_FORMAT = "MarketScannerDistanceFields"
DISTANCE_FIELD_VERSION = 1
DEFAULT_RESOLUTIONS_M = (0.40, 0.20, 0.10)
DEFAULT_TRUNCATION_M = 2.0
MAXIMUM_DIMENSION_CELLS = 20_000
MAXIMUM_CELLS_PER_LEVEL = 8_000_000
MAXIMUM_TOTAL_CELLS = 16_000_000
MAXIMUM_SEED_SAMPLES_PER_SEGMENT = 100_000


def _segments(
    elements: Iterable[dict[str, Any]],
) -> dict[str, list[tuple[tuple[float, float], tuple[float, float]]]]:
    result: dict[
        str, list[tuple[tuple[float, float], tuple[float, float]]]
    ] = defaultdict(list)
    for element in elements:
        if (
            element.get("shape_type") not in STRUCTURE_TYPES
            or element.get("visible") is not True
        ):
            continue
        geometry = element.get("geometry")
        if not isinstance(geometry, dict):
            continue
        coordinates = geometry.get("coordinates")
        if not isinstance(coordinates, list) or len(coordinates) < 2:
            continue
        points = [
            (float(point[0]), float(point[1]))
            for point in coordinates
            if isinstance(point, list)
            and len(point) >= 2
            and isinstance(point[0], (int, float))
            and isinstance(point[1], (int, float))
        ]
        if len(points) < 2:
            continue
        if points[0] != points[-1]:
            points.append(points[0])
        floor_id = str(element.get("floor_id"))
        result[floor_id].extend(zip(points, points[1:]))
    return result


def _seed_cells(
    segments: list[tuple[tuple[float, float], tuple[float, float]]],
    origin_x: float,
    origin_y: float,
    resolution: float,
    width: int,
    height: int,
) -> set[tuple[int, int]]:
    seeds: set[tuple[int, int]] = set()
    for start, end in segments:
        length = math.hypot(end[0] - start[0], end[1] - start[1])
        raw_steps = math.ceil(length / max(resolution * 0.45, 0.01))
        if (
            not math.isfinite(length)
            or raw_steps > MAXIMUM_SEED_SAMPLES_PER_SEGMENT
        ):
            raise ValueError("Distance-field segment seed budget exceeded.")
        steps = max(1, int(raw_steps))
        for index in range(steps + 1):
            ratio = index / steps
            x = start[0] + (end[0] - start[0]) * ratio
            y = start[1] + (end[1] - start[1]) * ratio
            cell_x = int(math.floor((x - origin_x) / resolution))
            cell_y = int(math.floor((y - origin_y) / resolution))
            if 0 <= cell_x < width and 0 <= cell_y < height:
                seeds.add((cell_x, cell_y))
    return seeds


def _row_rle(
    width: int,
    height: int,
    distances: dict[tuple[int, int], float],
    truncation_cm: int,
) -> list[list[int]]:
    rows: list[list[int]] = []
    for y in range(height):
        encoded: list[int] = []
        previous: int | None = None
        count = 0
        for x in range(width):
            value = min(
                truncation_cm,
                int(round(distances.get((x, y), truncation_cm / 100.0) * 100.0)),
            )
            if previous is None or value == previous:
                count += 1
            else:
                encoded.extend((count, previous))
                count = 1
            previous = value
        if previous is not None:
            encoded.extend((count, previous))
        rows.append(encoded)
    return rows


def _validated_grid(
    bounds: dict[str, Any],
    resolution: float,
    truncation_m: float,
) -> tuple[float, float, int, int]:
    values = [bounds.get(key) for key in ("min_x_m", "min_y_m", "max_x_m", "max_y_m")]
    if any(
        isinstance(value, bool)
        or not isinstance(value, (int, float))
        or not math.isfinite(float(value))
        for value in values
    ):
        raise ValueError("Distance-field bounds are invalid.")
    min_x, min_y, max_x, max_y = (float(value) for value in values)
    if min_x > max_x or min_y > max_y:
        raise ValueError("Distance-field bounds are invalid.")
    origin_x = math.floor((min_x - truncation_m) / resolution) * resolution
    origin_y = math.floor((min_y - truncation_m) / resolution) * resolution
    maximum_x = math.ceil((max_x + truncation_m) / resolution) * resolution
    maximum_y = math.ceil((max_y + truncation_m) / resolution) * resolution
    raw_width = round((maximum_x - origin_x) / resolution) + 1
    raw_height = round((maximum_y - origin_y) / resolution) + 1
    if (
        not all(
            math.isfinite(value)
            for value in (origin_x, origin_y, maximum_x, maximum_y)
        )
        or raw_width < 1
        or raw_height < 1
        or raw_width > MAXIMUM_DIMENSION_CELLS
        or raw_height > MAXIMUM_DIMENSION_CELLS
        or raw_width * raw_height > MAXIMUM_CELLS_PER_LEVEL
    ):
        raise ValueError("Distance-field grid exceeds the resource budget.")
    return origin_x, origin_y, int(raw_width), int(raw_height)


def _level(
    segments: list[tuple[tuple[float, float], tuple[float, float]]],
    resolution: float,
    truncation_m: float,
    grid: tuple[float, float, int, int],
) -> dict[str, Any]:
    origin_x, origin_y, width, height = grid
    seeds = _seed_cells(
        segments,
        origin_x,
        origin_y,
        resolution,
        width,
        height,
    )
    distances: dict[tuple[int, int], float] = {seed: 0.0 for seed in seeds}
    queue = [(0.0, seed[0], seed[1]) for seed in seeds]
    heapq.heapify(queue)
    neighbours = (
        (-1, 0, 1.0),
        (1, 0, 1.0),
        (0, -1, 1.0),
        (0, 1, 1.0),
        (-1, -1, math.sqrt(2.0)),
        (-1, 1, math.sqrt(2.0)),
        (1, -1, math.sqrt(2.0)),
        (1, 1, math.sqrt(2.0)),
    )
    while queue:
        distance, x, y = heapq.heappop(queue)
        if distance > distances.get((x, y), truncation_m) + 1.0e-12:
            continue
        for dx, dy, scale in neighbours:
            following_x = x + dx
            following_y = y + dy
            following_distance = distance + resolution * scale
            if (
                following_distance > truncation_m
                or following_x < 0
                or following_y < 0
                or following_x >= width
                or following_y >= height
                or following_distance
                >= distances.get((following_x, following_y), truncation_m)
            ):
                continue
            distances[(following_x, following_y)] = following_distance
            heapq.heappush(
                queue,
                (following_distance, following_x, following_y),
            )
    rows = _row_rle(width, height, distances, int(round(truncation_m * 100.0)))
    canonical = json.dumps(rows, separators=(",", ":"), ensure_ascii=True).encode()
    return {
        "resolution_m": resolution,
        "origin_m": [round(origin_x, 6), round(origin_y, 6)],
        "width": width,
        "height": height,
        "encoding": "row_rle_u8_cm",
        "data_sha256": hashlib.sha256(canonical).hexdigest(),
        "rows": rows,
    }


def build_distance_fields(
    elements: list[dict[str, Any]],
    floors: list[dict[str, Any]],
    resolutions_m: tuple[float, ...] = DEFAULT_RESOLUTIONS_M,
    truncation_m: float = DEFAULT_TRUNCATION_M,
) -> dict[str, Any]:
    if (
        not resolutions_m
        or any(not math.isfinite(value) or value <= 0 for value in resolutions_m)
        or not math.isfinite(truncation_m)
        or truncation_m <= 0
        or truncation_m > 2.55
    ):
        raise ValueError("Distance-field resolutions/truncation are invalid.")
    grids_by_floor: dict[str, list[tuple[float, float, int, int]]] = {}
    total_cells = 0
    for floor in floors:
        floor_id = str(floor.get("id", ""))
        if not floor_id or floor_id in grids_by_floor or not isinstance(floor.get("bounds"), dict):
            raise ValueError("Distance-field floor identity/bounds are invalid or duplicated.")
        floor_grids = [
            _validated_grid(floor["bounds"], resolution, truncation_m)
            for resolution in resolutions_m
        ]
        total_cells += sum(width * height for _x, _y, width, height in floor_grids)
        if total_cells > MAXIMUM_TOTAL_CELLS:
            raise ValueError("Distance-field total grid cell budget exceeded.")
        grids_by_floor[floor_id] = floor_grids
    by_floor = _segments(elements)
    payload_floors: dict[str, Any] = {}
    for floor in floors:
        floor_id = str(floor["id"])
        payload_floors[floor_id] = {
            "levels": [
                _level(
                    by_floor.get(floor_id, []),
                    resolution,
                    truncation_m,
                    grid,
                )
                for resolution, grid in zip(
                    resolutions_m, grids_by_floor[floor_id]
                )
            ]
        }
    return {
        "format": DISTANCE_FIELD_FORMAT,
        "version": DISTANCE_FIELD_VERSION,
        "unit": "metre",
        "distance_encoding": "unsigned_centimetres",
        "truncation_distance_m": truncation_m,
        "floors": payload_floors,
    }


def decode_level(level: dict[str, Any]) -> list[int]:
    width = level.get("width")
    height = level.get("height")
    if (
        type(width) is not int
        or type(height) is not int
        or width <= 0
        or height <= 0
        or width > MAXIMUM_DIMENSION_CELLS
        or height > MAXIMUM_DIMENSION_CELLS
        or width * height > MAXIMUM_CELLS_PER_LEVEL
    ):
        raise ValueError("Distance-field dimensions are invalid or exceed the budget.")
    values: list[int] = []
    rows = level["rows"]
    if not isinstance(rows, list) or len(rows) != height:
        raise ValueError("Distance-field row count is invalid.")
    for row in rows:
        if not isinstance(row, list) or len(row) % 2:
            raise ValueError("Distance-field RLE row is invalid.")
        decoded: list[int] = []
        decoded_count = 0
        for index in range(0, len(row), 2):
            count, value = row[index], row[index + 1]
            if (
                type(count) is not int
                or count <= 0
                or type(value) is not int
                or not 0 <= value <= 255
                or count > width - decoded_count
            ):
                raise ValueError("Distance-field RLE value is invalid.")
            decoded.extend([value] * count)
            decoded_count += count
        if len(decoded) != width:
            raise ValueError("Distance-field RLE width is invalid.")
        values.extend(decoded)
    canonical = json.dumps(rows, separators=(",", ":"), ensure_ascii=True).encode()
    data_sha256 = level.get("data_sha256")
    if (
        not isinstance(data_sha256, str)
        or len(data_sha256) != 64
        or any(character not in "0123456789abcdef" for character in data_sha256)
        or hashlib.sha256(canonical).hexdigest() != data_sha256
    ):
        raise ValueError("Distance-field checksum does not match.")
    return values
