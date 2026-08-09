#!/usr/bin/env python3
"""Render a dependency-free PNG preview from a prior-map package."""

from __future__ import annotations

import argparse
import json
import math
import struct
import sys
import zlib
from pathlib import Path
from typing import Iterable, Sequence

if __package__ in {None, ""}:
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
    from PriorMap.element_roles import (
        ROLE_FIXED_STRUCTURE,
        ROLE_SHELF,
        role_for,
    )
    from PriorMap.prior_map_schema import load_json
else:
    from .element_roles import ROLE_FIXED_STRUCTURE, ROLE_SHELF, role_for
    from .prior_map_schema import load_json


Color = tuple[int, int, int]
WHITE: Color = (250, 250, 248)
ROAD: Color = (213, 235, 250)
ROAD_CENTER: Color = (136, 191, 225)
SHELF_FILL: Color = (255, 255, 255)
SHELF_EDGE: Color = (73, 102, 234)
TABLE_FILL: Color = (255, 177, 91)
TABLE_EDGE: Color = (166, 118, 71)
PILLAR: Color = (20, 24, 28)
HIDDEN: Color = (190, 190, 190)
UNKNOWN: Color = (218, 87, 87)


class Raster:
    def __init__(self, width: int, height: int, background: Color = WHITE) -> None:
        self.width = width
        self.height = height
        self.pixels = bytearray(background * (width * height))

    def set_pixel(self, x: int, y: int, color: Color) -> None:
        if 0 <= x < self.width and 0 <= y < self.height:
            offset = (y * self.width + x) * 3
            self.pixels[offset : offset + 3] = bytes(color)

    def disk(self, x: float, y: float, radius: float, color: Color) -> None:
        radius = max(0.5, radius)
        minimum_x = max(0, int(math.floor(x - radius)))
        maximum_x = min(self.width - 1, int(math.ceil(x + radius)))
        minimum_y = max(0, int(math.floor(y - radius)))
        maximum_y = min(self.height - 1, int(math.ceil(y + radius)))
        radius_squared = radius * radius
        for py in range(minimum_y, maximum_y + 1):
            for px in range(minimum_x, maximum_x + 1):
                if (px - x) ** 2 + (py - y) ** 2 <= radius_squared:
                    self.set_pixel(px, py, color)

    def line(
        self,
        start: Sequence[float],
        end: Sequence[float],
        color: Color,
        width: float = 1.0,
    ) -> None:
        x0, y0 = float(start[0]), float(start[1])
        x1, y1 = float(end[0]), float(end[1])
        distance = max(abs(x1 - x0), abs(y1 - y0))
        steps = max(1, int(math.ceil(distance)))
        radius = max(0.5, width / 2.0)
        for index in range(steps + 1):
            ratio = index / steps
            self.disk(x0 + (x1 - x0) * ratio, y0 + (y1 - y0) * ratio, radius, color)

    def polygon(self, points: Sequence[Sequence[float]], fill: Color, edge: Color) -> None:
        if len(points) < 3:
            return
        minimum_y = max(0, int(math.floor(min(point[1] for point in points))))
        maximum_y = min(self.height - 1, int(math.ceil(max(point[1] for point in points))))
        for y in range(minimum_y, maximum_y + 1):
            scan_y = y + 0.5
            intersections: list[float] = []
            for index, point in enumerate(points):
                following = points[(index + 1) % len(points)]
                y0 = float(point[1])
                y1 = float(following[1])
                if (y0 <= scan_y < y1) or (y1 <= scan_y < y0):
                    ratio = (scan_y - y0) / (y1 - y0)
                    intersections.append(float(point[0]) + ratio * (float(following[0]) - float(point[0])))
            intersections.sort()
            for left, right in zip(intersections[0::2], intersections[1::2]):
                for x in range(max(0, int(math.ceil(left))), min(self.width - 1, int(math.floor(right))) + 1):
                    self.set_pixel(x, y, fill)
        for index, point in enumerate(points):
            self.line(point, points[(index + 1) % len(points)], edge, 2.0)

    def save_png(self, path: Path) -> None:
        raw = bytearray()
        row_bytes = self.width * 3
        for y in range(self.height):
            raw.append(0)
            offset = y * row_bytes
            raw.extend(self.pixels[offset : offset + row_bytes])

        def chunk(kind: bytes, payload: bytes) -> bytes:
            return (
                struct.pack(">I", len(payload))
                + kind
                + payload
                + struct.pack(">I", zlib.crc32(kind + payload) & 0xFFFFFFFF)
            )

        png = (
            b"\x89PNG\r\n\x1a\n"
            + chunk("IHDR".encode(), struct.pack(">IIBBBBB", self.width, self.height, 8, 2, 0, 0, 0))
            + chunk("IDAT".encode(), zlib.compress(bytes(raw), level=9))
            + chunk("IEND".encode(), b"")
        )
        path.write_bytes(png)


