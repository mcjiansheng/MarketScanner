#!/usr/bin/env python3
"""Fail-closed evidence collector for MarketScanner device and field trials."""

from __future__ import annotations

import argparse
import base64
import csv
from dataclasses import dataclass
from datetime import datetime, timezone
import hashlib
import io
import json
import math
import os
from pathlib import Path
import re
import stat
import statistics
import sys
from typing import Any, Iterable


FORMAT_DEVICE_PLAN = "MarketScannerDeviceQualificationPlan"
FORMAT_DEVICE_EVIDENCE = "MarketScannerDeviceQualificationEvidence"
FORMAT_FIELD_PLAN = "MarketScannerFieldQualificationPlan"
FORMAT_FIELD_EVIDENCE = "MarketScannerFieldQualificationEvidence"
FORMAT_TRAJECTORY_EVIDENCE = "MarketScannerTrajectoryQualificationEvidence"
FORMAT_TRAJECTORY_SOURCE_BUNDLE = "MarketScannerTrajectorySourceBundle"
FORMAT_FIELD_RUN_INPUT_BUNDLE = "MarketScannerFieldRunInputBundle"
FORMAT_RELEASE_MANIFEST = "MarketScannerReleaseManifest"
FORMAT_QUALITY_POLICY = "MarketScannerFactorGraphQualityPolicy"
SHA_RE = re.compile(r"^[0-9a-f]{64}$")
GIT_SHA_RE = re.compile(r"^[0-9a-f]{40}$")
REQUIRED_DEVICE_SCENARIOS = {
    "normal_long_scan",
    "weak_texture",
    "dynamic_occlusion",
    "tag_scan",
    "manual_correction",
    "stop_finalization",
    "provider_copy",
    "kill_relaunch",
    "provider_failure",
    "low_disk",
    "thermal_serious",
    "checkpoint_cleanup",
}
DEVICE_SCENARIO_ASSERTIONS = {
    "normal_long_scan": {"raw_database_retained", "continuous_database_observed"},
    "weak_texture": {"weak_lost_audited", "no_hard_snap_during_weak_lost"},
    "dynamic_occlusion": {"dynamic_interference_audited", "no_false_auto_confirm"},
    "tag_scan": {"three_tag_scans_completed", "endpoint_tag_sent_to_review"},
    "manual_correction": {"manual_correction_bound_to_node_time"},
    "stop_finalization": {"no_writes_after_metadata_commit", "required_evidence_fail_closed"},
    "provider_copy": {"local_copy_retained", "provider_copy_reread_completed"},
    "kill_relaunch": {"kill_relaunch_state_audited", "raw_database_survived_kill"},
    "provider_failure": {"provider_failure_visible", "local_copy_survived_provider_failure"},
    "low_disk": {"low_disk_policy_visible", "low_disk_state_audited"},
    "thermal_serious": {"thermal_serious_observed", "thermal_policy_visible"},
    "checkpoint_cleanup": {"cleanup_exact_cas_confirmed", "cleanup_audit_persisted"},
}
REQUIRED_SIDECARS = {
    "localization_trace.jsonl",
    "localization_constraints.jsonl",
    "localization_events.jsonl",
    "localized_price_tags.json",
    "metadata.json",
}
TRAJECTORY_SOURCE_FILES = (
    "source_manifest.json",
    "processing_manifest.json",
    "localization_report.json",
    "factor_graph_report.json",
    "localized_price_tags.json",
)


class QualificationError(ValueError):
    pass


@dataclass(frozen=True)
class _TrajectoryVersionIdentity:
    version_id: str
    manifest_sha256: str
    input_identity_id: str
    session_input_bundle_sha256: str


def _read_stable_bytes(
    path: Path,
    *,
    maximum_bytes: int,
    label: str,
) -> tuple[bytes, str, int, tuple[int, int]]:
    """Read the exact bytes later parsed/hashed from one verified descriptor."""

    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as exc:
        raise QualificationError(
            f"unsafe_or_oversized_{label}:{path.name}"
        ) from exc
    try:
        try:
            opened = os.fstat(descriptor)
            before = path.lstat()
            binding_before_descriptor = os.open(path, flags)
            try:
                binding_before = os.fstat(binding_before_descriptor)
            finally:
                os.close(binding_before_descriptor)
            if (
                not stat.S_ISREG(before.st_mode)
                or not stat.S_ISREG(opened.st_mode)
                or not stat.S_ISREG(binding_before.st_mode)
                or before.st_nlink != 1
                or opened.st_nlink != 1
                or binding_before.st_nlink != 1
                or before.st_size > maximum_bytes
                or opened.st_size > maximum_bytes
            ):
                raise QualificationError(
                    f"unsafe_or_oversized_{label}:{path.name}"
                )
            chunks: list[bytes] = []
            total = 0
            while True:
                chunk = os.read(
                    descriptor, min(1024 * 1024, maximum_bytes + 1 - total)
                )
                if not chunk:
                    break
                chunks.append(chunk)
                total += len(chunk)
                if total > maximum_bytes:
                    raise QualificationError(f"{label}_size_limit:{path.name}")
            opened_after = os.fstat(descriptor)
            after = path.lstat()
            binding_after_descriptor = os.open(path, flags)
            try:
                binding_after = os.fstat(binding_after_descriptor)
            finally:
                os.close(binding_after_descriptor)
        except QualificationError:
            raise
        except OSError as exc:
            raise QualificationError(
                f"{label}_changed_during_read:{path.name}"
            ) from exc
    finally:
        os.close(descriptor)

    # On Windows, path-based stat and handle-based fstat may expose different
    # device/inode or timestamp representations for the same unchanged file.
    # Compare each API surface with itself. Separate path descriptors bind the
    # named file to the still-open read descriptor before and after the read;
    # this also rejects a same-size swap that restores the original path.
    path_identity = (
        before.st_dev,
        before.st_ino,
        before.st_size,
        before.st_nlink,
        before.st_mtime_ns,
        before.st_ctime_ns,
    )
    descriptor_identity = (
        opened.st_dev,
        opened.st_ino,
        opened.st_size,
        opened.st_nlink,
        opened.st_mtime_ns,
        opened.st_ctime_ns,
    )
    binding_before_identity = (
        binding_before.st_dev,
        binding_before.st_ino,
        binding_before.st_size,
        binding_before.st_nlink,
        binding_before.st_mtime_ns,
        binding_before.st_ctime_ns,
    )
    if (
        not stat.S_ISREG(opened.st_mode)
        or not stat.S_ISREG(opened_after.st_mode)
        or not stat.S_ISREG(after.st_mode)
        or not stat.S_ISREG(binding_after.st_mode)
        or opened.st_nlink != 1
        or opened_after.st_nlink != 1
        or after.st_nlink != 1
        or binding_after.st_nlink != 1
        or path_identity
        != (
            after.st_dev,
            after.st_ino,
            after.st_size,
            after.st_nlink,
            after.st_mtime_ns,
            after.st_ctime_ns,
        )
        or descriptor_identity != binding_before_identity
        or descriptor_identity
        != (
            opened_after.st_dev,
            opened_after.st_ino,
            opened_after.st_size,
            opened_after.st_nlink,
            opened_after.st_mtime_ns,
            opened_after.st_ctime_ns,
        )
        or descriptor_identity
        != (
            binding_after.st_dev,
            binding_after.st_ino,
            binding_after.st_size,
            binding_after.st_nlink,
            binding_after.st_mtime_ns,
            binding_after.st_ctime_ns,
        )
    ):
        raise QualificationError(f"{label}_changed_during_read:{path.name}")
    data = b"".join(chunks)
    if len(data) != before.st_size or len(data) != opened.st_size:
        raise QualificationError(f"{label}_partial_read:{path.name}")
    return data, hashlib.sha256(data).hexdigest(), len(data), (
        int(before.st_dev),
        int(before.st_ino),
    )


def _load_json_with_identity(
    path: Path, maximum_bytes: int = 16 * 1024 * 1024
) -> tuple[Any, str, int]:
    value, digest, size, _data = _load_json_with_identity_bytes(
        path, maximum_bytes
    )
    return value, digest, size


