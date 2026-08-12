#!/usr/bin/env python3
"""Convert an ``Element Info`` XLSX workbook to a versioned prior-map package."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import shutil
import sys
import tempfile
from collections import Counter, defaultdict, deque
from pathlib import Path
from typing import Any, Iterable, Sequence

if __package__ in {None, ""}:
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
    from PriorMap.coordinate_system import (
        Bounds,
        legacy_center_pivot_rectangle_center,
        legacy_center_pivot_rectangle_polygon,
        merge_bounds,
        polygon_bounds,
        rounded,
        source_point_to_map,
        source_rectangle_center,
        source_rectangle_polygon,
        source_rotation_to_yaw,
    )
    from PriorMap.distance_field import build_distance_fields
    from PriorMap.element_roles import (
        ACTIVE_TYPES,
        ELEMENT_ROLE_CONTRACT_VERSION,
        FIXED_STRUCTURE_TYPES,
        RECTANGLE_TYPES,
        ROLE_PRESENTATION_ONLY,
        ROLE_UNSUPPORTED,
        SHELF_TYPES,
        STRUCTURE_TYPES,
        role_contract_payload,
        role_for,
    )
    from PriorMap.prior_map_schema import (
        PACKAGE_MANIFEST_FILE,
        PACKAGE_FORMAT,
        PACKAGE_VERSION,
        PriorMapValidationError,
        build_package_manifest,
        canonical_safe_name,
        validate_business_identity,
        validate_package,
    )
    from PriorMap.render_prior_map import render_package
    from PriorMap.xlsx_reader import (
        BasicMapInfo,
        WorkbookElement,
        WorkbookError,
        read_workbook,
    )
else:
    from .coordinate_system import (
        Bounds,
        legacy_center_pivot_rectangle_center,
        legacy_center_pivot_rectangle_polygon,
        merge_bounds,
        polygon_bounds,
        rounded,
        source_point_to_map,
        source_rectangle_center,
        source_rectangle_polygon,
        source_rotation_to_yaw,
    )
    from .distance_field import build_distance_fields
    from .element_roles import (
        ACTIVE_TYPES,
        ELEMENT_ROLE_CONTRACT_VERSION,
        FIXED_STRUCTURE_TYPES,
        RECTANGLE_TYPES,
        ROLE_PRESENTATION_ONLY,
        ROLE_UNSUPPORTED,
        SHELF_TYPES,
        STRUCTURE_TYPES,
        role_contract_payload,
        role_for,
    )
    from .prior_map_schema import (
        PACKAGE_MANIFEST_FILE,
        PACKAGE_FORMAT,
        PACKAGE_VERSION,
        PriorMapValidationError,
        build_package_manifest,
        canonical_safe_name,
        validate_business_identity,
        validate_package,
    )
    from .render_prior_map import render_package
    from .xlsx_reader import BasicMapInfo, WorkbookElement, WorkbookError, read_workbook


MAXIMUM_SPATIAL_CELL_ASSIGNMENTS = 8_000_000


class ConversionError(ValueError):
    pass


def _spatial_cell_ranges(
    min_x: float,
    max_x: float,
    min_y: float,
    max_y: float,
    cell_size_m: float,
) -> tuple[range, range, int]:
    values = (min_x, max_x, min_y, max_y, cell_size_m)
    if (
        not all(math.isfinite(value) for value in values)
        or min_x > max_x
        or min_y > max_y
        or cell_size_m <= 0
    ):
        raise ConversionError("Spatial-index bounds are invalid.")
    lower_x = math.floor(min_x / cell_size_m)
    upper_x = math.floor(max_x / cell_size_m)
    lower_y = math.floor(min_y / cell_size_m)
    upper_y = math.floor(max_y / cell_size_m)
    width = upper_x - lower_x + 1
    height = upper_y - lower_y + 1
    assignments = width * height
    if (
        width <= 0
        or height <= 0
        or assignments > MAXIMUM_SPATIAL_CELL_ASSIGNMENTS
    ):
        raise ConversionError("Spatial-index cell assignment budget exceeded.")
    return range(lower_x, upper_x + 1), range(lower_y, upper_y + 1), assignments


def _json_write(path: Path, payload: Any, *, compact: bool = False) -> None:
    path.write_text(
        json.dumps(
            payload,
            ensure_ascii=False,
            indent=None if compact else 2,
            separators=(",", ":") if compact else None,
            sort_keys=True,
        )
        + "\n",
        encoding="utf-8",
    )


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _number(element: dict[str, Any], key: str) -> float:
    value = element.get(key)
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ConversionError(f"{key} must be numeric")
    if not math.isfinite(float(value)):
        raise ConversionError(f"{key} must be finite")
    return float(value)


def _line_geometry(points: Any) -> dict[str, Any]:
    if not isinstance(points, list) or len(points) < 4 or len(points) % 2:
        raise ConversionError("points must contain at least two x/y pairs")
    converted = [
        list(source_point_to_map(float(points[index]), float(points[index + 1])))
        for index in range(0, len(points), 2)
    ]
    return {"type": "line_string", "coordinates": converted}


def _normalized_element(
    record: WorkbookElement,
    warnings: list[dict[str, Any]],
    *,
    legacy_center_pivot: bool = False,
) -> dict[str, Any]:
    raw = record.element
    shape_type = str(raw.get("shapeType") or "Unknown")
    element_role = role_for(shape_type)
    identifier = f"f{record.floor}-r{record.row}"
    visible = raw.get("visible", True) is not False
    geometry: dict[str, Any] | None = None
    bounds: Bounds | None = None
    center: list[float] | None = None
    yaw_rad: float | None = None
    try:
        if shape_type in RECTANGLE_TYPES:
            x = _number(raw, "x")
            y = _number(raw, "y")
            width = _number(raw, "width")
            height = _number(raw, "height")
            rotation = _number(raw, "rotation") if "rotation" in raw else 0.0
            if width <= 0 or height <= 0:
                raise ConversionError("width and height must be positive")
            polygon = (
                legacy_center_pivot_rectangle_polygon(
                    x, y, width, height, rotation
                )
                if legacy_center_pivot
                else source_rectangle_polygon(x, y, width, height, rotation)
            )
            geometry = {"type": "polygon", "coordinates": polygon}
            bounds = polygon_bounds(polygon)
            center = list(
                legacy_center_pivot_rectangle_center(x, y, width, height)
                if legacy_center_pivot
                else source_rectangle_center(x, y, width, height, rotation)
            )
            yaw_rad = source_rotation_to_yaw(rotation)
        elif shape_type == "MapCross":
            geometry = _line_geometry(raw.get("points"))
            bounds = polygon_bounds(geometry["coordinates"])
        elif shape_type == "MapRoadPoint":
            point = list(source_point_to_map(_number(raw, "x"), _number(raw, "y")))
            geometry = {"type": "point", "coordinates": point}
            bounds = Bounds(point[0], point[1], point[0], point[1])
            center = point
        elif element_role == ROLE_UNSUPPORTED:
            warnings.append(
                {
                    "code": "unknown_shape_type",
                    "row": record.row,
                    "floor": record.floor,
                    "shape_type": shape_type,
                    "message": f"发现未知元素类型 {shape_type}；原始数据已保留但不会参与定位。",
                }
            )
    except (ConversionError, TypeError, ValueError) as exc:
        warnings.append(
            {
                "code": "invalid_geometry",
                "row": record.row,
                "floor": record.floor,
                "shape_type": shape_type,
                "message": f"元素几何无效：{exc}；原始数据已保留。",
            }
        )

    if not visible:
        warnings.append(
            {
                "code": "hidden_element",
                "row": record.row,
                "floor": record.floor,
                "shape_type": shape_type,
                "message": "元素 visible=false，已保留并从默认定位索引中排除。",
            }
        )
    normalized: dict[str, Any] = {
        "id": identifier,
        "source_row": record.row,
        "floor_id": str(record.floor),
        "shape_type": shape_type,
        "role": element_role,
        "visible": visible,
        "locked": bool(raw.get("locked", False)),
        "code": str(raw.get("code") or ""),
        "cross_code": str(raw.get("crossCode") or ""),
        "row_flag": str(raw.get("rowFlag") or ""),
        "subsection": raw.get("subsection"),
        "geometry": geometry,
        "source": raw,
    }
    if bounds is not None:
        normalized["bounds"] = bounds.as_dict()
    if center is not None:
        normalized["center_m"] = center
    if yaw_rad is not None:
        normalized["yaw_rad"] = yaw_rad
    return normalized


def _distance(first: Sequence[float], second: Sequence[float]) -> float:
    return math.hypot(float(first[0]) - float(second[0]), float(first[1]) - float(second[1]))


def _polyline_abscissa(point: Sequence[float], polyline: Sequence[Sequence[float]]) -> float:
    """Return arc length at the closest projection onto a possibly bent road."""
    if len(polyline) < 2:
        return 0.0
    best_distance = math.inf
    best_abscissa = 0.0
    accumulated = 0.0
    px, py = float(point[0]), float(point[1])
    for start, end in zip(polyline, polyline[1:]):
        sx, sy = float(start[0]), float(start[1])
        dx, dy = float(end[0]) - sx, float(end[1]) - sy
        length_squared = dx * dx + dy * dy
        if length_squared <= 1.0e-18:
            continue
        ratio = max(0.0, min(1.0, ((px - sx) * dx + (py - sy) * dy) / length_squared))
        projected_x = sx + ratio * dx
        projected_y = sy + ratio * dy
        distance = math.hypot(px - projected_x, py - projected_y)
        segment_length = math.sqrt(length_squared)
        abscissa = accumulated + ratio * segment_length
        if distance < best_distance - 1.0e-12 or (
            abs(distance - best_distance) <= 1.0e-12 and abscissa < best_abscissa
        ):
            best_distance = distance
            best_abscissa = abscissa
        accumulated += segment_length
    return best_abscissa


def _road_graph(
    elements: list[dict[str, Any]],
    warnings: list[dict[str, Any]],
) -> dict[str, Any]:
    crosses: list[dict[str, Any]] = []
    cross_by_key: dict[tuple[str, str], dict[str, Any]] = {}
    for element in elements:
        if element["shape_type"] != "MapCross" or element.get("geometry") is None:
            continue
        code = element["code"] or element["id"]
        coordinates = element["geometry"]["coordinates"]
        key = (element["floor_id"], code)
        graph_id = code
        if key in cross_by_key:
            graph_id = f"{code}@{element['id']}"
            warnings.append(
                {
                    "code": "duplicate_cross_id",
                    "element_id": element["id"],
                    "floor": element["floor_id"],
                    "cross_id": code,
                    "message": f"楼层内道路编号 {code} 重复；道路点仍关联首次出现的道路，重复线已独立保留。",
                }
            )
        cross = {
            "id": graph_id,
            "element_id": element["id"],
            "floor_id": element["floor_id"],
            "points_m": coordinates,
            "width_m": rounded(float(element["source"].get("lineWidth", 0.0)) / 100.0),
        }
        crosses.append(cross)
        if key not in cross_by_key:
            cross_by_key[key] = cross

    nodes: list[dict[str, Any]] = []
    nodes_by_cross: dict[tuple[str, str], list[dict[str, Any]]] = defaultdict(list)
    used_node_ids: set[str] = set()
    for element in elements:
        if element["shape_type"] != "MapRoadPoint" or element.get("geometry") is None:
            continue
        raw_codes = element["source"].get("crossCodes", [])
        if isinstance(raw_codes, (str, int, float)):
            raw_codes = [raw_codes]
        if not isinstance(raw_codes, list):
            raw_codes = []
        cross_codes = [str(value) for value in raw_codes if str(value)]
        preferred_node_id = element["code"] or element["id"]
        node_id = preferred_node_id
        if node_id in used_node_ids:
            node_id = f"{preferred_node_id}@{element['id']}"
            warnings.append(
                {
                    "code": "duplicate_road_point_id",
                    "element_id": element["id"],
                    "floor": element["floor_id"],
                    "road_point_id": preferred_node_id,
                    "message": f"道路点编号 {preferred_node_id} 重复；已分配稳定唯一 ID，节点未丢失。",
                }
            )
        used_node_ids.add(node_id)
        node = {
            "id": node_id,
            "element_id": element["id"],
            "floor_id": element["floor_id"],
            "position_m": element["geometry"]["coordinates"],
            "cross_ids": cross_codes,
            "visible": element["visible"],
        }
        nodes.append(node)
        for code in cross_codes:
            key = (element["floor_id"], code)
            # Some production workbooks intentionally mark every MapCross
            # drawing hidden while keeping visible MapRoadPoint membership in
            # `crossCodes`.  The old active-element filter consequently kept
            # all nodes but deleted every edge.  Always retain membership here;
            # after the complete node inventory is known, a missing line can be
            # deterministically reconstructed from two or more member points.
            nodes_by_cross[key].append(node)
        if not cross_codes:
            warnings.append(
                {
                    "code": "road_point_without_cross",
                    "element_id": element["id"],
                    "floor": element["floor_id"],
                    "message": "道路点没有 crossCodes，已保留为孤立节点。",
                }
            )

    # Reconstruct an omitted/hidden straight road centreline from its visible
    # member points. The active package manifest binds these road points, while
    # hidden MapCross source rows are intentionally excluded. Using hidden
    # geometry directly would make the derived graph impossible for package
    # validators to reproduce until a future topology-source schema binds it.
    for key, cross_nodes in sorted(nodes_by_cross.items()):
        if key in cross_by_key:
            continue
        if len(cross_nodes) < 2:
            node = cross_nodes[0]
            warnings.append(
                {
                    "code": "missing_cross",
                    "element_id": node["element_id"],
                    "floor": key[0],
                    "cross_id": key[1],
                    "message": f"道路点引用了不存在的道路 {key[1]}，且成员不足，无法恢复道路边。",
                }
            )
            continue
        ordered_nodes = sorted(cross_nodes, key=lambda item: str(item["id"]))
        endpoint_pair: tuple[dict[str, Any], dict[str, Any]] | None = None
        endpoint_key: tuple[float, str, str] | None = None
        for index, first in enumerate(ordered_nodes):
            for second in ordered_nodes[index + 1 :]:
                first_id, second_id = sorted((str(first["id"]), str(second["id"])))
                candidate_key = (
                    _distance(first["position_m"], second["position_m"]),
                    first_id,
                    second_id,
                )
                if endpoint_key is None or candidate_key[0] > endpoint_key[0] + 1.0e-12 or (
                    abs(candidate_key[0] - endpoint_key[0]) <= 1.0e-12
                    and candidate_key[1:] < endpoint_key[1:]
                ):
                    endpoint_key = candidate_key
                    endpoint_pair = (first, second)
        if endpoint_pair is None or endpoint_key is None or endpoint_key[0] <= 1.0e-9:
            node = ordered_nodes[0]
            warnings.append(
                {
                    "code": "missing_cross",
                    "element_id": node["element_id"],
                    "floor": key[0],
                    "cross_id": key[1],
                    "message": f"道路 {key[1]} 的成员点全部重合，无法恢复道路边。",
                }
            )
            continue
        first, second = endpoint_pair
        first_point = list(map(float, first["position_m"][:2]))
        second_point = list(map(float, second["position_m"][:2]))
        if (second_point[0], second_point[1], str(second["id"])) < (
            first_point[0], first_point[1], str(first["id"])
        ):
            first_point, second_point = second_point, first_point
        cross = {
            "id": key[1],
            "element_id": "",
            "floor_id": key[0],
            "points_m": [first_point, second_point],
            "width_m": 0.0,
            "provenance": "road_point_membership_v1",
        }
        crosses.append(cross)
        cross_by_key[key] = cross
        warnings.append(
            {
                "code": "road_cross_inferred_from_points",
                "floor": key[0],
                "cross_id": key[1],
                "member_count": len(cross_nodes),
                "message": f"道路 {key[1]} 的线元素不可见或缺失，已由 {len(cross_nodes)} 个可见道路点恢复拓扑。",
            }
        )

    edges_by_key: dict[tuple[str, str], dict[str, Any]] = {}
    for key, cross_nodes in nodes_by_cross.items():
        cross = cross_by_key.get(key)
        if cross is None:
            continue
        ordered = sorted(
            cross_nodes,
            key=lambda item: (
                _polyline_abscissa(item["position_m"], cross["points_m"]),
                item["id"],
            ),
        )
        for first, second in zip(ordered, ordered[1:]):
            if first["id"] == second["id"]:
                continue
            pair = tuple(sorted((str(first["id"]), str(second["id"]))))
            edge_key = (key[0], "|".join(pair))
            length = _distance(first["position_m"], second["position_m"])
            if length <= 1e-9:
                warnings.append(
                    {
                        "code": "zero_length_road_edge",
                        "floor": key[0],
                        "cross_id": key[1],
                        "message": f"道路 {key[1]} 中存在重合道路点，未建立零长度边。",
                    }
                )
                continue
            edge = edges_by_key.setdefault(
                edge_key,
                {
                    "id": f"{key[0]}:{pair[0]}--{pair[1]}",
                    "floor_id": key[0],
                    "from": pair[0],
                    "to": pair[1],
                    "length_m": rounded(length),
                    "cross_ids": [],
                },
            )
            if key[1] not in edge["cross_ids"]:
                edge["cross_ids"].append(key[1])
                edge["cross_ids"].sort()

    edges = sorted(edges_by_key.values(), key=lambda item: item["id"])
    adjacency: dict[str, set[str]] = {str(node["id"]): set() for node in nodes}
    for edge in edges:
        adjacency[str(edge["from"])].add(str(edge["to"]))
        adjacency[str(edge["to"])].add(str(edge["from"]))
    components = 0
    unvisited = set(adjacency)
    while unvisited:
        components += 1
        queue = deque([unvisited.pop()])
        while queue:
            node_id = queue.popleft()
            for neighbour in adjacency[node_id]:
                if neighbour in unvisited:
                    unvisited.remove(neighbour)
                    queue.append(neighbour)
    isolated = sorted(node_id for node_id, neighbours in adjacency.items() if not neighbours)
    return {
        "format": "MarketScannerRoadGraph",
        "version": 1,
        "crosses": sorted(crosses, key=lambda item: (item["floor_id"], item["id"])),
        "nodes": sorted(nodes, key=lambda item: (item["floor_id"], item["id"])),
        "edges": edges,
        "statistics": {
            "cross_count": len(crosses),
            "node_count": len(nodes),
            "edge_count": len(edges),
            "connected_component_count": components,
            "isolated_node_count": len(isolated),
            "isolated_node_ids": isolated,
        },
    }


def _spatial_index(
    elements: list[dict[str, Any]],
    graph: dict[str, Any],
    cell_size_m: float = 5.0,
) -> dict[str, Any]:
    floors: dict[str, dict[str, Any]] = {}
    element_roles: dict[str, dict[str, str]] = {}
    total_assignments = 0
    by_floor: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for element in elements:
        if (
            element["shape_type"] in STRUCTURE_TYPES
            and element.get("visible") is True
            and element.get("bounds") is not None
        ):
            by_floor[element["floor_id"]].append(element)
            element_roles[element["id"]] = {
                "role": element["role"],
                "shape_type": element["shape_type"],
            }
    for floor_id, floor_elements in sorted(by_floor.items()):
        cells: dict[str, list[str]] = defaultdict(list)
        for element in floor_elements:
            bounds = element["bounds"]
            x_cells, y_cells, assignments = _spatial_cell_ranges(
                float(bounds["min_x_m"]),
                float(bounds["max_x_m"]),
                float(bounds["min_y_m"]),
                float(bounds["max_y_m"]),
                cell_size_m,
            )
            total_assignments += assignments
            if total_assignments > MAXIMUM_SPATIAL_CELL_ASSIGNMENTS:
                raise ConversionError("Spatial-index total cell assignment budget exceeded.")
            for cell_x in x_cells:
                for cell_y in y_cells:
                    cells[f"{cell_x},{cell_y}"].append(element["id"])
        floors[floor_id] = {
            "cells": {
                key: sorted(set(value))
                for key, value in sorted(cells.items())
            },
            "road_cells": {},
        }
    node_positions = {
        str(node["id"]): node["position_m"]
        for node in graph.get("nodes", [])
        if isinstance(node, dict) and len(node.get("position_m", [])) >= 2
    }
    road_cells_by_floor: dict[str, dict[str, list[str]]] = defaultdict(
        lambda: defaultdict(list)
    )
    for edge in graph.get("edges", []):
        start = node_positions.get(str(edge.get("from")))
        end = node_positions.get(str(edge.get("to")))
        if start is None or end is None:
            continue
        floor_id = str(edge["floor_id"])
        x_cells, y_cells, assignments = _spatial_cell_ranges(
            min(float(start[0]), float(end[0])),
            max(float(start[0]), float(end[0])),
            min(float(start[1]), float(end[1])),
            max(float(start[1]), float(end[1])),
            cell_size_m,
        )
        total_assignments += assignments
        if total_assignments > MAXIMUM_SPATIAL_CELL_ASSIGNMENTS:
            raise ConversionError("Spatial-index total cell assignment budget exceeded.")
        for cell_x in x_cells:
            for cell_y in y_cells:
                road_cells_by_floor[floor_id][f"{cell_x},{cell_y}"].append(
                    str(edge["id"])
                )
    for floor_id, road_cells in sorted(road_cells_by_floor.items()):
        floor = floors.setdefault(floor_id, {"cells": {}, "road_cells": {}})
        floor["road_cells"] = {
            key: sorted(set(value))
            for key, value in sorted(road_cells.items())
        }
    return {
        "format": "MarketScannerSpatialIndex",
        "version": 1,
        "cell_size_m": cell_size_m,
        "element_roles": dict(sorted(element_roles.items())),
        "floors": floors,
    }


def _floor_bounds(elements: list[dict[str, Any]]) -> list[dict[str, Any]]:
    grouped: dict[str, list[Bounds]] = defaultdict(list)
    for element in elements:
        value = element.get("bounds")
        if value is not None:
            grouped[element["floor_id"]].append(
                Bounds(
                    float(value["min_x_m"]),
                    float(value["min_y_m"]),
                    float(value["max_x_m"]),
                    float(value["max_y_m"]),
                )
            )
    return [
        {"id": floor_id, "bounds": merge_bounds(bounds).as_dict()}
        for floor_id, bounds in sorted(grouped.items(), key=lambda item: item[0])
    ]


def _canvas_bounds(basic_info: BasicMapInfo) -> Bounds:
    return Bounds(
        0.0,
        rounded(-basic_info.height_cm / 100.0),
        rounded(basic_info.width_cm / 100.0),
        0.0,
    )


def _official_source_id(element: dict[str, Any]) -> str | None:
    source = element.get("source")
    if not isinstance(source, dict):
        return None
    for key in ("sourceId", "source_id", "id"):
        value = source.get(key)
        if isinstance(value, str) and value:
            return value
        if key == "id" and isinstance(value, int) and not isinstance(value, bool):
            return str(value)
    return None


def _stable_element_id(
    element: dict[str, Any],
    basic_info: BasicMapInfo,
) -> str:
    return _stable_element_id_for_context(
        element,
        store_id=basic_info.store_code,
        map_name=basic_info.map_name,
    )


def _stable_element_id_for_context(
    element: dict[str, Any],
    *,
    store_id: str,
    map_name: str,
) -> str:
    official = _official_source_id(element)
    if official is not None:
        return official
    identity: dict[str, Any] = {
        "shape_type": element["shape_type"],
        "floor_id": element["floor_id"],
        "code": element["code"],
        "cross_code": element["cross_code"],
    }
    for name in ("geometry", "bounds", "center_m", "yaw_rad"):
        if name in element and element[name] is not None:
            identity[name] = element[name]
    context = {
        "store_id": store_id,
        "map_name": map_name,
        "identity": identity,
    }
    encoded = json.dumps(
        context,
        ensure_ascii=False,
        separators=(",", ":"),
        sort_keys=True,
        allow_nan=False,
    ).encode("utf-8")
    return "e-" + hashlib.sha256(encoded).hexdigest()[:20]


def _require_unique_stable_element_ids(
    elements: Sequence[dict[str, Any]],
    *,
    store_id: str,
    map_name: str,
) -> None:
    """Reject duplicate business identities before canonical/package output.

    The row-scoped ``f<floor>-r<row>`` identifier is only an import audit
    handle.  Production identity is the official source id when present, or
    the same store/map/business hash used by the mobile importer.  Letting two
    rows share that identity would make canonical ordering and shelf
    association ambiguous even if their row handles differ.
    """

    seen: dict[str, dict[str, Any]] = {}
    for element in elements:
        stable_id = _stable_element_id_for_context(
            element,
            store_id=store_id,
            map_name=map_name,
        )
        previous = seen.get(stable_id)
        if previous is not None:
            raise ConversionError(
                "Duplicate business element identity "
                f"{stable_id!r} at Element Info rows "
                f"{previous.get('source_row')} and {element.get('source_row')}; "
                "strict production import is fail-closed."
            )
        seen[stable_id] = element


def _compiled_shelf_segments(
    shelves: Sequence[dict[str, Any]],
) -> list[dict[str, Any]]:
    """Build the shelves-v2 direction contract used by the mobile compiler.

    Business yaw is authoritative.  The longest explicit polygon edge is
    used only to create a deterministic segment when yaw is unavailable; the
    provenance remains ``unavailable`` so downstream quality gates cannot
    treat that fallback as explicit business-side evidence.
    """

    segments: list[dict[str, Any]] = []
    for element in shelves:
        geometry = element.get("geometry")
        raw_coordinates = (
            geometry.get("coordinates") if isinstance(geometry, dict) else None
        )
        if (
            not isinstance(raw_coordinates, list)
            or len(raw_coordinates) < 3
            or not all(
                isinstance(point, list)
                and len(point) >= 2
                and isinstance(point[0], (int, float))
                and not isinstance(point[0], bool)
                and isinstance(point[1], (int, float))
                and not isinstance(point[1], bool)
                and math.isfinite(float(point[0]))
                and math.isfinite(float(point[1]))
                for point in raw_coordinates
            )
        ):
            raise ConversionError(
                f"Shelf {element.get('id')} is missing finite polygon geometry."
            )
        points = [(float(point[0]), float(point[1])) for point in raw_coordinates]
        center_x = sum(point[0] for point in points) / len(points)
        center_y = sum(point[1] for point in points) / len(points)

        yaw = element.get("yaw_rad")
        if (
            isinstance(yaw, (int, float))
            and not isinstance(yaw, bool)
            and math.isfinite(float(yaw))
        ):
            axis = (math.cos(float(yaw)), math.sin(float(yaw)))
            provenance = "element_yaw"
        else:
            longest_length = 0.0
            axis = (1.0, 0.0)
            for index, point in enumerate(points):
                following = points[(index + 1) % len(points)]
                dx = following[0] - point[0]
                dy = following[1] - point[1]
                length = math.hypot(dx, dy)
                if length > longest_length:
                    longest_length = length
                    axis = (dx / length, dy / length)
            if longest_length <= 1.0e-9:
                raise ConversionError(
                    f"Shelf {element.get('id')} polygon has no nonzero edge."
                )
            provenance = "unavailable"

        projections = [
            (point[0] - center_x) * axis[0]
            + (point[1] - center_y) * axis[1]
            for point in points
        ]
        minimum_projection = min(projections)
        maximum_projection = max(projections)
        start = [
            center_x + minimum_projection * axis[0],
            center_y + minimum_projection * axis[1],
        ]
        end = [
            center_x + maximum_projection * axis[0],
            center_y + maximum_projection * axis[1],
        ]
        segments.append(
            {
                "shelf_segment_id": element["id"],
                "shelf_code": element["code"],
                "floor_id": element["floor_id"],
                "longitudinal_start_m": start,
                "longitudinal_end_m": end,
                "longitudinal_axis": [axis[0], axis[1]],
                "front_normal": [axis[1], -axis[0]],
                "back_normal": [-axis[1], axis[0]],
                "side_semantics_version": 1,
                "orientation_provenance": provenance,
            }
        )
    return segments


def _canonical_business_element(
    element: dict[str, Any],
    basic_info: BasicMapInfo,
) -> dict[str, Any]:
    payload: dict[str, Any] = {
        "id": _stable_element_id(element, basic_info),
        "floor_id": element["floor_id"],
        "shape_type": element["shape_type"],
        "visible": element["visible"],
        "locked": element["locked"],
        "code": element["code"],
        "cross_code": element["cross_code"],
        "row_flag": element["row_flag"],
        "subsection": element["subsection"],
    }
    for name in ("geometry", "bounds", "center_m", "yaw_rad"):
        if name in element and element[name] is not None:
            payload[name] = element[name]
    return payload


def _canonical_business_sha256(
    basic_info: BasicMapInfo,
    elements: list[dict[str, Any]],
) -> str:
    ordered = sorted(
        (_canonical_business_element(element, basic_info) for element in elements),
        key=lambda value: (
            str(value["id"]),
            json.dumps(
                value,
                ensure_ascii=False,
                separators=(",", ":"),
                sort_keys=True,
                allow_nan=False,
            ),
        ),
    )
    payload = {
        "format": "MarketScannerPriorMapSource",
        "version": 3,
        "store_id": basic_info.store_code,
        "map_name": basic_info.map_name,
        "source_map_info": basic_info.canonical_payload(),
        "coordinate_contract": {
            "unit": "centimetre",
            "origin": "top_left",
            "x_axis": "right",
            "y_axis": "down",
            "rotation_direction": "clockwise_degrees",
            "rectangle_anchor": "top_left",
            "rotation_pivot": "top_left_anchor",
        },
        "role_contract": {
            "version": ELEMENT_ROLE_CONTRACT_VERSION,
            "presentation_policy": "excluded_from_production_elements",
        },
        "elements": ordered,
    }
    canonical = json.dumps(
        payload,
        ensure_ascii=False,
        separators=(",", ":"),
        sort_keys=True,
        allow_nan=False,
    ).encode("utf-8")
    return hashlib.sha256(canonical).hexdigest()


def _geometry_inside_bounds(
    element: dict[str, Any],
    bounds: Bounds,
    tolerance: float = 1.0e-8,
) -> bool:
    geometry = element.get("geometry")
    if not isinstance(geometry, dict):
        return False
    coordinates = geometry.get("coordinates")
    if geometry.get("type") == "point":
        coordinates = [coordinates]
    if not isinstance(coordinates, list) or not coordinates:
        return False
    for point in coordinates:
        if not isinstance(point, list) or len(point) < 2:
            return False
        x, y = float(point[0]), float(point[1])
        if (
            x < bounds.min_x_m - tolerance
            or x > bounds.max_x_m + tolerance
            or y < bounds.min_y_m - tolerance
            or y > bounds.max_y_m + tolerance
        ):
            return False
    return True


def convert_workbook(
    source: Path | str,
    output: Path | str | None = None,
    map_name: str | None = None,
    store_id: str | None = None,
    *,
    allow_legacy_element_only: bool = False,
) -> Path:
    source_path = Path(source).resolve()
    result = read_workbook(
        source_path,
        allow_legacy_element_only=allow_legacy_element_only,
    )
    basic_info = result.basic_info
    if basic_info is not None and result.malformed_rows:
        first = result.malformed_rows[0]
        raise ConversionError(
            "Standard Basic Info + Element Info workbooks reject every "
            "malformed Element Info row; "
            f"row {first.get('row')} ({first.get('code', 'malformed_row')}): "
            f"{first.get('message', 'invalid row')}"
        )
    if basic_info is not None:
        if store_id is not None and store_id != basic_info.store_code:
            raise ConversionError(
                "--store-id must exactly match Basic Info.storeCode; "
                "the workbook is authoritative."
            )
        if map_name is not None and map_name != basic_info.map_name:
            raise ConversionError(
                "--name must exactly match Basic Info.map_name; "
                "the workbook is authoritative."
            )
        resolved_store_id = basic_info.store_code
        resolved_map_name = basic_info.map_name
    else:
        if not allow_legacy_element_only:
            raise ConversionError("Basic Info is required for the standard workbook format.")
        resolved_store_id = store_id
        resolved_map_name = str(map_name or source_path.stem)
    try:
        validate_business_identity(resolved_store_id, resolved_map_name)
    except PriorMapValidationError as exc:
        raise ConversionError(str(exc)) from exc
    source_hash = _sha256(source_path)
    warnings = list(result.warnings)
    source_elements = [
        _normalized_element(
            item,
            warnings,
            legacy_center_pivot=basic_info is None,
        )
        for item in result.elements
    ]
    ignored_by_shape_type = Counter(
        item["shape_type"]
        for item in source_elements
        if item["role"] == ROLE_PRESENTATION_ONLY
    )
    unsupported_ignored_count = sum(
        item["role"] == ROLE_UNSUPPORTED for item in source_elements
    )
    hidden_element_count = sum(
        item["shape_type"] in ACTIVE_TYPES and item["visible"] is False
        for item in source_elements
    )
    invalid_geometry_ignored_count = sum(
        item["shape_type"] in ACTIVE_TYPES
        and item["visible"] is True
        and item.get("geometry") is None
        for item in source_elements
    )
    if invalid_geometry_ignored_count:
        first = next(
            item
            for item in source_elements
            if item["shape_type"] in ACTIVE_TYPES
            and item["visible"] is True
            and item.get("geometry") is None
        )
        raise ConversionError(
            f"Active element {first['id']} ({first['shape_type']}) has invalid geometry; "
            "strict production import is fail-closed."
        )
    if ignored_by_shape_type:
        warnings.append(
            {
                "code": "presentation_only_element_ignored",
                "count": sum(ignored_by_shape_type.values()),
                "by_shape_type": dict(sorted(ignored_by_shape_type.items())),
                "message": (
                    f"已自动忽略 {sum(ignored_by_shape_type.values())} 个仅用于源地图展示的元素。"
                ),
            }
        )
    if result.legacy_shelf_info.present:
        warnings.append(
            {
                "code": "legacy_shelf_info_ignored",
                "count": result.legacy_shelf_info.row_count,
                "message": (
                    "Shelf Info 是历史冗余投影，已审计但不参与几何、业务身份或 canonical hash。"
                ),
            }
        )
    elements = [
        item
        for item in source_elements
        if item["role"] not in {ROLE_PRESENTATION_ONLY, ROLE_UNSUPPORTED}
        and item["shape_type"] in ACTIVE_TYPES
        and item["visible"] is True
        and item.get("geometry") is not None
    ]
    assert isinstance(resolved_store_id, str)
    _require_unique_stable_element_ids(
        elements,
        store_id=resolved_store_id,
        map_name=resolved_map_name,
    )
    counts = Counter(item["shape_type"] for item in elements)
    floor_ids = sorted({str(item["floor_id"]) for item in elements})
    if basic_info is not None:
        canvas_bounds = _canvas_bounds(basic_info)
        for element in elements:
            if not _geometry_inside_bounds(element, canvas_bounds):
                raise ConversionError(
                    f"Active element {element['id']} ({element['shape_type']}) "
                    "falls outside the authoritative Basic Info canvas."
                )
        floors = [
            {"id": floor_id, "bounds": canvas_bounds.as_dict()}
            for floor_id in floor_ids
        ]
    else:
        floors = _floor_bounds(elements)
    if not floors:
        raise ConversionError("No valid geometry was found in the workbook.")
    for index, floor in enumerate(floors):
        safe_floor = canonical_safe_name(floor["id"], fallback="floor")
        floor["preview_file"] = f"preview_floor_{index + 1:03d}_{safe_floor}.png"
    if basic_info is not None:
        canonical_source_hash = _canonical_business_sha256(basic_info, elements)
        base_name = canonical_safe_name(resolved_map_name)
        prior_map_id = f"{base_name}-{canonical_source_hash[:12]}"
    else:
        canonical_source_hash = None
        base_name = canonical_safe_name(source_path.stem)
        prior_map_id = f"{base_name}-{source_hash[:12]}"
    output_path = (
        Path(output).resolve()
        if output is not None
        else source_path.parent / f"PriorMap-{prior_map_id}"
    )
    if output_path.exists():
        if not output_path.is_dir() or any(output_path.iterdir()):
            raise ConversionError(f"Output directory must not exist or must be empty: {output_path}")
        output_path.rmdir()
    output_path.parent.mkdir(parents=True, exist_ok=True)

    temporary = Path(
        tempfile.mkdtemp(prefix=f".{output_path.name}.", dir=str(output_path.parent))
    )
    try:
        formal_workbook = result.basic_info is not None
        manifest: dict[str, Any] = {
            "format": PACKAGE_FORMAT,
            "version": PACKAGE_VERSION if formal_workbook else 1,
            "prior_map_id": prior_map_id,
            "store_id": resolved_store_id,
            "name": resolved_map_name,
            "source_file": source_path.name,
            "source_sha256": source_hash,
            "source_coordinate_system": {
                "unit": "centimetre",
                "origin": "top_left",
                "x_axis": "right",
                "y_axis": "down",
                "rotation_direction": "clockwise_degrees",
                "rectangle_anchor": (
                    "top_left" if formal_workbook
                    else "top_left_rotated_about_center"
                ),
                "rotation_pivot": (
                    "top_left_anchor" if formal_workbook else "rectangle_center"
                ),
            },
            "map_coordinate_system": {
                "unit": "metre",
                "origin": "source_origin",
                "x_axis": "right",
                "y_axis": "up",
                "yaw": "counter_clockwise_radians",
                "transform": "x_m=x_cm/100; y_m=-y_cm/100; yaw_rad=-rotation_deg*pi/180",
            },
            "localization_scope": {
                "floor_mode": "single_floor_per_scan",
                "cross_floor_switching": False,
                "vertical_motion": "ignored_in_prior_map_2d_preserved_in_raw_3d",
            },
            "floors": floors,
            "bounds": merge_bounds(
                Bounds(
                    floor["bounds"]["min_x_m"],
                    floor["bounds"]["min_y_m"],
                    floor["bounds"]["max_x_m"],
                    floor["bounds"]["max_y_m"],
                )
                for floor in floors
            ).as_dict(),
            "element_statistics": dict(sorted(counts.items())),
            "element_count": len(elements),
            "visible_element_count": len(elements),
            "hidden_element_count": hidden_element_count if formal_workbook else 0,
            "warning_count": len(warnings) + len(result.malformed_rows),
        }
        if formal_workbook:
            assert basic_info is not None
            assert canonical_source_hash is not None
            manifest.update(
                {
                    "canonical_source_sha256": canonical_source_hash,
                    "source_canvas": {
                        "width_cm": basic_info.width_cm,
                        "height_cm": basic_info.height_cm,
                        "source_scale": basic_info.source_scale,
                    },
                    "source_map_info": basic_info.canonical_payload(),
                    "element_role_contract": role_contract_payload(),
                    "source_element_count": len(source_elements),
                    "active_element_count": len(elements),
                    "shelf_count": sum(
                        item["role"] == "shelf" for item in elements
                    ),
                    "fixed_structure_count": sum(
                        item["role"] == "fixed_structure" for item in elements
                    ),
                    "road_element_count": sum(
                        item["role"] == "road" for item in elements
                    ),
                    "presentation_ignored_count": sum(
                        ignored_by_shape_type.values()
                    ),
                    "unsupported_ignored_count": unsupported_ignored_count,
                    "invalid_geometry_ignored_count": invalid_geometry_ignored_count,
                    "ignored_by_shape_type": dict(
                        sorted(ignored_by_shape_type.items())
                    ),
                    "legacy_shelf_info": {
                        "present": result.legacy_shelf_info.present,
                        "row_count": result.legacy_shelf_info.row_count,
                        "authority": False,
                    },
                }
            )
        graph = _road_graph(elements, warnings)
        manifest["warning_count"] = len(warnings) + len(result.malformed_rows)
        distance_fields = build_distance_fields(elements, floors)
        spatial = _spatial_index(elements, graph)
        manifest["distance_fields"] = {
            "file": "distance_fields.json",
            "format": distance_fields["format"],
            "version": distance_fields["version"],
            "resolutions_m": [
                level["resolution_m"]
                for level in next(iter(distance_fields["floors"].values()))["levels"]
            ],
            "truncation_distance_m": distance_fields["truncation_distance_m"],
        }
        shelves = [item for item in elements if item["shape_type"] in SHELF_TYPES]
        fixed = [
            item
            for item in elements
            if item["shape_type"] in FIXED_STRUCTURE_TYPES
        ]
        _json_write(temporary / "manifest.json", manifest)
        _json_write(
            temporary / "elements.json",
            {"format": "MarketScannerPriorMapElements", "version": 1, "elements": elements},
        )
        shelves_payload: dict[str, Any] = {
            "format": "MarketScannerPriorMapShelves",
            "version": 2 if formal_workbook else 1,
            "shelves": shelves,
        }
        if formal_workbook:
            shelves_payload["shelf_segments"] = _compiled_shelf_segments(shelves)
        _json_write(temporary / "shelves.json", shelves_payload)
        _json_write(
            temporary / "fixed_structures.json",
            {"format": "MarketScannerPriorMapStructures", "version": 1, "structures": fixed},
        )
        _json_write(temporary / "road_graph.json", graph)
        _json_write(temporary / "spatial_index.json", spatial)
        # Distance rows are already RLE-compressed. Pretty-printing every
        # integer expands a two-floor production package by tens of MB, so
        # keep this deterministic payload compact for mobile transfer.
        _json_write(
            temporary / "distance_fields.json",
            distance_fields,
            compact=True,
        )
        validation_report = {
            "format": "MarketScannerPriorMapValidation",
            "version": 1,
            "valid": True,
            "summary": {
                "element_count": len(elements),
                "source_element_count": len(source_elements),
                "active_element_count": len(elements),
                "shelf_count": len(shelves),
                "fixed_structure_count": len(fixed),
                "road_element_count": sum(item["role"] == "road" for item in elements),
                "presentation_ignored_count": sum(ignored_by_shape_type.values()),
                "unsupported_ignored_count": unsupported_ignored_count,
                "hidden_element_count": hidden_element_count,
                "invalid_geometry_ignored_count": invalid_geometry_ignored_count,
                "malformed_row_count": len(result.malformed_rows),
                "warning_count": len(warnings) + len(result.malformed_rows),
                "floor_count": len(floors),
                **graph["statistics"],
            },
            "warnings": warnings,
            "malformed_rows": result.malformed_rows,
        }
        _json_write(temporary / "validation_report.json", validation_report)
        render_package(temporary)
        for floor in floors:
            render_package(
                temporary,
                temporary / str(floor["preview_file"]),
                str(floor["id"]),
            )
        _json_write(
            temporary / PACKAGE_MANIFEST_FILE,
            build_package_manifest(temporary),
        )
        package_validation = validate_package(temporary)
        if not package_validation["valid"]:
            raise ConversionError(
                "Generated package failed validation: "
                + "; ".join(item["message"] for item in package_validation["errors"])
            )
        temporary.rename(output_path)
    except Exception:
        shutil.rmtree(temporary, ignore_errors=True)
        raise
    return output_path


def main(argv: Iterable[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Convert a standard Basic Info + Element Info XLSX workbook to a MarketScanner prior-map package."
    )
    parser.add_argument("xlsx", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--name")
    parser.add_argument("--store-id")
    parser.add_argument(
        "--allow-legacy-element-only",
        action="store_true",
        help="Explicitly import a legacy workbook without Basic Info.",
    )
    args = parser.parse_args(argv)
    try:
        output = convert_workbook(
            args.xlsx,
            args.output,
            map_name=args.name,
            store_id=args.store_id,
            allow_legacy_element_only=args.allow_legacy_element_only,
        )
    except (WorkbookError, ConversionError, OSError) as exc:
        parser.error(str(exc))
    print(output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
