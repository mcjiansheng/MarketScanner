"""Diagnostic sequence alignment for finalized structure-coverage evidence.

This module deliberately does **not** create publishable factor-graph priors.
``structure_coverage_cells.json`` is not yet part of the PC localized-session
input manifest, so consuming it as an authoritative absolute constraint would
break the parse-and-hash-once safety contract.  The implementation instead
provides a deterministic, bounded audit that answers the engineering question:
does a whole scan, with its known start/heading and time-ordered shelf shape,
select one continuous prior-map hypothesis better than repeated aisle aliases?

The same scoring semantics are suitable for a future resource-bounded mobile
implementation.  PC uses all three distance-field levels; a mobile caller can
select only the 0.40 m level and a smaller candidate/window budget.
"""

from __future__ import annotations

from dataclasses import dataclass
import bisect
import hashlib
import json
import math
from pathlib import Path
import heapq
import sqlite3
import statistics
import struct
from typing import Any, Iterable, Sequence
import zlib

from tools.PriorMap.distance_field import decode_level
from tools.PriorMap.strict_json import StrictJSONError, load_strict_json_bytes


REPORT_FORMAT = "MarketScannerStructureWindowAlignmentDiagnostic"
REPORT_VERSION = 1
MAXIMUM_COVERAGE_FILE_BYTES = 64 * 1024 * 1024
MAXIMUM_COVERAGE_CELLS = 200_000
MAXIMUM_TRACE_FILE_BYTES = 512 * 1024 * 1024
MAXIMUM_TRACE_RECORD_BYTES = 1024 * 1024
MAXIMUM_TRACE_RECORDS = 500_000
MAXIMUM_OPTIMIZED_NODES = 200_000
MAXIMUM_ROAD_GRAPH_FILE_BYTES = 32 * 1024 * 1024
MAXIMUM_ROAD_NODES = 100_000
MAXIMUM_ROAD_EDGES = 200_000

_COVERAGE_DOCUMENT_FIELDS = frozenset(
    {"format", "version", "updatedAt", "cellSizeM", "floorHeightM", "summary", "cells"}
)
_COVERAGE_SUMMARY_FIELDS = frozenset(
    {
        "evaluatedDepthFrameCount",
        "depthUnavailableFrameCount",
        "validDepthSampleCount",
        "observedCellCount",
        "floorCellCount",
        "elevatedCellCount",
        "stableStructureCellCount",
        "multiViewStructureCellCount",
        "groundConflictCellCount",
        "singleViewStructureCellCount",
        "coverageScore",
        "currentDetectionRateHz",
    }
)
_COVERAGE_CELL_REQUIRED_FIELDS = frozenset(
    {
        "x",
        "z",
        "floorObservationCount",
        "elevatedObservationCount",
        "highObservationCount",
        "distinctTimeBucketCount",
        "viewDirectionMask",
        "highConfidenceObservationCount",
        "lastObservedAt",
    }
)
_COVERAGE_CELL_OPTIONAL_FIELDS = frozenset(
    {"firstElevatedObservedAt", "lastElevatedObservedAt"}
)


class StructureWindowAlignmentError(ValueError):
    pass


@dataclass(frozen=True)
class Pose2D:
    x: float
    y: float
    yaw: float


@dataclass(frozen=True)
class TracePose:
    timestamp: float
    pose: Pose2D
    node_timebase_timestamp: float | None = None


@dataclass(frozen=True)
class OptimizedNodePose:
    node_id: int
    node_timebase_timestamp: float
    pose: Pose2D


@dataclass(frozen=True)
class StructureCoverageCell:
    x_index: int
    z_index: int
    first_timestamp: float
    last_timestamp: float
    elevated_observation_count: int
    distinct_time_bucket_count: int
    view_direction_mask: int
    high_confidence_observation_count: int
    floor_observation_count: int

    @property
    def representative_timestamp(self) -> float:
        # The sidecar stores only first/last observation bounds, not every
        # contributing frame. The last timestamp is guaranteed to represent
        # a real observation; the midpoint can fall inside a multi-second
        # trace gap and manufacture a pose binding that never existed.
        return self.last_timestamp


@dataclass(frozen=True)
class WindowPoint:
    local_x: float
    local_y: float
    timestamp: float
    observation_count: int
    multi_view: bool


@dataclass(frozen=True)
class StructureWindow:
    index: int
    start_timestamp: float
    end_timestamp: float
    representative_timestamp: float
    representative_trace_index: int
    points: tuple[WindowPoint, ...]


@dataclass(frozen=True)
class AlignmentCandidate:
    correction: Pose2D
    geometry_cost: float
    outside_ratio: float
    road_distance_m: float = 0.0
    road_yaws_rad: tuple[float, ...] = ()
    map_x: float | None = None
    map_y: float | None = None
    road_edge_index: int = -1
    road_edge_fraction: float = 0.0


@dataclass(frozen=True)
class RoadSegment:
    edge_id: str
    start_node_id: str
    end_node_id: str
    start_x: float
    start_y: float
    end_x: float
    end_y: float
    yaw: float
    length_m: float


@dataclass(frozen=True)
class RoadCandidateEvidence:
    distance_m: float
    yaws_rad: tuple[float, ...]
    edge_index: int
    edge_fraction: float


class RoadGraph:
    """Strict, bounded floor-level road centerline lookup.

    The graph is a soft sequence prior only. Missing or distant roads never
    delete a structure candidate; they merely add a bounded diagnostic cost.
    """

    def __init__(
        self,
        segments: Sequence[RoadSegment],
        adjacency: dict[str, tuple[tuple[str, float], ...]],
    ) -> None:
        if not segments:
            raise StructureWindowAlignmentError(
                "Road graph floor has no usable centerline edge."
            )
        self.segments = tuple(segments)
        self.adjacency = adjacency
        self._shortest_path_cache: dict[
            tuple[str, str], float | None
        ] = {}

    def evidence(self, pose: Pose2D) -> RoadCandidateEvidence:
        distances: list[tuple[float, int, float, RoadSegment]] = []
        for edge_index, segment in enumerate(self.segments):
            dx = segment.end_x - segment.start_x
            dy = segment.end_y - segment.start_y
            length_squared = dx * dx + dy * dy
            if length_squared <= 1.0e-12:
                continue
            fraction = max(
                0.0,
                min(
                    1.0,
                    ((pose.x - segment.start_x) * dx
                     + (pose.y - segment.start_y) * dy)
                    / length_squared,
                ),
            )
            nearest_x = segment.start_x + fraction * dx
            nearest_y = segment.start_y + fraction * dy
            distance = math.hypot(pose.x - nearest_x, pose.y - nearest_y)
            distances.append((distance, edge_index, fraction, segment))
        if not distances:
            raise StructureWindowAlignmentError(
                "Road graph floor has no non-degenerate centerline edge."
            )
        distances.sort(
            key=lambda value: (
                value[0], value[3].start_x, value[3].start_y,
                value[3].end_x, value[3].end_y,
            )
        )
        best_distance = distances[0][0]
        best_edge_index = distances[0][1]
        best_fraction = distances[0][2]
        yaws: list[float] = []
        for distance, _edge_index, _fraction, segment in distances:
            if distance > best_distance + 0.30 or len(yaws) >= 8:
                break
            canonical_yaw = _normalize_angle(segment.yaw)
            if all(
                min(
                    abs(_normalize_angle(canonical_yaw - prior)),
                    abs(_normalize_angle(canonical_yaw - prior - math.pi)),
                ) > math.radians(3.0)
                for prior in yaws
            ):
                yaws.append(canonical_yaw)
        return RoadCandidateEvidence(
            best_distance, tuple(yaws), best_edge_index, best_fraction
        )

    def _node_distance(self, start: str, end: str) -> float | None:
        key = (start, end) if start <= end else (end, start)
        if key in self._shortest_path_cache:
            return self._shortest_path_cache[key]
        if start == end:
            self._shortest_path_cache[key] = 0.0
            return 0.0
        queue: list[tuple[float, str]] = [(0.0, start)]
        best = {start: 0.0}
        result: float | None = None
        while queue:
            distance, node = heapq.heappop(queue)
            if distance > best.get(node, math.inf) + 1.0e-12:
                continue
            if node == end:
                result = distance
                break
            for neighbor, edge_length in self.adjacency.get(node, ()):
                candidate = distance + edge_length
                if candidate + 1.0e-12 < best.get(neighbor, math.inf):
                    best[neighbor] = candidate
                    heapq.heappush(queue, (candidate, neighbor))
        self._shortest_path_cache[key] = result
        return result

    def route_distance(
        self,
        first_edge_index: int,
        first_fraction: float,
        second_edge_index: int,
        second_fraction: float,
    ) -> float | None:
        if not (
            0 <= first_edge_index < len(self.segments)
            and 0 <= second_edge_index < len(self.segments)
            and 0.0 <= first_fraction <= 1.0
            and 0.0 <= second_fraction <= 1.0
        ):
            return None
        first = self.segments[first_edge_index]
        second = self.segments[second_edge_index]
        candidates: list[float] = []
        if first_edge_index == second_edge_index:
            candidates.append(
                abs(first_fraction - second_fraction) * first.length_m
            )
        first_endpoints = (
            (first.start_node_id, first_fraction * first.length_m),
            (first.end_node_id, (1.0 - first_fraction) * first.length_m),
        )
        second_endpoints = (
            (second.start_node_id, second_fraction * second.length_m),
            (second.end_node_id, (1.0 - second_fraction) * second.length_m),
        )
        for first_node, first_offset in first_endpoints:
            for second_node, second_offset in second_endpoints:
                middle = self._node_distance(first_node, second_node)
                if middle is not None:
                    candidates.append(first_offset + middle + second_offset)
        return min(candidates) if candidates else None


