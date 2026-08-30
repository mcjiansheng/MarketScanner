"""Source-level contracts that unit tests over Swift cannot express.

Swift assertions can pin a constant's *value*, but they cannot prove that two
call sites both read that constant instead of re-typing the number. These
scans close that gap for the structure-point threshold, which regressed
exactly that way: the search threshold lived in a named constant while the
acceptance threshold was a literal, and the two silently disagreed for the
whole 30-44 band.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
IOS = ROOT / "app" / "ios" / "RTABMapApp"

MATCHER = IOS / "PriorMapScanMatcher.swift"
LOCALIZATION = IOS / "PriorMapLocalization.swift"

# Literal point-count comparisons that must not come back.
_LITERAL_POINT_GATE = re.compile(
    r"(points\.count\s*>=\s*45"
    r"|effectivePointCount[^\n]*>=\s*45"
    r"|minimumSearchPointCount\s*=\s*(?!30)\d+)"
)


def _read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


class StructurePointThresholdTests(unittest.TestCase):
    def test_sources_exist(self) -> None:
        self.assertTrue(MATCHER.is_file(), MATCHER)
        self.assertTrue(LOCALIZATION.is_file(), LOCALIZATION)

    def test_search_threshold_is_declared_once(self) -> None:
        source = _read(MATCHER)
        self.assertIn(
            "static let minimumSearchPointCount = 30",
            source,
            "structure point search threshold must be a single named constant",
        )

    def test_no_literal_point_gate_in_matcher(self) -> None:
        match = _LITERAL_POINT_GATE.search(_read(MATCHER))
        if match is not None:
            self.fail(
                "hardcoded structure point gate found in matcher: "
                f"{match.group(0)!r}"
            )

    def test_localization_reads_the_constant(self) -> None:
        """The second call site must reference the constant, not a copy."""
        source = _read(LOCALIZATION)
        self.assertIn(
            "PriorMapScanMatcher.minimumSearchPointCount",
            source,
            "PriorMapLocalization must read the matcher's point threshold",
        )
        match = _LITERAL_POINT_GATE.search(source)
        if match is not None:
            self.fail(
                "hardcoded structure point gate found in localization: "
                f"{match.group(0)!r}"
            )

    def test_acceptance_gate_uses_the_constant(self) -> None:
        source = _read(MATCHER)
        self.assertIn(
            "points.count >= Self.minimumSearchPointCount",
            source,
            "acceptance gate must use the shared search threshold",
        )


if __name__ == "__main__":
    unittest.main()
