#!/usr/bin/env python3
"""Fail-closed evidence collector for MarketScanner device and field trials."""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import math
import os
from pathlib import Path
import re
import statistics
import sys
from typing import Any, Iterable


FORMAT_DEVICE_PLAN = "MarketScannerDeviceQualificationPlan"
FORMAT_DEVICE_EVIDENCE = "MarketScannerDeviceQualificationEvidence"
FORMAT_FIELD_PLAN = "MarketScannerFieldQualificationPlan"
FORMAT_FIELD_EVIDENCE = "MarketScannerFieldQualificationEvidence"
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


class QualificationError(ValueError):
    pass


def _load_json_with_identity(
    path: Path, maximum_bytes: int = 16 * 1024 * 1024
) -> tuple[Any, str, int]:
    info = path.lstat()
    if not path.is_file() or path.is_symlink() or info.st_nlink != 1:
        raise QualificationError(f"unsafe_regular_file:{path.name}")
    if info.st_size > maximum_bytes:
        raise QualificationError(f"json_size_limit:{path.name}")
    with path.open("rb") as stream:
        data = stream.read(maximum_bytes + 1)
        after = os.fstat(stream.fileno())
    current = path.lstat()
    if (
        len(data) > maximum_bytes
        or (info.st_dev, info.st_ino, info.st_size)
        != (after.st_dev, after.st_ino, after.st_size)
        or (info.st_dev, info.st_ino, info.st_size)
        != (current.st_dev, current.st_ino, current.st_size)
    ):
        raise QualificationError(f"json_changed_during_read:{path.name}")
    try:
        return json.loads(data), hashlib.sha256(data).hexdigest(), len(data)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise QualificationError(f"invalid_json:{path.name}") from exc


def _load_json(path: Path, maximum_bytes: int = 16 * 1024 * 1024) -> Any:
    return _load_json_with_identity(path, maximum_bytes)[0]


def _sha256(path: Path) -> tuple[str, int]:
    before = path.lstat()
    if not path.is_file() or path.is_symlink() or before.st_nlink != 1:
        raise QualificationError(f"unsafe_artifact:{path.name}")
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            digest.update(chunk)
        opened = os.fstat(stream.fileno())
    after = path.lstat()
    identity = (before.st_dev, before.st_ino, before.st_size)
    if identity != (opened.st_dev, opened.st_ino, opened.st_size) or identity != (
        after.st_dev,
        after.st_ino,
        after.st_size,
    ):
        raise QualificationError(f"artifact_changed_during_hash:{path.name}")
    return digest.hexdigest(), before.st_size


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
    value, digest, size = _load_json_with_identity(path)
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
    return value, digest, size


def _validate_release_manifest(path: Path) -> tuple[dict[str, Any], str, int]:
    value, digest, size = _load_json_with_identity(path)
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
    return value, digest, size


def _validate_quality_policy(path: Path) -> tuple[dict[str, Any], str, int]:
    value, digest, size = _load_json_with_identity(path, maximum_bytes=1024 * 1024)
    if (
        not isinstance(value, dict)
        or value.get("format") != FORMAT_QUALITY_POLICY
        or value.get("version") != 1
        or value.get("status") != "frozen"
        or not isinstance(value.get("policy_version"), str)
        or not value["policy_version"].strip()
    ):
        raise QualificationError("quality_policy_not_frozen_or_invalid")
    return value, digest, size


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


def _read_tag_measurements(path: Path) -> dict[str, float]:
    planar: list[float] = []
    height: list[float] = []
    with path.open(newline="", encoding="utf-8") as stream:
        reader = csv.DictReader(stream)
        required = {"tag_id", "truth_x_m", "truth_y_m", "truth_height_m", "estimated_x_m", "estimated_y_m", "estimated_height_m"}
        if reader.fieldnames is None or not required.issubset(reader.fieldnames):
            raise QualificationError("tag_measurement_columns_missing")
        seen: set[str] = set()
        for row in reader:
            tag_id = _required_string(row.get("tag_id"), "tag_id")
            if tag_id in seen:
                raise QualificationError("duplicate_tag_measurement")
            seen.add(tag_id)
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
    return {
        "count": len(planar),
        "planarP50M": statistics.median(planar),
        "planarP95M": _percentile(planar, 0.95),
        "planarMaxM": max(planar),
        "heightP95M": _percentile(height, 0.95),
        "heightMaxM": max(height),
    }


