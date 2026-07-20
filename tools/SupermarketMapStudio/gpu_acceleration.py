#!/usr/bin/env python3
"""Runtime selection and binary protocol for PC GPU depth projection."""

from __future__ import annotations

import array
import json
import os
import platform
import struct
import subprocess
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Dict, Iterable, Optional, Sequence


BACKENDS = ("auto", "cpu", "apple_metal", "nvidia_cuda")
PROTOCOL_VERSION = 1
REQUEST_HEADER = struct.Struct("<4s6I32f")
REPLY_HEADER = struct.Struct("<4s4I")
APPLE_HELPER_ENV = "SUPERMARKET_METAL_PROJECTOR"
NVIDIA_HELPER_ENV = "SUPERMARKET_CUDA_PROJECTOR"


class GPUAccelerationError(RuntimeError):
    pass


def _repository() -> Path:
    return Path(__file__).resolve().parents[2]


def _helper_candidates(backend: str, explicit: Optional[str] = None) -> Iterable[Path]:
    if explicit:
        yield Path(explicit).expanduser()
    environment_name = APPLE_HELPER_ENV if backend == "apple_metal" else NVIDIA_HELPER_ENV
    if os.environ.get(environment_name):
        yield Path(os.environ[environment_name]).expanduser()
    repository = _repository()
    executable = "supermarket-metal-projector" if backend == "apple_metal" else "supermarket-cuda-projector"
    suffix = ".exe" if os.name == "nt" else ""
    if backend == "apple_metal":
        yield repository / "build-pc-release" / "bin" / (executable + suffix)
    else:
        yield repository / "build-pc-cuda" / "bin" / (executable + suffix)
        yield repository / "build" / "bin" / (executable + suffix)


def find_helper(backend: str, explicit: Optional[str] = None) -> Optional[Path]:
    if backend not in {"apple_metal", "nvidia_cuda"}:
        return None
    for candidate in _helper_candidates(backend, explicit):
        resolved = candidate.resolve()
        if resolved.is_file() and os.access(resolved, os.X_OK):
            return resolved
    return None


