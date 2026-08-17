"""Strict manifest-v5 corridor/shelf evidence parser and frozen gates."""

from __future__ import annotations

from dataclasses import dataclass
import hashlib
import json
import math
from pathlib import Path
import re
from typing import Any, Iterator

from tools.PriorMap.generated_mobile_evidence_contracts import (
    MOBILE_EVIDENCE_CONTRACTS,
)


CONTRACT_VERSION = 3
SUPPORTED_CONTRACT_VERSIONS = frozenset({2, CONTRACT_VERSION})
CALIBRATION_STATUS = "CALIBRATION_PENDING"
SHA256_RE = re.compile(r"[0-9a-f]{64}")

# Frozen S-7/S-11/S-12/S-5 values.
MAXIMUM_PHONE_SHELF_PENETRATION_M = 0.4
MAXIMUM_ONLINE_CORRECTION_STEP_M = 0.25
MANUAL_ANCHOR_TRANSLATION_SIGMA_M = 3.0
MANUAL_ANCHOR_YAW_SIGMA_RAD = math.radians(15.0)
MAXIMUM_PUBLISHED_SHELF_NORMAL_RESIDUAL_M = 0.5

# C-1/C-2/C-3 starting values; never report these as field-calibrated.
CALIBRATION_PENDING_LOOP_TRANSLATION_M = 0.5
CALIBRATION_PENDING_LOOP_YAW_RAD = math.radians(10.0)
CALIBRATION_PENDING_LOOP_INLIER_RATIO = 0.70
CALIBRATION_PENDING_OPPOSING_NORMAL_RAD = math.radians(120.0)
CALIBRATION_PENDING_LOW_CONFIDENCE_MARGIN = 0.15
CALIBRATION_PENDING_DYNAMIC_PERSISTENCE_SECONDS = 10.0


class ShelfEvidenceError(ValueError):
    pass


@dataclass(frozen=True)
class ShelfEvidenceBundle:
    pose_epoch_transitions: tuple[dict[str, Any], ...]
    corridor_hypotheses: tuple[dict[str, Any], ...]
    shelf_observation_windows: tuple[dict[str, Any], ...]
    shelf_loop_events: tuple[dict[str, Any], ...]
    accepted_shelf_loops: tuple[dict[str, Any], ...]
    file_sha256: dict[str, str]


ROOT_FIELDS_V2: dict[str, frozenset[str]] = {
    "pose_epoch_transitions.jsonl": frozenset({
        "format", "version", "tracking_session_id", "sequence", "from_epoch",
        "to_epoch", "before_frame_timestamp", "after_frame_timestamp",
        "before_node_id", "after_node_id", "transform", "bridge_evidence",
        "reason", "write_watermark",
    }),
    "corridor_hypotheses.jsonl": frozenset({
        "format", "version", "tracking_session_id", "sequence", "node_id",
        "node_timestamp", "node_map_id", "epoch", "component", "hypotheses",
        "top1_top2_margin", "tracking_state", "selected_corridor_id",
        "selected_shelf_segment_id", "selected_shelf_side",
        "low_confidence_reasons", "penetration_audit", "covariance",
        "write_watermark",
    }),
    "shelf_observation_windows.jsonl": frozenset({
        "format", "version", "tracking_session_id", "sequence", "window_id",
        "node_range", "time_range", "epoch", "component", "side",
        "face_normal_map", "shelf_candidates", "coverage_angle_rad",
        "observation_node_count", "geometry",
        "endcap_visible", "dynamic_rejection_count", "prior_map_sha256",
        "distance_field_sha256", "write_watermark",
    }),
    "shelf_loop_events.jsonl": frozenset({
        "format", "version", "tracking_session_id", "sequence",
        "shelf_segment_id", "window_ids", "sides", "epoch", "component",
        "loop_from_node", "loop_to_node", "rtab_loop_id",
        "rtab_loop_residual_m", "rtab_graph_optimization_max_error",
        "phone_shelf_se2", "consistency", "accepted",
        "reason", "calibration_status", "write_watermark",
    }),
}

ROOT_FIELDS_V3 = dict(ROOT_FIELDS_V2)
ROOT_FIELDS_V3["pose_epoch_transitions.jsonl"] = frozenset({
    *ROOT_FIELDS_V2["pose_epoch_transitions.jsonl"],
    "from_component", "to_component",
})

FORMATS = {
    "pose_epoch_transitions.jsonl": "MarketScannerPoseEpochTransition",
    "corridor_hypotheses.jsonl": "MarketScannerCorridorHypotheses",
    "shelf_observation_windows.jsonl": "MarketScannerShelfObservationWindow",
    "shelf_loop_events.jsonl": "MarketScannerShelfLoopEvent",
}

