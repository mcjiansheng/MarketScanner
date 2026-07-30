from __future__ import annotations

import json
import hashlib
import math
import os
import shutil
import sqlite3
import stat
import struct
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import zlib
import zipfile
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


def immediate_popen(callback):
    """Adapt an existing completed-process fixture to the cancellable Popen path."""
    class ImmediatePopen:
        def __init__(self, command: list[str], **kwargs: object) -> None:
            result = callback(command, **kwargs)
            self.returncode = int(result.returncode)
            output = kwargs.get("stdout")
            if output is not None and result.stdout:
                output.write(result.stdout)
                output.flush()

        def poll(self) -> int:
            return self.returncode

        def terminate(self) -> None:
            self.returncode = -15

        def kill(self) -> None:
            self.returncode = -9

        def wait(self, timeout: float | None = None) -> int:
            del timeout
            return self.returncode

    return ImmediatePopen


def create_localized_store(
    output: Path,
    revision: int = 1,
    *,
    source_manifest: dict | None = None,
    journal: dict | None = None,
    report: dict | None = None,
):
    store = server.LocalizedVersionStore(output)
    report_payload = {
        "publish_state": "draft",
        "publish_gate": {
            "passed": False,
            "blockers": [{"code": "solver_not_full_relative_se2_factor_graph"}],
        },
        "solver": {
            "type": "bounded_correction_field",
            "full_factor_graph": False,
            "published_capable": False,
        },
        **(report or {}),
    }
    solver_payload = dict(report_payload.get("solver") or {})
    report_payload["solver"] = solver_payload
    full_factor_graph = (
        isinstance(solver_payload, dict)
        and solver_payload.get("type") == "relative_se2_factor_graph"
        and solver_payload.get("full_factor_graph") is True
        and solver_payload.get("published_capable") is True
    )
    if full_factor_graph:
        solver_payload.setdefault("factor_set_sha256", "d" * 64)
        solver_payload.setdefault("graph_quality_passed", True)
    previous = store.current()
    staging = store.begin()
    source_manifest = dict(source_manifest or {})
    replay_parameters = server.localized.normalize_replay_parameters()
    processing_hash = server.localized.processing_parameter_sha256(replay_parameters)
    source_hash = str(source_manifest.get("source_database_sha256_before") or "b" * 64)
    optimized_path = Path(source_manifest.get("optimized_database") or output)
    optimized_hash = (
        server.localized._sha256(optimized_path)
        if optimized_path.is_file()
        else str(source_manifest.get("optimized_database_sha256") or "c" * 64)
    )
    prior_hash = str((journal or {}).get("prior_map_sha256") or "a" * 64)
    session_files = [
        {
            "role": role,
            "file": file_name,
            "bytes": 0,
            "sha256": source_hash if role == "source_database" else "f" * 64,
        }
        for role, file_name in (
            ("metadata", "metadata.json"),
            ("source_database", "source.db"),
            ("localization_trace.jsonl", "localization_trace.jsonl"),
            ("localization_constraints.jsonl", "localization_constraints.jsonl"),
            ("localization_events.jsonl", "localization_events.jsonl"),
            ("manual_localization_events.jsonl", "manual_localization_events.jsonl"),
            ("tag_observations.jsonl", "tag_observations.jsonl"),
            ("localized_price_tags.json", "localized_price_tags.json"),
        )
    ]
    bundle_body = {
        "format": "MarketScannerLocalizedInputManifest",
        "version": 1,
        "source_database_sha256": source_hash,
        "files": session_files,
    }
    bundle_hash = hashlib.sha256(
        json.dumps(bundle_body, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()
    identities = {
        "session_input_bundle_sha256": bundle_hash,
        "source_database_sha256": source_hash,
        "optimized_database_sha256": optimized_hash,
        "prior_map_sha256": prior_hash,
        "processing_parameter_sha256": processing_hash,
    }
    local_record = {
        "format": "MarketScannerLocalizedLocalInputs",
        "version": 1,
        "paths": {
            "prior_map": str(source_manifest.get("prior_map") or output),
            "source_session": str(source_manifest.get("source_session") or output),
            "source_database": str(source_manifest.get("source_database") or output),
            "optimized_database": str(source_manifest.get("optimized_database") or output),
        },
        "identities": identities,
    }
    local_record["input_identity_id"] = hashlib.sha256(
        json.dumps(local_record, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()
    input_identity_id = local_record["input_identity_id"]
    payloads = {
        "prior_map_manifest.json": {
            "format": "MarketScannerPriorMap", "version": 1
        },
        "source_manifest.json": {
            "format": "MarketScannerLocalizedSourceManifest", "version": 2,
            **source_manifest,
            "input_identity_id": input_identity_id,
            "session_input_bundle_sha256": bundle_hash,
            "source_database_sha256_before": source_hash,
            "optimized_database_sha256": optimized_hash,
            "prior_map_sha256": prior_hash,
            "prior_map_id": "prior-test",
        },
        "processing_manifest.json": {
            "format": "MarketScannerLocalizedProcessing", "version": 2,
            "publish_state": report_payload["publish_state"],
            "input_identity_id": input_identity_id,
            **identities,
            "factor_graph_quality_policy_sha256": "e" * 64,
            "factor_graph_quality_policy_version": "test-frozen-1",
            "replay_parameters": replay_parameters,
        },
        "session_input_manifest.json": {
            **bundle_body,
            "bundle_sha256": bundle_hash,
            "input_identity_id": input_identity_id,
        },
        "online_localization_trace.json": [],
        "optimized_map_trajectory.geojson": {"type": "FeatureCollection", "features": []},
        "localization_constraints.json": {
            "format": "MarketScannerOfflineLocalizationConstraints", "version": 1,
            "raw": [],
        },
        "localization_report.json": {
            "format": "MarketScannerLocalizationReport", "version": 1,
            **report_payload,
        },
        "factor_graph_report.json": {
            "format": "MarketScannerRelativeSE2FactorGraphReport",
            "version": 2,
            "solver": (
                "rtabmap_g2o_slam2d" if full_factor_graph else "unavailable"
            ),
            "full_factor_graph": full_factor_graph,
            "published_capable": full_factor_graph,
            "converged": full_factor_graph,
            "solver_converged": full_factor_graph,
            "graph_integrity_passed": full_factor_graph,
            "graph_quality_passed": full_factor_graph,
            "quality_policy": ({
                "policy_sha256": "e" * 64,
                "policy_version": "test-frozen-1",
                "policy_status": "frozen",
                "passed": True,
                "blockers": [],
            } if full_factor_graph else None),
            "input_identity_id": input_identity_id,
            "optimized_database_sha256": optimized_hash,
            **(
                {"factor_set_sha256": solver_payload["factor_set_sha256"]}
                if full_factor_graph
                else {}
            ),
        },
        "review_items.json": {
            "format": "MarketScannerLocalizationReviewItems", "version": 1,
            "items": [],
        },
        "localized_review.json": {
            "format": "MarketScannerLocalizedReview", "version": 1,
        },
        "manual_edits.json": {
            "format": "MarketScannerManualEdits", "version": 4,
            **(journal or {"revision": revision, "events": [], "cursor": 0}),
            "input_identity_id": input_identity_id,
            **identities,
        },
        "localized_price_tags.json": [],
        "localized_price_tags.geojson": {"type": "FeatureCollection", "features": []},
        "shelf_tag_index.json": {
            "format": "MarketScannerShelfTagIndex", "version": 1,
            "shelves": {},
        },
    }
    for name, payload in payloads.items():
        (staging / name).write_text(json.dumps(payload) + "\n", encoding="utf-8")
    (staging / "localized_price_tags.csv").write_text(
        "tag_id,approval_status\n", encoding="utf-8"
    )
    (staging / "audit_log.jsonl").write_text("{}\n", encoding="utf-8")
    manifest = store.validate_staging(
        staging, parent_version=previous.version_id if previous else None
    )
    return store.commit(
        staging,
        manifest,
        update_current=True,
        local_input_record=local_record,
    )


def transform_blob(x: float, y: float, z: float) -> bytes:
    return struct.pack("<12f", 1.0, 0.0, 0.0, x, 0.0, 1.0, 0.0, y, 0.0, 0.0, 1.0, z)


def transform_yaw_blob(x: float, y: float, z: float, yaw_degrees: float) -> bytes:
    yaw = yaw_degrees * 3.141592653589793 / 180.0
    cosine = math.cos(yaw)
    sine = math.sin(yaw)
    return struct.pack(
        "<12f",
        cosine,
        -sine,
        0.0,
        x,
        sine,
        cosine,
        0.0,
        y,
        0.0,
        0.0,
        1.0,
        z,
    )


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


def create_prior_map_workbook(path: Path) -> None:
    elements = [
        {
            "shapeType": "MapShelf",
            "x": 100,
            "y": 200,
            "width": 300,
            "height": 100,
            "rotation": 90,
            "code": "Shelf-A",
            "crossCode": "Cross-A",
            "rowFlag": "Row-A",
            "visible": True,
        },
        {
            "shapeType": "MapCross",
            "points": [0, 500, 1000, 500],
            "lineWidth": 200,
            "code": "Cross-A",
            "visible": True,
        },
        {
            "shapeType": "MapRoadPoint",
            "x": 100,
            "y": 500,
            "code": "Road-1",
            "crossCodes": ["Cross-A"],
            "visible": True,
        },
        {
            "shapeType": "MapRoadPoint",
            "x": 900,
            "y": 500,
            "code": "Road-2",
            "crossCodes": ["Cross-A"],
            "visible": True,
        },
    ]
    strings = ["floor", "element"]
    for element in elements:
        strings.extend(("1", json.dumps(element)))
    shared = "".join(
        f"<si><t>{value.replace('&', '&amp;').replace('<', '&lt;')}</t></si>"
        for value in strings
    )
    rows = [
        '<row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c></row>'
    ]
    for row_index in range(2, len(elements) + 2):
        string_index = 2 + (row_index - 2) * 2
        rows.append(
            f'<row r="{row_index}"><c r="A{row_index}" t="s"><v>{string_index}</v></c>'
            f'<c r="B{row_index}" t="s"><v>{string_index + 1}</v></c></row>'
        )
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as archive:
        archive.writestr(
            "[Content_Types].xml",
            '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
            '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
            '<Default Extension="xml" ContentType="application/xml"/>'
            '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
            '<Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>'
            '<Override PartName="/xl/sharedStrings.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"/>'
            "</Types>",
        )
        archive.writestr(
            "_rels/.rels",
            '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
            '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>'
            "</Relationships>",
        )
        archive.writestr(
            "xl/workbook.xml",
            '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" '
            'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
            '<sheets><sheet name="Element Info" sheetId="1" r:id="rId1"/></sheets></workbook>',
        )
        archive.writestr(
            "xl/_rels/workbook.xml.rels",
            '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
            '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>'
            "</Relationships>",
        )
        archive.writestr(
            "xl/sharedStrings.xml",
            f'<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="{len(strings)}" uniqueCount="{len(strings)}">{shared}</sst>',
        )
        archive.writestr(
            "xl/worksheets/sheet1.xml",
            '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
            f"<sheetData>{''.join(rows)}</sheetData></worksheet>",
        )


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


def create_manual_merge_result(root: Path) -> tuple[Path, Path, Path]:
    session = create_session(
        root,
        "SupermarketSession-ManualMerge",
        0.0,
        "continuous_streaming",
    )
    database = session / "segment_0001" / "rtabmap_segment_0001.db"
    transforms: dict[int, bytes] = {}
    with closing(sqlite3.connect(database)) as conn, conn:
        conn.execute("DELETE FROM Node")
        for index in range(6):
            target_id = index + 1
            source_id = index + 101
            target = transform_blob(float(index), 0.0, 0.0)
            source = transform_blob(float(index + 10), 0.0, 0.0)
            transforms[target_id] = target
            transforms[source_id] = source
            conn.execute(
                "INSERT INTO Node VALUES (?, ?, ?)",
                (target_id, target, float(target_id)),
            )
            conn.execute(
                "INSERT INTO Node VALUES (?, ?, ?)",
                (source_id, source, float(source_id)),
            )
        conn.execute(
            "CREATE TABLE Link ("
            "from_id INTEGER NOT NULL, to_id INTEGER NOT NULL, type INTEGER NOT NULL, "
            "information_matrix BLOB NOT NULL, transform BLOB, user_data BLOB)"
        )
    add_optimized_poses(database, transforms)
    add_rgbd_frame(session)

    output = session / "MapStudio-ManualBase"
    output.mkdir()
    (output / "map.json").write_text(
        json.dumps(
            {
                "format": "SupermarketMap2D",
                "session": str(session),
                "parameters": {
                    "resolution": 0.1,
                    "horizontal_axes": "xy",
                },
            }
        ),
        encoding="utf-8",
    )
    (output / "preview_layers.json").write_text(
        json.dumps(
            {
                "format": "SupermarketPreviewLayers",
                "version": 4,
                "width": 220,
                "height": 100,
                "resolution_m": 0.1,
                "origin": [-2.0, -2.0],
                "layers": [],
            }
        ),
        encoding="utf-8",
    )
    (output / "offline_processing_report.json").write_text(
        json.dumps(
            {
                "format": "SupermarketOfflineProcessingBundle",
                "version": 1,
                "databases": [{"output": {"path": str(database)}}],
            }
        ),
        encoding="utf-8",
    )
    return session, database, output


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
            request = Request(url, headers={
                "X-MarketScanner-Session-Token": self.httpd.session_token,
            })
            with urlopen(request, timeout=10) as response:
                return json.loads(response.read())
        request = Request(
            url,
            data=json.dumps(payload).encode("utf-8"),
            headers={
                "Content-Type": "application/json",
                "Origin": f"http://127.0.0.1:{self.port}",
                "X-MarketScanner-Session-Token": self.httpd.session_token,
            },
            method="POST",
        )
        try:
            with urlopen(request, timeout=10) as response:
                return json.loads(response.read())
        except HTTPError as exc:
            exc.payload = json.loads(exc.read())
            exc.close()
            raise

    def fetch(self, path: str) -> tuple[bytes, str]:
        request = Request(
            f"http://127.0.0.1:{self.port}{path}",
            headers={"X-MarketScanner-Session-Token": self.httpd.session_token},
        )
        with urlopen(request, timeout=10) as response:
            return response.read(), response.headers.get_content_type()

    def wait_for_job(self, identifier: str) -> dict:
        deadline = time.time() + 10
        while time.time() < deadline:
            job = self.api(f"/api/jobs/{identifier}")
            if job["status"] in {"complete", "failed"}:
                return job
            time.sleep(0.05)
        self.fail("Timed out waiting for map job")

    def test_post_requires_session_token_and_expected_origin(self) -> None:
        url = f"http://127.0.0.1:{self.port}/api/session/inspect"
        body = json.dumps({"session": str(self.session_a)}).encode("utf-8")
        for headers in (
            {"Content-Type": "application/json"},
            {
                "Content-Type": "application/json",
                "Origin": f"http://127.0.0.1:{self.port}",
                "X-MarketScanner-Session-Token": "invalid",
            },
            {
                "Content-Type": "application/json",
                "Origin": "https://attacker.example",
                "X-MarketScanner-Session-Token": self.httpd.session_token,
            },
        ):
            request = Request(url, data=body, headers=headers, method="POST")
            with self.assertRaises(HTTPError) as context:
                urlopen(request, timeout=10)
            self.assertEqual(context.exception.code, 403)
            payload = json.loads(context.exception.read())
            context.exception.close()
            self.assertEqual(payload["code"], "request_forbidden")

        controlled = Request(
            url,
            data=body,
            headers={
                "Content-Type": "application/json",
                "X-MarketScanner-Session-Token": self.httpd.session_token,
            },
            method="POST",
        )
        with urlopen(controlled, timeout=10) as response:
            self.assertEqual(response.status, 200)

    def test_server_refuses_non_loopback_bind_and_reports_about(self) -> None:
        with self.assertRaisesRegex(ValueError, "loopback"):
            server.create_server(0, host="0.0.0.0")
        request = Request(
            f"http://127.0.0.1:{self.port}/api/about",
            headers={"X-MarketScanner-Session-Token": self.httpd.session_token},
        )
        with urlopen(request, timeout=10) as response:
            payload = json.loads(response.read())
            self.assertEqual(response.headers["X-Frame-Options"], "DENY")
            self.assertEqual(response.headers["Referrer-Policy"], "no-referrer")
        self.assertEqual(payload["product"], "Supermarket Map Studio")
        self.assertEqual(payload["version"], server.MAP_STUDIO_VERSION)
        self.assertEqual(payload["runtime_mode"], "development")
        self.assertEqual(payload["startup_diagnostics"]["mode"], "development")
        self.assertNotIn("session_token", json.dumps(payload))

    def test_sensitive_get_requires_auth_and_bootstrap_sets_http_only_cookie(self) -> None:
        with self.assertRaises(HTTPError) as unauthorized:
            urlopen(f"http://127.0.0.1:{self.port}/api/jobs", timeout=10)
        self.assertEqual(unauthorized.exception.code, 403)
        unauthorized.exception.close()
        bootstrap = Request(
            f"http://127.0.0.1:{self.port}/api/session/bootstrap",
            data=b"{}",
            headers={
                "Content-Type": "application/json",
                "Origin": f"http://127.0.0.1:{self.port}",
                "X-MarketScanner-Session-Token": self.httpd.session_token,
            },
            method="POST",
        )
        with urlopen(bootstrap, timeout=10) as response:
            cookie = response.headers.get("Set-Cookie", "")
        self.assertIn("HttpOnly", cookie)
        self.assertIn("SameSite=Strict", cookie)
        authenticated = Request(
            f"http://127.0.0.1:{self.port}/api/jobs",
            headers={"Cookie": cookie.split(";", 1)[0]},
        )
        with urlopen(authenticated, timeout=10) as response:
            self.assertEqual(response.status, 200)

    def test_operator_diagnostics_bundle_excludes_session_token(self) -> None:
        result = self.api(
            "/api/diagnostics/export",
            {"output_directory": str(self.root)},
        )
        archive = Path(result["path"])
        self.assertTrue(archive.is_file())
        self.assertRegex(result["sha256"], r"^[0-9a-f]{64}$")
        self.assertFalse(result["token_persisted"])
        with zipfile.ZipFile(archive) as bundle:
            self.assertIn("diagnostics.json", bundle.namelist())
            contents = b"".join(bundle.read(name) for name in bundle.namelist())
        self.assertNotIn(self.httpd.session_token.encode("utf-8"), contents)

    def test_recoverable_journal_error_does_not_hide_recovery_ui(self) -> None:
        executable = Path(sys.executable)
        original_errors = list(server.STATE.startup_errors)
        server.STATE.startup_errors[:] = ["old.json: journal schema is invalid"]
        try:
            with (
                mock.patch.object(server.offline, "find_reprocess_binary", return_value=executable),
                mock.patch.object(server, "find_factor_graph_binary", return_value=executable),
                mock.patch.object(
                    server,
                    "native_tool_diagnostic",
                    side_effect=lambda name, _path: {
                        "name": name,
                        "ok": True,
                        "detail": "ok",
                    },
                ),
                mock.patch.object(
                    server,
                    "operator_package_diagnostic",
                    return_value={
                        "name": "operator_package_integrity",
                        "ok": True,
                        "detail": "ok",
                    },
                ),
            ):
                diagnostics = server.startup_diagnostics()
        finally:
            server.STATE.startup_errors[:] = original_errors
        self.assertFalse(diagnostics["ok"])
        self.assertTrue(diagnostics["can_start"])

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

    def test_localized_edit_requires_cas_and_reports_conflict_as_409(self) -> None:
        output = self.root / "localized-cas"
        snapshot = create_localized_store(output)
        job = server.STATE.add("localized", output)
        server.STATE.set_status(job.identifier, "complete")

        with self.assertRaises(HTTPError) as missing:
            self.api(
                f"/api/jobs/{job.identifier}/localized/edit",
                {"action": "undo"},
            )
        self.assertEqual(missing.exception.code, 400)
        missing_payload = missing.exception.payload
        self.assertEqual(missing_payload["code"], "bad_request")

        with self.assertRaises(HTTPError) as conflict:
            self.api(
                f"/api/jobs/{job.identifier}/localized/edit",
                {
                    "action": "undo",
                    "expected_version_id": snapshot.version_id,
                    "expected_revision": snapshot.revision + 1,
                },
            )
        self.assertEqual(conflict.exception.code, 409)
        conflict_payload = conflict.exception.payload
        self.assertEqual(conflict_payload["code"], "revision_conflict")
        self.assertEqual(conflict_payload["current_version_id"], snapshot.version_id)
        self.assertEqual(conflict_payload["current_revision"], snapshot.revision)

    def test_two_localized_clients_cannot_commit_the_same_base_revision(self) -> None:
        output = self.root / "localized-two-clients"
        source_database = self.session_a / "segment_0001" / "rtabmap_segment_0001.db"
        prior_map = self.root / "PriorMap-placeholder"
        prior_map.mkdir()
        (prior_map / "package_manifest.json").write_text(
            json.dumps({"package_sha256": "a" * 64}), encoding="utf-8"
        )
        source_manifest = {
            "prior_map": str(prior_map),
            "source_session": str(self.session_a),
            "source_database": str(source_database),
            "source_database_sha256_before": server.localized._sha256(source_database),
            "optimized_database": str(source_database),
        }
        journal = server.localized.new_manual_edits(
            "a" * 64,
            server.localized._sha256(source_database),
            server.localized._sha256(source_database),
        )
        first = create_localized_store(
            output, source_manifest=source_manifest, journal=journal
        )
        session_input = server.LocalizedVersionStore(output).read_verified_json(
            first, "session_input_manifest.json"
        )
        (output / "map.json").write_text(
            json.dumps({"parameters": {}}), encoding="utf-8"
        )
        job = server.STATE.add("localized", output)
        server.STATE.set_status(job.identifier, "complete")

        def commit_replay(**kwargs):
            next_journal = kwargs["manual_edits"]
            snapshot = create_localized_store(
                output,
                source_manifest=source_manifest,
                journal=next_journal,
            )
            return {
                "version_id": snapshot.version_id,
                "revision": snapshot.revision,
                "current_updated": True,
            }

        segment = SimpleNamespace(
            poses=[SimpleNamespace(node_id=1, stamp=1.0, x=0.0, y=0.0, yaw=0.0)]
        )
        payload = {
            "action": "undo",
            "expected_version_id": first.version_id,
            "expected_revision": first.revision,
        }
        with (
            mock.patch.object(
                server,
                "_manual_edit_context",
                return_value=(
                    [],
                    [],
                    [],
                    {
                        "bounds": {
                            "min_x_m": 0,
                            "max_x_m": 1,
                            "min_y_m": 0,
                            "max_y_m": 1,
                        }
                    },
                ),
            ),
            mock.patch.object(
                server, "validate_prior_map_package", return_value={"valid": True}
            ),
            mock.patch.object(
                server.localized,
                "build_session_input_manifest",
                return_value={
                    key: value
                    for key, value in session_input.items()
                    if key != "input_identity_id"
                },
            ),
            mock.patch.object(server.base, "discover_segments", return_value=[segment]),
            mock.patch.object(
                server.localized,
                "process_localized_session",
                side_effect=commit_replay,
            ),
        ):
            barrier = threading.Barrier(3)
            accepted_results: list[dict] = []
            rejected_results: list[HTTPError] = []

            def submit_same_revision() -> None:
                barrier.wait()
                try:
                    accepted_results.append(
                        self.api(
                            f"/api/jobs/{job.identifier}/localized/edit", payload
                        )
                    )
                except HTTPError as exc:
                    rejected_results.append(exc)

            clients = [
                threading.Thread(target=submit_same_revision) for _ in range(2)
            ]
            for client in clients:
                client.start()
            barrier.wait()
            for client in clients:
                client.join(timeout=5)
            self.assertTrue(all(not client.is_alive() for client in clients))
        self.assertEqual(len(accepted_results), 1)
        self.assertEqual(len(rejected_results), 1)
        accepted = accepted_results[0]
        self.assertEqual(accepted["revision"], first.revision + 1)
        self.assertNotEqual(accepted["version_id"], first.version_id)
        stale = rejected_results[0]
        self.assertEqual(stale.code, 409)
        self.assertEqual(
            stale.payload["current_revision"], first.revision + 1
        )

    def test_localized_replay_failure_keeps_revision_and_current(self) -> None:
        output = self.root / "localized-replay-failure"
        source_database = self.session_a / "segment_0001" / "rtabmap_segment_0001.db"
        prior_map = self.root / "PriorMap-replay-failure"
        prior_map.mkdir()
        (prior_map / "package_manifest.json").write_text(
            json.dumps({"package_sha256": "a" * 64}), encoding="utf-8"
        )
        source_manifest = {
            "prior_map": str(prior_map),
            "source_session": str(self.session_a),
            "source_database": str(source_database),
            "source_database_sha256_before": server.localized._sha256(source_database),
            "optimized_database": str(source_database),
        }
        journal = server.localized.new_manual_edits(
            "a" * 64,
            server.localized._sha256(source_database),
            server.localized._sha256(source_database),
        )
        first = create_localized_store(
            output, source_manifest=source_manifest, journal=journal
        )
        session_input = server.LocalizedVersionStore(output).read_verified_json(
            first, "session_input_manifest.json"
        )
        (output / "map.json").write_text("{}\n", encoding="utf-8")
        job = server.STATE.add("localized", output)
        server.STATE.set_status(job.identifier, "complete")
        segment = SimpleNamespace(
            poses=[SimpleNamespace(node_id=1, stamp=1.0, x=0.0, y=0.0, yaw=0.0)]
        )
        with (
            mock.patch.object(
                server,
                "_manual_edit_context",
                return_value=([], [], [], {"bounds": {}}),
            ),
            mock.patch.object(
                server, "validate_prior_map_package", return_value={"valid": True}
            ),
            mock.patch.object(
                server.localized,
                "build_session_input_manifest",
                return_value={
                    key: value
                    for key, value in session_input.items()
                    if key != "input_identity_id"
                },
            ),
            mock.patch.object(server.base, "discover_segments", return_value=[segment]),
            mock.patch.object(
                server.localized,
                "process_localized_session",
                side_effect=RuntimeError("injected replay failure"),
            ),
            self.assertRaises(RuntimeError),
        ):
            server.apply_localized_edit(
                job,
                {
                    "action": "undo",
                    "expected_version_id": first.version_id,
                    "expected_revision": first.revision,
                },
            )
        current = server.LocalizedVersionStore(output).current()
        self.assertIsNotNone(current)
        assert current is not None
        self.assertEqual(current.version_id, first.version_id)
        self.assertEqual(current.revision, first.revision)

    def test_review_transition_is_versioned_and_bounded_solver_cannot_publish(self) -> None:
        output = self.root / "localized-publish-gate"
        draft = create_localized_store(
            output,
            report={
                "publish_state": "draft",
                "review_gate": {"passed": True, "blockers": []},
                "publish_gate": {
                    "passed": False,
                    "blockers": [
                        {"code": "solver_not_full_relative_se2_factor_graph"}
                    ],
                },
                "solver": {
                    "type": "bounded_correction_field",
                    "full_factor_graph": False,
                },
            },
        )
        job = server.STATE.add("localized", output)
        server.STATE.set_status(job.identifier, "complete")
        review = self.api(
            f"/api/jobs/{job.identifier}/localized/state",
            {
                "action": "submit_review",
                "reason": "review checks complete",
                "expected_version_id": draft.version_id,
                "expected_revision": draft.revision,
            },
        )
        self.assertEqual(review["publish_state"], "review")
        self.assertNotEqual(review["version_id"], draft.version_id)
        with self.assertRaises(HTTPError) as blocked:
            self.api(
                f"/api/jobs/{job.identifier}/localized/state",
                {
                    "action": "publish",
                    "reason": "attempt explicit publication",
                    "expected_version_id": review["version_id"],
                    "expected_revision": review["revision"],
                },
            )
        self.assertEqual(blocked.exception.code, 403)
        self.assertEqual(blocked.exception.payload["code"], "request_forbidden")
        self.assertIsNone(server.LocalizedVersionStore(output).published())

    def test_production_publish_rechecks_selfcheck_and_preserves_pointers_on_failure(self) -> None:
        output = self.root / "localized-production-selfcheck"
        review = create_localized_store(
            output,
            report={
                "publish_state": "review",
                "review_gate": {"passed": True, "blockers": []},
                "publish_gate": {"passed": True, "blockers": []},
                "solver": {
                    "type": "relative_se2_factor_graph",
                    "full_factor_graph": True,
                    "published_capable": True,
                },
            },
        )
        job = server.STATE.add("localized", output)
        server.STATE.set_status(job.identifier, "complete")
        evidence = self.root / "field-evidence.json"
        evidence.write_text("{}\n", encoding="utf-8")
        before_current = server.LocalizedVersionStore(output).current()
        original_mode = self.httpd.runtime_mode
        self.httpd.runtime_mode = "production"
        try:
            with mock.patch.object(
                server,
                "startup_diagnostics",
                return_value={
                    "mode": "production",
                    "production_qualified": False,
                    "can_start": False,
                    "checks": [{"name": "injected", "ok": False}],
                },
            ) as diagnostics:
                with self.assertRaises(HTTPError) as blocked:
                    self.api(
                        f"/api/jobs/{job.identifier}/localized/state",
                        {
                            "action": "publish",
                            "reason": "must fail selfcheck",
                            "expected_version_id": review.version_id,
                            "expected_revision": review.revision,
                            "operator_confirmed": True,
                            "qualification_evidence_path": str(evidence),
                            "qualification_evidence_sha256": "f" * 64,
                        },
                    )
            self.assertEqual(blocked.exception.code, 422)
            self.assertEqual(
                blocked.exception.payload["blockers"][0]["code"],
                "production_selfcheck_failed",
            )
            diagnostics.assert_called_once_with("production")
        finally:
            self.httpd.runtime_mode = original_mode
        store = server.LocalizedVersionStore(output)
        self.assertEqual(store.current(), before_current)
        self.assertIsNone(store.published())

    def test_production_publish_passes_only_after_fresh_selfcheck(self) -> None:
        output = self.root / "localized-production-pass"
        review = create_localized_store(
            output,
            report={
                "publish_state": "review",
                "review_gate": {"passed": True, "blockers": []},
                "publish_gate": {"passed": True, "blockers": []},
                "solver": {
                    "type": "relative_se2_factor_graph",
                    "full_factor_graph": True,
                    "published_capable": True,
                },
            },
        )
        job = server.STATE.add("localized", output)
        server.STATE.set_status(job.identifier, "complete")
        evidence = self.root / "field-evidence.json"
        evidence.write_text("{}\n", encoding="utf-8")
        with self.assertRaises(HTTPError) as development_blocked:
            self.api(
                f"/api/jobs/{job.identifier}/localized/state",
                {
                    "action": "publish",
                    "reason": "development must never publish",
                    "expected_version_id": review.version_id,
                    "expected_revision": review.revision,
                    "operator_confirmed": True,
                    "qualification_evidence_path": str(evidence),
                    "qualification_evidence_sha256": "f" * 64,
                },
            )
        self.assertEqual(development_blocked.exception.code, 403)
        self.assertEqual(
            server.LocalizedVersionStore(output).current(), review
        )
        self.assertIsNone(server.LocalizedVersionStore(output).published())
        published = SimpleNamespace(
            version_id="v999999",
            revision=review.revision,
            state="published",
        )
        original_mode = self.httpd.runtime_mode
        self.httpd.runtime_mode = "production"
        try:
            with (
                mock.patch.object(
                    server,
                    "startup_diagnostics",
                    return_value={
                        "mode": "production",
                        "production_qualified": True,
                        "can_start": True,
                        "checks": [],
                    },
                ) as diagnostics,
                mock.patch.object(
                    server.LocalizedVersionStore,
                    "publish_current",
                    return_value=published,
                ) as publish_current,
                mock.patch.object(
                    server,
                    "runtime_release_identity",
                    return_value={
                        "release_manifest_sha256": "a" * 64,
                        "git_sha": "b" * 40,
                        "product_version": "test",
                        "quality_policy_sha256": "c" * 64,
                    },
                ),
            ):
                result = self.api(
                    f"/api/jobs/{job.identifier}/localized/state",
                    {
                        "action": "publish",
                        "reason": "qualified publication",
                        "expected_version_id": review.version_id,
                        "expected_revision": review.revision,
                        "operator_confirmed": True,
                        "qualification_evidence_path": str(evidence),
                        "qualification_evidence_sha256": "f" * 64,
                    },
                )
            self.assertEqual(result["publish_state"], "published")
            diagnostics.assert_called_once_with("production")
            publish_current.assert_called_once()
        finally:
            self.httpd.runtime_mode = original_mode

    def test_about_uses_server_runtime_mode_for_diagnostics(self) -> None:
        original_mode = self.httpd.runtime_mode
        self.httpd.runtime_mode = "production"
        try:
            with mock.patch.object(
                server,
                "startup_diagnostics",
                side_effect=lambda mode: {
                    "mode": mode,
                    "production_qualified": mode == "production",
                    "can_start": True,
                    "checks": [],
                },
            ) as diagnostics:
                payload = self.api("/api/about")
            self.assertEqual(payload["runtime_mode"], "production")
            self.assertEqual(payload["startup_diagnostics"]["mode"], "production")
            self.assertTrue(
                payload["startup_diagnostics"]["production_qualified"]
            )
            diagnostics.assert_called_once_with("production")
        finally:
            self.httpd.runtime_mode = original_mode

    def test_prior_map_api_converts_validates_and_serves_preview(self) -> None:
        workbook = self.root / "prior-map.xlsx"
        output = self.root / "PriorMap-output"
        create_prior_map_workbook(workbook)
        source_before = workbook.read_bytes()
        job = self.api(
            "/api/prior-map/convert",
            {"xlsx": str(workbook), "output": str(output), "name": "测试货架图"},
        )
        completed = self.wait_for_job(job["id"])
        self.assertEqual(completed["status"], "complete", completed.get("error"))
        self.assertEqual(completed["kind"], "prior_map")
        self.assertEqual(completed["map"]["name"], "测试货架图")
        self.assertEqual(completed["map"]["element_statistics"]["MapShelf"], 1)
        self.assertIn("preview.png", completed["artifacts"])
        preview, content_type = self.fetch(completed["artifacts"]["preview.png"])
        self.assertEqual(content_type, "image/png")
        self.assertTrue(preview.startswith(b"\x89PNG\r\n\x1a\n"))
        inspection = self.api(
            "/api/prior-map/inspect",
            {"package": str(output)},
        )
        self.assertTrue(inspection["valid"])
        self.assertEqual(inspection["manifest"]["prior_map_id"], completed["map"]["prior_map_id"])
        self.assertEqual(workbook.read_bytes(), source_before)

    def test_session_inspection_keeps_storage_and_workflow_modes_separate(self) -> None:
        legacy = self.api(
            "/api/session/inspect",
            {"session": str(self.session_a)},
        )
        self.assertEqual(legacy["workflow_mode"], "free_mapping")
        self.assertTrue(legacy["workflow_legacy"])

        session = create_session(
            self.root,
            "SupermarketSession-Prior",
            0.0,
            "continuous_streaming",
        )
        metadata_path = session / "segment_0001" / "metadata.json"
        metadata = json.loads(metadata_path.read_text())
        metadata.update(
            {
                "workflowMode": "prior_map_localized",
                "priorMapId": "fixture-map",
                "priorMapSha256": "0" * 64,
                "floorId": "1",
                "initialMapPose": {"x_m": 1.0, "y_m": 2.0, "yaw_rad": 0.5},
            }
        )
        metadata_path.write_text(json.dumps(metadata), encoding="utf-8")
        inspected = self.api(
            "/api/session/inspect",
            {"session": str(session)},
        )
        self.assertEqual(inspected["scan_mode"], "continuous_streaming")
        self.assertEqual(inspected["workflow_mode"], "prior_map_localized")
        self.assertEqual(inspected["prior_map_ids"], ["fixture-map"])

    def test_explicit_checkpoint_cleanup_requires_matching_older_evidence(self) -> None:
        session = create_session(
            self.root,
            "SupermarketSession-FinalizedCleanup",
            0.0,
            "continuous_streaming",
        )
        segment = session / "segment_0001"
        metadata_path = segment / "metadata.json"
        metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
        metadata.update(
            {
                "trackingSessionId": "tracking-cleanup",
                "finalizedAtUnix": 20.0,
            }
        )
        metadata_path.write_text(json.dumps(metadata), encoding="utf-8")
        checkpoint_path = segment / "live_checkpoint.json"
        checkpoint_path.write_text(
            json.dumps(
                {
                    "trackingSessionId": "tracking-cleanup",
                    "updatedAtUnix": 10.0,
                }
            ),
            encoding="utf-8",
        )

        evidence = self.api(
            "/api/session/inspect",
            {"session": str(session)},
        )["checkpoint_cleanup"]
        self.assertTrue(evidence["available"])
        request = {
            "session": str(session),
            "confirmed": True,
            "expected_tracking_session_id": evidence["tracking_session_id"],
            "expected_finalized_at_unix": evidence["finalized_at_unix"],
            "expected_metadata_sha256": evidence["metadata_sha256"],
            "expected_checkpoint_sha256": evidence["checkpoint_sha256"],
        }
        result = self.api(
            "/api/session/cleanup-finalized-checkpoint",
            request,
        )
        self.assertTrue(result["cleaned"])
        self.assertFalse(checkpoint_path.exists())
        events = (segment / "scan_events.jsonl").read_text(encoding="utf-8")
        self.assertIn("finalization_checkpoint_cleanup_authorized", events)
        self.assertIn("finalization_checkpoint_cleanup_completed", events)
        self.assertEqual(
            result["deleted_checkpoint_sha256"],
            evidence["checkpoint_sha256"],
        )
        with self.assertRaises(HTTPError) as repeated:
            self.api("/api/session/cleanup-finalized-checkpoint", request)
        self.assertEqual(repeated.exception.code, 409)
        self.assertEqual(
            repeated.exception.payload["code"],
            "checkpoint_cleanup_conflict",
        )

    def test_checkpoint_cleanup_rejects_mismatch_and_newer_checkpoint(self) -> None:
        for name, checkpoint_identity, checkpoint_time, error_text in (
            ("Mismatch", "other", 10.0, "identity"),
            ("Newer", "tracking-cleanup", 21.0, "newer"),
        ):
            with self.subTest(name=name):
                session = create_session(
                    self.root,
                    f"SupermarketSession-FinalizedCleanup{name}",
                    0.0,
                    "continuous_streaming",
                )
                segment = session / "segment_0001"
                metadata_path = segment / "metadata.json"
                metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
                metadata.update(
                    {
                        "trackingSessionId": "tracking-cleanup",
                        "finalizedAtUnix": 20.0,
                    }
                )
                metadata_path.write_text(json.dumps(metadata), encoding="utf-8")
                checkpoint_path = segment / "live_checkpoint.json"
                checkpoint_path.write_text(
                    json.dumps(
                        {
                            "trackingSessionId": checkpoint_identity,
                            "updatedAtUnix": checkpoint_time,
                        }
                    ),
                    encoding="utf-8",
                )
                with self.assertRaises(HTTPError) as rejected:
                    self.api(
                        "/api/session/cleanup-finalized-checkpoint",
                        {
                            "session": str(session),
                            "confirmed": True,
                            "expected_tracking_session_id": "tracking-cleanup",
                            "expected_finalized_at_unix": 20.0,
                            "expected_metadata_sha256": "0" * 64,
                            "expected_checkpoint_sha256": "0" * 64,
                        },
                    )
                self.assertEqual(rejected.exception.code, 400)
                self.assertIn(
                    error_text,
                    rejected.exception.payload["error"].lower(),
                )
                self.assertTrue(checkpoint_path.exists())

    def test_checkpoint_cleanup_requires_confirmation_and_exact_evidence(self) -> None:
        session = create_session(
            self.root,
            "SupermarketSession-CleanupCAS",
            0.0,
            "continuous_streaming",
        )
        segment = session / "segment_0001"
        metadata_path = segment / "metadata.json"
        metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
        metadata.update(
            {"trackingSessionId": "cleanup-cas", "finalizedAtUnix": 20.0}
        )
        metadata_path.write_text(json.dumps(metadata), encoding="utf-8")
        checkpoint = segment / "live_checkpoint.json"
        checkpoint.write_text(
            json.dumps(
                {"trackingSessionId": "cleanup-cas", "updatedAtUnix": 10.0}
            ),
            encoding="utf-8",
        )
        evidence = self.api(
            "/api/session/inspect", {"session": str(session)}
        )["checkpoint_cleanup"]
        with self.assertRaises(HTTPError) as unconfirmed:
            self.api(
                "/api/session/cleanup-finalized-checkpoint",
                {"session": str(session)},
            )
        self.assertEqual(unconfirmed.exception.code, 400)
        stale = {
            "session": str(session),
            "confirmed": True,
            "expected_tracking_session_id": evidence["tracking_session_id"],
            "expected_finalized_at_unix": evidence["finalized_at_unix"],
            "expected_metadata_sha256": evidence["metadata_sha256"],
            "expected_checkpoint_sha256": "f" * 64,
        }
        with self.assertRaises(HTTPError) as conflict:
            self.api("/api/session/cleanup-finalized-checkpoint", stale)
        self.assertEqual(conflict.exception.code, 409)
        self.assertEqual(
            conflict.exception.payload["code"],
            "checkpoint_cleanup_conflict",
        )
        self.assertTrue(checkpoint.exists())

    def test_checkpoint_cleanup_rejects_linked_segment_and_files(self) -> None:
        outside = self.root / "outside-cleanup"
        outside.mkdir()
        for linked_name in ("segment", "metadata", "checkpoint", "events"):
            with self.subTest(linked_name=linked_name):
                session = create_session(
                    self.root,
                    f"SupermarketSession-Linked-{linked_name}",
                    0.0,
                    "continuous_streaming",
                )
                segment = session / "segment_0001"
                metadata_path = segment / "metadata.json"
                metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
                metadata.update(
                    {"trackingSessionId": "linked", "finalizedAtUnix": 20.0}
                )
                metadata_path.write_text(json.dumps(metadata), encoding="utf-8")
                checkpoint = segment / "live_checkpoint.json"
                checkpoint.write_text(
                    json.dumps(
                        {"trackingSessionId": "linked", "updatedAtUnix": 10.0}
                    ),
                    encoding="utf-8",
                )
                target = outside / linked_name
                if linked_name == "segment":
                    segment.rename(target)
                    segment.symlink_to(target, target_is_directory=True)
                else:
                    path = {
                        "metadata": metadata_path,
                        "checkpoint": checkpoint,
                        "events": segment / "scan_events.jsonl",
                    }[linked_name]
                    if path.exists():
                        path.rename(target)
                    else:
                        target.write_text("", encoding="utf-8")
                    path.symlink_to(target)
                inspected = self.api(
                    "/api/session/inspect", {"session": str(session)}
                )
                self.assertFalse(inspected["checkpoint_cleanup"]["available"])

    def test_checkpoint_cleanup_rejects_windows_reparse_attributes(self) -> None:
        synthetic = SimpleNamespace(
            st_mode=stat.S_IFDIR,
            st_file_attributes=0x0400,
        )
        self.assertTrue(
            server._is_link_or_reparse(Path("segment_0001"), synthetic)
        )

    def test_cleanup_evidence_closes_metadata_when_checkpoint_open_fails(
        self,
    ) -> None:
        session = create_session(
            self.root,
            "SupermarketSession-CleanupMissingCheckpoint",
            0.0,
            "continuous_streaming",
        )
        opened_descriptors: list[int] = []
        open_regular = server._open_regular_no_follow

        def tracked_open(path: Path, flags: int) -> int:
            descriptor = open_regular(path, flags)
            opened_descriptors.append(descriptor)
            return descriptor

        with mock.patch.object(
            server,
            "_open_regular_no_follow",
            side_effect=tracked_open,
        ):
            evidence = server.checkpoint_cleanup_evidence(session)

        self.assertFalse(evidence["available"])
        self.assertEqual(len(opened_descriptors), 1)
        with self.assertRaises(OSError):
            os.fstat(opened_descriptors[0])

    def test_manual_merge_preview_maps_regions_to_user_closures(self) -> None:
        _session, _database, output = create_manual_merge_result(self.root)
        job = server.STATE.add("map", output)
        server.STATE.set_status(job.identifier, "complete")
        preview = self.api(
            f"/api/jobs/{job.identifier}/merge/preview",
            {
                "regions": [
                    {"rect_pixels": [15, 70, 75, 90]},
                    {"rect_pixels": [115, 70, 175, 90]},
                ],
                "information_level": "medium",
            },
        )
        self.assertTrue(preview["can_apply"])
        self.assertGreaterEqual(preview["summary"]["constraint_count"], 2)
        self.assertAlmostEqual(preview["alignment"]["dx_m"], -10.0, places=3)
        self.assertTrue(all(item["type"] == 4 for item in preview["constraints"]))
        self.assertTrue(all(item["from_id"] > item["to_id"] for item in preview["constraints"]))

    def test_manual_user_closures_are_injected_only_into_disposable_copy(self) -> None:
        _session, source, output = create_manual_merge_result(self.root)
        preview = server.merge.preview_merge(
            output,
            {
                "regions": [
                    {"rect_pixels": [15, 70, 75, 90]},
                    {"rect_pixels": [115, 70, 175, 90]},
                ],
            },
        )
        disposable = self.root / "manual-staging.db"
        shutil.copy2(source, disposable)
        result = server.offline._inject_user_links(disposable, preview["constraints"])
        self.assertEqual(result["injected_count"], len(preview["constraints"]))
        with closing(sqlite3.connect(source)) as conn:
            self.assertEqual(conn.execute("SELECT count(*) FROM Link").fetchone()[0], 0)
        with closing(sqlite3.connect(disposable)) as conn:
            rows = conn.execute(
                "SELECT from_id, to_id, type, length(information_matrix), length(transform) "
                "FROM Link ORDER BY from_id"
            ).fetchall()
        self.assertEqual(len(rows), len(preview["constraints"]))
        self.assertTrue(all(row[0] > row[1] and row[2:] == (4, 288, 48) for row in rows))

    def test_manual_merge_rejects_indistinguishable_overlapping_regions(self) -> None:
        _session, _database, output = create_manual_merge_result(self.root)
        with self.assertRaisesRegex(
            server.merge.MergeProcessingError,
            "overlap almost completely",
        ):
            server.merge.preview_merge(
                output,
                {
                    "regions": [
                        {"rect_pixels": [12, 68, 82, 92]},
                        {"rect_pixels": [12, 68, 82, 92]},
                    ],
                },
            )

    def test_manual_merge_validation_rejects_unapplied_alignment(self) -> None:
        _session, source, output = create_manual_merge_result(self.root)
        preview = server.merge.preview_merge(
            output,
            {
                "regions": [
                    {"rect_pixels": [15, 70, 75, 90]},
                    {"rect_pixels": [115, 70, 175, 90]},
                ],
            },
        )
        validation = server.merge.validate_optimized_merge(
            source,
            source,
            preview["constraints"],
            "xy",
        )
        self.assertEqual(validation["status"], "rejected")
        self.assertGreater(validation["median_constraint_residual_m"], 1.0)

    def test_manual_merge_validation_rejects_missing_constraint_nodes(self) -> None:
        _session, source, output = create_manual_merge_result(self.root)
        preview = server.merge.preview_merge(
            output,
            {
                "regions": [
                    {"rect_pixels": [15, 70, 75, 90]},
                    {"rect_pixels": [115, 70, 175, 90]},
                ],
            },
        )
        optimized = self.root / "optimized-missing-node.db"
        shutil.copy2(source, optimized)
        aligned = {
            index + 1: transform_blob(float(index), 0.0, 0.0)
            for index in range(6)
        }
        aligned.update(
            {
                index + 101: transform_blob(float(index), 0.0, 0.0)
                for index in range(6)
            }
        )
        add_optimized_poses(optimized, aligned)
        missing_node = int(preview["constraints"][0]["from_id"])
        with closing(sqlite3.connect(optimized)) as conn, conn:
            conn.execute("DELETE FROM Node WHERE id=?", (missing_node,))
        add_optimized_poses(
            optimized,
            {
                node_id: transform
                for node_id, transform in aligned.items()
                if node_id != missing_node
            },
        )

        validation = server.merge.validate_optimized_merge(
            source,
            optimized,
            preview["constraints"],
            "xy",
        )

        self.assertEqual(validation["status"], "rejected")
        self.assertEqual(
            validation["requested_constraint_count"],
            len(preview["constraints"]),
        )
        self.assertLess(
            validation["evaluated_constraint_count"],
            validation["requested_constraint_count"],
        )
        self.assertTrue(validation["missing_constraints"])

    def test_manual_merge_validation_rejects_rotational_conflict(self) -> None:
        _session, source, output = create_manual_merge_result(self.root)
        preview = server.merge.preview_merge(
            output,
            {
                "regions": [
                    {"rect_pixels": [15, 70, 75, 90]},
                    {"rect_pixels": [115, 70, 175, 90]},
                ],
            },
        )
        optimized = self.root / "optimized-rotational-conflict.db"
        shutil.copy2(source, optimized)
        rotated = {
            index + 1: transform_blob(float(index), 0.0, 0.0)
            for index in range(6)
        }
        rotated.update(
            {
                index + 101: transform_yaw_blob(
                    float(index), 0.0, 0.0, 30.0
                )
                for index in range(6)
            }
        )
        add_optimized_poses(optimized, rotated)

        validation = server.merge.validate_optimized_merge(
            source,
            optimized,
            preview["constraints"],
            "xy",
        )

        self.assertEqual(validation["status"], "rejected")
        self.assertLess(validation["median_constraint_residual_m"], 0.01)
        self.assertGreater(validation["median_constraint_rotation_deg"], 20.0)

    def test_manual_merge_apply_creates_new_validated_map_version(self) -> None:
        _session, source, base_output = create_manual_merge_result(self.root)
        source_contents = source.read_bytes()
        base_job = server.STATE.add("map", base_output)
        server.STATE.set_status(base_job.identifier, "complete")
        fake_binary = self.root / "rtabmap-reprocess-manual"
        fake_binary.write_text("fake", encoding="utf-8")
        fake_binary.chmod(0o755)

        def fake_run(command: list[str], **_kwargs: object) -> SimpleNamespace:
            staged_source = Path(command[-2])
            destination = Path(command[-1])
            with closing(sqlite3.connect(staged_source)) as conn:
                self.assertGreater(
                    conn.execute("SELECT count(*) FROM Link WHERE type=4").fetchone()[0],
                    1,
                )
            shutil.copy2(staged_source, destination)
            optimized = {
                index + 1: transform_blob(float(index), 0.0, 0.0)
                for index in range(6)
            }
            optimized.update(
                {
                    index + 101: transform_blob(float(index), 0.0, 0.0)
                    for index in range(6)
                }
            )
            add_optimized_poses(destination, optimized)
            return SimpleNamespace(
                returncode=0,
                stdout=(
                    "Processed 12/12 nodes [id=106 map=0 graph=12 hyp=0]... 4ms\n"
                    "FINAL_OPTIMIZATION_DONE poses=12 constraints=6 "
                    "iterations_done=4 error=0.01 seconds=0.02"
                ),
                stderr="",
            )

        payload = {
            "regions": [
                {"rect_pixels": [15, 70, 75, 90]},
                {"rect_pixels": [115, 70, 175, 90]},
            ],
            "confirmed": True,
            "options": {
                "reprocess_binary": str(fake_binary),
                "pc_local_staging": True,
                "gpu_backend": "cpu",
                "horizontal_axes": "xy",
                "resolution": 0.1,
            },
        }
        with mock.patch.object(server.offline.subprocess, "run", side_effect=fake_run):
            job = self.api(
                f"/api/jobs/{base_job.identifier}/merge/apply",
                payload,
            )
            result = self.wait_for_job(job["id"])
        self.assertEqual(result["status"], "complete", result.get("error"))
        self.assertIn("merge_manifest.json", result["artifacts"])
        manifest = self.api(result["artifacts"]["merge_manifest.json"])
        self.assertEqual(manifest["validation_status"], "pass")
        self.assertGreaterEqual(manifest["constraint_count"], 2)
        self.assertNotEqual(Path(result["output_dir"]), base_output)
        self.assertEqual(source.read_bytes(), source_contents)

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

    def test_inspection_exposes_phone_structure_coverage_summary(self) -> None:
        coverage = {
            "format": "SupermarketStructureCoverage",
            "version": 1,
            "cellSizeM": 0.2,
            "floorHeightM": -1.4,
            "summary": {
                "stableStructureCellCount": 48,
                "multiViewStructureCellCount": 31,
                "groundConflictCellCount": 3,
                "coverageScore": 0.61,
                "currentDetectionRateHz": 1.5,
            },
            "cells": [],
        }
        path = self.session_a / "segment_0001" / "structure_coverage_cells.json"
        path.write_text(json.dumps(coverage), encoding="utf-8")

        inspection = self.api("/api/session/inspect", {"session": str(self.session_a)})
        result = inspection["structure_coverage"]
        self.assertTrue(result["available"])
        self.assertEqual(result["summary"]["stableStructureCellCount"], 48)
        self.assertEqual(result["summary"]["multiViewStructureCellCount"], 31)
        self.assertEqual(result["summary"]["source"], "segment_0001/structure_coverage_cells.json")

    def test_inspection_exposes_stage_two_localization_and_tag_audit_counts(self) -> None:
        segment = self.session_a / "segment_0001"
        constraints = [
            {"accepted": True, "reason": "trusted_structure_correction"},
            {"accepted": False, "reason": "ambiguous_structure_match"},
        ]
        events = [
            {"state": "initializing"},
            {"state": "stable"},
            {"state": "weak"},
        ]
        observations = [
            {"observation_id": "o1", "needs_review": False},
            {"observation_id": "o2", "needs_review": True},
        ]
        for filename, records in (
            ("localization_constraints.jsonl", constraints),
            ("localization_events.jsonl", events),
            ("tag_observations.jsonl", observations),
        ):
            (segment / filename).write_text(
                "\n".join(json.dumps(record) for record in records) + "\n",
                encoding="utf-8",
            )
        (segment / "localized_price_tags.json").write_text(
            json.dumps(
                [
                    {"tag_id": "t1", "needs_review": False},
                    {"tag_id": "t2", "needs_review": True},
                ]
            ),
            encoding="utf-8",
        )

        inspection = self.api("/api/session/inspect", {"session": str(self.session_a)})
        audit = inspection["prior_map_localization"]
        self.assertTrue(audit["available"])
        self.assertEqual(audit["constraints"], 2)
        self.assertEqual(audit["accepted_constraints"], 1)
        self.assertEqual(audit["state_counts"]["stable"], 1)
        self.assertEqual(audit["tag_observations"], 2)
        self.assertEqual(audit["localized_price_tags"], 2)
        self.assertEqual(audit["needs_review"], 2)

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

    def test_nfc_is_hidden_from_active_debug_information(self) -> None:
        log = self.session_a / "segment_0001" / "scan_events.jsonl"
        events = [
            {"timestampUnix": 1.0, "event": "scan_started", "message": "scan"},
            {"timestampUnix": 2.0, "event": "price_tag_recorded", "message": "legacy NFC event"},
        ]
        log.write_text("\n".join(json.dumps(event) for event in events) + "\n", encoding="utf-8")

        inspection = self.api("/api/session/inspect", {"session": str(self.session_a)})
        self.assertEqual(inspection["scan_logs"]["event_count"], 1)
        self.assertEqual([event["event"] for event in inspection["scan_logs"]["events"]], ["scan_started"])
        self.assertNotIn("price_tag_count", inspection)
        self.assertNotIn("price_tags", inspection["segments"][0])

        html, _ = self.fetch("/")
        script, _ = self.fetch("/app.js")
        self.assertIn(b'<input id="option-tag-snap" type="hidden"', html)
        self.assertNotIn("价签吸附".encode("utf-8"), html)
        self.assertNotIn("个价签".encode("utf-8"), script)

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
        self.assertIn("shelf_outline.png", result["artifacts"])
        self.assertIn("shelf_outline_evidence.json", result["artifacts"])
        self.assertIn("preview_3d.json", result["artifacts"])
        self.assertTrue((output / "shelf_outline.png").is_file())
        evidence = self.api(result["artifacts"]["shelf_outline_evidence.json"])
        self.assertEqual(evidence["format"], "SupermarketShelfOutlineEvidence")
        self.assertEqual(evidence["version"], 6)
        self.assertEqual(evidence["defaults"]["maximum_fill_distance_m"], 0.62)
        self.assertEqual(evidence["defaults"]["minimum_region_area_m2"], 0.40)
        self.assertEqual(evidence["defaults"]["minimum_elevated_observation_count"], 2)
        self.assertEqual(evidence["defaults"]["minimum_observation_count"], 2)
        self.assertEqual(evidence["defaults"]["maximum_bridge_width_m"], 0.50)
        self.assertIn("source_frames", evidence)
        self.assertEqual(evidence["defaults"]["boundary_thickness_cells"], 2)
        self.assertIn("ground_runs", evidence)
        self.assertIn("elevated_runs", evidence)
        self.assertIn("free_space_runs", evidence)
        self.assertIn("elevated_observation_cells", evidence)
        preview_layers = self.api(result["artifacts"]["preview_layers.json"])
        self.assertEqual(preview_layers["version"], 4)
        self.assertIn("shelf_outline", {layer["id"] for layer in preview_layers["layers"]})
        self.assertIn("runs", preview_layers["shelf_outline"])
        self.assertIn("shelf_runs", preview_layers["shelf_outline"])
        self.assertIn("vertical_structure_runs", preview_layers["shelf_outline"])
        self.assertEqual(preview_layers["shelf_outline"]["evidence"], "shelf_outline_evidence.json")
        self.assertEqual(preview_layers["shelf_outline"]["display"], "closed_contours")
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
        with mock.patch.object(
            server.offline.subprocess, "Popen", immediate_popen(fake_run)
        ):
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
        self.assertEqual(cloud["structure_gpu_projected_frames"], 1)
        self.assertEqual(cloud["points"][0][:3], [42.0, 24.0, 1.5])

    def test_depth_cloud_projects_with_full_optimized_pose(self) -> None:
        add_rgbd_frame(self.session_a)
        database = self.session_a / "segment_0001" / "rtabmap_segment_0001.db"
        optimized = transform_blob(5.0, 6.0, 7.0)
        add_optimized_poses(database, {1: optimized})
        config = server.base.MapConfig(0.05, 0.1, 1.25, 1.0, 0.08, 8.0, "xz", False)
        segments = server.base.discover_segments(self.session_a, config)

        captured: dict[str, object] = {}

        class CapturingProjector:
            backend = "apple_metal"

            def project(self, **kwargs: object) -> list[tuple[float, float, float, float]]:
                captured.update(kwargs)
                width = int(kwargs["width"])
                height = int(kwargs["height"])
                step = int(kwargs["step"])
                count = ((width + step - 1) // step) * ((height + step - 1) // step)
                return [(0.0, 0.0, 8.0, 1.0)] * count

        cloud = server.base.extract_depth_point_cloud(
            segments,
            "xz",
            max_frames=1,
            pixel_step=3,
            max_points=100,
            depth_projector=CapturingProjector(),
        )
        self.assertEqual(tuple(captured["raw_transform"]), struct.unpack("<12f", optimized))
        self.assertAlmostEqual(float(captured["correction_dx"]), 0.0, places=5)
        self.assertAlmostEqual(float(captured["correction_dy"]), 0.0, places=5)
        self.assertAlmostEqual(float(captured["correction_yaw"]), 0.0, places=5)
        self.assertEqual(cloud["optimized_projection_pose_count"], 1)
        self.assertEqual(cloud["raw_projection_pose_count"], 0)

        cpu_cloud = server.base.extract_depth_point_cloud(
            segments,
            "xz",
            max_frames=1,
            pixel_step=3,
            max_points=100,
        )
        self.assertGreater(min(point[2] for point in cpu_cloud["points"]), 7.0)

    def test_gpu_capability_api_has_both_platform_backends(self) -> None:
        payload = self.api("/api/gpu/capabilities")
        self.assertIn("apple_metal", payload["backends"])
        self.assertIn("nvidia_cuda", payload["backends"])
        self.assertTrue(payload["backends"]["cpu"]["available"])

    def test_gpu_probe_rejects_helper_for_the_wrong_backend(self) -> None:
        helper = self.root / "wrong-gpu-helper"
        helper.write_bytes(b"protocol fixture")
        with (
            mock.patch.object(server.gpu, "find_helper", return_value=helper),
            mock.patch.object(
                server.gpu.subprocess,
                "run",
                return_value=SimpleNamespace(
                    returncode=0,
                    stdout=(
                        '{"available":true,"backend":"apple_metal",'
                        '"protocol":1}'
                    ),
                    stderr="",
                ),
            ),
        ):
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
        self.assertIn(b'id="shelf-preview-tab"', html)
        self.assertIn(b'id="shelf-completeness"', html)
        self.assertIn(b'id="shelf-min-orientation"', html)
        self.assertIn(b'id="shelf-min-observations"', html)
        self.assertIn(b'id="shelf-min-ground-observations"', html)
        self.assertIn(b'id="shelf-max-ground-conflict"', html)
        self.assertIn(b'id="shelf-fill-distance"', html)
        self.assertIn(b'id="shelf-ground-search"', html)
        self.assertIn(b'id="shelf-min-area"', html)
        self.assertIn(b'id="shelf-max-hole-area"', html)
        self.assertIn(b'id="shelf-free-margin"', html)
        self.assertIn(b'id="shelf-bridge-width"', html)
        self.assertIn(b'id="shelf-boundary-thickness"', html)
        self.assertNotIn(b'id="shelf-show-structures"', html)
        self.assertNotIn(b'id="shelf-min-line-support"', html)
        self.assertNotIn(b'id="shelf-duplicate-radius"', html)
        self.assertIn(b'data-shelf-preset="50"', html)
        self.assertIn(b'id="shelf-download"', html)
        self.assertIn("高级判定参数".encode("utf-8"), html)
        self.assertIn("彩色/3D 预览质量".encode("utf-8"), html)
        self.assertIn(b'<option value="maximum" selected>', html)
        self.assertIn(b"max-width: 1920px", css)
        self.assertIn(b".preview-panel:fullscreen", css)
        script, _ = self.fetch("/app.js")
        self.assertIn(b"SupermarketShelfOutlineEvidence", script)
        self.assertIn(b"renderShelfOutline", script)

    def test_map_studio_exposes_localized_stage_three_review_controls(self) -> None:
        html, _ = self.fetch("/")
        script, _ = self.fetch("/app.js")
        for marker in (
            b'data-mode="localized"',
            b'id="localized-prior-map"',
            b'id="localized-session"',
            b'id="run-localized"',
            b'id="localized-review-editor"',
            b'id="localized-review-canvas"',
            b'id="localized-tag-filter"',
            b'id="localized-shelf-filter"',
            b'id="localized-undo"',
            b'id="localized-redo"',
            b'id="localized-apply-edit"',
            b'id="localized-edit-reason"',
            b'id="localized-submit-review"',
            b'id="localized-publish"',
            b'id="localized-revoke"',
        ):
            self.assertIn(marker, html)
        self.assertIn(b'kind: "localized"', script)
        self.assertIn(b"/localized/edit", script)
        self.assertIn(b"publish_gate", script)
        self.assertIn(b"expected_revision", script)
        self.assertIn(b"expected_version_id", script)
        self.assertIn(b"/localized/state", script)
        self.assertIn(b"drawLocalizedReview", script)

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

    def test_residual_single_floor_vertical_shift_requires_review(self) -> None:
        source = self.root / "vertical-source.db"
        optimized = self.root / "vertical-optimized.db"
        raw_transforms = {
            node_id: transform_blob(node_id * 0.10, 0.0, node_id * 0.015)
            for node_id in range(1, 81)
        }
        optimized_transforms = {
            node_id: transform_blob(node_id * 0.10, 0.0, node_id * 0.010)
            for node_id in range(1, 81)
        }
        with closing(sqlite3.connect(source)) as conn, conn:
            conn.execute("CREATE TABLE Node (id INTEGER PRIMARY KEY, pose BLOB, stamp REAL)")
            conn.executemany(
                "INSERT INTO Node VALUES (?, ?, ?)",
                (
                    (node_id, raw_transforms[node_id], float(node_id))
                    for node_id in sorted(raw_transforms)
                ),
            )
        shutil.copy2(source, optimized)
        with closing(sqlite3.connect(optimized)) as conn, conn:
            conn.execute("CREATE TABLE Link (from_id INTEGER, to_id INTEGER, type INTEGER)")
            conn.executemany(
                "INSERT INTO Link VALUES (?, ?, 0)",
                ((node_id, node_id + 1) for node_id in range(1, 80)),
            )
            conn.execute("INSERT INTO Link VALUES (1, 80, 1)")
        add_optimized_poses(optimized, optimized_transforms)

        assessment = server.offline.assess_optimized_trajectory(source, optimized)
        self.assertEqual(assessment["status"], "warning")
        self.assertGreater(
            abs(assessment["optimized"]["vertical_endpoint_band_shift_m"]), 0.45
        )
        self.assertIn("translation_correction_p95_m", assessment["optimization_displacement"])
        self.assertTrue(
            any("start and end bands" in warning for warning in assessment["warnings"])
        )

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

    def test_pc_reprocess_rejects_incomplete_prior_map_write_health(self) -> None:
        session = create_session(
            self.root,
            "SupermarketSession-PriorMapEvidenceFailure",
            0.0,
            "continuous_streaming",
        )
        add_rgbd_frame(session)
        metadata_path = session / "segment_0001" / "metadata.json"
        metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
        metadata.update(
            {
                "workflowMode": "prior_map_localized",
                "captureHealth": {
                    "localizationRequiredWriteFailureCount": 1,
                    "localizationEvidenceComplete": False,
                },
                "processingEligibility": {
                    "status": "invalid",
                    "blockers": ["localization_required_sidecar_write_failed"],
                },
            }
        )
        metadata_path.write_text(json.dumps(metadata), encoding="utf-8")
        output = self.root / "prior-map-evidence-failure-output"
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
        self.assertIn("localization evidence is incomplete", result["error"])

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
        with mock.patch.object(
            server.offline.subprocess, "Popen", immediate_popen(fake_run)
        ):
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
        self.assertIn("shelf_outline.png", result["artifacts"])
        self.assertIn("shelf_outline_evidence.json", result["artifacts"])
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

    def test_local_grid_columns_require_an_actual_nonempty_blob(self) -> None:
        database = self.session_a / "segment_0001" / "rtabmap_segment_0001.db"
        with closing(sqlite3.connect(database)) as conn, conn:
            conn.execute(
                "CREATE TABLE Data (id INTEGER PRIMARY KEY, ground_cells BLOB, obstacle_cells BLOB, empty_cells BLOB)"
            )
            conn.execute("INSERT INTO Data VALUES (1, NULL, NULL, NULL)")
        _poses, has_grids, _warnings = server.base.extract_db_poses(database, 1, "xz")
        self.assertFalse(has_grids)

        with closing(sqlite3.connect(database)) as conn, conn:
            conn.execute("UPDATE Data SET ground_cells=? WHERE id=1", (b"grid",))
        _poses, has_grids, _warnings = server.base.extract_db_poses(database, 1, "xz")
        self.assertTrue(has_grids)

    def test_depth_png_and_calibration_create_point_cloud_preview(self) -> None:
        database = self.session_a / "segment_0001" / "rtabmap_segment_0001.db"
        with closing(sqlite3.connect(database)) as conn, conn:
            conn.execute("CREATE TABLE Data (id INTEGER PRIMARY KEY, depth BLOB, calibration BLOB, image BLOB)")
            conn.execute(
                "INSERT INTO Data VALUES (?, ?, ?, ?)",
                (1, depth_png(2, 2, [1.0, 1.02, 1.03, 1.04]), calibration_blob(2, 2), b"\xff\xd8test"),
            )
            conn.execute(
                "INSERT INTO Data VALUES (?, ?, ?, ?)",
                (2, depth_png(2, 2, [1.1, 1.12, 1.13, 1.14]), calibration_blob(2, 2), b"\xff\xd8test2"),
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
        self.assertEqual(preview["sampled_frames"], 1)
        self.assertEqual(preview["structure_sampled_frames"], 2)
        self.assertEqual(preview["structure_decoded_frames"], 2)
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

    def _legacy_vertical_height_span_creates_black_shelf_outline(self) -> None:
        vertical = server.base.vertical_triangle_sample(
            (0.0, 0.0, 0.0), (0.0, 0.0, 1.0), (0.0, 1.0, 0.0)
        )
        horizontal = server.base.vertical_triangle_sample(
            (0.0, 0.0, 0.0), (1.0, 0.0, 0.0), (0.0, 1.0, 0.0)
        )
        ground = server.base.horizontal_triangle_sample(
            (0.0, 0.0, 0.0), (1.0, 0.0, 0.0), (0.0, 1.0, 0.0)
        )
        self.assertIsNotNone(vertical)
        self.assertIsNone(horizontal)
        self.assertIsNotNone(ground)

        grid = server.base.OccupancyGrid(0.05, [(0.0, 0.0), (1.0, 1.0)], 0.1)
        evidence = [
            [x / 20.0, 0.5, 0.20, 1.80, 8, 0.01, 0.95]
            for x in range(4, 17)
        ]
        point_cloud = {
            "estimated_floor_height_m": 0.0,
            "vertical_surface_triangle_count": len(evidence) * 8,
            "_vertical_surface_evidence": evidence,
        }
        outline = server.base.build_shelf_outline(point_cloud, grid)
        self.assertEqual(len(outline.components), 1)
        self.assertGreaterEqual(len(outline.cells), 10)
        self.assertTrue(outline.evidence_cells)

        output = self.root / "shelf-outline.png"
        server.base.render_shelf_outline(grid, outline, output)
        width, height, _bit_depth, color_type, pixels = server.base.decode_png_pixels(output.read_bytes())
        self.assertEqual((width, height, color_type), (grid.width, grid.height, 2))
        black_pixels = sum(
            1 for index in range(0, len(pixels), 3)
            if pixels[index:index + 3] == bytes((12, 16, 18))
        )
        self.assertEqual(black_pixels, len(outline.cells))

        evidence_output = self.root / "shelf-outline-evidence.json"
        server.base.write_shelf_outline_evidence(evidence_output, grid, outline)
        payload = json.loads(evidence_output.read_text(encoding="utf-8"))
        self.assertEqual(payload["format"], "SupermarketShelfOutlineEvidence")
        self.assertEqual(payload["version"], 3)
        self.assertFalse(payload["has_orientation_evidence"])
        self.assertFalse(payload["has_ground_conflict_evidence"])
        self.assertEqual(payload["defaults"]["minimum_height_span_m"], 0.45)
        self.assertEqual(payload["defaults"]["minimum_orientation_coherence"], 0.45)
        self.assertEqual(payload["defaults"]["minimum_ground_observation_count"], 2)
        self.assertEqual(payload["defaults"]["maximum_ground_conflict_ratio"], 0.60)
        self.assertEqual(len(payload["evidence_cells"]), len(outline.evidence_cells))

        weak_point_cloud = {
            "estimated_floor_height_m": 0.0,
            "vertical_surface_triangle_count": 5,
            "_vertical_surface_evidence": [
                [0.20 + index * 0.10, 0.50, 0.10, 0.42, 1, 0.005, 0.50]
                for index in range(5)
            ],
        }
        strict_outline = server.base.build_shelf_outline(weak_point_cloud, grid)
        complete_outline = server.base.build_shelf_outline(
            weak_point_cloud,
            grid,
            minimum_height_span_m=0.20,
            minimum_height_above_floor_m=0.30,
            minimum_component_length_m=0.05,
            minimum_verticality=0.45,
            minimum_triangle_count=1,
            maximum_gap_cells=3,
        )
        self.assertFalse(strict_outline.cells)
        self.assertTrue(complete_outline.cells)

        oriented_evidence = []
        for y in (0.40, 0.90):
            oriented_evidence.extend(
                [x / 20.0, y, 0.10, 1.80, 10, 0.01, 0.95, 3, 1.0, 0.0, 1.0]
                for x in range(4, 29)
            )
        # A weaker duplicate ridge only 5 cm from the first physical face
        # should be suppressed instead of producing a third parallel edge.
        oriented_evidence.extend(
            [x / 20.0, 0.45, 0.10, 1.80, 3, 0.005, 0.90, 1, 1.0, 0.0, 1.0]
            for x in range(4, 29)
        )
        oriented_cloud = {
            "estimated_floor_height_m": 0.0,
            "vertical_surface_triangle_count": len(oriented_evidence) * 8,
            "_vertical_surface_evidence": oriented_evidence,
        }
        instance_grid = server.base.OccupancyGrid(0.05, [(0.0, 0.0), (2.0, 2.0)], 0.1)
        instance_outline = server.base.build_shelf_outline(oriented_cloud, instance_grid)
        self.assertEqual(instance_outline.instance_count, 0)
        self.assertEqual(instance_outline.line_candidate_count, 2)
        self.assertEqual(len(instance_outline.components), 2)
        self.assertGreater(len(instance_outline.cells), 40)
        self.assertTrue(instance_outline.shelf_cells)
        self.assertFalse(instance_outline.vertical_structure_cells)
        # Parallel measured faces remain two open lines. The algorithm must
        # never add the artificial end caps that previously formed rectangles.
        self.assertNotIn(instance_grid.cell(0.20, 0.65), instance_outline.cells)
        self.assertNotIn(instance_grid.cell(1.40, 0.65), instance_outline.cells)

        sparse_fragments = [
            [x / 20.0, 1.70, 0.10, 1.80, 10, 0.01, 0.95, 3, 1.0, 0.0, 1.0]
            for x in (4, 5, 6, 31, 32, 33)
        ]
        sparse_outline = server.base.build_shelf_outline(
            {
                "estimated_floor_height_m": 0.0,
                "vertical_surface_triangle_count": len(sparse_fragments) * 8,
                "_vertical_surface_evidence": sparse_fragments,
            },
            instance_grid,
        )
        self.assertFalse(sparse_outline.cells)

        # Ground is a conflict signal, never a prerequisite. A one-frame
        # vertical trace survives where no floor was observed, but the same
        # sparse trace is rejected where the floor was seen in four frames.
        transient_vertical = [
            [x / 20.0, 1.40, 0.10, 1.80, 8, 0.01, 0.95, 1, 1.0, 0.0, 1.0]
            for x in range(4, 21)
        ]
        transient_ground = [
            [x / 20.0, 1.40, 0.0, 8, 0.01, 4, 0.98]
            for x in range(4, 21)
        ]
        no_ground_outline = server.base.build_shelf_outline(
            {
                "estimated_floor_height_m": 0.0,
                "vertical_surface_triangle_count": len(transient_vertical) * 8,
                "_vertical_surface_evidence": transient_vertical,
            },
            instance_grid,
        )
        self.assertTrue(no_ground_outline.cells)
        self.assertTrue(no_ground_outline.shelf_cells)
        self.assertFalse(no_ground_outline.vertical_structure_cells)
        conflict_outline = server.base.build_shelf_outline(
            {
                "estimated_floor_height_m": 0.0,
                "vertical_surface_triangle_count": len(transient_vertical) * 8,
                "_vertical_surface_evidence": transient_vertical,
                "_horizontal_surface_evidence": transient_ground,
            },
            instance_grid,
        )
        self.assertFalse(conflict_outline.cells)
        self.assertGreater(conflict_outline.ground_conflict_rejected_count, 0)

        persistent_vertical = [row[:7] + [3, 1.0, 0.0, 1.0] for row in transient_vertical]
        persistent_outline = server.base.build_shelf_outline(
            {
                "estimated_floor_height_m": 0.0,
                "vertical_surface_triangle_count": len(persistent_vertical) * 8,
                "_vertical_surface_evidence": persistent_vertical,
                "_horizontal_surface_evidence": [
                    [x / 20.0, 1.40, 0.0, 8, 0.01, 2, 0.98]
                    for x in range(4, 21)
                ],
            },
            instance_grid,
        )
        self.assertTrue(persistent_outline.cells)

    def test_floor_gap_and_surface_evidence_create_closed_shelf_contour(self) -> None:
        vertical = server.base.vertical_triangle_sample(
            (0.0, 0.0, 0.0), (0.0, 0.0, 1.0), (0.0, 1.0, 0.0)
        )
        horizontal = server.base.vertical_triangle_sample(
            (0.0, 0.0, 0.0), (1.0, 0.0, 0.0), (0.0, 1.0, 0.0)
        )
        ground_triangle = server.base.horizontal_triangle_sample(
            (0.0, 0.0, 0.0), (1.0, 0.0, 0.0), (0.0, 1.0, 0.0)
        )
        self.assertIsNotNone(vertical)
        self.assertIsNone(horizontal)
        self.assertIsNotNone(ground_triangle)

        resolution = 0.05
        grid = server.base.OccupancyGrid(resolution, [(0.0, 0.0), (2.0, 2.0)], 0.1)
        shelf_x = [index * resolution for index in range(6, 35)]
        vertical_evidence = [
            [x, y, 0.10, 1.80, 8, 0.01, 0.95, 3, 1.0, 0.0, 1.0]
            for y in (0.80, 1.20)
            for x in shelf_x
        ]
        ground_evidence = [
            [x, y, 0.0, 8, 0.01, 4, 0.98]
            for y in (0.55, 1.45)
            for x in shelf_x
        ]
        elevated_evidence = [
            [x, y, 0.85, 6, 0.008, 3, 0.98]
            for y in (0.90, 1.00, 1.10)
            for x in shelf_x[2:-2:2]
        ]
        cloud = {
            "estimated_floor_height_m": 0.0,
            "vertical_surface_triangle_count": len(vertical_evidence) * 8,
            "_vertical_surface_evidence": vertical_evidence,
            "_horizontal_surface_evidence": ground_evidence + elevated_evidence,
        }
        outline = server.base.build_shelf_outline(
            cloud,
            grid,
            minimum_region_area_m2=0.10,
            maximum_fill_distance_m=0.50,
            maximum_hole_area_m2=0.30,
        )
        self.assertEqual(outline.line_candidate_count, 0)
        self.assertEqual(outline.instance_count, 1)
        self.assertEqual(outline.closed_contour_count, 1)
        self.assertEqual(len(outline.components), 1)
        self.assertGreater(len(outline.shelf_cells), len(outline.cells))
        self.assertIn(grid.cell(1.0, 1.0), outline.shelf_cells)
        self.assertNotIn(grid.cell(1.0, 1.0), outline.cells)
        self.assertNotIn(grid.cell(1.0, 0.55), outline.cells)
        self.assertGreater(outline.summary(resolution)["area_m2"], 0.5)
        for cell in outline.components[0]:
            x, y = cell
            adjacent = sum(
                (nx, ny) in outline.cells
                for ny in range(y - 1, y + 2)
                for nx in range(x - 1, x + 2)
                if (nx, ny) != cell
            )
            self.assertGreaterEqual(adjacent, 2)

        output = self.root / "shelf-regions.png"
        server.base.render_shelf_outline(grid, outline, output)
        width, height, _bit_depth, color_type, pixels = server.base.decode_png_pixels(output.read_bytes())
        self.assertEqual((width, height, color_type), (grid.width, grid.height, 2))
        black_pixels = sum(
            1 for index in range(0, len(pixels), 3)
            if pixels[index:index + 3] == bytes((12, 16, 18))
        )
        self.assertEqual(black_pixels, len(outline.cells))

        evidence_output = self.root / "shelf-region-evidence.json"
        server.base.write_shelf_outline_evidence(evidence_output, grid, outline)
        payload = json.loads(evidence_output.read_text(encoding="utf-8"))
        self.assertEqual(payload["format"], "SupermarketShelfOutlineEvidence")
        self.assertEqual(payload["version"], 6)
        self.assertTrue(payload["ground_runs"])
        self.assertTrue(payload["elevated_runs"])
        self.assertTrue(payload["stable_elevated_runs"])
        self.assertTrue(payload["elevated_observation_cells"])
        self.assertIn("free_space_runs", payload)
        self.assertEqual(payload["defaults"]["minimum_observation_count"], 2)
        self.assertEqual(payload["defaults"]["maximum_bridge_width_m"], 0.50)
        self.assertEqual(payload["source_frames"]["sampled"], 0)
        self.assertEqual(payload["defaults"]["boundary_thickness_cells"], 2)
        self.assertEqual(payload["defaults"]["minimum_region_area_m2"], 0.10)

    def test_shelf_regions_reject_floor_conflicts_and_unknown_space(self) -> None:
        resolution = 0.05
        grid = server.base.OccupancyGrid(resolution, [(0.0, 0.0), (2.0, 2.0)], 0.1)
        xs = [index * resolution for index in range(6, 35)]
        transient_vertical = [
            [x, 1.0, 0.10, 1.80, 8, 0.01, 0.95, 1, 1.0, 0.0, 1.0]
            for x in xs
        ]
        same_cell_ground = [
            [x, 1.0, 0.0, 8, 0.01, 4, 0.98]
            for x in xs
        ]
        person_cloud = {
            "estimated_floor_height_m": 0.0,
            "vertical_surface_triangle_count": len(transient_vertical) * 8,
            "_vertical_surface_evidence": transient_vertical,
            "_horizontal_surface_evidence": same_cell_ground,
        }
        person_outline = server.base.build_shelf_outline(
            person_cloud, grid, minimum_region_area_m2=0.05
        )
        self.assertFalse(person_outline.cells)
        self.assertGreater(person_outline.ground_conflict_rejected_count, 0)

        # Vertical evidence without floor observations on two opposite sides
        # is unknown space, not a licence to invent a shelf footprint.
        unknown_outline = server.base.build_shelf_outline(
            {
                "estimated_floor_height_m": 0.0,
                "vertical_surface_triangle_count": len(transient_vertical) * 8,
                "_vertical_surface_evidence": transient_vertical,
            },
            grid,
            minimum_region_area_m2=0.05,
        )
        self.assertFalse(unknown_outline.cells)

        one_sided_floor = [
            [x, 0.70, 0.0, 8, 0.01, 4, 0.98]
            for x in xs
        ]
        one_sided_outline = server.base.build_shelf_outline(
            {
                "estimated_floor_height_m": 0.0,
                "vertical_surface_triangle_count": len(transient_vertical) * 8,
                "_vertical_surface_evidence": transient_vertical,
                "_horizontal_surface_evidence": one_sided_floor,
            },
            grid,
            minimum_region_area_m2=0.05,
        )
        self.assertFalse(one_sided_outline.cells)

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


class PersistentJobRuntimeTests(unittest.TestCase):
    def test_killed_runtime_process_recovers_job_as_interrupted(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            journals = root / "journals"
            marker = root / "running-job-id.txt"
            child_script = "\n".join((
                "import sys, time",
                "from pathlib import Path",
                "sys.path.insert(0, sys.argv[1])",
                "import server",
                "state = server.StudioState(Path(sys.argv[2]))",
                "job = state.add('map', Path(sys.argv[3]), (sys.argv[4],))",
                "state.set_status(job.identifier, 'running')",
                "Path(sys.argv[5]).write_text(job.identifier, encoding='utf-8')",
                "time.sleep(60)",
            ))
            process = subprocess.Popen([
                sys.executable,
                "-c",
                child_script,
                str(STUDIO_DIR),
                str(journals),
                str(root / "output"),
                str(root / "input.db"),
                str(marker),
            ])
            try:
                deadline = time.time() + 10
                while time.time() < deadline and not marker.is_file():
                    if process.poll() is not None:
                        self.fail(f"runtime fixture exited early: {process.returncode}")
                    time.sleep(0.02)
                self.assertTrue(marker.is_file())
                job_id = marker.read_text(encoding="utf-8")
                process.kill()
                process.wait(timeout=10)

                restarted = server.StudioState(journals)
                restored = restarted.get(job_id)
                self.assertIsNotNone(restored)
                assert restored is not None
                self.assertEqual(restored.status, "interrupted")
                self.assertIn("restarted", restored.error or "")
                self.assertFalse((root / "output").exists())
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait(timeout=10)

    def test_cancellation_stops_reprocess_child_and_preserves_runtime_log(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            session = create_session(
                root,
                "SupermarketSession-Cancel",
                0.0,
                "continuous_streaming",
            )
            add_rgbd_frame(session)
            database = session / "segment_0001" / "rtabmap_segment_0001.db"
            original = database.read_bytes()
            fixture_script = root / "synthetic_reprocess.py"
            fixture_script.write_text(
                "from pathlib import Path\n"
                "import time\n"
                "Path('child.pid').write_text('started', encoding='utf-8')\n"
                "print('synthetic child started', flush=True)\n"
                "time.sleep(60)\n",
                encoding="utf-8",
            )
            cancellation = threading.Event()
            runtime_log = root / "runtime.log"
            failures: list[BaseException] = []

            def invoke() -> None:
                try:
                    server.offline.run_reprocess(
                        database,
                        root / "optimized.db",
                        explicit_binary=sys.executable,
                        use_local_staging=False,
                        cancel_event=cancellation,
                        persistent_log_path=runtime_log,
                    )
                except BaseException as exc:  # captured for the test thread
                    failures.append(exc)

            with mock.patch.object(
                server.offline,
                "_command",
                return_value=[sys.executable, str(fixture_script)],
            ):
                worker = threading.Thread(target=invoke)
                worker.start()
                try:
                    deadline = time.time() + 5
                    while time.time() < deadline and not (root / "child.pid").is_file():
                        time.sleep(0.02)
                    self.assertTrue((root / "child.pid").is_file())
                finally:
                    cancellation.set()
                    worker.join(timeout=8)

            self.assertFalse(worker.is_alive())
            self.assertEqual(len(failures), 1)
            self.assertIsInstance(failures[0], server.offline.OfflineProcessingError)
            self.assertIn("cancelled", str(failures[0]))
            self.assertIn("synthetic child started", runtime_log.read_text(encoding="utf-8"))
            self.assertFalse((root / "optimized.db").exists())
            self.assertEqual(database.read_bytes(), original)

    def test_restart_marks_active_job_interrupted_and_preserves_history(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            output = root / "output"
            first = server.StudioState(root / "journals")
            job = first.add("map", output, (str(root / "input.db"),))
            first.set_status(job.identifier, "running")
            first.update_progress(job.identifier, 42, "优化中", "subprocess active")

            restarted = server.StudioState(root / "journals")
            restored = restarted.get(job.identifier)
            self.assertIsNotNone(restored)
            assert restored is not None
            self.assertEqual(restored.status, "interrupted")
            self.assertEqual(restored.progress, 42)
            self.assertIn("restarted", restored.error or "")
            self.assertEqual(restored.tool_version, server.JOB_RUNTIME_TOOL_VERSION)
            self.assertEqual(len(restored.input_identities), 1)
            self.assertRegex(
                restored.input_identities[0]["identity_sha256"], r"^[0-9a-f]{64}$"
            )
            self.assertFalse(output.exists())

    def test_completed_job_remains_visible_after_restart(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            state = server.StudioState(root / "journals")
            job = state.add("map", root / "output")
            state.set_status(job.identifier, "running")
            state.set_status(job.identifier, "complete")

            restarted = server.StudioState(root / "journals")
            restored = restarted.get(job.identifier)
            self.assertIsNotNone(restored)
            assert restored is not None
            self.assertEqual(restored.status, "complete")
            self.assertEqual(restored.progress, 100)

    def test_cancel_is_persisted_and_signals_worker(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            state = server.StudioState(Path(temporary) / "journals")
            job = state.add("map", Path(temporary) / "output")
            state.set_status(job.identifier, "running")
            cancelled = state.cancel(job.identifier)
            self.assertTrue(cancelled.cancel_event.is_set())
            self.assertEqual(cancelled.status, "cancelling")
            restarted = server.StudioState(Path(temporary) / "journals")
            self.assertEqual(restarted.get(job.identifier).status, "interrupted")

    def test_cancel_before_worker_start_wins_atomic_begin_race(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            state = server.StudioState(Path(temporary) / "journals")
            job = state.add("map", Path(temporary) / "output")
            state.cancel(job.identifier)
            self.assertFalse(state.begin(job.identifier))
            self.assertEqual(state.get(job.identifier).status, "cancelling")

    def test_corrupt_journal_fails_closed_without_path_cleanup(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            journals = root / "journals"
            journals.mkdir()
            protected = root / "must-remain"
            protected.mkdir()
            (protected / "data").write_text("safe", encoding="utf-8")
            (journals / "bad.json").write_text(
                json.dumps({"output_dir": str(protected), "status": "running"}),
                encoding="utf-8",
            )
            state = server.StudioState(journals)
            self.assertTrue(state.startup_errors)
            self.assertTrue((protected / "data").is_file())
            self.assertEqual(state.list(), [])


if __name__ == "__main__":
    unittest.main()
