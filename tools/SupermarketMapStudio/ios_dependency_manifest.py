#!/usr/bin/env python3
"""Create and verify platform-scoped iOS native dependency manifests."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import mmap
from pathlib import Path
import struct
import subprocess
import sys
from typing import Any


REPOSITORIES = (
    "lz4",
    "flann",
    "gtsam",
    "SuiteSparse",
    "g2o",
    "VTK",
    "pcl",
    "opencv",
    "opencv_contrib",
    "LASzip",
    "libLAS",
)
SUPPORTED_PLATFORMS = {"iphoneos": 2, "iphonesimulator": 7}
PLATFORM_NAMES = {value: key for key, value in SUPPORTED_PLATFORMS.items()}
CPU_ARCHITECTURES = {
    7: "i386",
    12: "arm",
    0x01000007: "x86_64",
    0x0100000C: "arm64",
}
LC_BUILD_VERSION = 0x32
AR_MAGIC = b"!<arch>\n"
MACHO_MAGICS = {
    b"\xce\xfa\xed\xfe": ("<", False),
    b"\xcf\xfa\xed\xfe": ("<", True),
    b"\xfe\xed\xfa\xce": (">", False),
    b"\xfe\xed\xfa\xcf": (">", True),
}
FAT_MAGICS = {
    b"\xca\xfe\xba\xbe": (">", False),
    b"\xbe\xba\xfe\xca": ("<", False),
    b"\xca\xfe\xba\xbf": (">", True),
    b"\xbf\xba\xfe\xca": ("<", True),
}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _checked_region(start: int, size: int, limit: int, label: str) -> tuple[int, int]:
    if start < 0 or size < 0 or start > limit or size > limit - start:
        raise ValueError(f"malformed Mach-O {label} range")
    return start, start + size


def _record_macho(
    data: mmap.mmap,
    start: int,
    size: int,
    evidence: dict[str, Any],
) -> None:
    magic = bytes(data[start : start + 4])
    endian, is_64 = MACHO_MAGICS[magic]
    header_size = 32 if is_64 else 28
    _checked_region(start, header_size, start + size, "header")
    cpu_type = struct.unpack_from(f"{endian}I", data, start + 4)[0]
    command_count = struct.unpack_from(f"{endian}I", data, start + 16)[0]
    command_bytes = struct.unpack_from(f"{endian}I", data, start + 20)[0]
    if command_count > 65536:
        raise ValueError("malformed Mach-O load command count")
    command_start = start + header_size
    _, command_end = _checked_region(
        command_start, command_bytes, start + size, "load command"
    )
    platforms: set[int] = set()
    cursor = command_start
    for _ in range(command_count):
        if cursor + 8 > command_end:
            raise ValueError("truncated Mach-O load command")
        command, command_size = struct.unpack_from(f"{endian}II", data, cursor)
        if command_size < 8 or cursor + command_size > command_end:
            raise ValueError("invalid Mach-O load command size")
        if command == LC_BUILD_VERSION:
            if command_size < 24:
                raise ValueError("truncated LC_BUILD_VERSION command")
            platforms.add(struct.unpack_from(f"{endian}I", data, cursor + 8)[0])
        cursor += command_size
    if cursor != command_end:
        raise ValueError("Mach-O load commands do not consume sizeofcmds")
    evidence["macho_object_count"] += 1
    evidence["architectures"].add(CPU_ARCHITECTURES.get(cpu_type, f"cpu-{cpu_type}"))
    if not platforms:
        evidence["objects_without_build_version"] += 1
    evidence["platform_ids"].update(platforms)


def _walk_binary(
    data: mmap.mmap,
    start: int,
    size: int,
    evidence: dict[str, Any],
    depth: int = 0,
) -> None:
    if depth > 4:
        raise ValueError("binary container nesting is too deep")
    _checked_region(start, size, len(data), "container")
    magic = bytes(data[start : start + min(8, size)])
    if magic[:4] in MACHO_MAGICS:
        _record_macho(data, start, size, evidence)
        return
    if magic[:4] in FAT_MAGICS:
        endian, is_64 = FAT_MAGICS[magic[:4]]
        if size < 8:
            raise ValueError("truncated universal binary header")
        architecture_count = struct.unpack_from(f"{endian}I", data, start + 4)[0]
        if architecture_count == 0 or architecture_count > 64:
            raise ValueError("invalid universal binary architecture count")
        entry_size = 32 if is_64 else 20
        table_size = architecture_count * entry_size
        _checked_region(start + 8, table_size, start + size, "universal table")
        for index in range(architecture_count):
            entry = start + 8 + index * entry_size
            if is_64:
                offset, slice_size = struct.unpack_from(f"{endian}QQ", data, entry + 8)
            else:
                offset, slice_size = struct.unpack_from(f"{endian}II", data, entry + 8)
            slice_start, slice_end = _checked_region(
                start + offset, slice_size, start + size, "universal slice"
            )
            _walk_binary(
                data, slice_start, slice_end - slice_start, evidence, depth + 1
            )
        return
    if magic == AR_MAGIC:
        cursor = start + len(AR_MAGIC)
        end = start + size
        while cursor < end:
            if cursor + 60 > end:
                raise ValueError("truncated static archive member header")
            header = bytes(data[cursor : cursor + 60])
            if header[58:60] != b"`\n":
                raise ValueError("invalid static archive member header")
            try:
                member_size = int(header[48:58].decode("ascii").strip())
            except (UnicodeDecodeError, ValueError) as exc:
                raise ValueError("invalid static archive member size") from exc
            member_start, member_end = _checked_region(
                cursor + 60, member_size, end, "archive member"
            )
            name = header[:16].decode("ascii", errors="replace").strip()
            payload_start = member_start
            if name.startswith("#1/"):
                try:
                    name_bytes = int(name[3:])
                except ValueError as exc:
                    raise ValueError("invalid BSD archive member name") from exc
                if name_bytes > member_size:
                    raise ValueError("truncated BSD archive member name")
                payload_start += name_bytes
            payload_size = member_end - payload_start
            if payload_size >= 4:
                payload_magic = bytes(data[payload_start : payload_start + 8])
                if (
                    payload_magic[:4] in MACHO_MAGICS
                    or payload_magic[:4] in FAT_MAGICS
                    or payload_magic == AR_MAGIC
                ):
                    _walk_binary(data, payload_start, payload_size, evidence, depth + 1)
            cursor = member_end + (member_size % 2)
        if cursor != end:
            raise ValueError("static archive alignment exceeds file size")
        return
    raise ValueError("artifact is not a Mach-O binary, universal binary, or archive")


def inspect_binary(path: Path) -> dict[str, Any]:
    evidence: dict[str, Any] = {
        "architectures": set(),
        "platform_ids": set(),
        "macho_object_count": 0,
        "objects_without_build_version": 0,
    }
    with path.open("rb") as handle:
        with mmap.mmap(handle.fileno(), 0, access=mmap.ACCESS_READ) as data:
            _walk_binary(data, 0, len(data), evidence)
    if evidence["macho_object_count"] == 0:
        raise ValueError(f"no Mach-O object was found in {path}")
    platform_ids = sorted(evidence.pop("platform_ids"))
    evidence["architectures"] = sorted(evidence["architectures"])
    evidence["platforms"] = [
        {"id": platform_id, "name": PLATFORM_NAMES.get(platform_id, "unknown")}
        for platform_id in platform_ids
    ]
    return evidence


def _policy() -> dict[str, Any]:
    payload = json.loads(
        (Path(__file__).with_name("release_dependencies.json")).read_text(
            encoding="utf-8"
        )
    )
    if not isinstance(payload, dict):
        raise ValueError("iOS dependency policy root must be an object")
    return payload


def _string_list(
    container: dict[str, Any], key: str, label: str
) -> list[str]:
    value = container.get(key)
    if (
        not isinstance(value, list)
        or any(not isinstance(item, str) or not item for item in value)
        or len(set(value)) != len(value)
    ):
        raise ValueError(f"{label} must be a duplicate-free list of non-empty strings")
    return value


def _ios_policy_lists(policy: dict[str, Any]) -> tuple[list[str], list[str], list[str]]:
    ios = policy.get("ios")
    if not isinstance(ios, dict):
        raise ValueError("iOS dependency policy ios section must be an object")
    required_artifacts = _string_list(
        ios, "required_artifacts", "iOS dependency policy required_artifacts"
    )
    platform_artifacts = _string_list(
        ios,
        "platform_validated_artifacts",
        "iOS dependency policy platform_validated_artifacts",
    )
    required_architectures = _string_list(
        ios,
        "required_architectures",
        "iOS dependency policy required_architectures",
    )
    missing = sorted(set(platform_artifacts) - set(required_artifacts))
    if missing:
        raise ValueError(
            "iOS dependency policy platform artifacts are not required artifacts: "
            + ", ".join(missing)
        )
    return required_artifacts, platform_artifacts, required_architectures


def _validate_platform(platform: str) -> None:
    if platform not in SUPPORTED_PLATFORMS:
        raise ValueError(f"unsupported iOS dependency platform: {platform}")


def _validate_scoped_root(root: Path, platform: str, ci_mode: bool) -> None:
    if ci_mode and (root.name != platform or root.parent.name != "Libraries"):
        raise ValueError(
            "CI requires a platform-scoped dependency prefix at "
            f"Libraries/{platform}; legacy or unscoped prefixes are forbidden"
        )


def _artifact_files(root: Path) -> list[dict[str, Any]]:
    files: list[dict[str, Any]] = []
    for directory in (root / "include", root / "lib"):
        if not directory.is_dir():
            raise ValueError(f"required iOS dependency directory is missing: {directory.name}")
        for path in sorted(directory.rglob("*")):
            if path.is_symlink() or not path.is_file():
                continue
            files.append(
                {
                    "file": path.relative_to(root).as_posix(),
                    "bytes": path.stat().st_size,
                    "sha256": sha256(path),
                }
            )
    return files


def _binary_evidence(root: Path, platform: str, policy: dict[str, Any]) -> list[dict[str, Any]]:
    expected_platform = SUPPORTED_PLATFORMS[platform]
    _, platform_artifacts, required_architectures = _ios_policy_lists(policy)
    required_architectures = sorted(required_architectures)
    results: list[dict[str, Any]] = []
    for relative in platform_artifacts:
        path = root / relative
        if not path.is_file() or path.is_symlink():
            raise ValueError(f"required platform artifact is missing or unsafe: {relative}")
        evidence = inspect_binary(path)
        platform_ids = [entry["id"] for entry in evidence["platforms"]]
        if platform_ids != [expected_platform]:
            raise ValueError(
                f"iOS dependency platform mismatch for {relative}: "
                f"expected {platform} ({expected_platform}), found {platform_ids}"
            )
        if evidence["objects_without_build_version"] != 0:
            raise ValueError(
                f"iOS dependency platform is missing from one or more Mach-O objects: {relative}"
            )
        if evidence["architectures"] != required_architectures:
            raise ValueError(
                f"iOS dependency architecture mismatch for {relative}: "
                f"expected {required_architectures}, found {evidence['architectures']}"
            )
        results.append({"file": relative, **evidence})
    return results


def generate(
    root: Path,
    output: Path,
    git_sha: str,
    platform: str,
    *,
    ci_mode: bool = False,
) -> dict[str, Any]:
    _validate_platform(platform)
    if len(git_sha) != 40 or any(character not in "0123456789abcdef" for character in git_sha.lower()):
        raise ValueError("app git SHA must contain exactly 40 hexadecimal characters")
    root = root.resolve()
    _validate_scoped_root(root, platform, ci_mode)
    policy = _policy()
    required_artifacts, _, _ = _ios_policy_lists(policy)
    for relative in required_artifacts:
        if not (root / relative).is_file():
            raise ValueError(f"required iOS dependency artifact is missing: {relative}")
    body: dict[str, Any] = {
        "format": "MarketScannerIOSDependencyManifest",
        "version": 2,
        "platform": platform,
        "prefix_scope": f"Libraries/{platform}",
        "app_git_sha": git_sha.lower(),
        "generated_at_utc": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "files": _artifact_files(root),
        "platform_artifacts": _binary_evidence(root, platform, policy),
        "source_repositories": [],
    }
    for name in REPOSITORIES:
        path = root / name
        if not (path / ".git").exists():
            continue
        head = subprocess.run(
            ["git", "-C", str(path), "rev-parse", "HEAD"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
        dirty = bool(
            subprocess.run(
                ["git", "-C", str(path), "status", "--porcelain"],
                check=True,
                capture_output=True,
                text=True,
            ).stdout.strip()
        )
        body["source_repositories"].append(
            {"name": name, "head_sha": head, "patched_or_dirty": dirty}
        )
    canonical = json.dumps(body, sort_keys=True, separators=(",", ":")).encode()
    body["manifest_body_sha256"] = hashlib.sha256(canonical).hexdigest()
    output.write_text(json.dumps(body, sort_keys=True, indent=2) + "\n", encoding="utf-8")
    return body


def verify(
    root: Path,
    manifest_path: Path,
    platform: str,
    *,
    ci_mode: bool = False,
) -> dict[str, Any]:
    _validate_platform(platform)
    root = root.resolve()
    _validate_scoped_root(root, platform, ci_mode)
    payload = json.loads(manifest_path.read_text(encoding="utf-8"))
    if not isinstance(payload, dict):
        raise ValueError("iOS dependency manifest root must be an object")
    if payload.get("format") != "MarketScannerIOSDependencyManifest" or payload.get("version") != 2:
        raise ValueError("iOS dependency manifest format/version is invalid")
    if payload.get("platform") != platform:
        raise ValueError(
            f"iOS dependency manifest platform mismatch: expected {platform}, "
            f"found {payload.get('platform')!r}"
        )
    if payload.get("prefix_scope") != f"Libraries/{platform}":
        raise ValueError("iOS dependency manifest prefix scope is invalid")
    body = {key: value for key, value in payload.items() if key != "manifest_body_sha256"}
    expected = hashlib.sha256(
        json.dumps(body, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()
    if payload.get("manifest_body_sha256") != expected:
        raise ValueError("iOS dependency manifest body hash differs")
    manifest_files = payload.get("files")
    if not isinstance(manifest_files, list):
        raise ValueError("iOS dependency manifest files list is invalid")
    expected_files: dict[str, dict[str, Any]] = {}
    for index, entry in enumerate(manifest_files):
        if not isinstance(entry, dict):
            raise ValueError(
                f"iOS dependency manifest file entry {index} must be an object"
            )
        relative = entry.get("file")
        byte_count = entry.get("bytes")
        digest = entry.get("sha256")
        if not isinstance(relative, str) or not relative:
            raise ValueError(
                f"iOS dependency manifest file entry {index} has an invalid path"
            )
        relative_path = Path(relative)
        if (
            relative_path.is_absolute()
            or ".." in relative_path.parts
            or not relative_path.parts
            or relative_path.parts[0] not in {"include", "lib"}
        ):
            raise ValueError(
                f"iOS dependency manifest file entry {index} is outside include/lib"
            )
        if isinstance(byte_count, bool) or not isinstance(byte_count, int) or byte_count < 0:
            raise ValueError(
                f"iOS dependency manifest file entry {index} has an invalid byte count"
            )
        if (
            not isinstance(digest, str)
            or len(digest) != 64
            or any(character not in "0123456789abcdef" for character in digest.lower())
        ):
            raise ValueError(
                f"iOS dependency manifest file entry {index} has an invalid SHA-256"
            )
        if set(entry) != {"file", "bytes", "sha256"}:
            raise ValueError(
                f"iOS dependency manifest file entry {index} has unexpected fields"
            )
        if relative in expected_files:
            raise ValueError("iOS dependency manifest contains duplicate file entries")
        expected_files[relative] = entry
    actual_files = {entry["file"]: entry for entry in _artifact_files(root)}
    if set(actual_files) != set(expected_files):
        raise ValueError("iOS dependency artifact file set differs")
    for relative, entry in expected_files.items():
        if actual_files[relative] != entry:
            raise ValueError(f"iOS dependency artifact differs: {relative}")
    current_evidence = _binary_evidence(root, platform, _policy())
    if payload.get("platform_artifacts") != current_evidence:
        raise ValueError("iOS dependency platform evidence differs")
    return payload


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--libraries", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--platform", choices=sorted(SUPPORTED_PLATFORMS), required=True)
    parser.add_argument("--git-sha")
    parser.add_argument("--verify", action="store_true")
    parser.add_argument(
        "--ci",
        action="store_true",
        help="reject legacy/unscoped dependency prefixes",
    )
    args = parser.parse_args()
    try:
        if args.verify:
            verify(args.libraries, args.output, args.platform, ci_mode=args.ci)
        else:
            if not args.git_sha:
                raise ValueError("--git-sha is required when generating a manifest")
            generate(
                args.libraries,
                args.output,
                args.git_sha,
                args.platform,
                ci_mode=args.ci,
            )
    except (OSError, ValueError, subprocess.SubprocessError, json.JSONDecodeError) as exc:
        print(f"iOS dependency manifest error: {exc}", file=sys.stderr)
        raise SystemExit(2)


if __name__ == "__main__":
    main()
