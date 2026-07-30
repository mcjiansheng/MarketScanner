#!/usr/bin/env python3
"""Create a hash-bound, no-overwrite Map Studio operator archive."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import zipfile
from typing import Any, Iterable


ROOT = Path(__file__).resolve().parents[2]
SHA_RE = re.compile(r"^[0-9a-f]{64}$")
GIT_SHA_RE = re.compile(r"^[0-9a-f]{40}$")
SOURCE_DIRECTORIES = (
    Path("tools/SupermarketMapStudio"),
    Path("tools/Supermarket2DMap"),
    Path("tools/PriorMap"),
)
EXCLUDED_PARTS = {"__pycache__", "tests", ".pytest_cache"}
EXCLUDED_NAMES = {
    "package_release.py",
    "start.sh",
    "start.bat",
    "launch_macos.command",
    "launch_windows.ps1",
}


class PackagingError(ValueError):
    pass


def sha256(path: Path) -> str:
    info = path.lstat()
    if path.is_symlink() or not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
        raise PackagingError(f"unsafe release file: {path}")
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
        opened = os.fstat(stream.fileno())
    after = path.lstat()
    expected = (info.st_dev, info.st_ino, info.st_size)
    if expected != (opened.st_dev, opened.st_ino, opened.st_size) or expected != (
        after.st_dev,
        after.st_ino,
        after.st_size,
    ):
        raise PackagingError(f"release file changed while hashing: {path}")
    return digest.hexdigest()


def validate_release_manifest(
    path: Path,
    platform_name: str,
    binaries: list[Path],
) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if (
        not isinstance(value, dict)
        or value.get("format") != "MarketScannerReleaseManifest"
        or value.get("version") != 2
        or value.get("platform") != platform_name
        or not GIT_SHA_RE.fullmatch(str(value.get("git_sha", "")))
    ):
        raise PackagingError("release manifest identity is invalid")
    body = dict(value)
    expected_body_sha = body.pop("manifest_body_sha256", None)
    encoded = json.dumps(
        body,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    if hashlib.sha256(encoded).hexdigest() != expected_body_sha:
        raise PackagingError("release manifest body digest is invalid")
    quality_path = ROOT / "tools/PriorMap/factor_graph_quality_policy.json"
    if (
        not quality_path.is_file()
        or value.get("factor_graph_quality_policy_sha256") != sha256(quality_path)
    ):
        raise PackagingError("release manifest quality policy binding is invalid")
    artifacts = value.get("artifacts")
    if not isinstance(artifacts, list):
        raise PackagingError("release manifest artifact list is invalid")
    declared = {
        item.get("file"): item
        for item in artifacts
        if isinstance(item, dict) and isinstance(item.get("file"), str)
    }
    for binary in binaries:
        item = declared.get(binary.name)
        if (
            item is None
            or item.get("bytes") != binary.stat().st_size
            or item.get("sha256") != sha256(binary)
        ):
            raise PackagingError(f"binary is not hash-bound by release manifest: {binary.name}")
        try:
            completed = subprocess.run(
                [str(binary), "--version"],
                check=False,
                capture_output=True,
                text=True,
                timeout=10,
            )
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise PackagingError(f"binary version check failed: {binary.name}") from exc
        version_output = (completed.stdout or "") + (completed.stderr or "")
        if completed.returncode != 0 or f"marketscanner_git_sha={value['git_sha']}" not in version_output:
            raise PackagingError(f"binary source SHA differs: {binary.name}")
    return value


def current_source_git_sha() -> str:
    completed = subprocess.run(
        ["git", "rev-parse", "HEAD"],
        cwd=ROOT,
        check=False,
        capture_output=True,
        text=True,
    )
    value = completed.stdout.strip().lower()
    return value if completed.returncode == 0 and GIT_SHA_RE.fullmatch(value) else "unknown"


def source_tree_is_clean() -> bool:
    scopes = [str(value) for value in SOURCE_DIRECTORIES]
    tracked = subprocess.run(
        ["git", "diff", "--quiet", "HEAD", "--", *scopes],
        cwd=ROOT,
        check=False,
    )
    untracked = subprocess.run(
        ["git", "ls-files", "--others", "--exclude-standard", "--", *scopes],
        cwd=ROOT,
        check=False,
        capture_output=True,
        text=True,
    )
    return tracked.returncode == 0 and untracked.returncode == 0 and not untracked.stdout.strip()


def source_files() -> list[tuple[Path, str]]:
    files: list[tuple[Path, str]] = []
    for relative_root in SOURCE_DIRECTORIES:
        directory = ROOT / relative_root
        for path in sorted(directory.rglob("*")):
            relative = path.relative_to(ROOT)
            if (
                path.is_dir()
                or path.is_symlink()
                or EXCLUDED_PARTS.intersection(relative.parts)
                or path.name in EXCLUDED_NAMES
                or path.suffix in {".pyc", ".bak"}
            ):
                continue
            files.append((path, relative.as_posix()))
    return files


def create_package(
    *,
    platform_name: str,
    output: Path,
    release_manifest: Path,
    reprocess_binary: Path,
    factor_binary: Path,
) -> dict[str, Any]:
    if platform_name not in {"macos", "windows"}:
        raise PackagingError("operator archive platform must be macos or windows")
    if output.exists():
        raise PackagingError("operator archive already exists")
    binaries = [path.resolve() for path in (reprocess_binary, factor_binary)]
    for binary in binaries:
        if not binary.is_file() or binary.is_symlink():
            raise PackagingError(f"release binary is missing or linked: {binary.name}")
    release = validate_release_manifest(release_manifest, platform_name, binaries)
    if current_source_git_sha() != release["git_sha"]:
        raise PackagingError("release manifest Git SHA differs from source checkout")
    if not source_tree_is_clean():
        raise PackagingError("release source tree contains tracked or untracked changes")
    entries = source_files()
    launcher_name = "launch_macos.command" if platform_name == "macos" else "launch_windows.ps1"
    launcher = ROOT / "tools/SupermarketMapStudio" / launcher_name
    entries.extend([
        (launcher, launcher_name),
        (release_manifest, "release-manifest.json"),
        (ROOT / "tools/SupermarketMapStudio/release_dependencies.json", "release-dependencies.json"),
        (ROOT / "tools/PriorMap/factor_graph_quality_policy.json", "factor-graph-quality-policy.json"),
        (binaries[0], f"bin/{binaries[0].name}"),
        (binaries[1], f"bin/{binaries[1].name}"),
    ])
    if len({name for _, name in entries}) != len(entries):
        raise PackagingError("duplicate package entry")
    file_manifest = [
        {
            "relativePath": name,
            "bytes": path.stat().st_size,
            "sha256": sha256(path),
        }
        for path, name in sorted(entries, key=lambda item: item[1])
    ]
    package_manifest: dict[str, Any] = {
        "format": "MarketScannerMapStudioOperatorPackage",
        "version": 1,
        "platform": platform_name,
        "gitSha": release["git_sha"],
        "releaseManifestSha256": sha256(release_manifest),
        "files": file_manifest,
    }
    package_manifest["packageContentSha256"] = hashlib.sha256(
        json.dumps(file_manifest, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()
    output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(
        output,
        mode="x",
        compression=zipfile.ZIP_DEFLATED,
        compresslevel=9,
    ) as archive:
        for path, name in sorted(entries, key=lambda item: item[1]):
            archive.write(path, name)
        archive.writestr(
            "package-manifest.json",
            json.dumps(package_manifest, indent=2, sort_keys=True).encode() + b"\n",
        )
    package_manifest["archiveSha256"] = sha256(output)
    package_manifest["archiveBytes"] = output.stat().st_size
    return package_manifest


def main(argv: Iterable[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--platform", choices=("macos", "windows"), required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--release-manifest", type=Path, required=True)
    parser.add_argument("--reprocess", type=Path, required=True)
    parser.add_argument("--factor-helper", type=Path, required=True)
    arguments = parser.parse_args(argv)
    try:
        result = create_package(
            platform_name=arguments.platform,
            output=arguments.output,
            release_manifest=arguments.release_manifest,
            reprocess_binary=arguments.reprocess,
            factor_binary=arguments.factor_helper,
        )
    except (OSError, json.JSONDecodeError, PackagingError) as exc:
        print(f"package error: {exc}", file=sys.stderr)
        return 2
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
