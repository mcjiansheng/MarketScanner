"""Stage-one ARKit projection with conservative road-graph soft constraints."""

from __future__ import annotations

import math
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Sequence

from .coordinate_system import normalize_angle, rounded, transform_se2
from .prior_map_schema import load_json


@dataclass(frozen=True)
class Pose2D:
    x_m: float
    y_m: float
    yaw_rad: float

    def as_dict(self) -> dict[str, float]:
        return {
            "x_m": rounded(self.x_m),
            "y_m": rounded(self.y_m),
            "yaw_rad": rounded(self.yaw_rad),
        }


@dataclass(frozen=True)
class RoadCandidate:
    edge_id: str
    distance_m: float
    projection: Pose2D

    def as_dict(self) -> dict[str, Any]:
        return {
            "edge_id": self.edge_id,
            "distance_m": rounded(self.distance_m),
            "projection": self.projection.as_dict(),
        }


def _project_to_segment(
    pose: Pose2D,
    start: Sequence[float],
    end: Sequence[float],
) -> tuple[float, Pose2D]:
    start_x, start_y = float(start[0]), float(start[1])
    dx = float(end[0]) - start_x
    dy = float(end[1]) - start_y
    length_squared = dx * dx + dy * dy
    if length_squared <= 1e-12:
        projection_x, projection_y = start_x, start_y
    else:
        ratio = ((pose.x_m - start_x) * dx + (pose.y_m - start_y) * dy) / length_squared
        ratio = min(1.0, max(0.0, ratio))
        projection_x = start_x + ratio * dx
        projection_y = start_y + ratio * dy
    return (
        math.hypot(pose.x_m - projection_x, pose.y_m - projection_y),
        Pose2D(projection_x, projection_y, pose.yaw_rad),
    )


