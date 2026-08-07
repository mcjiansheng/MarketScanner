#!/usr/bin/env python3
"""Fail-closed RTABMapApp source-membership and SwiftPM lock audit.

The shipping Swift source list is derived from the named PBXNativeTarget's
PBXSourcesBuildPhase.  The checker deliberately does not maintain a second
production-source allow-list: every Swift file below RTABMapApp is expected to
ship unless it is a test or one of the two documented, unused legacy point
cloud model files.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, Iterable, List, Mapping, Optional, Sequence, Set, Tuple


PBX_ID_RE = re.compile(r"\b[0-9A-Fa-f]{24}\b")
REVISION_RE = re.compile(r"[0-9a-f]{40}")
DEFAULT_TARGET = "RTABMapApp"
DEFAULT_PROJECT = Path("app/ios/RTABMapApp.xcodeproj/project.pbxproj")
DEFAULT_SOURCE_ROOT = Path("app/ios/RTABMapApp")
DEFAULT_PACKAGE_RESOLVED = Path(
    "app/ios/RTABMapApp.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
)

# These tracked files are unused remnants from the pre-RTAB-Map ThreeDScanner
# sample.  Both declare a different `PointCloud` with the same module symbol,
# so adding either (or both) to the shipping target would be incorrect.
LEGACY_NON_PRODUCTION_SWIFT = frozenset({"PointCloud.swift", "PointCloudData.swift"})
NON_PRODUCTION_SOURCE_DIRS = frozenset({"Libraries"})


class ProjectParseError(ValueError):
    """The pbxproj cannot provide an unambiguous shipping source graph."""


@dataclass(frozen=True)
class Issue:
    code: str
    message: str


@dataclass
class AuditResult:
    target_name: str
    swift_sources: List[Path] = field(default_factory=list)
    package_pins: List[Mapping[str, object]] = field(default_factory=list)
    remote_packages: List[str] = field(default_factory=list)
    issues: List[Issue] = field(default_factory=list)

    @property
    def ok(self) -> bool:
        return not self.issues


@dataclass(frozen=True)
class PBXObject:
    identifier: str
    body: str


def _section(text: str, name: str) -> str:
    match = re.search(
        rf"/\* Begin {re.escape(name)} section \*/(.*?)/\* End {re.escape(name)} section \*/",
        text,
        re.DOTALL,
    )
    if not match:
        raise ProjectParseError(f"missing {name} section")
    return match.group(1)


def _matching_brace(text: str, opening_index: int) -> int:
    depth = 0
    in_string = False
    escaped = False
    in_comment = False
    index = opening_index
    while index < len(text):
        current = text[index]
        following = text[index + 1] if index + 1 < len(text) else ""
        if in_comment:
            if current == "*" and following == "/":
                in_comment = False
                index += 2
                continue
        elif in_string:
            if escaped:
                escaped = False
            elif current == "\\":
                escaped = True
            elif current == '"':
                in_string = False
        elif current == "/" and following == "*":
            in_comment = True
            index += 2
            continue
        elif current == '"':
            in_string = True
        elif current == "{":
            depth += 1
        elif current == "}":
            depth -= 1
            if depth == 0:
                return index
        index += 1
    raise ProjectParseError("unterminated object in pbxproj")


def _objects(section: str) -> Dict[str, PBXObject]:
    result: Dict[str, PBXObject] = {}
    object_start = re.compile(
        r"(?m)^[ \t]*([0-9A-Fa-f]{24})(?:[ \t]+/\*.*?\*/)?[ \t]*=[ \t]*\{"
    )
    for match in object_start.finditer(section):
        identifier = match.group(1).upper()
        opening = match.end() - 1
        closing = _matching_brace(section, opening)
        if identifier in result:
            raise ProjectParseError(f"duplicate PBX object identifier {identifier}")
        result[identifier] = PBXObject(identifier, section[opening + 1 : closing])
    return result


def _decode_atom(value: str) -> str:
    value = value.strip()
    if value.startswith('"') and value.endswith('"'):
        try:
            return str(json.loads(value))
        except json.JSONDecodeError as error:
            raise ProjectParseError(f"invalid quoted pbxproj value {value!r}") from error
    return value


def _assignment(body: str, key: str) -> Optional[str]:
    match = re.search(
        rf"\b{re.escape(key)}\s*=\s*((?:\"(?:\\.|[^\"])*\")|[^;\r\n]+)\s*;",
        body,
    )
    return _decode_atom(match.group(1)) if match else None


def _list_ids(body: str, key: str) -> List[str]:
    match = re.search(rf"\b{re.escape(key)}\s*=\s*\((.*?)\);", body, re.DOTALL)
    if not match:
        return []
    return [identifier.upper() for identifier in PBX_ID_RE.findall(match.group(1))]


def _id_assignment(body: str, key: str) -> Optional[str]:
    match = re.search(rf"\b{re.escape(key)}\s*=\s*([0-9A-Fa-f]{{24}})\b", body)
    return match.group(1).upper() if match else None


def _is_swift_file_ref(body: str) -> bool:
    file_type = _assignment(body, "lastKnownFileType") or _assignment(body, "explicitFileType")
    path = _assignment(body, "path") or _assignment(body, "name") or ""
    return file_type == "sourcecode.swift" or path.lower().endswith(".swift")


def _looks_like_test_source(path: Path) -> bool:
    lowered_parts = [part.lower() for part in path.parts]
    if any(part in {"test", "tests", "uitest", "uitests"} for part in lowered_parts):
        return True
    stem = path.stem.lower()
    return stem.startswith("test_") or stem.endswith("test") or stem.endswith("tests")


def _normal_path(path: Path) -> Path:
    return Path(os.path.abspath(os.path.normpath(os.fspath(path))))


def _repo_relative(path: Path, repo: Path) -> str:
    try:
        return path.relative_to(repo).as_posix()
    except ValueError:
        return path.as_posix()


def _case_mismatch(path: Path) -> Optional[str]:
    """Return the on-disk spelling if only the path's case is wrong."""

    absolute = _normal_path(path)
    parts = absolute.parts
    if not parts:
        return None
    current = Path(parts[0])
    actual_parts = [parts[0]]
    mismatch = False
    for component in parts[1:]:
        try:
            entries = os.listdir(current)
        except OSError:
            return None
        if component in entries:
            actual = component
        else:
            matches = [entry for entry in entries if entry.casefold() == component.casefold()]
            if len(matches) != 1:
                return None
            actual = matches[0]
            mismatch = True
        current = current / actual
        actual_parts.append(actual)
    return str(Path(*actual_parts)) if mismatch else None


