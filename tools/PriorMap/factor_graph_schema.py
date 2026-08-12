"""Strict schema validation for the native relative SE(2) factor graph."""

from __future__ import annotations

import hashlib
import math
import re
from typing import Any, Iterable

from tools.PriorMap.factor_graph_quality import (
    FactorGraphQualityError,
    evaluate_graph_quality,
)


RESULT_FORMAT = "MarketScannerRelativeSE2FactorGraphReport"
RESULT_VERSION = 2
SOLVER_NAME = "rtabmap_g2o_slam2d"
SHA256_RE = re.compile(r"[0-9a-f]{64}")


class FactorGraphValidationError(ValueError):
    pass


def _finite(value: Any, field: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise FactorGraphValidationError(f"{field} must be numeric.")
    result = float(value)
    if not math.isfinite(result):
        raise FactorGraphValidationError(f"{field} must be finite.")
    return result


def _positive_int(value: Any, field: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
        raise FactorGraphValidationError(f"{field} must be a positive integer.")
    return value


def _canonical_number(value: Any) -> str:
    return format(_finite(value, "canonical factor value"), ".17g")


def canonical_factor_line(factor: dict[str, Any]) -> str:
    identifier = factor.get("id")
    kind = factor.get("kind")
    if (
        not isinstance(identifier, str)
        or not identifier
        or any(character in identifier for character in "\t\r\n")
        or not isinstance(kind, str)
        or not kind
        or any(character in kind for character in "\t\r\n")
    ):
        raise FactorGraphValidationError("Factor id/kind is not canonical-safe.")
    from_id = _positive_int(factor.get("from_node_id"), "factor from_node_id")
    to_id = _positive_int(factor.get("to_node_id"), "factor to_node_id")
    measurement = factor.get("measurement")
    information = factor.get("planar_information")
    if not isinstance(measurement, list) or len(measurement) != 3:
        raise FactorGraphValidationError("Factor measurement must have three values.")
    if not isinstance(information, list) or len(information) != 9:
        raise FactorGraphValidationError("Factor planar information must have nine values.")
    values = [
        identifier,
        kind,
        str(from_id),
        str(to_id),
        *(_canonical_number(value) for value in measurement),
        *(_canonical_number(value) for value in information),
    ]
    return "\t".join(values) + "\n"


def _validate_positive_definite(information: list[Any]) -> None:
    values = [_finite(value, "planar information") for value in information]
    for row in range(3):
        for column in range(row + 1, 3):
            if not math.isclose(
                values[row * 3 + column],
                values[column * 3 + row],
                rel_tol=1.0e-8,
                abs_tol=1.0e-10,
            ):
                raise FactorGraphValidationError("Planar information is not symmetric.")
    minor_1 = values[0]
    minor_2 = values[0] * values[4] - values[1] * values[3]
    determinant = (
        values[0] * (values[4] * values[8] - values[5] * values[7])
        - values[1] * (values[3] * values[8] - values[5] * values[6])
        + values[2] * (values[3] * values[7] - values[4] * values[6])
    )
    if minor_1 <= 0.0 or minor_2 <= 0.0 or determinant <= 0.0:
        raise FactorGraphValidationError("Planar information is not positive definite.")


def validate_factor_graph_result(
    payload: Any,
    *,
    expected_input_identity_id: str,
    expected_database_sha256: str,
    expected_node_ids: Iterable[int],
    quality_policy: dict[str, Any],
    quality_policy_sha256: str,
    verified_absolute_gauge_authority: bool = False,
) -> dict[str, Any]:
    if not isinstance(payload, dict):
        raise FactorGraphValidationError("Factor graph result must be an object.")
    if payload.get("format") != RESULT_FORMAT or payload.get("version") != RESULT_VERSION:
        raise FactorGraphValidationError("Factor graph format/version is unsupported.")
    if payload.get("solver") != SOLVER_NAME:
        raise FactorGraphValidationError("Factor graph solver identity is unsupported.")
    if not isinstance(payload.get("database_version"), str) or not payload[
        "database_version"
    ].strip():
        raise FactorGraphValidationError("Factor graph database version is missing.")
    if payload.get("input_identity_id") != expected_input_identity_id:
        raise FactorGraphValidationError("Factor graph input identity changed.")
    if payload.get("optimized_database_sha256") != expected_database_sha256:
        raise FactorGraphValidationError("Factor graph database hash changed.")
    if SHA256_RE.fullmatch(str(payload.get("factor_set_sha256") or "")) is None:
        raise FactorGraphValidationError("Factor graph digest is invalid.")

    node_ids = tuple(sorted(set(int(value) for value in expected_node_ids)))
    if not node_ids or any(value <= 0 for value in node_ids):
        raise FactorGraphValidationError("Expected node inventory is invalid.")
    poses = payload.get("poses")
    if not isinstance(poses, list) or len(poses) != len(node_ids):
        raise FactorGraphValidationError("Factor graph pose inventory is incomplete.")
    parsed_pose_ids: list[int] = []
    for pose in poses:
        if not isinstance(pose, dict):
            raise FactorGraphValidationError("Factor graph pose must be an object.")
        parsed_pose_ids.append(_positive_int(pose.get("node_id"), "pose node_id"))
        for field in ("x", "y", "yaw"):
            _finite(pose.get(field), f"pose {field}")
    if tuple(parsed_pose_ids) != node_ids or len(set(parsed_pose_ids)) != len(parsed_pose_ids):
        raise FactorGraphValidationError("Factor graph pose IDs differ from input nodes.")

    factors = payload.get("factors")
    if not isinstance(factors, list) or not factors:
        raise FactorGraphValidationError("Factor graph has no factors.")
    if payload.get("factor_count") != len(factors):
        raise FactorGraphValidationError("Factor graph factor count differs from payload.")
    if payload.get("node_count") != len(node_ids):
        raise FactorGraphValidationError("Factor graph node count differs from payload.")
    factor_ids: set[str] = set()
    actual_factor_counts: dict[str, int] = {}
    relative_adjacency = {node_id: set() for node_id in node_ids}
    canonical_lines: list[tuple[str, str]] = []
    for factor in factors:
        if not isinstance(factor, dict):
            raise FactorGraphValidationError("Factor record must be an object.")
        identifier = factor.get("id")
        if not isinstance(identifier, str) or identifier in factor_ids:
            raise FactorGraphValidationError("Factor IDs must be unique strings.")
        factor_ids.add(identifier)
        kind = factor.get("kind")
        actual_factor_counts[str(kind)] = actual_factor_counts.get(str(kind), 0) + 1
        line = canonical_factor_line(factor)
        if factor.get("canonical") != line:
            raise FactorGraphValidationError("Factor canonical bytes differ from fields.")
        canonical_lines.append((identifier, line))
        _validate_positive_definite(factor["planar_information"])
        from_id = factor["from_node_id"]
        to_id = factor["to_node_id"]
        if from_id not in relative_adjacency or to_id not in relative_adjacency:
            raise FactorGraphValidationError("Factor references a missing node.")
        if str(factor.get("kind", "")).startswith("relative_"):
            if from_id == to_id:
                raise FactorGraphValidationError("Relative factor cannot be self-referential.")
            relative_adjacency[from_id].add(to_id)
            relative_adjacency[to_id].add(from_id)
    digest = hashlib.sha256(
        "".join(line for _, line in sorted(canonical_lines)).encode("utf-8")
    ).hexdigest()
    if digest != payload["factor_set_sha256"]:
        raise FactorGraphValidationError("Factor set digest does not match canonical factors.")
    if payload.get("factor_counts_by_type") != actual_factor_counts:
        raise FactorGraphValidationError("Factor type counts differ from canonical factors.")

    visited = {node_ids[0]}
    pending = [node_ids[0]]
    while pending:
        node_id = pending.pop()
        for neighbor in relative_adjacency[node_id]:
            if neighbor not in visited:
                visited.add(neighbor)
                pending.append(neighbor)
    if visited != set(node_ids):
        raise FactorGraphValidationError("Relative factor graph is disconnected.")

    for field in (
        "initial_objective",
        "final_objective",
        "native_final_error",
        "maximum_pose_update_m",
        "maximum_pose_update_yaw_deg",
        "maximum_relative_edge_translation_residual_m",
        "p95_relative_edge_translation_residual_m",
        "maximum_relative_edge_yaw_residual_deg",
        "p95_relative_edge_yaw_residual_deg",
        "maximum_loop_edge_translation_residual_m",
        "p95_loop_edge_translation_residual_m",
        "maximum_loop_edge_yaw_residual_deg",
        "p95_loop_edge_yaw_residual_deg",
    ):
        if _finite(payload.get(field), field) < 0.0:
            raise FactorGraphValidationError(f"{field} cannot be negative.")
    if (
        payload.get("converged") is not True
        or payload.get("solver_converged") is not True
        or payload.get("graph_integrity_passed") is not True
        or payload.get("full_factor_graph") is not True
        or payload.get("graph_quality_passed") is not False
        or payload.get("published_capable") is not False
        or not isinstance(payload.get("iterations_done"), int)
        or payload["iterations_done"] <= 0
    ):
        raise FactorGraphValidationError("Native factor graph did not pass convergence gates.")
    if payload.get("root_node_id") != node_ids[0]:
        raise FactorGraphValidationError("Factor graph root gauge differs from the first node.")
    if payload.get("graph_connected") is not True:
        raise FactorGraphValidationError("Factor graph did not attest connectivity.")
    gauge_mode = payload.get("gauge_mode")
    if gauge_mode not in {"fixed_root", "absolute_priors"}:
        raise FactorGraphValidationError("Factor graph gauge mode is invalid.")
    for field in ("rejected_factor_ids",):
        values = payload.get(field)
        if not isinstance(values, list) or any(not isinstance(value, str) for value in values):
            raise FactorGraphValidationError(f"{field} must be a string array.")
    collapsed = payload.get("duplicate_reciprocal_collapsed")
    if isinstance(collapsed, bool) or not isinstance(collapsed, int) or collapsed < 0:
        raise FactorGraphValidationError("Duplicate reciprocal count is invalid.")
    rejected_details = payload.get("rejected_factor_details")
    if not isinstance(rejected_details, list):
        raise FactorGraphValidationError("Rejected factor detail inventory is invalid.")
    rejected_ids = set(payload["rejected_factor_ids"])
    detail_ids: set[str] = set()
    for detail in rejected_details:
        if not isinstance(detail, dict):
            raise FactorGraphValidationError("Rejected factor detail must be an object.")
        identifier = detail.get("factor_id")
        if not isinstance(identifier, str) or identifier in detail_ids or identifier not in rejected_ids:
            raise FactorGraphValidationError("Rejected factor detail identity is invalid.")
        detail_ids.add(identifier)
        if not isinstance(detail.get("kind"), str) or not detail["kind"]:
            raise FactorGraphValidationError("Rejected factor detail kind is invalid.")
        _positive_int(detail.get("from_node_id"), "rejected factor from_node_id")
        _positive_int(detail.get("to_node_id"), "rejected factor to_node_id")
        for field in ("translation_residual_m", "yaw_residual_deg"):
            if _finite(detail.get(field), f"rejected factor {field}") < 0.0:
                raise FactorGraphValidationError("Rejected factor residual cannot be negative.")
        if not isinstance(detail.get("reason"), str) or not detail["reason"]:
            raise FactorGraphValidationError("Rejected factor detail reason is invalid.")
    if not detail_ids.issubset(rejected_ids):
        raise FactorGraphValidationError("Rejected factor detail inventory is incomplete.")
    for field in ("quarantined_loop_count", "total_loop_count"):
        value = payload.get(field)
        if isinstance(value, bool) or not isinstance(value, int) or value < 0:
            raise FactorGraphValidationError(f"{field} is invalid.")
    ratio = _finite(payload.get("quarantined_loop_ratio"), "quarantined_loop_ratio")
    if not 0.0 <= ratio <= 1.0:
        raise FactorGraphValidationError("quarantined_loop_ratio is out of range.")
    expected_ratio = payload["quarantined_loop_count"] / max(1, payload["total_loop_count"])
    if not math.isclose(ratio, expected_ratio, rel_tol=1.0e-7, abs_tol=1.0e-9):
        raise FactorGraphValidationError("quarantined loop ratio differs from counts.")
    if payload["quarantined_loop_count"] != len(rejected_details):
        raise FactorGraphValidationError("quarantined loop count differs from details.")
    if any(item.get("kind") != "relative_loop" for item in rejected_details):
        raise FactorGraphValidationError("Only relative loop factors may be quarantined.")
    quarantine_translation = _finite(
        payload.get("loop_quarantine_translation_m"),
        "loop_quarantine_translation_m",
    )
    quarantine_yaw = _finite(
        payload.get("loop_quarantine_yaw_deg"), "loop_quarantine_yaw_deg"
    )
    maximum_quarantine_ratio = _finite(
        payload.get("maximum_quarantined_loop_ratio"),
        "maximum_quarantined_loop_ratio",
    )
    limits = quality_policy.get("limits") if isinstance(quality_policy, dict) else None
    if not isinstance(limits, dict):
        raise FactorGraphValidationError("Factor graph quality policy is invalid.")
    if not math.isclose(
        quarantine_translation,
        float(limits["high_residual_loop_translation_m"]),
        rel_tol=1.0e-7,
        abs_tol=1.0e-9,
    ) or not math.isclose(
        quarantine_yaw,
        float(limits["high_residual_loop_yaw_deg"]),
        rel_tol=1.0e-7,
        abs_tol=1.0e-9,
    ) or not math.isclose(
        maximum_quarantine_ratio,
        float(limits["high_residual_loop_ratio_max"]),
        rel_tol=1.0e-7,
        abs_tol=1.0e-9,
    ):
        raise FactorGraphValidationError("Loop quarantine gates differ from quality policy.")
    if payload.get("quarantine_gate_passed") is not (
        ratio <= maximum_quarantine_ratio
    ):
        raise FactorGraphValidationError("Quarantine gate attestation is invalid.")
    residuals = payload.get("loop_factor_residuals")
    if not isinstance(residuals, list):
        raise FactorGraphValidationError("Loop residual inventory is invalid.")
    loop_ids = {factor["id"] for factor in factors if factor.get("kind") == "relative_loop"}
    seen_residual_ids: set[str] = set()
    for residual in residuals:
        if not isinstance(residual, dict) or not isinstance(residual.get("factor_id"), str):
            raise FactorGraphValidationError("Loop residual record is invalid.")
        identifier = residual["factor_id"]
        if identifier in seen_residual_ids or identifier not in loop_ids:
            raise FactorGraphValidationError("Loop residual factor identity is invalid.")
        seen_residual_ids.add(identifier)
        for field in ("translation_m", "yaw_deg"):
            if _finite(residual.get(field), f"loop residual {field}") < 0.0:
                raise FactorGraphValidationError("Loop residual cannot be negative.")
    if seen_residual_ids != loop_ids:
        raise FactorGraphValidationError("Loop residual inventory is incomplete.")
    loop_translation = sorted(float(item["translation_m"]) for item in residuals)
    loop_yaw = sorted(float(item["yaw_deg"]) for item in residuals)
    def percentile95(values: list[float]) -> float:
        return values[max(0, math.ceil(0.95 * len(values)) - 1)] if values else 0.0
    expected_loop_metrics = {
        "maximum_loop_edge_translation_residual_m": max(loop_translation, default=0.0),
        "p95_loop_edge_translation_residual_m": percentile95(loop_translation),
        "maximum_loop_edge_yaw_residual_deg": max(loop_yaw, default=0.0),
        "p95_loop_edge_yaw_residual_deg": percentile95(loop_yaw),
    }
    if any(
        not math.isclose(float(payload[name]), value, rel_tol=1.0e-7, abs_tol=1.0e-9)
        for name, value in expected_loop_metrics.items()
    ):
        raise FactorGraphValidationError("Loop residual aggregates differ from factor residuals.")
    high_residual_ids = sorted(
        item["factor_id"]
        for item in residuals
        if item["translation_m"] > float(limits["high_residual_loop_translation_m"])
        or item["yaw_deg"] > float(limits["high_residual_loop_yaw_deg"])
    )
    enriched = {
        **payload,
        "high_residual_loop_factor_ids": high_residual_ids,
        "verified_absolute_gauge_authority": bool(
            verified_absolute_gauge_authority
        ),
    }
    try:
        quality = evaluate_graph_quality(enriched, quality_policy, quality_policy_sha256)
    except (FactorGraphQualityError, KeyError, TypeError, ValueError) as exc:
        raise FactorGraphValidationError(str(exc)) from exc
    return {
        **enriched,
        "quality_policy": quality,
        "graph_quality_passed": quality["passed"],
        "published_capable": (
            payload["solver_converged"] is True
            and payload["graph_integrity_passed"] is True
            and quality["passed"] is True
        ),
    }
