from __future__ import annotations

import json
import tempfile
from pathlib import Path
import unittest

from tools.PriorMap.offline_localization import (
    Pose,
    _shelf_localization_calibration_gate,
    build_shelf_face_constraints,
)
from tools.PriorMap.factor_graph_runner import _write_priors
from tools.PriorMap.shelf_localization_evidence import (
    ShelfEvidenceError,
    read_shelf_localization_evidence,
    validate_shelf_localization_records,
)


SESSION = "tracking-1"
MAP_SHA = "a" * 64
DISTANCE_SHA = "b" * 64
SHARED_FIXTURE = (
    Path(__file__).with_name("fixtures")
    / "shelf_localization"
    / "valid_v2.json"
)


def metadata(**updates: object) -> dict[str, object]:
    value: dict[str, object] = {
        "trackingSessionId": SESSION,
        "priorMapSha256": MAP_SHA,
        "shelfLocalizationEvidenceComplete": True,
        "poseEpochTransitionCount": 0,
        "poseEpochTransitionLastSequence": None,
        "corridorHypothesisCount": 1,
        "corridorHypothesisLastSequence": 1,
        "shelfObservationWindowCount": 2,
        "shelfObservationWindowLastSequence": 2,
        "shelfLoopEventCount": 1,
        "shelfLoopEventLastSequence": 1,
    }
    value.update(updates)
    return value


def corridor() -> dict[str, object]:
    return {
        "format": "MarketScannerCorridorHypotheses",
        "version": 2,
        "tracking_session_id": SESSION,
        "sequence": 1,
        "node_id": 1,
        "node_timestamp": 1.0,
        "node_map_id": 0,
        "epoch": 1,
        "component": 0,
        "hypotheses": [{
            "corridor_id": "aisle-1", "distance_score": 0.9,
            "structure_basin_score": 0.8, "topology_reachable": True,
            "score": 0.875,
        }],
        "top1_top2_margin": 0.9,
        "tracking_state": "TRACKING",
        "selected_corridor_id": "aisle-1",
        "selected_shelf_segment_id": "shelf-1",
        "selected_shelf_side": "right",
        "low_confidence_reasons": [],
        "penetration_audit": {
            "node_inside_shelf_count": 0,
            "segment_crossing_count": 0,
        },
        "covariance": {"along_m": 0.8, "cross_m": 0.1, "yaw_rad": 0.05},
        "write_watermark": 1,
    }


def window(sequence: int, side: str, normal_x: float) -> dict[str, object]:
    first_node = 1 if sequence == 1 else 6
    return {
        "format": "MarketScannerShelfObservationWindow",
        "version": 2,
        "tracking_session_id": SESSION,
        "sequence": sequence,
        "window_id": f"window-{sequence}",
        "node_range": [first_node, first_node + 4],
        "time_range": [float(first_node), float(first_node + 4)],
        "epoch": 1,
        "component": 0,
        "side": side,
        "face_normal_map": {"x": normal_x, "y": 0.0},
        "shelf_candidates": [{"shelf_segment_id": "shelf-1", "score": 0.9}],
        "observation_node_count": 5,
        "geometry": {
            "sample_count": 20, "inlier_count": 16, "inlier_ratio": 0.8,
            "residual_median_m": 0.1, "residual_maximum_m": 0.2,
        },
        "coverage_angle_rad": 0.5,
        "endcap_visible": False,
        # One rejected dynamic sample out of five is not dominant.
        "dynamic_rejection_count": 1,
        "prior_map_sha256": MAP_SHA,
        "distance_field_sha256": DISTANCE_SHA,
        "write_watermark": sequence,
    }


def loop(*, accepted: bool = True) -> dict[str, object]:
    return {
        "format": "MarketScannerShelfLoopEvent",
        "version": 2,
        "tracking_session_id": SESSION,
        "sequence": 1,
        "shelf_segment_id": "shelf-1",
        "window_ids": ["window-1", "window-2"],
        "sides": ["right", "left"],
        "epoch": 1,
        "component": 0,
        "loop_from_node": 5,
        "loop_to_node": 10,
        "rtab_loop_id": 1,
        "rtab_loop_residual_m": None,
        "rtab_graph_optimization_max_error": 0.1,
        "phone_shelf_se2": {"dx_m": 1.0, "dy_m": 1.2, "dyaw_rad": 0.0},
        "consistency": {
            "relative_pose_delta_m": 0.2,
            "relative_pose_delta_yaw_rad": 0.05,
            "inlier_ratio": 0.8,
            "residual_median_m": 0.1,
            "residual_maximum_m": 0.2,
        },
        "accepted": accepted,
        "reason": "frozen_criteria_passed" if accepted else "epoch_bridge_missing",
        "calibration_status": "CALIBRATION_PENDING",
        "write_watermark": 1,
    }