class DistanceLevel:
    def __init__(self, payload: dict[str, Any], truncation_m: float) -> None:
        resolution = payload.get("resolution_m")
        origin = payload.get("origin_m")
        width = payload.get("width")
        height = payload.get("height")
        if (
            isinstance(resolution, bool)
            or not isinstance(resolution, (int, float))
            or not math.isfinite(float(resolution))
            or float(resolution) <= 0
            or not isinstance(origin, list)
            or len(origin) != 2
            or any(
                isinstance(value, bool)
                or not isinstance(value, (int, float))
                or not math.isfinite(float(value))
                for value in origin
            )
            or type(width) is not int
            or type(height) is not int
            or width <= 0
            or height <= 0
        ):
            raise StructureWindowAlignmentError("Distance-field level is invalid.")
        self.resolution = float(resolution)
        self.origin_x = float(origin[0])
        self.origin_y = float(origin[1])
        self.width = width
        self.height = height
        self.values = decode_level(payload)
        self.truncation_m = truncation_m

    def distance(self, x: float, y: float) -> tuple[float, bool]:
        column = math.floor((x - self.origin_x) / self.resolution)
        row = math.floor((y - self.origin_y) / self.resolution)
        if column < 0 or row < 0 or column >= self.width or row >= self.height:
            return self.truncation_m, True
        return (
            min(
                self.truncation_m,
                self.values[row * self.width + column] / 100.0,
            ),
            False,
        )


def _strict_int(value: Any, field: str, *, minimum: int = 0) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < minimum:
        raise StructureWindowAlignmentError(f"{field} is invalid.")
    return value


