"""Bounded prior-map corridor route matching.

The matcher treats the road graph and occupied supermarket structures as
geometry contracts, not as soft suggestions.  It chooses one connected route
through the road graph with a bounded Viterbi pass, rejects transitions whose
straight rendered segment intersects an occupied polygon, and reports route
ambiguity instead of turning a periodic aisle choice into false precision.

This module intentionally depends only on the Python standard library.  It is
used after relative-motion reconstruction: map-gauge corrections may change
the route hypothesis, but they are never interpreted as physical travel.
"""

from __future__ import annotations

import bisect
from dataclasses import dataclass
import heapq
import math
from typing import Any, Mapping, Sequence


@dataclass(frozen=True)
class RoutePoint:
    x: float
    y: float
    yaw: float


@dataclass(frozen=True)
class RouteAnchor:
    index: int
    x: float
    y: float
    translation_sigma_m: float
    identifier: str


@dataclass(frozen=True)
class RouteMatchResult:
    poses: tuple[RoutePoint, ...]
    audit: dict[str, Any]


@dataclass(frozen=True)
class _RoadEdge:
    identifier: str
    corridor_id: str
    first_node: int
    second_node: int
    first: tuple[float, float]
    second: tuple[float, float]
    length: float
    width: float


@dataclass(frozen=True)
class _Candidate:
    edge_index: int
    x: float
    y: float
    fraction: float
    hint_distance: float
    heading: float


@dataclass(frozen=True)
class _EnvelopeProjection:
    x: float
    y: float
    correction_x: float
    correction_y: float
    signed_lateral_offset_m: float
    minimum_lateral_offset_m: float
    maximum_lateral_offset_m: float
    outside_distance_m: float
    clamped: bool


def _normalize_angle(value: float) -> float:
    while value > math.pi:
        value -= 2.0 * math.pi
    while value <= -math.pi:
        value += 2.0 * math.pi
    return value


def _finite_margin(value: float) -> float | None:
    return round(value, 6) if math.isfinite(value) else None


def _positive_finite_float(value: Any) -> float | None:
    try:
        parsed = float(value)
    except (TypeError, ValueError):
        return None
    return parsed if math.isfinite(parsed) and parsed > 0.0 else None


def _axis_residual(first: float, second: float) -> float:
    direct = abs(_normalize_angle(first - second))
    reverse = abs(_normalize_angle(first + math.pi - second))
    return min(direct, reverse)


def _project_to_segment(
    x: float,
    y: float,
    first: tuple[float, float],
    second: tuple[float, float],
) -> tuple[float, float, float, float, float] | None:
    dx = second[0] - first[0]
    dy = second[1] - first[1]
    length_squared = dx * dx + dy * dy
    if length_squared <= 1.0e-12:
        return None
    fraction = max(
        0.0,
        min(1.0, ((x - first[0]) * dx + (y - first[1]) * dy) / length_squared),
    )
    projected_x = first[0] + fraction * dx
    projected_y = first[1] + fraction * dy
    return (
        projected_x,
        projected_y,
        math.hypot(x - projected_x, y - projected_y),
        fraction,
        math.atan2(dy, dx),
    )


def _point_segment_distance(
    point: tuple[float, float],
    first: tuple[float, float],
    second: tuple[float, float],
) -> float:
    projected = _project_to_segment(point[0], point[1], first, second)
    return math.inf if projected is None else projected[2]


def _orientation(
    first: tuple[float, float],
    second: tuple[float, float],
    third: tuple[float, float],
) -> float:
    return (
        (second[0] - first[0]) * (third[1] - first[1])
        - (second[1] - first[1]) * (third[0] - first[0])
    )


def _on_segment(
    point: tuple[float, float],
    first: tuple[float, float],
    second: tuple[float, float],
) -> bool:
    return (
        min(first[0], second[0]) - 1.0e-9
        <= point[0]
        <= max(first[0], second[0]) + 1.0e-9
        and min(first[1], second[1]) - 1.0e-9
        <= point[1]
        <= max(first[1], second[1]) + 1.0e-9
        and abs(_orientation(first, second, point)) <= 1.0e-9
    )


def _segments_intersect(
    first_a: tuple[float, float],
    second_a: tuple[float, float],
    first_b: tuple[float, float],
    second_b: tuple[float, float],
) -> bool:
    first_orientation = _orientation(first_a, second_a, first_b)
    second_orientation = _orientation(first_a, second_a, second_b)
    third_orientation = _orientation(first_b, second_b, first_a)
    fourth_orientation = _orientation(first_b, second_b, second_a)
    if (
        (first_orientation > 0.0) != (second_orientation > 0.0)
        and (third_orientation > 0.0) != (fourth_orientation > 0.0)
    ):
        return True
    return any(
        (
            abs(orientation) <= 1.0e-9
            and _on_segment(point, segment_first, segment_second)
        )
        for orientation, point, segment_first, segment_second in (
            (first_orientation, first_b, first_a, second_a),
            (second_orientation, second_b, first_a, second_a),
            (third_orientation, first_a, first_b, second_b),
            (fourth_orientation, second_a, first_b, second_b),
        )
    )


def _segment_distance(
    first_a: tuple[float, float],
    second_a: tuple[float, float],
    first_b: tuple[float, float],
    second_b: tuple[float, float],
) -> float:
    if _segments_intersect(first_a, second_a, first_b, second_b):
        return 0.0
    return min(
        _point_segment_distance(first_a, first_b, second_b),
        _point_segment_distance(second_a, first_b, second_b),
        _point_segment_distance(first_b, first_a, second_a),
        _point_segment_distance(second_b, first_a, second_a),
    )


def _point_in_polygon(
    point: tuple[float, float], polygon: Sequence[tuple[float, float]]
) -> bool:
    inside = False
    previous = polygon[-1]
    for current in polygon:
        if _point_segment_distance(point, previous, current) <= 1.0e-9:
            return True
        if (current[1] > point[1]) != (previous[1] > point[1]):
            crossing_x = (
                (previous[0] - current[0])
                * (point[1] - current[1])
                / (previous[1] - current[1])
                + current[0]
            )
            if point[0] < crossing_x:
                inside = not inside
        previous = current
    return inside


class ObstacleIndex:
    """Small uniform-grid index for shelf/fixed-structure polygons."""

    def __init__(
        self,
        polygons: Sequence[Sequence[tuple[float, float]]],
        clearance_m: float = 0.12,
        cell_size_m: float = 2.0,
    ) -> None:
        self.polygons = tuple(tuple(value) for value in polygons if len(value) >= 3)
        self.clearance_m = max(0.0, float(clearance_m))
        self.cell_size_m = max(0.5, float(cell_size_m))
        self.bounds: list[tuple[float, float, float, float]] = []
        self.grid: dict[tuple[int, int], list[int]] = {}
        for index, polygon in enumerate(self.polygons):
            xs = [point[0] for point in polygon]
            ys = [point[1] for point in polygon]
            bounds = (
                min(xs) - self.clearance_m,
                min(ys) - self.clearance_m,
                max(xs) + self.clearance_m,
                max(ys) + self.clearance_m,
            )
            self.bounds.append(bounds)
            for cell in self._cells(bounds):
                self.grid.setdefault(cell, []).append(index)

    def _cells(
        self, bounds: tuple[float, float, float, float]
    ) -> Sequence[tuple[int, int]]:
        minimum_x = math.floor(bounds[0] / self.cell_size_m)
        minimum_y = math.floor(bounds[1] / self.cell_size_m)
        maximum_x = math.floor(bounds[2] / self.cell_size_m)
        maximum_y = math.floor(bounds[3] / self.cell_size_m)
        return tuple(
            (x, y)
            for x in range(minimum_x, maximum_x + 1)
            for y in range(minimum_y, maximum_y + 1)
        )

    def _query(
        self, bounds: tuple[float, float, float, float]
    ) -> Sequence[int]:
        result: set[int] = set()
        for cell in self._cells(bounds):
            result.update(self.grid.get(cell, ()))
        return tuple(result)

    def point_blocked(self, point: tuple[float, float]) -> bool:
        bounds = (
            point[0] - self.clearance_m,
            point[1] - self.clearance_m,
            point[0] + self.clearance_m,
            point[1] + self.clearance_m,
        )
        for index in self._query(bounds):
            polygon = self.polygons[index]
            if _point_in_polygon(point, polygon):
                return True
            if any(
                _point_segment_distance(point, first, second)
                <= self.clearance_m
                for first, second in zip(polygon, (*polygon[1:], polygon[0]))
            ):
                return True
        return False

    def segment_blocked(
        self,
        first: tuple[float, float],
        second: tuple[float, float],
    ) -> bool:
        bounds = (
            min(first[0], second[0]) - self.clearance_m,
            min(first[1], second[1]) - self.clearance_m,
            max(first[0], second[0]) + self.clearance_m,
            max(first[1], second[1]) + self.clearance_m,
        )
        for index in self._query(bounds):
            polygon = self.polygons[index]
            if _point_in_polygon(first, polygon) or _point_in_polygon(second, polygon):
                return True
            if any(
                _segment_distance(first, second, edge_first, edge_second)
                <= self.clearance_m
                for edge_first, edge_second in zip(
                    polygon, (*polygon[1:], polygon[0])
                )
            ):
                return True
        return False

    def directional_clearance(
        self,
        origin: tuple[float, float],
        direction: tuple[float, float],
        maximum_distance_m: float,
        *,
        step_m: float = 0.20,
    ) -> float:
        """Return the largest collision-free distance along one unit ray.

        Road graph center lines identify corridor topology, but they are not
        phone trajectories.  This ray query derives the usable lateral aisle
        envelope from the authoritative shelf/fixed-structure polygons.  A
        missing or zero road width therefore does not collapse the corridor to
        an arbitrary 0.2 m center strip.
        """

        maximum_distance_m = max(0.0, float(maximum_distance_m))
        if maximum_distance_m <= 1.0e-9:
            return 0.0
        norm = math.hypot(direction[0], direction[1])
        if norm <= 1.0e-12 or self.point_blocked(origin):
            return 0.0
        unit = (direction[0] / norm, direction[1] / norm)
        previous = 0.0
        distance = min(maximum_distance_m, max(0.05, float(step_m)))
        while True:
            point = (
                origin[0] + unit[0] * distance,
                origin[1] + unit[1] * distance,
            )
            if self.point_blocked(point):
                low = previous
                high = distance
                for _ in range(12):
                    middle = (low + high) / 2.0
                    middle_point = (
                        origin[0] + unit[0] * middle,
                        origin[1] + unit[1] * middle,
                    )
                    if self.point_blocked(middle_point):
                        high = middle
                    else:
                        low = middle
                return low
            if distance >= maximum_distance_m - 1.0e-9:
                return maximum_distance_m
            previous = distance
            distance = min(maximum_distance_m, distance + max(0.05, float(step_m)))


