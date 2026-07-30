"""Versioned product-quality policy for relative SE(2) factor graphs."""

from __future__ import annotations

import hashlib
import json
import math
from pathlib import Path
import re
from typing import Any


POLICY_FORMAT = "MarketScannerFactorGraphQualityPolicy"
POLICY_VERSION = 1
DEFAULT_POLICY_PATH = Path(__file__).with_name("factor_graph_quality_policy.json")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")


class FactorGraphQualityError(ValueError):
    pass


def _number(value: Any, name: str, *, minimum: float = 0.0) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise FactorGraphQualityError(f"quality policy {name} must be numeric")
    result = float(value)
    if not math.isfinite(result) or result < minimum:
        raise FactorGraphQualityError(f"quality policy {name} is out of range")
    return result


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_quality_policy(path: Path = DEFAULT_POLICY_PATH) -> tuple[dict[str, Any], str]:
    try:
        raw = path.read_bytes()
        value = json.loads(raw)
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise FactorGraphQualityError("factor graph quality policy is unreadable") from exc
    if (
        not isinstance(value, dict)
        or value.get("format") != POLICY_FORMAT
        or value.get("version") != POLICY_VERSION
        or value.get("status") not in {"candidate", "frozen"}
        or not isinstance(value.get("policy_version"), str)
        or not value["policy_version"].strip()
    ):
        raise FactorGraphQualityError("factor graph quality policy identity is invalid")
    limits = value.get("limits")
    if not isinstance(limits, dict):
        raise FactorGraphQualityError("factor graph quality policy limits are missing")
    required = (
        "relative_translation_p95_max_m",
        "relative_translation_max_m",
        "relative_yaw_p95_max_deg",
        "relative_yaw_max_deg",
        "loop_translation_p95_max_m",
        "loop_translation_max_m",
        "loop_yaw_p95_max_deg",
        "loop_yaw_max_deg",
        "high_residual_loop_ratio_max",
        "maximum_pose_update_m",
        "maximum_pose_update_yaw_deg",
        "minimum_relative_factor_to_node_ratio",
        "minimum_objective_improvement_ratio",
    )
    for name in required:
        _number(limits.get(name), name)
    for name in (
        "high_residual_loop_translation_m",
        "high_residual_loop_yaw_deg",
    ):
        _number(limits.get(name), name, minimum=1.0e-12)
    if not 0.0 <= float(limits["high_residual_loop_ratio_max"]) <= 1.0:
        raise FactorGraphQualityError("high residual loop ratio must be within [0, 1]")
    if not 0.0 <= float(limits["minimum_objective_improvement_ratio"]) <= 1.0:
        raise FactorGraphQualityError("objective improvement ratio must be within [0, 1]")
    return value, hashlib.sha256(raw).hexdigest()


