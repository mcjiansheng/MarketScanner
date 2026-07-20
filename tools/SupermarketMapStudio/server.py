#!/usr/bin/env python3
"""Dependency-light local visual workflow for supermarket map processing."""

from __future__ import annotations

import argparse
import json
import os
import platform
import subprocess
import sys
import tempfile
import threading
import time
import traceback
import uuid
import webbrowser
from collections import deque
from dataclasses import dataclass, field
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from types import SimpleNamespace
from typing import Any, Callable, Dict, List, Optional
from urllib.parse import unquote, urlparse


APP_DIR = Path(__file__).resolve().parent
WEB_DIR = APP_DIR / "web"
MAPPER_DIR = APP_DIR.parent / "Supermarket2DMap"
if str(MAPPER_DIR) not in sys.path:
    sys.path.insert(0, str(MAPPER_DIR))

import supermarket_2d_map as base
import supermarket_multi_device_map as multi
import supermarket_staged_map as staged
import offline_processing as offline
import gpu_acceleration as gpu


ARTIFACTS = (
    "preview.png",
    "occupancy_grid.png",
    "preview_layers.json",
    "preview_3d.json",
    "quality_report.json",
    "review_items.json",
    "map.json",
    "trajectory.geojson",
    "price_tags.geojson",
    "vector_map.geojson",
    "semantic_layers.json",
    "stage_manifest.json",
    "stage_quality_report.json",
    "multi_device_manifest.json",
    "alignment_config_used.json",
    "source_manifest.json",
    "offline_processing_report.json",
    "pc_acceleration_report.json",
)


class RequestError(ValueError):
    pass


@dataclass
class Job:
    identifier: str
    kind: str
    output_dir: Path
    created_at: float = field(default_factory=time.time)
    status: str = "queued"
    error: Optional[str] = None
    finished_at: Optional[float] = None
    progress: int = 0
    stage: str = "等待处理"
    updated_at: float = field(default_factory=time.time)
    logs: List[Dict[str, Any]] = field(default_factory=list)
    input_keys: tuple[str, ...] = field(default_factory=tuple)


class StudioState:
    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.jobs: Dict[str, Job] = {}

    def add(self, kind: str, output_dir: Path, input_keys: tuple[str, ...] = ()) -> Job:
        with self.lock:
            resolved = output_dir.resolve()
            normalized_inputs = tuple(sorted({str(Path(key).resolve()) for key in input_keys}))
            if any(
                existing.output_dir.resolve() == resolved and existing.status in {"queued", "running"}
                for existing in self.jobs.values()
            ):
                raise RequestError("This output directory is already reserved by a Map Studio task.")
            input_set = set(normalized_inputs)
            duplicate = next(
                (
                    existing
                    for existing in self.jobs.values()
                    if existing.status in {"queued", "running"}
                    and input_set.intersection(existing.input_keys)
                ),
                None,
            )
            if duplicate is not None:
                raise RequestError(
                    "This scan database is already being optimized by task "
                    f"{duplicate.identifier} ({duplicate.output_dir}). Reconnect to that task instead of starting a duplicate."
                )
            job = Job(
                identifier=uuid.uuid4().hex[:12],
                kind=kind,
                output_dir=output_dir,
                input_keys=normalized_inputs,
            )
            self.jobs[job.identifier] = job
        return job

    def get(self, job_id: str) -> Optional[Job]:
        with self.lock:
            return self.jobs.get(job_id)

    def active_for_input(self, input_key: str) -> Optional[Job]:
        normalized = str(Path(input_key).resolve())
        with self.lock:
            return next(
                (
                    job
                    for job in self.jobs.values()
                    if job.status in {"queued", "running"} and normalized in job.input_keys
                ),
                None,
            )

    def set_status(self, job_id: str, status: str, error: Optional[str] = None) -> None:
        with self.lock:
            job = self.jobs[job_id]
            job.status = status
            job.error = error
            job.updated_at = time.time()
            if status in {"complete", "failed"}:
                job.finished_at = time.time()
            if status == "complete":
                job.progress = 100
                job.stage = "处理完成"
            elif status == "failed":
                job.stage = "处理失败"

    def update_progress(self, job_id: str, progress: int, stage: str, message: str = "") -> None:
        with self.lock:
            job = self.jobs[job_id]
            job.progress = max(job.progress, min(99, max(0, int(progress))))
            job.stage = stage
            job.updated_at = time.time()
            if message:
                job.logs.append({
                    "timestamp": time.strftime("%Y-%m-%d %H:%M:%S"),
                    "progress": job.progress,
                    "stage": stage,
                    "message": message,
                })
                if len(job.logs) > 500:
                    del job.logs[:-500]

    def restore(self, kind: str, output_dir: Path) -> Job:
        with self.lock:
            resolved = output_dir.resolve()
            for existing in self.jobs.values():
                if existing.output_dir.resolve() == resolved and existing.status == "complete":
                    return existing
            timestamp = (resolved / "map.json").stat().st_mtime
            job = Job(
                identifier=uuid.uuid4().hex[:12],
                kind=kind,
                output_dir=resolved,
                created_at=timestamp,
                status="complete",
                finished_at=timestamp,
                progress=100,
                stage="处理完成",
                updated_at=timestamp,
            )
            self.jobs[job.identifier] = job
            return job


