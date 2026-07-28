"""Strict schema validation for the native relative SE(2) factor graph."""

from __future__ import annotations

import hashlib
import math
import re
from typing import Any, Iterable


RESULT_FORMAT = "MarketScannerRelativeSE2FactorGraphReport"
RESULT_VERSION = 1
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
    relative_adjacency = {node_id: set() for node_id in node_ids}
    canonical_lines: list[tuple[str, str]] = []
    for factor in factors:
        if not isinstance(factor, dict):
            raise FactorGraphValidationError("Factor record must be an object.")
        identifier = factor.get("id")
        if not isinstance(identifier, str) or identifier in factor_ids:
            raise FactorGraphValidationError("Factor IDs must be unique strings.")
        factor_ids.add(identifier)
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
    ):
        if _finite(payload.get(field), field) < 0.0:
            raise FactorGraphValidationError(f"{field} cannot be negative.")
    if (
        payload.get("converged") is not True
        or payload.get("full_factor_graph") is not True
        or payload.get("published_capable") is not True
        or payload["final_objective"] > payload["initial_objective"] * (1.0 + 1.0e-7)
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
    for field in ("downweighted_factor_ids", "rejected_factor_ids"):
        values = payload.get(field)
        if not isinstance(values, list) or any(not isinstance(value, str) for value in values):
            raise FactorGraphValidationError(f"{field} must be a string array.")
    return payload
