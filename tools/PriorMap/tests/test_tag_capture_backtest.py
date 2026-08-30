"""Regression tests for the ESL capture backtest replay.

The backtest exists because field logs could not answer "which gate rejected
this burst". These tests pin the gate semantics so the replay stays honest:
a policy change must move the numbers for a *reason*, not by accident.
"""

from __future__ import annotations

import os
import tempfile
import unittest

from tools.PriorMap import tag_capture_backtest as backtest


def _observation(
    observation_id: str,
    *,
    method: str = "scene_depth",
    depth_samples: int = 40,
    localization_state: str = "usable",
    freshness: str = "fresh",
    bound_node: bool = True,
    needs_review: bool = False,
) -> dict[str, object]:
    return {
        "observation_id": observation_id,
        "frame_id": f"frame-{observation_id}",
        "measurement_method": method,
        "depth_sample_count": depth_samples,
        "localization_state": localization_state,
        "alignment_freshness": freshness,
        "bound_node_id": 101 if bound_node else None,
        "needs_review": needs_review,
    }


def _burst(
    burst_id: str,
    observation_ids: list[str],
    *,
    complete: bool = True,
    depth_flags: list[int] | None = None,
) -> dict[str, object]:
    flags = depth_flags or [1] * len(observation_ids)
    return {
        "burst_id": burst_id,
        "barcode": "980415258",
        "sequence": 1,
        "complete": complete,
        "first_frame_timestamp": 100.0,
        "last_frame_timestamp": 100.5,
        "frames": [
            {
                "frame_id": f"frame-{oid}",
                "observation_id": oid,
                "bound_node_id": 101,
                "depth": flag,
            }
            for oid, flag in zip(observation_ids, flags)
        ],
    }


class FrameGateTests(unittest.TestCase):
    def test_clean_frame_is_accepted(self) -> None:
        verdict = backtest.evaluate_frame(
            _observation("o1"), backtest.CapturePolicy.production()
        )
        self.assertTrue(verdict.accepted)
        self.assertIsNone(verdict.rejecting_gate)

    def test_production_rejects_non_scene_depth(self) -> None:
        """The single biggest field failure: 219/233 frames had no depth."""
        for method in ("shelf_plane_ray", "unavailable"):
            with self.subTest(method=method):
                verdict = backtest.evaluate_frame(
                    _observation("o1", method=method, needs_review=True),
                    backtest.CapturePolicy.production(),
                )
                self.assertFalse(verdict.accepted)
                self.assertEqual(
                    verdict.rejecting_gate, "measurement_unavailable"
                )

    def test_optimized_admits_plane_ray_evidence(self) -> None:
        verdict = backtest.evaluate_frame(
            _observation("o1", method="shelf_plane_ray", needs_review=True),
            backtest.CapturePolicy.optimized(),
        )
        self.assertTrue(verdict.accepted)

    def test_optimized_still_rejects_unmeasured_frame(self) -> None:
        verdict = backtest.evaluate_frame(
            _observation(
                "o1", method="unavailable", depth_samples=0, needs_review=True
            ),
            backtest.CapturePolicy.optimized(),
        )
        self.assertFalse(verdict.accepted)
        self.assertEqual(verdict.rejecting_gate, "measurement_unavailable")

    def test_optimized_still_rejects_missing_node_binding(self) -> None:
        verdict = backtest.evaluate_frame(
            _observation("o1", method="shelf_plane_ray", bound_node=False),
            backtest.CapturePolicy.optimized(),
        )
        self.assertFalse(verdict.accepted)
        self.assertEqual(verdict.rejecting_gate, "node_binding_missing")


class BurstGateTests(unittest.TestCase):
    def _replay(
        self,
        policy: backtest.CapturePolicy,
        frames: list[dict[str, object]],
        *,
        complete: bool = True,
    ) -> backtest.BurstVerdict:
        observations = {str(f["observation_id"]): f for f in frames}
        burst = _burst(
            "b1",
            [str(f["observation_id"]) for f in frames],
            complete=complete,
        )
        return backtest.evaluate_burst("s", burst, observations, policy)

    def test_incomplete_burst_is_rejected_first(self) -> None:
        frames = [_observation("o1"), _observation("o2")]
        verdict = self._replay(
            backtest.CapturePolicy.production(), frames, complete=False
        )
        self.assertEqual(verdict.rejecting_gate, "burst_incomplete")

    def test_production_needs_three_frames(self) -> None:
        """Two clean frames used to be discarded after the full window."""
        frames = [_observation("o1"), _observation("o2")]
        verdict = self._replay(backtest.CapturePolicy.production(), frames)
        self.assertFalse(verdict.resolved)
        self.assertEqual(verdict.rejecting_gate, "insufficient_frames")
        # The operator paid the full window for nothing.
        self.assertAlmostEqual(verdict.simulated_duration_s, 4.0, places=5)

    def test_optimized_resolves_two_frames(self) -> None:
        frames = [_observation("o1"), _observation("o2")]
        verdict = self._replay(backtest.CapturePolicy.optimized(), frames)
        self.assertTrue(verdict.resolved)
        self.assertIsNone(verdict.rejecting_gate)

    def test_single_frame_is_never_enough(self) -> None:
        """One frame is a fluke under either policy."""
        frames = [_observation("o1")]
        for policy in (
            backtest.CapturePolicy.production(),
            backtest.CapturePolicy.optimized(),
        ):
            with self.subTest(policy=policy.name):
                verdict = self._replay(policy, frames)
                self.assertFalse(verdict.resolved)
                self.assertEqual(verdict.rejecting_gate, "insufficient_frames")

    def test_optimized_caps_wait_at_two_and_a_half_seconds(self) -> None:
        frames = [_observation("o1")]
        verdict = self._replay(backtest.CapturePolicy.optimized(), frames)
        self.assertLessEqual(verdict.simulated_duration_s, 2.5)

    def test_early_exit_shortens_successful_capture(self) -> None:
        frames = [
            _observation("o1"),
            _observation("o2"),
            _observation("o3"),
        ]
        verdict = self._replay(backtest.CapturePolicy.optimized(), frames)
        self.assertTrue(verdict.resolved)
        # 0.5 s observed over 3 frames -> target reached well before the cap.
        self.assertLess(verdict.simulated_duration_s, 1.0)


