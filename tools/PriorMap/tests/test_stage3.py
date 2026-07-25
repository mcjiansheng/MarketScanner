from __future__ import annotations

import hashlib
import json
import tempfile
import unittest
from pathlib import Path

from tools.PriorMap.offline_localization import (
    Pose,
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
                "timestamp": float(index),
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
                "timestamp": 19.0,
                "accepted": True,
                "estimated_pose": {"x_m": 11.0, "y_m": -2.5, "yaw_rad": 0},
                "uniqueness": 0.8,
            },
            {
                "timestamp": 10.0,
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
                {"timestamp": 0.0, "state": "usable", "reason": "initial"},
                {"timestamp": 5.0, "state": "weak", "reason": "low_uniqueness"},
                {"timestamp": 8.0, "state": "lost", "reason": "stale"},
                {"timestamp": 10.0, "state": "stable", "reason": "recovered"},
            ],
        )
        jsonl_write(
            self.segment / "tag_observations.jsonl",
            [{"observation_id": "obs-1", "frame_timestamp": 10.0}],
        )
        json_write(
            self.segment / "localized_price_tags.json",
            [
                {
                    "tag_id": "tag-1",
                    "observation_id": "obs-1",
                    "payload": "690000000001",
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
                (first_output / name).read_bytes(),
                (second_output / name).read_bytes(),
                name,
            )
        self.assertEqual(first["rejected_constraint_count"], 1)
        self.assertFalse(first["automatic_publish_allowed"])
        self.assertEqual(first["weak_lost_duration_seconds"], 5.0)
        self.assertTrue(
            json.loads((first_output / "source_manifest.json").read_text())[
                "source_database_immutable"
            ]
        )


if __name__ == "__main__":
    unittest.main()
