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


def _normalize_angle(value: float) -> float:
    while value > math.pi:
        value -= 2.0 * math.pi
    while value <= -math.pi:
        value += 2.0 * math.pi
    return value


def _finite_margin(value: float) -> float | None:
    return round(value, 6) if math.isfinite(value) else None


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
        widths = {
            str(item.get("id")): max(0.2, float(item.get("width_m", 1.0) or 1.0))
            for item in road_graph.get("crosses", ())
            if isinstance(item, Mapping) and str(item.get("floor_id")) == floor_id
        }
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
            width = max((widths.get(value, 1.0) for value in cross_ids), default=1.0)
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
        self._node_path_cache: dict[tuple[int, int], tuple[int, ...]] = {}

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

    def _node_path(self, source: int, target: int) -> tuple[int, ...]:
        if source == target:
            return (source,)
        key = (source, target)
        cached = self._node_path_cache.get(key)
        if cached is not None:
            return cached
        distances = [math.inf] * len(self.node_ids)
        parents = [-1] * len(self.node_ids)
        distances[source] = 0.0
        queue = [(0.0, source)]
        while queue:
            distance, node = heapq.heappop(queue)
            if distance != distances[node]:
                continue
            if node == target:
                break
            for neighbor, length in self.adjacency[node]:
                candidate = distance + length
                if candidate < distances[neighbor]:
                    distances[neighbor] = candidate
                    parents[neighbor] = node
                    heapq.heappush(queue, (candidate, neighbor))
        if parents[target] < 0:
            return ()
        path = [target]
        while path[-1] != source:
            path.append(parents[path[-1]])
        path.reverse()
        result = tuple(path)
        self._node_path_cache[key] = result
        self._node_path_cache[(target, source)] = tuple(reversed(result))
        return result

    def polyline(self, first: _Candidate, second: _Candidate) -> tuple[tuple[float, float], ...]:
        first_point = (first.x, first.y)
        second_point = (second.x, second.y)
        if first.edge_index == second.edge_index:
            return (first_point, second_point)
        first_edge = self.edges[first.edge_index]
        second_edge = self.edges[second.edge_index]
        first_endpoints = (
            (first_edge.first_node, first.fraction * first_edge.length),
            (first_edge.second_node, (1.0 - first.fraction) * first_edge.length),
        )
        second_endpoints = (
            (second_edge.first_node, second.fraction * second_edge.length),
            (second_edge.second_node, (1.0 - second.fraction) * second_edge.length),
        )
        endpoint_options = [
            (
                first_node,
                first_offset,
                second_node,
                second_offset,
            )
            for first_node, first_offset in first_endpoints
            for second_node, second_offset in second_endpoints
            if math.isfinite(self.shortest[first_node][second_node])
        ]
        first_node, _first_offset, second_node, _second_offset = min(
            endpoint_options,
            key=lambda value: (
                value[1] + self.shortest[value[0]][value[2]] + value[3]
            ),
        )
        node_path = self._node_path(first_node, second_node)
        values = [first_point]
        values.extend(self.positions[node] for node in node_path)
        values.append(second_point)
        compact: list[tuple[float, float]] = []
        for value in values:
            if not compact or math.hypot(
                value[0] - compact[-1][0], value[1] - compact[-1][1]
            ) > 1.0e-8:
                compact.append(value)
        return tuple(compact)

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


def _point_at_distance(
    polyline: Sequence[tuple[float, float]],
    cumulative: Sequence[float],
    distance: float,
) -> tuple[float, float]:
    if not polyline:
        return (0.0, 0.0)
    if distance <= 0.0:
        return polyline[0]
    if distance >= cumulative[-1]:
        return polyline[-1]
    for index in range(1, len(cumulative)):
        if cumulative[index] < distance:
            continue
        first_distance = cumulative[index - 1]
        segment_length = cumulative[index] - first_distance
        if segment_length <= 1.0e-12:
            return polyline[index]
        fraction = (distance - first_distance) / segment_length
        return (
            polyline[index - 1][0]
            + fraction * (polyline[index][0] - polyline[index - 1][0]),
            polyline[index - 1][1]
            + fraction * (polyline[index][1] - polyline[index - 1][1]),
        )


def _physical_cumulative(poses: Sequence[Any]) -> tuple[float, ...]:
    values = [0.0]
    for first, second in zip(poses, poses[1:]):
        values.append(values[-1] + math.hypot(
            float(second.x) - float(first.x),
            float(second.y) - float(first.y),
        ))
    return tuple(values)