STATE = StudioState()
ProgressCallback = Callable[[int, str, str], None]


def report_progress(
    callback: Optional[ProgressCallback],
    progress: int,
    stage: str,
    message: str = "",
) -> None:
    if callback is not None:
        callback(progress, stage, message)


def resolve_path(raw: Any, label: str) -> Path:
    if not isinstance(raw, str) or not raw.strip():
        raise RequestError(f"{label} is required.")
    return Path(raw).expanduser().resolve()


def require_session(raw: Any) -> Path:
    path = resolve_path(raw, "Session directory")
    if not path.is_dir():
        raise RequestError(f"Session directory does not exist: {path}")
    if not list(path.glob("segment_*")):
        raise RequestError(f"No segment_* directories were found in: {path}")
    return path


def require_output(raw: Any) -> Path:
    path = resolve_path(raw, "Output directory")
    if path.exists() and not path.is_dir():
        raise RequestError(f"Output path is a file: {path}")
    if path.exists() and any(path.iterdir()):
        raise RequestError(f"Output directory must be empty: {path}")
    if not path.parent.is_dir():
        raise RequestError(f"Output parent directory does not exist: {path.parent}")
    return path


def optional_points(raw: Any) -> List[str]:
    if raw in (None, ""):
        return []
    if not isinstance(raw, list):
        raise RequestError("Projected point paths must be a list.")
    result: List[str] = []
    for value in raw:
        path = resolve_path(value, "Projected point file")
        if not path.is_file():
            raise RequestError(f"Projected point file does not exist: {path}")
        result.append(str(path))
    return result


def number(raw: Any, name: str, default: float) -> float:
    if raw in (None, ""):
        return default
    try:
        return float(raw)
    except (TypeError, ValueError) as exc:
        raise RequestError(f"{name} must be numeric.") from exc


def integer(raw: Any, name: str, default: int, minimum: int, maximum: int) -> int:
    if raw in (None, ""):
        return default
    try:
        value = int(raw)
    except (TypeError, ValueError) as exc:
        raise RequestError(f"{name} must be an integer.") from exc
    if value < minimum or value > maximum:
        raise RequestError(f"{name} must be between {minimum} and {maximum}.")
    return value


def boolean(raw: Any, default: bool = False) -> bool:
    if raw is None:
        return default
    if isinstance(raw, bool):
        return raw
    if isinstance(raw, (int, float)):
        return bool(raw)
    if isinstance(raw, str):
        normalized = raw.strip().lower()
        if normalized in {"1", "true", "yes", "on"}:
            return True
        if normalized in {"0", "false", "no", "off", ""}:
            return False
    raise RequestError("Boolean option is invalid.")


def map_options(data: Dict[str, Any]) -> Dict[str, Any]:
    options = data.get("options", {})
    if not isinstance(options, dict):
        raise RequestError("Options must be an object.")
    axes = options.get("horizontal_axes", "xz")
    if axes not in {"xz", "xy"}:
        raise RequestError("Horizontal axes must be xz or xy.")
    preview_3d_quality = str(
        options.get("preview_3d_quality", base.DEFAULT_PREVIEW_3D_QUALITY)
    )
    if preview_3d_quality not in base.PREVIEW_3D_PROFILES:
        raise RequestError("3D preview quality must be quick, detailed or maximum.")
    gpu_backend = str(options.get("gpu_backend") or "auto").strip()
    if gpu_backend not in gpu.BACKENDS:
        raise RequestError(f"GPU backend must be one of: {', '.join(gpu.BACKENDS)}")
    return {
        "resolution": number(options.get("resolution"), "Resolution", 0.05),
        "preview_resolution": number(options.get("preview_resolution"), "Preview resolution", 0.10),
        "trajectory_radius": number(options.get("trajectory_radius"), "Trajectory radius", 1.25),
        "tag_snap_distance": number(options.get("tag_snap_distance"), "Tag snap distance", 1.0),
        "occupied_inflate_radius": number(options.get("occupied_inflate_radius"), "Occupied inflation radius", 0.08),
        "free_ray_max_range": number(options.get("free_ray_max_range"), "Free ray maximum range", 8.0),
        "horizontal_axes": axes,
        "preview_3d_quality": preview_3d_quality,
        "offline_optimize": boolean(options.get("offline_optimize"), False),
        "reprocess_binary": str(options.get("reprocess_binary") or "").strip() or None,
        "pc_threads": integer(
            options.get("pc_threads"),
            "PC worker count",
            offline.DEFAULT_PC_THREADS,
            1,
            64,
        ),
        "pc_local_staging": boolean(options.get("pc_local_staging"), True),
        "gpu_backend": gpu_backend,
        "gpu_helper": str(options.get("gpu_helper") or "").strip() or None,
    }


