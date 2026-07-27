from __future__ import annotations

import hashlib
import json
import math
import tempfile
import unittest
from pathlib import Path

from tools.PriorMap.offline_localization import (
    Pose,
    OfflineLocalizationError,
    _associate_tag,
    _segment_intersection,
    apply_pose_delta_to_point,
    bind_tag_observation_to_pose,
    bind_manual_localization_event_to_pose,
    append_manual_edit,
    build_road_soft_constraints,
    build_manual_aisle_constraints,
    apply_manual_edits,
    move_manual_edit_cursor,
    new_manual_edits,
    optimize_trajectory,
    process_localized_session,
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
            "frame_timestamp": 101.05,
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
        with self.assertRaisesRegex(OfflineLocalizationError, "timestamp"):
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
            self._bind({**self.observation, "frame_timestamp": 110.0})

    def test_missing_or_ambiguous_explicit_node_does_not_fallback(self) -> None:
        with self.assertRaisesRegex(OfflineLocalizationError, "not_found"):
            self._bind({**self.observation, "nearest_node_id": 99})
        duplicate = [self.poses[0], Pose(10, 100.0, 2.0, 0.0, 0.0)]
        with self.assertRaisesRegex(OfflineLocalizationError, "ambiguous"):
            bind_tag_observation_to_pose(
                duplicate,
                {**self.observation, "frame_timestamp": 100.0, "nearest_node_id": 10},
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
            Pose(21, 10.0, 0.0, 0.0, 0.0),
            Pose(22, 11.0, 1.0, 0.0, 0.0),
        ]
        self.event = {
            "format": "MarketScannerManualLocalizationEvent",
            "version": 2,
            "wall_clock_timestamp_unix": 1_800_000_000.0,
            "frame_timestamp": 11.05,
            "nearest_node_id": None,
            "nearest_node_stamp": None,
            "node_time_delta_seconds": None,
            "node_binding_status": "frame_timestamp_only",
            "alignment_version": 2,
            "tracking_session_id": "tracking-1",
            "prior_map_sha256": "a" * 64,
            "floor_id": "1",
            "confirmed_map_pose": {"x_m": 1.0, "y_m": 2.0, "yaw_rad": 0.1},
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
            "nearest_node_stamp": 11.0,
            "node_time_delta_seconds": 0.05,
            "node_binding_status": "matched",
        }
        self.assertEqual(self._bind(event).binding_source, "nearest_node_id")
        with self.assertRaisesRegex(OfflineLocalizationError, "stamp_mismatch"):
            self._bind({**event, "nearest_node_stamp": 10.5})
        with self.assertRaisesRegex(OfflineLocalizationError, "delta_mismatch"):
            self._bind({**event, "node_time_delta_seconds": 0.5})

    def test_legacy_wrong_identity_and_ambiguous_time_are_rejected(self) -> None:
        with self.assertRaisesRegex(OfflineLocalizationError, "legacy"):
            self._bind({**self.event, "version": 1})
        with self.assertRaisesRegex(OfflineLocalizationError, "tracking_session"):
            self._bind({**self.event, "tracking_session_id": "wrong"})
        ambiguous = [
            Pose(1, 10.0, 0.0, 0.0, 0.0),
            Pose(2, 12.0, 0.0, 0.0, 0.0),
        ]
        with self.assertRaisesRegex(OfflineLocalizationError, "ambiguous"):
            bind_manual_localization_event_to_pose(
                ambiguous,
                {**self.event, "frame_timestamp": 11.0},
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
        far = [
            Pose(index + 1, float(index), float(index), 5.0, 0)
            for index in range(10)
        ]
        self.assertEqual(build_road_soft_constraints(far, graph, "1"), [])

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
            },
        )
        self.source_database = self.segment / "rtabmap_segment_0001.db"
        self.source_database.write_bytes(b"read-only-source-database-fixture")
        self.optimized_database = self.root / "optimized.db"
        self.optimized_database.write_bytes(b"derived-optimized-database-fixture")
        self.poses = [
            Pose(index + 1, float(index), float(index) * 0.5, 0.05 * index, 0)
            for index in range(20)
        ]
        trace = [
            {
                "format": "MarketScannerLocalizationTrace",
                "version": 1,
                "timestamp": float(index),
                "trackingSessionId": "tracking-1",
                "priorMapSha256": manifest["source_sha256"],
                "floorId": "1",
                "estimated_pose": {
                    "x_m": 1.5 + 0.5 * index,
                    "y_m": -2.5,
                    "yaw_rad": 0,
                },
                "road_candidates": [{"edge_id": "1:1--2", "distance_m": 0.1}],
            }
            for index in range(20)
        ]
        constraints = [
            {
                "format": "MarketScannerLocalizationConstraint",
                "version": 1,
                "timestamp": 19.0,
                "tracking_session_id": "tracking-1",
                "prior_map_sha256": manifest["source_sha256"],
                "floor_id": "1",
                "accepted": True,
                "estimated_pose": {"x_m": 11.0, "y_m": -2.5, "yaw_rad": 0},
                "uniqueness": 0.8,
            },
            {
                "format": "MarketScannerLocalizationConstraint",
                "version": 1,
                "timestamp": 10.0,
                "tracking_session_id": "tracking-1",
                "prior_map_sha256": manifest["source_sha256"],
                "floor_id": "1",
                "accepted": True,
                "estimated_pose": {"x_m": 99.0, "y_m": 99.0, "yaw_rad": 2.0},
                "uniqueness": 0.9,
            },
        ]
        jsonl_write(self.segment / "localization_trace.jsonl", trace)
        jsonl_write(self.segment / "localization_constraints.jsonl", constraints)
        jsonl_write(
            self.segment / "localization_events.jsonl",
            [
                {
                    "format": "MarketScannerLocalizationStateEvent",
                    "version": 1,
                    "timestamp": timestamp,
                    "state": state,
                    "reason": reason,
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
                "tracking_session_id": "tracking-1",
                "prior_map_sha256": manifest["source_sha256"],
                "floor_id": "1",
                "raw_map_position": {"x_m": 2.0, "y_m": -2.0, "height_m": 1.2},
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
                    "timestamp": 10.0,
                    "tracking_session_id": "tracking-1",
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
                    "needs_review": False,
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
            "processing_manifest.json",
            "optimized_map_trajectory.geojson",
            "localization_report.json",
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
        self.assertEqual(first["weak_lost_duration_seconds"], 5.0)
        # source_database_immutable is in source_manifest, not report
        self.assertTrue(
            json.loads((first_version.version_dir / "source_manifest.json").read_text())[
                "source_database_immutable"
            ]
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
                "trackingSessionId": "tracking-1",
                "priorMapSha256": json.loads(
                    (self.prior_map / "manifest.json").read_text()
                )["source_sha256"],
                "floorId": "1",
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
                    "trackingSessionId": "tracking-1",
                    "priorMapSha256": manifest["source_sha256"],
                    "floorId": "1",
                    "estimated_pose": {
                        "x_m": 1.5 + 0.5 * index,
                        "y_m": -2.5,
                        "yaw_rad": 0,
                    },
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


if __name__ == "__main__":
    unittest.main()
