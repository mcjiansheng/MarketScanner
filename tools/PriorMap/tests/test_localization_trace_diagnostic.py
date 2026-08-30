"""Regression tests for the localization trace diagnostic.

The diagnostic exists to answer "which gate rejects us?" from field data.
These tests pin the aggregation semantics, especially the gate-fit table --
the number that revealed the uniqueness threshold sits at the 91st percentile
of observed data.
"""

from __future__ import annotations

import json
import os
import tempfile
import unittest

from tools.PriorMap import localization_trace_diagnostic as diag


def _record(
    *,
    reason: str = "trusted_structure_correction",
    state: str = "usable",
    points: int = 80,
    angle: float = 0.8,
    uniqueness: float = 0.4,
    cost: float = 0.01,
    correction: float = 0.1,
) -> dict[str, object]:
    return {
        "constraintReason": reason,
        "localizationState": state,
        "structurePointCount": points,
        "structureCoverageAngleRad": angle,
        "matchUniqueness": uniqueness,
        "matchResidualCost": cost,
        "correctionTranslationM": correction,
        "structureSource": "scene_depth",
    }


def _write_session(root: str, session: str, records: list[dict]) -> str:
    segment = os.path.join(root, session, "segment_0001")
    os.makedirs(segment, exist_ok=True)
    path = os.path.join(segment, "localization_trace.jsonl")
    with open(path, "w", encoding="utf-8") as handle:
        for record in records:
            handle.write(json.dumps(record) + "\n")
    return path