def _finite_number(value: Any, field: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise StructureWindowAlignmentError(f"{field} is invalid.")
    result = float(value)
    if not math.isfinite(result):
        raise StructureWindowAlignmentError(f"{field} is non-finite.")
    return result


def _normalize_angle(value: float) -> float:
    return math.atan2(math.sin(value), math.cos(value))


def correction_continuity_metrics(
    translation_deltas_m: Sequence[float],
    yaw_deltas_deg: Sequence[float],
    physical_travel_m: Sequence[float],
) -> tuple[bool, list[float], list[float]]:
    """Judge map-gauge correction continuity per metre of physical travel.

    Absolute correction differences are intentionally not a validity gate.
    A slowly accumulated five-metre correction over a long aisle is continuous,
    while the same correction over one short step remains a discontinuity.
    """

    if not (
        len(translation_deltas_m)
        == len(yaw_deltas_deg)
        == len(physical_travel_m)
    ):
        raise StructureWindowAlignmentError(
            "Correction continuity inputs have inconsistent lengths."
        )
    values = [
        *translation_deltas_m,
        *yaw_deltas_deg,
        *physical_travel_m,
    ]
    if any(not math.isfinite(value) or value < 0 for value in values):
        raise StructureWindowAlignmentError(
            "Correction continuity inputs must be finite and non-negative."
        )
    translation_gradient = [
        delta / max(0.75, travel)
        for delta, travel in zip(translation_deltas_m, physical_travel_m)
    ]
    yaw_gradient_deg_per_m = [
        delta / max(0.75, travel)
        for delta, travel in zip(yaw_deltas_deg, physical_travel_m)
    ]
    supported = (
        not translation_deltas_m
        or (
            max(translation_gradient, default=0.0) <= 1.0
            and max(yaw_gradient_deg_per_m, default=0.0) <= 8.0
        )
    )
    return supported, translation_gradient, yaw_gradient_deg_per_m


def _rotate(x: float, y: float, yaw: float) -> tuple[float, float]:
    cosine, sine = math.cos(yaw), math.sin(yaw)
    return cosine * x - sine * y, sine * x + cosine * y


def _compose(first: Pose2D, second: Pose2D) -> Pose2D:
    x, y = _rotate(second.x, second.y, first.yaw)
    return Pose2D(first.x + x, first.y + y, _normalize_angle(first.yaw + second.yaw))


def _inverse(value: Pose2D) -> Pose2D:
    x, y = _rotate(-value.x, -value.y, -value.yaw)
    return Pose2D(x, y, _normalize_angle(-value.yaw))


def _relative(first: Pose2D, second: Pose2D) -> Pose2D:
    return _compose(_inverse(first), second)


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def load_structure_coverage(
    path: Path,
) -> tuple[float, list[StructureCoverageCell], dict[str, Any]]:
    try:
        size = path.stat().st_size
        if size <= 0 or size > MAXIMUM_COVERAGE_FILE_BYTES:
            raise StructureWindowAlignmentError(
                "Structure coverage exceeds the diagnostic resource budget."
            )
        payload = load_strict_json_bytes(path.read_bytes(), name=path.name)
    except (OSError, StrictJSONError) as exc:
        raise StructureWindowAlignmentError(
            f"Structure coverage cannot be read: {exc}"
        ) from exc
    if (
        not isinstance(payload, dict)
        or set(payload) != _COVERAGE_DOCUMENT_FIELDS
        or payload.get("format") != "SupermarketStructureCoverage"
        or payload.get("version") != 1
        or not isinstance(payload.get("updatedAt"), str)
        or not payload["updatedAt"]
        or not isinstance(payload.get("summary"), dict)
        or set(payload["summary"]) != _COVERAGE_SUMMARY_FIELDS
        or not isinstance(payload.get("cells"), list)
        or len(payload["cells"]) > MAXIMUM_COVERAGE_CELLS
    ):
        raise StructureWindowAlignmentError("Structure coverage schema is invalid.")
    floor_height = payload.get("floorHeightM")
    if floor_height is not None:
        _finite_number(floor_height, "floorHeightM")
    cell_size_m = _finite_number(payload.get("cellSizeM"), "cellSizeM")
    if not 0.05 <= cell_size_m <= 1.0:
        raise StructureWindowAlignmentError("Structure coverage cell size is invalid.")
    cells: list[StructureCoverageCell] = []
    seen: set[tuple[int, int]] = set()
    floor_cell_count = 0
    elevated_cell_count = 0
    multi_view_structure_cell_count = 0
    ground_conflict_cell_count = 0
    for record in payload["cells"]:
        if (
            not isinstance(record, dict)
            or not _COVERAGE_CELL_REQUIRED_FIELDS.issubset(record)
            or not set(record).issubset(
                _COVERAGE_CELL_REQUIRED_FIELDS | _COVERAGE_CELL_OPTIONAL_FIELDS
            )
        ):
            raise StructureWindowAlignmentError("Structure coverage cell is invalid.")
        x_index = _strict_int(record.get("x"), "coverage x", minimum=-2_000_000)
        z_index = _strict_int(record.get("z"), "coverage z", minimum=-2_000_000)
        if not -2_000_000 <= x_index <= 2_000_000 or not -2_000_000 <= z_index <= 2_000_000:
            raise StructureWindowAlignmentError("Structure coverage index is out of range.")
        if (x_index, z_index) in seen:
            raise StructureWindowAlignmentError("Structure coverage cells are duplicated.")
        seen.add((x_index, z_index))
        floor_count = _strict_int(
            record.get("floorObservationCount"), "floor observation count"
        )
        elevated_count = _strict_int(
            record.get("elevatedObservationCount"),
            "elevated observation count",
        )
        high_count = _strict_int(
            record.get("highObservationCount"), "high observation count"
        )
        time_bucket_count = _strict_int(
            record.get("distinctTimeBucketCount"),
            "distinct time bucket count",
        )
        view_direction_mask = _strict_int(
            record.get("viewDirectionMask"), "view direction mask"
        )
        high_confidence_count = _strict_int(
            record.get("highConfidenceObservationCount"),
            "high confidence observation count",
        )
        last_observed_at = _finite_number(
            record.get("lastObservedAt"), "last observed timestamp"
        )
        if (
            last_observed_at < 0
            or high_count > elevated_count
            or high_confidence_count > elevated_count
            or time_bucket_count > elevated_count
            or view_direction_mask > 0xFF
        ):
            raise StructureWindowAlignmentError(
                "Structure coverage observation counts are inconsistent."
            )
        floor_cell_count += int(floor_count >= 2)
        elevated_cell_count += int(elevated_count > 0)
        first_value = record.get("firstElevatedObservedAt")
        last_value = record.get("lastElevatedObservedAt")
        if elevated_count == 0:
            if first_value is not None or last_value is not None:
                raise StructureWindowAlignmentError(
                    "Empty elevated coverage unexpectedly has timestamps."
                )
            # Floor-only cells are fully validated but are not structure
            # evidence and therefore never enter a matching window.
            continue
        first = _finite_number(first_value, "first elevated timestamp")
        last = _finite_number(last_value, "last elevated timestamp")
        if first < 0 or last < first or last > last_observed_at + 1.0e-9:
            raise StructureWindowAlignmentError("Structure coverage time span is invalid.")
        cell = StructureCoverageCell(
            x_index=x_index,
            z_index=z_index,
            first_timestamp=first,
            last_timestamp=last,
            elevated_observation_count=elevated_count,
            distinct_time_bucket_count=time_bucket_count,
            view_direction_mask=view_direction_mask,
            high_confidence_observation_count=high_confidence_count,
            floor_observation_count=floor_count,
        )
        observation_span = cell.last_timestamp - cell.first_timestamp
        if (
            cell.elevated_observation_count >= 2
            and cell.distinct_time_bucket_count >= 2
            and observation_span >= 0.75
        ):
            cells.append(cell)
            multi_view_structure_cell_count += int(
                cell.view_direction_mask.bit_count() >= 2
            )
            conflict_ratio = cell.floor_observation_count / max(
                1,
                cell.floor_observation_count
                + cell.elevated_observation_count,
            )
            ground_conflict_cell_count += int(
                cell.floor_observation_count >= 2 and conflict_ratio > 0.66
            )
    summary = payload["summary"]
    integer_summary_fields = _COVERAGE_SUMMARY_FIELDS - {
        "coverageScore",
        "currentDetectionRateHz",
    }
    if any(
        type(summary.get(field)) is not int or summary[field] < 0
        for field in integer_summary_fields
    ):
        raise StructureWindowAlignmentError(
            "Structure coverage summary counts are invalid."
        )
    coverage_score = _finite_number(summary.get("coverageScore"), "coverage score")
    detection_rate = _finite_number(
        summary.get("currentDetectionRateHz"), "current detection rate"
    )
    expected_coverage_score = max(
        0.0,
        min(
            1.0,
            multi_view_structure_cell_count / max(1, len(cells))
            * (1.0 - ground_conflict_cell_count / max(1, len(cells))),
        ),
    )
    expected_counts = {
        "observedCellCount": len(payload["cells"]),
        "floorCellCount": floor_cell_count,
        "elevatedCellCount": elevated_cell_count,
        "stableStructureCellCount": len(cells),
        "multiViewStructureCellCount": multi_view_structure_cell_count,
        "groundConflictCellCount": ground_conflict_cell_count,
        "singleViewStructureCellCount": len(cells)
        - multi_view_structure_cell_count,
    }
    if (
        detection_rate <= 0
        or not 0.0 <= coverage_score <= 1.0
        or any(summary[field] != value for field, value in expected_counts.items())
        or abs(coverage_score - expected_coverage_score) > 1.0e-9
    ):
        raise StructureWindowAlignmentError(
            "Structure coverage summary differs from the finalized cell evidence."
        )
    return cell_size_m, cells, summary


def load_localization_trace(path: Path) -> list[TracePose]:
    records: list[TracePose] = []
    try:
        file_size = path.stat().st_size
        if file_size <= 0 or file_size > MAXIMUM_TRACE_FILE_BYTES:
            raise StructureWindowAlignmentError(
                "Localization trace exceeds the diagnostic file budget."
            )
        with path.open("rb") as handle:
            for index, raw in enumerate(handle, start=1):
                if index > MAXIMUM_TRACE_RECORDS:
                    raise StructureWindowAlignmentError(
                        "Localization trace exceeds the diagnostic record budget."
                    )
                if (
                    len(raw) > MAXIMUM_TRACE_RECORD_BYTES
                    or not raw.endswith(b"\n")
                    or not raw.strip()
                ):
                    raise StructureWindowAlignmentError(
                        "Localization trace framing is invalid."
                    )
                value = load_strict_json_bytes(raw[:-1], name=f"{path.name}:{index}")
                if (
                    not isinstance(value, dict)
                    or value.get("format") != "MarketScannerLocalizationTrace"
                    or value.get("version") != 1
                ):
                    raise StructureWindowAlignmentError(
                        "Localization trace schema is invalid."
                    )
                timestamp = _finite_number(value.get("timestamp"), "trace timestamp")
                node_timestamp_value = value.get("nodeTimebaseTimestamp")
                node_offset_value = value.get("nodeTimebaseOffsetSeconds")
                node_timestamp: float | None = None
                if node_timestamp_value is not None or node_offset_value is not None:
                    node_timestamp = _finite_number(
                        node_timestamp_value, "trace node-timebase timestamp"
                    )
                    node_offset = _finite_number(
                        node_offset_value, "trace node-timebase offset"
                    )
                    if abs(timestamp + node_offset - node_timestamp) > 0.001:
                        raise StructureWindowAlignmentError(
                            "Localization trace node-timebase identity is invalid."
                        )
                raw_pose = value.get("rawPose")
                if not isinstance(raw_pose, dict):
                    raise StructureWindowAlignmentError("Trace raw pose is invalid.")
                pose = Pose2D(
                    _finite_number(raw_pose.get("x_m"), "trace raw x"),
                    _finite_number(raw_pose.get("y_m"), "trace raw y"),
                    _normalize_angle(
                        _finite_number(raw_pose.get("yaw_rad"), "trace raw yaw")
                    ),
                )
                if records and timestamp <= records[-1].timestamp:
                    raise StructureWindowAlignmentError(
                        "Localization trace timestamps are not strictly increasing."
                    )
                if (
                    records
                    and node_timestamp is not None
                    and records[-1].node_timebase_timestamp is not None
                    and node_timestamp <= records[-1].node_timebase_timestamp
                ):
                    raise StructureWindowAlignmentError(
                        "Localization trace node-timebase timestamps are not strictly increasing."
                    )
                records.append(TracePose(timestamp, pose, node_timestamp))
    except (OSError, StrictJSONError) as exc:
        raise StructureWindowAlignmentError(
            f"Localization trace cannot be read: {exc}"
        ) from exc
    if not records:
        raise StructureWindowAlignmentError("Localization trace is empty.")
    return records


def _decode_cv_matrix(
    blob: Any,
    *,
    expected_type: int,
    element_size: int,
) -> tuple[int, int, bytes]:
    if not isinstance(blob, bytes) or len(blob) < 12:
        raise StructureWindowAlignmentError(
            "Optimized RTAB-Map matrix is missing or invalid."
        )
    rows, columns, matrix_type = struct.unpack_from("<3i", blob, len(blob) - 12)
    expected_size = rows * columns * element_size
    if (
        rows <= 0
        or columns <= 0
        or matrix_type != expected_type
        or expected_size <= 0
        or expected_size > 512 * 1024 * 1024
    ):
        raise StructureWindowAlignmentError(
            "Optimized RTAB-Map matrix header is invalid."
        )
    try:
        payload = zlib.decompress(blob)
    except zlib.error as exc:
        raise StructureWindowAlignmentError(
            "Optimized RTAB-Map matrix cannot be decompressed."
        ) from exc
    if len(payload) != expected_size:
        raise StructureWindowAlignmentError(
            "Optimized RTAB-Map matrix size is inconsistent."
        )
    return rows, columns, payload


def _parse_ios_prior_transform(values: Sequence[float]) -> Pose2D:
    if len(values) != 12 or not all(math.isfinite(value) for value in values):
        raise StructureWindowAlignmentError("Optimized RTAB-Map pose is invalid.")
    # Same contract as offline_localization horizontal_axes=ios_prior:
    # RTABMapApp stores N = R * ARKit * inverse(R), so prior-map horizontal
    # coordinates recover as (-native_y, native_x) with native XY yaw.
    return Pose2D(
        -float(values[7]),
        float(values[3]),
        _normalize_angle(math.atan2(float(values[4]), float(values[0]))),
    )


def load_optimized_node_poses(path: Path) -> list[OptimizedNodePose]:
    try:
        connection = sqlite3.connect(f"file:{path.resolve()}?mode=ro", uri=True)
        try:
            quick_check = connection.execute("PRAGMA quick_check").fetchone()
            if not quick_check or quick_check[0] != "ok":
                raise StructureWindowAlignmentError(
                    "Optimized RTAB-Map database failed quick_check."
                )
            table_names = {
                str(row[0])
                for row in connection.execute(
                    "SELECT name FROM sqlite_master WHERE type='table'"
                )
            }
            if not {"Node", "Admin"}.issubset(table_names):
                raise StructureWindowAlignmentError(
                    "Optimized RTAB-Map database schema is incomplete."
                )
            node_rows = connection.execute(
                "SELECT id, stamp FROM Node WHERE id>0 ORDER BY id"
            ).fetchall()
            admin_rows = connection.execute(
                "SELECT opt_ids, opt_poses FROM Admin "
                "WHERE length(opt_ids)>0 AND length(opt_poses)>0 "
                "ORDER BY rowid DESC"
            ).fetchall()
        finally:
            connection.close()
    except sqlite3.Error as exc:
        raise StructureWindowAlignmentError(
            f"Optimized RTAB-Map database cannot be read: {exc}"
        ) from exc
    if not node_rows or len(node_rows) > MAXIMUM_OPTIMIZED_NODES or not admin_rows:
        raise StructureWindowAlignmentError(
            "Optimized RTAB-Map node inventory is unavailable or exceeds the budget."
        )
    stamps: dict[int, float] = {}
    previous_node_id = 0
    previous_timestamp: float | None = None
    for node_id_value, timestamp_value in node_rows:
        node_id = _strict_int(node_id_value, "optimized node id", minimum=1)
        timestamp = _finite_number(timestamp_value, "optimized node timestamp")
        if node_id <= previous_node_id or (
            previous_timestamp is not None and timestamp <= previous_timestamp
        ):
            raise StructureWindowAlignmentError(
                "Optimized RTAB-Map node identity is not strictly increasing."
            )
        stamps[node_id] = timestamp
        previous_node_id = node_id
        previous_timestamp = timestamp
    for ids_blob, poses_blob in admin_rows:
        try:
            _id_rows, id_columns, ids_payload = _decode_cv_matrix(
                ids_blob, expected_type=4, element_size=4
            )
            _pose_rows, pose_columns, poses_payload = _decode_cv_matrix(
                poses_blob, expected_type=5, element_size=4
            )
            node_ids = [value[0] for value in struct.iter_unpack("<i", ids_payload)]
            pose_values = [value[0] for value in struct.iter_unpack("<f", poses_payload)]
            if (
                len(node_ids) != id_columns
                or len(pose_values) != pose_columns
                or len(pose_values) != len(node_ids) * 12
                or len(node_ids) != len(stamps)
                or set(node_ids) != set(stamps)
            ):
                continue
            return [
                OptimizedNodePose(
                    node_id=int(node_id),
                    node_timebase_timestamp=stamps[int(node_id)],
                    pose=_parse_ios_prior_transform(
                        pose_values[index * 12 : (index + 1) * 12]
                    ),
                )
                for index, node_id in sorted(
                    enumerate(node_ids), key=lambda item: int(item[1])
                )
            ]
        except StructureWindowAlignmentError:
            continue
    raise StructureWindowAlignmentError(
        "Admin.opt_poses does not exactly cover the optimized Node inventory."
    )


def build_optimized_placement_trace(
    trace: Sequence[TracePose],
    optimized_nodes: Sequence[OptimizedNodePose],
    initial_pose: Pose2D,
) -> tuple[list[TracePose], dict[str, Any]]:
    if (
        not trace
        or not optimized_nodes
        or any(record.node_timebase_timestamp is None for record in trace)
    ):
        raise StructureWindowAlignmentError(
            "Optimized trajectory cannot be bound to localization trace."
        )
    trace_node_timestamps = [
        float(record.node_timebase_timestamp) for record in trace
    ]
    pairs: list[tuple[Pose2D, Pose2D, float]] = []
    for record in optimized_nodes:
        trace_index = _nearest_trace_index(
            trace_node_timestamps, record.node_timebase_timestamp
        )
        delta = abs(
            trace_node_timestamps[trace_index] - record.node_timebase_timestamp
        )
        if delta > 1.0:
            raise StructureWindowAlignmentError(
                "Optimized node timestamp cannot be bound to localization trace."
            )
        pairs.append((record.pose, trace[trace_index].pose, delta))
    first = optimized_nodes[0].pose
    rotation = _normalize_angle(initial_pose.yaw - first.yaw)
    rotated_first_x, rotated_first_y = _rotate(first.x, first.y, rotation)
    translation_x = initial_pose.x - rotated_first_x
    translation_y = initial_pose.y - rotated_first_y
    aligned_node_poses = [
        TracePose(
            timestamp=record.node_timebase_timestamp,
            node_timebase_timestamp=record.node_timebase_timestamp,
            pose=_compose(
                Pose2D(translation_x, translation_y, rotation),
                record.pose,
            ),
        )
        for record in optimized_nodes
    ]
    aligned_node_timestamps = [record.timestamp for record in aligned_node_poses]
    residuals_m: list[float] = []
    residuals_yaw_deg: list[float] = []
    for source, target, _delta in pairs:
        aligned = _compose(
            Pose2D(translation_x, translation_y, rotation), source
        )
        residuals_m.append(math.hypot(aligned.x - target.x, aligned.y - target.y))
        residuals_yaw_deg.append(
            abs(math.degrees(_normalize_angle(aligned.yaw - target.yaw)))
        )
    def percentile(values: Sequence[float], ratio: float) -> float:
        ordered = sorted(values)
        return ordered[min(len(ordered) - 1, int((len(ordered) - 1) * ratio))]

    result: list[TracePose] = []
    for record in trace:
        assert record.node_timebase_timestamp is not None
        node_index = _nearest_trace_index(
            aligned_node_timestamps, record.node_timebase_timestamp
        )
        result.append(
            TracePose(
                timestamp=record.timestamp,
                pose=aligned_node_poses[node_index].pose,
                node_timebase_timestamp=record.node_timebase_timestamp,
            )
        )
    return result, {
        "source": "admin_opt_poses_exact_node_coverage",
        "optimized_node_count": len(optimized_nodes),
        "gauge_authority": "metadata.initialMapPose_bound_to_first_optimized_node",
        "gauge_rotation_deg": math.degrees(rotation),
        "gauge_translation_x_m": translation_x,
        "gauge_translation_y_m": translation_y,
        "trace_binding_max_delta_seconds": max(delta for _source, _target, delta in pairs),
        "raw_trace_fit_translation_median_m": statistics.median(residuals_m),
        "raw_trace_fit_translation_p95_m": percentile(residuals_m, 0.95),
        "raw_trace_fit_translation_max_m": max(residuals_m),
        "raw_trace_fit_yaw_median_deg": statistics.median(residuals_yaw_deg),
        "raw_trace_fit_yaw_p95_deg": percentile(residuals_yaw_deg, 0.95),
        "raw_trace_fit_yaw_max_deg": max(residuals_yaw_deg),
    }


def load_initial_pose(metadata_path: Path) -> Pose2D:
    try:
        payload = load_strict_json_bytes(metadata_path.read_bytes(), name=metadata_path.name)
    except (OSError, StrictJSONError) as exc:
        raise StructureWindowAlignmentError(f"Metadata cannot be read: {exc}") from exc
    value = payload.get("initialMapPose") if isinstance(payload, dict) else None
    if not isinstance(value, dict):
        raise StructureWindowAlignmentError("Metadata initialMapPose is missing.")
    return Pose2D(
        _finite_number(value.get("x_m"), "initial pose x"),
        _finite_number(value.get("y_m"), "initial pose y"),
        _normalize_angle(_finite_number(value.get("yaw_rad"), "initial pose yaw")),
    )


def load_distance_levels(
    distance_fields_path: Path,
    floor_id: str,
    resolutions: Sequence[float] = (0.40, 0.20, 0.10),
) -> list[DistanceLevel]:
    try:
        payload = load_strict_json_bytes(
            distance_fields_path.read_bytes(), name=distance_fields_path.name
        )
    except (OSError, StrictJSONError) as exc:
        raise StructureWindowAlignmentError(
            f"Distance fields cannot be read: {exc}"
        ) from exc
    if (
        not isinstance(payload, dict)
        or payload.get("format") != "MarketScannerDistanceFields"
        or payload.get("version") != 1
        or not isinstance(payload.get("floors"), dict)
        or not isinstance(payload["floors"].get(floor_id), dict)
        or not isinstance(payload["floors"][floor_id].get("levels"), list)
    ):
        raise StructureWindowAlignmentError("Distance-field schema is invalid.")
    truncation = _finite_number(
        payload.get("truncation_distance_m"), "distance truncation"
    )
    by_resolution = {
        round(float(level.get("resolution_m")), 6): level
        for level in payload["floors"][floor_id]["levels"]
        if isinstance(level, dict)
        and isinstance(level.get("resolution_m"), (int, float))
        and not isinstance(level.get("resolution_m"), bool)
    }
    levels: list[DistanceLevel] = []
    for resolution in resolutions:
        raw = by_resolution.get(round(float(resolution), 6))
        if raw is None:
            raise StructureWindowAlignmentError(
                f"Distance field {resolution:.2f} m is missing."
            )
        levels.append(DistanceLevel(raw, truncation))
    return levels


def load_road_graph(path: Path, floor_id: str) -> RoadGraph:
    try:
        size = path.stat().st_size
        if size <= 0 or size > MAXIMUM_ROAD_GRAPH_FILE_BYTES:
            raise StructureWindowAlignmentError(
                "Road graph exceeds the diagnostic resource budget."
            )
        payload = load_strict_json_bytes(path.read_bytes(), name=path.name)
    except (OSError, StrictJSONError) as exc:
        raise StructureWindowAlignmentError(f"Road graph cannot be read: {exc}") from exc
    if (
        not isinstance(payload, dict)
        or set(payload) != {"format", "version", "nodes", "edges", "crosses", "statistics"}
        or payload.get("format") != "MarketScannerRoadGraph"
        or payload.get("version") != 1
        or not isinstance(payload.get("nodes"), list)
        or not isinstance(payload.get("edges"), list)
        or not isinstance(payload.get("crosses"), list)
        or not isinstance(payload.get("statistics"), dict)
        or len(payload["nodes"]) > MAXIMUM_ROAD_NODES
        or len(payload["edges"]) > MAXIMUM_ROAD_EDGES
    ):
        raise StructureWindowAlignmentError("Road graph schema is invalid.")
    nodes: dict[str, tuple[float, float]] = {}
    for value in payload["nodes"]:
        if (
            not isinstance(value, dict)
            or set(value)
            != {"id", "floor_id", "element_id", "position_m", "visible", "cross_ids"}
            or not isinstance(value.get("id"), str)
            or not value["id"]
            or not isinstance(value.get("floor_id"), str)
            or not isinstance(value.get("element_id"), str)
            or not isinstance(value.get("visible"), bool)
            or not isinstance(value.get("cross_ids"), list)
            or any(not isinstance(item, str) or not item for item in value["cross_ids"])
            or not isinstance(value.get("position_m"), list)
            or len(value["position_m"]) != 2
        ):
            raise StructureWindowAlignmentError("Road graph node is invalid.")
        if value["id"] in nodes:
            raise StructureWindowAlignmentError("Road graph nodes are duplicated.")
        position = (
            _finite_number(value["position_m"][0], "road node x"),
            _finite_number(value["position_m"][1], "road node y"),
        )
        if value["floor_id"] == floor_id and value["visible"]:
            nodes[value["id"]] = position
    segments: list[RoadSegment] = []
    adjacency_values: dict[str, list[tuple[str, float]]] = {}
    edge_ids: set[str] = set()
    for value in payload["edges"]:
        if (
            not isinstance(value, dict)
            or set(value)
            != {"id", "floor_id", "from", "to", "length_m", "cross_ids"}
            or not isinstance(value.get("id"), str)
            or not value["id"]
            or not isinstance(value.get("floor_id"), str)
            or not isinstance(value.get("from"), str)
            or not isinstance(value.get("to"), str)
            or not isinstance(value.get("cross_ids"), list)
            or any(not isinstance(item, str) or not item for item in value["cross_ids"])
        ):
            raise StructureWindowAlignmentError("Road graph edge is invalid.")
        if value["id"] in edge_ids:
            raise StructureWindowAlignmentError("Road graph edges are duplicated.")
        edge_ids.add(value["id"])
        length = _finite_number(value.get("length_m"), "road edge length")
        if length <= 0:
            raise StructureWindowAlignmentError("Road graph edge length is invalid.")
        if value["floor_id"] != floor_id:
            continue
        start = nodes.get(value["from"])
        end = nodes.get(value["to"])
        if start is None or end is None:
            raise StructureWindowAlignmentError(
                "Road graph edge references an unavailable floor node."
            )
        actual_length = math.hypot(end[0] - start[0], end[1] - start[1])
        if actual_length <= 1.0e-9 or abs(actual_length - length) > 0.02:
            raise StructureWindowAlignmentError(
                "Road graph edge length differs from its node geometry."
            )
        segments.append(
            RoadSegment(
                value["id"], value["from"], value["to"],
                start[0], start[1], end[0], end[1],
                math.atan2(end[1] - start[1], end[0] - start[0]),
                actual_length,
            )
        )
        adjacency_values.setdefault(value["from"], []).append(
            (value["to"], actual_length)
        )
        adjacency_values.setdefault(value["to"], []).append(
            (value["from"], actual_length)
        )
    statistics_payload = payload["statistics"]
    for field in ("node_count", "edge_count", "cross_count"):
        if type(statistics_payload.get(field)) is not int or statistics_payload[field] < 0:
            raise StructureWindowAlignmentError("Road graph statistics are invalid.")
    if (
        statistics_payload["node_count"] != len(payload["nodes"])
        or statistics_payload["edge_count"] != len(payload["edges"])
        or statistics_payload["cross_count"] != len(payload["crosses"])
    ):
        raise StructureWindowAlignmentError("Road graph statistics drifted from content.")
    return RoadGraph(
        segments,
        {
            node: tuple(sorted(neighbors, key=lambda item: (item[0], item[1])))
            for node, neighbors in adjacency_values.items()
        },
    )


def _nearest_trace_index(trace_timestamps: Sequence[float], timestamp: float) -> int:
    insertion = bisect.bisect_left(trace_timestamps, timestamp)
    candidates = range(max(0, insertion - 1), min(len(trace_timestamps), insertion + 2))
    return min(candidates, key=lambda index: abs(trace_timestamps[index] - timestamp))


def build_structure_windows(
    cells: Sequence[StructureCoverageCell],
    *,
    cell_size_m: float,
    trace: Sequence[TracePose],
    initial_pose: Pose2D,
    window_seconds: float = 120.0,
    maximum_points_per_window: int = 300,
    minimum_points_per_window: int = 30,
) -> list[StructureWindow]:
    if (
        not cells
        or not trace
        or not math.isfinite(window_seconds)
        or window_seconds <= 0
        or not 30 <= maximum_points_per_window <= 2_000
        or not 10 <= minimum_points_per_window <= maximum_points_per_window
    ):
        raise StructureWindowAlignmentError("Structure window budget is invalid.")
    trace_timestamps = [record.timestamp for record in trace]
    first_time = min(cell.representative_timestamp for cell in cells)
    grouped: dict[int, list[WindowPoint]] = {}
    for cell in cells:
        representative = cell.representative_timestamp
        trace_index = _nearest_trace_index(trace_timestamps, representative)
        if abs(trace_timestamps[trace_index] - representative) > 1.0:
            raise StructureWindowAlignmentError(
                "Structure coverage cannot be time-bound to localization trace."
            )
        relative_pose = _relative(initial_pose, trace[trace_index].pose)
        # Coverage is persisted in the RTAB-Map/ARKit horizontal world grid:
        # Swift stores world X and world Z. Canonical map/local horizontal Y is
        # ARKit -Z, so this is the single required axis conversion.
        coverage_x = (cell.x_index + 0.5) * cell_size_m
        coverage_y = -(cell.z_index + 0.5) * cell_size_m
        # Convert the persistent world-grid cell into the representative
        # camera/trajectory pose's local horizontal frame. Translation alone
        # is insufficient: after an aisle turn it would rotate the shelf shape
        # differently in every window and manufacture false map ambiguity.
        local_x, local_y = _rotate(
            coverage_x - relative_pose.x,
            coverage_y - relative_pose.y,
            -relative_pose.yaw,
        )
        grouped.setdefault(int(math.floor((representative - first_time) / window_seconds)), []).append(
            WindowPoint(
                local_x,
                local_y,
                representative,
                cell.elevated_observation_count,
                cell.view_direction_mask.bit_count() >= 2,
            )
        )
    windows: list[StructureWindow] = []
    for window_key, raw_points in sorted(grouped.items()):
        ordered = sorted(
            raw_points,
            key=lambda point: (
                not point.multi_view,
                -point.observation_count,
                point.local_x,
                point.local_y,
                point.timestamp,
            ),
        )
        if len(ordered) > maximum_points_per_window:
            stride = len(ordered) / maximum_points_per_window
            sampled = [ordered[min(len(ordered) - 1, int(index * stride))] for index in range(maximum_points_per_window)]
        else:
            sampled = ordered
        if len(sampled) < minimum_points_per_window:
            continue
        start_timestamp = first_time + window_key * window_seconds
        end_timestamp = start_timestamp + window_seconds
        representative_timestamp = statistics.median(point.timestamp for point in sampled)
        trace_index = _nearest_trace_index(trace_timestamps, representative_timestamp)
        windows.append(
            StructureWindow(
                index=len(windows),
                start_timestamp=start_timestamp,
                end_timestamp=end_timestamp,
                representative_timestamp=representative_timestamp,
                representative_trace_index=trace_index,
                points=tuple(sampled),
            )
        )
    return windows


def _window_cost(
    correction: Pose2D,
    window_pose: Pose2D,
    points: Sequence[WindowPoint],
    level: DistanceLevel,
) -> tuple[float, float]:
    map_pose = _compose(correction, window_pose)
    total = 0.0
    outside = 0
    for point in points:
        x, y = _rotate(point.local_x, point.local_y, map_pose.yaw)
        distance, is_outside = level.distance(map_pose.x + x, map_pose.y + y)
        bounded = min(0.45, distance)
        total += bounded * bounded
        outside += int(is_outside)
    return total / max(1, len(points)), outside / max(1, len(points))


def _independent_candidates(
    values: Iterable[AlignmentCandidate],
    limit: int,
    *,
    translation_separation_m: float,
    yaw_separation_deg: float,
) -> list[AlignmentCandidate]:
    selected: list[AlignmentCandidate] = []
    yaw_separation = math.radians(yaw_separation_deg)
    for candidate in sorted(
        values,
        key=lambda value: (
            _candidate_observation_cost(value),
            value.geometry_cost,
            value.outside_ratio,
            value.correction.x,
            value.correction.y,
            value.correction.yaw,
        ),
    ):
        if all(
            math.hypot(
                candidate.correction.x - prior.correction.x,
                candidate.correction.y - prior.correction.y,
            )
            >= translation_separation_m
            or abs(_normalize_angle(candidate.correction.yaw - prior.correction.yaw))
            >= yaw_separation
            for prior in selected
        ):
            selected.append(candidate)
        if len(selected) >= limit:
            break
    return selected


def _search(
    centers: Sequence[Pose2D],
    window_pose: Pose2D,
    points: Sequence[WindowPoint],
    level: DistanceLevel,
    *,
    translation_radius_m: float,
    translation_step_m: float,
    yaw_radius_deg: float,
    yaw_step_deg: float,
    limit: int,
    translation_separation_m: float,
    maximum_correction_radius_m: float,
    maximum_correction_yaw_deg: float,
    road_graph: RoadGraph | None,
) -> list[AlignmentCandidate]:
    translation_steps = int(math.floor(translation_radius_m / translation_step_m))
    yaw_steps = int(math.floor(yaw_radius_deg / yaw_step_deg))
    candidates: list[AlignmentCandidate] = []
    for center in centers:
        for x_index in range(-translation_steps, translation_steps + 1):
            for y_index in range(-translation_steps, translation_steps + 1):
                for yaw_index in range(-yaw_steps, yaw_steps + 1):
                    correction = Pose2D(
                        center.x + x_index * translation_step_m,
                        center.y + y_index * translation_step_m,
                        _normalize_angle(
                            center.yaw + math.radians(yaw_index * yaw_step_deg)
                        ),
                    )
                    if (
                        math.hypot(correction.x, correction.y)
                        > maximum_correction_radius_m + 1.0e-9
                        or abs(math.degrees(correction.yaw))
                        > maximum_correction_yaw_deg + 1.0e-9
                    ):
                        continue
                    cost, outside = _window_cost(
                        correction, window_pose, points, level
                    )
                    if road_graph is None:
                        candidates.append(
                            AlignmentCandidate(correction, cost, outside)
                        )
                    else:
                        map_pose = _compose(correction, window_pose)
                        evidence = road_graph.evidence(map_pose)
                        candidates.append(
                            AlignmentCandidate(
                                correction,
                                cost,
                                outside,
                                evidence.distance_m,
                                evidence.yaws_rad,
                                map_pose.x,
                                map_pose.y,
                                evidence.edge_index,
                                evidence.edge_fraction,
                            )
                        )
    return _independent_candidates(
        candidates,
        limit,
        translation_separation_m=translation_separation_m,
        yaw_separation_deg=max(2.0, yaw_step_deg * 1.5),
    )


def search_window_candidates(
    window: StructureWindow,
    *,
    trace: Sequence[TracePose],
    levels: Sequence[DistanceLevel],
    correction_radius_m: float = 6.0,
    yaw_radius_deg: float = 25.0,
    candidate_limit: int = 5,
    road_graph: RoadGraph | None = None,
) -> list[AlignmentCandidate]:
    if (
        len(levels) != 3
        or not 0.5 <= correction_radius_m <= 25.0
        or not 1.0 <= yaw_radius_deg <= 90.0
        or not 1 <= candidate_limit <= 24
    ):
        raise StructureWindowAlignmentError("PC structure matcher requires three levels.")
    window_pose = trace[window.representative_trace_index].pose
    coarse = _search(
        [Pose2D(0.0, 0.0, 0.0)],
        window_pose,
        window.points,
        levels[0],
        translation_radius_m=correction_radius_m,
        translation_step_m=0.6,
        yaw_radius_deg=yaw_radius_deg,
        yaw_step_deg=5.0,
        limit=24,
        translation_separation_m=0.8,
        maximum_correction_radius_m=correction_radius_m,
        maximum_correction_yaw_deg=yaw_radius_deg,
        road_graph=road_graph,
    )
    medium = _search(
        [candidate.correction for candidate in coarse],
        window_pose,
        window.points,
        levels[1],
        translation_radius_m=0.6,
        translation_step_m=0.2,
        yaw_radius_deg=5.0,
        yaw_step_deg=2.0,
        limit=24,
        translation_separation_m=0.45,
        maximum_correction_radius_m=correction_radius_m,
        maximum_correction_yaw_deg=yaw_radius_deg,
        road_graph=road_graph,
    )
    fine = _search(
        [candidate.correction for candidate in medium],
        window_pose,
        window.points,
        levels[2],
        translation_radius_m=0.2,
        translation_step_m=0.1,
        yaw_radius_deg=2.0,
        yaw_step_deg=1.0,
        limit=candidate_limit,
        translation_separation_m=0.30,
        maximum_correction_radius_m=correction_radius_m,
        maximum_correction_yaw_deg=yaw_radius_deg,
        road_graph=road_graph,
    )
    # The start pose is already a moderately uncertain absolute gauge. A
    # sequence hypothesis may refine it, but a candidate beyond the requested
    # diagnostic search radius is never silently introduced during refinement.
    bounded = [
        value
        for value in fine
        if math.hypot(value.correction.x, value.correction.y)
        <= correction_radius_m + 1.0e-9
        and abs(math.degrees(value.correction.yaw)) <= yaw_radius_deg + 1.0e-9
    ]
    return sorted(
        bounded,
        key=lambda value: (
            _candidate_observation_cost(value),
            value.geometry_cost,
            value.correction.x,
            value.correction.y,
            value.correction.yaw,
        ),
    )


def _candidate_observation_cost(candidate: AlignmentCandidate) -> float:
    """Structure-primary, bounded road-topology soft evidence.

    A road mismatch can never delete a candidate or outweigh a clearly better
    shelf fit. It only helps choose between periodic candidates whose distance-
    field geometry is otherwise nearly identical.
    """
    road_distance = min(4.0, max(0.0, candidate.road_distance_m))
    return (
        candidate.geometry_cost
        + 0.25 * candidate.outside_ratio
        + 0.005 * (road_distance / 2.0) ** 2
    )


def _road_transition_cost(
    prior: AlignmentCandidate,
    candidate: AlignmentCandidate,
) -> tuple[float, float | None]:
    if (
        prior.map_x is None or prior.map_y is None
        or candidate.map_x is None or candidate.map_y is None
        or not prior.road_yaws_rad or not candidate.road_yaws_rad
    ):
        return 0.0, None
    dx = candidate.map_x - prior.map_x
    dy = candidate.map_y - prior.map_y
    if math.hypot(dx, dy) < 0.75:
        return 0.0, None
    travel_yaw = math.atan2(dy, dx)
    yaw_delta = min(
        min(
            abs(_normalize_angle(travel_yaw - road_yaw)),
            abs(_normalize_angle(travel_yaw - road_yaw - math.pi)),
        )
        for road_yaw in (*prior.road_yaws_rad, *candidate.road_yaws_rad)
    )
    bounded = min(math.pi / 2.0, yaw_delta)
    return 0.006 * (bounded / math.radians(30.0)) ** 2, yaw_delta


def select_candidate_sequence(
    candidate_sets: Sequence[Sequence[AlignmentCandidate]],
    *,
    translation_continuity_sigma_m: float = 1.0,
    yaw_continuity_sigma_deg: float = 6.0,
    road_graph: RoadGraph | None = None,
    expected_travel_distances_m: Sequence[float] | None = None,
) -> tuple[list[int], float, float | None, float | None]:
    if (
        not candidate_sets
        or any(not values for values in candidate_sets)
        or not math.isfinite(translation_continuity_sigma_m)
        or translation_continuity_sigma_m <= 0
        or not math.isfinite(yaw_continuity_sigma_deg)
        or yaw_continuity_sigma_deg <= 0
        or (
            expected_travel_distances_m is not None
            and (
                len(expected_travel_distances_m) != len(candidate_sets) - 1
                or any(
                    not math.isfinite(value) or value < 0
                    for value in expected_travel_distances_m
                )
            )
        )
    ):
        raise StructureWindowAlignmentError("Candidate sequence is incomplete.")
    yaw_sigma = math.radians(yaw_continuity_sigma_deg)
    first_costs = [
        _candidate_observation_cost(candidate)
        + 0.015 * (candidate.correction.x * candidate.correction.x + candidate.correction.y * candidate.correction.y)
        + 0.02 * (candidate.correction.yaw / math.radians(15.0)) ** 2
        for candidate in candidate_sets[0]
    ]
    # Retain a bounded beam of *complete paths* for every state. Keeping only one
    # backpointer per candidate loses the true runner-up when two distinct
    # sequences converge on the same final candidate. Keeping only two still
    # lets sub-grid variants crowd out the first genuinely different aisle.
    paths_per_state = 12
    paths_by_state: list[list[tuple[float, tuple[int, ...]]]] = [
        [(cost, (candidate_index,))]
        for candidate_index, cost in enumerate(first_costs)
    ]
    for window_index in range(1, len(candidate_sets)):
        current_paths_by_state: list[list[tuple[float, tuple[int, ...]]]] = []
        for candidate_index, candidate in enumerate(candidate_sets[window_index]):
            alternatives: list[tuple[float, tuple[int, ...]]] = []
            for prior_index, prior in enumerate(candidate_sets[window_index - 1]):
                translation_delta = math.hypot(
                    candidate.correction.x - prior.correction.x,
                    candidate.correction.y - prior.correction.y,
                )
                yaw_delta = abs(
                    _normalize_angle(candidate.correction.yaw - prior.correction.yaw)
                )
                transition = (
                    0.20 * (translation_delta / translation_continuity_sigma_m) ** 2
                    + 0.15 * (yaw_delta / yaw_sigma) ** 2
                )
                road_transition, _road_yaw_delta = _road_transition_cost(
                    prior, candidate
                )
                transition += road_transition
                if road_graph is not None:
                    route_distance = road_graph.route_distance(
                        prior.road_edge_index,
                        prior.road_edge_fraction,
                        candidate.road_edge_index,
                        candidate.road_edge_fraction,
                    )
                    if route_distance is None:
                        transition += 0.06
                    else:
                        if expected_travel_distances_m is not None:
                            reference_distance = expected_travel_distances_m[
                                window_index - 1
                            ]
                            mismatch = min(
                                30.0,
                                abs(route_distance - reference_distance),
                            )
                            transition += 0.004 * (mismatch / 5.0) ** 2
                        elif (
                            prior.map_x is not None and prior.map_y is not None
                            and candidate.map_x is not None and candidate.map_y is not None
                        ):
                            euclidean = math.hypot(
                                candidate.map_x - prior.map_x,
                                candidate.map_y - prior.map_y,
                            )
                            detour = min(
                                20.0,
                                max(0.0, route_distance - euclidean),
                            )
                            transition += 0.012 * (detour / 5.0) ** 2
                for prior_cost, prior_path in paths_by_state[prior_index]:
                    alternatives.append(
                        (
                            prior_cost
                            + transition
                            + _candidate_observation_cost(candidate),
                            prior_path + (candidate_index,),
                        )
                    )
            ranked_state = sorted(
                alternatives, key=lambda item: (item[0], item[1])
            )
            unique_state: list[tuple[float, tuple[int, ...]]] = []
            seen_paths: set[tuple[int, ...]] = set()
            for alternative in ranked_state:
                if alternative[1] in seen_paths:
                    continue
                seen_paths.add(alternative[1])
                unique_state.append(alternative)
                if len(unique_state) == paths_per_state:
                    break
            if not unique_state:
                raise StructureWindowAlignmentError(
                    "Candidate sequence state has no predecessor."
                )
            current_paths_by_state.append(unique_state)
        paths_by_state = current_paths_by_state
    ranked = sorted(
        (path for state_paths in paths_by_state for path in state_paths),
        key=lambda item: (item[0], item[1]),
    )
    unique_ranked: list[tuple[float, tuple[int, ...]]] = []
    seen_final_paths: set[tuple[int, ...]] = set()
    for value in ranked:
        if value[1] in seen_final_paths:
            continue
        seen_final_paths.add(value[1])
        unique_ranked.append(value)
    if not unique_ranked:
        raise StructureWindowAlignmentError("Candidate sequence has no complete path.")
    best_total, best_path = unique_ranked[0]
    second_total: float | None = None
    for alternative_total, alternative_path in unique_ranked[1:]:
        moderate_difference_count = 0
        strongly_different = False
        for window_index, (best_index, alternative_index) in enumerate(
            zip(best_path, alternative_path)
        ):
            best_candidate = candidate_sets[window_index][best_index]
            alternative_candidate = candidate_sets[window_index][alternative_index]
            translation = math.hypot(
                best_candidate.correction.x - alternative_candidate.correction.x,
                best_candidate.correction.y - alternative_candidate.correction.y,
            )
            yaw = abs(
                _normalize_angle(
                    best_candidate.correction.yaw
                    - alternative_candidate.correction.yaw
                )
            )
            moderate_difference_count += int(
                translation >= 1.0 or yaw >= math.radians(8.0)
            )
            strongly_different = strongly_different or (
                translation >= 3.0 or yaw >= math.radians(15.0)
            )
        if strongly_different or moderate_difference_count >= 2:
            second_total = alternative_total
            break
    selected = list(best_path)
    normalized_margin = (
        None
        if second_total is None
        else max(0.0, (second_total - best_total) / max(abs(second_total), 1.0e-9))
    )
    return selected, best_total, second_total, normalized_margin


def diagnostic_report(
    *,
    prior_map: Path,
    segment: Path,
    floor_id: str,
    optimized_database: Path | None = None,
    window_seconds: float = 120.0,
    maximum_points_per_window: int = 300,
    correction_radius_m: float = 6.0,
    yaw_radius_deg: float = 25.0,
    candidate_limit: int = 24,
) -> dict[str, Any]:
    coverage_path = segment / "structure_coverage_cells.json"
    trace_path = segment / "localization_trace.jsonl"
    metadata_path = segment / "metadata.json"
    initial_pose = load_initial_pose(metadata_path)
    raw_trace = load_localization_trace(trace_path)
    trajectory_audit: dict[str, Any] = {
        "source": "localization_trace_raw_pose",
        "optimized_node_count": 0,
    }
    if optimized_database is not None:
        trace, trajectory_audit = build_optimized_placement_trace(
            raw_trace,
            load_optimized_node_poses(optimized_database),
            initial_pose,
        )
    else:
        trace = raw_trace
    cell_size_m, cells, summary = load_structure_coverage(coverage_path)
    levels = load_distance_levels(
        prior_map / "distance_fields.json", floor_id=floor_id
    )
    road_graph_path = prior_map / "road_graph.json"
    road_graph = load_road_graph(road_graph_path, floor_id=floor_id)
    windows = build_structure_windows(
        cells,
        cell_size_m=cell_size_m,
        trace=trace,
        initial_pose=initial_pose,
        window_seconds=window_seconds,
        maximum_points_per_window=maximum_points_per_window,
    )
    if not windows:
        raise StructureWindowAlignmentError(
            "No structure window meets the evidence budget."
        )
    candidate_sets = [
        search_window_candidates(
            window,
            trace=trace,
            levels=levels,
            correction_radius_m=correction_radius_m,
            yaw_radius_deg=yaw_radius_deg,
            candidate_limit=candidate_limit,
            road_graph=road_graph,
        )
        for window in windows
    ]
    if any(not candidates for candidates in candidate_sets):
        raise StructureWindowAlignmentError(
            "At least one structure window produced no bounded candidate."
        )
    trace_prefix_distance_m = [0.0]
    for index in range(1, len(trace)):
        trace_prefix_distance_m.append(
            trace_prefix_distance_m[-1]
            + math.hypot(
                trace[index].pose.x - trace[index - 1].pose.x,
                trace[index].pose.y - trace[index - 1].pose.y,
            )
        )
    expected_window_travel_m = [
        abs(
            trace_prefix_distance_m[windows[index].representative_trace_index]
            - trace_prefix_distance_m[
                windows[index - 1].representative_trace_index
            ]
        )
        for index in range(1, len(windows))
    ]
    selected, total_cost, second_total, sequence_margin = select_candidate_sequence(
        candidate_sets,
        road_graph=road_graph,
        expected_travel_distances_m=expected_window_travel_m,
    )
    selected_candidates = [
        candidate_sets[index][candidate_index]
        for index, candidate_index in enumerate(selected)
    ]
    corrections_m = [
        math.hypot(candidate.correction.x, candidate.correction.y)
        for candidate in selected_candidates
    ]
    continuity_m = [
        math.hypot(
            selected_candidates[index].correction.x
            - selected_candidates[index - 1].correction.x,
            selected_candidates[index].correction.y
            - selected_candidates[index - 1].correction.y,
        )
        for index in range(1, len(selected_candidates))
    ]
    continuity_yaw_deg = [
        abs(
            math.degrees(
                _normalize_angle(
                    selected_candidates[index].correction.yaw
                    - selected_candidates[index - 1].correction.yaw
                )
            )
        )
        for index in range(1, len(selected_candidates))
    ]
    (
        continuity_supported,
        continuity_translation_gradient,
        continuity_yaw_gradient_deg_per_m,
    ) = correction_continuity_metrics(
        continuity_m,
        continuity_yaw_deg,
        expected_window_travel_m,
    )
    window_records: list[dict[str, Any]] = []
    for index, window in enumerate(windows):
        candidates = candidate_sets[index]
        chosen = selected[index]
        window_records.append(
            {
                "window_index": window.index,
                "start_timestamp": window.start_timestamp,
                "end_timestamp": window.end_timestamp,
                "representative_timestamp": window.representative_timestamp,
                "point_count": len(window.points),
                "selected_candidate_index": chosen,
                "selected": _candidate_payload(candidates[chosen]),
                "local_geometry_margin": (
                    None
                    if len(candidates) < 2
                    else max(0.0, candidates[1].geometry_cost - candidates[0].geometry_cost)
                ),
                "candidates": [_candidate_payload(candidate) for candidate in candidates],
            }
        )
    # Diagnostic-only confidence. It is intentionally conservative and never
    # becomes an absolute factor without the future input-manifest upgrade.
    mean_cost = statistics.fmean(
        candidate.geometry_cost for candidate in selected_candidates
    )
    maximum_outside = max(
        candidate.outside_ratio for candidate in selected_candidates
    )
    mean_road_distance = statistics.fmean(
        candidate.road_distance_m for candidate in selected_candidates
    )
    maximum_road_distance = max(
        candidate.road_distance_m for candidate in selected_candidates
    )
    selected_road_transition_yaw_deg = [
        math.degrees(yaw_delta)
        for index in range(1, len(selected_candidates))
        for _cost, yaw_delta in [
            _road_transition_cost(
                selected_candidates[index - 1], selected_candidates[index]
            )
        ]
        if yaw_delta is not None
    ]
    sequence_unique = sequence_margin is None or sequence_margin >= 0.03
    geometry_supported = mean_cost <= 0.10 and maximum_outside <= 0.20
    # A large absolute correction change is expected when a long scan slowly
    # accumulates drift. It is not a physical phone jump: each window carries
    # a map-gauge correction and distant windows may legitimately differ by
    # several metres. Continuity is therefore judged by correction change per
    # metre of gauge-neutral physical travel. A real short-distance reset still
    # produces a large gradient and remains unsupported. The absolute delta is
    # retained below as an audit metric, but it is not a rejection threshold.
    return {
        "format": REPORT_FORMAT,
        "version": REPORT_VERSION,
        "authority": "diagnostic_only_unbound_structure_coverage_v1",
        "publishable_constraint_count": 0,
        "factor_injection_allowed": False,
        "floor_id": floor_id,
        "input": {
            "structure_coverage_file": coverage_path.name,
            "structure_coverage_sha256": _sha256(coverage_path),
            "localization_trace_file": trace_path.name,
            "localization_trace_sha256": _sha256(trace_path),
            "metadata_sha256": _sha256(metadata_path),
            "optimized_database_sha256": (
                _sha256(optimized_database)
                if optimized_database is not None
                else None
            ),
            "prior_distance_fields_sha256": _sha256(
                prior_map / "distance_fields.json"
            ),
            "prior_road_graph_sha256": _sha256(road_graph_path),
            "stable_structure_cell_count": len(cells),
            "coverage_summary": summary,
        },
        "coordinate_contract": {
            "coverage_plane": "rtabmap_arkit_world_x_z",
            "local_plane": "x_and_negative_z_relative_to_trace_pose",
            "map_plane": "canonical_prior_map_x_y",
            "known_start_and_heading": {
                "x_m": initial_pose.x,
                "y_m": initial_pose.y,
                "yaw_rad": initial_pose.yaw,
            },
        },
        "trajectory": trajectory_audit,
        "parameters": {
            "window_seconds": window_seconds,
            "maximum_points_per_window": maximum_points_per_window,
            "correction_radius_m": correction_radius_m,
            "yaw_radius_deg": yaw_radius_deg,
            "candidate_limit": candidate_limit,
            "distance_field_resolutions_m": [level.resolution for level in levels],
            "road_topology_cost": {
                "authority": "soft_only_never_candidate_filter",
                "distance_cap_m": 4.0,
                "distance_sigma_m": 2.0,
                "distance_weight": 0.005,
                "direction_source": "adjacent_corrected_window_travel_tangent",
                "bidirectional_yaw_cap_deg": 90.0,
                "yaw_sigma_deg": 30.0,
                "yaw_weight": 0.006,
                "route_connectivity": "shortest_path_soft_only",
                "disconnected_transition_penalty": 0.06,
                "route_detour_cap_m": 20.0,
                "route_detour_sigma_m": 5.0,
                "route_detour_weight": 0.012,
                "optimized_trajectory_arc_length_source": (
                    "representative_trace_index_prefix_distance"
                ),
                "route_arc_length_mismatch_cap_m": 30.0,
                "route_arc_length_mismatch_sigma_m": 5.0,
                "route_arc_length_mismatch_weight": 0.004,
            },
        },
        "window_count": len(windows),
        "candidate_count": sum(len(values) for values in candidate_sets),
        "sequence": {
            "total_cost": total_cost,
            "second_total_cost": second_total,
            "normalized_margin": sequence_margin,
            "mean_geometry_cost": mean_cost,
            "maximum_outside_ratio": maximum_outside,
            "mean_selected_road_distance_m": mean_road_distance,
            "maximum_selected_road_distance_m": maximum_road_distance,
            "mean_selected_road_travel_yaw_delta_deg": (
                statistics.fmean(selected_road_transition_yaw_deg)
                if selected_road_transition_yaw_deg
                else None
            ),
            "maximum_selected_road_travel_yaw_delta_deg": (
                max(selected_road_transition_yaw_deg)
                if selected_road_transition_yaw_deg
                else None
            ),
            "median_selected_correction_m": statistics.median(corrections_m),
            "maximum_selected_correction_m": max(corrections_m),
            "maximum_adjacent_correction_delta_m": max(continuity_m, default=0.0),
            "maximum_adjacent_correction_delta_yaw_deg": max(
                continuity_yaw_deg, default=0.0
            ),
            "maximum_adjacent_correction_translation_gradient": max(
                continuity_translation_gradient, default=0.0
            ),
            "maximum_adjacent_correction_yaw_gradient_deg_per_m": max(
                continuity_yaw_gradient_deg_per_m, default=0.0
            ),
            "continuity_thresholds": {
                "authority": "gauge_neutral_gradient_v1",
                "translation_gradient_max_m_per_m": 1.0,
                "yaw_gradient_max_deg_per_m": 8.0,
                "absolute_delta_is_audit_only": True,
            },
            "sequence_unique": sequence_unique,
            "geometry_supported": geometry_supported,
            "continuity_supported": continuity_supported,
            "diagnostic_alignment_supported": (
                sequence_unique and geometry_supported and continuity_supported
            ),
        },
        "windows": window_records,
        "blockers": [
            *(
                []
                if sequence_unique
                else ["structure_window_sequence_ambiguous"]
            ),
            *(
                []
                if geometry_supported
                else ["structure_window_geometry_weak"]
            ),
            *(
                []
                if continuity_supported
                else ["structure_window_correction_discontinuous"]
            ),
            "structure_coverage_not_bound_by_localized_input_manifest",
        ],
    }


def _candidate_payload(candidate: AlignmentCandidate) -> dict[str, Any]:
    return {
        "correction_x_m": candidate.correction.x,
        "correction_y_m": candidate.correction.y,
        "correction_yaw_deg": math.degrees(candidate.correction.yaw),
        "geometry_cost": candidate.geometry_cost,
        "outside_ratio": candidate.outside_ratio,
        "road_distance_m": candidate.road_distance_m,
        "road_yaws_deg": [
            math.degrees(value) for value in candidate.road_yaws_rad
        ],
        "road_edge_index": candidate.road_edge_index,
        "road_edge_fraction": candidate.road_edge_fraction,
        "map_position_m": (
            None
            if candidate.map_x is None or candidate.map_y is None
            else [candidate.map_x, candidate.map_y]
        ),
        "observation_cost": _candidate_observation_cost(candidate),
    }


def write_diagnostic_report(
    output: Path,
    *,
    prior_map: Path,
    segment: Path,
    floor_id: str,
    **parameters: Any,
) -> dict[str, Any]:
    report = diagnostic_report(
        prior_map=prior_map,
        segment=segment,
        floor_id=floor_id,
        **parameters,
    )
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(
        json.dumps(
            report,
            ensure_ascii=False,
            indent=2,
            sort_keys=True,
            allow_nan=False,
        )
        + "\n",
        encoding="utf-8",
    )
    return report
