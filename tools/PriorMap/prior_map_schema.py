"""Schema constants and package validation for a version-1 prior map."""

from __future__ import annotations

import json
import unicodedata

from .strict_json import StrictJSONError, load_strict_json_bytes
import hashlib
import math
import struct
import zlib
from pathlib import Path
from typing import Any

from .distance_field import decode_level


PACKAGE_FORMAT = "MarketScannerPriorMap"
PACKAGE_VERSION = 1
PACKAGE_MANIFEST_FORMAT = "MarketScannerPriorMapPackageManifest"
PACKAGE_MANIFEST_FILE = "package_manifest.json"
SUPPORTED_TYPES = {
    "MapShelf",
    "MapTable",
    "MapPillar",
    "MapTableFeature",
    "MapCross",
    "MapRoadPoint",
}
PACKAGE_FILES = {
    PACKAGE_MANIFEST_FILE,
    "manifest.json",
    "elements.json",
    "shelves.json",
    "fixed_structures.json",
    "road_graph.json",
    "spatial_index.json",
    "distance_fields.json",
    "preview.png",
    "validation_report.json",
}
IGNORABLE_FILESYSTEM_METADATA = frozenset({".DS_Store"})
MAXIMUM_STORE_ID_UTF8_BYTES = 128
MAXIMUM_MAP_NAME_UTF8_BYTES = 200


class PriorMapValidationError(ValueError):
    pass


def _valid_business_identity_component(value: Any, maximum_utf8_bytes: int) -> bool:
    if not isinstance(value, str) or not value:
        return False
    if unicodedata.normalize("NFC", value) != value:
        return False
    if len(value.encode("utf-8")) > maximum_utf8_bytes:
        return False
    if value in {".", ".."} or value.startswith("."):
        return False
    if "/" in value or "\\" in value or Path(value).name != value:
        return False
    if value != value.strip() or not value.strip():
        return False
    if any(ord(character) < 0x20 or 0x7F <= ord(character) <= 0x9F for character in value):
        return False
    return True


def validate_business_identity(store_id: Any, map_name: Any) -> None:
    """Enforce the shared Mobile/PC store and map-name contract."""
    if not _valid_business_identity_component(store_id, MAXIMUM_STORE_ID_UTF8_BYTES):
        raise PriorMapValidationError("store_id 不符合统一业务标识策略。")
    if not _valid_business_identity_component(map_name, MAXIMUM_MAP_NAME_UTF8_BYTES):
        raise PriorMapValidationError("地图 name 不符合统一业务标识策略。")


def _is_ignorable_filesystem_metadata(path: Path) -> bool:
    """Return whether *path* is a non-authoritative macOS metadata sidecar."""
    return path.name in IGNORABLE_FILESYSTEM_METADATA or path.name.startswith("._")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def package_digest(artifacts: list[dict[str, Any]]) -> str:
    canonical = "".join(
        "\0".join(
            (
                str(item.get("file", "")),
                str(item.get("bytes", "")),
                str(item.get("sha256", "")),
                str(item.get("format") or ""),
                str(item.get("version") if item.get("version") is not None else ""),
            )
        )
        + "\n"
        for item in artifacts
    ).encode("utf-8")
    return hashlib.sha256(canonical).hexdigest()


def build_package_manifest(root: Path) -> dict[str, Any]:
    """Describe every authoritative package artifact without a self-hash cycle."""
    artifacts: list[dict[str, Any]] = []
    for path in sorted(
        item
        for item in root.iterdir()
        if item.is_file()
        and item.name != PACKAGE_MANIFEST_FILE
        and not _is_ignorable_filesystem_metadata(item)
    ):
        record: dict[str, Any] = {
            "file": path.name,
            "bytes": path.stat().st_size,
            "sha256": sha256_file(path),
            "media_type": "image/png" if path.suffix.lower() == ".png" else "application/json",
        }
        if path.suffix.lower() == ".json":
            payload = load_json(path)
            if not isinstance(payload, dict):
                raise PriorMapValidationError(f"{path.name} 顶层必须是对象。")
            record["format"] = payload.get("format")
            record["version"] = payload.get("version")
        artifacts.append(record)
    return {
        "format": PACKAGE_MANIFEST_FORMAT,
        "version": PACKAGE_VERSION,
        "hash_algorithm": "sha256",
        "artifact_count": len(artifacts),
        "artifacts": artifacts,
        "package_sha256": package_digest(artifacts),
    }


