from __future__ import annotations

import dataclasses
import json
import math
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from tools.PriorMap import factor_graph_runner as runner


@dataclasses.dataclass
class Pose:
    node_id: int
    timestamp: float
    x: float
    y: float
    yaw: float


@dataclasses.dataclass
class Constraint:
    identifier: str
    node_index: int
    x: float
    y: float
    yaw: float
    weight: float
    kind: str
    translation_sigma_m: float | None = None
    yaw_sigma_rad: float | None = None
    trusted_absolute: bool = False


POLICY = {
    "format": "MarketScannerFactorGraphQualityPolicy",
    "version": 1,
    "status": "candidate",
    "policy_version": "runner-test",
    "limits": {
        "relative_translation_p95_max_m": 0.2,
        "relative_translation_max_m": 1.0,
        "relative_yaw_p95_max_deg": 5.0,
        "relative_yaw_max_deg": 20.0,
        "loop_translation_p95_max_m": 0.5,
        "loop_translation_max_m": 1.0,
        "loop_yaw_p95_max_deg": 10.0,
        "loop_yaw_max_deg": 20.0,
        "high_residual_loop_translation_m": 1.25,
        "high_residual_loop_yaw_deg": 22.5,
        "high_residual_loop_ratio_max": 0.075,
        "maximum_pose_update_m": 2.0,
        "maximum_pose_update_yaw_deg": 30.0,
        "minimum_relative_factor_to_node_ratio": 0.5,
        "minimum_objective_improvement_ratio": 0.0,
    },
}


class FactorGraphRunnerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.binary = self.root / "factor-graph"
        self.binary.write_text("fixture", encoding="utf-8")
        self.binary.chmod(0o755)
        self.database = self.root / "optimized.db"
        self.database.write_bytes(b"database")
        self.policy = self.root / "quality.json"
        self.policy.write_text(
            json.dumps(POLICY, separators=(",", ":")), encoding="utf-8"
        )
        self.baseline = [Pose(1, 10.0, 0.0, 0.0, 0.0)]
        self.initial = Constraint(
            "initial",
            0,
            25.0,
            -40.0,
            math.pi / 2.0,
            1.0,
            "initial_map_pose",
            translation_sigma_m=1.0,
            yaw_sigma_rad=math.radians(15.0),
            trusted_absolute=True,
        )

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def _run(self, *, returncode: int, payload: object) -> tuple[object, list[str]]:
        command: list[str] = []

        def fake_run(values, **_kwargs):
            command.extend(values)
            output = Path(values[values.index("--output") + 1])
            if isinstance(payload, bytes):
                output.write_bytes(payload)
            else:
                output.write_text(json.dumps(payload), encoding="utf-8")
            return mock.Mock(returncode=returncode, stdout="", stderr="")

        validated = {
            "poses": [{"node_id": 1, "x": 25.0, "y": -40.0, "yaw": math.pi / 2.0}],
            "full_factor_graph": True,
            "published_capable": False,
            "graph_quality_passed": False,
        }
        with mock.patch.object(runner.subprocess, "run", side_effect=fake_run), mock.patch.object(
            runner,
            "validate_factor_graph_result",
            return_value=validated,
        ) as validate:
            result = runner.run_relative_se2_factor_graph(
                binary=self.binary,
                optimized_database=self.database,
                baseline=self.baseline,
                constraints=[self.initial],
                input_identity_id="a" * 64,
                horizontal_axes="ios_prior",
                pose_type=Pose,
                hard_reject_translation_m=2.5,
                hard_reject_yaw_rad=math.radians(45.0),
                quality_policy_path=self.policy,
            )
        self.assertTrue(validate.called)
        return result, command

    def test_return_code_three_reads_and_validates_detailed_json(self) -> None:
        result, command = self._run(returncode=3, payload={"converged": True})
        optimized, accepted, rejected, report = result
        self.assertEqual(len(optimized), 1)
        self.assertEqual(len(accepted), 1)
        self.assertEqual(rejected, [])
        self.assertEqual(report["initial_map_pose_constraint_count"], 1)
        self.assertIn("--loop-quarantine-translation-m", command)
        self.assertEqual(
            command[command.index("--loop-quarantine-translation-m") + 1],
            "1.25",
        )
        self.assertEqual(
            command[command.index("--loop-quarantine-yaw-rad") + 1],
            format(math.radians(22.5), ".17g"),
        )
        self.assertEqual(
            command[command.index("--maximum-quarantined-loop-ratio") + 1],
            "0.074999999999999997",
        )

    def test_return_code_three_malformed_json_fails_closed(self) -> None:
        with self.assertRaisesRegex(
            runner.FactorGraphRunnerError, "result is unreadable"
        ):
            self._run(returncode=3, payload=b"{not-json")

    def test_initial_map_pose_bypasses_drifted_baseline_hard_gate(self) -> None:
        selected, rejected = runner._select_absolute_priors(
            self.baseline,
            [self.initial],
            hard_reject_translation_m=2.5,
            hard_reject_yaw_rad=math.radians(45.0),
        )
        self.assertEqual(selected, [self.initial])
        self.assertEqual(rejected, [])


if __name__ == "__main__":
    unittest.main()
