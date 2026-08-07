#!/usr/bin/env python3
"""Convert an ``Element Info`` XLSX workbook to a versioned prior-map package."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import re
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
        merge_bounds,
        polygon_bounds,
        rounded,
        source_point_to_map,
        source_rectangle_polygon,
        source_rotation_to_yaw,
    )
    from PriorMap.distance_field import build_distance_fields
    from PriorMap.prior_map_schema import (
        PACKAGE_MANIFEST_FILE,
        PACKAGE_FORMAT,
        PACKAGE_VERSION,
        PriorMapValidationError,
        SUPPORTED_TYPES,
        build_package_manifest,
        validate_business_identity,
        validate_package,
    )
    from PriorMap.render_prior_map import render_package
    from PriorMap.xlsx_reader import WorkbookElement, WorkbookError, read_element_info
else:
    from .coordinate_system import (
        Bounds,
        merge_bounds,
        polygon_bounds,
        rounded,
        source_point_to_map,
        source_rectangle_polygon,
        source_rotation_to_yaw,
    )
    from .distance_field import build_distance_fields
    from .prior_map_schema import (
        PACKAGE_MANIFEST_FILE,
        PACKAGE_FORMAT,
        PACKAGE_VERSION,
        PriorMapValidationError,
        SUPPORTED_TYPES,
        build_package_manifest,
        validate_business_identity,
        validate_package,
    )
    from .render_prior_map import render_package
    from .xlsx_reader import WorkbookElement, WorkbookError, read_element_info


RECTANGLE_TYPES = {"MapShelf", "MapTable", "MapPillar", "MapTableFeature"}
STRUCTURE_TYPES = RECTANGLE_TYPES
SAFE_NAME = re.compile(r"[^A-Za-z0-9._-]+")


class ConversionError(ValueError):
    pass


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
) -> dict[str, Any]:
    raw = record.element
    shape_type = str(raw.get("shapeType") or "Unknown")
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
            polygon = source_rectangle_polygon(x, y, width, height, rotation)
            geometry = {"type": "polygon", "coordinates": polygon}
            bounds = polygon_bounds(polygon)
            center = list(source_point_to_map(x + width / 2.0, y + height / 2.0))
            yaw_rad = source_rotation_to_yaw(rotation)
        elif shape_type == "MapCross":
            geometry = _line_geometry(raw.get("points"))
            bounds = polygon_bounds(geometry["coordinates"])
        elif shape_type == "MapRoadPoint":
            point = list(source_point_to_map(_number(raw, "x"), _number(raw, "y")))
            geometry = {"type": "point", "coordinates": point}
            bounds = Bounds(point[0], point[1], point[0], point[1])
            center = point
        elif shape_type not in SUPPORTED_TYPES:
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
            if key not in cross_by_key:
                warnings.append(
                    {
                        "code": "missing_cross",
                        "element_id": element["id"],
                        "floor": element["floor_id"],
                        "cross_id": code,
                        "message": f"道路点引用了不存在的道路 {code}。",
                    }
                )
            else:
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

    edges_by_key: dict[tuple[str, str], dict[str, Any]] = {}
    for key, cross_nodes in nodes_by_cross.items():
        cross = cross_by_key[key]
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
    by_floor: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for element in elements:
        if (
            element["shape_type"] in STRUCTURE_TYPES
            and element.get("visible") is True
            and element.get("bounds") is not None
        ):
            by_floor[element["floor_id"]].append(element)
    for floor_id, floor_elements in sorted(by_floor.items()):
        cells: dict[str, list[str]] = defaultdict(list)
        for element in floor_elements:
            bounds = element["bounds"]
            min_x = math.floor(float(bounds["min_x_m"]) / cell_size_m)
            max_x = math.floor(float(bounds["max_x_m"]) / cell_size_m)
            min_y = math.floor(float(bounds["min_y_m"]) / cell_size_m)
            max_y = math.floor(float(bounds["max_y_m"]) / cell_size_m)
            for cell_x in range(min_x, max_x + 1):
                for cell_y in range(min_y, max_y + 1):
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
        min_x = math.floor(min(float(start[0]), float(end[0])) / cell_size_m)
        max_x = math.floor(max(float(start[0]), float(end[0])) / cell_size_m)
        min_y = math.floor(min(float(start[1]), float(end[1])) / cell_size_m)
        max_y = math.floor(max(float(start[1]), float(end[1])) / cell_size_m)
        for cell_x in range(min_x, max_x + 1):
            for cell_y in range(min_y, max_y + 1):
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


def convert_workbook(
    source: Path | str,
    output: Path | str | None = None,
    map_name: str | None = None,
    store_id: str | None = None,
) -> Path:
    source_path = Path(source).resolve()
    resolved_map_name = str(map_name or source_path.stem)
    try:
        validate_business_identity(store_id, resolved_map_name)
    except PriorMapValidationError as exc:
        raise ConversionError(str(exc)) from exc
    source_hash = _sha256(source_path)
    result = read_element_info(source_path)
    warnings = list(result.warnings)
    elements = [_normalized_element(item, warnings) for item in result.elements]
    counts = Counter(item["shape_type"] for item in elements)
    floors = _floor_bounds(elements)
    if not floors:
        raise ConversionError("No valid geometry was found in the workbook.")
    for index, floor in enumerate(floors):
        safe_floor = SAFE_NAME.sub("-", str(floor["id"])).strip("-") or "floor"
        floor["preview_file"] = f"preview_floor_{index + 1:03d}_{safe_floor}.png"
    base_name = SAFE_NAME.sub("-", source_path.stem).strip("-") or "map"
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
        manifest = {
            "format": PACKAGE_FORMAT,
            "version": PACKAGE_VERSION,
            "prior_map_id": prior_map_id,
            "store_id": store_id,
            "name": resolved_map_name,
            "source_file": source_path.name,
            "source_sha256": source_hash,
            "source_coordinate_system": {
                "unit": "centimetre",
                "origin": "top_left",
                "x_axis": "right",
                "y_axis": "down",
                "rotation": "clockwise_degrees",
                "rectangle_anchor": "top_left_rotated_about_center",
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
            "visible_element_count": sum(item["visible"] for item in elements),
            "hidden_element_count": sum(not item["visible"] for item in elements),
            "warning_count": len(warnings) + len(result.malformed_rows),
        }
        graph = _road_graph(elements, warnings)
        manifest["warning_count"] = len(warnings) + len(result.malformed_rows)
        spatial = _spatial_index(elements, graph)
        distance_fields = build_distance_fields(elements, floors)
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
        shelves = [item for item in elements if item["shape_type"] == "MapShelf"]
        fixed = [
            item
            for item in elements
            if item["shape_type"] in {"MapTable", "MapPillar", "MapTableFeature"}
        ]
        _json_write(temporary / "manifest.json", manifest)
        _json_write(
            temporary / "elements.json",
            {"format": "MarketScannerPriorMapElements", "version": 1, "elements": elements},
        )
        _json_write(
            temporary / "shelves.json",
            {"format": "MarketScannerPriorMapShelves", "version": 1, "shelves": shelves},
        )
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
        description="Convert an Element Info XLSX workbook to a MarketScanner prior-map package."
    )
    parser.add_argument("xlsx", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--name")
    parser.add_argument("--store-id", required=True)
    args = parser.parse_args(argv)
    try:
        output = convert_workbook(
            args.xlsx,
            args.output,
            map_name=args.name,
            store_id=args.store_id,
        )
    except (WorkbookError, ConversionError, OSError) as exc:
        parser.error(str(exc))
    print(output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