def _reparameterize_selected_route(
    selected: Sequence[_Candidate],
    physical_poses: Sequence[Any],
    anchors: Sequence[RouteAnchor],
    network: _RoadNetwork,
    obstacle_index: ObstacleIndex,
) -> tuple[list[tuple[float, float]], dict[str, Any]] | None:
    """Replace projection jumps with physical-distance progress on the route."""

    boundaries = [0]
    boundaries.extend(
        sorted(
            {
                anchor.index
                for anchor in anchors
                if 0 < anchor.index < len(selected) - 1
            }
        )
    )
    boundaries.append(len(selected) - 1)
    physical_distance = _physical_cumulative(physical_poses)
    route_polyline: list[tuple[float, float]] = [
        (selected[0].x, selected[0].y)
    ]
    route_cumulative = [0.0]
    selected_route_distances = [0.0]
    for first, second in zip(selected, selected[1:]):
        connection = network.polyline(first, second)
        if len(connection) < 2:
            selected_route_distances.append(route_cumulative[-1])
            continue
        for point in connection[1:]:
            previous = route_polyline[-1]
            distance = math.hypot(point[0] - previous[0], point[1] - previous[1])
            if distance <= 1.0e-9:
                continue
            route_polyline.append(point)
            route_cumulative.append(route_cumulative[-1] + distance)
        selected_route_distances.append(route_cumulative[-1])
    final_points: list[tuple[float, float] | None] = [None] * len(selected)
    segment_audit: list[dict[str, Any]] = []
    for first_index, second_index in zip(boundaries, boundaries[1:]):
        route_start = selected_route_distances[first_index]
        route_end = selected_route_distances[second_index]
        route_length = route_end - route_start
        physical_length = (
            physical_distance[second_index] - physical_distance[first_index]
        )
        if route_length <= 1.0e-9 or physical_length <= 1.0e-9:
            return None
        scale = route_length / physical_length
        for index in range(first_index, second_index + 1):
            relative = physical_distance[index] - physical_distance[first_index]
            final_points[index] = _point_at_distance(
                route_polyline,
                route_cumulative,
                route_start + relative * scale,
            )
        segment_audit.append(
            {
                "start_index": first_index,
                "end_index": second_index,
                "route_length_m": round(route_length, 6),
                "physical_length_m": round(physical_length, 6),
                "distance_scale": round(scale, 9),
            }
        )
    if any(point is None for point in final_points):
        return None
    resolved = [point for point in final_points if point is not None]
    return resolved, {
        "method": "physical_cumulative_distance_piecewise_anchor_v1",
        "segments": segment_audit,
        "selected_route_length_m": round(route_cumulative[-1], 6),
        "maximum_distance_scale": round(
            max((value["distance_scale"] for value in segment_audit), default=1.0),
            9,
        ),
        "minimum_distance_scale": round(
            min((value["distance_scale"] for value in segment_audit), default=1.0),
            9,
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
    candidate_sets: list[list[_Candidate]] = []
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
        for candidate in candidates:
            edge = network.edges[candidate.edge_index]
            outside = max(0.0, candidate.hint_distance - edge.width / 2.0)
            emission = (outside / 1.5) ** 2 + 0.10 * (
                candidate.hint_distance / (edge.width / 2.0 + 1.0)
            ) ** 2
            if travel_heading is not None and tangent_distance >= 0.75:
                heading_residual = _axis_residual(candidate.heading, travel_heading)
                emission += 0.45 * (heading_residual / math.radians(18.0)) ** 2
            if index == 0:
                emission += (candidate.hint_distance / 0.45) ** 2
            if anchor is not None:
                anchor_distance = math.hypot(candidate.x - anchor.x, candidate.y - anchor.y)
                emission += (anchor_distance / max(0.25, anchor.translation_sigma_m)) ** 2
            values.append(emission)
        candidate_sets.append(candidates)
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
        for previous in candidate_sets[index - 1]:
            row: list[float] = []
            previous_hint = map_hints[index - 1]
            previous_correction = (
                previous.x - float(previous_hint.x),
                previous.y - float(previous_hint.y),
            )
            for current in candidate_sets[index]:
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
                current_hint = map_hints[index]
                current_correction = (
                    current.x - float(current_hint.x),
                    current.y - float(current_hint.y),
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

    reparameterized = _reparameterize_selected_route(
        selected, physical_poses, anchors, network, obstacle_index
    )
    if reparameterized is None:
        return None
    center_points, reparameterization_audit = reparameterized
    final_points = list(center_points)

    route_headings: list[float | None] = []
    physical_headings: list[float | None] = []
    for index in range(len(final_points)):
        left = max(0, index - 2)
        right = min(len(final_points) - 1, index + 2)
        route_dx = final_points[right][0] - final_points[left][0]
        route_dy = final_points[right][1] - final_points[left][1]
        physical_dx = float(physical_poses[right].x) - float(physical_poses[left].x)
        physical_dy = float(physical_poses[right].y) - float(physical_poses[left].y)
        route_headings.append(
            math.atan2(route_dy, route_dx)
            if math.hypot(route_dx, route_dy) >= 0.20
            else None
        )
        physical_headings.append(
            math.atan2(physical_dy, physical_dx)
            if math.hypot(physical_dx, physical_dy) >= 0.20
            else None
        )
    poses: list[RoutePoint] = []
    previous_delta = 0.0
    for index, point in enumerate(final_points):
        if route_headings[index] is not None and physical_headings[index] is not None:
            delta = _normalize_angle(route_headings[index] - physical_headings[index])
            previous_delta = delta
        else:
            delta = previous_delta
        poses.append(
            RoutePoint(
                x=point[0],
                y=point[1],
                yaw=_normalize_angle(float(physical_poses[index].yaw) + delta),
            )
        )

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
        reparameterization_audit.get("maximum_distance_scale", 1.0)
    )
    minimum_distance_scale = float(
        reparameterization_audit.get("minimum_distance_scale", 1.0)
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
            "version": 1,
            "matcher": "bounded_free_space_road_hmm_v1",
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
            "reparameterization": reparameterization_audit,
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
    """Return a connected, collision-free, physical-distance route draft.

    The full Viterbi projection pass retains global periodic-aisle hypotheses
    and exact manual-anchor evidence.  Its selected road visit sequence is then
    reparameterized by gauge-neutral physical cumulative distance, removing
    projection jumps without collapsing loops or U-turns to endpoint shortest
    paths.  Ambiguous aisle identity remains explicit in the audit.
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
