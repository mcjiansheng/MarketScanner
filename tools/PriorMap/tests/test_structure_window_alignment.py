from __future__ import annotations

import hashlib
import json
import math
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from tools.PriorMap import structure_window_alignment as alignment
from tools.PriorMap.structure_window_alignment import (
    AlignmentCandidate,
    Pose2D,
    StructureCoverageCell,
    StructureWindowAlignmentError,
    TracePose,
    build_structure_windows,
    diagnostic_report,
    load_localization_trace,
    load_road_graph,
    load_structure_coverage,
    select_candidate_sequence,
)


def _coverage_cell(
    x: int,
    z: int,
    *,
    first: float = 9.0,
    last: float = 11.0,
    elevated: int = 3,
    buckets: int = 2,
    views: int = 3,
) -> dict[str, object]:
    record: dict[str, object] = {
        "x": x,
        "z": z,
        "floorObservationCount": 0,
        "elevatedObservationCount": elevated,
        "highObservationCount": min(1, elevated),
        "distinctTimeBucketCount": min(buckets, elevated),
        "viewDirectionMask": views if elevated else 0,
        "highConfidenceObservationCount": min(1, elevated),
        "lastObservedAt": last,
    }
    if elevated:
        record["firstElevatedObservedAt"] = first
        record["lastElevatedObservedAt"] = last
    return record


def _coverage_payload(cells: list[dict[str, object]]) -> dict[str, object]:
    floor_count = sum(int(int(cell["floorObservationCount"]) >= 2) for cell in cells)
    elevated_count = sum(int(int(cell["elevatedObservationCount"]) > 0) for cell in cells)
    stable = [
        cell
        for cell in cells
        if int(cell["elevatedObservationCount"]) >= 2
        and int(cell["distinctTimeBucketCount"]) >= 2
        and float(cell["lastElevatedObservedAt"])
        - float(cell["firstElevatedObservedAt"])
        >= 0.75
    ]
    multi_view = sum(int(int(cell["viewDirectionMask"]).bit_count() >= 2) for cell in stable)
    conflicts = sum(
        int(
            int(cell["floorObservationCount"]) >= 2
            and int(cell["floorObservationCount"])
            / max(
                1,
                int(cell["floorObservationCount"])
                + int(cell["elevatedObservationCount"]),
            )
            > 0.66
        )
        for cell in stable
    )
    stable_count = len(stable)
    coverage_score = multi_view / max(1, stable_count) * (
        1.0 - conflicts / max(1, stable_count)
    )
    return {
        "format": "SupermarketStructureCoverage",
        "version": 1,
        "updatedAt": "2026-08-12 00:00:00",
        "cellSizeM": 1.0,
        "floorHeightM": 0.0,
        "summary": {
            "evaluatedDepthFrameCount": 10,
            "depthUnavailableFrameCount": 0,
            "validDepthSampleCount": 100,
            "observedCellCount": len(cells),
            "floorCellCount": floor_count,
            "elevatedCellCount": elevated_count,
            "stableStructureCellCount": stable_count,
            "multiViewStructureCellCount": multi_view,
            "groundConflictCellCount": conflicts,
            "singleViewStructureCellCount": stable_count - multi_view,
            "coverageScore": coverage_score,
            "currentDetectionRateHz": 1.0,
        },
        "cells": cells,
    }


def _write_json(path: Path, payload: object) -> None:
    path.write_text(
        json.dumps(payload, separators=(",", ":"), allow_nan=False),
        encoding="utf-8",
    )


def _write_trace(path: Path, values: list[tuple[float, Pose2D]]) -> None:
    with path.open("w", encoding="utf-8") as handle:
        for timestamp, pose in values:
            handle.write(
                json.dumps(
                    {
                        "format": "MarketScannerLocalizationTrace",
                        "version": 1,
                        "timestamp": timestamp,
                        "rawPose": {
                            "x_m": pose.x,
                            "y_m": pose.y,
                            "yaw_rad": pose.yaw,
                        },
                    },
                    separators=(",", ":"),
                    allow_nan=False,
                )
                + "\n"
            )


def _zero_distance_level(resolution: float) -> dict[str, object]:
    width = 160
    height = 160
    rows = [[width, 0] for _ in range(height)]
    canonical = json.dumps(rows, separators=(",", ":")).encode("ascii")
    return {
        "resolution_m": resolution,
        "origin_m": [-8.0, -8.0],
        "width": width,
        "height": height,
        "encoding": "row_rle_u8_cm",
        "data_sha256": hashlib.sha256(canonical).hexdigest(),
        "rows": rows,
    }


