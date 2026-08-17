from __future__ import annotations

import copy
import hashlib
import json
import math
import unittest

from tools.PriorMap.factor_graph_schema import (
    canonical_factor_line,
    validate_factor_graph_result,
)
from tools.PriorMap.final_trajectory_authority import (
    FinalTrajectoryAuthorityError,
    attest_final_trajectory,
    poses_from_trajectory_geojson,
    trajectory_sha256,
)
from tools.PriorMap.tests.test_factor_graph_schema import (
    DATABASE,
    IDENTITY,
    POLICY,
    POLICY_SHA,
    valid_report,
)


def validated_native_report() -> dict:
    report = validate_factor_graph_result(
        valid_report(),
        expected_input_identity_id=IDENTITY,
        expected_database_sha256=DATABASE,
        expected_node_ids=(1, 2, 3),
        quality_policy=POLICY,
        quality_policy_sha256=POLICY_SHA,
    )
    policy_document = json.dumps(
        POLICY, sort_keys=True, separators=(",", ":")
    )
    report["quality_policy"]["policy_sha256"] = hashlib.sha256(
        policy_document.encode("utf-8")
    ).hexdigest()
    report["quality_policy_limits"] = copy.deepcopy(POLICY["limits"])
    report["quality_policy_document"] = policy_document
    report["native_published_capable"] = report["published_capable"]
    return report


def rigid_transform(poses: list[dict], *, x: float, y: float, yaw: float) -> list[dict]:
    cosine = math.cos(yaw)
    sine = math.sin(yaw)
    return [
        {
            "node_id": pose["node_id"],
            "x": x + cosine * pose["x"] - sine * pose["y"],
            "y": y + sine * pose["x"] + cosine * pose["y"],
            "yaw": pose["yaw"] + yaw,
        }
        for pose in poses
    ]


def append_absolute_factor(
    report: dict,
    *,
    kind: str,
    measurement: list[float],
    information: list[float],
) -> None:
    factor = {
        "id": f"prior:{kind}",
        "kind": kind,
        "from_node_id": 1,
        "to_node_id": 1,
        "measurement": measurement,
        "planar_information": information,
    }
    factor["canonical"] = canonical_factor_line(factor)
    report["factors"].append(factor)
    report["factor_count"] = len(report["factors"])
    report["factor_set_sha256"] = hashlib.sha256(
        "".join(
            item["canonical"]
            for item in sorted(report["factors"], key=lambda value: value["id"])
        ).encode("utf-8")
    ).hexdigest()


