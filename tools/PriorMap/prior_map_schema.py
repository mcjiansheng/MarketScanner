"""Schema constants and validation for legacy-v1 and current-v2 prior maps."""

from __future__ import annotations

import json
import unicodedata

from .strict_json import StrictJSONError, load_strict_json_bytes
import hashlib
import math
import re
import struct
import zlib
from pathlib import Path
from typing import Any

from .distance_field import (
    MAXIMUM_TOTAL_CELLS,
    build_distance_fields,
    decode_level,
)
from .element_roles import (
    ACTIVE_TYPES,
    FIXED_STRUCTURE_TYPES,
    PRESENTATION_ONLY_TYPES,
    ROLE_FIXED_STRUCTURE,
    ROLE_SHELF,
    SHELF_TYPES,
    STRUCTURE_TYPES,
    role_contract_payload,
    role_for,
)


PACKAGE_FORMAT = "MarketScannerPriorMap"
LEGACY_PACKAGE_VERSION = 1
PACKAGE_VERSION = 2
SUPPORTED_PACKAGE_VERSIONS = frozenset({LEGACY_PACKAGE_VERSION, PACKAGE_VERSION})
PACKAGE_MANIFEST_VERSION = 1
ARTIFACT_VERSION = 1
PACKAGE_MANIFEST_FORMAT = "MarketScannerPriorMapPackageManifest"
PACKAGE_MANIFEST_FILE = "package_manifest.json"
# Compatibility export for older callers.  New code must classify through
# element_roles.py instead of maintaining another role table here.
SUPPORTED_TYPES = set(ACTIVE_TYPES)
SAFE_NAME = re.compile(r"[^A-Za-z0-9._-]+")
MAXIMUM_PRIOR_MAP_ID_LENGTH = 128
PRIOR_MAP_ID_HASH_PREFIX_LENGTH = 12
MAXIMUM_PRIOR_MAP_SLUG_LENGTH = (
    MAXIMUM_PRIOR_MAP_ID_LENGTH - PRIOR_MAP_ID_HASH_PREFIX_LENGTH - 1
)
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


def canonical_safe_name(value: Any, fallback: str = "map") -> str:
    """Return the canonical lowercase filesystem slug used by map packages."""

    # Filter original Unicode scalars before ASCII lowercasing. Python's full
    # Unicode lower() can otherwise create ASCII bytes that Swift never sees
    # (for example U+0130 or the Kelvin sign), breaking cross-end IDs.
    filtered = SAFE_NAME.sub("-", str(value)).strip("-")
    lowered = filtered.translate(
        str.maketrans(
            "ABCDEFGHIJKLMNOPQRSTUVWXYZ",
            "abcdefghijklmnopqrstuvwxyz",
        )
    )
    bounded = lowered[:MAXIMUM_PRIOR_MAP_SLUG_LENGTH].rstrip("-")
    return bounded or fallback