def evaluate_field(plan_path: Path, output_path: Path) -> dict[str, Any]:
    plan = _load_json(plan_path)
    if not isinstance(plan, dict) or plan.get("format") != FORMAT_FIELD_PLAN or plan.get("version") != 2:
        raise QualificationError("field_plan_contract_invalid")
    if plan.get("executionStatus") != "executed_with_independent_ground_truth":
        raise QualificationError("field_execution_not_attested")
    thresholds = plan.get("thresholds")
    runs = plan.get("runs")
    if not isinstance(thresholds, dict) or not isinstance(runs, list) or len(runs) < 3:
        raise QualificationError("field_thresholds_or_three_runs_missing")
    frozen_at = _finite_number(plan.get("thresholdsFrozenAtUnix"), "thresholds_frozen_at")
    release_manifest = Path(_required_string(plan.get("releaseManifest"), "release_manifest"))
    release, release_sha, release_size = _validate_release_manifest(release_manifest)
    if release_sha != plan.get("releaseManifestSha256"):
        raise QualificationError("release_manifest_sha_mismatch")
    quality_policy_path = Path(
        _required_string(plan.get("qualityPolicy"), "quality_policy")
    )
    quality_policy, policy_sha, policy_size = _validate_quality_policy(
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
        metrics_path = Path(_required_string(run.get("trajectoryMetrics"), "trajectory_metrics"))
        tags_path = Path(_required_string(run.get("tagMeasurements"), "tag_measurements"))
        device_evidence_path = Path(_required_string(run.get("deviceEvidence"), "device_evidence"))
        metrics_sha, metrics_size = _sha256(metrics_path)
        tags_sha, tags_size = _sha256(tags_path)
        metrics = _load_json(metrics_path)
        device_evidence, device_sha, device_size = _validated_canonical_evidence(
            device_evidence_path,
            expected_format=FORMAT_DEVICE_EVIDENCE,
            expected_version=2,
        )
        if not isinstance(metrics, dict):
            raise QualificationError("trajectory_metrics_not_object")
        if not isinstance(device_evidence, dict):
            raise QualificationError("device_evidence_not_object")
        if device_evidence.get("result") != "PASS" or device_evidence.get("blockers") != []:
            raise QualificationError("device_evidence_contract_invalid")
        for key, destination in (
            ("topologyDigest", topology_digests),
            ("shelfAssociationDigest", shelf_digests),
        ):
            value = metrics.get(key)
            if not SHA_RE.fullmatch(str(value or "")):
                blockers.append(f"required_digest_invalid:{key}")
            else:
                destination.add(value)
        source_bundle_sha = str(metrics.get("sourceSessionBundleSha256", ""))
        tracking_session_id = str(metrics.get("trackingSessionId", ""))
        raw_database_sha = str(metrics.get("rawDatabaseSha256", ""))
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
        if metrics.get("qualityPolicySha256") != policy_sha:
            blockers.append("trajectory_quality_policy_sha_mismatch")
        measured = _read_tag_measurements(tags_path)
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
            "trajectoryMetrics": metrics,
            "independentTagMetrics": measured,
            "deviceEvidenceIdentity": {
                "format": device_evidence.get("format"),
                "version": device_evidence.get("version"),
                "result": device_evidence.get("result"),
                "evidenceBodySha256": device_evidence.get("evidenceSha256"),
                "fileSha256": device_sha,
            },
            "inputFiles": [
                {"role": "trajectory_metrics", "name": metrics_path.name, "bytes": metrics_size, "sha256": metrics_sha},
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
        "version": 2,
        "sourcePlanSha256": _sha256(plan_path)[0],
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
    evidence, file_sha, file_size = _validated_canonical_evidence(
        path,
        expected_format=FORMAT_FIELD_EVIDENCE,
        expected_version=2,
    )
    if evidence.get("result") != "PASS" or evidence.get("blockers") != []:
        raise QualificationError("field_evidence_not_pass")
    if evidence.get("siteType") != required_site_type:
        raise QualificationError("field_site_type_not_qualified")
    _required_string(evidence.get("siteId"), "field_site_id")
    _required_string(evidence.get("groundTruthMethod"), "ground_truth_method")
    _required_string(evidence.get("independentSurveyor"), "independent_surveyor")
    _finite_number(evidence.get("thresholdsFrozenAtUnix"), "thresholds_frozen_at")
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
    runs = evidence.get("runs")
    if not isinstance(runs, list) or len(runs) < 3:
        raise QualificationError("field_evidence_three_runs_missing")
    run_ids: set[str] = set()
    session_identities: set[tuple[str, str]] = set()
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
        tag_count += count
        device_identity = run.get("deviceEvidenceIdentity")
        if (
            not isinstance(device_identity, dict)
            or device_identity.get("format") != FORMAT_DEVICE_EVIDENCE
            or device_identity.get("version") != 2
            or device_identity.get("result") != "PASS"
            or not SHA_RE.fullmatch(str(device_identity.get("evidenceBodySha256", "")))
            or not SHA_RE.fullmatch(str(device_identity.get("fileSha256", "")))
        ):
            raise QualificationError("nested_device_evidence_identity_invalid")
    if len(session_identities) < 3:
        raise QualificationError("fewer_than_three_distinct_source_sessions")
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
    }


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
    arguments = parser.parse_args(argv)
    try:
        result = (
            collect_device(arguments.plan, arguments.output)
            if arguments.command == "device"
            else evaluate_field(arguments.plan, arguments.output)
        )
    except (OSError, QualificationError) as exc:
        print(f"qualification error: {exc}", file=sys.stderr)
        return 2
    print(json.dumps({"result": result["result"], "output": str(arguments.output)}))
    return 0 if result["result"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