def obstacle_polygons(
    shelves_payload: Any,
    structures_payload: Any,
    floor_id: str,
) -> tuple[tuple[tuple[float, float], ...], ...]:
    polygons: list[tuple[tuple[float, float], ...]] = []
    sources: list[Any] = []
    if isinstance(shelves_payload, Mapping):
        sources.extend(shelves_payload.get("shelves", ()))
    if isinstance(structures_payload, Mapping):
        sources.extend(structures_payload.get("structures", ()))
    for item in sources:
        if (
            not isinstance(item, Mapping)
            or str(item.get("floor_id")) != floor_id
            or item.get("visible") is False
        ):
            continue
        geometry = item.get("geometry")
        coordinates = geometry.get("coordinates") if isinstance(geometry, Mapping) else None
        if not isinstance(coordinates, list) or len(coordinates) < 3:
            continue
        try:
            polygon = tuple((float(value[0]), float(value[1])) for value in coordinates)
        except (IndexError, TypeError, ValueError):
            continue
        if all(math.isfinite(value) for point in polygon for value in point):
            polygons.append(polygon)
    return tuple(polygons)


class _RoadNetwork:
    def __init__(self, road_graph: Mapping[str, Any], floor_id: str) -> None:
        raw_nodes = [
            item
            for item in road_graph.get("nodes", ())
            if isinstance(item, Mapping) and str(item.get("floor_id")) == floor_id
        ]
        self.node_ids = tuple(str(item.get("id")) for item in raw_nodes)
        node_index = {identifier: index for index, identifier in enumerate(self.node_ids)}
        positions: list[tuple[float, float]] = []
        for item in raw_nodes:
            value = item.get("position_m")
            if not isinstance(value, list) or len(value) < 2:
                raise ValueError("road_graph_node_position_invalid")
            positions.append((float(value[0]), float(value[1])))
        self.positions = tuple(positions)
        widths: dict[str, float] = {}
        for item in road_graph.get("crosses", ()):
            if (
                not isinstance(item, Mapping)
                or str(item.get("floor_id")) != floor_id
            ):
                continue
            width = _positive_finite_float(item.get("width_m"))
            if width is not None:
                widths[str(item.get("id"))] = width
        edges: list[_RoadEdge] = []
        adjacency: list[list[tuple[int, float]]] = [[] for _ in self.node_ids]
        incident_edges: list[list[int]] = [[] for _ in self.node_ids]
        for item in road_graph.get("edges", ()):
            if not isinstance(item, Mapping) or str(item.get("floor_id")) != floor_id:
                continue
            first_id = str(item.get("from"))
            second_id = str(item.get("to"))
            if first_id not in node_index or second_id not in node_index:
                continue
            first_node = node_index[first_id]
            second_node = node_index[second_id]
            first = self.positions[first_node]
            second = self.positions[second_node]
            length = math.hypot(second[0] - first[0], second[1] - first[1])
            if length <= 1.0e-6:
                continue
            cross_ids = [str(value) for value in item.get("cross_ids", ())]
            corridor_id = cross_ids[0] if cross_ids else str(item.get("id"))
            width = max((widths[value] for value in cross_ids if value in widths), default=0.0)
            edge = _RoadEdge(
                identifier=str(item.get("id") or f"edge-{len(edges)}"),
                corridor_id=corridor_id,
                first_node=first_node,
                second_node=second_node,
                first=first,
                second=second,
                length=length,
                width=width,
            )
            edges.append(edge)
            incident_edges[first_node].append(len(edges) - 1)
            incident_edges[second_node].append(len(edges) - 1)
            adjacency[first_node].append((second_node, length))
            adjacency[second_node].append((first_node, length))
        if not self.node_ids or not edges:
            raise ValueError("road_graph_empty")
        self.edges = tuple(edges)
        self.adjacency = tuple(tuple(values) for values in adjacency)
        self.incident_edges = tuple(tuple(values) for values in incident_edges)
        self.shortest = tuple(self._distances(index, adjacency) for index in range(len(self.node_ids)))

    @staticmethod
    def _distances(
        source: int, adjacency: Sequence[Sequence[tuple[int, float]]]
    ) -> tuple[float, ...]:
        distances = [math.inf] * len(adjacency)
        distances[source] = 0.0
        queue = [(0.0, source)]
        while queue:
            distance, node = heapq.heappop(queue)
            if distance != distances[node]:
                continue
            for neighbor, length in adjacency[node]:
                candidate = distance + length
                if candidate < distances[neighbor]:
                    distances[neighbor] = candidate
                    heapq.heappush(queue, (candidate, neighbor))
        return tuple(distances)

    def candidates(
        self,
        point: tuple[float, float],
        obstacle_index: ObstacleIndex,
        maximum_candidates: int,
        search_radius_m: float,
    ) -> list[_Candidate]:
        values: list[_Candidate] = []
        for edge_index, edge in enumerate(self.edges):
            projected = _project_to_segment(point[0], point[1], edge.first, edge.second)
            if projected is None or projected[2] > search_radius_m:
                continue
            candidate = _Candidate(
                edge_index=edge_index,
                x=projected[0],
                y=projected[1],
                fraction=projected[3],
                hint_distance=projected[2],
                heading=projected[4],
            )
            if not obstacle_index.point_blocked((candidate.x, candidate.y)):
                values.append(candidate)
        values.sort(key=lambda value: (value.hint_distance, self.edges[value.edge_index].identifier))
        return values[:maximum_candidates]

    def distance(self, first: _Candidate, second: _Candidate) -> float:
        first_edge = self.edges[first.edge_index]
        second_edge = self.edges[second.edge_index]
        if first.edge_index == second.edge_index:
            return abs(first.fraction - second.fraction) * first_edge.length
        first_endpoints = (
            (first_edge.first_node, first.fraction * first_edge.length),
            (first_edge.second_node, (1.0 - first.fraction) * first_edge.length),
        )
        second_endpoints = (
            (second_edge.first_node, second.fraction * second_edge.length),
            (second_edge.second_node, (1.0 - second.fraction) * second_edge.length),
        )
        return min(
            first_offset + self.shortest[first_node][second_node] + second_offset
            for first_node, first_offset in first_endpoints
            for second_node, second_offset in second_endpoints
        )

def _motion_heading(poses: Sequence[Any], index: int) -> tuple[float | None, float]:
    for radius in range(1, 9):
        left = max(0, index - radius)
        right = min(len(poses) - 1, index + radius)
        dx = float(poses[right].x) - float(poses[left].x)
        dy = float(poses[right].y) - float(poses[left].y)
        distance = math.hypot(dx, dy)
        if distance >= 0.75:
            return math.atan2(dy, dx), distance
    return None, 0.0


def _ambiguity_intervals(
    margins: Sequence[float],
    candidates: Sequence[_Candidate],
    network: _RoadNetwork,
    threshold: float,
) -> list[dict[str, Any]]:
    intervals: list[dict[str, Any]] = []
    start: int | None = None
    for index in range(len(margins) + 1):
        ambiguous = index < len(margins) and margins[index] < threshold
        if ambiguous and start is None:
            start = index
        if not ambiguous and start is not None:
            end = index - 1
            intervals.append(
                {
                    "start_index": start,
                    "end_index": end,
                    "sample_count": end - start + 1,
                    "minimum_path_margin": _finite_margin(
                        min(margins[start : end + 1])
                    ),
                    "corridor_ids": sorted(
                        {
                            network.edges[candidates[item].edge_index].corridor_id
                            for item in range(start, end + 1)
                        }
                    ),
                }
            )
            start = None
    return intervals


def _polyline_cumulative(
    polyline: Sequence[tuple[float, float]],
) -> tuple[float, ...]:
    values = [0.0]
    for first, second in zip(polyline, polyline[1:]):
        values.append(values[-1] + math.hypot(
            second[0] - first[0], second[1] - first[1]
        ))
    return tuple(values)


def _physical_cumulative(poses: Sequence[Any]) -> tuple[float, ...]:
    values = [0.0]
    for first, second in zip(poses, poses[1:]):
        values.append(values[-1] + math.hypot(
            float(second.x) - float(first.x),
            float(second.y) - float(first.y),
        ))
    return tuple(values)


def _corridor_lateral_limits(
    candidate: _Candidate,
    network: _RoadNetwork,
    obstacle_index: ObstacleIndex,
    cache: dict[tuple[int, int], tuple[float, float]],
    *,
    maximum_free_half_width_m: float = 4.0,
) -> tuple[float, float]:
    edge = network.edges[candidate.edge_index]
    # Half-metre bins keep the obstacle queries bounded on multi-thousand-node
    # sessions while still following shelf ends and cross-aisle openings.
    bin_index = int(round(candidate.fraction * edge.length * 2.0))
    key = (candidate.edge_index, bin_index)
    cached = cache.get(key)
    if cached is not None:
        return cached
    dx = edge.second[0] - edge.first[0]
    dy = edge.second[1] - edge.first[1]
    inverse_length = 1.0 / edge.length
    normal = (-dy * inverse_length, dx * inverse_length)
    probe_distance = max(0.0, min(edge.length, bin_index * 0.5))
    probe_origin = (
        edge.first[0] + dx * (probe_distance / edge.length),
        edge.first[1] + dy * (probe_distance / edge.length),
    )
    declared_half_width = (
        edge.width / 2.0 if edge.width >= 0.50 else maximum_free_half_width_m
    )
    probe_limit = min(maximum_free_half_width_m, declared_half_width)
    negative = obstacle_index.directional_clearance(
        probe_origin,
        (-normal[0], -normal[1]),
        probe_limit,
    )
    positive = obstacle_index.directional_clearance(
        probe_origin,
        normal,
        probe_limit,
    )
    # The ray query returns the last numerically free point.  Keep a small
    # interior margin whenever a real structure, rather than the probe budget,
    # ended the ray; otherwise two individually free endpoints can still draw a
    # segment exactly along the obstacle-clearance boundary.
    boundary_inset_m = 0.02
    if negative < probe_limit - 1.0e-6:
        negative = max(0.0, negative - boundary_inset_m)
    if positive < probe_limit - 1.0e-6:
        positive = max(0.0, positive - boundary_inset_m)
    result = (-negative, positive)
    cache[key] = result
    return result