def evaluate_graph_quality(
    report: dict[str, Any],
    policy: dict[str, Any],
    policy_sha256: str,
) -> dict[str, Any]:
    if not SHA256_RE.fullmatch(policy_sha256):
        raise FactorGraphQualityError("quality policy SHA-256 is invalid")
    limits = policy["limits"]
    factor_counts = report.get("factor_counts_by_type")
    if not isinstance(factor_counts, dict):
        raise FactorGraphQualityError("factor type counts are missing")
    relative_count = sum(
        int(value)
        for name, value in factor_counts.items()
        if isinstance(name, str)
        and name.startswith("relative_")
        and isinstance(value, int)
        and not isinstance(value, bool)
        and value >= 0
    )
    node_count = report.get("node_count")
    loop_count = int(factor_counts.get("relative_loop", 0))
    high_residual = report.get("high_residual_loop_factor_ids")
    if (
        not isinstance(node_count, int)
        or isinstance(node_count, bool)
        or node_count <= 0
        or not isinstance(high_residual, list)
        or any(not isinstance(item, str) for item in high_residual)
    ):
        raise FactorGraphQualityError("factor inventory for quality evaluation is invalid")
    initial = _number(report.get("initial_objective"), "initial_objective")
    final = _number(report.get("final_objective"), "final_objective")
    objective_improvement_ratio = (
        max(0.0, (initial - final) / initial) if initial > 0.0 else (1.0 if final == 0.0 else 0.0)
    )
    ratio = len(high_residual) / max(1, loop_count)
    checks = (
        (report.get("solver_converged") is True, "solver_not_converged", report.get("solver_converged")),
        (report.get("graph_integrity_passed") is True, "graph_integrity_failed", report.get("graph_integrity_passed")),
        (float(report["p95_relative_edge_translation_residual_m"]) <= float(limits["relative_translation_p95_max_m"]), "relative_translation_p95_exceeded", report["p95_relative_edge_translation_residual_m"]),
        (float(report["maximum_relative_edge_translation_residual_m"]) <= float(limits["relative_translation_max_m"]), "relative_translation_max_exceeded", report["maximum_relative_edge_translation_residual_m"]),
        (float(report["p95_relative_edge_yaw_residual_deg"]) <= float(limits["relative_yaw_p95_max_deg"]), "relative_yaw_p95_exceeded", report["p95_relative_edge_yaw_residual_deg"]),
        (float(report["maximum_relative_edge_yaw_residual_deg"]) <= float(limits["relative_yaw_max_deg"]), "relative_yaw_max_exceeded", report["maximum_relative_edge_yaw_residual_deg"]),
        (float(report["p95_loop_edge_translation_residual_m"]) <= float(limits["loop_translation_p95_max_m"]), "loop_translation_p95_exceeded", report["p95_loop_edge_translation_residual_m"]),
        (float(report["maximum_loop_edge_translation_residual_m"]) <= float(limits["loop_translation_max_m"]), "loop_translation_max_exceeded", report["maximum_loop_edge_translation_residual_m"]),
        (float(report["p95_loop_edge_yaw_residual_deg"]) <= float(limits["loop_yaw_p95_max_deg"]), "loop_yaw_p95_exceeded", report["p95_loop_edge_yaw_residual_deg"]),
        (float(report["maximum_loop_edge_yaw_residual_deg"]) <= float(limits["loop_yaw_max_deg"]), "loop_yaw_max_exceeded", report["maximum_loop_edge_yaw_residual_deg"]),
        (ratio <= float(limits["high_residual_loop_ratio_max"]), "high_residual_loop_ratio_exceeded", ratio),
        (float(report["maximum_pose_update_m"]) <= float(limits["maximum_pose_update_m"]), "maximum_pose_update_exceeded", report["maximum_pose_update_m"]),
        (float(report["maximum_pose_update_yaw_deg"]) <= float(limits["maximum_pose_update_yaw_deg"]), "maximum_pose_yaw_update_exceeded", report["maximum_pose_update_yaw_deg"]),
        (relative_count / node_count >= float(limits["minimum_relative_factor_to_node_ratio"]), "relative_factor_coverage_too_low", relative_count / node_count),
        (objective_improvement_ratio >= float(limits["minimum_objective_improvement_ratio"]), "objective_improvement_too_low", objective_improvement_ratio),
    )
    blockers = [
        {"code": code, "value": value}
        for passed, code, value in checks
        if not passed
    ]
    policy_frozen = policy.get("status") == "frozen"
    if not policy_frozen:
        blockers.insert(0, {"code": "factor_graph_quality_policy_not_frozen", "value": policy.get("status")})
    return {
        "policy_format": policy["format"],
        "policy_version": policy["policy_version"],
        "policy_status": policy["status"],
        "policy_sha256": policy_sha256,
        "objective_improvement_ratio": objective_improvement_ratio,
        "high_residual_loop_ratio": ratio,
        "passed": policy_frozen and not blockers,
        "blockers": blockers,
    }
