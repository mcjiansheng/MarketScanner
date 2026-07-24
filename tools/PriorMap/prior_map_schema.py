"""Schema constants and package validation for a version-1 prior map."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any


PACKAGE_FORMAT = "MarketScannerPriorMap"
PACKAGE_VERSION = 1
SUPPORTED_TYPES = {
    "MapShelf",
    "MapTable",
    "MapPillar",
    "MapTableFeature",
    "MapCross",
    "MapRoadPoint",
}
PACKAGE_FILES = {
    "manifest.json",
    "elements.json",
    "shelves.json",
    "fixed_structures.json",
    "road_graph.json",
    "spatial_index.json",
    "preview.png",
    "validation_report.json",
}


class PriorMapValidationError(ValueError):
    pass


def load_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise PriorMapValidationError(f"Cannot read valid JSON from {path.name}: {exc}") from exc


def validate_package(directory: Path | str) -> dict[str, Any]:
    root = Path(directory)
    errors: list[dict[str, str]] = []
    warnings: list[dict[str, str]] = []
    if not root.is_dir():
        raise PriorMapValidationError(f"Prior-map package is not a directory: {root}")
    for name in sorted(PACKAGE_FILES):
        if not (root / name).is_file():
            errors.append({"code": "missing_file", "message": f"缺少文件：{name}"})
    if errors:
        return {"valid": False, "errors": errors, "warnings": warnings}

    manifest = load_json(root / "manifest.json")
    if manifest.get("format") != PACKAGE_FORMAT:
        errors.append({"code": "format", "message": "manifest.json 格式标识不正确。"})
    if manifest.get("version") != PACKAGE_VERSION:
        errors.append({"code": "version", "message": "当前程序不支持该地图包版本。"})
    if not isinstance(manifest.get("prior_map_id"), str) or not manifest["prior_map_id"]:
        errors.append({"code": "map_id", "message": "地图包缺少 prior_map_id。"})
    if not isinstance(manifest.get("source_sha256"), str) or len(manifest["source_sha256"]) != 64:
        errors.append({"code": "source_hash", "message": "地图包缺少有效的源文件 SHA-256。"})
    floors = manifest.get("floors")
    if not isinstance(floors, list) or not floors:
        errors.append({"code": "floors", "message": "地图包没有可用楼层。"})

    elements_payload = load_json(root / "elements.json")
    elements = elements_payload.get("elements", []) if isinstance(elements_payload, dict) else []
    if not isinstance(elements, list):
        errors.append({"code": "elements", "message": "elements.json 的元素列表无效。"})
        elements = []
    identifiers: set[str] = set()
    for index, element in enumerate(elements):
        if not isinstance(element, dict):
            errors.append({"code": "element", "message": f"第 {index + 1} 个元素不是对象。"})
            continue
        identifier = element.get("id")
        if not isinstance(identifier, str) or not identifier:
            errors.append({"code": "element_id", "message": f"第 {index + 1} 个元素缺少 ID。"})
        elif identifier in identifiers:
            errors.append({"code": "duplicate_element_id", "message": f"元素 ID 重复：{identifier}"})
        else:
            identifiers.add(identifier)
        if element.get("shape_type") in SUPPORTED_TYPES and element.get("geometry") is None:
            errors.append(
                {
                    "code": "geometry",
                    "message": f"受支持元素 {identifier or index + 1} 缺少几何数据。",
                }
            )

    graph = load_json(root / "road_graph.json")
    node_values = [
        str(node.get("id"))
        for node in graph.get("nodes", [])
        if isinstance(node, dict) and node.get("id") is not None
    ]
    node_ids = set(node_values)
    if len(node_ids) != len(node_values):
        errors.append({"code": "duplicate_road_node", "message": "道路图包含重复节点 ID。"})
    for edge in graph.get("edges", []):
        if str(edge.get("from")) not in node_ids or str(edge.get("to")) not in node_ids:
            errors.append({"code": "road_edge", "message": "道路边引用了不存在的节点。"})

    spatial = load_json(root / "spatial_index.json")
    indexed_ids = {
        identifier
        for floor in spatial.get("floors", {}).values()
        for identifiers_in_cell in floor.get("cells", {}).values()
        for identifier in identifiers_in_cell
    }
    missing_index_references = sorted(indexed_ids - identifiers)
    if missing_index_references:
        errors.append(
            {
                "code": "spatial_reference",
                "message": f"空间索引引用未知元素：{missing_index_references[0]}",
            }
        )
    return {"valid": not errors, "errors": errors, "warnings": warnings}
