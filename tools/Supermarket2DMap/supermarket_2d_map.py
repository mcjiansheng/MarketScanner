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
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Sequence, Tuple


UNKNOWN = 0
FREE = 1
OCCUPIED = 2
CONFLICT = 3


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

        stamp_expr = "stamp" if "stamp" in columns else "NULL AS stamp"
        query = f"SELECT id, pose, {stamp_expr} FROM Node ORDER BY id"
        for node_id, pose_blob, stamp in conn.execute(query):
            parsed = parse_rtabmap_transform_3d(pose_blob, axes)
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
                )
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


def discover_segments(session_dir: Path, config: MapConfig) -> List[Segment]:
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
        database_path = expected_database if expected_database.is_file() else (db_candidates[0] if db_candidates else None)
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
        if occ >= 2 and free >= 3:
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
    colors = {
        UNKNOWN: (190, 190, 190),
        FREE: (248, 248, 248),
        OCCUPIED: (30, 30, 30),
        CONFLICT: (220, 60, 50),
    }
    pixels = [[colors[grid.classify(ix, iy)] for ix in range(grid.width)] for iy in range(grid.height)]

    def paint(x: float, y: float, color: Tuple[int, int, int], radius_cells: int) -> None:
        ix, iy = grid.cell(x, y)
        for yy in range(iy - radius_cells, iy + radius_cells + 1):
            for xx in range(ix - radius_cells, ix + radius_cells + 1):
                if grid.in_bounds(xx, yy):
                    pixels[yy][xx] = color

    for pose in trajectories:
        paint(pose.x, pose.y, (35, 110, 230), 1)
    for tag in tags:
        paint(tag.snapped_x if tag.snapped_x is not None else tag.raw_x, tag.snapped_y if tag.snapped_y is not None else tag.raw_y, (35, 170, 80), 2)

    rows: List[bytes] = []
    for iy in range(grid.height - 1, -1, -1):
        row = bytearray()
        for r, g, b in pixels[iy]:
            row.extend((r, g, b))
        rows.append(bytes(row))
    write_png(path, grid.width, grid.height, rows)


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


def write_preview_3d(
    path: Path,
    segments: Sequence[Segment],
    points: Sequence[ProjectedPoint],
    tags: Sequence[PriceTag],
    horizontal_axes: str,
) -> None:
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

    data = {
        "format": "SupermarketMap3DPreview",
        "version": 1,
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
    }
    path.write_text(json.dumps(data, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")


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


def semantic_layers(grid: OccupancyGrid) -> Dict[str, Any]:
    counts = grid.class_counts()
    cell_area = grid.resolution * grid.resolution
    return {
        "layers": [
            {"id": "occupied", "kind": "structure_or_obstacle", "area_m2": counts["occupied"] * cell_area},
            {"id": "walkable_confirmed", "kind": "free_space", "area_m2": counts["free"] * cell_area},
            {"id": "unknown", "kind": "unobserved", "area_m2": counts["unknown"] * cell_area},
            {"id": "conflict", "kind": "needs_review", "area_m2": counts["conflict"] * cell_area},
        ]
    }


def quality_report(
    session_dir: Path,
    segments: Sequence[Segment],
    points: Sequence[ProjectedPoint],
    tags: Sequence[PriceTag],
    grid: OccupancyGrid,
    transforms: Dict[int, Dict[str, float]],
) -> Dict[str, Any]:
    counts = grid.class_counts()
    total = grid.width * grid.height
    cell_area = grid.resolution * grid.resolution
    review_tags = sum(1 for tag in tags if tag.needs_review)
    warnings = []
    for segment in segments:
        warnings.extend([f"segment_{segment.index:04d}: {w}" for w in segment.sqlite_warnings])
        if not segment.poses:
            warnings.append(f"segment_{segment.index:04d}: no db poses available")
        if segment.has_local_grid_blobs:
            warnings.append(
                f"segment_{segment.index:04d}: RTAB-Map occupancy blobs detected but not decoded by this Python tool"
            )
    if not points:
        warnings.append("No projected structure points were provided; occupancy is based on trajectory free-space only.")
    if counts["conflict"] / max(1, total) > 0.05:
        warnings.append("Conflict grid ratio is above 5%; inspect segment alignment and dynamic obstacles.")
    return {
        "session": str(session_dir),
        "generated_at": time.strftime("%Y-%m-%d %H:%M:%S"),
        "segments": [
            {
                "index": segment.index,
                "directory": str(segment.directory),
                "database": str(segment.database_path) if segment.database_path else None,
                "node_count": len(segment.poses),
                "price_tag_count": len(segment.price_tags),
                "has_local_grid_blobs": segment.has_local_grid_blobs,
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
    return {"session": str(session_dir), "files": files}


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

    segments = discover_segments(session_dir, config)
    point_paths = [Path(p).resolve() for p in args.points_csv]
    point_paths.extend(sorted(session_dir.glob("segment_*/points.csv")))
    point_paths.extend(sorted(session_dir.glob("points.csv")))
    points = load_projected_points(point_paths, config.horizontal_axes)
    require_map_evidence(segments, points)
    output_dir.mkdir(parents=True, exist_ok=True)
    transforms = apply_segment_transforms(segments, points, Path(args.corrections).resolve() if args.corrections else None, config.auto_align_segments)

    tags = [tag for segment in segments for tag in segment.price_tags]
    snap_price_tags(tags, points, config.tag_snap_distance)
    grid = build_grid(segments, points, config)
    poses = [pose for segment in segments for pose in segment.poses]

    render_grid(grid, output_dir / "occupancy_grid.png")
    render_grid(grid, output_dir / "preview.png", trajectories=poses, tags=tags)
    write_yaml(output_dir / "occupancy_grid.yaml", grid, "occupancy_grid.png")
    write_geojson(output_dir / "trajectory.geojson", trajectory_geojson(segments))
    write_geojson(output_dir / "price_tags.geojson", price_tags_geojson(tags))
    write_geojson(output_dir / "vector_map.geojson", vector_map_geojson(grid))
    write_preview_3d(output_dir / "preview_3d.json", segments, points, tags, config.horizontal_axes)
    (output_dir / "semantic_layers.json").write_text(json.dumps(semantic_layers(grid), ensure_ascii=False, indent=2), encoding="utf-8")

    report = quality_report(session_dir, segments, points, tags, grid, transforms)
    (output_dir / "quality_report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    (output_dir / "source_manifest.json").write_text(
        json.dumps(source_manifest(session_dir, segments, point_paths), ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    write_review_items(output_dir / "review_items.json", report, tags)
    map_json = {
        "format": "SupermarketMap2D",
        "version": 1,
        "session": str(session_dir),
        "generated_at": report["generated_at"],
        "coordinate_frame": {
            "name": "map_2d",
            "horizontal_axes": config.horizontal_axes,
            "origin": [grid.origin_x, grid.origin_y],
            "resolution_m": grid.resolution,
        },
        "parameters": dataclasses.asdict(config),
        "outputs": [
            "occupancy_grid.png",
            "occupancy_grid.yaml",
            "vector_map.geojson",
            "semantic_layers.json",
            "price_tags.geojson",
            "trajectory.geojson",
            "quality_report.json",
            "preview.png",
            "preview_3d.json",
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
