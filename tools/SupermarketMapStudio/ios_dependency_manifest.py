#!/usr/bin/env python3
"""Hash the complete generated iOS native dependency interface and libraries."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import subprocess
import sys


REPOSITORIES = ("lz4", "flann", "gtsam", "SuiteSparse", "g2o", "VTK", "pcl", "opencv", "opencv_contrib", "LASzip", "libLAS")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def generate(root: Path, output: Path, git_sha: str) -> dict:
    root = root.resolve()
    policy = json.loads((Path(__file__).with_name("release_dependencies.json")).read_text(encoding="utf-8"))
    required = policy["ios"]["required_artifacts"]
    for relative in required:
        if not (root / relative).is_file():
            raise ValueError(f"required iOS dependency artifact is missing: {relative}")
    files = []
    for directory in (root / "include", root / "lib"):
        for path in sorted(item for item in directory.rglob("*") if item.is_file() and not item.is_symlink()):
            files.append({"file": path.relative_to(root).as_posix(), "bytes": path.stat().st_size, "sha256": sha256(path)})
    repositories = []
    for name in REPOSITORIES:
        path = root / name
        if not (path / ".git").exists():
            continue
        head = subprocess.run(["git", "-C", str(path), "rev-parse", "HEAD"], check=True, capture_output=True, text=True).stdout.strip()
        dirty = bool(subprocess.run(["git", "-C", str(path), "status", "--porcelain"], check=True, capture_output=True, text=True).stdout.strip())
        repositories.append({"name": name, "head_sha": head, "patched_or_dirty": dirty})
    body = {
        "format": "MarketScannerIOSDependencyManifest",
        "version": 1,
        "app_git_sha": git_sha,
        "generated_at_utc": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "files": files,
        "source_repositories": repositories,
    }
    canonical = json.dumps(body, sort_keys=True, separators=(",", ":")).encode()
    body["manifest_body_sha256"] = hashlib.sha256(canonical).hexdigest()
    output.write_text(json.dumps(body, sort_keys=True, indent=2) + "\n", encoding="utf-8")
    return body


def verify(root: Path, manifest_path: Path) -> dict:
    root = root.resolve()
    payload = json.loads(manifest_path.read_text(encoding="utf-8"))
    if payload.get("format") != "MarketScannerIOSDependencyManifest" or payload.get("version") != 1:
        raise ValueError("iOS dependency manifest format/version is invalid")
    body = {key: value for key, value in payload.items() if key != "manifest_body_sha256"}
    expected = hashlib.sha256(json.dumps(body, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
    if payload.get("manifest_body_sha256") != expected:
        raise ValueError("iOS dependency manifest body hash differs")
    for entry in payload.get("files", []):
        path = root / entry["file"]
        if not path.is_file() or path.stat().st_size != entry["bytes"] or sha256(path) != entry["sha256"]:
            raise ValueError(f"iOS dependency artifact differs: {entry['file']}")
    return payload


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--libraries", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--git-sha", required=True)
    parser.add_argument("--verify", action="store_true")
    args = parser.parse_args()
    try:
        if args.verify:
            verify(args.libraries, args.output)
        else:
            generate(args.libraries, args.output, args.git_sha)
    except (OSError, ValueError, subprocess.SubprocessError, json.JSONDecodeError) as exc:
        print(f"iOS dependency manifest error: {exc}", file=sys.stderr)
        raise SystemExit(2)


if __name__ == "__main__":
    main()
