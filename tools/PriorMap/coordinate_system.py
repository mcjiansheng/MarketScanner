"""The single authoritative source-to-map coordinate conversion.

The source workbook uses centimetres, a top-left origin, +x to the right,
+y down, and clockwise-positive rotation.  Internal map coordinates use
metres, +x to the right, +y up, and counter-clockwise-positive yaw.
"""

from __future__ import annotations

import math
from dataclasses import dataclass
from typing import Iterable, Sequence


CM_PER_M = 100.0


@dataclass(frozen=True)
class Bounds:
    min_x_m: float
    min_y_m: float
    max_x_m: float
    max_y_m: float

    @property
    def width_m(self) -> float:
        return self.max_x_m - self.min_x_m

    @property
    def height_m(self) -> float:
        return self.max_y_m - self.min_y_m

    def as_dict(self) -> dict[str, float]:
        return {
            "min_x_m": rounded(self.min_x_m),
            "min_y_m": rounded(self.min_y_m),
            "max_x_m": rounded(self.max_x_m),
            "max_y_m": rounded(self.max_y_m),
            "width_m": rounded(self.width_m),
            "height_m": rounded(self.height_m),
        }


def rounded(value: float, digits: int = 6) -> float:
    value = round(float(value), digits)
    return 0.0 if value == -0.0 else value


def cm_to_m(value: float) -> float:
    return float(value) / CM_PER_M


def source_point_to_map(x_cm: float, y_cm: float) -> tuple[float, float]:
    return rounded(cm_to_m(x_cm)), rounded(-cm_to_m(y_cm))


def source_rotation_to_yaw(rotation_deg: float) -> float:
    return rounded(math.radians(-float(rotation_deg)), 9)


def source_rectangle_polygon(
    x_cm: float,
    y_cm: float,
    width_cm: float,
    height_cm: float,
    rotation_deg: float = 0.0,
) -> list[list[float]]:
    """Return a CCW map-space polygon for a source rectangle.

    ``x`` and ``y`` denote the unrotated source rectangle's top-left corner.
    Rotation is applied around its centre, matching the supplied map editor.
    """

    x = float(x_cm)
    y = float(y_cm)
    width = float(width_cm)
    height = float(height_cm)
    cx = x + width / 2.0
    cy = y + height / 2.0
    radians = math.radians(float(rotation_deg))
    cosine = math.cos(radians)
    sine = math.sin(radians)
    source_corners = (
        (x, y),
        (x + width, y),
        (x + width, y + height),
        (x, y + height),
    )
    polygon: list[list[float]] = []
    for px, py in source_corners:
        dx = px - cx
        dy = py - cy
        rotated_x = cx + dx * cosine - dy * sine
        rotated_y = cy + dx * sine + dy * cosine
        map_x, map_y = source_point_to_map(rotated_x, rotated_y)
        polygon.append([map_x, map_y])
    # Flipping source y reverses winding. Restore CCW order.
    polygon.reverse()
    return polygon


def polygon_bounds(points: Sequence[Sequence[float]]) -> Bounds:
    if not points:
        raise ValueError("Cannot calculate bounds for an empty polygon.")
    xs = [float(point[0]) for point in points]
    ys = [float(point[1]) for point in points]
    return Bounds(min(xs), min(ys), max(xs), max(ys))


def merge_bounds(bounds: Iterable[Bounds]) -> Bounds:
    items = list(bounds)
    if not items:
        return Bounds(0.0, 0.0, 0.0, 0.0)
    return Bounds(
        min(item.min_x_m for item in items),
        min(item.min_y_m for item in items),
        max(item.max_x_m for item in items),
        max(item.max_y_m for item in items),
    )


def transform_se2(
    x_m: float,
    y_m: float,
    yaw_rad: float,
    local_x_m: float,
    local_y_m: float,
    local_yaw_rad: float = 0.0,
) -> tuple[float, float, float]:
    cosine = math.cos(yaw_rad)
    sine = math.sin(yaw_rad)
    x = x_m + cosine * local_x_m - sine * local_y_m
    y = y_m + sine * local_x_m + cosine * local_y_m
    yaw = normalize_angle(yaw_rad + local_yaw_rad)
    return rounded(x), rounded(y), rounded(yaw)


def normalize_angle(value: float) -> float:
    return math.atan2(math.sin(value), math.cos(value))
