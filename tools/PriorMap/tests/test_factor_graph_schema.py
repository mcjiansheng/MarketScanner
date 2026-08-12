from __future__ import annotations

import copy
import hashlib
import math
import unittest

from tools.PriorMap.factor_graph_schema import (
    FactorGraphValidationError,
    canonical_factor_line,
    validate_factor_graph_result,
)


IDENTITY = "a" * 64
DATABASE = "b" * 64
POLICY_SHA = "c" * 64
POLICY = {
    "format": "MarketScannerFactorGraphQualityPolicy",
    "version": 1,
    "status": "frozen",
    "policy_version": "test-1",
    "limits": {
        "relative_translation_p95_max_m": 0.2,
        "relative_translation_max_m": 1.0,
        "relative_yaw_p95_max_deg": 5.0,
        "relative_yaw_max_deg": 20.0,
        "loop_translation_p95_max_m": 0.5,
        "loop_translation_max_m": 1.0,
        "loop_yaw_p95_max_deg": 10.0,
        "loop_yaw_max_deg": 20.0,
        "high_residual_loop_translation_m": 1.0,
        "high_residual_loop_yaw_deg": 20.0,
        "high_residual_loop_ratio_max": 0.05,
        "maximum_pose_update_m": 2.0,
        "maximum_pose_update_yaw_deg": 30.0,
        "minimum_relative_factor_to_node_ratio": 0.5,
        "minimum_objective_improvement_ratio": 0.0,
    },
}


def factor(identifier: str, from_id: int, to_id: int, measurement=None, information=None):
    payload = {
        "id": identifier,
        "kind": "relative_neighbor",
        "from_node_id": from_id,
        "to_node_id": to_id,
        "measurement": list(measurement or [1.0, 0.0, 0.0]),
        "planar_information": list(
            information or [100.0, 0.0, 0.0, 0.0, 100.0, 0.0, 0.0, 0.0, 100.0]
        ),
    }
    payload["canonical"] = canonical_factor_line(payload)
    return payload


def valid_report():
    factors = [
        factor("link:1:2:0", 1, 2),
        factor("link:2:3:0", 2, 3, [0.0, 1.0, math.pi / 2.0]),
    ]
    digest = hashlib.sha256(
        "".join(item["canonical"] for item in sorted(factors, key=lambda value: value["id"])).encode()
    ).hexdigest()
    return {
        "format": "MarketScannerRelativeSE2FactorGraphReport",
        "version": 2,
        "solver": "rtabmap_g2o_slam2d",
        "database_version": "0.23.5",
        "input_identity_id": IDENTITY,
        "optimized_database_sha256": DATABASE,
        "factor_set_sha256": digest,
        "node_count": 3,
        "factor_count": 2,
        "root_node_id": 1,
        "gauge_mode": "fixed_root",
        "graph_connected": True,
        "poses": [
            {"node_id": 1, "x": 0.0, "y": 0.0, "yaw": 0.0},
            {"node_id": 2, "x": 1.0, "y": 0.0, "yaw": 0.0},
            {"node_id": 3, "x": 1.0, "y": 1.0, "yaw": math.pi / 2.0},
        ],
        "factors": factors,
        "initial_objective": 2.0,
        "final_objective": 1.0,
        "native_final_error": 1.0,
        "maximum_pose_update_m": 0.1,
        "maximum_pose_update_yaw_deg": 1.0,
        "maximum_relative_edge_translation_residual_m": 0.01,
        "p95_relative_edge_translation_residual_m": 0.01,
        "maximum_relative_edge_yaw_residual_deg": 0.1,
        "p95_relative_edge_yaw_residual_deg": 0.1,
        "maximum_loop_edge_translation_residual_m": 0.0,
        "p95_loop_edge_translation_residual_m": 0.0,
        "maximum_loop_edge_yaw_residual_deg": 0.0,
        "p95_loop_edge_yaw_residual_deg": 0.0,
        "factor_counts_by_type": {"relative_neighbor": 2},
        "loop_factor_residuals": [],
        "duplicate_reciprocal_collapsed": 0,
        "iterations_done": 5,
        "converged": True,
        "solver_converged": True,
        "graph_integrity_passed": True,
        "graph_quality_passed": False,
        "full_factor_graph": True,
        "published_capable": False,
        "rejected_factor_ids": [],
        "rejected_factor_details": [],
        "quarantined_loop_count": 0,
        "total_loop_count": 0,
        "quarantined_loop_ratio": 0.0,
        "quarantine_gate_passed": True,
        "loop_quarantine_translation_m": 1.0,
        "loop_quarantine_yaw_deg": 20.0,
        "maximum_quarantined_loop_ratio": 0.05,
    }