def _load_json_with_identity_bytes(
    path: Path, maximum_bytes: int = 16 * 1024 * 1024
) -> tuple[Any, str, int, bytes]:
    data, digest, size, _ = _read_stable_bytes(
        path, maximum_bytes=maximum_bytes, label="json"
    )
    try:
        return (
            json.loads(
                data.decode("utf-8", errors="strict"),
                parse_constant=lambda token: (_ for _ in ()).throw(ValueError(token)),
            ),
            digest,
            size,
            data,
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise QualificationError(f"invalid_json:{path.name}") from exc
    except ValueError as exc:
        raise QualificationError(f"nonfinite_json:{path.name}") from exc


def _load_json(path: Path, maximum_bytes: int = 16 * 1024 * 1024) -> Any:
    return _load_json_with_identity(path, maximum_bytes)[0]


def _sha256(path: Path) -> tuple[str, int]:
    _data, digest, size, _identity = _read_stable_bytes(
        path, maximum_bytes=2 * 1024 * 1024 * 1024, label="artifact"
    )
    return digest, size


def _tree_manifest(root: Path) -> list[dict[str, Any]]:
    if root.is_symlink():
        raise QualificationError("artifact_root_is_symlink")
    root = root.resolve(strict=True)
    if not root.is_dir():
        raise QualificationError("artifact_root_not_directory")
    values: list[dict[str, Any]] = []
    for path in sorted(root.rglob("*")):
        if path.is_symlink():
            raise QualificationError(f"symlink_in_artifact_tree:{path.name}")
        if path.is_dir():
            continue
        relative = path.relative_to(root).as_posix()
        digest, size = _sha256(path)
        values.append({"relativePath": relative, "bytes": size, "sha256": digest})
    return values


def _canonical_sha(value: Any) -> str:
    data = json.dumps(
        value,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    return hashlib.sha256(data).hexdigest()


def _validated_canonical_evidence(
    path: Path,
    *,
    expected_format: str,
    expected_version: int,
) -> tuple[dict[str, Any], str, int]:
    value, digest, size, _data = _validated_canonical_evidence_bytes(
        path,
        expected_format=expected_format,
        expected_version=expected_version,
    )
    return value, digest, size


def _validated_canonical_evidence_bytes(
    path: Path,
    *,
    expected_format: str,
    expected_version: int,
    maximum_bytes: int = 16 * 1024 * 1024,
) -> tuple[dict[str, Any], str, int, bytes]:
    data, digest, size, _identity = _read_stable_bytes(
        path, maximum_bytes=maximum_bytes, label="evidence"
    )
    value = _validated_canonical_evidence_data(
        data,
        expected_format=expected_format,
        expected_version=expected_version,
    )
    return value, digest, size, data


def _validated_canonical_evidence_data(
    data: bytes,
    *,
    expected_format: str,
    expected_version: int,
) -> dict[str, Any]:
    try:
        value = json.loads(
            data.decode("utf-8", errors="strict"),
            parse_constant=lambda token: (_ for _ in ()).throw(ValueError(token)),
        )
    except (UnicodeDecodeError, json.JSONDecodeError, ValueError) as exc:
        raise QualificationError("evidence_json_invalid") from exc
    if not isinstance(value, dict):
        raise QualificationError("evidence_not_object")
    body = dict(value)
    declared = body.pop("evidenceSha256", None)
    if (
        value.get("format") != expected_format
        or value.get("version") != expected_version
        or not SHA_RE.fullmatch(str(declared or ""))
        or _canonical_sha(body) != declared
    ):
        raise QualificationError("evidence_contract_invalid")
    return value


def _validate_release_manifest(
    path: Path,
) -> tuple[dict[str, Any], str, int, bytes]:
    value, digest, size, data = _load_json_with_identity_bytes(path)
    _validate_release_manifest_value(value)
    return value, digest, size, data


def _validate_release_manifest_value(value: Any) -> None:
    if not isinstance(value, dict):
        raise QualificationError("release_manifest_not_object")
    body = dict(value)
    declared = body.pop("manifest_body_sha256", None)
    if (
        value.get("format") != FORMAT_RELEASE_MANIFEST
        or value.get("version") != 2
        or not GIT_SHA_RE.fullmatch(str(value.get("git_sha", "")))
        or not SHA_RE.fullmatch(str(value.get("factor_graph_quality_policy_sha256", "")))
        or not SHA_RE.fullmatch(str(declared or ""))
        or _canonical_sha(body) != declared
    ):
        raise QualificationError("release_manifest_contract_invalid")


def _validate_quality_policy(
    path: Path,
) -> tuple[dict[str, Any], str, int, bytes]:
    value, digest, size, data = _load_json_with_identity_bytes(
        path, maximum_bytes=1024 * 1024
    )
    _validate_quality_policy_value(value)
    return value, digest, size, data


def _validate_quality_policy_value(value: Any) -> None:
    if (
        not isinstance(value, dict)
        or value.get("format") != FORMAT_QUALITY_POLICY
        or value.get("version") != 1
        or value.get("status") != "frozen"
        or not isinstance(value.get("policy_version"), str)
        or not value["policy_version"].strip()
    ):
        raise QualificationError("quality_policy_not_frozen_or_invalid")


def _required_string(value: Any, label: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise QualificationError(f"missing_{label}")
    return value


def _finite_number(value: Any, label: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise QualificationError(f"invalid_{label}")
    result = float(value)
    if not math.isfinite(result):
        raise QualificationError(f"nonfinite_{label}")
    return result


def _csv_number(value: Any, label: str) -> float:
    try:
        result = float(value)
    except (TypeError, ValueError) as exc:
        raise QualificationError(f"invalid_{label}") from exc
    if not math.isfinite(result):
        raise QualificationError(f"nonfinite_{label}")
    return result


def _percentile(values: list[float], percentile: float) -> float:
    if not values:
        raise QualificationError("empty_measurements")
    ordered = sorted(values)
    index = (len(ordered) - 1) * percentile
    low = math.floor(index)
    high = math.ceil(index)
    if low == high:
        return ordered[low]
    return ordered[low] * (high - index) + ordered[high] * (index - low)


def _session_checks(segment: Path, expected: str) -> tuple[list[str], dict[str, Any]]:
    blockers: list[str] = []
    if not segment.is_dir() or segment.name != "segment_0001":
        return ["invalid_segment_directory"], {}
    metadata_path = segment / "metadata.json"
    try:
        metadata = _load_json(metadata_path)
    except (OSError, QualificationError) as exc:
        return [str(exc)], {}
    if not isinstance(metadata, dict):
        return ["metadata_not_object"], {}
    database = segment / "rtabmap_segment_0001.db"
    if not database.is_file() or database.is_symlink() or database.stat().st_size <= 0:
        blockers.append("raw_database_missing_or_empty")
    if metadata.get("scanMode") != "continuous_streaming":
        blockers.append("scan_mode_not_continuous_streaming")
    health = metadata.get("captureHealth")
    eligibility = metadata.get("processingEligibility")
    if expected == "finalized_eligible":
        missing = sorted(name for name in REQUIRED_SIDECARS if not (segment / name).is_file())
        if missing:
            blockers.append("required_sidecars_missing:" + ",".join(missing))
        if metadata.get("finalized") is not True:
            blockers.append("metadata_not_finalized")
        if (segment / "live_checkpoint.json").exists():
            blockers.append("live_checkpoint_present")
        if not isinstance(health, dict):
            blockers.append("capture_health_missing")
        else:
            if health.get("localizationEvidenceComplete") is not True:
                blockers.append("localization_evidence_incomplete")
            if health.get("localizationRequiredWriteFailureCount") != 0:
                blockers.append("required_sidecar_write_failure")
        if not isinstance(eligibility, dict) or eligibility.get("blockers") != []:
            blockers.append("processing_eligibility_blocked")
    elif expected == "interrupted_or_ineligible":
        safely_blocked = (
            metadata.get("finalized") is not True
            or (segment / "live_checkpoint.json").exists()
            or (isinstance(eligibility, dict) and bool(eligibility.get("blockers")))
        )
        if not safely_blocked:
            blockers.append("abnormal_run_not_fail_closed")
    else:
        blockers.append("unknown_expected_session_outcome")
    identity = {
        "trackingSessionId": metadata.get("trackingSessionId"),
        "priorMapId": metadata.get("priorMapId"),
        "priorMapSha256": metadata.get("priorMapSha256"),
        "finalized": metadata.get("finalized"),
    }
    if not isinstance(identity["trackingSessionId"], str) or not identity["trackingSessionId"]:
        blockers.append("tracking_session_identity_missing")
    return blockers, identity


def _copy_checks(copy_root: Path, session_id: str) -> tuple[list[str], dict[str, Any]]:
    blockers: list[str] = []
    try:
        receipt = _load_json(copy_root / "copy_verification.json")
        package = _load_json(copy_root / "copy_package_manifest.json")
    except (OSError, QualificationError) as exc:
        return [str(exc)], {}
    if not isinstance(receipt, dict) or not isinstance(package, dict):
        return ["copy_receipt_or_manifest_not_object"], {}
    if receipt.get("format") != "MarketScannerExternalCopyVerification" or receipt.get("version") != 2:
        blockers.append("copy_receipt_contract_invalid")
    if package.get("format") != "MarketScannerExternalCopyPackageManifest" or package.get("version") != 1:
        blockers.append("copy_package_contract_invalid")
    if receipt.get("sessionId") != session_id or package.get("sessionId") != session_id:
        blockers.append("copy_session_identity_mismatch")
    if receipt.get("localCopyRetained") is not True or package.get("localCopyRetained") is not True:
        blockers.append("local_copy_not_retained")
    forbidden = {"sourceDirectory", "destinationDirectory"}
    if forbidden.intersection(receipt):
        blockers.append("absolute_path_field_in_receipt")
    files = package.get("files")
    receipt_files = receipt.get("files")
    if (
        not isinstance(receipt_files, list)
        or not receipt_files
        or _canonical_sha(receipt_files) != receipt.get("packageContentSha256")
    ):
        blockers.append("copy_receipt_manifest_invalid")
    if (
        not isinstance(files, list)
        or not files
        or not SHA_RE.fullmatch(str(package.get("packageContentSha256", "")))
    ):
        blockers.append("copy_package_manifest_invalid")
    elif _canonical_sha(files) != package["packageContentSha256"]:
        blockers.append("copy_package_digest_mismatch")
    try:
        actual_files = [
            {
                "relativePath": value["relativePath"],
                "byteCount": value["bytes"],
                "sha256": value["sha256"],
            }
            for value in _tree_manifest(copy_root)
            if value["relativePath"] not in {
                "copy_package_manifest.json",
                "copy_durability_qualification.json",
            }
        ]
        segment_directories = [
            path for path in copy_root.iterdir()
            if path.is_dir() and path.name == "segment_0001"
        ]
        actual_capture_files = [] if len(segment_directories) != 1 else [
            {
                "relativePath": value["relativePath"],
                "byteCount": value["bytes"],
                "sha256": value["sha256"],
            }
            for value in _tree_manifest(segment_directories[0])
        ]
        if actual_files != files:
            blockers.append("copy_package_files_changed")
        if actual_capture_files != receipt_files:
            blockers.append("copy_receipt_files_changed")
    except (OSError, QualificationError) as exc:
        blockers.append(str(exc))
    if receipt.get("packageId") != package.get("packageId"):
        blockers.append("copy_package_id_mismatch")
    return blockers, {
        "packageId": package.get("packageId"),
        "packageContentSha256": package.get("packageContentSha256"),
        "durabilityQualificationStatus": package.get("durabilityQualificationStatus"),
    }


def collect_device(plan_path: Path, output_path: Path) -> dict[str, Any]:
    plan = _load_json(plan_path)
    if not isinstance(plan, dict) or plan.get("format") != FORMAT_DEVICE_PLAN or plan.get("version") != 1:
        raise QualificationError("device_plan_contract_invalid")
    if plan.get("executionStatus") != "executed_on_real_device":
        raise QualificationError("real_device_execution_not_attested")
    app = plan.get("app")
    device = plan.get("device")
    runs = plan.get("runs")
    if not isinstance(app, dict) or not GIT_SHA_RE.fullmatch(str(app.get("gitSha", ""))):
        raise QualificationError("app_git_sha_invalid")
    if not isinstance(device, dict) or device.get("lidarAvailable") is not True:
        raise QualificationError("lidar_device_identity_invalid")
    for key in ("model", "iosBuild"):
        _required_string(device.get(key), f"device_{key}")
    _required_string(app.get("buildId"), "app_build_id")
    library_paths = app.get("nativeStaticLibraries")
    if not isinstance(library_paths, list) or not library_paths:
        raise QualificationError("native_static_libraries_missing")
    library_evidence = []
    for raw_path in library_paths:
        library_path = Path(str(raw_path))
        digest, size = _sha256(library_path)
        library_evidence.append({
            "name": library_path.name,
            "bytes": size,
            "sha256": digest,
        })
    if not isinstance(runs, list) or not runs:
        raise QualificationError("device_runs_missing")
    all_scenarios: set[str] = set()
    evidence_runs: list[dict[str, Any]] = []
    overall_blockers: list[str] = []
    seen_run_ids: set[str] = set()
    for index, run in enumerate(runs):
        label = f"run_{index + 1}"
        blockers: list[str] = []
        if not isinstance(run, dict):
            overall_blockers.append(f"{label}:not_object")
            continue
        run_id = _required_string(run.get("runId"), f"{label}_id")
        if run_id in seen_run_ids:
            blockers.append("duplicate_run_id")
        seen_run_ids.add(run_id)
        _finite_number(run.get("executedAtUnix"), f"{label}_executed_at")
        environment = run.get("environment")
        if not isinstance(environment, dict):
            blockers.append("environment_missing")
            environment = {}
        for key in ("testAreaDimensions", "filesProvider", "initialThermalState"):
            if not isinstance(environment.get(key), str) or not environment[key].strip():
                blockers.append(f"environment_{key}_missing")
        try:
            if _finite_number(environment.get("initialAvailableStorageBytes"), "initial_storage") <= 0:
                blockers.append("initial_storage_not_positive")
            battery = _finite_number(environment.get("initialBatteryPercent"), "initial_battery")
            if not 0 <= battery <= 100:
                blockers.append("initial_battery_out_of_range")
        except QualificationError as exc:
            blockers.append(str(exc))
        covers = run.get("covers")
        if not isinstance(covers, list) or not covers or any(item not in REQUIRED_DEVICE_SCENARIOS for item in covers):
            blockers.append("scenario_coverage_invalid")
            covers = []
        all_scenarios.update(covers)
        assertions = run.get("operatorAssertions")
        if not isinstance(assertions, dict):
            assertions = {}
        required_assertions = set().union(
            *(DEVICE_SCENARIO_ASSERTIONS[scenario] for scenario in covers)
        ) if covers else set()
        failed_assertions = sorted(
            key for key in required_assertions if assertions.get(key) is not True
        )
        if failed_assertions:
            blockers.append(
                "operator_assertion_missing_or_failed:"
                + ",".join(failed_assertions)
            )
        segment = Path(_required_string(run.get("segmentDirectory"), f"{label}_segment"))
        session_blockers, identity = _session_checks(
            segment, str(run.get("expectedSessionOutcome", "")))
        blockers.extend(session_blockers)
        if run.get("priorMapId") != identity.get("priorMapId") or run.get("priorMapSha256") != identity.get("priorMapSha256"):
            blockers.append("prior_map_identity_mismatch")
        if not SHA_RE.fullmatch(str(run.get("priorMapSha256", ""))):
            blockers.append("prior_map_sha_invalid")
        prior_map_path = run.get("priorMapPackage")
        if not isinstance(prior_map_path, str) or not prior_map_path:
            blockers.append("prior_map_package_missing")
            prior_map_evidence = {}
        else:
            try:
                prior_sha, prior_size = _sha256(Path(prior_map_path))
                prior_map_evidence = {
                    "name": Path(prior_map_path).name,
                    "bytes": prior_size,
                    "sha256": prior_sha,
                }
                if prior_sha != run.get("priorMapSha256"):
                    blockers.append("prior_map_package_sha_mismatch")
            except (OSError, QualificationError) as exc:
                blockers.append(str(exc))
                prior_map_evidence = {}
        if "provider_copy" in covers:
            copy_path = run.get("externalCopyRoot")
            if not isinstance(copy_path, str) or not copy_path:
                blockers.append("external_copy_root_missing")
                copy_identity = {}
            else:
                copy_blockers, copy_identity = _copy_checks(
                    Path(copy_path), str(identity.get("trackingSessionId", "")))
                blockers.extend(copy_blockers)
        else:
            copy_identity = {}
        artifacts = []
        raw_evidence_files = run.get("evidenceFiles")
        if not isinstance(raw_evidence_files, list) or not raw_evidence_files:
            blockers.append("evidence_files_missing")
            raw_evidence_files = []
        for raw_path in raw_evidence_files:
            path = Path(str(raw_path))
            try:
                digest, size = _sha256(path)
                artifacts.append({"name": path.name, "bytes": size, "sha256": digest})
            except (OSError, QualificationError) as exc:
                blockers.append(str(exc))
        try:
            session_manifest = _tree_manifest(segment)
        except (OSError, QualificationError) as exc:
            blockers.append(str(exc))
            session_manifest = []
        raw_session_bundle_sha = _canonical_sha(session_manifest)
        raw_database_sha = ""
        try:
            raw_database_sha, _ = _sha256(
                segment / "rtabmap_segment_0001.db"
            )
        except (OSError, QualificationError) as exc:
            blockers.append(str(exc))
        evidence_runs.append({
            "runId": run_id,
            "covers": covers,
            "expectedSessionOutcome": run.get("expectedSessionOutcome"),
            "sessionDirectoryName": segment.name,
            "sessionIdentity": identity,
            "trackingSessionId": identity.get("trackingSessionId"),
            "rawSessionBundleSha256": raw_session_bundle_sha,
            "rawDatabaseSha256": raw_database_sha,
            "environment": environment,
            "priorMapPackage": prior_map_evidence,
            "sessionFiles": session_manifest,
            "sessionManifestSha256": raw_session_bundle_sha,
            "copyIdentity": copy_identity,
            "evidenceFiles": artifacts,
            "blockers": blockers,
            "result": "PASS" if not blockers else "FAIL",
        })
        overall_blockers.extend(f"{run_id}:{item}" for item in blockers)
    missing_scenarios = sorted(REQUIRED_DEVICE_SCENARIOS - all_scenarios)
    if missing_scenarios:
        overall_blockers.append("missing_scenarios:" + ",".join(missing_scenarios))
    evidence: dict[str, Any] = {
        "format": FORMAT_DEVICE_EVIDENCE,
        "version": 2,
        "sourcePlanSha256": _sha256(plan_path)[0],
        "device": device,
        "app": {
            "gitSha": app["gitSha"],
            "buildId": app["buildId"],
            "nativeStaticLibraries": library_evidence,
        },
        "operator": _required_string(plan.get("operator"), "operator"),
        "runs": evidence_runs,
        "blockers": overall_blockers,
        "result": "PASS" if not overall_blockers else "FAIL",
    }
    evidence["evidenceSha256"] = _canonical_sha(evidence)
    _write_json(output_path, evidence)
    return evidence


def _trajectory_json(artifacts: dict[str, bytes], name: str) -> Any:
    try:
        return json.loads(
            artifacts[name].decode("utf-8", errors="strict"),
            parse_constant=lambda token: (_ for _ in ()).throw(ValueError(token)),
        )
    except (KeyError, UnicodeDecodeError, json.JSONDecodeError, ValueError) as exc:
        raise QualificationError(f"localized_artifact_invalid:{name}") from exc


def _derive_trajectory_evidence(
    identity: _TrajectoryVersionIdentity,
    artifacts: dict[str, bytes],
    optimized_trajectory_sha256: str,
    *,
    release: dict[str, Any],
    release_sha256: str,
    generated_at_utc: str,
) -> dict[str, Any]:
    """Derive the typed evidence solely from manifest-bound artifact bytes."""

    source = _trajectory_json(artifacts, "source_manifest.json")
    processing = _trajectory_json(artifacts, "processing_manifest.json")
    report = _trajectory_json(artifacts, "localization_report.json")
    factor = _trajectory_json(artifacts, "factor_graph_report.json")
    tags = _trajectory_json(artifacts, "localized_price_tags.json")
    if any(not isinstance(value, dict) for value in (source, processing, report, factor)):
        raise QualificationError("localized_artifact_not_object")
    if not isinstance(tags, list) or not tags or any(not isinstance(tag, dict) for tag in tags):
        raise QualificationError("localized_tags_missing_or_invalid")
    if not SHA_RE.fullmatch(optimized_trajectory_sha256):
        raise QualificationError("optimized_trajectory_identity_invalid")

    quality = factor.get("quality_policy")
    if (
        source.get("input_identity_id") != identity.input_identity_id
        or source.get("session_input_bundle_sha256")
        != identity.session_input_bundle_sha256
        or processing.get("input_identity_id") != identity.input_identity_id
        or report.get("input_identity_id") != identity.input_identity_id
        or factor.get("input_identity_id") != identity.input_identity_id
        or not isinstance(quality, dict)
        or quality.get("policy_sha256")
        != release.get("factor_graph_quality_policy_sha256")
    ):
        raise QualificationError("trajectory_evidence_identity_mismatch")

    tag_ids: list[str] = []
    tracking_ids: set[str] = set()
    observed_complete = True
    user_confirmed_preserved = True
    automatic_confirm_during_weak_lost = 0
    weak_lost_intervals = report.get("weak_lost_intervals")
    if not isinstance(weak_lost_intervals, list):
        raise QualificationError("weak_lost_intervals_invalid")
    association_rows: list[dict[str, Any]] = []
    for tag in tags:
        tag_id = tag.get("tag_id")
        tracking_id = tag.get("tracking_session_id")
        if not isinstance(tag_id, str) or not tag_id or tag_id in tag_ids:
            raise QualificationError("localized_tag_id_invalid")
        if not isinstance(tracking_id, str) or not tracking_id:
            raise QualificationError("tracking_session_id_invalid")
        tag_ids.append(tag_id)
        tracking_ids.add(tracking_id)
        transform = tag.get("transform_audit")
        if not isinstance(transform, dict) or transform.get("status") != "applied":
            observed_complete = False
        if tag.get("user_confirmed") is True and (
            tag.get("approval_status") != "approved"
            or tag.get("needs_review") is True
        ):
            user_confirmed_preserved = False
        association = tag.get("association_audit")
        if isinstance(association, dict) and association.get("status") == "auto_confirmed":
            timestamp = _finite_number(tag.get("timestamp"), "tag_timestamp")
            if any(
                isinstance(interval, dict)
                and _finite_number(interval.get("start_timestamp"), "weak_start")
                <= timestamp
                <= _finite_number(interval.get("end_timestamp"), "weak_end")
                for interval in weak_lost_intervals
            ):
                automatic_confirm_during_weak_lost += 1
        association_rows.append(
            {
                "tag_id": tag_id,
                "shelf_code": tag.get("shelf_code"),
                "shelf_side": tag.get("shelf_side"),
                "distance_from_shelf_start_cm": tag.get(
                    "distance_from_shelf_start_cm"
                ),
                "approval_status": tag.get("approval_status"),
            }
        )
    if len(tracking_ids) != 1:
        raise QualificationError("multiple_tracking_sessions_in_version")

    inventory = report.get("node_inventory_audit")
    if not isinstance(inventory, dict):
        raise QualificationError("node_inventory_audit_invalid")
    mismatch_fields = (
        "source_missing_from_optimized",
        "source_missing_from_export",
        "optimized_not_in_source",
        "exported_not_in_optimized",
        "source_duplicate_ids",
        "optimized_duplicate_ids",
        "exported_duplicate_ids",
        "source_non_monotonic_stamp_node_ids",
        "optimized_non_monotonic_stamp_node_ids",
    )
    inventories_match = (
        all(inventory.get(name) == [] for name in mismatch_fields)
        and inventory.get("source_count") == inventory.get("optimized_count")
        and inventory.get("source_count") == inventory.get("exported_count")
    )
    durations = report.get("localization_state_duration_seconds")
    if not isinstance(durations, dict):
        raise QualificationError("localization_state_durations_invalid")
    correction_distribution = report.get("correction_distribution_m")
    if not isinstance(correction_distribution, dict):
        raise QualificationError("correction_distribution_invalid")
    total_duration = sum(
        _finite_number(value, f"duration_{name}") for name, value in durations.items()
    )
    weak_lost_duration = _finite_number(
        report.get("weak_lost_duration_seconds"), "weak_lost_duration"
    )
    weak_lost_ratio = weak_lost_duration / total_duration if total_duration > 0.0 else 0.0
    topology_digest = _canonical_sha(
        {
            "nodeInventoryAudit": inventory,
            "aisleSwitchSequence": report.get("aisle_switch_sequence"),
            "optimizedTrajectorySha256": optimized_trajectory_sha256,
        }
    )
    shelf_digest = _canonical_sha(sorted(association_rows, key=lambda item: item["tag_id"]))
    evidence: dict[str, Any] = {
        "format": FORMAT_TRAJECTORY_EVIDENCE,
        "version": 1,
        "generated_at_utc": _required_string(
            generated_at_utc, "trajectory_generated_at_utc"
        ),
        "release_git_sha": release["git_sha"],
        "release_manifest_sha256": release_sha256,
        "product_version": release["product_version"],
        "localized_version_id": identity.version_id,
        "localized_version_manifest_sha256": identity.manifest_sha256,
        "input_identity_id": identity.input_identity_id,
        "session_input_bundle_sha256": identity.session_input_bundle_sha256,
        "raw_database_sha256": source.get("source_database_sha256_before"),
        "tracking_session_id": next(iter(tracking_ids)),
        "prior_map_id": source.get("prior_map_id"),
        "prior_map_sha256": source.get("prior_map_sha256"),
        "quality_policy_sha256": quality.get("policy_sha256"),
        "quality_policy_version": quality.get("policy_version"),
        "nodeCoverage": _finite_number(report.get("node_coverage_ratio"), "nodeCoverage"),
        "correctionP95M": _finite_number(
            correction_distribution.get("p95"),
            "correctionP95M",
        ),
        "correctionMaxM": _finite_number(
            correction_distribution.get("maximum"),
            "correctionMaxM",
        ),
        "relativeTranslationResidualP95M": _finite_number(
            factor.get("p95_relative_edge_translation_residual_m"),
            "relativeTranslationResidualP95M",
        ),
        "relativeYawResidualP95Rad": math.radians(
            _finite_number(
                factor.get("p95_relative_edge_yaw_residual_deg"),
                "relativeYawResidualP95Deg",
            )
        ),
        "weakLostDurationRatio": weak_lost_ratio,
        "inventoriesMatch": inventories_match,
        "factorGraphConverged": (
            factor.get("converged") is True
            and factor.get("solver_converged") is True
        ),
        "factorGraphQualityPassed": factor.get("graph_quality_passed") is True,
        "singleConnectedComponent": factor.get("graph_connected") is True,
        "allGroundTruthTagsObserved": observed_complete,
        "userConfirmedTagsPreserved": user_confirmed_preserved,
        "automaticConfirmDuringWeakLost": automatic_confirm_during_weak_lost,
        "topologyDigest": topology_digest,
        "shelfAssociationDigest": shelf_digest,
        "localizedTagIds": sorted(tag_ids),
        "localizedTagIdsSha256": _canonical_sha(sorted(tag_ids)),
    }
    for name in (
        "input_identity_id",
        "session_input_bundle_sha256",
        "raw_database_sha256",
        "prior_map_sha256",
        "quality_policy_sha256",
        "localized_version_manifest_sha256",
    ):
        if not SHA_RE.fullmatch(str(evidence.get(name, ""))):
            raise QualificationError(f"trajectory_identity_invalid:{name}")
    for name in ("release_git_sha",):
        if not GIT_SHA_RE.fullmatch(str(evidence.get(name, ""))):
            raise QualificationError(f"trajectory_identity_invalid:{name}")
    for name in ("product_version", "tracking_session_id", "prior_map_id", "quality_policy_version"):
        _required_string(evidence.get(name), name)
    evidence["evidenceSha256"] = _canonical_sha(evidence)
    return evidence


def _trajectory_bundle_from_verified_bytes(
    manifest_bytes: bytes, artifacts: dict[str, bytes]
) -> dict[str, Any]:
    return {
        "format": FORMAT_TRAJECTORY_SOURCE_BUNDLE,
        "version": 1,
        "versionManifestBase64": base64.b64encode(manifest_bytes).decode("ascii"),
        "artifactsBase64": {
            name: base64.b64encode(artifacts[name]).decode("ascii")
            for name in TRAJECTORY_SOURCE_FILES
        },
    }


def _trajectory_source_from_bundle(
    bundle: Any,
    *,
    expected_manifest_sha256: str,
) -> tuple[_TrajectoryVersionIdentity, dict[str, bytes], str]:
    """Validate the self-contained source package used to derive trajectory metrics."""

    if (
        not isinstance(bundle, dict)
        or bundle.get("format") != FORMAT_TRAJECTORY_SOURCE_BUNDLE
        or bundle.get("version") != 1
        or set(bundle) != {
            "format",
            "version",
            "versionManifestBase64",
            "artifactsBase64",
        }
    ):
        raise QualificationError("trajectory_source_bundle_invalid")
    encoded_manifest = bundle.get("versionManifestBase64")
    encoded_artifacts = bundle.get("artifactsBase64")
    if not isinstance(encoded_manifest, str) or not isinstance(encoded_artifacts, dict):
        raise QualificationError("trajectory_source_bundle_invalid")
    if set(encoded_artifacts) != set(TRAJECTORY_SOURCE_FILES):
        raise QualificationError("trajectory_source_bundle_files_invalid")
    try:
        manifest_bytes = base64.b64decode(encoded_manifest, validate=True)
        artifacts = {
            name: base64.b64decode(encoded_artifacts[name], validate=True)
            for name in TRAJECTORY_SOURCE_FILES
            if isinstance(encoded_artifacts.get(name), str)
        }
    except (ValueError, TypeError) as exc:
        raise QualificationError("trajectory_source_bundle_base64_invalid") from exc
    if (
        len(artifacts) != len(TRAJECTORY_SOURCE_FILES)
        or len(manifest_bytes) > 4 * 1024 * 1024
        or sum(len(value) for value in artifacts.values()) > 12 * 1024 * 1024
        or hashlib.sha256(manifest_bytes).hexdigest() != expected_manifest_sha256
    ):
        raise QualificationError("trajectory_source_bundle_size_or_manifest_invalid")
    try:
        manifest = json.loads(
            manifest_bytes.decode("utf-8", errors="strict"),
            parse_constant=lambda token: (_ for _ in ()).throw(ValueError(token)),
        )
    except (UnicodeDecodeError, json.JSONDecodeError, ValueError) as exc:
        raise QualificationError("trajectory_source_manifest_invalid") from exc
    if (
        not isinstance(manifest, dict)
        or manifest.get("format") != "MarketScannerLocalizedVersionManifest"
        or manifest.get("version") not in {3, 4}
        or re.fullmatch(r"v[0-9]{6}", str(manifest.get("version_id", ""))) is None
        or not SHA_RE.fullmatch(str(manifest.get("input_identity_id", "")))
        or not SHA_RE.fullmatch(
            str(manifest.get("session_input_bundle_sha256", ""))
        )
        or not isinstance(manifest.get("files"), list)
    ):
        raise QualificationError("trajectory_source_manifest_contract_invalid")
    by_name: dict[str, dict[str, Any]] = {}
    for entry in manifest["files"]:
        if (
            not isinstance(entry, dict)
            or not isinstance(entry.get("file"), str)
            or entry["file"] in by_name
        ):
            raise QualificationError("trajectory_source_manifest_files_invalid")
        by_name[entry["file"]] = entry
    try:
        from tools.PriorMap.localized_output_store import (
            PUBLISHED_VERSION_FILES,
            REQUIRED_VERSION_FILES,
        )

        expected_files = (
            PUBLISHED_VERSION_FILES
            if manifest.get("version") == 4
            else REQUIRED_VERSION_FILES
        )
    except ImportError as exc:
        raise QualificationError("trajectory_source_manifest_contract_unavailable") from exc
    if set(by_name) != set(expected_files):
        raise QualificationError("trajectory_source_manifest_file_set_invalid")
    for name, entry in by_name.items():
        if (
            isinstance(entry.get("bytes"), bool)
            or not isinstance(entry.get("bytes"), int)
            or entry["bytes"] < 0
            or not SHA_RE.fullmatch(str(entry.get("sha256", "")))
        ):
            raise QualificationError(
                f"trajectory_source_manifest_entry_invalid:{name}"
            )
    for name, content in artifacts.items():
        entry = by_name.get(name)
        if (
            not isinstance(entry, dict)
            or isinstance(entry.get("bytes"), bool)
            or entry.get("bytes") != len(content)
            or entry.get("sha256") != hashlib.sha256(content).hexdigest()
        ):
            raise QualificationError(
                f"trajectory_source_artifact_identity_invalid:{name}"
            )
    optimized_entry = by_name.get("optimized_map_trajectory.geojson")
    if (
        not isinstance(optimized_entry, dict)
        or not SHA_RE.fullmatch(str(optimized_entry.get("sha256", "")))
        or isinstance(optimized_entry.get("bytes"), bool)
        or not isinstance(optimized_entry.get("bytes"), int)
        or optimized_entry["bytes"] < 0
    ):
        raise QualificationError("optimized_trajectory_manifest_identity_invalid")
    return (
        _TrajectoryVersionIdentity(
            version_id=manifest["version_id"],
            manifest_sha256=expected_manifest_sha256,
            input_identity_id=manifest["input_identity_id"],
            session_input_bundle_sha256=manifest[
                "session_input_bundle_sha256"
            ],
        ),
        artifacts,
        optimized_entry["sha256"],
    )


def _trajectory_evidence_from_bundle(
    bundle: Any,
    trajectory: dict[str, Any],
    *,
    release: dict[str, Any],
    release_sha256: str,
) -> dict[str, Any]:
    identity, artifacts, optimized_sha = _trajectory_source_from_bundle(
        bundle,
        expected_manifest_sha256=str(
            trajectory.get("localized_version_manifest_sha256", "")
        ),
    )
    return _derive_trajectory_evidence(
        identity,
        artifacts,
        optimized_sha,
        release=release,
        release_sha256=release_sha256,
        generated_at_utc=str(trajectory.get("generated_at_utc", "")),
    )


def _trajectory_evidence_and_bundle_from_version(
    localized_output: Path,
    version_id: str,
    *,
    expected_version_manifest_sha256: str,
    release: dict[str, Any],
    release_sha256: str,
) -> tuple[dict[str, Any], dict[str, Any]]:
    """Read one verified immutable version and preserve its derivation package."""

    if re.fullmatch(r"v[0-9]{6}", version_id) is None:
        raise QualificationError("localized_version_id_invalid")
    try:
        from tools.PriorMap.localized_output_store import (  # Local import avoids a cycle.
            LocalizedStoreError,
            LocalizedVersionStore,
        )

        store = LocalizedVersionStore(localized_output)
        snapshot = store.resolve_version(version_id)
        if (
            not SHA_RE.fullmatch(expected_version_manifest_sha256)
            or snapshot.manifest_sha256 != expected_version_manifest_sha256
        ):
            raise QualificationError("localized_version_manifest_sha_mismatch")
        manifest_bytes, artifacts = store.read_verified_manifest_and_artifacts(
            snapshot, TRAJECTORY_SOURCE_FILES
        )
        manifest = json.loads(manifest_bytes.decode("utf-8", errors="strict"))
        optimized_entry = next(
            entry
            for entry in manifest["files"]
            if entry.get("file") == "optimized_map_trajectory.geojson"
        )
        identity = _TrajectoryVersionIdentity(
            version_id=snapshot.version_id,
            manifest_sha256=snapshot.manifest_sha256,
            input_identity_id=str(snapshot.input_identity_id),
            session_input_bundle_sha256=str(snapshot.session_input_bundle_sha256),
        )
        evidence = _derive_trajectory_evidence(
            identity,
            artifacts,
            str(optimized_entry["sha256"]),
            release=release,
            release_sha256=release_sha256,
            generated_at_utc=datetime.now(timezone.utc).isoformat(
                timespec="milliseconds"
            ),
        )
    except QualificationError:
        raise
    except (
        OSError,
        LocalizedStoreError,
        UnicodeDecodeError,
        json.JSONDecodeError,
        KeyError,
        StopIteration,
        TypeError,
        ValueError,
    ) as exc:
        raise QualificationError("localized_version_verification_failed") from exc
    return evidence, _trajectory_bundle_from_verified_bytes(
        manifest_bytes, artifacts
    )


def _trajectory_evidence_from_version(
    localized_output: Path,
    version_id: str,
    *,
    expected_version_manifest_sha256: str,
    release: dict[str, Any],
    release_sha256: str,
) -> dict[str, Any]:
    evidence, _bundle = _trajectory_evidence_and_bundle_from_version(
        localized_output,
        version_id,
        expected_version_manifest_sha256=expected_version_manifest_sha256,
        release=release,
        release_sha256=release_sha256,
    )
    return evidence


def build_trajectory_qualification_evidence(
    localized_output: Path,
    version_id: str,
    expected_version_manifest_sha256: str,
    release_manifest: Path,
    output_path: Path,
) -> dict[str, Any]:
    release, release_sha, _release_size, _release_data = (
        _validate_release_manifest(release_manifest)
    )
    evidence = _trajectory_evidence_from_version(
        localized_output,
        version_id,
        expected_version_manifest_sha256=expected_version_manifest_sha256,
        release=release,
        release_sha256=release_sha,
    )
    _write_json(output_path, evidence)
    return evidence


def _read_tag_measurements_with_identity(
    path: Path,
    *,
    maximum_bytes: int = 16 * 1024 * 1024,
    maximum_rows: int = 50_000,
) -> tuple[dict[str, float], str, int, list[str], bytes]:
    data, digest, size, _identity = _read_stable_bytes(
        path, maximum_bytes=maximum_bytes, label="tag_measurements"
    )
    metrics, tag_ids = _parse_tag_measurements_bytes(
        data, maximum_rows=maximum_rows
    )
    return metrics, digest, size, tag_ids, data


def _parse_tag_measurements_bytes(
    data: bytes,
    *,
    maximum_rows: int = 50_000,
) -> tuple[dict[str, float], list[str]]:
    planar: list[float] = []
    height: list[float] = []
    try:
        text = data.decode("utf-8", errors="strict")
    except UnicodeDecodeError as exc:
        raise QualificationError("tag_measurements_invalid_utf8") from exc
    tag_ids: list[str] = []
    with io.StringIO(text, newline="") as stream:
        reader = csv.DictReader(stream)
        required = {"tag_id", "truth_x_m", "truth_y_m", "truth_height_m", "estimated_x_m", "estimated_y_m", "estimated_height_m"}
        if reader.fieldnames is None or not required.issubset(reader.fieldnames):
            raise QualificationError("tag_measurement_columns_missing")
        seen: set[str] = set()
        for row_index, row in enumerate(reader, start=1):
            if row_index > maximum_rows:
                raise QualificationError("tag_measurement_row_limit")
            tag_id = _required_string(row.get("tag_id"), "tag_id")
            if tag_id in seen:
                raise QualificationError("duplicate_tag_measurement")
            seen.add(tag_id)
            tag_ids.append(tag_id)
            tx, ty, th, ex, ey, eh = (
                _csv_number(row[name], name) for name in (
                    "truth_x_m", "truth_y_m", "truth_height_m",
                    "estimated_x_m", "estimated_y_m", "estimated_height_m",
                )
            )
            planar.append(math.hypot(ex - tx, ey - ty))
            height.append(abs(eh - th))
    if len(planar) < 20:
        raise QualificationError("fewer_than_20_independent_tag_controls")
    return (
        {
            "count": len(planar),
            "planarP50M": statistics.median(planar),
            "planarP95M": _percentile(planar, 0.95),
            "planarMaxM": max(planar),
            "heightP95M": _percentile(height, 0.95),
            "heightMaxM": max(height),
        },
        tag_ids,
    )


def _field_run_input_bundle(
    *,
    tag_name: str,
    tag_data: bytes,
    device_name: str,
    device_data: bytes,
) -> dict[str, Any]:
    def entry(name: str, data: bytes) -> dict[str, Any]:
        return {
            "name": name,
            "bytes": len(data),
            "sha256": hashlib.sha256(data).hexdigest(),
            "contentBase64": base64.b64encode(data).decode("ascii"),
        }

    return {
        "format": FORMAT_FIELD_RUN_INPUT_BUNDLE,
        "version": 1,
        "tagMeasurements": entry(tag_name, tag_data),
        "deviceEvidence": entry(device_name, device_data),
    }


def _qualification_source_bundle(
    *,
    plan_name: str,
    plan_data: bytes,
    release_name: str,
    release_data: bytes,
    policy_name: str,
    policy_data: bytes,
) -> dict[str, Any]:
    def entry(name: str, data: bytes) -> dict[str, Any]:
        return {
            "name": name,
            "bytes": len(data),
            "sha256": hashlib.sha256(data).hexdigest(),
            "contentBase64": base64.b64encode(data).decode("ascii"),
        }

    return {
        "format": "MarketScannerQualificationSourceBundle",
        "version": 1,
        "fieldPlan": entry(plan_name, plan_data),
        "releaseManifest": entry(release_name, release_data),
        "qualityPolicy": entry(policy_name, policy_data),
    }


def _qualification_source_bytes(
    bundle: Any,
) -> tuple[bytes, bytes, bytes]:
    if (
        not isinstance(bundle, dict)
        or bundle.get("format") != "MarketScannerQualificationSourceBundle"
        or bundle.get("version") != 1
        or set(bundle)
        != {
            "format",
            "version",
            "fieldPlan",
            "releaseManifest",
            "qualityPolicy",
        }
    ):
        raise QualificationError("qualification_source_bundle_invalid")
    values: list[bytes] = []
    for key, maximum in (
        ("fieldPlan", 16 * 1024 * 1024),
        ("releaseManifest", 16 * 1024 * 1024),
        ("qualityPolicy", 1024 * 1024),
    ):
        entry = bundle.get(key)
        if (
            not isinstance(entry, dict)
            or set(entry) != {"name", "bytes", "sha256", "contentBase64"}
            or not isinstance(entry.get("name"), str)
            or not entry["name"]
            or Path(entry["name"]).name != entry["name"]
            or isinstance(entry.get("bytes"), bool)
            or not isinstance(entry.get("bytes"), int)
            or entry["bytes"] < 0
            or entry["bytes"] > maximum
            or not SHA_RE.fullmatch(str(entry.get("sha256", "")))
            or not isinstance(entry.get("contentBase64"), str)
        ):
            raise QualificationError("qualification_source_entry_invalid")
        try:
            data = base64.b64decode(entry["contentBase64"], validate=True)
        except (ValueError, TypeError) as exc:
            raise QualificationError("qualification_source_base64_invalid") from exc
        if (
            len(data) != entry["bytes"]
            or hashlib.sha256(data).hexdigest() != entry["sha256"]
        ):
            raise QualificationError("qualification_source_identity_invalid")
        values.append(data)
    return values[0], values[1], values[2]


def _field_run_input_bytes(
    bundle: Any,
) -> tuple[bytes, bytes, list[dict[str, Any]]]:
    if (
        not isinstance(bundle, dict)
        or bundle.get("format") != FORMAT_FIELD_RUN_INPUT_BUNDLE
        or bundle.get("version") != 1
        or set(bundle)
        != {"format", "version", "tagMeasurements", "deviceEvidence"}
    ):
        raise QualificationError("field_run_input_bundle_invalid")
    decoded: dict[str, bytes] = {}
    input_files: list[dict[str, Any]] = []
    for key, role in (
        ("tagMeasurements", "tag_measurements"),
        ("deviceEvidence", "device_evidence"),
    ):
        entry = bundle.get(key)
        if (
            not isinstance(entry, dict)
            or set(entry) != {"name", "bytes", "sha256", "contentBase64"}
            or not isinstance(entry.get("name"), str)
            or not entry["name"]
            or Path(entry["name"]).name != entry["name"]
            or isinstance(entry.get("bytes"), bool)
            or not isinstance(entry.get("bytes"), int)
            or entry["bytes"] < 0
            or entry["bytes"] > 16 * 1024 * 1024
            or not SHA_RE.fullmatch(str(entry.get("sha256", "")))
            or not isinstance(entry.get("contentBase64"), str)
        ):
            raise QualificationError("field_run_input_entry_invalid")
        try:
            data = base64.b64decode(entry["contentBase64"], validate=True)
        except (ValueError, TypeError) as exc:
            raise QualificationError("field_run_input_base64_invalid") from exc
        if (
            len(data) != entry["bytes"]
            or hashlib.sha256(data).hexdigest() != entry["sha256"]
        ):
            raise QualificationError("field_run_input_identity_invalid")
        decoded[key] = data
        input_files.append(
            {
                "role": role,
                "name": entry["name"],
                "bytes": entry["bytes"],
                "sha256": entry["sha256"],
            }
        )
    return decoded["tagMeasurements"], decoded["deviceEvidence"], input_files


def evaluate_field(plan_path: Path, output_path: Path) -> dict[str, Any]:
    plan, plan_sha, _plan_size, plan_data = _load_json_with_identity_bytes(
        plan_path
    )
    if not isinstance(plan, dict) or plan.get("format") != FORMAT_FIELD_PLAN or plan.get("version") != 3:
        raise QualificationError("field_plan_contract_invalid")
    if plan.get("executionStatus") != "executed_with_independent_ground_truth":
        raise QualificationError("field_execution_not_attested")
    thresholds = plan.get("thresholds")
    runs = plan.get("runs")
    if not isinstance(thresholds, dict) or not isinstance(runs, list) or len(runs) < 3:
        raise QualificationError("field_thresholds_or_three_runs_missing")
    frozen_at = _finite_number(plan.get("thresholdsFrozenAtUnix"), "thresholds_frozen_at")
    release_manifest = Path(_required_string(plan.get("releaseManifest"), "release_manifest"))
    release, release_sha, release_size, release_data = (
        _validate_release_manifest(release_manifest)
    )
    if release_sha != plan.get("releaseManifestSha256"):
        raise QualificationError("release_manifest_sha_mismatch")
    quality_policy_path = Path(
        _required_string(plan.get("qualityPolicy"), "quality_policy")
    )
    quality_policy, policy_sha, policy_size, quality_policy_data = _validate_quality_policy(
        quality_policy_path
    )
    if policy_sha != plan.get("qualityPolicySha256"):
        raise QualificationError("quality_policy_sha_mismatch")
    if release.get("factor_graph_quality_policy_sha256") != policy_sha:
        raise QualificationError("release_quality_policy_sha_mismatch")
    prior_map_id = _required_string(plan.get("priorMapId"), "prior_map_id")
    prior_map_sha = str(plan.get("priorMapSha256", ""))
    if not SHA_RE.fullmatch(prior_map_sha):
        raise QualificationError("prior_map_sha_invalid")
    output_runs: list[dict[str, Any]] = []
    overall_blockers: list[str] = []
    topology_digests: set[str] = set()
    shelf_digests: set[str] = set()
    source_session_identities: set[tuple[str, str]] = set()
    seen_run_ids: set[str] = set()
    _required_string(plan.get("groundTruthMethod"), "ground_truth_method")
    _required_string(plan.get("independentSurveyor"), "independent_surveyor")
    site_id = _required_string(plan.get("siteId"), "site_id")
    if plan.get("siteType") not in {"office", "supermarket"}:
        raise QualificationError("site_type_invalid")
    for index, run in enumerate(runs):
        if not isinstance(run, dict):
            overall_blockers.append(f"run_{index + 1}:not_object")
            continue
        run_id = _required_string(run.get("runId"), f"run_{index + 1}_id")
        blockers: list[str] = []
        if run_id in seen_run_ids:
            blockers.append("duplicate_run_id")
        seen_run_ids.add(run_id)
        if _finite_number(run.get("executedAtUnix"), "executed_at") <= frozen_at:
            blockers.append("run_not_after_threshold_freeze")
        if "trajectoryMetrics" in run:
            raise QualificationError("free_form_trajectory_metrics_forbidden")
        localized_output = Path(
            _required_string(run.get("localizedOutput"), "localized_output")
        )
        localized_version_id = _required_string(
            run.get("localizedVersionId"), "localized_version_id"
        )
        localized_version_manifest_sha256 = _required_string(
            run.get("localizedVersionManifestSha256"),
            "localized_version_manifest_sha256",
        )
        tags_path = Path(_required_string(run.get("tagMeasurements"), "tag_measurements"))
        device_evidence_path = Path(_required_string(run.get("deviceEvidence"), "device_evidence"))
        metrics, trajectory_source_bundle = _trajectory_evidence_and_bundle_from_version(
            localized_output,
            localized_version_id,
            expected_version_manifest_sha256=localized_version_manifest_sha256,
            release=release,
            release_sha256=release_sha,
        )
        measured, tags_sha, tags_size, measured_tag_ids, tags_data = (
            _read_tag_measurements_with_identity(tags_path)
        )
        device_evidence, device_sha, device_size, device_data = (
            _validated_canonical_evidence_bytes(
                device_evidence_path,
                expected_format=FORMAT_DEVICE_EVIDENCE,
                expected_version=2,
            )
        )
        if not isinstance(metrics, dict):
            raise QualificationError("trajectory_metrics_not_object")
        if not isinstance(device_evidence, dict):
            raise QualificationError("device_evidence_not_object")
        if device_evidence.get("result") != "PASS" or device_evidence.get("blockers") != []:
            raise QualificationError("device_evidence_contract_invalid")
        app_identity = device_evidence.get("app")
        if (
            not isinstance(app_identity, dict)
            or not GIT_SHA_RE.fullmatch(str(app_identity.get("gitSha", "")))
            or not isinstance(app_identity.get("buildId"), str)
            or not app_identity["buildId"].strip()
        ):
            raise QualificationError("device_app_identity_invalid")
        if app_identity["gitSha"] != release["git_sha"]:
            blockers.append("device_app_release_sha_mismatch")
        for key, destination in (
            ("topologyDigest", topology_digests),
            ("shelfAssociationDigest", shelf_digests),
        ):
            value = metrics.get(key)
            if not SHA_RE.fullmatch(str(value or "")):
                blockers.append(f"required_digest_invalid:{key}")
            else:
                destination.add(value)
        source_bundle_sha = str(metrics.get("session_input_bundle_sha256", ""))
        tracking_session_id = str(metrics.get("tracking_session_id", ""))
        raw_database_sha = str(metrics.get("raw_database_sha256", ""))
        if (
            not SHA_RE.fullmatch(source_bundle_sha)
            or not tracking_session_id
            or not SHA_RE.fullmatch(raw_database_sha)
        ):
            blockers.append("source_session_identity_invalid")
        else:
            source_session_identities.add((source_bundle_sha, tracking_session_id))
        device_runs = device_evidence.get("runs")
        matching_device_runs = [
            candidate
            for candidate in device_runs
            if isinstance(candidate, dict)
            and candidate.get("rawSessionBundleSha256") == source_bundle_sha
            and candidate.get("trackingSessionId") == tracking_session_id
            and candidate.get("rawDatabaseSha256") == raw_database_sha
        ] if isinstance(device_runs, list) else []
        if len(matching_device_runs) != 1:
            blockers.append("raw_session_not_bound_to_device_evidence")
        else:
            device_run = matching_device_runs[0]
            session_identity = device_run.get("sessionIdentity")
            if (
                not isinstance(session_identity, dict)
                or session_identity.get("priorMapId") != prior_map_id
                or session_identity.get("priorMapSha256") != prior_map_sha
            ):
                blockers.append("device_prior_map_identity_mismatch")
        if metrics.get("quality_policy_sha256") != policy_sha:
            blockers.append("trajectory_quality_policy_sha_mismatch")
        if (
            metrics.get("release_git_sha") != release.get("git_sha")
            or metrics.get("release_manifest_sha256") != release_sha
            or metrics.get("product_version") != release.get("product_version")
        ):
            blockers.append("trajectory_release_identity_mismatch")
        if (
            metrics.get("prior_map_id") != prior_map_id
            or metrics.get("prior_map_sha256") != prior_map_sha
        ):
            blockers.append("trajectory_prior_map_identity_mismatch")
        localized_tag_ids = metrics.get("localizedTagIds")
        if (
            not isinstance(localized_tag_ids, list)
            or any(not isinstance(tag_id, str) for tag_id in localized_tag_ids)
            or not set(measured_tag_ids).issubset(set(localized_tag_ids))
        ):
            blockers.append("ground_truth_tag_not_bound_to_localized_version")
        numeric_limits = {
            "nodeCoverage": (">=", "nodeCoverageMin"),
            "correctionP95M": ("<=", "correctionP95MaxM"),
            "correctionMaxM": ("<=", "correctionMaxM"),
            "relativeTranslationResidualP95M": ("<=", "relativeTranslationResidualP95MaxM"),
            "relativeYawResidualP95Rad": ("<=", "relativeYawResidualP95MaxRad"),
            "weakLostDurationRatio": ("<=", "weakLostDurationRatioMax"),
        }
        for metric, (operator, threshold) in numeric_limits.items():
            actual = _finite_number(metrics.get(metric), metric)
            limit = _finite_number(thresholds.get(threshold), threshold)
            if (operator == ">=" and actual < limit) or (operator == "<=" and actual > limit):
                blockers.append(f"threshold_failed:{metric}")
        tag_limits = {
            "planarP95M": "tagPlanarP95MaxM",
            "planarMaxM": "tagPlanarMaxM",
            "heightP95M": "tagHeightP95MaxM",
        }
        for metric, threshold in tag_limits.items():
            if measured[metric] > _finite_number(thresholds.get(threshold), threshold):
                blockers.append(f"threshold_failed:{metric}")
        for key in (
            "inventoriesMatch",
            "factorGraphConverged",
            "factorGraphQualityPassed",
            "singleConnectedComponent",
            "allGroundTruthTagsObserved",
            "userConfirmedTagsPreserved",
        ):
            if metrics.get(key) is not True:
                blockers.append(f"required_invariant_failed:{key}")
        if metrics.get("automaticConfirmDuringWeakLost") != 0:
            blockers.append("automatic_confirmation_during_weak_or_lost")
        output_runs.append({
            "runId": run_id,
            "executedAtUnix": run.get("executedAtUnix"),
            "sourceSessionIdentity": {
                "rawSessionBundleSha256": source_bundle_sha,
                "rawDatabaseSha256": raw_database_sha,
                "trackingSessionId": tracking_session_id,
            },
            "trajectoryEvidence": metrics,
            "trajectorySourceBundle": trajectory_source_bundle,
            "fieldRunInputBundle": _field_run_input_bundle(
                tag_name=tags_path.name,
                tag_data=tags_data,
                device_name=device_evidence_path.name,
                device_data=device_data,
            ),
            "independentTagMetrics": measured,
            "releaseGitSha": release["git_sha"],
            "deviceAppGitSha": app_identity["gitSha"],
            "deviceAppBuildId": app_identity["buildId"],
            "deviceEvidenceIdentity": {
                "format": device_evidence.get("format"),
                "version": device_evidence.get("version"),
                "result": device_evidence.get("result"),
                "appGitSha": app_identity["gitSha"],
                "appBuildId": app_identity["buildId"],
                "evidenceBodySha256": device_evidence.get("evidenceSha256"),
                "fileSha256": device_sha,
            },
            "inputFiles": [
                {"role": "tag_measurements", "name": tags_path.name, "bytes": tags_size, "sha256": tags_sha},
                {"role": "device_evidence", "name": device_evidence_path.name, "bytes": device_size, "sha256": device_sha},
            ],
            "blockers": blockers,
            "result": "PASS" if not blockers else "FAIL",
        })
        overall_blockers.extend(f"{run_id}:{item}" for item in blockers)
    if len(topology_digests) != 1:
        overall_blockers.append("topology_not_repeatable_across_runs")
    if len(shelf_digests) != 1:
        overall_blockers.append("shelf_association_not_repeatable_across_runs")
    if len(source_session_identities) < 3:
        overall_blockers.append("fewer_than_three_distinct_source_sessions")
    evidence = {
        "format": FORMAT_FIELD_EVIDENCE,
        "version": 3,
        "sourcePlanSha256": plan_sha,
        "qualificationSourceBundle": _qualification_source_bundle(
            plan_name=plan_path.name,
            plan_data=plan_data,
            release_name=release_manifest.name,
            release_data=release_data,
            policy_name=quality_policy_path.name,
            policy_data=quality_policy_data,
        ),
        "releaseManifest": {
            "name": release_manifest.name,
            "bytes": release_size,
            "sha256": release_sha,
            "gitSha": release.get("git_sha"),
            "productVersion": release.get("product_version"),
            "manifestBodySha256": release.get("manifest_body_sha256"),
        },
        "qualityPolicy": {
            "name": quality_policy_path.name,
            "bytes": policy_size,
            "sha256": policy_sha,
            "policyVersion": quality_policy.get("policy_version"),
            "status": quality_policy.get("status"),
        },
        "priorMapIdentity": {
            "priorMapId": prior_map_id,
            "priorMapSha256": prior_map_sha,
        },
        "thresholdsFrozenAtUnix": frozen_at,
        "thresholds": thresholds,
        "siteId": site_id,
        "siteType": plan["siteType"],
        "groundTruthMethod": plan["groundTruthMethod"],
        "independentSurveyor": plan["independentSurveyor"],
        "runs": output_runs,
        "blockers": overall_blockers,
        "result": "PASS" if not overall_blockers else "FAIL",
    }
    evidence["evidenceSha256"] = _canonical_sha(evidence)
    _write_json(output_path, evidence)
    return evidence


def inspect_field_evidence(
    path: Path,
    *,
    required_site_type: str = "supermarket",
) -> dict[str, Any]:
    """Validate immutable field evidence without trusting client-supplied claims."""
    summary, _data = inspect_field_evidence_with_bytes(
        path, required_site_type=required_site_type
    )
    return summary


def inspect_field_evidence_with_bytes(
    path: Path,
    *,
    required_site_type: str = "supermarket",
) -> tuple[dict[str, Any], bytes]:
    """Return validation summary and the exact accepted descriptor bytes."""

    evidence, file_sha, file_size, data = _validated_canonical_evidence_bytes(
        path,
        expected_format=FORMAT_FIELD_EVIDENCE,
        expected_version=3,
        maximum_bytes=128 * 1024 * 1024,
    )
    try:
        plan_data, release_data, policy_data = _qualification_source_bytes(
            evidence.get("qualificationSourceBundle")
        )
        plan = json.loads(
            plan_data.decode("utf-8", errors="strict"),
            parse_constant=lambda token: (_ for _ in ()).throw(ValueError(token)),
        )
        source_release = json.loads(
            release_data.decode("utf-8", errors="strict"),
            parse_constant=lambda token: (_ for _ in ()).throw(ValueError(token)),
        )
        source_policy = json.loads(
            policy_data.decode("utf-8", errors="strict"),
            parse_constant=lambda token: (_ for _ in ()).throw(ValueError(token)),
        )
        _validate_release_manifest_value(source_release)
        _validate_quality_policy_value(source_policy)
    except (
        QualificationError,
        UnicodeDecodeError,
        json.JSONDecodeError,
        ValueError,
    ) as exc:
        raise QualificationError("qualification_source_rederivation_failed") from exc
    if (
        not isinstance(plan, dict)
        or plan.get("format") != FORMAT_FIELD_PLAN
        or plan.get("version") != 3
        or plan.get("executionStatus")
        != "executed_with_independent_ground_truth"
        or evidence.get("sourcePlanSha256")
        != hashlib.sha256(plan_data).hexdigest()
    ):
        raise QualificationError("qualification_source_plan_invalid")
    if evidence.get("result") != "PASS" or evidence.get("blockers") != []:
        raise QualificationError("field_evidence_not_pass")
    if evidence.get("siteType") != required_site_type:
        raise QualificationError("field_site_type_not_qualified")
    _required_string(evidence.get("siteId"), "field_site_id")
    _required_string(evidence.get("groundTruthMethod"), "ground_truth_method")
    _required_string(evidence.get("independentSurveyor"), "independent_surveyor")
    _finite_number(evidence.get("thresholdsFrozenAtUnix"), "thresholds_frozen_at")
    thresholds = evidence.get("thresholds")
    if not isinstance(thresholds, dict):
        raise QualificationError("field_thresholds_invalid")
    release = evidence.get("releaseManifest")
    policy = evidence.get("qualityPolicy")
    prior = evidence.get("priorMapIdentity")
    if (
        not isinstance(release, dict)
        or not SHA_RE.fullmatch(str(release.get("sha256", "")))
        or not GIT_SHA_RE.fullmatch(str(release.get("gitSha", "")))
        or not isinstance(release.get("productVersion"), str)
        or not release["productVersion"].strip()
        or not isinstance(policy, dict)
        or policy.get("status") != "frozen"
        or not SHA_RE.fullmatch(str(policy.get("sha256", "")))
        or not isinstance(policy.get("policyVersion"), str)
        or not policy["policyVersion"].strip()
        or not isinstance(prior, dict)
        or not isinstance(prior.get("priorMapId"), str)
        or not prior["priorMapId"].strip()
        or not SHA_RE.fullmatch(str(prior.get("priorMapSha256", "")))
    ):
        raise QualificationError("field_publication_identity_invalid")
    source_bundle = evidence["qualificationSourceBundle"]
    plan_entry = source_bundle["fieldPlan"]
    release_entry = source_bundle["releaseManifest"]
    policy_entry = source_bundle["qualityPolicy"]
    if (
        release.get("name") != release_entry["name"]
        or release.get("bytes") != release_entry["bytes"]
        or release.get("sha256") != release_entry["sha256"]
        or release.get("gitSha") != source_release.get("git_sha")
        or release.get("productVersion")
        != source_release.get("product_version")
        or release.get("manifestBodySha256")
        != source_release.get("manifest_body_sha256")
        or policy.get("name") != policy_entry["name"]
        or policy.get("bytes") != policy_entry["bytes"]
        or policy.get("sha256") != policy_entry["sha256"]
        or policy.get("policyVersion") != source_policy.get("policy_version")
        or policy.get("status") != source_policy.get("status")
        or plan.get("releaseManifestSha256") != release_entry["sha256"]
        or plan.get("qualityPolicySha256") != policy_entry["sha256"]
        or source_release.get("factor_graph_quality_policy_sha256")
        != policy_entry["sha256"]
        or plan.get("thresholds") != thresholds
        or plan.get("thresholdsFrozenAtUnix")
        != evidence.get("thresholdsFrozenAtUnix")
        or plan.get("siteId") != evidence.get("siteId")
        or plan.get("siteType") != evidence.get("siteType")
        or plan.get("groundTruthMethod") != evidence.get("groundTruthMethod")
        or plan.get("independentSurveyor")
        != evidence.get("independentSurveyor")
        or plan.get("priorMapId") != prior.get("priorMapId")
        or plan.get("priorMapSha256") != prior.get("priorMapSha256")
        or plan_entry["bytes"] != len(plan_data)
        or plan_entry["sha256"] != hashlib.sha256(plan_data).hexdigest()
    ):
        raise QualificationError("qualification_sources_differ_from_field_evidence")
    runs = evidence.get("runs")
    plan_runs = plan.get("runs")
    if (
        not isinstance(runs, list)
        or len(runs) < 3
        or not isinstance(plan_runs, list)
        or len(plan_runs) != len(runs)
    ):
        raise QualificationError("field_evidence_three_runs_missing")
    plan_runs_by_id = {
        candidate.get("runId"): candidate
        for candidate in plan_runs
        if isinstance(candidate, dict)
        and isinstance(candidate.get("runId"), str)
    }
    if len(plan_runs_by_id) != len(plan_runs):
        raise QualificationError("qualification_source_runs_invalid")
    run_ids: set[str] = set()
    session_identities: set[tuple[str, str]] = set()
    topology_digests: set[str] = set()
    shelf_digests: set[str] = set()
    tag_count = 0
    for run in runs:
        if (
            not isinstance(run, dict)
            or run.get("result") != "PASS"
            or run.get("blockers") != []
        ):
            raise QualificationError("field_run_not_pass")
        run_id = _required_string(run.get("runId"), "field_run_id")
        if run_id in run_ids:
            raise QualificationError("duplicate_run_id")
        run_ids.add(run_id)
        plan_run = plan_runs_by_id.get(run_id)
        if (
            not isinstance(plan_run, dict)
            or plan_run.get("executedAtUnix") != run.get("executedAtUnix")
        ):
            raise QualificationError("field_run_differs_from_source_plan")
        identity = run.get("sourceSessionIdentity")
        if not isinstance(identity, dict):
            raise QualificationError("source_session_identity_invalid")
        bundle_sha = str(identity.get("rawSessionBundleSha256", ""))
        database_sha = str(identity.get("rawDatabaseSha256", ""))
        tracking_id = str(identity.get("trackingSessionId", ""))
        if (
            not SHA_RE.fullmatch(bundle_sha)
            or not SHA_RE.fullmatch(database_sha)
            or not tracking_id
        ):
            raise QualificationError("source_session_identity_invalid")
        session_identities.add((bundle_sha, tracking_id))
        tag_metrics = run.get("independentTagMetrics")
        count = tag_metrics.get("count") if isinstance(tag_metrics, dict) else None
        if not isinstance(count, int) or isinstance(count, bool) or count < 20:
            raise QualificationError("field_run_tag_controls_invalid")
        try:
            tag_data, device_data, bundled_input_files = _field_run_input_bytes(
                run.get("fieldRunInputBundle")
            )
            rederived_tag_metrics, measured_tag_ids = (
                _parse_tag_measurements_bytes(tag_data)
            )
            device_evidence = _validated_canonical_evidence_data(
                device_data,
                expected_format=FORMAT_DEVICE_EVIDENCE,
                expected_version=2,
            )
        except QualificationError as exc:
            raise QualificationError("field_run_input_rederivation_failed") from exc
        if (
            rederived_tag_metrics != tag_metrics
            or run.get("inputFiles") != bundled_input_files
        ):
            raise QualificationError("field_run_inputs_differ_from_summaries")
        tag_count += count
        device_identity = run.get("deviceEvidenceIdentity")
        device_app = (
            device_evidence.get("app")
            if isinstance(device_evidence, dict)
            else None
        )
        device_file_sha = hashlib.sha256(device_data).hexdigest()
        if (
            not isinstance(device_identity, dict)
            or device_identity.get("format") != FORMAT_DEVICE_EVIDENCE
            or device_identity.get("version") != 2
            or device_identity.get("result") != "PASS"
            or device_identity.get("appGitSha") != release["gitSha"]
            or device_identity.get("appBuildId") != run.get("deviceAppBuildId")
            or not SHA_RE.fullmatch(str(device_identity.get("evidenceBodySha256", "")))
            or not SHA_RE.fullmatch(str(device_identity.get("fileSha256", "")))
            or not isinstance(device_evidence, dict)
            or device_evidence.get("result") != "PASS"
            or device_evidence.get("blockers") != []
            or not isinstance(device_app, dict)
            or device_app.get("gitSha") != release["gitSha"]
            or device_app.get("buildId") != run.get("deviceAppBuildId")
            or device_identity.get("evidenceBodySha256")
            != device_evidence.get("evidenceSha256")
            or device_identity.get("fileSha256") != device_file_sha
        ):
            raise QualificationError("nested_device_evidence_identity_invalid")
        matching_device_runs = [
            candidate
            for candidate in device_evidence.get("runs", [])
            if isinstance(candidate, dict)
            and candidate.get("rawSessionBundleSha256") == bundle_sha
            and candidate.get("rawDatabaseSha256") == database_sha
            and candidate.get("trackingSessionId") == tracking_id
        ]
        if len(matching_device_runs) != 1:
            raise QualificationError("source_session_not_bound_to_device_evidence")
        device_session_identity = matching_device_runs[0].get("sessionIdentity")
        if (
            not isinstance(device_session_identity, dict)
            or device_session_identity.get("priorMapId") != prior["priorMapId"]
            or device_session_identity.get("priorMapSha256")
            != prior["priorMapSha256"]
        ):
            raise QualificationError("device_prior_map_identity_invalid")
        trajectory = run.get("trajectoryEvidence")
        if not isinstance(trajectory, dict):
            raise QualificationError("trajectory_evidence_missing")
        trajectory_body = dict(trajectory)
        trajectory_sha = trajectory_body.pop("evidenceSha256", None)
        if (
            trajectory.get("format") != FORMAT_TRAJECTORY_EVIDENCE
            or trajectory.get("version") != 1
            or not SHA_RE.fullmatch(str(trajectory_sha or ""))
            or _canonical_sha(trajectory_body) != trajectory_sha
            or trajectory.get("release_git_sha") != release["gitSha"]
            or trajectory.get("release_manifest_sha256") != release["sha256"]
            or trajectory.get("product_version") != release["productVersion"]
            or trajectory.get("prior_map_id") != prior["priorMapId"]
            or trajectory.get("prior_map_sha256") != prior["priorMapSha256"]
            or trajectory.get("quality_policy_sha256") != policy["sha256"]
            or not re.fullmatch(
                r"v[0-9]{6}", str(trajectory.get("localized_version_id", ""))
            )
        ):
            raise QualificationError("trajectory_evidence_contract_invalid")
        if (
            plan_run.get("localizedVersionId")
            != trajectory.get("localized_version_id")
            or plan_run.get("localizedVersionManifestSha256")
            != trajectory.get("localized_version_manifest_sha256")
        ):
            raise QualificationError("trajectory_differs_from_source_plan")
        for name in (
            "localized_version_manifest_sha256",
            "input_identity_id",
            "session_input_bundle_sha256",
            "raw_database_sha256",
            "quality_policy_sha256",
        ):
            if not SHA_RE.fullmatch(str(trajectory.get(name, ""))):
                raise QualificationError("trajectory_evidence_identity_invalid")
        if (
            trajectory.get("session_input_bundle_sha256") != bundle_sha
            or trajectory.get("raw_database_sha256") != database_sha
            or trajectory.get("tracking_session_id") != tracking_id
            or run.get("releaseGitSha") != release["gitSha"]
            or run.get("deviceAppGitSha") != release["gitSha"]
            or not isinstance(run.get("deviceAppBuildId"), str)
            or not run["deviceAppBuildId"].strip()
        ):
            raise QualificationError("field_run_release_or_session_identity_invalid")
        try:
            derived_trajectory = _trajectory_evidence_from_bundle(
                run.get("trajectorySourceBundle"),
                trajectory,
                release={
                    "git_sha": release["gitSha"],
                    "product_version": release["productVersion"],
                    "factor_graph_quality_policy_sha256": policy["sha256"],
                },
                release_sha256=release["sha256"],
            )
        except QualificationError as exc:
            raise QualificationError("trajectory_source_rederivation_failed") from exc
        if derived_trajectory != trajectory:
            raise QualificationError("trajectory_evidence_differs_from_source_bundle")
        for name, destination in (
            ("topologyDigest", topology_digests),
            ("shelfAssociationDigest", shelf_digests),
        ):
            digest = trajectory.get(name)
            if not SHA_RE.fullmatch(str(digest or "")):
                raise QualificationError(f"trajectory_digest_invalid:{name}")
            destination.add(str(digest))
        numeric_limits = {
            "nodeCoverage": (">=", "nodeCoverageMin"),
            "correctionP95M": ("<=", "correctionP95MaxM"),
            "correctionMaxM": ("<=", "correctionMaxM"),
            "relativeTranslationResidualP95M": (
                "<=",
                "relativeTranslationResidualP95MaxM",
            ),
            "relativeYawResidualP95Rad": (
                "<=",
                "relativeYawResidualP95MaxRad",
            ),
            "weakLostDurationRatio": ("<=", "weakLostDurationRatioMax"),
        }
        for metric, (operator, threshold_name) in numeric_limits.items():
            actual = _finite_number(trajectory.get(metric), metric)
            limit = _finite_number(thresholds.get(threshold_name), threshold_name)
            if (operator == ">=" and actual < limit) or (
                operator == "<=" and actual > limit
            ):
                raise QualificationError(f"field_threshold_failed:{metric}")
        tag_limits = {
            "planarP95M": "tagPlanarP95MaxM",
            "planarMaxM": "tagPlanarMaxM",
            "heightP95M": "tagHeightP95MaxM",
        }
        for metric, threshold_name in tag_limits.items():
            measured_value = _finite_number(tag_metrics.get(metric), metric)
            if measured_value > _finite_number(
                thresholds.get(threshold_name), threshold_name
            ):
                raise QualificationError(f"field_threshold_failed:{metric}")
        for name in (
            "inventoriesMatch",
            "factorGraphConverged",
            "factorGraphQualityPassed",
            "singleConnectedComponent",
            "allGroundTruthTagsObserved",
            "userConfirmedTagsPreserved",
        ):
            if trajectory.get(name) is not True:
                raise QualificationError("trajectory_required_invariant_failed")
        if trajectory.get("automaticConfirmDuringWeakLost") != 0:
            raise QualificationError("trajectory_weak_lost_auto_confirm_invalid")
        localized_tag_ids = trajectory.get("localizedTagIds")
        if (
            not isinstance(localized_tag_ids, list)
            or len(localized_tag_ids) < count
            or len(set(localized_tag_ids)) != len(localized_tag_ids)
            or any(not isinstance(tag_id, str) or not tag_id for tag_id in localized_tag_ids)
            or not set(measured_tag_ids).issubset(set(localized_tag_ids))
            or _canonical_sha(sorted(localized_tag_ids))
            != trajectory.get("localizedTagIdsSha256")
        ):
            raise QualificationError("trajectory_tag_inventory_invalid")
    if len(session_identities) < 3:
        raise QualificationError("fewer_than_three_distinct_source_sessions")
    if len(topology_digests) != 1:
        raise QualificationError("topology_not_repeatable_across_runs")
    if len(shelf_digests) != 1:
        raise QualificationError("shelf_association_not_repeatable_across_runs")
    return {
        "qualification_id": f"sha256:{file_sha}",
        "file_sha256": file_sha,
        "file_bytes": file_size,
        "evidence_sha256": evidence["evidenceSha256"],
        "release_manifest_sha256": release["sha256"],
        "release_git_sha": release["gitSha"],
        "product_version": release["productVersion"],
        "quality_policy_sha256": policy["sha256"],
        "quality_policy_version": policy["policyVersion"],
        "prior_map_id": prior["priorMapId"],
        "prior_map_sha256": prior["priorMapSha256"],
        "site_id": evidence["siteId"],
        "site_type": evidence["siteType"],
        "run_count": len(runs),
        "tag_control_count": tag_count,
        "result": "PASS",
    }, data


def _write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.tmp-{os.getpid()}")
    data = json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True).encode() + b"\n"
    with temporary.open("xb") as stream:
        stream.write(data)
        stream.flush()
        os.fsync(stream.fileno())
    try:
        os.link(temporary, path)
    except FileExistsError as exc:
        raise QualificationError("evidence_output_already_exists") from exc
    finally:
        temporary.unlink(missing_ok=True)
    # Windows does not support opening a directory through os.open(), so there
    # is no portable directory fsync equivalent. The evidence bytes themselves
    # have already been flushed above and os.link() still provides exclusive,
    # no-overwrite publication on that platform.
    if os.name == "nt":
        return
    directory_descriptor = os.open(path.parent, os.O_RDONLY)
    try:
        os.fsync(directory_descriptor)
    finally:
        os.close(directory_descriptor)


def main(argv: Iterable[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    for name in ("device", "field"):
        command = subparsers.add_parser(name)
        command.add_argument("--plan", type=Path, required=True)
        command.add_argument("--output", type=Path, required=True)
    trajectory = subparsers.add_parser("trajectory")
    trajectory.add_argument("--localized-output", type=Path, required=True)
    trajectory.add_argument("--version-id", required=True)
    trajectory.add_argument("--version-manifest-sha256", required=True)
    trajectory.add_argument("--release-manifest", type=Path, required=True)
    trajectory.add_argument("--output", type=Path, required=True)
    arguments = parser.parse_args(argv)
    try:
        if arguments.command == "device":
            result = collect_device(arguments.plan, arguments.output)
        elif arguments.command == "field":
            result = evaluate_field(arguments.plan, arguments.output)
        else:
            result = build_trajectory_qualification_evidence(
                arguments.localized_output,
                arguments.version_id,
                arguments.version_manifest_sha256,
                arguments.release_manifest,
                arguments.output,
            )
    except (OSError, QualificationError) as exc:
        print(f"qualification error: {exc}", file=sys.stderr)
        return 2
    result_value = result.get("result", "GENERATED")
    print(json.dumps({"result": result_value, "output": str(arguments.output)}))
    return 0 if result_value in {"PASS", "GENERATED"} else 1


if __name__ == "__main__":
    raise SystemExit(main())