def _projection(
    bounds: dict[str, float],
    maximum_width: int,
    maximum_height: int,
    margin: int = 32,
) -> tuple[int, int, float]:
    width_m = max(0.01, float(bounds["max_x_m"]) - float(bounds["min_x_m"]))
    height_m = max(0.01, float(bounds["max_y_m"]) - float(bounds["min_y_m"]))
    scale = min(
        (maximum_width - margin * 2) / width_m,
        (maximum_height - margin * 2) / height_m,
        20.0,
    )
    width = max(160, int(math.ceil(width_m * scale)) + margin * 2)
    height = max(120, int(math.ceil(height_m * scale)) + margin * 2)
    return width, height, scale


def render_package(
    package_directory: Path | str,
    output: Path | str | None = None,
    floor_id: str | None = None,
    maximum_width: int = 1600,
    maximum_height: int = 1200,
) -> Path:
    root = Path(package_directory)
    manifest = load_json(root / "manifest.json")
    elements = load_json(root / "elements.json")["elements"]
    graph = load_json(root / "road_graph.json")
    floor = str(floor_id or manifest["floors"][0]["id"])
    floor_record = next((item for item in manifest["floors"] if str(item["id"]) == floor), None)
    if floor_record is None:
        raise ValueError(f"Floor is not present in the package: {floor}")
    bounds = floor_record["bounds"]
    width, height, scale = _projection(bounds, maximum_width, maximum_height)
    margin = 32

    def point(value: Sequence[float]) -> tuple[float, float]:
        x = margin + (float(value[0]) - float(bounds["min_x_m"])) * scale
        y = margin + (float(bounds["max_y_m"]) - float(value[1])) * scale
        return x, y

    raster = Raster(width, height)
    cross_by_id = {
        str(item["id"]): item
        for item in graph.get("crosses", [])
        if str(item.get("floor_id")) == floor
    }
    for cross in cross_by_id.values():
        points = cross.get("points_m", [])
        if len(points) == 2:
            raster.line(
                point(points[0]),
                point(points[1]),
                ROAD,
                max(2.0, float(cross.get("width_m", 0.5)) * scale),
            )
            raster.line(point(points[0]), point(points[1]), ROAD_CENTER, 1.0)

    draw_order = {
        "MapTableFeature": 0,
        "MapTable": 1,
        "MapShelf": 2,
        "MapPillar": 3,
    }
    structures = sorted(
        (
            item
            for item in elements
            if str(item.get("floor_id")) == floor
            and item.get("visible") is True
            and role_for(str(item.get("shape_type")))
            in {ROLE_SHELF, ROLE_FIXED_STRUCTURE}
            and isinstance(item.get("geometry"), dict)
            and item["geometry"].get("type") == "polygon"
            and isinstance(item["geometry"].get("coordinates"), list)
        ),
        key=lambda item: draw_order.get(str(item.get("shape_type")), 9),
    )
    for element in structures:
        polygon = [point(value) for value in element["geometry"]["coordinates"]]
        if element["shape_type"] == "MapPillar":
            fill = edge = PILLAR
        elif element["shape_type"] in {"MapTable", "MapTableFeature"}:
            fill, edge = TABLE_FILL, TABLE_EDGE
        elif element["shape_type"] == "MapShelf":
            fill, edge = SHELF_FILL, SHELF_EDGE
        else:
            fill, edge = WHITE, UNKNOWN
        raster.polygon(polygon, fill, edge)

    for node in graph.get("nodes", []):
        if str(node.get("floor_id")) == floor:
            raster.disk(*point(node["position_m"]), max(1.5, scale * 0.06), (255, 255, 255))

    destination = Path(output) if output is not None else root / "preview.png"
    raster.save_png(destination)
    return destination


def main(argv: Iterable[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Render a prior-map package preview.")
    parser.add_argument("package", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--floor")
    args = parser.parse_args(argv)
    path = render_package(args.package, args.output, args.floor)
    print(path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
