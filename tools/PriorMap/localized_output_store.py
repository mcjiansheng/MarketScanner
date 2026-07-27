"""Transactional immutable storage for prior-map localized results."""

from __future__ import annotations

import csv
from datetime import datetime, timezone
import fcntl
import hashlib
import json
import os
import re
import shutil
import stat
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
VERSION_STATES = frozenset(
    {"invalid", "draft", "review", "published", "superseded", "revoked"}
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


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _reject_nonfinite(value: str) -> None:
    raise ValueError(f"Non-finite JSON number is forbidden: {value}")


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
        os.replace(temporary, path)
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
    def __init__(self, output_root: Path):
        self.output_root = output_root
        self.root = output_root / "localized"
        self.versions = self.root / "versions"
        self._lock_handle: Any | None = None

    def _acquire_lock(self) -> None:
        if self._lock_handle is not None:
            raise LocalizedStoreError("Localized write transaction is already active.")
        self.versions.mkdir(parents=True, exist_ok=True)
        handle = (self.root / ".write.lock").open("a+b")
        try:
            fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
        except Exception:
            handle.close()
            raise
        self._lock_handle = handle

    def _release_lock(self) -> None:
        handle = self._lock_handle
        self._lock_handle = None
        if handle is not None:
            try:
                fcntl.flock(handle.fileno(), fcntl.LOCK_UN)
            finally:
                handle.close()

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
        missing = sorted(set(REQUIRED_VERSION_FILES) - set(actual_files))
        unexpected = sorted(set(actual_files) - set(REQUIRED_VERSION_FILES))
        if missing or unexpected:
            raise LocalizedStoreError(
                f"Localized version file set mismatch: missing={missing}, unexpected={unexpected}"
            )
        parsed: dict[str, Any] = {}
        for name in REQUIRED_VERSION_FILES:
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
            "prior_map_manifest.json": ("MarketScannerPriorMap", 1),
            "source_manifest.json": ("MarketScannerLocalizedSourceManifest", 1),
            "processing_manifest.json": ("MarketScannerLocalizedProcessing", 1),
            "localization_constraints.json": ("MarketScannerOfflineLocalizationConstraints", 1),
            "localization_report.json": ("MarketScannerLocalizationReport", 1),
            "review_items.json": ("MarketScannerLocalizationReviewItems", 1),
            "localized_review.json": ("MarketScannerLocalizedReview", 1),
            "manual_edits.json": ("MarketScannerManualEdits", 3),
            "shelf_tag_index.json": ("MarketScannerShelfTagIndex", 1),
        }
        for name, (expected_format, expected_version) in expected_contracts.items():
            payload = parsed[name]
            if (
                not isinstance(payload, dict)
                or payload.get("format") != expected_format
                or payload.get("version") != expected_version
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
        report = parsed["localization_report.json"]
        processing = parsed["processing_manifest.json"]
        journal = parsed["manual_edits.json"]
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
        pointer_name: str | None = None,
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
            os.replace(staging, version_dir)
            # The immutable directory must be durable before any pointer can
            # reference it. Failure leaves an unreferenced version for audit
            # while the previous pointer remains unchanged.
            _fsync_directory(self.versions)
            manifest_sha256 = _sha256(version_dir / "version_manifest.json")
            snapshot = LocalizedSnapshot(
                version_id=version_id,
                version_dir=version_dir,
                revision=int(manifest["revision"]),
                state=str(manifest["state"]),
                manifest_sha256=manifest_sha256,
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
                "version": 1,
                "version_id": snapshot.version_id,
                "revision": snapshot.revision,
                "state": snapshot.state,
                "manifest_sha256": snapshot.manifest_sha256,
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
        field_acceptance: dict[str, Any],
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
            report = json.loads(
                self.read_verified_artifact(
                    current.version_id, "localization_report.json"
                ).decode("utf-8"),
                parse_constant=_reject_nonfinite,
            )
            if not isinstance(field_acceptance, dict):
                raise LocalizedStoreError("Field acceptance record is invalid.")
            expected_evidence = _sha256(
                current.version_dir / "localized_review.json"
            )
            if field_acceptance.get("evidence_sha256") != expected_evidence:
                raise LocalizedStoreError(
                    "Field acceptance evidence does not match localized_review.json."
                )
            self._validate_publication_gate(report, field_acceptance)
            return self._commit_transition(
                staging, current, "published", actor=actor, reason=reason,
                pointer_name="published.json",
                field_acceptance=field_acceptance,
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
    ) -> LocalizedSnapshot:
        if self._lock_handle is None:
            raise LocalizedStoreError("Localized transition requires the write lock.")
        try:
            for name in REQUIRED_VERSION_FILES:
                shutil.copy2(source.version_dir / name, staging / name)
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
            and isinstance(field_acceptance.get("evidence_sha256"), str)
            and re.fullmatch(
                r"[0-9a-f]{64}", field_acceptance.get("evidence_sha256", "")
            )
            is not None
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
            report = json.loads(
                (snapshot.version_dir / "localization_report.json").read_text(
                    encoding="utf-8"
                ),
                parse_constant=_reject_nonfinite,
            )
        except (OSError, ValueError, json.JSONDecodeError) as exc:
            raise LocalizedStoreError("Published localization report is invalid.") from exc
        acceptance = report.get("field_acceptance") if isinstance(report, dict) else None
        if not isinstance(report, dict) or not isinstance(acceptance, dict):
            raise LocalizedStoreError("Published output has no field acceptance record.")
        if acceptance.get("evidence_sha256") != _sha256(
            snapshot.version_dir / "localized_review.json"
        ):
            raise LocalizedStoreError(
                "Published field acceptance evidence no longer matches the review artifact."
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
        if pointer.get("format") != "MarketScannerLocalizedPointer" or pointer.get("version") != 1:
            raise LocalizedStoreError(f"Localized pointer contract is invalid: {name}")
        if re.fullmatch(r"v[0-9]{6}", version_id) is None:
            raise LocalizedStoreError(f"Localized pointer version is unsafe: {version_id}")
        snapshot = self.resolve_version(version_id)
        if snapshot.manifest_sha256 != expected_manifest:
            raise LocalizedStoreError(f"Localized pointer manifest mismatch: {name}")
        if snapshot.revision != revision or snapshot.state != state:
            raise LocalizedStoreError(f"Localized pointer metadata mismatch: {name}")
        if name == "published.json" and snapshot.state == "published":
            self._validate_publishable_snapshot(snapshot)
        return snapshot

    def read_verified_artifact(self, version_id: str, name: str) -> bytes:
        """Read one immutable artifact and verify the bytes from the open fd."""
        if name not in REQUIRED_VERSION_FILES:
            raise LocalizedStoreError(f"Localized artifact name is invalid: {name}")
        snapshot = self.resolve_version(version_id)
        flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
        try:
            manifest_fd = os.open(snapshot.version_dir / "version_manifest.json", flags)
            with os.fdopen(manifest_fd, "rb") as handle:
                manifest_bytes = handle.read()
            if hashlib.sha256(manifest_bytes).hexdigest() != snapshot.manifest_sha256:
                raise LocalizedStoreError("Localized version manifest changed during read.")
            manifest = json.loads(
                manifest_bytes.decode("utf-8"), parse_constant=_reject_nonfinite
            )
            entry = next(
                item for item in manifest["files"] if item.get("file") == name
            )
            artifact_fd = os.open(snapshot.version_dir / name, flags)
            with os.fdopen(artifact_fd, "rb") as handle:
                artifact_stat = os.fstat(handle.fileno())
                content = handle.read()
            expected_bytes = int(entry["bytes"])
        except LocalizedStoreError:
            raise
        except (
            OSError,
            UnicodeDecodeError,
            json.JSONDecodeError,
            KeyError,
            StopIteration,
            TypeError,
            ValueError,
        ) as exc:
            raise LocalizedStoreError(
                f"Localized artifact could not be read safely: {name}"
            ) from exc
        if (
            not stat.S_ISREG(artifact_stat.st_mode)
            or isinstance(entry.get("bytes"), bool)
            or len(content) != expected_bytes
            or hashlib.sha256(content).hexdigest() != entry.get("sha256")
        ):
            raise LocalizedStoreError(
                f"Localized artifact changed during verified read: {name}"
            )
        return content

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
            or state not in VERSION_STATES
            or revision < 1
        ):
            raise LocalizedStoreError(
                f"Localized version manifest contract is invalid: {version_id}"
            )
        entries = manifest.get("files")
        if not isinstance(entries, list) or len(entries) != len(REQUIRED_VERSION_FILES):
            raise LocalizedStoreError(f"Localized version file manifest is invalid: {version_id}")
        by_name: dict[str, dict[str, Any]] = {}
        for entry in entries:
            if not isinstance(entry, dict) or not isinstance(entry.get("file"), str):
                raise LocalizedStoreError(f"Localized version file manifest is invalid: {version_id}")
            name = entry["file"]
            if name in by_name:
                raise LocalizedStoreError(f"Localized version file manifest has duplicates: {version_id}")
            by_name[name] = entry
        if set(by_name) != set(REQUIRED_VERSION_FILES):
            raise LocalizedStoreError(f"Localized version file set is invalid: {version_id}")
        actual_names = {path.name for path in version_dir.iterdir()}
        if actual_names != set(REQUIRED_VERSION_FILES) | {"version_manifest.json"}:
            raise LocalizedStoreError(f"Localized version directory contents changed: {version_id}")
        for name in REQUIRED_VERSION_FILES:
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
        )

    def current(self) -> LocalizedSnapshot | None:
        return self.resolve_pointer("current.json")

    def published(self) -> LocalizedSnapshot | None:
        return self.resolve_pointer("published.json")


def immutable_version_artifacts(snapshot: LocalizedSnapshot) -> Iterable[Path]:
    return snapshot.version_dir.iterdir()
