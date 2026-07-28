#!/usr/bin/env python3
"""Generate a canonical hash-bound MarketScanner release manifest."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import platform
from pathlib import Path
import re
import shutil
import subprocess
import sys
from typing import Any


SHA_RE = re.compile(r"[0-9a-f]{40}")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def command_version(command: list[str]) -> str:
    completed = subprocess.run(command, check=True, capture_output=True, text=True)
    value = (completed.stdout or completed.stderr).strip().splitlines()
    if not value:
        raise ValueError(f"Version command returned no text: {command[0]}")
    return value[0][:500]


def generate(
    *, output: Path, git_sha: str, target_platform: str, artifacts: list[Path],
    dependency_policy: Path, build_time_utc: str | None = None,
) -> dict[str, Any]:
    if SHA_RE.fullmatch(git_sha) is None:
        raise ValueError("git SHA must be exactly 40 lowercase hexadecimal characters")
    if target_platform not in {"windows", "macos", "linux", "ios"}:
        raise ValueError("unsupported release platform")
    if not artifacts:
        raise ValueError("at least one release artifact is required")
    policy_bytes = dependency_policy.read_bytes()
    policy = json.loads(policy_bytes)
    if policy.get("format") != "MarketScannerDependencyPolicy" or policy.get("version") != 1:
        raise ValueError("dependency policy format/version is invalid")
    resolved = []
    for artifact in sorted((item.resolve() for item in artifacts), key=lambda item: item.name):
        if not artifact.is_file():
            raise ValueError(f"release artifact is missing: {artifact}")
        resolved.append({"file": artifact.name, "bytes": artifact.stat().st_size, "sha256": sha256(artifact)})
    timestamp = build_time_utc or datetime.now(timezone.utc).isoformat(timespec="seconds")
    if not timestamp.endswith("+00:00") and not timestamp.endswith("Z"):
        raise ValueError("build time must be an explicit UTC timestamp")
    compiler_command = shutil.which("c++") or shutil.which("clang++") or shutil.which("cl")
    compiler = command_version([compiler_command, "--version"]) if compiler_command else "unavailable"
    manifest = {
        "format": "MarketScannerReleaseManifest",
        "version": 1,
        "git_sha": git_sha,
        "build_time_utc": timestamp,
        "platform": target_platform,
        "host": platform.platform(),
        "compiler": compiler,
        "python": platform.python_version(),
        "cmake": command_version(["cmake", "--version"]),
        "dependency_policy_sha256": hashlib.sha256(policy_bytes).hexdigest(),
        "dependency_policy": policy,
        "artifacts": resolved,
    }
    encoded = json.dumps(manifest, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()
    manifest["manifest_body_sha256"] = hashlib.sha256(encoded).hexdigest()
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(manifest, ensure_ascii=False, sort_keys=True, indent=2) + "\n", encoding="utf-8")
    return manifest


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--git-sha", required=True)
    parser.add_argument("--platform", required=True)
    parser.add_argument("--dependency-policy", type=Path, required=True)
    parser.add_argument("--artifact", type=Path, action="append", required=True)
    parser.add_argument("--build-time-utc")
    args = parser.parse_args()
    try:
        generate(
            output=args.output,
            git_sha=args.git_sha,
            target_platform=args.platform,
            artifacts=args.artifact,
            dependency_policy=args.dependency_policy,
            build_time_utc=args.build_time_utc,
        )
    except (OSError, ValueError, json.JSONDecodeError, subprocess.SubprocessError) as exc:
        print(f"release manifest error: {exc}", file=sys.stderr)
        raise SystemExit(2)


if __name__ == "__main__":
    main()