class FinalTrajectoryAuthorityTests(unittest.TestCase):
    def test_native_and_global_rigid_relative_trajectory_pass(self) -> None:
        report = validated_native_report()
        native = attest_final_trajectory(
            report, report["poses"], post_solver="native_relative_se2"
        )
        self.assertTrue(native["passed"])
        self.assertFalse(native["trajectory_changed_after_native_solver"])
        self.assertEqual(native["factor_objective"], 0.0)

        transformed_poses = rigid_transform(
            report["poses"], x=14.0, y=-8.0, yaw=math.radians(37.0)
        )
        transformed = attest_final_trajectory(
            report,
            transformed_poses,
            post_solver="corridor_free_space_envelope_v2",
        )
        self.assertTrue(transformed["passed"])
        self.assertTrue(transformed["trajectory_changed_after_native_solver"])
        self.assertNotEqual(
            transformed["trajectory_sha256"], native["trajectory_sha256"]
        )
        self.assertAlmostEqual(
            transformed["relative_factor_metrics"][
                "maximum_translation_residual_m"
            ],
            0.0,
            places=12,
        )

    def test_single_node_or_factor_tampering_fails_closed(self) -> None:
        report = validated_native_report()
        poses = copy.deepcopy(report["poses"])
        poses[1]["x"] += 2.0
        authority = attest_final_trajectory(
            report, poses, post_solver="corridor_free_space_envelope_v2"
        )
        self.assertFalse(authority["passed"])
        self.assertIn(
            "relative_translation_max_within_policy",
            {item["code"] for item in authority["blockers"]},
        )

        tampered = copy.deepcopy(report)
        tampered["factors"][0]["measurement"][0] = 2.0
        authority = attest_final_trajectory(
            tampered, report["poses"], post_solver="native_relative_se2"
        )
        self.assertFalse(authority["passed"])
        self.assertEqual(
            authority["blockers"][0]["code"],
            "final_factor_recalculation_failed",
        )

    def test_absolute_prior_and_shelf_normal_remain_bound_after_post_solver(
        self,
    ) -> None:
        anchored = validated_native_report()
        append_absolute_factor(
            anchored,
            kind="manual_anchor",
            measurement=[0.0, 0.0, 0.0],
            information=[100.0, 0.0, 0.0, 0.0, 100.0, 0.0, 0.0, 0.0, 100.0],
        )
        shifted = rigid_transform(anchored["poses"], x=10.0, y=0.0, yaw=0.0)
        authority = attest_final_trajectory(
            anchored, shifted, post_solver="corridor_free_space_envelope_v2"
        )
        self.assertFalse(authority["passed"])
        self.assertIn(
            "objective_improvement_within_policy",
            {item["code"] for item in authority["blockers"]},
        )

        shelf = validated_native_report()
        append_absolute_factor(
            shelf,
            kind="shelf_face",
            measurement=[0.0, 0.0, 0.0],
            # Shelf normal is +X (sigma 0.1 m); along-shelf +Y is weak.
            information=[100.0, 0.0, 0.0, 0.0, 1.0 / 9.0, 0.0, 0.0, 0.0, 100.0],
        )
        along_shelf = rigid_transform(shelf["poses"], x=0.0, y=2.0, yaw=0.0)
        authority = attest_final_trajectory(
            shelf, along_shelf, post_solver="corridor_free_space_envelope_v2"
        )
        self.assertTrue(authority["passed"])
        self.assertAlmostEqual(
            authority["shelf_face_factor_metrics"][
                "maximum_translation_residual_m"
            ],
            0.0,
        )
        across_shelf = rigid_transform(shelf["poses"], x=0.6, y=2.0, yaw=0.0)
        authority = attest_final_trajectory(
            shelf, across_shelf, post_solver="corridor_free_space_envelope_v2"
        )
        self.assertFalse(authority["passed"])
        self.assertIn(
            "shelf_face_normal_residual_within_existing_gate",
            {item["code"] for item in authority["blockers"]},
        )

    def test_node_inventory_and_nonfinite_values_fail_closed(self) -> None:
        report = validated_native_report()
        for poses in (
            [report["poses"][0], report["poses"][2], report["poses"][1]],
            [*report["poses"], copy.deepcopy(report["poses"][-1])],
            [
                report["poses"][0],
                {**report["poses"][1], "yaw": math.nan},
                report["poses"][2],
            ],
        ):
            with self.subTest(poses=poses):
                authority = attest_final_trajectory(
                    report, poses, post_solver="native_relative_se2"
                )
                self.assertFalse(authority["passed"])
                self.assertIsNone(authority["trajectory_sha256"])

    def test_quality_limits_cannot_be_rebound_away_from_release_policy(self) -> None:
        report = validated_native_report()
        report["quality_policy_limits"]["relative_translation_max_m"] = 1000.0
        authority = attest_final_trajectory(
            report, report["poses"], post_solver="native_relative_se2"
        )
        self.assertFalse(authority["passed"])
        self.assertEqual(
            authority["blockers"][0]["code"],
            "final_factor_recalculation_failed",
        )
        self.assertIn(
            "Quality policy document differs",
            authority["blockers"][0]["value"],
        )

        report = validated_native_report()
        report["quality_policy_document"] += " "
        authority = attest_final_trajectory(
            report, report["poses"], post_solver="native_relative_se2"
        )
        self.assertFalse(authority["passed"])
        self.assertIn(
            "release SHA-256", authority["blockers"][0]["value"]
        )

    def test_geojson_recovery_is_strict_and_canonical(self) -> None:
        report = validated_native_report()
        payload = {
            "type": "FeatureCollection",
            "features": [
                {
                    "type": "Feature",
                    "properties": {
                        "layer": "prior_map_offline_optimized",
                        "node_ids": [pose["node_id"] for pose in report["poses"]],
                        "yaws_rad": [pose["yaw"] for pose in report["poses"]],
                    },
                    "geometry": {
                        "type": "LineString",
                        "coordinates": [
                            [pose["x"], pose["y"]] for pose in report["poses"]
                        ],
                    },
                }
            ],
        }
        recovered = poses_from_trajectory_geojson(payload)
        self.assertEqual(
            trajectory_sha256(recovered), trajectory_sha256(report["poses"])
        )
        payload["features"][0]["properties"]["node_ids"] = [1, 1, 3]
        with self.assertRaisesRegex(
            FinalTrajectoryAuthorityError, "strictly increasing"
        ):
            poses_from_trajectory_geojson(payload)


if __name__ == "__main__":
    unittest.main()