WATERMARKS = {
    "pose_epoch_transitions.jsonl": (
        "poseEpochTransitionCount", "poseEpochTransitionLastSequence"
    ),
    "corridor_hypotheses.jsonl": (
        "corridorHypothesisCount", "corridorHypothesisLastSequence"
    ),
    "shelf_observation_windows.jsonl": (
        "shelfObservationWindowCount", "shelfObservationWindowLastSequence"
    ),
    "shelf_loop_events.jsonl": (
        "shelfLoopEventCount", "shelfLoopEventLastSequence"
    ),
}


def _reject_duplicate_pairs(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ShelfEvidenceError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def _integer(value: Any, field: str, *, minimum: int = 0) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < minimum:
        raise ShelfEvidenceError(f"{field} must be integer >= {minimum}")
    return value


def _number(value: Any, field: str, *, minimum: float | None = None) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ShelfEvidenceError(f"{field} must be numeric")
    result = float(value)
    if not math.isfinite(result) or (minimum is not None and result < minimum):
        raise ShelfEvidenceError(f"{field} must be finite and in range")
    return result


def _string(value: Any, field: str) -> str:
    if not isinstance(value, str) or not value:
        raise ShelfEvidenceError(f"{field} must be a non-empty string")
    return value


def _exact_object(value: Any, fields: set[str], field: str) -> dict[str, Any]:
    if not isinstance(value, dict) or set(value) != fields:
        raise ShelfEvidenceError(f"{field} field set is invalid")
    return value


def _strict_lines(path: Path, name: str) -> Iterator[tuple[int, dict[str, Any]]]:
    limits = MOBILE_EVIDENCE_CONTRACTS[name]
    try:
        size = path.stat().st_size
    except OSError as exc:
        raise ShelfEvidenceError(f"{name} is missing") from exc
    if size > int(limits["max_file_bytes"]):
        raise ShelfEvidenceError(f"{name} exceeds file-size contract")
    if size == 0:
        return
    with path.open("rb") as handle:
        line_count = 0
        while True:
            raw = handle.readline(int(limits["max_record_bytes"]) + 2)
            if not raw:
                break
            line_count += 1
            if line_count > int(limits["max_records"]):
                raise ShelfEvidenceError(f"{name} exceeds record-count contract")
            if len(raw) > int(limits["max_record_bytes"]) + 1:
                raise ShelfEvidenceError(f"{name}:{line_count} record too large")
            if not raw.endswith(b"\n"):
                raise ShelfEvidenceError(f"{name} has no final newline")
            payload = raw[:-1]
            if not payload:
                raise ShelfEvidenceError(f"{name}:{line_count} blank line")
            try:
                value = json.loads(
                    payload.decode("utf-8"), object_pairs_hook=_reject_duplicate_pairs
                )
            except (UnicodeDecodeError, json.JSONDecodeError) as exc:
                raise ShelfEvidenceError(f"{name}:{line_count} invalid JSON") from exc
            if not isinstance(value, dict):
                raise ShelfEvidenceError(f"{name}:{line_count} must be object")
            yield line_count, value


def _file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while True:
            chunk = handle.read(1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
    return digest.hexdigest()


def _validate_common(
    name: str, line: int, value: dict[str, Any], tracking_session_id: str
) -> None:
    version = value.get("version")
    if version not in SUPPORTED_CONTRACT_VERSIONS:
        raise ShelfEvidenceError(f"{name}:{line} format/version mismatch")
    expected_fields = (
        ROOT_FIELDS_V2[name] if version == 2 else ROOT_FIELDS_V3[name]
    )
    if set(value) != expected_fields:
        raise ShelfEvidenceError(f"{name}:{line} root field set mismatch")
    if value.get("format") != FORMATS[name]:
        raise ShelfEvidenceError(f"{name}:{line} format/version mismatch")
    if value.get("tracking_session_id") != tracking_session_id:
        raise ShelfEvidenceError(f"{name}:{line} tracking identity mismatch")
    if _integer(value.get("sequence"), "sequence", minimum=1) != line:
        raise ShelfEvidenceError(f"{name}:{line} non-monotonic sequence")
    if value.get("write_watermark") != line:
        raise ShelfEvidenceError(f"{name}:{line} write watermark mismatch")


def _evidence_transform(value: Any, field: str) -> dict[str, float]:
    transform = _exact_object(
        value, {"dx_m", "dy_m", "dyaw_rad"}, field
    )
    return {
        key: _number(transform[key], f"{field}.{key}") for key in transform
    }


def _angle_distance(first: float, second: float) -> float:
    return abs(math.atan2(math.sin(first - second), math.cos(first - second)))


def _bridge_agrees(
    first: dict[str, float], second: dict[str, float]
) -> bool:
    return (
        math.hypot(first["dx_m"] - second["dx_m"],
                   first["dy_m"] - second["dy_m"])
        <= CALIBRATION_PENDING_LOOP_TRANSLATION_M
        and _angle_distance(first["dyaw_rad"], second["dyaw_rad"])
        <= CALIBRATION_PENDING_LOOP_YAW_RAD
    )


def _bridge_selection(
    links: list[dict[str, Any]], expected: dict[str, float]
) -> tuple[int, set[int]] | None:
    best: tuple[int, int, float] | None = None
    for center_index, center in enumerate(links):
        center_transform = center["_bridge_transform"]
        if not _bridge_agrees(center_transform, expected):
            continue
        inliers: set[int] = set()
        residual = 0.0
        for index, candidate in enumerate(links):
            candidate_transform = candidate["_bridge_transform"]
            if (
                _bridge_agrees(candidate_transform, expected)
                and _bridge_agrees(candidate_transform, center_transform)
            ):
                inliers.add(index)
            residual += (
                math.hypot(
                    candidate_transform["dx_m"] - center_transform["dx_m"],
                    candidate_transform["dy_m"] - center_transform["dy_m"],
                ) / CALIBRATION_PENDING_LOOP_TRANSLATION_M
                + _angle_distance(
                    candidate_transform["dyaw_rad"],
                    center_transform["dyaw_rad"],
                ) / CALIBRATION_PENDING_LOOP_YAW_RAD
            )
        if best is not None and (
            len(inliers) < best[1]
            or (len(inliers) == best[1] and residual >= best[2] - 1.0e-12)
        ):
            continue
        best = (center_index, len(inliers), residual)
    if best is None:
        return None
    center_transform = links[best[0]]["_bridge_transform"]
    return best[0], {
        index for index, candidate in enumerate(links)
        if _bridge_agrees(candidate["_bridge_transform"], expected)
        and _bridge_agrees(candidate["_bridge_transform"], center_transform)
    }


def _validate_v3_bridge(
    bridge: Any,
    *,
    from_epoch: int,
    to_epoch: int,
    before_node_id: int,
    after_node_id: int,
    from_component: int,
    to_component: int,
    expected_transform: dict[str, float],
) -> int:
    bridge = _exact_object(
        bridge,
        {"type", "independent_node_pairs", "consensus_inlier_ratio",
         "component", "consensus_transform", "links"},
        "bridge_evidence",
    )
    if _string(bridge["type"], "bridge type") != "multi_link_consensus":
        raise ShelfEvidenceError("bridge evidence type is unsupported")
    component = _integer(bridge["component"], "bridge component")
    if from_component != component or to_component != component:
        raise ShelfEvidenceError("bridge component does not bind transition endpoints")
    consensus_transform = _evidence_transform(
        bridge["consensus_transform"], "consensus_transform"
    )
    raw_links = bridge["links"]
    if not isinstance(raw_links, list) or not 2 <= len(raw_links) <= 16:
        raise ShelfEvidenceError("bridge links are invalid")
    parsed_links: list[dict[str, Any]] = []
    pairs: set[tuple[int, int]] = set()
    endpoints: set[int] = set()
    observed_order: list[tuple[int, int]] = []
    for raw_link in raw_links:
        link = _exact_object(
            raw_link,
            {"from_node_id", "to_node_id", "from_epoch", "to_epoch",
             "from_component", "to_component", "native_link_type",
             "measurement", "bridge_transform", "consensus_inlier"},
            "bridge link",
        )
        from_node = _integer(link["from_node_id"], "from_node_id", minimum=1)
        to_node = _integer(link["to_node_id"], "to_node_id", minimum=1)
        if (
            from_node == to_node
            or from_node > before_node_id
            or to_node < after_node_id
            or _integer(link["from_epoch"], "link from_epoch") != from_epoch
            or _integer(link["to_epoch"], "link to_epoch") != to_epoch
            or _integer(link["from_component"], "link from_component")
                != component
            or _integer(link["to_component"], "link to_component")
                != component
            or link["native_link_type"] not in {"global_visual", "local_space"}
            or type(link["consensus_inlier"]) is not bool
        ):
            raise ShelfEvidenceError("bridge link identity is invalid")
        pair = (min(from_node, to_node), max(from_node, to_node))
        if pair in pairs or from_node in endpoints or to_node in endpoints:
            raise ShelfEvidenceError("bridge links are not independent")
        pairs.add(pair)
        endpoints.update((from_node, to_node))
        observed_order.append((from_node, to_node))
        parsed = dict(link)
        parsed["_measurement"] = _evidence_transform(
            link["measurement"], "measurement"
        )
        parsed["_bridge_transform"] = _evidence_transform(
            link["bridge_transform"], "bridge_transform"
        )
        parsed_links.append(parsed)
    if observed_order != sorted(observed_order):
        raise ShelfEvidenceError("bridge links are not canonically ordered")
    selection = _bridge_selection(parsed_links, expected_transform)
    if selection is None:
        raise ShelfEvidenceError("bridge consensus has no transition-bound center")
    center_index, inliers = selection
    expected_count = len(inliers)
    expected_ratio = expected_count / len(parsed_links)
    if (
        expected_count < 2
        or expected_ratio < CALIBRATION_PENDING_LOOP_INLIER_RATIO
        or _integer(
            bridge["independent_node_pairs"],
            "independent_node_pairs", minimum=2,
        ) != expected_count
        or abs(_number(
            bridge["consensus_inlier_ratio"], "consensus_inlier_ratio"
        ) - expected_ratio) > 1.0e-12
        or any(
            link["consensus_inlier"] != (index in inliers)
            for index, link in enumerate(parsed_links)
        )
        or any(
            abs(consensus_transform[key]
                - parsed_links[center_index]["_bridge_transform"][key]) > 1.0e-12
            for key in ("dx_m", "dy_m")
        )
        or _angle_distance(
            consensus_transform["dyaw_rad"],
            parsed_links[center_index]["_bridge_transform"]["dyaw_rad"],
        ) > 1.0e-12
    ):
        raise ShelfEvidenceError("bridge consensus summary is invalid")
    return len(parsed_links)


def _validate_pose(value: dict[str, Any]) -> None:
    source = _integer(value["from_epoch"], "from_epoch")
    target = _integer(value["to_epoch"], "to_epoch")
    if target != source + 1:
        raise ShelfEvidenceError("pose epoch transition is not contiguous")
    before = _number(value["before_frame_timestamp"], "before timestamp")
    after = _number(value["after_frame_timestamp"], "after timestamp")
    if after < before:
        raise ShelfEvidenceError("pose epoch timestamps are reversed")
    before_node_id = _integer(value["before_node_id"], "before_node_id", minimum=1)
    after_node_id = _integer(value["after_node_id"], "after_node_id", minimum=1)
    transform = _evidence_transform(value["transform"], "transform")
    bridges = value["bridge_evidence"]
    if not isinstance(bridges, list) or len(bridges) > 16:
        raise ShelfEvidenceError("bridge_evidence is invalid")
    if value["version"] == 3:
        from_component = _integer(value["from_component"], "from_component")
        to_component = _integer(value["to_component"], "to_component")
        total_links = sum(
            _validate_v3_bridge(
                bridge,
                from_epoch=source,
                to_epoch=target,
                before_node_id=before_node_id,
                after_node_id=after_node_id,
                from_component=from_component,
                to_component=to_component,
                expected_transform=transform,
            )
            for bridge in bridges
        )
        if total_links > 16:
            raise ShelfEvidenceError("pose transition bridge-link capacity exceeded")
        components = [bridge["component"] for bridge in bridges]
        if len(set(components)) != len(components):
            raise ShelfEvidenceError("duplicate bridge component")
        _string(value["reason"], "reason")
        return
    for bridge in bridges:
        bridge = _exact_object(
            bridge,
            {"type", "independent_node_pairs", "consensus_inlier_ratio"},
            "bridge_evidence",
        )
        if _string(bridge["type"], "bridge type") != "multi_link_consensus":
            raise ShelfEvidenceError("bridge evidence type is unsupported")
        _integer(
            bridge["independent_node_pairs"],
            "independent_node_pairs",
            minimum=2,
        )
        ratio = _number(bridge["consensus_inlier_ratio"], "consensus_inlier_ratio")
        if ratio < CALIBRATION_PENDING_LOOP_INLIER_RATIO or ratio > 1.0:
            raise ShelfEvidenceError("bridge inlier ratio is invalid")
    _string(value["reason"], "reason")


def _validate_corridor(value: dict[str, Any]) -> None:
    _integer(value["node_id"], "node_id", minimum=1)
    _number(value["node_timestamp"], "node_timestamp")
    node_map_id = _integer(value["node_map_id"], "node_map_id", minimum=0)
    _integer(value["epoch"], "epoch")
    component = _integer(value["component"], "component")
    if component != node_map_id:
        raise ShelfEvidenceError("corridor component must equal node_map_id")
    hypotheses = value["hypotheses"]
    if not isinstance(hypotheses, list) or len(hypotheses) > 24:
        raise ShelfEvidenceError("corridor hypotheses are invalid")
    corridor_ids: list[str] = []
    corridor_scores: list[float] = []
    for hypothesis in hypotheses:
        hypothesis = _exact_object(
            hypothesis,
            {"corridor_id", "distance_score", "structure_basin_score",
             "topology_reachable", "score"},
            "corridor hypothesis",
        )
        corridor_ids.append(_string(hypothesis["corridor_id"], "corridor_id"))
        corridor_scores.append(
            _number(hypothesis["score"], "corridor score", minimum=0.0)
        )
        for key in ("distance_score", "structure_basin_score"):
            if _number(hypothesis[key], key, minimum=0.0) > 1.0:
                raise ShelfEvidenceError(f"{key} exceeds one")
        if type(hypothesis["topology_reachable"]) is not bool:
            raise ShelfEvidenceError("topology_reachable must be boolean")
    if any(score > 1.0 for score in corridor_scores):
        raise ShelfEvidenceError("corridor score exceeds one")
    if len(set(corridor_ids)) != len(corridor_ids):
        raise ShelfEvidenceError("corridor hypotheses contain duplicate identity")
    if any(first < second for first, second in zip(
        corridor_scores, corridor_scores[1:]
    )):
        raise ShelfEvidenceError("corridor hypotheses are not score ordered")
    _number(value["top1_top2_margin"], "top1_top2_margin", minimum=0.0)
    if value["tracking_state"] not in {"BOOTSTRAP", "TRACKING", "LOW_CONFIDENCE"}:
        raise ShelfEvidenceError("tracking_state is invalid")
    selected_corridor = value["selected_corridor_id"]
    if not isinstance(selected_corridor, str) or (
        selected_corridor and (not corridor_ids or selected_corridor != corridor_ids[0])
    ):
        raise ShelfEvidenceError("selected_corridor_id is invalid")
    selected_shelf = value["selected_shelf_segment_id"]
    selected_side = value["selected_shelf_side"]
    if not isinstance(selected_shelf, str) or selected_side not in {
        "unknown", "left", "right"
    } or ((not selected_shelf) != (selected_side == "unknown")):
        raise ShelfEvidenceError("selected shelf/side state is invalid")
    reasons = value["low_confidence_reasons"]
    if (
        not isinstance(reasons, list)
        or any(not isinstance(item, str) or not item for item in reasons)
        or len(set(reasons)) != len(reasons)
        or ((value["tracking_state"] == "TRACKING") == bool(reasons))
        or (value["tracking_state"] == "BOOTSTRAP" and bool(selected_corridor))
    ):
        raise ShelfEvidenceError("low-confidence reasons are invalid")
    if hypotheses:
        best = hypotheses[0]
        if (
            float(best["structure_basin_score"]) < 1.0e-9
            and "structure_basin_support_insufficient" not in reasons
        ):
            raise ShelfEvidenceError("weak structure basin was not persisted")
        if (
            best["topology_reachable"] is not True
            and "topology_reachability_failed" not in reasons
        ):
            raise ShelfEvidenceError("topology failure was not persisted")
    audit = _exact_object(
        value["penetration_audit"],
        {"node_inside_shelf_count", "segment_crossing_count"},
        "penetration_audit",
    )
    for key in audit:
        _integer(audit[key], f"penetration_audit.{key}")
    covariance = _exact_object(
        value["covariance"], {"along_m", "cross_m", "yaw_rad"}, "covariance"
    )
    for key in covariance:
        _number(covariance[key], f"covariance.{key}", minimum=0.0)


def _normal(value: Any) -> tuple[float, float]:
    normal = _exact_object(value, {"x", "y"}, "face_normal_map")
    x = _number(normal["x"], "normal.x")
    y = _number(normal["y"], "normal.y")
    if abs(math.hypot(x, y) - 1.0) > 0.05:
        raise ShelfEvidenceError("face normal is not unit length")
    return x, y


def _validate_window(value: dict[str, Any], prior_map_sha256: str) -> None:
    _string(value["window_id"], "window_id")
    nodes = value["node_range"]
    times = value["time_range"]
    if not isinstance(nodes, list) or len(nodes) != 2:
        raise ShelfEvidenceError("node_range is invalid")
    if not isinstance(times, list) or len(times) != 2:
        raise ShelfEvidenceError("time_range is invalid")
    start_node = _integer(nodes[0], "node_range[0]", minimum=1)
    end_node = _integer(nodes[1], "node_range[1]", minimum=1)
    if end_node < start_node:
        raise ShelfEvidenceError("node_range is reversed")
    start_time = _number(times[0], "time_range[0]")
    if _number(times[1], "time_range[1]") < start_time:
        raise ShelfEvidenceError("time_range is reversed")
    _integer(value["epoch"], "epoch")
    _integer(value["component"], "component")
    if value["side"] not in {"left", "right"}:
        raise ShelfEvidenceError("window side is invalid")
    _normal(value["face_normal_map"])
    candidates = value["shelf_candidates"]
    if not isinstance(candidates, list) or not candidates or len(candidates) > 24:
        raise ShelfEvidenceError("shelf_candidates are invalid")
    shelf_ids: list[str] = []
    shelf_scores: list[float] = []
    for candidate in candidates:
        candidate = _exact_object(
            candidate, {"shelf_segment_id", "score"}, "shelf candidate"
        )
        shelf_ids.append(_string(candidate["shelf_segment_id"], "shelf_segment_id"))
        shelf_scores.append(
            _number(candidate["score"], "shelf score", minimum=0.0)
        )
    if any(score > 1.0 for score in shelf_scores):
        raise ShelfEvidenceError("shelf score exceeds one")
    if len(set(shelf_ids)) != len(shelf_ids):
        raise ShelfEvidenceError("shelf candidates contain duplicate identity")
    if any(first < second for first, second in zip(
        shelf_scores, shelf_scores[1:]
    )):
        raise ShelfEvidenceError("shelf candidates are not score ordered")
    _number(value["coverage_angle_rad"], "coverage_angle_rad", minimum=0.0)
    if type(value["endcap_visible"]) is not bool:
        raise ShelfEvidenceError("endcap_visible must be boolean")
    observation_node_count = _integer(
        value["observation_node_count"],
        "observation_node_count",
        minimum=1,
    )
    if observation_node_count > end_node - start_node + 1:
        raise ShelfEvidenceError("observation_node_count exceeds node span")
    dynamic_rejection_count = _integer(
        value["dynamic_rejection_count"], "dynamic_rejection_count"
    )
    if dynamic_rejection_count > observation_node_count:
        raise ShelfEvidenceError("dynamic_rejection_count exceeds observations")
    if value["prior_map_sha256"] != prior_map_sha256:
        raise ShelfEvidenceError("window prior-map identity mismatch")
    if SHA256_RE.fullmatch(str(value["distance_field_sha256"])) is None:
        raise ShelfEvidenceError("window distance-field identity is invalid")
    geometry = _exact_object(
        value["geometry"],
        {"sample_count", "inlier_count", "inlier_ratio",
         "residual_median_m", "residual_maximum_m"},
        "geometry",
    )
    sample_count = _integer(geometry["sample_count"], "sample_count", minimum=12)
    inlier_count = _integer(geometry["inlier_count"], "inlier_count")
    ratio = _number(geometry["inlier_ratio"], "inlier_ratio", minimum=0.0)
    median = _number(geometry["residual_median_m"], "residual_median_m", minimum=0.0)
    maximum = _number(
        geometry["residual_maximum_m"], "residual_maximum_m", minimum=0.0
    )
    if (
        inlier_count > sample_count
        or ratio > 1.0
        or abs(ratio - inlier_count / sample_count) > 1.0e-9
        or maximum < median
    ):
        raise ShelfEvidenceError("window geometry summary is invalid")


def _validate_loop(value: dict[str, Any]) -> None:
    _string(value["shelf_segment_id"], "shelf_segment_id")
    windows, sides = value["window_ids"], value["sides"]
    if (
        not isinstance(windows, list) or len(windows) != 2
        or any(not isinstance(item, str) or not item for item in windows)
        or len(set(windows)) != 2
        or not isinstance(sides, list) or sides not in (["left", "right"], ["right", "left"])
    ):
        raise ShelfEvidenceError("shelf loop windows/sides are invalid")
    _integer(value["epoch"], "epoch")
    _integer(value["component"], "component")
    _integer(value["loop_from_node"], "loop_from_node", minimum=1)
    _integer(value["loop_to_node"], "loop_to_node", minimum=1)
    _integer(value["rtab_loop_id"], "rtab_loop_id")
    if value["rtab_loop_residual_m"] is not None:
        raise ShelfEvidenceError(
            "v2 rtab_loop_residual_m must be null; optimizationMaxError is not a loop residual"
        )
    _number(
        value["rtab_graph_optimization_max_error"],
        "rtab_graph_optimization_max_error",
        minimum=0.0,
    )
    pose = _exact_object(
        value["phone_shelf_se2"], {"dx_m", "dy_m", "dyaw_rad"}, "phone_shelf_se2"
    )
    for key in pose:
        _number(pose[key], f"phone_shelf_se2.{key}")
    consistency = _exact_object(
        value["consistency"],
        {"relative_pose_delta_m", "relative_pose_delta_yaw_rad", "inlier_ratio",
         "residual_median_m", "residual_maximum_m"},
        "consistency",
    )
    for key in consistency:
        _number(consistency[key], f"consistency.{key}", minimum=0.0)
    if consistency["inlier_ratio"] > 1.0:
        raise ShelfEvidenceError("loop inlier ratio is invalid")
    if type(value["accepted"]) is not bool:
        raise ShelfEvidenceError("accepted must be boolean")
    _string(value["reason"], "reason")
    if value["calibration_status"] != CALIBRATION_STATUS:
        raise ShelfEvidenceError("calibration status must remain pending")


def validate_shelf_evidence_record(
    name: str,
    line: int,
    record: dict[str, Any],
    *,
    tracking_session_id: str,
    prior_map_sha256: str,
) -> None:
    if name not in ROOT_FIELDS_V3:
        raise ShelfEvidenceError(f"unsupported shelf evidence file: {name}")
    _validate_common(name, line, record, tracking_session_id)
    if name == "pose_epoch_transitions.jsonl":
        _validate_pose(record)
    elif name == "corridor_hypotheses.jsonl":
        _validate_corridor(record)
    elif name == "shelf_observation_windows.jsonl":
        _validate_window(record, prior_map_sha256)
    else:
        _validate_loop(record)


def _has_epoch_bridge(
    transitions: tuple[dict[str, Any], ...], first_epoch: int, second_epoch: int,
    component: int,
) -> bool:
    if first_epoch == second_epoch:
        return True
    low, high = sorted((first_epoch, second_epoch))
    bridged = {
        int(item["from_epoch"])
        for item in transitions
        if item["version"] >= 3
        and any(
            int(evidence["component"]) == component
            for evidence in item["bridge_evidence"]
        )
    }
    return all(epoch in bridged for epoch in range(low, high))


def _candidate_relative_margin(window: dict[str, Any]) -> float:
    candidates = window["shelf_candidates"]
    if len(candidates) < 2:
        return 1.0
    first = float(candidates[0]["score"])
    second = float(candidates[1]["score"])
    return max(0.0, (first - second) / max(abs(first), 1.0e-9))


def _validate_loop_references(
    loop: dict[str, Any], windows: dict[str, dict[str, Any]],
    transitions: tuple[dict[str, Any], ...]
) -> None:
    first = windows.get(loop["window_ids"][0])
    second = windows.get(loop["window_ids"][1])
    if first is None or second is None:
        raise ShelfEvidenceError("loop references unknown shelf window")
    shelf_id = loop["shelf_segment_id"]
    if (
        first["shelf_candidates"][0]["shelf_segment_id"] != shelf_id
        or second["shelf_candidates"][0]["shelf_segment_id"] != shelf_id
        or loop["component"] != first["component"]
        or first["side"] == second["side"]
        or loop["sides"] != [first["side"], second["side"]]
        or loop["epoch"] not in {first["epoch"], second["epoch"]}
        or not (
            int(first["node_range"][0])
            <= int(loop["loop_from_node"])
            <= int(first["node_range"][1])
        )
        or not (
            int(second["node_range"][0])
            <= int(loop["loop_to_node"])
            <= int(second["node_range"][1])
        )
    ):
        raise ShelfEvidenceError("loop shelf/side/component identity mismatch")
    if first["component"] != second["component"]:
        if loop["accepted"]:
            raise ShelfEvidenceError("accepted loop crosses graph component")
        return
    if not _has_epoch_bridge(
        transitions, first["epoch"], second["epoch"], int(loop["component"])
    ):
        if loop["accepted"]:
            raise ShelfEvidenceError("accepted loop crosses epoch without bridge")
        return
    first_normal = _normal(first["face_normal_map"])
    second_normal = _normal(second["face_normal_map"])
    normal_angle = math.acos(max(-1.0, min(1.0, sum(
        a * b for a, b in zip(first_normal, second_normal)
    ))))
    consistency = loop["consistency"]
    expected_inlier_ratio = min(
        float(first["geometry"]["inlier_ratio"]),
        float(second["geometry"]["inlier_ratio"]),
    )
    expected_median = max(
        float(first["geometry"]["residual_median_m"]),
        float(second["geometry"]["residual_median_m"]),
    )
    expected_maximum = max(
        float(first["geometry"]["residual_maximum_m"]),
        float(second["geometry"]["residual_maximum_m"]),
    )
    if (
        abs(float(consistency["inlier_ratio"]) - expected_inlier_ratio) > 1.0e-9
        or abs(float(consistency["residual_median_m"]) - expected_median)
            > 1.0e-9
        or abs(float(consistency["residual_maximum_m"]) - expected_maximum)
            > 1.0e-9
    ):
        raise ShelfEvidenceError("loop geometry summary mismatch")
    dominant_dynamic = (
        int(first["dynamic_rejection_count"]) * 2
            > int(first["observation_node_count"])
        or int(second["dynamic_rejection_count"]) * 2
            > int(second["observation_node_count"])
    )
    qualifies = (
        normal_angle > CALIBRATION_PENDING_OPPOSING_NORMAL_RAD
        and _candidate_relative_margin(first)
            >= CALIBRATION_PENDING_LOW_CONFIDENCE_MARGIN
        and _candidate_relative_margin(second)
            >= CALIBRATION_PENDING_LOW_CONFIDENCE_MARGIN
        and consistency["relative_pose_delta_m"]
            <= CALIBRATION_PENDING_LOOP_TRANSLATION_M
        and consistency["relative_pose_delta_yaw_rad"]
            <= CALIBRATION_PENDING_LOOP_YAW_RAD
        and consistency["inlier_ratio"] >= CALIBRATION_PENDING_LOOP_INLIER_RATIO
        and first["geometry"]["inlier_ratio"]
            >= CALIBRATION_PENDING_LOOP_INLIER_RATIO
        and second["geometry"]["inlier_ratio"]
            >= CALIBRATION_PENDING_LOOP_INLIER_RATIO
        and not dominant_dynamic
    )
    if loop["accepted"] != qualifies:
        raise ShelfEvidenceError("loop acceptance disagrees with frozen criteria")


def read_shelf_localization_evidence(
    segment: Path, metadata: dict[str, Any]
) -> ShelfEvidenceBundle:
    if metadata.get("shelfLocalizationEvidenceComplete") is not True:
        raise ShelfEvidenceError("manifest-v5 shelf evidence is incomplete")
    tracking_session_id = _string(
        metadata.get("trackingSessionId"), "trackingSessionId"
    )
    prior_map_sha256 = _string(metadata.get("priorMapSha256"), "priorMapSha256")
    values: dict[str, tuple[dict[str, Any], ...]] = {}
    hashes: dict[str, str] = {}
    for name in ROOT_FIELDS_V3:
        count_key, last_key = WATERMARKS[name]
        expected_count = _integer(metadata.get(count_key), count_key)
        expected_last = metadata.get(last_key)
        if expected_last is not None:
            expected_last = _integer(expected_last, last_key, minimum=1)
        if expected_last != (expected_count if expected_count else None):
            raise ShelfEvidenceError(f"{name} metadata last-sequence mismatch")
        path = segment / name
        records: list[dict[str, Any]] = []
        for line, record in _strict_lines(path, name):
            _validate_common(name, line, record, tracking_session_id)
            if name == "pose_epoch_transitions.jsonl":
                _validate_pose(record)
            elif name == "corridor_hypotheses.jsonl":
                _validate_corridor(record)
            elif name == "shelf_observation_windows.jsonl":
                _validate_window(record, prior_map_sha256)
            else:
                _validate_loop(record)
            records.append(record)
        if len(records) != expected_count:
            raise ShelfEvidenceError(f"{name} count does not match metadata")
        values[name] = tuple(records)
        hashes[name] = _file_sha256(path)
    return validate_shelf_localization_records(values, metadata, file_sha256=hashes)


def validate_shelf_localization_records(
    values: dict[str, tuple[dict[str, Any], ...]],
    metadata: dict[str, Any],
    *,
    file_sha256: dict[str, str] | None = None,
) -> ShelfEvidenceBundle:
    """Cross-validate an already descriptor-stable, parse-and-hash-once view."""
    if metadata.get("shelfLocalizationEvidenceComplete") is not True:
        raise ShelfEvidenceError("manifest-v5 shelf evidence is incomplete")
    tracking_session_id = _string(
        metadata.get("trackingSessionId"), "trackingSessionId"
    )
    prior_map_sha256 = _string(
        metadata.get("priorMapSha256"), "priorMapSha256"
    )
    for name in ROOT_FIELDS_V3:
        if name not in values:
            raise ShelfEvidenceError(f"{name} is absent from manifest-v5 input")
        count_key, last_key = WATERMARKS[name]
        expected_count = _integer(metadata.get(count_key), count_key)
        expected_last = metadata.get(last_key)
        if expected_last is not None:
            expected_last = _integer(expected_last, last_key, minimum=1)
        if expected_last != (expected_count if expected_count else None):
            raise ShelfEvidenceError(f"{name} metadata last-sequence mismatch")
        if len(values[name]) != expected_count:
            raise ShelfEvidenceError(f"{name} count does not match metadata")
        for line, record in enumerate(values[name], start=1):
            validate_shelf_evidence_record(
                name,
                line,
                record,
                tracking_session_id=tracking_session_id,
                prior_map_sha256=prior_map_sha256,
            )
    transitions = values["pose_epoch_transitions.jsonl"]
    transition_from_epochs = [int(item["from_epoch"]) for item in transitions]
    if len(set(transition_from_epochs)) != len(transition_from_epochs):
        raise ShelfEvidenceError("duplicate pose epoch transition")
    windows = values["shelf_observation_windows.jsonl"]
    windows_by_id = {item["window_id"]: item for item in windows}
    if len(windows_by_id) != len(windows):
        raise ShelfEvidenceError("duplicate shelf window identity")
    loops = values["shelf_loop_events.jsonl"]
    for loop in loops:
        _validate_loop_references(loop, windows_by_id, transitions)
    return ShelfEvidenceBundle(
        pose_epoch_transitions=transitions,
        corridor_hypotheses=values["corridor_hypotheses.jsonl"],
        shelf_observation_windows=windows,
        shelf_loop_events=loops,
        accepted_shelf_loops=tuple(item for item in loops if item["accepted"]),
        file_sha256=dict(file_sha256 or {}),
    )