class StageOneLocalizer:
    """Project ARKit poses and apply a small, auditable road attraction.

    This is deliberately not a scan matcher.  The road graph influences the
    displayed estimate only when a nearby candidate is unambiguous, and each
    update is capped so repeated supermarket aisles cannot cause a hard jump.
    """

    def __init__(
        self,
        road_graph: dict[str, Any],
        floor_id: str,
        initial_map_pose: Pose2D,
        initial_arkit_pose: Pose2D = Pose2D(0.0, 0.0, 0.0),
        soft_gain: float = 0.15,
        maximum_correction_m: float = 0.25,
        candidate_radius_m: float = 3.0,
        ambiguity_margin_m: float = 0.35,
    ) -> None:
        self.floor_id = str(floor_id)
        self.soft_gain = min(0.5, max(0.0, float(soft_gain)))
        self.maximum_correction_m = max(0.0, float(maximum_correction_m))
        self.candidate_radius_m = max(0.1, float(candidate_radius_m))
        self.ambiguity_margin_m = max(0.0, float(ambiguity_margin_m))
        self.map_from_arkit = Pose2D(
            initial_map_pose.x_m,
            initial_map_pose.y_m,
            normalize_angle(initial_map_pose.yaw_rad - initial_arkit_pose.yaw_rad),
        )
        self.arkit_origin = initial_arkit_pose
        node_positions = {
            str(node["id"]): node["position_m"]
            for node in road_graph.get("nodes", [])
            if str(node.get("floor_id")) == self.floor_id
        }
        self.edges: list[dict[str, Any]] = []
        for edge in road_graph.get("edges", []):
            if str(edge.get("floor_id")) != self.floor_id:
                continue
            start = node_positions.get(str(edge.get("from")))
            end = node_positions.get(str(edge.get("to")))
            if start is not None and end is not None:
                self.edges.append({"id": str(edge["id"]), "start": start, "end": end})
        self.last_state = "lost"
        self.accepted_updates = 0
        self.rejected_updates = 0

    @classmethod
    def load(
        cls,
        package_directory: Path | str,
        floor_id: str,
        initial_map_pose: Pose2D,
        **options: Any,
    ) -> "StageOneLocalizer":
        graph = load_json(Path(package_directory) / "road_graph.json")
        return cls(graph, floor_id, initial_map_pose, **options)

    def raw_map_pose(self, arkit_pose: Pose2D) -> Pose2D:
        local_x = arkit_pose.x_m - self.arkit_origin.x_m
        local_y = arkit_pose.y_m - self.arkit_origin.y_m
        x, y, yaw = transform_se2(
            self.map_from_arkit.x_m,
            self.map_from_arkit.y_m,
            self.map_from_arkit.yaw_rad,
            local_x,
            local_y,
            arkit_pose.yaw_rad - self.arkit_origin.yaw_rad,
        )
        return Pose2D(x, y, yaw)

    def candidates(self, pose: Pose2D, limit: int = 3) -> list[RoadCandidate]:
        values: list[RoadCandidate] = []
        for edge in self.edges:
            distance, projection = _project_to_segment(pose, edge["start"], edge["end"])
            if distance <= self.candidate_radius_m:
                values.append(RoadCandidate(edge["id"], distance, projection))
        return sorted(values, key=lambda item: (item.distance_m, item.edge_id))[: max(1, limit)]

    def update(
        self,
        arkit_pose: Pose2D,
        tracking_state: str = "normal",
    ) -> dict[str, Any]:
        raw = self.raw_map_pose(arkit_pose)
        candidates = self.candidates(raw)
        accepted = False
        reason = "no_candidate"
        corrected = raw
        best = candidates[0] if candidates else None
        unique = (
            best is not None
            and (len(candidates) == 1 or candidates[1].distance_m - best.distance_m >= self.ambiguity_margin_m)
        )
        if tracking_state != "normal":
            reason = "tracking_not_normal"
        elif best is not None and not unique:
            reason = "ambiguous_parallel_roads"
        elif best is not None:
            dx = best.projection.x_m - raw.x_m
            dy = best.projection.y_m - raw.y_m
            desired_x = dx * self.soft_gain
            desired_y = dy * self.soft_gain
            magnitude = math.hypot(desired_x, desired_y)
            if magnitude > self.maximum_correction_m > 0:
                scale = self.maximum_correction_m / magnitude
                desired_x *= scale
                desired_y *= scale
            corrected = Pose2D(raw.x_m + desired_x, raw.y_m + desired_y, raw.yaw_rad)
            accepted = True
            reason = "nearby_unique_road_soft_constraint"

        if accepted:
            self.accepted_updates += 1
        else:
            self.rejected_updates += 1
        distance = best.distance_m if best is not None else float("inf")
        if tracking_state == "notAvailable" or not self.edges:
            state = "lost"
            confidence = 0.0
        elif tracking_state != "normal" or best is None or distance > 2.0:
            state = "weak"
            confidence = max(0.05, 0.35 - min(distance if math.isfinite(distance) else 3.0, 3.0) * 0.1)
        elif not unique or distance > 1.0:
            state = "usable"
            confidence = 0.55
        else:
            state = "stable"
            confidence = max(0.7, 1.0 - distance / 3.0)
        self.last_state = state
        return {
            "raw_pose": raw.as_dict(),
            "estimated_pose": corrected.as_dict(),
            "tracking_state": tracking_state,
            "localization_state": state,
            "confidence": rounded(confidence),
            "road_constraint": {
                "accepted": accepted,
                "reason": reason,
                "candidates": [item.as_dict() for item in candidates],
            },
        }

    def manual_calibrate(self, arkit_pose: Pose2D, confirmed_map_pose: Pose2D) -> dict[str, Any]:
        self.map_from_arkit = Pose2D(
            confirmed_map_pose.x_m,
            confirmed_map_pose.y_m,
            normalize_angle(confirmed_map_pose.yaw_rad - arkit_pose.yaw_rad),
        )
        self.arkit_origin = Pose2D(arkit_pose.x_m, arkit_pose.y_m, 0.0)
        return {
            "event": "manual_localization_confirmation",
            "arkit_pose": arkit_pose.as_dict(),
            "confirmed_map_pose": confirmed_map_pose.as_dict(),
            "map_from_arkit": self.map_from_arkit.as_dict(),
        }