def acceleration_selection(
    options: Dict[str, Any],
    progress: Optional[ProgressCallback] = None,
) -> gpu.BackendSelection:
    requested = options["gpu_backend"]
    if requested not in gpu.BACKENDS:
        raise RequestError(f"GPU backend must be one of: {', '.join(gpu.BACKENDS)}")
    try:
        selection = gpu.select_backend(requested, options["gpu_helper"])
    except gpu.GPUAccelerationError as exc:
        raise RequestError(str(exc)) from exc
    message = f"计算后端：{selection.effective}"
    if selection.device:
        message += f"（{selection.device}）"
    if selection.warnings:
        message += "；" + " ".join(selection.warnings)
    report_progress(progress, 6, "检测计算后端", message)
    return selection


def temporary_json(data: Any, prefix: str) -> Optional[Path]:
    if data in (None, "", {}):
        return None
    if isinstance(data, str):
        try:
            data = json.loads(data)
        except json.JSONDecodeError as exc:
            raise RequestError(f"Correction JSON is invalid: {exc}") from exc
    if not isinstance(data, dict):
        raise RequestError("Correction JSON must be an object.")
    handle = tempfile.NamedTemporaryFile(prefix=prefix, suffix=".json", mode="w", encoding="utf-8", delete=False)
    try:
        json.dump(data, handle, ensure_ascii=False, indent=2)
    finally:
        handle.close()
    return Path(handle.name)


def remove_temporary(path: Optional[Path]) -> None:
    if path is not None:
        path.unlink(missing_ok=True)


def job_artifacts(job: Job) -> Dict[str, str]:
    return {
        name: f"/api/jobs/{job.identifier}/artifact/{name}"
        for name in ARTIFACTS
        if (job.output_dir / name).is_file()
    }


def load_json(path: Path, default: Any) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return default


def job_payload(job: Job) -> Dict[str, Any]:
    payload: Dict[str, Any] = {
        "id": job.identifier,
        "kind": job.kind,
        "status": job.status,
        "output_dir": str(job.output_dir),
        "created_at": job.created_at,
        "finished_at": job.finished_at,
        "error": job.error,
        "progress": job.progress,
        "stage": job.stage,
        "updated_at": job.updated_at,
        "logs": list(job.logs),
        "input_keys": list(job.input_keys),
    }
    if job.status == "complete":
        payload["artifacts"] = job_artifacts(job)
        payload["quality_report"] = load_json(job.output_dir / "quality_report.json", {})
        payload["review_items"] = load_json(job.output_dir / "review_items.json", {"items": []})
        payload["map"] = load_json(job.output_dir / "map.json", {})
    return payload


def scan_event_logs(session: Path, limit: int = 1000) -> Dict[str, Any]:
    event_limit = max(1, int(limit))
    recent_events: deque[Dict[str, Any]] = deque(maxlen=event_limit)
    event_count = 0
    malformed_lines = 0
    files = sorted(session.glob("segment_*/scan_events.jsonl"))
    for path in files:
        try:
            handle = path.open("r", encoding="utf-8", errors="replace")
        except OSError:
            continue
        with handle:
            for line in handle:
                if not line.strip():
                    continue
                try:
                    event = json.loads(line)
                except json.JSONDecodeError:
                    malformed_lines += 1
                    continue
                if isinstance(event, dict):
                    event["source"] = str(path.relative_to(session))
                    event_count += 1
                    recent_events.append(event)
    events = sorted(recent_events, key=lambda item: float(item.get("timestampUnix", 0) or 0))
    return {
        "available": bool(files),
        "files": [str(path.relative_to(session)) for path in files],
        "event_count": event_count,
        "malformed_lines": malformed_lines,
        "events": events,
        "truncated": event_count > event_limit,
    }


