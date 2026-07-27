"""Transactional immutable storage for prior-map localized results."""

from __future__ import annotations

import csv
import hashlib
import json
import os
import re
import shutil
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable


REQUIRED_VERSION_FILES = (
    "prior_map_manifest.json",
    "source_manifest.json",
    "processing_manifest.json",
    "online_localization_trace.json",
    "optimized_map_trajectory.geojson",
    "localization_constraints.json",
    "localization_report.json",
    "review_items.json",
    "localized_review.json",
    "manual_edits.json",
    "localized_price_tags.json",
    "localized_price_tags.csv",
    "localized_price_tags.geojson",
    "shelf_tag_index.json",
    "audit_log.jsonl",
)


class LocalizedStoreError(ValueError):
    pass


@dataclass(frozen=True)
class LocalizedSnapshot:
    version_id: str
    version_dir: Path
    revision: int
    state: str
    manifest_sha256: str


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _fsync_file(path: Path) -> None:
    with path.open("rb") as handle:
        os.fsync(handle.fileno())


def _fsync_directory(path: Path) -> None:
    descriptor = os.open(path, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _atomic_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{uuid.uuid4().hex}.tmp")
    try:
        with temporary.open("w", encoding="utf-8") as handle:
            json.dump(payload, handle, ensure_ascii=False, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        _fsync_directory(path.parent)
    finally:
        temporary.unlink(missing_ok=True)


class LocalizedVersionStore:
    def __init__(self, output_root: Path):
        self.output_root = output_root
        self.root = output_root / "localized"
        self.versions = self.root / "versions"

    def prepare(self) -> None:
        self.versions.mkdir(parents=True, exist_ok=True)
        self.recover_stale_staging()

    def recover_stale_staging(self) -> list[Path]:
        if not self.root.is_dir():
            return []
        removed: list[Path] = []
        for path in sorted(self.root.glob(".staging-*")):
            if path.is_dir():
                shutil.rmtree(path)
                removed.append(path)
        if removed:
            _fsync_directory(self.root)
        return removed

    def begin(self) -> Path:
        self.prepare()
        staging = self.root / f".staging-{uuid.uuid4().hex}"
        staging.mkdir(mode=0o700)
        _fsync_directory(self.root)
        return staging

    def abort(self, staging: Path) -> None:
        if staging.parent != self.root or not staging.name.startswith(".staging-"):
            raise LocalizedStoreError("Refusing to remove a non-staging directory.")
        if staging.exists():
            shutil.rmtree(staging)
            _fsync_directory(self.root)

    def _next_version_id(self) -> str:
        numbers = []
        for path in self.versions.glob("v[0-9][0-9][0-9][0-9][0-9][0-9]"):
            try:
                numbers.append(int(path.name[1:]))
            except ValueError:
                continue
        return f"v{max(numbers, default=0) + 1:06d}"

    def validate_staging(
        self,
        staging: Path,
        *,
        parent_version: str | None,
    ) -> dict[str, Any]:
        if staging.parent != self.root or not staging.is_dir():
            raise LocalizedStoreError("Localized staging directory is invalid.")
        actual_files = sorted(
            path.name for path in staging.iterdir() if path.is_file()
        )
        missing = sorted(set(REQUIRED_VERSION_FILES) - set(actual_files))
        unexpected = sorted(set(actual_files) - set(REQUIRED_VERSION_FILES))
        if missing or unexpected:
            raise LocalizedStoreError(
                f"Localized version file set mismatch: missing={missing}, unexpected={unexpected}"
            )
        parsed: dict[str, Any] = {}
        for name in REQUIRED_VERSION_FILES:
            path = staging / name
            if path.stat().st_size <= 0:
                raise LocalizedStoreError(f"Localized artifact is empty: {name}")
            if path.suffix in {".json", ".geojson"}:
                try:
                    parsed[name] = json.loads(path.read_text(encoding="utf-8"))
                except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
                    raise LocalizedStoreError(f"Localized JSON is invalid: {name}: {exc}") from exc
        for name in ("optimized_map_trajectory.geojson", "localized_price_tags.geojson"):
            if parsed[name].get("type") != "FeatureCollection":
                raise LocalizedStoreError(f"GeoJSON is not a FeatureCollection: {name}")
        with (staging / "localized_price_tags.csv").open(
            "r", encoding="utf-8", newline=""
        ) as handle:
            reader = csv.reader(handle)
            header = next(reader, None)
            if not header or "tag_id" not in header or "approval_status" not in header:
                raise LocalizedStoreError("Localized CSV header is invalid.")
        report = parsed["localization_report.json"]
        journal = parsed["manual_edits.json"]
        state = str(report.get("publish_state") or "invalid")
        if state not in {"invalid", "draft", "review", "published"}:
            raise LocalizedStoreError(f"Localized publish state is invalid: {state}")
        try:
            revision = int(journal.get("revision"))
        except (TypeError, ValueError) as exc:
            raise LocalizedStoreError("Manual edit revision is invalid.") from exc
        if isinstance(journal.get("revision"), bool) or revision < 1:
            raise LocalizedStoreError("Manual edit revision is invalid.")
        files = [
            {
                "file": name,
                "bytes": (staging / name).stat().st_size,
                "sha256": _sha256(staging / name),
            }
            for name in REQUIRED_VERSION_FILES
        ]
        return {
            "format": "MarketScannerLocalizedVersionManifest",
            "version": 1,
            "state": state,
            "revision": revision,
            "parent_version": parent_version,
            "files": files,
        }

    def commit(
        self,
        staging: Path,
        manifest: dict[str, Any],
        *,
        update_current: bool,
    ) -> LocalizedSnapshot:
        version_id = self._next_version_id()
        version_dir = self.versions / version_id
        if version_dir.exists():
            raise LocalizedStoreError(f"Localized version already exists: {version_id}")
        manifest = {**manifest, "version_id": version_id}
        manifest_path = staging / "version_manifest.json"
        with manifest_path.open("w", encoding="utf-8") as handle:
            json.dump(manifest, handle, ensure_ascii=False, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        for path in staging.iterdir():
            if path.is_file():
                _fsync_file(path)
        _fsync_directory(staging)
        os.replace(staging, version_dir)
        _fsync_directory(self.versions)
        manifest_sha256 = _sha256(version_dir / "version_manifest.json")
        snapshot = LocalizedSnapshot(
            version_id=version_id,
            version_dir=version_dir,
            revision=int(manifest["revision"]),
            state=str(manifest["state"]),
            manifest_sha256=manifest_sha256,
        )
        if update_current:
            self.write_pointer("current.json", snapshot)
        return snapshot

    def write_pointer(self, name: str, snapshot: LocalizedSnapshot) -> None:
        if name not in {"current.json", "published.json"}:
            raise LocalizedStoreError("Localized pointer name is invalid.")
        _atomic_json(
            self.root / name,
            {
                "format": "MarketScannerLocalizedPointer",
                "version": 1,
                "version_id": snapshot.version_id,
                "revision": snapshot.revision,
                "state": snapshot.state,
                "manifest_sha256": snapshot.manifest_sha256,
            },
        )

    def resolve_pointer(self, name: str) -> LocalizedSnapshot | None:
        pointer_path = self.root / name
        if not pointer_path.is_file():
            return None
        try:
            pointer = json.loads(pointer_path.read_text(encoding="utf-8"))
            version_id = str(pointer["version_id"])
            revision = int(pointer["revision"])
            state = str(pointer["state"])
            expected_manifest = str(pointer["manifest_sha256"])
        except (OSError, KeyError, TypeError, ValueError, json.JSONDecodeError) as exc:
            raise LocalizedStoreError(f"Localized pointer is invalid: {name}") from exc
        if pointer.get("format") != "MarketScannerLocalizedPointer" or pointer.get("version") != 1:
            raise LocalizedStoreError(f"Localized pointer contract is invalid: {name}")
        if re.fullmatch(r"v[0-9]{6}", version_id) is None:
            raise LocalizedStoreError(f"Localized pointer version is unsafe: {version_id}")
        snapshot = self.resolve_version(version_id)
        if snapshot.manifest_sha256 != expected_manifest:
            raise LocalizedStoreError(f"Localized pointer manifest mismatch: {name}")
        if snapshot.revision != revision or snapshot.state != state:
            raise LocalizedStoreError(f"Localized pointer metadata mismatch: {name}")
        return snapshot

    def resolve_version(self, version_id: str) -> LocalizedSnapshot:
        if re.fullmatch(r"v[0-9]{6}", version_id) is None:
            raise LocalizedStoreError(f"Localized version is unsafe: {version_id}")
        version_dir = self.versions / version_id
        manifest_path = version_dir / "version_manifest.json"
        try:
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            revision = int(manifest["revision"])
            state = str(manifest["state"])
        except (OSError, KeyError, TypeError, ValueError, json.JSONDecodeError) as exc:
            raise LocalizedStoreError(
                f"Localized version manifest is invalid: {version_id}"
            ) from exc
        if (
            manifest.get("format") != "MarketScannerLocalizedVersionManifest"
            or manifest.get("version") != 1
            or manifest.get("version_id") != version_id
            or state not in {"invalid", "draft", "review", "published"}
            or revision < 1
        ):
            raise LocalizedStoreError(
                f"Localized version manifest contract is invalid: {version_id}"
            )
        return LocalizedSnapshot(
            version_id=version_id,
            version_dir=version_dir,
            revision=revision,
            state=state,
            manifest_sha256=_sha256(manifest_path),
        )

    def current(self) -> LocalizedSnapshot | None:
        return self.resolve_pointer("current.json")

    def published(self) -> LocalizedSnapshot | None:
        return self.resolve_pointer("published.json")


def immutable_version_artifacts(snapshot: LocalizedSnapshot) -> Iterable[Path]:
    return snapshot.version_dir.iterdir()