def _nearest_safe_fraction(
    safe: tuple[float, float],
    desired: tuple[float, float],
    obstacle_index: ObstacleIndex,
) -> tuple[float, float]:
    if not obstacle_index.point_blocked(desired):
        return desired
    if obstacle_index.point_blocked(safe):
        return safe
    low = 0.0
    high = 1.0
    for _ in range(16):
        middle = (low + high) / 2.0
        point = (
            safe[0] + middle * (desired[0] - safe[0]),
            safe[1] + middle * (desired[1] - safe[1]),
        )
        if obstacle_index.point_blocked(point):
            high = middle
        else:
            low = middle
    distance = math.hypot(desired[0] - safe[0], desired[1] - safe[1])
    if distance > 1.0e-9:
        # Do not return a point numerically tangent to the clearance boundary.
        # A two-centimetre retreat keeps adjacent rendered segments from being
        # classified as shelf intersections solely because both endpoints sit
        # on the exact boundary.
        low = max(0.0, low - 0.02 / distance)
    return (
        safe[0] + low * (desired[0] - safe[0]),
        safe[1] + low * (desired[1] - safe[1]),
    )


def _minimum_collision_free_point_translation(
    point: tuple[float, float],
    obstacle_index: ObstacleIndex,
    *,
    preferred_direction: tuple[float, float] | None = None,
    preferred_translation: tuple[float, float] | None = None,
    maximum_translation_m: float = 4.0,
    search_step_m: float = 0.04,
) -> tuple[float, float] | None:
    """Return the nearest free point without treating a road as a target."""

    if not obstacle_index.point_blocked(point):
        return point
    directions: list[tuple[float, float]] = []

    def append_direction(value: tuple[float, float] | None) -> None:
        if value is None:
            return
        norm = math.hypot(value[0], value[1])
        if norm <= 1.0e-12:
            return
        unit = (value[0] / norm, value[1] / norm)
        if any(
            math.hypot(unit[0] - existing[0], unit[1] - existing[1]) < 1.0e-6
            for existing in directions
        ):
            return
        directions.append(unit)

    append_direction(preferred_direction)
    for index in range(32):
        angle = 2.0 * math.pi * index / 32.0
        append_direction((math.cos(angle), math.sin(angle)))

    preferred_unit: tuple[float, float] | None = None
    if preferred_direction is not None:
        preferred_norm = math.hypot(*preferred_direction)
        if preferred_norm > 1.0e-12:
            preferred_unit = (
                preferred_direction[0] / preferred_norm,
                preferred_direction[1] / preferred_norm,
            )

    maximum = max(search_step_m, float(maximum_translation_m))
    step = max(0.02, float(search_step_m))
    best: tuple[float, float, float, float, float] | None = None
    for direction in directions:
        previous_distance = 0.0
        distance = step
        while distance <= maximum + 1.0e-9:
            candidate = (
                point[0] + direction[0] * distance,
                point[1] + direction[1] * distance,
            )
            if not obstacle_index.point_blocked(candidate):
                low = previous_distance
                high = distance
                for _ in range(12):
                    middle = (low + high) / 2.0
                    middle_point = (
                        point[0] + direction[0] * middle,
                        point[1] + direction[1] * middle,
                    )
                    if obstacle_index.point_blocked(middle_point):
                        low = middle
                    else:
                        high = middle
                resolved_distance = min(maximum, high + 0.02)
                resolved = (
                    point[0] + direction[0] * resolved_distance,
                    point[1] + direction[1] * resolved_distance,
                )
                preferred_penalty = (
                    0.0
                    if preferred_unit is None
                    else 1.0
                    - (
                        direction[0] * preferred_unit[0]
                        + direction[1] * preferred_unit[1]
                    )
                )
                translation = (
                    resolved[0] - point[0],
                    resolved[1] - point[1],
                )
                continuity_penalty = (
                    0.0
                    if preferred_translation is None
                    else math.hypot(
                        translation[0] - preferred_translation[0],
                        translation[1] - preferred_translation[1],
                    )
                )
                ranked = (
                    continuity_penalty,
                    resolved_distance,
                    preferred_penalty,
                    resolved[0],
                    resolved[1],
                )
                if best is None or ranked[:3] < best[:3]:
                    best = ranked
                break
            previous_distance = distance
            distance += step
    return None if best is None else (best[3], best[4])


def _project_to_corridor_envelope(
    point: tuple[float, float],
    candidate: _Candidate,
    network: _RoadNetwork,
    obstacle_index: ObstacleIndex,
    envelope_cache: dict[tuple[int, int], tuple[float, float]],
) -> _EnvelopeProjection:
    """Minimally move a point into the selected corridor's free envelope.

    The road edge supplies only topology and a local Frenet frame.  Lateral
    position remains the phone's measured position whenever that position is
    already inside the shelf-bounded free corridor.  This deliberately avoids
    treating the road center line as a measurement of the phone coordinate.
    """

    edge = network.edges[candidate.edge_index]
    dx = edge.second[0] - edge.first[0]
    dy = edge.second[1] - edge.first[1]
    inverse_length = 1.0 / edge.length
    tangent = (dx * inverse_length, dy * inverse_length)
    normal = (-dy * inverse_length, dx * inverse_length)
    longitudinal = (
        (point[0] - edge.first[0]) * tangent[0]
        + (point[1] - edge.first[1]) * tangent[1]
    )
    # A road edge is a finite topological element.  Treating it as an infinite
    # strip allows the HMM to switch to a perpendicular edge many metres before
    # the phone reaches their shared junction.  Keep only a bounded junction
    # apron; neighboring connected edges cover the remainder of the route.
    endpoint_extension_m = (
        max(1.0, min(2.5, edge.width / 2.0)) if edge.width >= 0.5 else 1.5
    )
    clamped_longitudinal = max(
        -endpoint_extension_m,
        min(edge.length + endpoint_extension_m, longitudinal),
    )
    longitudinal_outside = abs(longitudinal - clamped_longitudinal)
    finite_edge_center = (
        edge.first[0] + clamped_longitudinal * tangent[0],
        edge.first[1] + clamped_longitudinal * tangent[1],
    )
    # Keep a second Frenet origin at the phone's own longitudinal coordinate.
    # The finite edge extent is evidence for corridor identity, not a position
    # observation.  Using ``finite_edge_center`` as the geometric target would
    # drag a valid phone pose toward an endpoint whenever the HMM changes edge
    # slightly before or after the junction.
    phone_longitudinal_center = (
        edge.first[0] + longitudinal * tangent[0],
        edge.first[1] + longitudinal * tangent[1],
    )
    local_fraction = max(0.0, min(1.0, clamped_longitudinal / edge.length))
    local_candidate = _Candidate(
        edge_index=candidate.edge_index,
        x=edge.first[0] + local_fraction * dx,
        y=edge.first[1] + local_fraction * dy,
        fraction=local_fraction,
        hint_distance=math.hypot(
            point[0] - finite_edge_center[0], point[1] - finite_edge_center[1]
        ),
        heading=candidate.heading,
    )
    minimum_lateral, maximum_lateral = _corridor_lateral_limits(
        local_candidate,
        network,
        obstacle_index,
        envelope_cache,
    )
    signed_lateral = (
        (point[0] - phone_longitudinal_center[0]) * normal[0]
        + (point[1] - phone_longitudinal_center[1]) * normal[1]
    )
    clamped_lateral = max(
        minimum_lateral,
        min(maximum_lateral, signed_lateral),
    )
    lateral_outside = abs(signed_lateral - clamped_lateral)
    outside_distance = math.hypot(longitudinal_outside, lateral_outside)
    point_blocked = obstacle_index.point_blocked(point)
    lateral_target = (
        phone_longitudinal_center[0] + clamped_lateral * normal[0],
        phone_longitudinal_center[1] + clamped_lateral * normal[1],
    )
    if lateral_outside <= 1.0e-9 and not point_blocked:
        # A finite-edge overrun can penalize this road hypothesis, but it must
        # never change an otherwise valid phone coordinate.
        target = point
        clamped = False
    elif point_blocked:
        # Use one corridor-side escape during the alternating field solve so
        # adjacent blocked samples do not independently choose opposite shelf
        # sides.  A later trajectory-aware pass replaces only isolated escape
        # outliers with a shelf-derived alternative.
        safe_target = (
            lateral_target
            if not obstacle_index.point_blocked(lateral_target)
            else (local_candidate.x, local_candidate.y)
        )
        target = _nearest_safe_fraction(safe_target, point, obstacle_index)
        clamped = True
    else:
        # Lateral envelope correction preserves the phone's longitudinal
        # coordinate.  If a coarse envelope bin puts the target on an obstacle
        # boundary, stop at the last safe point from the original phone pose.
        target = (
            lateral_target
            if not obstacle_index.point_blocked(lateral_target)
            else _nearest_safe_fraction(point, lateral_target, obstacle_index)
        )
        clamped = True
    return _EnvelopeProjection(
        x=target[0],
        y=target[1],
        correction_x=target[0] - point[0],
        correction_y=target[1] - point[1],
        signed_lateral_offset_m=signed_lateral,
        minimum_lateral_offset_m=minimum_lateral,
        maximum_lateral_offset_m=maximum_lateral,
        outside_distance_m=outside_distance,
        clamped=clamped,
    )


def _smooth_vector_field(
    values: Sequence[tuple[float, float]],
    physical_poses: Sequence[Any],
    *,
    length_scale_m: float = 2.0,
) -> list[tuple[float, float]]:
    if not values:
        return []
    scale = max(0.25, float(length_scale_m))

    def pass_values(reverse: bool) -> list[tuple[float, float]]:
        order = range(len(values) - 1, -1, -1) if reverse else range(len(values))
        result: list[tuple[float, float] | None] = [None] * len(values)
        previous_index: int | None = None
        previous_value: tuple[float, float] | None = None
        for index in order:
            current = values[index]
            if previous_index is None or previous_value is None:
                filtered = current
            else:
                step = math.hypot(
                    float(physical_poses[index].x)
                    - float(physical_poses[previous_index].x),
                    float(physical_poses[index].y)
                    - float(physical_poses[previous_index].y),
                )
                retention = math.exp(-max(0.02, step) / scale)
                filtered = (
                    retention * previous_value[0]
                    + (1.0 - retention) * current[0],
                    retention * previous_value[1]
                    + (1.0 - retention) * current[1],
                )
            result[index] = filtered
            previous_index = index
            previous_value = filtered
        return [item for item in result if item is not None]

    forward = pass_values(False)
    backward = pass_values(True)
    return [
        (
            (forward[index][0] + backward[index][0] + values[index][0]) / 3.0,
            (forward[index][1] + backward[index][1] + values[index][1]) / 3.0,
        )
        for index in range(len(values))
    ]