def _canonical_package_location(location: str) -> str:
    canonical = location.strip().rstrip("/")
    if canonical.lower().endswith(".git"):
        canonical = canonical[:-4]
    return canonical.casefold()


class XcodeProject:
    def __init__(self, pbxproj: Path):
        self.pbxproj = _normal_path(pbxproj)
        self.project_dir = self.pbxproj.parent.parent
        try:
            self.text = self.pbxproj.read_text(encoding="utf-8")
        except OSError as error:
            raise ProjectParseError(f"cannot read {self.pbxproj}: {error}") from error

        self.build_files = _objects(_section(self.text, "PBXBuildFile"))
        self.file_refs = _objects(_section(self.text, "PBXFileReference"))
        self.groups = _objects(_section(self.text, "PBXGroup"))
        try:
            self.variant_groups = _objects(_section(self.text, "PBXVariantGroup"))
        except ProjectParseError:
            self.variant_groups = {}
        self.targets = _objects(_section(self.text, "PBXNativeTarget"))
        self.source_phases = _objects(_section(self.text, "PBXSourcesBuildPhase"))
        self.remote_packages = _objects(_section(self.text, "XCRemoteSwiftPackageReference"))

        self.group_children: Set[str] = set()
        for group in self.groups.values():
            self.group_children.update(_list_ids(group.body, "children"))

        self.all_build_phase_members: Set[str] = set()
        for section_name in (
            "PBXSourcesBuildPhase",
            "PBXFrameworksBuildPhase",
            "PBXResourcesBuildPhase",
        ):
            try:
                phase_objects = _objects(_section(self.text, section_name))
            except ProjectParseError:
                continue
            for phase in phase_objects.values():
                self.all_build_phase_members.update(_list_ids(phase.body, "files"))

    def target_source_phase(self, target_name: str) -> Tuple[str, List[str]]:
        matches = [
            target
            for target in self.targets.values()
            if _assignment(target.body, "name") == target_name
        ]
        if len(matches) != 1:
            raise ProjectParseError(
                f"expected exactly one PBXNativeTarget named {target_name!r}, found {len(matches)}"
            )
        phase_ids = _list_ids(matches[0].body, "buildPhases")
        sources = [phase_id for phase_id in phase_ids if phase_id in self.source_phases]
        if len(sources) != 1:
            raise ProjectParseError(
                f"target {target_name!r} must have exactly one PBXSourcesBuildPhase, found {len(sources)}"
            )
        phase_id = sources[0]
        return phase_id, _list_ids(self.source_phases[phase_id].body, "files")

    def file_ref_path(self, file_ref: PBXObject) -> Path:
        raw_path = _assignment(file_ref.body, "path") or _assignment(file_ref.body, "name")
        if not raw_path:
            raise ProjectParseError(f"Swift fileRef {file_ref.identifier} has no path or name")
        source_tree = _assignment(file_ref.body, "sourceTree") or "<group>"
        if source_tree in {"<group>", "SOURCE_ROOT"}:
            return _normal_path(self.project_dir / raw_path)
        if source_tree == "<absolute>":
            return _normal_path(Path(raw_path))
        raise ProjectParseError(
            f"Swift fileRef {file_ref.identifier} uses unsupported sourceTree {source_tree!r}"
        )

    def declared_remote_package_urls(self) -> List[str]:
        urls = []
        for package in self.remote_packages.values():
            url = _assignment(package.body, "repositoryURL")
            if not url:
                raise ProjectParseError(
                    f"remote package reference {package.identifier} has no repositoryURL"
                )
            urls.append(url)
        return sorted(urls)


