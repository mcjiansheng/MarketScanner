from __future__ import annotations

import json
import math
import os
import re
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
from tools.PriorMap.distance_field import build_distance_fields, decode_level
from tools.PriorMap.prior_map_schema import build_package_manifest, validate_package
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
            repository / "app/ios/RTABMapApp/SupermarketFinalizationCore.swift",
            repository
            / "app/ios/RTABMapApp/RecoveryLifecyclePersistenceCore.swift",
            repository
            / "app/ios/RTABMapApp/RecoveryLifecycleEvidenceParser.swift",
            repository / "app/ios/RTABMapApp/StrictJSONScalar.swift",
            repository
            / "app/ios/RTABMapApp/StrictJSONKeyUniquenessValidator.swift",
            repository / "app/ios/RTABMapApp/StrictJSONDocumentParser.swift",
            repository / "app/ios/RTABMapApp/PriorMapPackageSnapshotCore.swift",
            repository / "app/ios/RTABMapApp/PriorMapScanMatcher.swift",
            repository / "app/ios/RTABMapApp/PriceTagLocalizationCore.swift",
            repository
            / "app/ios/RTABMapApp/PriorMapPackageIntegrityCore.swift",
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
            match = re.search(
                r"(?m)^Finalization test peak RSS bytes: (\d+)$",
                run_result.stdout,
            )
            self.assertIsNotNone(match, run_result.stdout)
            peak_rss_bytes = int(match.group(1))
            self.assertLess(
                peak_rss_bytes,
                256 * 1024 * 1024,
                f"100k-record finalization peak RSS was {peak_rss_bytes} bytes",
            )
            # P7R6A: the device-side strict parser and the PC reader must
            # classify every shared recovery fixture identically.
            from tools.PriorMap.tests.test_stage3 import (
                EXPECTED_RECOVERY_FIXTURE_CATEGORIES,
                RECOVERY_FIXTURES_DIR,
                python_recovery_fixture_category,
            )

            fixture_result = subprocess.run(
                [
                    str(executable),
                    "--recovery-fixtures",
                    str(RECOVERY_FIXTURES_DIR),
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(fixture_result.returncode, 0, fixture_result.stderr)
            swift_categories = {}
            for line in fixture_result.stdout.splitlines():
                name, _, category = line.partition(" ")
                if name.endswith(".jsonl"):
                    swift_categories[name] = category
            self.assertEqual(
                sorted(swift_categories),
                sorted(EXPECTED_RECOVERY_FIXTURE_CATEGORIES),
                fixture_result.stdout,
            )
            for name, swift_category in sorted(swift_categories.items()):
                python_category = python_recovery_fixture_category(
                    RECOVERY_FIXTURES_DIR / name
                )
                self.assertEqual(
                    swift_category,
                    python_category,
                    f"Swift parser and PC reader disagree on {name}",
                )
                self.assertEqual(
                    swift_category,
                    EXPECTED_RECOVERY_FIXTURE_CATEGORIES[name],
                    name,
                )
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

            (package / "._manifest.json").write_bytes(
                b"\x00\x05\x16\x07AppleDouble metadata\xb0"
            )
            (package / ".DS_Store").write_bytes(b"Finder metadata")
            metadata_result = subprocess.run(
                [str(executable), str(package)],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(metadata_result.returncode, 0, metadata_result.stderr)

            unexpected = package / "unexpected.json"
            unexpected.write_text("{}\n", encoding="utf-8")
            unexpected_result = subprocess.run(
                [str(executable), str(package)],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(unexpected_result.returncode, 0)
            unexpected.unlink()

            # P7R6C-C3: run every integrity case inside ONE executable
            # invocation. Each directory is named "<case>.<expected>" and
            # the Swift harness validates them all without re-launching
            # the process (repeated launches blow CI wall-clock budgets).
            suite_root = Path(temporary) / "integrity-suite"
            suite_root.mkdir()
            valid_package = suite_root / "baseline.pass"
            shutil.copytree(package, valid_package)
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
                # P7R6C-C3 (M1/M12): a same-size replacement whose JSON is
                # self-consistent must still fail: the snapshot binds the
                # original bytes, so a hash-A/parse-B split is impossible.
                "same-size-self-consistent": lambda root: (
                    (root / "shelves.json").write_bytes(
                        _same_size_replacement(
                            (root / "shelves.json").read_bytes()
                        )
                    )
                ),
                # M3: a symlinked artifact must be rejected (no-follow read).
                "symlink-artifact": lambda root: (
                    _replace_with_symlink(root, "shelves.json", "fixed_structures.json")
                ),
                # M4: an extra hard link means st_nlink != 1; reject.
                "hardlink-artifact": lambda root: (
                    _create_extra_hardlink(root, "shelves.json", "shelves-link.json")
                ),
                # M5: a truncated artifact must be rejected (byte count and
                # SHA no longer match the snapshot manifest).
                "truncated-artifact": lambda root: (
                    (root / "shelves.json").write_bytes(
                        (root / "shelves.json").read_bytes()[:-1]
                    )
                ),
                # M6: a file added while the package is being read changes
                # the directory file set; the snapshot must fail closed.
                "file-set-added": lambda root: (
                    (root / "late_artifact.json").write_text("{}\n", encoding="utf-8")
                ),
                # M7: a preview image replaced by different bytes fails the
                # SHA bound in the package manifest.
                "preview-swap": lambda root: (
                    (root / "preview.png").write_bytes(
                        b"\x89PNG\r\n\x1a\n" + b"different preview bytes"
                    )
                ),
                # M8: a floor preview replaced by different bytes fails.
                "floor-preview-swap": lambda root: (
                    _replace_first_floor_preview(root)
                ),
                # M9: a duplicate key in the package manifest must be
                # rejected by the strict duplicate-key scanner.
                "manifest-duplicate-key": lambda root: (
                    (root / "package_manifest.json").write_bytes(
                        _duplicate_key_bytes(
                            (root / "package_manifest.json").read_bytes(),
                            "artifact_count",
                        )
                    )
                ),
                # M10: a nested duplicate key inside elements.json.
                "elements-duplicate-key": lambda root: (
                    (root / "elements.json").write_bytes(
                        _duplicate_key_bytes(
                            (root / "elements.json").read_bytes(),
                            "shape_type",
                        )
                    )
                ),
                # M11: a duplicate top-level `valid` key in the validation
                # report must be rejected.
                "report-duplicate-key": lambda root: (
                    (root / "validation_report.json").write_bytes(
                        _duplicate_key_bytes(
                            (root / "validation_report.json").read_bytes(),
                            "valid",
                        )
                    )
                ),
            }
            for name, mutate in mutations.items():
                corrupted = suite_root / f"{name}.fail"
                shutil.copytree(package, corrupted)
                mutate(corrupted)
            suite_result = subprocess.run(
                [str(executable), "--integrity-suite", str(suite_root)],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(
                suite_result.returncode,
                0,
                suite_result.stderr + "\n" + suite_result.stdout,
            )

    @staticmethod
    def _rewrite_integrity_json(path: Path, mutate: object) -> None:
        value = json.loads(path.read_text(encoding="utf-8"))
        mutate(value)
        path.write_text(
            json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )


def _same_size_replacement(original: bytes) -> bytes:
    """Replaces bytes one-for-one so the file keeps its exact length but
    the content changes. The replacement is valid ASCII/JSON-ish content so
    any "self-consistent JSON" argument cannot hide the SHA mismatch."""
    if not original:
        return original
    result = bytearray(original)
    for index in range(len(result)):
        if result[index] == ord("{"):
            result[index] = ord("[")
        elif result[index] == ord("}"):
            result[index] = ord("]")
    return bytes(result)


def _replace_with_symlink(root: Path, name: str, target_name: str) -> None:
    target = root / target_name
    target_bytes = target.read_bytes()
    (root / name).unlink()
    (root / name).symlink_to(target_name)
    # The symlink must not be resolvable as the original content: keep the
    # target untouched and let the no-follow reader reject the link itself.
    _ = target_bytes


def _create_extra_hardlink(root: Path, name: str, link_name: str) -> None:
    (root / link_name).hardlink_to(root / name)


def _replace_first_floor_preview(root: Path) -> None:
    previews = sorted(root.glob("preview_floor_*.png"))
    if not previews:
        return
    target = previews[0]
    target.write_bytes(target.read_bytes() + b"tampered")


def _duplicate_key_bytes(data: bytes, key: str) -> bytes:
    """Injects a duplicate JSON key by appending `"key": <key>," just after
    the first occurrence of the key name. The duplicate scanner must reject
    the document before JSONSerialization can apply last-key-wins."""
    needle = ('"%s"' % key).encode("utf-8")
    position = data.find(needle)
    if position < 0:
        return data
    # Find the end of the first value after the key to splice a duplicate.
    cursor = position + len(needle)
    while cursor < len(data) and data[cursor] in b" \t\r\n":
        cursor += 1
    if cursor >= len(data) or data[cursor] != ord(":"):
        return data
    cursor += 1
    while cursor < len(data) and data[cursor] in b" \t\r\n":
        cursor += 1
    if cursor >= len(data):
        return data
    value_start = cursor
    if data[cursor] == ord('"'):
        cursor += 1
        while cursor < len(data) and data[cursor] != ord('"'):
            cursor += 1
        cursor += 1
    elif data[cursor] == ord("{"):
        depth = 0
        while cursor < len(data):
            if data[cursor] == ord("{"):
                depth += 1
            elif data[cursor] == ord("}"):
                depth -= 1
                if depth == 0:
                    cursor += 1
                    break
            cursor += 1
    else:
        while cursor < len(data) and data[cursor] not in b",}\n":
            cursor += 1
    value_end = cursor
    insertion = b', "' + key.encode("utf-8") + b'": null'
    return data[:value_end] + insertion + data[value_end:]


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

    def test_package_integrity_ignores_macos_filesystem_metadata(self) -> None:
        package = convert_workbook(self.workbook, self.root / "package")
        expected_manifest = json.loads(
            (package / "package_manifest.json").read_text(encoding="utf-8")
        )
        (package / "._manifest.json").write_bytes(
            b"\x00\x05\x16\x07AppleDouble metadata\xb0"
        )
        (package / ".DS_Store").write_bytes(b"Finder metadata")

        self.assertEqual(build_package_manifest(package), expected_manifest)
        self.assertTrue(validate_package(package)["valid"])

        (package / "unexpected.json").write_text("{}\n", encoding="utf-8")
        validation = validate_package(package)
        self.assertFalse(validation["valid"])
        self.assertIn(
            "package_artifact_set",
            {item["code"] for item in validation["errors"]},
        )

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

    def test_distance_field_preserves_irregular_shelves_and_pillars(self) -> None:
        elements = [
            {
                "shape_type": "MapShelf",
                "floor_id": "1",
                "visible": True,
                "geometry": {
                    "type": "Polygon",
                    "coordinates": [
                        [0.5, 0.5],
                        [3.5, 0.5],
                        [3.5, 1.5],
                        [1.5, 1.5],
                        [1.5, 3.5],
                        [0.5, 3.5],
                    ],
                },
            },
            {
                "shape_type": "MapPillar",
                "floor_id": "1",
                "visible": True,
                "geometry": {
                    "type": "Polygon",
                    "coordinates": [
                        [4.2, 2.0],
                        [4.8, 2.0],
                        [4.8, 2.6],
                        [4.2, 2.6],
                    ],
                },
            },
        ]
        payload = build_distance_fields(
            elements,
            [{
                "id": "1",
                "bounds": {
                    "min_x_m": 0.0,
                    "min_y_m": 0.0,
                    "max_x_m": 6.0,
                    "max_y_m": 5.0,
                },
            }],
            resolutions_m=(0.1,),
        )
        level = payload["floors"]["1"]["levels"][0]
        values = decode_level(level)

        def value_at(x_m: float, y_m: float) -> int:
            origin_x, origin_y = level["origin_m"]
            cell_x = int(math.floor((x_m - origin_x) / level["resolution_m"]))
            cell_y = int(math.floor((y_m - origin_y) / level["resolution_m"]))
            return values[cell_y * level["width"] + cell_x]

        self.assertLessEqual(value_at(1.5, 2.5), 10)
        self.assertLessEqual(value_at(4.5, 2.0), 10)
        self.assertGreater(value_at(2.5, 2.5), 50)

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


class PriorMapStrictSchemaTests(unittest.TestCase):
    """P7R6C-C5: prior-map JSON strict scalar and duplicate-key contract.

    Every fixture mutates one authoritative field so a strict reader must
    fail closed; the mutations keep the JSON parseable so the failure is
    the schema/duplicate-key rejection, not a syntax error.
    """

    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        workbook = self.root / "fixture.xlsx"
        write_workbook(workbook, fixture_rows())
        self.package = convert_workbook(workbook, self.root / "package")

    def tearDown(self) -> None:
        self.temp.cleanup()

    def copy_with(self, name: str) -> Path:
        destination = self.root / name
        shutil.copytree(self.package, destination)
        return destination

    @staticmethod
    def refresh_manifest(package: Path) -> None:
        """Rebuilds package_manifest.json after an authoritative file is
        mutated so the SHA/hash checks stay satisfied and the strict-schema
        rejection (not the hash rejection) is what fails closed."""
        manifest = build_package_manifest(package)
        (package / "package_manifest.json").write_text(
            json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )

    @staticmethod
    def rewrite_json(path: Path, mutate: object) -> None:
        value = json.loads(path.read_text(encoding="utf-8"))
        mutate(value)
        path.write_text(
            json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )

    def assert_invalid(self, package: Path, expected_code: str, label: str) -> None:
        result = validate_package(package)
        self.assertFalse(result["valid"], label)
        self.assertTrue(
            any(item["code"] == expected_code for item in result["errors"]),
            f"{label}: expected {expected_code}, got {result['errors']}",
        )

    def test_n1_fractional_version_rejected(self) -> None:
        # N1: {"version":1.5} must be rejected by every formal reader.
        package = self.copy_with("n1-fractional-version")
        self.rewrite_json(
            package / "package_manifest.json",
            lambda value: value["artifacts"][0].__setitem__("version", 1.5),
        )
        self.assert_invalid(
            package, "package_artifact_schema", "N1 fractional manifest version"
        )

    def test_n2_boolean_artifact_count_rejected(self) -> None:
        # N2: {"artifact_count":true} must be rejected.
        package = self.copy_with("n2-boolean-count")
        self.rewrite_json(
            package / "package_manifest.json",
            lambda value: value.__setitem__("artifact_count", True),
        )
        self.assert_invalid(
            package, "package_manifest", "N2 boolean artifact_count"
        )

    def test_n3_fractional_bytes_rejected(self) -> None:
        # N3: {"bytes":3.5} must be rejected (strict integer contract).
        package = self.copy_with("n3-fractional-bytes")
        self.rewrite_json(
            package / "package_manifest.json",
            lambda value: value["artifacts"][0].__setitem__("bytes", 3.5),
        )
        self.assert_invalid(
            package, "package_artifact_bytes", "N3 fractional artifact bytes"
        )

    def test_n4_numeric_visible_rejected(self) -> None:
        # N4: {"visible":1} is not a JSON boolean and must be rejected.
        package = self.copy_with("n4-numeric-visible")
        elements = json.loads((package / "elements.json").read_text())
        elements["elements"][0]["visible"] = 1
        (package / "elements.json").write_text(
            json.dumps(elements, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
        )
        self.refresh_manifest(package)
        self.assert_invalid(
            package, "visibility_count", "N4 numeric visible field"
        )

    def test_n5_boolean_geometry_coordinate_rejected(self) -> None:
        # N5: a geometry coordinate like [true, 2.0] must be rejected.
        package = self.copy_with("n5-boolean-coordinate")
        elements = json.loads((package / "elements.json").read_text())
        elements["elements"][0]["geometry"] = {
            "type": "polygon",
            "coordinates": [[[True, 2.0], [1.0, 2.0], [1.0, 3.0], [True, 2.0]]],
        }
        (package / "elements.json").write_text(
            json.dumps(elements, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
        )
        self.refresh_manifest(package)
        self.assert_invalid(
            package, "floor_bounds", "N5 boolean geometry coordinate"
        )

    def test_n6_boolean_bounds_rejected(self) -> None:
        # N6: a bounds value like {"min_x_m":false} must be rejected.
        package = self.copy_with("n6-boolean-bounds")
        manifest = json.loads((package / "manifest.json").read_text())
        manifest["bounds"]["min_x_m"] = False
        (package / "manifest.json").write_text(
            json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
        )
        self.refresh_manifest(package)
        self.assert_invalid(package, "map_bounds", "N6 boolean bounds field")

    def test_n7_manifest_duplicate_version_rejected(self) -> None:
        # N7: a duplicate manifest version key must be rejected before
        # last-key-wins can hide the ambiguity.
        package = self.copy_with("n7-duplicate-version")
        (package / "manifest.json").write_bytes(
            _duplicate_key_bytes(
                (package / "manifest.json").read_bytes(), "version"
            )
        )
        self.assert_invalid(package, "invalid_json", "N7 duplicate version key")

    def test_n8_report_duplicate_valid_rejected(self) -> None:
        # N8: a duplicate `valid` key in the validation report.
        package = self.copy_with("n8-duplicate-valid")
        (package / "validation_report.json").write_bytes(
            _duplicate_key_bytes(
                (package / "validation_report.json").read_bytes(), "valid"
            )
        )
        self.assert_invalid(package, "invalid_json", "N8 duplicate valid key")

    def test_n9_escaped_equivalent_duplicate_field_rejected(self) -> None:
        # N9: an escaped-equivalent duplicate key ("version" vs "\u0076ersion")
        # must be detected as the same key.
        package = self.copy_with("n9-escaped-duplicate")
        data = (package / "manifest.json").read_bytes()
        needle = b'"version":'
        position = data.find(needle)
        self.assertGreaterEqual(position, 0)
        insertion = b', "\\u0076ersion": 1'
        (package / "manifest.json").write_bytes(
            data[:position + len(needle)] + insertion + data[position + len(needle):]
        )
        self.assert_invalid(
            package, "invalid_json", "N9 escaped-equivalent duplicate key"
        )


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