def _piecewise_anchor_translation_field(
    map_hints: Sequence[Any],
    physical_poses: Sequence[Any],
    anchors: Sequence[RouteAnchor],
) -> tuple[list[tuple[float, float]], dict[str, Any]]:
    """Spread exact anchor translation over physical distance, never one node."""

    field = [(0.0, 0.0)] * len(map_hints)
    by_index: dict[int, RouteAnchor] = {}
    duplicate_anchor_count = 0
    for anchor in anchors:
        if not 0 <= anchor.index < len(map_hints):
            continue
        if anchor.index in by_index:
            duplicate_anchor_count += 1
        # Active manual edits are ordered; the latest exact edit at one node is
        # the operator's current authoritative value.
        by_index[anchor.index] = anchor
    if not by_index:
        return field, {
            "anchor_count": 0,
            "duplicate_anchor_index_count": duplicate_anchor_count,
            "maximum_anchor_translation_residual_m": 0.0,
        }

    cumulative = _physical_cumulative(physical_poses)
    knots = [
        (
            index,
            float(anchor.x) - float(map_hints[index].x),
            float(anchor.y) - float(map_hints[index].y),
        )
        for index, anchor in sorted(by_index.items())
    ]

    def interpolate(
        index: int,
        first: tuple[int, float, float],
        second: tuple[int, float, float],
    ) -> tuple[float, float]:
        denominator = cumulative[second[0]] - cumulative[first[0]]
        if denominator > 1.0e-9:
            fraction = (cumulative[index] - cumulative[first[0]]) / denominator
        else:
            fraction = (index - first[0]) / max(1, second[0] - first[0])
        fraction = max(0.0, min(1.0, fraction))
        return (
            first[1] + fraction * (second[1] - first[1]),
            first[2] + fraction * (second[2] - first[2]),
        )

    knot_cursor = 0
    for index in range(len(field)):
        if index <= knots[0][0]:
            field[index] = (knots[0][1], knots[0][2])
            continue
        if index >= knots[-1][0]:
            field[index] = (knots[-1][1], knots[-1][2])
            continue
        while knot_cursor + 1 < len(knots) and index > knots[knot_cursor + 1][0]:
            knot_cursor += 1
        field[index] = interpolate(index, knots[knot_cursor], knots[knot_cursor + 1])

    return field, {
        "anchor_count": len(knots),
        "duplicate_anchor_index_count": duplicate_anchor_count,
        "maximum_anchor_translation_residual_m": round(
            max(math.hypot(value[1], value[2]) for value in knots), 9
        ),
    }


def _lock_vector_field_at_indices(
    values: Sequence[tuple[float, float]],
    physical_poses: Sequence[Any],
    indices: Sequence[int],
    *,
    taper_length_m: float = 4.0,
) -> list[tuple[float, float]]:
    """Make a smoothed residual field exactly zero at anchor nodes."""

    locked = sorted({index for index in indices if 0 <= index < len(values)})
    if not locked:
        return list(values)
    cumulative = _physical_cumulative(physical_poses)
    knots = [(index, values[index][0], values[index][1]) for index in locked]
    taper = max(0.25, float(taper_length_m))

    def removal(index: int) -> tuple[float, float]:
        if index <= knots[0][0]:
            weight = math.exp(
                -(cumulative[knots[0][0]] - cumulative[index]) / taper
            )
            return (knots[0][1] * weight, knots[0][2] * weight)
        if index >= knots[-1][0]:
            weight = math.exp(
                -(cumulative[index] - cumulative[knots[-1][0]]) / taper
            )
            return (knots[-1][1] * weight, knots[-1][2] * weight)
        right = next(position for position, knot in enumerate(knots) if knot[0] >= index)
        first = knots[right - 1]
        second = knots[right]
        denominator = cumulative[second[0]] - cumulative[first[0]]
        if denominator > 1.0e-9:
            fraction = (cumulative[index] - cumulative[first[0]]) / denominator
        else:
            fraction = (index - first[0]) / max(1, second[0] - first[0])
        fraction = max(0.0, min(1.0, fraction))
        return (
            first[1] + fraction * (second[1] - first[1]),
            first[2] + fraction * (second[2] - first[2]),
        )

    result: list[tuple[float, float]] = []
    for index, value in enumerate(values):
        subtract = removal(index)
        result.append((value[0] - subtract[0], value[1] - subtract[1]))
    return result


def _projected_smooth_correction_field(
    base_points: Sequence[tuple[float, float]],
    selected: Sequence[_Candidate],
    physical_poses: Sequence[Any],
    network: _RoadNetwork,
    obstacle_index: ObstacleIndex,
    envelope_cache: dict[tuple[int, int], tuple[float, float]],
    anchor_indices: Sequence[int],
    *,
    iterations: int = 32,
    length_scale_m: float = 3.0,
) -> tuple[list[tuple[float, float]], list[_EnvelopeProjection], int]:
    """Alternate free-envelope projection with low-pass correction smoothing.

    One final per-node clamp creates spikes at the entrance and exit of an
    occupied region.  Alternating projection spreads the required translation
    into neighboring physical samples while repeatedly restoring the selected
    corridor/free-space constraint.  The road center itself is never a target.
    """

    anchor_set = {
        index for index in anchor_indices if 0 <= index < len(base_points)
    }
    corrections = [(0.0, 0.0)] * len(base_points)
    last_projections: list[_EnvelopeProjection] = []
    iteration_count = max(1, int(iterations))
    for _ in range(iteration_count):
        projected_corrections: list[tuple[float, float]] = []
        last_projections = []
        for index, (base, candidate, correction) in enumerate(
            zip(base_points, selected, corrections)
        ):
            point = (base[0] + correction[0], base[1] + correction[1])
            projection = _project_to_corridor_envelope(
                point,
                candidate,
                network,
                obstacle_index,
                envelope_cache,
            )
            last_projections.append(projection)
            if index in anchor_set:
                projected_corrections.append((0.0, 0.0))
            else:
                projected_corrections.append(
                    (
                        correction[0] + projection.correction_x,
                        correction[1] + projection.correction_y,
                    )
                )
        smoothed = _smooth_vector_field(
            projected_corrections,
            physical_poses,
            length_scale_m=length_scale_m,
        )
        smoothed = _lock_vector_field_at_indices(
            smoothed,
            physical_poses,
            tuple(anchor_set),
            taper_length_m=max(4.0, length_scale_m * 1.5),
        )
        # Retain enough of the exact projection to converge into free space,
        # while the larger smooth component distributes it over nearby travel.
        corrections = [
            (
                0.35 * projected[0] + 0.65 * smooth[0],
                0.35 * projected[1] + 0.65 * smooth[1],
            )
            for projected, smooth in zip(projected_corrections, smoothed)
        ]
        for index in anchor_set:
            corrections[index] = (0.0, 0.0)
    return corrections, last_projections, iteration_count


def _trajectory_segment_scales(
    final_points: Sequence[tuple[float, float]],
    physical_poses: Sequence[Any],
    anchors: Sequence[RouteAnchor],
) -> list[dict[str, Any]]:
    boundaries = [0]
    boundaries.extend(
        sorted(
            {
                anchor.index
                for anchor in anchors
                if 0 < anchor.index < len(final_points) - 1
            }
        )
    )
    boundaries.append(len(final_points) - 1)
    physical_distance = _physical_cumulative(physical_poses)
    final_distance = _polyline_cumulative(final_points)
    segments: list[dict[str, Any]] = []
    for first_index, second_index in zip(boundaries, boundaries[1:]):
        physical_length = (
            physical_distance[second_index] - physical_distance[first_index]
        )
        final_length = final_distance[second_index] - final_distance[first_index]
        scale = final_length / physical_length if physical_length > 1.0e-9 else 1.0
        segments.append(
            {
                "start_index": first_index,
                "end_index": second_index,
                "route_length_m": round(final_length, 6),
                "trajectory_length_m": round(final_length, 6),
                "physical_length_m": round(physical_length, 6),
                "distance_scale": round(scale, 9),
            }
        )
    return segments


def _repair_point_escape_discontinuities(
    source_points: Sequence[tuple[float, float]],
    projected_points: Sequence[tuple[float, float]],
    selected: Sequence[_Candidate],
    obstacle_index: ObstacleIndex,
    anchor_indices: Sequence[int],
    *,
    discontinuity_threshold_m: float = 0.50,
    maximum_passes: int = 3,
) -> tuple[list[tuple[float, float]], dict[str, Any]]:
    """Replace isolated shelf exits with the locally continuous free side.

    The alternating solver first keeps neighboring blocked points on a common
    corridor side.  A road-edge switch can nevertheless make one point choose
    a distant candidate.  Only such an outlier is reconsidered: radial shelf
    exits are ranked by agreement with the neighboring correction field, then
    by movement distance.  Valid free points are never touched.
    """

    result = list(projected_points)
    locked = {index for index in anchor_indices if 0 <= index < len(result)}

    def delta(index: int) -> tuple[float, float]:
        return (
            result[index][0] - source_points[index][0],
            result[index][1] - source_points[index][1],
        )

    def neighbor_prediction(index: int) -> tuple[float, float]:
        values = [
            delta(neighbor)
            for neighbor in (index - 1, index + 1)
            if 0 <= neighbor < len(result)
        ]
        if not values:
            return (0.0, 0.0)
        return (
            sum(value[0] for value in values) / len(values),
            sum(value[1] for value in values) / len(values),
        )

    before = []
    for index in range(len(result)):
        predicted = neighbor_prediction(index)
        current = delta(index)
        before.append(
            math.hypot(current[0] - predicted[0], current[1] - predicted[1])
        )

    repaired: set[int] = set()
    for _ in range(max(1, int(maximum_passes))):
        changed = False
        for index in range(len(result)):
            if index in locked or not obstacle_index.point_blocked(source_points[index]):
                continue
            predicted = neighbor_prediction(index)
            current = delta(index)
            current_discontinuity = math.hypot(
                current[0] - predicted[0], current[1] - predicted[1]
            )
            if current_discontinuity <= discontinuity_threshold_m:
                continue
            preferred = (
                selected[index].x - source_points[index][0],
                selected[index].y - source_points[index][1],
            )
            alternative = _minimum_collision_free_point_translation(
                source_points[index],
                obstacle_index,
                preferred_direction=preferred,
                preferred_translation=predicted,
            )
            if alternative is None:
                continue
            alternative_delta = (
                alternative[0] - source_points[index][0],
                alternative[1] - source_points[index][1],
            )
            alternative_discontinuity = math.hypot(
                alternative_delta[0] - predicted[0],
                alternative_delta[1] - predicted[1],
            )
            if alternative_discontinuity + 1.0e-6 >= current_discontinuity:
                continue
            result[index] = alternative
            repaired.add(index)
            changed = True
        if not changed:
            break

    after = []
    for index in range(len(result)):
        predicted = neighbor_prediction(index)
        current = delta(index)
        after.append(
            math.hypot(current[0] - predicted[0], current[1] - predicted[1])
        )
    return result, {
        "method": "trajectory_continuous_shelf_exit_selection_v1",
        "repaired_point_count": len(repaired),
        "maximum_escape_discontinuity_before_m": round(max(before, default=0.0), 9),
        "maximum_escape_discontinuity_after_m": round(max(after, default=0.0), 9),
        "discontinuity_threshold_m": discontinuity_threshold_m,
    }