def _road_graph_payload() -> dict[str, object]:
    return {
        "format": "MarketScannerRoadGraph",
        "version": 1,
        "nodes": [
            {
                "id": "n0", "floor_id": "1", "element_id": "e0",
                "position_m": [-8.0, 0.0], "visible": True, "cross_ids": ["c0"],
            },
            {
                "id": "n1", "floor_id": "1", "element_id": "e1",
                "position_m": [8.0, 0.0], "visible": True, "cross_ids": ["c0"],
            },
        ],
        "edges": [
            {
                "id": "edge-0", "floor_id": "1", "from": "n0", "to": "n1",
                "length_m": 16.0, "cross_ids": ["c0"],
            }
        ],
        "crosses": [
            {
                "id": "c0", "floor_id": "1", "element_id": "",
                "points_m": [[-8.0, 0.0], [8.0, 0.0]], "width_m": 2.0,
                "provenance": "road_point_membership_v1",
            }
        ],
        "statistics": {
            "node_count": 2, "edge_count": 1, "cross_count": 1,
            "connected_component_count": 1, "isolated_node_count": 0,
            "isolated_node_ids": [],
        },
    }


class StructureWindowAlignmentTests(unittest.TestCase):
    def test_strict_coverage_accepts_negative_indices_and_filters_floor_only_cells(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "structure_coverage_cells.json"
            stable = _coverage_cell(-4, -7)
            floor_only = _coverage_cell(3, 4, elevated=0, buckets=0, views=0)
            floor_only["floorObservationCount"] = 3
            _write_json(path, _coverage_payload([stable, floor_only]))

            cell_size, cells, summary = load_structure_coverage(path)

            self.assertEqual(cell_size, 1.0)
            self.assertEqual([(cell.x_index, cell.z_index) for cell in cells], [(-4, -7)])
            self.assertEqual(summary["observedCellCount"], 2)

    def test_coverage_duplicate_cell_unknown_field_and_summary_drift_fail_closed(self) -> None:
        mutations = []
        duplicate = [_coverage_cell(1, 2), _coverage_cell(1, 2)]
        mutations.append(_coverage_payload(duplicate))
        unknown = _coverage_payload([_coverage_cell(1, 2)])
        unknown["cells"][0]["unexpected"] = True  # type: ignore[index]
        mutations.append(unknown)
        drift = _coverage_payload([_coverage_cell(1, 2)])
        drift["summary"]["stableStructureCellCount"] = 0  # type: ignore[index]
        mutations.append(drift)
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "structure_coverage_cells.json"
            for payload in mutations:
                _write_json(path, payload)
                with self.assertRaises(StructureWindowAlignmentError):
                    load_structure_coverage(path)

    def test_world_x_negative_z_conversion_applies_inverse_window_yaw_once(self) -> None:
        cells = [
            StructureCoverageCell(
                x_index=index,
                z_index=-5,
                first_timestamp=9.0,
                last_timestamp=11.0,
                elevated_observation_count=3,
                distinct_time_bucket_count=2,
                view_direction_mask=3,
                high_confidence_observation_count=1,
                floor_observation_count=0,
            )
            for index in range(2, 12)
        ]
        trace = [TracePose(10.0, Pose2D(2.5, 3.5, math.pi / 2.0))]

        windows = build_structure_windows(
            cells,
            cell_size_m=1.0,
            trace=trace,
            initial_pose=Pose2D(0.0, 0.0, 0.0),
            minimum_points_per_window=10,
        )

        self.assertEqual(len(windows), 1)
        point = min(windows[0].points, key=lambda value: abs(value.local_y))
        self.assertAlmostEqual(point.local_x, 1.0, places=9)
        self.assertAlmostEqual(point.local_y, 0.0, places=9)

    def test_time_binding_requires_nearby_trace_sample(self) -> None:
        cell = StructureCoverageCell(
            x_index=0,
            z_index=0,
            first_timestamp=9.0,
            last_timestamp=11.0,
            elevated_observation_count=3,
            distinct_time_bucket_count=2,
            view_direction_mask=3,
            high_confidence_observation_count=1,
            floor_observation_count=0,
        )
        with self.assertRaisesRegex(
            StructureWindowAlignmentError, "time-bound"
        ):
            build_structure_windows(
                [cell] * 10,
                cell_size_m=1.0,
                trace=[TracePose(20.0, Pose2D(0.0, 0.0, 0.0))],
                initial_pose=Pose2D(0.0, 0.0, 0.0),
                minimum_points_per_window=10,
            )

    def test_sequence_continuity_disambiguates_periodic_local_geometry(self) -> None:
        def candidate(x: float, cost: float) -> AlignmentCandidate:
            return AlignmentCandidate(Pose2D(x, 0.0, 0.0), cost, 0.0)

        selected, _total, _second, _margin = select_candidate_sequence(
            [
                [candidate(0.0, 0.01), candidate(4.0, 0.02)],
                [candidate(0.0, 0.02), candidate(4.0, 0.001)],
                [candidate(0.0, 0.01), candidate(4.0, 0.02)],
            ]
        )
        self.assertEqual(selected, [0, 0, 0])

    def test_long_distance_accumulated_correction_uses_gradient_not_total_delta(self) -> None:
        supported, translation_gradient, yaw_gradient = (
            alignment.correction_continuity_metrics(
                [4.0804],
                [28.7],
                [23.17],
            )
        )
        self.assertTrue(supported)
        self.assertAlmostEqual(translation_gradient[0], 0.1761, places=3)
        self.assertAlmostEqual(yaw_gradient[0], 1.2387, places=3)

    def test_short_distance_correction_jump_remains_discontinuous(self) -> None:
        supported, translation_gradient, yaw_gradient = (
            alignment.correction_continuity_metrics(
                [4.0],
                [20.0],
                [0.5],
            )
        )
        self.assertFalse(supported)
        self.assertGreater(translation_gradient[0], 1.0)
        self.assertGreater(yaw_gradient[0], 8.0)

    def test_second_best_sequence_can_share_the_same_final_candidate(self) -> None:
        def candidate(x: float, cost: float = 0.0) -> AlignmentCandidate:
            return AlignmentCandidate(Pose2D(x, 0.0, 0.0), cost, 0.0)

        selected, total, second, margin = select_candidate_sequence(
            [
                [candidate(-1.0), candidate(1.0)],
                [candidate(0.0)],
            ]
        )
        self.assertEqual(selected, [0, 0])
        self.assertIsNone(second)
        self.assertIsNone(margin)

        # A route that diverges at shelf scale and then rejoins the same final
        # candidate remains an independent runner-up.
        selected, total, second, margin = select_candidate_sequence(
            [
                [candidate(-4.0), candidate(4.0)],
                [candidate(0.0)],
            ]
        )
        self.assertEqual(selected, [0, 0])
        self.assertIsNotNone(second)
        self.assertAlmostEqual(second or -1.0, total, places=12)
        self.assertEqual(margin, 0.0)

    def test_road_topology_is_a_soft_periodic_tie_breaker(self) -> None:
        def candidate(
            x: float, geometry: float, road_distance: float, road_yaw_deg: float = 0.0
        ) -> AlignmentCandidate:
            return AlignmentCandidate(
                Pose2D(x, 0.0, 0.0), geometry, 0.0,
                road_distance, (math.radians(road_yaw_deg),), x, 0.0,
            )

        selected, _total, _second, _margin = select_candidate_sequence(
            [[
                candidate(0.0, 0.010, 0.1),
                candidate(0.0, 0.009, 3.0, 60.0),
            ]]
        )
        self.assertEqual(selected, [0])

        # Road evidence must remain soft: a clearly superior shelf fit wins
        # even when its road-centerline evidence is worse.
        selected, _total, _second, _margin = select_candidate_sequence(
            [[
                candidate(0.0, 0.001, 4.0, 90.0),
                candidate(0.0, 0.100, 0.0),
            ]]
        )
        self.assertEqual(selected, [0])

    def test_road_graph_is_strict_and_bidirectional(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "road_graph.json"
            _write_json(path, _road_graph_payload())
            road = load_road_graph(path, "1")
            forward = road.evidence(Pose2D(0.0, 1.0, 0.0))
            reverse = road.evidence(Pose2D(0.0, 1.0, math.pi))
            self.assertAlmostEqual(forward.distance_m, 1.0)
            self.assertAlmostEqual(reverse.distance_m, 1.0)
            self.assertEqual(len(forward.yaws_rad), 1)
            self.assertEqual(forward.yaws_rad, reverse.yaws_rad)

            payload = _road_graph_payload()
            payload["statistics"]["edge_count"] = 2  # type: ignore[index]
            _write_json(path, payload)
            with self.assertRaisesRegex(
                StructureWindowAlignmentError, "statistics"
            ):
                load_road_graph(path, "1")

    def test_trace_framing_order_and_resource_budgets_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "localization_trace.jsonl"
            _write_trace(
                path,
                [
                    (1.0, Pose2D(0.0, 0.0, 0.0)),
                    (2.0, Pose2D(1.0, 0.0, 0.0)),
                ],
            )
            with mock.patch.object(alignment, "MAXIMUM_TRACE_RECORDS", 1):
                with self.assertRaisesRegex(
                    StructureWindowAlignmentError, "record budget"
                ):
                    load_localization_trace(path)
            with mock.patch.object(alignment, "MAXIMUM_TRACE_FILE_BYTES", 1):
                with self.assertRaisesRegex(
                    StructureWindowAlignmentError, "file budget"
                ):
                    load_localization_trace(path)
            path.write_bytes(path.read_bytes().rstrip(b"\n"))
            with self.assertRaisesRegex(
                StructureWindowAlignmentError, "framing"
            ):
                load_localization_trace(path)

    def test_diagnostic_result_can_never_inject_a_publishable_factor(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            prior = root / "prior"
            segment = root / "segment_0001"
            prior.mkdir()
            segment.mkdir()
            _write_json(
                prior / "distance_fields.json",
                {
                    "format": "MarketScannerDistanceFields",
                    "version": 1,
                    "unit": "metre",
                    "distance_encoding": "unsigned_centimetres",
                    "truncation_distance_m": 2.0,
                    "floors": {
                        "1": {
                            "levels": [
                                _zero_distance_level(0.4),
                                _zero_distance_level(0.2),
                                _zero_distance_level(0.1),
                            ]
                        }
                    },
                },
            )
            _write_json(prior / "road_graph.json", _road_graph_payload())
            cells = [_coverage_cell(index, -1) for index in range(30)]
            coverage = _coverage_payload(cells)
            coverage["cellSizeM"] = 0.2
            _write_json(segment / "structure_coverage_cells.json", coverage)
            _write_trace(
                segment / "localization_trace.jsonl",
                [(10.0, Pose2D(0.0, 0.0, 0.0))],
            )
            _write_json(
                segment / "metadata.json",
                {
                    "initialMapPose": {
                        "x_m": 0.0,
                        "y_m": 0.0,
                        "yaw_rad": 0.0,
                    }
                },
            )

            report = diagnostic_report(
                prior_map=prior,
                segment=segment,
                floor_id="1",
                correction_radius_m=0.5,
                yaw_radius_deg=1.0,
                candidate_limit=2,
            )

            self.assertEqual(report["publishable_constraint_count"], 0)
            self.assertFalse(report["factor_injection_allowed"])
            self.assertEqual(
                report["authority"],
                "diagnostic_only_unbound_structure_coverage_v1",
            )
            self.assertIn(
                "structure_coverage_not_bound_by_localized_input_manifest",
                report["blockers"],
            )

    def test_optimized_placement_trace_keeps_initial_pose_as_absolute_gauge(self) -> None:
        trace = [
            TracePose(
                1.0,
                Pose2D(10.0, 20.0, math.pi / 2.0),
                node_timebase_timestamp=101.0,
            ),
            TracePose(
                2.0,
                Pose2D(10.0, 22.0, math.pi / 2.0),
                node_timebase_timestamp=102.0,
            ),
        ]
        optimized = [
            alignment.OptimizedNodePose(1, 101.0, Pose2D(1.0, 1.0, 0.0)),
            alignment.OptimizedNodePose(2, 102.0, Pose2D(3.0, 1.0, 0.0)),
        ]

        placement, audit = alignment.build_optimized_placement_trace(
            trace,
            optimized,
            Pose2D(10.0, 20.0, math.pi / 2.0),
        )

        self.assertAlmostEqual(placement[0].pose.x, 10.0)
        self.assertAlmostEqual(placement[0].pose.y, 20.0)
        self.assertAlmostEqual(placement[1].pose.x, 10.0)
        self.assertAlmostEqual(placement[1].pose.y, 22.0)
        self.assertEqual(
            audit["gauge_authority"],
            "metadata.initialMapPose_bound_to_first_optimized_node",
        )


if __name__ == "__main__":
    unittest.main()
