#!/usr/bin/env python3
"""Dependency-light local visual workflow for supermarket map processing."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import math
import os
import platform
import re
import secrets
import shutil
import subprocess
import stat
import sys
import tempfile
import threading
import time
import traceback
import uuid
import webbrowser
import zipfile
from collections import deque
from dataclasses import dataclass, field
from http import HTTPStatus
from http.cookies import SimpleCookie
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from types import SimpleNamespace
from typing import Any, Callable, Dict, List, Optional
from urllib.parse import unquote, urlparse


APP_DIR = Path(__file__).resolve().parent
WEB_DIR = APP_DIR / "web"
MAPPER_DIR = APP_DIR.parent / "Supermarket2DMap"
PRIOR_MAP_DIR = APP_DIR.parent / "PriorMap"
if str(MAPPER_DIR) not in sys.path:
    sys.path.insert(0, str(MAPPER_DIR))
if str(APP_DIR.parent) not in sys.path:
    sys.path.insert(0, str(APP_DIR.parent))
if str(APP_DIR.parent.parent) not in sys.path:
    sys.path.insert(0, str(APP_DIR.parent.parent))

import supermarket_2d_map as base
import supermarket_multi_device_map as multi
import supermarket_staged_map as staged
import offline_processing as offline
import gpu_acceleration as gpu
import merge_processing as merge
from PriorMap.prior_map_schema import (
    PriorMapValidationError,
    validate_business_identity,
    validate_package as validate_prior_map_package,
)
from PriorMap.xlsx_to_prior_map import convert_workbook as convert_prior_map_workbook
from PriorMap import offline_localization as localized
from PriorMap.factor_graph_runner import find_factor_graph_binary
from PriorMap.localized_output_store import (
    LocalizedSnapshot,
    LocalizedStoreError,
    LocalizedVersionStore,
    PUBLISHED_VERSION_FILES,
    REQUIRED_VERSION_FILES,
)
from Qualification.qualification import QualificationError, inspect_field_evidence


ARTIFACTS = (
    "preview.png",
    "occupancy_grid.png",
    "shelf_outline.png",
    "shelf_outline_evidence.json",
    "preview_layers.json",
    "preview_3d.json",
    "quality_report.json",
    "review_items.json",
    "localized_review.json",
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
    "merge_edits.json",
    "merge_manifest.json",
    "merge_report.json",
    "manifest.json",
    "elements.json",
    "shelves.json",
    "fixed_structures.json",
    "road_graph.json",
    "spatial_index.json",
    "validation_report.json",
    "package_manifest.json",
    "prior_map_manifest.json",
    "processing_manifest.json",
    "online_localization_trace.json",
    "optimized_map_trajectory.geojson",
    "localization_constraints.json",
    "localization_report.json",
    "factor_graph_report.json",
    "manual_edits.json",
    "localized_price_tags.json",
    "localized_price_tags.csv",
    "localized_price_tags.geojson",
    "shelf_tag_index.json",
    "audit_log.jsonl",
    "field_evidence.json",
    "qualification_manifest.json",
)
JOB_RUNTIME_TOOL_VERSION = "MarketScannerMapStudioJobRuntime/1"
MAP_STUDIO_VERSION = "MarketScannerMapStudio/2"
SESSION_TTL_SECONDS = 30 * 60


def source_git_sha() -> str:
    override = os.environ.get("MARKETSCANNER_GIT_SHA", "").strip().lower()
    if re.fullmatch(r"[0-9a-f]{40}", override):
        return override
    package_manifest = APP_DIR.parent.parent / "package-manifest.json"
    try:
        package_value = json.loads(package_manifest.read_text(encoding="utf-8"))
        package_sha = str(package_value.get("gitSha", "")).lower()
        if (
            package_value.get("format")
            == "MarketScannerMapStudioOperatorPackage"
            and package_value.get("version") == 1
            and re.fullmatch(r"[0-9a-f]{40}", package_sha)
        ):
            return package_sha
    except (OSError, json.JSONDecodeError, AttributeError):
        pass
    try:
        completed = subprocess.run(
            ["git", "rev-parse", "HEAD"],
            cwd=str(APP_DIR),
            text=True,
            capture_output=True,
            check=False,
            timeout=3,
        )
    except (OSError, subprocess.TimeoutExpired):
        return "unknown"
    candidate = completed.stdout.strip().lower()
    return candidate if re.fullmatch(r"[0-9a-f]{40}", candidate) else "unknown"


def runtime_release_identity(runtime_mode: str = "development") -> dict[str, str]:
    """Load the immutable release identity; source checkouts are not publishable."""
    configured = os.environ.get("MARKETSCANNER_RELEASE_MANIFEST", "").strip()
    package_root = APP_DIR.parent.parent
    if runtime_mode == "production":
        path = package_root / "release-manifest.json"
    else:
        path = Path(configured) if configured else package_root / "release-manifest.json"
    try:
        value, manifest_sha, _ = _stable_json_file(path)
        body = dict(value)
        declared = body.pop("manifest_body_sha256", None)
        calculated = hashlib.sha256(
            json.dumps(body, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")
        ).hexdigest()
        if (
            value.get("format") != "MarketScannerReleaseManifest"
            or value.get("version") != 2
            or re.fullmatch(r"[0-9a-f]{40}", str(value.get("git_sha", ""))) is None
            or not isinstance(value.get("product_version"), str)
            or not value["product_version"].strip()
            or declared != calculated
        ):
            raise ValueError("release manifest contract is invalid")
        if runtime_mode == "production":
            package, _package_sha, _package_size = _stable_json_file(
                package_root / "package-manifest.json"
            )
            if (
                package.get("format")
                != "MarketScannerMapStudioOperatorPackage"
                or package.get("version") != 1
                or package.get("releaseManifestSha256") != manifest_sha
                or package.get("gitSha") != value.get("git_sha")
            ):
                raise ValueError(
                    "production release identity differs from package manifest"
                )
    except (OSError, UnicodeDecodeError, json.JSONDecodeError, ValueError) as exc:
        raise RequestError("当前运行环境没有有效的 release-manifest.json，禁止发布。") from exc
    return {
        "release_manifest_sha256": manifest_sha,
        "git_sha": value["git_sha"],
        "product_version": value["product_version"],
        "quality_policy_sha256": str(value.get("factor_graph_quality_policy_sha256", "")),
    }
SOURCE_GIT_SHA = source_git_sha()


class RequestError(ValueError):
    status = HTTPStatus.BAD_REQUEST
    code = "bad_request"

    def details(self) -> Dict[str, Any]:
        return {"error": str(self), "code": self.code}


class RequestForbidden(RequestError):
    status = HTTPStatus.FORBIDDEN
    code = "request_forbidden"


class ConflictError(RequestError):
    status = HTTPStatus.CONFLICT
    code = "revision_conflict"

    def __init__(self, message: str, *, version_id: str, revision: int):
        super().__init__(message)
        self.version_id = version_id
        self.revision = revision

    def details(self) -> Dict[str, Any]:
        return {
            **super().details(),
            "current_version_id": self.version_id,
            "current_revision": self.revision,
        }


class CheckpointCleanupConflict(RequestError):
    status = HTTPStatus.CONFLICT
    code = "checkpoint_cleanup_conflict"


class QualityGateError(RequestError):
    status = HTTPStatus.UNPROCESSABLE_ENTITY
    code = "quality_gate_blocked"

    def __init__(self, message: str, blockers: List[Dict[str, Any]]):
        super().__init__(message)
        self.blockers = blockers

    def details(self) -> Dict[str, Any]:
        return {**super().details(), "blockers": self.blockers}


class JobCancelled(RuntimeError):
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
    input_identities: tuple[Dict[str, Any], ...] = field(default_factory=tuple)
    tool_version: str = JOB_RUNTIME_TOOL_VERSION
    git_sha: str = SOURCE_GIT_SHA
    cancel_requested: bool = False
    cancel_event: threading.Event = field(default_factory=threading.Event, repr=False)


class StudioState:
    JOURNAL_FORMAT = "MarketScannerMapStudioJob"
    JOURNAL_VERSION = 1
    TERMINAL_STATUSES = frozenset({"complete", "failed", "cancelled", "interrupted"})
    ACTIVE_STATUSES = frozenset({"queued", "running", "cancelling"})

    def __init__(self, state_dir: Path | None = None, retention: int = 200) -> None:
        self.lock = threading.Lock()
        self.jobs: Dict[str, Job] = {}
        self._edit_locks: Dict[str, threading.Lock] = {}
        self.state_dir = state_dir.resolve() if state_dir is not None else None
        self.retention = max(20, min(1000, int(retention)))
        self.startup_errors: list[str] = []
        if self.state_dir is not None:
            self.state_dir.mkdir(parents=True, exist_ok=True)
            self._load_journals()

    @staticmethod
    def _input_identity(path_text: str) -> Dict[str, Any]:
        path = Path(path_text).resolve()
        try:
            info = path.lstat()
            kind = "symlink" if stat.S_ISLNK(info.st_mode) else "directory" if stat.S_ISDIR(info.st_mode) else "file" if stat.S_ISREG(info.st_mode) else "other"
            body: Dict[str, Any] = {
                "path": str(path),
                "kind": kind,
                "device": int(info.st_dev),
                "inode": int(info.st_ino),
                "bytes": int(info.st_size),
                "mtime_ns": int(info.st_mtime_ns),
            }
        except OSError:
            body = {"path": str(path), "kind": "missing"}
        encoded = json.dumps(body, sort_keys=True, separators=(",", ":")).encode("utf-8")
        return {**body, "identity_sha256": hashlib.sha256(encoded).hexdigest()}

    @staticmethod
    def _valid_input_identity(value: Any) -> bool:
        if not isinstance(value, dict) or not isinstance(value.get("path"), str):
            return False
        digest = value.get("identity_sha256")
        if not isinstance(digest, str) or re.fullmatch(r"[0-9a-f]{64}", digest) is None:
            return False
        body = {key: item for key, item in value.items() if key != "identity_sha256"}
        encoded = json.dumps(body, sort_keys=True, separators=(",", ":")).encode("utf-8")
        return hashlib.sha256(encoded).hexdigest() == digest

    @staticmethod
    def _payload(job: Job) -> dict[str, Any]:
        return {
            "format": StudioState.JOURNAL_FORMAT,
            "version": StudioState.JOURNAL_VERSION,
            "storage_version": 2,
            "id": job.identifier,
            "kind": job.kind,
            "output_dir": str(job.output_dir),
            "created_at": job.created_at,
            "status": job.status,
            "error": job.error,
            "finished_at": job.finished_at,
            "progress": job.progress,
            "stage": job.stage,
            "updated_at": job.updated_at,
            "logs": list(job.logs),
            "input_keys": list(job.input_keys),
            "input_identities": list(job.input_identities),
            "tool_version": job.tool_version,
            "git_sha": job.git_sha,
            "cancel_requested": job.cancel_requested,
        }

    def _journal_path(self, identifier: str) -> Path:
        assert self.state_dir is not None
        if re.fullmatch(r"[0-9a-f]{12}", identifier) is None:
            raise ValueError("Job identifier is unsafe for journal storage.")
        return self.state_dir / f"{identifier}.json"

    def _persist_locked(self, job: Job) -> None:
        if self.state_dir is None:
            return
        destination = self._journal_path(job.identifier)
        temporary = destination.with_name(f".{destination.name}.{uuid.uuid4().hex}.tmp")
        encoded = json.dumps(
            self._payload(job), ensure_ascii=False, sort_keys=True, separators=(",", ":")
        ).encode("utf-8") + b"\n"
        descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        try:
            with os.fdopen(descriptor, "wb") as handle:
                handle.write(encoded)
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(temporary, destination)
            if os.name != "nt":
                directory_descriptor = os.open(self.state_dir, os.O_RDONLY)
                try:
                    os.fsync(directory_descriptor)
                finally:
                    os.close(directory_descriptor)
        finally:
            temporary.unlink(missing_ok=True)

    def _load_journals(self) -> None:
        assert self.state_dir is not None
        for path in sorted(self.state_dir.glob("*.json")):
            try:
                if path.is_symlink() or not path.is_file():
                    raise ValueError("journal is not a regular file")
                payload = json.loads(path.read_text(encoding="utf-8"))
                identifier = path.stem
                if (
                    not isinstance(payload, dict)
                    or payload.get("format") != self.JOURNAL_FORMAT
                    or payload.get("version") != self.JOURNAL_VERSION
                    or payload.get("id") != identifier
                    or re.fullmatch(r"[0-9a-f]{12}", identifier) is None
                    or payload.get("status")
                    not in (self.ACTIVE_STATUSES | self.TERMINAL_STATUSES)
                    or not isinstance(payload.get("kind"), str)
                    or not payload["kind"]
                    or not isinstance(payload.get("output_dir"), str)
                    or not Path(payload["output_dir"]).is_absolute()
                    or not isinstance(payload.get("logs"), list)
                    or not isinstance(payload.get("input_keys"), list)
                    or not isinstance(payload.get("input_identities"), list)
                    or len(payload["input_identities"]) != len(payload["input_keys"])
                    or not all(
                        self._valid_input_identity(item)
                        for item in payload["input_identities"]
                    )
                    or not isinstance(payload.get("tool_version"), str)
                    or not isinstance(payload.get("git_sha"), str)
                    or (
                        payload["git_sha"] != "unknown"
                        and re.fullmatch(r"[0-9a-f]{40}", payload["git_sha"]) is None
                    )
                ):
                    raise ValueError("journal schema is invalid")
                created_at = float(payload.get("created_at"))
                updated_at = float(payload.get("updated_at"))
                finished_at = (
                    float(payload["finished_at"])
                    if payload.get("finished_at") is not None
                    else None
                )
                if not all(
                    math.isfinite(value)
                    for value in (created_at, updated_at)
                ) or (finished_at is not None and not math.isfinite(finished_at)):
                    raise ValueError("journal timestamps are invalid")
                job = Job(
                    identifier=identifier,
                    kind=str(payload.get("kind") or "unknown"),
                    output_dir=Path(payload["output_dir"]).resolve(),
                    created_at=created_at,
                    status=str(payload["status"]),
                    error=payload.get("error") if isinstance(payload.get("error"), str) else None,
                    finished_at=finished_at,
                    progress=max(0, min(100, int(payload.get("progress", 0)))),
                    stage=str(payload.get("stage") or "未知阶段"),
                    updated_at=updated_at,
                    logs=[item for item in payload["logs"][-500:] if isinstance(item, dict)],
                    input_keys=tuple(str(Path(item).resolve()) for item in payload["input_keys"] if isinstance(item, str)),
                    input_identities=tuple(dict(item) for item in payload["input_identities"]),
                    tool_version=payload["tool_version"],
                    git_sha=payload["git_sha"],
                    cancel_requested=bool(payload.get("cancel_requested")),
                )
                if job.status in self.ACTIVE_STATUSES:
                    job.status = "interrupted"
                    job.error = "Map Studio restarted while this task was active; output staging was not published."
                    job.stage = "服务重启后已中断"
                    job.finished_at = time.time()
                    job.updated_at = job.finished_at
                    self._persist_locked(job)
                self.jobs[job.identifier] = job
            except (OSError, ValueError, TypeError, json.JSONDecodeError) as exc:
                self.startup_errors.append(f"{path.name}: {exc}")
        self._prune_locked()

    def _prune_locked(self) -> None:
        if self.state_dir is None:
            return
        terminal = sorted(
            (job for job in self.jobs.values() if job.status in self.TERMINAL_STATUSES),
            key=lambda job: job.updated_at,
            reverse=True,
        )
        for job in terminal[self.retention :]:
            self.jobs.pop(job.identifier, None)
            self._journal_path(job.identifier).unlink(missing_ok=True)
            for log_path in self.state_dir.glob(
                f"{job.identifier}-rtabmap-reprocess-*.log"
            ):
                if log_path.is_file() and not log_path.is_symlink():
                    log_path.unlink(missing_ok=True)

    def acquire_edit_lock(self, job_id: str) -> threading.Lock:
        """Return a per-job mutex for localized edit operations.

        Locks are created lazily and cleaned up when a job transitions
        away from ``complete`` status (e.g. on reprocess).
        """
        with self.lock:
            if job_id not in self._edit_locks:
                self._edit_locks[job_id] = threading.Lock()
            return self._edit_locks[job_id]

    def release_edit_lock(self, job_id: str) -> None:
        with self.lock:
            self._edit_locks.pop(job_id, None)

    def add(self, kind: str, output_dir: Path, input_keys: tuple[str, ...] = ()) -> Job:
        with self.lock:
            resolved = output_dir.resolve()
            normalized_inputs = tuple(sorted({str(Path(key).resolve()) for key in input_keys}))
            if any(
                existing.output_dir.resolve() == resolved and existing.status in self.ACTIVE_STATUSES
                for existing in self.jobs.values()
            ):
                raise RequestError("This output directory is already reserved by a Map Studio task.")
            input_set = set(normalized_inputs)
            duplicate = next(
                (
                    existing
                    for existing in self.jobs.values()
                    if existing.status in self.ACTIVE_STATUSES
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
                input_identities=tuple(
                    self._input_identity(path) for path in normalized_inputs
                ),
            )
            self.jobs[job.identifier] = job
            self._persist_locked(job)
            self._prune_locked()
        return job

    def get(self, job_id: str) -> Optional[Job]:
        with self.lock:
            return self.jobs.get(job_id)

    def begin(self, job_id: str) -> bool:
        """Atomically claim a queued job unless cancellation won the race."""
        with self.lock:
            job = self.jobs[job_id]
            if job.cancel_requested or job.status != "queued":
                return False
            job.status = "running"
            job.updated_at = time.time()
            self._persist_locked(job)
            return True

    def list(self) -> list[Job]:
        with self.lock:
            return sorted(self.jobs.values(), key=lambda job: job.created_at, reverse=True)

    def cancel(self, job_id: str) -> Job:
        with self.lock:
            job = self.jobs.get(job_id)
            if job is None:
                raise RequestError("Task not found.")
            if job.status not in self.ACTIVE_STATUSES:
                raise RequestError("Only an active task can be cancelled.")
            job.cancel_requested = True
            job.cancel_event.set()
            job.status = "cancelling"
            job.stage = "正在取消"
            job.updated_at = time.time()
            self._persist_locked(job)
            return job

    def active_for_input(self, input_key: str) -> Optional[Job]:
        normalized = str(Path(input_key).resolve())
        with self.lock:
            return next(
                (
                    job
                    for job in self.jobs.values()
                    if job.status in self.ACTIVE_STATUSES and normalized in job.input_keys
                ),
                None,
            )

    def set_status(self, job_id: str, status: str, error: Optional[str] = None) -> None:
        with self.lock:
            job = self.jobs[job_id]
            job.status = status
            job.error = error
            job.updated_at = time.time()
            if status in self.TERMINAL_STATUSES:
                job.finished_at = time.time()
            if status == "complete":
                job.progress = 100
                job.stage = "处理完成"
            elif status == "failed":
                job.stage = "处理失败"
            elif status == "cancelled":
                job.stage = "已取消"
            elif status == "interrupted":
                job.stage = "服务重启后已中断"
            self._persist_locked(job)
            self._prune_locked()

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
            self._persist_locked(job)

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
            self._persist_locked(job)
            return job


def default_job_state_dir() -> Path:
    override = os.environ.get("MARKETSCANNER_JOB_STATE_DIR")
    if override:
        return Path(override).expanduser().resolve()
    if sys.platform == "darwin":
        return Path.home() / "Library/Application Support/MarketScanner/MapStudio/jobs"
    if os.name == "nt":
        base = Path(os.environ.get("LOCALAPPDATA", Path.home() / "AppData/Local"))
        return base / "MarketScanner/MapStudio/jobs"
    base = Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state"))
    return base / "marketscanner/mapstudio/jobs"


def legacy_job_state_dir() -> Path:
    owner = hashlib.sha256(str(Path.home()).encode("utf-8")).hexdigest()[:12]
    return Path(tempfile.gettempdir()) / f"marketscanner-mapstudio-{owner}" / "jobs"


try:
    STATE = StudioState(default_job_state_dir())
except OSError as exc:
    # Import remains usable for diagnostics/tests, but production startup fails closed.
    STATE = StudioState(None)
    STATE.startup_errors.append(f"app_data_job_state_unavailable:{exc}")
if legacy_job_state_dir().is_dir() and legacy_job_state_dir() != STATE.state_dir:
    STATE.startup_errors.append(
        f"legacy_job_state_available_for_read_only_migration:{legacy_job_state_dir()}"
    )
JOB_RUNTIME_CONTEXT = threading.local()
FINALIZED_CHECKPOINT_CLEANUP_LOCK = threading.Lock()
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
        "factor_graph_binary": str(options.get("factor_graph_binary") or "").strip() or None,
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


def job_artifacts(
    job: Job, localized_snapshot: LocalizedSnapshot | None = None
) -> Dict[str, str]:
    artifacts = {
        name: f"/api/jobs/{job.identifier}/artifact/{name}"
        for name in ARTIFACTS
        if (job.output_dir / name).is_file()
    }
    if job.kind == "localized":
        snapshot = localized_snapshot
        if snapshot is None:
            snapshot = LocalizedVersionStore(job.output_dir).current()
        if snapshot is not None:
            artifacts.update(
                {
                    name: (
                        f"/api/jobs/{job.identifier}/localized/versions/"
                        f"{snapshot.version_id}/artifact/{name}"
                    )
                    for name in PUBLISHED_VERSION_FILES
                    if (snapshot.version_dir / name).is_file()
                }
            )
    return artifacts


def load_json(path: Path, default: Any) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return default


def job_summary_payload(job: Job) -> Dict[str, Any]:
    runtime_logs: list[dict[str, Any]] = []
    if STATE.state_dir is not None:
        for path in sorted(STATE.state_dir.glob(f"{job.identifier}-rtabmap-reprocess-*.log")):
            if path.is_file() and not path.is_symlink():
                runtime_logs.append(
                    {
                        "name": path.name,
                        "bytes": path.stat().st_size,
                        "url": f"/api/jobs/{job.identifier}/runtime-log/{path.name}",
                    }
                )
    return {
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
        "input_identities": list(job.input_identities),
        "tool_version": job.tool_version,
        "git_sha": job.git_sha,
        "cancel_requested": job.cancel_requested,
        "recoverability": (
            "restart_required"
            if job.status == "interrupted"
            else "terminal"
            if job.status in StudioState.TERMINAL_STATUSES
            else "active"
        ),
        "runtime_logs": runtime_logs,
    }


def job_payload(job: Job) -> Dict[str, Any]:
    payload: Dict[str, Any] = job_summary_payload(job)
    if job.status == "complete":
        localized_snapshot = None
        if job.kind == "localized":
            localized_snapshot = LocalizedVersionStore(job.output_dir).current()
            if localized_snapshot is None:
                raise LocalizedStoreError(
                    "Completed localized job has no validated current version."
                )
        payload["artifacts"] = job_artifacts(job, localized_snapshot)
        if job.kind == "prior_map":
            validation = load_json(job.output_dir / "validation_report.json", {})
            payload["quality_report"] = {
                "warnings": validation.get("warnings", []),
                "prior_map": validation.get("summary", {}),
            }
            payload["review_items"] = {
                "items": validation.get("malformed_rows", [])
            }
            payload["map"] = load_json(job.output_dir / "manifest.json", {})
        elif job.kind == "localized":
            store = LocalizedVersionStore(job.output_dir)
            snapshot = localized_snapshot
            assert snapshot is not None
            payload["localized"] = {
                "version_id": snapshot.version_id,
                "revision": snapshot.revision,
                "publish_state": snapshot.state,
            }
            published = store.published()
            if published is not None:
                payload["localized"]["published"] = {
                    "version_id": published.version_id,
                    "revision": published.revision,
                    "publish_state": published.state,
                }
            try:
                payload["quality_report"] = json.loads(
                    store.read_verified_artifact(
                        snapshot.version_id, "localization_report.json"
                    )
                )
                payload["review_items"] = json.loads(
                    store.read_verified_artifact(
                        snapshot.version_id, "review_items.json"
                    )
                )
                payload["map"] = json.loads(
                    store.read_verified_artifact(
                        snapshot.version_id, "localized_review.json"
                    )
                )
            except (UnicodeDecodeError, json.JSONDecodeError) as exc:
                raise LocalizedStoreError(
                    "Validated localized JSON changed while building the response."
                ) from exc
        else:
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
                    # NFC capture is paused and should not appear in the active
                    # scan-debug surface. Old event data remains untouched on
                    # disk and the compatibility parser is retained.
                    if event.get("event") == "price_tag_recorded":
                        continue
                    event["source"] = path.relative_to(session).as_posix()
                    event_count += 1
                    recent_events.append(event)
    events = sorted(recent_events, key=lambda item: float(item.get("timestampUnix", 0) or 0))
    return {
        "available": bool(files),
        "files": [path.relative_to(session).as_posix() for path in files],
        "event_count": event_count,
        "malformed_lines": malformed_lines,
        "events": events,
        "truncated": event_count > event_limit,
    }


def structure_coverage_summary(session: Path) -> Dict[str, Any]:
    """Read the bounded phone-side coverage evidence without loading its cells."""
    files = sorted(session.glob("segment_*/structure_coverage_cells.json"))
    summaries: list[Dict[str, Any]] = []
    malformed_files: list[str] = []
    for path in files:
        payload = load_json(path, {})
        summary = payload.get("summary") if isinstance(payload, dict) else None
        if not isinstance(summary, dict):
            malformed_files.append(path.relative_to(session).as_posix())
            continue
        summaries.append(
            {
                "source": path.relative_to(session).as_posix(),
                "cell_size_m": payload.get("cellSizeM"),
                "floor_height_m": payload.get("floorHeightM"),
                **summary,
            }
        )
    return {
        "available": bool(summaries),
        "files": [path.relative_to(session).as_posix() for path in files],
        "malformed_files": malformed_files,
        # A production continuous scan has one segment. Keep the per-segment
        # list so legacy inputs never have unrelated grids silently merged.
        "segments": summaries,
        "summary": summaries[-1] if summaries else None,
    }


def prior_map_localization_summary(session: Path) -> Dict[str, Any]:
    """Inspect bounded Stage-2 audit sidecars without touching the scan DB."""
    names = {
        "constraints": "localization_constraints.jsonl",
        "events": "localization_events.jsonl",
        "observations": "tag_observations.jsonl",
    }
    result: Dict[str, Any] = {
        "available": False,
        "constraints": 0,
        "accepted_constraints": 0,
        "events": 0,
        "tag_observations": 0,
        "localized_price_tags": 0,
        "needs_review": 0,
        "malformed_records": 0,
        "state_counts": {},
        "files": [],
    }
    for category, filename in names.items():
        for path in sorted(session.glob(f"segment_*/{filename}")):
            result["files"].append(path.relative_to(session).as_posix())
            result["available"] = True
            try:
                handle = path.open("r", encoding="utf-8", errors="replace")
            except OSError:
                result["malformed_records"] += 1
                continue
            with handle:
                for line in handle:
                    if not line.strip():
                        continue
                    if len(line) > 1_000_000:
                        result["malformed_records"] += 1
                        continue
                    try:
                        record = json.loads(line)
                    except json.JSONDecodeError:
                        result["malformed_records"] += 1
                        continue
                    if not isinstance(record, dict):
                        result["malformed_records"] += 1
                        continue
                    if category == "constraints":
                        result["constraints"] += 1
                        result["accepted_constraints"] += int(
                            record.get("accepted") is True
                        )
                    elif category == "events":
                        result["events"] += 1
                        state = str(record.get("state") or "unknown")
                        result["state_counts"][state] = (
                            result["state_counts"].get(state, 0) + 1
                        )
                    else:
                        result["tag_observations"] += 1
                        result["needs_review"] += int(
                            record.get("needs_review") is True
                        )
    for path in sorted(session.glob("segment_*/localized_price_tags.json")):
        result["files"].append(path.relative_to(session).as_posix())
        result["available"] = True
        try:
            if path.stat().st_size > 20 * 1024 * 1024:
                raise ValueError("localized price-tag sidecar exceeds inspection limit")
            tags = json.loads(path.read_text(encoding="utf-8"))
            if not isinstance(tags, list):
                raise ValueError("localized price-tag sidecar is not an array")
            result["localized_price_tags"] += sum(
                1 for tag in tags if isinstance(tag, dict)
            )
            result["needs_review"] += sum(
                1
                for tag in tags
                if isinstance(tag, dict) and tag.get("needs_review") is True
            )
        except (OSError, ValueError, json.JSONDecodeError):
            result["malformed_records"] += 1
    result["files"].sort()
    result["state_counts"] = dict(sorted(result["state_counts"].items()))
    return result


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
        "segments": [
            {
                "index": segment.index,
                "database": str(segment.database_path) if segment.database_path else None,
                "nodes": len(segment.poses),
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
        "structure_coverage": structure_coverage_summary(session),
        "prior_map_localization": prior_map_localization_summary(session),
        "scan_logs": scan_event_logs(session),
        "checkpoint_cleanup": checkpoint_cleanup_evidence(session),
        "active_job": job_payload(active_job) if active_job else None,
    }


def _required_finite_unix_time(value: Any, field_name: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise RequestError(f"{field_name} must be a finite Unix timestamp.")
    result = float(value)
    if not math.isfinite(result):
        raise RequestError(f"{field_name} must be a finite Unix timestamp.")
    return result


_FILE_ATTRIBUTE_REPARSE_POINT = 0x0400


def _is_link_or_reparse(path: Path, value: os.stat_result) -> bool:
    return stat.S_ISLNK(value.st_mode) or bool(
        getattr(value, "st_file_attributes", 0)
        & _FILE_ATTRIBUTE_REPARSE_POINT
    )


def _validated_cleanup_paths(session: Path) -> tuple[Path, Path, Path, Path]:
    try:
        session_stat = os.lstat(session)
    except OSError as exc:
        raise RequestError(f"Cleanup session is unavailable: {exc}") from exc
    if _is_link_or_reparse(session, session_stat) or not stat.S_ISDIR(
        session_stat.st_mode
    ):
        raise RequestError("Cleanup session must be a local directory, not a link.")
    try:
        entries = [
            entry
            for entry in os.scandir(session)
            if entry.name.startswith("segment_")
        ]
    except OSError as exc:
        raise RequestError(f"Unable to enumerate cleanup session: {exc}") from exc
    if len(entries) != 1 or entries[0].name != "segment_0001":
        raise RequestError(
            "Checkpoint cleanup requires exactly one continuous segment_0001."
        )
    segment = Path(entries[0].path)
    segment_stat = entries[0].stat(follow_symlinks=False)
    if _is_link_or_reparse(segment, segment_stat) or not stat.S_ISDIR(
        segment_stat.st_mode
    ):
        raise RequestError("Refused checkpoint cleanup through a linked segment.")
    try:
        if segment.resolve(strict=True).parent != session.resolve(strict=True):
            raise RequestError("Cleanup segment escaped the selected session.")
    except OSError as exc:
        raise RequestError(f"Cleanup path resolution failed: {exc}") from exc
    return (
        segment,
        segment / "metadata.json",
        segment / "live_checkpoint.json",
        segment / "scan_events.jsonl",
    )


def _open_regular_no_follow(path: Path, flags: int) -> int:
    no_follow = getattr(os, "O_NOFOLLOW", 0)
    binary = getattr(os, "O_BINARY", 0)
    try:
        before = os.lstat(path)
        if _is_link_or_reparse(path, before):
            raise RequestError(f"Refused linked cleanup file: {path.name}.")
        descriptor = os.open(path, flags | no_follow | binary)
    except FileNotFoundError as exc:
        if path.name == "live_checkpoint.json":
            raise CheckpointCleanupConflict(
                "Checkpoint no longer exists; inspect the session again."
            ) from exc
        raise RequestError(f"Cleanup file is missing: {path.name}.") from exc
    except RequestError:
        raise
    except OSError as exc:
        raise RequestError(f"Unable to open cleanup file {path.name}: {exc}") from exc
    try:
        opened = os.fstat(descriptor)
        if not stat.S_ISREG(opened.st_mode):
            raise RequestError(f"Cleanup file is not regular: {path.name}.")
        if (before.st_dev, before.st_ino) != (opened.st_dev, opened.st_ino):
            raise CheckpointCleanupConflict(
                f"Cleanup file changed while opening: {path.name}."
            )
        return descriptor
    except Exception:
        os.close(descriptor)
        raise


def _read_descriptor(descriptor: int) -> bytes:
    os.lseek(descriptor, 0, os.SEEK_SET)
    chunks: List[bytes] = []
    while True:
        chunk = os.read(descriptor, 1024 * 1024)
        if not chunk:
            return b"".join(chunks)
        chunks.append(chunk)


def _append_finalization_cleanup_audit(
    events_path: Path,
    *,
    tracking_session_id: str,
    event: str,
    message: str,
) -> None:
    timestamp = datetime.now(timezone.utc)
    record = {
        "event": event,
        "fields": {
            "cleanup_policy": "finalized_same_identity_older_checkpoint_v1",
            "operator": "map_studio_explicit_api",
        },
        "format": "SupermarketScanEvent",
        "level": "warning",
        "message": message,
        "timestamp": timestamp.isoformat().replace("+00:00", "Z"),
        "timestampUnix": timestamp.timestamp(),
        "trackingSessionId": tracking_session_id,
        "version": 1,
    }
    payload = (
        json.dumps(record, ensure_ascii=False, sort_keys=True, allow_nan=False)
        + "\n"
    ).encode("utf-8")
    no_follow = getattr(os, "O_NOFOLLOW", 0)
    binary = getattr(os, "O_BINARY", 0)
    try:
        event_stat = None
        if events_path.exists() or events_path.is_symlink():
            event_stat = os.lstat(events_path)
            if _is_link_or_reparse(events_path, event_stat):
                raise RequestError(
                    "Refused to write a checkpoint cleanup audit through a link."
                )
        descriptor = os.open(
            events_path,
            os.O_APPEND | os.O_CREAT | os.O_WRONLY | no_follow | binary,
            0o600,
        )
        try:
            opened_stat = os.fstat(descriptor)
            if not stat.S_ISREG(opened_stat.st_mode):
                raise OSError("cleanup audit target is not a regular file")
            if event_stat is not None and (
                event_stat.st_dev,
                event_stat.st_ino,
            ) != (opened_stat.st_dev, opened_stat.st_ino):
                raise CheckpointCleanupConflict(
                    "Cleanup audit target changed while opening."
                )
            written = 0
            while written < len(payload):
                count = os.write(descriptor, payload[written:])
                if count <= 0:
                    raise OSError("short write while persisting cleanup audit")
                written += count
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
    except RequestError:
        raise
    except OSError as exc:
        raise RequestError(f"Unable to persist checkpoint cleanup audit: {exc}") from exc


def _cleanup_evidence(session: Path) -> Dict[str, Any]:
    segment, metadata_path, checkpoint_path, events_path = _validated_cleanup_paths(
        session
    )
    if events_path.exists() or events_path.is_symlink():
        events_stat = os.lstat(events_path)
        if _is_link_or_reparse(events_path, events_stat) or not stat.S_ISREG(
            events_stat.st_mode
        ):
            raise RequestError(
                "Checkpoint cleanup audit target must be a regular local file."
            )
    metadata_descriptor: Optional[int] = None
    checkpoint_descriptor: Optional[int] = None
    try:
        metadata_descriptor = _open_regular_no_follow(metadata_path, os.O_RDONLY)
        checkpoint_descriptor = _open_regular_no_follow(
            checkpoint_path, os.O_RDONLY
        )
        metadata_bytes = _read_descriptor(metadata_descriptor)
        checkpoint_bytes = _read_descriptor(checkpoint_descriptor)
        metadata = json.loads(metadata_bytes.decode("utf-8"))
        checkpoint = json.loads(checkpoint_bytes.decode("utf-8"))
        if not isinstance(metadata, dict) or not isinstance(checkpoint, dict):
            raise RequestError("Finalization cleanup evidence must be JSON objects.")
        if metadata.get("finalized") is not True:
            raise RequestError("metadata.json is not a committed finalized scan.")
        metadata_identity = metadata.get("trackingSessionId")
        checkpoint_identity = checkpoint.get("trackingSessionId")
        if (
            not isinstance(metadata_identity, str)
            or not metadata_identity
            or metadata_identity != checkpoint_identity
        ):
            raise RequestError(
                "Checkpoint tracking identity does not match finalized metadata."
            )
        finalized_at = _required_finite_unix_time(
            metadata.get("finalizedAtUnix"), "metadata.finalizedAtUnix"
        )
        checkpoint_updated_at = _required_finite_unix_time(
            checkpoint.get("updatedAtUnix"), "checkpoint.updatedAtUnix"
        )
        if checkpoint_updated_at > finalized_at:
            raise RequestError(
                "Checkpoint is newer than the finalized metadata commit."
            )
        return {
            "segment": segment,
            "metadata_path": metadata_path,
            "checkpoint_path": checkpoint_path,
            "events_path": events_path,
            "metadata_bytes": metadata_bytes,
            "checkpoint_bytes": checkpoint_bytes,
            "metadata_stat": os.fstat(metadata_descriptor),
            "checkpoint_stat": os.fstat(checkpoint_descriptor),
            "tracking_session_id": metadata_identity,
            "finalized_at_unix": finalized_at,
            "checkpoint_updated_at_unix": checkpoint_updated_at,
            "metadata_sha256": hashlib.sha256(metadata_bytes).hexdigest(),
            "checkpoint_sha256": hashlib.sha256(checkpoint_bytes).hexdigest(),
        }
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise RequestError(f"Finalization cleanup evidence is unreadable: {exc}") from exc
    finally:
        if checkpoint_descriptor is not None:
            os.close(checkpoint_descriptor)
        if metadata_descriptor is not None:
            os.close(metadata_descriptor)


def checkpoint_cleanup_evidence(session: Path) -> Dict[str, Any]:
    try:
        evidence = _cleanup_evidence(session)
    except RequestError as exc:
        return {"available": False, "reason": str(exc)}
    return {
        "available": True,
        "tracking_session_id": evidence["tracking_session_id"],
        "finalized_at_unix": evidence["finalized_at_unix"],
        "checkpoint_updated_at_unix": evidence["checkpoint_updated_at_unix"],
        "metadata_sha256": evidence["metadata_sha256"],
        "checkpoint_sha256": evidence["checkpoint_sha256"],
        "warning": "This only deletes an older checkpoint; it does not repair scan data.",
    }


def cleanup_finalized_checkpoint(
    session: Path,
    *,
    confirmed: Any,
    expected_tracking_session_id: Any,
    expected_finalized_at_unix: Any,
    expected_metadata_sha256: Any,
    expected_checkpoint_sha256: Any,
) -> Dict[str, Any]:
    """Explicitly remove one stale checkpoint after strict commit validation.

    Normal inspection and processing never invoke this recovery path. The
    checkpoint is preserved unless finalized metadata proves the same tracking
    identity and has a commit time at least as new as the checkpoint.
    """
    with FINALIZED_CHECKPOINT_CLEANUP_LOCK:
        if confirmed is not True:
            raise RequestError("Checkpoint cleanup requires confirmed=true.")
        evidence = _cleanup_evidence(session)
        expected_time = _required_finite_unix_time(
            expected_finalized_at_unix, "expected_finalized_at_unix"
        )
        expected_values = (
            expected_tracking_session_id,
            expected_time,
            expected_metadata_sha256,
            expected_checkpoint_sha256,
        )
        actual_values = (
            evidence["tracking_session_id"],
            evidence["finalized_at_unix"],
            evidence["metadata_sha256"],
            evidence["checkpoint_sha256"],
        )
        if expected_values != actual_values:
            raise CheckpointCleanupConflict(
                "Checkpoint cleanup evidence changed; inspect again before retrying."
            )
        segment = evidence["segment"]
        checkpoint_path = evidence["checkpoint_path"]
        events_path = evidence["events_path"]
        metadata_identity = evidence["tracking_session_id"]
        _append_finalization_cleanup_audit(
            events_path,
            tracking_session_id=metadata_identity,
            event="finalization_checkpoint_cleanup_authorized",
            message="Operator explicitly authorized stale finalized checkpoint cleanup",
        )
        try:
            current_descriptor = _open_regular_no_follow(
                checkpoint_path, os.O_RDONLY
            )
            try:
                current_stat = os.fstat(current_descriptor)
                current_bytes = _read_descriptor(current_descriptor)
            finally:
                os.close(current_descriptor)
            if (
                (current_stat.st_dev, current_stat.st_ino, current_stat.st_size)
                != (
                    evidence["checkpoint_stat"].st_dev,
                    evidence["checkpoint_stat"].st_ino,
                    evidence["checkpoint_stat"].st_size,
                )
                or current_bytes != evidence["checkpoint_bytes"]
            ):
                raise CheckpointCleanupConflict(
                    "Checkpoint changed during validation; cleanup was cancelled."
                )
            if os.name == "nt":
                os.unlink(checkpoint_path)
            else:
                directory_flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
                directory_flags |= getattr(os, "O_NOFOLLOW", 0)
                segment_descriptor = os.open(segment, directory_flags)
                try:
                    opened_segment = os.fstat(segment_descriptor)
                    expected_segment = os.lstat(segment)
                    if (
                        not stat.S_ISDIR(opened_segment.st_mode)
                        or _is_link_or_reparse(segment, expected_segment)
                        or (opened_segment.st_dev, opened_segment.st_ino)
                        != (expected_segment.st_dev, expected_segment.st_ino)
                    ):
                        raise CheckpointCleanupConflict(
                            "Cleanup segment changed before checkpoint deletion."
                        )
                    os.unlink(checkpoint_path.name, dir_fd=segment_descriptor)
                finally:
                    os.close(segment_descriptor)
        except FileNotFoundError as exc:
            failure = CheckpointCleanupConflict(
                "Checkpoint changed during cleanup; operation cancelled."
            )
            try:
                _append_finalization_cleanup_audit(
                    events_path,
                    tracking_session_id=metadata_identity,
                    event="finalization_checkpoint_cleanup_failed",
                    message=str(failure),
                )
            except RequestError as audit_exc:
                print(f"Cleanup failure audit degraded: {audit_exc}", file=sys.stderr)
            raise failure from exc
        except (OSError, RequestError) as exc:
            try:
                _append_finalization_cleanup_audit(
                    events_path,
                    tracking_session_id=metadata_identity,
                    event="finalization_checkpoint_cleanup_failed",
                    message=str(exc),
                )
            except RequestError as audit_exc:
                print(f"Cleanup failure audit degraded: {audit_exc}", file=sys.stderr)
            if isinstance(exc, RequestError):
                raise
            raise RequestError(f"Unable to remove the validated checkpoint: {exc}") from exc

        warning = None
        try:
            _append_finalization_cleanup_audit(
                events_path,
                tracking_session_id=metadata_identity,
                event="finalization_checkpoint_cleanup_completed",
                message="Validated finalized checkpoint cleanup completed",
            )
        except RequestError as exc:
            # The eligibility-changing deletion already succeeded. Report the
            # audit warning without turning it into a misleading cleanup error.
            warning = str(exc)
        return {
            "cleaned": True,
            "session": str(session),
            "segment": str(segment),
            "tracking_session_id": metadata_identity,
            "deleted_checkpoint_sha256": evidence["checkpoint_sha256"],
            "audit_warning": warning,
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
    if summary["finalized"] is not True:
        raise RequestError(
            "The phone database is not explicitly marked finalized=true; "
            "finalize/copy it before PC processing."
        )
    metadata = segments[0].metadata
    workflow_mode = metadata.get("workflowMode") or metadata.get("workflow_mode")
    if workflow_mode == "prior_map_localized":
        capture_health = metadata.get("captureHealth") or metadata.get("capture_health")
        eligibility = metadata.get("processingEligibility") or metadata.get(
            "processing_eligibility"
        )
        failure_count = (
            capture_health.get("localizationRequiredWriteFailureCount")
            if isinstance(capture_health, dict)
            else None
        )
        evidence_complete = (
            capture_health.get("localizationEvidenceComplete")
            if isinstance(capture_health, dict)
            else None
        )
        blockers = eligibility.get("blockers") if isinstance(eligibility, dict) else None
        if (
            not isinstance(capture_health, dict)
            or isinstance(failure_count, bool)
            or failure_count != 0
            or evidence_complete is not True
            or not isinstance(eligibility, dict)
            or eligibility.get("status") != "eligible"
            or blockers != []
        ):
            raise RequestError(
                "Prior-map localization evidence is incomplete or ineligible; "
                "PC optimization requires zero required sidecar write failures, "
                "localizationEvidenceComplete=true, and an empty eligibility blocker list."
            )
    optimized_dir = output / "rtabmap_optimized"
    optimized_database = optimized_dir / output_name

    def reprocess_progress(fraction: float, stage: str, message: str) -> None:
        start, end = progress_range
        mapped = start + round(max(0.0, min(1.0, fraction)) * (end - start))
        report_progress(progress, mapped, stage, message)

    cancel_event = getattr(JOB_RUNTIME_CONTEXT, "cancel_event", None)
    log_prefix = getattr(JOB_RUNTIME_CONTEXT, "log_prefix", None)
    try:
        report = offline.run_adaptive_reprocess(
            segments[0].database_path,
            optimized_database,
            explicit_binary=explicit_binary,
            thread_count=thread_count,
            use_local_staging=use_local_staging,
            accelerator_backend=acceleration.effective,
            extra_parameters=acceleration.rtabmap_parameters,
            progress_callback=reprocess_progress,
            cancel_event=cancel_event,
            persistent_log_prefix=log_prefix,
        )
    except offline.OfflineProcessingError as exc:
        if cancel_event is not None and cancel_event.is_set():
            raise JobCancelled(str(exc)) from exc
        raise
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
        "strategy": (
            "manual_user_closure_and_robust_global_optimization"
            if any(bool(report.get("user_constraints_used")) for report in reports)
            else "software_only_vio_rgbd_loop_closure_and_robust_global_optimization"
        ),
        "fiducials_used": False,
        "landmark_constraints_used": False,
        "pose_priors_used": False,
        "user_constraints_used": any(
            bool(report.get("user_constraints_used")) for report in reports
        ),
        "user_constraint_count": sum(
            int(report.get("user_constraint_count", 0)) for report in reports
        ),
        "execution": {
            "profile": (
                "manual_region_merge_v1"
                if any(bool(report.get("user_constraints_used")) for report in reports)
                else offline.ADAPTIVE_PROFILE
            ),
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
    localized_root = latest / "localized"
    has_localized_state = any(
        path.exists()
        for path in (
            localized_root / "current.json",
            localized_root / "published.json",
            localized_root / "versions",
        )
    )
    localized_snapshot = LocalizedVersionStore(latest).current()
    if has_localized_state and localized_snapshot is None:
        raise LocalizedStoreError(
            "Localized storage exists but has no validated current version."
        )
    if localized_snapshot is not None:
        kind = "localized"
    else:
        kind = "stage" if metadata.get("format") == "SupermarketStageMap2D" else "map"
    return STATE.restore(kind, latest)


def _manual_merge_output(session: Path, raw: Any) -> Path:
    if raw not in (None, ""):
        return require_output(raw)
    stem = f"MapStudio-Merge-{time.strftime('%Y%m%d-%H%M%S')}"
    candidate = session / stem
    suffix = 2
    while candidate.exists():
        candidate = session / f"{stem}-{suffix}"
        suffix += 1
    return candidate


def merge_preview(job: Job, data: Dict[str, Any]) -> Dict[str, Any]:
    if job.status != "complete":
        raise RequestError("Manual repair requires a completed map result.")
    if not (job.output_dir / "preview_layers.json").is_file():
        raise RequestError(
            "This result has no metric preview evidence. Regenerate the map before manual repair."
        )
    try:
        return merge.preview_merge(job.output_dir, data)
    except merge.MergeProcessingError as exc:
        raise RequestError(str(exc)) from exc


def run_manual_merge(
    base_job: Job,
    data: Dict[str, Any],
    output: Path,
    progress: Optional[ProgressCallback] = None,
) -> None:
    report_progress(progress, 3, "验证人工修复", "正在重新校验框选区域和位姿对应关系")
    preview = merge_preview(base_job, data)
    if not preview.get("can_apply"):
        raise RequestError("The regional alignment did not pass the preview confidence threshold.")
    session = require_session(preview["source_session"])
    source_database = resolve_path(preview["source_database"], "Merge source database")
    if not source_database.is_file():
        raise RequestError(f"Merge source database does not exist: {source_database}")

    options = map_options(data)
    base_map = load_json(base_job.output_dir / "map.json", {})
    base_parameters = (
        base_map.get("parameters", {}) if isinstance(base_map, dict) else {}
    )
    if isinstance(base_parameters, dict):
        for key in (
            "resolution",
            "preview_resolution",
            "trajectory_radius",
            "tag_snap_distance",
            "occupied_inflate_radius",
            "free_ray_max_range",
            "horizontal_axes",
        ):
            if base_parameters.get(key) is not None:
                options[key] = base_parameters[key]
    # Constraint transforms were derived in the base result's map plane. The
    # regenerated version must keep that plane even if the form was changed.
    options["horizontal_axes"] = preview["geometry"]["horizontal_axes"]
    options["resolution"] = preview["geometry"]["resolution_m"]
    acceleration = acceleration_selection(options, progress)
    config = base.MapConfig(
        options["resolution"],
        options["preview_resolution"],
        options["trajectory_radius"],
        options["tag_snap_distance"],
        options["occupied_inflate_radius"],
        options["free_ray_max_range"],
        options["horizontal_axes"],
        False,
    )
    segments = base.discover_segments(session, config)
    if len(segments) != 1 or segments[0].database_path is None:
        raise RequestError(
            "Manual regional repair currently requires one continuous RTAB-Map database."
        )
    optimized_database = output / "rtabmap_optimized" / "manual_merge_optimized.db"

    def reprocess_progress(fraction: float, stage: str, message: str) -> None:
        mapped = 12 + round(max(0.0, min(1.0, fraction)) * 54)
        report_progress(progress, mapped, stage, message)

    report_progress(
        progress,
        10,
        "注入人工闭环",
        f"将 {len(preview['constraints'])} 条 kUserClosure 约束写入一次性数据库副本",
    )
    report = offline.run_reprocess(
        source_database,
        optimized_database,
        explicit_binary=options["reprocess_binary"],
        thread_count=options["pc_threads"],
        use_local_staging=options["pc_local_staging"],
        accelerator_backend=acceleration.effective,
        extra_parameters=acceleration.rtabmap_parameters + offline.FAST_REUSE_PARAMETERS,
        progress_callback=reprocess_progress,
        profile_name="manual_region_merge_v1",
        link_injections=preview["constraints"],
    )
    report["session"] = str(session)
    report["scan_mode"] = base.session_scan_summary(segments)["scan_mode"]
    report_progress(progress, 68, "验证人工修复", "正在检查人工约束残差和全图位姿位移")
    validation = merge.validate_optimized_merge(
        source_database,
        optimized_database,
        preview["constraints"],
        preview["geometry"]["horizontal_axes"],
    )
    if validation["status"] != "pass":
        output.mkdir(parents=True, exist_ok=True)
        merge.write_merge_artifacts(output, preview, validation, base_job.output_dir)
        reasons = " ".join(validation["rejection_reasons"])
        raise RequestError(
            "Manual repair failed post-optimization safety validation and was not rendered: "
            + reasons
        )

    args = SimpleNamespace(
        session=str(session),
        output=str(output),
        points_csv=optional_points(data.get("points_csv")),
        corrections=None,
        auto_align_segments=False,
        database_overrides={segments[0].index: str(optimized_database)},
        **options,
    )
    report_progress(
        progress,
        72,
        "重建修复地图",
        f"人工闭环已通过验证，正在用 {acceleration.effective} 重投影完整地图",
    )
    with gpu.DepthProjector(acceleration) as projector:
        args.depth_projector = projector
        base.generate(args)
        acceleration_report = projector.report()
    report_progress(progress, 94, "写入修复版本", "正在保存人工操作、约束和验证报告")
    attach_offline_reports(output, [report])
    attach_acceleration_report(output, acceleration_report, [report])
    merge.write_merge_artifacts(output, preview, validation, base_job.output_dir)
    report_progress(progress, 98, "校验成果", "人工误差修复版本已写入，原结果保持不变")


def start_manual_merge(base_job: Job, data: Dict[str, Any]) -> Job:
    if not boolean(data.get("confirmed"), False):
        raise RequestError("Confirm the preview before applying manual regional repair.")
    preview = merge_preview(base_job, data)
    session = require_session(preview["source_session"])
    output = _manual_merge_output(session, data.get("output"))
    job = STATE.add("merge", output, (str(session),))

    def worker() -> None:
        def progress(value: int, stage: str, message: str = "") -> None:
            if job.cancel_event.is_set():
                raise JobCancelled("Task cancellation was requested.")
            STATE.update_progress(job.identifier, value, stage, message)
        try:
            if not STATE.begin(job.identifier):
                raise JobCancelled("Task cancellation was requested before startup.")
            JOB_RUNTIME_CONTEXT.cancel_event = job.cancel_event
            JOB_RUNTIME_CONTEXT.log_prefix = (
                STATE.state_dir / f"{job.identifier}-rtabmap-reprocess"
                if STATE.state_dir is not None
                else None
            )
            progress(1, "任务已启动", f"基于 {base_job.output_dir.name} 创建人工修复版本")
            run_manual_merge(base_job, data, output, progress)
            if job.cancel_event.is_set():
                raise JobCancelled("Task cancellation was requested.")
        except JobCancelled as exc:
            STATE.update_progress(job.identifier, 99, "已取消", str(exc))
            STATE.set_status(job.identifier, "cancelled", str(exc))
        except Exception as exc:
            STATE.update_progress(job.identifier, 99, "处理失败", str(exc))
            STATE.set_status(job.identifier, "failed", str(exc))
            print(traceback.format_exc(), file=sys.stderr, flush=True)
        else:
            STATE.update_progress(job.identifier, 99, "完成校验", "人工修复版本已通过生成流程校验")
            STATE.set_status(job.identifier, "complete")
        finally:
            JOB_RUNTIME_CONTEXT.__dict__.clear()

    threading.Thread(
        target=worker,
        name=f"map-studio-merge-{job.identifier}",
        daemon=True,
    ).start()
    return job


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
        report_progress(progress, 72, "生成阶段地图", f"正在用 {acceleration.effective} 投影结构、提取货架轮廓并整理扫描帧")
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
        report_progress(progress, 72, "生成地图", f"正在用 {acceleration.effective} 生成二维结构、货架轮廓和彩色三维预览")
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


def run_localized_map(
    data: Dict[str, Any],
    output: Path,
    progress: Optional[ProgressCallback] = None,
) -> None:
    session = require_session(data.get("session"))
    prior_map = resolve_path(data.get("prior_map"), "Prior-map package")
    validation = validate_prior_map_package(prior_map)
    if not validation["valid"]:
        raise RequestError(
            "先验地图校验失败："
            + "；".join(item["message"] for item in validation["errors"])
        )
    options = map_options(data)
    acceleration = acceleration_selection(options, progress)
    report_progress(progress, 4, "检查地图与会话", "正在校验地图 hash、单库会话和只读源数据库")
    config = base.MapConfig(
        options["resolution"],
        options["preview_resolution"],
        options["trajectory_radius"],
        options["tag_snap_distance"],
        options["occupied_inflate_radius"],
        options["free_ray_max_range"],
        options["horizontal_axes"],
        False,
    )
    original_segments = base.discover_segments(session, config)
    if len(original_segments) != 1 or original_segments[0].database_path is None:
        raise RequestError("先验地图离线优化只接受一个已完成的连续扫描数据库。")
    database_overrides, offline_report = reprocess_single_session(
        session,
        output,
        options["reprocess_binary"],
        "optimized.db",
        options["pc_threads"],
        options["pc_local_staging"],
        acceleration,
        progress,
        (10, 62),
    )
    report_progress(progress, 64, "生成 RTAB-Map 成果", "正在用优化数据库生成兼容的 2D/3D 地图成果")
    args = SimpleNamespace(
        session=str(session),
        output=str(output),
        points_csv=optional_points(data.get("points_csv")),
        corrections=None,
        auto_align_segments=False,
        database_overrides=database_overrides,
        **options,
    )
    with gpu.DepthProjector(acceleration) as projector:
        args.depth_projector = projector
        base.generate(args)
        acceleration_report = projector.report()
    # Map rendering keeps the selected legacy axes for compatibility, while
    # prior-map localization must use the exact iOS ARKit x/-z contract.  The
    # native database stores R * ARKit * R^-1, so treating it as the historical
    # xz sidecar convention rotates/mirrors the trajectory and manufactures
    # tens of metres of apparent anchor error.
    localization_config = base.MapConfig(
        resolution=config.resolution,
        preview_resolution=config.preview_resolution,
        trajectory_radius=config.trajectory_radius,
        tag_snap_distance=config.tag_snap_distance,
        occupied_inflate_radius=config.occupied_inflate_radius,
        free_ray_max_range=config.free_ray_max_range,
        horizontal_axes="ios_prior",
        auto_align_segments=False,
    )
    optimized_segments = base.discover_segments(
        session,
        localization_config,
        {key: Path(value) for key, value in database_overrides.items()},
    )
    poses = [
        localized.Pose(
            node_id=pose.node_id,
            timestamp=pose.stamp,
            x=pose.x,
            y=pose.y,
            yaw=pose.yaw,
        )
        for pose in optimized_segments[0].poses
    ]
    manual_edits = None
    raw_edits = data.get("manual_edits")
    if raw_edits not in (None, ""):
        edits_path = resolve_path(raw_edits, "Manual edits")
        manual_edits = load_json(edits_path, None)
        if not isinstance(manual_edits, dict):
            raise RequestError("manual_edits.json 无效。")
    # These root-level reports are part of successful job completion.  Finish
    # them before the immutable localized pointer commit so a post-processing
    # failure cannot leave a failed job with an advanced current pointer.
    attach_offline_reports(output, [offline_report])
    attach_acceleration_report(output, acceleration_report, [offline_report])
    localized_result = localized.process_localized_session(
        prior_map=prior_map,
        session=session,
        optimized_poses=poses,
        source_database=original_segments[0].database_path,
        optimized_database=Path(database_overrides[optimized_segments[0].index]),
        output=output,
        manual_edits=manual_edits,
        progress=progress,
        factor_graph_binary=find_factor_graph_binary(options["factor_graph_binary"]),
        replay_parameters={
            "resolution": config.resolution,
            "preview_resolution": config.preview_resolution,
            "trajectory_radius": config.trajectory_radius,
            "tag_snap_distance": config.tag_snap_distance,
            "occupied_inflate_radius": config.occupied_inflate_radius,
            "free_ray_max_range": config.free_ray_max_range,
            "horizontal_axes": localization_config.horizontal_axes,
            "auto_align_segments": config.auto_align_segments,
            "diagnostic_mode": data.get("diagnostic_mode") is True,
        },
    )
    if not localized_result.get("current_updated"):
        raise RequestError(
            "本地化质量门禁未通过；诊断版本已保留，但不会切换为 current 结果。"
            "测试阶段可启用“测试诊断模式”以加载不可发布草稿和误差报告。"
        )


def _manual_edit_context(
    tags: Any, constraints_payload: Any, prior_map: Path
) -> tuple[list[Dict[str, Any]], list[Dict[str, Any]], list[Dict[str, Any]], Dict[str, Any]]:
    elements_payload = load_json(prior_map / "elements.json", None)
    manifest = load_json(prior_map / "manifest.json", None)
    constraints = (
        constraints_payload.get("raw")
        if isinstance(constraints_payload, dict)
        else None
    )
    elements = (
        elements_payload.get("elements")
        if isinstance(elements_payload, dict)
        else None
    )
    if (
        not isinstance(tags, list)
        or not isinstance(constraints, list)
        or not isinstance(elements, list)
        or not isinstance(manifest, dict)
    ):
        raise RequestError("本地化结果缺少完整的人工编辑校验上下文。")
    if any(not isinstance(item, dict) for item in tags + constraints + elements):
        raise RequestError("本地化人工编辑校验上下文包含无效记录。")
    return tags, constraints, elements, manifest


def _one_by_id(
    records: List[Dict[str, Any]], field: str, identifier: str, label: str
) -> Dict[str, Any]:
    matches = [item for item in records if str(item.get(field) or "") == identifier]
    if len(matches) != 1:
        raise RequestError(f"{label} {identifier!r} 不存在或不唯一。")
    return matches[0]


def _validate_manual_tag_association(
    tag: Dict[str, Any],
    elements: List[Dict[str, Any]],
    manifest: Dict[str, Any],
) -> None:
    shelf_code = str(tag.get("shelf_code") or "")
    shelf = _one_by_id(
        [
            item
            for item in elements
            if item.get("shape_type") in {"MapShelf", "MapTable", "MapTableFeature"}
        ],
        "code",
        shelf_code,
        "货架/柜台",
    )
    side = str(tag.get("shelf_side") or "")
    edges = {edge_id: (start, end) for edge_id, start, end in localized._stable_edges(shelf)}
    if side not in edges:
        raise RequestError(f"货架 {shelf_code!r} 不存在侧面 {side!r}。")
    try:
        offset_cm = float(tag.get("distance_from_shelf_start_cm"))
    except (TypeError, ValueError) as exc:
        raise RequestError("价签沿货架起点距离必须是有限厘米数。") from exc
    start, end = edges[side]
    edge_length_cm = math.hypot(end[0] - start[0], end[1] - start[1]) * 100
    if not math.isfinite(offset_cm) or not 0 <= offset_cm <= edge_length_cm + 1.0e-6:
        raise RequestError(
            f"价签距离 {offset_cm!r} cm 超出货架侧面长度 {edge_length_cm:.3f} cm。"
        )
    position = tag.get("final_map_position")
    if not isinstance(position, dict):
        raise RequestError("价签缺少 final_map_position，不能批准或保存关联。")
    try:
        x = float(position.get("x_m"))
        y = float(position.get("y_m"))
        height = float(position.get("height_m", 0.0))
    except (TypeError, ValueError) as exc:
        raise RequestError("价签位置必须包含有限的 x_m/y_m/height_m。") from exc
    bounds = manifest.get("bounds") if isinstance(manifest.get("bounds"), dict) else {}
    try:
        inside = (
            float(bounds["min_x_m"]) <= x <= float(bounds["max_x_m"])
            and float(bounds["min_y_m"]) <= y <= float(bounds["max_y_m"])
        )
    except (KeyError, TypeError, ValueError) as exc:
        raise RequestError("先验地图缺少有效 bounds，不能验证价签位置。") from exc
    if not all(math.isfinite(value) for value in (x, y, height)) or not inside or not 0 <= height <= 5:
        raise RequestError("价签位置超出先验地图或高度范围。")
    ratio = 0.0 if edge_length_cm <= 1.0e-9 else offset_cm / edge_length_cm
    shelf_x = start[0] + ratio * (end[0] - start[0])
    shelf_y = start[1] + ratio * (end[1] - start[1])
    if math.hypot(x - shelf_x, y - shelf_y) > 0.45 + 1.0e-9:
        raise RequestError("价签位置与指定货架侧面/距离不一致（超过 0.45 m）。")


def _authoritative_manual_event(
    request_event: Dict[str, Any],
    *,
    revision: int,
    tags: List[Dict[str, Any]],
    constraints: List[Dict[str, Any]],
    elements: List[Dict[str, Any]],
    manifest: Dict[str, Any],
) -> Dict[str, Any]:
    kind = str(request_event.get("type") or "")
    target = str(request_event.get("object_id") or "")
    new_value = request_event.get("new_value")
    provisional = {"type": kind, "object_id": target, "new_value": new_value}
    try:
        localized.validate_manual_edit_event(provisional)
    except localized.OfflineLocalizationError as exc:
        raise RequestError(str(exc)) from exc
    old_value: Any = None
    if kind == "edit_tag":
        tag = _one_by_id(tags, "tag_id", target, "价签")
        assert isinstance(new_value, dict)
        old_value = {key: tag.get(key) for key in new_value}
        if "height_cm" in new_value:
            old_position = tag.get("final_map_position")
            old_height = (
                old_position.get("height_m")
                if isinstance(old_position, dict)
                else None
            )
            old_value["height_cm"] = (
                float(old_height) * 100
                if isinstance(old_height, (int, float))
                and not isinstance(old_height, bool)
                and math.isfinite(float(old_height))
                else None
            )
        merged = {**tag, **new_value}
        if "height_cm" in new_value:
            position = dict(merged.get("final_map_position") or {})
            position["height_m"] = float(new_value["height_cm"]) / 100
            merged["final_map_position"] = position
        _validate_manual_tag_association(merged, elements, manifest)
    elif kind == "approve_tag":
        tag = _one_by_id(tags, "tag_id", target, "价签")
        _validate_manual_tag_association(tag, elements, manifest)
        old_value = {
            "approval_status": tag.get("approval_status"),
            "needs_review": tag.get("needs_review"),
        }
    elif kind == "batch_approve_tags":
        assert isinstance(new_value, list)
        old_value = {}
        for identifier in (str(item) for item in new_value):
            tag = _one_by_id(tags, "tag_id", identifier, "价签")
            _validate_manual_tag_association(tag, elements, manifest)
            old_value[identifier] = {
                "approval_status": tag.get("approval_status"),
                "needs_review": tag.get("needs_review"),
            }
    elif kind == "disable_constraint":
        constraint = _one_by_id(constraints, "constraint_id", target, "约束")
        old_value = bool(constraint.get("disabled_by_manual_edit", False))

    reason = request_event.get("reason")
    if reason is None:
        reason = ""
    if not isinstance(reason, str) or len(reason) > 500:
        raise RequestError("人工编辑原因必须是不超过 500 个字符的文本。")
    return {
        "event_id": f"edit-{uuid.uuid4().hex}",
        "created_at_utc": datetime.now(timezone.utc).isoformat(timespec="milliseconds"),
        "base_revision": revision,
        "type": kind,
        "object_id": target,
        "old_value": old_value,
        "new_value": new_value,
        "actor": "local-user",
        "reason": reason,
    }


def _append_manual_operation_audit(
    journal: Dict[str, Any],
    *,
    action: str,
    base_revision: int,
    old_cursor: int,
    new_cursor: int,
    event_id: str | None = None,
) -> None:
    audit_events = list(journal.get("audit_events", []))
    audit_events.append(
        {
            "audit_id": f"audit-{uuid.uuid4().hex}",
            "created_at_utc": datetime.now(timezone.utc).isoformat(timespec="milliseconds"),
            "base_revision": base_revision,
            "action": action,
            "old_cursor": old_cursor,
            "new_cursor": new_cursor,
            "event_id": event_id,
            "actor": "local-user",
        }
    )
    journal["audit_events"] = audit_events


def apply_localized_edit(job: Job, data: Dict[str, Any]) -> Dict[str, Any]:
    if job.kind != "localized" or job.status != "complete":
        raise RequestError("人工复核只适用于已完成的先验地图会话优化结果。")
    edit_lock = STATE.acquire_edit_lock(job.identifier)
    with edit_lock:
        store = LocalizedVersionStore(job.output_dir)
        current = store.current()
        if current is None:
            raise RequestError("结果缺少已验证的 current 本地化版本。")
        try:
            verified_bytes = store.read_verified_artifacts(
                current,
                (
                    "manual_edits.json",
                    "source_manifest.json",
                    "processing_manifest.json",
                    "session_input_manifest.json",
                    "localized_price_tags.json",
                    "localization_constraints.json",
                ),
            )
            verified = {
                name: json.loads(content)
                for name, content in verified_bytes.items()
            }
            local_state = store.local_inputs_for(current)
        except (LocalizedStoreError, UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise RequestError(
                "当前版本或本机输入记录无法通过完整性验证，不能安全重放。"
            ) from exc
        journal = verified["manual_edits.json"]
        source = verified["source_manifest.json"]
        processing = verified["processing_manifest.json"]
        session_input = verified["session_input_manifest.json"]
        tags_payload = verified["localized_price_tags.json"]
        constraints_payload = verified["localization_constraints.json"]
        if not all(
            isinstance(item, dict)
            for item in (journal, source, processing, session_input)
        ):
            raise RequestError("当前版本缺少有效的重放身份文件。")
        if "expected_revision" not in data or "expected_version_id" not in data:
            raise RequestError(
                "人工编辑必须提供 expected_revision 和 expected_version_id。"
            )
        expected_revision = data["expected_revision"]
        if isinstance(expected_revision, bool) or not isinstance(expected_revision, int):
            raise RequestError("expected_revision 必须是整数。")
        expected_version = data["expected_version_id"]
        if not isinstance(expected_version, str) or not expected_version:
            raise RequestError("expected_version_id 必须是非空字符串。")
        try:
            journal_revision = int(journal["revision"])
        except (KeyError, TypeError, ValueError) as exc:
            raise RequestError("manual_edits.json revision 无效。") from exc
        if journal_revision != current.revision:
            raise RequestError("current 指针与 manual_edits.json revision 不一致。")
        if expected_revision != current.revision or expected_version != current.version_id:
            raise ConflictError(
                (
                    f"人工编辑冲突：当前为 {current.version_id}/r{current.revision}，"
                    f"请求为 {expected_version}/r{expected_revision}。请重新加载后重试。"
                ),
                version_id=current.version_id,
                revision=current.revision,
            )

        paths = local_state.get("paths")
        identities = local_state.get("identities")
        if not isinstance(paths, dict) or not isinstance(identities, dict):
            raise RequestError("本机输入记录缺少路径或身份摘要。")
        prior_map = resolve_path(paths.get("prior_map"), "Prior-map package")
        session = require_session(paths.get("source_session"))
        source_database = resolve_path(
            paths.get("source_database"), "Source database"
        )
        optimized_database = resolve_path(
            paths.get("optimized_database"), "Optimized database"
        )
        if not source_database.is_file() or not optimized_database.is_file():
            raise RequestError("源数据库或优化数据库不存在，无法重放人工编辑。")
        validation = validate_prior_map_package(prior_map)
        if not validation["valid"]:
            raise RequestError("先验地图已变化或损坏，无法安全重放。")
        package_manifest = load_json(prior_map / "package_manifest.json", None)
        segment_dirs = sorted(
            path for path in session.glob("segment_*") if path.is_dir()
        )
        if len(segment_dirs) != 1:
            raise RequestError("重放要求唯一的连续扫描 segment。")
        try:
            replay_parameters = localized.normalize_replay_parameters(
                processing.get("replay_parameters")
            )
            processing_hash = localized.processing_parameter_sha256(
                replay_parameters
            )
            verified_bundle = localized.session_input_bundle_sha256(session_input)
            actual_session_input = localized.build_session_input_manifest(
                segment_dirs[0], source_database
            )
        except localized.OfflineLocalizationError as exc:
            raise RequestError("重放参数或 finalized 输入清单无效。") from exc
        actual_hashes = {
            "session_input_bundle_sha256": actual_session_input["bundle_sha256"],
            "source_database_sha256": localized._sha256(source_database),
            "optimized_database_sha256": localized._sha256(optimized_database),
            "prior_map_sha256": (
                package_manifest.get("package_sha256")
                if isinstance(package_manifest, dict)
                else None
            ),
            "processing_parameter_sha256": processing_hash,
        }
        if (
            verified_bundle != actual_session_input["bundle_sha256"]
            or session_input.get("files") != actual_session_input["files"]
            or any(identities.get(name) != value for name, value in actual_hashes.items())
            or source.get("session_input_bundle_sha256") != verified_bundle
            or processing.get("session_input_bundle_sha256") != verified_bundle
            or journal.get("session_input_bundle_sha256") != verified_bundle
            or source.get("input_identity_id") != current.input_identity_id
            or processing.get("input_identity_id") != current.input_identity_id
            or journal.get("input_identity_id") != current.input_identity_id
            or session_input.get("input_identity_id") != current.input_identity_id
            or source.get("source_database_sha256_before")
            != actual_hashes["source_database_sha256"]
            or source.get("optimized_database_sha256")
            != actual_hashes["optimized_database_sha256"]
            or source.get("prior_map_sha256") != actual_hashes["prior_map_sha256"]
            or processing.get("processing_parameter_sha256") != processing_hash
            or journal.get("processing_parameter_sha256") != processing_hash
        ):
            raise RequestError(
                "重放输入、参数或版本身份已变化；旧 current 保持不变。"
            )
        tags, constraints, elements, manifest = _manual_edit_context(
            tags_payload, constraints_payload, prior_map
        )

        action = str(data.get("action") or "append")
        old_cursor = int(journal.get("cursor", 0))
        edited_event_id: str | None = None
        if action == "undo":
            journal = localized.move_manual_edit_cursor(journal, -1)
        elif action == "redo":
            journal = localized.move_manual_edit_cursor(journal, 1)
        elif action == "append":
            request_event = data.get("event")
            if not isinstance(request_event, dict):
                raise RequestError("人工编辑事件必须是对象。")
            event = _authoritative_manual_event(
                request_event,
                revision=current.revision,
                tags=tags,
                constraints=constraints,
                elements=elements,
                manifest=manifest,
            )
            journal = localized.append_manual_edit(journal, event)
            edited_event_id = event["event_id"]
        else:
            raise RequestError("人工编辑 action 必须是 append、undo 或 redo。")
        _append_manual_operation_audit(
            journal,
            action=action,
            base_revision=current.revision,
            old_cursor=old_cursor,
            new_cursor=int(journal.get("cursor", 0)),
            event_id=edited_event_id,
        )
        journal["revision"] = current.revision + 1

        config = base.MapConfig(
            replay_parameters["resolution"],
            replay_parameters["preview_resolution"],
            replay_parameters["trajectory_radius"],
            replay_parameters["tag_snap_distance"],
            replay_parameters["occupied_inflate_radius"],
            replay_parameters["free_ray_max_range"],
            replay_parameters["horizontal_axes"],
            replay_parameters["auto_align_segments"],
        )
        segments = base.discover_segments(session, config, {1: optimized_database})
        if len(segments) != 1:
            raise RequestError("优化轨迹无法重新读取。")
        poses = [
            localized.Pose(
                node_id=pose.node_id,
                timestamp=pose.stamp,
                x=pose.x,
                y=pose.y,
                yaw=pose.yaw,
            )
            for pose in segments[0].poses
        ]
        try:
            result = localized.process_localized_session(
                prior_map=prior_map,
                session=session,
                optimized_poses=poses,
                source_database=source_database,
                optimized_database=optimized_database,
                output=job.output_dir,
                manual_edits=journal,
                expected_parent_version=current.version_id,
                replay_parameters=replay_parameters,
                factor_graph_binary=find_factor_graph_binary(),
            )
        except localized.OfflineLocalizationError as exc:
            if "current version changed during replay" in str(exc):
                latest = LocalizedVersionStore(job.output_dir).current()
                if latest is not None:
                    raise ConflictError(
                        "人工编辑冲突：处理期间 current 已更新，请刷新后重试。",
                        version_id=latest.version_id,
                        revision=latest.revision,
                    ) from exc
            raise
        if not result.get("current_updated"):
            raise RequestError(
                "人工编辑重放未通过质量门禁；旧 current 版本保持不变。"
            )
    return {
        "cursor": journal["cursor"],
        "revision": journal["revision"],
        "event_count": len(journal["events"]),
        "version_id": result["version_id"],
        "job": job_payload(job),
    }


def apply_localized_state_transition(
    job: Job, data: Dict[str, Any], *, runtime_mode: str = "development"
) -> Dict[str, Any]:
    if job.kind != "localized" or job.status != "complete":
        raise RequestError("发布状态操作只适用于已完成的本地化任务。")
    with STATE.acquire_edit_lock(job.identifier):
        store = LocalizedVersionStore(job.output_dir)
        action = str(data.get("action") or "")
        targets = {
            "submit_review": "review",
            "return_to_draft": "draft",
            "publish": "published",
            "revoke": "revoked",
        }
        if action not in targets:
            raise RequestError("不支持的本地化状态操作。")
        if action == "publish" and runtime_mode != "production":
            raise RequestForbidden(
                "Development runtime is not permitted to publish localized versions."
            )
        source_snapshot = store.published() if action == "revoke" else store.current()
        if source_snapshot is None:
            missing = "published" if action == "revoke" else "current"
            raise RequestError(f"结果缺少已验证的 {missing} 本地化版本。")
        expected_revision = data.get("expected_revision")
        expected_version = data.get("expected_version_id")
        if (
            isinstance(expected_revision, bool)
            or not isinstance(expected_revision, int)
            or not isinstance(expected_version, str)
            or not expected_version
        ):
            raise RequestError(
                "状态操作必须提供整数 expected_revision 和 expected_version_id。"
            )
        if (
            expected_revision != source_snapshot.revision
            or expected_version != source_snapshot.version_id
        ):
            raise ConflictError(
                "发布状态冲突，请刷新最新版本后重试。",
                version_id=source_snapshot.version_id,
                revision=source_snapshot.revision,
            )
        reason = data.get("reason")
        if not isinstance(reason, str) or not reason.strip() or len(reason) > 500:
            raise RequestError("状态操作必须提供 1 到 500 字符的审核说明。")
        try:
            report = store.read_verified_json(
                source_snapshot, "localization_report.json"
            )
        except LocalizedStoreError as exc:
            raise RequestError(
                "当前版本的 localization_report.json 无法通过完整性验证。"
            ) from exc
        if not isinstance(report, dict):
            raise RequestError("当前版本缺少有效的 localization_report.json。")
        if action == "submit_review":
            gate = report.get("review_gate")
            blockers = gate.get("blockers", []) if isinstance(gate, dict) else []
            if not isinstance(gate, dict) or gate.get("passed") is not True:
                raise QualityGateError("结果尚未通过 review 门禁。", blockers)
        elif action == "publish":
            gate = report.get("publish_gate")
            blockers = gate.get("blockers", []) if isinstance(gate, dict) else []
            solver = report.get("solver")
            evidence_path_value = data.get("qualification_evidence_path")
            evidence_sha = data.get("qualification_evidence_sha256")
            acceptance_valid = (
                data.get("operator_confirmed") is True
                and isinstance(evidence_path_value, str)
                and bool(evidence_path_value.strip())
                and isinstance(evidence_sha, str)
                and re.fullmatch(r"[0-9a-f]{64}", evidence_sha) is not None
            )
            if (
                not isinstance(gate, dict)
                or gate.get("passed") is not True
                or gate.get("blockers") != []
                or not isinstance(solver, dict)
                or solver.get("full_factor_graph") is not True
                or solver.get("published_capable") is not True
                or solver.get("type") != "relative_se2_factor_graph"
                or not acceptance_valid
            ):
                if not blockers:
                    blockers = [{"code": "publish_gate_not_satisfied"}]
                if not acceptance_valid:
                    blockers = [*blockers, {"code": "field_acceptance_missing"}]
                raise QualityGateError(
                    "当前有界修正场仅允许草稿/复核，不能发布。", blockers
                )
        try:
            if action == "publish":
                production_diagnostics = startup_diagnostics("production")
                if (
                    production_diagnostics.get("production_qualified") is not True
                    or production_diagnostics.get("can_start") is not True
                ):
                    raise QualityGateError(
                        "Production selfcheck failed immediately before publication.",
                        [
                            {
                                "code": "production_selfcheck_failed",
                                "checks": production_diagnostics.get("checks", []),
                            }
                        ],
                    )
                snapshot = store.publish_current(
                    actor="local-user",
                    reason=reason.strip(),
                    qualification_evidence_path=resolve_path(
                        evidence_path_value, "Field qualification evidence"
                    ),
                    expected_field_evidence_sha256=evidence_sha,
                    expected_release_identity=runtime_release_identity("production"),
                    expected_version=expected_version,
                )
            elif action == "revoke":
                snapshot = store.revoke_published(
                    actor="local-user",
                    reason=reason.strip(),
                    expected_version=expected_version,
                )
            else:
                snapshot = store.transition_current(
                    targets[action],
                    actor="local-user",
                    reason=reason.strip(),
                    expected_version=expected_version,
                )
        except LocalizedStoreError as exc:
            if "changed before" in str(exc):
                latest = store.published() if action == "revoke" else store.current()
                if latest is not None:
                    raise ConflictError(
                        "发布状态冲突，请刷新最新版本后重试。",
                        version_id=latest.version_id,
                        revision=latest.revision,
                    ) from exc
            raise RequestError(str(exc)) from exc
    return {
        "version_id": snapshot.version_id,
        "revision": snapshot.revision,
        "publish_state": snapshot.state,
        "job": job_payload(job),
    }


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
        report_progress(progress, 72, "合并多设备地图", f"正在用 {acceleration.effective} 对齐设备轨迹并融合结构与货架轮廓")
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
    if kind not in {"map", "stage", "multi", "localized"}:
        raise RequestError("Task kind must be map, stage, multi or localized.")
    output = require_output(data.get("output"))
    options = map_options(data)
    input_keys: tuple[str, ...] = ()
    if kind == "localized" or options["offline_optimize"]:
        if kind in {"map", "stage"}:
            input_keys = (str(require_session(data.get("session"))),)
        elif kind == "localized":
            input_keys = (
                str(require_session(data.get("session"))),
                str(resolve_path(data.get("prior_map"), "Prior-map package")),
            )
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
        def progress(value: int, stage: str, message: str = "") -> None:
            if job.cancel_event.is_set():
                raise JobCancelled("Task cancellation was requested.")
            STATE.update_progress(job.identifier, value, stage, message)
        try:
            if not STATE.begin(job.identifier):
                raise JobCancelled("Task cancellation was requested before startup.")
            JOB_RUNTIME_CONTEXT.cancel_event = job.cancel_event
            JOB_RUNTIME_CONTEXT.log_prefix = (
                STATE.state_dir / f"{job.identifier}-rtabmap-reprocess"
                if STATE.state_dir is not None
                else None
            )
            progress(1, "任务已启动", "Map Studio 后台任务已启动")
            if kind == "map":
                run_basic_map(data, output, progress)
            elif kind == "stage":
                run_stage(data, output, progress)
            elif kind == "localized":
                run_localized_map(data, output, progress)
            else:
                run_multi(data, output, progress)
            if job.cancel_event.is_set():
                raise JobCancelled("Task cancellation was requested.")
        except JobCancelled as exc:
            STATE.update_progress(job.identifier, 99, "已取消", str(exc))
            STATE.set_status(job.identifier, "cancelled", str(exc))
        except Exception as exc:
            STATE.update_progress(job.identifier, 99, "处理失败", str(exc))
            STATE.set_status(job.identifier, "failed", str(exc))
            print(traceback.format_exc(), file=sys.stderr, flush=True)
        else:
            STATE.update_progress(job.identifier, 99, "完成校验", "所有地图成果已通过生成流程校验")
            STATE.set_status(job.identifier, "complete")
        finally:
            JOB_RUNTIME_CONTEXT.__dict__.clear()

    threading.Thread(target=worker, name=f"map-studio-{job.identifier}", daemon=True).start()
    return job


def start_prior_map_job(data: Dict[str, Any]) -> Job:
    source = resolve_path(data.get("xlsx"), "Prior-map workbook")
    if not source.is_file() or source.suffix.lower() != ".xlsx":
        raise RequestError("请选择包含 Element Info 工作表的 .xlsx 地图文件。")
    output = resolve_path(data.get("output"), "Prior-map output directory")
    if output.exists() and (not output.is_dir() or any(output.iterdir())):
        raise RequestError("先验地图输出目录必须为空；源 Excel 不会被修改。")
    if not output.parent.is_dir():
        raise RequestError(f"先验地图输出目录的上级目录不存在：{output.parent}")
    map_name = data.get("name")
    if map_name is not None and not isinstance(map_name, str):
        raise RequestError("地图 name 必须是字符串。")
    store_id = data.get("store_id")
    try:
        validate_business_identity(store_id, map_name if map_name is not None else source.stem)
    except PriorMapValidationError as exc:
        raise RequestError(str(exc)) from exc
    job = STATE.add("prior_map", output, (str(source),))

    def worker() -> None:
        try:
            if not STATE.begin(job.identifier):
                raise JobCancelled("Task cancellation was requested before startup.")
            STATE.update_progress(
                job.identifier,
                5,
                "读取先验地图",
                "正在读取 Element Info；源 Excel 保持只读。",
            )
            STATE.update_progress(
                job.identifier,
                25,
                "转换坐标与几何",
                "正在统一厘米、坐标轴、旋转矩形和楼层范围。",
            )
            convert_prior_map_workbook(
                source,
                output,
                map_name,
                store_id,
            )
            STATE.update_progress(
                job.identifier,
                82,
                "校验地图包",
                "正在检查道路连通性、空间索引和版本化文件。",
            )
            validation = validate_prior_map_package(output)
            if not validation["valid"]:
                raise RequestError(
                    "地图包校验失败："
                    + "；".join(item["message"] for item in validation["errors"])
                )
            STATE.update_progress(
                job.identifier,
                98,
                "生成预览",
                "地图包和可缩放预览已生成；可安全用于手机导入。",
            )
            if job.cancel_event.is_set():
                raise JobCancelled("Task cancellation was requested.")
        except JobCancelled as exc:
            STATE.update_progress(job.identifier, 99, "已取消", str(exc))
            STATE.set_status(job.identifier, "cancelled", str(exc))
        except Exception as exc:
            STATE.update_progress(
                job.identifier,
                99,
                "导入失败",
                f"地图未发布，源 Excel 不受影响：{exc}",
            )
            STATE.set_status(job.identifier, "failed", str(exc))
            print(traceback.format_exc(), file=sys.stderr, flush=True)
        else:
            STATE.set_status(job.identifier, "complete")

    threading.Thread(
        target=worker,
        name=f"map-studio-prior-map-{job.identifier}",
        daemon=True,
    ).start()
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
    server_version = "SupermarketMapStudio/2.0"

    def log_message(self, _format: str, *_args: Any) -> None:
        return

    def send_json(self, status: int, payload: Dict[str, Any]) -> None:
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_security_headers()
        self.end_headers()
        self.wfile.write(body)

    def send_security_headers(self) -> None:
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header(
            "Content-Security-Policy",
            "default-src 'self'; connect-src 'self'; img-src 'self' data: blob:; "
            "script-src 'self'; style-src 'self'; object-src 'none'; base-uri 'none'; "
            "frame-ancestors 'none'",
        )

    def authorize_post(self, *, require_token: bool = False) -> None:
        expected_token = getattr(self.server, "session_token", "")
        supplied_token = self.headers.get("X-MarketScanner-Session-Token", "")
        if require_token and (
            not isinstance(expected_token, str)
            or not expected_token
            or not secrets.compare_digest(supplied_token, expected_token)
        ):
            raise RequestForbidden("Missing or invalid local session token.")
        origin = self.headers.get("Origin")
        if origin is None:
            return
        allowed_origins = getattr(self.server, "allowed_origins", frozenset())
        if origin not in allowed_origins:
            raise RequestForbidden("Unexpected request Origin.")

    def session_cookie_id(self) -> str:
        """Return the opaque HttpOnly session id supplied by the browser."""
        cookie = SimpleCookie()
        try:
            cookie.load(self.headers.get("Cookie", ""))
        except Exception as exc:
            raise RequestForbidden("Invalid local session cookie.") from exc
        morsel = cookie.get("marketscanner_session")
        return morsel.value if morsel is not None else ""

    def authorize_session(self) -> str | None:
        """Require a short-lived HttpOnly session (token header remains CLI-only auth)."""
        supplied_token = self.headers.get("X-MarketScanner-Session-Token", "")
        expected_token = getattr(self.server, "session_token", "")
        if supplied_token and expected_token and secrets.compare_digest(supplied_token, expected_token):
            return None
        session_id = self.session_cookie_id()
        sessions = getattr(self.server, "authenticated_sessions", {})
        expires_at = sessions.get(session_id) if isinstance(sessions, dict) else None
        if not isinstance(expires_at, (int, float)) or expires_at <= time.time():
            if isinstance(sessions, dict) and session_id:
                sessions.pop(session_id, None)
            raise RequestForbidden("Missing or expired local session.")
        return session_id

    def send_session_response(self, session_id: str, *, refreshed: bool = False) -> None:
        body = json.dumps(
            {
                "authenticated": True,
                "refreshed": refreshed,
                "expires_in_seconds": SESSION_TTL_SECONDS,
            }
        ).encode("utf-8")
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header(
            "Set-Cookie",
            "marketscanner_session="
            f"{session_id}; HttpOnly; SameSite=Strict; Path=/; "
            f"Max-Age={SESSION_TTL_SECONDS}",
        )
        self.send_security_headers()
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
            self.send_json(
                HTTPStatus.OK,
                {
                    "ok": not STATE.startup_errors,
                    "service": "MarketScannerMapStudio",
                    "authentication_required": True,
                },
            )
            return
        if path.startswith("/api/"):
            try:
                self.authorize_session()
            except RequestError as exc:
                self.send_json(exc.status, exc.details())
                return
        if path == "/api/about":
            runtime_mode = getattr(self.server, "runtime_mode", "development")
            self.send_json(
                HTTPStatus.OK,
                {
                    "product": "Supermarket Map Studio",
                    "version": MAP_STUDIO_VERSION,
                    "runtime_mode": runtime_mode,
                    "git_sha": SOURCE_GIT_SHA,
                    "python": sys.version.split()[0],
                    "platform": platform.platform(),
                    "startup_diagnostics": startup_diagnostics(runtime_mode),
                },
            )
            return
        if path == "/api/recovery":
            interrupted = [
                job_summary_payload(job)
                for job in STATE.list()
                if job.status == "interrupted"
            ]
            self.send_json(
                HTTPStatus.OK,
                {
                    "startup_errors": list(STATE.startup_errors),
                    "interrupted_jobs": interrupted,
                    "actions": [
                        "Inspect the original immutable input before retrying.",
                        "Use a new output/staging directory for a retry.",
                        "Keep the previous current/published version unchanged.",
                        "Export diagnostics before clearing retained staging.",
                    ],
                },
            )
            return
        if path == "/api/jobs":
            self.send_json(
                HTTPStatus.OK,
                {"jobs": [job_summary_payload(job) for job in STATE.list()]},
            )
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
            path = urlparse(self.path).path
            if path == "/api/session/bootstrap":
                self.authorize_post(require_token=True)
                data = self.read_json()
                session_id = secrets.token_urlsafe(32)
                sessions = getattr(self.server, "authenticated_sessions", None)
                if not isinstance(sessions, dict):
                    raise RequestForbidden("Session service is unavailable.")
                sessions[session_id] = time.time() + SESSION_TTL_SECONDS
                self.send_session_response(session_id)
                return
            session_id = self.authorize_session()
            self.authorize_post()
            data = self.read_json()
            if path == "/api/session/refresh":
                if not session_id:
                    raise RequestForbidden(
                        "Session refresh requires an authenticated browser cookie."
                    )
                sessions = getattr(self.server, "authenticated_sessions", None)
                if not isinstance(sessions, dict):
                    raise RequestForbidden("Session service is unavailable.")
                sessions[session_id] = time.time() + SESSION_TTL_SECONDS
                self.send_session_response(session_id, refreshed=True)
                return
            if path == "/api/qualification/field/inspect":
                try:
                    evidence = inspect_field_evidence(
                        resolve_path(data.get("path"), "Field qualification evidence"),
                        required_site_type="supermarket",
                    )
                except (OSError, QualificationError) as exc:
                    raise RequestError(f"现场验收证据无效：{exc}") from exc
                self.send_json(HTTPStatus.OK, evidence)
                return
            if path == "/api/dialog":
                selected = choose_path(str(data.get("mode", "directory")), str(data.get("title", "Select folder")))
                self.send_json(HTTPStatus.OK, {"path": selected})
                return
            if path == "/api/diagnostics/export":
                self.send_json(
                    HTTPStatus.OK,
                    export_operator_diagnostics(
                        resolve_path(
                            data.get("output_directory"),
                            "Diagnostics output directory",
                        )
                    ),
                )
                return
            if path == "/api/session/inspect":
                self.send_json(HTTPStatus.OK, inspect_session(require_session(data.get("session"))))
                return
            if path == "/api/session/cleanup-finalized-checkpoint":
                self.send_json(
                    HTTPStatus.OK,
                    cleanup_finalized_checkpoint(
                        require_session(data.get("session")),
                        confirmed=data.get("confirmed"),
                        expected_tracking_session_id=data.get(
                            "expected_tracking_session_id"
                        ),
                        expected_finalized_at_unix=data.get(
                            "expected_finalized_at_unix"
                        ),
                        expected_metadata_sha256=data.get(
                            "expected_metadata_sha256"
                        ),
                        expected_checkpoint_sha256=data.get(
                            "expected_checkpoint_sha256"
                        ),
                    ),
                )
                return
            if path == "/api/session/result":
                job = find_existing_result(require_session(data.get("session")))
                self.send_json(HTTPStatus.OK, {"found": job is not None, "job": job_payload(job) if job else None})
                return
            if path == "/api/prior-map/convert":
                job = start_prior_map_job(data)
                self.send_json(HTTPStatus.ACCEPTED, job_payload(job))
                return
            if path == "/api/prior-map/inspect":
                package = resolve_path(data.get("package"), "Prior-map package")
                validation = validate_prior_map_package(package)
                self.send_json(
                    HTTPStatus.OK if validation["valid"] else HTTPStatus.BAD_REQUEST,
                    {
                        **validation,
                        "manifest": load_json(package / "manifest.json", {}),
                        "validation_report": load_json(
                            package / "validation_report.json", {}
                        ),
                    },
                )
                return
            if path == "/api/jobs":
                job = start_job(data)
                self.send_json(HTTPStatus.ACCEPTED, job_payload(job))
                return
            if path.startswith("/api/jobs/") and path.endswith("/cancel"):
                job_id = path.split("/")[3]
                job = STATE.cancel(job_id)
                self.send_json(HTTPStatus.ACCEPTED, job_payload(job))
                return
            if path.startswith("/api/jobs/") and path.endswith("/merge/preview"):
                job_id = path.split("/")[3]
                job = STATE.get(job_id)
                if job is None:
                    raise RequestError("Completed base job not found.")
                self.send_json(HTTPStatus.OK, merge_preview(job, data))
                return
            if path.startswith("/api/jobs/") and path.endswith("/merge/apply"):
                job_id = path.split("/")[3]
                job = STATE.get(job_id)
                if job is None:
                    raise RequestError("Completed base job not found.")
                merge_job = start_manual_merge(job, data)
                self.send_json(HTTPStatus.ACCEPTED, job_payload(merge_job))
                return
            if path.startswith("/api/jobs/") and path.endswith("/localized/edit"):
                job_id = path.split("/")[3]
                job = STATE.get(job_id)
                if job is None:
                    raise RequestError("Completed localized job not found.")
                self.send_json(HTTPStatus.OK, apply_localized_edit(job, data))
                return
            if path.startswith("/api/jobs/") and path.endswith("/localized/state"):
                job_id = path.split("/")[3]
                job = STATE.get(job_id)
                if job is None:
                    raise RequestError("Completed localized job not found.")
                self.send_json(
                    HTTPStatus.OK,
                    apply_localized_state_transition(
                        job,
                        data,
                        runtime_mode=getattr(
                            self.server, "runtime_mode", "development"
                        ),
                    ),
                )
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
            self.send_json(exc.status, exc.details())
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
        if len(parts) == 6 and parts[4] == "runtime-log":
            self.serve_runtime_log(job, parts[5])
            return
        if (
            len(parts) >= 9
            and parts[4] == "localized"
            and parts[5] == "versions"
            and parts[7] == "artifact"
        ):
            self.serve_localized_artifact(
                job, parts[6], "/".join(parts[8:])
            )
            return
        self.send_json(HTTPStatus.NOT_FOUND, {"error": "Unknown job endpoint."})

    def serve_runtime_log(self, job: Job, name: str) -> None:
        if (
            STATE.state_dir is None
            or re.fullmatch(
                re.escape(job.identifier) + r"-rtabmap-reprocess-(?:fast|discovery)\.log",
                name,
            )
            is None
        ):
            self.send_json(HTTPStatus.NOT_FOUND, {"error": "Runtime log is not available."})
            return
        self.serve_file(STATE.state_dir, name)

    def serve_localized_artifact(
        self, job: Job, version_id: str, name: str
    ) -> None:
        if job.kind != "localized" or name not in PUBLISHED_VERSION_FILES:
            self.send_json(HTTPStatus.NOT_FOUND, {"error": "Artifact is not available."})
            return
        try:
            store = LocalizedVersionStore(job.output_dir)
            snapshot = store.resolve_version(version_id)
            content = store.read_verified_artifact(snapshot.version_id, name)
        except LocalizedStoreError:
            self.send_json(HTTPStatus.NOT_FOUND, {"error": "Localized version was not found."})
            return
        self.send_content(name, content)

    def serve_artifact(self, job: Job, name: str) -> None:
        if name not in ARTIFACTS and not name.startswith("preview_frames/"):
            self.send_json(HTTPStatus.NOT_FOUND, {"error": "Artifact is not available."})
            return
        self.serve_file(job.output_dir, name)

    def serve_file(self, root: Path, name: str) -> None:
        path = (root / name).resolve()
        if root.resolve() not in path.parents or not path.is_file():
            self.send_json(HTTPStatus.NOT_FOUND, {"error": "Artifact was not found."})
            return
        self.send_content(name, path.read_bytes())

    def send_content(self, name: str, content: bytes) -> None:
        content_type = {
            ".png": "image/png",
            ".jpg": "image/jpeg",
            ".jpeg": "image/jpeg",
            ".json": "application/json; charset=utf-8",
            ".geojson": "application/geo+json; charset=utf-8",
        }.get(Path(name).suffix, "application/octet-stream")
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(content)))
        self.send_header("Cache-Control", "no-store")
        self.send_security_headers()
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
        self.send_security_headers()
        self.end_headers()
        self.wfile.write(content)


def startup_diagnostics(mode: str = "development") -> Dict[str, Any]:
    state_directory = STATE.state_dir or Path(tempfile.gettempdir())
    checks: list[Dict[str, Any]] = []
    checks.append({
        "name": "python_3_10_or_newer",
        "ok": sys.version_info >= (3, 10),
        "detail": sys.version.split()[0],
    })
    try:
        state_resolved = state_directory.resolve()
        temporary_root = Path(tempfile.gettempdir()).resolve()
        state_is_temporary = state_resolved == temporary_root or temporary_root in state_resolved.parents
    except OSError:
        state_is_temporary = True
    checks.append({
        "name": "job_state_not_os_temp",
        "ok": mode != "production" or (STATE.state_dir is not None and not state_is_temporary),
        "detail": "platform app-data" if not state_is_temporary else "OS temporary directory",
    })
    try:
        usage = shutil.disk_usage(state_directory)
        checks.append({
            "name": "state_disk_free_1_gib",
            "ok": usage.free >= 1024 * 1024 * 1024,
            "detail": str(usage.free),
        })
    except OSError as exc:
        checks.append({"name": "state_disk_free_1_gib", "ok": False, "detail": str(exc)})
    reprocess = offline.find_reprocess_binary()
    factor = find_factor_graph_binary()
    native_checks = (
        [
            native_tool_diagnostic("rtabmap_reprocess", reprocess, strict=True),
            native_tool_diagnostic("relative_se2_factor_helper", factor, strict=True),
        ]
        if mode == "production"
        else [
            native_tool_diagnostic("rtabmap_reprocess", reprocess),
            native_tool_diagnostic("relative_se2_factor_helper", factor),
        ]
    )
    checks.extend([
        *native_checks,
        {
            "name": "job_journal",
            "ok": not STATE.startup_errors,
            "detail": "; ".join(STATE.startup_errors) or "ok",
        },
        operator_package_diagnostic(require_package=mode == "production"),
    ])
    critical_names = {
        "python_3_10_or_newer",
        "state_disk_free_1_gib",
        "rtabmap_reprocess",
        "relative_se2_factor_helper",
        "operator_package_integrity",
    }
    if mode == "production":
        critical_names.update({"job_journal", "job_state_not_os_temp"})
    return {
        "mode": mode,
        "production_qualified": mode == "production" and all(item["ok"] for item in checks),
        "ok": all(item["ok"] for item in checks),
        "can_start": all(
            item["ok"] for item in checks if item["name"] in critical_names
        ),
        "checks": checks,
    }


def native_tool_diagnostic(name: str, binary: Path | None, *, strict: bool = False) -> Dict[str, Any]:
    if binary is None:
        return {"name": name, "ok": False, "detail": "not found"}
    try:
        completed = subprocess.run(
            [str(binary), "--version"],
            check=False,
            capture_output=True,
            text=True,
            timeout=10,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        return {"name": name, "ok": False, "detail": str(exc)}
    output = ((completed.stdout or "") + (completed.stderr or "")).strip()
    source_matches = (
        (not strict and SOURCE_GIT_SHA == "unknown")
        or f"marketscanner_git_sha={SOURCE_GIT_SHA}" in output
    )
    return {
        "name": name,
        "ok": completed.returncode == 0 and source_matches,
        "detail": (output.splitlines() or [str(binary)])[0][:500],
    }


def _stable_file_digest(path: Path) -> tuple[str, int]:
    try:
        with path.open("rb") as stream:
            opened = os.fstat(stream.fileno())
            before = path.lstat()
            with path.open("rb") as binding_before_stream:
                binding_before = os.fstat(binding_before_stream.fileno())
            if (
                not stat.S_ISREG(before.st_mode)
                or not stat.S_ISREG(opened.st_mode)
                or not stat.S_ISREG(binding_before.st_mode)
                or before.st_nlink != 1
                or opened.st_nlink != 1
                or binding_before.st_nlink != 1
            ):
                raise ValueError(
                    f"file is not a single-link regular file: {path.name}"
                )
            digest = hashlib.sha256()
            byte_count = 0
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(chunk)
                byte_count += len(chunk)
            opened_after = os.fstat(stream.fileno())
            after = path.lstat()
            with path.open("rb") as binding_after_stream:
                binding_after = os.fstat(binding_after_stream.fileno())
    except ValueError:
        raise
    except OSError as exc:
        raise ValueError(f"file changed while hashing: {path.name}") from exc
    path_identity = (
        before.st_dev,
        before.st_ino,
        before.st_size,
        before.st_nlink,
        before.st_mtime_ns,
        before.st_ctime_ns,
    )
    descriptor_identity = (
        opened.st_dev,
        opened.st_ino,
        opened.st_size,
        opened.st_nlink,
        opened.st_mtime_ns,
        opened.st_ctime_ns,
    )
    if (
        not stat.S_ISREG(opened_after.st_mode)
        or not stat.S_ISREG(after.st_mode)
        or not stat.S_ISREG(binding_after.st_mode)
        or opened_after.st_nlink != 1
        or after.st_nlink != 1
        or binding_after.st_nlink != 1
        or byte_count != opened.st_size
        or path_identity
        != (
            after.st_dev,
            after.st_ino,
            after.st_size,
            after.st_nlink,
            after.st_mtime_ns,
            after.st_ctime_ns,
        )
        or descriptor_identity
        != (
            binding_before.st_dev,
            binding_before.st_ino,
            binding_before.st_size,
            binding_before.st_nlink,
            binding_before.st_mtime_ns,
            binding_before.st_ctime_ns,
        )
        or descriptor_identity
        != (
            opened_after.st_dev,
            opened_after.st_ino,
            opened_after.st_size,
            opened_after.st_nlink,
            opened_after.st_mtime_ns,
            opened_after.st_ctime_ns,
        )
        or descriptor_identity
        != (
            binding_after.st_dev,
            binding_after.st_ino,
            binding_after.st_size,
            binding_after.st_nlink,
            binding_after.st_mtime_ns,
            binding_after.st_ctime_ns,
        )
    ):
        raise ValueError(f"file changed while hashing: {path.name}")
    return digest.hexdigest(), byte_count


def _stable_json_file(path: Path, maximum_bytes: int = 16 * 1024 * 1024) -> tuple[dict[str, Any], str, int]:
    flags = (
        os.O_RDONLY
        | getattr(os, "O_NOFOLLOW", 0)
        | getattr(os, "O_BINARY", 0)
    )
    try:
        descriptor = os.open(path, flags)
    except OSError as exc:
        raise ValueError(f"JSON file is unsafe or oversized: {path.name}") from exc
    try:
        try:
            opened = os.fstat(descriptor)
            before = path.lstat()
            binding_before_descriptor = os.open(path, flags)
            try:
                binding_before = os.fstat(binding_before_descriptor)
            finally:
                os.close(binding_before_descriptor)
            if (
                not stat.S_ISREG(before.st_mode)
                or not stat.S_ISREG(opened.st_mode)
                or not stat.S_ISREG(binding_before.st_mode)
                or before.st_nlink != 1
                or opened.st_nlink != 1
                or binding_before.st_nlink != 1
                or before.st_size > maximum_bytes
                or opened.st_size > maximum_bytes
            ):
                raise ValueError(f"JSON file is unsafe or oversized: {path.name}")
            chunks: list[bytes] = []
            total = 0
            while True:
                chunk = os.read(
                    descriptor, min(1024 * 1024, maximum_bytes + 1 - total)
                )
                if not chunk:
                    break
                chunks.append(chunk)
                total += len(chunk)
                if total > maximum_bytes:
                    raise ValueError(f"JSON file is oversized: {path.name}")
            opened_after = os.fstat(descriptor)
            after = path.lstat()
            binding_after_descriptor = os.open(path, flags)
            try:
                binding_after = os.fstat(binding_after_descriptor)
            finally:
                os.close(binding_after_descriptor)
        except ValueError:
            raise
        except OSError as exc:
            raise ValueError(f"JSON file changed during read: {path.name}") from exc
    finally:
        os.close(descriptor)
    data = b"".join(chunks)
    path_identity = (
        before.st_dev,
        before.st_ino,
        before.st_size,
        before.st_nlink,
        before.st_mtime_ns,
        before.st_ctime_ns,
    )
    descriptor_identity = (
        opened.st_dev,
        opened.st_ino,
        opened.st_size,
        opened.st_nlink,
        opened.st_mtime_ns,
        opened.st_ctime_ns,
    )
    if (
        len(data) > maximum_bytes
        or len(data) != before.st_size
        or len(data) != opened.st_size
        or not stat.S_ISREG(opened_after.st_mode)
        or not stat.S_ISREG(after.st_mode)
        or not stat.S_ISREG(binding_after.st_mode)
        or opened_after.st_nlink != 1
        or after.st_nlink != 1
        or binding_after.st_nlink != 1
        or path_identity
        != (
            after.st_dev,
            after.st_ino,
            after.st_size,
            after.st_nlink,
            after.st_mtime_ns,
            after.st_ctime_ns,
        )
        or descriptor_identity
        != (
            binding_before.st_dev,
            binding_before.st_ino,
            binding_before.st_size,
            binding_before.st_nlink,
            binding_before.st_mtime_ns,
            binding_before.st_ctime_ns,
        )
        or descriptor_identity
        != (
            opened_after.st_dev,
            opened_after.st_ino,
            opened_after.st_size,
            opened_after.st_nlink,
            opened_after.st_mtime_ns,
            opened_after.st_ctime_ns,
        )
        or descriptor_identity
        != (
            binding_after.st_dev,
            binding_after.st_ino,
            binding_after.st_size,
            binding_after.st_nlink,
            binding_after.st_mtime_ns,
            binding_after.st_ctime_ns,
        )
    ):
        raise ValueError(f"JSON file changed during read: {path.name}")
    value = json.loads(
        data.decode("utf-8", errors="strict"),
        parse_constant=lambda token: (_ for _ in ()).throw(ValueError(token)),
    )
    if not isinstance(value, dict):
        raise ValueError(f"JSON file is not an object: {path.name}")
    return value, hashlib.sha256(data).hexdigest(), len(data)


def operator_package_diagnostic(
    package_root: Path | None = None, *, require_package: bool = False
) -> Dict[str, Any]:
    package_root = (package_root or APP_DIR.parent.parent).resolve()
    manifest_path = package_root / "package-manifest.json"
    if not manifest_path.exists():
        return {
            "name": "operator_package_integrity",
            "ok": not require_package,
            "detail": "source checkout (DEVELOPMENT / NOT QUALIFIED FOR PRODUCTION)",
        }
    try:
        manifest, _manifest_digest, _manifest_size = _stable_json_file(
            manifest_path
        )
        files = manifest.get("files")
        if (
            manifest.get("format") != "MarketScannerMapStudioOperatorPackage"
            or manifest.get("version") != 1
            or not isinstance(files, list)
            or not files
        ):
            raise ValueError("manifest contract is invalid")
        content_sha = hashlib.sha256(
            json.dumps(files, sort_keys=True, separators=(",", ":")).encode()
        ).hexdigest()
        if content_sha != manifest.get("packageContentSha256"):
            raise ValueError("manifest content digest differs")
        for item in files:
            if not isinstance(item, dict):
                raise ValueError("file record is invalid")
            relative = item.get("relativePath")
            if (
                not isinstance(relative, str)
                or not relative
                or relative.startswith("/")
                or ".." in Path(relative).parts
                or "\\" in relative
            ):
                raise ValueError("file path is unsafe")
            candidate = package_root
            for component in Path(relative).parts:
                candidate = candidate / component
                if candidate.is_symlink():
                    raise ValueError(f"file path contains a symlink: {relative}")
            path = candidate.resolve()
            if package_root not in path.parents or not path.is_file():
                raise ValueError(f"file is missing or linked: {relative}")
            digest, size = _stable_file_digest(path)
            if size != item.get("bytes") or digest != item.get("sha256"):
                raise ValueError(f"file digest differs: {relative}")
        release_manifest = package_root / "release-manifest.json"
        release, release_digest, _release_size = _stable_json_file(
            release_manifest
        )
        if release_digest != manifest.get("releaseManifestSha256"):
            raise ValueError("release manifest digest differs")
        quality_path = package_root / "factor-graph-quality-policy.json"
        quality, quality_digest, _quality_size = _stable_json_file(
            quality_path,
            maximum_bytes=1024 * 1024,
        )
        if (
            release.get("format") != "MarketScannerReleaseManifest"
            or release.get("version") != 2
            or release.get("git_sha") != manifest.get("gitSha")
            or (require_package and release.get("git_sha") != SOURCE_GIT_SHA)
            or release.get("factor_graph_quality_policy_sha256") != quality_digest
            or quality.get("format") != "MarketScannerFactorGraphQualityPolicy"
            or quality.get("version") != 1
            or (require_package and quality.get("status") != "frozen")
        ):
            raise ValueError("release or quality policy identity differs")
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        return {
            "name": "operator_package_integrity",
            "ok": False,
            "detail": str(exc),
        }
    return {
        "name": "operator_package_integrity",
        "ok": True,
        "detail": str(manifest.get("packageContentSha256")),
    }


def export_operator_diagnostics(output_directory: Path) -> Dict[str, Any]:
    output_directory = output_directory.resolve()
    try:
        info = output_directory.lstat()
    except OSError as exc:
        raise RequestError("Diagnostics output directory is unavailable.") from exc
    if not stat.S_ISDIR(info.st_mode) or output_directory.is_symlink():
        raise RequestError("Diagnostics output must be a real directory.")
    archive = output_directory / (
        f"marketscanner-diagnostics-{int(time.time())}-{uuid.uuid4().hex[:8]}.zip"
    )
    summary = {
        "format": "MarketScannerMapStudioDiagnostics",
        "version": 1,
        "created_at_unix": time.time(),
        "product_version": MAP_STUDIO_VERSION,
        "git_sha": SOURCE_GIT_SHA,
        "python": sys.version.split()[0],
        "platform": platform.platform(),
        "startup_diagnostics": startup_diagnostics(),
        "startup_errors": list(STATE.startup_errors),
        "jobs": [job_summary_payload(job) for job in STATE.list()],
    }
    total_bytes = 0
    with zipfile.ZipFile(
        archive,
        mode="x",
        compression=zipfile.ZIP_DEFLATED,
        compresslevel=6,
    ) as bundle:
        bundle.writestr(
            "diagnostics.json",
            json.dumps(summary, indent=2, sort_keys=True).encode("utf-8") + b"\n",
        )
        if STATE.state_dir is not None:
            for path in sorted(STATE.state_dir.iterdir()):
                try:
                    path_info = path.lstat()
                except OSError:
                    continue
                if (
                    path.is_symlink()
                    or not stat.S_ISREG(path_info.st_mode)
                    or path.suffix not in {".json", ".log"}
                    or path_info.st_size > 16 * 1024 * 1024
                    or total_bytes + path_info.st_size > 128 * 1024 * 1024
                ):
                    continue
                bundle.write(path, f"job-runtime/{path.name}")
                total_bytes += path_info.st_size
    digest = hashlib.sha256()
    with archive.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return {
        "path": str(archive),
        "bytes": archive.stat().st_size,
        "sha256": digest.hexdigest(),
        "token_persisted": False,
    }


def create_server(
    port: int = 8765,
    host: str = "127.0.0.1",
    session_token: str | None = None,
    mode: str = "development",
) -> ThreadingHTTPServer:
    if host != "127.0.0.1":
        raise ValueError("Supermarket Map Studio may bind only to a loopback address.")
    server = ThreadingHTTPServer((host, port), StudioHandler)
    server.session_token = session_token or secrets.token_urlsafe(32)  # type: ignore[attr-defined]
    server.authenticated_sessions = {}  # type: ignore[attr-defined]
    server.runtime_mode = mode  # type: ignore[attr-defined]
    server.allowed_origins = frozenset({  # type: ignore[attr-defined]
        f"http://{host}:{server.server_port}",
    })
    return server


def main() -> int:
    parser = argparse.ArgumentParser(description="Start Supermarket Map Studio.")
    parser.add_argument("--version", action="store_true")
    parser.add_argument("--selfcheck", action="store_true")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--no-browser", action="store_true")
    parser.add_argument("--mode", choices=("development", "production"), default="development")
    args = parser.parse_args()
    if args.version:
        print(f"{MAP_STUDIO_VERSION} git_sha={SOURCE_GIT_SHA}")
        return 0
    if args.selfcheck:
        diagnostics = startup_diagnostics(args.mode)
        print(json.dumps(diagnostics, indent=2, sort_keys=True))
        return 0 if diagnostics["can_start"] else 1
    diagnostics = startup_diagnostics(args.mode)
    if args.mode == "production" and not diagnostics["can_start"]:
        print(json.dumps(diagnostics, indent=2, sort_keys=True), file=sys.stderr)
        return 1
    server = create_server(args.port, mode=args.mode)
    url = f"http://127.0.0.1:{server.server_port}/"
    print(f"Supermarket Map Studio: {url}", flush=True)
    if not args.no_browser:
        launch_url = f"{url}#token={server.session_token}"  # type: ignore[attr-defined]
        threading.Timer(0.25, lambda: webbrowser.open(launch_url)).start()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