def _repair_free_correction_spikes(
    reference_points: Sequence[tuple[float, float]],
    points: Sequence[tuple[float, float]],
    physical_poses: Sequence[Any],
    obstacle_index: ObstacleIndex,
    anchor_indices: Sequence[int],
    *,
    discontinuity_threshold_m: float = 0.50,
    maximum_passes: int = 4,
) -> tuple[list[tuple[float, float]], dict[str, Any]]:
    """Remove isolated correction spikes only when interpolation is free.

    This is a projection onto the low-frequency correction-field contract, not
    a road observation.  A candidate replaces one node only when the linearly
    interpolated neighboring correction keeps the point and both adjacent
    segments collision-free and does not increase the local maximum step.
    """

    result = list(points)
    locked = {index for index in anchor_indices if 0 <= index < len(result)}
    cumulative = _physical_cumulative(physical_poses)

    def correction(index: int) -> tuple[float, float]:
        return (
            result[index][0] - reference_points[index][0],
            result[index][1] - reference_points[index][1],
        )

    def interpolated_correction(index: int) -> tuple[float, float]:
        first = correction(index - 1)
        second = correction(index + 1)
        span = cumulative[index + 1] - cumulative[index - 1]
        fraction = (
            (cumulative[index] - cumulative[index - 1]) / span
            if span > 1.0e-9
            else 0.5
        )
        fraction = max(0.0, min(1.0, fraction))
        return (
            first[0] + fraction * (second[0] - first[0]),
            first[1] + fraction * (second[1] - first[1]),
        )

    def discontinuity(index: int) -> float:
        current = correction(index)
        expected = interpolated_correction(index)
        return math.hypot(current[0] - expected[0], current[1] - expected[1])

    before = [
        discontinuity(index) for index in range(1, max(1, len(result) - 1))
    ]
    repaired: set[int] = set()
    for _ in range(max(1, int(maximum_passes))):
        changed = False
        candidates = sorted(
            (
                (discontinuity(index), index)
                for index in range(1, len(result) - 1)
                if index not in locked
            ),
            reverse=True,
        )
        for current_discontinuity, index in candidates:
            if current_discontinuity <= discontinuity_threshold_m:
                break
            expected = interpolated_correction(index)
            candidate = (
                reference_points[index][0] + expected[0],
                reference_points[index][1] + expected[1],
            )
            if obstacle_index.point_blocked(candidate):
                continue
            if obstacle_index.segment_blocked(result[index - 1], candidate):
                continue
            if obstacle_index.segment_blocked(candidate, result[index + 1]):
                continue
            old_local_step = max(
                math.hypot(
                    result[index][0] - result[index - 1][0],
                    result[index][1] - result[index - 1][1],
                ),
                math.hypot(
                    result[index + 1][0] - result[index][0],
                    result[index + 1][1] - result[index][1],
                ),
            )
            new_local_step = max(
                math.hypot(
                    candidate[0] - result[index - 1][0],
                    candidate[1] - result[index - 1][1],
                ),
                math.hypot(
                    result[index + 1][0] - candidate[0],
                    result[index + 1][1] - candidate[1],
                ),
            )
            if new_local_step > old_local_step + 1.0e-9:
                continue
            result[index] = candidate
            repaired.add(index)
            changed = True
        if not changed:
            break

    after = [
        discontinuity(index) for index in range(1, max(1, len(result) - 1))
    ]
    return result, {
        "method": "collision_safe_low_frequency_correction_interpolation_v1",
        "repaired_point_count": len(repaired),
        "maximum_spike_before_m": round(max(before, default=0.0), 9),
        "maximum_spike_after_m": round(max(after, default=0.0), 9),
        "discontinuity_threshold_m": discontinuity_threshold_m,
    }


def _repair_free_correction_gradient_steps(
    reference_points: Sequence[tuple[float, float]],
    points: Sequence[tuple[float, float]],
    physical_poses: Sequence[Any],
    obstacle_index: ObstacleIndex,
    anchor_indices: Sequence[int],
    *,
    gradient_threshold_m: float = 0.50,
    maximum_passes: int = 8,
) -> tuple[list[tuple[float, float]], dict[str, Any]]:
    """Spread a free-space correction step over physical travel distance."""

    result = list(points)
    locked = {index for index in anchor_indices if 0 <= index < len(result)}
    cumulative = _physical_cumulative(physical_poses)

    def correction(index: int) -> tuple[float, float]:
        return (
            result[index][0] - reference_points[index][0],
            result[index][1] - reference_points[index][1],
        )

    def changes() -> list[float]:
        values = [correction(index) for index in range(len(result))]
        return [
            math.hypot(second[0] - first[0], second[1] - first[1])
            for first, second in zip(values, values[1:])
        ]

    before = changes()
    repaired_boundaries: set[int] = set()
    attempted_boundary_count = 0
    for _ in range(max(1, int(maximum_passes))):
        current_changes = changes()
        boundaries = sorted(
            (
                (value, index)
                for index, value in enumerate(current_changes)
                if value > gradient_threshold_m
                and index not in locked
                and index + 1 not in locked
            ),
            reverse=True,
        )
        if not boundaries:
            break
        changed = False
        for boundary_change, boundary in boundaries:
            attempted_boundary_count += 1
            for half_window_m in (3.0, 2.0, 1.0, 0.5):
                start = bisect.bisect_left(
                    cumulative, cumulative[boundary] - half_window_m
                )
                end = bisect.bisect_right(
                    cumulative, cumulative[boundary + 1] + half_window_m
                ) - 1
                if end - start < 2:
                    continue
                if any(start < index < end for index in locked):
                    continue
                first_correction = correction(start)
                last_correction = correction(end)
                span = cumulative[end] - cumulative[start]
                candidate_points = list(result[start : end + 1])
                candidate_corrections: list[tuple[float, float]] = []
                for index in range(start, end + 1):
                    fraction = (
                        (cumulative[index] - cumulative[start]) / span
                        if span > 1.0e-9
                        else (index - start) / max(1, end - start)
                    )
                    fraction = max(0.0, min(1.0, fraction))
                    candidate_correction = (
                        first_correction[0]
                        + fraction * (last_correction[0] - first_correction[0]),
                        first_correction[1]
                        + fraction * (last_correction[1] - first_correction[1]),
                    )
                    candidate_corrections.append(candidate_correction)
                    candidate_points[index - start] = (
                        reference_points[index][0] + candidate_correction[0],
                        reference_points[index][1] + candidate_correction[1],
                    )
                if any(
                    obstacle_index.point_blocked(point)
                    for point in candidate_points
                ):
                    continue
                if any(
                    obstacle_index.segment_blocked(first, second)
                    for first, second in zip(candidate_points, candidate_points[1:])
                ):
                    continue
                old_steps = [
                    math.hypot(second[0] - first[0], second[1] - first[1])
                    for first, second in zip(
                        result[start : end + 1], result[start + 1 : end + 1]
                    )
                ]
                new_steps = [
                    math.hypot(second[0] - first[0], second[1] - first[1])
                    for first, second in zip(candidate_points, candidate_points[1:])
                ]
                if max(new_steps, default=0.0) > max(old_steps, default=0.0) + 1.0e-9:
                    continue
                new_changes = [
                    math.hypot(
                        second[0] - first[0], second[1] - first[1]
                    )
                    for first, second in zip(
                        candidate_corrections, candidate_corrections[1:]
                    )
                ]
                if max(new_changes, default=0.0) + 1.0e-6 >= boundary_change:
                    continue
                result[start : end + 1] = candidate_points
                repaired_boundaries.add(boundary)
                changed = True
                break
        if not changed:
            break

    after = changes()
    return result, {
        "method": "collision_safe_physical_distance_correction_ramp_v1",
        "repaired_boundary_count": len(repaired_boundaries),
        "attempted_boundary_count": attempted_boundary_count,
        "maximum_neighbor_change_before_m": round(max(before, default=0.0), 9),
        "maximum_neighbor_change_after_m": round(max(after, default=0.0), 9),
        "gradient_threshold_m": gradient_threshold_m,
    }


def _minimum_collision_free_center_blend(
    first: tuple[float, float],
    second: tuple[float, float],
    first_safe: tuple[float, float],
    second_safe: tuple[float, float],
    obstacle_index: ObstacleIndex,
    *,
    move_first: bool,
    move_second: bool,
) -> tuple[tuple[float, float], tuple[float, float], float] | None:
    """Find the least local attraction needed to clear one blocked segment."""

    def blended(fraction: float) -> tuple[tuple[float, float], tuple[float, float]]:
        return (
            (
                first[0] + fraction * (first_safe[0] - first[0]),
                first[1] + fraction * (first_safe[1] - first[1]),
            )
            if move_first
            else first,
            (
                second[0] + fraction * (second_safe[0] - second[0]),
                second[1] + fraction * (second_safe[1] - second[1]),
            )
            if move_second
            else second,
        )

    fully_blended = blended(1.0)
    if obstacle_index.segment_blocked(*fully_blended):
        return None
    low = 0.0
    high = 1.0
    for _ in range(16):
        middle = (low + high) / 2.0
        candidate = blended(middle)
        if obstacle_index.segment_blocked(*candidate):
            low = middle
        else:
            high = middle
    resolved = blended(min(1.0, high + 0.01))
    return resolved[0], resolved[1], min(1.0, high + 0.01)