def legacy_safe_name(value: Any, fallback: str = "map") -> str:
    """Return the pre-canonical v2 slug for read-only compatibility."""

    return SAFE_NAME.sub("-", str(value)).strip("-") or fallback


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
        "version": PACKAGE_MANIFEST_VERSION,
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
        frozenset({PACKAGE_MANIFEST_VERSION}),
    )
    if payload is None:
        return None
    artifacts = payload.get("artifacts")
    if (
        payload.get("hash_algorithm") != "sha256"
        or not isinstance(artifacts, list)
        or not all(isinstance(item, dict) for item in artifacts)
        or type(payload.get("artifact_count")) is not int
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
                or type(artifact.get("version")) is not int
                or type(child.get("version")) is not int
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
    supported_versions: frozenset[int] = SUPPORTED_PACKAGE_VERSIONS,
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
    version = value.get("version")
    if type(version) is not int or version not in supported_versions:
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
        if not (
            isinstance(point, list)
            and len(point) >= 2
            and isinstance(point[0], (int, float))
            and not isinstance(point[0], bool)
            and isinstance(point[1], (int, float))
            and not isinstance(point[1], bool)
            and math.isfinite(float(point[0]))
            and math.isfinite(float(point[1]))
        ):
            return []
        points.append((float(point[0]), float(point[1])))
    return points


def _production_geometry_points(
    shape_type: str,
    geometry: Any,
) -> list[tuple[float, float]] | None:
    """Validate the role-specific v2 production geometry contract.

    Package validation must not infer geometry from a merely parseable
    coordinate list.  Shelves/fixed structures are four-point polygons,
    crosses are non-degenerate line strings, and road points are one
    finite 2D point.  This mirrors the mobile validator and prevents a
    hash-consistent package from passing while downstream builders silently
    ignore its structure geometry.
    """

    if not isinstance(geometry, dict):
        return None
    geometry_type = geometry.get("type")
    coordinates = geometry.get("coordinates")

    def point(value: Any) -> tuple[float, float] | None:
        if not (
            isinstance(value, list)
            and len(value) == 2
            and all(
                isinstance(component, (int, float))
                and not isinstance(component, bool)
                and math.isfinite(float(component))
                for component in value
            )
        ):
            return None
        return float(value[0]), float(value[1])

    if shape_type in STRUCTURE_TYPES:
        if geometry_type != "polygon" or not isinstance(coordinates, list):
            return None
        if len(coordinates) != 4:
            return None
        points = [point(value) for value in coordinates]
        if any(value is None for value in points):
            return None
        polygon = [value for value in points if value is not None]
        twice_area = 0.0
        for index, current in enumerate(polygon):
            following = polygon[(index + 1) % len(polygon)]
            if math.hypot(
                following[0] - current[0], following[1] - current[1]
            ) <= 1.0e-9:
                return None
            twice_area += current[0] * following[1] - following[0] * current[1]
        return polygon if abs(twice_area) > 1.0e-12 else None

    if shape_type == "MapCross":
        if geometry_type != "line_string" or not isinstance(coordinates, list):
            return None
        if len(coordinates) < 2:
            return None
        points = [point(value) for value in coordinates]
        if any(value is None for value in points):
            return None
        line = [value for value in points if value is not None]
        return line if any(
            math.hypot(second[0] - first[0], second[1] - first[1]) > 1.0e-9
            for first, second in zip(line, line[1:])
        ) else None

    if shape_type == "MapRoadPoint":
        if geometry_type != "point":
            return None
        converted = point(coordinates)
        return [converted] if converted is not None else None

    return None


def _bounds(
    points: list[tuple[float, float]], *, include_dimensions: bool = False
) -> dict[str, float]:
    result = {
        "min_x_m": min(point[0] for point in points),
        "min_y_m": min(point[1] for point in points),
        "max_x_m": max(point[0] for point in points),
        "max_y_m": max(point[1] for point in points),
    }
    if include_dimensions:
        result["width_m"] = result["max_x_m"] - result["min_x_m"]
        result["height_m"] = result["max_y_m"] - result["min_y_m"]
    return result


def _bounds_match(
    first: Any,
    second: dict[str, float],
    tolerance: float = 1.0e-5,
    *,
    exact_keys: bool = False,
) -> bool:
    return (
        isinstance(first, dict)
        and (not exact_keys or set(first) == set(second))
        and all(
            isinstance(first.get(key), (int, float))
            and not isinstance(first.get(key), bool)
            and math.isfinite(float(first[key]))
            and abs(float(first[key]) - value) <= tolerance
            for key, value in second.items()
        )
    )


def _valid_sha256(value: Any) -> bool:
    return (
        isinstance(value, str)
        and len(value) == 64
        and all(character in "0123456789abcdef" for character in value)
    )


def _positive_finite(value: Any) -> bool:
    return (
        isinstance(value, (int, float))
        and not isinstance(value, bool)
        and math.isfinite(float(value))
        and float(value) > 0
    )


def _points_inside_bounds(
    points: list[tuple[float, float]],
    bounds: dict[str, float],
    tolerance: float = 1.0e-5,
) -> bool:
    return all(
        bounds["min_x_m"] - tolerance <= point[0] <= bounds["max_x_m"] + tolerance
        and bounds["min_y_m"] - tolerance <= point[1] <= bounds["max_y_m"] + tolerance
        for point in points
    )


def _finite_vector2(value: Any) -> tuple[float, float] | None:
    if (
        not isinstance(value, list)
        or len(value) != 2
        or not all(
            isinstance(component, (int, float))
            and not isinstance(component, bool)
            and math.isfinite(float(component))
            for component in value
        )
    ):
        return None
    return float(value[0]), float(value[1])


def _validate_shelves_document(
    payload: dict[str, Any],
    *,
    package_version: int,
    elements_by_id: dict[str, dict[str, Any]],
    errors: list[dict[str, str]],
) -> None:
    """Validate the shared legacy-v1 / production-v2 shelves contract.

    Package v2 is a formal production package and therefore requires
    shelves v2.  Package v1 remains readable with its historical shelves v1
    document, and also accepts shelves v2 produced by newer mobile compilers.
    Whenever shelves v2 is present, all segment vectors and cross-file
    shelf/floor/code relations are fail-closed.
    """

    version = payload.get("version")
    if package_version == PACKAGE_VERSION and version != 2:
        errors.append(
            {
                "code": "shelf_version_contract",
                "message": "v2 正式地图包必须携带 shelves.json v2 显式方向合同。",
            }
        )

    expected_top_level = (
        {"format", "version", "shelves"}
        if version == 1
        else {"format", "version", "shelves", "shelf_segments"}
    )
    if type(version) is not int or version not in {1, 2} or set(payload) != expected_top_level:
        errors.append(
            {
                "code": "shelf_schema",
                "message": "shelves.json 顶层字段与版本合同不一致。",
            }
        )
        return

    raw_shelves = payload.get("shelves")
    if not isinstance(raw_shelves, list) or not all(
        isinstance(item, dict) for item in raw_shelves
    ):
        errors.append(
            {"code": "shelf_schema", "message": "shelves.json shelves 列表无效。"}
        )
        return

    inventory: dict[str, tuple[str, str | None]] = {}
    for shelf in raw_shelves:
        identifier = shelf.get("id")
        floor_id = shelf.get("floor_id")
        code = shelf.get("code")
        if (
            not isinstance(identifier, str)
            or not identifier
            or not isinstance(floor_id, str)
            or not floor_id
            or (code is not None and not isinstance(code, str))
            or identifier in inventory
        ):
            errors.append(
                {
                    "code": "shelf_schema",
                    "message": "shelves.json 货架 identity/floor/code 无效或重复。",
                }
            )
            return
        inventory[identifier] = (floor_id, code)

    if version == 1:
        return

    raw_segments = payload.get("shelf_segments")
    if not isinstance(raw_segments, list) or not all(
        isinstance(item, dict) for item in raw_segments
    ):
        errors.append(
            {
                "code": "shelf_segment_schema",
                "message": "shelves.json v2 shelf_segments 列表无效。",
            }
        )
        return

    segment_fields = {
        "shelf_segment_id",
        "shelf_code",
        "floor_id",
        "longitudinal_start_m",
        "longitudinal_end_m",
        "longitudinal_axis",
        "front_normal",
        "back_normal",
        "side_semantics_version",
        "orientation_provenance",
    }
    allowed_provenance = {"element_yaw", "unavailable"}
    vector_tolerance = 1.0e-6
    seen_segment_ids: set[str] = set()

    for index, segment in enumerate(raw_segments, start=1):
        if set(segment) != segment_fields:
            errors.append(
                {
                    "code": "shelf_segment_schema",
                    "message": f"第 {index} 个 shelf segment 字段集合无效。",
                }
            )
            continue
        segment_id = segment.get("shelf_segment_id")
        shelf_code = segment.get("shelf_code")
        floor_id = segment.get("floor_id")
        provenance = segment.get("orientation_provenance")
        semantics_version = segment.get("side_semantics_version")
        start = _finite_vector2(segment.get("longitudinal_start_m"))
        end = _finite_vector2(segment.get("longitudinal_end_m"))
        axis = _finite_vector2(segment.get("longitudinal_axis"))
        front = _finite_vector2(segment.get("front_normal"))
        back = _finite_vector2(segment.get("back_normal"))
        if (
            not isinstance(segment_id, str)
            or not segment_id
            or not isinstance(shelf_code, str)
            or not isinstance(floor_id, str)
            or not floor_id
            or type(semantics_version) is not int
            or semantics_version != 1
            or provenance not in allowed_provenance
            or start is None
            or end is None
            or axis is None
            or front is None
            or back is None
        ):
            errors.append(
                {
                    "code": "shelf_segment_schema",
                    "message": f"第 {index} 个 shelf segment 标量或二维向量无效。",
                }
            )
            continue
        if segment_id in seen_segment_ids:
            errors.append(
                {
                    "code": "shelf_segment_relation",
                    "message": f"shelf_segment_id 重复：{segment_id}",
                }
            )
            continue
        seen_segment_ids.add(segment_id)

        dx = end[0] - start[0]
        dy = end[1] - start[1]
        segment_length = math.hypot(dx, dy)

        def is_unit(value: tuple[float, float]) -> bool:
            return abs(math.hypot(value[0], value[1]) - 1.0) <= vector_tolerance

        geometric_relations_valid = (
            segment_length > vector_tolerance
            and is_unit(axis)
            and is_unit(front)
            and is_unit(back)
            and abs(axis[0] * front[0] + axis[1] * front[1])
            <= vector_tolerance
            and abs(axis[0] * back[0] + axis[1] * back[1])
            <= vector_tolerance
            and abs(front[0] + back[0]) <= vector_tolerance
            and abs(front[1] + back[1]) <= vector_tolerance
            and (
                dx / segment_length * axis[0]
                + dy / segment_length * axis[1]
            )
            >= 1.0 - vector_tolerance
        )
        if not geometric_relations_valid:
            errors.append(
                {
                    "code": "shelf_segment_relation",
                    "message": f"第 {index} 个 shelf segment 轴、法向或起止方向关系无效。",
                }
            )
            continue
        if inventory.get(segment_id) != (floor_id, shelf_code):
            errors.append(
                {
                    "code": "shelf_segment_relation",
                    "message": (
                        f"第 {index} 个 shelf segment 未精确绑定对应货架的 ID/floor/code。"
                    ),
                }
            )
            continue

        element = elements_by_id.get(segment_id)
        expected = _expected_shelf_segment(element)
        vector_fields = (
            "longitudinal_start_m",
            "longitudinal_end_m",
            "longitudinal_axis",
            "front_normal",
            "back_normal",
        )
        if (
            expected is None
            or any(
                any(
                    abs(float(actual) - float(reference)) > 1.0e-8
                    for actual, reference in zip(segment[field], expected[field])
                )
                for field in vector_fields
            )
            or segment.get("orientation_provenance")
            != expected["orientation_provenance"]
            or segment.get("side_semantics_version")
            != expected["side_semantics_version"]
        ):
            errors.append(
                {
                    "code": "shelf_segment_source_binding",
                    "message": (
                        f"第 {index} 个 shelf segment 未确定性绑定对应货架 geometry/yaw。"
                    ),
                }
            )

    if len(raw_segments) != len(inventory) or seen_segment_ids != set(inventory):
        errors.append(
            {
                "code": "shelf_segment_relation",
                "message": "shelves v2 的货架与 shelf segment 不是一对一关系。",
            }
        )


def _expected_shelf_segment(
    element: dict[str, Any] | None,
) -> dict[str, Any] | None:
    if not isinstance(element, dict) or element.get("shape_type") != "MapShelf":
        return None
    geometry = element.get("geometry")
    coordinates = geometry.get("coordinates") if isinstance(geometry, dict) else None
    if not isinstance(coordinates, list) or len(coordinates) < 3:
        return None
    points = [_finite_vector2(point) for point in coordinates]
    if any(point is None for point in points):
        return None
    finite_points = [point for point in points if point is not None]
    center_x = sum(point[0] for point in finite_points) / len(finite_points)
    center_y = sum(point[1] for point in finite_points) / len(finite_points)
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
        for index, point in enumerate(finite_points):
            following = finite_points[(index + 1) % len(finite_points)]
            dx = following[0] - point[0]
            dy = following[1] - point[1]
            length = math.hypot(dx, dy)
            if length > longest_length:
                longest_length = length
                axis = (dx / length, dy / length)
        if longest_length <= 1.0e-9:
            return None
        provenance = "unavailable"
    projections = [
        (point[0] - center_x) * axis[0] + (point[1] - center_y) * axis[1]
        for point in finite_points
    ]
    minimum = min(projections)
    maximum = max(projections)
    return {
        "longitudinal_start_m": [
            center_x + minimum * axis[0], center_y + minimum * axis[1]
        ],
        "longitudinal_end_m": [
            center_x + maximum * axis[0], center_y + maximum * axis[1]
        ],
        "longitudinal_axis": [axis[0], axis[1]],
        "front_normal": [axis[1], -axis[0]],
        "back_normal": [-axis[1], axis[0]],
        "side_semantics_version": 1,
        "orientation_provenance": provenance,
    }


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


def validate_package(
    directory: Path | str,
    *,
    allow_legacy_v2_identifier_for_diagnostics: bool = False,
) -> dict[str, Any]:
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
    manifest = _payload(
        root,
        "manifest.json",
        PACKAGE_FORMAT,
        errors,
        SUPPORTED_PACKAGE_VERSIONS,
    )
    if package_manifest is None or manifest is None:
        return {"valid": False, "errors": errors, "warnings": warnings}
    package_version = manifest.get("version")
    if type(package_version) is not int or package_version not in SUPPORTED_PACKAGE_VERSIONS:
        return {"valid": False, "errors": errors, "warnings": warnings}
    artifact_versions = frozenset({ARTIFACT_VERSION})
    elements_payload = _payload(
        root,
        "elements.json",
        "MarketScannerPriorMapElements",
        errors,
        artifact_versions,
    )
    shelves_payload = _payload(
        root,
        "shelves.json",
        "MarketScannerPriorMapShelves",
        errors,
        frozenset({1, 2}),
    )
    structures_payload = _payload(
        root,
        "fixed_structures.json",
        "MarketScannerPriorMapStructures",
        errors,
        artifact_versions,
    )
    graph = _payload(
        root,
        "road_graph.json",
        "MarketScannerRoadGraph",
        errors,
        artifact_versions,
    )
    spatial = _payload(
        root,
        "spatial_index.json",
        "MarketScannerSpatialIndex",
        errors,
        artifact_versions,
    )
    distance_fields = _payload(
        root,
        "distance_fields.json",
        "MarketScannerDistanceFields",
        errors,
        artifact_versions,
    )
    validation_report = _payload(
        root,
        "validation_report.json",
        "MarketScannerPriorMapValidation",
        errors,
        artifact_versions,
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
        )
    ):
        return {"valid": False, "errors": errors, "warnings": warnings}

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
    if not _valid_sha256(source_hash):
        errors.append({"code": "source_hash", "message": "地图包缺少有效的源文件 SHA-256。"})
    authoritative_canvas: dict[str, float] | None = None
    if package_version == PACKAGE_VERSION:
        canonical_hash = manifest.get("canonical_source_sha256")
        if not _valid_sha256(canonical_hash):
            errors.append(
                {
                    "code": "canonical_source_hash",
                    "message": "v2 地图包缺少有效的 canonical source SHA-256。",
                }
            )
        else:
            suffix = canonical_hash[:PRIOR_MAP_ID_HASH_PREFIX_LENGTH]
            accepted_ids = {
                f"{canonical_safe_name(manifest.get('name', ''))}-{suffix}",
            }
            if allow_legacy_v2_identifier_for_diagnostics:
                accepted_ids.add(
                    f"{legacy_safe_name(manifest.get('name', ''))}-{suffix}"
                )
            if manifest.get("prior_map_id") not in accepted_ids:
                errors.append(
                    {
                        "code": "map_id",
                        "message": (
                            "v2 prior_map_id 未绑定 canonical lowercase slug 与 "
                            "canonical source SHA-256；旧 uppercase 开发包只能"
                            "通过显式只读诊断模式检查，不能用于加载或定位。"
                        ),
                    }
                )
        expected_source_coordinate_system = {
            "unit": "centimetre",
            "origin": "top_left",
            "x_axis": "right",
            "y_axis": "down",
            "rotation_direction": "clockwise_degrees",
            "rectangle_anchor": "top_left",
            "rotation_pivot": "top_left_anchor",
        }
        if manifest.get("source_coordinate_system") != expected_source_coordinate_system:
            errors.append(
                {
                    "code": "source_coordinate_system",
                    "message": "v2 source coordinate contract 必须使用 top-left anchor/pivot。",
                }
            )
        if manifest.get("element_role_contract") != role_contract_payload():
            errors.append(
                {
                    "code": "element_role_contract",
                    "message": "v2 元素角色合同与唯一角色表不一致。",
                }
            )
        source_canvas = manifest.get("source_canvas")
        if not isinstance(source_canvas, dict):
            errors.append({"code": "source_canvas", "message": "v2 manifest 缺少 source_canvas。"})
        else:
            width_cm = source_canvas.get("width_cm")
            height_cm = source_canvas.get("height_cm")
            source_scale = source_canvas.get("source_scale")
            if (
                not _positive_finite(width_cm)
                or not _positive_finite(height_cm)
                or (source_scale is not None and not _positive_finite(source_scale))
            ):
                errors.append({"code": "source_canvas", "message": "v2 source_canvas 字段无效。"})
            else:
                authoritative_canvas = {
                    "min_x_m": 0.0,
                    "min_y_m": -float(height_cm) / 100.0,
                    "max_x_m": float(width_cm) / 100.0,
                    "max_y_m": 0.0,
                    "width_m": float(width_cm) / 100.0,
                    "height_m": float(height_cm) / 100.0,
                }
            source_map_info = manifest.get("source_map_info")
            if not isinstance(source_map_info, dict) or source_map_info != {
                "map_name": manifest.get("name"),
                "store_code": manifest.get("store_id"),
                "width_cm": width_cm,
                "height_cm": height_cm,
                "scale": source_scale,
            }:
                errors.append(
                    {
                        "code": "source_map_info",
                        "message": "v2 source_map_info 与业务身份/source_canvas 不一致。",
                    }
                )
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
        shape_type = str(element.get("shape_type"))
        if package_version == PACKAGE_VERSION:
            expected_role = role_for(shape_type)
            if (
                shape_type not in ACTIVE_TYPES
                or element.get("visible") is not True
                or element.get("role") != expected_role
            ):
                errors.append(
                    {
                        "code": "active_element_contract",
                        "message": (
                            f"v2 元素 {identifier or index + 1} 含非 active/hidden/错误角色记录。"
                        ),
                    }
                )
            center = element.get("center_m")
            if center is not None and (
                not isinstance(center, list)
                or len(center) != 2
                or not all(
                    isinstance(value, (int, float))
                    and not isinstance(value, bool)
                    and math.isfinite(float(value))
                    for value in center
                )
            ):
                errors.append(
                    {
                        "code": "element_center",
                        "message": f"v2 元素 {identifier or index + 1} 的 center_m 无效。",
                    }
                )
            yaw = element.get("yaw_rad")
            if yaw is not None and (
                not isinstance(yaw, (int, float))
                or isinstance(yaw, bool)
                or not math.isfinite(float(yaw))
            ):
                errors.append(
                    {
                        "code": "element_yaw",
                        "message": f"v2 元素 {identifier or index + 1} 的 yaw_rad 无效。",
                    }
                )
        points: list[tuple[float, float]]
        if package_version == PACKAGE_VERSION:
            validated_points = _production_geometry_points(
                shape_type, element.get("geometry")
            )
            if validated_points is None:
                errors.append(
                    {
                        "code": "active_geometry_contract",
                        "message": (
                            f"v2 元素 {identifier or index + 1} 的几何类型、点数或坐标无效。"
                        ),
                    }
                )
                points = []
            else:
                points = validated_points
        else:
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
            expected_bounds = _bounds(
                points, include_dimensions=package_version == PACKAGE_VERSION
            )
            if not _bounds_match(
                element.get("bounds"),
                expected_bounds,
                tolerance=1.0e-8 if package_version == PACKAGE_VERSION else 1.0e-5,
                exact_keys=package_version == PACKAGE_VERSION,
            ):
                errors.append(
                    {
                        "code": "element_bounds",
                        "message": f"元素 {identifier or index + 1} 的 bounds 与几何不一致。",
                    }
                )
            if (
                package_version == PACKAGE_VERSION
                and authoritative_canvas is not None
                and not _points_inside_bounds(points, authoritative_canvas)
            ):
                errors.append(
                    {
                        "code": "canvas_containment",
                        "message": f"v2 元素 {identifier or index + 1} 超出 Basic Info 画布。",
                    }
                )
        if shape_type in SUPPORTED_TYPES and not points:
            errors.append(
                {
                    "code": "geometry",
                    "message": f"受支持元素 {identifier or index + 1} 缺少几何数据。",
                }
            )

    if (
        type(manifest.get("element_count")) is not int
        or manifest.get("element_count") != len(elements)
    ):
        errors.append({"code": "element_count", "message": "manifest 元素数量与 elements.json 不一致。"})
    expected_statistics: dict[str, int] = {}
    for element in elements:
        if isinstance(element, dict):
            shape_type = str(element.get("shape_type"))
            expected_statistics[shape_type] = expected_statistics.get(shape_type, 0) + 1
    declared_statistics = manifest.get("element_statistics")
    expected_statistics = dict(sorted(expected_statistics.items()))
    if (
        not isinstance(declared_statistics, dict)
        or set(declared_statistics) != set(expected_statistics)
        or not all(
            type(declared_statistics.get(shape_type)) is int
            and declared_statistics.get(shape_type) == count
            for shape_type, count in expected_statistics.items()
        )
    ):
        errors.append({"code": "element_statistics", "message": "manifest 元素分类统计不一致。"})
    visible_count = sum(element.get("visible") is True for element in elements if isinstance(element, dict))
    if package_version == LEGACY_PACKAGE_VERSION:
        if (
            type(manifest.get("visible_element_count")) is not int
            or manifest.get("visible_element_count") != visible_count
            or type(manifest.get("hidden_element_count")) is not int
            or manifest.get("hidden_element_count")
            != len(elements) - visible_count
        ):
            errors.append({"code": "visibility_count", "message": "manifest 可见/隐藏元素统计不一致。"})
    else:
        role_counts = {
            ROLE_SHELF: sum(
                item.get("role") == ROLE_SHELF for item in elements if isinstance(item, dict)
            ),
            ROLE_FIXED_STRUCTURE: sum(
                item.get("role") == ROLE_FIXED_STRUCTURE
                for item in elements
                if isinstance(item, dict)
            ),
            "road": sum(
                item.get("role") == "road" for item in elements if isinstance(item, dict)
            ),
        }
        ignored_by_shape_type = manifest.get("ignored_by_shape_type")
        ignored_valid = (
            isinstance(ignored_by_shape_type, dict)
            and all(
                shape_type in PRESENTATION_ONLY_TYPES
                and type(count) is int
                and count >= 0
                for shape_type, count in ignored_by_shape_type.items()
            )
        )
        presentation_count = (
            sum(ignored_by_shape_type.values()) if ignored_valid else -1
        )
        expected_v2_counts = {
            "active_element_count": len(elements),
            "visible_element_count": len(elements),
            "shelf_count": role_counts[ROLE_SHELF],
            "fixed_structure_count": role_counts[ROLE_FIXED_STRUCTURE],
            "road_element_count": role_counts["road"],
            "presentation_ignored_count": presentation_count,
        }
        ignored_count_keys = (
            "unsupported_ignored_count",
            "hidden_element_count",
            "invalid_geometry_ignored_count",
        )
        ignored_counts_valid = all(
            type(manifest.get(key)) is int and manifest.get(key) >= 0
            for key in ignored_count_keys
        )
        expected_source_count = (
            len(elements)
            + presentation_count
            + sum(manifest.get(key, 0) for key in ignored_count_keys)
            if ignored_counts_valid
            else -1
        )
        if (
            not all(
                type(manifest.get(key)) is int
                and manifest.get(key) == expected
                for key, expected in expected_v2_counts.items()
            )
            or not ignored_valid
            or not ignored_counts_valid
            or type(manifest.get("source_element_count")) is not int
            or manifest.get("source_element_count") != expected_source_count
        ):
            errors.append(
                {
                    "code": "v2_element_counts",
                    "message": "v2 source/active/role/ignored 元素统计不一致。",
                }
            )
    for floor_id, record in floor_records.items():
        points = geometry_by_floor.get(floor_id, [])
        if not points:
            errors.append({"code": "floor_geometry", "message": f"楼层 {floor_id} 没有有效几何。"})
        elif package_version == LEGACY_PACKAGE_VERSION and not _bounds_match(
            record.get("bounds"), _bounds(points)
        ):
            errors.append({"code": "floor_bounds", "message": f"楼层 {floor_id} 的 bounds 与实际几何不一致。"})
        elif (
            package_version == PACKAGE_VERSION
            and authoritative_canvas is not None
            and not _bounds_match(
                record.get("bounds"),
                authoritative_canvas,
                tolerance=1.0e-8,
                exact_keys=True,
            )
        ):
            errors.append(
                {
                    "code": "floor_bounds",
                    "message": f"v2 楼层 {floor_id} bounds 不等于 Basic Info 画布。",
                }
            )
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
    if (
        package_version == LEGACY_PACKAGE_VERSION
        and all_points
        and not _bounds_match(manifest.get("bounds"), _bounds(all_points))
    ):
        errors.append({"code": "map_bounds", "message": "manifest 总体 bounds 与实际几何不一致。"})
    elif (
        package_version == PACKAGE_VERSION
        and authoritative_canvas is not None
        and not _bounds_match(
            manifest.get("bounds"),
            authoritative_canvas,
            tolerance=1.0e-8,
            exact_keys=True,
        )
    ):
        errors.append({"code": "map_bounds", "message": "v2 manifest bounds 不等于 Basic Info 画布。"})

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

    validate_subset(shelves_payload, "shelves", set(SHELF_TYPES), "shelves.json")
    _validate_shelves_document(
        shelves_payload,
        package_version=package_version,
        elements_by_id=elements_by_id,
        errors=errors,
    )
    validate_subset(
        structures_payload,
        "structures",
        set(FIXED_STRUCTURE_TYPES),
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

    if package_version == PACKAGE_VERSION:
        try:
            # Local import avoids a module cycle: the converter imports this
            # validator, while formal validation reuses the converter's one
            # deterministic spatial-index implementation.
            from .xlsx_reader import BasicMapInfo
            from .xlsx_to_prior_map import (
                _canonical_business_sha256,
                _road_graph,
                _spatial_index,
                _stable_element_id_for_context,
            )

            source_map_info = manifest["source_map_info"]
            basic_info = BasicMapInfo(
                map_name=str(source_map_info["map_name"]),
                width_cm=float(source_map_info["width_cm"]),
                height_cm=float(source_map_info["height_cm"]),
                store_code=str(source_map_info["store_code"]),
                source_scale=(
                    None
                    if source_map_info.get("scale") is None
                    else float(source_map_info["scale"])
                ),
            )
            stable_business_ids = [
                _stable_element_id_for_context(
                    element,
                    store_id=basic_info.store_code,
                    map_name=basic_info.map_name,
                )
                for element in elements
            ]
            if (
                any(not value for value in stable_business_ids)
                or len(set(stable_business_ids)) != len(stable_business_ids)
            ):
                errors.append(
                    {
                        "code": "duplicate_stable_element_id",
                        "message": "v2 elements.json 含重复 stable business identity。",
                    }
                )
            if (
                manifest.get("canonical_source_sha256")
                != _canonical_business_sha256(basic_info, elements)
            ):
                errors.append(
                    {
                        "code": "canonical_source_binding",
                        "message": "v2 canonical_source_sha256 与权威业务内容不一致。",
                    }
                )

            expected_graph = _road_graph(elements, [])
            if graph != expected_graph:
                errors.append(
                    {
                        "code": "road_graph_source_binding",
                        "message": "v2 road_graph 未确定性绑定道路元素。",
                    }
                )
            expected_spatial = _spatial_index(elements, expected_graph)
            if spatial != expected_spatial:
                errors.append(
                    {
                        "code": "spatial_source_binding",
                        "message": "v2 spatial_index 未确定性绑定 elements/road_graph。",
                    }
                )
            expected_distance = build_distance_fields(elements, floors)
            if distance_fields != expected_distance:
                errors.append(
                    {
                        "code": "distance_source_binding",
                        "message": "v2 distance_fields 未确定性绑定 elements/floor bounds。",
                    }
                )
        except (KeyError, TypeError, ValueError, OverflowError) as exc:
            errors.append(
                {
                    "code": "derived_artifact_binding",
                    "message": f"v2 派生空间工件无法从权威元素重建：{exc}",
                }
            )

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
        if element.get("shape_type") in STRUCTURE_TYPES
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
    if package_version == PACKAGE_VERSION:
        declared_roles = spatial.get("element_roles")
        if not isinstance(declared_roles, dict) or set(declared_roles) != expected_indexed_ids:
            errors.append(
                {
                    "code": "spatial_element_roles",
                    "message": "v2 spatial_index.element_roles 未精确覆盖结构元素。",
                }
            )
        else:
            for identifier, record in declared_roles.items():
                element = elements_by_id[identifier]
                if not isinstance(record, dict) or record != {
                    "role": role_for(str(element.get("shape_type"))),
                    "shape_type": element.get("shape_type"),
                }:
                    errors.append(
                        {
                            "code": "spatial_element_role",
                            "message": (
                                f"v2 spatial role/type 与元素不一致：{identifier}"
                            ),
                        }
                    )
                    break
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
        or distance_manifest.get("version") != distance_fields.get("version")
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
    total_distance_cells = 0
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
                    or any(
                        isinstance(value, bool)
                        or not isinstance(value, (int, float))
                        or not math.isfinite(float(value))
                        for value in level["origin_m"]
                    )
                    or isinstance(level.get("resolution_m"), bool)
                    or not isinstance(level.get("resolution_m"), (int, float))
                    or not math.isfinite(float(level["resolution_m"]))
                    or float(level["resolution_m"]) <= 0
                ):
                    raise ValueError("Distance-field metadata is invalid.")
                width = level.get("width")
                height = level.get("height")
                if type(width) is not int or type(height) is not int:
                    raise ValueError("Distance-field dimensions are not strict integers.")
                cells = width * height
                if cells < 1 or cells > MAXIMUM_TOTAL_CELLS - total_distance_cells:
                    raise ValueError("Distance-field total grid cell budget exceeded.")
                total_distance_cells += cells
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
    summary_counts_match = False
    if (
        isinstance(summary, dict)
        and isinstance(report_warnings, list)
        and isinstance(malformed_rows, list)
    ):
        expected_summary_counts = {
            "element_count": len(elements),
            "floor_count": len(floor_records),
            "node_count": len(nodes),
            "edge_count": len(edges),
            "malformed_row_count": len(malformed_rows),
            "warning_count": len(report_warnings) + len(malformed_rows),
        }
        if package_version == PACKAGE_VERSION:
            expected_summary_counts.update(
                {
                    "source_element_count": manifest.get("source_element_count"),
                    "active_element_count": len(elements),
                    "shelf_count": manifest.get("shelf_count"),
                    "fixed_structure_count": manifest.get("fixed_structure_count"),
                    "road_element_count": manifest.get("road_element_count"),
                    "presentation_ignored_count": manifest.get(
                        "presentation_ignored_count"
                    ),
                    "unsupported_ignored_count": manifest.get(
                        "unsupported_ignored_count"
                    ),
                    "hidden_element_count": manifest.get("hidden_element_count"),
                    "invalid_geometry_ignored_count": manifest.get(
                        "invalid_geometry_ignored_count"
                    ),
                }
            )
        summary_counts_match = all(
            type(summary.get(key)) is int and summary.get(key) == expected
            for key, expected in expected_summary_counts.items()
        ) and (
            type(manifest.get("warning_count")) is int
            and summary.get("warning_count") == manifest.get("warning_count")
        )
    if (
        validation_report.get("valid") is not True
        or not summary_counts_match
    ):
        errors.append({"code": "validation_report", "message": "validation_report.json 与地图包内容不一致。"})
    return {"valid": not errors, "errors": errors, "warnings": warnings}
