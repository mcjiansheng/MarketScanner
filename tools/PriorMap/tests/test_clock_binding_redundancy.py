"""Clock node-binding redundancy: redundant repeats vs genuine conflicts.

Field data showed 14 of 36 sessions (38.9%) re-bind the same node id, because
the phone reuses a frozen exact-ID snapshot when no live snapshot is
available. Every one of those sessions previously aborted the whole PC job
with "Invalid or duplicate clock node binding".

These tests pin the distinction the fix relies on:

  - a repeat of the same node with the *same* stamp is redundant -- identity
    is still decidable, so it is retained (preserving the binding count that
    the metadata watermark requires) and surfaced as a degradation code;
  - a repeat carrying a *different* stamp is a genuine identity conflict and
    must stay fatal.
"""

from __future__ import annotations

import json
import unittest

from tools.PriorMap.offline_localization import (
    OfflineLocalizationError,
    _read_clock_evidence_bytes,
)

SESSION = "F69954A1-50CC-4A95-9386-80616797202D"
TIMEZONE = "Asia/Shanghai"
OFFSET = 28800


def _binding(
    node_id: int,
    node_stamp: float,
    frame_stamp: float,
    utc: float,
) -> dict:
    return {
        "format": "MarketScannerClockCorrelation",
        "version": 2,
        "record_kind": "node_binding",
        "reason": "node_bound",
        "tracking_session_id": SESSION,
        "node_id": node_id,
        "node_stamp": node_stamp,
        "sampled_frame_timestamp": frame_stamp,
        "system_uptime": utc - 1_700_000_000.0,
        "utc_unix_seconds": utc,
        "timezone_id": TIMEZONE,
        "utc_offset_seconds": OFFSET,
    }


def _correlation(monotonic: float, utc: float, reason: str) -> dict:
    return {
        "format": "MarketScannerClockCorrelation",
        "version": 2,
        "record_kind": "correlation",
        "reason": reason,
        "tracking_session_id": SESSION,
        "monotonic_seconds": monotonic,
        "utc_unix_seconds": utc,
        "timezone_id": TIMEZONE,
        "utc_offset_seconds": OFFSET,
    }


def _bytes(records: list[dict]) -> bytes:
    return ("\n".join(json.dumps(r) for r in records) + "\n").encode("utf-8")


def _metadata(correlation_count: int, binding_count: int) -> dict:
    return {
        "trackingSessionId": SESSION,
        "clockCorrelationCount": correlation_count,
        "clockNodeBindingCount": binding_count,
        "clockEvidenceComplete": True,
    }


class RedundantDuplicateTests(unittest.TestCase):
    def _read(self, bindings: list[dict], correlations: list[dict] | None = None):
        if correlations is None:
            # The contract requires at least two correlations bracketing the
            # bindings; without them the watermark check fails before the
            # duplicate-binding logic is ever reached.
            start = min(b["utc_unix_seconds"] for b in bindings) - 1.0
            end = max(b["utc_unix_seconds"] for b in bindings) + 1.0
            correlations = self._two_correlations(start, end)
        node_stamps = {b["node_id"]: b["node_stamp"] for b in bindings}
        return _read_clock_evidence_bytes(
            _bytes(correlations + bindings),
            metadata=_metadata(len(correlations), len(bindings)),
            node_stamps_by_id=node_stamps,
        )

    def _two_correlations(self, start_utc: float, end_utc: float) -> list[dict]:
        return [
            _correlation(start_utc - 1_700_000_000.0, start_utc, "session_start"),
            _correlation(end_utc - 1_700_000_000.0, end_utc, "session_end"),
        ]

    def test_identical_repeat_is_retained_and_flagged(self) -> None:
        """Same node, same stamp, later sample: redundant, not ambiguous."""
        base = 1_786_400_000.0
        bindings = [
            _binding(1, base + 1.0, base + 1.0, base + 1.0),
            _binding(2, base + 2.0, base + 2.0, base + 2.0),
            # Re-binding of node 2 produced by a reused frozen snapshot.
            _binding(2, base + 2.0, base + 2.7, base + 2.7),
            _binding(3, base + 3.0, base + 3.0, base + 3.0),
        ]
        _evidence, diagnostics = self._read(bindings)
        self.assertEqual(diagnostics["redundant_duplicate_binding_count"], 1)
        self.assertIn(
            "clock_node_binding_redundant_duplicate_retained",
            diagnostics["degradation_codes"],
        )
        # The binding count still matches the declared watermark.
        self.assertEqual(diagnostics["declared_binding_count"], 4)

    def test_conflicting_repeat_stays_fatal(self) -> None:
        """Same node id, different stamp: identity is no longer decidable."""
        base = 1_786_400_000.0
        bindings = [
            _binding(1, base + 1.0, base + 1.0, base + 1.0),
            _binding(2, base + 2.0, base + 2.0, base + 2.0),
            _binding(2, base + 9.0, base + 9.0, base + 2.7),
        ]
        with self.assertRaises(OfflineLocalizationError):
            self._read(bindings)

    def test_stamp_not_matching_database_stays_fatal(self) -> None:
        base = 1_786_400_000.0
        bindings = [
            _binding(1, base + 1.0, base + 1.0, base + 1.0),
            _binding(2, base + 2.0, base + 2.0, base + 2.0),
        ]
        node_stamps = {1: base + 1.0, 2: base + 5.0}  # database disagrees
        with self.assertRaises(OfflineLocalizationError):
            _read_clock_evidence_bytes(
                _bytes(bindings),
                metadata=_metadata(0, len(bindings)),
                node_stamps_by_id=node_stamps,
            )

    def test_clean_file_has_no_redundancy_flag(self) -> None:
        base = 1_786_400_000.0
        bindings = [
            _binding(1, base + 1.0, base + 1.0, base + 1.0),
            _binding(2, base + 2.0, base + 2.0, base + 2.0),
            _binding(3, base + 3.0, base + 3.0, base + 3.0),
        ]
        _evidence, diagnostics = self._read(bindings)
        self.assertEqual(diagnostics["redundant_duplicate_binding_count"], 0)
        self.assertNotIn(
            "clock_node_binding_redundant_duplicate_retained",
            diagnostics["degradation_codes"],
        )


if __name__ == "__main__":
    unittest.main()