class FactorGraphSchemaTests(unittest.TestCase):
    def validate(self, payload, *, verified_absolute_gauge_authority=False):
        return validate_factor_graph_result(
            payload,
            expected_input_identity_id=IDENTITY,
            expected_database_sha256=DATABASE,
            expected_node_ids=(1, 2, 3),
            quality_policy=POLICY,
            quality_policy_sha256=POLICY_SHA,
            verified_absolute_gauge_authority=(
                verified_absolute_gauge_authority
            ),
        )

    def test_valid_connected_graph_and_canonical_digest(self):
        first = valid_report()
        second = valid_report()
        self.assertEqual(first["factor_set_sha256"], second["factor_set_sha256"])
        self.assertEqual(self.validate(first)["root_node_id"], 1)

    def test_candidate_or_failed_numeric_quality_is_never_publishable(self):
        candidate = copy.deepcopy(POLICY)
        candidate["status"] = "candidate"
        result = validate_factor_graph_result(
            valid_report(),
            expected_input_identity_id=IDENTITY,
            expected_database_sha256=DATABASE,
            expected_node_ids=(1, 2, 3),
            quality_policy=candidate,
            quality_policy_sha256=POLICY_SHA,
        )
        self.assertFalse(result["graph_quality_passed"])
        self.assertFalse(result["published_capable"])
        payload = valid_report()
        payload["p95_relative_edge_translation_residual_m"] = 0.21
        result = self.validate(payload)
        self.assertFalse(result["graph_quality_passed"])
        self.assertIn(
            "relative_translation_p95_exceeded",
            {item["code"] for item in result["quality_policy"]["blockers"]},
        )

    def test_ninety_degree_measurement_is_preserved_in_canonical_factor(self):
        item = valid_report()["factors"][1]
        fields = item["canonical"].rstrip("\n").split("\t")
        self.assertAlmostEqual(float(fields[6]), math.pi / 2.0)
        self.assertEqual(item["measurement"][:2], [0.0, 1.0])

    def test_disconnected_graph_fails_closed(self):
        payload = valid_report()
        payload["factors"] = [factor("link:1:2:0", 1, 2)]
        payload["factor_count"] = 1
        payload["factor_counts_by_type"] = {"relative_neighbor": 1}
        payload["factor_set_sha256"] = hashlib.sha256(
            payload["factors"][0]["canonical"].encode()
        ).hexdigest()
        with self.assertRaisesRegex(FactorGraphValidationError, "disconnected"):
            self.validate(payload)

    def test_missing_endpoint_fails_closed(self):
        payload = valid_report()
        payload["factors"][1] = factor("link:2:4:0", 2, 4)
        payload["factor_set_sha256"] = hashlib.sha256(
            "".join(item["canonical"] for item in payload["factors"]).encode()
        ).hexdigest()
        with self.assertRaisesRegex(FactorGraphValidationError, "missing node"):
            self.validate(payload)

    def test_singular_information_fails_closed(self):
        payload = valid_report()
        payload["factors"][0] = factor(
            "link:1:2:0", 1, 2, information=[1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0]
        )
        payload["factor_set_sha256"] = hashlib.sha256(
            "".join(item["canonical"] for item in payload["factors"]).encode()
        ).hexdigest()
        with self.assertRaisesRegex(FactorGraphValidationError, "positive definite"):
            self.validate(payload)

    def test_nonfinite_and_digest_tampering_fail_closed(self):
        payload = valid_report()
        payload["poses"][1]["x"] = math.nan
        with self.assertRaisesRegex(FactorGraphValidationError, "finite"):
            self.validate(payload)
        payload = valid_report()
        payload["factor_set_sha256"] = "0" * 64
        with self.assertRaisesRegex(FactorGraphValidationError, "digest"):
            self.validate(payload)

    def test_wrong_gauge_and_nonconvergence_fail_closed(self):
        for field, value, message in (
            ("root_node_id", 2, "root gauge"),
            ("converged", False, "convergence gates"),
            ("solver_converged", False, "convergence gates"),
        ):
            with self.subTest(field=field):
                payload = copy.deepcopy(valid_report())
                payload[field] = value
                with self.assertRaisesRegex(FactorGraphValidationError, message):
                    self.validate(payload)

    def test_absolute_prior_gauge_allows_large_global_update_but_keeps_relative_gates(self):
        payload = valid_report()
        payload["gauge_mode"] = "absolute_priors"
        payload["maximum_pose_update_m"] = 40.0
        payload["maximum_pose_update_yaw_deg"] = 90.0
        report = self.validate(
            payload, verified_absolute_gauge_authority=True
        )
        self.assertTrue(report["quality_policy"]["passed"])
        self.assertFalse(
            report["quality_policy"]["absolute_pose_update_gate_applied"]
        )

        payload = valid_report()
        payload["gauge_mode"] = "absolute_priors"
        payload["maximum_pose_update_m"] = 40.0
        payload["maximum_relative_edge_translation_residual_m"] = 2.0
        report = self.validate(
            payload, verified_absolute_gauge_authority=True
        )
        self.assertFalse(report["quality_policy"]["passed"])
        self.assertIn(
            "relative_translation_max_exceeded",
            {item["code"] for item in report["quality_policy"]["blockers"]},
        )

    def test_automatic_absolute_priors_cannot_bypass_pose_update_gate(self):
        payload = valid_report()
        payload["gauge_mode"] = "absolute_priors"
        payload["maximum_pose_update_m"] = 40.0
        report = self.validate(payload)
        self.assertFalse(report["quality_policy"]["passed"])
        self.assertTrue(
            report["quality_policy"]["absolute_pose_update_gate_applied"]
        )
        self.assertIn(
            "maximum_pose_update_exceeded",
            {item["code"] for item in report["quality_policy"]["blockers"]},
        )


if __name__ == "__main__":
    unittest.main()
