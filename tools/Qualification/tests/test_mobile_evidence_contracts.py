from __future__ import annotations

import unittest

from tools.PriorMap.generated_mobile_evidence_contracts import (
    MOBILE_EVIDENCE_CONTRACTS,
)
from tools.Qualification.generate_mobile_contracts import CONTRACT


class MobileEvidenceContractTests(unittest.TestCase):
    def test_scan_events_has_a_generated_strict_streaming_contract(self) -> None:
        generated = MOBILE_EVIDENCE_CONTRACTS["scan_events.jsonl"]
        self.assertEqual(
            generated,
            CONTRACT["evidence_files"]["scan_events.jsonl"],
        )
        self.assertEqual(generated["blank_line_policy"], "reject")
        self.assertTrue(generated["final_newline"])
        self.assertTrue(generated["strict_bool"])
        self.assertTrue(generated["strict_integer"])
        self.assertEqual(generated["identity_fields"], ["trackingSessionId"])
        # Finalized metadata has no scan-event count/last-ID watermark yet.
        # Identity and strict framing are enforced now; cardinality remains a
        # future writer-schema migration rather than an invented reader value.
        self.assertEqual(generated["watermark_fields"], [])
        self.assertGreater(generated["max_file_bytes"], 0)
        self.assertGreater(generated["max_record_bytes"], 0)
        self.assertGreater(generated["max_records"], 0)

    def test_trace_hard_cap_is_not_misreported_as_qualified_scale(self) -> None:
        trace = MOBILE_EVIDENCE_CONTRACTS["localization_trace.jsonl"]
        qualified = 48 * 3600 * 10
        self.assertEqual(trace["qualification_record_rate_hz"], 10)
        self.assertEqual(trace["qualification_max_records"], qualified)
        self.assertGreater(trace["max_records"], qualified)

    def test_constraint_scale_watermark_and_native_caps_are_frozen(self) -> None:
        constraints = MOBILE_EVIDENCE_CONTRACTS[
            "localization_constraints.jsonl"
        ]
        qualified = 48 * 3600 * 2
        self.assertEqual(
            constraints,
            CONTRACT["evidence_files"]["localization_constraints.jsonl"],
        )
        self.assertEqual(constraints["qualification_record_rate_hz"], 2)
        self.assertEqual(constraints["qualification_max_records"], qualified)
        self.assertEqual(qualified, 345_600)
        self.assertGreaterEqual(constraints["max_records"], qualified)
        self.assertEqual(constraints["max_record_bytes"], 64 * 1024)
        self.assertEqual(constraints["max_file_bytes"], 768 * 1024 * 1024)
        self.assertEqual(
            constraints["watermark_fields"],
            ["captureHealth.localizationConstraintRecordCount"],
        )
        manual = MOBILE_EVIDENCE_CONTRACTS[
            "manual_localization_events.jsonl"
        ]
        self.assertEqual(
            manual["watermark_fields"],
            ["captureHealth.manualLocalizationEventCount"],
        )
        metadata = MOBILE_EVIDENCE_CONTRACTS["metadata.json"]
        for watermark in (
            "captureHealth.localizationConstraintRecordCount",
            "captureHealth.manualLocalizationEventCount",
            "captureHealth.localizationRecoveryEventCount",
        ):
            self.assertIn(watermark, metadata["watermark_fields"])
        native = MOBILE_EVIDENCE_CONTRACTS["native_graph"]
        self.assertEqual(native["max_skeleton_nodes"], 4096)
        self.assertEqual(native["max_factors"], 4096)
        self.assertEqual(native["max_priors"], 4096)


if __name__ == "__main__":
    unittest.main()
