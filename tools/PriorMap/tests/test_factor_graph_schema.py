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
        "version": 1,
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
        "iterations_done": 5,
        "converged": True,
        "full_factor_graph": True,
        "published_capable": True,
        "downweighted_factor_ids": [],
        "rejected_factor_ids": [],
    }


class FactorGraphSchemaTests(unittest.TestCase):
    def validate(self, payload):
        return validate_factor_graph_result(
            payload,
            expected_input_identity_id=IDENTITY,
            expected_database_sha256=DATABASE,
            expected_node_ids=(1, 2, 3),
        )

    def test_valid_connected_graph_and_canonical_digest(self):
        first = valid_report()
        second = valid_report()
        self.assertEqual(first["factor_set_sha256"], second["factor_set_sha256"])
        self.assertEqual(self.validate(first)["root_node_id"], 1)

    def test_ninety_degree_measurement_is_preserved_in_canonical_factor(self):
        item = valid_report()["factors"][1]
        fields = item["canonical"].rstrip("\n").split("\t")
        self.assertAlmostEqual(float(fields[6]), math.pi / 2.0)
        self.assertEqual(item["measurement"][:2], [0.0, 1.0])

    def test_disconnected_graph_fails_closed(self):
        payload = valid_report()
        payload["factors"] = [factor("link:1:2:0", 1, 2)]
        payload["factor_count"] = 1
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
            ("published_capable", False, "convergence gates"),
        ):
            with self.subTest(field=field):
                payload = copy.deepcopy(valid_report())
                payload[field] = value
                with self.assertRaisesRegex(FactorGraphValidationError, message):
                    self.validate(payload)


if __name__ == "__main__":
    unittest.main()
