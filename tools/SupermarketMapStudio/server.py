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
from dataclasses import dataclass, field
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from types import SimpleNamespace
from typing import Any, Dict, List, Optional
from urllib.parse import unquote, urlparse


APP_DIR = Path(__file__).resolve().parent
WEB_DIR = APP_DIR / "web"
MAPPER_DIR = APP_DIR.parent / "Supermarket2DMap"
if str(MAPPER_DIR) not in sys.path:
    sys.path.insert(0, str(MAPPER_DIR))

import supermarket_2d_map as base
import supermarket_multi_device_map as multi
import supermarket_staged_map as staged


ARTIFACTS = (
    "preview.png",
    "occupancy_grid.png",
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


class StudioState:
    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.jobs: Dict[str, Job] = {}

    def add(self, kind: str, output_dir: Path) -> Job:
        with self.lock:
            resolved = output_dir.resolve()
            if any(
                existing.output_dir.resolve() == resolved and existing.status in {"queued", "running"}
                for existing in self.jobs.values()
            ):
                raise RequestError("This output directory is already reserved by a Map Studio task.")
            job = Job(identifier=uuid.uuid4().hex[:12], kind=kind, output_dir=output_dir)
            self.jobs[job.identifier] = job
        return job

    def get(self, job_id: str) -> Optional[Job]:
        with self.lock:
            return self.jobs.get(job_id)

    def set_status(self, job_id: str, status: str, error: Optional[str] = None) -> None:
        with self.lock:
            job = self.jobs[job_id]
            job.status = status
            job.error = error
            if status in {"complete", "failed"}:
                job.finished_at = time.time()

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
            )
            self.jobs[job.identifier] = job
            return job


STATE = StudioState()


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


def map_options(data: Dict[str, Any]) -> Dict[str, Any]:
    options = data.get("options", {})
    if not isinstance(options, dict):
        raise RequestError("Options must be an object.")
    axes = options.get("horizontal_axes", "xz")
    if axes not in {"xz", "xy"}:
        raise RequestError("Horizontal axes must be xz or xy.")
    preview_3d_quality = str(options.get("preview_3d_quality", "detailed"))
    if preview_3d_quality not in base.PREVIEW_3D_PROFILES:
        raise RequestError("3D preview quality must be quick, detailed or maximum.")
    return {
        "resolution": number(options.get("resolution"), "Resolution", 0.05),
        "preview_resolution": number(options.get("preview_resolution"), "Preview resolution", 0.10),
        "trajectory_radius": number(options.get("trajectory_radius"), "Trajectory radius", 1.25),
        "tag_snap_distance": number(options.get("tag_snap_distance"), "Tag snap distance", 1.0),
        "occupied_inflate_radius": number(options.get("occupied_inflate_radius"), "Occupied inflation radius", 0.08),
        "free_ray_max_range": number(options.get("free_ray_max_range"), "Free ray maximum range", 8.0),
        "horizontal_axes": axes,
        "preview_3d_quality": preview_3d_quality,
    }


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
    }
    if job.status == "complete":
        payload["artifacts"] = job_artifacts(job)
        payload["quality_report"] = load_json(job.output_dir / "quality_report.json", {})
        payload["review_items"] = load_json(job.output_dir / "review_items.json", {"items": []})
        payload["map"] = load_json(job.output_dir / "map.json", {})
    return payload


def inspect_session(session: Path) -> Dict[str, Any]:
    config = base.MapConfig(0.05, 0.1, 1.25, 1.0, 0.08, 8.0, "xz", False)
    segments = base.discover_segments(session, config)
    return {
        "session": str(session),
        "segment_count": len(segments),
        "node_count": sum(len(segment.poses) for segment in segments),
        "price_tag_count": sum(len(segment.price_tags) for segment in segments),
        "segments": [
            {
                "index": segment.index,
                "database": str(segment.database_path) if segment.database_path else None,
                "nodes": len(segment.poses),
                "price_tags": len(segment.price_tags),
                "warnings": segment.sqlite_warnings,
            }
            for segment in segments
        ],
    }


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


def run_stage(data: Dict[str, Any], output: Path) -> None:
    session = require_session(data.get("session"))
    options = map_options(data)
    config_path = temporary_json(data.get("stage_config"), "map-studio-stage-")
    try:
        args = SimpleNamespace(
            session=str(session),
            stage_config=str(config_path) if config_path else None,
            output=str(output),
            points_csv=optional_points(data.get("points_csv")),
            **options,
        )
        staged.generate(args)
    finally:
        remove_temporary(config_path)


def run_basic_map(data: Dict[str, Any], output: Path) -> None:
    session = require_session(data.get("session"))
    options = map_options(data)
    corrections_path = temporary_json(data.get("corrections"), "map-studio-corrections-")
    try:
        args = SimpleNamespace(
            session=str(session),
            output=str(output),
            points_csv=optional_points(data.get("points_csv")),
            corrections=str(corrections_path) if corrections_path else None,
            auto_align_segments=bool(data.get("auto_align_segments", False)),
            **options,
        )
        base.generate(args)
    finally:
        remove_temporary(corrections_path)


def run_multi(data: Dict[str, Any], output: Path) -> None:
    raw_devices = data.get("devices")
    if not isinstance(raw_devices, list) or len(raw_devices) < 2:
        raise RequestError("At least two device sessions are required.")
    devices = []
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
        devices.append(device)

    options = map_options(data)
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
        multi.generate(args)
    finally:
        remove_temporary(config_path)


def start_job(data: Dict[str, Any]) -> Job:
    kind = data.get("kind")
    if kind not in {"map", "stage", "multi"}:
        raise RequestError("Task kind must be map, stage or multi.")
    output = require_output(data.get("output"))
    job = STATE.add(kind, output)

    def worker() -> None:
        STATE.set_status(job.identifier, "running")
        try:
            if kind == "map":
                run_basic_map(data, output)
            elif kind == "stage":
                run_stage(data, output)
            else:
                run_multi(data, output)
        except Exception as exc:
            STATE.set_status(job.identifier, "failed", str(exc))
            print(traceback.format_exc(), file=sys.stderr, flush=True)
        else:
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