def _minimum_collision_free_rigid_translation(
    first: tuple[float, float],
    second: tuple[float, float],
    obstacle_index: ObstacleIndex,
    *,
    preferred_direction: tuple[float, float] | None = None,
    maximum_translation_m: float = 4.0,
    search_step_m: float = 0.05,
) -> tuple[float, float, float] | None:
    """Translate a blocked local segment rigidly to its nearest free side.

    Shelf geometry, not a road center line, determines the correction.  Both
    endpoints receive the same translation, preserving the measured segment
    direction and length.  A road-derived preferred direction is used only as
    a deterministic tie-breaker between equally short free-space solutions.
    """

    segment_dx = second[0] - first[0]
    segment_dy = second[1] - first[1]
    segment_length = math.hypot(segment_dx, segment_dy)
    directions: list[tuple[float, float]] = []

    def append_direction(value: tuple[float, float] | None) -> None:
        if value is None:
            return
        norm = math.hypot(value[0], value[1])
        if norm <= 1.0e-12:
            return
        unit = (value[0] / norm, value[1] / norm)
        if any(
            math.hypot(unit[0] - existing[0], unit[1] - existing[1]) < 1.0e-6
            for existing in directions
        ):
            return
        directions.append(unit)

    append_direction(preferred_direction)
    if segment_length > 1.0e-12:
        tangent = (segment_dx / segment_length, segment_dy / segment_length)
        append_direction((-tangent[1], tangent[0]))
        append_direction((tangent[1], -tangent[0]))
        append_direction(tangent)
        append_direction((-tangent[0], -tangent[1]))
    # Twenty-four directions bound the angular miss to 7.5 degrees while
    # keeping this rare collision-only search inexpensive on long sessions.
    for index in range(24):
        angle = 2.0 * math.pi * index / 24.0
        append_direction((math.cos(angle), math.sin(angle)))

    preferred_unit: tuple[float, float] | None = None
    if preferred_direction is not None:
        preferred_norm = math.hypot(*preferred_direction)
        if preferred_norm > 1.0e-12:
            preferred_unit = (
                preferred_direction[0] / preferred_norm,
                preferred_direction[1] / preferred_norm,
            )

    best: tuple[float, float, float, float] | None = None
    maximum = max(search_step_m, float(maximum_translation_m))
    step = max(0.02, float(search_step_m))
    for direction in directions:
        previous_distance = 0.0
        distance = step
        while distance <= maximum + 1.0e-9:
            delta = (direction[0] * distance, direction[1] * distance)
            translated = (
                (first[0] + delta[0], first[1] + delta[1]),
                (second[0] + delta[0], second[1] + delta[1]),
            )
            if not obstacle_index.segment_blocked(*translated):
                low = previous_distance
                high = distance
                for _ in range(12):
                    middle = (low + high) / 2.0
                    middle_delta = (
                        direction[0] * middle,
                        direction[1] * middle,
                    )
                    middle_segment = (
                        (
                            first[0] + middle_delta[0],
                            first[1] + middle_delta[1],
                        ),
                        (
                            second[0] + middle_delta[0],
                            second[1] + middle_delta[1],
                        ),
                    )
                    if obstacle_index.segment_blocked(*middle_segment):
                        low = middle
                    else:
                        high = middle
                # Retain a two-centimetre interior margin so the repaired
                # segment is not numerically tangent to the shelf clearance.
                resolved_distance = min(maximum, high + 0.02)
                resolved_delta = (
                    direction[0] * resolved_distance,
                    direction[1] * resolved_distance,
                )
                preferred_penalty = (
                    0.0
                    if preferred_unit is None
                    else 1.0
                    - (
                        direction[0] * preferred_unit[0]
                        + direction[1] * preferred_unit[1]
                    )
                )
                candidate = (
                    resolved_distance,
                    preferred_penalty,
                    resolved_delta[0],
                    resolved_delta[1],
                )
                if best is None or candidate[:2] < best[:2]:
                    best = candidate
                break
            previous_distance = distance
            distance += step
    if best is None:
        return None
    return (best[2], best[3], best[0])


def _repair_blocked_segments_with_local_field(
    points: Sequence[tuple[float, float]],
    selected: Sequence[_Candidate],
    physical_poses: Sequence[Any],
    anchors: Sequence[RouteAnchor],
    network: _RoadNetwork,
    obstacle_index: ObstacleIndex,
    envelope_cache: dict[tuple[int, int], tuple[float, float]],
    *,
    maximum_passes: int = 16,
    taper_length_m: float = 2.0,
) -> tuple[list[tuple[float, float]], dict[str, Any]]:
    """Clear residual shelf crossings with a tapered, minimum local field.

    Candidate centers are used only as a proven collision-free escape
    direction for a segment that actually intersects occupied structure.  The
    minimum required blend is tapered over neighboring physical travel, so this
    cannot turn the full phone trajectory into a road-center polyline.
    """

    result = list(points)
    anchor_indices = {
        anchor.index for anchor in anchors if 0 <= anchor.index < len(result)
    }
    cumulative = _physical_cumulative(physical_poses)
    initial_crossings = sum(
        obstacle_index.segment_blocked(first, second)
        for first, second in zip(result, result[1:])
    )
    maximum_blend = 0.0
    maximum_rigid_translation = 0.0
    repaired_segment_count = 0
    rigid_translation_repair_count = 0
    anchor_endpoint_escape_count = 0
    passes_used = 0
    for pass_index in range(max(0, int(maximum_passes))):
        blocked_indices = [
            index
            for index, (first, second) in enumerate(zip(result, result[1:]))
            if obstacle_index.segment_blocked(first, second)
        ]
        if not blocked_indices:
            break
        passes_used = pass_index + 1
        repaired_in_pass = False
        proposals: list[list[tuple[float, float, float]]] = [
            [] for _ in result
        ]
        touched_indices: set[int] = set()
        for index in blocked_indices:
            first_locked = index in anchor_indices
            second_locked = index + 1 in anchor_indices
            rigid_repair = None
            if not first_locked and not second_locked:
                current_midpoint = (
                    (result[index][0] + result[index + 1][0]) / 2.0,
                    (result[index][1] + result[index + 1][1]) / 2.0,
                )
                candidate_midpoint = (
                    (selected[index].x + selected[index + 1].x) / 2.0,
                    (selected[index].y + selected[index + 1].y) / 2.0,
                )
                rigid_repair = _minimum_collision_free_rigid_translation(
                    result[index],
                    result[index + 1],
                    obstacle_index,
                    preferred_direction=(
                        candidate_midpoint[0] - current_midpoint[0],
                        candidate_midpoint[1] - current_midpoint[1],
                    ),
                )
            if rigid_repair is not None:
                delta_x, delta_y, translation = rigid_repair
                target_first = (
                    result[index][0] + delta_x,
                    result[index][1] + delta_y,
                )
                target_second = (
                    result[index + 1][0] + delta_x,
                    result[index + 1][1] + delta_y,
                )
                maximum_rigid_translation = max(
                    maximum_rigid_translation, translation
                )
                rigid_translation_repair_count += 1
            else:
                # Exact anchors are immutable.  If one endpoint is locked, a
                # rigid translation is impossible; use the selected topology
                # candidate only for the unlocked endpoint and audit it as a
                # distinct fallback rather than silently moving the anchor.
                repair = _minimum_collision_free_center_blend(
                    result[index],
                    result[index + 1],
                    (selected[index].x, selected[index].y),
                    (selected[index + 1].x, selected[index + 1].y),
                    obstacle_index,
                    move_first=not first_locked,
                    move_second=not second_locked,
                )
                if repair is None:
                    continue
                target_first, target_second, blend = repair
                maximum_blend = max(maximum_blend, blend)
                anchor_endpoint_escape_count += 1
            repaired_segment_count += 1
            repaired_in_pass = True
            first_delta = (
                target_first[0] - result[index][0],
                target_first[1] - result[index][1],
            )
            second_delta = (
                target_second[0] - result[index + 1][0],
                target_second[1] - result[index + 1][1],
            )
            taper_limit = taper_length_m * 4.0
            first_neighbor = bisect.bisect_left(
                cumulative, cumulative[index] - taper_limit
            )
            last_neighbor = bisect.bisect_right(
                cumulative, cumulative[index + 1] + taper_limit
            )
            for neighbor in range(first_neighbor, last_neighbor):
                if neighbor in anchor_indices:
                    continue
                if neighbor <= index:
                    travel = cumulative[index] - cumulative[neighbor]
                    delta = first_delta
                else:
                    travel = cumulative[neighbor] - cumulative[index + 1]
                    delta = second_delta
                if travel > taper_limit:
                    continue
                weight = math.exp(-travel / max(0.25, taper_length_m))
                proposals[neighbor].append((delta[0], delta[1], weight))
                touched_indices.add(neighbor)
        if not repaired_in_pass:
            break
        # Multiple adjacent blocked segments often describe the same shelf
        # boundary. Combine their local rigid-translation proposals into one
        # field for this pass; never add every proposal sequentially to the
        # same node, which would manufacture a large one-node detour.
        for index, values in enumerate(proposals):
            if not values or index in anchor_indices:
                continue
            total_weight = sum(value[2] for value in values)
            if total_weight <= 1.0e-12:
                continue
            result[index] = (
                result[index][0]
                + sum(value[0] * value[2] for value in values) / total_weight,
                result[index][1]
                + sum(value[1] * value[2] for value in values) / total_weight,
            )
        # Restore point-wise validity only where the combined field put a
        # neighboring sample inside a structure. A free translated point is
        # never pulled toward a road candidate here.
        for index in sorted(touched_indices):
            if index in anchor_indices or not obstacle_index.point_blocked(result[index]):
                continue
            projection = _project_to_corridor_envelope(
                result[index],
                selected[index],
                network,
                obstacle_index,
                envelope_cache,
            )
            result[index] = (projection.x, projection.y)
    final_crossings = sum(
        obstacle_index.segment_blocked(first, second)
        for first, second in zip(result, result[1:])
    )
    return result, {
        "initial_obstacle_crossing_segment_count": initial_crossings,
        "final_obstacle_crossing_segment_count": final_crossings,
        "repair_pass_count": passes_used,
        "repaired_segment_attempt_count": repaired_segment_count,
        "rigid_translation_repair_count": rigid_translation_repair_count,
        "maximum_local_rigid_translation_m": round(
            maximum_rigid_translation, 9
        ),
        "anchor_endpoint_escape_count": anchor_endpoint_escape_count,
        "maximum_local_safe_escape_blend": round(maximum_blend, 9),
        "safe_escape_reference": (
            "shelf_driven_rigid_translation_then_locked_anchor_topology_fallback"
        ),
        "taper_length_m": taper_length_m,
    }


