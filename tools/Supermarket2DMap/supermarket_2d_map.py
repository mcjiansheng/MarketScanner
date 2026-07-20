#!/usr/bin/env python3
"""
Generate a 2D supermarket map package from segmented RTAB-Map scan results.

This tool intentionally uses only Python's standard library so it can run in
the iOS project checkout without rebuilding RTAB-Map. It reads segment sidecar
files, RTAB-Map sqlite Node poses when available, optional projected point CSVs,
and writes a reproducible map package with occupancy, trajectory, price-tag and
quality-report outputs.
"""

from __future__ import annotations

import argparse
import csv
import dataclasses
import hashlib
import json
import math
import os
import sqlite3
import struct
import sys
import time
import zlib
from collections import defaultdict, deque
from contextlib import closing
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Sequence, Set, Tuple


UNKNOWN = 0
FREE = 1
OCCUPIED = 2
CONFLICT = 3

GRID_COLORS = {
    UNKNOWN: (224, 230, 233),
    FREE: (250, 252, 252),
    OCCUPIED: (34, 43, 47),
    CONFLICT: (224, 117, 52),
}
GRID_LAYER_DEFINITIONS = (
    ("unknown", "未知区域", UNKNOWN, True),
    ("free", "可通行区域", FREE, True),
    ("occupied", "墙体/货架/障碍", OCCUPIED, True),
    ("conflict", "结构冲突", CONFLICT, True),
)

PREVIEW_3D_PROFILES = {
    "quick": {"max_frames": 96, "pixel_step": 8, "max_points": 100000},
    "detailed": {"max_frames": 240, "pixel_step": 3, "max_points": 500000},
    "maximum": {"max_frames": 384, "pixel_step": 2, "max_points": 1000000},
}
DEFAULT_PREVIEW_3D_QUALITY = "maximum"

SCAN_MODE_CONTINUOUS_STREAMING = "continuous_streaming"
SCAN_MODE_SEGMENTED = "segmented"
SCAN_MODE_LEGACY_SINGLE_DATABASE = "legacy_single_database"
SCAN_MODE_MIXED = "mixed"

CV_32S = 4
CV_32F = 5


@dataclasses.dataclass
class Pose2D:
    node_id: int
    segment_index: int
    x: float
    y: float
    yaw: float = 0.0
    stamp: Optional[float] = None
    source: str = "db"
    height: float = 0.0


@dataclasses.dataclass
class PriceTag:
    tag_id: str
    payload: str
    segment_index: int
    node_count: Optional[int]
    raw_x: float
    raw_y: float
    yaw: float
    timestamp: Optional[float]
    snapped_x: Optional[float] = None
    snapped_y: Optional[float] = None
    confidence: float = 0.35
    needs_review: bool = True


@dataclasses.dataclass
class ProjectedPoint:
    x: float
    y: float
    z: float
    kind: str
    segment_index: int
    node_id: Optional[int] = None
    height: float = 0.0


@dataclasses.dataclass
class Segment:
    index: int
    directory: Path
    database_path: Optional[Path]
    metadata: Dict[str, Any]
    poses: List[Pose2D]
    price_tags: List[PriceTag]
    has_local_grid_blobs: bool = False
    sqlite_warnings: List[str] = dataclasses.field(default_factory=list)


@dataclasses.dataclass
class MapConfig:
    resolution: float
    preview_resolution: float
    trajectory_radius: float
    tag_snap_distance: float
    occupied_inflate_radius: float
    free_ray_max_range: float
    horizontal_axes: str
    auto_align_segments: bool


@dataclasses.dataclass
class CameraCalibration:
    width: int
    height: int
    fx: float
    fy: float
    cx: float
    cy: float
    local_transform: Tuple[float, ...]


@dataclasses.dataclass
class ShelfOutline:
    """Filtered floor-plan cells supported by vertically observed RGB-D surfaces."""

    cells: Set[Tuple[int, int]] = dataclasses.field(default_factory=set)
    components: List[List[Tuple[int, int]]] = dataclasses.field(default_factory=list)
    evidence_cell_count: int = 0
    candidate_cell_count: int = 0
    vertical_triangle_count: int = 0
    floor_height_m: Optional[float] = None
    minimum_height_span_m: float = 0.45

    def summary(self, resolution: float) -> Dict[str, Any]:
        return {
            "status": "available" if self.cells else "no_reliable_vertical_structure",
            "cell_count": len(self.cells),
            "component_count": len(self.components),
            "evidence_cell_count": self.evidence_cell_count,
            "candidate_cell_count": self.candidate_cell_count,
            "vertical_triangle_count": self.vertical_triangle_count,
            "floor_height_m": self.floor_height_m,
            "minimum_height_span_m": self.minimum_height_span_m,
            "line_coverage_m2": round(len(self.cells) * resolution * resolution, 3),
        }


def metadata_scan_mode(metadata: Dict[str, Any]) -> Optional[str]:
    """Normalize the iOS scan-mode marker while accepting early aliases."""
    raw = metadata.get("scanMode") or metadata.get("scan_mode")
    if not isinstance(raw, str):
        return None
    normalized = raw.strip().lower().replace("-", "_")
    if normalized in {"continuous", "streaming", "streaming_single_database", SCAN_MODE_CONTINUOUS_STREAMING}:
        return SCAN_MODE_CONTINUOUS_STREAMING
    if normalized in {"segment", "legacy_segmented", SCAN_MODE_SEGMENTED}:
        return SCAN_MODE_SEGMENTED
    return normalized or None


def session_scan_summary(segments: Sequence[Segment]) -> Dict[str, Any]:
    """Describe whether PC processing joins segments or reuses one graph."""
    explicit_modes = {
        mode
        for segment in segments
        for mode in [metadata_scan_mode(segment.metadata)]
        if mode is not None
    }
    has_streaming_marker = SCAN_MODE_CONTINUOUS_STREAMING in explicit_modes
    if has_streaming_marker and len(segments) == 1:
        scan_mode = SCAN_MODE_CONTINUOUS_STREAMING
    elif has_streaming_marker:
        scan_mode = SCAN_MODE_MIXED
    elif SCAN_MODE_SEGMENTED in explicit_modes or len(segments) > 1:
        scan_mode = SCAN_MODE_SEGMENTED
    else:
        scan_mode = SCAN_MODE_LEGACY_SINGLE_DATABASE

    database_count = sum(1 for segment in segments if segment.database_path is not None)
    finalized_values = [
        segment.metadata.get("finalized")
        for segment in segments
        if isinstance(segment.metadata.get("finalized"), bool)
    ]
    finalized: Optional[bool]
    if any(value is False for value in finalized_values):
        finalized = False
    elif len(finalized_values) == len(segments) and finalized_values:
        finalized = True
    else:
        finalized = None

    if scan_mode == SCAN_MODE_CONTINUOUS_STREAMING:
        strategy = "reuse_continuous_database"
    elif len(segments) > 1:
        strategy = "align_and_combine_segments"
    else:
        strategy = "reuse_single_database"

    return {
        "scan_mode": scan_mode,
        "segment_count": len(segments),
        "database_count": database_count,
        "merge_required": len(segments) > 1,
        "segment_alignment_supported": len(segments) > 1 and not has_streaming_marker,
        "processing_strategy": strategy,
        "finalized": finalized,
    }


def read_json(path: Path, default: Any) -> Any:
    try:
        with path.open("r", encoding="utf-8") as f:
            return json.load(f)
    except FileNotFoundError:
        return default
    except json.JSONDecodeError as exc:
        return {"_error": f"Invalid JSON: {exc}"}


def sha256_file(path: Path) -> Optional[str]:
    if not path.exists() or not path.is_file():
        return None
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def parse_rtabmap_transform_3d(blob: bytes, axes: str) -> Optional[Tuple[float, float, float, float]]:
    """Parse RTAB-Map Transform into map-plane x/y, height and yaw."""
    if not blob or len(blob) != 12 * 4:
        return None
    values = struct.unpack("<12f", blob)
    tx, ty, tz = values[3], values[7], values[11]
    yaw_xy = math.atan2(values[4], values[0])
    if axes == "xy":
        return tx, ty, tz, yaw_xy
    if axes == "xz":
        # Convert RTAB-Map's native frame to the iOS pose frame used by the
        # supermarket trajectory sidecars: ios(x,y,z)=(-native_y,native_z,-native_x).
        yaw_xz = math.atan2(-values[9], values[5])
        return -ty, -tx, tz, yaw_xz
    raise ValueError(f"Unsupported horizontal axes: {axes}")


def parse_transform_matrix(blob: bytes) -> Optional[Tuple[float, ...]]:
    if not blob or len(blob) != 12 * 4:
        return None
    return struct.unpack("<12f", blob)


def transform_xyz(matrix: Sequence[float], point: Sequence[float]) -> Tuple[float, float, float]:
    x, y, z = point
    return (
        matrix[0] * x + matrix[1] * y + matrix[2] * z + matrix[3],
        matrix[4] * x + matrix[5] * y + matrix[6] * z + matrix[7],
        matrix[8] * x + matrix[9] * y + matrix[10] * z + matrix[11],
    )


def parse_camera_calibration(blob: bytes) -> Optional[CameraCalibration]:
    """Read the first serialized RTAB-Map mono CameraModel."""
    if not blob or len(blob) < 44:
        return None
    header = struct.unpack_from("<11i", blob)
    if header[3] != 0:
        return None
    width, height = header[4], header[5]
    counts = header[6:10]
    if any(count < 0 for count in counts) or counts[0] not in {0, 9} or counts[3] not in {0, 12}:
        return None
    matrix_bytes = sum(counts) * 8
    local_size = header[10]
    required = 44 + matrix_bytes + local_size * 4
    if width <= 0 or height <= 0 or len(blob) < required:
        return None
    if counts[3] == 12:
        projection_offset = 44 + sum(counts[:3]) * 8
        projection = struct.unpack_from("<12d", blob, projection_offset)
        fx, fy, cx, cy = projection[0], projection[5], projection[2], projection[6]
    elif counts[0] == 9:
        camera_matrix = struct.unpack_from("<9d", blob, 44)
        fx, fy, cx, cy = camera_matrix[0], camera_matrix[4], camera_matrix[2], camera_matrix[5]
    else:
        return None
    local_offset = 44 + matrix_bytes
    if local_size == 12:
        local_transform = struct.unpack_from("<12f", blob, local_offset)
    elif local_size == 0:
        local_transform = (1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0)
    else:
        return None
    if fx <= 0.0 or fy <= 0.0:
        return None
    return CameraCalibration(width, height, fx, fy, cx, cy, local_transform)