def _read_package_pins(path: Path) -> List[Mapping[str, object]]:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except OSError as error:
        raise ProjectParseError(f"cannot read SwiftPM lock {path}: {error}") from error
    except json.JSONDecodeError as error:
        raise ProjectParseError(f"invalid SwiftPM lock JSON {path}: {error}") from error

    if not isinstance(payload, dict):
        raise ProjectParseError("Package.resolved root must be an object")
    pins = payload.get("pins")
    if pins is None and isinstance(payload.get("object"), dict):
        pins = payload["object"].get("pins")
    if not isinstance(pins, list):
        raise ProjectParseError("Package.resolved must contain a pins array")
    if not all(isinstance(pin, dict) for pin in pins):
        raise ProjectParseError("Package.resolved pins must be objects")
    return pins


def _pin_location(pin: Mapping[str, object]) -> Optional[str]:
    value = pin.get("location") or pin.get("repositoryURL")
    return value if isinstance(value, str) else None


def _pin_identity(pin: Mapping[str, object]) -> str:
    value = pin.get("identity") or pin.get("package") or _pin_location(pin) or "<unknown>"
    return str(value)


def audit_project(
    *,
    repo: Path,
    project_path: Path,
    source_root: Path,
    target_name: str = DEFAULT_TARGET,
    package_resolved: Optional[Path] = None,
    check_package_lock: bool = True,
    legacy_exclusions: Iterable[str] = LEGACY_NON_PRODUCTION_SWIFT,
) -> AuditResult:
    repo = _normal_path(repo)
    project_path = _normal_path(project_path if project_path.is_absolute() else repo / project_path)
    source_root = _normal_path(source_root if source_root.is_absolute() else repo / source_root)
    result = AuditResult(target_name=target_name)

    try:
        project = XcodeProject(project_path)
        _, source_build_file_ids = project.target_source_phase(target_name)
    except ProjectParseError as error:
        result.issues.append(Issue("project_parse", str(error)))
        return result

    build_file_id_counts = Counter(source_build_file_ids)
    for identifier, count in sorted(build_file_id_counts.items()):
        if count > 1:
            result.issues.append(
                Issue("duplicate_build_file", f"buildFile {identifier} occurs {count} times in target Sources")
            )

    target_ref_ids: List[str] = []
    for build_file_id in source_build_file_ids:
        build_file = project.build_files.get(build_file_id)
        if build_file is None:
            result.issues.append(
                Issue("orphan_build_file", f"target Sources references undefined buildFile {build_file_id}")
            )
            continue
        file_ref_id = _id_assignment(build_file.body, "fileRef")
        if not file_ref_id:
            continue  # A package product or other non-file source entry.
        target_ref_ids.append(file_ref_id.upper())

    target_ref_counts = Counter(target_ref_ids)
    for file_ref_id, count in sorted(target_ref_counts.items()):
        if count > 1:
            result.issues.append(
                Issue(
                    "duplicate_build_file",
                    f"fileRef {file_ref_id} has {count} buildFiles in target Sources",
                )
            )

    swift_ref_paths: Dict[str, Path] = {}
    for file_ref_id, file_ref in project.file_refs.items():
        if not _is_swift_file_ref(file_ref.body):
            continue
        try:
            swift_ref_paths[file_ref_id] = project.file_ref_path(file_ref)
        except ProjectParseError as error:
            result.issues.append(Issue("stale_file_ref", str(error)))
            continue
        path = swift_ref_paths[file_ref_id]
        case_actual = _case_mismatch(path)
        if case_actual:
            result.issues.append(
                Issue(
                    "case_mismatch",
                    f"{_repo_relative(path, repo)} is cased differently on disk as "
                    f"{_repo_relative(Path(case_actual), repo)}",
                )
            )
        elif not path.is_file():
            result.issues.append(
                Issue("stale_file_ref", f"Swift fileRef does not exist: {_repo_relative(path, repo)}")
            )
        if file_ref_id not in project.group_children:
            result.issues.append(
                Issue("orphan_file_ref", f"Swift fileRef {file_ref_id} is not present in a PBXGroup")
            )

    duplicate_refs: Dict[str, List[str]] = defaultdict(list)
    for file_ref_id, path in swift_ref_paths.items():
        duplicate_refs[str(path).casefold()].append(file_ref_id)
    for path_key, identifiers in sorted(duplicate_refs.items()):
        if len(identifiers) > 1:
            result.issues.append(
                Issue(
                    "duplicate_file_ref",
                    f"Swift path {path_key} has duplicate fileRefs: {', '.join(sorted(identifiers))}",
                )
            )

    for build_file_id, build_file in project.build_files.items():
        file_ref_id = _id_assignment(build_file.body, "fileRef")
        valid_file_like_refs = set(project.file_refs) | set(project.variant_groups)
        if file_ref_id and file_ref_id not in valid_file_like_refs:
            result.issues.append(
                Issue(
                    "orphan_build_file",
                    f"buildFile {build_file_id} references undefined fileRef {file_ref_id}",
                )
            )
            continue
        if not file_ref_id or file_ref_id not in swift_ref_paths:
            continue
        if build_file_id not in project.all_build_phase_members:
            result.issues.append(
                Issue(
                    "orphan_build_file",
                    f"Swift buildFile {build_file_id} is not present in any build phase",
                )
            )

    for file_ref_id in target_ref_ids:
        file_ref = project.file_refs.get(file_ref_id)
        if file_ref is None:
            result.issues.append(
                Issue("orphan_file_ref", f"target buildFile references undefined fileRef {file_ref_id}")
            )
            continue
        if not _is_swift_file_ref(file_ref.body):
            continue
        path = swift_ref_paths.get(file_ref_id)
        if path is None:
            continue
        if _looks_like_test_source(path):
            result.issues.append(
                Issue(
                    "test_source_in_production",
                    f"test-like Swift source is compiled by {target_name}: {_repo_relative(path, repo)}",
                )
            )
        result.swift_sources.append(path)

    exclusions = set(legacy_exclusions)
    disk_production: Set[Path] = set()
    if not source_root.is_dir():
        result.issues.append(
            Issue("source_root_missing", f"production Swift root does not exist: {_repo_relative(source_root, repo)}")
        )
    else:
        for path in source_root.rglob("*.swift"):
            relative = path.relative_to(source_root)
            if (
                relative.as_posix() in exclusions
                or (relative.parts and relative.parts[0] in NON_PRODUCTION_SOURCE_DIRS)
                or _looks_like_test_source(relative)
            ):
                continue
            disk_production.add(_normal_path(path))

    target_swift = set(result.swift_sources)
    target_swift_casefold = {str(path).casefold(): path for path in target_swift}
    for production_path in sorted(disk_production, key=lambda item: item.as_posix()):
        if production_path in target_swift:
            continue
        wrong_case = target_swift_casefold.get(str(production_path).casefold())
        if wrong_case:
            result.issues.append(
                Issue(
                    "case_mismatch",
                    f"production source {_repo_relative(production_path, repo)} is registered as "
                    f"{_repo_relative(wrong_case, repo)}",
                )
            )
        else:
            result.issues.append(
                Issue(
                    "production_source_missing",
                    f"production Swift source is not compiled by {target_name}: "
                    f"{_repo_relative(production_path, repo)}",
                )
            )

    source_root_prefix = str(source_root) + os.sep
    for target_path in sorted(target_swift, key=lambda item: item.as_posix()):
        if str(target_path).startswith(source_root_prefix) or target_path == source_root:
            continue
        result.issues.append(
            Issue(
                "source_outside_production_root",
                f"target Swift source is outside {_repo_relative(source_root, repo)}: "
                f"{_repo_relative(target_path, repo)}",
            )
        )

    try:
        result.remote_packages = project.declared_remote_package_urls()
    except ProjectParseError as error:
        result.issues.append(Issue("package_reference", str(error)))

    if check_package_lock and result.remote_packages:
        lock_path = package_resolved or (repo / DEFAULT_PACKAGE_RESOLVED)
        lock_path = _normal_path(lock_path if lock_path.is_absolute() else repo / lock_path)
        if not lock_path.is_file():
            result.issues.append(
                Issue(
                    "package_lock_missing",
                    f"{len(result.remote_packages)} remote SwiftPM package(s) require a shared lock: "
                    f"{_repo_relative(lock_path, repo)}",
                )
            )
        else:
            try:
                result.package_pins = _read_package_pins(lock_path)
            except ProjectParseError as error:
                result.issues.append(Issue("package_lock_invalid", str(error)))
            pin_locations: Dict[str, Mapping[str, object]] = {}
            for pin in result.package_pins:
                location = _pin_location(pin)
                state = pin.get("state")
                revision = state.get("revision") if isinstance(state, dict) else None
                if not location:
                    result.issues.append(
                        Issue("package_lock_invalid", f"pin {_pin_identity(pin)} has no repository location")
                    )
                    continue
                pin_locations[_canonical_package_location(location)] = pin
                if not isinstance(revision, str) or not REVISION_RE.fullmatch(revision):
                    result.issues.append(
                        Issue(
                            "package_lock_invalid",
                            f"pin {_pin_identity(pin)} does not contain an exact 40-hex revision",
                        )
                    )
            for url in result.remote_packages:
                if _canonical_package_location(url) not in pin_locations:
                    result.issues.append(
                        Issue("package_lock_missing_pin", f"Package.resolved does not pin {url}")
                    )

    result.swift_sources = sorted(set(result.swift_sources), key=lambda item: item.as_posix())
    return result


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--project", type=Path, default=DEFAULT_PROJECT)
    parser.add_argument("--source-root", type=Path, default=DEFAULT_SOURCE_ROOT)
    parser.add_argument("--target", default=DEFAULT_TARGET)
    parser.add_argument("--package-resolved", type=Path, default=DEFAULT_PACKAGE_RESOLVED)
    parser.add_argument(
        "--source-list-output",
        type=Path,
        help="write the validated target Swift list as NUL-delimited repo-relative paths",
    )
    parser.add_argument(
        "--print-sources",
        action="store_true",
        help="print the validated target Swift list, one repo-relative path per line",
    )
    return parser


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = _parser().parse_args(argv)
    repo = _normal_path(args.repo)
    result = audit_project(
        repo=repo,
        project_path=args.project,
        source_root=args.source_root,
        target_name=args.target,
        package_resolved=args.package_resolved,
    )
    summary_stream = sys.stderr if args.print_sources else sys.stdout
    if result.issues:
        for issue in result.issues:
            print(f"ERROR [{issue.code}] {issue.message}", file=sys.stderr)
        print(
            f"iOS source membership FAILED: {len(result.issues)} issue(s)",
            file=sys.stderr,
        )
        return 1

    relative_sources = [_repo_relative(path, repo) for path in result.swift_sources]
    if args.source_list_output:
        output = args.source_list_output
        if not output.is_absolute():
            output = repo / output
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_bytes(b"\0".join(path.encode("utf-8") for path in relative_sources) + b"\0")
    if args.print_sources:
        print("\n".join(relative_sources))

    print(
        f"iOS source membership OK: target={result.target_name}, "
        f"Swift sources={len(relative_sources)}",
        file=summary_stream,
    )
    if result.remote_packages:
        pins = ", ".join(
            f"{_pin_identity(pin)}@{str(pin.get('state', {}).get('revision', ''))[:12]}"
            for pin in result.package_pins
        )
        print(
            f"SwiftPM lock OK: direct packages={len(result.remote_packages)}, "
            f"resolved pins={len(result.package_pins)} ({pins})",
            file=summary_stream,
        )
    else:
        print(
            "SwiftPM lock not required: project has no remote package references",
            file=summary_stream,
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