def _preserve_local_geometry_in_selected_corridor(
    selected: Sequence[_Candidate],
    physical_poses: Sequence[Any],
    map_hints: Sequence[Any],
    anchors: Sequence[RouteAnchor],
    network: _RoadNetwork,
    obstacle_index: ObstacleIndex,
) -> tuple[list[tuple[float, float]], dict[str, Any]]:
    """Apply a low-frequency minimal correction, never a center-line trace."""

    envelope_cache: dict[tuple[int, int], tuple[float, float]] = {}
    anchor_field, anchor_field_audit = _piecewise_anchor_translation_field(
        map_hints, physical_poses, anchors
    )
    base_points = [
        (
            float(hint.x) + anchor_correction[0],
            float(hint.y) + anchor_correction[1],
        )
        for hint, anchor_correction in zip(map_hints, anchor_field)
    ]
    initial = [
        _project_to_corridor_envelope(
            point,
            candidate,
            network,
            obstacle_index,
            envelope_cache,
        )
        for point, candidate in zip(base_points, selected)
    ]
    anchor_indices = [
        anchor.index for anchor in anchors if 0 <= anchor.index < len(base_points)
    ]
    smoothed, _projected_iterations, correction_iteration_count = (
        _projected_smooth_correction_field(
        base_points,
        selected,
        physical_poses,
        network,
        obstacle_index,
        envelope_cache,
        anchor_indices,
        )
    )
    final_points = [
        (point[0] + correction[0], point[1] + correction[1])
        for point, correction in zip(base_points, smoothed)
    ]

    anchor_by_index = {
        anchor.index: anchor for anchor in anchors if 0 <= anchor.index < len(final_points)
    }
    # The smoothing field is intentionally corrected once more only where it
    # left the selected free envelope.  Points already valid in the aisle keep
    # their measured lateral offset.  Exact operator anchors are never moved by
    # an automatic road hypothesis.
    final_envelopes: list[_EnvelopeProjection] = []
    for index, (point, candidate) in enumerate(zip(final_points, selected)):
        anchor = anchor_by_index.get(index)
        if anchor is not None:
            final_points[index] = (anchor.x, anchor.y)
            final_envelopes.append(
                _EnvelopeProjection(
                    x=anchor.x,
                    y=anchor.y,
                    correction_x=anchor.x - float(map_hints[index].x),
                    correction_y=anchor.y - float(map_hints[index].y),
                    signed_lateral_offset_m=0.0,
                    minimum_lateral_offset_m=0.0,
                    maximum_lateral_offset_m=0.0,
                    outside_distance_m=0.0,
                    clamped=False,
                )
            )
            continue
        envelope = _project_to_corridor_envelope(
            point,
            candidate,
            network,
            obstacle_index,
            envelope_cache,
        )
        final_points[index] = (envelope.x, envelope.y)
        final_envelopes.append(envelope)

    final_points, point_escape_audit = _repair_point_escape_discontinuities(
        [
            (point[0] + correction[0], point[1] + correction[1])
            for point, correction in zip(base_points, smoothed)
        ],
        final_points,
        selected,
        obstacle_index,
        anchor_indices,
    )

    final_points, segment_repair_audit = _repair_blocked_segments_with_local_field(
        final_points,
        selected,
        physical_poses,
        anchors,
        network,
        obstacle_index,
        envelope_cache,
    )

    final_points, correction_spike_audit = _repair_free_correction_spikes(
        [(float(hint.x), float(hint.y)) for hint in map_hints],
        final_points,
        physical_poses,
        obstacle_index,
        anchor_indices,
    )

    final_points, correction_gradient_audit = (
        _repair_free_correction_gradient_steps(
            [(float(hint.x), float(hint.y)) for hint in map_hints],
            final_points,
            physical_poses,
            obstacle_index,
            anchor_indices,
        )
    )

    final_corrections = [
        (
            point[0] - float(hint.x),
            point[1] - float(hint.y),
        )
        for point, hint in zip(final_points, map_hints)
    ]
    correction_magnitudes = [math.hypot(*value) for value in final_corrections]
    neighbor_correction_changes = [
        math.hypot(
            second[0] - first[0],
            second[1] - first[1],
        )
        for first, second in zip(final_corrections, final_corrections[1:])
    ]
    centerline_offsets = [
        projected[2] if projected is not None else math.inf
        for point, candidate in zip(final_points, selected)
        for projected in (
            _project_to_segment(
                point[0],
                point[1],
                network.edges[candidate.edge_index].first,
                network.edges[candidate.edge_index].second,
            ),
        )
    ]
    segments = _trajectory_segment_scales(final_points, physical_poses, anchors)
    selected_graph_steps = [
        network.distance(first, second)
        for first, second in zip(selected, selected[1:])
    ]
    return final_points, {
        "method": "local_geometry_preserving_corridor_envelope_v2",
        "centerline_snap_applied": False,
        "road_geometry_role": "topology_and_free_space_constraint_only",
        "source_geometry_role": "optimized_phone_pose_local_geometry",
        "point_obstacle_escape": "corridor_consistent_then_temporal_continuity_repair_v1",
        "point_escape_continuity_repair": point_escape_audit,
        "correction_spike_repair": correction_spike_audit,
        "correction_gradient_repair": correction_gradient_audit,
        "anchor_translation_field": anchor_field_audit,
        "correction_field_solver": "alternating_free_envelope_projection_v1",
        "correction_field_iteration_count": correction_iteration_count,
        "segment_collision_repair": segment_repair_audit,
        "segments": segments,
        "selected_route_length_m": round(
            sum(value for value in selected_graph_steps if math.isfinite(value)),
            6,
        ),
        "maximum_distance_scale": round(
            max((value["distance_scale"] for value in segments), default=1.0),
            9,
        ),
        "minimum_distance_scale": round(
            min((value["distance_scale"] for value in segments), default=1.0),
            9,
        ),
        "initial_envelope_clamped_count": sum(item.clamped for item in initial),
        "final_envelope_clamped_count": sum(item.clamped for item in final_envelopes),
        "maximum_correction_m": round(max(correction_magnitudes, default=0.0), 9),
        "maximum_neighbor_correction_change_m": round(
            max(neighbor_correction_changes, default=0.0), 9
        ),
        "mean_centerline_offset_m": round(
            sum(centerline_offsets) / max(1, len(centerline_offsets)), 9
        ),
        "maximum_centerline_offset_m": round(
            max(centerline_offsets, default=0.0), 9
        ),
    }


