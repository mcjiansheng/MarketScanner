from __future__ import annotations

import hashlib
import json
import sqlite3
import math
import shutil
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from tools.PriorMap.offline_localization import (
    CONSTRAINT_CONTRACT,
    DEFAULT_REPLAY_PARAMETERS,
    RECOVERY_EVIDENCE_UNBOUND_LEGACY,
    RECOVERY_EVENT_CONTRACT,
    SESSION_INPUT_FILE_NAMES_V2,
    Pose,
    OfflineLocalizationError,
    _read_jsonl,
    _validate_jsonl_business_record,
    _validate_recovery_event_sequence,
    _associate_tag,
    _segment_intersection,
    apply_pose_delta_to_point,
    bind_tag_observation_to_pose,
    bind_manual_localization_event_to_pose,
    append_manual_edit,
    build_session_input_manifest,
    build_road_soft_constraints,
    build_manual_aisle_constraints,
    infer_aisle_switch_sequence,
    apply_manual_edits,
    move_manual_edit_cursor,
    new_manual_edits,
    optimize_trajectory,
    processing_parameter_sha256,
    _legacy_processing_parameter_sha256_v3,
    process_localized_session,
    session_input_bundle_sha256,
    upgrade_manual_edits_v2,
    AbsoluteConstraint,
)
from tools.PriorMap.localized_output_store import LocalizedVersionStore
from tools.PriorMap.tests.test_prior_map import fixture_rows, write_workbook
from tools.PriorMap.xlsx_to_prior_map import convert_workbook


