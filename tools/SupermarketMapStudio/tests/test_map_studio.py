from __future__ import annotations

import json
import shutil
import sqlite3
import struct
import sys
import tempfile
import threading
import time
import unittest
import zlib
from contextlib import closing
from pathlib import Path
from types import SimpleNamespace
from unittest import mock
from urllib.error import HTTPError
from urllib.request import Request, urlopen


STUDIO_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(STUDIO_DIR))
import server  # noqa: E402
import folder_dialog  # noqa: E402


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


def cv_matrix_blob(payload: bytes, columns: int, matrix_type: int) -> bytes:
    return zlib.compress(payload) + struct.pack("<3i", 1, columns, matrix_type)


def add_optimized_poses(database: Path, transforms: dict[int, bytes]) -> None:
    node_ids = sorted(transforms)
    ids_blob = cv_matrix_blob(struct.pack(f"<{len(node_ids)}i", *node_ids), len(node_ids), 4)
    poses_payload = b"".join(transforms[node_id] for node_id in node_ids)
    poses_blob = cv_matrix_blob(poses_payload, len(node_ids) * 12, 5)
    with closing(sqlite3.connect(database)) as conn, conn:
        conn.execute("CREATE TABLE IF NOT EXISTS Admin (opt_ids BLOB, opt_poses BLOB)")
        conn.execute("DELETE FROM Admin")
        conn.execute("INSERT INTO Admin VALUES (?, ?)", (ids_blob, poses_blob))


def create_session(root: Path, name: str, offset: float, scan_mode: str | None = None) -> Path:
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
    metadata = {"segmentIndex": 1}
    if scan_mode is not None:
        metadata.update({"scanMode": scan_mode, "finalized": True, "nodeCount": 300})
    (segment / "metadata.json").write_text(json.dumps(metadata), encoding="utf-8")
    (segment / "price_tags.json").write_text("[]", encoding="utf-8")
    return session