def _paeth_predictor(left: int, above: int, upper_left: int) -> int:
    estimate = left + above - upper_left
    left_distance = abs(estimate - left)
    above_distance = abs(estimate - above)
    upper_left_distance = abs(estimate - upper_left)
    if left_distance <= above_distance and left_distance <= upper_left_distance:
        return left
    return above if above_distance <= upper_left_distance else upper_left


def decode_png_pixels(blob: bytes) -> Tuple[int, int, int, int, bytes]:
    """Decode non-interlaced 8/16-bit PNG scanlines using only stdlib."""
    if not blob.startswith(b"\x89PNG\r\n\x1a\n"):
        raise ValueError("Depth image is not PNG encoded.")
    offset = 8
    width = height = bit_depth = color_type = interlace = 0
    compressed = bytearray()
    while offset + 12 <= len(blob):
        length = struct.unpack_from(">I", blob, offset)[0]
        chunk_type = blob[offset + 4 : offset + 8]
        payload_start = offset + 8
        payload_end = payload_start + length
        if payload_end + 4 > len(blob):
            raise ValueError("PNG chunk is truncated.")
        payload = blob[payload_start:payload_end]
        if chunk_type == b"IHDR":
            width, height, bit_depth, color_type, _compression, _filter, interlace = struct.unpack(">IIBBBBB", payload)
        elif chunk_type == b"IDAT":
            compressed.extend(payload)
        elif chunk_type == b"IEND":
            break
        offset = payload_end + 4

    channels = {0: 1, 2: 3, 4: 2, 6: 4}.get(color_type, 0)
    if width <= 0 or height <= 0 or channels == 0 or bit_depth not in {8, 16} or interlace != 0:
        raise ValueError(f"Unsupported PNG layout: {width}x{height}, depth={bit_depth}, color={color_type}, interlace={interlace}")
    bytes_per_pixel = channels * (bit_depth // 8)
    row_size = width * bytes_per_pixel
    raw = zlib.decompress(bytes(compressed))
    if len(raw) != height * (row_size + 1):
        raise ValueError("PNG scanline size does not match its header.")

    decoded = bytearray(height * row_size)
    previous = bytearray(row_size)
    source_offset = 0
    for row_index in range(height):
        filter_type = raw[source_offset]
        source_offset += 1
        row = bytearray(raw[source_offset : source_offset + row_size])
        source_offset += row_size
        for index in range(row_size):
            left = row[index - bytes_per_pixel] if index >= bytes_per_pixel else 0
            above = previous[index]
            upper_left = previous[index - bytes_per_pixel] if index >= bytes_per_pixel else 0
            if filter_type == 1:
                row[index] = (row[index] + left) & 0xFF
            elif filter_type == 2:
                row[index] = (row[index] + above) & 0xFF
            elif filter_type == 3:
                row[index] = (row[index] + ((left + above) // 2)) & 0xFF
            elif filter_type == 4:
                row[index] = (row[index] + _paeth_predictor(left, above, upper_left)) & 0xFF
            elif filter_type != 0:
                raise ValueError(f"Unsupported PNG filter type: {filter_type}")
        destination = row_index * row_size
        decoded[destination : destination + row_size] = row
        previous = row
    return width, height, bit_depth, color_type, bytes(decoded)


def decode_depth_image(blob: bytes) -> Tuple[int, int, List[float]]:
    width, height, bit_depth, color_type, pixels = decode_png_pixels(blob)
    if color_type == 6 and bit_depth == 8:
        # OpenCV writes CV_32FC1 as BGRA bytes in a PNG RGBA image. Restore
        # channel order before interpreting each four bytes as a float.
        float_bytes = bytearray(len(pixels))
        for offset in range(0, len(pixels), 4):
            float_bytes[offset : offset + 4] = bytes((pixels[offset + 2], pixels[offset + 1], pixels[offset], pixels[offset + 3]))
        values = [value[0] for value in struct.iter_unpack("<f", float_bytes)]
        return width, height, values
    if color_type == 0 and bit_depth == 16:
        values = [value[0] / 1000.0 for value in struct.iter_unpack(">H", pixels)]
        return width, height, values
    raise ValueError(f"Unsupported RTAB-Map depth PNG: bit_depth={bit_depth}, color_type={color_type}")


def parse_rtabmap_transform(blob: bytes, axes: str) -> Optional[Tuple[float, float, float]]:
    parsed = parse_rtabmap_transform_3d(blob, axes)
    if parsed is None:
        return None
    x, y, _height, yaw = parsed
    return x, y, yaw


def table_columns(conn: sqlite3.Connection, table: str) -> List[str]:
    return [row[1] for row in conn.execute(f"PRAGMA table_info({table})")]


def sqlite_tables(conn: sqlite3.Connection) -> List[str]:
    rows = conn.execute("SELECT name FROM sqlite_master WHERE type='table'").fetchall()
    return [row[0] for row in rows]


def uncompress_cv_matrix(blob: Optional[bytes], expected_type: int) -> Optional[Tuple[int, int, bytes]]:
    """Decode RTAB-Map's compressData2() payload without requiring OpenCV.

    The final three native-endian int32 values contain rows, columns and the
    OpenCV matrix type. zlib ignores those trailing values while inflating the
    matrix bytes, matching corelib/src/Compression.cpp::uncompressData().
    """
    if blob is None or len(blob) < 12:
        return None
    rows, columns, matrix_type = struct.unpack_from("<3i", blob, len(blob) - 12)
    if rows <= 0 or columns <= 0 or matrix_type != expected_type:
        return None
    element_size = 4
    expected_size = rows * columns * element_size
    if expected_size <= 0 or expected_size > 512 * 1024 * 1024:
        return None
    try:
        payload = zlib.decompress(blob)
    except zlib.error:
        return None
    if len(payload) != expected_size:
        return None
    return rows, columns, payload


def extract_optimized_pose_blobs(conn: sqlite3.Connection) -> Dict[int, bytes]:
    """Return the globally optimized graph saved in Admin.opt_poses.

    Node.pose is RTAB-Map's odometry input and intentionally remains unchanged
    after graph optimization. Admin.opt_poses is therefore the authoritative
    trajectory for PC map assembly when it is present.
    """
    if "Admin" not in set(sqlite_tables(conn)):
        return {}
    columns = set(table_columns(conn, "Admin"))
    if not {"opt_ids", "opt_poses"}.issubset(columns):
        return {}
    try:
        rows = conn.execute(
            "SELECT opt_ids, opt_poses FROM Admin "
            "WHERE length(opt_ids)>0 AND length(opt_poses)>0 ORDER BY rowid DESC"
        ).fetchall()
    except sqlite3.Error:
        return {}
    for ids_blob, poses_blob in rows:
        ids_matrix = uncompress_cv_matrix(ids_blob, CV_32S)
        poses_matrix = uncompress_cv_matrix(poses_blob, CV_32F)
        if ids_matrix is None or poses_matrix is None:
            continue
        _ids_rows, ids_columns, ids_payload = ids_matrix
        _poses_rows, poses_columns, poses_payload = poses_matrix
        node_ids = [value[0] for value in struct.iter_unpack("<i", ids_payload)]
        pose_values = [value[0] for value in struct.iter_unpack("<f", poses_payload)]
        if len(node_ids) != ids_columns or len(pose_values) != poses_columns:
            continue
        if len(pose_values) != len(node_ids) * 12:
            continue
        return {
            int(node_id): struct.pack("<12f", *pose_values[index * 12 : (index + 1) * 12])
            for index, node_id in enumerate(node_ids)
        }
    return {}


def extract_db_poses(db_path: Path, segment_index: int, axes: str) -> Tuple[List[Pose2D], bool, List[str]]:
    poses: List[Pose2D] = []
    warnings: List[str] = []
    has_grid_blobs = False
    if not db_path.exists():
        return poses, has_grid_blobs, [f"Database not found: {db_path}"]

    try:
        conn = sqlite3.connect(str(db_path))
    except sqlite3.Error as exc:
        return poses, has_grid_blobs, [f"Cannot open sqlite database {db_path}: {exc}"]

    try:
        tables = set(sqlite_tables(conn))
        if "Data" in tables:
            columns = set(table_columns(conn, "Data"))
            has_grid_blobs = bool({"ground_cells", "obstacle_cells", "empty_cells"} & columns)

        if "Node" not in tables:
            warnings.append("No Node table found; trajectory will rely on sidecar/CSV only.")
            return poses, has_grid_blobs, warnings

        columns = table_columns(conn, "Node")
        if "id" not in columns or "pose" not in columns:
            warnings.append("Node table has no id/pose columns.")
            return poses, has_grid_blobs, warnings

        optimized_pose_blobs = extract_optimized_pose_blobs(conn)
        stamp_expr = "stamp" if "stamp" in columns else "NULL AS stamp"
        query = f"SELECT id, pose, {stamp_expr} FROM Node ORDER BY id"
        for node_id, pose_blob, stamp in conn.execute(query):
            optimized_blob = optimized_pose_blobs.get(int(node_id))
            parsed = parse_rtabmap_transform_3d(optimized_blob or pose_blob, axes)
            if parsed is None:
                continue
            x, y, height, yaw = parsed
            poses.append(
                Pose2D(
                    node_id=int(node_id),
                    segment_index=segment_index,
                    x=x,
                    y=y,
                    yaw=yaw,
                    stamp=float(stamp) if stamp is not None else None,
                    height=height,
                    source="db_optimized" if optimized_blob is not None else "db",
                )
            )
        if optimized_pose_blobs:
            optimized_count = sum(1 for pose in poses if pose.source == "db_optimized")
            warnings.append(
                f"Using {optimized_count} globally optimized poses from Admin.opt_poses "
                f"({len(poses) - optimized_count} odometry-pose fallbacks)."
            )
    except sqlite3.Error as exc:
        warnings.append(f"SQLite read failed: {exc}")
    finally:
        conn.close()

    if not poses:
        warnings.append("No valid Node.pose transforms could be parsed.")
    return poses, has_grid_blobs, warnings


def project_xy(x: float, y: float, z: float, axes: str) -> Tuple[float, float]:
    if axes == "xy":
        return x, y
    if axes == "xz":
        return x, z
    raise ValueError(f"Unsupported horizontal axes: {axes}")


def load_price_tags(path: Path, axes: str) -> List[PriceTag]:
    raw_tags = read_json(path, [])
    if not isinstance(raw_tags, list):
        return []
    tags: List[PriceTag] = []
    for raw in raw_tags:
        if not isinstance(raw, dict):
            continue
        x = float(raw.get("x", 0.0))
        y = float(raw.get("y", 0.0))
        z = float(raw.get("z", 0.0))
        px, py = project_xy(x, y, z, axes)
        tags.append(
            PriceTag(
                tag_id=str(raw.get("tagIdentifier") or raw.get("id") or ""),
                payload=str(raw.get("payload") or ""),
                segment_index=int(raw.get("segmentIndex") or raw.get("segment_index") or 0),
                node_count=int(raw["nodeCount"]) if raw.get("nodeCount") is not None else None,
                raw_x=px,
                raw_y=py,
                yaw=float(raw.get("yaw", 0.0)),
                timestamp=float(raw["timestamp"]) if raw.get("timestamp") is not None else None,
            )
        )
    return tags


def load_trajectory_samples(segment_dir: Path, segment_index: int, axes: str) -> List[Pose2D]:
    rows: List[Dict[str, Any]] = []
    json_path = segment_dir / "trajectory_samples.json"
    raw_json = read_json(json_path, [])
    if isinstance(raw_json, list):
        rows = [row for row in raw_json if isinstance(row, dict)]
    if not rows:
        csv_path = segment_dir / "trajectory_samples.csv"
        if csv_path.is_file():
            with csv_path.open("r", encoding="utf-8", newline="") as stream:
                rows = [dict(row) for row in csv.DictReader(stream)]

    poses: List[Pose2D] = []
    for row_index, row in enumerate(rows, start=1):
        try:
            x = float(row.get("x", 0.0))
            y = float(row.get("y", 0.0))
            z = float(row.get("z", 0.0))
            yaw = float(row.get("yaw", 0.0))
            node_id = int(float(row.get("nodeCount") or row.get("node_id") or row_index))
            stamp_raw = row.get("timestamp") or row.get("stamp")
            stamp = float(stamp_raw) if stamp_raw not in (None, "") else None
        except (TypeError, ValueError):
            continue
        px, py = project_xy(x, y, z, axes)
        poses.append(
            Pose2D(
                node_id=node_id,
                segment_index=segment_index,
                x=px,
                y=py,
                yaw=yaw,
                stamp=stamp,
                source="trajectory_samples",
                height=y if axes == "xz" else z,
            )
        )
    return poses


def require_map_evidence(segments: Sequence[Segment], points: Sequence[ProjectedPoint]) -> None:
    pose_count = sum(len(segment.poses) for segment in segments)
    if pose_count == 0 and not points:
        raise ValueError(
            "No valid trajectory or structure points were found. Check the segment databases and trajectory_samples files."
        )


def discover_segments(
    session_dir: Path,
    config: MapConfig,
    database_overrides: Optional[Dict[int, Path]] = None,
) -> List[Segment]:
    segment_dirs = sorted([p for p in session_dir.glob("segment_*") if p.is_dir()])
    segments: List[Segment] = []
    for idx, segment_dir in enumerate(segment_dirs, start=1):
        suffix = segment_dir.name.split("_")[-1]
        try:
            segment_index = int(suffix)
        except ValueError:
            segment_index = idx

        metadata = read_json(segment_dir / "metadata.json", {})
        expected_database = segment_dir / f"rtabmap_segment_{segment_index:04d}.db"
        db_candidates = sorted(path for path in segment_dir.glob("*.db") if not path.name.startswith("."))
        override = database_overrides.get(segment_index) if database_overrides else None
        if override is not None and not override.is_file():
            raise ValueError(f"Optimized database override does not exist: {override}")
        database_path = override or (expected_database if expected_database.is_file() else (db_candidates[0] if db_candidates else None))
        poses: List[Pose2D] = []
        has_grids = False
        warnings: List[str] = []
        if database_path:
            poses, has_grids, warnings = extract_db_poses(database_path, segment_index, config.horizontal_axes)
        if not poses:
            sidecar_poses = load_trajectory_samples(segment_dir, segment_index, config.horizontal_axes)
            if sidecar_poses:
                poses = sidecar_poses
                warnings.append("Using trajectory_samples sidecar because database poses were unavailable.")
        price_tags = load_price_tags(segment_dir / "price_tags.json", config.horizontal_axes)
        for tag in price_tags:
            if tag.segment_index == 0:
                tag.segment_index = segment_index

        segments.append(
            Segment(
                index=segment_index,
                directory=segment_dir,
                database_path=database_path,
                metadata=metadata if isinstance(metadata, dict) else {},
                poses=poses,
                price_tags=price_tags,
                has_local_grid_blobs=has_grids,
                sqlite_warnings=warnings,
            )
        )

    if not segments:
        metadata = read_json(session_dir / "metadata.json", {})
        tags = load_price_tags(session_dir / "price_tags.json", config.horizontal_axes)
        segments.append(Segment(1, session_dir, None, metadata if isinstance(metadata, dict) else {}, [], tags))

    scan_summary = session_scan_summary(segments)
    if scan_summary["scan_mode"] == SCAN_MODE_MIXED:
        raise ValueError(
            "A continuous_streaming database cannot be combined with additional segment_* directories in one session. "
            "Remove duplicate/legacy segment directories or process them as separate sessions."
        )
    return segments


def load_projected_points(paths: Sequence[Path], axes: str) -> List[ProjectedPoint]:
    points: List[ProjectedPoint] = []
    for path in paths:
        if not path.exists():
            continue
        with path.open("r", encoding="utf-8", newline="") as f:
            reader = csv.DictReader(f)
            for row in reader:
                try:
                    x = float(row.get("x", 0.0))
                    y = float(row.get("y", 0.0))
                    z = float(row.get("z", 0.0))
                except ValueError:
                    continue
                px, py = project_xy(x, y, z, axes)
                kind = (row.get("kind") or row.get("type") or "occupied").strip().lower()
                segment_index = int(row.get("segmentIndex") or row.get("segment_index") or 0)
                node_raw = row.get("nodeId") or row.get("node_id")
                points.append(
                    ProjectedPoint(
                        x=px,
                        y=py,
                        z=z,
                        kind=kind,
                        segment_index=segment_index,
                        node_id=int(node_raw) if node_raw else None,
                        height=y if axes == "xz" else z,
                    )
                )
    return points


def transform_point(x: float, y: float, dx: float, dy: float, yaw: float) -> Tuple[float, float]:
    c, s = math.cos(yaw), math.sin(yaw)
    return c * x - s * y + dx, s * x + c * y + dy


def apply_segment_transforms(
    segments: List[Segment],
    points: List[ProjectedPoint],
    corrections_path: Optional[Path],
    auto_align: bool,
) -> Dict[int, Dict[str, float]]:
    transforms: Dict[int, Dict[str, float]] = defaultdict(lambda: {"dx": 0.0, "dy": 0.0, "yaw": 0.0})
    if corrections_path and corrections_path.exists():
        corrections = read_json(corrections_path, {})
        raw = corrections.get("segment_transforms", {}) if isinstance(corrections, dict) else {}
        if isinstance(raw, list):
            raw = {str(item.get("segment")): item for item in raw if isinstance(item, dict)}
        if isinstance(raw, dict):
            for key, item in raw.items():
                if not isinstance(item, dict):
                    continue
                try:
                    segment_id = int(key)
                except ValueError:
                    segment_id = int(item.get("segment", 0))
                transforms[segment_id] = {
                    "dx": float(item.get("dx", 0.0)),
                    "dy": float(item.get("dy", 0.0)),
                    "yaw": math.radians(float(item.get("yaw_deg", 0.0))) if "yaw_deg" in item else float(item.get("yaw", 0.0)),
                }

    if auto_align:
        previous_last: Optional[Pose2D] = None
        for segment in sorted(segments, key=lambda s: s.index):
            if not segment.poses:
                continue
            if previous_last is not None and segment.index not in transforms:
                first = segment.poses[0]
                transforms[segment.index] = {
                    "dx": previous_last.x - first.x,
                    "dy": previous_last.y - first.y,
                    "yaw": previous_last.yaw - first.yaw,
                }
            tr = transforms[segment.index]
            for pose in segment.poses:
                pose.x, pose.y = transform_point(pose.x, pose.y, tr["dx"], tr["dy"], tr["yaw"])
                pose.yaw += tr["yaw"]
            previous_last = segment.poses[-1]
    else:
        for segment in segments:
            tr = transforms[segment.index]
            for pose in segment.poses:
                pose.x, pose.y = transform_point(pose.x, pose.y, tr["dx"], tr["dy"], tr["yaw"])
                pose.yaw += tr["yaw"]

    for segment in segments:
        tr = transforms[segment.index]
        for tag in segment.price_tags:
            tag.raw_x, tag.raw_y = transform_point(tag.raw_x, tag.raw_y, tr["dx"], tr["dy"], tr["yaw"])
            tag.yaw += tr["yaw"]
    for point in points:
        tr = transforms[point.segment_index]
        point.x, point.y = transform_point(point.x, point.y, tr["dx"], tr["dy"], tr["yaw"])
    return dict(transforms)


class OccupancyGrid:
    def __init__(self, resolution: float, points: Sequence[Tuple[float, float]], margin: float) -> None:
        if not points:
            points = [(0.0, 0.0)]
        xs = [p[0] for p in points]
        ys = [p[1] for p in points]
        self.resolution = resolution
        self.origin_x = math.floor((min(xs) - margin) / resolution) * resolution
        self.origin_y = math.floor((min(ys) - margin) / resolution) * resolution
        max_x = math.ceil((max(xs) + margin) / resolution) * resolution
        max_y = math.ceil((max(ys) + margin) / resolution) * resolution
        self.width = max(1, int(math.ceil((max_x - self.origin_x) / resolution)) + 1)
        self.height = max(1, int(math.ceil((max_y - self.origin_y) / resolution)) + 1)
        self.free = [[0 for _ in range(self.width)] for _ in range(self.height)]
        self.occ = [[0 for _ in range(self.width)] for _ in range(self.height)]

    def cell(self, x: float, y: float) -> Tuple[int, int]:
        return int(round((x - self.origin_x) / self.resolution)), int(round((y - self.origin_y) / self.resolution))

    def world(self, ix: int, iy: int) -> Tuple[float, float]:
        return self.origin_x + ix * self.resolution, self.origin_y + iy * self.resolution

    def in_bounds(self, ix: int, iy: int) -> bool:
        return 0 <= ix < self.width and 0 <= iy < self.height

    def add_disk(self, x: float, y: float, radius: float, occupied: bool) -> None:
        cx, cy = self.cell(x, y)
        r = max(0, int(math.ceil(radius / self.resolution)))
        for iy in range(cy - r, cy + r + 1):
            for ix in range(cx - r, cx + r + 1):
                if not self.in_bounds(ix, iy):
                    continue
                wx, wy = self.world(ix, iy)
                if (wx - x) ** 2 + (wy - y) ** 2 <= radius * radius:
                    if occupied:
                        self.occ[iy][ix] += 1
                    else:
                        self.free[iy][ix] += 1

    def add_line(self, a: Tuple[float, float], b: Tuple[float, float], occupied: bool) -> None:
        x0, y0 = self.cell(*a)
        x1, y1 = self.cell(*b)
        dx = abs(x1 - x0)
        dy = -abs(y1 - y0)
        sx = 1 if x0 < x1 else -1
        sy = 1 if y0 < y1 else -1
        err = dx + dy
        x, y = x0, y0
        while True:
            if self.in_bounds(x, y):
                if occupied:
                    self.occ[y][x] += 1
                else:
                    self.free[y][x] += 1
            if x == x1 and y == y1:
                break
            e2 = 2 * err
            if e2 >= dy:
                err += dy
                x += sx
            if e2 <= dx:
                err += dx
                y += sy

    def classify(self, ix: int, iy: int) -> int:
        occ = self.occ[iy][ix]
        free = self.free[iy][ix]
        if 0 < occ < 3 and free >= 3:
            return CONFLICT
        if occ > 0:
            return OCCUPIED
        if free > 0:
            return FREE
        return UNKNOWN

    def class_counts(self) -> Dict[str, int]:
        counts = {"unknown": 0, "free": 0, "occupied": 0, "conflict": 0}
        names = {UNKNOWN: "unknown", FREE: "free", OCCUPIED: "occupied", CONFLICT: "conflict"}
        for iy in range(self.height):
            for ix in range(self.width):
                counts[names[self.classify(ix, iy)]] += 1
        return counts


def build_grid(segments: List[Segment], points: List[ProjectedPoint], config: MapConfig) -> OccupancyGrid:
    all_xy: List[Tuple[float, float]] = []
    for segment in segments:
        all_xy.extend((pose.x, pose.y) for pose in segment.poses)
        all_xy.extend((tag.raw_x, tag.raw_y) for tag in segment.price_tags)
    all_xy.extend((point.x, point.y) for point in points)
    grid = OccupancyGrid(config.resolution, all_xy, margin=max(4.0, config.trajectory_radius * 2.0))

    for segment in segments:
        poses = segment.poses
        for a, b in zip(poses, poses[1:]):
            grid.add_line((a.x, a.y), (b.x, b.y), occupied=False)
        for pose in poses:
            grid.add_disk(pose.x, pose.y, config.trajectory_radius, occupied=False)

    poses_by_segment: Dict[int, List[Pose2D]] = {s.index: s.poses for s in segments}
    for point in points:
        if point.kind in {"free", "empty", "ground"}:
            grid.add_disk(point.x, point.y, config.resolution, occupied=False)
            continue
        if point.kind == "depth_surface":
            grid.add_disk(point.x, point.y, config.occupied_inflate_radius, occupied=True)
            continue
        nearest_pose = nearest(point.x, point.y, poses_by_segment.get(point.segment_index, []))
        if nearest_pose is not None:
            distance = math.hypot(point.x - nearest_pose.x, point.y - nearest_pose.y)
            if distance <= config.free_ray_max_range:
                grid.add_line((nearest_pose.x, nearest_pose.y), (point.x, point.y), occupied=False)
        grid.add_disk(point.x, point.y, config.occupied_inflate_radius, occupied=True)
    return grid


def nearest(x: float, y: float, poses: Sequence[Pose2D]) -> Optional[Pose2D]:
    best: Optional[Pose2D] = None
    best_d2 = float("inf")
    for pose in poses:
        d2 = (pose.x - x) ** 2 + (pose.y - y) ** 2
        if d2 < best_d2:
            best = pose
            best_d2 = d2
    return best


def snap_price_tags(tags: Iterable[PriceTag], points: Sequence[ProjectedPoint], max_distance: float) -> None:
    occupied = [p for p in points if p.kind not in {"free", "empty", "ground"}]
    for tag in tags:
        best = None
        best_dist = max_distance
        for point in occupied:
            d = math.hypot(tag.raw_x - point.x, tag.raw_y - point.y)
            if d < best_dist:
                best = point
                best_dist = d
        if best is None:
            tag.snapped_x = tag.raw_x
            tag.snapped_y = tag.raw_y
            tag.confidence = 0.35
            tag.needs_review = True
        else:
            tag.snapped_x = best.x
            tag.snapped_y = best.y
            tag.confidence = max(0.5, 1.0 - best_dist / max_distance)
            tag.needs_review = tag.confidence < 0.7


def png_chunk(kind: bytes, data: bytes) -> bytes:
    crc = zlib.crc32(kind)
    crc = zlib.crc32(data, crc)
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", crc & 0xFFFFFFFF)


def write_png(path: Path, width: int, height: int, rgb_rows: Sequence[bytes]) -> None:
    raw = b"".join(b"\x00" + row for row in rgb_rows)
    payload = (
        b"\x89PNG\r\n\x1a\n"
        + png_chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
        + png_chunk(b"IDAT", zlib.compress(raw, 9))
        + png_chunk(b"IEND", b"")
    )
    path.write_bytes(payload)


def render_grid(
    grid: OccupancyGrid,
    path: Path,
    trajectories: Sequence[Pose2D] = (),
    tags: Sequence[PriceTag] = (),
) -> None:
    pixels = [[GRID_COLORS[grid.classify(ix, iy)] for ix in range(grid.width)] for iy in range(grid.height)]

    def paint_cell(ix: int, iy: int, color: Tuple[int, int, int], radius_cells: int) -> None:
        for yy in range(iy - radius_cells, iy + radius_cells + 1):
            for xx in range(ix - radius_cells, ix + radius_cells + 1):
                if grid.in_bounds(xx, yy):
                    pixels[yy][xx] = color

    def paint_line(first: Tuple[int, int], second: Tuple[int, int], color: Tuple[int, int, int]) -> None:
        x0, y0 = first
        x1, y1 = second
        dx = abs(x1 - x0)
        sx = 1 if x0 < x1 else -1
        dy = -abs(y1 - y0)
        sy = 1 if y0 < y1 else -1
        error = dx + dy
        while True:
            paint_cell(x0, y0, color, 1)
            if x0 == x1 and y0 == y1:
                break
            doubled = 2 * error
            if doubled >= dy:
                error += dy
                x0 += sx
            if doubled <= dx:
                error += dx
                y0 += sy

    trajectories_by_segment: Dict[int, List[Pose2D]] = defaultdict(list)
    for pose in trajectories:
        trajectories_by_segment[pose.segment_index].append(pose)
    for segment_poses in trajectories_by_segment.values():
        previous_cell: Optional[Tuple[int, int]] = None
        for pose in segment_poses:
            current_cell = grid.cell(pose.x, pose.y)
            if previous_cell is not None:
                paint_line(previous_cell, current_cell, (35, 110, 230))
            else:
                paint_cell(*current_cell, (35, 110, 230), 1)
            previous_cell = current_cell
    for tag in tags:
        tag_cell = grid.cell(
            tag.snapped_x if tag.snapped_x is not None else tag.raw_x,
            tag.snapped_y if tag.snapped_y is not None else tag.raw_y,
        )
        paint_cell(*tag_cell, (18, 96, 57), 3)
        paint_cell(*tag_cell, (65, 200, 118), 1)

    rows: List[bytes] = []
    for iy in range(grid.height - 1, -1, -1):
        row = bytearray()
        for r, g, b in pixels[iy]:
            row.extend((r, g, b))
        rows.append(bytes(row))
    write_png(path, grid.width, grid.height, rows)


def write_preview_layers(
    path: Path,
    grid: OccupancyGrid,
    segments: Sequence[Segment],
    tags: Sequence[PriceTag],
    shelf_outline: Optional[ShelfOutline] = None,
    trajectory_point_limit: int = 100_000,
) -> Dict[str, Any]:
    """Write lightweight layer controls without duplicating the full grid image."""
    segment_paths: List[Dict[str, Any]] = []
    total_points = 0
    raw_paths: List[Tuple[int, List[List[int]]]] = []
    for segment in segments:
        pixels: List[List[int]] = []
        previous: Optional[List[int]] = None
        for pose in segment.poses:
            ix, iy = grid.cell(pose.x, pose.y)
            if not grid.in_bounds(ix, iy):
                continue
            current = [ix, grid.height - 1 - iy]
            if current != previous:
                pixels.append(current)
                previous = current
        if pixels:
            raw_paths.append((segment.index, pixels))
            total_points += len(pixels)

    stride = max(1, math.ceil(total_points / max(1, trajectory_point_limit)))
    for segment_index, pixels in raw_paths:
        sampled = pixels[::stride]
        if sampled[-1] != pixels[-1]:
            sampled.append(pixels[-1])
        segment_paths.append({"segment": segment_index, "points": sampled})

    tag_entries = []
    for tag in tags:
        x = tag.snapped_x if tag.snapped_x is not None else tag.raw_x
        y = tag.snapped_y if tag.snapped_y is not None else tag.raw_y
        ix, iy = grid.cell(x, y)
        if grid.in_bounds(ix, iy):
            tag_entries.append(
                {
                    "id": tag.tag_id,
                    "pixel": [ix, grid.height - 1 - iy],
                    "needs_review": tag.needs_review,
                }
            )

    layers = [
        {
            "id": layer_id,
            "label": label,
            "kind": "structure_class",
            "class_value": class_value,
            "color": list(GRID_COLORS[class_value]),
            "default_visible": default_visible,
        }
        for layer_id, label, class_value, default_visible in GRID_LAYER_DEFINITIONS
    ]
    layers.append(
        {
            "id": "shelf_outline",
            "label": "货架/竖直结构轮廓",
            "kind": "shelf_outline",
            "color": [12, 16, 18],
            "default_visible": True,
        }
    )
    layers.extend(
        (
            {
                "id": "metric_grid",
                "label": "米制网格",
                "kind": "metric_grid",
                "color": [92, 108, 117],
                "default_visible": False,
            },
            {
                "id": "trajectory",
                "label": "扫描轨迹",
                "kind": "trajectory",
                "color": [35, 110, 230],
                "default_visible": True,
            },
            {
                "id": "price_tags",
                "label": "价签位置/编号",
                "kind": "price_tags",
                "color": [35, 170, 80],
                "default_visible": True,
            },
        )
    )
    payload = {
        "format": "SupermarketMap2DPreviewLayers",
        "version": 2,
        "width": grid.width,
        "height": grid.height,
        "resolution_m": grid.resolution,
        "origin": [grid.origin_x, grid.origin_y],
        "structure_image": "occupancy_grid.png",
        "layers": layers,
        "trajectory": {
            "segments": segment_paths,
            "source_point_count": total_points,
            "exported_point_count": sum(len(entry["points"]) for entry in segment_paths),
            "stride": stride,
        },
        "price_tags": tag_entries,
        "shelf_outline": {
            "runs": shelf_outline_runs(shelf_outline, grid) if shelf_outline is not None else [],
            "summary": shelf_outline.summary(grid.resolution) if shelf_outline is not None else None,
        },
        "export_scales": [1, 2, 4],
    }
    path.write_text(json.dumps(payload, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    return payload


def write_yaml(path: Path, grid: OccupancyGrid, image_name: str) -> None:
    path.write_text(
        "\n".join(
            [
                f"image: {image_name}",
                f"resolution: {grid.resolution:.6f}",
                f"origin: [{grid.origin_x:.6f}, {grid.origin_y:.6f}, 0.0]",
                "negate: 0",
                "occupied_thresh: 0.65",
                "free_thresh: 0.20",
                "",
            ]
        ),
        encoding="utf-8",
    )


def feature_collection(features: List[Dict[str, Any]]) -> Dict[str, Any]:
    return {"type": "FeatureCollection", "features": features}


def write_geojson(path: Path, data: Dict[str, Any]) -> None:
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")


def trajectory_geojson(segments: Sequence[Segment]) -> Dict[str, Any]:
    features = []
    for segment in segments:
        coords = [[pose.x, pose.y] for pose in segment.poses]
        if len(coords) >= 2:
            features.append(
                {
                    "type": "Feature",
                    "properties": {"segment": segment.index, "kind": "trajectory", "nodes": len(coords)},
                    "geometry": {"type": "LineString", "coordinates": coords},
                }
            )
    return feature_collection(features)


def _evenly_sampled_rows(rows: Sequence[Any], limit: int) -> List[Any]:
    if len(rows) <= limit:
        return list(rows)
    if limit <= 1:
        return [rows[0]]
    indices = [round(index * (len(rows) - 1) / (limit - 1)) for index in range(limit)]
    return [rows[index] for index in dict.fromkeys(indices)]


def vertical_triangle_sample(
    first: Sequence[float],
    second: Sequence[float],
    third: Sequence[float],
    maximum_vertical_normal_ratio: float = 0.55,
) -> Optional[Tuple[float, float, float, float, float, float]]:
    """Return compact evidence when a triangle belongs to a near-vertical surface.

    The third coordinate is height. A vertical wall/shelf face has an almost
    horizontal normal, so the absolute height component of its unit normal is
    small. Horizontal floor and shelf-top triangles are rejected.
    """
    if min(len(first), len(second), len(third)) < 3:
        return None
    ux = float(second[0]) - float(first[0])
    uy = float(second[1]) - float(first[1])
    uz = float(second[2]) - float(first[2])
    vx = float(third[0]) - float(first[0])
    vy = float(third[1]) - float(first[1])
    vz = float(third[2]) - float(first[2])
    normal_x = uy * vz - uz * vy
    normal_y = uz * vx - ux * vz
    normal_z = ux * vy - uy * vx
    normal_length = math.sqrt(normal_x * normal_x + normal_y * normal_y + normal_z * normal_z)
    if normal_length <= 1e-8:
        return None
    normal_height_ratio = abs(normal_z) / normal_length
    if normal_height_ratio > maximum_vertical_normal_ratio:
        return None
    heights = (float(first[2]), float(second[2]), float(third[2]))
    return (
        (float(first[0]) + float(second[0]) + float(third[0])) / 3.0,
        (float(first[1]) + float(second[1]) + float(third[1])) / 3.0,
        min(heights),
        max(heights),
        normal_length * 0.5,
        1.0 - normal_height_ratio,
    )


def extract_depth_point_cloud(
    segments: Sequence[Segment],
    horizontal_axes: str,
    max_frames: int = 192,
    pixel_step: int = 4,
    max_depth: float = 5.0,
    max_points: int = 400000,
    frame_output_dir: Optional[Path] = None,
    depth_projector: Optional[Any] = None,
    structure_resolution: float = 0.05,
) -> Dict[str, Any]:
    """Build a bounded preview cloud from RTAB-Map RGB-D node data."""
    candidates: List[Tuple[Segment, int]] = []
    for segment in segments:
        if segment.database_path is None or not segment.database_path.is_file():
            continue
        pose_ids = {pose.node_id for pose in segment.poses}
        if not pose_ids:
            continue
        try:
            with closing(sqlite3.connect(str(segment.database_path))) as conn:
                tables = set(sqlite_tables(conn))
                if "Data" not in tables:
                    continue
                for (node_id,) in conn.execute(
                    "SELECT id FROM Data WHERE length(depth)>0 AND length(calibration)>0 ORDER BY id"
                ):
                    if int(node_id) in pose_ids:
                        candidates.append((segment, int(node_id)))
        except sqlite3.Error:
            continue

    selected = _evenly_sampled_rows(candidates, max_frames)
    selected_by_database: Dict[Path, List[Tuple[Segment, int]]] = defaultdict(list)
    for segment, node_id in selected:
        if segment.database_path is not None:
            selected_by_database[segment.database_path].append((segment, node_id))

    points: List[List[Any]] = []
    decoded_frames = 0
    skipped_frames = 0
    warnings: List[str] = []
    effective_steps: List[int] = []
    surface_frames: List[Dict[str, Any]] = []
    gpu_projected_frames = 0
    gpu_projection_failures = 0
    palette = [(17, 132, 141), (47, 123, 202), (147, 89, 170), (189, 106, 50), (88, 125, 53)]
    structure_cell_size = max(0.025, float(structure_resolution))
    vertical_surface_cells: Dict[Tuple[int, int], List[float]] = {}
    vertical_triangle_count = 0

    for database_path, rows in selected_by_database.items():
        segment = rows[0][0]
        selected_ids = {node_id for _segment, node_id in rows}
        current_by_node = {pose.node_id: pose for pose in segment.poses}
        placeholders = ",".join("?" for _ in selected_ids)
        try:
            with closing(sqlite3.connect(str(database_path))) as conn:
                data_columns = {str(row[1]) for row in conn.execute("PRAGMA table_info(Data)")}
                image_expression = "d.image" if "image" in data_columns else "NULL"
                query = (
                    f"SELECT n.id,n.pose,d.depth,d.calibration,{image_expression} FROM Node n "
                    "JOIN Data d ON d.id=n.id WHERE n.id IN (" + placeholders + ") ORDER BY n.id"
                )
                database_rows = conn.execute(query, sorted(selected_ids)).fetchall()
        except sqlite3.Error as exc:
            warnings.append(f"segment_{segment.index:04d}: point cloud SQLite read failed: {exc}")
            skipped_frames += len(rows)
            continue

        base_color = palette[(segment.index - 1) % len(palette)]
        for node_id, pose_blob, depth_blob, calibration_blob, image_blob in database_rows:
            current_pose = current_by_node.get(int(node_id))
            raw_matrix = parse_transform_matrix(pose_blob)
            raw_projected = parse_rtabmap_transform_3d(pose_blob, horizontal_axes)
            calibration = parse_camera_calibration(calibration_blob)
            if current_pose is None or raw_matrix is None or raw_projected is None or calibration is None:
                skipped_frames += 1
                continue
            try:
                depth_width, depth_height, depths = decode_depth_image(depth_blob)
            except (ValueError, zlib.error, struct.error) as exc:
                skipped_frames += 1
                if len(warnings) < 8:
                    warnings.append(f"segment_{segment.index:04d} node {node_id}: depth decode failed: {exc}")
                continue

            raw_x, raw_y, _raw_height, raw_yaw = raw_projected
            correction_yaw = current_pose.yaw - raw_yaw
            rotated_raw_x, rotated_raw_y = transform_point(raw_x, raw_y, 0.0, 0.0, correction_yaw)
            correction_dx = current_pose.x - rotated_raw_x
            correction_dy = current_pose.y - rotated_raw_y
            scale_x = depth_width / calibration.width
            scale_y = depth_height / calibration.height
            fx = calibration.fx * scale_x
            fy = calibration.fy * scale_y
            cx = calibration.cx * scale_x
            cy = calibration.cy * scale_y

            # WebGL 1 indexed geometry uses 16-bit indices. Keep every frame
            # below that limit even when processing a one-frame database.
            frame_budget = min(65000, max(1, max_points // max(1, len(selected))))
            effective_step = max(1, pixel_step)
            while math.ceil(depth_width / effective_step) * math.ceil(depth_height / effective_step) > frame_budget:
                effective_step += 1
            effective_steps.append(effective_step)

            frame_points = 0
            grid_width = math.ceil(depth_width / effective_step)
            grid_height = math.ceil(depth_height / effective_step)
            grid_indices = [-1] * (grid_width * grid_height)
            frame_vertices: List[List[float]] = []
            frame_uv: List[List[float]] = []
            frame_depths: List[float] = []
            projected_grid = None
            if depth_projector is not None:
                try:
                    projected_grid = depth_projector.project(
                        depths=depths,
                        width=depth_width,
                        height=depth_height,
                        step=effective_step,
                        horizontal_axes=horizontal_axes,
                        max_depth=max_depth,
                        fx=fx,
                        fy=fy,
                        cx=cx,
                        cy=cy,
                        correction_dx=correction_dx,
                        correction_dy=correction_dy,
                        correction_yaw=correction_yaw,
                        local_transform=calibration.local_transform,
                        raw_transform=raw_matrix,
                    )
                    if projected_grid is not None:
                        gpu_projected_frames += 1
                except Exception as exc:
                    gpu_projection_failures += 1
                    projected_grid = None
                    if len(warnings) < 8:
                        warnings.append(
                            f"segment_{segment.index:04d} node {node_id}: GPU projection failed, using CPU: {exc}"
                        )
            for row in range(0, depth_height, effective_step):
                for column in range(0, depth_width, effective_step):
                    depth = depths[row * depth_width + column]
                    if not math.isfinite(depth) or depth <= 0.05 or depth > max_depth:
                        continue
                    cell_index = (row // effective_step) * grid_width + (column // effective_step)
                    if projected_grid is not None:
                        point_x, point_y, point_height, projected_depth = projected_grid[cell_index]
                        if not all(math.isfinite(value) for value in (point_x, point_y, point_height, projected_depth)):
                            continue
                    else:
                        camera_point = ((column - cx) * depth / fx, (row - cy) * depth / fy, depth)
                        local_point = transform_xyz(calibration.local_transform, camera_point)
                        native_world = transform_xyz(raw_matrix, local_point)
                        if horizontal_axes == "xz":
                            point_x, point_y, point_height = -native_world[1], -native_world[0], native_world[2]
                        else:
                            point_x, point_y, point_height = native_world
                        point_x, point_y = transform_point(
                            point_x, point_y, correction_dx, correction_dy, correction_yaw
                        )
                    depth_shade = 0.72 + 0.28 * (1.0 - min(1.0, depth / max_depth))
                    height_shade = 0.82 + 0.18 * max(0.0, min(1.0, point_height / 3.0))
                    shade = depth_shade * height_shade
                    color = [min(255, round(channel * shade)) for channel in base_color]
                    points.append(
                        [round(point_x, 3), round(point_y, 3), round(point_height, 3), *color, segment.index]
                    )
                    local_index = len(frame_vertices)
                    grid_indices[cell_index] = local_index
                    frame_vertices.append([round(point_x, 3), round(point_y, 3), round(point_height, 3)])
                    frame_uv.append(
                        [
                            round(column / max(1, depth_width - 1), 5),
                            round(row / max(1, depth_height - 1), 5),
                        ]
                    )
                    frame_depths.append(depth)
                    frame_points += 1
            if frame_points:
                decoded_frames += 1
                frame_indices: List[int] = []

                def append_triangle(first: int, second: int, third: int) -> None:
                    nonlocal vertical_triangle_count
                    if min(first, second, third) < 0:
                        return
                    triangle_depths = (frame_depths[first], frame_depths[second], frame_depths[third])
                    depth_jump_limit = 0.08 + min(triangle_depths) * 0.04
                    if max(triangle_depths) - min(triangle_depths) <= depth_jump_limit:
                        frame_indices.extend((first, second, third))
                        evidence = vertical_triangle_sample(
                            frame_vertices[first], frame_vertices[second], frame_vertices[third]
                        )
                        if evidence is not None:
                            x, y, minimum_height, maximum_height, area, verticality = evidence
                            key = (round(x / structure_cell_size), round(y / structure_cell_size))
                            accumulated = vertical_surface_cells.get(key)
                            if accumulated is None:
                                # min height, max height, triangle count,
                                # accumulated area, accumulated verticality.
                                vertical_surface_cells[key] = [
                                    minimum_height,
                                    maximum_height,
                                    1.0,
                                    area,
                                    verticality,
                                ]
                            else:
                                accumulated[0] = min(accumulated[0], minimum_height)
                                accumulated[1] = max(accumulated[1], maximum_height)
                                accumulated[2] += 1.0
                                accumulated[3] += area
                                accumulated[4] += verticality
                            vertical_triangle_count += 1

                for grid_row in range(grid_height - 1):
                    for grid_column in range(grid_width - 1):
                        top_left = grid_indices[grid_row * grid_width + grid_column]
                        top_right = grid_indices[grid_row * grid_width + grid_column + 1]
                        bottom_left = grid_indices[(grid_row + 1) * grid_width + grid_column]
                        bottom_right = grid_indices[(grid_row + 1) * grid_width + grid_column + 1]
                        append_triangle(top_left, top_right, bottom_left)
                        append_triangle(top_right, bottom_right, bottom_left)

                image_name: Optional[str] = None
                if frame_output_dir is not None and image_blob:
                    if image_blob.startswith(b"\xff\xd8"):
                        suffix = ".jpg"
                    elif image_blob.startswith(b"\x89PNG"):
                        suffix = ".png"
                    else:
                        suffix = ""
                    if suffix:
                        frame_output_dir.mkdir(parents=True, exist_ok=True)
                        image_name = f"segment_{segment.index:04d}_node_{int(node_id):06d}{suffix}"
                        (frame_output_dir / image_name).write_bytes(image_blob)
                if image_name and frame_indices:
                    surface_frames.append(
                        {
                            "segment": segment.index,
                            "node": int(node_id),
                            "image": f"preview_frames/{image_name}",
                            "vertices": frame_vertices,
                            "uv": frame_uv,
                            "indices": frame_indices,
                            "triangles": len(frame_indices) // 3,
                        }
                    )
            else:
                skipped_frames += 1

    return {
        "points": points,
        "point_count": len(points),
        "available_frames": len(candidates),
        "sampled_frames": len(selected),
        "decoded_frames": decoded_frames,
        "skipped_frames": skipped_frames,
        "minimum_pixel_step": pixel_step,
        "effective_pixel_step_max": max(effective_steps, default=pixel_step),
        "max_depth_m": max_depth,
        "max_points": max_points,
        "color_mode": "rgb_surface_with_segment_cloud_fallback",
        "surface_frames": surface_frames,
        "surface_frame_count": len(surface_frames),
        "surface_triangle_count": sum(frame["triangles"] for frame in surface_frames),
        "gpu_projection_backend": getattr(depth_projector, "backend", "cpu") if depth_projector else "cpu",
        "gpu_projected_frames": gpu_projected_frames,
        "gpu_projection_failures": gpu_projection_failures,
        "vertical_surface_triangle_count": vertical_triangle_count,
        "vertical_surface_evidence_cell_count": len(vertical_surface_cells),
        "vertical_surface_evidence_resolution_m": structure_cell_size,
        "_vertical_surface_evidence": [
            [
                key[0] * structure_cell_size,
                key[1] * structure_cell_size,
                values[0],
                values[1],
                int(values[2]),
                values[3],
                values[4] / max(1.0, values[2]),
            ]
            for key, values in vertical_surface_cells.items()
        ],
        "warnings": warnings,
    }


def projected_depth_surface_points(
    point_cloud: Dict[str, Any],
    resolution: float,
) -> List[ProjectedPoint]:
    rows = point_cloud.get("points", [])
    if not rows:
        return []
    heights = sorted(float(row[2]) for row in rows if len(row) >= 3 and math.isfinite(float(row[2])))
    if not heights:
        return []
    floor_height = heights[min(len(heights) - 1, int(len(heights) * 0.05))]
    point_cloud["estimated_floor_height_m"] = round(floor_height, 3)
    cell_size = max(0.05, resolution)
    selected: Dict[Tuple[int, int, int], List[Any]] = {}
    for row in rows:
        if len(row) < 7:
            continue
        x, y, height = float(row[0]), float(row[1]), float(row[2])
        if height < floor_height + 0.25 or height > floor_height + 2.8:
            continue
        key = (int(row[6]), round(x / cell_size), round(y / cell_size))
        previous = selected.get(key)
        if previous is None or abs(height - (floor_height + 1.2)) < abs(float(previous[2]) - (floor_height + 1.2)):
            selected[key] = row
    return [
        ProjectedPoint(
            x=float(row[0]),
            y=float(row[1]),
            z=float(row[2]),
            kind="depth_surface",
            segment_index=int(row[6]),
            height=float(row[2]),
        )
        for row in selected.values()
    ]


def build_shelf_outline(
    point_cloud: Dict[str, Any],
    grid: OccupancyGrid,
    minimum_height_span_m: float = 0.45,
    minimum_height_above_floor_m: float = 0.55,
    minimum_component_length_m: float = 0.20,
) -> ShelfOutline:
    """Extract thin shelf/wall traces from vertically observed RGB-D faces.

    Evidence is accumulated in a 3x3 grid neighborhood so small LiDAR depth
    jitter does not split one physical face into adjacent columns. One-cell
    gaps are closed, then short isolated fragments are removed. Horizontal
    floor and shelf-top surfaces have already been rejected by their normals.
    """
    raw_evidence = point_cloud.get("_vertical_surface_evidence", [])
    floor_raw = point_cloud.get("estimated_floor_height_m")
    floor_height = float(floor_raw) if isinstance(floor_raw, (int, float)) else None
    outline = ShelfOutline(
        evidence_cell_count=len(raw_evidence),
        vertical_triangle_count=int(point_cloud.get("vertical_surface_triangle_count") or 0),
        floor_height_m=round(floor_height, 3) if floor_height is not None else None,
        minimum_height_span_m=minimum_height_span_m,
    )
    if not raw_evidence:
        return outline

    # Each value contains min height, max height, triangle count, area and
    # triangle-count-weighted verticality.
    evidence_by_cell: Dict[Tuple[int, int], List[float]] = {}
    for row in raw_evidence:
        if not isinstance(row, list) or len(row) < 7:
            continue
        try:
            x, y = float(row[0]), float(row[1])
            minimum_height, maximum_height = float(row[2]), float(row[3])
            triangle_count = max(1.0, float(row[4]))
            area = max(0.0, float(row[5]))
            verticality = max(0.0, min(1.0, float(row[6])))
        except (TypeError, ValueError):
            continue
        if not all(math.isfinite(value) for value in (x, y, minimum_height, maximum_height, area, verticality)):
            continue
        cell = grid.cell(x, y)
        if not grid.in_bounds(*cell):
            continue
        accumulated = evidence_by_cell.get(cell)
        if accumulated is None:
            evidence_by_cell[cell] = [
                minimum_height,
                maximum_height,
                triangle_count,
                area,
                verticality * triangle_count,
            ]
        else:
            accumulated[0] = min(accumulated[0], minimum_height)
            accumulated[1] = max(accumulated[1], maximum_height)
            accumulated[2] += triangle_count
            accumulated[3] += area
            accumulated[4] += verticality * triangle_count

    candidates: Set[Tuple[int, int]] = set()
    for ix, iy in evidence_by_cell:
        neighbors = [
            evidence_by_cell[(nx, ny)]
            for ny in range(iy - 1, iy + 2)
            for nx in range(ix - 1, ix + 2)
            if (nx, ny) in evidence_by_cell
        ]
        if not neighbors:
            continue
        minimum_height = min(value[0] for value in neighbors)
        maximum_height = max(value[1] for value in neighbors)
        triangle_count = sum(value[2] for value in neighbors)
        weighted_verticality = sum(value[4] for value in neighbors) / max(1.0, triangle_count)
        if maximum_height - minimum_height < minimum_height_span_m:
            continue
        if floor_height is not None and maximum_height < floor_height + minimum_height_above_floor_m:
            continue
        if triangle_count < 3 or weighted_verticality < 0.60:
            continue
        candidates.add((ix, iy))

    outline.candidate_cell_count = len(candidates)
    if not candidates:
        return outline

    # Close a single missing 2D cell without expanding the measured outline.
    closed = set(candidates)
    for ix, iy in candidates:
        for dx, dy in ((1, 0), (0, 1), (1, 1), (1, -1)):
            far = (ix + 2 * dx, iy + 2 * dy)
            middle = (ix + dx, iy + dy)
            if far in candidates and grid.in_bounds(*middle):
                closed.add(middle)

    minimum_cells = max(3, int(math.ceil(minimum_component_length_m / grid.resolution)))
    remaining = set(closed)
    components: List[List[Tuple[int, int]]] = []
    while remaining:
        start = remaining.pop()
        queue = deque([start])
        component = [start]
        while queue:
            cx, cy = queue.popleft()
            for ny in range(cy - 1, cy + 2):
                for nx in range(cx - 1, cx + 2):
                    if (nx, ny) == (cx, cy) or (nx, ny) not in remaining:
                        continue
                    remaining.remove((nx, ny))
                    queue.append((nx, ny))
                    component.append((nx, ny))
        if len(component) >= minimum_cells:
            components.append(sorted(component, key=lambda cell: (cell[1], cell[0])))

    outline.components = sorted(components, key=len, reverse=True)
    outline.cells = {cell for component in outline.components for cell in component}
    return outline


def shelf_outline_runs(outline: ShelfOutline, grid: OccupancyGrid) -> List[List[int]]:
    """Run-length encode outline cells in image coordinates for browser drawing."""
    rows: Dict[int, List[int]] = defaultdict(list)
    for ix, iy in outline.cells:
        rows[grid.height - 1 - iy].append(ix)
    runs: List[List[int]] = []
    for image_y, xs in sorted(rows.items()):
        ordered = sorted(set(xs))
        if not ordered:
            continue
        start = previous = ordered[0]
        for x in ordered[1:]:
            if x == previous + 1:
                previous = x
                continue
            runs.append([image_y, start, previous - start + 1])
            start = previous = x
        runs.append([image_y, start, previous - start + 1])
    return runs


def render_shelf_outline(grid: OccupancyGrid, outline: ShelfOutline, path: Path) -> None:
    """Write a reference-style white floor plan with black vertical traces."""
    rows: List[bytes] = []
    for iy in range(grid.height - 1, -1, -1):
        row = bytearray()
        for ix in range(grid.width):
            row.extend((12, 16, 18) if (ix, iy) in outline.cells else (255, 255, 255))
        rows.append(bytes(row))
    write_png(path, grid.width, grid.height, rows)


def write_preview_3d(
    path: Path,
    segments: Sequence[Segment],
    points: Sequence[ProjectedPoint],
    tags: Sequence[PriceTag],
    horizontal_axes: str,
    quality: str = DEFAULT_PREVIEW_3D_QUALITY,
    point_cloud: Optional[Dict[str, Any]] = None,
) -> Dict[str, Any]:
    """Write a compact, renderer-neutral 3D preview for the local UI."""
    max_trajectory_points = 2500
    max_structure_points = 8000

    def compact_triplets(rows: Sequence[Tuple[float, float, float]], limit: int) -> List[List[float]]:
        if not rows:
            return []
        stride = max(1, math.ceil(len(rows) / limit))
        sampled = rows[::stride]
        if sampled[-1] != rows[-1]:
            sampled.append(rows[-1])
        return [[round(x, 4), round(y, 4), round(z, 4)] for x, y, z in sampled]

    segment_entries = []
    for segment in segments:
        trajectory = compact_triplets([(pose.x, pose.y, pose.height) for pose in segment.poses], max_trajectory_points)
        if trajectory:
            segment_entries.append({"segment": segment.index, "trajectory": trajectory})

    sampled_points = list(points)
    if len(sampled_points) > max_structure_points:
        stride = math.ceil(len(sampled_points) / max_structure_points)
        sampled_points = sampled_points[::stride]

    if point_cloud is None:
        profile = PREVIEW_3D_PROFILES.get(quality, PREVIEW_3D_PROFILES[DEFAULT_PREVIEW_3D_QUALITY])
        point_cloud = extract_depth_point_cloud(
            segments,
            horizontal_axes,
            frame_output_dir=path.parent / "preview_frames",
            **profile,
        )
    public_point_cloud = {
        key: value for key, value in point_cloud.items() if not key.startswith("_")
    }
    data = {
        "format": "SupermarketMap3DPreview",
        "version": 2,
        "horizontal_axes": horizontal_axes,
        "segments": segment_entries,
        "points": [
            {
                "position": [round(point.x, 4), round(point.y, 4), round(point.height, 4)],
                "kind": point.kind,
                "segment": point.segment_index,
            }
            for point in sampled_points
        ],
        "price_tags": [
            {
                "position": [
                    round(tag.snapped_x if tag.snapped_x is not None else tag.raw_x, 4),
                    round(tag.snapped_y if tag.snapped_y is not None else tag.raw_y, 4),
                    0.0,
                ],
                "id": tag.tag_id,
                "segment": tag.segment_index,
            }
            for tag in tags
        ],
        "point_cloud": public_point_cloud,
    }
    path.write_text(json.dumps(data, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    return {
        key: value
        for key, value in public_point_cloud.items()
        if key not in {"points", "surface_frames"}
    }


def price_tags_geojson(tags: Sequence[PriceTag]) -> Dict[str, Any]:
    features = []
    for tag in tags:
        x = tag.snapped_x if tag.snapped_x is not None else tag.raw_x
        y = tag.snapped_y if tag.snapped_y is not None else tag.raw_y
        features.append(
            {
                "type": "Feature",
                "properties": {
                    "tag_id": tag.tag_id,
                    "payload": tag.payload,
                    "segment": tag.segment_index,
                    "node_count": tag.node_count,
                    "raw_x": tag.raw_x,
                    "raw_y": tag.raw_y,
                    "confidence": round(tag.confidence, 3),
                    "needs_review": tag.needs_review,
                    "timestamp": tag.timestamp,
                },
                "geometry": {"type": "Point", "coordinates": [x, y]},
            }
        )
    return feature_collection(features)


def vector_map_geojson(grid: OccupancyGrid) -> Dict[str, Any]:
    visited = [[False for _ in range(grid.width)] for _ in range(grid.height)]
    features: List[Dict[str, Any]] = []
    for y in range(grid.height):
        for x in range(grid.width):
            if visited[y][x] or grid.classify(x, y) != OCCUPIED:
                continue
            queue = deque([(x, y)])
            visited[y][x] = True
            cells = []
            while queue:
                cx, cy = queue.popleft()
                cells.append((cx, cy))
                for nx, ny in ((cx + 1, cy), (cx - 1, cy), (cx, cy + 1), (cx, cy - 1)):
                    if grid.in_bounds(nx, ny) and not visited[ny][nx] and grid.classify(nx, ny) == OCCUPIED:
                        visited[ny][nx] = True
                        queue.append((nx, ny))
            if len(cells) < 3:
                continue
            min_x = min(c[0] for c in cells)
            max_x = max(c[0] for c in cells)
            min_y = min(c[1] for c in cells)
            max_y = max(c[1] for c in cells)
            wx0, wy0 = grid.world(min_x, min_y)
            wx1, wy1 = grid.world(max_x + 1, max_y + 1)
            features.append(
                {
                    "type": "Feature",
                    "properties": {
                        "kind": "occupied_component",
                        "cell_count": len(cells),
                        "confidence": 0.55,
                    },
                    "geometry": {
                        "type": "Polygon",
                        "coordinates": [[[wx0, wy0], [wx1, wy0], [wx1, wy1], [wx0, wy1], [wx0, wy0]]],
                    },
                }
            )
    return feature_collection(features)


def semantic_layers(grid: OccupancyGrid, shelf_outline: Optional[ShelfOutline] = None) -> Dict[str, Any]:
    counts = grid.class_counts()
    cell_area = grid.resolution * grid.resolution
    layers = [
        {"id": "occupied", "kind": "structure_or_obstacle", "area_m2": counts["occupied"] * cell_area},
        {"id": "walkable_confirmed", "kind": "free_space", "area_m2": counts["free"] * cell_area},
        {"id": "unknown", "kind": "unobserved", "area_m2": counts["unknown"] * cell_area},
        {"id": "conflict", "kind": "needs_review", "area_m2": counts["conflict"] * cell_area},
    ]
    if shelf_outline is not None:
        layers.append(
            {
                "id": "shelf_outline",
                "kind": "vertical_structure_trace",
                **shelf_outline.summary(grid.resolution),
            }
        )
    return {"layers": layers}


def quality_report(
    session_dir: Path,
    segments: Sequence[Segment],
    points: Sequence[ProjectedPoint],
    tags: Sequence[PriceTag],
    grid: OccupancyGrid,
    transforms: Dict[int, Dict[str, float]],
    shelf_outline: Optional[ShelfOutline] = None,
) -> Dict[str, Any]:
    counts = grid.class_counts()
    total = grid.width * grid.height
    cell_area = grid.resolution * grid.resolution
    review_tags = sum(1 for tag in tags if tag.needs_review)
    warnings = []
    depth_surface_segments = {point.segment_index for point in points if point.kind == "depth_surface"}
    for segment in segments:
        warnings.extend([f"segment_{segment.index:04d}: {w}" for w in segment.sqlite_warnings])
        capture_health = segment.metadata.get("captureHealth") or segment.metadata.get("capture_health")
        if isinstance(capture_health, dict):
            sensor_count = int(capture_health.get("sensorPoseCount") or 0)
            normal_count = int(capture_health.get("normalTrackingPoseCount") or 0)
            degraded_ratio = (sensor_count - normal_count) / max(1, sensor_count)
            longest_gap = float(capture_health.get("longestSensorGapSeconds") or 0.0)
            if sensor_count and degraded_ratio > 0.10:
                warnings.append(
                    f"segment_{segment.index:04d}: ARKit tracking was degraded for "
                    f"{degraded_ratio * 100:.1f}% of recorded sensor poses; inspect this route for drift."
                )
            if longest_gap > 0.5:
                warnings.append(
                    f"segment_{segment.index:04d}: longest ARKit sensor-pose gap was {longest_gap:.2f}s."
                )
            evaluated_frames = int(capture_health.get("evaluatedMappingFrameCount") or 0)
            rejected_frames = int(capture_health.get("rejectedMappingFrameCount") or 0)
            rejected_ratio = rejected_frames / max(1, evaluated_frames)
            if evaluated_frames and rejected_ratio > 0.15:
                warnings.append(
                    f"segment_{segment.index:04d}: software pose quality gating rejected "
                    f"{rejected_ratio * 100:.1f}% of mapping frames; inspect low-texture or fast-motion areas."
                )
            compensation_count = int(capture_health.get("poseDiscontinuityCompensationCount") or 0)
            if compensation_count:
                warnings.append(
                    f"segment_{segment.index:04d}: {compensation_count} implausible ARKit pose "
                    "discontinuities were removed before entering the map graph."
                )
            low_feature_frames = int(capture_health.get("lowVisualFeatureFrameCount") or 0)
            if evaluated_frames and low_feature_frames / evaluated_frames > 0.25:
                warnings.append(
                    f"segment_{segment.index:04d}: more than 25% of evaluated frames had fewer "
                    "than 50 ARKit visual features."
                )
        if not segment.poses:
            warnings.append(f"segment_{segment.index:04d}: no db poses available")
        if segment.has_local_grid_blobs and segment.index not in depth_surface_segments:
            warnings.append(
                f"segment_{segment.index:04d}: RTAB-Map local occupancy blobs were not decoded and no RGB-D surface projection was available"
            )
    if not points:
        warnings.append("No projected structure points were provided; 2D occupancy is based on trajectory free-space only.")
    if counts["conflict"] / max(1, total) > 0.05:
        warnings.append("Conflict grid ratio is above 5%; inspect segment alignment and dynamic obstacles.")
    if shelf_outline is not None and shelf_outline.evidence_cell_count and not shelf_outline.cells:
        warnings.append(
            "Vertical RGB-D surface evidence was detected, but no shelf/wall outline passed the height-span and continuity filters."
        )
    return {
        "session": str(session_dir),
        "generated_at": time.strftime("%Y-%m-%d %H:%M:%S"),
        "input_scan": session_scan_summary(segments),
        "segments": [
            {
                "index": segment.index,
                "directory": str(segment.directory),
                "database": str(segment.database_path) if segment.database_path else None,
                "node_count": len(segment.poses),
                "price_tag_count": len(segment.price_tags),
                "has_local_grid_blobs": segment.has_local_grid_blobs,
                "scan_mode": metadata_scan_mode(segment.metadata),
                "capture_health": segment.metadata.get("captureHealth") or segment.metadata.get("capture_health"),
            }
            for segment in segments
        ],
        "grid": {
            "resolution_m": grid.resolution,
            "width": grid.width,
            "height": grid.height,
            "origin": [grid.origin_x, grid.origin_y],
            "area_m2": total * cell_area,
            "class_counts": counts,
            "class_areas_m2": {k: round(v * cell_area, 3) for k, v in counts.items()},
        },
        "projected_points": len(points),
        "shelf_outline": shelf_outline.summary(grid.resolution) if shelf_outline is not None else None,
        "price_tags": {"total": len(tags), "needs_review": review_tags},
        "segment_transforms": transforms,
        "warnings": warnings,
    }


def source_manifest(session_dir: Path, segments: Sequence[Segment], extra_inputs: Sequence[Path]) -> Dict[str, Any]:
    files = []
    for path in [session_dir / "metadata.json", session_dir / "price_tags.json", *extra_inputs]:
        if path.exists():
            files.append({"path": str(path), "sha256": sha256_file(path)})
    for segment in segments:
        for path in [segment.directory / "metadata.json", segment.directory / "price_tags.json", segment.database_path]:
            if path and path.exists():
                files.append({"path": str(path), "sha256": sha256_file(path)})
    return {
        "session": str(session_dir),
        "input_scan": session_scan_summary(segments),
        "files": files,
    }


def write_review_items(path: Path, report: Dict[str, Any], tags: Sequence[PriceTag]) -> None:
    items = []
    for warning in report.get("warnings", []):
        items.append({"type": "warning", "message": warning})
    for tag in tags:
        if tag.needs_review:
            items.append(
                {
                    "type": "price_tag",
                    "message": f"Price tag {tag.tag_id} needs position review",
                    "segment": tag.segment_index,
                    "raw_xy": [tag.raw_x, tag.raw_y],
                    "snapped_xy": [tag.snapped_x, tag.snapped_y],
                    "confidence": tag.confidence,
                }
            )
    path.write_text(json.dumps({"items": items}, ensure_ascii=False, indent=2), encoding="utf-8")


def generate(args: argparse.Namespace) -> Path:
    session_dir = Path(args.session).resolve()
    output_dir = Path(args.output).resolve() if args.output else session_dir / f"Map2D-{time.strftime('%Y%m%d-%H%M%S')}"

    config = MapConfig(
        resolution=args.resolution,
        preview_resolution=args.preview_resolution,
        trajectory_radius=args.trajectory_radius,
        tag_snap_distance=args.tag_snap_distance,
        occupied_inflate_radius=args.occupied_inflate_radius,
        free_ray_max_range=args.free_ray_max_range,
        horizontal_axes=args.horizontal_axes,
        auto_align_segments=args.auto_align_segments,
    )

    raw_overrides = getattr(args, "database_overrides", None) or {}
    database_overrides = {
        int(index): Path(path).resolve()
        for index, path in raw_overrides.items()
    }
    segments = discover_segments(session_dir, config, database_overrides)
    input_scan = session_scan_summary(segments)
    if input_scan["scan_mode"] == SCAN_MODE_CONTINUOUS_STREAMING:
        # The graph is already continuous. Segment-boundary alignment would
        # be both unnecessary and conceptually wrong for this input mode.
        config.auto_align_segments = False
    point_paths = [Path(p).resolve() for p in args.points_csv]
    point_paths.extend(sorted(session_dir.glob("segment_*/points.csv")))
    point_paths.extend(sorted(session_dir.glob("points.csv")))
    points = load_projected_points(point_paths, config.horizontal_axes)
    require_map_evidence(segments, points)
    output_dir.mkdir(parents=True, exist_ok=True)
    transforms = apply_segment_transforms(segments, points, Path(args.corrections).resolve() if args.corrections else None, config.auto_align_segments)

    preview_3d_quality = getattr(args, "preview_3d_quality", DEFAULT_PREVIEW_3D_QUALITY)
    preview_profile = PREVIEW_3D_PROFILES.get(
        preview_3d_quality, PREVIEW_3D_PROFILES[DEFAULT_PREVIEW_3D_QUALITY]
    )
    point_cloud = extract_depth_point_cloud(
        segments,
        config.horizontal_axes,
        frame_output_dir=output_dir / "preview_frames",
        depth_projector=getattr(args, "depth_projector", None),
        structure_resolution=config.resolution,
        **preview_profile,
    )
    points.extend(projected_depth_surface_points(point_cloud, config.resolution))

    tags = [tag for segment in segments for tag in segment.price_tags]
    snap_price_tags(tags, points, config.tag_snap_distance)
    grid = build_grid(segments, points, config)
    shelf_outline = build_shelf_outline(point_cloud, grid)
    poses = [pose for segment in segments for pose in segment.poses]

    render_grid(grid, output_dir / "occupancy_grid.png")
    render_shelf_outline(grid, shelf_outline, output_dir / "shelf_outline.png")
    render_grid(grid, output_dir / "preview.png", trajectories=poses, tags=tags)
    write_preview_layers(output_dir / "preview_layers.json", grid, segments, tags, shelf_outline)
    write_yaml(output_dir / "occupancy_grid.yaml", grid, "occupancy_grid.png")
    write_geojson(output_dir / "trajectory.geojson", trajectory_geojson(segments))
    write_geojson(output_dir / "price_tags.geojson", price_tags_geojson(tags))
    write_geojson(output_dir / "vector_map.geojson", vector_map_geojson(grid))
    preview_3d_summary = write_preview_3d(
        output_dir / "preview_3d.json",
        segments,
        points,
        tags,
        config.horizontal_axes,
        quality=preview_3d_quality,
        point_cloud=point_cloud,
    )
    (output_dir / "semantic_layers.json").write_text(
        json.dumps(semantic_layers(grid, shelf_outline), ensure_ascii=False, indent=2),
        encoding="utf-8",
    )

    report = quality_report(session_dir, segments, points, tags, grid, transforms, shelf_outline)
    report["preview_3d"] = preview_3d_summary
    (output_dir / "quality_report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    (output_dir / "source_manifest.json").write_text(
        json.dumps(source_manifest(session_dir, segments, point_paths), ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    write_review_items(output_dir / "review_items.json", report, tags)
    map_json = {
        "format": "SupermarketMap2D",
        "version": 2,
        "session": str(session_dir),
        "generated_at": report["generated_at"],
        "input_scan": input_scan,
        "coordinate_frame": {
            "name": "map_2d",
            "horizontal_axes": config.horizontal_axes,
            "origin": [grid.origin_x, grid.origin_y],
            "resolution_m": grid.resolution,
        },
        "parameters": dataclasses.asdict(config),
        "preview_3d_quality": preview_3d_quality,
        "outputs": [
            "occupancy_grid.png",
            "shelf_outline.png",
            "occupancy_grid.yaml",
            "vector_map.geojson",
            "semantic_layers.json",
            "price_tags.geojson",
            "trajectory.geojson",
            "quality_report.json",
            "preview.png",
            "preview_layers.json",
            "preview_3d.json",
            "preview_frames/",
            "review_items.json",
            "source_manifest.json",
        ],
    }
    (output_dir / "map.json").write_text(json.dumps(map_json, ensure_ascii=False, indent=2), encoding="utf-8")
    return output_dir


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Generate a 2D map package from a SupermarketSession directory.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument("session", help="Path to SupermarketSession-* directory or a single segment directory.")
    parser.add_argument("--output", help="Output Map2D directory.")
    parser.add_argument("--points-csv", action="append", default=[], help="Projected point CSV with x,y,z,kind,segmentIndex,nodeId columns.")
    parser.add_argument("--corrections", help="Optional corrections.json with segment_transforms.")
    parser.add_argument("--resolution", type=float, default=0.05, help="Occupancy grid resolution in meters.")
    parser.add_argument("--preview-resolution", type=float, default=0.10, help="Reserved for future preview downsampling.")
    parser.add_argument("--trajectory-radius", type=float, default=1.25, help="Free-space radius around scan trajectory.")
    parser.add_argument("--tag-snap-distance", type=float, default=1.0, help="Maximum distance for snapping price tags to occupied points.")
    parser.add_argument(
        "--preview-3d-quality",
        choices=sorted(PREVIEW_3D_PROFILES),
        default=DEFAULT_PREVIEW_3D_QUALITY,
        help="RGB-D surface preview sampling quality.",
    )
    parser.add_argument("--occupied-inflate-radius", type=float, default=0.08, help="Inflation radius for projected occupied points.")
    parser.add_argument("--free-ray-max-range", type=float, default=8.0, help="Maximum ray clearing range from pose to occupied point.")
    parser.add_argument("--horizontal-axes", choices=["xz", "xy"], default="xz", help="RTAB-Map transform axes used for the 2D floor plane.")
    parser.add_argument("--auto-align-segments", action="store_true", help="Translate/yaw-align each segment start to previous segment end.")
    return parser


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = build_arg_parser()
    args = parser.parse_args(argv)
    try:
        output_dir = generate(args)
    except Exception as exc:
        print(f"supermarket_2d_map: {exc}", file=sys.stderr)
        return 1
    print(output_dir)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