class DiscoveryTests(unittest.TestCase):
    def test_finds_traces_and_ignores_empty_files(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            self.assertEqual(diag.discover_traces([tmp]), [])
            _write_session(tmp, "S-a", [_record()])
            _write_session(tmp, "S-b", [_record()])
            empty = os.path.join(tmp, "S-c", "segment_0001")
            os.makedirs(empty)
            open(
                os.path.join(empty, "localization_trace.jsonl"), "w"
            ).close()
            found = diag.discover_traces([tmp])
            # The empty file must be skipped.
            self.assertEqual(len(found), 2)

    def test_handles_malformed_lines(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = _write_session(tmp, "S-a", [_record()])
            with open(path, "a", encoding="utf-8") as handle:
                handle.write("{not json}\n\n")
            records = diag._read_jsonl(path)
            self.assertEqual(len(records), 1)


class GateFitTests(unittest.TestCase):
    def test_gate_fit_reports_reject_rate(self) -> None:
        records = [
            _record(points=10),
            _record(points=20),
            _record(points=90),
            _record(points=100),
        ]
        fit = diag._gate_fit(records, "structurePointCount", 45.0, ">=")
        self.assertEqual(fit["samples"], 4)
        self.assertEqual(fit["passed"], 2)
        self.assertEqual(fit["rejected"], 2)
        self.assertAlmostEqual(fit["reject_rate"], 0.5)

    def test_correction_gate_ignores_zero_values(self) -> None:
        """A zero correction means none was attempted, not that it passed."""
        records = [
            _record(correction=0.0),
            _record(correction=0.0),
            _record(correction=1.0),
        ]
        fit = diag._gate_fit(records, "correctionTranslationM", 0.35, "<=")
        self.assertEqual(fit["samples"], 1)
        self.assertEqual(fit["passed"], 0)
        self.assertAlmostEqual(fit["reject_rate"], 1.0)

    def test_gate_fit_tolerates_missing_field(self) -> None:
        fit = diag._gate_fit([{"x": 1}], "structurePointCount", 45.0, ">=")
        self.assertEqual(fit["samples"], 0)

    def test_quantiles_are_ordered(self) -> None:
        values = [float(i) for i in range(100)]
        q = diag._quantiles(values)
        self.assertLessEqual(q["min"], q["p25"])
        self.assertLessEqual(q["p25"], q["median"])
        self.assertLessEqual(q["median"], q["p90"])
        self.assertLessEqual(q["p90"], q["max"])


def _candidate(x: float, y: float, cost: float) -> dict:
    return {"pose": {"x_m": x, "y_m": y, "yaw_rad": 0.0}, "cost": cost}


class BasinUniquenessTests(unittest.TestCase):
    def test_single_candidate_is_not_proof_of_uniqueness(self) -> None:
        """One sample is absence of evidence, so it must fail closed."""
        self.assertIsNone(diag.basin_uniqueness([_candidate(0, 0, 0.01)]))

    def test_empty_is_none(self) -> None:
        self.assertIsNone(diag.basin_uniqueness([]))

    def test_converged_search_is_not_ambiguous(self) -> None:
        """Neighbouring samples of one basin describe one location."""
        candidates = [
            _candidate(0.00, 0.00, 0.010),
            _candidate(0.10, 0.00, 0.011),
            _candidate(0.20, 0.10, 0.012),
        ]
        self.assertEqual(diag.basin_uniqueness(candidates), 1.0)

    def test_distant_equal_cost_basins_stay_ambiguous(self) -> None:
        """Two equally good locations several metres apart are ambiguous."""
        candidates = [
            _candidate(0.0, 0.0, 0.010),
            _candidate(6.0, 0.0, 0.010),
        ]
        self.assertAlmostEqual(diag.basin_uniqueness(candidates), 0.0)

    def test_distant_basins_use_cost_ratio(self) -> None:
        candidates = [
            _candidate(0.0, 0.0, 0.010),
            _candidate(6.0, 0.0, 0.020),
        ]
        # (0.020 - 0.010) / 0.020 = 0.5
        self.assertAlmostEqual(diag.basin_uniqueness(candidates), 0.5)

    def test_chained_cluster_collapses_to_one_basin(self) -> None:
        """0.3 m hops must chain together instead of being split by order."""
        candidates = [
            _candidate(0.0, 0.0, 0.010),
            _candidate(0.3, 0.0, 0.010),
            _candidate(0.6, 0.0, 0.010),
        ]
        self.assertEqual(diag.basin_uniqueness(candidates), 1.0)

    def test_periodic_structure_at_0_6m_is_not_merged(self) -> None:
        """The regression suite models periodic shelving at 0.6 m spacing.

        Merging those would call a genuinely ambiguous scene unique, which is
        exactly the failure the contract test guards against.
        """
        candidates = [
            _candidate(0.0, 0.0, 0.010),
            _candidate(0.6, 0.0, 0.010),
        ]
        value = diag.basin_uniqueness(candidates)
        self.assertIsNotNone(value)
        self.assertLess(value, 0.10)

    def test_radius_stays_below_periodic_spacing(self) -> None:
        self.assertLess(diag.BASIN_RADIUS_M, 0.6)


class AnalysisTests(unittest.TestCase):
    def test_aggregates_reasons_states_and_gates(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            _write_session(
                tmp,
                "S-a",
                [
                    _record(reason="insufficient_structure_points", points=5),
                    _record(reason="ambiguous_structure_match", uniqueness=0.0),
                    _record(),
                ],
            )
            report = diag.analyse([tmp])
            self.assertEqual(report["records"], 3)
            self.assertEqual(report["sessions"], 1)
            self.assertEqual(
                report["constraint_reasons"]["insufficient_structure_points"], 1
            )
            # All three fixtures default to the usable state; the reasons
            # differ, which is exactly what the reason histogram separates.
            self.assertEqual(report["localization_states"]["usable"], 3)
            fields = {g["field"] for g in report["gate_fit"]}
            self.assertIn("matchUniqueness", fields)
            self.assertIn("correctionTranslationM", fields)

    def test_ambiguity_vs_residual_is_reported(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            _write_session(
                tmp,
                "S-a",
                [
                    # Ambiguous frames with a *lower* residual than the unique
                    # one -- the field signature this check exists to expose.
                    _record(uniqueness=0.0, cost=0.001),
                    _record(uniqueness=0.0, cost=0.001),
                    _record(uniqueness=0.5, cost=0.02),
                ],
            )
            report = diag.analyse([tmp])
            amb = report["ambiguity_vs_residual"]
            self.assertIsNotNone(amb["cost_median_ambiguous"])
            self.assertIsNotNone(amb["cost_median_unique"])
            self.assertLessEqual(
                amb["cost_median_ambiguous"], amb["cost_median_unique"]
            )

    def test_empty_tree_is_safe(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            report = diag.analyse([tmp])
            self.assertEqual(report["records"], 0)
            self.assertEqual(report["traces"], 0)


if __name__ == "__main__":
    unittest.main()