def inspect_session(session: Path) -> Dict[str, Any]:
    config = base.MapConfig(0.05, 0.1, 1.25, 1.0, 0.08, 8.0, "xz", False)
    segments = base.discover_segments(session, config)
    input_scan = base.session_scan_summary(segments)
    binary = offline.find_reprocess_binary()
    active_job = STATE.active_for_input(str(session))
    return {
        "session": str(session),
        **input_scan,
        "segment_count": len(segments),
        "node_count": sum(len(segment.poses) for segment in segments),
        "price_tag_count": sum(len(segment.price_tags) for segment in segments),
        "segments": [
            {
                "index": segment.index,
                "database": str(segment.database_path) if segment.database_path else None,
                "nodes": len(segment.poses),
                "price_tags": len(segment.price_tags),
                "scan_mode": base.metadata_scan_mode(segment.metadata),
                "finalized": segment.metadata.get("finalized"),
                "warnings": segment.sqlite_warnings,
                "optimized_poses": sum(1 for pose in segment.poses if pose.source == "db_optimized"),
            }
            for segment in segments
        ],
        "pc_processing": {
            "recommended": input_scan["scan_mode"] == base.SCAN_MODE_CONTINUOUS_STREAMING,
            "reprocess_available": binary is not None,
            "reprocess_binary": str(binary) if binary else None,
            "uses_optimized_poses": any(
                pose.source == "db_optimized"
                for segment in segments
                for pose in segment.poses
            ),
        },
        "scan_logs": scan_event_logs(session),
        "active_job": job_payload(active_job) if active_job else None,
    }


def reprocess_single_session(
    session: Path,
    output: Path,
    explicit_binary: Optional[str],
    output_name: str,
    thread_count: int,
    use_local_staging: bool,
    acceleration: gpu.BackendSelection,
    progress: Optional[ProgressCallback] = None,
    progress_range: tuple[int, int] = (12, 68),
) -> tuple[Dict[int, str], Dict[str, Any]]:
    staging_label = "本机高速盘暂存" if use_local_staging else "直接在输出盘处理"
    report_progress(
        progress,
        progress_range[0],
        "PC 全局优化",
        f"开始校验并优化 {session.name}（{thread_count} 线程，{staging_label}）",
    )
    config = base.MapConfig(0.05, 0.1, 1.25, 1.0, 0.08, 8.0, "xz", False)
    segments = base.discover_segments(session, config)
    summary = base.session_scan_summary(segments)
    if len(segments) != 1 or segments[0].database_path is None:
        raise RequestError(
            "PC offline optimization currently requires one continuous database per device. "
            "Legacy segmented sessions must first be merged with their boundary metadata."
        )
    if (segments[0].directory / "live_checkpoint.json").is_file():
        raise RequestError(
            "This session still contains live_checkpoint.json and may have been copied while scanning. "
            "Finalize the scan on the iPhone before PC optimization."
        )
    if summary["finalized"] is False:
        raise RequestError("The phone database is still marked as unfinalized; finalize/copy it before PC processing.")
    optimized_dir = output / "rtabmap_optimized"
    optimized_database = optimized_dir / output_name

    def reprocess_progress(fraction: float, stage: str, message: str) -> None:
        start, end = progress_range
        mapped = start + round(max(0.0, min(1.0, fraction)) * (end - start))
        report_progress(progress, mapped, stage, message)

    report = offline.run_adaptive_reprocess(
        segments[0].database_path,
        optimized_database,
        explicit_binary=explicit_binary,
        thread_count=thread_count,
        use_local_staging=use_local_staging,
        accelerator_backend=acceleration.effective,
        extra_parameters=acceleration.rtabmap_parameters,
        progress_callback=reprocess_progress,
    )
    report["session"] = str(session)
    report["scan_mode"] = summary["scan_mode"]
    assessment = report.get("error_optimization", {})
    report_progress(
        progress,
        max(progress_range[0], progress_range[1] - 2),
        "验证轨迹误差",
        f"纯软件误差验证{assessment.get('status', 'unknown')}，质量分 {assessment.get('quality_score', 0)}/100",
    )
    report_progress(
        progress,
        progress_range[1],
        "PC 全局优化",
        f"{session.name} 优化完成，已生成新的优化数据库",
    )
    return {segments[0].index: str(optimized_database)}, report