def add_rgbd_frame(session: Path) -> None:
    database = session / "segment_0001" / "rtabmap_segment_0001.db"
    depths = [0.5] * (9 * 4) + [1.0] * (9 * 5)
    with closing(sqlite3.connect(database)) as conn, conn:
        conn.execute("CREATE TABLE Data (id INTEGER PRIMARY KEY, depth BLOB, calibration BLOB, image BLOB)")
        conn.execute(
            "INSERT INTO Data VALUES (?, ?, ?, ?)",
            (
                1,
                depth_png(9, 9, depths),
                calibration_blob(9, 9),
                b"\xff\xd8test",
            ),
        )


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
        try:
            with urlopen(request, timeout=10) as response:
                return json.loads(response.read())
        except HTTPError as exc:
            exc.close()
            raise

    def fetch(self, path: str) -> tuple[bytes, str]:
        with urlopen(f"http://127.0.0.1:{self.port}{path}", timeout=10) as response:
            return response.read(), response.headers.get_content_type()

    def wait_for_job(self, identifier: str) -> dict:
        deadline = time.time() + 10
        while time.time() < deadline:
            job = self.api(f"/api/jobs/{identifier}")
            if job["status"] in {"complete", "failed"}:
                return job
            time.sleep(0.05)
        self.fail("Timed out waiting for map job")

    def test_dialog_api_returns_selected_directory(self) -> None:
        with mock.patch.object(
            server.subprocess,
            "run",
            return_value=SimpleNamespace(
                returncode=0,
                stdout=str(self.session_a) + "\n",
                stderr="",
            ),
        ) as run:
            result = self.api(
                "/api/dialog",
                {"mode": "directory", "title": "选择扫描会话"},
            )
        self.assertEqual(result["path"], str(self.session_a))
        self.assertEqual(run.call_args.args[0][2:], ["directory", "选择扫描会话"])

    def test_macos_dialog_uses_native_chooser_without_tkinter(self) -> None:
        with mock.patch.object(
            folder_dialog.subprocess,
            "run",
            return_value=SimpleNamespace(
                returncode=0,
                stdout=str(self.session_a) + "/\n",
                stderr="",
            ),
        ) as run:
            selected = folder_dialog.macos_dialog("directory", "选择扫描会话")
        command = run.call_args.args[0]
        self.assertEqual(command[0], "/usr/bin/osascript")
        self.assertEqual(command[-2:], ["directory", "选择扫描会话"])
        self.assertEqual(selected, str(self.session_a) + "/")

    def test_inspection_exposes_structured_iphone_scan_logs(self) -> None:
        log = self.session_a / "segment_0001" / "scan_events.jsonl"
        events = [
            {
                "format": "SupermarketScanEvent",
                "version": 1,
                "timestamp": "2026-07-18T10:00:00.000Z",
                "timestampUnix": 1.0,
                "level": "info",
                "event": "scan_started",
                "message": "Continuous streaming scan started",
                "trackingSessionId": "test-session",
                "fields": {"workingMemoryNodes": "300"},
            },
            {
                "format": "SupermarketScanEvent",
                "version": 1,
                "timestamp": "2026-07-18T10:00:15.000Z",
                "timestampUnix": 2.0,
                "level": "info",
                "event": "health_checkpoint",
                "message": "Continuous capture health checkpoint",
                "trackingSessionId": "test-session",
                "fields": {"scanStorageBytes": "1048576"},
            },
        ]
        log.write_text("\n".join(json.dumps(event) for event in events) + "\n", encoding="utf-8")

        inspection = self.api("/api/session/inspect", {"session": str(self.session_a)})
        self.assertTrue(inspection["scan_logs"]["available"])
        self.assertEqual(inspection["scan_logs"]["event_count"], 2)
        self.assertEqual(inspection["scan_logs"]["events"][-1]["event"], "health_checkpoint")
        self.assertEqual(inspection["scan_logs"]["malformed_lines"], 0)

    def test_scan_log_reader_keeps_only_the_requested_tail(self) -> None:
        log = self.session_a / "segment_0001" / "scan_events.jsonl"
        events = [
            {
                "timestampUnix": float(index),
                "event": f"event_{index}",
                "message": "bounded log test",
            }
            for index in range(5)
        ]
        log.write_text(
            "\n".join(json.dumps(event) for event in events) + "\nmalformed\n",
            encoding="utf-8",
        )

        result = server.scan_event_logs(self.session_a, limit=2)
        self.assertEqual(result["event_count"], 5)
        self.assertEqual(result["malformed_lines"], 1)
        self.assertTrue(result["truncated"])
        self.assertEqual([event["event"] for event in result["events"]], ["event_3", "event_4"])

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
        self.assertEqual(result["progress"], 100)
        self.assertEqual(result["stage"], "处理完成")
        self.assertTrue(result["logs"])
        self.assertEqual(result["logs"][0]["stage"], "任务已启动")
        self.assertIn("preview.png", result["artifacts"])
        self.assertIn("preview_3d.json", result["artifacts"])
        preview = self.api(result["artifacts"]["preview_3d.json"])
        self.assertEqual(preview["format"], "SupermarketMap3DPreview")
        self.assertEqual(len(preview["segments"][0]["trajectory"]), 2)
        self.assertAlmostEqual(preview["segments"][0]["trajectory"][0][2], 0.0, places=4)
        manifest = self.api(result["artifacts"]["stage_manifest.json"])
        self.assertEqual(manifest["stages"][0]["name"], "anchor")
        self.assertAlmostEqual(manifest["stages"][0]["stage_transform"]["dx"], 0.2, places=4)

        restored = self.api("/api/session/result", {"session": str(self.session_a)})
        self.assertTrue(restored["found"])
        self.assertEqual(restored["job"]["status"], "complete")
        self.assertEqual(Path(restored["job"]["output_dir"]).resolve(), output.resolve())

    def test_continuous_streaming_session_reuses_single_database(self) -> None:
        session = create_session(self.root, "SupermarketSession-Streaming", 0.0, "continuous_streaming")
        inspection = self.api("/api/session/inspect", {"session": str(session)})
        self.assertEqual(inspection["scan_mode"], "continuous_streaming")
        self.assertEqual(inspection["database_count"], 1)
        self.assertFalse(inspection["merge_required"])
        self.assertFalse(inspection["segment_alignment_supported"])
        self.assertEqual(inspection["processing_strategy"], "reuse_continuous_database")
        # Node count comes from the complete SQLite Node table, not the iOS WM
        # count in metadata, which can plateau in streaming mode.
        self.assertEqual(inspection["node_count"], 2)

        output = self.root / "streaming-output"
        job = self.api(
            "/api/jobs",
            {
                "kind": "map",
                "session": str(session),
                "output": str(output),
                "auto_align_segments": True,
                "options": {},
            },
        )
        result = self.wait_for_job(job["id"])
        self.assertEqual(result["status"], "complete", result.get("error"))
        map_metadata = self.api(result["artifacts"]["map.json"])
        self.assertEqual(map_metadata["input_scan"]["scan_mode"], "continuous_streaming")
        self.assertFalse(map_metadata["parameters"]["auto_align_segments"])
        self.assertEqual(result["quality_report"]["input_scan"]["processing_strategy"], "reuse_continuous_database")
        source_manifest = self.api(result["artifacts"]["source_manifest.json"])
        self.assertEqual(source_manifest["input_scan"]["database_count"], 1)

    def test_admin_optimized_poses_override_raw_node_poses(self) -> None:
        database = self.session_a / "segment_0001" / "rtabmap_segment_0001.db"
        add_optimized_poses(
            database,
            {
                1: transform_blob(10.0, 1.1, 0.0),
                2: transform_blob(12.0, 1.5, 1.0),
            },
        )
        config = server.base.MapConfig(0.05, 0.1, 1.25, 1.0, 0.08, 8.0, "xy", False)
        segments = server.base.discover_segments(self.session_a, config)
        self.assertEqual([pose.source for pose in segments[0].poses], ["db_optimized", "db_optimized"])
        self.assertEqual([round(pose.x, 3) for pose in segments[0].poses], [10.0, 12.0])

    def test_pc_offline_reprocess_is_used_for_map_generation(self) -> None:
        session = create_session(self.root, "SupermarketSession-PC", 0.0, "continuous_streaming")
        add_rgbd_frame(session)
        fake_binary = self.root / "rtabmap-reprocess"
        fake_binary.write_text("fake", encoding="utf-8")
        fake_binary.chmod(0o755)

        original_database = session / "segment_0001" / "rtabmap_segment_0001.db"
        original_contents = original_database.read_bytes()

        def fake_run(command: list[str], **kwargs: object) -> SimpleNamespace:
            source = Path(command[-2])
            destination = Path(command[-1])
            strategy_index = command.index("--Optimizer/Strategy")
            self.assertEqual(command[strategy_index + 1], "1")
            solver_index = command.index("--g2o/Solver")
            self.assertEqual(command[solver_index + 1], "3")
            online_iterations = [
                command[index + 1]
                for index, value in enumerate(command[:-1])
                if value == "--Optimizer/Iterations"
            ]
            self.assertEqual(online_iterations[-1], "5")
            final_index = command.index("-final_opt_iterations")
            self.assertEqual(command[final_index + 1], "50")
            self.assertIn("-pub_loops", command)
            self.assertEqual(destination.suffix, ".db")
            self.assertTrue(destination.name.endswith(".partial.db"))
            self.assertNotEqual(source, original_database)
            self.assertEqual(source.parent, Path(str(kwargs["cwd"])))
            environment = kwargs["env"]
            self.assertEqual(environment["OMP_NUM_THREADS"], "3")
            self.assertEqual(environment["OPENCV_FOR_THREADS_NUM"], "3")
            self.assertEqual(environment["OMP_DYNAMIC"], "FALSE")
            shutil.copy2(source, destination)
            add_optimized_poses(
                destination,
                {
                    1: transform_blob(20.0, 1.1, 0.0),
                    2: transform_blob(22.0, 1.5, 1.0),
                },
            )
            return SimpleNamespace(
                returncode=0,
                stdout=(
                    "Processed 2/2 nodes [id=2 map=0 graph=2 hyp=0]... 4ms\n"
                    "FINAL_OPTIMIZATION_DONE poses=2 constraints=1 iterations_done=3 error=0.1 seconds=0.01"
                ),
                stderr="",
            )

        output = self.root / "pc-output"
        with mock.patch.object(server.offline.subprocess, "run", side_effect=fake_run):
            job = self.api(
                "/api/jobs",
                {
                    "kind": "map",
                    "session": str(session),
                    "output": str(output),
                    "options": {
                        "offline_optimize": True,
                        "reprocess_binary": str(fake_binary),
                        "pc_threads": 3,
                        "pc_local_staging": True,
                        "gpu_backend": "cpu",
                    },
                },
            )
            result = self.wait_for_job(job["id"])
        self.assertEqual(result["status"], "complete", result.get("error"))
        self.assertIn("offline_processing_report.json", result["artifacts"])
        report = self.api(result["artifacts"]["offline_processing_report.json"])
        self.assertEqual(report["databases"][0]["output"]["optimized_pose_count"], 2)
        self.assertEqual(report["databases"][0]["execution"]["thread_count"], 3)
        self.assertTrue(report["databases"][0]["execution"]["local_staging"])
        map_metadata = self.api(result["artifacts"]["map.json"])
        self.assertTrue(map_metadata["pc_offline_processing"]["enabled"])
        self.assertFalse(map_metadata["pc_offline_processing"]["fiducials_used"])
        self.assertEqual(
            map_metadata["pc_offline_processing"]["error_optimization"]["status"],
            "pass",
        )
        self.assertEqual(map_metadata["pc_offline_processing"]["execution"]["thread_count"], 3)
        self.assertEqual(original_database.read_bytes(), original_contents)

    def test_software_error_profile_disables_fiducials_and_priors(self) -> None:
        parameters = dict(server.offline.REPROCESS_PARAMETERS)
        self.assertEqual(parameters["RGBD/MarkerDetection"], "false")
        self.assertEqual(parameters["Optimizer/LandmarksIgnored"], "true")
        self.assertEqual(parameters["Optimizer/PriorsIgnored"], "true")
        self.assertEqual(parameters["Mem/UseOdomGravity"], "true")
        self.assertEqual(parameters["Optimizer/Robust"], "true")

    def test_map_studio_defaults_to_bounded_maximum_preview_quality(self) -> None:
        options = server.map_options({"options": {}})
        profile = server.base.PREVIEW_3D_PROFILES[options["preview_3d_quality"]]
        self.assertEqual(options["preview_3d_quality"], "maximum")
        self.assertEqual(profile["max_frames"], 384)
        self.assertEqual(profile["max_points"], 1_000_000)

    def test_pc_execution_options_are_bounded_and_default_to_local_staging(self) -> None:
        options = server.map_options({"options": {}})
        self.assertEqual(options["pc_threads"], server.offline.DEFAULT_PC_THREADS)
        self.assertTrue(options["pc_local_staging"])
        with self.assertRaisesRegex(server.RequestError, "between 1 and 64"):
            server.map_options({"options": {"pc_threads": 0}})
        with self.assertRaisesRegex(server.RequestError, "must be an integer"):
            server.map_options({"options": {"pc_threads": "four"}})
        self.assertEqual(options["gpu_backend"], "auto")
        with self.assertRaisesRegex(server.RequestError, "GPU backend"):
            server.map_options({"options": {"gpu_backend": "magic_gpu"}})

    def test_nvidia_profile_preserves_feature_family_and_enables_cuda_paths(self) -> None:
        parameters = dict(server.gpu.nvidia_rtabmap_parameters())
        self.assertEqual(parameters["Kp/DetectorStrategy"], "6")
        self.assertEqual(parameters["Vis/FeatureType"], "6")
        self.assertEqual(parameters["GFTT/Gpu"], "true")
        self.assertEqual(parameters["Kp/NNStrategy"], "4")
        command = server.offline._command(
            Path("/tmp/rtabmap-reprocess"),
            Path("/tmp/input.db"),
            Path("/tmp/output.db"),
            server.gpu.nvidia_rtabmap_parameters(),
        )
        self.assertEqual(command[command.index("--GFTT/Gpu") + 1], "true")

    def test_depth_cloud_uses_injected_gpu_projector(self) -> None:
        add_rgbd_frame(self.session_a)

        class FakeProjector:
            backend = "apple_metal"

            def __init__(self) -> None:
                self.calls = 0

            def project(self, **kwargs: object) -> list[tuple[float, float, float, float]]:
                self.calls += 1
                width = int(kwargs["width"])
                height = int(kwargs["height"])
                step = int(kwargs["step"])
                count = ((width + step - 1) // step) * ((height + step - 1) // step)
                return [(42.0, 24.0, 1.5, 1.0)] * count

        projector = FakeProjector()
        config = server.base.MapConfig(0.05, 0.1, 1.25, 1.0, 0.08, 8.0, "xz", False)
        segments = server.base.discover_segments(self.session_a, config)
        cloud = server.base.extract_depth_point_cloud(
            segments,
            "xz",
            max_frames=1,
            pixel_step=3,
            max_points=100,
            depth_projector=projector,
        )
        self.assertEqual(projector.calls, 1)
        self.assertEqual(cloud["gpu_projection_backend"], "apple_metal")
        self.assertEqual(cloud["gpu_projected_frames"], 1)
        self.assertEqual(cloud["points"][0][:3], [42.0, 24.0, 1.5])

    def test_gpu_capability_api_has_both_platform_backends(self) -> None:
        payload = self.api("/api/gpu/capabilities")
        self.assertIn("apple_metal", payload["backends"])
        self.assertIn("nvidia_cuda", payload["backends"])
        self.assertTrue(payload["backends"]["cpu"]["available"])

    def test_gpu_probe_rejects_helper_for_the_wrong_backend(self) -> None:
        helper = self.root / "wrong-gpu-helper"
        helper.write_text(
            "#!/bin/sh\nprintf '%s\\n' '{\"available\":true,\"backend\":\"apple_metal\",\"protocol\":1}'\n",
            encoding="utf-8",
        )
        helper.chmod(0o755)
        result = server.gpu.probe_backend("nvidia_cuda", str(helper))
        self.assertFalse(result["available"])
        self.assertIn("does not match", result["reason"])

    def test_acceleration_report_exposes_rtabmap_cuda_fallback(self) -> None:
        output = self.root / "acceleration-report"
        output.mkdir()
        for name in ("map.json", "quality_report.json"):
            (output / name).write_text("{}", encoding="utf-8")
        report = {"effective_backend": "nvidia_cuda", "warnings": []}
        server.attach_acceleration_report(
            output,
            report,
            [{"execution": {"rtabmap_gpu_fallback_detected": True}}],
        )
        stored = json.loads((output / "pc_acceleration_report.json").read_text(encoding="utf-8"))
        self.assertTrue(stored["rtabmap_gpu_fallback_detected"])
        self.assertTrue(any("fell back to CPU" in warning for warning in stored["warnings"]))
        quality = json.loads((output / "quality_report.json").read_text(encoding="utf-8"))
        self.assertTrue(quality["pc_acceleration"]["rtabmap_gpu_fallback_detected"])

    def test_map_job_reports_effective_gpu_projection_backend(self) -> None:
        add_rgbd_frame(self.session_a)
        capabilities = self.api("/api/gpu/capabilities")
        output = self.root / "gpu-map-output"
        job = self.api(
            "/api/jobs",
            {
                "kind": "map",
                "session": str(self.session_a),
                "output": str(output),
                "options": {"gpu_backend": "auto"},
            },
        )
        result = self.wait_for_job(job["id"])
        self.assertEqual(result["status"], "complete", result.get("error"))
        self.assertIn("pc_acceleration_report.json", result["artifacts"])
        report = self.api(result["artifacts"]["pc_acceleration_report.json"])
        if capabilities["backends"]["apple_metal"]["available"]:
            self.assertEqual(report["effective_backend"], "apple_metal")
            self.assertEqual(report["projection_backend"], "apple_metal")
            self.assertGreater(report["projected_frames"], 0)
            self.assertFalse(report["runtime_failures"])

    def test_map_studio_exposes_large_and_fullscreen_preview_controls(self) -> None:
        html, html_type = self.fetch("/")
        css, css_type = self.fetch("/app.css")
        self.assertIn("text/html", html_type)
        self.assertIn("text/css", css_type)
        self.assertIn(b'id="preview-fullscreen"', html)
        self.assertIn(b'id="option-pc-threads"', html)
        self.assertIn(b'id="option-pc-local-staging"', html)
        self.assertIn(b'id="option-gpu-backend"', html)
        self.assertIn(b'id="gpu-capability"', html)
        self.assertIn(b'<option value="maximum" selected>', html)
        self.assertIn(b"max-width: 1920px", css)
        self.assertIn(b".preview-panel:fullscreen", css)

    def test_unsafe_optimized_pose_jump_is_rejected_before_publication(self) -> None:
        session = create_session(self.root, "SupermarketSession-UnsafeOptimization", 0.0, "continuous_streaming")
        add_rgbd_frame(session)
        source = session / "segment_0001" / "rtabmap_segment_0001.db"
        output = self.root / "unsafe-optimized.db"
        fake_binary = self.root / "rtabmap-reprocess-unsafe"
        fake_binary.write_text("fake", encoding="utf-8")
        fake_binary.chmod(0o755)

        def fake_run(command: list[str], **_kwargs: object) -> SimpleNamespace:
            destination = Path(command[-1])
            shutil.copy2(source, destination)
            add_optimized_poses(
                destination,
                {
                    1: transform_blob(0.0, 1.1, 0.0),
                    2: transform_blob(20.0, 1.5, 1.0),
                },
            )
            return SimpleNamespace(
                returncode=0,
                stdout="FINAL_OPTIMIZATION_DONE poses=2 constraints=1 iterations_done=3 error=0.1 seconds=0.01",
                stderr="",
            )

        with mock.patch.object(server.offline.subprocess, "run", side_effect=fake_run):
            with self.assertRaisesRegex(server.offline.OfflineProcessingError, "failed software error validation"):
                server.offline.run_reprocess(source, output, explicit_binary=str(fake_binary))
        self.assertFalse(output.exists())

    def test_adaptive_reprocess_discovers_loops_only_for_weak_graph(self) -> None:
        fast = {
            "elapsed_seconds": 10.0,
            "execution": {"profile": server.offline.FAST_REUSE_PROFILE},
            "runtime": {"processed_node_count": 1000, "node_time_ms": {}, "final_optimization": {}},
            "output": {"node_count": 1000, "loop_closure_pair_count": 1, "long_range_loop_pair_count": 1},
            "error_optimization": {
                "status": "warning",
                "quality_score": 85,
                "constraints": {"input_long_range_loop_retention": 1.0},
            },
        }
        discovered = {
            "elapsed_seconds": 40.0,
            "execution": {"profile": server.offline.DISCOVERY_PROFILE},
            "runtime": {"processed_node_count": 1000, "node_time_ms": {}, "final_optimization": {}},
            "output": {"node_count": 1000, "loop_closure_pair_count": 20, "long_range_loop_pair_count": 8},
            "error_optimization": {"status": "pass", "quality_score": 100, "constraints": {}},
        }
        with mock.patch.object(server.offline, "run_reprocess", side_effect=[fast, discovered]) as run:
            result = server.offline.run_adaptive_reprocess(Path("input.db"), Path("output.db"))
        self.assertEqual(run.call_count, 2)
        self.assertTrue(result["adaptive"]["discovery_required"])
        self.assertEqual(result["adaptive"]["selected_pass"], server.offline.DISCOVERY_PROFILE)
        self.assertEqual(result["execution"]["profile"], server.offline.ADAPTIVE_PROFILE)

    def test_adaptive_reprocess_keeps_fast_result_when_graph_is_well_constrained(self) -> None:
        fast = {
            "elapsed_seconds": 10.0,
            "execution": {"profile": server.offline.FAST_REUSE_PROFILE},
            "runtime": {"processed_node_count": 1000, "node_time_ms": {}, "final_optimization": {}},
            "output": {"node_count": 1000, "loop_closure_pair_count": 12, "long_range_loop_pair_count": 6},
            "error_optimization": {
                "status": "pass",
                "quality_score": 100,
                "constraints": {"input_long_range_loop_retention": 1.0},
            },
        }
        with mock.patch.object(server.offline, "run_reprocess", return_value=fast) as run:
            result = server.offline.run_adaptive_reprocess(Path("input.db"), Path("output.db"))
        self.assertEqual(run.call_count, 1)
        self.assertFalse(result["adaptive"]["discovery_required"])
        self.assertEqual(result["adaptive"]["selected_pass"], server.offline.FAST_REUSE_PROFILE)

    def test_large_trajectory_without_loop_closure_requires_review(self) -> None:
        source = self.root / "large-source.db"
        optimized = self.root / "large-optimized.db"
        transforms = {
            node_id: transform_blob(node_id * 0.05, 0.0, 0.0)
            for node_id in range(1, 51)
        }
        with closing(sqlite3.connect(source)) as conn, conn:
            conn.execute("CREATE TABLE Node (id INTEGER PRIMARY KEY, pose BLOB, stamp REAL)")
            conn.executemany(
                "INSERT INTO Node VALUES (?, ?, ?)",
                ((node_id, pose, float(node_id)) for node_id, pose in transforms.items()),
            )
        shutil.copy2(source, optimized)
        with closing(sqlite3.connect(optimized)) as conn, conn:
            conn.execute('CREATE TABLE Link (from_id INTEGER, to_id INTEGER, type INTEGER)')
            conn.executemany(
                'INSERT INTO Link VALUES (?, ?, 0)',
                ((node_id, node_id + 1) for node_id in range(1, 50)),
            )
        add_optimized_poses(optimized, transforms)

        assessment = server.offline.assess_optimized_trajectory(source, optimized)
        self.assertEqual(assessment["status"], "warning")
        self.assertEqual(assessment["constraints"]["loop_closure_count"], 0)
        self.assertTrue(any("accumulated drift" in warning for warning in assessment["warnings"]))

    def test_pc_reprocess_rejects_optimizer_fallback(self) -> None:
        session = create_session(self.root, "SupermarketSession-Fallback", 0.0, "continuous_streaming")
        add_rgbd_frame(session)
        database = session / "segment_0001" / "rtabmap_segment_0001.db"
        fake_binary = self.root / "rtabmap-reprocess"
        fake_binary.write_text("fake", encoding="utf-8")
        fake_binary.chmod(0o755)
        output = self.root / "fallback-output.db"

        def fake_run(command: list[str], **_kwargs: object) -> SimpleNamespace:
            destination = Path(command[-1])
            shutil.copy2(database, destination)
            add_optimized_poses(
                destination,
                {
                    1: transform_blob(0.0, 1.1, 0.0),
                    2: transform_blob(2.0, 1.5, 1.0),
                },
            )
            return SimpleNamespace(
                returncode=0,
                stdout="g2o optimizer not available. TORO will be used instead.",
                stderr="",
            )

        with mock.patch.object(server.offline.subprocess, "run", side_effect=fake_run):
            with self.assertRaisesRegex(server.offline.OfflineProcessingError, "g2o/Vertigo"):
                server.offline.run_reprocess(database, output, explicit_binary=str(fake_binary))
        self.assertFalse(output.exists())
        self.assertFalse((self.root / "fallback-output.partial.db").exists())

    def test_pc_reprocess_failure_removes_empty_output_and_disk_log(self) -> None:
        session = create_session(self.root, "SupermarketSession-ProcessFailure", 0.0, "continuous_streaming")
        add_rgbd_frame(session)
        database = session / "segment_0001" / "rtabmap_segment_0001.db"
        fake_binary = self.root / "rtabmap-reprocess-failure"
        fake_binary.write_text("fake", encoding="utf-8")
        fake_binary.chmod(0o755)
        output = self.root / "new-output" / "optimized.db"

        with mock.patch.object(
            server.offline.subprocess,
            "run",
            return_value=SimpleNamespace(returncode=7, stdout="synthetic failure", stderr=""),
        ):
            with self.assertRaisesRegex(server.offline.OfflineProcessingError, "exit code 7"):
                server.offline.run_reprocess(
                    database,
                    output,
                    explicit_binary=str(fake_binary),
                    use_local_staging=False,
                )
        self.assertFalse(output.parent.exists())

    def test_pc_reprocess_never_overwrites_phone_capture(self) -> None:
        session = create_session(self.root, "SupermarketSession-Immutable", 0.0, "continuous_streaming")
        add_rgbd_frame(session)
        database = session / "segment_0001" / "rtabmap_segment_0001.db"
        original = database.read_bytes()
        fake_binary = self.root / "rtabmap-reprocess"
        fake_binary.write_text("fake", encoding="utf-8")
        fake_binary.chmod(0o755)

        with self.assertRaisesRegex(server.offline.OfflineProcessingError, "immutable input"):
            server.offline.run_reprocess(
                database,
                database,
                explicit_binary=str(fake_binary),
            )
        self.assertEqual(database.read_bytes(), original)

    def test_pc_reprocess_rejects_live_phone_database(self) -> None:
        session = create_session(self.root, "SupermarketSession-Live", 0.0, "continuous_streaming")
        add_rgbd_frame(session)
        (session / "segment_0001" / "live_checkpoint.json").write_text(
            json.dumps({"format": "SupermarketLiveCheckpoint", "finalized": False}),
            encoding="utf-8",
        )
        output = self.root / "live-output"
        job = self.api(
            "/api/jobs",
            {
                "kind": "map",
                "session": str(session),
                "output": str(output),
                "options": {"offline_optimize": True},
            },
        )
        result = self.wait_for_job(job["id"])
        self.assertEqual(result["status"], "failed")
        self.assertIn("live_checkpoint.json", result["error"])

    def test_multi_device_pc_reprocess_optimizes_each_phone_database(self) -> None:
        for session in (self.session_a, self.session_b):
            metadata_path = session / "segment_0001" / "metadata.json"
            metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
            metadata.update({"scanMode": "continuous_streaming", "finalized": True})
            metadata_path.write_text(json.dumps(metadata), encoding="utf-8")
            add_rgbd_frame(session)
        fake_binary = self.root / "rtabmap-reprocess"
        fake_binary.write_text("fake", encoding="utf-8")
        fake_binary.chmod(0o755)

        def fake_run(command: list[str], **_kwargs: object) -> SimpleNamespace:
            source = Path(command[-2])
            destination = Path(command[-1])
            shutil.copy2(source, destination)
            with closing(sqlite3.connect(source)) as conn:
                raw = {
                    int(node_id): bytes(pose)
                    for node_id, pose in conn.execute("SELECT id, pose FROM Node WHERE id>0")
                }
            add_optimized_poses(destination, raw)
            return SimpleNamespace(
                returncode=0,
                stdout="FINAL_OPTIMIZATION_DONE poses=2 constraints=1 iterations_done=3 error=0.1 seconds=0.01",
                stderr="",
            )

        output = self.root / "multi-pc-output"
        with mock.patch.object(server.offline.subprocess, "run", side_effect=fake_run):
            job = self.api(
                "/api/jobs",
                {
                    "kind": "multi",
                    "output": str(output),
                    "devices": [
                        {"id": "phone_a", "session": str(self.session_a)},
                        {"id": "phone_b", "session": str(self.session_b)},
                    ],
                    "options": {
                        "offline_optimize": True,
                        "reprocess_binary": str(fake_binary),
                        "gpu_backend": "cpu",
                    },
                },
            )
            result = self.wait_for_job(job["id"])
        self.assertEqual(result["status"], "complete", result.get("error"))
        report = self.api(result["artifacts"]["offline_processing_report.json"])
        self.assertEqual(len(report["databases"]), 2)
        self.assertEqual({entry["device_id"] for entry in report["databases"]}, {"phone_a", "phone_b"})
        self.assertTrue(all(entry["output"]["optimized_pose_count"] == 2 for entry in report["databases"]))

    def test_streaming_marker_cannot_be_mixed_with_legacy_segments(self) -> None:
        session = create_session(self.root, "SupermarketSession-Mixed", 0.0, "continuous_streaming")
        duplicate = session / "segment_0002"
        duplicate.mkdir()
        (duplicate / "metadata.json").write_text(
            json.dumps({"segmentIndex": 2, "scanMode": "segmented", "finalized": True}),
            encoding="utf-8",
        )
        config = server.base.MapConfig(0.05, 0.1, 1.25, 1.0, 0.08, 8.0, "xz", False)
        with self.assertRaisesRegex(ValueError, "continuous_streaming"):
            server.base.discover_segments(session, config)

    def test_multi_device_job_creates_merge_manifest(self) -> None:
        metadata_path = self.session_a / "segment_0001" / "metadata.json"
        metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
        metadata.update({"scanMode": "continuous_streaming", "finalized": True})
        metadata_path.write_text(json.dumps(metadata), encoding="utf-8")
        add_rgbd_frame(self.session_a)
        add_rgbd_frame(self.session_b)
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
        self.assertEqual(manifest["devices"][0]["input_scan"]["scan_mode"], "continuous_streaming")
        self.assertEqual(manifest["devices"][1]["input_scan"]["scan_mode"], "legacy_single_database")
        preview = self.api(result["artifacts"]["preview_3d.json"])
        self.assertEqual(preview["point_cloud"]["surface_frame_count"], 2)
        alignment_warnings = result["quality_report"]["multi_device_summary"]["alignment_warnings"]
        self.assertFalse(any(warning.get("type") == "map" for warning in alignment_warnings))

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
        with closing(sqlite3.connect(database)) as conn, conn:
            conn.execute("CREATE TABLE Data (id INTEGER PRIMARY KEY, depth BLOB, calibration BLOB, image BLOB)")
            conn.execute(
                "INSERT INTO Data VALUES (?, ?, ?, ?)",
                (1, depth_png(2, 2, [1.0, 1.02, 1.03, 1.04]), calibration_blob(2, 2), b"\xff\xd8test"),
            )
        config = server.base.MapConfig(0.05, 0.1, 1.25, 1.0, 0.1, 8.0, "xz", False)
        segments = server.base.discover_segments(self.session_a, config)
        preview = server.base.extract_depth_point_cloud(
            segments,
            "xz",
            max_frames=1,
            pixel_step=1,
            max_depth=5.0,
            frame_output_dir=self.root / "frames",
        )
        self.assertEqual(preview["decoded_frames"], 1)
        self.assertEqual(preview["point_count"], 4)
        self.assertEqual(preview["surface_frame_count"], 1)
        self.assertGreater(preview["surface_triangle_count"], 0)
        projected = server.base.projected_depth_surface_points(
            {
                "points": [
                    [0.0, 0.0, 0.0, 0, 0, 0, 1],
                    [0.0, 0.0, 1.0, 0, 0, 0, 1],
                    [0.1, 0.0, 1.2, 0, 0, 0, 1],
                ]
            },
            0.05,
        )
        self.assertTrue(projected)
        self.assertEqual(projected[0].kind, "depth_surface")
        self.assertEqual(
            [round(value, 3) for value in server.base.decode_depth_image(depth_png(2, 2, [1.0, 1.02, 1.03, 1.04]))[2]],
            [1.0, 1.02, 1.03, 1.04],
        )

        database_without_image = self.session_b / "segment_0001" / "rtabmap_segment_0001.db"
        with closing(sqlite3.connect(database_without_image)) as conn, conn:
            conn.execute("CREATE TABLE Data (id INTEGER PRIMARY KEY, depth BLOB, calibration BLOB)")
            conn.execute(
                "INSERT INTO Data VALUES (?, ?, ?)",
                (1, depth_png(2, 2, [1.0, 1.02, 1.03, 1.04]), calibration_blob(2, 2)),
            )
        legacy_segments = server.base.discover_segments(self.session_b, config)
        legacy_preview = server.base.extract_depth_point_cloud(
            legacy_segments, "xz", max_frames=1, pixel_step=1, max_depth=5.0
        )
        self.assertEqual(legacy_preview["decoded_frames"], 1)
        self.assertEqual(legacy_preview["surface_frame_count"], 0)

    def test_nested_preview_frame_artifact_is_served_from_job_output(self) -> None:
        output = self.root / "surface-output"
        frames = output / "preview_frames"
        frames.mkdir(parents=True)
        image = b"\xff\xd8surface-frame"
        (frames / "node.jpg").write_bytes(image)
        job = server.STATE.add("map", output)
        server.STATE.set_status(job.identifier, "complete")

        content, content_type = self.fetch(f"/api/jobs/{job.identifier}/artifact/preview_frames/node.jpg")
        self.assertEqual(content, image)
        self.assertEqual(content_type, "image/jpeg")

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

    def test_duplicate_pc_optimization_for_same_session_is_rejected(self) -> None:
        state = server.StudioState()
        first = state.add("map", self.root / "first-output", (str(self.session_a),))
        with self.assertRaisesRegex(server.RequestError, "already being optimized"):
            state.add("map", self.root / "second-output", (str(self.session_a),))
        self.assertEqual(state.active_for_input(str(self.session_a)), first)
        state.set_status(first.identifier, "complete")
        second = state.add("map", self.root / "second-output", (str(self.session_a),))
        self.assertNotEqual(first.identifier, second.identifier)


if __name__ == "__main__":
    unittest.main()
