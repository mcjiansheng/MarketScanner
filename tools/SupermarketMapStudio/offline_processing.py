#!/usr/bin/env python3
"""RTAB-Map PC reprocessing for continuous iPhone supermarket scans.

The phone database is treated as immutable input. Reprocessing always writes a
new database through a temporary path, validates it, and only then publishes it
as the optimized database consumed by Map Studio.
"""

from __future__ import annotations

import json
import math
import os
import re
import shutil
import sqlite3
import statistics
import struct
import subprocess
import tempfile
import threading
import time
from contextlib import closing
from pathlib import Path
from typing import Any, Callable, Dict, Iterable, Optional

import supermarket_2d_map as base


REPROCESS_ENV = "RTABMAP_REPROCESS"
REPROCESS_TEMP_ENV = "SUPERMARKET_PC_TEMP"
DEFAULT_PC_THREADS = min(4, max(1, os.cpu_count() or 1))
DEFAULT_ONLINE_OPTIMIZATION_ITERATIONS = 5
DEFAULT_FINAL_OPTIMIZATION_ITERATIONS = 50
DEFAULT_FINAL_OPTIMIZATION_EPSILON = 0.00001
ADAPTIVE_PROFILE = "adaptive_constraint_reuse_then_discovery_v1"
FAST_REUSE_PROFILE = "constraint_reuse_fast_v1"
DISCOVERY_PROFILE = "orb_loop_discovery_v2"
FAST_REUSE_PARAMETERS = (
    ("RGBD/LoopClosureReextractFeatures", "false"),
    ("RGBD/ProximityByTime", "false"),
    ("RGBD/ProximityBySpace", "false"),
    ("Rtabmap/LoopThr", "1.0"),
)
ReprocessProgressCallback = Callable[[float, str, str], None]
REPROCESS_PARAMETERS = (
    ("Mem/IncrementalMemory", "true"),
    ("Mem/InitWMWithAllNodes", "false"),
    ("Mem/STMSize", "30"),
    ("Mem/RehearsalSimilarity", "0.6"),
    ("Mem/UseOdomGravity", "true"),
    ("Rtabmap/MemoryThr", "2000"),
    ("Rtabmap/TimeThr", "0"),
    ("Rtabmap/MaxRetrieved", "5"),
    ("Rtabmap/LoopThr", "0.15"),
    # ORB is substantially faster than GFTT/BRIEF for PC re-extraction on the
    # iPhone frames while retaining enough correspondences for strict loop
    # validation. Phone odometry features remain in the immutable source DB.
    ("Kp/DetectorStrategy", "2"),
    ("Vis/FeatureType", "2"),
    ("Kp/MaxFeatures", "500"),
    ("Vis/MinInliers", "40"),
    ("RGBD/LinearUpdate", "0"),
    ("RGBD/AngularUpdate", "0"),
    ("RGBD/MaxLocalRetrieved", "5"),
    # ARKit VIO already supplies dense metric neighbor constraints. Refining
    # every adjacent pair repeats visual work without adding global
    # observability; reserve PC visual registration for loop/proximity edges.
    ("RGBD/NeighborLinkRefining", "false"),
    ("RGBD/ProximityByTime", "true"),
    ("RGBD/ProximityBySpace", "true"),
    ("RGBD/ProximityMaxGraphDepth", "100"),
    ("RGBD/ProximityMaxPaths", "5"),
    ("RGBD/ProximityOdomGuess", "true"),
    ("RGBD/LoopClosureReextractFeatures", "true"),
    ("RGBD/OptimizeFromGraphEnd", "true"),
    ("RGBD/OptimizeMaxError", "2.0"),
    ("RGBD/OptimizeMaxErrorRepairRadius", "1.0"),
    # This profile deliberately uses no fiducial or externally positioned
    # anchors. ARKit VIO, RGB-D registration and appearance/proximity loop
    # closures are the only constraints entering the graph.
    ("RGBD/MarkerDetection", "false"),
    # Robust kernels and gravity constraints require g2o/GTSAM. Pin g2o so
    # results don't change with whichever optional solver a PC happens to
    # have installed.
    ("Optimizer/Strategy", "1"),
    # Replaying a long capture with 50 iterations at every graph update makes
    # total cost grow superlinearly. A warm-started online solve only keeps the
    # graph coherent for loop/proximity decisions; one full solve is run after
    # replay by rtabmap-reprocess's -final_opt_iterations option.
    ("Optimizer/Iterations", str(DEFAULT_ONLINE_OPTIMIZATION_ITERATIONS)),
    ("Optimizer/GravitySigma", "0.2"),
    ("Optimizer/Robust", "true"),
    ("Optimizer/PriorsIgnored", "true"),
    ("Optimizer/LandmarksIgnored", "true"),
    ("g2o/RobustKernelDelta", "8"),
    # Homebrew g2o may be built without CSparse/CHOLMOD. Explicitly select the
    # always-available sparse Eigen backend instead of silently falling back to
    # PCG, which is especially slow for this graph shape.
    ("g2o/Solver", "3"),
    ("DbSqlite3/InMemory", "false"),
)


_PROCESSED_NODE_RE = re.compile(r"Processed\s+(\d+)/(\d+)\s+nodes.*?\.\.\.\s+(\d+)ms")
_FINAL_START_RE = re.compile(
    r"FINAL_OPTIMIZATION_START\s+poses=(\d+)\s+constraints=(\d+).*?iterations=(\d+)"
)
_FINAL_DONE_RE = re.compile(
    r"FINAL_OPTIMIZATION_DONE\s+poses=(\d+)\s+constraints=(\d+)\s+"
    r"iterations_done=(\d+)\s+error=([^\s]+)\s+seconds=([^\s]+)"
)


class OfflineProcessingError(RuntimeError):
    pass


def _executable(path: Path) -> bool:
    return path.is_file() and os.access(path, os.X_OK)


def find_reprocess_binary(explicit: Optional[str] = None, prefer_cuda: bool = False) -> Optional[Path]:
    candidates = []
    if explicit:
        candidates.append(Path(explicit).expanduser())
    if os.environ.get(REPROCESS_ENV):
        candidates.append(Path(os.environ[REPROCESS_ENV]).expanduser())
    repository = Path(__file__).resolve().parents[2]
    # Prefer the project-local optimized build over an older system/debug
    # binary, while still letting an explicit path or environment override win.
    if prefer_cuda:
        candidates.append(repository / "build-pc-cuda/bin/rtabmap-reprocess")
    candidates.extend(
        repository / relative
        for relative in (
            "build/marketscanner-macos-release/bin/rtabmap-reprocess",
            "build/marketscanner-linux-release/bin/rtabmap-reprocess",
            "build/marketscanner-windows-release/bin/rtabmap-reprocess.exe",
        )
    )
    candidates.append(repository / "build-pc-release/bin/rtabmap-reprocess")
    discovered = shutil.which("rtabmap-reprocess")
    if discovered:
        candidates.append(Path(discovered))

    candidates.extend(
        repository / relative
        for relative in (
            "build/bin/rtabmap-reprocess",
            "build-pc-debug/bin/rtabmap-reprocess",
            "build/tools/Reprocess/rtabmap-reprocess",
            "build/Release/rtabmap-reprocess",
            "bin/rtabmap-reprocess",
            "build/bin/Release/rtabmap-reprocess.exe",
            "build/tools/Reprocess/Release/rtabmap-reprocess.exe",
        )
    )
    for candidate in candidates:
        resolved = candidate.resolve()
        if _executable(resolved):
            return resolved
    return None


def inspect_database(path: Path) -> Dict[str, Any]:
    result: Dict[str, Any] = {
        "path": str(path),
        "size_bytes": path.stat().st_size if path.is_file() else 0,
        "integrity": "missing",
        "node_count": 0,
        "rgbd_frame_count": 0,
        "optimized_pose_count": 0,
        "timestamp_regressions": 0,
        "link_table_present": False,
        "link_type_counts": {},
        "neighbor_link_count": 0,
        "loop_closure_count": 0,
        "loop_closure_pair_count": 0,
        "long_range_loop_pair_count": 0,
        "landmark_link_count": 0,
        "pose_prior_link_count": 0,
    }
    if not path.is_file():
        return result
    try:
        with closing(sqlite3.connect(path.resolve().as_uri() + "?mode=ro", uri=True)) as conn:
            integrity_row = conn.execute("PRAGMA quick_check").fetchone()
            result["integrity"] = str(integrity_row[0]) if integrity_row else "unknown"
            tables = set(base.sqlite_tables(conn))
            if "Node" in tables:
                result["node_count"] = int(conn.execute("SELECT count(*) FROM Node WHERE id>0").fetchone()[0])
                node_columns = set(base.table_columns(conn, "Node"))
                if "stamp" in node_columns:
                    previous = None
                    regressions = 0
                    for (stamp,) in conn.execute("SELECT stamp FROM Node WHERE id>0 ORDER BY id"):
                        if stamp is not None and previous is not None and float(stamp) < previous:
                            regressions += 1
                        if stamp is not None:
                            previous = float(stamp)
                    result["timestamp_regressions"] = regressions
            if "Data" in tables:
                data_columns = set(base.table_columns(conn, "Data"))
                required_columns = {"image", "depth", "calibration"}
                if required_columns.issubset(data_columns):
                    predicates = [f"length({column})>0" for column in sorted(required_columns)]
                    result["rgbd_frame_count"] = int(
                        conn.execute("SELECT count(*) FROM Data WHERE " + " AND ".join(predicates)).fetchone()[0]
                    )
            result["optimized_pose_count"] = len(base.extract_optimized_pose_blobs(conn))
            if "Link" in tables:
                result["link_table_present"] = True
                link_counts = {
                    int(link_type): int(count)
                    for link_type, count in conn.execute(
                        "SELECT type, count(*) FROM Link GROUP BY type"
                    )
                }
                loop_pairs = {
                    (min(int(from_id), int(to_id)), max(int(from_id), int(to_id)))
                    for from_id, to_id in conn.execute(
                        "SELECT from_id, to_id FROM Link WHERE type BETWEEN 1 AND 5"
                    )
                    if int(from_id) != int(to_id)
                }
                result["link_type_counts"] = {
                    str(link_type): count for link_type, count in sorted(link_counts.items())
                }
                result["neighbor_link_count"] = link_counts.get(0, 0) + link_counts.get(6, 0)
                result["loop_closure_count"] = sum(link_counts.get(kind, 0) for kind in (1, 2, 3, 4, 5))
                result["loop_closure_pair_count"] = len(loop_pairs)
                result["long_range_loop_pair_count"] = sum(
                    1 for from_id, to_id in loop_pairs if abs(to_id - from_id) >= 30
                )
                result["pose_prior_link_count"] = link_counts.get(7, 0)
                result["landmark_link_count"] = link_counts.get(8, 0)
    except sqlite3.Error as exc:
        result["integrity"] = f"error: {exc}"
    return result


