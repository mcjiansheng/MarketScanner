"""Invocation and fail-closed validation for the native RTAB-Map SE(2) solver."""

from __future__ import annotations

import hashlib
import json
import math
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
from typing import Any, Sequence

from tools.PriorMap.factor_graph_schema import (
    FactorGraphValidationError,
    validate_factor_graph_result,
)
from tools.PriorMap.factor_graph_quality import DEFAULT_POLICY_PATH, load_quality_policy


FACTOR_GRAPH_ENV = "MARKETSCANNER_FACTOR_GRAPH_BIN"
DEFAULT_ITERATIONS = 100
DEFAULT_EPSILON = 1.0e-6
SAFE_TEXT_RE = re.compile(r"[^\t\r\n]{1,500}")
UNVERIFIED_MANUAL_ANCHOR_MAX_TRANSLATION_M = 5.0
UNVERIFIED_MANUAL_ANCHOR_MAX_YAW_RAD = math.radians(30.0)


class FactorGraphRunnerError(ValueError):
    pass


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def find_factor_graph_binary(explicit: str | Path | None = None) -> Path | None:
    repository = Path(__file__).resolve().parents[2]
    candidates: list[Path] = []
    if explicit:
        candidates.append(Path(explicit).expanduser())
    if os.environ.get(FACTOR_GRAPH_ENV):
        candidates.append(Path(os.environ[FACTOR_GRAPH_ENV]).expanduser())
    candidates.extend(
        repository / relative
        for relative in (
            "build/marketscanner-macos-release/bin/rtabmap-prior-map-factor-graph",
            "build/marketscanner-linux-release/bin/rtabmap-prior-map-factor-graph",
            "build/marketscanner-windows-release/bin/rtabmap-prior-map-factor-graph.exe",
            "build-pc-release/bin/rtabmap-prior-map-factor-graph",
            "build/bin/rtabmap-prior-map-factor-graph",
            "build/tools/Reprocess/rtabmap-prior-map-factor-graph",
            "build/Release/rtabmap-prior-map-factor-graph.exe",
            "build/bin/Release/rtabmap-prior-map-factor-graph.exe",
        )
    )
    discovered = shutil.which("rtabmap-prior-map-factor-graph")
    if discovered:
        candidates.append(Path(discovered))
    for candidate in candidates:
        try:
            resolved = candidate.resolve()
        except OSError:
            continue
        if resolved.is_file() and os.access(resolved, os.X_OK):
            return resolved
    return None


def _normalize_angle(angle: float) -> float:
    return (angle + math.pi) % (2.0 * math.pi) - math.pi


def _select_absolute_priors(
    baseline: Sequence[Any],
    constraints: Sequence[Any],
    *,
    hard_reject_translation_m: float,
    hard_reject_yaw_rad: float,
) -> tuple[list[Any], list[dict[str, Any]]]:
    selected: list[Any] = []
    rejected: list[dict[str, Any]] = []
    for constraint in constraints:
        index = constraint.node_index
        if isinstance(index, bool) or not isinstance(index, int) or not 0 <= index < len(baseline):
            raise FactorGraphRunnerError("Absolute constraint node index is invalid.")
        current = baseline[index]
        translation = math.hypot(constraint.x - current.x, constraint.y - current.y)
        yaw = abs(_normalize_angle(constraint.yaw - current.yaw))
        is_manual_anchor = constraint.kind == "manual_anchor"
        is_initial_map_pose = constraint.kind == "initial_map_pose"
        trusted_manual_anchor = is_manual_anchor and constraint.trusted_absolute
        if is_initial_map_pose:
            # The operator-selected start is the global gauge authority.  It
            # is intentionally not compared with the drifted VIO baseline:
            # that difference is the correction we are solving for.
            exceeds_gate = False
        elif is_manual_anchor and not trusted_manual_anchor:
            exceeds_gate = (
                translation > UNVERIFIED_MANUAL_ANCHOR_MAX_TRANSLATION_M
                or yaw > UNVERIFIED_MANUAL_ANCHOR_MAX_YAW_RAD
            )
        else:
            exceeds_gate = not trusted_manual_anchor and constraint.kind not in {
                "manual_aisle_assignment",
                "road_soft",
            } and (
                translation > hard_reject_translation_m
                or yaw > hard_reject_yaw_rad
            )
        if exceeds_gate:
            rejected.append(
                {
                    "constraint_id": constraint.identifier,
                    "kind": constraint.kind,
                    "translation_residual_m": translation,
                    "yaw_residual_deg": math.degrees(yaw),
                    "reason": (
                        "unverified_manual_anchor_safety_gate"
                        if is_manual_anchor
                        else "factor_graph_robust_hard_gate"
                    ),
                }
            )
            continue
        selected.append(constraint)
    return selected, rejected


