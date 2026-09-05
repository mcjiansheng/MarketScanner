#!/usr/bin/env python3
"""Source contracts for phase-1 fields embedded in the large iOS session type."""

from __future__ import annotations

import re
import unittest
from pathlib import Path


REPOSITORY = Path(__file__).resolve().parents[3]
SESSION_SOURCE = REPOSITORY / "app/ios/RTABMapApp/SupermarketScanSession.swift"


class PeriodicMaintenanceSourceContractTests(unittest.TestCase):
    def test_live_checkpoint_mission_fields_participate_in_synthesized_decoding(self) -> None:
        source = SESSION_SOURCE.read_text(encoding="utf-8")
        checkpoint = source.split("struct ScanLiveCheckpoint: Codable {", 1)[1].split(
            "struct ManualLocalizationEvent", 1
        )[0]
        for field in (
            "missionId",
            "missionFormatVersion",
            "unitId",
            "unitIndex",
            "rolloverTrigger",
            "activeCaptureElapsedS",
            "nextMaintenanceAtActiveS",
            "maintenancePolicyVersion",
            "maintenanceState",
            "boundaryCheckpointId",
        ):
            self.assertRegex(
                checkpoint,
                rf"\bvar\s+{field}:\s*[^\n=]+\?\s*=\s*nil",
                f"{field} must be mutable so synthesized Decodable reads it",
            )
            self.assertNotRegex(checkpoint, rf"\blet\s+{field}\b")

    def test_final_metadata_uses_sanitized_active_capture_duration(self) -> None:
        source = SESSION_SOURCE.read_text(encoding="utf-8")
        binding = source.split("struct ScanMissionUnitBinding {", 1)[1].split(
            "struct ScanPerformanceSampleInput", 1
        )[0]
        self.assertIn(
            "metadata.activeCaptureDurationS = sanitizedActiveCaptureDurationS",
            binding,
        )
        self.assertNotIn(
            "metadata.activeCaptureDurationS = activeCaptureDurationS\n",
            binding,
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
