from __future__ import annotations

import hashlib
import json
import sys
import tempfile
import unittest
from pathlib import Path


STUDIO_DIR = Path(__file__).resolve().parents[1]
TOOLS_DIR = STUDIO_DIR.parent
sys.path.insert(0, str(STUDIO_DIR))
sys.path.insert(0, str(TOOLS_DIR))

import performance_analysis as performance  # noqa: E402


class PerformanceAnalysisTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.session = self.root / "SupermarketSession-test"
        self.segment = self.session / "segment_0001"
        self.segment.mkdir(parents=True)
        self.tracking_id = "tracking-performance-test"

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def sample(
        self,
        sequence: int,
        timestamp: float,
        *,
        thermal: str = "nominal",
        tracking_id: str | None = None,
    ) -> dict:
        return {
            "format": "MarketScannerPerformanceSample",
            "version": 1,
            "sequence": sequence,
            "timestamp_unix": timestamp,
            "process_uptime_seconds": 100.0 + sequence * 5.0,
            "tracking_session_id": tracking_id or self.tracking_id,
            "scan_state": "mapping",
            "tracking_state": "normal",
            "node_count": sequence * 10,
            "database_memory_mb": 100 + sequence,
            "database_bytes": sequence * 1_000_000,
            "scan_storage_bytes": sequence * 1_100_000,
            "process_memory_footprint_mb": 700 + sequence * 10,
            "available_memory_mb": max(100, 1800 - sequence * 20),
            "process_cpu_time_seconds": 20.0 + sequence,
            "process_cpu_percent": 50.0 + sequence * 5.0,
            "thermal_state": thermal,
            "battery_percent": max(0.0, 90.0 - sequence),
            "battery_charging": False,
            "available_disk_bytes": 100_000_000_000 - sequence * 2_000_000,
            "rendering_fps": max(0.1, 30.0 - sequence),
            "rtabmap_update_time_ms": 20.0 + sequence * 2.0,
            "word_count": sequence * 100,
            "feature_count": 500,
            "point_count": sequence * 1000,
            "polygon_count": 0,
            "online_loop_closure_count": sequence - 1,
            "reliable_loop_closure_count": max(0, sequence - 2),
            "gpu_metric_status": "not_available_public_ios_api",
            "gpu_utilization_percent": None,
        }

    def write_evidence(
        self,
        rows: list[dict],
        *,
        final_newline: bool = True,
        metadata_overrides: dict | None = None,
        preserve_scan_state: bool = False,
    ) -> bytes:
        rows = [dict(row) for row in rows]
        if rows and not preserve_scan_state:
            rows[-1]["scan_state"] = "finalizing"
        raw = b"".join(
            json.dumps(row, sort_keys=True, separators=(",", ":")).encode("utf-8")
            + b"\n"
            for row in rows
        )
        if raw and not final_newline:
            raw = raw[:-1]
        (self.segment / performance.PERFORMANCE_FILE_NAME).write_bytes(raw)
        metadata = {
            "trackingSessionId": self.tracking_id,
            "performanceSamples": performance.PERFORMANCE_FILE_NAME,
            "performanceSampleIntervalSeconds": 5.0,
            "performanceSampleCount": len(rows),
            "performanceLastSequence": len(rows) if rows else None,
            "performanceLastTimestampUnix": rows[-1]["timestamp_unix"] if rows else None,
            "performanceEvidenceComplete": bool(rows),
            "performanceWriteFailureCount": 0,
        }
        metadata.update(metadata_overrides or {})
        (self.segment / "metadata.json").write_text(
            json.dumps(metadata), encoding="utf-8"
        )
        return raw

    def test_strict_analysis_and_result_package_preserve_raw_hash(self) -> None:
        raw = self.write_evidence(
            [
                self.sample(1, 1_800_000_000.0),
                self.sample(2, 1_800_000_005.0),
                self.sample(3, 1_800_000_010.0),
            ]
        )
        summary = performance.analyze_session(self.session)
        self.assertTrue(summary["available"])
        self.assertTrue(summary["validated"])
        self.assertTrue(summary["performance_qualified"])
        self.assertEqual(summary["sample_count"], 3)
        self.assertEqual(summary["source"]["sha256"], hashlib.sha256(raw).hexdigest())
        self.assertAlmostEqual(
            summary["metrics"]["process_cpu_percent"]["mean"], 60.0
        )
        self.assertEqual(
            summary["source"]["gpu_metric_statuses"],
            ["not_available_public_ios_api"],
        )

        output = self.root / "MapStudio-result"
        packaged = performance.write_result_artifacts(self.session, output)
        package = output / "performance" / "phone"
        self.assertEqual(
            (package / performance.RAW_FILE_NAME).read_bytes(), raw
        )
        self.assertTrue((package / performance.CSV_FILE_NAME).is_file())
        persisted = json.loads(
            (package / performance.SUMMARY_FILE_NAME).read_text(encoding="utf-8")
        )
        self.assertEqual(persisted["source"]["sha256"], packaged["source"]["sha256"])

    def test_serious_thermal_is_retained_as_a_performance_warning(self) -> None:
        self.write_evidence(
            [
                self.sample(1, 1_800_000_000.0),
                self.sample(2, 1_800_000_005.0, thermal="serious"),
            ]
        )
        summary = performance.analyze_session(self.session)
        self.assertTrue(summary["validated"])
        self.assertFalse(summary["performance_qualified"])
        self.assertIn(
            "serious_or_critical_thermal_samples_detected", summary["warnings"]
        )
        self.assertEqual(summary["thermal"]["serious_or_critical_sample_count"], 1)

    def test_rejects_missing_final_newline(self) -> None:
        raw = self.write_evidence(
            [self.sample(1, 1_800_000_000.0)], final_newline=False
        )
        summary = performance.analyze_session(self.session)
        self.assertFalse(summary["available"])
        self.assertIn("newline", summary["reason"])
        packaged = performance.write_result_artifacts(
            self.session, self.root / "invalid-result"
        )
        self.assertFalse(packaged["validated"])
        forensic = (
            self.root
            / "invalid-result"
            / "performance"
            / "phone"
            / performance.INVALID_RAW_FILE_NAME
        )
        self.assertEqual(forensic.read_bytes(), raw)

    def test_rejects_sequence_gap_timestamp_regression_and_identity_change(self) -> None:
        cases = (
            [self.sample(1, 1_800_000_000.0), self.sample(3, 1_800_000_005.0)],
            [self.sample(1, 1_800_000_005.0), self.sample(2, 1_800_000_004.0)],
            [
                self.sample(1, 1_800_000_000.0),
                self.sample(2, 1_800_000_005.0, tracking_id="different"),
            ],
        )
        for index, rows in enumerate(cases):
            with self.subTest(index=index):
                self.write_evidence(rows)
                summary = performance.analyze_session(self.session)
                self.assertFalse(summary["available"])
                self.assertIn("performance_evidence_invalid", summary["reason"])

    def test_rejects_metadata_watermark_drift_and_non_finite_json(self) -> None:
        self.write_evidence(
            [self.sample(1, 1_800_000_000.0)],
            metadata_overrides={"performanceSampleCount": 2},
        )
        summary = performance.analyze_session(self.session)
        self.assertFalse(summary["available"])
        self.assertIn("performance_evidence_invalid", summary["reason"])

        record = self.sample(1, 1_800_000_000.0)
        line = json.dumps(record, separators=(",", ":")).replace(
            '"process_cpu_percent":55.0', '"process_cpu_percent":NaN'
        )
        (self.segment / performance.PERFORMANCE_FILE_NAME).write_text(
            line + "\n", encoding="utf-8"
        )
        (self.segment / "metadata.json").write_text(
            json.dumps(
                {
                    "trackingSessionId": self.tracking_id,
                    "performanceSamples": performance.PERFORMANCE_FILE_NAME,
                    "performanceSampleIntervalSeconds": 5.0,
                    "performanceSampleCount": 1,
                    "performanceLastSequence": 1,
                    "performanceLastTimestampUnix": 1_800_000_000.0,
                    "performanceEvidenceComplete": True,
                    "performanceWriteFailureCount": 0,
                }
            ),
            encoding="utf-8",
        )
        summary = performance.analyze_session(self.session)
        self.assertFalse(summary["available"])
        self.assertIn("non-finite", summary["reason"])

    def test_large_series_is_deterministically_bounded(self) -> None:
        rows = [
            self.sample(index, 1_800_000_000.0 + index * 5.0)
            for index in range(1, 25_001)
        ]
        self.write_evidence(rows)
        first = performance.analyze_session(self.session, series_limit=128)
        second = performance.analyze_session(self.session, series_limit=128)
        self.assertTrue(first["validated"])
        self.assertEqual(first["sample_count"], 25_000)
        self.assertLessEqual(len(first["series"]), 128)
        self.assertEqual(first["series"], second["series"])
        self.assertFalse(
            first["metrics"]["process_cpu_percent"]["quantiles_exact"]
        )
        self.assertLessEqual(
            first["metrics"]["process_cpu_percent"]["quantile_sample_count"],
            performance.MAXIMUM_QUANTILE_SAMPLES,
        )

    def test_rejects_metadata_schema_unknown_fields_and_fake_gpu(self) -> None:
        self.write_evidence([self.sample(1, 1_800_000_000.0)])
        (self.segment / "metadata.json").write_text("{}", encoding="utf-8")
        self.assertFalse(performance.analyze_session(self.session)["available"])

        row = self.sample(1, 1_800_000_000.0)
        row["unexpected"] = 1
        self.write_evidence([row])
        summary = performance.analyze_session(self.session)
        self.assertFalse(summary["available"])
        self.assertIn("unknown performance sample fields", summary["reason"])

        row = self.sample(1, 1_800_000_000.0)
        row["gpu_metric_status"] = "inferred"
        row["gpu_utilization_percent"] = 50.0
        self.write_evidence([row])
        summary = performance.analyze_session(self.session)
        self.assertFalse(summary["available"])
        self.assertIn("GPU utilization", summary["reason"])

    def test_rejects_duplicate_keys_uptime_regression_and_missing_terminal_sample(self) -> None:
        row = self.sample(1, 1_800_000_000.0)
        self.write_evidence([row])
        raw = (self.segment / performance.PERFORMANCE_FILE_NAME).read_text(
            encoding="utf-8"
        )
        duplicated = raw.replace('"version":1', '"version":1,"version":1')
        (self.segment / performance.PERFORMANCE_FILE_NAME).write_text(
            duplicated, encoding="utf-8"
        )
        summary = performance.analyze_session(self.session)
        self.assertFalse(summary["available"])
        self.assertIn("Duplicate JSON key", summary["reason"])

        first = self.sample(1, 1_800_000_000.0)
        second = self.sample(2, 1_800_000_005.0)
        second["process_uptime_seconds"] = first["process_uptime_seconds"]
        self.write_evidence([first, second])
        summary = performance.analyze_session(self.session)
        self.assertFalse(summary["available"])
        self.assertIn("uptime", summary["reason"])

        self.write_evidence(
            [self.sample(1, 1_800_000_000.0)],
            preserve_scan_state=True,
        )
        summary = performance.analyze_session(self.session)
        self.assertFalse(summary["available"])
        self.assertIn("finalizing", summary["reason"])

    def test_sampling_gap_count_is_exact_after_series_compaction(self) -> None:
        rows = [
            self.sample(index, 1_800_000_000.0 + index * 5.0)
            for index in range(1, 25_001)
        ]
        rows[-1]["timestamp_unix"] += 120.0
        self.write_evidence(rows)
        summary = performance.analyze_session(self.session, series_limit=32)
        self.assertTrue(summary["validated"])
        self.assertFalse(summary["performance_qualified"])
        self.assertEqual(summary["cadence_seconds"]["gaps_over_threshold"], 1)
        self.assertIn("performance_sampling_gaps_detected", summary["warnings"])


if __name__ == "__main__":
    unittest.main()