def attach_offline_reports(output: Path, reports: List[Dict[str, Any]]) -> None:
    if not reports:
        return
    offline.write_report(output / "offline_processing_report.json", reports)
    assessments = [
        report.get("error_optimization", {})
        for report in reports
        if isinstance(report.get("error_optimization"), dict)
    ]
    assessment_warnings = [
        warning
        for assessment in assessments
        for warning in assessment.get("warnings", [])
    ]
    summary = {
        "enabled": True,
        "database_count": len(reports),
        "strategy": "software_only_vio_rgbd_loop_closure_and_robust_global_optimization",
        "fiducials_used": False,
        "landmark_constraints_used": False,
        "pose_priors_used": False,
        "execution": {
            "profile": offline.ADAPTIVE_PROFILE,
            "selected_pass_profiles": sorted(
                {
                    str(report.get("adaptive", {}).get("selected_pass", "unknown"))
                    for report in reports
                }
            ),
            "discovery_database_count": sum(
                1
                for report in reports
                if bool(report.get("adaptive", {}).get("discovery_required", False))
            ),
            "thread_count": max(
                (int(report.get("execution", {}).get("thread_count", 1)) for report in reports),
                default=1,
            ),
            "local_staging": all(
                bool(report.get("execution", {}).get("local_staging", False))
                for report in reports
            ),
        },
        "optimized_pose_count": sum(int(report["output"].get("optimized_pose_count", 0)) for report in reports),
        "error_optimization": {
            "profile": "software_only_no_fiducials",
            "status": "warning" if assessment_warnings else "pass",
            "quality_score": min(
                (int(assessment.get("quality_score", 0)) for assessment in assessments),
                default=0,
            ),
            "database_count": len(assessments),
            "warnings": assessment_warnings,
        },
    }
    for name in ("quality_report.json", "map.json"):
        path = output / name
        payload = load_json(path, {})
        if isinstance(payload, dict):
            payload["pc_offline_processing"] = summary
            if name == "quality_report.json" and assessment_warnings:
                existing_warnings = payload.get("warnings")
                if not isinstance(existing_warnings, list):
                    existing_warnings = []
                payload["warnings"] = existing_warnings + [
                    "PC error optimization: " + warning
                    for warning in assessment_warnings
                ]
            path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")