def _match_projection_route(
    physical_poses: Sequence[Any],
    map_hints: Sequence[Any],
    road_graph: Mapping[str, Any],
    floor_id: str,
    polygons: Sequence[Sequence[tuple[float, float]]],
    anchors: Sequence[RouteAnchor] = (),
    *,
    maximum_candidates: int = 18,
    search_radius_m: float = 10.0,
    obstacle_clearance_m: float = 0.12,
    ambiguity_margin: float = 1.0,
) -> RouteMatchResult | None:
    """Match a physical trajectory to one collision-free connected route.

    ``physical_poses`` supplies relative motion and timestamps. ``map_hints``
    supplies the current map-gauge hypothesis.  They must have identical
    indexing; a route transition is admissible only when its graph distance is
    compatible with the physical displacement and its rendered segment stays
    in free space.
    """

    if len(physical_poses) != len(map_hints) or len(physical_poses) < 2:
        return None
    try:
        network = _RoadNetwork(road_graph, floor_id)
    except (TypeError, ValueError):
        return None
    obstacle_index = ObstacleIndex(polygons, clearance_m=obstacle_clearance_m)
    anchor_by_index = {value.index: value for value in anchors}
    envelope_cache: dict[tuple[int, int], tuple[float, float]] = {}
    candidate_sets: list[list[_Candidate]] = []
    candidate_envelopes: list[list[_EnvelopeProjection]] = []
    emissions: list[list[float]] = []
    for index, hint in enumerate(map_hints):
        point = (float(hint.x), float(hint.y))
        candidates = network.candidates(
            point,
            obstacle_index,
            maximum_candidates=maximum_candidates,
            search_radius_m=search_radius_m,
        )
        if not candidates:
            return None
        travel_heading, tangent_distance = _motion_heading(physical_poses, index)
        anchor = anchor_by_index.get(index)
        values: list[float] = []
        layer_envelopes: list[_EnvelopeProjection] = []
        for candidate in candidates:
            envelope = _project_to_corridor_envelope(
                point,
                candidate,
                network,
                obstacle_index,
                envelope_cache,
            )
            layer_envelopes.append(envelope)
            # The finite edge extent constrains corridor identity, but the
            # geometric correction deliberately ignores longitudinal overrun.
            # Score with the full finite-envelope residual so the HMM cannot
            # switch to a perpendicular edge metres before a real junction.
            required_move = envelope.outside_distance_m
            lateral_span = max(
                0.25,
                envelope.maximum_lateral_offset_m
                - envelope.minimum_lateral_offset_m,
            )
            # No center-line attraction exists inside the selected free
            # corridor.  A tiny normalized distance term is only a stable
            # tie-breaker when multiple topology candidates contain the same
            # point; it cannot erase the phone's lateral movement.
            emission = (required_move / 1.5) ** 2 + 0.01 * (
                candidate.hint_distance / (lateral_span + 1.0)
            ) ** 2
            if travel_heading is not None and tangent_distance >= 0.75:
                heading_residual = _axis_residual(candidate.heading, travel_heading)
                emission += 0.45 * (heading_residual / math.radians(18.0)) ** 2
            if index == 0:
                emission += (required_move / 0.45) ** 2
            if anchor is not None:
                anchor_envelope = _project_to_corridor_envelope(
                    (anchor.x, anchor.y),
                    candidate,
                    network,
                    obstacle_index,
                    envelope_cache,
                )
                anchor_distance = math.hypot(
                    anchor_envelope.correction_x,
                    anchor_envelope.correction_y,
                )
                emission += (
                    anchor_distance / max(0.25, anchor.translation_sigma_m)
                ) ** 2
            values.append(emission)
        candidate_sets.append(candidates)
        candidate_envelopes.append(layer_envelopes)
        emissions.append(values)

    transitions: list[list[list[float]]] = []
    rejected_for_topology = 0
    rejected_for_collision = 0
    for index in range(1, len(candidate_sets)):
        previous_pose = physical_poses[index - 1]
        current_pose = physical_poses[index]
        physical_step = math.hypot(
            float(current_pose.x) - float(previous_pose.x),
            float(current_pose.y) - float(previous_pose.y),
        )
        time_gap = 0.0
        if previous_pose.timestamp is not None and current_pose.timestamp is not None:
            time_gap = max(0.0, float(current_pose.timestamp) - float(previous_pose.timestamp))
        # The map-gauge hint can drift by several metres between neighboring
        # road hypotheses even though physical motion is short.  Keep a hard
        # finite topology bound, but make it wide enough for Viterbi to retain
        # the prior connected route until later absolute evidence resolves the
        # aisle identity.  The quadratic graph/physical distance cost below
        # still strongly prefers walking-scale progress; the bound only avoids
        # deleting the correct hypothesis during accumulated gauge drift.
        maximum_graph_step = max(
            12.0,
            physical_step * 4.0 + 1.0,
            min(12.0, time_gap * 3.0 + 1.0),
        )
        layer: list[list[float]] = []
        for previous_index, previous in enumerate(candidate_sets[index - 1]):
            row: list[float] = []
            previous_correction = (
                candidate_envelopes[index - 1][previous_index].correction_x,
                candidate_envelopes[index - 1][previous_index].correction_y,
            )
            for current_index, current in enumerate(candidate_sets[index]):
                graph_distance = network.distance(previous, current)
                if not math.isfinite(graph_distance) or graph_distance > maximum_graph_step:
                    rejected_for_topology += 1
                    row.append(math.inf)
                    continue
                if obstacle_index.segment_blocked(
                    (previous.x, previous.y), (current.x, current.y)
                ):
                    rejected_for_collision += 1
                    row.append(math.inf)
                    continue
                current_correction = (
                    candidate_envelopes[index][current_index].correction_x,
                    candidate_envelopes[index][current_index].correction_y,
                )
                correction_change = math.hypot(
                    current_correction[0] - previous_correction[0],
                    current_correction[1] - previous_correction[1],
                )
                row.append(
                    0.55 * ((graph_distance - physical_step) / 0.45) ** 2
                    + 0.20 * (correction_change / 0.75) ** 2
                )
            layer.append(row)
        transitions.append(layer)

    forward: list[list[float]] = [list(emissions[0])]
    parents: list[list[int]] = [[-1] * len(candidate_sets[0])]
    for index in range(1, len(candidate_sets)):
        costs: list[float] = []
        links: list[int] = []
        for current_index in range(len(candidate_sets[index])):
            options = [
                (
                    forward[index - 1][previous_index]
                    + transitions[index - 1][previous_index][current_index],
                    previous_index,
                )
                for previous_index in range(len(candidate_sets[index - 1]))
            ]
            best_cost, best_parent = min(options)
            costs.append(best_cost + emissions[index][current_index])
            links.append(best_parent)
        if not any(math.isfinite(value) for value in costs):
            return None
        forward.append(costs)
        parents.append(links)

    selected_indices = [0] * len(candidate_sets)
    selected_indices[-1] = min(
        range(len(forward[-1])), key=forward[-1].__getitem__
    )
    for index in range(len(candidate_sets) - 1, 0, -1):
        selected_indices[index - 1] = parents[index][selected_indices[index]]
    selected = [
        candidate_sets[index][candidate_index]
        for index, candidate_index in enumerate(selected_indices)
    ]

    backward = [[0.0] * len(values) for values in candidate_sets]
    for index in range(len(candidate_sets) - 2, -1, -1):
        for previous_index in range(len(candidate_sets[index])):
            backward[index][previous_index] = min(
                transitions[index][previous_index][current_index]
                + emissions[index + 1][current_index]
                + backward[index + 1][current_index]
                for current_index in range(len(candidate_sets[index + 1]))
            )
    margins: list[float] = []
    for index, selected_index in enumerate(selected_indices):
        totals = [
            forward[index][candidate_index] + backward[index][candidate_index]
            for candidate_index in range(len(candidate_sets[index]))
        ]
        selected_total = totals[selected_index]
        alternatives = [
            value for candidate_index, value in enumerate(totals)
            if candidate_index != selected_index and math.isfinite(value)
        ]
        margins.append(
            math.inf if not alternatives else max(0.0, min(alternatives) - selected_total)
        )

    final_points, geometry_preservation_audit = (
        _preserve_local_geometry_in_selected_corridor(
            selected,
            physical_poses,
            map_hints,
            anchors,
            network,
            obstacle_index,
        )
    )
    poses = [
        RoutePoint(
            x=point[0],
            y=point[1],
            # Corridor direction describes walking topology, not the phone's
            # viewing direction.  Preserve the already optimized phone yaw.
            yaw=_normalize_angle(float(map_hints[index].yaw)),
        )
        for index, point in enumerate(final_points)
    ]

    point_penetrations = sum(obstacle_index.point_blocked(point) for point in final_points)
    crossing_count = sum(
        obstacle_index.segment_blocked(first, second)
        for first, second in zip(final_points, final_points[1:])
    )
    steps = [
        math.hypot(second[0] - first[0], second[1] - first[1])
        for first, second in zip(final_points, final_points[1:])
    ]
    physical_steps = [
        math.hypot(
            float(second.x) - float(first.x),
            float(second.y) - float(first.y),
        )
        for first, second in zip(physical_poses, physical_poses[1:])
    ]
    graph_steps = [
        network.distance(first, second)
        for first, second in zip(selected, selected[1:])
    ]
    topology_discontinuities = sum(not math.isfinite(value) for value in graph_steps)
    intervals = _ambiguity_intervals(
        margins, selected, network, ambiguity_margin
    )
    maximum_distance_scale = float(
        geometry_preservation_audit.get("maximum_distance_scale", 1.0)
    )
    minimum_distance_scale = float(
        geometry_preservation_audit.get("minimum_distance_scale", 1.0)
    )
    maximum_distance_scale_deviation = max(
        abs(maximum_distance_scale - 1.0),
        abs(minimum_distance_scale - 1.0),
    )
    distance_scale_confidence = (
        "low" if maximum_distance_scale_deviation > 0.05 else "high"
    )
    edge_ids = [network.edges[value.edge_index].identifier for value in selected]
    corridor_ids = [network.edges[value.edge_index].corridor_id for value in selected]
    anchor_audit = [
        {
            "identifier": anchor.identifier,
            "index": anchor.index,
            "translation_sigma_m": anchor.translation_sigma_m,
            "matched_distance_m": round(
                math.hypot(
                    final_points[anchor.index][0] - anchor.x,
                    final_points[anchor.index][1] - anchor.y,
                ),
                6,
            ),
        }
        for anchor in anchors
        if 0 <= anchor.index < len(final_points)
    ]
    return RouteMatchResult(
        poses=tuple(poses),
        audit={
            "format": "MarketScannerCorridorRouteMatchAudit",
            "version": 2,
            "matcher": "bounded_free_space_road_hmm_v2",
            "sample_count": len(poses),
            "edge_ids": edge_ids,
            "corridor_ids": corridor_ids,
            "unique_edge_count": len(set(edge_ids)),
            "unique_corridor_count": len(set(corridor_ids)),
            "point_obstacle_penetration_count": point_penetrations,
            "point_obstacle_penetration_ratio": round(
                point_penetrations / max(1, len(final_points)), 9
            ),
            "obstacle_crossing_segment_count": crossing_count,
            "topological_discontinuity_count": topology_discontinuities,
            "maximum_step_m": round(max(steps, default=0.0), 9),
            "maximum_physical_step_m": round(
                max(physical_steps, default=0.0), 9
            ),
            "maximum_step_excess_m": round(
                max(
                    (
                        route_step - physical_step
                        for route_step, physical_step in zip(steps, physical_steps)
                    ),
                    default=0.0,
                ),
                9,
            ),
            "trajectory_length_m": round(sum(steps), 6),
            "physical_trajectory_length_m": round(sum(physical_steps), 6),
            "minimum_path_margin": _finite_margin(min(margins, default=0.0)),
            "ambiguous_sample_count": sum(value < ambiguity_margin for value in margins),
            "ambiguity_intervals": intervals,
            "route_confidence": (
                "low"
                if intervals or distance_scale_confidence == "low"
                else "high"
            ),
            "distance_scale_confidence": distance_scale_confidence,
            "maximum_distance_scale_deviation": round(
                maximum_distance_scale_deviation, 9
            ),
            "anchors": anchor_audit,
            "rejected_transition_count_topology": rejected_for_topology,
            "rejected_transition_count_collision": rejected_for_collision,
            "obstacle_clearance_m": obstacle_clearance_m,
            "search_radius_m": search_radius_m,
            "maximum_candidates": maximum_candidates,
            "geometry_preservation": geometry_preservation_audit,
        },
    )


def match_corridor_route(
    physical_poses: Sequence[Any],
    map_hints: Sequence[Any],
    road_graph: Mapping[str, Any],
    floor_id: str,
    polygons: Sequence[Sequence[tuple[float, float]]],
    anchors: Sequence[RouteAnchor] = (),
    *,
    maximum_candidates: int = 24,
    search_radius_m: float = 15.0,
    obstacle_clearance_m: float = 0.05,
    ambiguity_margin: float = 1.0,
) -> RouteMatchResult | None:
    """Return a connected corridor hypothesis without center-line snapping.

    Viterbi retains global periodic-aisle hypotheses, exact manual-anchor
    evidence and road connectivity.  The selected road sequence supplies only
    corridor identity/topology and a shelf-bounded free-space envelope.  Final
    x/y/yaw preserve the optimized phone trajectory's local geometry; only a
    low-frequency minimum translation field keeps it out of occupied structure
    and distributes exact anchor corrections continuously.  Ambiguous aisle
    identity remains explicit in the audit.
    """

    return _match_projection_route(
        physical_poses,
        map_hints,
        road_graph,
        floor_id,
        polygons,
        anchors,
        maximum_candidates=maximum_candidates,
        search_radius_m=search_radius_m,
        obstacle_clearance_m=obstacle_clearance_m,
        ambiguity_margin=ambiguity_margin,
    )