def _validate_package_manifest(
    root: Path,
    errors: list[dict[str, str]],
) -> dict[str, Any] | None:
    payload = _payload(
        root,
        PACKAGE_MANIFEST_FILE,
        PACKAGE_MANIFEST_FORMAT,
        errors,
    )
    if payload is None:
        return None
    artifacts = payload.get("artifacts")
    if (
        payload.get("hash_algorithm") != "sha256"
        or not isinstance(artifacts, list)
        or not all(isinstance(item, dict) for item in artifacts)
        or payload.get("artifact_count") != len(artifacts)
    ):
        errors.append(
            {"code": "package_manifest", "message": "package_manifest.json 结构无效。"}
        )
        return payload
    names = [item.get("file") for item in artifacts]
    if (
        not all(
            isinstance(name, str)
            and name
            and Path(name).name == name
            and name != PACKAGE_MANIFEST_FILE
            for name in names
        )
        or len(set(names)) != len(names)
    ):
        errors.append(
            {"code": "package_artifact_name", "message": "地图包文件名缺失、重复或不安全。"}
        )
        return payload
    actual_names = {
        path.name
        for path in root.iterdir()
        if path.is_file()
        and path.name != PACKAGE_MANIFEST_FILE
        and not _is_ignorable_filesystem_metadata(path)
    }
    if set(names) != actual_names:
        errors.append(
            {
                "code": "package_artifact_set",
                "message": "package_manifest.json 未精确覆盖地图包文件。",
            }
        )
    for artifact in artifacts:
        name = str(artifact["file"])
        path = root / name
        if not path.is_file():
            continue
        expected_bytes = artifact.get("bytes")
        expected_hash = artifact.get("sha256")
        if (
            not isinstance(expected_bytes, int)
            or isinstance(expected_bytes, bool)
            or expected_bytes < 0
            or expected_bytes != path.stat().st_size
        ):
            errors.append(
                {"code": "package_artifact_bytes", "message": f"{name} 文件长度校验失败。"}
            )
        if (
            not isinstance(expected_hash, str)
            or len(expected_hash) != 64
            or sha256_file(path) != expected_hash
        ):
            errors.append(
                {"code": "package_artifact_hash", "message": f"{name} SHA-256 校验失败。"}
            )
        if path.suffix.lower() == ".json":
            try:
                child = load_json(path)
            except PriorMapValidationError as exc:
                errors.append({"code": "invalid_json", "message": str(exc)})
                continue
            if (
                not isinstance(child, dict)
                or artifact.get("format") != child.get("format")
                or artifact.get("version") != child.get("version")
            ):
                errors.append(
                    {
                        "code": "package_artifact_schema",
                        "message": f"{name} 的格式/版本与 package_manifest.json 不一致。",
                    }
                )
    if payload.get("package_sha256") != package_digest(artifacts):
        errors.append(
            {"code": "package_hash", "message": "地图包规范化 SHA-256 校验失败。"}
        )
    return payload


def load_json(path: Path) -> Any:
    """Read one formal prior-map JSON document with the shared strict
    contract (P7R6C): strict UTF-8, no NaN/Infinity, duplicate keys
    rejected before last-key-wins parsing."""

    try:
        return load_strict_json_bytes(path.read_bytes(), name=path.name)
    except (OSError, StrictJSONError) as exc:
        raise PriorMapValidationError(f"Cannot read valid JSON from {path.name}: {exc}") from exc


def _payload(
    root: Path,
    name: str,
    expected_format: str,
    errors: list[dict[str, str]],
) -> dict[str, Any] | None:
    try:
        value = load_json(root / name)
    except PriorMapValidationError as exc:
        errors.append({"code": "invalid_json", "message": str(exc)})
        return None
    if not isinstance(value, dict):
        errors.append({"code": "json_object", "message": f"{name} 顶层必须是对象。"})
        return None
    if value.get("format") != expected_format:
        errors.append({"code": "file_format", "message": f"{name} 格式标识不正确。"})
    if value.get("version") != PACKAGE_VERSION:
        errors.append({"code": "file_version", "message": f"{name} 版本不受支持。"})
    return value