def attach_acceleration_report(
    output: Path,
    report: Dict[str, Any],
    offline_reports: Iterable[Dict[str, Any]] = (),
) -> None:
    rtabmap_cuda_fallback = any(
        bool(item.get("execution", {}).get("rtabmap_gpu_fallback_detected"))
        for item in offline_reports
    )
    report["rtabmap_gpu_fallback_detected"] = rtabmap_cuda_fallback
    if rtabmap_cuda_fallback:
        warnings = list(report.get("warnings", []))
        warning = "RTAB-Map CUDA feature extraction or matching was unavailable and fell back to CPU."
        if warning not in warnings:
            warnings.append(warning)
        report["warnings"] = warnings
    (output / "pc_acceleration_report.json").write_text(
        json.dumps(report, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    for name in ("quality_report.json", "map.json"):
        path = output / name
        payload = load_json(path, {})
        if isinstance(payload, dict):
            payload["pc_acceleration"] = report
            path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")


def find_existing_result(session: Path) -> Optional[Job]:
    required = ("map.json", "preview.png", "preview_3d.json", "quality_report.json")
    candidates = []
    for directory in session.iterdir():
        if not directory.is_dir() or not directory.name.startswith(("MapStudio-", "Map2D-", "StageMap2D-")):
            continue
        if not all((directory / name).is_file() for name in required):
            continue
        metadata = load_json(directory / "map.json", {})
        if metadata.get("format") not in {"SupermarketMap2D", "SupermarketStageMap2D"}:
            continue
        source_session = metadata.get("session")
        if source_session and Path(source_session).expanduser().resolve() != session.resolve():
            continue
        candidates.append(directory)
    if not candidates:
        return None
    latest = max(candidates, key=lambda path: (path / "map.json").stat().st_mtime)
    metadata = load_json(latest / "map.json", {})
    kind = "stage" if metadata.get("format") == "SupermarketStageMap2D" else "map"
    return STATE.restore(kind, latest)


def run_stage(data: Dict[str, Any], output: Path, progress: Optional[ProgressCallback] = None) -> None:
    report_progress(progress, 4, "检查输入", "正在读取扫描数据库和阶段配置")
    session = require_session(data.get("session"))
    options = map_options(data)
    acceleration = acceleration_selection(options, progress)
    config_path = temporary_json(data.get("stage_config"), "map-studio-stage-")
    try:
        reports: List[Dict[str, Any]] = []
        database_overrides: Dict[int, str] = {}
        if options["offline_optimize"]:
            database_overrides, report = reprocess_single_session(
                session,
                output,
                options["reprocess_binary"],
                "optimized.db",
                options["pc_threads"],
                options["pc_local_staging"],
                acceleration,
                progress,
            )
            reports.append(report)
        args = SimpleNamespace(
            session=str(session),
            stage_config=str(config_path) if config_path else None,
            output=str(output),
            points_csv=optional_points(data.get("points_csv")),
            database_overrides=database_overrides,
            **options,
        )
        report_progress(progress, 72, "生成阶段地图", f"正在用 {acceleration.effective} 投影结构、轨迹和扫描帧")
        with gpu.DepthProjector(acceleration) as projector:
            args.depth_projector = projector
            staged.generate(args)
            acceleration_report = projector.report()
        report_progress(progress, 94, "整理成果", "阶段地图已生成，正在写入质量报告")
        attach_offline_reports(output, reports)
        attach_acceleration_report(output, acceleration_report, reports)
        report_progress(progress, 98, "校验成果", "阶段地图成果文件已写入")
    finally:
        remove_temporary(config_path)


def run_basic_map(data: Dict[str, Any], output: Path, progress: Optional[ProgressCallback] = None) -> None:
    report_progress(progress, 4, "检查输入", "正在读取连续扫描数据库和元数据")
    session = require_session(data.get("session"))
    options = map_options(data)
    acceleration = acceleration_selection(options, progress)
    corrections_path = temporary_json(data.get("corrections"), "map-studio-corrections-")
    try:
        reports: List[Dict[str, Any]] = []
        database_overrides: Dict[int, str] = {}
        if options["offline_optimize"]:
            database_overrides, report = reprocess_single_session(
                session,
                output,
                options["reprocess_binary"],
                "optimized.db",
                options["pc_threads"],
                options["pc_local_staging"],
                acceleration,
                progress,
            )
            reports.append(report)
        args = SimpleNamespace(
            session=str(session),
            output=str(output),
            points_csv=optional_points(data.get("points_csv")),
            corrections=str(corrections_path) if corrections_path else None,
            auto_align_segments=bool(data.get("auto_align_segments", False)),
            database_overrides=database_overrides,
            **options,
        )
        report_progress(progress, 72, "生成地图", f"正在用 {acceleration.effective} 生成二维结构图和彩色三维预览")
        with gpu.DepthProjector(acceleration) as projector:
            args.depth_projector = projector
            base.generate(args)
            acceleration_report = projector.report()
        report_progress(progress, 94, "整理成果", "地图已生成，正在写入质量报告和清单")
        attach_offline_reports(output, reports)
        attach_acceleration_report(output, acceleration_report, reports)
        report_progress(progress, 98, "校验成果", "地图成果文件已写入")
    finally:
        remove_temporary(corrections_path)


def run_multi(data: Dict[str, Any], output: Path, progress: Optional[ProgressCallback] = None) -> None:
    raw_devices = data.get("devices")
    if not isinstance(raw_devices, list) or len(raw_devices) < 2:
        raise RequestError("At least two device sessions are required.")
    devices = []
    reports: List[Dict[str, Any]] = []
    options = map_options(data)
    report_progress(progress, 4, "检查多设备输入", f"正在检查 {len(raw_devices)} 个设备会话")
    acceleration = acceleration_selection(options, progress)
    for index, raw_device in enumerate(raw_devices, start=1):
        if not isinstance(raw_device, dict):
            raise RequestError("Each device entry must be an object.")
        session = require_session(raw_device.get("session"))
        device_id = str(raw_device.get("id") or f"device_{index}").strip()
        if not device_id:
            raise RequestError("Each device needs an ID.")
        transform = {
            "dx": number(raw_device.get("dx"), f"{device_id} dx", 0.0),
            "dy": number(raw_device.get("dy"), f"{device_id} dy", 0.0),
            "yaw_deg": number(raw_device.get("yaw_deg"), f"{device_id} yaw", 0.0),
        }
        device: Dict[str, Any] = {"id": device_id, "session": str(session)}
        if any(abs(value) > 1e-12 for value in transform.values()):
            device["transform"] = transform
        if options["offline_optimize"]:
            start_progress = 8 + int((index - 1) * 58 / len(raw_devices))
            end_progress = 8 + int(index * 58 / len(raw_devices))
            overrides, report = reprocess_single_session(
                session,
                output,
                options["reprocess_binary"],
                f"device_{index:02d}_optimized.db",
                options["pc_threads"],
                options["pc_local_staging"],
                acceleration,
                progress,
                (start_progress, end_progress),
            )
            device["database_overrides"] = {str(key): value for key, value in overrides.items()}
            report["device_id"] = device_id
            reports.append(report)
        devices.append(device)

    config = {
        "format": "SupermarketMultiDeviceConfig",
        "version": 1,
        "reference_device": devices[0]["id"],
        "align_common_start": bool(data.get("align_common_start", True)),
        "devices": devices,
    }
    config_path = temporary_json(config, "map-studio-multi-")
    try:
        args = SimpleNamespace(
            sessions=[],
            config=str(config_path),
            output=str(output),
            align_common_start=bool(data.get("align_common_start", True)),
            points_csv=optional_points(data.get("points_csv")),
            **options,
        )
        report_progress(progress, 72, "合并多设备地图", f"正在用 {acceleration.effective} 对齐设备轨迹并融合地图")
        with gpu.DepthProjector(acceleration) as projector:
            args.depth_projector = projector
            multi.generate(args)
            acceleration_report = projector.report()
        report_progress(progress, 94, "整理成果", "多设备地图已生成，正在写入质量报告")
        attach_offline_reports(output, reports)
        attach_acceleration_report(output, acceleration_report, reports)
        report_progress(progress, 98, "校验成果", "多设备地图成果文件已写入")
    finally:
        remove_temporary(config_path)


def start_job(data: Dict[str, Any]) -> Job:
    kind = data.get("kind")
    if kind not in {"map", "stage", "multi"}:
        raise RequestError("Task kind must be map, stage or multi.")
    output = require_output(data.get("output"))
    options = map_options(data)
    input_keys: tuple[str, ...] = ()
    if options["offline_optimize"]:
        if kind in {"map", "stage"}:
            input_keys = (str(require_session(data.get("session"))),)
        else:
            raw_devices = data.get("devices")
            if not isinstance(raw_devices, list):
                raise RequestError("Devices must be a list.")
            input_keys = tuple(
                str(require_session(device.get("session")))
                for device in raw_devices
                if isinstance(device, dict)
            )
    job = STATE.add(kind, output, input_keys)

    def worker() -> None:
        STATE.set_status(job.identifier, "running")
        progress = lambda value, stage, message="": STATE.update_progress(job.identifier, value, stage, message)
        progress(1, "任务已启动", "Map Studio 后台任务已启动")
        try:
            if kind == "map":
                run_basic_map(data, output, progress)
            elif kind == "stage":
                run_stage(data, output, progress)
            else:
                run_multi(data, output, progress)
        except Exception as exc:
            progress(99, "处理失败", str(exc))
            STATE.set_status(job.identifier, "failed", str(exc))
            print(traceback.format_exc(), file=sys.stderr, flush=True)
        else:
            progress(99, "完成校验", "所有地图成果已通过生成流程校验")
            STATE.set_status(job.identifier, "complete")

    threading.Thread(target=worker, name=f"map-studio-{job.identifier}", daemon=True).start()
    return job


def choose_path(mode: str, title: str) -> str:
    if mode not in {"directory", "file"}:
        raise RequestError("Dialog mode must be directory or file.")
    dialog = APP_DIR / "folder_dialog.py"
    try:
        completed = subprocess.run(
            [sys.executable, str(dialog), mode, title],
            capture_output=True,
            text=True,
            timeout=180,
            check=False,
        )
    except subprocess.TimeoutExpired as exc:
        raise RequestError("Folder selection timed out.") from exc
    if completed.returncode != 0:
        message = completed.stderr.strip() or "Native file chooser is unavailable. Paste a path into the field instead."
        raise RequestError(message)
    return completed.stdout.strip()


def reveal_directory(path: Path) -> None:
    system = platform.system()
    if system == "Windows":
        os.startfile(str(path))  # type: ignore[attr-defined]
    elif system == "Darwin":
        subprocess.Popen(["open", str(path)])
    else:
        subprocess.Popen(["xdg-open", str(path)])


class StudioHandler(BaseHTTPRequestHandler):
    server_version = "SupermarketMapStudio/1.0"

    def log_message(self, _format: str, *_args: Any) -> None:
        return

    def send_json(self, status: int, payload: Dict[str, Any]) -> None:
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def read_json(self) -> Dict[str, Any]:
        length = int(self.headers.get("Content-Length", "0"))
        if length <= 0 or length > 2 * 1024 * 1024:
            raise RequestError("Request body must be between 1 byte and 2 MB.")
        try:
            data = json.loads(self.rfile.read(length).decode("utf-8"))
        except json.JSONDecodeError as exc:
            raise RequestError(f"Invalid JSON request: {exc}") from exc
        if not isinstance(data, dict):
            raise RequestError("Request JSON must be an object.")
        return data

    def do_GET(self) -> None:  # noqa: N802
        parsed = urlparse(self.path)
        path = unquote(parsed.path)
        if path == "/api/health":
            self.send_json(HTTPStatus.OK, {"ok": True, "python": sys.version.split()[0]})
            return
        if path == "/api/gpu/capabilities":
            self.send_json(HTTPStatus.OK, gpu.capabilities())
            return
        if path.startswith("/api/jobs/"):
            self.handle_job_get(path)
            return
        self.serve_static(path)

    def do_POST(self) -> None:  # noqa: N802
        try:
            data = self.read_json()
            path = urlparse(self.path).path
            if path == "/api/dialog":
                selected = choose_path(str(data.get("mode", "directory")), str(data.get("title", "Select folder")))
                self.send_json(HTTPStatus.OK, {"path": selected})
                return
            if path == "/api/session/inspect":
                self.send_json(HTTPStatus.OK, inspect_session(require_session(data.get("session"))))
                return
            if path == "/api/session/result":
                job = find_existing_result(require_session(data.get("session")))
                self.send_json(HTTPStatus.OK, {"found": job is not None, "job": job_payload(job) if job else None})
                return
            if path == "/api/jobs":
                job = start_job(data)
                self.send_json(HTTPStatus.ACCEPTED, job_payload(job))
                return
            if path.startswith("/api/jobs/") and path.endswith("/open"):
                job_id = path.split("/")[3]
                job = STATE.get(job_id)
                if job is None or job.status != "complete":
                    raise RequestError("Completed job not found.")
                reveal_directory(job.output_dir)
                self.send_json(HTTPStatus.OK, {"opened": str(job.output_dir)})
                return
            self.send_json(HTTPStatus.NOT_FOUND, {"error": "Unknown API endpoint."})
        except RequestError as exc:
            self.send_json(HTTPStatus.BAD_REQUEST, {"error": str(exc)})
        except Exception as exc:
            self.send_json(HTTPStatus.INTERNAL_SERVER_ERROR, {"error": str(exc)})

    def handle_job_get(self, path: str) -> None:
        parts = path.split("/")
        if len(parts) < 4:
            self.send_json(HTTPStatus.NOT_FOUND, {"error": "Unknown job endpoint."})
            return
        job = STATE.get(parts[3])
        if job is None:
            self.send_json(HTTPStatus.NOT_FOUND, {"error": "Job not found."})
            return
        if len(parts) == 4:
            self.send_json(HTTPStatus.OK, job_payload(job))
            return
        if len(parts) >= 6 and parts[4] == "artifact":
            self.serve_artifact(job, "/".join(parts[5:]))
            return
        self.send_json(HTTPStatus.NOT_FOUND, {"error": "Unknown job endpoint."})

    def serve_artifact(self, job: Job, name: str) -> None:
        if name not in ARTIFACTS and not name.startswith("preview_frames/"):
            self.send_json(HTTPStatus.NOT_FOUND, {"error": "Artifact is not available."})
            return
        path = (job.output_dir / name).resolve()
        if job.output_dir.resolve() not in path.parents or not path.is_file():
            self.send_json(HTTPStatus.NOT_FOUND, {"error": "Artifact was not found."})
            return
        content_type = {
            ".png": "image/png",
            ".jpg": "image/jpeg",
            ".jpeg": "image/jpeg",
            ".json": "application/json; charset=utf-8",
            ".geojson": "application/geo+json; charset=utf-8",
        }.get(path.suffix, "application/octet-stream")
        content = path.read_bytes()
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(content)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(content)

    def serve_static(self, request_path: str) -> None:
        name = "index.html" if request_path in {"", "/"} else request_path.lstrip("/")
        if name not in {"index.html", "app.css", "app.js"}:
            self.send_error(HTTPStatus.NOT_FOUND)
            return
        path = WEB_DIR / name
        content = path.read_bytes()
        content_type = {".html": "text/html; charset=utf-8", ".css": "text/css; charset=utf-8", ".js": "application/javascript; charset=utf-8"}[path.suffix]
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(content)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(content)


def create_server(port: int = 8765) -> ThreadingHTTPServer:
    return ThreadingHTTPServer(("127.0.0.1", port), StudioHandler)


def main() -> int:
    parser = argparse.ArgumentParser(description="Start Supermarket Map Studio.")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--no-browser", action="store_true")
    args = parser.parse_args()
    server = create_server(args.port)
    url = f"http://127.0.0.1:{server.server_port}/"
    print(f"Supermarket Map Studio: {url}", flush=True)
    if not args.no_browser:
        threading.Timer(0.25, lambda: webbrowser.open(url)).start()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
