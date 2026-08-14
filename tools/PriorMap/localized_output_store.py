"""Transactional immutable storage for prior-map localized results."""

from __future__ import annotations

import csv
from datetime import datetime, timezone
import hashlib
import json
import math
import ntpath
import os
import re
import shutil
import stat
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable

from tools.PriorMap.localized_file_lock import FileLock, FileLockTimeout
from tools.Qualification.qualification import (
    QualificationError,
    inspect_field_evidence,
    inspect_field_evidence_with_bytes,
)


REQUIRED_VERSION_FILES = (
    "prior_map_manifest.json",
    "source_manifest.json",
    "processing_manifest.json",
    "session_input_manifest.json",
    "online_localization_trace.json",
    "optimized_map_trajectory.geojson",
    "localization_constraints.json",
    "localization_report.json",
    "factor_graph_report.json",
    "review_items.json",
    "localized_review.json",
    "manual_edits.json",
    "localized_price_tags.json",
    "localized_price_tags.csv",
    "localized_price_tags.geojson",
    "shelf_tag_index.json",
    "audit_log.jsonl",
)
CALIBRATED_DELIVERABLE_FILES = (
    "calibrated_positions_by_node.csv",
    "calibrated_positions_1s.csv",
    "calibrated_deliverables_manifest.json",
)
CURRENT_REQUIRED_VERSION_FILES = (
    REQUIRED_VERSION_FILES + CALIBRATED_DELIVERABLE_FILES
)
PUBLICATION_EVIDENCE_FILES = (
    "field_evidence.json",
    "qualification_manifest.json",
)
PUBLISHED_VERSION_FILES = REQUIRED_VERSION_FILES + PUBLICATION_EVIDENCE_FILES
CURRENT_PUBLISHED_VERSION_FILES = (
    CURRENT_REQUIRED_VERSION_FILES + PUBLICATION_EVIDENCE_FILES
)
ALL_LOCALIZED_VERSION_FILES = frozenset(CURRENT_PUBLISHED_VERSION_FILES)
VERSION_2_REQUIRED_VERSION_FILES = tuple(
    name for name in REQUIRED_VERSION_FILES if name != "factor_graph_report.json"
)
LEGACY_REQUIRED_VERSION_FILES = tuple(
    name
    for name in VERSION_2_REQUIRED_VERSION_FILES
    if name != "session_input_manifest.json"
)
VERSION_STATES = frozenset(
    {"invalid", "draft", "review", "published", "superseded", "revoked"}
)
RECOVERY_EVIDENCE_UNBOUND_LEGACY = (
    "recovery_lifecycle_evidence_unbound_legacy"
)
RECOVERY_EVIDENCE_BOUND_V2 = "recovery_lifecycle_evidence_bound_v2"
SESSION_INPUT_ROLE_FILES_BY_VERSION = {
    1: (
        ("metadata", "metadata.json"),
        ("source_database", None),
        ("localization_trace.jsonl", "localization_trace.jsonl"),
        ("localization_constraints.jsonl", "localization_constraints.jsonl"),
        ("localization_events.jsonl", "localization_events.jsonl"),
        ("manual_localization_events.jsonl", "manual_localization_events.jsonl"),
        ("tag_observations.jsonl", "tag_observations.jsonl"),
        ("localized_price_tags.json", "localized_price_tags.json"),
    ),
    2: (
        ("metadata", "metadata.json"),
        ("source_database", None),
        ("localization_trace.jsonl", "localization_trace.jsonl"),
        ("localization_constraints.jsonl", "localization_constraints.jsonl"),
        ("localization_events.jsonl", "localization_events.jsonl"),
        (
            "localization_recovery_events.jsonl",
            "localization_recovery_events.jsonl",
        ),
        ("manual_localization_events.jsonl", "manual_localization_events.jsonl"),
        ("tag_observations.jsonl", "tag_observations.jsonl"),
        ("localized_price_tags.json", "localized_price_tags.json"),
    ),
    3: (
        ("metadata", "metadata.json"),
        ("source_database", None),
        ("localization_trace.jsonl", "localization_trace.jsonl"),
        ("localization_constraints.jsonl", "localization_constraints.jsonl"),
        ("localization_events.jsonl", "localization_events.jsonl"),
        (
            "localization_recovery_events.jsonl",
            "localization_recovery_events.jsonl",
        ),
        ("manual_localization_events.jsonl", "manual_localization_events.jsonl"),
        ("tag_observations.jsonl", "tag_observations.jsonl"),
        ("tag_observation_bursts.jsonl", "tag_observation_bursts.jsonl"),
        ("localized_price_tags.json", "localized_price_tags.json"),
    ),
    4: (
        ("metadata", "metadata.json"),
        ("source_database", None),
        ("clock_correlations.jsonl", "clock_correlations.jsonl"),
        ("localization_trace.jsonl", "localization_trace.jsonl"),
        ("localization_constraints.jsonl", "localization_constraints.jsonl"),
        ("localization_events.jsonl", "localization_events.jsonl"),
        (
            "localization_recovery_events.jsonl",
            "localization_recovery_events.jsonl",
        ),
        ("manual_localization_events.jsonl", "manual_localization_events.jsonl"),
        ("tag_observations.jsonl", "tag_observations.jsonl"),
        ("tag_observation_bursts.jsonl", "tag_observation_bursts.jsonl"),
        ("localized_price_tags.json", "localized_price_tags.json"),
    ),
}
RECOVERY_EVIDENCE_BINDING_BY_SESSION_VERSION = {
    1: RECOVERY_EVIDENCE_UNBOUND_LEGACY,
    2: RECOVERY_EVIDENCE_BOUND_V2,
    3: RECOVERY_EVIDENCE_BOUND_V2,
    4: RECOVERY_EVIDENCE_BOUND_V2,
}
_CANONICAL_SESSION_SIDECAR_FILES = frozenset(
    file_name
    for role_files in SESSION_INPUT_ROLE_FILES_BY_VERSION.values()
    for role, file_name in role_files
    if role != "source_database" and file_name is not None
)
_CANONICAL_SESSION_SIDECAR_FILES_CASEFOLDED = frozenset(
    file_name.casefold() for file_name in _CANONICAL_SESSION_SIDECAR_FILES
)


class LocalizedStoreError(ValueError):
    pass


class LocalizedCommitIndeterminate(LocalizedStoreError):
    """A pointer is visible, but its directory entry could not be fsynced.

    Callers must inspect the pointer before recovery; blindly retrying could
    create a second committed state transition.
    """


@dataclass(frozen=True)
class LocalizedSnapshot:
    version_id: str
    version_dir: Path
    revision: int
    state: str
    manifest_sha256: str
    input_identity_id: str | None = None
    session_input_bundle_sha256: str | None = None


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _canonical_json_bytes(payload: dict[str, Any]) -> bytes:
    return json.dumps(
        payload,
        ensure_ascii=False,
        separators=(",", ":"),
        sort_keys=True,
        allow_nan=False,
    ).encode("utf-8")


def _safe_session_input_basename(value: Any) -> bool:
    if (
        not isinstance(value, str)
        or not value
        or value in {".", ".."}
        or "\x00" in value
        or "/" in value
        or "\\" in value
    ):
        return False
    drive, _tail = ntpath.splitdrive(value)
    return not drive and not ntpath.isabs(value)


def validate_session_input_manifest_contract(
    payload: Any,
) -> dict[str, Any]:
    """Validate one canonical v1/v2/v3/v4 finalized-session manifest.

    The returned fields are safe to use for cross-artifact binding.  In
    particular, version is a strict JSON integer (Bool, float and string are
    rejected), the source DB is a portable basename that cannot alias a
    canonical sidecar, and every filename is unique even when an attacker has
    recomputed the bundle SHA.
    """

    if (
        not isinstance(payload, dict)
        or payload.get("format") != "MarketScannerLocalizedInputManifest"
    ):
        raise LocalizedStoreError("Session input manifest contract is invalid.")
    version = payload.get("version")
    if (
        isinstance(version, bool)
        or not isinstance(version, int)
        or version not in SESSION_INPUT_ROLE_FILES_BY_VERSION
    ):
        raise LocalizedStoreError("Session input manifest contract is invalid.")
    base_keys = {
        "format",
        "version",
        "source_database_sha256",
        "files",
        "bundle_sha256",
    }
    required_keys = (
        base_keys | {"recovery_evidence_binding"}
        if version == 1
        else base_keys
    )
    allowed_keys = required_keys | {"input_identity_id"}
    if frozenset(payload) not in {
        frozenset(required_keys),
        frozenset(allowed_keys),
    }:
        raise LocalizedStoreError("Session input manifest contract is invalid.")
    if version == 1:
        if (
            payload.get("recovery_evidence_binding")
            != RECOVERY_EVIDENCE_UNBOUND_LEGACY
        ):
            raise LocalizedStoreError("Session input manifest contract is invalid.")
    elif "recovery_evidence_binding" in payload:
        raise LocalizedStoreError("Session input manifest contract is invalid.")

    role_files = SESSION_INPUT_ROLE_FILES_BY_VERSION[version]
    files = payload.get("files")
    if not isinstance(files, list) or len(files) != len(role_files):
        raise LocalizedStoreError("Session input manifest file set is invalid.")
    observed_files: set[str] = set()
    source_database_name: str | None = None
    for entry, (role, canonical_file) in zip(files, role_files):
        if (
            not isinstance(entry, dict)
            or set(entry) != {"role", "file", "bytes", "sha256"}
            or entry.get("role") != role
            or not _safe_session_input_basename(entry.get("file"))
            or isinstance(entry.get("bytes"), bool)
            or not isinstance(entry.get("bytes"), int)
            or entry["bytes"] < 0
            or not isinstance(entry.get("sha256"), str)
            or re.fullmatch(r"[0-9a-f]{64}", entry["sha256"]) is None
        ):
            raise LocalizedStoreError("Session input manifest entry is invalid.")
        file_name = entry["file"]
        normalized_file_name = file_name.casefold()
        if normalized_file_name in observed_files:
            raise LocalizedStoreError("Session input manifest filename is invalid.")
        observed_files.add(normalized_file_name)
        if role == "source_database":
            if (
                normalized_file_name
                in _CANONICAL_SESSION_SIDECAR_FILES_CASEFOLDED
            ):
                raise LocalizedStoreError(
                    "Session input manifest source database filename is invalid."
                )
            source_database_name = file_name
        elif file_name != canonical_file:
            raise LocalizedStoreError("Session input manifest filename is invalid.")

    source_database_sha256 = payload.get("source_database_sha256")
    if (
        not isinstance(source_database_sha256, str)
        or re.fullmatch(r"[0-9a-f]{64}", source_database_sha256) is None
        or source_database_sha256 != files[1]["sha256"]
    ):
        raise LocalizedStoreError(
            "Session input manifest source database hash is inconsistent."
        )
    canonical = {
        "format": payload["format"],
        "version": version,
        "source_database_sha256": source_database_sha256,
        "files": files,
    }
    calculated = hashlib.sha256(_canonical_json_bytes(canonical)).hexdigest()
    if payload.get("bundle_sha256") != calculated:
        raise LocalizedStoreError("Session input manifest bundle hash is invalid.")
    input_identity_id = payload.get("input_identity_id")
    if input_identity_id is not None and (
        not isinstance(input_identity_id, str)
        or re.fullmatch(r"[0-9a-f]{64}", input_identity_id) is None
    ):
        raise LocalizedStoreError("Session input manifest input identity is invalid.")
    assert source_database_name is not None
    return {
        "version": version,
        "bundle_sha256": calculated,
        "source_database_name": source_database_name,
        "source_database_sha256": source_database_sha256,
        "recovery_evidence_binding": (
            RECOVERY_EVIDENCE_BINDING_BY_SESSION_VERSION[version]
        ),
    }


