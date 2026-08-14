#!/usr/bin/env python3
"""Strict, bounded analysis of iPhone scan performance evidence.

The phone writes one JSON object per line to ``performance_samples.jsonl``.
This module validates the framing and identity of that evidence, computes a
bounded deterministic trend summary, and can publish the original bytes plus
PC-friendly CSV/JSON artifacts into a map result package.

The parser never loads the JSONL file or all decoded records into memory.
Exact extrema/means are accumulated online; percentile samples and the browser
series are deterministically compacted so multi-day captures remain bounded.
"""

from __future__ import annotations

import csv
import hashlib
import json
import math
import os
import shutil
import stat
import tempfile
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, BinaryIO, Dict, Iterable, Optional, TextIO

from PriorMap.generated_mobile_evidence_contracts import (
    MOBILE_EVIDENCE_CONTRACTS,
)
from PriorMap.strict_json import (
    json_nesting_depth,
    reject_duplicate_object_pairs,
)


PERFORMANCE_FILE_NAME = "performance_samples.jsonl"
SUMMARY_FILE_NAME = "phone_performance_summary.json"
CSV_FILE_NAME = "phone_performance_samples.csv"
RAW_FILE_NAME = "phone_performance_samples.jsonl"
INVALID_RAW_FILE_NAME = "phone_performance_samples.invalid.jsonl"
_PERFORMANCE_CONTRACT = MOBILE_EVIDENCE_CONTRACTS[PERFORMANCE_FILE_NAME]
MAXIMUM_FILE_BYTES = int(_PERFORMANCE_CONTRACT["max_file_bytes"])
MAXIMUM_RECORD_BYTES = int(_PERFORMANCE_CONTRACT["max_record_bytes"])
MAXIMUM_RECORDS = int(_PERFORMANCE_CONTRACT["max_records"])
MAXIMUM_BROWSER_SERIES = 720
MAXIMUM_QUANTILE_SAMPLES = 20_000
MAXIMUM_DIAGNOSTIC_FILE_BYTES = 8 * 1024 * 1024
MAXIMUM_METADATA_FILE_BYTES = 1024 * 1024
MAXIMUM_NESTING_DEPTH = int(_PERFORMANCE_CONTRACT["max_nesting_depth"])

REQUIRED_SAMPLE_FIELDS = frozenset(
    {
        "format",
        "version",
        "sequence",
        "timestamp_unix",
        "process_uptime_seconds",
        "tracking_session_id",
        "scan_state",
        "tracking_state",
        "thermal_state",
        "gpu_metric_status",
    }
)
OPTIONAL_SAMPLE_FIELDS = frozenset(
    {
        "node_count",
        "database_memory_mb",
        "database_bytes",
        "scan_storage_bytes",
        "process_memory_footprint_mb",
        "available_memory_mb",
        "process_cpu_time_seconds",
        "process_cpu_percent",
        "battery_percent",
        "battery_charging",
        "available_disk_bytes",
        "rendering_fps",
        "rtabmap_update_time_ms",
        "word_count",
        "feature_count",
        "point_count",
        "polygon_count",
        "online_loop_closure_count",
        "reliable_loop_closure_count",
        "gpu_utilization_percent",
    }
)
ALLOWED_SAMPLE_FIELDS = REQUIRED_SAMPLE_FIELDS | OPTIONAL_SAMPLE_FIELDS
ALLOWED_SCAN_STATES = frozenset({"mapping", "finalizing"})
ALLOWED_THERMAL_STATES = frozenset(
    {"nominal", "fair", "serious", "critical", "unknown"}
)
GPU_UNAVAILABLE_STATUS = "not_available_public_ios_api"

CSV_FIELDS = (
    "sequence",
    "timestamp_unix",
    "process_uptime_seconds",
    "scan_state",
    "tracking_state",
    "node_count",
    "database_memory_mb",
    "database_bytes",
    "scan_storage_bytes",
    "process_memory_footprint_mb",
    "available_memory_mb",
    "process_cpu_time_seconds",
    "process_cpu_percent",
    "thermal_state",
    "battery_percent",
    "battery_charging",
    "available_disk_bytes",
    "rendering_fps",
    "rtabmap_update_time_ms",
    "word_count",
    "feature_count",
    "point_count",
    "polygon_count",
    "online_loop_closure_count",
    "reliable_loop_closure_count",
    "gpu_metric_status",
    "gpu_utilization_percent",
)

SERIES_FIELDS = (
    "sequence",
    "timestamp_unix",
    "process_cpu_percent",
    "process_memory_footprint_mb",
    "available_memory_mb",
    "available_disk_bytes",
    "database_bytes",
    "scan_storage_bytes",
    "rendering_fps",
    "rtabmap_update_time_ms",
    "node_count",
    "battery_percent",
    "thermal_state",
)


class PerformanceEvidenceError(ValueError):
    """Raised when authoritative performance evidence is malformed."""


def _reject_json_constant(value: str) -> None:
    raise PerformanceEvidenceError(f"non-finite JSON constant is forbidden: {value}")