def probe_backend(backend: str, explicit: Optional[str] = None) -> Dict[str, Any]:
    helper = find_helper(backend, explicit)
    result: Dict[str, Any] = {
        "backend": backend,
        "available": False,
        "helper": str(helper) if helper else None,
        "scope": (
            "metal_depth_projection"
            if backend == "apple_metal"
            else "cuda_depth_projection_and_rtabmap_cuda_features"
        ),
    }
    if helper is None:
        result["reason"] = "GPU helper is not built or configured."
        return result
    try:
        completed = subprocess.run(
            [str(helper), "--probe"],
            capture_output=True,
            text=True,
            check=False,
            timeout=10,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        result["reason"] = str(exc)
        return result
    if completed.returncode != 0:
        result["reason"] = (completed.stderr or completed.stdout or "GPU probe failed").strip()
        return result
    try:
        payload = json.loads(completed.stdout)
    except json.JSONDecodeError as exc:
        result["reason"] = f"GPU probe returned invalid JSON: {exc}"
        return result
    if not isinstance(payload, dict) or not payload.get("available"):
        result["reason"] = "GPU helper did not report an available device."
        return result
    if payload.get("backend") != backend or payload.get("protocol") != PROTOCOL_VERSION:
        result["reason"] = "GPU helper backend or protocol does not match the requested accelerator."
        return result
    result.update(payload)
    result["available"] = True
    result["helper"] = str(helper)
    return result


def capabilities(explicit: Optional[str] = None) -> Dict[str, Any]:
    return {
        "platform": platform.platform(),
        "machine": platform.machine(),
        "backends": {
            "cpu": {
                "backend": "cpu",
                "available": True,
                "scope": "openmp_cpu",
            },
            "apple_metal": probe_backend("apple_metal", explicit),
            "nvidia_cuda": probe_backend("nvidia_cuda", explicit),
        },
    }


def nvidia_rtabmap_parameters() -> tuple[tuple[str, str], ...]:
    # Preserve the software profile's GFTT/BRIEF feature family. Only the
    # detector and matching implementations move to OpenCV CUDA.
    return (
        ("Kp/DetectorStrategy", "6"),
        ("Vis/FeatureType", "6"),
        ("GFTT/Gpu", "true"),
        ("Kp/NNStrategy", "4"),
        ("Vis/CorNNType", "4"),
    )


@dataclass
class BackendSelection:
    requested: str
    effective: str
    available: bool
    helper: Optional[Path] = None
    device: Optional[str] = None
    scope: str = "openmp_cpu"
    warnings: list[str] = field(default_factory=list)
    probe: Dict[str, Any] = field(default_factory=dict)

    @property
    def rtabmap_parameters(self) -> tuple[tuple[str, str], ...]:
        return nvidia_rtabmap_parameters() if self.effective == "nvidia_cuda" else ()

    def report(self) -> Dict[str, Any]:
        return {
            "requested_backend": self.requested,
            "effective_backend": self.effective,
            "available": self.available,
            "helper": str(self.helper) if self.helper else None,
            "device": self.device,
            "scope": self.scope,
            "warnings": list(self.warnings),
        }


def select_backend(requested: str, explicit: Optional[str] = None) -> BackendSelection:
    if requested not in BACKENDS:
        raise GPUAccelerationError(f"GPU backend must be one of: {', '.join(BACKENDS)}")
    candidates: list[str]
    if requested == "auto":
        if platform.system() == "Darwin" and platform.machine().lower() in {"arm64", "aarch64"}:
            candidates = ["apple_metal", "nvidia_cuda"]
        else:
            candidates = ["nvidia_cuda", "apple_metal"]
    elif requested == "cpu":
        candidates = []
    else:
        candidates = [requested]
    warnings: list[str] = []
    for backend in candidates:
        probe = probe_backend(backend, explicit)
        if probe.get("available"):
            return BackendSelection(
                requested=requested,
                effective=backend,
                available=True,
                helper=Path(str(probe["helper"])),
                device=str(probe.get("device") or backend),
                scope=str(probe.get("scope") or "gpu_depth_projection"),
                warnings=warnings,
                probe=probe,
            )
        warnings.append(f"{backend} unavailable: {probe.get('reason', 'probe failed')}")
    if requested not in {"auto", "cpu"}:
        warnings.append(f"Requested {requested} backend fell back to CPU/OpenMP.")
    return BackendSelection(
        requested=requested,
        effective="cpu",
        available=True,
        scope="openmp_cpu",
        warnings=warnings,
    )


def _float_bytes(values: Sequence[float]) -> bytes:
    payload = array.array("f", (float(value) for value in values))
    if sys.byteorder != "little":
        payload.byteswap()
    return payload.tobytes()


def _read_exact(stream: Any, size: int) -> bytes:
    chunks = bytearray()
    while len(chunks) < size:
        block = stream.read(size - len(chunks))
        if not block:
            raise GPUAccelerationError("GPU projection helper closed its output unexpectedly.")
        chunks.extend(block)
    return bytes(chunks)


class DepthProjector:
    def __init__(self, selection: BackendSelection):
        self.selection = selection
        self.backend = selection.effective
        self.process: Optional[subprocess.Popen[bytes]] = None
        self.projected_frames = 0
        self.projected_points = 0
        self.elapsed_seconds = 0.0
        self.failures: list[str] = []

    def __enter__(self) -> "DepthProjector":
        return self

    def _start(self) -> None:
        if self.process is not None or self.backend == "cpu" or self.selection.helper is None:
            return
        try:
            self.process = subprocess.Popen(
                [str(self.selection.helper), "--server"],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
        except OSError as exc:
            self.failures.append(str(exc))
            self.backend = "cpu"

    def __exit__(self, _exc_type: Any, _exc: Any, _traceback: Any) -> None:
        self.close()

    def close(self) -> None:
        if self.process is None:
            return
        if self.process.stdin:
            self.process.stdin.close()
        try:
            self.process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            self.process.terminate()
            try:
                self.process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=3)
        if self.process.returncode not in (0, None) and self.process.stderr:
            error = self.process.stderr.read(4000).decode("utf-8", errors="replace").strip()
            if error:
                self.failures.append(error)
        for stream in (self.process.stdout, self.process.stderr):
            if stream is not None and not stream.closed:
                stream.close()
        self.process = None

    def project(
        self,
        depths: Sequence[float],
        width: int,
        height: int,
        step: int,
        horizontal_axes: str,
        max_depth: float,
        fx: float,
        fy: float,
        cx: float,
        cy: float,
        correction_dx: float,
        correction_dy: float,
        correction_yaw: float,
        local_transform: Sequence[float],
        raw_transform: Sequence[float],
    ) -> Optional[list[tuple[float, float, float, float]]]:
        self._start()
        if self.process is None or self.backend == "cpu":
            return None
        if len(depths) != width * height or len(local_transform) != 12 or len(raw_transform) != 12:
            raise GPUAccelerationError("GPU projection request dimensions are invalid.")
        values = (
            float(max_depth), float(fx), float(fy), float(cx), float(cy),
            float(correction_dx), float(correction_dy), float(correction_yaw),
            *(float(value) for value in local_transform),
            *(float(value) for value in raw_transform),
        )
        header = REQUEST_HEADER.pack(
            b"SMGP", PROTOCOL_VERSION, int(width), int(height), int(step),
            0 if horizontal_axes == "xz" else 1, len(depths), *values,
        )
        started = time.perf_counter()
        try:
            assert self.process.stdin is not None and self.process.stdout is not None
            self.process.stdin.write(header)
            self.process.stdin.write(_float_bytes(depths))
            self.process.stdin.flush()
            reply = REPLY_HEADER.unpack(_read_exact(self.process.stdout, REPLY_HEADER.size))
            magic, version, grid_width, grid_height, count = reply
            expected_count = ((width + step - 1) // step) * ((height + step - 1) // step)
            if magic != b"SMGO" or version != PROTOCOL_VERSION or count != expected_count:
                raise GPUAccelerationError("GPU projection helper returned an invalid response header.")
            raw = _read_exact(self.process.stdout, count * 4 * 4)
            floats = array.array("f")
            floats.frombytes(raw)
            if sys.byteorder != "little":
                floats.byteswap()
            result = [tuple(floats[index:index + 4]) for index in range(0, len(floats), 4)]
            self.projected_frames += 1
            self.projected_points += count
            self.elapsed_seconds += time.perf_counter() - started
            return result
        except (BrokenPipeError, OSError, GPUAccelerationError) as exc:
            self.failures.append(str(exc))
            self.backend = "cpu"
            return None

    def report(self) -> Dict[str, Any]:
        report = self.selection.report()
        report.update(
            {
                "projection_backend": self.backend,
                "projected_frames": self.projected_frames,
                "projected_grid_points": self.projected_points,
                "projection_seconds": round(self.elapsed_seconds, 3),
                "runtime_failures": list(self.failures),
            }
        )
        if self.backend == "cpu" and self.selection.effective != "cpu":
            report["warnings"] = report["warnings"] + ["GPU projection failed at runtime and fell back to CPU."]
        return report