def _constraint_pairs(path: Path, link_types: tuple[int, ...]) -> set[tuple[int, int]]:
    if not path.is_file() or not link_types:
        return set()
    placeholders = ",".join("?" for _ in link_types)
    try:
        with closing(sqlite3.connect(path.resolve().as_uri() + "?mode=ro", uri=True)) as conn:
            if "Link" not in set(base.sqlite_tables(conn)):
                return set()
            return {
                (min(int(from_id), int(to_id)), max(int(from_id), int(to_id)))
                for from_id, to_id in conn.execute(
                    f"SELECT from_id, to_id FROM Link WHERE type IN ({placeholders})",
                    link_types,
                )
                if int(from_id) != int(to_id)
            }
    except sqlite3.Error:
        return set()


def validate_capture_database(path: Path) -> Dict[str, Any]:
    inspection = inspect_database(path)
    if inspection["integrity"] != "ok":
        raise OfflineProcessingError(
            f"Input database integrity check failed ({inspection['integrity']}): {path}"
        )
    if inspection["node_count"] <= 0:
        raise OfflineProcessingError(f"Input database has no mapping nodes: {path}")
    if inspection["rgbd_frame_count"] <= 0:
        raise OfflineProcessingError(
            f"Input database has no complete RGB-D/calibration frames and cannot be reprocessed: {path}"
        )
    if inspection["timestamp_regressions"]:
        raise OfflineProcessingError(
            f"Input database has {inspection['timestamp_regressions']} timestamp regressions; "
            "the continuous trajectory is unsafe to reprocess automatically."
        )
    return inspection


def _command(
    binary: Path,
    input_database: Path,
    output_database: Path,
    extra_parameters: Iterable[tuple[str, str]] = (),
    final_optimization_iterations: int = DEFAULT_FINAL_OPTIMIZATION_ITERATIONS,
    final_optimization_epsilon: float = DEFAULT_FINAL_OPTIMIZATION_EPSILON,
    republish_input_loop_closures: bool = True,
) -> list[str]:
    command = [str(binary), "-default"]
    if republish_input_loop_closures:
        # Accepted phone loop closures are valuable constraints, especially
        # when thermal throttling limited the number found during capture.
        command.append("-pub_loops")
    for key, value in REPROCESS_PARAMETERS:
        command.extend((f"--{key}", value))
    for key, value in extra_parameters:
        command.extend((f"--{key}", value))
    if final_optimization_iterations > 0:
        command.extend(("-final_opt_iterations", str(final_optimization_iterations)))
        command.extend(("-final_opt_epsilon", f"{final_optimization_epsilon:.12g}"))
    # Deliberately omit -odom: ARKit VIO is the continuous metric prior. PC
    # feature matching adds loop/proximity constraints and globally optimizes
    # that graph without introducing a second odometry chain by default.
    command.extend((str(input_database), str(output_database)))
    return command


def parse_reprocess_runtime(log_text: str) -> Dict[str, Any]:
    node_samples = [
        (int(match.group(1)), int(match.group(2)), int(match.group(3)))
        for match in _PROCESSED_NODE_RE.finditer(log_text)
    ]
    durations = [sample[2] for sample in node_samples]
    final_start = list(_FINAL_START_RE.finditer(log_text))
    final_done = list(_FINAL_DONE_RE.finditer(log_text))
    runtime: Dict[str, Any] = {
        "processed_node_count": node_samples[-1][0] if node_samples else 0,
        "total_node_count": node_samples[-1][1] if node_samples else 0,
        "node_timing_sample_count": len(durations),
        "node_time_ms": {
            "median": round(_percentile([float(value) for value in durations], 0.5), 3),
            "p95": round(_percentile([float(value) for value in durations], 0.95), 3),
            "maximum": max(durations, default=0),
        },
        "final_optimization": {
            "started": bool(final_start),
            "completed": bool(final_done),
        },
    }
    if final_start:
        match = final_start[-1]
        runtime["final_optimization"].update(
            {
                "pose_count": int(match.group(1)),
                "constraint_count": int(match.group(2)),
                "requested_iterations": int(match.group(3)),
            }
        )
    if final_done:
        match = final_done[-1]
        runtime["final_optimization"].update(
            {
                "pose_count": int(match.group(1)),
                "constraint_count": int(match.group(2)),
                "iterations_done": int(match.group(3)),
                "final_error": float(match.group(4)),
                "elapsed_seconds": float(match.group(5)),
            }
        )
    return runtime


def _monitor_reprocess_log(
    path: Path,
    done: threading.Event,
    callback: ReprocessProgressCallback,
) -> None:
    offset = 0
    fragment = ""
    processed = 0
    total = 0
    last_emit = 0.0
    started = time.monotonic()
    final_stage = False
    while not done.wait(0.5):
        if not path.is_file():
            continue
        with path.open("r", encoding="utf-8", errors="replace") as handle:
            handle.seek(offset)
            chunk = handle.read()
            offset = handle.tell()
        if chunk:
            lines = (fragment + chunk).split("\n")
            fragment = lines.pop()
            for line in lines:
                node_match = _PROCESSED_NODE_RE.search(line)
                if node_match:
                    processed = int(node_match.group(1))
                    total = int(node_match.group(2))
                if _FINAL_START_RE.search(line):
                    final_stage = True
                    callback(0.92, "最终全局优化", "回放完成，正在执行一次高质量全图求解")
                if _FINAL_DONE_RE.search(line):
                    callback(0.98, "最终全局优化", "最终全图求解完成，正在验证输出数据库")
        now = time.monotonic()
        if processed and total and not final_stage and now - last_emit >= 1.0:
            fraction = min(0.90, 0.02 + 0.88 * processed / max(1, total))
            elapsed = int(now - started)
            callback(
                fraction,
                "节点回放与在线优化",
                f"已处理 {processed}/{total} 节点（{processed * 100 / total:.1f}%），已用时 "
                f"{elapsed // 60}分{elapsed % 60}秒",
            )
            last_emit = now


def _tail(text: str, limit: int = 12000) -> str:
    return text[-limit:] if len(text) > limit else text


def _tail_file(path: Path, limit: int = 12000) -> str:
    if not path.is_file():
        return ""
    with path.open("rb") as handle:
        handle.seek(0, os.SEEK_END)
        size = handle.tell()
        handle.seek(max(0, size - limit * 4), os.SEEK_SET)
        return _tail(handle.read().decode("utf-8", errors="replace"), limit)


def _log_contains(path: Path, messages: tuple[str, ...]) -> bool:
    if not path.is_file():
        return False
    with path.open("r", encoding="utf-8", errors="replace") as handle:
        return any(any(message in line.lower() for message in messages) for line in handle)


def _existing_directory(path: Path) -> Path:
    candidate = path
    while not candidate.is_dir():
        parent = candidate.parent
        if parent == candidate:
            raise OfflineProcessingError(f"No existing parent directory was found for: {path}")
        candidate = parent
    return candidate


def _thread_environment(thread_count: int) -> Dict[str, str]:
    threads = max(1, int(thread_count))
    environment = os.environ.copy()
    environment.update(
        {
            "OMP_NUM_THREADS": str(threads),
            "OMP_DYNAMIC": "FALSE",
            "OMP_WAIT_POLICY": "PASSIVE",
            # OpenCV 4 reads this before initializing its TBB/OpenMP backend.
            "OPENCV_FOR_THREADS_NUM": str(threads),
        }
    )
    return environment