def _write_priors(path: Path, input_identity_id: str, baseline: Sequence[Any], constraints: Sequence[Any]) -> None:
    lines = [f"MarketScannerAbsoluteSE2Priors\t2\t{input_identity_id}\n"]
    identifiers: set[str] = set()
    for constraint in constraints:
        identifier = str(constraint.identifier)
        kind = str(constraint.kind)
        if (
            SAFE_TEXT_RE.fullmatch(identifier) is None
            or SAFE_TEXT_RE.fullmatch(kind) is None
            or identifier in identifiers
        ):
            raise FactorGraphRunnerError("Absolute constraint id/kind is invalid or duplicated.")
        identifiers.add(identifier)
        pose = baseline[constraint.node_index]
        explicit_translation = getattr(constraint, "translation_sigma_m", None)
        explicit_yaw = getattr(constraint, "yaw_sigma_rad", None)
        if explicit_translation is None and explicit_yaw is None:
            weight = float(constraint.weight)
            if not math.isfinite(weight) or weight <= 0.0:
                raise FactorGraphRunnerError("Absolute constraint legacy weight is invalid.")
            translation_sigma_m = 1.0 / math.sqrt(weight)
            yaw_sigma_rad = 1.0 / math.sqrt(weight)
        elif explicit_translation is not None and explicit_yaw is not None:
            translation_sigma_m = float(explicit_translation)
            yaw_sigma_rad = float(explicit_yaw)
        else:
            raise FactorGraphRunnerError("Both translation and yaw uncertainty are required.")
        if (
            not math.isfinite(translation_sigma_m)
            or not 1.0e-4 <= translation_sigma_m <= 1000.0
            or not math.isfinite(yaw_sigma_rad)
            or not 1.0e-5 <= yaw_sigma_rad <= math.pi
        ):
            raise FactorGraphRunnerError("Absolute constraint uncertainty is out of range.")
        values = (
            identifier,
            kind,
            str(int(pose.node_id)),
            format(float(constraint.x), ".17g"),
            format(float(constraint.y), ".17g"),
            format(float(constraint.yaw), ".17g"),
            format(translation_sigma_m, ".17g"),
            format(yaw_sigma_rad, ".17g"),
        )
        if any(not math.isfinite(float(value)) for value in values[3:]):
            raise FactorGraphRunnerError("Absolute constraint contains non-finite values.")
        lines.append("\t".join(values) + "\n")
    path.write_text("".join(lines), encoding="utf-8")