def json_write(path: Path, value: object) -> None:
    path.write_text(
        json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def jsonl_write(path: Path, values: list[dict[str, object]]) -> None:
    path.write_text(
        "".join(json.dumps(value, sort_keys=True) + "\n" for value in values),
        encoding="utf-8",
    )


class RecoveryConstraintDispositionTests(unittest.TestCase):
    def test_pc_reader_rejects_provisional_step_marked_formally_accepted(self) -> None:
        record = {
            "timestamp": 1.0,
            "nodeTimebaseTimestamp": 1.0,
            "nodeTimebaseOffsetSeconds": 0.0,
            "accepted": True,
            "disposition": "provisional_recovery_step",
            "predictedPose": {"x_m": 0.0, "y_m": 0.0, "yaw_rad": 0.0},
            "estimatedPose": {"x_m": 0.35, "y_m": 0.0, "yaw_rad": 0.0},
            "uniqueness": 0.5,
        }
        with self.assertRaisesRegex(
            OfflineLocalizationError, "Provisional recovery step marked accepted"
        ):
            _validate_jsonl_business_record(
                CONSTRAINT_CONTRACT, record, "constraint:1"
            )
        record["accepted"] = False
        _validate_jsonl_business_record(CONSTRAINT_CONTRACT, record, "constraint:1")


class SE2TagPropagationTests(unittest.TestCase):
    """Wave 3A: verify that tag positions follow the full rigid-body delta,
    not just dx/dy.  ``DeltaT = T_offline * inverse(T_baseline)``.
    """

    def _pose(self, x: float, y: float, yaw: float) -> Pose:
        return Pose(1, 0.0, x, y, yaw)

    def test_no_change_leaves_point_unchanged(self) -> None:
        base = self._pose(3.0, 4.0, 0.5)
        opt = self._pose(3.0, 4.0, 0.5)
        x, y = apply_pose_delta_to_point(base, opt, (5.0, 6.0))
        self.assertAlmostEqual(x, 5.0, places=9)
        self.assertAlmostEqual(y, 6.0, places=9)

    def test_pure_translation(self) -> None:
        base = self._pose(0.0, 0.0, 0.0)
        opt = self._pose(1.0, 2.0, 0.0)
        x, y = apply_pose_delta_to_point(base, opt, (5.0, 6.0))
        self.assertAlmostEqual(x, 6.0, places=9)
        self.assertAlmostEqual(y, 8.0, places=9)

    def test_positive_90_deg_rotation(self) -> None:
        # Baseline node at origin facing 0; optimized node rotated +90deg.
        # A tag at (1, 0) relative to node should move to (0, 1).
        base = self._pose(0.0, 0.0, 0.0)
        opt = self._pose(0.0, 0.0, math.pi / 2)
        x, y = apply_pose_delta_to_point(base, opt, (1.0, 0.0))
        self.assertAlmostEqual(x, 0.0, places=9)
        self.assertAlmostEqual(y, 1.0, places=9)

    def test_negative_90_deg_rotation(self) -> None:
        base = self._pose(0.0, 0.0, 0.0)
        opt = self._pose(0.0, 0.0, -math.pi / 2)
        x, y = apply_pose_delta_to_point(base, opt, (1.0, 0.0))
        self.assertAlmostEqual(x, 0.0, places=9)
        self.assertAlmostEqual(y, -1.0, places=9)

    def test_180_deg_rotation(self) -> None:
        base = self._pose(0.0, 0.0, 0.0)
        opt = self._pose(0.0, 0.0, math.pi)
        x, y = apply_pose_delta_to_point(base, opt, (1.0, 0.0))
        self.assertAlmostEqual(x, -1.0, places=9)
        self.assertAlmostEqual(y, 0.0, places=9)

    def test_translation_plus_rotation(self) -> None:
        # Baseline node at (2, 1) yaw 0; optimized at (3, 2) yaw 90deg.
        # Tag online at (4, 1) → relative to baseline: (2, 0).
        # After +90 rotation: (0, 2). After adding delta_t:
        #   delta_yaw = 90, R_delta * t_base = rotate (2,1) by 90 = (-1, 2)
        #   delta_t = (3,2) - (-1, 2) = (4, 0)
        #   final = R_delta * (4,1) + delta_t = (-1, 4) + (4, 0) = (3, 4)
        base = self._pose(2.0, 1.0, 0.0)
        opt = self._pose(3.0, 2.0, math.pi / 2)
        x, y = apply_pose_delta_to_point(base, opt, (4.0, 1.0))
        self.assertAlmostEqual(x, 3.0, places=9)
        self.assertAlmostEqual(y, 4.0, places=9)

    def test_angle_wrap_across_pi(self) -> None:
        # Baseline yaw just below +pi, optimized yaw just above -pi;
        # delta should be ~0, not ~2pi.
        base = self._pose(0.0, 0.0, math.pi - 0.01)
        opt = self._pose(0.0, 0.0, -math.pi + 0.01)
        x, y = apply_pose_delta_to_point(base, opt, (1.0, 0.0))
        # Delta yaw ~0.02 rad; point should barely move.
        self.assertAlmostEqual(x, math.cos(0.02), places=4)
        self.assertAlmostEqual(y, math.sin(0.02), places=4)

    def test_node_own_point_equals_optimized_translation(self) -> None:
        # If the tag sits exactly at the baseline node position, the result
        # equals the optimized node translation.
        base = self._pose(2.0, 3.0, 0.7)
        opt = self._pose(5.0, 7.0, 1.2)
        x, y = apply_pose_delta_to_point(base, opt, (2.0, 3.0))
        self.assertAlmostEqual(x, 5.0, places=9)
        self.assertAlmostEqual(y, 7.0, places=9)

    def test_non_finite_coordinates_raise(self) -> None:
        base = self._pose(0.0, 0.0, 0.0)
        opt = self._pose(float("nan"), 0.0, 0.0)
        with self.assertRaises(OfflineLocalizationError):
            apply_pose_delta_to_point(base, opt, (1.0, 0.0))


class TagObservationBindingTests(unittest.TestCase):
    def setUp(self) -> None:
        self.poses = [
            Pose(10, 100.0, 0.0, 0.0, 0.0),
            Pose(11, 101.0, 1.0, 0.0, 0.0),
        ]
        self.observation = {
            "frame_timestamp": 1.05,
            "node_timebase_frame_timestamp": 101.05,
            "node_timebase_offset_seconds": 100.0,
            "tracking_session_id": "tracking-1",
            "prior_map_sha256": "a" * 64,
            "floor_id": "1",
        }

    def _bind(self, observation: dict[str, object] | None = None):
        return bind_tag_observation_to_pose(
            self.poses,
            self.observation if observation is None else observation,
            expected_tracking_session_id="tracking-1",
            expected_map_hashes={"a" * 64},
            expected_floor_id="1",
            maximum_time_delta_seconds=0.2,
        )

    def test_frame_timestamp_binds_nearest_real_node(self) -> None:
        binding = self._bind()
        self.assertEqual(binding.node_index, 1)
        self.assertEqual(binding.binding_source, "frame_timestamp")
        self.assertAlmostEqual(binding.time_delta_seconds, 0.05)

    def test_explicit_node_id_is_used_and_audited(self) -> None:
        observation = {**self.observation, "nearest_node_id": 11}
        binding = self._bind(observation)
        self.assertEqual(binding.node_index, 1)
        self.assertEqual(binding.binding_source, "nearest_node_id")

    def test_missing_observation_and_timestamp_fail_closed(self) -> None:
        with self.assertRaisesRegex(OfflineLocalizationError, "missing"):
            bind_tag_observation_to_pose(
                self.poses,
                None,
                expected_tracking_session_id="tracking-1",
                expected_map_hashes={"a" * 64},
                expected_floor_id="1",
            )
        with self.assertRaisesRegex(OfflineLocalizationError, "timebase"):
            self._bind(
                {
                    key: value
                    for key, value in self.observation.items()
                    if key != "frame_timestamp"
                }
            )

    def test_identity_and_time_delta_mismatches_fail_closed(self) -> None:
        with self.assertRaisesRegex(OfflineLocalizationError, "tracking_session"):
            self._bind({**self.observation, "tracking_session_id": "wrong"})
        with self.assertRaisesRegex(OfflineLocalizationError, "prior_map"):
            self._bind({**self.observation, "prior_map_sha256": "b" * 64})
        with self.assertRaisesRegex(OfflineLocalizationError, "floor"):
            self._bind({**self.observation, "floor_id": "2"})
        with self.assertRaisesRegex(OfflineLocalizationError, "time_delta"):
            self._bind({
                **self.observation,
                "frame_timestamp": 10.0,
                "node_timebase_frame_timestamp": 110.0,
            })

    def test_missing_or_ambiguous_explicit_node_does_not_fallback(self) -> None:
        with self.assertRaisesRegex(OfflineLocalizationError, "not_found"):
            self._bind({**self.observation, "nearest_node_id": 99})
        duplicate = [self.poses[0], Pose(10, 100.0, 2.0, 0.0, 0.0)]
        with self.assertRaisesRegex(OfflineLocalizationError, "ambiguous"):
            bind_tag_observation_to_pose(
                duplicate,
                {
                    **self.observation,
                    "frame_timestamp": 0.0,
                    "node_timebase_frame_timestamp": 100.0,
                    "nearest_node_id": 10,
                },
                expected_tracking_session_id="tracking-1",
                expected_map_hashes={"a" * 64},
                expected_floor_id="1",
            )
        for invalid in (True, 10.5):
            with self.assertRaisesRegex(OfflineLocalizationError, "invalid"):
                self._bind({**self.observation, "nearest_node_id": invalid})


class ManualLocalizationTimebaseTests(unittest.TestCase):
    def setUp(self) -> None:
        self.poses = [
            Pose(21, 110.0, 0.0, 0.0, 0.0),
            Pose(22, 111.0, 1.0, 0.0, 0.0),
        ]
        self.event = {
            "format": "MarketScannerManualLocalizationEvent",
            "version": 2,
            "wall_clock_timestamp_unix": 1_800_000_000.0,
            "wall_clock_timestamp": "2027-01-15T08:00:00.000Z",
            "frame_timestamp": 11.05,
            "node_timebase_frame_timestamp": 111.05,
            "node_timebase_offset_seconds": 100.0,
            "nearest_node_id": None,
            "nearest_node_stamp": None,
            "node_time_delta_seconds": None,
            "node_binding_status": "frame_timestamp_only",
            "alignment_version": 2,
            "tracking_session_id": "tracking-1",
            "prior_map_sha256": "a" * 64,
            "floor_id": "1",
            "confirmed_map_pose": {"x_m": 1.0, "y_m": 2.0, "yaw_rad": 0.1},
            "arkit_pose": {"x_m": 0.9, "y_m": 2.0, "yaw_rad": 0.1},
        }

    def _bind(self, event: dict[str, object]):
        return bind_manual_localization_event_to_pose(
            self.poses,
            event,
            expected_tracking_session_id="tracking-1",
            expected_map_hash="a" * 64,
            expected_floor_id="1",
        )

    def test_v2_uses_frame_timestamp_not_wall_clock(self) -> None:
        binding = self._bind(self.event)
        self.assertEqual(binding.node_index, 1)
        self.assertAlmostEqual(binding.time_delta_seconds, 0.05)

    def test_exact_node_evidence_must_match_database_stamp_and_delta(self) -> None:
        event = {
            **self.event,
            "nearest_node_id": 22,
            "nearest_node_stamp": 111.0,
            "node_time_delta_seconds": 0.05,
            "node_binding_status": "matched",
        }
        self.assertEqual(self._bind(event).binding_source, "nearest_node_id")
        with self.assertRaisesRegex(OfflineLocalizationError, "stamp_mismatch"):
            self._bind({**event, "nearest_node_stamp": 110.5})
        with self.assertRaisesRegex(OfflineLocalizationError, "delta_mismatch"):
            self._bind({**event, "node_time_delta_seconds": 0.5})
        with self.assertRaisesRegex(OfflineLocalizationError, "binding_status"):
            self._bind({**event, "node_binding_status": "frame_timestamp_only"})

    def test_v3_requires_atomic_matched_node_snapshot_generation(self) -> None:
        event = {
            **self.event,
            "version": 3,
            "nearest_node_id": 22,
            "nearest_node_stamp": 111.0,
            "node_time_delta_seconds": 0.05,
            "node_binding_status": "matched",
            "node_binding_reason": "native_atomic_node_time_snapshot",
            "node_time_snapshot_generation": 7,
        }
        binding = self._bind(event)
        self.assertEqual(binding.binding_source, "nearest_node_id")
        for invalid_generation in (None, 0, -1, True, 1.5):
            with self.assertRaisesRegex(
                OfflineLocalizationError, "snapshot_generation_invalid"
            ):
                self._bind(
                    {
                        **event,
                        "node_time_snapshot_generation": invalid_generation,
                    }
                )
        with self.assertRaisesRegex(OfflineLocalizationError, "binding_status"):
            self._bind(
                {
                    **event,
                    "nearest_node_id": None,
                    "nearest_node_stamp": None,
                    "node_time_delta_seconds": None,
                    "node_binding_status": "frame_timestamp_only",
                }
            )

    def test_v2_requires_wall_clock_and_consistent_null_node_evidence(self) -> None:
        without_wall_clock = dict(self.event)
        without_wall_clock.pop("wall_clock_timestamp")
        with self.assertRaisesRegex(OfflineLocalizationError, "wall_clock"):
            self._bind(without_wall_clock)
        with self.assertRaisesRegex(OfflineLocalizationError, "contradictory"):
            self._bind({**self.event, "nearest_node_stamp": 111.0})

    def test_legacy_wrong_identity_and_ambiguous_time_are_rejected(self) -> None:
        with self.assertRaisesRegex(OfflineLocalizationError, "legacy"):
            self._bind({**self.event, "version": 1})
        with self.assertRaisesRegex(OfflineLocalizationError, "tracking_session"):
            self._bind({**self.event, "tracking_session_id": "wrong"})
        ambiguous = [
            Pose(1, 110.0, 0.0, 0.0, 0.0),
            Pose(2, 112.0, 0.0, 0.0, 0.0),
        ]
        with self.assertRaisesRegex(OfflineLocalizationError, "ambiguous"):
            bind_manual_localization_event_to_pose(
                ambiguous,
                {
                    **self.event,
                    "frame_timestamp": 11.0,
                    "node_timebase_frame_timestamp": 111.0,
                },
                expected_tracking_session_id="tracking-1",
                expected_map_hash="a" * 64,
                expected_floor_id="1",
            )


class RobustSE2OptimizerTests(unittest.TestCase):
    def test_drift_is_reduced_and_gross_map_constraint_is_rejected(self) -> None:
        baseline = [
            Pose(index, float(index), float(index), 0.08 * index, 0)
            for index in range(12)
        ]
        constraints = [
            AbsoluteConstraint(
                identifier="good-end",
                node_index=11,
                x=11,
                y=0,
                yaw=0,
                weight=12,
                kind="online_structure",
                source={},
            ),
            AbsoluteConstraint(
                identifier="wrong-basin",
                node_index=6,
                x=50,
                y=50,
                yaw=2,
                weight=20,
                kind="online_structure",
                source={},
            ),
        ]
        optimized, accepted, rejected = optimize_trajectory(baseline, constraints)
        self.assertLess(abs(optimized[-1].y), abs(baseline[-1].y))
        self.assertEqual([item["constraint_id"] for item in rejected], ["wrong-basin"])
        self.assertEqual([item["constraint_id"] for item in accepted], ["good-end"])

    def test_manual_anchor_is_tolerant_but_never_unbounded(self) -> None:
        baseline = [Pose(1, 0.0, 0.0, 0.0, 0.0)]
        constraints = [
            AbsoluteConstraint(
                identifier="within-test-tolerance",
                node_index=0,
                x=4.8,
                y=0.0,
                yaw=math.radians(29.0),
                weight=10.0,
                kind="manual_anchor",
                source={},
            ),
            AbsoluteConstraint(
                identifier="conflicting-phone-anchor",
                node_index=0,
                x=8.0,
                y=0.0,
                yaw=0.0,
                weight=100.0,
                kind="manual_anchor",
                source={},
            ),
        ]
        _optimized, accepted, rejected = optimize_trajectory(baseline, constraints)
        self.assertEqual(
            [item["constraint_id"] for item in accepted],
            ["within-test-tolerance"],
        )
        self.assertEqual(
            [item["constraint_id"] for item in rejected],
            ["conflicting-phone-anchor"],
        )
        self.assertEqual(rejected[0]["reason"], "manual_anchor_safety_gate")

    def test_road_soft_constraints_are_local_bounded_and_direction_aware(self) -> None:
        baseline = [
            Pose(index + 1, float(index), float(index), 0.2, 0.1)
            for index in range(10)
        ]
        graph = {
            "crosses": [
                {
                    "id": "aisle-1",
                    "floor_id": "1",
                    "width_m": 2.0,
                    "points_m": [[0.0, 0.0], [9.0, 0.0]],
                }
            ]
        }
        constraints = build_road_soft_constraints(
            baseline, graph, "1", stride=3
        )
        self.assertEqual(len(constraints), 4)
        self.assertTrue(all(item.kind == "road_soft" for item in constraints))
        self.assertTrue(all(abs(item.y) < 1.0e-9 for item in constraints))
        self.assertTrue(all(0 < item.weight <= 0.35 for item in constraints))
        self.assertTrue(
            all(item.translation_sigma_m is not None for item in constraints)
        )
        self.assertTrue(
            all(
                item.yaw_sigma_rad is not None
                and 0 < item.yaw_sigma_rad <= math.pi
                for item in constraints
            )
        )
        weak = build_road_soft_constraints(
            [Pose(1, 0.0, 2.0, 1.7, 0.0)], graph, "1", stride=1
        )
        self.assertEqual(len(weak), 1)
        self.assertGreater(weak[0].translation_sigma_m, math.pi)
        self.assertEqual(weak[0].yaw_sigma_rad, math.pi)
        far = [
            Pose(index + 1, float(index), float(index), 5.0, 0)
            for index in range(10)
        ]
        self.assertEqual(build_road_soft_constraints(far, graph, "1"), [])

    def test_aisle_sequence_uses_final_trajectory_geometry(self) -> None:
        road_graph = {
            "crosses": [
                {
                    "id": "A",
                    "floor_id": "1",
                    "width_m": 1.0,
                    "points_m": [[0.0, 0.0], [4.0, 0.0]],
                },
                {
                    "id": "B",
                    "floor_id": "1",
                    "width_m": 1.0,
                    "points_m": [[6.0, 0.0], [10.0, 0.0]],
                },
            ]
        }
        trajectory = [
            Pose(index + 1, float(index), float(index), 0.1, 0.0)
            for index in range(11)
        ]
        sequence = infer_aisle_switch_sequence(
            trajectory, road_graph, "1", stride=1
        )
        self.assertEqual([item["corridor_id"] for item in sequence], ["A", "B"])
        self.assertTrue(
            all(item["source"] == "final_trajectory_geometry" for item in sequence)
        )
        self.assertEqual([item["direction"] for item in sequence], ["forward", "forward"])
        self.assertFalse(sequence[0]["possible_silent_switch"])
        self.assertTrue(sequence[1]["possible_silent_switch"])
    def test_manual_aisle_assignment_creates_constraints_for_interval(self) -> None:
        baseline = [
            Pose(index + 1, float(index), float(index), 2.0, 0)
            for index in range(10)
        ]
        graph = {
            "crosses": [
                {
                    "id": "aisle-1",
                    "floor_id": "1",
                    "points_m": [[0.0, 0.0], [9.0, 0.0]],
                }
            ],
            "nodes": [],
            "edges": [],
        }
        event = {
            "event_id": "edit-1",
            "object_id": "interval-1",
            "new_value": {
                "aisle_id": "aisle-1",
                "start_timestamp": 2.0,
                "end_timestamp": 6.0,
            },
        }
        constraints = build_manual_aisle_constraints(
            baseline, graph, "1", event, stride=2
        )
        self.assertEqual([item.node_index for item in constraints], [2, 4, 6])
        self.assertTrue(
            all(item.kind == "manual_aisle_assignment" for item in constraints)
        )
        self.assertTrue(all(abs(item.y) < 1.0e-9 for item in constraints))


class ShelfAssociationSafetyTests(unittest.TestCase):
    """Wave 3B: occluded, endpoint-ambiguous, and multi-candidate tag
    association must fail-closed with only suggested values."""

    def _shelf_element(self, code: str, coords: list[tuple[float, float]], shape_type: str = "MapShelf") -> dict:
        return {
            "id": code,
            "code": code,
            "shape_type": shape_type,
            "row_flag": "R1",
            "cross_code": "C1",
            "center_m": [
                sum(p[0] for p in coords) / len(coords),
                sum(p[1] for p in coords) / len(coords),
            ],
            "geometry": {
                "type": "Polygon",
                "coordinates": [list(p) for p in coords],
            },
        }

    def _tag(self, x: float, y: float) -> dict[str, object]:
        return {
            "tag_id": "tag-1",
            "final_map_position": {"x_m": x, "y_m": y, "height_m": 1.2},
            "localization_confidence": 0.8,
            "measurement_confidence": 0.8,
            "needs_review": False,
        }

    def test_near_side_auto_confirmed(self) -> None:
        # Shelf from (0,0) to (4,0) — camera at (2, 2) looking at near side.
        shelf = self._shelf_element("SHELF-01", [(0.0, 0.0), (4.0, 0.0), (4.0, -0.5), (0.0, -0.5)])
        second = self._shelf_element("SHELF-02", [(0.0, -0.8), (4.0, -0.8), (4.0, -1.3), (0.0, -1.3)])
        tag = self._tag(2.0, 0.15)
        result = _associate_tag(tag, [shelf, second], (2.0, 2.0))
        self.assertEqual(result.get("shelf_code"), "SHELF-01")
        self.assertFalse(result.get("needs_review"))
        self.assertEqual(result["association_audit"]["status"], "auto_confirmed")
        self.assertTrue(result["association_audit"]["candidate_search_complete"])
        self.assertEqual(
            result["association_audit"]["candidate_search_scope"],
            "all_stable_edges_within_radius",
        )

    def test_no_independent_second_candidate_fails_closed(self) -> None:
        shelf = self._shelf_element("SHELF-01", [(0.0, 0.0), (4.0, 0.0), (4.0, -0.5), (0.0, -0.5)])
        result = _associate_tag(self._tag(2.0, 0.15), [shelf], (2.0, 2.0))
        self.assertTrue(result.get("needs_review"))
        self.assertEqual(result.get("approval_status"), "pending")
        self.assertNotIn("shelf_code", result)

    def test_user_confirmed_business_fields_are_not_overwritten(self) -> None:
        shelf = self._shelf_element("AUTO", [(0.0, 0.0), (4.0, 0.0), (4.0, -0.5), (0.0, -0.5)])
        second = self._shelf_element("SECOND", [(0.0, -0.8), (4.0, -0.8), (4.0, -1.3), (0.0, -1.3)])
        tag = self._tag(2.0, 0.15)
        tag.update({
            "user_confirmed": True,
            "shelf_code": "HUMAN",
            "shelf_side": "A",
            "distance_from_shelf_start_cm": 25.0,
        })
        result = _associate_tag(tag, [shelf, second], (2.0, 2.0))
        self.assertEqual(result.get("shelf_code"), "HUMAN")
        self.assertEqual(result.get("shelf_side"), "A")
        self.assertTrue(result.get("needs_review"))
        self.assertEqual(result.get("approval_status"), "pending")
        self.assertEqual(
            result.get("suggested_association", {}).get("shelf_code"), "AUTO"
        )

    def test_collinear_overlap_counts_as_an_occlusion(self) -> None:
        hit = _segment_intersection(
            (0.0, 0.0), (4.0, 0.0), (1.0, 0.0), (2.0, 0.0)
        )
        self.assertIsNotNone(hit)
        assert hit is not None
        self.assertAlmostEqual(hit[0], 0.25)
        self.assertAlmostEqual(hit[2], 1.0)

    def test_far_side_fail_closed(self) -> None:
        # Camera at (2, 2) on the near side, tag on the far side at (2, -0.6).
        shelf = self._shelf_element("SHELF-01", [(0.0, 0.0), (4.0, 0.0), (4.0, -0.5), (0.0, -0.5)])
        tag = self._tag(2.0, -0.6)
        result = _associate_tag(tag, [shelf], (2.0, 2.0))
        self.assertTrue(result.get("needs_review"))
        self.assertIn("suggested_association", result)
        self.assertNotIn("shelf_code", result)

    def test_no_camera_fail_closed(self) -> None:
        shelf = self._shelf_element("SHELF-01", [(0.0, 0.0), (4.0, 0.0), (4.0, -0.5), (0.0, -0.5)])
        tag = self._tag(2.0, 0.15)
        result = _associate_tag(tag, [shelf])
        self.assertTrue(result.get("needs_review"))
        self.assertIn("suggested_association", result)

    def test_occluded_by_front_shelf(self) -> None:
        # Front shelf at y=-1, rear at y=-3. Camera at (3, 2), tag at (3, -3.1).
        front = self._shelf_element("FRONT", [(1.0, -1.0), (5.0, -1.0), (5.0, -1.5), (1.0, -1.5)])
        rear = self._shelf_element("REAR", [(1.0, -3.0), (5.0, -3.0), (5.0, -3.5), (1.0, -3.5)])
        tag = self._tag(3.0, -3.1)
        result = _associate_tag(tag, [front, rear], (3.0, 2.0))
        # The rear shelf should be occluded by the front shelf.
        self.assertTrue(result.get("needs_review"))

    def test_pillar_occludes(self) -> None:
        pillar = self._shelf_element("PILLAR", [(2.8, 0.0), (3.2, 0.0), (3.2, -0.4), (2.8, -0.4)], "MapPillar")
        shelf = self._shelf_element("SHELF", [(2.0, -1.0), (4.0, -1.0), (4.0, -1.5), (2.0, -1.5)])
        tag = self._tag(3.0, -1.1)
        result = _associate_tag(tag, [pillar, shelf], (3.0, 2.0))
        self.assertTrue(result.get("needs_review"))

    def test_endpoint_ambiguity_triggers_review(self) -> None:
        shelf = self._shelf_element("SHELF", [(0.0, 0.0), (4.0, 0.0), (4.0, -0.5), (0.0, -0.5)])
        tag = self._tag(0.1, 0.15)  # very close to the left endpoint
        result = _associate_tag(tag, [shelf], (0.1, 2.0))
        self.assertTrue(result.get("needs_review"))


class ManualEditJournalTests(unittest.TestCase):
    def test_append_after_undo_discards_redo_branch(self) -> None:
        journal = new_manual_edits("a" * 64, "b" * 64)
        journal = append_manual_edit(
            journal,
            {"type": "approve_tag", "object_id": "tag-1", "new_value": True},
        )
        journal = append_manual_edit(
            journal,
            {"type": "disable_constraint", "object_id": "c-1", "new_value": True},
        )
        journal = move_manual_edit_cursor(journal, -1)
        self.assertEqual(journal["cursor"], 1)
        journal = move_manual_edit_cursor(journal, 1)
        self.assertEqual(journal["cursor"], 2)
        journal = move_manual_edit_cursor(journal, -1)
        journal = append_manual_edit(
            journal,
            {"type": "edit_tag", "object_id": "tag-1", "new_value": {"height_cm": 120}},
        )
        self.assertEqual(journal["cursor"], 2)
        self.assertEqual(journal["events"][-1]["type"], "edit_tag")

    def test_manual_tag_edit_replayed_after_automatic_values_wins(self) -> None:
        journal = new_manual_edits("a" * 64, "b" * 64)
        journal = append_manual_edit(
            journal,
            {
                "type": "edit_tag",
                "object_id": "tag-1",
                "new_value": {
                    "shelf_code": "MANUAL-SHELF",
                    "shelf_side": "B",
                    "distance_from_shelf_start_cm": 123.0,
                },
            },
        )
        _, tags, _ = apply_manual_edits(
            [],
            [
                {
                    "tag_id": "tag-1",
                    "shelf_code": "AUTO-SHELF",
                    "shelf_side": "A",
                    "distance_from_shelf_start_cm": 10.0,
                }
            ],
            journal,
        )
        self.assertEqual(tags[0]["shelf_code"], "MANUAL-SHELF")
        self.assertEqual(tags[0]["shelf_side"], "B")
        self.assertTrue(tags[0]["manually_modified"])

    def test_invalid_manual_edit_is_rejected_before_journal_append(self) -> None:
        journal = new_manual_edits("a" * 64, "b" * 64)
        with self.assertRaisesRegex(ValueError, "start/end"):
            append_manual_edit(
                journal,
                {
                    "type": "assign_interval_to_aisle",
                    "object_id": "interval-1",
                    "new_value": {"aisle_id": "aisle-1"},
                },
            )

    def test_tag_edit_whitelist_and_ranges_fail_closed(self) -> None:
        journal = new_manual_edits("a" * 64, "b" * 64)
        with self.assertRaisesRegex(ValueError, "not editable"):
            append_manual_edit(
                journal,
                {
                    "type": "edit_tag",
                    "object_id": "tag-1",
                    "new_value": {"approval_status": "approved"},
                },
            )
        with self.assertRaisesRegex(ValueError, "outside"):
            append_manual_edit(
                journal,
                {
                    "type": "edit_tag",
                    "object_id": "tag-1",
                    "new_value": {"height_cm": 501},
                },
            )

    def test_manual_approval_requires_a_real_map_edge_and_valid_offset(self) -> None:
        shelf = {
            "shape_type": "MapShelf",
            "code": "S1",
            "yaw_rad": 0.0,
            "source": {"width": 400, "height": 50},
            "geometry": {
                "coordinates": [[0.0, 0.0], [4.0, 0.0], [4.0, -0.5], [0.0, -0.5]]
            },
        }
        tag = {
            "tag_id": "tag-1",
            "final_map_position": {"x_m": 2.0, "y_m": 0.0},
            "shelf_code": "S1",
            "shelf_side": "A",
            "distance_from_shelf_start_cm": 200,
            "needs_review": True,
            "approval_status": "pending",
        }
        journal = append_manual_edit(
            new_manual_edits("a" * 64, "b" * 64),
            {"type": "approve_tag", "object_id": "tag-1", "new_value": None},
        )
        _, approved, _ = apply_manual_edits([], [dict(tag)], journal, elements=[shelf])
        self.assertEqual(approved[0]["approval_status"], "approved")
        self.assertTrue(approved[0]["user_confirmed"])

        invalid = {**tag, "distance_from_shelf_start_cm": 500}
        _, rejected, _ = apply_manual_edits([], [invalid], journal, elements=[shelf])
        self.assertEqual(rejected[0]["approval_status"], "pending")
        self.assertTrue(rejected[0]["needs_review"])


class LocalizedPipelineTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        workbook = self.root / "fixture.xlsx"
        write_workbook(workbook, fixture_rows())
        self.prior_map = convert_workbook(workbook, self.root / "PriorMap-fixture")
        manifest = json.loads((self.prior_map / "manifest.json").read_text())
        self.session = self.root / "SupermarketSession-fixture"
        self.segment = self.session / "segment_0001"
        self.segment.mkdir(parents=True)
        json_write(
            self.segment / "metadata.json",
            {
                "scanMode": "continuous_streaming",
                "finalized": True,
                "workflowMode": "prior_map_localized",
                "trackingSessionId": "tracking-1",
                "priorMapId": manifest["prior_map_id"],
                "priorMapSha256": manifest["source_sha256"],
                "floorId": "1",
                "initialMapPose": {"x_m": 1.5, "y_m": -2.5, "yaw_rad": 0},
                "localizedPriceTags": "localized_price_tags.json",
                "localizedPriceTagCount": 1,
                "captureHealth": {
                    "localizationRequiredWriteFailureCount": 0,
                    "localizationTraceRecordCount": 20,
                    "localizationConstraintRecordCount": 2,
                    "localizationStateEventCount": 3,
                    "localizationEvidenceComplete": True,
                },
                "processingEligibility": {
                    "status": "eligible",
                    "blockers": [],
                },
            },
        )
        self.source_database = self.segment / "rtabmap_segment_0001.db"
        self.node_timebase_offset = 1_700_000_000.0
        connection = sqlite3.connect(self.source_database)
        try:
            connection.execute("CREATE TABLE Node(id INTEGER PRIMARY KEY, stamp REAL NOT NULL)")
            connection.executemany(
                "INSERT INTO Node(id, stamp) VALUES(?, ?)",
                [
                    (index + 1, self.node_timebase_offset + float(index))
                    for index in range(20)
                ],
            )
            connection.commit()
        finally:
            connection.close()
        self.optimized_database = self.root / "optimized.db"
        connection = sqlite3.connect(self.optimized_database)
        try:
            connection.execute("CREATE TABLE Node(id INTEGER PRIMARY KEY, stamp REAL NOT NULL)")
            connection.executemany(
                "INSERT INTO Node(id, stamp) VALUES(?, ?)",
                [
                    (index + 1, self.node_timebase_offset + float(index))
                    for index in range(20)
                ],
            )
            connection.commit()
        finally:
            connection.close()
        self.poses = [
            Pose(
                index + 1,
                self.node_timebase_offset + float(index),
                float(index) * 0.5,
                0.05 * index,
                0,
            )
            for index in range(20)
        ]
        trace = [
            {
                "format": "MarketScannerLocalizationTrace",
                "version": 1,
                "timestamp": float(index),
                "nodeTimebaseTimestamp": self.node_timebase_offset + float(index),
                "nodeTimebaseOffsetSeconds": self.node_timebase_offset,
                "trackingSessionId": "tracking-1",
                "priorMapSha256": manifest["source_sha256"],
                "floorId": "1",
                "estimated_pose": {
                    "x_m": 1.5 + 0.5 * index,
                    "y_m": -2.5,
                    "yaw_rad": 0,
                },
                "raw_pose": {
                    "x_m": 1.5 + 0.5 * index,
                    "y_m": -2.5,
                    "yaw_rad": 0,
                },
                "trackingState": "normal",
                "localizationState": "stable",
                "confidence": 0.9,
                "road_candidates": [{"edge_id": "1:1--2", "distance_m": 0.1}],
            }
            for index in range(20)
        ]
        constraints = [
            {
                "format": "MarketScannerLocalizationConstraint",
                "version": 1,
                "timestamp": 19.0,
                "node_timebase_timestamp": self.node_timebase_offset + 19.0,
                "node_timebase_offset_seconds": self.node_timebase_offset,
                "tracking_session_id": "tracking-1",
                "prior_map_sha256": manifest["source_sha256"],
                "floor_id": "1",
                "accepted": True,
                "predicted_pose": {"x_m": 11.0, "y_m": -2.5, "yaw_rad": 0},
                "estimated_pose": {"x_m": 11.0, "y_m": -2.5, "yaw_rad": 0},
                "uniqueness": 0.8,
            },
            {
                "format": "MarketScannerLocalizationConstraint",
                "version": 1,
                "timestamp": 10.0,
                "node_timebase_timestamp": self.node_timebase_offset + 10.0,
                "node_timebase_offset_seconds": self.node_timebase_offset,
                "tracking_session_id": "tracking-1",
                "prior_map_sha256": manifest["source_sha256"],
                "floor_id": "1",
                "accepted": True,
                "predicted_pose": {"x_m": 6.5, "y_m": -2.5, "yaw_rad": 0},
                "estimated_pose": {"x_m": 99.0, "y_m": 99.0, "yaw_rad": 2.0},
                "uniqueness": 0.9,
            },
        ]
        jsonl_write(self.segment / "localization_trace.jsonl", trace)
        jsonl_write(self.segment / "localization_constraints.jsonl", constraints)
        jsonl_write(self.segment / "manual_localization_events.jsonl", [])
        jsonl_write(
            self.segment / "localization_events.jsonl",
            [
                {
                    "format": "MarketScannerLocalizationStateEvent",
                    "version": 1,
                    "timestamp": timestamp,
                    "node_timebase_timestamp": self.node_timebase_offset + timestamp,
                    "node_timebase_offset_seconds": self.node_timebase_offset,
                    "state": state,
                    "reason": reason,
                    "confidence": 0.8,
                    "tracking_session_id": "tracking-1",
                    "prior_map_sha256": manifest["source_sha256"],
                    "floor_id": "1",
                }
                for timestamp, state, reason in (
                    (0.0, "usable", "initial"),
                    (5.0, "weak", "low_uniqueness"),
                    (8.0, "lost", "stale"),
                    (10.0, "stable", "recovered"),
                )
            ],
        )
        jsonl_write(
            self.segment / "tag_observations.jsonl",
            [{
                "format": "MarketScannerPriceTagObservation",
                "version": 1,
                "observation_id": "obs-1",
                "frame_timestamp": 10.0,
                "node_timebase_frame_timestamp": self.node_timebase_offset + 10.0,
                "node_timebase_offset_seconds": self.node_timebase_offset,
                "tracking_session_id": "tracking-1",
                "prior_map_sha256": manifest["source_sha256"],
                "floor_id": "1",
                "raw_map_position": {"x_m": 2.0, "y_m": -2.0, "height_m": 1.2},
                "payload": "690000000001",
                "symbology": "EAN13",
            }],
        )
        json_write(
            self.segment / "localized_price_tags.json",
            [
                {
                    "format": "MarketScannerLocalizedPriceTag",
                    "version": 1,
                    "tag_id": "tag-1",
                    "observation_id": "obs-1",
                    "payload": "690000000001",
                    "symbology": "EAN13",
                    "timestamp": 10.0,
                    "tracking_session_id": "tracking-1",
                    "prior_map_id": manifest["prior_map_id"],
                    "prior_map_sha256": manifest["source_sha256"],
                    "floor_id": "1",
                    "raw_map_position": {
                        "x_m": 2.0,
                        "y_m": -2.0,
                        "height_m": 1.2,
                    },
                    "snapped_map_position": {
                        "x_m": 2.1,
                        "y_m": -2.0,
                        "height_m": 1.2,
                    },
                    "localization_confidence": 0.8,
                    "measurement_confidence": 0.8,
                    "association_confidence": 0.8,
                    "measurement_method": "depth_plane",
                    "needs_review": False,
                    "user_confirmed": False,
                }
            ],
        )

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def test_end_to_end_is_reproducible_and_source_database_is_immutable(self) -> None:
        source_hash = hashlib.sha256(self.source_database.read_bytes()).hexdigest()
        first_output = self.root / "localized-first"
        second_output = self.root / "localized-second"
        first = process_localized_session(
            self.prior_map,
            self.session,
            self.poses,
            self.source_database,
            self.optimized_database,
            first_output,
        )
        second = process_localized_session(
            self.prior_map,
            self.session,
            self.poses,
            self.source_database,
            self.optimized_database,
            second_output,
        )
        self.assertEqual(
            hashlib.sha256(self.source_database.read_bytes()).hexdigest(),
            source_hash,
        )
        self.assertEqual(first, second)
        first_version = LocalizedVersionStore(first_output).current()
        second_version = LocalizedVersionStore(second_output).current()
        self.assertIsNotNone(first_version)
        self.assertIsNotNone(second_version)
        assert first_version is not None
        assert second_version is not None
        for name in (
            "session_input_manifest.json",
            "processing_manifest.json",
            "optimized_map_trajectory.geojson",
            "localization_report.json",
            "factor_graph_report.json",
            "review_items.json",
            "localized_review.json",
            "manual_edits.json",
            "localized_price_tags.json",
            "localized_price_tags.csv",
            "localized_price_tags.geojson",
            "shelf_tag_index.json",
            "audit_log.jsonl",
        ):
            self.assertEqual(
                (first_version.version_dir / name).read_bytes(),
                (second_version.version_dir / name).read_bytes(),
                name,
            )
        self.assertEqual(first["rejected_constraint_count"], 1)
        self.assertTrue(first["allow_draft"])
        self.assertEqual(first["solver"]["type"], "bounded_correction_field")
        self.assertFalse(first["solver"]["published_capable"])
        self.assertIn(
            "absolute_constraint_residual_diagnostic_before", first["solver"]
        )
        self.assertIn("maximum_local_relative_translation_change_m", first["solver"])
        self.assertFalse(first["publish_gate"]["passed"])
        self.assertIn(
            "solver_not_full_relative_se2_factor_graph",
            {item["code"] for item in first["publish_gate"]["blockers"]},
        )
        self.assertEqual(first["weak_lost_duration_seconds"], 5.0)
        # source_database_immutable is in source_manifest, not report
        self.assertTrue(
            json.loads((first_version.version_dir / "source_manifest.json").read_text())[
                "source_database_immutable"
            ]
        )
        source_manifest_text = (
            first_version.version_dir / "source_manifest.json"
        ).read_text()
        self.assertNotIn(str(self.root), source_manifest_text)
        session_input = json.loads(
            (first_version.version_dir / "session_input_manifest.json").read_text()
        )
        source_manifest = json.loads(source_manifest_text)
        processing_manifest = json.loads(
            (first_version.version_dir / "processing_manifest.json").read_text()
        )
        manual_edits = json.loads(
            (first_version.version_dir / "manual_edits.json").read_text()
        )
        self.assertEqual(session_input_bundle_sha256(session_input), session_input["bundle_sha256"])
        self.assertEqual(source_manifest["version"], 2)
        self.assertEqual(processing_manifest["version"], 2)
        self.assertEqual(manual_edits["version"], 4)
        self.assertEqual(
            {
                session_input["bundle_sha256"],
                source_manifest["session_input_bundle_sha256"],
                processing_manifest["session_input_bundle_sha256"],
                manual_edits["session_input_bundle_sha256"],
            },
            {session_input["bundle_sha256"]},
        )
        self.assertEqual(
            {
                session_input["input_identity_id"],
                source_manifest["input_identity_id"],
                processing_manifest["input_identity_id"],
                manual_edits["input_identity_id"],
            },
            {first_version.input_identity_id},
        )
        local_state = LocalizedVersionStore(first_output).local_inputs_for(
            first_version
        )["paths"]
        self.assertEqual(
            Path(local_state["source_database"]), self.source_database.resolve()
        )
        tag = json.loads(
            (first_version.version_dir / "localized_price_tags.json").read_text()
        )[0]
        self.assertEqual(tag["online_map_position"]["x_m"], 2.0)
        self.assertEqual(tag["transform_audit"]["bound_node_id"], 11)
        self.assertEqual(
            tag["transform_audit"]["source_position_field"],
            "tag.raw_map_position",
        )

    def test_session_input_manifest_is_deterministic_and_binds_every_required_file(self) -> None:
        first = build_session_input_manifest(self.segment, self.source_database)
        second = build_session_input_manifest(self.segment, self.source_database)
        self.assertEqual(first, second)
        self.assertEqual(
            [entry["role"] for entry in first["files"]],
            [
                "metadata",
                "source_database",
                "localization_trace.jsonl",
                "localization_constraints.jsonl",
                "localization_events.jsonl",
                "manual_localization_events.jsonl",
                "tag_observations.jsonl",
                "localized_price_tags.json",
            ],
        )
        self.assertEqual(first["source_database_sha256"], first["files"][1]["sha256"])
        self.assertEqual(session_input_bundle_sha256(first), first["bundle_sha256"])

        paths = [self.segment / "metadata.json", self.source_database] + [
            self.segment / name
            for name in (
                "localization_trace.jsonl",
                "localization_constraints.jsonl",
                "localization_events.jsonl",
                "manual_localization_events.jsonl",
                "tag_observations.jsonl",
                "localized_price_tags.json",
            )
        ]
        for path in paths:
            with self.subTest(path=path.name):
                original = path.read_bytes()
                path.write_bytes(original + b" ")
                changed = build_session_input_manifest(self.segment, self.source_database)
                self.assertNotEqual(changed["bundle_sha256"], first["bundle_sha256"])
                path.write_bytes(original)

    def test_session_input_manifest_rejects_symlink_and_inflight_change(self) -> None:
        events = self.segment / "localization_events.jsonl"
        original = events.read_bytes()
        target = self.root / "events-target.jsonl"
        target.write_bytes(original)
        events.unlink()
        events.symlink_to(target)
        with self.assertRaisesRegex(OfflineLocalizationError, "regular file"):
            build_session_input_manifest(self.segment, self.source_database)
        events.unlink()
        events.write_bytes(original)

        real_builder = build_session_input_manifest
        calls = 0

        def mutate_before_final_check(segment: Path, database: Path) -> dict:
            nonlocal calls
            calls += 1
            if calls == 3:
                trace = segment / "localization_trace.jsonl"
                trace.write_bytes(trace.read_bytes() + b"\n")
            return real_builder(segment, database)

        output = self.root / "localized-input-changed-during-render"
        with (
            mock.patch(
                "tools.PriorMap.offline_localization.build_session_input_manifest",
                side_effect=mutate_before_final_check,
            ),
            self.assertRaisesRegex(OfflineLocalizationError, "changed during"),
        ):
            process_localized_session(
                self.prior_map,
                self.session,
                self.poses,
                self.source_database,
                self.optimized_database,
                output,
            )
        self.assertIsNone(LocalizedVersionStore(output).current())

    def _upgrade_fixture_to_recovery_manifest_v2(self) -> Path:
        """Bind the fixture session to P7R6 recovery evidence (manifest v2).

        Adds the capture watermark and writes one valid terminal lifecycle
        record that reconciles with it.
        """

        metadata_path = self.segment / "metadata.json"
        metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
        metadata["captureHealth"].update(
            {
                "localizationRecoveryEventCount": 1,
                "localizationLastRecoveryEpisodeId": 1,
                "localizationLastRecoveryFinishedAtUptime": 14.5,
            }
        )
        json_write(metadata_path, metadata)
        manifest = json.loads((self.prior_map / "manifest.json").read_text())
        recovery_path = self.segment / "localization_recovery_events.jsonl"
        jsonl_write(
            recovery_path,
            [
                {
                    "format": "MarketScannerRecoveryLifecycleEvent",
                    "version": 2,
                    "tracking_session_id": "tracking-1",
                    "prior_map_id": manifest["prior_map_id"],
                    "prior_map_sha256": manifest["source_sha256"],
                    "floor_id": "1",
                    "episode_id": 1,
                    "reason": "reliable_rtabmap_loop",
                    "outcome": "converged",
                    "episode_automatic": False,
                    "started_at_uptime": 10.0,
                    "deadline_uptime": 40.0,
                    "finished_at_uptime": 14.5,
                    "elapsed_ms": 4500.0,
                    "maximum_valid_attempts": 40,
                    "valid_matcher_attempts": 7,
                    "accepted_corrections": 2,
                    "trigger_count": 1,
                    "automatic_trigger_count": 0,
                    "reliable_loop_trigger_count": 1,
                    "last_trigger_reason": "reliable_rtabmap_loop",
                    "last_trigger_at_uptime": 10.0,
                    "trigger_records": [
                        {
                            "reason": "reliable_rtabmap_loop",
                            "automatic": False,
                            "at_uptime": 10.0,
                        }
                    ],
                    "fresh_support_frames": 4,
                    "completion_frame_step_applied": False,
                }
            ],
        )
        return recovery_path

    def test_p1_p3_recovery_file_bytes_bind_the_v2_bundle_sha(self) -> None:
        recovery_path = self._upgrade_fixture_to_recovery_manifest_v2()
        baseline = build_session_input_manifest(self.segment, self.source_database)
        self.assertEqual(baseline["version"], 2)
        self.assertNotIn("recovery_evidence_binding", baseline)
        self.assertIn(
            "localization_recovery_events.jsonl",
            [entry["file"] for entry in baseline["files"]],
        )
        # P1: any byte change in the recovery sidecar moves the bundle SHA.
        original = recovery_path.read_bytes()
        recovery_path.write_bytes(original[:-1] + b"\x00" + original[-1:])
        mutated = build_session_input_manifest(self.segment, self.source_database)
        self.assertNotEqual(mutated["bundle_sha256"], baseline["bundle_sha256"])
        recovery_path.write_bytes(original)
        # P3: even a same-length replacement must move the bundle SHA.
        same_length = b"x" * len(original)
        self.assertEqual(len(same_length), len(original))
        recovery_path.write_bytes(same_length)
        swapped = build_session_input_manifest(self.segment, self.source_database)
        self.assertNotEqual(swapped["bundle_sha256"], baseline["bundle_sha256"])
        recovery_path.write_bytes(original)
        restored = build_session_input_manifest(self.segment, self.source_database)
        self.assertEqual(restored["bundle_sha256"], baseline["bundle_sha256"])

    def test_p2_missing_recovery_file_fails_the_v2_manifest_build(self) -> None:
        recovery_path = self._upgrade_fixture_to_recovery_manifest_v2()
        recovery_path.unlink()
        with self.assertRaisesRegex(
            OfflineLocalizationError,
            "localization_recovery_events.jsonl is missing",
        ):
            build_session_input_manifest(self.segment, self.source_database)

    def test_p4_duplicate_recovery_episode_fails_processing(self) -> None:
        recovery_path = self._upgrade_fixture_to_recovery_manifest_v2()
        duplicated = recovery_path.read_bytes()
        recovery_path.write_bytes(duplicated + duplicated)
        output = self.root / "localized-duplicate-recovery-episode"
        with self.assertRaisesRegex(OfflineLocalizationError, "recovery"):
            process_localized_session(
                self.prior_map,
                self.session,
                self.poses,
                self.source_database,
                self.optimized_database,
                output,
            )
        self.assertIsNone(LocalizedVersionStore(output).current())

    def test_p5_p6_legacy_sessions_stay_v1_and_unbound(self) -> None:
        # P5: a legacy session without the watermark builds manifest v1 with
        # the explicit unbound marker and stays readable.
        legacy = build_session_input_manifest(self.segment, self.source_database)
        self.assertEqual(legacy["version"], 1)
        self.assertEqual(
            legacy["recovery_evidence_binding"],
            RECOVERY_EVIDENCE_UNBOUND_LEGACY,
        )
        self.assertNotIn(
            "localization_recovery_events.jsonl",
            [entry["file"] for entry in legacy["files"]],
        )
        self.assertEqual(session_input_bundle_sha256(legacy), legacy["bundle_sha256"])
        # P6: a stray recovery sidecar must never upgrade a legacy session to
        # v2; the watermark key decides the manifest version.
        jsonl_write(
            self.segment / "localization_recovery_events.jsonl",
            [{"format": "MarketScannerRecoveryLifecycleEvent", "version": 2}],
        )
        still_legacy = build_session_input_manifest(
            self.segment, self.source_database
        )
        self.assertEqual(still_legacy["version"], 1)
        self.assertEqual(
            still_legacy["recovery_evidence_binding"],
            RECOVERY_EVIDENCE_UNBOUND_LEGACY,
        )
        self.assertNotIn(
            "localization_recovery_events.jsonl",
            [entry["file"] for entry in still_legacy["files"]],
        )
        self.assertEqual(still_legacy["bundle_sha256"], legacy["bundle_sha256"])

    def test_p7_p8_v2_manifest_is_ordered_and_platform_stable(self) -> None:
        self._upgrade_fixture_to_recovery_manifest_v2()
        # P7: deterministic file order and canonical encoding.
        first = build_session_input_manifest(self.segment, self.source_database)
        second = build_session_input_manifest(self.segment, self.source_database)
        self.assertEqual(first, second)
        self.assertEqual(
            [entry["role"] for entry in first["files"]],
            ["metadata", "source_database", *SESSION_INPUT_FILE_NAMES_V2[1:]],
        )
        self.assertEqual(
            first["files"][5]["file"],
            "localization_recovery_events.jsonl",
        )
        self.assertEqual(session_input_bundle_sha256(first), first["bundle_sha256"])
        # P8: the canonical bundle SHA depends only on the canonical payload
        # (bare file names, sorted keys), never on OS paths, so a Windows
        # reader hashing the same payload reproduces the identical digest.
        for entry in first["files"]:
            self.assertNotIn("/", entry["file"])
            self.assertNotIn("\\", entry["file"])
        transported = json.loads(json.dumps(first))
        self.assertEqual(
            session_input_bundle_sha256(transported), first["bundle_sha256"]
        )
        transported_with_audit = dict(transported)
        transported_with_audit["input_identity_id"] = "e" * 64
        self.assertEqual(
            session_input_bundle_sha256(transported_with_audit),
            first["bundle_sha256"],
        )

    def test_output_root_rejects_a_different_session_identity(self) -> None:
        output = self.root / "localized-bound-output"
        process_localized_session(
            self.prior_map,
            self.session,
            self.poses,
            self.source_database,
            self.optimized_database,
            output,
        )
        store = LocalizedVersionStore(output)
        original = store.current()
        self.assertIsNotNone(original)
        assert original is not None
        original_local_inputs = store.local_inputs_for(original)

        copied_session = self.root / "second-session"
        shutil.copytree(self.session, copied_session)
        copied_database = (
            copied_session / "segment_0001" / self.source_database.name
        )
        with self.assertRaisesRegex(
            OfflineLocalizationError, "different session input identity"
        ):
            process_localized_session(
                self.prior_map,
                copied_session,
                self.poses,
                copied_database,
                self.optimized_database,
                output,
            )
        self.assertEqual(store.current(), original)
        self.assertEqual(store.local_inputs_for(original), original_local_inputs)

    def test_manual_journal_v2_v3_migration_requires_verified_bundle(self) -> None:
        session_input = build_session_input_manifest(self.segment, self.source_database)
        package_manifest = json.loads(
            (self.prior_map / "package_manifest.json").read_text()
        )
        source_sha = session_input["source_database_sha256"]
        optimized_sha = hashlib.sha256(self.optimized_database.read_bytes()).hexdigest()
        identity_id = "d" * 64
        for version in (2, 3):
            with self.subTest(version=version):
                journal = {
                    "format": "MarketScannerManualEdits",
                    "version": version,
                    "revision": 2,
                    "prior_map_sha256": package_manifest["package_sha256"],
                    "source_session_sha256": source_sha,
                    "source_database_sha256": source_sha,
                    "optimized_database_sha256": optimized_sha,
                    "processing_parameter_sha256": (
                        _legacy_processing_parameter_sha256_v3()
                        if version == 3
                        else processing_parameter_sha256()
                    ),
                    "cursor": 0,
                    "events": [],
                    "audit_events": [],
                }
                with self.assertRaisesRegex(OfflineLocalizationError, "verified input bundle"):
                    upgrade_manual_edits_v2(
                        journal,
                        package_manifest["package_sha256"],
                        source_sha,
                        optimized_sha,
                        "",
                        identity_id,
                    )
                upgraded = upgrade_manual_edits_v2(
                    journal,
                    package_manifest["package_sha256"],
                    source_sha,
                    optimized_sha,
                    session_input["bundle_sha256"],
                    identity_id,
                )
                self.assertEqual(upgraded["version"], 4)
                self.assertEqual(
                    upgraded["session_input_bundle_sha256"],
                    session_input["bundle_sha256"],
                )
                self.assertEqual(upgraded["input_identity_id"], identity_id)
                self.assertEqual(
                    upgraded["audit_events"][-1]["event_id"],
                    f"migration-v{version}-to-v4",
                )

    def test_missing_tag_observation_never_defaults_to_node_zero(self) -> None:
        jsonl_write(self.segment / "tag_observations.jsonl", [])
        output = self.root / "localized-missing-observation"
        with self.assertRaisesRegex(
            OfflineLocalizationError, "tag_observations.jsonl"
        ):
            process_localized_session(
                self.prior_map,
                self.session,
                self.poses,
                self.source_database,
                self.optimized_database,
                output,
            )
        self.assertIsNone(LocalizedVersionStore(output).current())

    def test_legacy_manual_wall_clock_event_is_audited_not_applied(self) -> None:
        jsonl_write(
            self.segment / "manual_localization_events.jsonl",
            [{
                "format": "MarketScannerManualLocalizationEvent",
                "version": 1,
                "timestampUnix": 1_800_000_000.0,
                "confirmedMapPose": {"x_m": 50.0, "y_m": 50.0, "yaw_rad": 0.0},
            }],
        )
        output = self.root / "localized-legacy-manual"
        report = process_localized_session(
            self.prior_map,
            self.session,
            self.poses,
            self.source_database,
            self.optimized_database,
            output,
        )
        self.assertEqual(report["accepted_manual_anchor_count"], 0)
        self.assertEqual(
            report["manual_localization_event_audit"][0]["reason"],
            "manual_event_legacy_or_unknown_version",
        )
        self.assertFalse(report["review_gate"]["passed"])
        self.assertIn(
            "rejected_manual_localization_events_present",
            {item["code"] for item in report["review_gate"]["blockers"]},
        )

    def test_manual_v3_atomic_snapshot_is_applied(self) -> None:
        manifest = json.loads((self.prior_map / "manifest.json").read_text())
        jsonl_write(
            self.segment / "manual_localization_events.jsonl",
            [{
                "format": "MarketScannerManualLocalizationEvent",
                "version": 3,
                "wall_clock_timestamp": "2027-01-15T08:00:00.000Z",
                "wall_clock_timestamp_unix": 1_800_000_000.0,
                "frame_timestamp": 10.0,
                "node_timebase_frame_timestamp": self.node_timebase_offset + 10.0,
                "node_timebase_offset_seconds": self.node_timebase_offset,
                "nearest_node_id": 11,
                "nearest_node_stamp": self.node_timebase_offset + 10.0,
                "node_time_delta_seconds": 0.0,
                "node_time_snapshot_generation": 9,
                "node_binding_status": "matched",
                "node_binding_reason": "native_atomic_node_time_snapshot",
                "alignment_version": 2,
                "tracking_session_id": "tracking-1",
                "prior_map_sha256": manifest["source_sha256"],
                "floor_id": "1",
                "arkit_pose": {"x_m": 5.0, "y_m": 0.0, "yaw_rad": 0.0},
                "confirmed_map_pose": {
                    "x_m": 6.5,
                    "y_m": -2.5,
                    "yaw_rad": 0.0,
                },
            }],
        )
        output = self.root / "localized-manual-v3"
        report = process_localized_session(
            self.prior_map,
            self.session,
            self.poses,
            self.source_database,
            self.optimized_database,
            output,
        )
        self.assertEqual(report["accepted_manual_anchor_count"], 1)
        self.assertEqual(
            report["manual_localization_event_audit"][0]["status"], "accepted"
        )

    def test_diagnostic_mode_ignores_unsafe_manual_anchor_and_phone_conflicts(self) -> None:
        manifest = json.loads((self.prior_map / "manifest.json").read_text())
        jsonl_write(
            self.segment / "manual_localization_events.jsonl",
            [{
                "format": "MarketScannerManualLocalizationEvent",
                "version": 3,
                "wall_clock_timestamp": "2027-01-15T08:00:00.000Z",
                "wall_clock_timestamp_unix": 1_800_000_000.0,
                "frame_timestamp": 10.0,
                "node_timebase_frame_timestamp": self.node_timebase_offset + 10.0,
                "node_timebase_offset_seconds": self.node_timebase_offset,
                "nearest_node_id": 11,
                "nearest_node_stamp": self.node_timebase_offset + 10.0,
                "node_time_delta_seconds": 0.0,
                "node_time_snapshot_generation": 9,
                "node_binding_status": "matched",
                "node_binding_reason": "native_atomic_node_time_snapshot",
                "alignment_version": 2,
                "tracking_session_id": "tracking-1",
                "prior_map_sha256": manifest["source_sha256"],
                "floor_id": "1",
                "arkit_pose": {"x_m": 5.0, "y_m": 0.0, "yaw_rad": 0.0},
                "confirmed_map_pose": {
                    "x_m": 100.0,
                    "y_m": 100.0,
                    "yaw_rad": 0.0,
                },
            }],
        )
        strict_output = self.root / "localized-unsafe-strict"
        strict = process_localized_session(
            self.prior_map,
            self.session,
            self.poses,
            self.source_database,
            self.optimized_database,
            strict_output,
        )
        self.assertLess(strict["maximum_correction_m"], 2.0)
        self.assertIn(
            "manual_anchor_safety_gate",
            {item["reason"] for item in strict["high_residual_intervals"]},
        )
        self.assertTrue(strict["allow_draft"])
        self.assertTrue(strict["current_updated"])
        self.assertIsNotNone(LocalizedVersionStore(strict_output).current())

        diagnostic_output = self.root / "localized-unsafe-diagnostic"
        diagnostic = process_localized_session(
            self.prior_map,
            self.session,
            self.poses,
            self.source_database,
            self.optimized_database,
            diagnostic_output,
            replay_parameters={
                **DEFAULT_REPLAY_PARAMETERS,
                "diagnostic_mode": True,
            },
        )
        self.assertTrue(diagnostic["diagnostic_mode"])
        self.assertTrue(diagnostic["diagnostic_only"])
        self.assertTrue(diagnostic["allow_draft"])
        self.assertTrue(diagnostic["current_updated"])
        self.assertEqual(diagnostic["publish_state"], "draft")
        self.assertEqual(
            diagnostic["ignored_conflicting_source_constraint_count"], 1
        )
        self.assertFalse(diagnostic["publish_gate"]["passed"])
        self.assertIn(
            "diagnostic_mode_enabled",
            {item["code"] for item in diagnostic["publish_gate"]["blockers"]},
        )
        self.assertIsNotNone(LocalizedVersionStore(diagnostic_output).current())

    def test_stale_or_duplicate_manual_alignment_version_is_rejected(self) -> None:
        manifest = json.loads((self.prior_map / "manifest.json").read_text())
        base = {
            "format": "MarketScannerManualLocalizationEvent",
            "version": 2,
            "wall_clock_timestamp": "2027-01-15T08:00:00.000Z",
            "wall_clock_timestamp_unix": 1_800_000_000.0,
            "nearest_node_id": None,
            "nearest_node_stamp": None,
            "node_time_delta_seconds": None,
            "node_binding_status": "frame_timestamp_only",
            "node_timebase_offset_seconds": self.node_timebase_offset,
            "tracking_session_id": "tracking-1",
            "prior_map_sha256": manifest["source_sha256"],
            "floor_id": "1",
            "arkit_pose": {"x_m": 5.0, "y_m": 0.0, "yaw_rad": 0.0},
            "confirmed_map_pose": {"x_m": 6.5, "y_m": -2.5, "yaw_rad": 0.0},
        }
        jsonl_write(
            self.segment / "manual_localization_events.jsonl",
            [
                {
                    **base,
                    "frame_timestamp": 10.0,
                    "node_timebase_frame_timestamp": self.node_timebase_offset + 10.0,
                    "alignment_version": 2,
                },
                {
                    **base,
                    "frame_timestamp": 11.0,
                    "node_timebase_frame_timestamp": self.node_timebase_offset + 11.0,
                    "alignment_version": 1,
                },
            ],
        )
        report = process_localized_session(
            self.prior_map,
            self.session,
            self.poses,
            self.source_database,
            self.optimized_database,
            self.root / "stale-manual-alignment",
        )
        self.assertEqual(report["accepted_manual_anchor_count"], 1)
        self.assertEqual(
            report["manual_localization_event_audit"][1]["reason"],
            "manual_event_alignment_version_stale_or_duplicate",
        )
        self.assertFalse(report["review_gate"]["passed"])

    def test_sidecar_invalid_utf8_and_nonfinite_numbers_fail_closed(self) -> None:
        trace_path = self.segment / "localization_trace.jsonl"
        trace_path.write_bytes(trace_path.read_bytes() + b"\xff\n")
        with self.assertRaisesRegex(OfflineLocalizationError, "Invalid UTF-8"):
            process_localized_session(
                self.prior_map,
                self.session,
                self.poses,
                self.source_database,
                self.optimized_database,
                self.root / "invalid-utf8",
            )

        self.setUp_sidecar_trace_after_corruption()
        events_path = self.segment / "localization_events.jsonl"
        event = json.loads(events_path.read_text().splitlines()[0])
        event["timestamp"] = float("nan")
        jsonl_write(events_path, [event])
        with self.assertRaisesRegex(OfflineLocalizationError, "Non-finite"):
            process_localized_session(
                self.prior_map,
                self.session,
                self.poses,
                self.source_database,
                self.optimized_database,
                self.root / "invalid-nan",
            )

    def setUp_sidecar_trace_after_corruption(self) -> None:
        manifest = json.loads((self.prior_map / "manifest.json").read_text())
        jsonl_write(
            self.segment / "localization_trace.jsonl",
            [
                {
                    "format": "MarketScannerLocalizationTrace",
                    "version": 1,
                    "timestamp": float(index),
                    "nodeTimebaseTimestamp": self.node_timebase_offset + float(index),
                    "nodeTimebaseOffsetSeconds": self.node_timebase_offset,
                    "trackingSessionId": "tracking-1",
                    "priorMapSha256": manifest["source_sha256"],
                    "floorId": "1",
                    "estimated_pose": {
                        "x_m": 1.5 + 0.5 * index,
                        "y_m": -2.5,
                        "yaw_rad": 0,
                    },
                    "raw_pose": {
                        "x_m": 1.5 + 0.5 * index,
                        "y_m": -2.5,
                        "yaw_rad": 0,
                    },
                    "trackingState": "normal",
                    "localizationState": "stable",
                    "confidence": 0.9,
                }
                for index in range(20)
            ],
        )

    def test_sidecar_identity_and_duplicate_observation_ids_fail_closed(self) -> None:
        constraints_path = self.segment / "localization_constraints.jsonl"
        constraints = [
            json.loads(line) for line in constraints_path.read_text().splitlines()
        ]
        constraints[0]["floor_id"] = "wrong-floor"
        jsonl_write(constraints_path, constraints)
        with self.assertRaisesRegex(OfflineLocalizationError, "Floor mismatch"):
            process_localized_session(
                self.prior_map,
                self.session,
                self.poses,
                self.source_database,
                self.optimized_database,
                self.root / "identity-mismatch",
            )

        constraints[0]["floor_id"] = "1"
        jsonl_write(constraints_path, constraints)
        observations_path = self.segment / "tag_observations.jsonl"
        observation = json.loads(observations_path.read_text().splitlines()[0])
        jsonl_write(observations_path, [observation, observation])
        with self.assertRaisesRegex(OfflineLocalizationError, "duplicate observation_id"):
            process_localized_session(
                self.prior_map,
                self.session,
                self.poses,
                self.source_database,
                self.optimized_database,
                self.root / "duplicate-observation",
            )

    def test_localized_tag_contract_and_required_state_events_fail_closed(self) -> None:
        tags_path = self.segment / "localized_price_tags.json"
        tags = json.loads(tags_path.read_text())
        json_write(tags_path, [tags[0], tags[0]])
        metadata_path = self.segment / "metadata.json"
        metadata = json.loads(metadata_path.read_text())
        metadata["localizedPriceTagCount"] = 2
        json_write(metadata_path, metadata)
        with self.assertRaisesRegex(OfflineLocalizationError, "missing/duplicate IDs"):
            process_localized_session(
                self.prior_map,
                self.session,
                self.poses,
                self.source_database,
                self.optimized_database,
                self.root / "duplicate-tags",
            )

        json_write(tags_path, tags)
        metadata["localizedPriceTagCount"] = 1
        json_write(metadata_path, metadata)
        (self.segment / "localization_events.jsonl").unlink()
        with self.assertRaisesRegex(OfflineLocalizationError, "Required sidecar"):
            process_localized_session(
                self.prior_map,
                self.session,
                self.poses,
                self.source_database,
                self.optimized_database,
                self.root / "missing-events",
            )

    def test_prior_map_processing_requires_complete_capture_write_health(self) -> None:
        metadata_path = self.segment / "metadata.json"
        original = json.loads(metadata_path.read_text(encoding="utf-8"))
        cases = {
            "missing-health": lambda value: value.pop("captureHealth"),
            "recorded-failure": lambda value: value["captureHealth"].update(
                {
                    "localizationRequiredWriteFailureCount": 1,
                    "localizationEvidenceComplete": False,
                }
            ),
            "ineligible": lambda value: value["processingEligibility"].update(
                {"status": "invalid", "blockers": ["sidecar_write_failed"]}
            ),
        }
        for name, mutate in cases.items():
            with self.subTest(name=name):
                metadata = json.loads(json.dumps(original))
                mutate(metadata)
                json_write(metadata_path, metadata)
                with self.assertRaisesRegex(
                    OfflineLocalizationError, "complete prior-map sidecar"
                ):
                    process_localized_session(
                        self.prior_map,
                        self.session,
                        self.poses,
                        self.source_database,
                        self.optimized_database,
                        self.root / f"incomplete-write-health-{name}",
                    )
        json_write(metadata_path, original)

    def test_tag_file_count_and_tag_observation_content_are_fail_closed(self) -> None:
        tags_path = self.segment / "localized_price_tags.json"
        original_tags = tags_path.read_text()
        tags_path.unlink()
        with self.assertRaisesRegex(OfflineLocalizationError, "tag.*missing"):
            process_localized_session(
                self.prior_map,
                self.session,
                self.poses,
                self.source_database,
                self.optimized_database,
                self.root / "missing-tags",
            )

        tags_path.write_text(original_tags, encoding="utf-8")
        observations_path = self.segment / "tag_observations.jsonl"
        observation = json.loads(observations_path.read_text().splitlines()[0])
        observation["payload"] = "different-product"
        jsonl_write(observations_path, [observation])
        output = self.root / "mismatched-tag-observation"
        report = process_localized_session(
            self.prior_map,
            self.session,
            self.poses,
            self.source_database,
            self.optimized_database,
            output,
        )
        self.assertTrue(report["current_updated"])
        self.assertFalse(report["review_gate"]["passed"])
        self.assertIn(
            "tag_and_observation_payload_mismatch",
            json.loads(
                (LocalizedVersionStore(output).resolve_version(report["version_id"])
                 .version_dir / "localized_price_tags.json").read_text()
            )[0]["review_reasons"],
        )

    def test_final_tag_identity_and_optional_business_types_fail_closed(self) -> None:
        tags_path = self.segment / "localized_price_tags.json"
        original = json.loads(tags_path.read_text())
        wrong_map = [dict(original[0], prior_map_id="another-map")]
        json_write(tags_path, wrong_map)
        with self.assertRaisesRegex(OfflineLocalizationError, "prior_map_id"):
            process_localized_session(
                self.prior_map,
                self.session,
                self.poses,
                self.source_database,
                self.optimized_database,
                self.root / "wrong-final-tag-map-id",
            )

        invalid_height = [dict(original[0], height_cm=True)]
        json_write(tags_path, invalid_height)
        with self.assertRaisesRegex(OfflineLocalizationError, "height_cm"):
            process_localized_session(
                self.prior_map,
                self.session,
                self.poses,
                self.source_database,
                self.optimized_database,
                self.root / "wrong-final-tag-height",
            )


# P7R6A: shared recovery lifecycle fixtures. The device-side strict parser
# and the PC reader must classify every fixture into the same stable
# category, so one file is accepted by both or rejected by both.
RECOVERY_FIXTURES_DIR = (
    Path(__file__).with_name("fixtures") / "recovery_lifecycle"
)

EXPECTED_RECOVERY_FIXTURE_CATEGORIES = {
    "valid_v1.jsonl": "PASS",
    "valid_v2.jsonl": "PASS",
    "valid_mixed_v1_v2.jsonl": "PASS",
    "missing_final_newline.jsonl": "missing_final_newline",
    "blank_line.jsonl": "blank_record",
    "duplicate_episode.jsonl": "duplicate_episode",
    "out_of_order_episode.jsonl": "episode_order_invalid",
    "finish_time_regression.jsonl": "finish_order_invalid",
    "unknown_field.jsonl": "unknown_field",
    "identity_mismatch.jsonl": "identity_mismatch",
}

_PYTHON_RECOVERY_ERROR_PATTERNS = (
    ("Missing final newline", "missing_final_newline"),
    ("Blank JSONL record", "blank_record"),
    ("Oversized record", "record_too_large"),
    ("Invalid UTF-8", "invalid_utf8"),
    ("Invalid JSON", "invalid_json"),
    ("Non-object record", "non_object"),
    ("Format mismatch", "format_mismatch"),
    ("Version mismatch", "version_mismatch"),
    ("Tracking-session mismatch", "identity_mismatch"),
    ("Prior-map hash mismatch", "identity_mismatch"),
    ("Floor mismatch", "identity_mismatch"),
    ("recovery_unknown_field", "unknown_field"),
    ("recovery_outcome_invalid", "outcome_invalid"),
    ("recovery_cancellation_reason_invalid", "cancellation_reason_invalid"),
    ("recovery_trigger_records_invalid", "trigger_records_invalid"),
    ("recovery_business_schema_invalid", "business_schema_invalid"),
    ("recovery_episode_order_invalid", "episode_order_invalid"),
    ("recovery_finish_order_invalid", "finish_order_invalid"),
    ("duplicate episode_id", "duplicate_episode"),
    ("Invalid timestamp", "business_schema_invalid"),
)


def classify_python_recovery_error(message: str) -> str:
    for pattern, category in _PYTHON_RECOVERY_ERROR_PATTERNS:
        if pattern in message:
            return category
    return "unknown_error"


def python_recovery_fixture_category(path: Path) -> str:
    """Runs the PC reader over one fixture and returns the stable category
    shared with the device-side parser."""

    try:
        values, _ = _read_jsonl(
            path,
            RECOVERY_EVENT_CONTRACT,
            session_id="session-a",
            expected_map_hash="a" * 64,
            expected_floor_id="1",
        )
        _validate_recovery_event_sequence(values)
    except OfflineLocalizationError as exc:
        return classify_python_recovery_error(str(exc))
    return "PASS"


class RecoveryLifecycleFixtureContractTests(unittest.TestCase):
    def test_pc_reader_fixture_categories_are_stable(self) -> None:
        self.assertEqual(
            sorted(path.name for path in RECOVERY_FIXTURES_DIR.glob("*.jsonl")),
            sorted(EXPECTED_RECOVERY_FIXTURE_CATEGORIES),
            "the shared recovery fixture set must stay complete",
        )
        for name in sorted(EXPECTED_RECOVERY_FIXTURE_CATEGORIES):
            category = python_recovery_fixture_category(
                RECOVERY_FIXTURES_DIR / name
            )
            self.assertEqual(
                category,
                EXPECTED_RECOVERY_FIXTURE_CATEGORIES[name],
                name,
            )


if __name__ == "__main__":
    unittest.main()