def _staging_directory() -> Path:
    configured = os.environ.get(REPROCESS_TEMP_ENV)
    root = Path(configured).expanduser() if configured else Path(tempfile.gettempdir())
    root = root.resolve()
    if not root.is_dir():
        raise OfflineProcessingError(f"PC staging directory does not exist: {root}")
    return root


def _copy_and_sync(source: Path, destination: Path) -> None:
    shutil.copy2(source, destination)
    # Windows rejects fsync() on a read-only CRT descriptor with EBADF. Open
    # the copied staging file writable so both POSIX and Windows flush the
    # actual destination bytes before reprocess starts.
    with destination.open("r+b") as handle:
        os.fsync(handle.fileno())


def _inject_user_links(
    database: Path,
    link_injections: Iterable[Dict[str, Any]],
) -> Dict[str, Any]:
    """Insert validated kUserClosure links into a disposable database copy."""
    injections = tuple(link_injections)
    if not injections:
        return {
            "requested_count": 0,
            "injected_count": 0,
            "pairs": [],
        }
    required_columns = {
        "from_id",
        "to_id",
        "type",
        "information_matrix",
        "transform",
        "user_data",
    }
    normalized: list[Dict[str, Any]] = []
    seen_pairs: set[tuple[int, int]] = set()
    for index, raw in enumerate(injections, start=1):
        if not isinstance(raw, dict):
            raise OfflineProcessingError(f"Manual constraint {index} must be an object.")
        try:
            from_id = int(raw["from_id"])
            to_id = int(raw["to_id"])
            link_type = int(raw.get("type", 4))
            transform = tuple(float(value) for value in raw["transform"])
            information = tuple(float(value) for value in raw["information_matrix"])
        except (KeyError, TypeError, ValueError) as exc:
            raise OfflineProcessingError(
                f"Manual constraint {index} has invalid node ids or matrices."
            ) from exc
        if from_id <= 0 or to_id <= 0 or from_id == to_id:
            raise OfflineProcessingError(
                f"Manual constraint {index} must connect two different positive node ids."
            )
        if from_id < to_id:
            raise OfflineProcessingError(
                f"Manual constraint {index} must use RTAB-Map ordering from_id > to_id."
            )
        if link_type != 4:
            raise OfflineProcessingError(
                f"Manual constraint {index} must use RTAB-Map kUserClosure type 4."
            )
        if len(transform) != 12 or not all(math.isfinite(value) for value in transform):
            raise OfflineProcessingError(
                f"Manual constraint {index} must contain 12 finite transform floats."
            )
        if len(information) != 36 or not all(math.isfinite(value) for value in information):
            raise OfflineProcessingError(
                f"Manual constraint {index} must contain a finite 6x6 information matrix."
            )
        if any(information[axis * 6 + axis] <= 0.0 for axis in range(6)):
            raise OfflineProcessingError(
                f"Manual constraint {index} must have a positive information diagonal."
            )
        pair = (to_id, from_id)
        if pair in seen_pairs:
            raise OfflineProcessingError(
                f"Manual constraint {index} duplicates node pair {from_id}->{to_id}."
            )
        seen_pairs.add(pair)
        normalized.append(
            {
                "from_id": from_id,
                "to_id": to_id,
                "transform": transform,
                "information": information,
            }
        )

    try:
        with closing(sqlite3.connect(database)) as connection:
            tables = set(base.sqlite_tables(connection))
            if not {"Node", "Link"}.issubset(tables):
                raise OfflineProcessingError(
                    "The disposable RTAB-Map database must contain Node and Link tables."
                )
            columns = set(base.table_columns(connection, "Link"))
            if not required_columns.issubset(columns):
                missing = ", ".join(sorted(required_columns - columns))
                raise OfflineProcessingError(
                    f"The RTAB-Map Link schema cannot store user closures; missing: {missing}."
                )
            node_ids = {
                int(row[0])
                for row in connection.execute("SELECT id FROM Node WHERE id > 0")
            }
            for item in normalized:
                if item["from_id"] not in node_ids or item["to_id"] not in node_ids:
                    raise OfflineProcessingError(
                        "A manual constraint references a node that is not present in the database: "
                        f"{item['from_id']}->{item['to_id']}."
                    )
                conflicts = list(
                    connection.execute(
                        "SELECT from_id, to_id, type FROM Link "
                        "WHERE (from_id=? AND to_id=?) OR (from_id=? AND to_id=?)",
                        (
                            item["from_id"],
                            item["to_id"],
                            item["to_id"],
                            item["from_id"],
                        ),
                    )
                )
                non_user = [row for row in conflicts if int(row[2]) != 4]
                if non_user:
                    raise OfflineProcessingError(
                        "Manual repair refused to replace an existing non-user graph edge for "
                        f"{item['from_id']}->{item['to_id']}."
                    )
                connection.execute(
                    "DELETE FROM Link WHERE type=4 AND "
                    "((from_id=? AND to_id=?) OR (from_id=? AND to_id=?))",
                    (
                        item["from_id"],
                        item["to_id"],
                        item["to_id"],
                        item["from_id"],
                    ),
                )
                connection.execute(
                    "INSERT INTO Link("
                    "from_id, to_id, type, information_matrix, transform, user_data"
                    ") VALUES(?,?,?,?,?,NULL)",
                    (
                        item["from_id"],
                        item["to_id"],
                        4,
                        sqlite3.Binary(struct.pack("<36d", *item["information"])),
                        sqlite3.Binary(struct.pack("<12f", *item["transform"])),
                    ),
                )
            connection.commit()
            integrity_row = connection.execute("PRAGMA quick_check").fetchone()
            integrity = str(integrity_row[0]) if integrity_row else "unknown"
            if integrity != "ok":
                raise OfflineProcessingError(
                    f"Manual constraint staging database failed quick_check: {integrity}."
                )
    except sqlite3.Error as exc:
        raise OfflineProcessingError(
            f"Failed to inject manual user closures into the disposable database: {exc}"
        ) from exc
    return {
        "requested_count": len(normalized),
        "injected_count": len(normalized),
        "pairs": [
            {
                "from_id": item["from_id"],
                "to_id": item["to_id"],
                "type": 4,
            }
            for item in normalized
        ],
    }


def _database_poses(path: Path, optimized: bool) -> Dict[int, tuple[float, ...]]:
    poses: Dict[int, tuple[float, ...]] = {}
    with closing(sqlite3.connect(path.resolve().as_uri() + "?mode=ro", uri=True)) as conn:
        if "Node" not in set(base.sqlite_tables(conn)):
            return poses
        optimized_blobs = base.extract_optimized_pose_blobs(conn) if optimized else {}
        for node_id, raw_blob in conn.execute("SELECT id, pose FROM Node WHERE id>0 ORDER BY id"):
            blob = optimized_blobs.get(int(node_id)) if optimized else raw_blob
            matrix = base.parse_transform_matrix(blob) if blob else None
            if matrix is not None:
                poses[int(node_id)] = matrix
    return poses