class PolicyComparisonTests(unittest.TestCase):
    def test_optimized_dominates_on_depth_starved_field(self) -> None:
        """Scene captures: most frames carry no scene depth at all."""
        frames = [
            _observation(
                f"o{index}",
                method="shelf_plane_ray",
                needs_review=True,
            )
            for index in range(4)
        ]
        observations = {str(f["observation_id"]): f for f in frames}
        burst = _burst("b1", [str(f["observation_id"]) for f in frames])

        base = backtest.evaluate_burst(
            "s", burst, observations, backtest.CapturePolicy.production()
        )
        opt = backtest.evaluate_burst(
            "s", burst, observations, backtest.CapturePolicy.optimized()
        )
        self.assertFalse(base.resolved)
        self.assertTrue(opt.resolved)
        self.assertLess(opt.simulated_duration_s, base.simulated_duration_s)

    def test_production_still_wins_nothing_on_clean_capture(self) -> None:
        """When depth is available both policies succeed; optimised is faster."""
        frames = [_observation(f"o{i}") for i in range(4)]
        observations = {str(f["observation_id"]): f for f in frames}
        burst = _burst("b1", [str(f["observation_id"]) for f in frames])

        base = backtest.evaluate_burst(
            "s", burst, observations, backtest.CapturePolicy.production()
        )
        opt = backtest.evaluate_burst(
            "s", burst, observations, backtest.CapturePolicy.optimized()
        )
        self.assertTrue(base.resolved)
        self.assertTrue(opt.resolved)
        self.assertLessEqual(opt.simulated_duration_s, base.simulated_duration_s)


class DiscoveryTests(unittest.TestCase):
    def test_discovers_sessions_and_tolerates_empty_tree(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            self.assertEqual(backtest.discover_sessions([tmp]), [])
            session = os.path.join(tmp, "SupermarketSession-x", "segment_0001")
            os.makedirs(session)
            with open(
                os.path.join(session, "tag_observations.jsonl"),
                "w",
                encoding="utf-8",
            ) as handle:
                handle.write('{"observation_id":"o1"}\n')
            found = backtest.discover_sessions([tmp])
            self.assertEqual(len(found), 1)
            self.assertTrue(found[0].endswith("segment_0001"))

    def test_report_runs_over_synthetic_tree(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            session = os.path.join(tmp, "SupermarketSession-x", "segment_0001")
            os.makedirs(session)
            with open(
                os.path.join(session, "tag_observations.jsonl"),
                "w",
                encoding="utf-8",
            ) as handle:
                for index in range(3):
                    handle.write(
                        '{"observation_id":"o%d","measurement_method":'
                        '"shelf_plane_ray","depth_sample_count":0,'
                        '"localization_state":"weak",'
                        '"alignment_freshness":"fresh","bound_node_id":9,'
                        '"needs_review":true}\n' % index
                    )
            with open(
                os.path.join(session, "tag_observation_bursts.jsonl"),
                "w",
                encoding="utf-8",
            ) as handle:
                handle.write(
                    '{"burst_id":"b1","barcode":"1","sequence":1,'
                    '"complete":true,"first_frame_timestamp":0,'
                    '"last_frame_timestamp":0.6,"frames":['
                    + ",".join(
                        '{"frame_id":"f%d","observation_id":"o%d",'
                        '"bound_node_id":9,"depth":0}' % (i, i)
                        for i in range(3)
                    )
                    + "]}\n"
                )
            report = backtest.run(tmp, [tmp], backtest.CapturePolicy.optimized())
            self.assertEqual(report.total_bursts, 1)
            self.assertEqual(report.resolved_bursts, 1)
            self.assertAlmostEqual(report.success_rate, 1.0)

            base = backtest.run(tmp, [tmp], backtest.CapturePolicy.production())
            self.assertEqual(base.resolved_bursts, 0)


if __name__ == "__main__":
    unittest.main()
