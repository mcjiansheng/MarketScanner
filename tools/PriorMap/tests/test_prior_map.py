from __future__ import annotations

import json
import math
import os
import shutil
import subprocess
import tempfile
import unittest
import zipfile
from pathlib import Path

from tools.PriorMap.coordinate_system import (
    source_point_to_map,
    source_rectangle_polygon,
    source_rotation_to_yaw,
)
from tools.PriorMap.distance_field import decode_level
from tools.PriorMap.prior_map_schema import validate_package
from tools.PriorMap.replay_localization import replay
from tools.PriorMap.replay_stage2 import (
    Pose as Stage2Pose,
    match as stage2_match,
    replay as replay_stage2,
)
from tools.PriorMap.spatial_index import PriorMapSpatialIndex
from tools.PriorMap.stage1_localizer import Pose2D, StageOneLocalizer
from tools.PriorMap.xlsx_to_prior_map import _polyline_abscissa, convert_workbook


def write_workbook(path: Path, rows: list[tuple[str, str]]) -> None:
    strings = ["floor", "element"]
    for floor, element in rows:
        strings.extend((floor, element))
    shared = "".join(f"<si><t>{value.replace('&', '&amp;').replace('<', '&lt;')}</t></si>" for value in strings)
    row_xml = [
        '<row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c></row>'
    ]
    for index, _row in enumerate(rows, start=2):
        string_index = 2 + (index - 2) * 2
        row_xml.append(
            f'<row r="{index}"><c r="A{index}" t="s"><v>{string_index}</v></c>'
            f'<c r="B{index}" t="s"><v>{string_index + 1}</v></c></row>'
        )
    with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        archive.writestr(
            "[Content_Types].xml",
            '<?xml version="1.0"?>'
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
            '<?xml version="1.0"?>'
            '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
            '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>'
            "</Relationships>",
        )
        archive.writestr(
            "xl/workbook.xml",
            '<?xml version="1.0"?>'
            '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" '
            'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
            '<sheets><sheet name="Element Info" sheetId="1" r:id="rId1"/></sheets></workbook>',
        )
        archive.writestr(
            "xl/_rels/workbook.xml.rels",
            '<?xml version="1.0"?>'
            '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
            '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>'
            "</Relationships>",
        )
        archive.writestr(
            "xl/sharedStrings.xml",
            f'<?xml version="1.0"?><sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="{len(strings)}" uniqueCount="{len(strings)}">{shared}</sst>',
        )
        archive.writestr(
            "xl/worksheets/sheet1.xml",
            '<?xml version="1.0"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
            f"<sheetData>{''.join(row_xml)}</sheetData></worksheet>",
        )


def fixture_rows() -> list[tuple[str, str]]:
    values = [
        (
            "1",
            {
                "shapeType": "MapShelf",
                "x": 100,
                "y": 200,
                "width": 300,
                "height": 100,
                "rotation": 90,
                "code": "S1",
                "crossCode": 7,
                "rowFlag": "R1",
                "subsection": 2,
                "visible": True,
            },
        ),
        (
            "1",
            {
                "shapeType": "MapTable",
                "x": 500,
                "y": 200,
                "width": 100,
                "height": 100,
                "rotation": 0,
                "code": "T1",
                "visible": False,
            },
        ),
        (
            "1",
            {
                "shapeType": "MapPillar",
                "x": 700,
                "y": 200,
                "width": 50,
                "height": 50,
                "rotation": 0,
                "code": "P1",
                "visible": True,
            },
        ),
        (
            "1",
            {
                "shapeType": "MapTableFeature",
                "x": 800,
                "y": 200,
                "width": 100,
                "height": 40,
                "rotation": 180,
                "code": "F1",
                "visible": True,
            },
        ),
        (
            "1",
            {
                "shapeType": "MapCross",
                "points": [0, 500, 1000, 500],
                "lineWidth": 200,
                "code": "C1",
                "visible": True,
            },
        ),
        (
            "1",
            {
                "shapeType": "MapRoadPoint",
                "x": 100,
                "y": 500,
                "width": 20,
                "height": 20,
                "code": 1,
                "crossCodes": ["C1"],
                "visible": True,
            },
        ),
        (
            "1",
            {
                "shapeType": "MapRoadPoint",
                "x": 900,
                "y": 500,
                "width": 20,
                "height": 20,
                "code": "2",
                "crossCodes": ["C1", "MISSING"],
                "visible": True,
            },
        ),
        (
            "2",
            {
                "shapeType": "FutureShape",
                "x": 1,
                "y": 2,
                "visible": True,
                "code": "future",
            },
        ),
    ]
    rows = [(floor, json.dumps(value, ensure_ascii=False)) for floor, value in values]
    rows.append(("2", "{bad json"))
    return rows