def _percentile(values: list[float], ratio: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    index = min(len(ordered) - 1, max(0, int(round((len(ordered) - 1) * ratio))))
    return ordered[index]


def _translation(matrix: tuple[float, ...]) -> tuple[float, float, float]:
    return matrix[3], matrix[7], matrix[11]


def _rotation_difference_degrees(first: tuple[float, ...], second: tuple[float, ...]) -> float:
    # trace(Ra^T Rb) is the Frobenius inner product of the two 3x3 rotations.
    rotation_indices = (0, 1, 2, 4, 5, 6, 8, 9, 10)
    trace = sum(first[index] * second[index] for index in rotation_indices)
    cosine = min(1.0, max(-1.0, (trace - 1.0) / 2.0))
    return math.degrees(math.acos(cosine))


def trajectory_metrics(poses: Dict[int, tuple[float, ...]]) -> Dict[str, Any]:
    node_ids = sorted(poses)
    finite_ids = [
        node_id
        for node_id in node_ids
        if all(math.isfinite(value) for value in poses[node_id])
    ]
    positions = [_translation(poses[node_id]) for node_id in finite_ids]
    step_distances: list[float] = []
    step_rotations: list[float] = []
    for first_id, second_id in zip(finite_ids, finite_ids[1:]):
        first_position = _translation(poses[first_id])
        second_position = _translation(poses[second_id])
        step_distances.append(math.dist(first_position, second_position))
        step_rotations.append(_rotation_difference_degrees(poses[first_id], poses[second_id]))
    vertical_values = [position[2] for position in positions]
    start_end_distance = math.dist(positions[0], positions[-1]) if len(positions) > 1 else 0.0
    endpoint_band_size = min(len(vertical_values) // 2, max(1, int(math.ceil(len(vertical_values) * 0.10))))
    first_vertical_band = vertical_values[:endpoint_band_size]
    last_vertical_band = vertical_values[-endpoint_band_size:]
    vertical_endpoint_delta = (
        vertical_values[-1] - vertical_values[0] if len(vertical_values) > 1 else 0.0
    )
    vertical_endpoint_band_shift = (
        statistics.median(last_vertical_band) - statistics.median(first_vertical_band)
        if first_vertical_band and last_vertical_band
        else 0.0
    )
    return {
        "pose_count": len(node_ids),
        "finite_pose_count": len(finite_ids),
        "nonfinite_pose_count": len(node_ids) - len(finite_ids),
        "trajectory_length_m": round(sum(step_distances), 4),
        "start_end_distance_m": round(start_end_distance, 4),
        "median_step_m": round(_percentile(step_distances, 0.5), 4),
        "p95_step_m": round(_percentile(step_distances, 0.95), 4),
        "max_step_m": round(max(step_distances, default=0.0), 4),
        "p95_step_rotation_deg": round(_percentile(step_rotations, 0.95), 3),
        "max_step_rotation_deg": round(max(step_rotations, default=0.0), 3),
        "vertical_span_m": round(max(vertical_values) - min(vertical_values), 4) if vertical_values else 0.0,
        "vertical_endpoint_delta_m": round(vertical_endpoint_delta, 4),
        "vertical_endpoint_band_shift_m": round(vertical_endpoint_band_shift, 4),
        "vertical_endpoint_band_pose_count": endpoint_band_size,
    }


def _matrix_multiply(
    first: tuple[float, ...], second: tuple[float, ...]
) -> tuple[float, ...]:
    return tuple(
        (
            sum(first[row * 4 + k] * second[k * 4 + column] for k in range(3))
            if column < 3
            else first[row * 4 + 3]
            + sum(first[row * 4 + k] * second[k * 4 + 3] for k in range(3))
        )
        for row in range(3)
        for column in range(4)
    )


def _matrix_inverse(matrix: tuple[float, ...]) -> tuple[float, ...]:
    return (
        matrix[0], matrix[4], matrix[8],
        -(matrix[0] * matrix[3] + matrix[4] * matrix[7] + matrix[8] * matrix[11]),
        matrix[1], matrix[5], matrix[9],
        -(matrix[1] * matrix[3] + matrix[5] * matrix[7] + matrix[9] * matrix[11]),
        matrix[2], matrix[6], matrix[10],
        -(matrix[2] * matrix[3] + matrix[6] * matrix[7] + matrix[10] * matrix[11]),
    )


def _relative_transform(
    first: tuple[float, ...], second: tuple[float, ...]
) -> tuple[float, ...]:
    return _matrix_multiply(_matrix_inverse(first), second)


def _transform_translation_m(matrix: tuple[float, ...]) -> float:
    return math.sqrt(matrix[3] ** 2 + matrix[7] ** 2 + matrix[11] ** 2)


def _transform_rotation_degrees(matrix: tuple[float, ...]) -> float:
    cosine = min(
        1.0,
        max(-1.0, (matrix[0] + matrix[5] + matrix[10] - 1.0) / 2.0),
    )
    return math.degrees(math.acos(cosine))


def _raw_pose_inventory(
    path: Path,
) -> tuple[list[int], Dict[int, float], Dict[int, tuple[float, ...]]]:
    try:
        with closing(
            sqlite3.connect(path.resolve().as_uri() + "?mode=ro", uri=True)
        ) as connection:
            rows = connection.execute(
                "SELECT id, stamp, pose FROM Node WHERE id>0 ORDER BY id"
            ).fetchall()
    except sqlite3.Error as exc:
        raise OfflineProcessingError(
            f"Cannot read immutable raw VIO poses from {path}: {exc}"
        ) from exc
    node_ids: list[int] = []
    stamps: Dict[int, float] = {}
    poses: Dict[int, tuple[float, ...]] = {}
    previous_stamp: Optional[float] = None
    for node_id_value, stamp_value, blob in rows:
        if (
            isinstance(node_id_value, bool)
            or not isinstance(node_id_value, int)
            or node_id_value <= 0
            or isinstance(stamp_value, bool)
        ):
            raise OfflineProcessingError("Raw Node.pose inventory is invalid.")
        try:
            stamp = float(stamp_value)
        except (TypeError, ValueError) as exc:
            raise OfflineProcessingError("Raw Node.pose timestamp is invalid.") from exc
        matrix = base.parse_transform_matrix(blob) if isinstance(blob, bytes) else None
        if (
            not math.isfinite(stamp)
            or (previous_stamp is not None and stamp <= previous_stamp)
            or matrix is None
            or not all(math.isfinite(value) for value in matrix)
        ):
            raise OfflineProcessingError(
                "Raw Node.pose inventory is incomplete, non-finite, or not time ordered."
            )
        node_ids.append(node_id_value)
        stamps[node_id_value] = stamp
        poses[node_id_value] = matrix
        previous_stamp = stamp
    if not node_ids:
        raise OfflineProcessingError("Raw Node.pose trajectory is empty.")
    return node_ids, stamps, poses


def _reset_bridge_candidates(
    path: Path,
    *,
    previous_segment_ids: set[int],
    next_segment_ids: set[int],
    stitched_poses: Dict[int, tuple[float, ...]],
    raw_poses: Dict[int, tuple[float, ...]],
) -> list[Dict[str, Any]]:
    candidates: list[Dict[str, Any]] = []
    seen: set[tuple[int, int, int]] = set()
    try:
        with closing(
            sqlite3.connect(path.resolve().as_uri() + "?mode=ro", uri=True)
        ) as connection:
            if "Link" not in set(base.sqlite_tables(connection)):
                return []
            rows = connection.execute(
                "SELECT from_id, to_id, type, transform FROM Link "
                "WHERE type IN (1,2,3) AND length(transform)=48"
            )
            for from_id_value, to_id_value, link_type_value, blob in rows:
                from_id = int(from_id_value)
                to_id = int(to_id_value)
                link_type = int(link_type_value)
                pair_key = (min(from_id, to_id), max(from_id, to_id), link_type)
                if pair_key in seen:
                    continue
                if not (
                    (from_id in previous_segment_ids and to_id in next_segment_ids)
                    or (to_id in previous_segment_ids and from_id in next_segment_ids)
                ):
                    continue
                link = base.parse_transform_matrix(blob)
                if link is None or not all(math.isfinite(value) for value in link):
                    continue
                link_translation = _transform_translation_m(link)
                link_rotation = _transform_rotation_degrees(link)
                if link_translation > 2.0 or link_rotation > 90.0:
                    continue
                if from_id in previous_segment_ids:
                    previous_id = from_id
                    next_id = to_id
                    mapping = _matrix_multiply(
                        _matrix_multiply(stitched_poses[previous_id], link),
                        _matrix_inverse(raw_poses[next_id]),
                    )
                else:
                    previous_id = to_id
                    next_id = from_id
                    mapping = _matrix_multiply(
                        _matrix_multiply(
                            stitched_poses[previous_id], _matrix_inverse(link)
                        ),
                        _matrix_inverse(raw_poses[next_id]),
                    )
                if not all(math.isfinite(value) for value in mapping):
                    continue
                seen.add(pair_key)
                candidates.append(
                    {
                        "from_id": from_id,
                        "to_id": to_id,
                        "previous_node_id": previous_id,
                        "next_node_id": next_id,
                        "type": link_type,
                        "link_translation_m": link_translation,
                        "link_rotation_deg": link_rotation,
                        "mapping": mapping,
                    }
                )
    except sqlite3.Error as exc:
        raise OfflineProcessingError(
            f"Cannot audit Link evidence for raw VIO recovery: {exc}"
        ) from exc
    return candidates


def _mapping_difference(
    first: tuple[float, ...], second: tuple[float, ...]
) -> tuple[float, float]:
    difference = _relative_transform(first, second)
    return (
        _transform_translation_m(difference),
        _transform_rotation_degrees(difference),
    )


def _select_reset_mapping(
    candidates: list[Dict[str, Any]],
) -> tuple[Optional[Dict[str, Any]], list[Dict[str, Any]], Dict[str, Any]]:
    if len(candidates) < 2:
        return None, [], {"reason": "fewer_than_two_independent_short_links"}
    consensus_sets: list[list[Dict[str, Any]]] = []
    for candidate in candidates:
        mapping = candidate["mapping"]
        consensus_sets.append(
            [
                other
                for other in candidates
                if _mapping_difference(mapping, other["mapping"])[0] <= 0.50
                and _mapping_difference(mapping, other["mapping"])[1] <= 10.0
            ]
        )
    consensus_sets.sort(key=len, reverse=True)
    best = consensus_sets[0]
    if len(best) < 2:
        return None, [], {"reason": "no_multi_link_transform_consensus"}
    competing = [
        group
        for group in consensus_sets[1:]
        if len(group) == len(best)
        and not any(item in best for item in group)
    ]
    if competing:
        return None, [], {"reason": "multiple_equal_transform_consensus_groups"}
    selected = min(
        best,
        key=lambda item: sum(
            _mapping_difference(item["mapping"], other["mapping"])[0]
            + _mapping_difference(item["mapping"], other["mapping"])[1] / 20.0
            for other in best
        ),
    )
    translation_spread = max(
        (_mapping_difference(selected["mapping"], item["mapping"])[0] for item in best),
        default=0.0,
    )
    rotation_spread = max(
        (_mapping_difference(selected["mapping"], item["mapping"])[1] for item in best),
        default=0.0,
    )
    return selected, best, {
        "candidate_count": len(candidates),
        "consensus_count": len(best),
        "maximum_consensus_translation_spread_m": round(translation_spread, 6),
        "maximum_consensus_rotation_spread_deg": round(rotation_spread, 6),
    }


def recover_raw_continuous_vio_poses(
    input_database: Path, horizontal_axes: str = "ios_prior"
) -> tuple[list[Dict[str, Any]], Dict[str, Any]]:
    """Recover an auditable diagnostic raw-VIO chain without changing SQLite.

    A large absolute Node.pose jump is stitched only when at least two
    independent, short RTAB-Map structural links agree on one rigid mapping
    between the adjacent coordinate epochs. Ambiguous or unsupported jumps
    remain fatal. The returned result is diagnostic-only and is never a claim
    that RTAB-Map produced a complete optimized graph.
    """
    if horizontal_axes not in {"xy", "xz", "ios_prior"}:
        raise OfflineProcessingError("Raw VIO horizontal axes are invalid.")
    inspection = validate_capture_database(input_database)
    node_ids, stamps, raw_poses = _raw_pose_inventory(input_database)
    before_metrics = trajectory_metrics(raw_poses)
    rejection_reasons: list[str] = []
    if len(node_ids) != int(inspection.get("node_count", 0)):
        rejection_reasons.append("Raw Node.pose coverage is incomplete.")
    jump_indexes = [
        index
        for index in range(1, len(node_ids))
        if _transform_translation_m(
            _relative_transform(raw_poses[node_ids[index - 1]], raw_poses[node_ids[index]])
        )
        > 3.0
        or _transform_rotation_degrees(
            _relative_transform(raw_poses[node_ids[index - 1]], raw_poses[node_ids[index]])
        )
        > 120.0
    ]
    stitched_poses = dict(raw_poses)
    reset_repairs: list[Dict[str, Any]] = []
    segment_start = 0
    for jump_sequence, jump_index in enumerate(jump_indexes):
        previous_id = node_ids[jump_index - 1]
        next_id = node_ids[jump_index]
        next_jump_index = (
            jump_indexes[jump_sequence + 1]
            if jump_sequence + 1 < len(jump_indexes)
            else len(node_ids)
        )
        previous_segment_ids = set(node_ids[segment_start:jump_index])
        next_segment_ids = set(node_ids[jump_index:next_jump_index])
        candidates = _reset_bridge_candidates(
            input_database,
            previous_segment_ids=previous_segment_ids,
            next_segment_ids=next_segment_ids,
            stitched_poses=stitched_poses,
            raw_poses=raw_poses,
        )
        selected, consensus, selection_audit = _select_reset_mapping(candidates)
        before_relative = _relative_transform(
            stitched_poses[previous_id], raw_poses[next_id]
        )
        if selected is None:
            rejection_reasons.append(
                f"Raw VIO jump {previous_id}->{next_id} has no unique multi-Link coordinate-reset bridge "
                f"({selection_audit['reason']})."
            )
            break
        # The consensus determines the coordinate-epoch mapping. Prefer the
        # agreeing bridge closest to the actual reset boundary for the applied
        # transform and audit record, instead of letting a distant loop with a
        # nearly identical mapping obscure which local continuity was repaired.
        selected = min(
            consensus,
            key=lambda item: (
                abs(int(item["previous_node_id"]) - previous_id)
                + abs(int(item["next_node_id"]) - next_id),
                float(item["link_translation_m"]),
            ),
        )
        mapping = selected["mapping"]
        for node_id in node_ids[jump_index:next_jump_index]:
            stitched_poses[node_id] = _matrix_multiply(mapping, raw_poses[node_id])
        after_relative = _relative_transform(
            stitched_poses[previous_id], stitched_poses[next_id]
        )
        after_translation = _transform_translation_m(after_relative)
        after_rotation = _transform_rotation_degrees(after_relative)
        if after_translation > 3.0 or after_rotation > 120.0:
            rejection_reasons.append(
                f"Raw VIO reset bridge for {previous_id}->{next_id} remains discontinuous."
            )
            break
        reset_repairs.append(
            {
                "format": "SupermarketRawVIOCoordinateResetRepair",
                "version": 1,
                "before_node_id": previous_id,
                "after_node_id": next_id,
                "before_timestamp": stamps[previous_id],
                "after_timestamp": stamps[next_id],
                "timestamp_gap_seconds": round(stamps[next_id] - stamps[previous_id], 6),
                "before_step_translation_m": round(
                    _transform_translation_m(before_relative), 6
                ),
                "before_step_rotation_deg": round(
                    _transform_rotation_degrees(before_relative), 6
                ),
                "after_step_translation_m": round(after_translation, 6),
                "after_step_rotation_deg": round(after_rotation, 6),
                "selected_bridge": {
                    key: selected[key]
                    for key in (
                        "from_id",
                        "to_id",
                        "previous_node_id",
                        "next_node_id",
                        "type",
                        "link_translation_m",
                        "link_rotation_deg",
                    )
                },
                "applied_mapping_translation": {
                    "x": mapping[3],
                    "y": mapping[7],
                    "z": mapping[11],
                },
                "applied_mapping_rotation_deg": _transform_rotation_degrees(mapping),
                "consensus_links": [
                    {
                        key: item[key]
                        for key in (
                            "from_id",
                            "to_id",
                            "previous_node_id",
                            "next_node_id",
                            "type",
                            "link_translation_m",
                            "link_rotation_deg",
                        )
                    }
                    for item in consensus
                ],
                **selection_audit,
            }
        )
        segment_start = jump_index
    after_metrics = trajectory_metrics(stitched_poses)
    if not rejection_reasons and float(after_metrics["max_step_m"]) > 3.0:
        rejection_reasons.append(
            f"Recovered raw VIO neighbor step {after_metrics['max_step_m']:.2f} m exceeds 3.00 m."
        )
    if not rejection_reasons and float(after_metrics["max_step_rotation_deg"]) > 120.0:
        rejection_reasons.append("Recovered raw VIO neighbor rotation exceeds 120 degrees.")
    assessment = {
        "format": "SupermarketRawContinuousVIORecoveryAssessment",
        "version": 2,
        "status": "rejected" if rejection_reasons else "pass",
        "source": (
            "immutable_node_pose_with_verified_link_reset_stitch"
            if reset_repairs
            else "immutable_node_pose"
        ),
        "diagnostic_only": True,
        "pose_count": len(stitched_poses),
        "node_count": inspection.get("node_count", 0),
        "raw_before_recovery": before_metrics,
        "raw": after_metrics,
        "coordinate_reset_count": len(reset_repairs),
        "coordinate_reset_repairs": reset_repairs,
        "rejection_reasons": rejection_reasons,
    }
    poses = []
    if not rejection_reasons:
        for node_id in node_ids:
            parsed = base.parse_rtabmap_transform_3d(
                struct.pack("<12f", *stitched_poses[node_id]), horizontal_axes
            )
            if parsed is None:
                raise OfflineProcessingError("Recovered raw VIO pose conversion failed.")
            x, y, _height, yaw = parsed
            poses.append(
                {
                    "node_id": node_id,
                    "timestamp": stamps[node_id],
                    "x": x,
                    "y": y,
                    "yaw": yaw,
                }
            )
    return poses, assessment


def optimization_displacement_metrics(
    raw: Dict[int, tuple[float, ...]], optimized: Dict[int, tuple[float, ...]]
) -> Dict[str, Any]:
    """Summarize where optimization moved the trajectory without judging it.

    Large corrections may be entirely legitimate, so these metrics are
    diagnostic rather than a publication gate.  They make residual-drift and
    local-warp investigations possible without reopening the databases.
    """
    common_ids = sorted(set(raw) & set(optimized))
    translations: list[float] = []
    vertical_corrections: list[float] = []
    rotations: list[float] = []
    correction_steps: list[float] = []
    previous_correction: Optional[tuple[float, float, float]] = None
    for node_id in common_ids:
        raw_position = _translation(raw[node_id])
        optimized_position = _translation(optimized[node_id])
        correction = tuple(
            optimized_position[index] - raw_position[index] for index in range(3)
        )
        translations.append(math.sqrt(sum(value * value for value in correction)))
        vertical_corrections.append(abs(correction[2]))
        rotations.append(_rotation_difference_degrees(raw[node_id], optimized[node_id]))
        if previous_correction is not None:
            correction_steps.append(math.dist(previous_correction, correction))
        previous_correction = correction
    return {
        "pose_count": len(common_ids),
        "translation_correction_median_m": round(_percentile(translations, 0.50), 4),
        "translation_correction_p95_m": round(_percentile(translations, 0.95), 4),
        "translation_correction_max_m": round(max(translations, default=0.0), 4),
        "vertical_correction_p95_m": round(_percentile(vertical_corrections, 0.95), 4),
        "vertical_correction_max_m": round(max(vertical_corrections, default=0.0), 4),
        "rotation_correction_p95_deg": round(_percentile(rotations, 0.95), 3),
        "rotation_correction_max_deg": round(max(rotations, default=0.0), 3),
        "neighbor_correction_change_p95_m": round(_percentile(correction_steps, 0.95), 4),
        "neighbor_correction_change_max_m": round(max(correction_steps, default=0.0), 4),
    }


def assess_optimized_trajectory(input_database: Path, output_database: Path) -> Dict[str, Any]:
    raw_all = _database_poses(input_database, optimized=False)
    optimized_all = _database_poses(output_database, optimized=True)
    common_ids = sorted(set(raw_all) & set(optimized_all))
    raw = {node_id: raw_all[node_id] for node_id in common_ids}
    optimized = {node_id: optimized_all[node_id] for node_id in common_ids}
    raw_metrics = trajectory_metrics(raw)
    optimized_metrics = trajectory_metrics(optimized)
    displacement_metrics = optimization_displacement_metrics(raw, optimized)
    input_database_inspection = inspect_database(input_database)
    optimized_database = inspect_database(output_database)
    input_loop_pairs = _constraint_pairs(input_database, (1, 2, 3, 4, 5))
    output_graph_pairs = _constraint_pairs(output_database, (0, 1, 2, 3, 4, 5, 6))
    retained_input_loop_pairs = input_loop_pairs & output_graph_pairs
    input_long_range_loop_pairs = {
        pair for pair in input_loop_pairs if abs(pair[1] - pair[0]) >= 30
    }
    retained_long_range_loop_pairs = input_long_range_loop_pairs & output_graph_pairs
    input_loop_retention = (
        len(retained_input_loop_pairs) / len(input_loop_pairs) if input_loop_pairs else 1.0
    )
    input_long_range_retention = (
        len(retained_long_range_loop_pairs) / len(input_long_range_loop_pairs)
        if input_long_range_loop_pairs
        else 1.0
    )
    coverage = len(common_ids) / max(1, len(raw_all))
    warnings: list[str] = []
    rejection_reasons: list[str] = []
    score = 100

    if coverage < 0.98:
        warnings.append(f"Only {coverage * 100:.1f}% of input poses have optimized counterparts.")
        score -= 20
    if coverage < 0.90:
        rejection_reasons.append("Optimized pose coverage is below 90%.")
    if optimized_metrics["nonfinite_pose_count"]:
        rejection_reasons.append("The optimized trajectory contains non-finite poses.")

    raw_max_step = float(raw_metrics["max_step_m"])
    optimized_max_step = float(optimized_metrics["max_step_m"])
    step_limit = max(3.0, raw_max_step * 3.0 + 0.5)
    if optimized_max_step > step_limit:
        rejection_reasons.append(
            f"Optimized neighbor step {optimized_max_step:.2f} m exceeds the safe {step_limit:.2f} m limit."
        )

    raw_p95 = float(raw_metrics["p95_step_m"])
    optimized_p95 = float(optimized_metrics["p95_step_m"])
    if optimized_p95 > max(1.5, raw_p95 * 2.5 + 0.1):
        warnings.append("The optimized trajectory enlarged normal frame-to-frame translation unusually.")
        score -= 20

    raw_rotation = float(raw_metrics["max_step_rotation_deg"])
    optimized_rotation = float(optimized_metrics["max_step_rotation_deg"])
    rotation_limit = max(75.0, raw_rotation * 2.0 + 20.0)
    if optimized_rotation > rotation_limit:
        rejection_reasons.append(
            f"Optimized neighbor rotation {optimized_rotation:.1f}° exceeds the safe {rotation_limit:.1f}° limit."
        )

    raw_vertical = float(raw_metrics["vertical_span_m"])
    optimized_vertical = float(optimized_metrics["vertical_span_m"])
    if optimized_vertical > max(raw_vertical + 0.75, raw_vertical * 1.75 + 0.25):
        warnings.append("Vertical drift increased after optimization despite gravity constraints.")
        score -= 15

    # This production profile assumes a single-floor supermarket.  A reduced
    # vertical span can still hide a near-monotonic start-to-end height drift,
    # as seen when both raw and optimized trajectories drift in the same
    # direction. Compare robust endpoint bands so a single crouch/raised frame
    # does not dominate the diagnostic. This is intentionally a warning, not a
    # hard rejection, because genuine ramps and sustained posture changes are
    # still possible.
    optimized_band_shift = abs(float(optimized_metrics["vertical_endpoint_band_shift_m"]))
    if len(common_ids) >= 50 and optimized_band_shift > 0.45:
        warnings.append(
            "The optimized single-floor trajectory retains a "
            f"{optimized_band_shift:.2f} m vertical shift between its start and end bands; "
            "residual height drift or a sustained device-height change requires review."
        )
        score -= 10

    raw_length = float(raw_metrics["trajectory_length_m"])
    optimized_length = float(optimized_metrics["trajectory_length_m"])
    length_ratio = optimized_length / raw_length if raw_length > 1e-6 else 1.0
    if length_ratio < 0.65 or length_ratio > 1.35:
        warnings.append(f"Trajectory length changed substantially after optimization (ratio {length_ratio:.3f}).")
        score -= 15
    if length_ratio < 0.25 or length_ratio > 3.0:
        rejection_reasons.append("Trajectory scale changed beyond the automatic safety envelope.")

    # Smooth odometry alone cannot correct accumulated global drift. For a
    # non-trivial graph, make the lack of any loop/proximity constraint visible
    # instead of presenting numerical continuity as successful error closure.
    if (
        optimized_database["link_table_present"]
        and len(common_ids) >= 50
        and optimized_database["loop_closure_count"] == 0
    ):
        warnings.append(
            "No visual or proximity loop-closure constraint was saved; global accumulated drift remains unobservable."
        )
        score -= 20

    if input_long_range_loop_pairs and input_long_range_retention < 0.80:
        warnings.append(
            f"Only {input_long_range_retention * 100:.1f}% of accepted long-range input loop-closure pairs remain represented in the output graph."
        )
        score -= 25
    if input_long_range_loop_pairs and input_long_range_retention < 0.50:
        rejection_reasons.append("More than half of the accepted long-range input loop-closure pairs were lost.")

    # A handful of short temporal links cannot constrain drift over a long
    # supermarket route. Mark the graph as weak so the adaptive workflow can
    # run the more expensive keyframe/appearance discovery pass only when it
    # is actually needed.
    minimum_long_range_pairs = max(2, len(common_ids) // 500)
    if (
        len(common_ids) >= 200
        and optimized_database["long_range_loop_pair_count"] < minimum_long_range_pairs
    ):
        warnings.append(
            "The graph has too few long-range loop-closure pairs for its trajectory length; accumulated drift may remain weakly observable."
        )
        score -= 15

    if rejection_reasons:
        score = min(score, 25)
        status = "rejected"
    elif warnings:
        status = "warning"
    else:
        status = "pass"
    return {
        "format": "SupermarketTrajectoryErrorAssessment",
        "version": 2,
        "profile": "software_only_no_fiducials",
        "status": status,
        "quality_score": max(0, score),
        "optimized_pose_coverage": round(coverage, 6),
        "common_pose_count": len(common_ids),
        "raw": raw_metrics,
        "optimized": optimized_metrics,
        "optimization_displacement": displacement_metrics,
        "trajectory_length_ratio": round(length_ratio, 6),
        "constraints": {
            "link_table_present": optimized_database["link_table_present"],
            "neighbor_link_count": optimized_database["neighbor_link_count"],
            "loop_closure_count": optimized_database["loop_closure_count"],
            "loop_closure_pair_count": optimized_database["loop_closure_pair_count"],
            "long_range_loop_pair_count": optimized_database["long_range_loop_pair_count"],
            "input_loop_closure_pair_count": len(input_loop_pairs),
            "retained_input_loop_closure_pair_count": len(retained_input_loop_pairs),
            "input_loop_closure_retention": round(input_loop_retention, 6),
            "input_long_range_loop_pair_count": input_database_inspection["long_range_loop_pair_count"],
            "retained_input_long_range_loop_pair_count": len(retained_long_range_loop_pairs),
            "input_long_range_loop_retention": round(input_long_range_retention, 6),
            "landmark_link_count": optimized_database["landmark_link_count"],
            "pose_prior_link_count": optimized_database["pose_prior_link_count"],
        },
        "warnings": warnings,
        "rejection_reasons": rejection_reasons,
    }


def assess_raw_continuous_vio_recovery(input_database: Path) -> Dict[str, Any]:
    """Validate the immutable full Node.pose chain as a diagnostic baseline.

    This is intentionally stricter than accepting a partial Admin.opt_poses
    graph and intentionally weaker than claiming global RTAB-Map optimization.
    It exists only so exact node-bound manual map anchors can recover a long,
    physically continuous VIO route when the replay graph is incomplete.
    """
    _poses, assessment = recover_raw_continuous_vio_poses(input_database)
    return assessment


def run_reprocess(
    input_database: Path,
    output_database: Path,
    explicit_binary: Optional[str] = None,
    timeout_seconds: int = 24 * 60 * 60,
    thread_count: int = DEFAULT_PC_THREADS,
    use_local_staging: bool = True,
    accelerator_backend: str = "cpu",
    extra_parameters: Iterable[tuple[str, str]] = (),
    online_optimization_iterations: int = DEFAULT_ONLINE_OPTIMIZATION_ITERATIONS,
    final_optimization_iterations: int = DEFAULT_FINAL_OPTIMIZATION_ITERATIONS,
    final_optimization_epsilon: float = DEFAULT_FINAL_OPTIMIZATION_EPSILON,
    progress_callback: Optional[ReprocessProgressCallback] = None,
    profile_name: str = DISCOVERY_PROFILE,
    link_injections: Iterable[Dict[str, Any]] = (),
    cancel_event: Optional[threading.Event] = None,
    persistent_log_path: Optional[Path] = None,
) -> Dict[str, Any]:
    if online_optimization_iterations < 1:
        raise OfflineProcessingError("Online optimization iterations must be at least 1.")
    if final_optimization_iterations < 1:
        raise OfflineProcessingError("Final optimization iterations must be at least 1.")
    if final_optimization_epsilon < 0.0:
        raise OfflineProcessingError("Final optimization epsilon cannot be negative.")
    accelerator_parameters = tuple(extra_parameters)
    requested_link_injections = tuple(link_injections)
    runtime_parameters = accelerator_parameters + (
        ("Optimizer/Iterations", str(int(online_optimization_iterations))),
    )
    binary = find_reprocess_binary(explicit_binary, prefer_cuda=accelerator_backend == "nvidia_cuda")
    if binary is None:
        raise OfflineProcessingError(
            "rtabmap-reprocess was not found. Build the repository with BUILD_TOOLS=ON, "
            f"add it to PATH, or set {REPROCESS_ENV}/the Map Studio binary path."
        )
    input_database = input_database.resolve()
    output_database = output_database.resolve()
    if input_database == output_database:
        raise OfflineProcessingError(
            "The optimized database must use a different path; the phone capture is immutable input."
        )
    source = validate_capture_database(input_database)
    threads = max(1, min(64, int(thread_count)))

    output_parent = output_database.parent
    output_parent_existed = output_parent.is_dir()
    free_bytes = shutil.disk_usage(_existing_directory(output_parent)).free
    recommended_bytes = max(2 * 1024**3, source["size_bytes"] * 2)
    if free_bytes < recommended_bytes:
        raise OfflineProcessingError(
            f"Not enough PC disk space for safe reprocessing: {free_bytes / 1024**3:.1f} GB free, "
            f"{recommended_bytes / 1024**3:.1f} GB recommended."
        )

    publish_partial = output_database.with_name(
        output_database.stem + ".partial" + output_database.suffix
    )
    started_at = time.time()
    needs_input_copy = use_local_staging or bool(requested_link_injections)
    staging_root = (
        _staging_directory()
        if use_local_staging
        else _existing_directory(output_database.parent)
    )
    if needs_input_copy:
        staging_free_bytes = shutil.disk_usage(staging_root).free
        staging_recommended_bytes = max(2 * 1024**3, source["size_bytes"] * 3)
        if staging_free_bytes < staging_recommended_bytes:
            raise OfflineProcessingError(
                f"Not enough local PC staging space: {staging_free_bytes / 1024**3:.1f} GB free, "
                f"{staging_recommended_bytes / 1024**3:.1f} GB recommended in {staging_root}. "
                f"Set {REPROCESS_TEMP_ENV} to another fast local directory if needed."
            )

    output_parent.mkdir(parents=True, exist_ok=True)
    publish_partial.unlink(missing_ok=True)

    temporary: Optional[tempfile.TemporaryDirectory[str]] = None
    log_path: Optional[Path] = None
    copy_in_seconds = 0.0
    copy_out_seconds = 0.0
    injected_links = {
        "requested_count": 0,
        "injected_count": 0,
        "pairs": [],
    }
    try:
        try:
            if needs_input_copy:
                temporary = tempfile.TemporaryDirectory(
                    prefix="supermarket-rtabmap-",
                    dir=staging_root,
                )
                work_directory = Path(temporary.name)
                work_input = work_directory / "capture.db"
                work_output = (
                    work_directory / "optimized.partial.db"
                    if use_local_staging
                    else publish_partial
                )
                copy_started = time.time()
                _copy_and_sync(input_database, work_input)
                copy_in_seconds = time.time() - copy_started
            else:
                work_directory = output_database.parent
                work_input = input_database
                work_output = publish_partial

            injected_links = _inject_user_links(work_input, requested_link_injections)
            command = _command(
                binary,
                work_input,
                work_output,
                runtime_parameters,
                final_optimization_iterations,
                final_optimization_epsilon,
            )
            log_path = work_directory / "rtabmap-reprocess.log"
            monitor_done = threading.Event()
            monitor_thread: Optional[threading.Thread] = None
            if progress_callback is not None:
                progress_callback(0.01, "准备优化", "输入数据库校验完成，正在启动节点回放")
                monitor_thread = threading.Thread(
                    target=_monitor_reprocess_log,
                    args=(log_path, monitor_done, progress_callback),
                    name="rtabmap-reprocess-progress",
                    daemon=True,
                )
                monitor_thread.start()
            with log_path.open("w", encoding="utf-8", errors="replace") as log_handle:
                try:
                    if cancel_event is None:
                        completed = subprocess.run(
                            command,
                            stdout=log_handle,
                            stderr=subprocess.STDOUT,
                            text=True,
                            timeout=timeout_seconds,
                            check=False,
                            cwd=str(work_directory),
                            env=_thread_environment(threads),
                        )
                    else:
                        process = subprocess.Popen(
                            command,
                            stdout=log_handle,
                            stderr=subprocess.STDOUT,
                            text=True,
                            cwd=str(work_directory),
                            env=_thread_environment(threads),
                        )
                        deadline = time.monotonic() + timeout_seconds
                        while process.poll() is None:
                            if cancel_event.is_set():
                                process.terminate()
                                try:
                                    process.wait(timeout=5)
                                except subprocess.TimeoutExpired:
                                    process.kill()
                                    process.wait(timeout=5)
                                raise OfflineProcessingError(
                                    "rtabmap-reprocess was cancelled by the operator."
                                )
                            if time.monotonic() >= deadline:
                                process.kill()
                                process.wait(timeout=5)
                                raise subprocess.TimeoutExpired(command, timeout_seconds)
                            time.sleep(0.25)
                        completed = subprocess.CompletedProcess(command, process.returncode)
                finally:
                    monitor_done.set()
                    if monitor_thread is not None:
                        monitor_thread.join(timeout=2)
        except subprocess.TimeoutExpired as exc:
            raise OfflineProcessingError(
                f"rtabmap-reprocess exceeded the {timeout_seconds}-second safety timeout."
            ) from exc
        except OSError as exc:
            raise OfflineProcessingError(
                f"PC staging or rtabmap-reprocess I/O failed: {exc}"
            ) from exc

        if completed.returncode != 0:
            returned_log = (getattr(completed, "stdout", None) or "") + "\n" + (
                getattr(completed, "stderr", None) or ""
            )
            detail = _tail((returned_log.strip() or _tail_file(log_path, 4000)), 4000)
            raise OfflineProcessingError(
                f"rtabmap-reprocess failed with exit code {completed.returncode}: {detail}"
            )

        unavailable_features = (
            "g2o optimizer not available",
            "vertigo robust optimization is not available",
        )
        returned_log = (getattr(completed, "stdout", None) or "") + "\n" + (
            getattr(completed, "stderr", None) or ""
        )
        if any(message in returned_log.lower() for message in unavailable_features) or _log_contains(
            log_path, unavailable_features
        ):
            raise OfflineProcessingError(
                "rtabmap-reprocess completed only after disabling or replacing the requested g2o/Vertigo optimizer. "
                "Rebuild the PC tool with WITH_G2O=ON and WITH_VERTIGO=ON."
            )

        gpu_fallback_messages = (
            "gpu version of gftt not available",
            "gpu version of gftt is not implemented",
            "nearest neighobr strategy \"knnbruteforcegpu\" chosen but",
            "no cuda device(s) detected",
            "no gpu found",
        )
        rtabmap_gpu_fallback = accelerator_backend == "nvidia_cuda" and (
            any(message in returned_log.lower() for message in gpu_fallback_messages)
            or _log_contains(log_path, gpu_fallback_messages)
        )

        full_log = log_path.read_text(encoding="utf-8", errors="replace") if log_path.is_file() else ""
        runtime = parse_reprocess_runtime(returned_log + "\n" + full_log)
        if not runtime["final_optimization"]["completed"]:
            raise OfflineProcessingError(
                "rtabmap-reprocess did not report completion of the required final global optimization. "
                "Rebuild the project-local reprocess tool before using the staged optimization profile."
            )

        optimized = inspect_database(work_output)
        if optimized["integrity"] != "ok" or optimized["node_count"] <= 0:
            raise OfflineProcessingError(
                f"Reprocessed database validation failed: integrity={optimized['integrity']}, "
                f"nodes={optimized['node_count']}"
            )
        if optimized["optimized_pose_count"] <= 0:
            raise OfflineProcessingError(
                "Reprocessing completed but no Admin.opt_poses graph was saved; refusing to use raw odometry poses as optimized output."
            )
        error_optimization = assess_optimized_trajectory(input_database, work_output)
        if error_optimization["status"] == "rejected":
            reasons = " ".join(error_optimization["rejection_reasons"])
            raise OfflineProcessingError(
                "Optimized trajectory failed software error validation and was not published: " + reasons
            )

        if use_local_staging:
            copy_started = time.time()
            _copy_and_sync(work_output, publish_partial)
            copy_out_seconds = time.time() - copy_started
        os.replace(publish_partial, output_database)
        optimized["path"] = str(output_database)
        logical_command = _command(
            binary,
            input_database,
            output_database,
            runtime_parameters,
            final_optimization_iterations,
            final_optimization_epsilon,
        )
        return {
            "format": "SupermarketOfflineProcessingReport",
            "version": 1,
            "status": "complete",
            "strategy": "software_only_vio_rgbd_loop_closure_and_robust_global_optimization",
            "fiducials_used": False,
            "landmark_constraints_used": False,
            "pose_priors_used": False,
            "user_constraints_used": injected_links["injected_count"] > 0,
            "user_constraint_count": injected_links["injected_count"],
            "started_at": started_at,
            "elapsed_seconds": round(time.time() - started_at, 3),
            "binary": str(binary),
            "command": logical_command,
            "execution": {
                "profile": profile_name,
                "thread_count": threads,
                "openmp_wait_policy": "PASSIVE",
                "opencv_thread_limit": threads,
                "local_staging": use_local_staging,
                "disposable_input_copy": needs_input_copy,
                "staging_root": str(staging_root) if use_local_staging else None,
                "copy_in_seconds": round(copy_in_seconds, 3),
                "copy_out_seconds": round(copy_out_seconds, 3),
                "accelerator_backend": accelerator_backend,
                "rtabmap_gpu_parameters": dict(accelerator_parameters),
                "rtabmap_gpu_fallback_detected": rtabmap_gpu_fallback,
                "online_optimization_iterations": online_optimization_iterations,
                "final_optimization_iterations": final_optimization_iterations,
                "final_optimization_epsilon": final_optimization_epsilon,
                "g2o_solver": "eigen_sparse",
                "injected_user_links": injected_links,
            },
            "runtime": runtime,
            "input": source,
            "output": optimized,
            "error_optimization": error_optimization,
            "stdout_tail": _tail(returned_log) if returned_log.strip() else _tail_file(log_path),
            "stderr_tail": "",
        }
    finally:
        publish_partial.unlink(missing_ok=True)
        if persistent_log_path is not None and log_path is not None and log_path.is_file():
            try:
                persistent_log_path.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(log_path, persistent_log_path)
                with persistent_log_path.open("rb") as persistent_log:
                    os.fsync(persistent_log.fileno())
            except OSError:
                pass
        if log_path is not None:
            log_path.unlink(missing_ok=True)
        if temporary is not None:
            temporary.cleanup()
        if not output_parent_existed:
            try:
                output_parent.rmdir()
            except OSError:
                pass


def _adaptive_pass_summary(report: Dict[str, Any]) -> Dict[str, Any]:
    assessment = report.get("error_optimization", {})
    output = report.get("output", {})
    return {
        "profile": report.get("execution", {}).get("profile"),
        "elapsed_seconds": report.get("elapsed_seconds", 0.0),
        "processed_node_count": report.get("runtime", {}).get("processed_node_count", 0),
        "node_time_ms": report.get("runtime", {}).get("node_time_ms", {}),
        "final_optimization": report.get("runtime", {}).get("final_optimization", {}),
        "quality_status": assessment.get("status", "unknown"),
        "quality_score": assessment.get("quality_score", 0),
        "loop_closure_pair_count": output.get("loop_closure_pair_count", 0),
        "long_range_loop_pair_count": output.get("long_range_loop_pair_count", 0),
    }


def run_adaptive_reprocess(
    input_database: Path,
    output_database: Path,
    explicit_binary: Optional[str] = None,
    timeout_seconds: int = 24 * 60 * 60,
    thread_count: int = DEFAULT_PC_THREADS,
    use_local_staging: bool = True,
    accelerator_backend: str = "cpu",
    extra_parameters: Iterable[tuple[str, str]] = (),
    progress_callback: Optional[ReprocessProgressCallback] = None,
    cancel_event: Optional[threading.Event] = None,
    persistent_log_prefix: Optional[Path] = None,
) -> Dict[str, Any]:
    """Reuse accepted phone constraints first, then discover loops only if needed.

    This keeps well-constrained long captures close to linear replay cost while
    preserving the more expensive ORB discovery pass for weak graphs.
    """
    started = time.time()
    base_parameters = tuple(extra_parameters)

    def fast_progress(fraction: float, stage: str, message: str) -> None:
        if progress_callback is not None:
            progress_callback(
                min(0.25, max(0.0, fraction) * 0.25),
                "快速约束复用" if stage != "最终全局优化" else stage,
                message,
            )

    fast_report: Optional[Dict[str, Any]] = None
    fast_error: Optional[str] = None
    try:
        fast_report = run_reprocess(
            input_database,
            output_database,
            explicit_binary=explicit_binary,
            timeout_seconds=timeout_seconds,
            thread_count=thread_count,
            use_local_staging=use_local_staging,
            accelerator_backend=accelerator_backend,
            extra_parameters=base_parameters + FAST_REUSE_PARAMETERS,
            progress_callback=fast_progress,
            profile_name=FAST_REUSE_PROFILE,
            cancel_event=cancel_event,
            persistent_log_path=(
                persistent_log_prefix.with_name(persistent_log_prefix.name + "-fast.log")
                if persistent_log_prefix is not None
                else None
            ),
        )
    except OfflineProcessingError as exc:
        if cancel_event is not None and cancel_event.is_set():
            raise
        fast_error = str(exc)

    if fast_report is not None:
        node_count = int(fast_report.get("output", {}).get("node_count", 0))
        long_range_pairs = int(
            fast_report.get("output", {}).get("long_range_loop_pair_count", 0)
        )
        long_range_retention = float(
            fast_report.get("error_optimization", {})
            .get("constraints", {})
            .get("input_long_range_loop_retention", 1.0)
        )
    else:
        node_count = int(inspect_database(input_database)["node_count"])
        long_range_pairs = 0
        long_range_retention = 0.0
    required_long_range_pairs = max(2, node_count // 500) if node_count >= 200 else 0
    discovery_reasons: list[str] = []
    if fast_error is not None:
        discovery_reasons.append("constraint-reuse pass failed validation")
    if long_range_pairs < required_long_range_pairs:
        discovery_reasons.append(
            f"long-range loop pairs {long_range_pairs} < required {required_long_range_pairs}"
        )
    if long_range_retention < 0.80:
        discovery_reasons.append(
            f"accepted long-range loop retention {long_range_retention * 100:.1f}% < 80%"
        )

    passes = (
        [_adaptive_pass_summary(fast_report)]
        if fast_report is not None
        else [
            {
                "profile": FAST_REUSE_PROFILE,
                "quality_status": "failed",
                "error": fast_error,
            }
        ]
    )
    selected_report = fast_report
    selected_pass = FAST_REUSE_PROFILE
    if discovery_reasons:
        if progress_callback is not None:
            progress_callback(
                0.25,
                "补充闭环发现",
                "快速图的长程约束不足，开始 ORB 关键视觉闭环发现",
            )

        def discovery_progress(fraction: float, stage: str, message: str) -> None:
            if progress_callback is not None:
                progress_callback(
                    0.25 + min(0.75, max(0.0, fraction) * 0.75),
                    stage,
                    message,
                )

        try:
            discovered_report = run_reprocess(
                input_database,
                output_database,
                explicit_binary=explicit_binary,
                timeout_seconds=timeout_seconds,
                thread_count=thread_count,
                use_local_staging=use_local_staging,
                accelerator_backend=accelerator_backend,
                extra_parameters=base_parameters,
                progress_callback=discovery_progress,
                profile_name=DISCOVERY_PROFILE,
                cancel_event=cancel_event,
                persistent_log_path=(
                    persistent_log_prefix.with_name(persistent_log_prefix.name + "-discovery.log")
                    if persistent_log_prefix is not None
                    else None
                ),
            )
        except OfflineProcessingError as exc:
            if cancel_event is not None and cancel_event.is_set():
                raise
            passes.append(
                {
                    "profile": DISCOVERY_PROFILE,
                    "quality_status": "failed",
                    "error": str(exc),
                }
            )
            if fast_report is None:
                raise
            # The discovery pass is exploratory. A failed or unsafe discovery
            # graph must not erase an already validated fast graph.
            selected_report = fast_report
            selected_pass = FAST_REUSE_PROFILE
        else:
            selected_report = discovered_report
            passes.append(_adaptive_pass_summary(selected_report))
            selected_pass = DISCOVERY_PROFILE

    if selected_report is None:
        raise OfflineProcessingError("Adaptive processing did not produce a publishable result.")

    selected_report["elapsed_seconds"] = round(time.time() - started, 3)
    selected_report["execution"]["profile"] = ADAPTIVE_PROFILE
    selected_report["execution"]["selected_pass_profile"] = selected_pass
    selected_report["adaptive"] = {
        "profile": ADAPTIVE_PROFILE,
        "selected_pass": selected_pass,
        "discovery_required": bool(discovery_reasons),
        "discovery_reasons": discovery_reasons,
        "required_long_range_loop_pairs": required_long_range_pairs,
        "passes": passes,
    }
    if progress_callback is not None:
        progress_callback(1.0, "自适应优化完成", f"已选择 {selected_pass} 结果")
    return selected_report


def write_report(path: Path, reports: Iterable[Dict[str, Any]]) -> None:
    entries = list(reports)
    payload = {
        "format": "SupermarketOfflineProcessingBundle",
        "version": 1,
        "generated_at": time.strftime("%Y-%m-%d %H:%M:%S"),
        "databases": entries,
    }
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