def _geometry_points(geometry: Any) -> list[tuple[float, float]]:
    if not isinstance(geometry, dict):
        return []
    coordinates = geometry.get("coordinates")
    if geometry.get("type") == "point":
        coordinates = [coordinates]
    if not isinstance(coordinates, list):
        return []
    points: list[tuple[float, float]] = []
    for point in coordinates:
        if (
            isinstance(point, list)
            and len(point) >= 2
            and isinstance(point[0], (int, float))
            and not isinstance(point[0], bool)
            and isinstance(point[1], (int, float))
            and not isinstance(point[1], bool)
            and math.isfinite(float(point[0]))
            and math.isfinite(float(point[1]))
        ):
            points.append((float(point[0]), float(point[1])))
    return points


def _bounds(points: list[tuple[float, float]]) -> dict[str, float]:
    return {
        "min_x_m": min(point[0] for point in points),
        "min_y_m": min(point[1] for point in points),
        "max_x_m": max(point[0] for point in points),
        "max_y_m": max(point[1] for point in points),
    }


def _bounds_match(first: Any, second: dict[str, float], tolerance: float = 1.0e-5) -> bool:
    return isinstance(first, dict) and all(
        isinstance(first.get(key), (int, float))
        and not isinstance(first.get(key), bool)
        and math.isfinite(float(first[key]))
        and abs(float(first[key]) - value) <= tolerance
        for key, value in second.items()
    )


def _validate_png(path: Path) -> str | None:
    try:
        data = path.read_bytes()
    except OSError as exc:
        return f"preview.png 无法读取：{exc}"
    if not data.startswith(b"\x89PNG\r\n\x1a\n"):
        return "preview.png 缺少有效 PNG 签名。"
    offset = 8
    width = height = color_type = None
    compressed = bytearray()
    saw_end = False
    try:
        while offset + 12 <= len(data):
            length = struct.unpack(">I", data[offset : offset + 4])[0]
            kind = data[offset + 4 : offset + 8]
            payload_start = offset + 8
            payload_end = payload_start + length
            if payload_end + 4 > len(data):
                return "preview.png 数据块被截断。"
            payload = data[payload_start:payload_end]
            expected_crc = struct.unpack(">I", data[payload_end : payload_end + 4])[0]
            if zlib.crc32(kind + payload) & 0xFFFFFFFF != expected_crc:
                return "preview.png 数据块校验失败。"
            if kind == b"IHDR":
                if length != 13:
                    return "preview.png IHDR 无效。"
                width, height, bit_depth, color_type, compression, filtering, interlace = struct.unpack(
                    ">IIBBBBB", payload
                )
                if (
                    width <= 0
                    or height <= 0
                    or bit_depth != 8
                    or color_type not in {2, 6}
                    or compression != 0
                    or filtering != 0
                    or interlace != 0
                ):
                    return "preview.png 使用了不受支持或无效的图像参数。"
            elif kind == b"IDAT":
                compressed.extend(payload)
            elif kind == b"IEND":
                saw_end = True
                break
            offset = payload_end + 4
        if width is None or height is None or not compressed or not saw_end:
            return "preview.png 缺少必需数据块。"
        raw = zlib.decompress(bytes(compressed))
        channels = 3 if color_type == 2 else 4
        if len(raw) != height * (1 + width * channels):
            return "preview.png 解压后的像素长度不正确。"
    except (struct.error, zlib.error, OverflowError) as exc:
        return f"preview.png 无法解码：{exc}"
    return None