def _finite_number(
    value: Any,
    name: str,
    *,
    minimum: Optional[float] = None,
    maximum: Optional[float] = None,
) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise PerformanceEvidenceError(f"{name} must be a finite number")
    result = float(value)
    if not math.isfinite(result):
        raise PerformanceEvidenceError(f"{name} must be finite")
    if minimum is not None and result < minimum:
        raise PerformanceEvidenceError(f"{name} must be >= {minimum}")
    if maximum is not None and result > maximum:
        raise PerformanceEvidenceError(f"{name} must be <= {maximum}")
    return result


def _optional_number(
    value: Any,
    name: str,
    *,
    minimum: Optional[float] = None,
    maximum: Optional[float] = None,
) -> Optional[float]:
    if value is None:
        return None
    return _finite_number(value, name, minimum=minimum, maximum=maximum)


def _integer(value: Any, name: str, *, minimum: int = 0) -> int:
    number = _finite_number(value, name, minimum=float(minimum))
    integer = int(number)
    if float(integer) != number:
        raise PerformanceEvidenceError(f"{name} must be an integer")
    return integer


def _optional_integer(value: Any, name: str, *, minimum: int = 0) -> Optional[int]:
    if value is None:
        return None
    return _integer(value, name, minimum=minimum)


def _string(value: Any, name: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise PerformanceEvidenceError(f"{name} must be a non-empty string")
    return value


@dataclass
class _BoundedMetric:
    first: Optional[float] = None
    last: Optional[float] = None
    minimum: Optional[float] = None
    maximum: Optional[float] = None
    total: float = 0.0
    count: int = 0
    samples: list[float] = field(default_factory=list)
    stride: int = 1
    input_count: int = 0

    def add(self, value: Optional[float]) -> None:
        if value is None:
            return
        if self.first is None:
            self.first = value
        self.last = value
        self.minimum = value if self.minimum is None else min(self.minimum, value)
        self.maximum = value if self.maximum is None else max(self.maximum, value)
        self.total += value
        self.count += 1
        self.input_count += 1
        if self.input_count % self.stride == 0:
            self.samples.append(value)
        if len(self.samples) >= MAXIMUM_QUANTILE_SAMPLES:
            self.samples = self.samples[::2]
            self.stride *= 2

    def percentile(self, fraction: float) -> Optional[float]:
        if not self.samples:
            return None
        values = sorted(self.samples)
        if len(values) == 1:
            return values[0]
        index = max(0.0, min(1.0, fraction)) * (len(values) - 1)
        lower = int(math.floor(index))
        upper = int(math.ceil(index))
        if lower == upper:
            return values[lower]
        weight = index - lower
        return values[lower] * (1.0 - weight) + values[upper] * weight

    def summary(self, percentiles: Iterable[tuple[str, float]]) -> Dict[str, Any]:
        if self.count == 0:
            return {"available": False, "sample_count": 0}
        result: Dict[str, Any] = {
            "available": True,
            "sample_count": self.count,
            "first": self.first,
            "last": self.last,
            "min": self.minimum,
            "max": self.maximum,
            "mean": self.total / self.count,
            "quantiles_exact": self.count <= MAXIMUM_QUANTILE_SAMPLES,
            "quantile_sample_count": len(self.samples),
        }
        for label, fraction in percentiles:
            result[label] = self.percentile(fraction)
        return result


@dataclass
class _BoundedSeries:
    limit: int
    rows: list[Dict[str, Any]] = field(default_factory=list)
    stride: int = 1
    input_count: int = 0

    def add(self, row: Dict[str, Any]) -> None:
        self.input_count += 1
        if self.input_count % self.stride == 0:
            self.rows.append({key: row.get(key) for key in SERIES_FIELDS})
        if len(self.rows) >= self.limit:
            self.rows = self.rows[::2]
            self.stride *= 2


def _metric_payload(record: Dict[str, Any], name: str) -> Optional[float]:
    return _optional_number(record.get(name), name, minimum=0.0)


def _metadata_for_segment(segment: Path) -> Dict[str, Any]:
    path = segment / "metadata.json"
    handle, before = _open_stable_regular_file(
        path,
        maximum_bytes=MAXIMUM_METADATA_FILE_BYTES,
    )
    try:
        data = handle.read(MAXIMUM_METADATA_FILE_BYTES + 1)
        after_descriptor = os.fstat(handle.fileno())
    finally:
        handle.close()
    after_path = os.lstat(path)
    stable_fields = ("st_dev", "st_ino", "st_mode", "st_nlink", "st_size", "st_mtime_ns")
    if len(data) > MAXIMUM_METADATA_FILE_BYTES or len(data) != before.st_size:
        raise PerformanceEvidenceError("metadata.json is oversized or changed during read")
    if any(getattr(before, name) != getattr(after_descriptor, name) for name in stable_fields) or any(
        getattr(before, name) != getattr(after_path, name) for name in stable_fields
    ):
        raise PerformanceEvidenceError("metadata.json changed during performance analysis")
    try:
        payload = json.loads(
            data.decode("utf-8", errors="strict"),
            parse_constant=_reject_json_constant,
            object_pairs_hook=reject_duplicate_object_pairs,
        )
    except (UnicodeDecodeError, json.JSONDecodeError, ValueError, RecursionError) as exc:
        raise PerformanceEvidenceError(f"metadata.json is not strict JSON: {exc}") from exc
    if not isinstance(payload, dict):
        raise PerformanceEvidenceError("metadata.json must contain an object")
    if payload.get("performanceSamples") != PERFORMANCE_FILE_NAME:
        raise PerformanceEvidenceError("metadata does not declare performance_samples.jsonl")
    tracking_id = _string(payload.get("trackingSessionId"), "trackingSessionId")
    interval = _finite_number(
        payload.get("performanceSampleIntervalSeconds"),
        "performanceSampleIntervalSeconds",
        minimum=1.0,
        maximum=300.0,
    )
    count = _integer(payload.get("performanceSampleCount"), "performanceSampleCount")
    complete = payload.get("performanceEvidenceComplete")
    if not isinstance(complete, bool):
        raise PerformanceEvidenceError("performanceEvidenceComplete must be boolean")
    write_failures = _integer(
        payload.get("performanceWriteFailureCount"),
        "performanceWriteFailureCount",
    )
    last_sequence = payload.get("performanceLastSequence")
    last_timestamp = payload.get("performanceLastTimestampUnix")
    if count == 0:
        if last_sequence is not None or last_timestamp is not None or complete:
            raise PerformanceEvidenceError("empty performance metadata has invalid watermarks")
    else:
        if _integer(last_sequence, "performanceLastSequence", minimum=1) != count:
            raise PerformanceEvidenceError("performance last sequence must equal sample count")
        _finite_number(
            last_timestamp,
            "performanceLastTimestampUnix",
            minimum=1.0,
        )
    if complete and (count == 0 or write_failures != 0):
        raise PerformanceEvidenceError(
            "complete performance metadata conflicts with count/write failures"
        )
    payload["trackingSessionId"] = tracking_id
    payload["performanceSampleIntervalSeconds"] = interval
    payload["performanceSampleCount"] = count
    payload["performanceWriteFailureCount"] = write_failures
    return payload


class _PerformanceAccumulator:
    def __init__(
        self,
        *,
        expected_tracking_session_id: Optional[str],
        expected_count: Optional[int],
        expected_last_sequence: Optional[int],
        expected_last_timestamp: Optional[float],
        expected_complete: Optional[bool],
        expected_interval: float,
        expected_write_failure_count: int,
        series_limit: int,
    ) -> None:
        self.expected_tracking_session_id = expected_tracking_session_id
        self.expected_count = expected_count
        self.expected_last_sequence = expected_last_sequence
        self.expected_last_timestamp = expected_last_timestamp
        self.expected_complete = expected_complete
        self.expected_interval = expected_interval
        self.expected_write_failure_count = expected_write_failure_count
        self.tracking_session_id: Optional[str] = None
        self.count = 0
        self.last_sequence = 0
        self.first_timestamp: Optional[float] = None
        self.last_timestamp: Optional[float] = None
        self.previous_timestamp: Optional[float] = None
        self.previous_uptime: Optional[float] = None
        self.last_scan_state: Optional[str] = None
        self.gap_threshold = max(15.0, expected_interval * 3.0)
        self.gaps_over_threshold = 0
        self.metrics = {
            name: _BoundedMetric()
            for name in (
                "process_cpu_percent",
                "process_memory_footprint_mb",
                "available_memory_mb",
                "available_disk_bytes",
                "database_bytes",
                "scan_storage_bytes",
                "rendering_fps",
                "rtabmap_update_time_ms",
                "node_count",
                "battery_percent",
            )
        }
        self.gaps = _BoundedMetric()
        self.series = _BoundedSeries(max(8, min(MAXIMUM_BROWSER_SERIES, series_limit)))
        self.thermal_counts: Dict[str, int] = {}
        self.thermal_seconds: Dict[str, float] = {}
        self.previous_thermal: Optional[str] = None
        self.charging_samples = 0
        self.gpu_statuses: set[str] = set()
        self.worst: Dict[str, Dict[str, Any]] = {}

    def _update_worst(
        self,
        key: str,
        value: Optional[float],
        record: Dict[str, Any],
        *,
        prefer_lower: bool = False,
    ) -> None:
        if value is None:
            return
        existing = self.worst.get(key)
        if existing is not None:
            old = float(existing["value"])
            if (prefer_lower and value >= old) or (not prefer_lower and value <= old):
                return
        self.worst[key] = {
            "value": value,
            "sequence": record["sequence"],
            "timestamp_unix": record["timestamp_unix"],
        }

    def add(self, raw: Dict[str, Any]) -> Dict[str, Any]:
        if self.last_scan_state == "finalizing":
            raise PerformanceEvidenceError("finalizing performance sample must be terminal")
        unknown = set(raw) - ALLOWED_SAMPLE_FIELDS
        missing = REQUIRED_SAMPLE_FIELDS - set(raw)
        if unknown:
            raise PerformanceEvidenceError(
                "unknown performance sample fields: " + ", ".join(sorted(unknown))
            )
        if missing:
            raise PerformanceEvidenceError(
                "missing performance sample fields: " + ", ".join(sorted(missing))
            )
        if json_nesting_depth(raw) > MAXIMUM_NESTING_DEPTH:
            raise PerformanceEvidenceError("performance sample nesting exceeds the limit")
        if raw.get("format") != "MarketScannerPerformanceSample":
            raise PerformanceEvidenceError("performance sample format is invalid")
        if _integer(raw.get("version"), "version", minimum=1) != 1:
            raise PerformanceEvidenceError("unsupported performance sample version")
        sequence = _integer(raw.get("sequence"), "sequence", minimum=1)
        if sequence != self.last_sequence + 1:
            raise PerformanceEvidenceError(
                f"sequence discontinuity: expected {self.last_sequence + 1}, got {sequence}"
            )
        timestamp = _finite_number(raw.get("timestamp_unix"), "timestamp_unix", minimum=1.0)
        uptime = _finite_number(
            raw.get("process_uptime_seconds"), "process_uptime_seconds", minimum=0.0
        )
        tracking_id = _string(raw.get("tracking_session_id"), "tracking_session_id")
        if self.tracking_session_id is None:
            self.tracking_session_id = tracking_id
        elif tracking_id != self.tracking_session_id:
            raise PerformanceEvidenceError("tracking_session_id changed inside performance evidence")
        if self.expected_tracking_session_id and tracking_id != self.expected_tracking_session_id:
            raise PerformanceEvidenceError("performance tracking identity differs from metadata")
        scan_state = _string(raw.get("scan_state"), "scan_state")
        if scan_state not in ALLOWED_SCAN_STATES:
            raise PerformanceEvidenceError("scan_state is unsupported")
        tracking_state = _string(raw.get("tracking_state"), "tracking_state")
        thermal = _string(raw.get("thermal_state"), "thermal_state")
        if thermal not in ALLOWED_THERMAL_STATES:
            raise PerformanceEvidenceError("thermal_state is unsupported")
        gpu_status = _string(raw.get("gpu_metric_status"), "gpu_metric_status")
        if gpu_status != GPU_UNAVAILABLE_STATUS or raw.get("gpu_utilization_percent") is not None:
            raise PerformanceEvidenceError(
                "iOS GPU utilization must remain unavailable under the v1 contract"
            )

        record: Dict[str, Any] = {
            "sequence": sequence,
            "timestamp_unix": timestamp,
            "process_uptime_seconds": uptime,
            "scan_state": scan_state,
            "tracking_state": tracking_state,
            "thermal_state": thermal,
            "gpu_metric_status": gpu_status,
        }
        for name in (
            "node_count",
            "database_memory_mb",
            "database_bytes",
            "scan_storage_bytes",
            "word_count",
            "feature_count",
            "point_count",
            "polygon_count",
            "online_loop_closure_count",
            "reliable_loop_closure_count",
        ):
            record[name] = _optional_integer(raw.get(name), name, minimum=0)
        for name in (
            "process_memory_footprint_mb",
            "available_memory_mb",
            "process_cpu_time_seconds",
            "process_cpu_percent",
            "available_disk_bytes",
            "rendering_fps",
            "rtabmap_update_time_ms",
        ):
            record[name] = _optional_number(raw.get(name), name, minimum=0.0)
        record["battery_percent"] = _optional_number(
            raw.get("battery_percent"),
            "battery_percent",
            minimum=0.0,
            maximum=100.0,
        )
        record["gpu_utilization_percent"] = None
        charging = raw.get("battery_charging")
        if charging is not None and not isinstance(charging, bool):
            raise PerformanceEvidenceError("battery_charging must be boolean or null")
        record["battery_charging"] = charging

        if self.previous_timestamp is not None:
            if timestamp <= self.previous_timestamp:
                raise PerformanceEvidenceError("timestamps must be strictly increasing")
            gap = timestamp - self.previous_timestamp
            self.gaps.add(gap)
            if gap > self.gap_threshold:
                self.gaps_over_threshold += 1
            if self.previous_thermal is not None:
                self.thermal_seconds[self.previous_thermal] = (
                    self.thermal_seconds.get(self.previous_thermal, 0.0) + gap
                )
        else:
            self.first_timestamp = timestamp
        if self.previous_uptime is not None and uptime <= self.previous_uptime:
            raise PerformanceEvidenceError("process uptime must be strictly increasing")
        self.previous_timestamp = timestamp
        self.previous_uptime = uptime
        self.last_timestamp = timestamp
        self.last_scan_state = scan_state
        self.last_sequence = sequence
        self.count += 1
        self.thermal_counts[thermal] = self.thermal_counts.get(thermal, 0) + 1
        self.previous_thermal = thermal
        if charging is True:
            self.charging_samples += 1
        self.gpu_statuses.add(gpu_status)

        for name, metric in self.metrics.items():
            value = _metric_payload(record, name)
            metric.add(value)
        self._update_worst("highest_cpu_percent", record["process_cpu_percent"], record)
        self._update_worst(
            "highest_memory_footprint_mb", record["process_memory_footprint_mb"], record
        )
        self._update_worst(
            "lowest_rendering_fps", record["rendering_fps"], record, prefer_lower=True
        )
        self._update_worst(
            "highest_rtabmap_update_time_ms", record["rtabmap_update_time_ms"], record
        )
        self._update_worst(
            "lowest_available_memory_mb", record["available_memory_mb"], record, prefer_lower=True
        )
        self.series.add(record)
        return record

    def finish(self, *, source_sha256: str, source_bytes: int) -> Dict[str, Any]:
        if self.expected_count is not None and self.count != self.expected_count:
            raise PerformanceEvidenceError(
                f"metadata sample count {self.expected_count} != parsed count {self.count}"
            )
        if self.expected_last_sequence is not None and self.last_sequence != self.expected_last_sequence:
            raise PerformanceEvidenceError("metadata last sequence differs from performance evidence")
        if self.expected_last_timestamp is not None:
            if self.last_timestamp is None or abs(self.last_timestamp - self.expected_last_timestamp) > 1e-6:
                raise PerformanceEvidenceError("metadata last timestamp differs from performance evidence")
        if self.expected_complete is True and self.last_scan_state != "finalizing":
            raise PerformanceEvidenceError(
                "complete performance evidence must end with a finalizing sample"
            )

        duration = (
            max(0.0, self.last_timestamp - self.first_timestamp)
            if self.first_timestamp is not None and self.last_timestamp is not None
            else 0.0
        )
        gap_summary = self.gaps.summary((("p50", 0.50), ("p95", 0.95), ("p99", 0.99)))
        gap_threshold = self.gap_threshold
        gaps_over_threshold = self.gaps_over_threshold

        metrics = {
            "process_cpu_percent": self.metrics["process_cpu_percent"].summary(
                (("p50", 0.50), ("p95", 0.95))
            ),
            "process_memory_footprint_mb": self.metrics[
                "process_memory_footprint_mb"
            ].summary((("p50", 0.50), ("p95", 0.95))),
            "available_memory_mb": self.metrics["available_memory_mb"].summary(
                (("p05", 0.05), ("p50", 0.50))
            ),
            "available_disk_bytes": self.metrics["available_disk_bytes"].summary(
                (("p05", 0.05),)
            ),
            "database_bytes": self.metrics["database_bytes"].summary(()),
            "scan_storage_bytes": self.metrics["scan_storage_bytes"].summary(()),
            "rendering_fps": self.metrics["rendering_fps"].summary(
                (("p05", 0.05), ("p50", 0.50))
            ),
            "rtabmap_update_time_ms": self.metrics["rtabmap_update_time_ms"].summary(
                (("p50", 0.50), ("p95", 0.95))
            ),
            "node_count": self.metrics["node_count"].summary(()),
            "battery_percent": self.metrics["battery_percent"].summary(
                (("p05", 0.05),)
            ),
        }
        for name in ("database_bytes", "scan_storage_bytes"):
            metric = metrics[name]
            if metric.get("available"):
                growth = float(metric["last"]) - float(metric["first"])
                metric["growth"] = growth
                metric["growth_bytes_per_minute"] = (
                    growth / (duration / 60.0) if duration > 0 else 0.0
                )
        node_metric = metrics["node_count"]
        if node_metric.get("available"):
            growth = float(node_metric["last"]) - float(node_metric["first"])
            node_metric["growth"] = growth
            node_metric["nodes_per_minute"] = (
                growth / (duration / 60.0) if duration > 0 else 0.0
            )
        battery_metric = metrics["battery_percent"]
        if battery_metric.get("available"):
            battery_metric["drop_percent"] = max(
                0.0, float(battery_metric["first"]) - float(battery_metric["last"])
            )

        warnings: list[str] = []
        if self.expected_complete is not True:
            warnings.append("phone_metadata_did_not_mark_performance_evidence_complete")
        if self.expected_write_failure_count:
            warnings.append("phone_performance_writer_reported_failures")
        if gaps_over_threshold:
            warnings.append("performance_sampling_gaps_detected")
        if self.thermal_counts.get("serious", 0) or self.thermal_counts.get("critical", 0):
            warnings.append("serious_or_critical_thermal_samples_detected")
        if self.count == 0:
            warnings.append("performance_evidence_empty")

        return {
            "format": "MarketScannerPhonePerformanceSummary",
            "version": 1,
            "available": True,
            "validated": True,
            "performance_qualified": self.expected_complete is True and not warnings,
            "tracking_session_id": self.tracking_session_id,
            "source": {
                "file": PERFORMANCE_FILE_NAME,
                "bytes": source_bytes,
                "sha256": source_sha256,
                "metadata_evidence_complete": self.expected_complete,
                "metadata_write_failure_count": self.expected_write_failure_count,
                "sample_interval_seconds": self.expected_interval,
                "gpu_metric_statuses": sorted(self.gpu_statuses),
            },
            "sample_count": self.count,
            "first_sequence": 1 if self.count else None,
            "last_sequence": self.last_sequence if self.count else None,
            "first_timestamp_unix": self.first_timestamp,
            "last_timestamp_unix": self.last_timestamp,
            "duration_seconds": duration,
            "cadence_seconds": {
                **gap_summary,
                "gap_threshold": gap_threshold,
                "gaps_over_threshold": gaps_over_threshold,
            },
            "thermal": {
                "sample_counts": dict(sorted(self.thermal_counts.items())),
                "estimated_seconds": {
                    key: round(value, 6)
                    for key, value in sorted(self.thermal_seconds.items())
                },
                "serious_or_critical_sample_count": self.thermal_counts.get("serious", 0)
                + self.thermal_counts.get("critical", 0),
            },
            "battery": {"charging_sample_count": self.charging_samples},
            "metrics": metrics,
            "worst_samples": self.worst,
            "measurement_availability": {
                name: bool(payload.get("available")) for name, payload in metrics.items()
            }
            | {
                "gpu_utilization_percent": self.metrics.get(
                    "gpu_utilization_percent", _BoundedMetric()
                ).count
                > 0,
            },
            "warnings": warnings,
            "series": self.series.rows,
            "series_stride": self.series.stride,
            "series_truncated": self.count > len(self.series.rows),
        }


def _watermarks(metadata: Dict[str, Any]) -> Dict[str, Any]:
    return {
        "tracking_session_id": metadata["trackingSessionId"],
        "count": metadata["performanceSampleCount"],
        "last_sequence": (
            _optional_integer(
                metadata.get("performanceLastSequence"),
                "performanceLastSequence",
                minimum=1,
            )
            if metadata.get("performanceLastSequence") is not None
            else None
        ),
        "last_timestamp": (
            _optional_number(
                metadata.get("performanceLastTimestampUnix"),
                "performanceLastTimestampUnix",
                minimum=1.0,
            )
            if metadata.get("performanceLastTimestampUnix") is not None
            else None
        ),
        "complete": metadata["performanceEvidenceComplete"],
        "interval": metadata["performanceSampleIntervalSeconds"],
        "write_failure_count": metadata["performanceWriteFailureCount"],
    }


def _open_stable_regular_file(
    path: Path,
    *,
    maximum_bytes: int = MAXIMUM_FILE_BYTES,
) -> tuple[BinaryIO, os.stat_result]:
    before = os.lstat(path)
    if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
        raise PerformanceEvidenceError("performance evidence must be one regular, single-link file")
    if before.st_size > maximum_bytes:
        raise PerformanceEvidenceError("performance evidence exceeds the file-size limit")
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_BINARY", 0)
    descriptor = os.open(path, flags)
    handle = os.fdopen(descriptor, "rb")
    opened = os.fstat(handle.fileno())
    if (before.st_dev, before.st_ino, before.st_size) != (
        opened.st_dev,
        opened.st_ino,
        opened.st_size,
    ):
        handle.close()
        raise PerformanceEvidenceError("performance evidence changed while opening")
    return handle, before


def _parse_file(
    path: Path,
    metadata: Dict[str, Any],
    *,
    series_limit: int,
    raw_output: Optional[BinaryIO] = None,
    csv_output: Optional[TextIO] = None,
) -> Dict[str, Any]:
    watermarks = _watermarks(metadata)
    accumulator = _PerformanceAccumulator(
        expected_tracking_session_id=watermarks["tracking_session_id"],
        expected_count=watermarks["count"],
        expected_last_sequence=watermarks["last_sequence"],
        expected_last_timestamp=watermarks["last_timestamp"],
        expected_complete=watermarks["complete"],
        expected_interval=watermarks["interval"],
        expected_write_failure_count=watermarks["write_failure_count"],
        series_limit=series_limit,
    )
    csv_writer = csv.DictWriter(csv_output, fieldnames=CSV_FIELDS) if csv_output else None
    if csv_writer:
        csv_writer.writeheader()
    hasher = hashlib.sha256()
    handle, before = _open_stable_regular_file(path)
    total_bytes = 0
    final_byte: Optional[int] = None
    try:
        for line_number, line in enumerate(handle, start=1):
            total_bytes += len(line)
            if len(line) > MAXIMUM_RECORD_BYTES:
                raise PerformanceEvidenceError(
                    f"line {line_number} exceeds the record-size limit"
                )
            if line_number > MAXIMUM_RECORDS:
                raise PerformanceEvidenceError("performance sample count exceeds the limit")
            if not line.endswith(b"\n"):
                raise PerformanceEvidenceError("performance JSONL must end every record with newline")
            if not line.strip():
                raise PerformanceEvidenceError(f"blank JSONL line at {line_number}")
            final_byte = line[-1]
            hasher.update(line)
            if raw_output is not None:
                raw_output.write(line)
            try:
                record = json.loads(
                    line,
                    parse_constant=_reject_json_constant,
                    object_pairs_hook=reject_duplicate_object_pairs,
                )
            except (UnicodeDecodeError, json.JSONDecodeError, ValueError, RecursionError) as exc:
                raise PerformanceEvidenceError(
                    f"invalid JSON on performance line {line_number}: {exc}"
                ) from exc
            if not isinstance(record, dict):
                raise PerformanceEvidenceError(
                    f"performance line {line_number} must contain an object"
                )
            normalized = accumulator.add(record)
            if csv_writer:
                csv_writer.writerow(
                    {
                        key: (
                            "true"
                            if normalized.get(key) is True
                            else "false"
                            if normalized.get(key) is False
                            else ""
                            if normalized.get(key) is None
                            else normalized.get(key)
                        )
                        for key in CSV_FIELDS
                    }
                )
        if before.st_size > 0 and final_byte != 0x0A:
            raise PerformanceEvidenceError("performance JSONL lacks a final newline")
        after_descriptor = os.fstat(handle.fileno())
    finally:
        handle.close()
    after_path = os.lstat(path)
    stable_fields = ("st_dev", "st_ino", "st_mode", "st_nlink", "st_size", "st_mtime_ns")
    if any(getattr(before, name) != getattr(after_descriptor, name) for name in stable_fields) or any(
        getattr(before, name) != getattr(after_path, name) for name in stable_fields
    ):
        raise PerformanceEvidenceError("performance evidence changed during analysis")
    return accumulator.finish(
        source_sha256=hasher.hexdigest(),
        source_bytes=total_bytes,
    )


def unavailable_summary(reason: str, files: Optional[list[str]] = None) -> Dict[str, Any]:
    return {
        "format": "MarketScannerPhonePerformanceSummary",
        "version": 1,
        "available": False,
        "validated": False,
        "performance_qualified": False,
        "reason": reason,
        "files": files or [],
        "warnings": [reason],
        "series": [],
    }


def analyze_session(session: Path, *, series_limit: int = MAXIMUM_BROWSER_SERIES) -> Dict[str, Any]:
    files = sorted(session.glob(f"segment_*/{PERFORMANCE_FILE_NAME}"))
    if not files:
        return unavailable_summary("performance_evidence_missing")
    if len(files) != 1:
        return unavailable_summary(
            "multiple_performance_evidence_files_not_supported_for_single_session",
            [path.relative_to(session).as_posix() for path in files],
        )
    path = files[0]
    try:
        metadata = _metadata_for_segment(path.parent)
        summary = _parse_file(path, metadata, series_limit=series_limit)
    except (OSError, PerformanceEvidenceError) as exc:
        return unavailable_summary(
            f"performance_evidence_invalid: {exc}",
            [path.relative_to(session).as_posix()],
        )
    summary["files"] = [path.relative_to(session).as_posix()]
    return summary


def _fsync_file(path: Path) -> None:
    with path.open("rb") as handle:
        os.fsync(handle.fileno())


def _fsync_directory(path: Path) -> None:
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _copy_forensic_raw(source: Path, destination: Path) -> Dict[str, Any]:
    """Preserve exact invalid evidence bytes without treating them as parsed."""

    hasher = hashlib.sha256()
    total = 0
    handle, before = _open_stable_regular_file(source)
    try:
        with destination.open("xb") as output:
            while True:
                chunk = handle.read(1024 * 1024)
                if not chunk:
                    break
                total += len(chunk)
                hasher.update(chunk)
                output.write(chunk)
            output.flush()
            os.fsync(output.fileno())
        after_descriptor = os.fstat(handle.fileno())
    finally:
        handle.close()
    after_path = os.lstat(source)
    stable_fields = ("st_dev", "st_ino", "st_mode", "st_nlink", "st_size", "st_mtime_ns")
    if any(getattr(before, name) != getattr(after_descriptor, name) for name in stable_fields) or any(
        getattr(before, name) != getattr(after_path, name) for name in stable_fields
    ):
        destination.unlink(missing_ok=True)
        raise PerformanceEvidenceError("invalid performance evidence changed during forensic copy")
    return {
        "file": INVALID_RAW_FILE_NAME,
        "bytes": total,
        "sha256": hasher.hexdigest(),
        "validated": False,
    }


def _copy_diagnostics(session: Path, destination: Path) -> list[Dict[str, Any]]:
    entries: list[Dict[str, Any]] = []
    diagnostic_files = sorted(session.glob("segment_*/metrickit_diagnostics*.jsonl"))
    if not diagnostic_files:
        return entries
    diagnostics_dir = destination / "diagnostics"
    diagnostics_dir.mkdir(parents=True, exist_ok=True)
    for index, source in enumerate(diagnostic_files, start=1):
        try:
            input_handle, source_stat = _open_stable_regular_file(
                source,
                maximum_bytes=MAXIMUM_DIAGNOSTIC_FILE_BYTES,
            )
        except (OSError, PerformanceEvidenceError):
            entries.append(
                {
                    "source": source.relative_to(session).as_posix(),
                    "copied": False,
                    "reason": "unsafe_or_oversized_diagnostic_file",
                }
            )
            continue
        name = f"metrickit_diagnostics_{index:03d}.jsonl"
        target = diagnostics_dir / name
        digest = hashlib.sha256()
        try:
            with target.open("xb") as output_handle:
                while True:
                    chunk = input_handle.read(1024 * 1024)
                    if not chunk:
                        break
                    digest.update(chunk)
                    output_handle.write(chunk)
                output_handle.flush()
                os.fsync(output_handle.fileno())
            after_descriptor = os.fstat(input_handle.fileno())
        finally:
            input_handle.close()
        after = os.lstat(source)
        stable_fields = ("st_dev", "st_ino", "st_mode", "st_nlink", "st_size", "st_mtime_ns")
        if any(
            getattr(source_stat, field) != getattr(after_descriptor, field)
            for field in stable_fields
        ) or any(
            getattr(source_stat, field) != getattr(after, field)
            for field in stable_fields
        ):
            target.unlink(missing_ok=True)
            raise PerformanceEvidenceError("MetricKit diagnostics changed during result packaging")
        entries.append(
            {
                "source": source.relative_to(session).as_posix(),
                "file": f"diagnostics/{name}",
                "bytes": source_stat.st_size,
                "sha256": digest.hexdigest(),
                "copied": True,
            }
        )
    if diagnostics_dir.exists():
        _fsync_directory(diagnostics_dir)
    return entries


def write_result_artifacts(
    session: Path,
    output: Path,
    *,
    namespace: str = "phone",
    series_limit: int = MAXIMUM_BROWSER_SERIES,
) -> Dict[str, Any]:
    """Validate and publish raw/CSV/summary evidence under ``output/performance``.

    ``namespace`` is a safe subdirectory for multi-device outputs. For the
    ordinary single-phone path it is ``phone``.
    """

    if not namespace or namespace in {".", ".."} or "/" in namespace or "\\" in namespace:
        raise PerformanceEvidenceError("performance namespace must be one safe basename")
    files = sorted(session.glob(f"segment_*/{PERFORMANCE_FILE_NAME}"))
    destination = output / "performance" / namespace
    destination.parent.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix=f".{namespace}-performance-", dir=destination.parent))
    try:
        if len(files) != 1:
            reason = (
                "performance_evidence_missing"
                if not files
                else "multiple_performance_evidence_files_not_supported_for_single_session"
            )
            summary = unavailable_summary(
                reason,
                [path.relative_to(session).as_posix() for path in files],
            )
        else:
            source = files[0]
            raw_path = staging / RAW_FILE_NAME
            csv_path = staging / CSV_FILE_NAME
            try:
                metadata = _metadata_for_segment(source.parent)
                with raw_path.open("xb") as raw_output, csv_path.open(
                    "x", encoding="utf-8", newline=""
                ) as csv_output:
                    summary = _parse_file(
                        source,
                        metadata,
                        series_limit=series_limit,
                        raw_output=raw_output,
                        csv_output=csv_output,
                    )
                    raw_output.flush()
                    os.fsync(raw_output.fileno())
                    csv_output.flush()
                    os.fsync(csv_output.fileno())
                summary["files"] = [source.relative_to(session).as_posix()]
                summary["result_artifacts"] = {
                    "raw_jsonl": RAW_FILE_NAME,
                    "csv": CSV_FILE_NAME,
                    "summary": SUMMARY_FILE_NAME,
                }
            except (OSError, PerformanceEvidenceError) as exc:
                raw_path.unlink(missing_ok=True)
                csv_path.unlink(missing_ok=True)
                forensic = _copy_forensic_raw(
                    source, staging / INVALID_RAW_FILE_NAME
                )
                summary = unavailable_summary(
                    f"performance_evidence_invalid: {exc}",
                    [source.relative_to(session).as_posix()],
                )
                summary["forensic_raw"] = forensic
                summary["result_artifacts"] = {
                    "invalid_raw_jsonl": INVALID_RAW_FILE_NAME,
                    "summary": SUMMARY_FILE_NAME,
                }
        summary["crash_diagnostics"] = _copy_diagnostics(session, staging)
        summary_path = staging / SUMMARY_FILE_NAME
        summary_path.write_text(
            json.dumps(summary, ensure_ascii=False, indent=2, allow_nan=False) + "\n",
            encoding="utf-8",
        )
        _fsync_file(summary_path)
        _fsync_directory(staging)
        if destination.exists():
            shutil.rmtree(destination)
        os.replace(staging, destination)
        _fsync_directory(destination.parent)
        return summary
    except Exception:
        shutil.rmtree(staging, ignore_errors=True)
        raise
