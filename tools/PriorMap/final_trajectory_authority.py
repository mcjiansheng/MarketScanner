"""Canonical authority for the exact final localized SE(2) trajectory.

The native helper proves a canonical factor inventory and its own optimized
poses.  Stage 3 may subsequently apply the corridor/free-space envelope to
the trajectory.  This module re-evaluates the *final exported poses* against
that same factor inventory so publication never relies on residuals measured
on a different trajectory.
"""

from __future__ import annotations

import hashlib
import json
import math
import re
from typing import Any, Iterable, Sequence

from tools.PriorMap.factor_graph_schema import (
    FactorGraphValidationError,
    canonical_factor_line,
)


AUTHORITY_FORMAT = "MarketScannerFinalTrajectoryFactorAuthority"
AUTHORITY_VERSION = 1
PROCESSING_CONTRACT_VERSION = 3
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
SHELF_FACE_NORMAL_RESIDUAL_LIMIT_M = 0.50


class FinalTrajectoryAuthorityError(ValueError):
    pass


def _finite(value: Any, field: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise FinalTrajectoryAuthorityError(f"{field} must be numeric.")
    result = float(value)
    if not math.isfinite(result):
        raise FinalTrajectoryAuthorityError(f"{field} must be finite.")
    return result


def _positive_int(value: Any, field: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
        raise FinalTrajectoryAuthorityError(f"{field} must be a positive integer.")
    return value


def normalize_angle(value: float) -> float:
    result = _finite(value, "trajectory yaw")
    result = math.fmod(result, 2.0 * math.pi)
    if result > math.pi:
        result -= 2.0 * math.pi
    elif result <= -math.pi:
        result += 2.0 * math.pi
    return result


def _pose_value(pose: Any, field: str) -> Any:
    if isinstance(pose, dict):
        return pose.get(field)
    return getattr(pose, field, None)


def canonical_trajectory_records(
    poses: Sequence[Any] | Iterable[Any],
) -> tuple[list[dict[str, Any]], bytes]:
    records: list[dict[str, Any]] = []
    lines: list[str] = []
    previous_node_id = 0
    for pose in poses:
        node_id = _positive_int(_pose_value(pose, "node_id"), "trajectory node_id")
        if node_id <= previous_node_id:
            raise FinalTrajectoryAuthorityError(
                "Trajectory node IDs must be unique and strictly increasing."
            )
        x = _finite(_pose_value(pose, "x"), "trajectory x")
        y = _finite(_pose_value(pose, "y"), "trajectory y")
        yaw = normalize_angle(_pose_value(pose, "yaw"))
        records.append({"node_id": node_id, "x": x, "y": y, "yaw": yaw})
        lines.append(
            "\t".join(
                (
                    str(node_id),
                    format(x, ".17g"),
                    format(y, ".17g"),
                    format(yaw, ".17g"),
                )
            )
            + "\n"
        )
        previous_node_id = node_id
    if not records:
        raise FinalTrajectoryAuthorityError("Final trajectory is empty.")
    return records, "".join(lines).encode("utf-8")


def trajectory_sha256(poses: Sequence[Any] | Iterable[Any]) -> str:
    _, canonical = canonical_trajectory_records(poses)
    return hashlib.sha256(canonical).hexdigest()


def _percentile95(values: Sequence[float]) -> float:
    ordered = sorted(values)
    if not ordered:
        return 0.0
    return ordered[max(0, math.ceil(0.95 * len(ordered)) - 1)]


def _se2_error(
    measurement: Sequence[Any], predicted: tuple[float, float, float]
) -> tuple[float, float, float]:
    if len(measurement) != 3:
        raise FinalTrajectoryAuthorityError("Factor measurement must have three values.")
    mx, my, myaw = (
        _finite(measurement[0], "factor measurement x"),
        _finite(measurement[1], "factor measurement y"),
        normalize_angle(measurement[2]),
    )
    px, py, pyaw = predicted
    dx = px - mx
    dy = py - my
    cosine = math.cos(myaw)
    sine = math.sin(myaw)
    return (
        cosine * dx + sine * dy,
        -sine * dx + cosine * dy,
        normalize_angle(pyaw - myaw),
    )


def _relative_pose(
    source: dict[str, Any], target: dict[str, Any]
) -> tuple[float, float, float]:
    dx = target["x"] - source["x"]
    dy = target["y"] - source["y"]
    cosine = math.cos(source["yaw"])
    sine = math.sin(source["yaw"])
    return (
        cosine * dx + sine * dy,
        -sine * dx + cosine * dy,
        normalize_angle(target["yaw"] - source["yaw"]),
    )


def _weighted_objective(error: tuple[float, float, float], information: Any) -> float:
    if not isinstance(information, list) or len(information) != 9:
        raise FinalTrajectoryAuthorityError(
            "Factor planar information must have nine values."
        )
    matrix = [_finite(value, "factor planar information") for value in information]
    weighted = sum(
        error[row] * matrix[row * 3 + column] * error[column]
        for row in range(3)
        for column in range(3)
    )
    if not math.isfinite(weighted) or weighted < -1.0e-9:
        raise FinalTrajectoryAuthorityError("Factor objective is invalid.")
    return max(0.0, weighted)


def _shelf_face_normal_residual(
    pose: dict[str, Any], measurement: Sequence[Any], information: Any
) -> float:
    """Recover the shelf-normal axis from the anisotropic prior information."""

    if len(measurement) != 3 or not isinstance(information, list) or len(information) != 9:
        raise FinalTrajectoryAuthorityError("Shelf-face factor is invalid.")
    xx = _finite(information[0], "shelf-face information xx")
    xy = 0.5 * (
        _finite(information[1], "shelf-face information xy")
        + _finite(information[3], "shelf-face information yx")
    )
    yy = _finite(information[4], "shelf-face information yy")
    # Principal eigenvector of the 2x2 translation-information matrix.  V3
    # shelf priors make this the normal axis; isotropic legacy priors fall back
    # to the conservative full translation residual.
    discriminant = math.hypot(xx - yy, 2.0 * xy)
    dx = pose["x"] - _finite(measurement[0], "shelf-face measurement x")
    dy = pose["y"] - _finite(measurement[1], "shelf-face measurement y")
    if discriminant <= 1.0e-12 * max(1.0, abs(xx), abs(yy)):
        return math.hypot(dx, dy)
    eigenvalue = 0.5 * (xx + yy + discriminant)
    # Both expressions below are valid eigenvectors for the principal
    # eigenvalue.  Choose the one with the larger norm so axis-aligned
    # matrices remain well-conditioned in both directions.  In particular,
    # [[weak, 0], [0, normal]] must select (0, normal-weak), not the zero
    # vector produced by (normal-normal, 0).
    first = (xy, eigenvalue - xx)
    second = (eigenvalue - yy, xy)
    nx, ny = (
        first
        if math.hypot(*first) >= math.hypot(*second)
        else second
    )
    length = math.hypot(nx, ny)
    if length <= 0.0 or not math.isfinite(length):
        raise FinalTrajectoryAuthorityError("Shelf-face normal axis is invalid.")
    return abs(dx * nx / length + dy * ny / length)


def _metrics(translation: Sequence[float], yaw_deg: Sequence[float]) -> dict[str, Any]:
    return {
        "count": len(translation),
        "maximum_translation_residual_m": max(translation, default=0.0),
        "p95_translation_residual_m": _percentile95(translation),
        "maximum_yaw_residual_deg": max(yaw_deg, default=0.0),
        "p95_yaw_residual_deg": _percentile95(yaw_deg),
    }


def _bound_quality_policy(
    factor_graph_report: dict[str, Any], quality: dict[str, Any]
) -> dict[str, Any]:
    document = factor_graph_report.get("quality_policy_document")
    policy_sha256 = quality.get("policy_sha256")
    if (
        not isinstance(document, str)
        or SHA256_RE.fullmatch(str(policy_sha256 or "")) is None
        or hashlib.sha256(document.encode("utf-8")).hexdigest() != policy_sha256
    ):
        raise FinalTrajectoryAuthorityError(
            "Quality policy document does not match its release SHA-256."
        )
    try:
        policy = json.loads(
            document,
            parse_constant=lambda value: (_ for _ in ()).throw(
                ValueError(f"non-finite JSON number: {value}")
            ),
        )
    except (json.JSONDecodeError, ValueError) as exc:
        raise FinalTrajectoryAuthorityError(
            "Quality policy document is invalid."
        ) from exc
    limits = policy.get("limits") if isinstance(policy, dict) else None
    if (
        not isinstance(limits, dict)
        or limits != factor_graph_report.get("quality_policy_limits")
        or policy.get("format") != quality.get("policy_format")
        or policy.get("policy_version") != quality.get("policy_version")
        or policy.get("status") != quality.get("policy_status")
    ):
        raise FinalTrajectoryAuthorityError(
            "Quality policy document differs from the validated factor report."
        )
    return limits


def _failed_authority(
    poses: Sequence[Any] | Iterable[Any],
    factor_graph_report: Any,
    *,
    post_solver: str,
    blocker: dict[str, Any],
) -> dict[str, Any]:
    try:
        records, canonical = canonical_trajectory_records(poses)
        digest = hashlib.sha256(canonical).hexdigest()
        node_count = len(records)
    except FinalTrajectoryAuthorityError as exc:
        digest = None
        node_count = 0
        blocker = {"code": "final_trajectory_invalid", "value": str(exc)}
    factor_set_sha256 = (
        factor_graph_report.get("factor_set_sha256")
        if isinstance(factor_graph_report, dict)
        and SHA256_RE.fullmatch(str(factor_graph_report.get("factor_set_sha256") or ""))
        else None
    )
    return {
        "format": AUTHORITY_FORMAT,
        "version": AUTHORITY_VERSION,
        "passed": False,
        "trajectory_sha256": digest,
        "node_count": node_count,
        "factor_set_sha256": factor_set_sha256,
        "post_solver": post_solver,
        "trajectory_changed_after_native_solver": None,
        "native_trajectory_sha256": None,
        "factor_objective": None,
        "objective_improvement_ratio": None,
        "relative_factor_metrics": {},
        "loop_factor_metrics": {},
        "absolute_factor_metrics": {},
        "shelf_face_factor_metrics": {},
        "high_residual_loop_factor_ids": [],
        "high_residual_loop_ratio": None,
        "checks": [],
        "blockers": [blocker],
    }


def attest_final_trajectory(
    factor_graph_report: Any,
    poses: Sequence[Any] | Iterable[Any],
    *,
    post_solver: str,
) -> dict[str, Any]:
    """Recompute factor residuals and quality gates on the exact final poses.

    Invalid or unavailable native evidence produces a bound, non-publishable
    authority record instead of preventing recovery/draft artifact export.
    """

    pose_list = list(poses)
    if not isinstance(post_solver, str) or not post_solver.strip():
        raise FinalTrajectoryAuthorityError("Final trajectory post-solver is invalid.")
    if not isinstance(factor_graph_report, dict):
        return _failed_authority(
            pose_list,
            factor_graph_report,
            post_solver=post_solver,
            blocker={"code": "native_factor_graph_report_unavailable", "value": None},
        )
    factors = factor_graph_report.get("factors")
    quality = factor_graph_report.get("quality_policy")
    native_poses = factor_graph_report.get("poses")
    if (
        not isinstance(factors, list)
        or not factors
        or not isinstance(quality, dict)
        or not isinstance(native_poses, list)
    ):
        return _failed_authority(
            pose_list,
            factor_graph_report,
            post_solver=post_solver,
            blocker={
                "code": "native_factor_graph_evidence_incomplete",
                "value": None,
            },
        )
    try:
        limits = _bound_quality_policy(factor_graph_report, quality)
        records, canonical = canonical_trajectory_records(pose_list)
        native_records, native_canonical = canonical_trajectory_records(native_poses)
        pose_by_id = {record["node_id"]: record for record in records}
        node_ids = [record["node_id"] for record in records]
        native_node_ids = [record["node_id"] for record in native_records]
        canonical_factor_lines: list[tuple[str, str]] = []
        factor_ids: set[str] = set()
        relative_translation: list[float] = []
        relative_yaw: list[float] = []
        loop_translation: list[float] = []
        loop_yaw: list[float] = []
        absolute_translation: list[float] = []
        absolute_yaw: list[float] = []
        shelf_translation: list[float] = []
        shelf_yaw: list[float] = []
        high_residual_loop_ids: list[str] = []
        factor_objective = 0.0
        factor_counts: dict[str, int] = {}
        for factor in factors:
            if not isinstance(factor, dict):
                raise FinalTrajectoryAuthorityError("Factor record must be an object.")
            identifier = factor.get("id")
            kind = factor.get("kind")
            if not isinstance(identifier, str) or identifier in factor_ids:
                raise FinalTrajectoryAuthorityError("Factor IDs must be unique strings.")
            if not isinstance(kind, str) or not kind:
                raise FinalTrajectoryAuthorityError("Factor kind is invalid.")
            factor_ids.add(identifier)
            try:
                canonical_line = canonical_factor_line(factor)
            except FactorGraphValidationError as exc:
                raise FinalTrajectoryAuthorityError(str(exc)) from exc
            if factor.get("canonical") != canonical_line:
                raise FinalTrajectoryAuthorityError(
                    "Factor canonical bytes differ from fields."
                )
            canonical_factor_lines.append((identifier, canonical_line))
            from_id = _positive_int(factor.get("from_node_id"), "factor from_node_id")
            to_id = _positive_int(factor.get("to_node_id"), "factor to_node_id")
            if from_id not in pose_by_id or to_id not in pose_by_id:
                raise FinalTrajectoryAuthorityError(
                    "Factor references a missing final trajectory node."
                )
            factor_counts[kind] = factor_counts.get(kind, 0) + 1
            if from_id == to_id:
                pose = pose_by_id[from_id]
                predicted = (pose["x"], pose["y"], pose["yaw"])
            elif kind.startswith("relative_"):
                predicted = _relative_pose(pose_by_id[from_id], pose_by_id[to_id])
            else:
                raise FinalTrajectoryAuthorityError(
                    "Non-relative factor cannot reference two different nodes."
                )
            measurement = factor.get("measurement")
            if not isinstance(measurement, list):
                raise FinalTrajectoryAuthorityError("Factor measurement is invalid.")
            error = _se2_error(measurement, predicted)
            translation = math.hypot(error[0], error[1])
            yaw_deg = abs(math.degrees(error[2]))
            factor_objective += _weighted_objective(
                error, factor.get("planar_information")
            )
            if from_id != to_id:
                relative_translation.append(translation)
                relative_yaw.append(yaw_deg)
                if kind == "relative_loop":
                    loop_translation.append(translation)
                    loop_yaw.append(yaw_deg)
                    if (
                        translation
                        > _finite(
                            limits.get("high_residual_loop_translation_m"),
                            "high residual loop translation limit",
                        )
                        or yaw_deg
                        > _finite(
                            limits.get("high_residual_loop_yaw_deg"),
                            "high residual loop yaw limit",
                        )
                    ):
                        high_residual_loop_ids.append(identifier)
            else:
                absolute_translation.append(translation)
                absolute_yaw.append(yaw_deg)
                if kind == "shelf_face":
                    shelf_translation.append(
                        _shelf_face_normal_residual(
                            pose_by_id[from_id],
                            measurement,
                            factor.get("planar_information"),
                        )
                    )
                    shelf_yaw.append(yaw_deg)

        factor_digest = hashlib.sha256(
            "".join(
                line for _, line in sorted(canonical_factor_lines)
            ).encode("utf-8")
        ).hexdigest()
        trajectory_digest = hashlib.sha256(canonical).hexdigest()
        native_trajectory_digest = hashlib.sha256(native_canonical).hexdigest()
        relative_metrics = _metrics(relative_translation, relative_yaw)
        loop_metrics = _metrics(loop_translation, loop_yaw)
        absolute_metrics = _metrics(absolute_translation, absolute_yaw)
        shelf_metrics = _metrics(shelf_translation, shelf_yaw)
        relative_count = sum(
            count for kind, count in factor_counts.items() if kind.startswith("relative_")
        )
        high_residual_ratio = len(high_residual_loop_ids) / max(1, len(loop_translation))
        initial_objective = _finite(
            factor_graph_report.get("initial_objective"), "initial factor objective"
        )
        objective_improvement_ratio = (
            (initial_objective - factor_objective) / initial_objective
            if initial_objective > 0.0
            else (1.0 if factor_objective == 0.0 else -1.0)
        )

        checks = [
            {
                "code": "native_factor_graph_publish_capable",
                "passed": factor_graph_report.get(
                    "native_published_capable",
                    factor_graph_report.get("published_capable"),
                )
                is True,
                "value": factor_graph_report.get(
                    "native_published_capable",
                    factor_graph_report.get("published_capable"),
                ),
                "limit": True,
            },
            {
                "code": "quality_policy_frozen_and_passed",
                "passed": quality.get("policy_status") == "frozen"
                and quality.get("passed") is True,
                "value": {
                    "policy_status": quality.get("policy_status"),
                    "passed": quality.get("passed"),
                },
                "limit": {"policy_status": "frozen", "passed": True},
            },
            {
                "code": "final_node_inventory_matches_native",
                "passed": node_ids == native_node_ids
                and factor_graph_report.get("node_count") == len(node_ids),
                "value": node_ids,
                "limit": native_node_ids,
            },
            {
                "code": "canonical_factor_set_matches_native_digest",
                "passed": factor_digest == factor_graph_report.get("factor_set_sha256")
                and factor_graph_report.get("factor_count") == len(factors),
                "value": factor_digest,
                "limit": factor_graph_report.get("factor_set_sha256"),
            },
            {
                "code": "relative_translation_p95_within_policy",
                "passed": relative_metrics["p95_translation_residual_m"]
                <= _finite(
                    limits.get("relative_translation_p95_max_m"),
                    "relative translation p95 limit",
                ),
                "value": relative_metrics["p95_translation_residual_m"],
                "limit": float(limits["relative_translation_p95_max_m"]),
            },
            {
                "code": "relative_translation_max_within_policy",
                "passed": relative_metrics["maximum_translation_residual_m"]
                <= _finite(
                    limits.get("relative_translation_max_m"),
                    "relative translation maximum limit",
                ),
                "value": relative_metrics["maximum_translation_residual_m"],
                "limit": float(limits["relative_translation_max_m"]),
            },
            {
                "code": "relative_yaw_p95_within_policy",
                "passed": relative_metrics["p95_yaw_residual_deg"]
                <= _finite(
                    limits.get("relative_yaw_p95_max_deg"),
                    "relative yaw p95 limit",
                ),
                "value": relative_metrics["p95_yaw_residual_deg"],
                "limit": float(limits["relative_yaw_p95_max_deg"]),
            },
            {
                "code": "relative_yaw_max_within_policy",
                "passed": relative_metrics["maximum_yaw_residual_deg"]
                <= _finite(
                    limits.get("relative_yaw_max_deg"),
                    "relative yaw maximum limit",
                ),
                "value": relative_metrics["maximum_yaw_residual_deg"],
                "limit": float(limits["relative_yaw_max_deg"]),
            },
            {
                "code": "loop_translation_p95_within_policy",
                "passed": loop_metrics["p95_translation_residual_m"]
                <= _finite(
                    limits.get("loop_translation_p95_max_m"),
                    "loop translation p95 limit",
                ),
                "value": loop_metrics["p95_translation_residual_m"],
                "limit": float(limits["loop_translation_p95_max_m"]),
            },
            {
                "code": "loop_translation_max_within_policy",
                "passed": loop_metrics["maximum_translation_residual_m"]
                <= _finite(
                    limits.get("loop_translation_max_m"),
                    "loop translation maximum limit",
                ),
                "value": loop_metrics["maximum_translation_residual_m"],
                "limit": float(limits["loop_translation_max_m"]),
            },
            {
                "code": "loop_yaw_p95_within_policy",
                "passed": loop_metrics["p95_yaw_residual_deg"]
                <= _finite(
                    limits.get("loop_yaw_p95_max_deg"),
                    "loop yaw p95 limit",
                ),
                "value": loop_metrics["p95_yaw_residual_deg"],
                "limit": float(limits["loop_yaw_p95_max_deg"]),
            },
            {
                "code": "loop_yaw_max_within_policy",
                "passed": loop_metrics["maximum_yaw_residual_deg"]
                <= _finite(
                    limits.get("loop_yaw_max_deg"),
                    "loop yaw maximum limit",
                ),
                "value": loop_metrics["maximum_yaw_residual_deg"],
                "limit": float(limits["loop_yaw_max_deg"]),
            },
            {
                "code": "high_residual_loop_ratio_within_policy",
                "passed": high_residual_ratio
                <= _finite(
                    limits.get("high_residual_loop_ratio_max"),
                    "high residual loop ratio limit",
                ),
                "value": high_residual_ratio,
                "limit": float(limits["high_residual_loop_ratio_max"]),
            },
            {
                "code": "relative_factor_coverage_within_policy",
                "passed": relative_count / len(records)
                >= _finite(
                    limits.get("minimum_relative_factor_to_node_ratio"),
                    "minimum relative factor coverage",
                ),
                "value": relative_count / len(records),
                "limit": float(limits["minimum_relative_factor_to_node_ratio"]),
            },
            {
                "code": "objective_improvement_within_policy",
                "passed": objective_improvement_ratio
                >= _finite(
                    limits.get("minimum_objective_improvement_ratio"),
                    "minimum objective improvement",
                ),
                "value": objective_improvement_ratio,
                "limit": float(limits["minimum_objective_improvement_ratio"]),
            },
            {
                "code": "shelf_face_normal_residual_within_existing_gate",
                "passed": shelf_metrics["maximum_translation_residual_m"]
                <= SHELF_FACE_NORMAL_RESIDUAL_LIMIT_M,
                "value": shelf_metrics["maximum_translation_residual_m"],
                "limit": SHELF_FACE_NORMAL_RESIDUAL_LIMIT_M,
            },
        ]
        blockers = [
            {"code": item["code"], "value": item["value"], "limit": item["limit"]}
            for item in checks
            if item["passed"] is not True
        ]
        return {
            "format": AUTHORITY_FORMAT,
            "version": AUTHORITY_VERSION,
            "passed": not blockers,
            "trajectory_sha256": trajectory_digest,
            "node_count": len(records),
            "factor_set_sha256": factor_digest,
            "post_solver": post_solver,
            "trajectory_changed_after_native_solver": (
                trajectory_digest != native_trajectory_digest
            ),
            "native_trajectory_sha256": native_trajectory_digest,
            "factor_objective": factor_objective,
            "objective_improvement_ratio": objective_improvement_ratio,
            "relative_factor_metrics": relative_metrics,
            "loop_factor_metrics": loop_metrics,
            "absolute_factor_metrics": absolute_metrics,
            "shelf_face_factor_metrics": shelf_metrics,
            "high_residual_loop_factor_ids": sorted(high_residual_loop_ids),
            "high_residual_loop_ratio": high_residual_ratio,
            "checks": checks,
            "blockers": blockers,
        }
    except (FinalTrajectoryAuthorityError, KeyError, TypeError, ValueError) as exc:
        return _failed_authority(
            pose_list,
            factor_graph_report,
            post_solver=post_solver,
            blocker={"code": "final_factor_recalculation_failed", "value": str(exc)},
        )


def poses_from_trajectory_geojson(payload: Any) -> list[dict[str, Any]]:
    if not isinstance(payload, dict) or payload.get("type") != "FeatureCollection":
        raise FinalTrajectoryAuthorityError(
            "Final trajectory GeoJSON is not a FeatureCollection."
        )
    features = payload.get("features")
    if not isinstance(features, list):
        raise FinalTrajectoryAuthorityError("Final trajectory features are invalid.")
    matches = [
        feature
        for feature in features
        if isinstance(feature, dict)
        and isinstance(feature.get("properties"), dict)
        and feature["properties"].get("layer") == "prior_map_offline_optimized"
    ]
    if len(matches) != 1:
        raise FinalTrajectoryAuthorityError(
            "Final trajectory must contain exactly one optimized layer."
        )
    feature = matches[0]
    properties = feature["properties"]
    geometry = feature.get("geometry")
    if not isinstance(geometry, dict) or geometry.get("type") != "LineString":
        raise FinalTrajectoryAuthorityError("Final trajectory geometry is invalid.")
    node_ids = properties.get("node_ids")
    yaws = properties.get("yaws_rad")
    coordinates = geometry.get("coordinates")
    if (
        not isinstance(node_ids, list)
        or not isinstance(yaws, list)
        or not isinstance(coordinates, list)
        or not len(node_ids) == len(yaws) == len(coordinates)
        or not node_ids
    ):
        raise FinalTrajectoryAuthorityError(
            "Final trajectory coordinate, node and yaw inventories differ."
        )
    poses: list[dict[str, Any]] = []
    for node_id, yaw, coordinate in zip(node_ids, yaws, coordinates):
        if not isinstance(coordinate, list) or len(coordinate) != 2:
            raise FinalTrajectoryAuthorityError(
                "Final trajectory coordinate must contain x and y."
            )
        poses.append(
            {
                "node_id": node_id,
                "x": coordinate[0],
                "y": coordinate[1],
                "yaw": yaw,
            }
        )
    canonical_trajectory_records(poses)
    return poses


def validate_final_trajectory_bindings(
    *,
    trajectory_geojson: Any,
    factor_graph_report: Any,
    localization_report: Any,
    processing_manifest: Any,
    require_passed: bool = False,
) -> dict[str, Any]:
    """Validate v3 cross-artifact bindings and recompute passed authorities."""

    if not all(
        isinstance(value, dict)
        for value in (
            trajectory_geojson,
            factor_graph_report,
            localization_report,
            processing_manifest,
        )
    ):
        raise FinalTrajectoryAuthorityError(
            "Final trajectory authority artifacts must be objects."
        )
    if processing_manifest.get("version") != PROCESSING_CONTRACT_VERSION:
        raise FinalTrajectoryAuthorityError(
            "Final trajectory authority requires processing contract v3."
        )
    authority = factor_graph_report.get("final_trajectory_authority")
    solver = localization_report.get("solver")
    if (
        not isinstance(authority, dict)
        or authority.get("format") != AUTHORITY_FORMAT
        or authority.get("version") != AUTHORITY_VERSION
        or not isinstance(solver, dict)
    ):
        raise FinalTrajectoryAuthorityError(
            "Final trajectory authority record is missing or invalid."
        )
    poses = poses_from_trajectory_geojson(trajectory_geojson)
    digest = trajectory_sha256(poses)
    expected = {
        "version": AUTHORITY_VERSION,
        "trajectory_sha256": digest,
        "factor_set_sha256": authority.get("factor_set_sha256"),
        "passed": authority.get("passed"),
    }
    bindings = (
        (
            "processing manifest",
            processing_manifest.get("final_trajectory_authority_version"),
            processing_manifest.get("final_trajectory_sha256"),
            processing_manifest.get("final_trajectory_factor_set_sha256"),
            processing_manifest.get("final_trajectory_factor_authority_passed"),
        ),
        (
            "localization solver",
            solver.get("final_trajectory_authority_version"),
            solver.get("final_trajectory_sha256"),
            solver.get("factor_set_sha256"),
            solver.get("final_trajectory_factor_authority_passed"),
        ),
        (
            "trajectory GeoJSON",
            trajectory_geojson.get("final_trajectory_authority_version"),
            trajectory_geojson.get("final_trajectory_sha256"),
            trajectory_geojson.get("final_trajectory_factor_set_sha256"),
            trajectory_geojson.get("final_trajectory_factor_authority_passed"),
        ),
    )
    for name, version, trajectory_digest, factor_digest, passed in bindings:
        if (
            version != expected["version"]
            or trajectory_digest != expected["trajectory_sha256"]
            or factor_digest != expected["factor_set_sha256"]
            or passed is not expected["passed"]
        ):
            raise FinalTrajectoryAuthorityError(
                f"Final trajectory authority differs in {name}."
            )
    if authority.get("trajectory_sha256") != digest or authority.get(
        "node_count"
    ) != len(poses):
        raise FinalTrajectoryAuthorityError(
            "Final trajectory authority hash or node inventory differs from GeoJSON."
        )
    if authority.get("passed") is True:
        recomputed = attest_final_trajectory(
            factor_graph_report,
            poses,
            post_solver=str(authority.get("post_solver") or ""),
        )
        if recomputed != authority:
            raise FinalTrajectoryAuthorityError(
                "Final trajectory factor authority differs from recomputation."
            )
    elif localization_report.get("publish_gate", {}).get("passed") is True:
        raise FinalTrajectoryAuthorityError(
            "Publish gate cannot pass a failed final trajectory authority."
        )
    if require_passed and authority.get("passed") is not True:
        raise FinalTrajectoryAuthorityError(
            "Publication requires a passed final trajectory factor authority."
        )
    return authority