def _indexed_identifiers(
    floors: dict[str, Any],
    key: str,
    errors: list[dict[str, str]],
) -> set[str]:
    result: set[str] = set()
    for floor_id, floor in floors.items():
        if not isinstance(floor, dict):
            errors.append(
                {"code": "spatial_floor", "message": f"空间索引楼层 {floor_id} 不是对象。"}
            )
            continue
        cells = floor.get(key)
        if not isinstance(cells, dict):
            errors.append(
                {
                    "code": "spatial_cells",
                    "message": f"空间索引楼层 {floor_id} 的 {key} 无效。",
                }
            )
            continue
        for cell, identifiers in cells.items():
            if (
                not isinstance(cell, str)
                or not isinstance(identifiers, list)
                or not all(isinstance(identifier, str) for identifier in identifiers)
            ):
                errors.append(
                    {
                        "code": "spatial_cell",
                        "message": f"空间索引楼层 {floor_id} 包含无效网格记录。",
                    }
                )
                continue
            result.update(identifiers)
    return result


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

    package_manifest = _validate_package_manifest(root, errors)
    manifest = _payload(root, "manifest.json", PACKAGE_FORMAT, errors)
    elements_payload = _payload(
        root, "elements.json", "MarketScannerPriorMapElements", errors
    )
    shelves_payload = _payload(
        root, "shelves.json", "MarketScannerPriorMapShelves", errors
    )
    structures_payload = _payload(
        root, "fixed_structures.json", "MarketScannerPriorMapStructures", errors
    )
    graph = _payload(root, "road_graph.json", "MarketScannerRoadGraph", errors)
    spatial = _payload(
        root, "spatial_index.json", "MarketScannerSpatialIndex", errors
    )
    distance_fields = _payload(
        root, "distance_fields.json", "MarketScannerDistanceFields", errors
    )
    validation_report = _payload(
        root,
        "validation_report.json",
        "MarketScannerPriorMapValidation",
        errors,
    )
    png_error = _validate_png(root / "preview.png")
    if png_error:
        errors.append({"code": "preview_png", "message": png_error})
    if any(
        value is None
        for value in (
            manifest,
            elements_payload,
            shelves_payload,
            structures_payload,
            graph,
            spatial,
            distance_fields,
            validation_report,
            package_manifest,
        )
    ):
        return {"valid": False, "errors": errors, "warnings": warnings}

    assert manifest is not None
    assert elements_payload is not None
    assert shelves_payload is not None
    assert structures_payload is not None
    assert graph is not None
    assert spatial is not None
    assert distance_fields is not None
    assert validation_report is not None

    try:
        validate_business_identity(manifest.get("store_id"), manifest.get("name"))
    except PriorMapValidationError as exc:
        errors.append({"code": "business_identity", "message": str(exc)})

    if not isinstance(manifest.get("prior_map_id"), str) or not manifest["prior_map_id"]:
        errors.append({"code": "map_id", "message": "地图包缺少 prior_map_id。"})
    source_hash = manifest.get("source_sha256")
    if (
        not isinstance(source_hash, str)
        or len(source_hash) != 64
        or any(character not in "0123456789abcdef" for character in source_hash)
    ):
        errors.append({"code": "source_hash", "message": "地图包缺少有效的源文件 SHA-256。"})
    floors = manifest.get("floors")
    if not isinstance(floors, list) or not floors:
        errors.append({"code": "floors", "message": "地图包没有可用楼层。"})
        floors = []
    floor_records = {
        str(item.get("id")): item
        for item in floors
        if isinstance(item, dict) and item.get("id") is not None
    }
    if len(floor_records) != len(floors):
        errors.append({"code": "floor_id", "message": "楼层 ID 缺失或重复。"})
    localization_scope = manifest.get("localization_scope")
    if (
        not isinstance(localization_scope, dict)
        or localization_scope.get("floor_mode") != "single_floor_per_scan"
        or localization_scope.get("cross_floor_switching") is not False
        or localization_scope.get("vertical_motion")
        != "ignored_in_prior_map_2d_preserved_in_raw_3d"
    ):
        errors.append(
            {
                "code": "localization_scope",
                "message": "manifest 缺少当前单楼层定位范围声明。",
            }
        )

    elements = elements_payload.get("elements", [])
    if not isinstance(elements, list):
        errors.append({"code": "elements", "message": "elements.json 的元素列表无效。"})
        elements = []
    identifiers: set[str] = set()
    elements_by_id: dict[str, dict[str, Any]] = {}
    geometry_by_floor: dict[str, list[tuple[float, float]]] = {}
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
            elements_by_id[identifier] = element
        points = _geometry_points(element.get("geometry"))
        if points:
            floor_id = str(element.get("floor_id"))
            if floor_id not in floor_records:
                errors.append(
                    {
                        "code": "element_floor",
                        "message": f"元素 {identifier or index + 1} 引用了未知楼层。",
                    }
                )
            geometry_by_floor.setdefault(floor_id, []).extend(points)
            if not _bounds_match(element.get("bounds"), _bounds(points)):
                errors.append(
                    {
                        "code": "element_bounds",
                        "message": f"元素 {identifier or index + 1} 的 bounds 与几何不一致。",
                    }
                )
        if element.get("shape_type") in SUPPORTED_TYPES and element.get("geometry") is None:
            errors.append(
                {
                    "code": "geometry",
                    "message": f"受支持元素 {identifier or index + 1} 缺少几何数据。",
                }
            )

    if manifest.get("element_count") != len(elements):
        errors.append({"code": "element_count", "message": "manifest 元素数量与 elements.json 不一致。"})
    expected_statistics: dict[str, int] = {}
    for element in elements:
        if isinstance(element, dict):
            shape_type = str(element.get("shape_type"))
            expected_statistics[shape_type] = expected_statistics.get(shape_type, 0) + 1
    if manifest.get("element_statistics") != dict(sorted(expected_statistics.items())):
        errors.append({"code": "element_statistics", "message": "manifest 元素分类统计不一致。"})
    visible_count = sum(element.get("visible") is True for element in elements if isinstance(element, dict))
    if (
        manifest.get("visible_element_count") != visible_count
        or manifest.get("hidden_element_count") != len(elements) - visible_count
    ):
        errors.append({"code": "visibility_count", "message": "manifest 可见/隐藏元素统计不一致。"})
    for floor_id, record in floor_records.items():
        points = geometry_by_floor.get(floor_id, [])
        if not points:
            errors.append({"code": "floor_geometry", "message": f"楼层 {floor_id} 没有有效几何。"})
        elif not _bounds_match(record.get("bounds"), _bounds(points)):
            errors.append({"code": "floor_bounds", "message": f"楼层 {floor_id} 的 bounds 与实际几何不一致。"})
        preview_file = record.get("preview_file")
        if (
            not isinstance(preview_file, str)
            or not preview_file
            or Path(preview_file).name != preview_file
            or not (root / preview_file).is_file()
        ):
            errors.append({"code": "floor_preview", "message": f"楼层 {floor_id} 缺少独立预览图。"})
        else:
            floor_png_error = _validate_png(root / preview_file)
            if floor_png_error:
                errors.append(
                    {
                        "code": "floor_preview_png",
                        "message": f"楼层 {floor_id} 预览无效：{floor_png_error}",
                    }
                )
    all_points = [point for values in geometry_by_floor.values() for point in values]
    if all_points and not _bounds_match(manifest.get("bounds"), _bounds(all_points)):
        errors.append({"code": "map_bounds", "message": "manifest 总体 bounds 与实际几何不一致。"})

    def validate_subset(
        payload: dict[str, Any],
        key: str,
        expected_types: set[str],
        label: str,
    ) -> None:
        values = payload.get(key)
        if not isinstance(values, list) or not all(isinstance(item, dict) for item in values):
            errors.append({"code": "subset", "message": f"{label} 列表无效。"})
            return
        expected = {
            identifier
            for identifier, item in elements_by_id.items()
            if item.get("shape_type") in expected_types
        }
        actual = {
            str(item.get("id"))
            for item in values
            if isinstance(item.get("id"), str)
        }
        if actual != expected or len(actual) != len(values):
            errors.append({"code": "subset_ids", "message": f"{label} 不是 elements.json 的正确子集。"})
            return
        if any(item != elements_by_id[str(item["id"])] for item in values):
            errors.append({"code": "subset_content", "message": f"{label} 内容与 elements.json 不一致。"})

    validate_subset(shelves_payload, "shelves", {"MapShelf"}, "shelves.json")
    validate_subset(
        structures_payload,
        "structures",
        {"MapTable", "MapPillar", "MapTableFeature"},
        "fixed_structures.json",
    )

    nodes = graph.get("nodes")
    edges = graph.get("edges")
    if not isinstance(nodes, list) or not all(isinstance(node, dict) for node in nodes):
        errors.append({"code": "road_nodes", "message": "road_graph.json 节点列表无效。"})
        nodes = []
    if not isinstance(edges, list) or not all(isinstance(edge, dict) for edge in edges):
        errors.append({"code": "road_edges", "message": "road_graph.json 道路边列表无效。"})
        edges = []
    node_values = [
        str(node.get("id"))
        for node in nodes
        if isinstance(node, dict) and node.get("id") is not None
    ]
    node_ids = set(node_values)
    if len(node_ids) != len(node_values):
        errors.append({"code": "duplicate_road_node", "message": "道路图包含重复节点 ID。"})
    node_by_id = {str(node.get("id")): node for node in nodes}
    edge_ids: set[str] = set()
    for node in nodes:
        if str(node.get("floor_id")) not in floor_records:
            errors.append({"code": "road_node_floor", "message": "道路节点引用了未知楼层。"})
        element = elements_by_id.get(str(node.get("element_id")))
        if element is None or element.get("shape_type") != "MapRoadPoint":
            errors.append({"code": "road_node_element", "message": "道路节点没有对应的 MapRoadPoint 元素。"})
            continue
        position = node.get("position_m")
        element_points = _geometry_points(element.get("geometry"))
        if (
            not isinstance(position, list)
            or len(position) < 2
            or not element_points
            or not all(
                isinstance(value, (int, float))
                and not isinstance(value, bool)
                and math.isfinite(float(value))
                for value in position[:2]
            )
            or abs(float(position[0]) - element_points[0][0]) > 1.0e-5
            or abs(float(position[1]) - element_points[0][1]) > 1.0e-5
        ):
            errors.append({"code": "road_node_position", "message": "道路节点位置与来源元素不一致。"})
    for edge in edges:
        raw_edge_id = edge.get("id")
        edge_id = raw_edge_id if isinstance(raw_edge_id, str) else ""
        if not edge_id or edge_id in edge_ids:
            errors.append({"code": "road_edge_id", "message": "道路边 ID 缺失或重复。"})
        if edge_id:
            edge_ids.add(edge_id)
        if str(edge.get("from")) not in node_ids or str(edge.get("to")) not in node_ids:
            errors.append({"code": "road_edge", "message": "道路边引用了不存在的节点。"})
            continue
        edge_floor = str(edge.get("floor_id"))
        if (
            edge_floor not in floor_records
            or str(node_by_id[str(edge.get("from"))].get("floor_id")) != edge_floor
            or str(node_by_id[str(edge.get("to"))].get("floor_id")) != edge_floor
        ):
            errors.append({"code": "road_edge_floor", "message": "道路边与节点楼层不一致。"})

    cell_size = spatial.get("cell_size_m")
    if (
        not isinstance(cell_size, (int, float))
        or isinstance(cell_size, bool)
        or not math.isfinite(float(cell_size))
        or float(cell_size) <= 0
    ):
        errors.append({"code": "spatial_cell_size", "message": "空间索引网格尺寸无效。"})
    spatial_floors = spatial.get("floors")
    if not isinstance(spatial_floors, dict):
        errors.append({"code": "spatial_floors", "message": "空间索引楼层对象无效。"})
        spatial_floors = {}
    indexed_ids = _indexed_identifiers(spatial_floors, "cells", errors)
    missing_index_references = sorted(indexed_ids - identifiers)
    if missing_index_references:
        errors.append(
            {
                "code": "spatial_reference",
                "message": f"空间索引引用未知元素：{missing_index_references[0]}",
            }
        )
    expected_indexed_ids = {
        identifier
        for identifier, element in elements_by_id.items()
        if element.get("shape_type") in {"MapShelf", "MapTable", "MapPillar", "MapTableFeature"}
        and element.get("visible") is True
        and element.get("bounds") is not None
    }
    if indexed_ids != expected_indexed_ids:
        errors.append(
            {
                "code": "spatial_coverage",
                "message": "结构空间索引未完整且精确覆盖可见固定结构。",
            }
        )
    indexed_road_ids = _indexed_identifiers(spatial_floors, "road_cells", errors)
    missing_road_references = sorted(indexed_road_ids - edge_ids)
    if missing_road_references:
        errors.append(
            {
                "code": "spatial_road_reference",
                "message": f"道路空间索引引用未知边：{missing_road_references[0]}",
            }
        )
    if indexed_road_ids != edge_ids:
        errors.append(
            {
                "code": "spatial_road_coverage",
                "message": "道路空间索引未完整且精确覆盖道路边。",
            }
        )
    distance_manifest = manifest.get("distance_fields")
    if (
        not isinstance(distance_manifest, dict)
        or distance_manifest.get("file") != "distance_fields.json"
        or distance_manifest.get("format") != "MarketScannerDistanceFields"
        or distance_manifest.get("version") != PACKAGE_VERSION
    ):
        errors.append({"code": "distance_manifest", "message": "manifest 距离场声明无效。"})
    truncation = distance_fields.get("truncation_distance_m")
    distance_floors = distance_fields.get("floors")
    if (
        not isinstance(truncation, (int, float))
        or isinstance(truncation, bool)
        or not 0 < float(truncation) <= 2.55
        or not isinstance(distance_floors, dict)
        or set(distance_floors) != set(floor_records)
    ):
        errors.append({"code": "distance_fields", "message": "距离场楼层或截断距离无效。"})
        distance_floors = {}
    expected_resolutions = distance_manifest.get("resolutions_m") if isinstance(distance_manifest, dict) else None
    if expected_resolutions != [0.4, 0.2, 0.1]:
        errors.append(
            {
                "code": "distance_resolutions",
                "message": "距离场必须包含 0.40/0.20/0.10 m 三个层级。",
            }
        )
    for floor_id, floor in distance_floors.items():
        levels = floor.get("levels") if isinstance(floor, dict) else None
        if not isinstance(levels, list) or not levels:
            errors.append({"code": "distance_levels", "message": f"楼层 {floor_id} 缺少距离场层级。"})
            continue
        resolutions = [level.get("resolution_m") for level in levels if isinstance(level, dict)]
        if resolutions != expected_resolutions:
            errors.append({"code": "distance_resolutions", "message": f"楼层 {floor_id} 距离场分辨率不一致。"})
        for level in levels:
            try:
                if (
                    not isinstance(level, dict)
                    or level.get("encoding") != "row_rle_u8_cm"
                    or not isinstance(level.get("origin_m"), list)
                    or len(level["origin_m"]) != 2
                    or float(level.get("resolution_m", 0)) <= 0
                ):
                    raise ValueError("Distance-field metadata is invalid.")
                values = decode_level(level)
                if 0 not in values:
                    raise ValueError(
                        "Distance field contains no visible structure seed."
                    )
            except (TypeError, ValueError, OverflowError) as exc:
                errors.append(
                    {
                        "code": "distance_data",
                        "message": f"楼层 {floor_id} 距离场无法解码：{exc}",
                    }
                )
    summary = validation_report.get("summary")
    report_warnings = validation_report.get("warnings")
    malformed_rows = validation_report.get("malformed_rows")
    if (
        validation_report.get("valid") is not True
        or not isinstance(summary, dict)
        or not isinstance(report_warnings, list)
        or not isinstance(malformed_rows, list)
        or summary.get("element_count") != len(elements)
        or summary.get("floor_count") != len(floor_records)
        or summary.get("node_count") != len(nodes)
        or summary.get("edge_count") != len(edges)
        or (
            isinstance(report_warnings, list)
            and isinstance(malformed_rows, list)
            and summary.get("warning_count") != len(report_warnings) + len(malformed_rows)
        )
        or summary.get("warning_count") != manifest.get("warning_count")
    ):
        errors.append({"code": "validation_report", "message": "validation_report.json 与地图包内容不一致。"})
    return {"valid": not errors, "errors": errors, "warnings": warnings}