def values() -> dict[str, tuple[dict[str, object], ...]]:
    return {
        "pose_epoch_transitions.jsonl": (),
        "corridor_hypotheses.jsonl": (corridor(),),
        "shelf_observation_windows.jsonl": (
            window(1, "right", 1.0),
            window(2, "left", -1.0),
        ),
        "shelf_loop_events.jsonl": (loop(),),
    }


class ShelfLocalizationEvidenceTests(unittest.TestCase):
    def test_shared_v2_fixture_is_accepted_by_pc_reader(self) -> None:
        fixture = json.loads(SHARED_FIXTURE.read_text(encoding="utf-8"))
        records = {
            name: tuple(items) for name, items in fixture["records"].items()
        }
        shared_metadata = {
            "trackingSessionId": fixture["tracking_session_id"],
            "priorMapSha256": fixture["prior_map_sha256"],
            "shelfLocalizationEvidenceComplete": True,
            "poseEpochTransitionCount": 0,
            "poseEpochTransitionLastSequence": None,
            "corridorHypothesisCount": 1,
            "corridorHypothesisLastSequence": 1,
            "shelfObservationWindowCount": 2,
            "shelfObservationWindowLastSequence": 2,
            "shelfLoopEventCount": 1,
            "shelfLoopEventLastSequence": 1,
        }
        bundle = validate_shelf_localization_records(records, shared_metadata)
        self.assertEqual(len(bundle.accepted_shelf_loops), 1)

    def test_pending_calibration_is_a_publication_blocker(self) -> None:
        status, qualified = _shelf_localization_calibration_gate(
            {"shelfLocalizationCalibrationStatus": "CALIBRATION_PENDING"},
            evidence_bound=True,
        )
        self.assertEqual(status, "CALIBRATION_PENDING")
        self.assertFalse(qualified)
        self.assertEqual(
            _shelf_localization_calibration_gate({}, evidence_bound=False),
            ("NOT_APPLICABLE", True),
        )

    def test_strict_bundle_and_shelf_factors(self) -> None:
        bundle = validate_shelf_localization_records(values(), metadata())
        self.assertEqual(len(bundle.accepted_shelf_loops), 1)
        baseline = [
            Pose(node_id=index, timestamp=float(index), x=0.0, y=0.0, yaw=0.0)
            for index in range(1, 11)
        ]
        shelves = {
            "shelf_segments": [{
                "shelf_segment_id": "shelf-1",
                "floor_id": "1",
                "longitudinal_start_m": [0.0, 0.0],
                "longitudinal_end_m": [4.0, 0.0],
                "longitudinal_axis": [1.0, 0.0],
                "front_normal": [0.0, 1.0],
                "back_normal": [0.0, -1.0],
            }]
        }
        constraints, audit = build_shelf_face_constraints(
            baseline, bundle, shelves, "1"
        )
        self.assertEqual(len(constraints), 2)
        self.assertTrue(all(item.kind == "shelf_face" for item in constraints))
        self.assertEqual({item.node_index for item in constraints}, {4, 9})
        self.assertEqual(len(audit), 2)
        with tempfile.TemporaryDirectory() as temporary:
            priors = Path(temporary) / "priors.tsv"
            _write_priors(priors, "c" * 64, baseline, constraints)
            lines = priors.read_text(encoding="utf-8").splitlines()
        self.assertEqual(
            lines[0], f"MarketScannerAbsoluteSE2Priors\t3\t{'c' * 64}"
        )
        fields = lines[1].split("\t")
        self.assertEqual(len(fields), 11)
        self.assertAlmostEqual(float(fields[8]), 1.0 / 9.0)
        self.assertAlmostEqual(float(fields[9]), 0.0)
        self.assertAlmostEqual(float(fields[10]), 4.0)

    def test_cross_epoch_without_bridge_cannot_be_accepted(self) -> None:
        records = values()
        second = dict(records["shelf_observation_windows.jsonl"][1])
        second["epoch"] = 2
        records["shelf_observation_windows.jsonl"] = (
            records["shelf_observation_windows.jsonl"][0], second
        )
        with self.assertRaisesRegex(ShelfEvidenceError, "without bridge"):
            validate_shelf_localization_records(records, metadata())

    def test_ambiguous_shelf_margin_cannot_be_promoted_to_loop_factor(self) -> None:
        records = values()
        first = dict(records["shelf_observation_windows.jsonl"][0])
        first["shelf_candidates"] = [
            {"shelf_segment_id": "shelf-1", "score": 0.90},
            {"shelf_segment_id": "shelf-parallel", "score": 0.85},
        ]
        records["shelf_observation_windows.jsonl"] = (
            first,
            records["shelf_observation_windows.jsonl"][1],
        )
        with self.assertRaisesRegex(ShelfEvidenceError, "frozen criteria"):
            validate_shelf_localization_records(records, metadata())

    def test_depth_geometry_not_visual_graph_metric_controls_acceptance(self) -> None:
        records = values()
        damaged_windows = []
        for source in records["shelf_observation_windows.jsonl"]:
            item = dict(source)
            item["geometry"] = {
                "sample_count": 20,
                "inlier_count": 12,
                "inlier_ratio": 0.6,
                "residual_median_m": 0.3,
                "residual_maximum_m": 0.5,
            }
            damaged_windows.append(item)
        event = dict(records["shelf_loop_events.jsonl"][0])
        event["rtab_graph_optimization_max_error"] = 0.0
        event["consistency"] = {
            **event["consistency"],
            "inlier_ratio": 0.6,
            "residual_median_m": 0.3,
            "residual_maximum_m": 0.5,
        }
        records["shelf_observation_windows.jsonl"] = tuple(damaged_windows)
        records["shelf_loop_events.jsonl"] = (event,)
        with self.assertRaisesRegex(ShelfEvidenceError, "frozen criteria"):
            validate_shelf_localization_records(records, metadata())

        # Conversely this diagnostic graph setting cannot veto an otherwise
        # valid shelf-geometry loop; it is stored under its real name only.
        valid_records = values()
        diagnostic = dict(valid_records["shelf_loop_events.jsonl"][0])
        diagnostic["rtab_graph_optimization_max_error"] = 99.0
        valid_records["shelf_loop_events.jsonl"] = (diagnostic,)
        bundle = validate_shelf_localization_records(valid_records, metadata())
        self.assertEqual(len(bundle.accepted_shelf_loops), 1)

    def test_legacy_loop_residual_key_is_retained_but_must_be_null(self) -> None:
        records = values()
        event = dict(records["shelf_loop_events.jsonl"][0])
        event["rtab_loop_residual_m"] = 0.1
        records["shelf_loop_events.jsonl"] = (event,)
        with self.assertRaisesRegex(ShelfEvidenceError, "must be null"):
            validate_shelf_localization_records(records, metadata())

    def test_loop_nodes_must_belong_to_the_referenced_windows(self) -> None:
        records = values()
        event = dict(records["shelf_loop_events.jsonl"][0])
        event["loop_from_node"] = 999
        records["shelf_loop_events.jsonl"] = (event,)
        with self.assertRaisesRegex(ShelfEvidenceError, "identity mismatch"):
            validate_shelf_localization_records(records, metadata())

    def test_sparse_node_span_cannot_hide_dominant_dynamic_samples(self) -> None:
        records = values()
        first = dict(records["shelf_observation_windows.jsonl"][0])
        first["node_range"] = [1, 17]
        first["observation_node_count"] = 5
        first["dynamic_rejection_count"] = 3
        records["shelf_observation_windows.jsonl"] = (
            first,
            records["shelf_observation_windows.jsonl"][1],
        )
        with self.assertRaisesRegex(ShelfEvidenceError, "frozen criteria"):
            validate_shelf_localization_records(records, metadata())

    def test_unknown_field_and_watermark_fail_closed(self) -> None:
        records = values()
        damaged = dict(records["corridor_hypotheses.jsonl"][0])
        damaged["unexpected"] = True
        records["corridor_hypotheses.jsonl"] = (damaged,)
        with self.assertRaisesRegex(ShelfEvidenceError, "field set"):
            validate_shelf_localization_records(records, metadata())

    def test_corridor_component_must_match_native_node_map_id(self) -> None:
        records = values()
        damaged = dict(records["corridor_hypotheses.jsonl"][0])
        damaged["component"] = 1
        records["corridor_hypotheses.jsonl"] = (damaged,)
        with self.assertRaisesRegex(ShelfEvidenceError, "node_map_id"):
            validate_shelf_localization_records(records, metadata())

    def test_streaming_read_reconciles_all_four_files(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for name, records in values().items():
                with (root / name).open("w", encoding="utf-8") as handle:
                    for record in records:
                        handle.write(json.dumps(record, separators=(",", ":")))
                        handle.write("\n")
            bundle = read_shelf_localization_evidence(root, metadata())
            self.assertEqual(len(bundle.shelf_observation_windows), 2)
            self.assertEqual(set(bundle.file_sha256), set(values()))


if __name__ == "__main__":
    unittest.main()
