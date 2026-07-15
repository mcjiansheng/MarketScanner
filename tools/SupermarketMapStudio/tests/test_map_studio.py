from __future__ import annotations

import json
import sqlite3
import struct
import sys
import tempfile
import threading
import time
import unittest
import zlib
from pathlib import Path
from urllib.request import Request, urlopen


STUDIO_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(STUDIO_DIR))
import server  # noqa: E402


def transform_blob(x: float, y: float, z: float) -> bytes:
    return struct.pack("<12f", 1.0, 0.0, 0.0, x, 0.0, 1.0, 0.0, y, 0.0, 0.0, 1.0, z)


def png_chunk(kind: bytes, payload: bytes) -> bytes:
    return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", zlib.crc32(kind + payload) & 0xFFFFFFFF)


def depth_png(width: int, height: int, values: list[float]) -> bytes:
    rows = bytearray()
    for row in range(height):
        rows.append(0)
        for value in values[row * width : (row + 1) * width]:
            bgra = struct.pack("<f", value)
            rows.extend((bgra[2], bgra[1], bgra[0], bgra[3]))
    header = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + png_chunk(b"IHDR", header) + png_chunk(b"IDAT", zlib.compress(rows)) + png_chunk(b"IEND", b"")


def calibration_blob(width: int, height: int) -> bytes:
    header = struct.pack("<11i", 0, 23, 5, 0, width, height, 9, 0, 0, 0, 12)
    camera = struct.pack("<9d", 2.0, 0.0, width / 2, 0.0, 2.0, height / 2, 0.0, 0.0, 1.0)
    return header + camera + transform_blob(0.0, 0.0, 0.0)


def create_session(root: Path, name: str, offset: float) -> Path:
    session = root / name
    segment = session / "segment_0001"
    segment.mkdir(parents=True)
    db = segment / "rtabmap_segment_0001.db"
    conn = sqlite3.connect(db)
    conn.execute("CREATE TABLE Node (id INTEGER PRIMARY KEY, pose BLOB, stamp REAL)")
    conn.execute("INSERT INTO Node VALUES (?, ?, ?)", (1, transform_blob(offset, 1.1, 0.0), 1.0))
    conn.execute("INSERT INTO Node VALUES (?, ?, ?)", (2, transform_blob(offset + 2.0, 1.5, 1.0), 2.0))
    conn.commit()
    conn.close()
    (segment / "._rtabmap_segment_0001.db").write_bytes(b"AppleDouble metadata")
    (segment / "metadata.json").write_text(json.dumps({"segmentIndex": 1}), encoding="utf-8")
    (segment / "price_tags.json").write_text("[]", encoding="utf-8")
    return session


class MapStudioApiTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.httpd = server.create_server(0)
        cls.port = cls.httpd.server_port
        cls.thread = threading.Thread(target=cls.httpd.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls) -> None:
        cls.httpd.shutdown()
        cls.httpd.server_close()
        cls.thread.join(timeout=2)

    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        root = Path(self.temp.name)
        self.session_a = create_session(root, "SupermarketSession-A", 0.0)
        self.session_b = create_session(root, "SupermarketSession-B", 0.4)
        self.root = root

    def tearDown(self) -> None:
        self.temp.cleanup()

    def api(self, path: str, payload: dict | None = None) -> dict:
        url = f"http://127.0.0.1:{self.port}{path}"
        if payload is None:
            with urlopen(url, timeout=10) as response:
                return json.loads(response.read())
        request = Request(url, data=json.dumps(payload).encode("utf-8"), headers={"Content-Type": "application/json"}, method="POST")
        with urlopen(request, timeout=10) as response:
            return json.loads(response.read())

    def wait_for_job(self, identifier: str) -> dict:
        deadline = time.time() + 10
        while time.time() < deadline:
            job = self.api(f"/api/jobs/{identifier}")
            if job["status"] in {"complete", "failed"}:
                return job
            time.sleep(0.05)
        self.fail("Timed out waiting for map job")

    def test_inspect_and_stage_job_write_preview_artifacts(self) -> None:
        inspection = self.api("/api/session/inspect", {"session": str(self.session_a)})
        self.assertEqual(inspection["segment_count"], 1)
        self.assertEqual(inspection["node_count"], 2)

        output = self.session_a / "MapStudio-Stage-test"
        job = self.api(
            "/api/jobs",
            {
                "kind": "stage",
                "session": str(self.session_a),
                "output": str(output),
                "stage_config": {
                    "format": "SupermarketStageConfig",
                    "version": 1,
                    "stages": [
                        {
                            "id": "stage_1",
                            "name": "anchor",
                            "segments": [1],
                            "transform": {"dx": 0.2, "dy": 0, "yaw_deg": 0},
                        }
                    ],
                },
                "options": {},
            },
        )
        result = self.wait_for_job(job["id"])
        self.assertEqual(result["status"], "complete", result.get("error"))
        self.assertIn("preview.png", result["artifacts"])
        self.assertIn("preview_3d.json", result["artifacts"])
        preview = self.api(result["artifacts"]["preview_3d.json"])
        self.assertEqual(preview["format"], "SupermarketMap3DPreview")
        self.assertEqual(len(preview["segments"][0]["trajectory"]), 2)
        self.assertAlmostEqual(preview["segments"][0]["trajectory"][0][2], 0.0, places=4)
        manifest = self.api(result["artifacts"]["stage_manifest.json"])
        self.assertEqual(manifest["stages"][0]["name"], "anchor")
        self.assertAlmostEqual(manifest["stages"][0]["stage_transform"]["dx"], 0.2, places=4)

    def test_multi_device_job_creates_merge_manifest(self) -> None:
        output = self.root / "multi-output"
        job = self.api(
            "/api/jobs",
            {
                "kind": "multi",
                "output": str(output),
                "align_common_start": True,
                "devices": [
                    {"id": "phone_a", "session": str(self.session_a), "dx": 0, "dy": 0, "yaw_deg": 0},
                    {"id": "phone_b", "session": str(self.session_b), "dx": 0, "dy": 0, "yaw_deg": 0},
                ],
                "options": {},
            },
        )
        result = self.wait_for_job(job["id"])
        self.assertEqual(result["status"], "complete", result.get("error"))
        self.assertIn("multi_device_manifest.json", result["artifacts"])
        manifest = self.api(result["artifacts"]["multi_device_manifest.json"])
        self.assertEqual(len(manifest["devices"]), 2)

    def test_projected_points_keep_height_for_3d_preview(self) -> None:
        points_csv = self.root / "points.csv"
        points_csv.write_text("x,y,z,kind,segmentIndex\n1,2,3,wall,1\n", encoding="utf-8")
        point = server.base.load_projected_points([points_csv], "xz")[0]
        self.assertEqual((point.x, point.y, point.height), (1.0, 3.0, 2.0))

    def test_database_pose_is_converted_to_ios_xz_frame(self) -> None:
        parsed = server.base.parse_rtabmap_transform_3d(transform_blob(2.0, 1.5, 1.0), "xz")
        self.assertEqual(parsed, (-1.5, -2.0, 1.0, 0.0))

    def test_depth_png_and_calibration_create_point_cloud_preview(self) -> None:
        database = self.session_a / "segment_0001" / "rtabmap_segment_0001.db"
        with sqlite3.connect(database) as conn:
            conn.execute("CREATE TABLE Data (id INTEGER PRIMARY KEY, depth BLOB, calibration BLOB)")
            conn.execute(
                "INSERT INTO Data VALUES (?, ?, ?)",
                (1, depth_png(2, 2, [1.0, 1.5, 2.0, 2.5]), calibration_blob(2, 2)),
            )
        config = server.base.MapConfig(0.05, 0.1, 1.25, 1.0, 0.1, 8.0, "xz", False)
        segments = server.base.discover_segments(self.session_a, config)
        preview = server.base.extract_depth_point_cloud(
            segments, "xz", max_frames=1, pixel_step=1, max_depth=5.0
        )
        self.assertEqual(preview["decoded_frames"], 1)
        self.assertEqual(preview["point_count"], 4)
        self.assertEqual([round(value, 3) for value in server.base.decode_depth_image(depth_png(2, 2, [1.0, 1.5, 2.0, 2.5]))[2]], [1.0, 1.5, 2.0, 2.5])

    def test_trajectory_sidecar_is_used_when_database_is_missing(self) -> None:
        session = self.root / "SupermarketSession-Sidecar"
        segment = session / "segment_0001"
        segment.mkdir(parents=True)
        (segment / "metadata.json").write_text('{"segmentIndex": 1}', encoding="utf-8")
        (segment / "price_tags.json").write_text("[]", encoding="utf-8")
        (segment / "trajectory_samples.json").write_text(
            json.dumps(
                [
                    {"nodeCount": 1, "timestamp": 1, "x": 0, "y": 1.2, "z": 0, "yaw": 0},
                    {"nodeCount": 2, "timestamp": 2, "x": 2, "y": 1.3, "z": 1, "yaw": 0.2},
                ]
            ),
            encoding="utf-8",
        )
        inspection = self.api("/api/session/inspect", {"session": str(session)})
        self.assertEqual(inspection["node_count"], 2)

        output = self.root / "sidecar-output"
        job = self.api("/api/jobs", {"kind": "map", "session": str(session), "output": str(output), "options": {}})
        result = self.wait_for_job(job["id"])
        self.assertEqual(result["status"], "complete", result.get("error"))

    def test_empty_map_evidence_fails_without_creating_output(self) -> None:
        session = self.root / "SupermarketSession-Empty"
        segment = session / "segment_0001"
        segment.mkdir(parents=True)
        (segment / "metadata.json").write_text('{"segmentIndex": 1}', encoding="utf-8")
        (segment / "price_tags.json").write_text("[]", encoding="utf-8")
        output = self.root / "empty-output"
        job = self.api("/api/jobs", {"kind": "map", "session": str(session), "output": str(output), "options": {}})
        result = self.wait_for_job(job["id"])
        self.assertEqual(result["status"], "failed")
        self.assertIn("No valid trajectory", result["error"])
        self.assertFalse(output.exists())

    def test_nonempty_output_is_rejected(self) -> None:
        output = self.root / "occupied-output"
        output.mkdir()
        (output / "existing.txt").write_text("x", encoding="utf-8")
        with self.assertRaises(Exception):
            self.api("/api/jobs", {"kind": "map", "session": str(self.session_a), "output": str(output), "options": {}})


if __name__ == "__main__":
    unittest.main()