class CoordinateSystemTests(unittest.TestCase):
    def test_source_coordinates_and_rotation_have_one_defined_conversion(self) -> None:
        self.assertEqual(source_point_to_map(250, 300), (2.5, -3.0))
        self.assertAlmostEqual(source_rotation_to_yaw(90), -math.pi / 2)
        polygon = source_rectangle_polygon(100, 200, 300, 100, 90)
        self.assertEqual(
            {(round(point[0], 2), round(point[1], 2)) for point in polygon},
            {(2.0, -1.0), (3.0, -1.0), (3.0, -4.0), (2.0, -4.0)},
        )


class IOSCoreContractTests(unittest.TestCase):
    def test_swift_workflow_state_and_se2_projection(self) -> None:
        xcrun = shutil.which("xcrun")
        if xcrun is None:
            self.skipTest("xcrun is unavailable outside the macOS iOS build environment")
        repository = Path(__file__).resolve().parents[3]
        swift_sources = [
            repository / "app/ios/RTABMapApp/PriorMapLocalizationCore.swift",
            repository / "app/ios/RTABMapApp/PriorMapScanMatcher.swift",
            repository / "app/ios/RTABMapApp/PriceTagLocalizationCore.swift",
            repository / "app/ios/RTABMapApp/PriorMapPackageIntegrityCore.swift",
        ]
        swift_test = Path(__file__).with_name("swift") / "main.swift"
        with tempfile.TemporaryDirectory() as temporary:
            executable = Path(temporary) / "prior-map-core-tests"
            environment = os.environ.copy()
            environment["CLANG_MODULE_CACHE_PATH"] = str(Path(temporary) / "clang-cache")
            environment["SWIFT_MODULECACHE_PATH"] = str(Path(temporary) / "swift-cache")
            compile_result = subprocess.run(
                [
                    xcrun,
                    "swiftc",
                    *map(str, swift_sources),
                    str(swift_test),
                    "-o",
                    str(executable),
                ],
                check=False,
                capture_output=True,
                text=True,
                env=environment,
            )
            self.assertEqual(compile_result.returncode, 0, compile_result.stderr)
            run_result = subprocess.run(
                [str(executable)],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(run_result.returncode, 0, run_result.stderr)
            self.assertIn("Swift tests passed", run_result.stdout)
            workbook = Path(temporary) / "integrity.xlsx"
            write_workbook(workbook, fixture_rows())
            package = convert_workbook(workbook, Path(temporary) / "package")
            valid_result = subprocess.run(
                [str(executable), str(package)],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(valid_result.returncode, 0, valid_result.stderr)

            mutations = {
                "swapped-shelves": lambda root: (
                    (root / "shelves.json").write_bytes(
                        (root / "fixed_structures.json").read_bytes()
                    )
                ),
                "tampered-bounds": lambda root: self._rewrite_integrity_json(
                    root / "manifest.json",
                    lambda value: value["bounds"].__setitem__("max_x_m", 999),
                ),
                "broken-road-reference": lambda root: self._rewrite_integrity_json(
                    root / "road_graph.json",
                    lambda value: value["edges"][0].__setitem__("to", "missing"),
                ),
                "mixed-preview": lambda root: (
                    (root / "preview.png").write_bytes(
                        next(root.glob("preview_floor_*.png")).read_bytes() + b"mixed"
                    )
                ),
                "mixed-distance-field": lambda root: self._rewrite_integrity_json(
                    root / "distance_fields.json",
                    lambda value: value["floors"].pop(next(iter(value["floors"]))),
                ),
                "invalid-report": lambda root: self._rewrite_integrity_json(
                    root / "validation_report.json",
                    lambda value: value.__setitem__("valid", False),
                ),
            }
            for name, mutate in mutations.items():
                with self.subTest(swift_integrity=name):
                    corrupted = Path(temporary) / name
                    shutil.copytree(package, corrupted)
                    mutate(corrupted)
                    invalid_result = subprocess.run(
                        [str(executable), str(corrupted)],
                        check=False,
                        capture_output=True,
                        text=True,
                    )
                    self.assertNotEqual(invalid_result.returncode, 0)

    @staticmethod
    def _rewrite_integrity_json(path: Path, mutate: object) -> None:
        value = json.loads(path.read_text(encoding="utf-8"))
        mutate(value)
        path.write_text(
            json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )


class PriorMapConversionTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.workbook = self.root / "fixture.xlsx"
        write_workbook(self.workbook, fixture_rows())

    def tearDown(self) -> None:
        self.temp.cleanup()

    def test_road_node_order_uses_full_l_shaped_polyline_abscissa(self) -> None:
        road = [(0.0, 0.0), (0.0, 10.0), (10.0, 10.0)]
        before_corner = _polyline_abscissa((0.0, 9.0), road)
        after_corner = _polyline_abscissa((1.0, 10.0), road)
        self.assertAlmostEqual(before_corner, 9.0)
        self.assertAlmostEqual(after_corner, 11.0)
        self.assertLess(before_corner, after_corner)

    def corrupted_package(self, source: Path, name: str) -> Path:
        destination = self.root / name
        shutil.copytree(source, destination)
        return destination

    @staticmethod
    def rewrite_json(path: Path, mutate: object) -> None:
        value = json.loads(path.read_text(encoding="utf-8"))
        mutate(value)
        path.write_text(
            json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )

    def test_conversion_preserves_supported_unknown_hidden_and_business_fields(self) -> None:
        package = convert_workbook(self.workbook, self.root / "package")
        manifest = json.loads((package / "manifest.json").read_text())
        elements = json.loads((package / "elements.json").read_text())["elements"]
        report = json.loads(
            (package / "validation_report.json").read_text(encoding="utf-8")
        )
        self.assertEqual(manifest["element_count"], 8)
        self.assertEqual(manifest["hidden_element_count"], 1)
        self.assertEqual([floor["id"] for floor in manifest["floors"]], ["1"])
        shelf = next(item for item in elements if item["code"] == "S1")
        self.assertEqual(shelf["cross_code"], "7")
        self.assertEqual(shelf["row_flag"], "R1")
        self.assertEqual(shelf["subsection"], 2)
        unknown = next(item for item in elements if item["shape_type"] == "FutureShape")
        self.assertIsNone(unknown["geometry"])
        self.assertEqual(report["summary"]["malformed_row_count"], 1)
        warning_codes = {item["code"] for item in report["warnings"]}
        self.assertIn("unknown_shape_type", warning_codes)
        self.assertIn("hidden_element", warning_codes)
        self.assertIn("missing_cross", warning_codes)
        self.assertTrue(validate_package(package)["valid"])
        self.assertTrue((package / "preview.png").read_bytes().startswith(b"\x89PNG\r\n\x1a\n"))

    def test_distance_fields_are_decodable_bounded_and_integrity_checked(self) -> None:
        package = convert_workbook(self.workbook, self.root / "package")
        payload = json.loads((package / "distance_fields.json").read_text())
        self.assertEqual(payload["format"], "MarketScannerDistanceFields")
        self.assertEqual(
            [level["resolution_m"] for level in payload["floors"]["1"]["levels"]],
            [0.4, 0.2, 0.1],
        )
        for level in payload["floors"]["1"]["levels"]:
            values = decode_level(level)
            self.assertEqual(len(values), level["width"] * level["height"])
            self.assertIn(0, values)
            self.assertLessEqual(max(values), 200)

        corrupted = self.corrupted_package(package, "bad-distance-checksum")
        self.rewrite_json(
            corrupted / "distance_fields.json",
            lambda value: value["floors"]["1"]["levels"][0].__setitem__(
                "data_sha256", "0" * 64
            ),
        )
        self.assertFalse(validate_package(corrupted)["valid"])

    def test_road_graph_normalizes_numeric_ids_and_spatial_query_is_bounded(self) -> None:
        package = convert_workbook(self.workbook, self.root / "package")
        graph = json.loads((package / "road_graph.json").read_text())
        self.assertEqual({node["id"] for node in graph["nodes"]}, {"1", "2"})
        self.assertEqual(len(graph["edges"]), 1)
        index = PriorMapSpatialIndex.load(package)
        identifiers = index.query_ids("1", 2.5, -2.5, 1.0)
        self.assertIn("f1-r2", identifiers)
        self.assertNotIn("f1-r3", identifiers)
        self.assertEqual(index.query_road_edge_ids("1", 5.0, -5.0, 0.5), ["1:1--2"])

    def test_spatial_road_query_does_not_scan_a_large_index(self) -> None:
        road_cells = {
            f"{cell_x},{cell_y}": [f"edge-{cell_x}-{cell_y}"]
            for cell_x in range(100)
            for cell_y in range(100)
        }
        index = PriorMapSpatialIndex(5.0, {}, {"1": road_cells}, {})
        nearby = index.query_road_edge_ids("1", 252.0, 252.0, 1.0)
        self.assertEqual(nearby, ["edge-50-50"])
        self.assertLess(len(nearby), len(road_cells) // 100)

    def test_validator_rejects_corrupt_or_cross_file_inconsistent_packages(self) -> None:
        package = convert_workbook(self.workbook, self.root / "package")
        cases: list[tuple[str, str, object]] = [
            (
                "bad-hash",
                "manifest.json",
                lambda value: value.__setitem__("source_sha256", "not-a-sha"),
            ),
            (
                "bad-count",
                "manifest.json",
                lambda value: value.__setitem__("element_count", 999),
            ),
            (
                "bad-bounds",
                "manifest.json",
                lambda value: value["floors"][0]["bounds"].__setitem__("max_x_m", 999),
            ),
            (
                "bad-shelves",
                "shelves.json",
                lambda value: value.__setitem__("shelves", []),
            ),
            (
                "bad-road",
                "road_graph.json",
                lambda value: value["edges"][0].__setitem__("to", "missing"),
            ),
            (
                "bad-spatial-road",
                "spatial_index.json",
                lambda value: value["floors"]["1"]["road_cells"].__setitem__(
                    "0,0", ["missing-edge"]
                ),
            ),
            (
                "bad-report",
                "validation_report.json",
                lambda value: value["summary"].__setitem__("floor_count", 99),
            ),
        ]
        for name, filename, mutate in cases:
            with self.subTest(name=name):
                corrupted = self.corrupted_package(package, name)
                self.rewrite_json(corrupted / filename, mutate)
                self.assertFalse(validate_package(corrupted)["valid"])

        invalid_json = self.corrupted_package(package, "invalid-json")
        (invalid_json / "fixed_structures.json").write_text("{", encoding="utf-8")
        self.assertFalse(validate_package(invalid_json)["valid"])

        invalid_png = self.corrupted_package(package, "invalid-png")
        (invalid_png / "preview.png").write_bytes(b"\x89PNG\r\n\x1a\ntruncated")
        self.assertFalse(validate_package(invalid_png)["valid"])

    def test_conversion_is_reproducible(self) -> None:
        first = convert_workbook(self.workbook, self.root / "first")
        second = convert_workbook(self.workbook, self.root / "second")
        for name in (
            "package_manifest.json",
            "manifest.json",
            "elements.json",
            "shelves.json",
            "fixed_structures.json",
            "road_graph.json",
            "spatial_index.json",
            "distance_fields.json",
            "preview.png",
            "validation_report.json",
        ):
            self.assertEqual((first / name).read_bytes(), (second / name).read_bytes(), name)

    def test_replay_checks_error_road_assignment_and_tracking_state(self) -> None:
        package = convert_workbook(self.workbook, self.root / "package")
        report = replay(
            package,
            self.root / "replay",
            floor_id="1",
            translation_drift_per_m=0.01,
            rotation_drift_deg_per_m=0.05,
            noise_std_m=0.01,
            tracking_loss_start=2,
            tracking_loss_length=2,
            seed=24,
        )
        self.assertGreater(report["summary"]["sample_count"], 2)
        self.assertGreaterEqual(report["summary"]["state_counts"]["lost"], 2)
        self.assertTrue(any(item["road_assignment"] for item in report["samples"]))
        self.assertGreaterEqual(report["summary"]["maximum_error_m"], 0.0)
        self.assertGreater(report["summary"]["maximum_yaw_error_deg"], 0.0)

    def test_rotation_drift_changes_xy_and_reports_yaw_error(self) -> None:
        package = convert_workbook(self.workbook, self.root / "package")
        baseline = replay(package, self.root / "baseline", floor_id="1", seed=12)
        rotated = replay(
            package,
            self.root / "rotated",
            floor_id="1",
            rotation_drift_deg_per_m=3.0,
            seed=12,
        )
        self.assertEqual(baseline["summary"]["maximum_yaw_error_deg"], 0.0)
        self.assertGreater(rotated["summary"]["maximum_yaw_error_deg"], 0.0)
        self.assertGreater(
            rotated["summary"]["maximum_error_m"],
            baseline["summary"]["maximum_error_m"],
        )
        self.assertNotEqual(
            rotated["samples"][-1]["estimated_pose"],
            baseline["samples"][-1]["estimated_pose"],
        )

    def test_stage_two_replay_improves_drift_and_rejects_wrong_initialization(self) -> None:
        package = convert_workbook(self.workbook, self.root / "package")
        report = replay_stage2(
            package,
            self.root / "stage2-replay",
            seed=24,
            dynamic_fraction=0.2,
        )
        summary = report["summary"]
        self.assertGreater(summary["accepted_count"], 0)
        self.assertLess(
            summary["median_estimated_error_m"],
            summary["median_predicted_error_m"],
        )
        self.assertGreater(summary["matcher_p95_ms"], 0)
        self.assertGreater(summary["single_frame_geometry_candidate_count"], 0)
        self.assertLess(summary["p95_estimated_yaw_error_deg"], 8)
        self.assertEqual(summary["catastrophic_jump_count"], 0)
        self.assertTrue((self.root / "stage2-replay/stage2_replay_report.json").is_file())

        wrong = replay_stage2(
            package,
            seed=24,
            dynamic_fraction=0.2,
            wrong_initial_offset_m=3.0,
        )
        self.assertEqual(wrong["summary"]["accepted_count"], 0)

        recovered = replay_stage2(
            package,
            seed=24,
            dynamic_fraction=0.2,
            tracking_loss_indices={8, 9},
        )
        self.assertEqual(recovered["samples"][8]["state"], "lost")
        self.assertEqual(recovered["samples"][9]["state"], "lost")
        self.assertIsNotNone(recovered["summary"]["tracking_recovery_frames"])
        self.assertGreaterEqual(recovered["summary"]["tracking_recovery_frames"], 2)

    def test_stage_two_periodic_structure_cannot_claim_uniqueness(self) -> None:
        points = [(0.0, -1.5 + index * 3.0 / 79.0) for index in range(80)]
        for name, separation in (
            ("near_candidates", 0.4),
            ("identical_shelf_ends", 0.6),
            ("parallel_periodic_aisles", 0.8),
            ("symmetric_pillar_rows", 1.2),
        ):
            with self.subTest(name=name):
                class PeriodicLevel:
                    truncation_m = 2.55

                    @staticmethod
                    def distance(x: float, _y: float) -> float:
                        return min(abs(x), abs(x - separation), 2.55)

                result = stage2_match(
                    Stage2Pose(separation / 2, 0, 0),
                    points,
                    [PeriodicLevel(), PeriodicLevel(), PeriodicLevel()],
                )
                self.assertFalse(result["accepted"])
                self.assertEqual(result["reason"], "ambiguous_structure_match")
                self.assertLess(result["uniqueness"], 0.10)


class StageOneLocalizerTests(unittest.TestCase):
    @staticmethod
    def single_road_graph() -> dict[str, object]:
        return {
            "nodes": [
                {"id": "a", "floor_id": "1", "position_m": [0, 0]},
                {"id": "b", "floor_id": "1", "position_m": [10, 0]},
            ],
            "edges": [{"id": "road", "floor_id": "1", "from": "a", "to": "b"}],
        }

    def test_no_drift_projection_and_manual_calibration_are_numerically_correct(self) -> None:
        localizer = StageOneLocalizer(
            self.single_road_graph(),
            "1",
            Pose2D(2, 0, math.pi / 2),
        )
        projected = localizer.update(Pose2D(0, 2, 0))
        self.assertAlmostEqual(projected["raw_pose"]["x_m"], 0.0, places=6)
        self.assertAlmostEqual(projected["raw_pose"]["y_m"], 0.0, places=6)
        event = localizer.manual_calibrate(
            Pose2D(3, 4, 0.2),
            Pose2D(8, 0, -0.5),
        )
        calibrated = localizer.update(Pose2D(3, 4, 0.2))
        self.assertEqual(event["event"], "manual_localization_confirmation")
        self.assertAlmostEqual(calibrated["raw_pose"]["x_m"], 8.0, places=6)
        self.assertAlmostEqual(calibrated["raw_pose"]["y_m"], 0.0, places=6)
        self.assertAlmostEqual(calibrated["raw_pose"]["yaw_rad"], -0.5, places=6)

    def test_manual_calibration_reduces_a_known_initial_alignment_error(self) -> None:
        localizer = StageOneLocalizer(
            self.single_road_graph(),
            "1",
            Pose2D(0, 2, 0),
        )
        before = localizer.update(Pose2D(2, 0, 0))
        before_error = math.hypot(
            before["estimated_pose"]["x_m"] - 2,
            before["estimated_pose"]["y_m"],
        )
        localizer.manual_calibrate(Pose2D(2, 0, 0), Pose2D(2, 0, 0))
        after = localizer.update(Pose2D(2, 0, 0))
        after_error = math.hypot(
            after["estimated_pose"]["x_m"] - 2,
            after["estimated_pose"]["y_m"],
        )
        self.assertGreater(before_error, 0.0)
        self.assertAlmostEqual(after_error, 0.0, places=6)

    def test_wrong_start_outside_candidate_radius_stays_weak_without_jump(self) -> None:
        localizer = StageOneLocalizer(
            self.single_road_graph(),
            "1",
            Pose2D(0, 10, 0),
        )
        result = localizer.update(Pose2D(2, 0, 0))
        self.assertEqual(result["localization_state"], "weak")
        self.assertEqual(result["road_constraint"]["reason"], "no_candidate")
        self.assertEqual(result["raw_pose"], result["estimated_pose"])

    def test_parallel_roads_are_ambiguous_and_never_hard_snap(self) -> None:
        graph = {
            "nodes": [
                {"id": "a", "floor_id": "1", "position_m": [0, 0]},
                {"id": "b", "floor_id": "1", "position_m": [10, 0]},
                {"id": "c", "floor_id": "1", "position_m": [0, 1]},
                {"id": "d", "floor_id": "1", "position_m": [10, 1]},
            ],
            "edges": [
                {"id": "lower", "floor_id": "1", "from": "a", "to": "b"},
                {"id": "upper", "floor_id": "1", "from": "c", "to": "d"},
            ],
        }
        localizer = StageOneLocalizer(graph, "1", Pose2D(0, 0.5, 0), ambiguity_margin_m=0.2)
        result = localizer.update(Pose2D(2, 0, 0))
        self.assertFalse(result["road_constraint"]["accepted"])
        self.assertEqual(result["road_constraint"]["reason"], "ambiguous_parallel_roads")
        self.assertEqual(result["raw_pose"], result["estimated_pose"])

    def test_unique_road_uses_only_capped_soft_correction(self) -> None:
        localizer = StageOneLocalizer(
            self.single_road_graph(),
            "1",
            Pose2D(0, 1, 0),
            soft_gain=0.5,
            maximum_correction_m=0.2,
        )
        result = localizer.update(Pose2D(2, 0, 0))
        correction = abs(result["estimated_pose"]["y_m"] - result["raw_pose"]["y_m"])
        self.assertTrue(result["road_constraint"]["accepted"])
        self.assertEqual(result["road_constraint"]["candidates"][0]["edge_id"], "road")
        self.assertLessEqual(correction, 0.200001)

    def test_tracking_states_drive_explicit_localization_transitions(self) -> None:
        localizer = StageOneLocalizer(
            self.single_road_graph(),
            "1",
            Pose2D(0, 0, 0),
        )
        self.assertEqual(localizer.update(Pose2D(1, 0, 0), "normal")["localization_state"], "stable")
        self.assertEqual(localizer.update(Pose2D(1, 0, 0), "limited")["localization_state"], "weak")
        self.assertEqual(
            localizer.update(Pose2D(1, 0, 0), "notAvailable")["localization_state"],
            "lost",
        )


if __name__ == "__main__":
    unittest.main()
