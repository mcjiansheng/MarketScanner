"""Regression tests for the map-anchored shelf occlusion classifier (C-3a)."""

from __future__ import annotations

import math
import unittest

from tools.PriorMap.shelf_occlusion_classifier import (
    CLASS_SHELF_END_REGION,
    CLASS_STATIC_OCCLUDER,
    CLASS_UNCLASSIFIED_LARGE_GAP,
    MAX_STATIC_OCCLUDER_GAP_M,
    MIN_STATIC_OCCLUDER_GAP_M,
    classify_shelf_observation_gaps,
)


class ShelfOcclusionClassifierTests(unittest.TestCase):
    def test_typical_static_customer_gap_on_ten_meter_shelf(self):
        # Field scenario: a 10 m shelf with a 1-2 m gap caused by a standing
        # customer; both flanks were observed during the pass.
        gaps = classify_shelf_observation_gaps(10.0, [(0.0, 4.0), (6.0, 10.0)])
        self.assertEqual(len(gaps), 1)
        gap = gaps[0]
        self.assertAlmostEqual(gap.start_m, 4.0)
        self.assertAlmostEqual(gap.length_m, 2.0)
        self.assertEqual(gap.classification, CLASS_STATIC_OCCLUDER)
        self.assertTrue(gap.presumed_shelf_present)

    def test_unordered_overlapping_intervals_are_merged(self):
        gaps = classify_shelf_observation_gaps(
            10.0, [(5.5, 10.0), (0.0, 3.0), (2.5, 4.5)])
        self.assertEqual(len(gaps), 1)
        self.assertEqual(gaps[0].classification, CLASS_STATIC_OCCLUDER)
        self.assertAlmostEqual(gaps[0].start_m, 4.5)
        self.assertAlmostEqual(gaps[0].length_m, 1.0)

    def test_leading_gap_is_shelf_end_region_without_assertion(self):
        gaps = classify_shelf_observation_gaps(10.0, [(2.0, 10.0)])
        self.assertEqual(len(gaps), 1)
        self.assertEqual(gaps[0].classification, CLASS_SHELF_END_REGION)
        self.assertIsNone(gaps[0].presumed_shelf_present)
        self.assertAlmostEqual(gaps[0].length_m, 2.0)

    def test_trailing_gap_is_shelf_end_region(self):
        gaps = classify_shelf_observation_gaps(10.0, [(0.0, 8.0)])
        self.assertEqual(len(gaps), 1)
        self.assertEqual(gaps[0].classification, CLASS_SHELF_END_REGION)

    def test_large_interior_gap_gets_no_presence_assertion(self):
        gaps = classify_shelf_observation_gaps(10.0, [(0.0, 2.0), (7.0, 10.0)])
        self.assertEqual(len(gaps), 1)
        self.assertEqual(gaps[0].classification, CLASS_UNCLASSIFIED_LARGE_GAP)
        self.assertIsNone(gaps[0].presumed_shelf_present)
        self.assertAlmostEqual(gaps[0].length_m, 5.0)

    def test_interior_gap_at_max_boundary_is_still_static_occluder(self):
        gaps = classify_shelf_observation_gaps(
            10.0, [(0.0, 3.0), (3.0 + MAX_STATIC_OCCLUDER_GAP_M, 10.0)])
        self.assertEqual(len(gaps), 1)
        self.assertEqual(gaps[0].classification, CLASS_STATIC_OCCLUDER)

    def test_small_interior_gap_is_sampling_noise_not_occluder(self):
        gaps = classify_shelf_observation_gaps(
            10.0, [(0.0, 5.0), (5.0 + MIN_STATIC_OCCLUDER_GAP_M / 2, 10.0)])
        self.assertEqual(gaps, [])

    def test_empty_observations_yield_single_end_region(self):
        gaps = classify_shelf_observation_gaps(10.0, [])
        self.assertEqual(len(gaps), 1)
        self.assertEqual(gaps[0].classification, CLASS_SHELF_END_REGION)
        self.assertAlmostEqual(gaps[0].length_m, 10.0)

    def test_intervals_outside_shelf_are_clipped(self):
        gaps = classify_shelf_observation_gaps(
            10.0, [(-5.0, 4.0), (6.0, 20.0)])
        self.assertEqual(len(gaps), 1)
        self.assertEqual(gaps[0].classification, CLASS_STATIC_OCCLUDER)
        self.assertAlmostEqual(gaps[0].start_m, 4.0)
        self.assertAlmostEqual(gaps[0].length_m, 2.0)

    def test_multiple_static_occluders_in_one_pass(self):
        gaps = classify_shelf_observation_gaps(
            20.0, [(0.0, 4.0), (5.5, 9.0), (11.0, 20.0)])
        self.assertEqual(len(gaps), 2)
        for gap in gaps:
            self.assertEqual(gap.classification, CLASS_STATIC_OCCLUDER)
            self.assertTrue(gap.presumed_shelf_present)

    def test_zero_length_interval_is_ignored(self):
        gaps = classify_shelf_observation_gaps(10.0, [(3.0, 3.0), (0.0, 10.0)])
        self.assertEqual(gaps, [])

    def test_invalid_shelf_length_rejected(self):
        for bad in (0.0, -1.0, math.nan, math.inf, "10", None, True):
            with self.assertRaises(ValueError):
                classify_shelf_observation_gaps(bad, [(0.0, 1.0)])

    def test_invalid_interval_rejected(self):
        with self.assertRaises(ValueError):
            classify_shelf_observation_gaps(10.0, [(6.0, 4.0)])
        with self.assertRaises(ValueError):
            classify_shelf_observation_gaps(10.0, [(math.nan, 4.0)])
        with self.assertRaises(ValueError):
            classify_shelf_observation_gaps(10.0, [(0.0,)])
        with self.assertRaises(ValueError):
            classify_shelf_observation_gaps(10.0, ["bad"])

    def test_invalid_thresholds_rejected(self):
        with self.assertRaises(ValueError):
            classify_shelf_observation_gaps(
                10.0, [(0.0, 4.0)], min_gap_m=0.0)
        with self.assertRaises(ValueError):
            classify_shelf_observation_gaps(
                10.0, [(0.0, 4.0)], min_gap_m=3.0, max_occluder_m=2.0)


if __name__ == "__main__":
    unittest.main()