def local_input_identity_id(payload: dict[str, Any]) -> str:
    """Return the content identity of a machine-local input record."""

    body = {key: value for key, value in payload.items() if key != "input_identity_id"}
    return hashlib.sha256(_canonical_json_bytes(body)).hexdigest()


def _reject_nonfinite(value: str) -> None:
    raise ValueError(f"Non-finite JSON number is forbidden: {value}")


def _fsync_file(path: Path) -> None:
    # Python's Windows os.fsync() maps to the CRT _commit(), which rejects a
    # read-only descriptor with EBADF.  Opening the already-written artifact
    # read/write supplies the required handle without modifying its bytes.
    mode = "r+b" if os.name == "nt" else "rb"
    with path.open(mode) as handle:
        os.fsync(handle.fileno())


def _fsync_directory(path: Path) -> None:
    if os.name == "nt":
        # Win32 FlushFileBuffers requires a writable file handle and rejects
        # ordinary directory handles with ERROR_ACCESS_DENIED.  Windows
        # durability is provided by _atomic_replace() using
        # MOVEFILE_WRITE_THROUGH after every fsynced file/staging write.
        return
    descriptor = os.open(path, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _atomic_replace(source: Path, destination: Path) -> None:
    """Atomically replace a path with the platform's durability barrier."""

    if os.name == "nt":
        _atomic_replace_windows(source, destination)
        return
    os.replace(source, destination)


def _atomic_replace_windows(source: Path, destination: Path) -> None:
    """Move a file or directory and wait for the Win32 move to reach disk."""

    import ctypes
    from ctypes import wintypes

    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    move_file_ex = kernel32.MoveFileExW
    move_file_ex.argtypes = (
        wintypes.LPCWSTR,
        wintypes.LPCWSTR,
        wintypes.DWORD,
    )
    move_file_ex.restype = wintypes.BOOL

    movefile_replace_existing = 0x00000001
    movefile_write_through = 0x00000008
    flags = movefile_replace_existing | movefile_write_through
    if not move_file_ex(
        str(source.resolve()),
        str(destination.resolve()),
        flags,
    ):
        raise ctypes.WinError(ctypes.get_last_error())


def _atomic_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{uuid.uuid4().hex}.tmp")
    try:
        with temporary.open("w", encoding="utf-8") as handle:
            json.dump(
                payload,
                handle,
                ensure_ascii=False,
                indent=2,
                sort_keys=True,
                allow_nan=False,
            )
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        _atomic_replace(temporary, path)
        try:
            _fsync_directory(path.parent)
        except OSError as exc:
            raise LocalizedCommitIndeterminate(
                f"Localized pointer {path.name} is visible, but durability is "
                "indeterminate; inspect the pointer before retrying."
            ) from exc
    finally:
        temporary.unlink(missing_ok=True)


class LocalizedVersionStore:
    def __init__(
        self,
        output_root: Path,
        *,
        lock_timeout_seconds: float | None = 30.0,
        lock_poll_interval_seconds: float = 0.05,
    ):
        self.output_root = output_root
        self.root = output_root / "localized"
        self.versions = self.root / "versions"
        self.local_inputs = self.root / "local_inputs"
        self.lock_timeout_seconds = lock_timeout_seconds
        self.lock_poll_interval_seconds = lock_poll_interval_seconds
        self._lock_handle: FileLock | None = None

    def _acquire_lock(self) -> None:
        if self._lock_handle is not None:
            raise LocalizedStoreError("Localized write transaction is already active.")
        self.versions.mkdir(parents=True, exist_ok=True)
        lock = FileLock(
            self.root / ".write.lock",
            timeout_seconds=self.lock_timeout_seconds,
            poll_interval_seconds=self.lock_poll_interval_seconds,
        )
        try:
            lock.acquire()
        except FileLockTimeout as exc:
            raise LocalizedStoreError(str(exc)) from exc
        self._lock_handle = lock

    def _release_lock(self) -> None:
        lock = self._lock_handle
        self._lock_handle = None
        if lock is not None:
            lock.release()

    def prepare(self) -> None:
        self._acquire_lock()
        try:
            self._recover_stale_staging_locked()
        finally:
            self._release_lock()

    def recover_stale_staging(self) -> list[Path]:
        self._acquire_lock()
        try:
            return self._recover_stale_staging_locked()
        finally:
            self._release_lock()

    def _recover_stale_staging_locked(self) -> list[Path]:
        if self._lock_handle is None:
            raise LocalizedStoreError("Staging recovery requires the write lock.")
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
        self._acquire_lock()
        try:
            self._recover_stale_staging_locked()
            staging = self.root / f".staging-{uuid.uuid4().hex}"
            staging.mkdir(mode=0o700)
            _fsync_directory(self.root)
            return staging
        except Exception:
            self._release_lock()
            raise

    def write_local_state(self, payload: dict[str, Any]) -> None:
        """Persist non-exportable machine paths while the transaction is locked."""
        if self._lock_handle is None:
            raise LocalizedStoreError("Localized local-state write requires the write lock.")
        required = (
            "source_session",
            "source_database",
            "optimized_database",
            "prior_map",
        )
        if any(
            not isinstance(payload.get(name), str) or not payload[name]
            for name in required
        ):
            raise LocalizedStoreError("Localized local-state paths are invalid.")
        _atomic_json(
            self.root / "local_state.json",
            {
                "format": "MarketScannerLocalizedLocalState",
                "version": 1,
                **payload,
            },
        )

    def local_state(self) -> dict[str, Any]:
        """Read the legacy, unversioned path state for explicit migration only."""
        path = self.root / "local_state.json"
        try:
            if not stat.S_ISREG(path.lstat().st_mode):
                raise LocalizedStoreError("Localized local state is not a regular file.")
            payload = json.loads(
                path.read_text(encoding="utf-8"), parse_constant=_reject_nonfinite
            )
        except (OSError, UnicodeDecodeError, json.JSONDecodeError, ValueError) as exc:
            raise LocalizedStoreError("Localized local state is invalid.") from exc
        if (
            not isinstance(payload, dict)
            or payload.get("format") != "MarketScannerLocalizedLocalState"
            or payload.get("version") != 1
        ):
            raise LocalizedStoreError("Localized local-state contract is invalid.")
        for name in (
            "source_session",
            "source_database",
            "optimized_database",
            "prior_map",
        ):
            if not isinstance(payload.get(name), str) or not payload[name]:
                raise LocalizedStoreError("Localized local-state paths are invalid.")
        return payload

    @staticmethod
    def _validate_local_input_payload(
        payload: Any,
        *,
        expected_identity_id: str | None = None,
    ) -> dict[str, Any]:
        if (
            not isinstance(payload, dict)
            or payload.get("format") != "MarketScannerLocalizedLocalInputs"
            or payload.get("version") != 1
        ):
            raise LocalizedStoreError("Localized local-input contract is invalid.")
        identity_id = payload.get("input_identity_id")
        if (
            not isinstance(identity_id, str)
            or re.fullmatch(r"[0-9a-f]{64}", identity_id) is None
            or identity_id != local_input_identity_id(payload)
            or (expected_identity_id is not None and identity_id != expected_identity_id)
        ):
            raise LocalizedStoreError("Localized local-input identity is invalid.")
        paths = payload.get("paths")
        identities = payload.get("identities")
        required_paths = {
            "source_session",
            "source_database",
            "optimized_database",
            "prior_map",
        }
        required_identities = {
            "session_input_bundle_sha256",
            "source_database_sha256",
            "optimized_database_sha256",
            "prior_map_sha256",
            "processing_parameter_sha256",
        }
        if not isinstance(paths, dict) or set(paths) != required_paths or any(
            not isinstance(paths.get(name), str) or not paths[name]
            for name in required_paths
        ):
            raise LocalizedStoreError("Localized local-input paths are invalid.")
        if not isinstance(identities, dict) or set(identities) != required_identities:
            raise LocalizedStoreError("Localized local-input hashes are invalid.")
        for name in required_identities:
            value = identities.get(name)
            if not isinstance(value, str) or re.fullmatch(r"[0-9a-f]{64}", value) is None:
                raise LocalizedStoreError("Localized local-input hashes are invalid.")
        return payload

    def _write_local_inputs_after_version_durable(
        self,
        payload: dict[str, Any],
        *,
        expected_identity_id: str,
    ) -> None:
        """Create one content-addressed local path record before pointer commit."""

        if self._lock_handle is None:
            raise LocalizedStoreError("Localized local-input write requires the write lock.")
        normalized = self._validate_local_input_payload(
            payload, expected_identity_id=expected_identity_id
        )
        created_directory = not self.local_inputs.exists()
        self.local_inputs.mkdir(parents=True, exist_ok=True)
        if created_directory:
            _fsync_directory(self.root)
        destination = self.local_inputs / f"{expected_identity_id}.json"
        if destination.exists():
            existing = self._read_local_input_file(destination, expected_identity_id)
            if existing != normalized:
                raise LocalizedStoreError(
                    "Localized local-input identity already has different content."
                )
            _fsync_file(destination)
            _fsync_directory(self.local_inputs)
            return
        temporary = self.local_inputs / f".{expected_identity_id}.{uuid.uuid4().hex}.tmp"
        try:
            with temporary.open("x", encoding="utf-8") as handle:
                json.dump(
                    normalized,
                    handle,
                    ensure_ascii=False,
                    indent=2,
                    sort_keys=True,
                    allow_nan=False,
                )
                handle.write("\n")
                handle.flush()
                os.fsync(handle.fileno())
            _atomic_replace(temporary, destination)
            _fsync_directory(self.local_inputs)
        finally:
            temporary.unlink(missing_ok=True)

    def _read_local_input_file(
        self, path: Path, expected_identity_id: str
    ) -> dict[str, Any]:
        flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
        try:
            path_stat = path.lstat()
            if not stat.S_ISREG(path_stat.st_mode):
                raise LocalizedStoreError(
                    "Localized local-input record is not a regular file."
                )
            descriptor = os.open(path, flags)
            with os.fdopen(descriptor, "rb") as handle:
                file_stat = os.fstat(handle.fileno())
                content = handle.read()
            path_after = path.lstat()
            if (
                not stat.S_ISREG(file_stat.st_mode)
                or not stat.S_ISREG(path_after.st_mode)
                or (path_stat.st_dev, path_stat.st_ino, path_stat.st_size)
                != (file_stat.st_dev, file_stat.st_ino, file_stat.st_size)
                or (file_stat.st_dev, file_stat.st_ino, file_stat.st_size)
                != (path_after.st_dev, path_after.st_ino, path_after.st_size)
            ):
                raise LocalizedStoreError(
                    "Localized local-input record is not a regular file."
                )
            payload = json.loads(
                content.decode("utf-8"), parse_constant=_reject_nonfinite
            )
        except LocalizedStoreError:
            raise
        except (OSError, UnicodeDecodeError, json.JSONDecodeError, ValueError) as exc:
            raise LocalizedStoreError("Localized local-input record is invalid.") from exc
        return self._validate_local_input_payload(
            payload, expected_identity_id=expected_identity_id
        )

    def local_inputs_for(self, snapshot: LocalizedSnapshot) -> dict[str, Any]:
        identity_id = snapshot.input_identity_id
        if identity_id is None:
            raise LocalizedStoreError(
                "Legacy localized versions require explicit input migration before replay."
            )
        verified = self.resolve_version(snapshot.version_id)
        if verified != snapshot:
            raise LocalizedStoreError("Localized snapshot changed before local-input read.")
        record = self._read_local_input_file(
            self.local_inputs / f"{identity_id}.json", identity_id
        )
        identities = record["identities"]
        if (
            identities["session_input_bundle_sha256"]
            != snapshot.session_input_bundle_sha256
        ):
            raise LocalizedStoreError(
                "Localized local-input bundle does not match the version."
            )
        return record

    def abort(self, staging: Path) -> None:
        try:
            if staging.parent != self.root or not staging.name.startswith(".staging-"):
                raise LocalizedStoreError("Refusing to remove a non-staging directory.")
            if staging.exists():
                shutil.rmtree(staging)
                _fsync_directory(self.root)
        finally:
            self._release_lock()

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
        publication_files_present = bool(
            set(actual_files) & set(PUBLICATION_EVIDENCE_FILES)
        )
        calibrated_files_present = bool(
            set(actual_files) & set(CALIBRATED_DELIVERABLE_FILES)
        )
        version_files = (
            CURRENT_PUBLISHED_VERSION_FILES
            if publication_files_present and calibrated_files_present
            else PUBLISHED_VERSION_FILES
            if publication_files_present
            else CURRENT_REQUIRED_VERSION_FILES
            if calibrated_files_present
            else REQUIRED_VERSION_FILES
        )
        missing = sorted(set(version_files) - set(actual_files))
        unexpected = sorted(set(actual_files) - set(version_files))
        if missing or unexpected:
            raise LocalizedStoreError(
                f"Localized version file set mismatch: missing={missing}, unexpected={unexpected}"
            )
        parsed: dict[str, Any] = {}
        for name in version_files:
            path = staging / name
            if not stat.S_ISREG(path.lstat().st_mode):
                raise LocalizedStoreError(
                    f"Localized artifact must be a regular file: {name}"
                )
            if path.stat().st_size <= 0:
                raise LocalizedStoreError(f"Localized artifact is empty: {name}")
            if path.suffix in {".json", ".geojson"}:
                try:
                    parsed[name] = json.loads(
                        path.read_text(encoding="utf-8"),
                        parse_constant=_reject_nonfinite,
                    )
                except (OSError, UnicodeDecodeError, json.JSONDecodeError, ValueError) as exc:
                    raise LocalizedStoreError(f"Localized JSON is invalid: {name}: {exc}") from exc
        for name in ("optimized_map_trajectory.geojson", "localized_price_tags.geojson"):
            if parsed[name].get("type") != "FeatureCollection":
                raise LocalizedStoreError(f"GeoJSON is not a FeatureCollection: {name}")
        expected_contracts = {
            # Standard-workbook MapCase02 packages are formal prior-map v2;
            # legacy packages remain v1. The localized store preserves the
            # exact source manifest and must accept both frozen versions.
            "prior_map_manifest.json": ("MarketScannerPriorMap", {1, 2}),
            "source_manifest.json": ("MarketScannerLocalizedSourceManifest", 2),
            "processing_manifest.json": ("MarketScannerLocalizedProcessing", 2),
            "localization_constraints.json": ("MarketScannerOfflineLocalizationConstraints", 1),
            "localization_report.json": ("MarketScannerLocalizationReport", 1),
            "factor_graph_report.json": (
                "MarketScannerRelativeSE2FactorGraphReport",
                2,
            ),
            "review_items.json": ("MarketScannerLocalizationReviewItems", 1),
            "localized_review.json": ("MarketScannerLocalizedReview", 1),
            "manual_edits.json": ("MarketScannerManualEdits", 4),
            "shelf_tag_index.json": ("MarketScannerShelfTagIndex", 1),
        }
        if calibrated_files_present:
            expected_contracts["calibrated_deliverables_manifest.json"] = (
                "MarketScannerCalibratedDeliverablesManifest",
                1,
            )
        if publication_files_present:
            expected_contracts.update(
                {
                    "field_evidence.json": (
                        "MarketScannerFieldQualificationEvidence",
                        3,
                    ),
                    "qualification_manifest.json": (
                        "MarketScannerPublishedQualificationManifest",
                        1,
                    ),
                }
            )
        for name, (expected_format, expected_version) in expected_contracts.items():
            payload = parsed[name]
            allowed_versions = (
                expected_version
                if isinstance(expected_version, set)
                else {expected_version}
            )
            actual_version = payload.get("version") if isinstance(payload, dict) else None
            if (
                not isinstance(payload, dict)
                or payload.get("format") != expected_format
                or type(actual_version) is not int
                or actual_version not in allowed_versions
            ):
                raise LocalizedStoreError(f"Localized artifact contract is invalid: {name}")
        if not isinstance(parsed["online_localization_trace.json"], list):
            raise LocalizedStoreError("Online localization trace must be an array.")
        tags = parsed["localized_price_tags.json"]
        tag_features = parsed["localized_price_tags.geojson"].get("features")
        if not isinstance(tags, list) or not isinstance(tag_features, list):
            raise LocalizedStoreError("Localized tag artifacts are invalid.")
        tag_ids = [item.get("tag_id") for item in tags if isinstance(item, dict)]
        positioned_tag_ids = [
            item.get("tag_id")
            for item in tags
            if isinstance(item, dict)
            and isinstance(item.get("final_map_position"), dict)
        ]
        feature_tag_ids = [
            feature.get("properties", {}).get("tag_id")
            for feature in tag_features
            if isinstance(feature, dict)
        ]
        if (
            len(tag_ids) != len(tags)
            or any(not isinstance(item, str) or not item for item in tag_ids)
            or len(set(tag_ids)) != len(tag_ids)
            or len(feature_tag_ids) != len(tag_features)
            or feature_tag_ids != positioned_tag_ids
        ):
            raise LocalizedStoreError("Localized tag JSON/GeoJSON counts or IDs differ.")
        audit_lines = (staging / "audit_log.jsonl").read_text(
            encoding="utf-8"
        ).splitlines()
        if not audit_lines:
            raise LocalizedStoreError("Localized audit log is empty.")
        try:
            if any(
                not isinstance(json.loads(line, parse_constant=_reject_nonfinite), dict)
                for line in audit_lines
            ):
                raise ValueError("non-object audit record")
        except (json.JSONDecodeError, ValueError) as exc:
            raise LocalizedStoreError("Localized audit log is invalid.") from exc
        csv_count = 0
        with (staging / "localized_price_tags.csv").open(
            "r", encoding="utf-8", newline=""
        ) as handle:
            reader = csv.DictReader(handle)
            header = reader.fieldnames
            if not header or "tag_id" not in header or "approval_status" not in header:
                raise LocalizedStoreError("Localized CSV header is invalid.")
            csv_ids = [row.get("tag_id") for row in reader]
            csv_count = len(csv_ids)
        if csv_count != len(tags) or csv_ids != tag_ids:
            raise LocalizedStoreError("Localized tag CSV does not match tag JSON order.")
        if calibrated_files_present:
            self._validate_calibrated_deliverables(
                staging,
                parsed["calibrated_deliverables_manifest.json"],
                tags=tags,
                tag_ids=tag_ids,
            )
        report = parsed["localization_report.json"]
        factor_graph = parsed["factor_graph_report.json"]
        source = parsed["source_manifest.json"]
        processing = parsed["processing_manifest.json"]
        session_input = parsed["session_input_manifest.json"]
        journal = parsed["manual_edits.json"]
        if calibrated_files_present:
            deliverables = parsed["calibrated_deliverables_manifest.json"]
            delivery_identity_checks = {
                "input_identity_id": report.get("input_identity_id"),
                "session_input_bundle_sha256": report.get(
                    "session_input_bundle_sha256"
                ),
                "source_database_sha256": report.get(
                    "source_database_sha256"
                ),
                "optimized_database_sha256": report.get(
                    "optimized_database_sha256"
                ),
                "prior_map_id": report.get("prior_map_id"),
                "prior_map_package_sha256": report.get("prior_map_sha256"),
                "canonical_source_sha256": (
                    report.get("prior_map_identity_binding") or {}
                ).get("canonical_source_sha256"),
            }
            if any(
                deliverables.get(name) != expected
                for name, expected in delivery_identity_checks.items()
            ):
                raise LocalizedStoreError(
                    "Calibrated deliverables identity differs from localization report."
                )
            report_counts = {
                "source_node_count": report.get("source_node_count"),
                "source_tag_count": report.get("tag_source_record_count"),
                "retained_tag_count": report.get("tag_retained_count"),
                "positioned_tag_count": report.get("tag_positioned_count"),
                "unpositioned_tag_count": report.get("tag_unpositioned_count"),
                "shelf_associated_tag_count": report.get(
                    "tag_shelf_associated_count"
                ),
                "unassociated_tag_count": report.get("tag_unassociated_count"),
                "low_confidence_tag_count": report.get(
                    "tag_low_confidence_count"
                ),
            }
            if any(
                deliverables.get(name) != expected
                for name, expected in report_counts.items()
            ):
                raise LocalizedStoreError(
                    "Calibrated deliverables counts differ from localization report."
                )
        try:
            session_contract = validate_session_input_manifest_contract(
                session_input
            )
        except LocalizedStoreError as exc:
            raise LocalizedStoreError(
                "Localized artifact contract is invalid: "
                f"session_input_manifest.json: {exc}"
            ) from exc
        session_input_version = session_contract["version"]
        if publication_files_present and report.get("publish_state") not in {
            "published",
            "revoked",
            "superseded",
        }:
            raise LocalizedStoreError(
                "Qualification evidence is allowed only in publication states."
            )
        expected_recovery_binding = session_contract[
            "recovery_evidence_binding"
        ]
        for artifact_name, artifact in (
            ("localization_report.json", report),
            ("processing_manifest.json", processing),
        ):
            artifact_version = artifact.get("session_input_manifest_version")
            if (
                isinstance(artifact_version, bool)
                or not isinstance(artifact_version, int)
                or artifact_version != session_input_version
                or artifact.get("recovery_evidence_binding")
                != expected_recovery_binding
            ):
                raise LocalizedStoreError(
                    "Localized session input version or recovery binding differs: "
                    f"{artifact_name}"
                )
        if source.get("source_database_name") != session_contract[
            "source_database_name"
        ]:
            raise LocalizedStoreError(
                "Localized source database name differs from session manifest."
            )
        state = str(report.get("publish_state") or "invalid")
        if state not in VERSION_STATES:
            raise LocalizedStoreError(f"Localized publish state is invalid: {state}")
        try:
            revision = int(journal.get("revision"))
        except (TypeError, ValueError) as exc:
            raise LocalizedStoreError("Manual edit revision is invalid.") from exc
        if isinstance(journal.get("revision"), bool) or revision < 1:
            raise LocalizedStoreError("Manual edit revision is invalid.")
        if processing.get("publish_state") != state:
            raise LocalizedStoreError("Localized report and processing state differ.")
        solver = report.get("solver")
        publish_gate = report.get("publish_gate")
        if not isinstance(solver, dict) or not isinstance(publish_gate, dict):
            raise LocalizedStoreError("Localized solver or publish gate is invalid.")
        full_solver = (
            solver.get("type") == "relative_se2_factor_graph"
            and solver.get("full_factor_graph") is True
            and solver.get("published_capable") is True
            and solver.get("graph_quality_passed") is True
        )
        factor_graph_valid = (
            factor_graph.get("solver") == "rtabmap_g2o_slam2d"
            and factor_graph.get("full_factor_graph") is True
            and factor_graph.get("published_capable") is True
            and factor_graph.get("converged") is True
            and factor_graph.get("solver_converged") is True
            and factor_graph.get("graph_integrity_passed") is True
            and factor_graph.get("graph_quality_passed") is True
            and isinstance(factor_graph.get("quality_policy"), dict)
            and isinstance(factor_graph.get("factor_set_sha256"), str)
            and re.fullmatch(r"[0-9a-f]{64}", factor_graph["factor_set_sha256"])
            is not None
            and solver.get("factor_set_sha256")
            == factor_graph.get("factor_set_sha256")
        )
        if full_solver != factor_graph_valid:
            raise LocalizedStoreError(
                "Localized solver capability differs from the native factor report."
            )
        if publish_gate.get("passed") is True and (
            not full_solver or publish_gate.get("blockers") != []
        ):
            raise LocalizedStoreError(
                "Localized publish gate cannot pass without a verified full factor graph."
            )
        identity_values = {
            session_input.get("input_identity_id"),
            source.get("input_identity_id"),
            processing.get("input_identity_id"),
            journal.get("input_identity_id"),
        }
        if len(identity_values) != 1:
            raise LocalizedStoreError("Localized input identities differ across artifacts.")
        input_identity_id = next(iter(identity_values))
        if (
            not isinstance(input_identity_id, str)
            or re.fullmatch(r"[0-9a-f]{64}", input_identity_id) is None
        ):
            raise LocalizedStoreError("Localized input identity is invalid.")
        bundle_values = {
            session_input.get("bundle_sha256"),
            source.get("session_input_bundle_sha256"),
            processing.get("session_input_bundle_sha256"),
            journal.get("session_input_bundle_sha256"),
        }
        if len(bundle_values) != 1:
            raise LocalizedStoreError("Localized session input bundles differ.")
        session_input_bundle_sha256 = next(iter(bundle_values))
        if (
            not isinstance(session_input_bundle_sha256, str)
            or re.fullmatch(r"[0-9a-f]{64}", session_input_bundle_sha256) is None
        ):
            raise LocalizedStoreError("Localized session input bundle is invalid.")
        identity_fields = {
            "source_database_sha256": source.get("source_database_sha256_before"),
            "optimized_database_sha256": source.get("optimized_database_sha256"),
            "prior_map_sha256": source.get("prior_map_sha256"),
            "processing_parameter_sha256": processing.get(
                "processing_parameter_sha256"
            ),
        }
        for name, value in identity_fields.items():
            if not isinstance(value, str) or re.fullmatch(r"[0-9a-f]{64}", value) is None:
                raise LocalizedStoreError(f"Localized identity hash is invalid: {name}")
            if processing.get(name) != value or journal.get(name) != value:
                raise LocalizedStoreError(
                    f"Localized identity hash differs across artifacts: {name}"
                )
        if session_input.get("source_database_sha256") != identity_fields[
            "source_database_sha256"
        ]:
            raise LocalizedStoreError(
                "Localized session input database hash differs from source manifest."
            )
        if (
            factor_graph.get("input_identity_id") != input_identity_id
            or factor_graph.get("optimized_database_sha256")
            != identity_fields["optimized_database_sha256"]
        ):
            raise LocalizedStoreError(
                "Native factor graph report differs from localized input identity."
            )
        quality_policy = factor_graph.get("quality_policy")
        if full_solver and (
            not isinstance(quality_policy, dict)
            or processing.get("factor_graph_quality_policy_sha256")
            != quality_policy.get("policy_sha256")
            or processing.get("factor_graph_quality_policy_version")
            != quality_policy.get("policy_version")
        ):
            raise LocalizedStoreError(
                "Localized processing manifest differs from factor graph quality policy."
            )
        files = [
            {
                "file": name,
                "bytes": (staging / name).stat().st_size,
                "sha256": _sha256(staging / name),
            }
            for name in version_files
        ]
        return {
            "format": "MarketScannerLocalizedVersionManifest",
            "version": (
                6
                if publication_files_present and calibrated_files_present
                else 4
                if publication_files_present
                else 5
                if calibrated_files_present
                else 3
            ),
            "state": state,
            "revision": revision,
            "parent_version": parent_version,
            "input_identity_id": input_identity_id,
            "session_input_bundle_sha256": session_input_bundle_sha256,
            **identity_fields,
            "files": files,
        }

    @staticmethod
    def _validate_calibrated_deliverables(
        staging: Path,
        manifest: dict[str, Any],
        *,
        tags: list[dict[str, Any]],
        tag_ids: list[str],
    ) -> None:
        required_keys = {
            "format", "version", "input_identity_id",
            "session_input_bundle_sha256", "source_database_sha256",
            "optimized_database_sha256", "prior_map_id",
            "prior_map_package_sha256", "canonical_source_sha256",
            "coordinate_contract_version", "source_node_count",
            "exported_node_count", "one_second_row_count",
            "one_second_unavailable_count", "clock_unavailable_node_count",
            "source_tag_count", "retained_tag_count", "positioned_tag_count",
            "unpositioned_tag_count", "shelf_associated_tag_count",
            "unassociated_tag_count", "low_confidence_tag_count",
            "result_quality_status", "publish_permitted",
            "algorithm_degradation_codes", "files",
        }
        if set(manifest) != required_keys:
            raise LocalizedStoreError(
                "Calibrated deliverables manifest key set is invalid."
            )
        hashes = (
            "input_identity_id", "session_input_bundle_sha256",
            "source_database_sha256", "optimized_database_sha256",
            "prior_map_package_sha256", "canonical_source_sha256",
        )
        if any(
            not isinstance(manifest.get(name), str)
            or re.fullmatch(r"[0-9a-f]{64}", manifest[name]) is None
            for name in hashes
        ):
            raise LocalizedStoreError(
                "Calibrated deliverables identity is invalid."
            )
        count_names = (
            "source_node_count", "exported_node_count", "one_second_row_count",
            "one_second_unavailable_count", "clock_unavailable_node_count",
            "source_tag_count", "retained_tag_count", "positioned_tag_count",
            "unpositioned_tag_count", "shelf_associated_tag_count",
            "unassociated_tag_count", "low_confidence_tag_count",
        )
        if any(
            isinstance(manifest.get(name), bool)
            or not isinstance(manifest.get(name), int)
            or manifest[name] < 0
            for name in count_names
        ):
            raise LocalizedStoreError(
                "Calibrated deliverables count is invalid."
            )
        if (
            manifest["source_node_count"] != manifest["exported_node_count"]
            or manifest["source_tag_count"] != manifest["retained_tag_count"]
            or manifest["retained_tag_count"] != len(tags)
            or manifest["positioned_tag_count"]
            + manifest["unpositioned_tag_count"]
            != len(tags)
            or manifest["shelf_associated_tag_count"]
            + manifest["unassociated_tag_count"]
            != len(tags)
            or manifest["low_confidence_tag_count"] > len(tags)
        ):
            raise LocalizedStoreError(
                "Calibrated deliverables inventory is incomplete."
            )
        expected_files = {
            "calibrated_positions_by_node.csv",
            "calibrated_positions_1s.csv",
            "localized_price_tags.json",
            "localized_price_tags.csv",
        }
        entries = manifest.get("files")
        if not isinstance(entries, list) or len(entries) != len(expected_files):
            raise LocalizedStoreError(
                "Calibrated deliverables file inventory is invalid."
            )
        by_name: dict[str, dict[str, Any]] = {}
        for entry in entries:
            if (
                not isinstance(entry, dict)
                or set(entry) != {"file", "bytes", "sha256", "row_count"}
                or entry.get("file") in by_name
            ):
                raise LocalizedStoreError(
                    "Calibrated deliverables file entry is invalid."
                )
            by_name[str(entry["file"])] = entry
        if set(by_name) != expected_files:
            raise LocalizedStoreError(
                "Calibrated deliverables file set is invalid."
            )
        for name, entry in by_name.items():
            path = staging / name
            if (
                not path.is_file()
                or isinstance(entry.get("bytes"), bool)
                or not isinstance(entry.get("bytes"), int)
                or entry["bytes"] != path.stat().st_size
                or not isinstance(entry.get("row_count"), int)
                or entry["row_count"] < 0
                or not isinstance(entry.get("sha256"), str)
                or entry["sha256"] != _sha256(path)
            ):
                raise LocalizedStoreError(
                    f"Calibrated deliverable identity mismatch: {name}"
                )
        with (staging / "calibrated_positions_by_node.csv").open(
            "r", encoding="utf-8", newline=""
        ) as handle:
            node_rows = list(csv.DictReader(handle))
        node_ids = [row.get("node_id") for row in node_rows]
        try:
            parsed_node_ids = [int(value) for value in node_ids]
        except (TypeError, ValueError) as exc:
            raise LocalizedStoreError(
                "Calibrated node table IDs are invalid."
            ) from exc
        if (
            len(node_rows) != manifest["exported_node_count"]
            or len(set(parsed_node_ids)) != len(parsed_node_ids)
            or any(value <= 0 for value in parsed_node_ids)
        ):
            raise LocalizedStoreError(
                "Calibrated node table IDs or count are invalid."
            )
        for row in node_rows:
            if (
                row.get("prior_map_id") != manifest["prior_map_id"]
                or row.get("canonical_source_sha256")
                != manifest["canonical_source_sha256"]
                or row.get("prior_map_package_sha256")
                != manifest["prior_map_package_sha256"]
                or row.get("input_identity_id") != manifest["input_identity_id"]
            ):
                raise LocalizedStoreError(
                    "Calibrated node table map identity differs."
                )
            for field in ("x_m", "y_m", "yaw_rad"):
                try:
                    value = float(row[field])
                except (KeyError, TypeError, ValueError) as exc:
                    raise LocalizedStoreError(
                        "Calibrated node table coordinate is invalid."
                    ) from exc
                if not math.isfinite(value):
                    raise LocalizedStoreError(
                        "Calibrated node table coordinate is non-finite."
                    )
        with (staging / "calibrated_positions_1s.csv").open(
            "r", encoding="utf-8", newline=""
        ) as handle:
            second_rows = list(csv.DictReader(handle))
        if len(second_rows) != manifest["one_second_row_count"]:
            raise LocalizedStoreError(
                "Calibrated one-second table count is invalid."
            )
        unavailable_count = 0
        for row in second_rows:
            status = row.get("position_status")
            if status not in {"AVAILABLE", "LOW_CONFIDENCE", "UNAVAILABLE"}:
                raise LocalizedStoreError(
                    "Calibrated one-second position status is invalid."
                )
            available = status != "UNAVAILABLE"
            if not available:
                unavailable_count += 1
            coordinate_values = [row.get(name) for name in ("x_m", "y_m", "yaw_rad")]
            if available != all(value not in {None, ""} for value in coordinate_values):
                raise LocalizedStoreError(
                    "Calibrated one-second position status is inconsistent."
                )
            if available and any(
                not math.isfinite(float(value)) for value in coordinate_values
            ):
                raise LocalizedStoreError(
                    "Calibrated one-second coordinate is non-finite."
                )
            if not available and not row.get("position_degradation_code"):
                raise LocalizedStoreError(
                    "Unavailable calibrated second has no degradation reason."
                )
        if unavailable_count != manifest["one_second_unavailable_count"]:
            raise LocalizedStoreError(
                "Calibrated one-second unavailable count differs from manifest."
            )
        expected_row_counts = {
            "calibrated_positions_by_node.csv": len(node_rows),
            "calibrated_positions_1s.csv": len(second_rows),
            "localized_price_tags.json": len(tag_ids),
            "localized_price_tags.csv": len(tag_ids),
        }
        if any(
            by_name[name]["row_count"] != count
            for name, count in expected_row_counts.items()
        ):
            raise LocalizedStoreError(
                "Calibrated deliverable row count differs from its artifact."
            )
        if by_name["localized_price_tags.json"]["row_count"] != len(tag_ids):
            raise LocalizedStoreError(
                "Calibrated tag manifest count differs from tag identities."
            )

    def commit(
        self,
        staging: Path,
        manifest: dict[str, Any],
        *,
        update_current: bool,
        pointer_name: str | None = None,
        local_input_record: dict[str, Any] | None = None,
    ) -> LocalizedSnapshot:
        if self._lock_handle is None:
            raise LocalizedStoreError("Localized commit requires the write lock.")
        try:
            version_id = self._next_version_id()
            version_dir = self.versions / version_id
            if version_dir.exists():
                raise LocalizedStoreError(f"Localized version already exists: {version_id}")
            manifest = {
                **manifest,
                "version_id": version_id,
                "created_at_utc": datetime.now(timezone.utc).isoformat(
                    timespec="milliseconds"
                ),
            }
            manifest_path = staging / "version_manifest.json"
            with manifest_path.open("w", encoding="utf-8") as handle:
                json.dump(
                    manifest,
                    handle,
                    ensure_ascii=False,
                    indent=2,
                    sort_keys=True,
                    allow_nan=False,
                )
                handle.write("\n")
                handle.flush()
                os.fsync(handle.fileno())
            for path in staging.iterdir():
                if path.is_file():
                    _fsync_file(path)
            _fsync_directory(staging)
            _atomic_replace(staging, version_dir)
            # The immutable directory must be durable before any pointer can
            # reference it. Failure leaves an unreferenced version for audit
            # while the previous pointer remains unchanged.
            _fsync_directory(self.versions)
            manifest_sha256 = _sha256(version_dir / "version_manifest.json")
            input_identity_id = manifest.get("input_identity_id")
            session_input_bundle_sha256 = manifest.get(
                "session_input_bundle_sha256"
            )
            if not isinstance(input_identity_id, str):
                raise LocalizedStoreError(
                    "New localized versions require an input identity."
                )
            if local_input_record is not None:
                record_identities = self._validate_local_input_payload(
                    local_input_record, expected_identity_id=input_identity_id
                )["identities"]
                for name in (
                    "session_input_bundle_sha256",
                    "source_database_sha256",
                    "optimized_database_sha256",
                    "prior_map_sha256",
                    "processing_parameter_sha256",
                ):
                    if record_identities.get(name) != manifest.get(name):
                        raise LocalizedStoreError(
                            f"Localized local-input identity differs from version: {name}"
                        )
                self._write_local_inputs_after_version_durable(
                    local_input_record, expected_identity_id=input_identity_id
                )
            else:
                existing_record = self._read_local_input_file(
                    self.local_inputs / f"{input_identity_id}.json",
                    input_identity_id,
                )
                for name, value in existing_record["identities"].items():
                    if value != manifest.get(name):
                        raise LocalizedStoreError(
                            f"Localized inherited input identity differs: {name}"
                        )
            snapshot = LocalizedSnapshot(
                version_id=version_id,
                version_dir=version_dir,
                revision=int(manifest["revision"]),
                state=str(manifest["state"]),
                manifest_sha256=manifest_sha256,
                input_identity_id=input_identity_id,
                session_input_bundle_sha256=str(session_input_bundle_sha256),
            )
            if update_current and pointer_name is not None:
                raise LocalizedStoreError("Localized commit pointer is ambiguous.")
            committed_pointer = "current.json" if update_current else pointer_name
            if committed_pointer is not None:
                self.write_pointer(committed_pointer, snapshot)
            return snapshot
        finally:
            self._release_lock()

    def write_pointer(self, name: str, snapshot: LocalizedSnapshot) -> None:
        if name not in {"current.json", "published.json"}:
            raise LocalizedStoreError("Localized pointer name is invalid.")
        verified = self.resolve_version(snapshot.version_id)
        if verified != snapshot:
            raise LocalizedStoreError("Localized snapshot changed before pointer commit.")
        if name == "published.json":
            if snapshot.state not in {"published", "revoked"}:
                raise LocalizedStoreError("Published pointer requires a publication state.")
            if snapshot.state == "published":
                self._validate_publishable_snapshot(snapshot)
        _atomic_json(
            self.root / name,
            {
                "format": "MarketScannerLocalizedPointer",
                "version": 2,
                "version_id": snapshot.version_id,
                "revision": snapshot.revision,
                "state": snapshot.state,
                "manifest_sha256": snapshot.manifest_sha256,
                "input_identity_id": snapshot.input_identity_id,
            },
        )

    def transition_current(
        self,
        target_state: str,
        *,
        actor: str,
        reason: str,
        expected_version: str | None = None,
    ) -> LocalizedSnapshot:
        allowed = {
            "draft": {"review"},
            "review": {"draft"},
            "published": set(),
            "revoked": set(),
            "superseded": set(),
            "invalid": set(),
        }
        staging = self.begin()
        try:
            current = self.current()
            if current is None:
                raise LocalizedStoreError("Localized current version is missing.")
            if expected_version is not None and current.version_id != expected_version:
                raise LocalizedStoreError("Localized current version changed before transition.")
            if target_state not in allowed.get(current.state, set()):
                raise LocalizedStoreError(
                    f"Localized state transition is invalid: {current.state} -> {target_state}"
                )
            return self._commit_transition(
                staging, current, target_state, actor=actor, reason=reason,
                pointer_name="current.json"
            )
        except Exception:
            if staging.exists():
                self.abort(staging)
            raise

    def publish_current(
        self,
        *,
        actor: str,
        reason: str,
        qualification_evidence_path: Path,
        expected_field_evidence_sha256: str,
        expected_release_identity: dict[str, str],
        expected_version: str | None = None,
    ) -> LocalizedSnapshot:
        staging = self.begin()
        try:
            current = self.current()
            if current is None or current.state != "review":
                raise LocalizedStoreError("Only a review version can be published.")
            if expected_version is not None and current.version_id != expected_version:
                raise LocalizedStoreError("Localized current version changed before publication.")
            active = self.published()
            if active is not None and active.state == "published":
                raise LocalizedStoreError(
                    "An active published version already exists; revoke it before publishing again."
                )
            report = self.read_verified_json(
                current, "localization_report.json"
            )
            review_evidence_sha256 = hashlib.sha256(
                self.read_verified_artifacts(
                    current, ("localized_review.json",)
                )["localized_review.json"]
            ).hexdigest()
            try:
                qualification, field_evidence_bytes = inspect_field_evidence_with_bytes(
                    qualification_evidence_path,
                    required_site_type="supermarket",
                )
            except (OSError, QualificationError) as exc:
                raise LocalizedStoreError("Field qualification evidence is invalid.") from exc
            if qualification["file_sha256"] != expected_field_evidence_sha256:
                raise LocalizedStoreError(
                    "Field qualification evidence changed after inspection."
                )
            source = self.read_verified_json(current, "source_manifest.json")
            factor_graph = self.read_verified_json(current, "factor_graph_report.json")
            quality = factor_graph.get("quality_policy") if isinstance(factor_graph, dict) else None
            if (
                not isinstance(source, dict)
                or qualification["prior_map_id"] != source.get("prior_map_id")
                or qualification["prior_map_sha256"] != source.get("prior_map_sha256")
                or not isinstance(quality, dict)
                or qualification["quality_policy_sha256"] != quality.get("policy_sha256")
                or qualification["quality_policy_version"] != quality.get("policy_version")
                or qualification["quality_policy_sha256"]
                != expected_release_identity.get("quality_policy_sha256")
                or qualification["release_manifest_sha256"]
                != expected_release_identity.get("release_manifest_sha256")
                or qualification["release_git_sha"] != expected_release_identity.get("git_sha")
                or qualification["product_version"] != expected_release_identity.get("product_version")
            ):
                raise LocalizedStoreError(
                    "Field qualification identity does not match the candidate or runtime release."
                )
            field_acceptance = {
                "accepted": True,
                "actor": actor,
                "accepted_at_utc": datetime.now(timezone.utc).isoformat(timespec="milliseconds"),
                "candidate_version": current.version_id,
                "candidate_revision": current.revision,
                "review_evidence_sha256": review_evidence_sha256,
                "field_evidence_sha256": qualification["file_sha256"],
                "field_evidence_body_sha256": qualification["evidence_sha256"],
                "release_manifest_sha256": qualification["release_manifest_sha256"],
                "release_git_sha": qualification["release_git_sha"],
                "product_version": qualification["product_version"],
                "prior_map_id": qualification["prior_map_id"],
                "prior_map_sha256": qualification["prior_map_sha256"],
                "quality_policy_sha256": qualification["quality_policy_sha256"],
                "quality_policy_version": qualification["quality_policy_version"],
                "site_id": qualification["site_id"],
                "site_type": qualification["site_type"],
                "run_count": qualification["run_count"],
                "tag_control_count": qualification["tag_control_count"],
                "field_evidence_file": "field_evidence.json",
                "qualification_manifest_file": "qualification_manifest.json",
                "reason": reason,
            }
            self._validate_publication_gate(report, field_acceptance)
            return self._commit_transition(
                staging, current, "published", actor=actor, reason=reason,
                pointer_name="published.json",
                field_acceptance=field_acceptance,
                field_evidence_bytes=field_evidence_bytes,
            )
        except Exception:
            if staging.exists():
                self.abort(staging)
            raise

    def revoke_published(
        self, *, actor: str, reason: str, expected_version: str | None = None
    ) -> LocalizedSnapshot:
        staging = self.begin()
        try:
            published = self.published()
            if published is None or published.state != "published":
                raise LocalizedStoreError("There is no active published version to revoke.")
            if expected_version is not None and published.version_id != expected_version:
                raise LocalizedStoreError("Published version changed before revocation.")
            return self._commit_transition(
                staging, published, "revoked", actor=actor, reason=reason,
                pointer_name="published.json"
            )
        except Exception:
            if staging.exists():
                self.abort(staging)
            raise

    def _commit_transition(
        self,
        staging: Path,
        source: LocalizedSnapshot,
        target_state: str,
        *,
        actor: str,
        reason: str,
        pointer_name: str,
        field_acceptance: dict[str, Any] | None = None,
        field_evidence_bytes: bytes | None = None,
    ) -> LocalizedSnapshot:
        if self._lock_handle is None:
            raise LocalizedStoreError("Localized transition requires the write lock.")
        try:
            source_has_publication_evidence = all(
                (source.version_dir / name).is_file()
                for name in PUBLICATION_EVIDENCE_FILES
            )
            source_manifest = json.loads(
                (source.version_dir / "version_manifest.json").read_text(
                    encoding="utf-8"
                )
            )
            source_manifest_version = int(source_manifest["version"])
            if source_manifest_version in {5, 6}:
                inherited_files = (
                    CURRENT_PUBLISHED_VERSION_FILES
                    if source_has_publication_evidence
                    else CURRENT_REQUIRED_VERSION_FILES
                )
            else:
                inherited_files = (
                    PUBLISHED_VERSION_FILES
                    if source_has_publication_evidence
                    else REQUIRED_VERSION_FILES
                )
            source_artifacts = self.read_verified_artifacts(
                source,
                inherited_files,
            )
            for name, content in source_artifacts.items():
                (staging / name).write_bytes(content)
            if field_evidence_bytes is not None:
                if field_acceptance is None or target_state != "published":
                    raise LocalizedStoreError(
                        "Published qualification evidence has no acceptance record."
                    )
                if hashlib.sha256(field_evidence_bytes).hexdigest() != field_acceptance.get(
                    "field_evidence_sha256"
                ):
                    raise LocalizedStoreError(
                        "Accepted field evidence bytes differ before publication commit."
                    )
                (staging / "field_evidence.json").write_bytes(field_evidence_bytes)
                _atomic_json(
                    staging / "qualification_manifest.json",
                    {
                        "format": "MarketScannerPublishedQualificationManifest",
                        "version": 1,
                        "candidate_version_id": source.version_id,
                        "candidate_revision": source.revision,
                        "candidate_version_manifest_sha256": source.manifest_sha256,
                        "field_evidence_file": "field_evidence.json",
                        "field_evidence_sha256": field_acceptance[
                            "field_evidence_sha256"
                        ],
                        "field_evidence_body_sha256": field_acceptance[
                            "field_evidence_body_sha256"
                        ],
                        "release_manifest_sha256": field_acceptance[
                            "release_manifest_sha256"
                        ],
                        "release_git_sha": field_acceptance["release_git_sha"],
                        "product_version": field_acceptance["product_version"],
                        "prior_map_id": field_acceptance["prior_map_id"],
                        "prior_map_sha256": field_acceptance[
                            "prior_map_sha256"
                        ],
                        "quality_policy_sha256": field_acceptance[
                            "quality_policy_sha256"
                        ],
                        "quality_policy_version": field_acceptance[
                            "quality_policy_version"
                        ],
                        "accepted_at_utc": field_acceptance["accepted_at_utc"],
                        "actor": field_acceptance["actor"],
                    },
                )
            now = datetime.now(timezone.utc).isoformat(timespec="milliseconds")
            for name in ("localization_report.json", "processing_manifest.json"):
                path = staging / name
                payload = json.loads(path.read_text(encoding="utf-8"))
                payload["publish_state"] = target_state
                if field_acceptance is not None:
                    payload["field_acceptance"] = field_acceptance
                history = list(payload.get("state_history", []))
                history.append(
                    {
                        "from": source.state,
                        "from_version": source.version_id,
                        "to": target_state,
                        "actor": actor,
                        "reason": reason,
                        "created_at_utc": now,
                    }
                )
                payload["state_history"] = history
                _atomic_json(path, payload)
            with (staging / "audit_log.jsonl").open(
                "a", encoding="utf-8"
            ) as handle:
                json.dump(
                    {
                        "event": "localized_state_transition",
                        "from": source.state,
                        "from_version": source.version_id,
                        "to": target_state,
                        "actor": actor,
                        "reason": reason,
                        "created_at_utc": now,
                    },
                    handle,
                    ensure_ascii=False,
                    separators=(",", ":"),
                    sort_keys=True,
                    allow_nan=False,
                )
                handle.write("\n")
            manifest = self.validate_staging(
                staging, parent_version=source.version_id
            )
            snapshot = self.commit(
                staging,
                manifest,
                update_current=False,
                pointer_name=pointer_name,
            )
            return snapshot
        except Exception:
            raise

    @staticmethod
    def _validate_publication_gate(
        report: dict[str, Any], field_acceptance: dict[str, Any]
    ) -> None:
        gate = report.get("publish_gate")
        solver = report.get("solver")
        valid_acceptance = (
            isinstance(field_acceptance, dict)
            and field_acceptance.get("accepted") is True
            and isinstance(field_acceptance.get("actor"), str)
            and bool(field_acceptance.get("actor", "").strip())
            and isinstance(field_acceptance.get("accepted_at_utc"), str)
            and bool(field_acceptance.get("accepted_at_utc", "").strip())
            and isinstance(field_acceptance.get("field_evidence_sha256"), str)
            and re.fullmatch(
                r"[0-9a-f]{64}", field_acceptance.get("field_evidence_sha256", "")
            )
            is not None
            and field_acceptance.get("field_evidence_file") == "field_evidence.json"
            and field_acceptance.get("qualification_manifest_file")
            == "qualification_manifest.json"
            and isinstance(field_acceptance.get("review_evidence_sha256"), str)
            and re.fullmatch(
                r"[0-9a-f]{64}", field_acceptance.get("review_evidence_sha256", "")
            ) is not None
            and field_acceptance.get("site_type") == "supermarket"
            and isinstance(field_acceptance.get("run_count"), int)
            and field_acceptance.get("run_count", 0) >= 3
        )
        if valid_acceptance:
            try:
                accepted_at = datetime.fromisoformat(
                    field_acceptance["accepted_at_utc"].replace("Z", "+00:00")
                )
                valid_acceptance = accepted_at.tzinfo is not None and (
                    accepted_at.utcoffset() == timezone.utc.utcoffset(accepted_at)
                )
            except (TypeError, ValueError):
                valid_acceptance = False
        if (
            not isinstance(gate, dict)
            or gate.get("passed") is not True
            or gate.get("blockers") != []
            or not isinstance(solver, dict)
            or solver.get("full_factor_graph") is not True
            or solver.get("published_capable") is not True
            or solver.get("type") != "relative_se2_factor_graph"
            or not valid_acceptance
        ):
            raise LocalizedStoreError(
                "Published output requires a verified full-factor-graph gate and field acceptance."
            )

    def _validate_publishable_snapshot(self, snapshot: LocalizedSnapshot) -> None:
        try:
            artifacts = self.read_verified_artifacts(
                snapshot,
                (
                    "localization_report.json",
                    "localized_review.json",
                    "field_evidence.json",
                    "qualification_manifest.json",
                ),
            )
            report = json.loads(
                artifacts["localization_report.json"].decode("utf-8"),
                parse_constant=_reject_nonfinite,
            )
            qualification_manifest = json.loads(
                artifacts["qualification_manifest.json"].decode("utf-8"),
                parse_constant=_reject_nonfinite,
            )
            embedded_qualification = inspect_field_evidence(
                snapshot.version_dir / "field_evidence.json",
                required_site_type="supermarket",
            )
        except (
            LocalizedStoreError,
            QualificationError,
            UnicodeDecodeError,
            ValueError,
            json.JSONDecodeError,
        ) as exc:
            raise LocalizedStoreError("Published localization report is invalid.") from exc
        acceptance = report.get("field_acceptance") if isinstance(report, dict) else None
        if not isinstance(report, dict) or not isinstance(acceptance, dict):
            raise LocalizedStoreError("Published output has no field acceptance record.")
        if acceptance.get("review_evidence_sha256") != hashlib.sha256(
            artifacts["localized_review.json"]
        ).hexdigest():
            raise LocalizedStoreError(
                "Published field acceptance evidence no longer matches the review artifact."
            )
        if (
            not isinstance(qualification_manifest, dict)
            or qualification_manifest.get("format")
            != "MarketScannerPublishedQualificationManifest"
            or qualification_manifest.get("version") != 1
            or qualification_manifest.get("field_evidence_file")
            != "field_evidence.json"
            or acceptance.get("field_evidence_file") != "field_evidence.json"
            or acceptance.get("qualification_manifest_file")
            != "qualification_manifest.json"
            or hashlib.sha256(artifacts["field_evidence.json"]).hexdigest()
            != acceptance.get("field_evidence_sha256")
            or embedded_qualification.get("file_sha256")
            != acceptance.get("field_evidence_sha256")
            or embedded_qualification.get("evidence_sha256")
            != acceptance.get("field_evidence_body_sha256")
        ):
            raise LocalizedStoreError(
                "Published qualification evidence no longer matches its acceptance record."
            )
        qualification_fields = {
            "field_evidence_sha256": "field_evidence_sha256",
            "field_evidence_body_sha256": "field_evidence_body_sha256",
            "release_manifest_sha256": "release_manifest_sha256",
            "release_git_sha": "release_git_sha",
            "product_version": "product_version",
            "prior_map_id": "prior_map_id",
            "prior_map_sha256": "prior_map_sha256",
            "quality_policy_sha256": "quality_policy_sha256",
            "quality_policy_version": "quality_policy_version",
            "accepted_at_utc": "accepted_at_utc",
            "actor": "actor",
        }
        if any(
            qualification_manifest.get(manifest_name)
            != acceptance.get(acceptance_name)
            for manifest_name, acceptance_name in qualification_fields.items()
        ):
            raise LocalizedStoreError(
                "Published qualification manifest identity differs from acceptance."
            )
        self._validate_publication_gate(report, acceptance)

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
        pointer_version = pointer.get("version")
        if (
            pointer.get("format") != "MarketScannerLocalizedPointer"
            or pointer_version not in {1, 2}
        ):
            raise LocalizedStoreError(f"Localized pointer contract is invalid: {name}")
        if re.fullmatch(r"v[0-9]{6}", version_id) is None:
            raise LocalizedStoreError(f"Localized pointer version is unsafe: {version_id}")
        snapshot = self.resolve_version(version_id)
        if snapshot.manifest_sha256 != expected_manifest:
            raise LocalizedStoreError(f"Localized pointer manifest mismatch: {name}")
        if snapshot.revision != revision or snapshot.state != state:
            raise LocalizedStoreError(f"Localized pointer metadata mismatch: {name}")
        if pointer_version == 2 and pointer.get("input_identity_id") != snapshot.input_identity_id:
            raise LocalizedStoreError(f"Localized pointer input identity mismatch: {name}")
        if pointer_version == 1 and snapshot.input_identity_id is not None:
            raise LocalizedStoreError(f"Localized pointer version is stale: {name}")
        if name == "published.json" and snapshot.state == "published":
            self._validate_publishable_snapshot(snapshot)
        return snapshot

    def read_verified_artifacts(
        self,
        snapshot: LocalizedSnapshot,
        names: Iterable[str],
    ) -> dict[str, bytes]:
        """Read a snapshot-bound artifact batch from the descriptors hashed."""

        requested = tuple(names)
        if not requested or len(set(requested)) != len(requested):
            raise LocalizedStoreError("Localized artifact batch is invalid.")
        if any(name not in ALL_LOCALIZED_VERSION_FILES for name in requested):
            raise LocalizedStoreError("Localized artifact name is invalid.")
        verified = self.resolve_version(snapshot.version_id)
        if verified != snapshot:
            raise LocalizedStoreError("Localized snapshot changed before verified read.")
        flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
        try:
            manifest_fd = os.open(snapshot.version_dir / "version_manifest.json", flags)
            with os.fdopen(manifest_fd, "rb") as handle:
                manifest_stat = os.fstat(handle.fileno())
                manifest_bytes = handle.read()
            if not stat.S_ISREG(manifest_stat.st_mode):
                raise LocalizedStoreError(
                    "Localized version manifest is not a regular file."
                )
            if hashlib.sha256(manifest_bytes).hexdigest() != snapshot.manifest_sha256:
                raise LocalizedStoreError("Localized version manifest changed during read.")
            manifest = json.loads(
                manifest_bytes.decode("utf-8"), parse_constant=_reject_nonfinite
            )
            by_name = {
                item["file"]: item
                for item in manifest["files"]
                if isinstance(item, dict) and isinstance(item.get("file"), str)
            }
            contents: dict[str, bytes] = {}
            for name in requested:
                entry = by_name[name]
                artifact_fd = os.open(snapshot.version_dir / name, flags)
                with os.fdopen(artifact_fd, "rb") as handle:
                    artifact_stat = os.fstat(handle.fileno())
                    content = handle.read()
                expected_bytes = int(entry["bytes"])
                if (
                    not stat.S_ISREG(artifact_stat.st_mode)
                    or isinstance(entry.get("bytes"), bool)
                    or len(content) != expected_bytes
                    or hashlib.sha256(content).hexdigest() != entry.get("sha256")
                ):
                    raise LocalizedStoreError(
                        f"Localized artifact changed during verified read: {name}"
                    )
                contents[name] = content
        except LocalizedStoreError:
            raise
        except (
            OSError,
            UnicodeDecodeError,
            json.JSONDecodeError,
            KeyError,
            TypeError,
            ValueError,
        ) as exc:
            raise LocalizedStoreError("Localized artifact batch could not be read safely.") from exc
        return contents

    def read_verified_manifest_and_artifacts(
        self,
        snapshot: LocalizedSnapshot,
        names: Iterable[str],
    ) -> tuple[bytes, dict[str, bytes]]:
        """Return exact manifest bytes with a snapshot-bound artifact batch."""

        contents = self.read_verified_artifacts(snapshot, names)
        flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
        try:
            descriptor = os.open(
                snapshot.version_dir / "version_manifest.json", flags
            )
            with os.fdopen(descriptor, "rb") as handle:
                opened = os.fstat(handle.fileno())
                manifest_bytes = handle.read()
            if (
                not stat.S_ISREG(opened.st_mode)
                or hashlib.sha256(manifest_bytes).hexdigest()
                != snapshot.manifest_sha256
            ):
                raise LocalizedStoreError(
                    "Localized version manifest changed during evidence read."
                )
        except LocalizedStoreError:
            raise
        except OSError as exc:
            raise LocalizedStoreError(
                "Localized version manifest could not be read safely."
            ) from exc
        return manifest_bytes, contents

    def read_verified_artifact(self, version_id: str, name: str) -> bytes:
        """Compatibility wrapper for one verified immutable artifact."""

        snapshot = self.resolve_version(version_id)
        return self.read_verified_artifacts(snapshot, (name,))[name]

    def read_verified_json(
        self,
        snapshot: LocalizedSnapshot,
        name: str,
        *,
        expected_type: type = dict,
    ) -> Any:
        content = self.read_verified_artifacts(snapshot, (name,))[name]
        try:
            payload = json.loads(
                content.decode("utf-8"), parse_constant=_reject_nonfinite
            )
        except (UnicodeDecodeError, json.JSONDecodeError, ValueError) as exc:
            raise LocalizedStoreError(
                f"Localized JSON artifact is invalid: {name}"
            ) from exc
        if not isinstance(payload, expected_type):
            raise LocalizedStoreError(
                f"Localized JSON artifact has the wrong type: {name}"
            )
        return payload

    def resolve_version(self, version_id: str) -> LocalizedSnapshot:
        if re.fullmatch(r"v[0-9]{6}", version_id) is None:
            raise LocalizedStoreError(f"Localized version is unsafe: {version_id}")
        version_dir = self.versions / version_id
        try:
            if not stat.S_ISDIR(version_dir.lstat().st_mode) or version_dir.resolve().parent != self.versions.resolve():
                raise LocalizedStoreError(f"Localized version directory is unsafe: {version_id}")
        except OSError as exc:
            raise LocalizedStoreError(f"Localized version is missing: {version_id}") from exc
        manifest_path = version_dir / "version_manifest.json"
        try:
            if not stat.S_ISREG(manifest_path.lstat().st_mode):
                raise LocalizedStoreError("Localized version manifest is not a regular file.")
            manifest = json.loads(
                manifest_path.read_text(encoding="utf-8"),
                parse_constant=_reject_nonfinite,
            )
            revision = int(manifest["revision"])
            state = str(manifest["state"])
        except (OSError, KeyError, TypeError, ValueError, json.JSONDecodeError) as exc:
            raise LocalizedStoreError(
                f"Localized version manifest is invalid: {version_id}"
            ) from exc
        if (
            manifest.get("format") != "MarketScannerLocalizedVersionManifest"
            or manifest.get("version") not in {1, 2, 3, 4, 5, 6}
            or manifest.get("version_id") != version_id
            or state not in VERSION_STATES
            or revision < 1
        ):
            raise LocalizedStoreError(
                f"Localized version manifest contract is invalid: {version_id}"
            )
        manifest_version = int(manifest["version"])
        expected_files = (
            CURRENT_PUBLISHED_VERSION_FILES
            if manifest_version == 6
            else CURRENT_REQUIRED_VERSION_FILES
            if manifest_version == 5
            else PUBLISHED_VERSION_FILES
            if manifest_version == 4
            else REQUIRED_VERSION_FILES
            if manifest_version == 3
            else VERSION_2_REQUIRED_VERSION_FILES
            if manifest_version == 2
            else LEGACY_REQUIRED_VERSION_FILES
        )
        input_identity_id: str | None = None
        session_input_bundle_sha256: str | None = None
        if manifest_version in {2, 3, 4, 5, 6}:
            input_identity_id = manifest.get("input_identity_id")
            session_input_bundle_sha256 = manifest.get(
                "session_input_bundle_sha256"
            )
            if (
                not isinstance(input_identity_id, str)
                or re.fullmatch(r"[0-9a-f]{64}", input_identity_id) is None
                or not isinstance(session_input_bundle_sha256, str)
                or re.fullmatch(r"[0-9a-f]{64}", session_input_bundle_sha256)
                is None
            ):
                raise LocalizedStoreError(
                    f"Localized version input identity is invalid: {version_id}"
                )
        entries = manifest.get("files")
        if not isinstance(entries, list) or len(entries) != len(expected_files):
            raise LocalizedStoreError(f"Localized version file manifest is invalid: {version_id}")
        by_name: dict[str, dict[str, Any]] = {}
        for entry in entries:
            if not isinstance(entry, dict) or not isinstance(entry.get("file"), str):
                raise LocalizedStoreError(f"Localized version file manifest is invalid: {version_id}")
            name = entry["file"]
            if name in by_name:
                raise LocalizedStoreError(f"Localized version file manifest has duplicates: {version_id}")
            by_name[name] = entry
        if set(by_name) != set(expected_files):
            raise LocalizedStoreError(f"Localized version file set is invalid: {version_id}")
        actual_names = {path.name for path in version_dir.iterdir()}
        if actual_names != set(expected_files) | {"version_manifest.json"}:
            raise LocalizedStoreError(f"Localized version directory contents changed: {version_id}")
        for name in expected_files:
            artifact = version_dir / name
            entry = by_name[name]
            try:
                artifact_stat = artifact.lstat()
                expected_bytes = int(entry["bytes"])
                expected_hash = str(entry["sha256"])
            except (OSError, KeyError, TypeError, ValueError) as exc:
                raise LocalizedStoreError(f"Localized artifact manifest is invalid: {name}") from exc
            if (
                not stat.S_ISREG(artifact_stat.st_mode)
                or isinstance(entry.get("bytes"), bool)
                or artifact_stat.st_size != expected_bytes
                or re.fullmatch(r"[0-9a-f]{64}", expected_hash) is None
                or _sha256(artifact) != expected_hash
            ):
                raise LocalizedStoreError(f"Localized artifact integrity mismatch: {name}")
        return LocalizedSnapshot(
            version_id=version_id,
            version_dir=version_dir,
            revision=revision,
            state=state,
            manifest_sha256=_sha256(manifest_path),
            input_identity_id=input_identity_id,
            session_input_bundle_sha256=session_input_bundle_sha256,
        )

    def current(self) -> LocalizedSnapshot | None:
        return self.resolve_pointer("current.json")

    def published(self) -> LocalizedSnapshot | None:
        return self.resolve_pointer("published.json")


def immutable_version_artifacts(snapshot: LocalizedSnapshot) -> Iterable[Path]:
    return snapshot.version_dir.iterdir()