def run_relative_se2_factor_graph(
    *,
    binary: Path,
    optimized_database: Path,
    baseline: Sequence[Any],
    constraints: Sequence[Any],
    input_identity_id: str,
    horizontal_axes: str,
    pose_type: type,
    hard_reject_translation_m: float,
    hard_reject_yaw_rad: float,
    quality_policy_path: Path = DEFAULT_POLICY_PATH,
    timeout_seconds: int = 30 * 60,
) -> tuple[list[Any], list[dict[str, Any]], list[dict[str, Any]], dict[str, Any]]:
    if horizontal_axes not in {"xy", "xz", "ios_prior"}:
        raise FactorGraphRunnerError(
            "Factor graph horizontal axes must be xy, xz or ios_prior."
        )
    if not baseline:
        raise FactorGraphRunnerError("Factor graph requires a non-empty trajectory.")
    database = optimized_database.resolve()
    executable = binary.resolve()
    if not database.is_file() or not executable.is_file():
        raise FactorGraphRunnerError("Factor graph binary or optimized database is missing.")
    database_hash = _sha256(database)
    if (
        not math.isfinite(hard_reject_translation_m)
        or hard_reject_translation_m <= 0.0
        or not math.isfinite(hard_reject_yaw_rad)
        or hard_reject_yaw_rad <= 0.0
    ):
        raise FactorGraphRunnerError("Factor graph robust hard gates are invalid.")
    try:
        quality_policy, quality_policy_sha256 = load_quality_policy(quality_policy_path)
    except ValueError as exc:
        raise FactorGraphRunnerError(str(exc)) from exc
    selected, rejected = _select_absolute_priors(
        baseline,
        constraints,
        hard_reject_translation_m=hard_reject_translation_m,
        hard_reject_yaw_rad=hard_reject_yaw_rad,
    )
    limits = quality_policy["limits"]
    try:
        with tempfile.TemporaryDirectory(prefix="marketscanner-factor-graph-") as temporary:
            root = Path(temporary)
            priors = root / "absolute_priors.tsv"
            result_path = root / "factor_graph_result.json"
            _write_priors(priors, input_identity_id, baseline, selected)
            command = [
                str(executable),
                "--database", str(database),
                "--output", str(result_path),
                "--priors", str(priors),
                "--input-identity", input_identity_id,
                "--database-sha256", database_hash,
                "--horizontal-axes", horizontal_axes,
                "--initial-x", format(float(baseline[0].x), ".17g"),
                "--initial-y", format(float(baseline[0].y), ".17g"),
                "--initial-yaw", format(float(baseline[0].yaw), ".17g"),
                "--loop-quarantine-translation-m", format(
                    float(limits["high_residual_loop_translation_m"]), ".17g"
                ),
                "--loop-quarantine-yaw-rad", format(
                    math.radians(float(limits["high_residual_loop_yaw_deg"])), ".17g"
                ),
                "--maximum-quarantined-loop-ratio", format(
                    float(limits["high_residual_loop_ratio_max"]), ".17g"
                ),
                "--iterations", str(DEFAULT_ITERATIONS),
                "--epsilon", format(DEFAULT_EPSILON, ".17g"),
            ]
            completed = subprocess.run(
                command,
                check=False,
                capture_output=True,
                text=True,
                timeout=timeout_seconds,
            )
            try:
                payload = json.loads(
                    result_path.read_text(encoding="utf-8"),
                    parse_constant=lambda value: (_ for _ in ()).throw(
                        ValueError(f"non-finite JSON number: {value}")
                    ),
                )
            except (OSError, UnicodeDecodeError, json.JSONDecodeError, ValueError) as exc:
                detail = (completed.stderr or completed.stdout or "native solver failed").strip()
                raise FactorGraphRunnerError("Native factor graph result is unreadable.") from exc
            if completed.returncode not in {0, 3}:
                detail = (completed.stderr or completed.stdout or "native solver failed").strip()
                raise FactorGraphRunnerError(
                    f"Native relative SE(2) factor graph failed ({completed.returncode}): {detail[-2000:]}"
                )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise FactorGraphRunnerError(f"Native factor graph execution failed: {exc}") from exc
    if _sha256(database) != database_hash:
        raise FactorGraphRunnerError("Optimized database changed during factor graph execution.")
    try:
        report = validate_factor_graph_result(
            payload,
            expected_input_identity_id=input_identity_id,
            expected_database_sha256=database_hash,
            expected_node_ids=(pose.node_id for pose in baseline),
            quality_policy=quality_policy,
            quality_policy_sha256=quality_policy_sha256,
            verified_absolute_gauge_authority=any(
                (
                    constraint.kind == "initial_map_pose"
                    or (
                        constraint.kind == "manual_anchor"
                        and getattr(constraint, "trusted_absolute", False) is True
                    )
                )
                for constraint in selected
            ),
        )
    except FactorGraphValidationError as exc:
        raise FactorGraphRunnerError(str(exc)) from exc
    timestamps = {pose.node_id: pose.timestamp for pose in baseline}
    optimized = [
        pose_type(
            node_id=pose["node_id"],
            timestamp=timestamps[pose["node_id"]],
            x=float(pose["x"]),
            y=float(pose["y"]),
            yaw=_normalize_angle(float(pose["yaw"])),
        )
        for pose in report["poses"]
    ]
    accepted = [
        {
            "constraint_id": constraint.identifier,
            "kind": constraint.kind,
            "node_id": baseline[constraint.node_index].node_id,
            "weight": constraint.weight,
            "translation_sigma_m": (
                float(constraint.translation_sigma_m)
                if getattr(constraint, "translation_sigma_m", None) is not None
                else 1.0 / math.sqrt(float(constraint.weight))
            ),
            "yaw_sigma_rad": (
                float(constraint.yaw_sigma_rad)
                if getattr(constraint, "yaw_sigma_rad", None) is not None
                else 1.0 / math.sqrt(float(constraint.weight))
            ),
            "uncertainty_source": (
                "explicit_v2"
                if getattr(constraint, "translation_sigma_m", None) is not None
                else "legacy_scalar_weight_migration"
            ),
            "trusted_absolute": bool(
                getattr(constraint, "trusted_absolute", False)
            ),
            "translation_residual_m": math.hypot(
                constraint.x - optimized[constraint.node_index].x,
                constraint.y - optimized[constraint.node_index].y,
            ),
            "yaw_residual_deg": math.degrees(
                abs(_normalize_angle(constraint.yaw - optimized[constraint.node_index].yaw))
            ),
        }
        for constraint in selected
    ]
    report = {
        **report,
        "absolute_constraint_count": len(selected),
        "absolute_constraint_rejected_count": len(rejected),
        "absolute_prior_uncertainty_schema": "translation_sigma_m_and_yaw_sigma_rad_v2",
        "verified_absolute_gauge_authority": any(
            constraint.kind == "initial_map_pose"
            or (
                constraint.kind == "manual_anchor"
                and getattr(constraint, "trusted_absolute", False) is True
            )
            for constraint in selected
        ),
        "initial_map_pose_constraint_count": sum(
            constraint.kind == "initial_map_pose" for constraint in selected
        ),
    }
    return optimized, accepted, rejected, report
